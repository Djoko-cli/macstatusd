[![English](https://img.shields.io/badge/lang-English-lightgrey.svg)](README.md) [![Français](https://img.shields.io/badge/lang-Fran%C3%A7ais-F65801.svg)](README.fr.md)

# macstatusd 5.0

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

La version 4 déduisait l'état en *lisant les messages de log privés de
`loginwindow`* (`log stream --predicate 'process == "loginwindow"'`) et en
cherchant des chaînes comme `screenLockUIIsHidden` ou `updatePlaceholderString`.
C'était la cause de fond du problème : ces chaînes ne sont pas une API, elles
changent d'une version de macOS à l'autre, un message coupé entre deux lectures
de 4 Ko est perdu, et un drapeau resté bloqué à `true` fige l'état pour toujours.

La version 5 n'utilise plus aucun log. Chaque fait vient d'une API observable,
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
règle, et `--check-rules` la vérifie sans économiseur réel.

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
`~/Library/LaunchAgents/com.majid.macstatusd.plist` et vérifie que l'endpoint
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

Si `auth_token` est renseigné, `/sleep`, `/wake` et `/resync` exigent
`?token=…` ou l'en‑tête `X-Auth-Token`. `/state`, `/status` et `/health` restent
publics (Homebridge lit `/state` sans jeton).

## Configuration

`/opt/macstatusd/config.json` — toutes les clés sont optionnelles, une clé
absente ou invalide retombe sur son défaut sans empêcher le démarrage.

| Clé | Défaut | Rôle |
|-----|--------|------|
| `enabled` | `false` | active les webhooks vers Homebridge |
| `webhook_base_url` | `""` | ex. `http://192.168.1.89:51828` |
| `accessory_id` | `"mac"` | `accessoryId` envoyé au plugin |
| `port` | `9090` | port HTTP |
| `bind_address` | `""` | `""` = toutes interfaces, `127.0.0.1` = loopback |
| `auth_token` | `""` | protège les commandes |
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

## Diagnostic

```bash
/opt/macstatusd/macstatusd --once      # état + faits en JSON, puis quitte
/opt/macstatusd/macstatusd --watch     # tableau des faits en continu
curl -s localhost:9090/status          # vue complète de l'instance qui tourne
tail -f ~/Library/Logs/macstatusd/macstatusd.log
launchctl print gui/$UID/com.majid.macstatusd
```

`reason` dans `/status` indique la règle qui a décidé : `desktop-ui`,
`lock-screen-ui`, `login-window-ui`, `display-asleep`, `system-asleep`,
`no-display`, `locked-without-auth-ui`, `screensaver:<preuves>` (par exemple
`screensaver:process+notification`), `command:on`, `command:off/<action>`.

## Tests

```bash
./scripts/selftest.sh                    # 30 vérifications, sans rien perturber sur la session
/opt/macstatusd/macstatusd --check-rules # règle de l'économiseur, logique pure
./scripts/validate-live.sh               # validation guidée en passant par les vrais états
# Sonde de diagnostic : déclenche un vrai OFF (économiseur) à t≈4 s
swiftc -O -o /tmp/saver-probe diagnostics/saver-probe.swift && /tmp/saver-probe 60
```

`selftest.sh` simule l'économiseur d'écran avec un faux binaire nommé
`ScreenSaverEngine` (exactement ce que l'oracle « process » observe) et un
serveur HTTP local jouant Homebridge ; il vérifie aussi le retour honnête d'une
commande sans effet, l'authentification, les erreurs HTTP, les réessais de
webhook et la reprise du serveur quand le port est occupé.

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
`macstatusdV4.4.4.swift` reste à la racine pour référence ; la v5 ne le remplace
pas sur disque.

## Licence

MIT — voir [LICENSE](LICENSE).
