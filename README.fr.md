[![English](https://img.shields.io/badge/lang-English-lightgrey.svg)](README.md) [![Français](https://img.shields.io/badge/lang-Fran%C3%A7ais-F65801.svg)](README.fr.md)

# macstatusd 0.5

Daemon macOS qui expose l'état ON/OFF du Mac à Homebridge (plugin
[http-webhooks](https://github.com/benzman81/homebridge-http-webhooks)), et qui
accepte les commandes ON/OFF venant de HomeKit.

```
HomeKit ──► Homebridge ──► GET /wake | /sleep ──► macstatusd ──► macOS
   ▲                       GET /state  ◄──────────────┤
   └───────── webhook push (state=true|false) ◄────────┘
```

## Sémantique de l'état

| Situation réelle du Mac                                  | État |
|----------------------------------------------------------|------|
| Bureau déverrouillé, dans une app                        | ON   |
| Écran de verrouillage visible (champ mot de passe)       | ON   |
| Fenêtre de login (personne de connecté), écran allumé    | ON   |
| Économiseur d'écran actif                                | OFF  |
| Écran éteint (display sleep)                             | OFF  |
| Veille système                                           | OFF  |
| Aucun écran connecté                                     | OFF  |

Autrement dit : **ON = une interface est visible et utilisable**, OFF = rien à
l'écran.

## Ce qui rend l'état déterministe

Les prototypes 4.x déduisaient l'état en *lisant les messages de log privés de
`loginwindow`* (`log stream --predicate 'process == "loginwindow"'`) et en
cherchant des chaînes comme `screenLockUIIsHidden` ou `updatePlaceholderString`.
C'était la cause de fond du problème : ces chaînes ne sont pas une API, elles
changent d'une version de macOS à l'autre, un message coupé entre deux lectures
de 4 Ko est perdu, et un drapeau resté bloqué à `true` fige l'état pour toujours.

La 0.5 n'utilise plus aucun log. Chaque fait vient d'une API observable,
avec une source de repli indépendante :

| Fait | Source primaire | Repli |
|------|-----------------|-------|
| Veille système | IOKit `IORegisterForSystemPower` (événement) | `NSWorkspace.didWake` |
| Écran éteint | `CGDisplayIsAsleep` (écran principal) | tous les écrans en ligne endormis + `screensDidSleep/Wake` |
| Économiseur en cours | process `ScreenSaverEngine` | fenêtre à l'écran au niveau `kCGScreenSaverWindowLevel` ou au‑dessus, appartenant à un process d'économiseur ; notifications `com.apple.screensaver.didstart/didstop` |
| Économiseur **seul à l'écran** | `IOHIDSystem.HIDIdleTime` comparé à l'instant de démarrage | — (voir ci‑dessous) |
| Session verrouillée | IORegistry `IOConsoleLocked` / `IOConsoleUsers` | `CGSessionCopyCurrentDictionary` |

### Économiseur en cours ≠ économiseur à l'écran

C'est le piège principal, mesuré sur macOS 26.5 (`diagnostics/saver-probe.swift`) :
quand une frappe fait apparaître le champ de mot de passe, **l'économiseur
continue de tourner derrière le panneau**. Pendant cet état :

- le process `ScreenSaverEngine` reste vivant ;
- `SACScreenSaverIsRunning` (API privée d'Apple) renvoie toujours `1` ;
- `com.apple.screensaver.didstop` n'est posté qu'**au déverrouillage** ;
- la liste des fenêtres à l'écran est inchangée ;
- `IsSecureEventInputEnabled` ne dit rien d'utile : `loginwindow` peut garder la
  saisie sécurisée bien après un déverrouillage.

Le seul signal qui change est l'activité matérielle. Comme sur macOS **toute
frappe ou tout mouvement écarte l'économiseur**, la règle est :

> l'économiseur occupe l'écran s'il tourne **et** qu'aucune activité clavier /
> souris n'a eu lieu depuis son démarrage.

`HIDIdleTime` est lisible session verrouillée, ce qui rend la règle utilisable
exactement là où on en a besoin. Une inactivité prolongée
(`saver_redisplay_idle_seconds`, 90 s) réarme l'économiseur, macOS y revenant
quand le panneau reste sans réponse. `saver_dismiss_on_input: false` désactive la
règle, et les tests unitaires (`swift test`, `ScreenSaverOracleTests`) la vérifient
sans économiseur réel.

Propriétés qui en découlent :

- **Aucun état mémorisé qui puisse rester bloqué.** Les faits sont relus à
  chaque cycle ; les notifications ne servent qu'à réagir plus vite, jamais de
  seule source de vérité.
- **Anti‑rebond explicite.** Un changement n'est publié qu'après une période de
  stabilité (`settle_on_ms` / `settle_off_ms`), ce qui absorbe les états
  transitoires (écran noir d'une seconde pendant le verrouillage, par exemple).
- **Auto‑réparation.** Un trou dans la boucle de scrutation (veille, gel,
  surcharge) est détecté et déclenche une resynchronisation complète.
- **OFF poussé *avant* la veille.** IOKit permet de retenir la veille le temps
  d'envoyer le webhook ; sans ça HomeKit resterait sur ON pendant toute la veille.
- **Commandes vérifiées par les faits.** Une commande HomeKit qui n'a aucun effet
  observable est escaladée puis abandonnée avec un avertissement, et l'état
  revient à la réalité au lieu de mentir.
- **Battement de cœur.** L'état est republié périodiquement : un webhook perdu ou
  un Homebridge redémarré ne peut pas laisser HomeKit désynchronisé.

Le cas « verrouillé sans champ visible » est traité comme ON par défaut (l'écran
de verrouillage *est* une UI accessible). `require_auth_ui_when_locked: true`
inverse ce choix en exigeant la saisie sécurisée active.

## Installation

```bash
./scripts/install.sh
```

**Sans `sudo`.** Le script élève lui‑même les privilèges pour `/opt/macstatusd`
et rien d'autre : lancé entièrement en root, `$UID` vaut 0 et
`launchctl bootstrap gui/0` échoue avec « Domain does not support specified
action » (un LaunchAgent appartient à une session graphique d'utilisateur). Si
tu l'appelles quand même avec `sudo`, il se relance de lui‑même sous
`$SUDO_USER`.

Compile en release, installe `/opt/macstatusd/macstatusd`, crée
`/opt/macstatusd/config.json` s'il n'existe pas, puis charge le LaunchAgent
`~/Library/LaunchAgents/com.djoko.macstatusd.plist` et vérifie que l'endpoint
répond.

**LaunchAgent (session Aqua) et non LaunchDaemon** : c'est ce qui donne accès à
l'état des écrans, aux notifications d'économiseur d'écran et à la saisie
sécurisée. Conséquence : macstatusd ne tourne pas avant l'ouverture de session
(après un redémarrage, Homebridge ne peut pas lire `/state` tant que personne ne
s'est connecté). Le verrouillage de session, lui, est lu via l'IORegistry et
fonctionnerait aussi depuis un LaunchDaemon.

Désinstallation : `./scripts/uninstall.sh` (ajouter `--purge` pour supprimer
aussi la configuration et les journaux).

## Endpoints

| Route | Effet |
|-------|-------|
| `GET /state` | `1` (ON) ou `0` (OFF) — l'état publié, identique au dernier webhook |
| `GET /status` | diagnostic JSON : faits bruts, preuves, commande en cours, état du webhook |
| `GET /health` | `OK` |
| `GET /sleep` (`/off`) | commande HomeKit OFF |
| `GET /wake` (`/on`) | commande HomeKit ON |
| `GET /resync` | republie l'état courant vers Homebridge |

### Contrôle d'accès

`/health` est toujours servi, sans aucun contrôle. Toute autre route passe par
ces contrôles, dans cet ordre (le premier refus répond) :

1. **En-tête `Host`.** Acceptés : un littéral IPv4 ou IPv6, `localhost`, les
   noms `.local` du Mac lui-même (nom Bonjour et nom d'hôte) et les noms de
   `allowed_hosts`. Tout autre nom reçoit `403` (protection contre le DNS
   rebinding). Une requête sans `Host` (HTTP/1.0) passe ; un `Host` vide ou mal
   formé est refusé.
2. **Requêtes de navigateur.** Un en-tête `Origin`, ou un `Sec-Fetch-Site`
   autre que `none`, reçoit `403` : une page web ouverte sur le Mac ne peut pas
   piloter le daemon, avec ou sans jeton.
3. **Méthode.** Les commandes n'acceptent que `GET` ; `/state` et `/status`
   acceptent `GET` et `HEAD`. Tout autre cas reçoit `405`.
4. **Jeton.** Envoyé dans l'en-tête `X-Auth-Token` ou sous la forme
   `Authorization: Bearer <jeton>`. Le `?token=` dans l'URL est refusé, sauf si
   `allow_query_token` vaut `true` (un jeton dans une URL finit dans les
   journaux et l'historique).
   - Avec `auth_token` : une commande exige le bon jeton (`401` sinon).
     `/state` et `/status` sont libres depuis la boucle locale et exigent le
     jeton depuis toute autre machine.
   - Sans `auth_token` : seuls les clients en boucle locale sont servis ; tout
     autre client reçoit `403`, pour les commandes comme pour les lectures.

Un chemin inconnu reçoit `404`, quel que soit le demandeur.

```bash
curl -H "X-Auth-Token: jeton-essai-0123456789abcdef" http://192.0.2.10:9090/wake
curl -H "Authorization: Bearer jeton-essai-0123456789abcdef" http://192.0.2.10:9090/state
```

## Configuration

`/opt/macstatusd/config.json` — toutes les clés sont optionnelles, une clé
absente ou invalide retombe sur son défaut sans empêcher le démarrage.

| Clé | Défaut | Rôle |
|-----|--------|------|
| `enabled` | `false` | active les webhooks vers Homebridge |
| `webhook_base_url` | `""` | ex. `http://192.0.2.10:51828` |
| `accessory_id` | `"mac"` | `accessoryId` envoyé au plugin |
| `port` | `9090` | port HTTP |
| `bind_address` | `""` | `""` = toutes interfaces, `127.0.0.1` = loopback |
| `auth_token` | `""` | jeton des commandes et des lectures depuis une autre machine ; vide = seuls les clients en boucle locale sont servis |
| `allow_query_token` | `false` | accepte aussi le jeton sous la forme `?token=…` dans l'URL |
| `allowed_hosts` | `[]` | noms supplémentaires acceptés dans l'en-tête `Host` (liste de chaînes) |
| `off_action` | `"screensaver"` | `screensaver`, `display_sleep` ou `system_sleep` |
| `off_escalate_to_display_sleep` | `true` | si l'action OFF reste sans effet observé |
| `stop_screensaver_on_wake` | `true` | termine l'économiseur lors d'un ON |
| `command_confirm_timeout_ms` | `12000` | délai avant d'abandonner une commande |
| `command_escalate_after_ms` | `2500` | délai avant d'escalader une commande sans effet |
| `saver_dismiss_on_input` | `true` | une activité après le démarrage de l'économiseur → ON |
| `saver_dismiss_grace_ms` | `1500` | marge ignorée juste après le démarrage |
| `saver_redisplay_idle_seconds` | `90` | inactivité au bout de laquelle l'économiseur est réputé réaffiché |
| `poll_interval_ms` | `500` | cadence de relecture des faits |
| `settle_on_ms` / `settle_off_ms` | `300` / `800` | stabilité exigée avant publication |
| `heartbeat_seconds` | `60` | republication périodique (`0` = désactivé) |
| `require_auth_ui_when_locked` | `false` | verrouillé sans champ visible → OFF |
| `webhook_timeout_ms` / `webhook_retries` | `4000` / `3` | robustesse des envois |
| `log_level` | `"info"` | `error`, `warn`, `info`, `debug` |
| `log_file` | `""` | `""` = `~/Library/Logs/macstatusd/macstatusd.log` |
| `off_command` / `wake_command` | `[]` | remplacent l'action intégrée (argv, ou chaîne passée à `sh -c`) |

### Choix de l'action OFF

`off_action` décide de ce que fait HomeKit → OFF :

- `screensaver` (défaut) — démarre l'économiseur d'écran. Le Mac reste éveillé et
  joignable, donc **HomeKit ON peut vraiment rallumer**.
- `display_sleep` — éteint l'écran (`pmset displaysleepnow`). Même propriété.
- `system_sleep` — vraie veille (`pmset sleepnow`). Attention : pendant la veille
  le daemon est gelé, `/wake` n'est pas reçu ; il faut Wake‑on‑LAN côté
  Homebridge pour rallumer.

Si la session est déjà verrouillée, `screensaver` éteint l'écran à la place :
mesuré sur macOS 26, `open -a ScreenSaverEngine` reste sans effet sur une
session verrouillée. Un OFF reçu alors que le Mac est déjà OFF ne déclenche
aucune action.

Dans les trois cas l'état publié devient OFF, et la commande n'est considérée
comme réussie que si les faits le confirment.

## Homebridge

Plugin `homebridge-http-webhooks`, accessoire de type switch :

```json
{
  "platform": "HttpWebHooks",
  "webhook_port": "51828",
  "switches": [
    {
      "id": "mac",
      "name": "Mac",
      "on_url": "http://<ip-du-mac>:9090/wake",
      "on_method": "GET",
      "off_url": "http://<ip-du-mac>:9090/sleep",
      "off_method": "GET"
    }
  ]
}
```

`webhook_base_url` dans `config.json` doit pointer vers ce `webhook_port`, et
`accessory_id` correspondre à `id`.

Les commandes envoyées depuis une autre machine exigent un `auth_token` renseigné et
envoyé dans un en-tête (voir [Contrôle d'accès](#contrôle-daccès)) : sans jeton,
seuls les clients en boucle locale sont servis.

## Diagnostic

```bash
/opt/macstatusd/macstatusd --once      # état + faits en JSON, puis quitte
/opt/macstatusd/macstatusd --watch     # tableau des faits en continu
curl -s localhost:9090/status          # vue complète de l'instance qui tourne
tail -f ~/Library/Logs/macstatusd/macstatusd.log
launchctl print gui/$UID/com.djoko.macstatusd
```

`reason` dans `/status` indique la règle qui a décidé : `desktop-ui`,
`lock-screen-ui`, `login-window-ui`, `display-asleep`, `system-asleep`,
`no-display`, `locked-without-auth-ui`, `screensaver:<preuves>` (par exemple
`screensaver:process+notification`), `command:on`, `command:off/<action>`.

## Tests

```bash
swift test                               # tests unitaires de MacStatusCore (règles, moteur, webhook, HTTP)
./scripts/selftest.sh                    # lance swift test, puis des vérifications sur des instances d'essai isolées
./scripts/validate-live.sh               # validation guidée en passant par les vrais états
# Sonde de diagnostic : déclenche un vrai OFF (économiseur) à t≈4 s
swiftc -O -o /tmp/saver-probe diagnostics/saver-probe.swift && /tmp/saver-probe 60
```

`selftest.sh` lance d'abord `swift test`, puis démarre des instances d'essai
isolées du vrai daemon : elles écoutent sur 127.0.0.1, sur les ports 19000 à
19999, leurs commandes sont inertes (`/usr/bin/true`) et les webhooks vont vers
un faux récepteur local. Il vérifie le retour honnête d'une commande sans
effet, l'authentification et le contrôle d'accès, les erreurs HTTP, les réessais
de webhook et la reprise du serveur quand le port est occupé.

Par défaut il est non intrusif et **ne lance aucun faux économiseur** : un faux
processus `ScreenSaverEngine` est visible de tout le Mac, donc un vrai daemon en
marche le verrait aussi, passerait à OFF et le pousserait vers HomeKit et Home
Assistant. Les sections qui en ont besoin (détection de l'économiseur, commandes
HomeKit confirmées par les faits, push OFF) sont marquées SAUTÉ. Variables
d'environnement :

- `SELFTEST_FAUX_ECONOMISEUR=1` : joue le faux économiseur, un binaire nommé
  `ScreenSaverEngine` (exactement ce que l'oracle « process » observe). Seulement
  avec le vrai daemon **arrêté** : le script refuse si quelque chose répond sur
  le port 9090.
- `SELFTEST_IGNORER_VERROU=1` : une session verrouillée ne fait plus sauter les
  sections qui exigent un écran allumé (par exemple depuis une session
  distante).
- `SELFTEST_FORCER_ECRAN_ETEINT=1` : force la branche « écran éteint » sans rien
  éteindre.
- `SWIFT_SCRATCH=<dossier>` : dossier de compilation de Swift, conservé après
  l'exécution (sinon un dossier temporaire, supprimé à la sortie). Il doit
  rester hors de `~/Documents` : la signature du `.xctest` échoue sous iCloud.

Si l'écran est éteint, la session verrouillée (sauf `SELFTEST_IGNORER_VERROU=1`)
ou le Mac en veille, les sections qui exigent un écran allumé sont marquées
SAUTÉ au lieu d'échouer.

`validate-live.sh` (à lancer sans `sudo`) demande d'effectuer les vraies actions (verrouiller, lancer
l'économiseur, éteindre l'écran, mettre en veille) et vérifie automatiquement ce
que macstatusd a rapporté pendant chacune.

## Limites connues

- **Veille système** : rien ne tourne pendant la veille. `/state` est
  injoignable et `/wake` ne peut pas réveiller le Mac — il faut Wake‑on‑LAN.
  C'est pourquoi `off_action` vaut `screensaver` par défaut.
- **Avant l'ouverture de session** : le LaunchAgent n'est pas encore chargé.
- **Multi‑utilisateur** : deux sessions ouvertes signifient deux instances pour
  un seul port ; la seconde réessaie en boucle sans planter, mais l'état publié
  est celui de l'instance qui détient le port.
- **Écran externe coupé physiquement** : macOS le considère allumé, donc l'état
  reste ON.
- **Économiseurs hébergés par `legacyScreenSaver`** : détectés par l'oracle
  fenêtres, qui nécessite la session graphique (donc le LaunchAgent).
- **Échap sur l'écran de verrouillage** : masquer l'overlay d'authentification
  avec Échap ne ramène pas l'état à OFF immédiatement ; il y revient après
  `saver_redisplay_idle_seconds` (90 s) d'inactivité, ou dès que l'écran
  s'éteint. Aucun signal distinguant l'overlay masqué de l'overlay affiché n'est
  encore identifié (investigation en cours avec `diagnostics/saver-probe.swift`).

## Historique

`Versionning/` et `backtest+debug/` contiennent les versions 1 à 4.4.4 et les
outils de capture qui ont servi à identifier les signaux exploitables.
`macstatusdV4.4.4.swift` reste à la racine pour référence ; la 0.5 ne le remplace
pas sur disque.

## Licence

MIT — voir [LICENSE](LICENSE).
