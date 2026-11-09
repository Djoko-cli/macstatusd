[![English](https://img.shields.io/badge/lang-English-lightgrey.svg)](README.md) [![Français](https://img.shields.io/badge/lang-Fran%C3%A7ais-F65801.svg)](README.fr.md)

# macstatusd 0.6

App macOS d'arrière-plan qui expose l'état ON/OFF du Mac à Home Assistant ou à
Homebridge (plugin
[http-webhooks](https://github.com/benzman81/homebridge-http-webhooks)), et
accepte les commandes ON/OFF qui en viennent. Il faut macOS 13 ou plus récent ;
aucune dépendance externe.

Les commentaires du code, les journaux et les sorties de diagnostic sont en
français.

```
Home Assistant / HomeKit ──► GET /wake | /sleep  (X-Auth-Token) ──► macstatusd ──► macOS
        ▲                    GET /state  ◄───────────────────────────┤
        └───────────── push webhook (state=true|false) ◄──────────────┘
```

## Sémantique de l'état

| Ce que le Mac montre réellement                          | État |
|----------------------------------------------------------|------|
| Bureau déverrouillé, dans une app                        | ON   |
| Écran de verrouillage visible (champ de mot de passe)    | ON   |
| Fenêtre de connexion (personne n'est connecté), écran allumé | ON |
| Économiseur d'écran en cours                             | OFF  |
| Écran éteint (veille de l'écran)                         | OFF  |
| Veille système                                           | OFF  |
| Aucun écran connecté                                     | OFF  |

Autrement dit : **ON = une interface utilisateur est visible et utilisable**,
OFF = rien à l'écran. L'inactivité ne rend pas le Mac OFF : une vidéo regardée
sans toucher au clavier reste ON.

## Ce qui rend l'état déterministe

Les prototypes 4.x déduisaient l'état en *lisant les messages de journal privés
de `loginwindow`* (`log stream --predicate 'process == "loginwindow"'`) et en y
cherchant des chaînes comme `screenLockUIIsHidden` ou `updatePlaceholderString`.
C'était la cause racine du problème : ces chaînes ne sont pas une API, elles
changent d'une version de macOS à l'autre, un message coupé entre deux lectures
de 4 Ko est perdu, et un drapeau resté à `true` fige l'état pour toujours.

Depuis la version 0.5, macstatusd ne lit plus aucun journal. Chaque fait vient
d'une API observable, avec une source de repli indépendante :

| Fait | Source principale | Repli |
|------|-------------------|-------|
| Veille système | IOKit `IORegisterForSystemPower` (événement) | `NSWorkspace.didWake` |
| Écran éteint | `CGDisplayIsAsleep` (écran principal) | tous les écrans en ligne endormis + `screensDidSleep/Wake` |
| Économiseur en cours | `SACScreenSaverIsRunning` (`login.framework`) | le process `ScreenSaverEngine` parmi ceux de l'utilisateur, ou un hôte d'économiseur apparu après `com.apple.screensaver.didstart` |
| Économiseur **seul à l'écran** | `IOHIDSystem.HIDIdleTime` comparé à son heure de démarrage | — (voir plus bas) |
| Session verrouillée | IORegistry `IOConsoleLocked` / `IOConsoleUsers` | `CGSessionCopyCurrentDictionary`, seulement si le registre ne répond pas |

### Détection de l'économiseur

`saver_detection` dans `/status` dit comment l'économiseur est détecté : `sac`
(`SACScreenSaverIsRunning`), ou `hôte` quand cette fonction manque (repli sur le
process hôte apparu après `didstart`). La preuve d'un économiseur actif est
`sac`, `process` ou `notification+hôte` ; une fois fini, elle devient
`écarté-par-activité` (clavier ou souris), `écarté-par-commande` (ON demandé par
HomeKit ou Home Assistant) ou `réaffiché` (de retour à l'écran), puis `none`. Une
notification seule ne fait jamais passer le Mac à OFF, et les fenêtres ne servent
plus de preuve (aucune autorisation d'enregistrement de l'écran n'est
nécessaire).

### Économiseur en cours ≠ économiseur à l'écran

C'est le piège principal, mesuré sur macOS 26.5 (`diagnostics/saver-probe.swift`) :
quand une frappe fait apparaître le champ de mot de passe, **l'économiseur
continue de tourner derrière le panneau**. Dans cet état :

- le process `ScreenSaverEngine` reste vivant ;
- `SACScreenSaverIsRunning` rend toujours `1` ;
- `com.apple.screensaver.didstop` n'est publiée qu'**au déverrouillage** ;
- `IsSecureEventInputEnabled` n'apprend rien d'utile : `loginwindow` peut garder
  la saisie sécurisée longtemps après un déverrouillage.

Le seul signal qui change est l'activité matérielle. Comme sous macOS **toute
frappe ou tout mouvement écarte l'économiseur**, la règle est :

> l'économiseur occupe l'écran s'il tourne **et** qu'aucune activité clavier /
> souris n'a eu lieu depuis son démarrage.

`HIDIdleTime` est lisible pendant que la session est verrouillée, ce qui rend la
règle utilisable là où elle sert. Le panneau compte pour ON jusqu'à 30 s après la
dernière frappe (`saver_redisplay_idle_seconds`) ; ensuite macOS retourne à
l'économiseur et l'état repasse à OFF. `saver_dismiss_on_input: false` désactive
la règle, et les tests unitaires (`swift test`, `ScreenSaverOracleTests`) la
vérifient sans vrai économiseur.

L'économiseur est démarré par `SACScreenSaverStartNow` et écarté par
`SACScreenSaverStopNow`, deux fonctions de `login.framework`, bibliothèque privée
du système (appelées par `dlopen` ; champs `saver_start` et `saver_dismissal` de
`/status`). Quand une fonction manque ou rend un code d'erreur, macstatusd
démarre l'économiseur par `open -a ScreenSaverEngine` en repli ; l'écartement n'a
pas de repli équivalent (`killall ScreenSaverEngine` ne marche plus sous
macOS 27), donc le ON est tenu 30 s au plus. Ces appels sont des API privées qui
peuvent changer avec macOS ; le journal dit quel moyen sert (INFO au démarrage,
WARN en cas de repli). Si le WARN « didstart non corroboré » paraît à chaque
économiseur, l'agent de session du système ne répond pas.

Propriétés qui en découlent :

- **Aucun état mémorisé qui puisse rester bloqué.** Les faits sont relus à chaque
  cycle ; les notifications accélèrent seulement les réactions, elles ne sont
  jamais l'unique source de vérité.
- **Anti-rebond explicite.** Un changement n'est publié qu'après une durée de
  stabilité (`settle_on_ms` / `settle_off_ms`), qui absorbe les états passagers
  (un écran noir d'une seconde pendant le verrouillage, par exemple).
- **Auto-réparation.** Un trou dans la boucle de scrutation (veille, gel,
  surcharge) est détecté et déclenche une resynchronisation complète.
- **OFF poussé *avant* la veille.** IOKit permet au daemon de retarder la veille
  le temps d'envoyer le webhook ; sinon HomeKit resterait à ON pendant toute la
  veille.
- **Commandes vérifiées par les faits.** Une commande sans effet observable est
  escaladée, puis abandonnée avec un avertissement, et l'état revient à la réalité
  au lieu de mentir.
- **Battement de cœur.** L'état est republié périodiquement
  (`heartbeat_seconds`) : un webhook perdu ou un récepteur redémarré ne peut pas
  laisser Home Assistant ou HomeKit désynchronisé.

Le cas « verrouillé sans champ visible » compte pour ON par défaut (l'écran de
verrouillage *est* une interface accessible). `require_auth_ui_when_locked: true`
inverse ce choix en exigeant que la saisie sécurisée soit active.

## Installation

macstatusd est une app qui vit dans `~/Applications` et lance un agent
d'arrière-plan enregistré auprès de macOS (`SMAppService`). Rien ne demande
`sudo`, et les scripts refusent de tourner en root.

### Depuis l'archive publiée

1. Télécharger `macstatusd-X.Y.Z.zip` et `SHA256SUMS` sur la page de la version,
   vérifier la somme (`shasum -a 256 -c SHA256SUMS`) et décompresser.
2. Déplacer `macstatusd.app` dans `~/Applications` (ou `/Applications` ; ailleurs,
   l'état est `not-found`).
3. Créer la configuration (avant que l'agent démarre, car elle n'est lue qu'au
   lancement). L'archive ne contient ni `install.sh` ni `config.example.json` :
   coller ce bloc dans un Terminal. Il n'affiche jamais le jeton, et il ne fait
   rien si le fichier existe déjà (dans ce cas, mettre le fichier existant de côté
   avec `mv` et relancer le bloc, ou garder l'`auth_token` qu'il contient) :

   ```bash
   D="$HOME/Library/Application Support/macstatusd"
   F="$D/config.json"
   mkdir -p "$D"; chmod 700 "$D"
   if [ -e "$F" ]; then echo "config.json existe déjà : le mettre de côté (mv) et relancer ce bloc, ou garder son auth_token"; else
     ( umask 077; : > "$F"; chmod 600 "$F"
       printf '{\n  "enabled": false,\n  "webhook_targets": [],\n  "auth_token": "%s"\n}\n' "$(openssl rand -hex 32)" > "$F" )
     echo "droits : $(stat -f %Lp "$F") (attendu : 600)"
   fi
   ```

   Le fichier contient un `auth_token` de 64 caractères hexadécimaux. Pour donner
   le jeton à Home Assistant, ouvrir le fichier dans un éditeur et copier la
   valeur de là ; ne pas l'imprimer dans un terminal partagé.
4. Double-cliquer sur l'app, ou l'enregistrer depuis un terminal :

   ```bash
   ~/Applications/macstatusd.app/Contents/MacOS/macstatusd --register
   ```

   L'agent est enregistré et son état s'affiche. Un double-clic fait la même
   chose, montre une alerte fidèle à l'état relu ensuite (« macstatusd tourne en
   arrière-plan. Réglages : Général > Ouverture et extensions. », ou une demande
   d'autorisation, ou « macstatusd n'a pas pu s'enregistrer : ... » avec la
   raison) puis quitte. Tant que l'agent tourne, un double-clic sur l'app n'ouvre
   rien.
5. La première fois, macOS demande d'autoriser l'app dans **Réglages Système >
   Général > Ouverture et extensions**. Sans cela, l'état reste
   `requires-approval`.
6. Éditer la configuration (`enabled`, `webhook_targets` ; les autres clés sont
   dans [Configuration](#configuration)), puis relancer l'agent pour qu'il la
   lise : `launchctl kickstart -k gui/$(id -u)/com.djoko.macstatusd`.

La version publiée est signée par un Developer ID et notariée (voir [Signature et
notarisation](#signature-et-notarisation)). Sans fichier de configuration, l'app
écoute sur `127.0.0.1` seulement et ne publie rien, et sans `auth_token` aucune
autre machine ne peut la commander.

### Depuis les sources

```bash
./scripts/install.sh
```

Le script compile en release, assemble l'app (`outils/assembler-app.sh`), la copie
dans `~/Applications`, enregistre l'agent et contrôle `/health`. Options :

| Option | Effet |
|--------|-------|
| `--app <chemin.app>` | installe cette app au lieu d'en compiler une |
| `--ancien-prefixe <dossier>` | dossier d'une installation 0.5 à migrer (défaut `/opt/macstatusd`) |
| `--anciens-journaux <dossier>` | dossier des journaux de l'ancien agent, vidé à la Corbeille (défaut `~/Library/Logs/macstatusd`) ; sous-dossier direct de `~/Library/Logs/` obligatoire |
| `--preparer-jeton` | s'arrête après la config et le jeton : ni copie, ni enregistrement. Sans `--ancien-prefixe`, lit `/opt/macstatusd/config.json` (le défaut) quand ce fichier existe |
| `--sans-verification` | ne contrôle pas `/health` à la fin |

Étapes, dans l'ordre :

1. **Configuration** : `~/Library/Application Support/macstatusd/config.json`
   (droits 600) est gardée si elle existe, migrée depuis l'ancienne installation,
   ou prise de `config.example.json` (`enabled: false`, `webhook_targets: []`).
2. **Jeton** : un jeton de 64 caractères hexadécimaux est généré s'il n'y en a
   pas. Le script affiche « jeton prêt dans <config> (64 caractères) » ou « jeton
   déjà présent dans <config> », jamais le jeton lui-même. `--preparer-jeton`
   s'arrête ici, pour pouvoir confier le jeton à Home Assistant avant
   l'installation.
3. **Redémarrage prévu** : un marqueur `restart-pending` est posé avant que l'app
   soit remplacée, pour que l'ancien process ne publie pas OFF en s'arrêtant. Si
   l'agent est déjà chargé, le script dit « Agent déjà chargé : marqueur
   restart-pending posé ». Le marqueur est retiré si le script échoue ensuite avant
   que l'agent ait été relancé.
4. **Copie et enregistrement** : l'app va dans `~/Applications`, puis `--register`
   est lancé.
5. **Ancien agent** : retiré, voir plus bas. Quand un ancien agent a été retiré et
   que le nouvel agent est chargé, le script relance le nouvel agent en dernier :
   son état est le dernier publié et il prend aussitôt le port libéré.
6. **Contrôle** : `GET /health`, sur l'hôte tiré de `bind_address` (`""`, `::` et
   `0.0.0.0` donnent `127.0.0.1`) et sur le port configuré, 20 essais espacés de
   0,5 s. En cas d'échec, le script affiche « macstatusd ne répond pas sur <url> »
   et sort avec le code 1.

Codes de sortie : 0 réussi (y compris quand une autorisation est attendue), 1 échec
ou refus, 2 usage.

Si le script affiche « À autoriser : Réglages Système > Général > Ouverture et
extensions » (code d'enregistrement 3), il s'arrête avec le code 0 **avant** de
retirer l'ancien agent et avant le contrôle : autoriser l'app dans les Réglages,
puis relancer `install.sh` aussitôt (voir [Mise à jour depuis la
0.5](#mise-à-jour-depuis-la-05)). Juste après une installation, le contrôle `/health`
peut aussi échouer si l'ancien agent tenait encore le port : relancer `install.sh`
suffit.

### L'app dans les Réglages

macstatusd apparaît dans **Réglages Système > Général > Ouverture et extensions**,
sous « Autoriser en arrière-plan », au nom de l'app. Le désactiver là arrête
l'agent. Son état se lit à tout moment :

```bash
~/Applications/macstatusd.app/Contents/MacOS/macstatusd --status-service
```

| État (`service` dans `/status`) | Message | Code de sortie |
|---------------------------------|---------|----------------|
| `enabled` | activé | 0 |
| `requires-approval` | à autoriser : Réglages Système > Général > Ouverture et extensions | 3 |
| `not-registered` | non enregistré : lancer macstatusd --register | 4 |
| `not-found` | introuvable : l'app doit être dans ~/Applications ou /Applications | 5 |
| `unknown` | inconnu (code N) | 1 |

macOS peut demander une fois l'accès au **réseau local** (et peut-être l'autorisation
du pare-feu) la première fois que l'app contacte une autre machine : l'identité de
signature a changé avec la 0.6, donc les anciennes réponses ne valent plus. Si
aucune invite n'apparaît et que le journal confirme le webhook, il n'y a rien à faire.

### Mise à jour depuis la 0.5

`install.sh` migre une installation 0.5, en lecture seule sur l'ancien dossier :

- l'ancien `config.json` est copié, et `webhook_base_url` est converti en
  `webhook_targets` (une config 0.5 sans jeton en reçoit un) ;
- l'ancien agent est retrouvé par son contenu (le plist de
  `~/Library/LaunchAgents` dont `ProgramArguments[0]` est l'ancien binaire), jamais
  par son libellé, puis retiré par `launchctl bootout` ; son plist et ses anciens
  journaux vont à la Corbeille. Le script affiche « ancien agent retiré (libellé
  de N caractères) ». Le gabarit 0.5 de ce dépôt porte le même libellé que l'agent
  0.6 (`com.djoko.macstatusd`) : dans ce cas, l'ancien agent est arrêté **avant**
  l'enregistrement de la 0.6 (« Ancienne version arrêtée avant l'enregistrement
  (même libellé) »), et seul son plist va ensuite à la Corbeille (jamais de
  `bootout` par libellé à ce moment-là, qui désignerait le nouvel agent). Si
  l'enregistrement échoue, l'ancien agent est relancé et le script sort avec le
  code 1 ;
- si le script s'arrête sur la demande d'autorisation (code d'enregistrement 3), les
  anciens journaux sont déjà à la Corbeille. Un ancien agent d'un autre libellé
  continue de tourner jusqu'à la relance du script ; celui qui porte
  `com.djoko.macstatusd` est déjà arrêté, et la 0.6 démarre à l'autorisation. Dans
  les deux cas, relancer `install.sh` aussitôt après avoir autorisé l'app : le
  vieux plist n'est retiré qu'à cette seconde passe ;
- les journaux de la 0.5 contiennent l'URL du webhook : si l'agent 0.5 a été
  retiré à la main avant, ils restent où ils sont, donc les mettre à la Corbeille
  soi-même ;
- le script **affiche** la commande qui supprime l'ancien dossier
  (`sudo rm -rf <ancien préfixe>`), et ne la lance jamais.

« Corbeille » veut dire ici un `mv` vers `~/.Trash` : le Finder n'a pas de
« Remettre » pour ces fichiers.

## Endpoints

| Route | Effet |
|-------|-------|
| `GET /state` | `1` (ON) ou `0` (OFF), l'état publié, identique au dernier webhook |
| `GET /status` | diagnostic JSON : faits bruts, preuves, commande en attente, état du webhook |
| `GET /health` | `OK` |
| `GET /sleep` (`/off`) | commande OFF |
| `GET /wake` (`/on`) | commande ON |
| `GET /resync` | republie l'état courant vers les cibles du webhook |

Réponses : `200` (`OK` pour une commande), `401` jeton absent ou faux, `403` `Host`
ou origine refusés, `404` chemin inconnu, `405` mauvaise méthode, `429` rafale ou
trop d'échecs, `503` configuration invalide. Les paramètres de requête inconnus
(`?action=WAKE`) sont ignorés.

### Contrôle d'accès

`/health` est toujours servi, sans aucun contrôle. Toute autre route passe ces
contrôles, dans cet ordre (le premier refus répond) :

1. **En-tête `Host`.** Acceptés : une adresse IPv4 ou IPv6 littérale, `localhost`,
   les noms `.local` du Mac lui-même (nom Bonjour et nom d'hôte) et les noms
   listés dans `allowed_hosts`. Tout autre nom reçoit `403` (protection contre le
   DNS rebinding). Une requête sans `Host` (HTTP/1.0) passe ; un `Host` vide ou
   mal formé est refusé.
2. **Requêtes de navigateur.** Un en-tête `Origin`, ou un `Sec-Fetch-Site` autre
   que `none`, reçoit `403` : une page web ouverte sur le Mac ne peut pas piloter
   le daemon, avec ou sans jeton.
3. **Méthode.** Les commandes n'acceptent que `GET` ; `/state` et `/status`
   acceptent `GET` et `HEAD`. Tout le reste reçoit `405`.
4. **Jeton.** Voir ci-dessous.

### Jeton

Le jeton se passe dans l'en-tête `X-Auth-Token` ou sous la forme `Authorization:
Bearer <jeton>`. `?token=` dans l'URL est refusé sauf si `allow_query_token` vaut
`true` (un jeton dans une URL finit dans les journaux et l'historique).

- Avec `auth_token` défini : une commande exige le bon jeton (`401` sinon).
  `/state` et `/status` sont libres depuis l'interface de bouclage et exigent le
  jeton depuis toute autre machine.
- Sans `auth_token` : seuls les clients de la boucle locale sont servis ; tout
  autre client reçoit `403`, pour les commandes comme pour les lectures.

`install.sh` génère le jeton (32 octets aléatoires en hexadécimal, soit 64
caractères) dans le fichier de configuration, en droits 600, et ne l'affiche
jamais. Pour le lire soi-même : ouvrir
`~/Library/Application Support/macstatusd/config.json`. Le jeton n'est jamais
écrit dans le journal ni montré dans `/status`.

```bash
curl -H "X-Auth-Token: <jeton>" http://192.0.2.10:9090/wake
curl -H "Authorization: Bearer <jeton>" http://192.0.2.10:9090/state
```

Une rafale de requêtes ou trop d'essais ratés venant d'un même pair reçoit `429`,
et le nombre de connexions simultanées est plafonné (32 en tout, 8 par pair).

## Home Assistant

### Commandes

Home Assistant pilote le Mac par `GET /wake` et `GET /sleep`, le jeton dans un
en-tête. Exemple (toutes les valeurs sont des exemples) :

```yaml
rest_command:
  mac_wake:
    url: "http://192.0.2.10:9090/wake"
    headers:
      X-Auth-Token: !secret mac_token
  mac_sleep:
    url: "http://192.0.2.10:9090/sleep"
    headers:
      X-Auth-Token: !secret mac_token
```

Mettre une adresse IPv4 littérale dans l'URL, ou un nom que `allowed_hosts` accepte.

### Push de l'état (webhook)

macstatusd pousse l'état à chaque changement, puis toutes les `heartbeat_seconds`
(60 par défaut), vers chaque cible de `webhook_targets` :

- `GET` : `<url>?accessoryId=<accessory_id>&state=true|false` ;
- `POST` : l'URL telle quelle, corps JSON `{"accessoryId": "<accessory_id>", "state": true}`.

Côté Home Assistant, un déclencheur webhook lit `state` et met à jour un
`input_boolean` qui sert d'état à un interrupteur. Exemple :

```yaml
input_boolean:
  mac_actif:
    name: "Mac"

automation:
  - alias: "Mac state from macstatusd"
    trigger:
      - platform: webhook
        webhook_id: "exemple-identifiant-webhook"
        allowed_methods: [GET, POST]
        local_only: true
    action:
      - service: "input_boolean.turn_{{ 'on' if trigger.query.state == 'true' else 'off' }}"
        target:
          entity_id: input_boolean.mac_actif
```

et dans `config.json` :

```json
{
  "enabled": true,
  "webhook_targets": [
    { "url": "http://192.0.2.20:8123/api/webhook/exemple-identifiant-webhook", "method": "GET" }
  ]
}
```

(Pour une cible `POST`, lire `trigger.json.state` à la place.) L'URL d'un webhook
peut porter un secret : elle n'est jamais écrite en clair dans le journal, et
`/status` la montre masquée.

## Homebridge

Plugin `homebridge-http-webhooks`, accessoire de type interrupteur. Les commandes
demandent le jeton dans les champs `on_headers` et `off_headers` (une chaîne
JSON) :

```json
{
  "platform": "HttpWebHooks",
  "webhook_port": "51828",
  "switches": [
    {
      "id": "mac",
      "name": "Mac",
      "on_url": "http://192.0.2.10:9090/wake",
      "on_method": "GET",
      "on_headers": "{\"X-Auth-Token\": \"<jeton>\"}",
      "off_url": "http://192.0.2.10:9090/sleep",
      "off_method": "GET",
      "off_headers": "{\"X-Auth-Token\": \"<jeton>\"}"
    }
  ]
}
```

Le push va au `webhook_port` du plugin :

```json
{
  "enabled": true,
  "accessory_id": "mac",
  "webhook_targets": [ { "url": "http://192.0.2.30:51828/", "method": "GET" } ]
}
```

`accessory_id` doit correspondre à l'`id` de l'accessoire. `webhook_base_url` (une
seule cible GET) marche encore pour une configuration existante, mais
`webhook_targets` l'emporte quand les deux sont présents.

## Configuration

La configuration est lue au lancement ; après une modification, relance l'agent :
`launchctl kickstart -k gui/$(id -u)/com.djoko.macstatusd` (Home Assistant voit un
OFF bref pendant la relance).

`~/Library/Application Support/macstatusd/config.json` (`--config <chemin>` pour
un autre fichier ; `MACSTATUSD_SUPPORT_DIR` remplace le dossier de support).
Toutes les clés sont facultatives ; une clé absente ou invalide retrouve son
défaut sans empêcher le démarrage. Un fichier illisible ou qui n'est pas du JSON
valide met le daemon en mode dégradé fermé : boucle locale seulement, aucun push,
`503` sur les commandes. Pas de fichier du tout : les défauts, toujours avec une
écoute sur `127.0.0.1` seulement.

| Clé | Défaut | Rôle |
|-----|--------|------|
| `enabled` | `false` | active les pushs webhook |
| `webhook_targets` | `[]` | jusqu'à 8 cibles `{url, method?, headers?}` (voir plus bas) |
| `webhook_base_url` | `""` | ancienne cible GET unique, p. ex. `http://192.0.2.30:51828` |
| `accessory_id` | `"mac"` | `accessoryId` envoyé avec chaque push |
| `port` | `9090` | port HTTP |
| `bind_address` | `""` | `""` ou `::` = toutes les interfaces, IPv4 et IPv6, `0.0.0.0` = toutes les interfaces, IPv4 seulement, `127.0.0.1` = boucle locale ; sinon une adresse IP littérale (valeur invalide : avertissement et boucle locale) |
| `auth_token` | `""` | jeton des commandes et des lectures venues d'une autre machine ; vide = seuls les clients de la boucle locale sont servis |
| `allow_query_token` | `false` | accepte aussi le jeton sous la forme `?token=…` dans l'URL |
| `allowed_hosts` | `[]` | noms supplémentaires acceptés dans l'en-tête `Host` (liste de chaînes) |
| `off_action` | `"screensaver"` | `screensaver`, `display_sleep` ou `system_sleep` |
| `off_escalate_to_display_sleep` | `true` | si l'action OFF n'a aucun effet observé |
| `stop_screensaver_on_wake` | `true` | écarte l'économiseur sur ON (arrêt natif) |
| `wake_hold_seconds` | `0` | secondes pendant lesquelles l'écran ne s'éteint pas par inactivité après un ON confirmé sur une session verrouillée (0 à 600 ; ignoré si `wake_command` est défini) |
| `command_confirm_timeout_ms` | `12000` | délai avant d'abandonner une commande |
| `command_escalate_after_ms` | `2500` | délai avant d'escalader une commande sans effet |
| `saver_dismiss_on_input` | `true` | activité après le démarrage de l'économiseur → ON |
| `saver_dismiss_grace_ms` | `1500` | marge ignorée juste après le démarrage |
| `saver_redisplay_idle_seconds` | `30` | inactivité au bout de laquelle l'économiseur est tenu pour revenu à l'écran |
| `poll_interval_ms` | `500` | fréquence de relecture des faits (100 à 5000) |
| `settle_on_ms` | `300` | stabilité exigée avant de publier ON |
| `settle_off_ms` | `800` | stabilité exigée avant de publier OFF |
| `heartbeat_seconds` | `60` | republication périodique (`0` = désactivée) |
| `publish_off_on_exit` | `true` | publie OFF sur SIGTERM/SIGINT avant de quitter, sauf redémarrage prévu (marqueur `restart-pending` dans le dossier de support, valable 10 min) ou mode dégradé |
| `require_auth_ui_when_locked` | `false` | verrouillé sans champ visible → OFF |
| `webhook_timeout_ms` | `4000` | délai d'un envoi |
| `webhook_retries` | `3` | essais de plus après un envoi raté (0 à 10) |
| `log_level` | `"info"` | `error`, `warn`, `info`, `debug` |
| `log_file` | `""` | `""` = `~/Library/Logs/macstatusd/macstatusd.log` |
| `off_command` | `[]` | remplace l'action OFF intégrée (argv, ou chaîne passée à `sh -c`) |
| `wake_command` | `[]` | remplace l'action ON intégrée (mêmes formes) |

`off_command` et `wake_command` : un premier élément qui n'est pas un chemin absolu
vers un fichier exécutable est ignoré, avec le WARN « off_command ignoré :
<chemin> n'est pas un chemin absolu exécutable ». Chaque commande lancée est
journalisée : INFO « <libellé> terminé (code 0) », WARN quand le code diffère. Le
nom de dossier `macstatusd` vient de la clé `MacstatusdSupportName` de l'`Info.plist`
de l'app.

### Cibles du webhook

Chaque entrée de `webhook_targets` est un objet :

| Champ | Rôle |
|-------|------|
| `url` | adresse `http://` ou `https://` (obligatoire) |
| `method` | `GET` (défaut) ou `POST` |
| `headers` | objet `{nom: valeur}` envoyé à chaque envoi (pour une clé ou un jeton) |

Une cible invalide est écartée, avec un avertissement qui la nomme
(« webhook_targets : cible N … »). Les valeurs des en-têtes ne sont jamais
journalisées ni montrées dans `/status`.

### Choisir l'action OFF

`off_action` décide de ce que fait OFF :

- `screensaver` (défaut) : démarre l'économiseur. Le Mac reste éveillé et
  joignable, donc **ON peut vraiment le rallumer**. C'est ce que doit faire le
  « OFF » d'un interrupteur de maison connectée.
- `display_sleep` : éteint l'écran (`pmset displaysleepnow`). Même propriété.
- `system_sleep` : vraie veille (`pmset sleepnow`). Attention : pendant la veille,
  le daemon est gelé et `/wake` n'est jamais reçu ; le contrôleur a besoin du
  Wake-on-LAN pour rallumer le Mac.

Si la session est déjà verrouillée, `screensaver` éteint l'écran à la place :
mesuré sous macOS 26, `open -a ScreenSaverEngine` n'a aucun effet sur une session
verrouillée. Un OFF reçu alors que le Mac est déjà OFF ne déclenche aucune action.
Dans les trois cas, l'état publié devient OFF, et la commande n'est tenue pour
réussie qu'une fois les faits confirmés.

## Diagnostic

- `--once` : état et faits en JSON, puis quitte.
- `--watch` : tableau continu des faits.
- `--version` : version et provenance (git, date).
- `curl -s localhost:9090/status` : vue complète de l'instance en cours.

```bash
~/Applications/macstatusd.app/Contents/MacOS/macstatusd --once
~/Applications/macstatusd.app/Contents/MacOS/macstatusd --watch
~/Applications/macstatusd.app/Contents/MacOS/macstatusd --version
curl -s localhost:9090/status
tail -f ~/Library/Logs/macstatusd/macstatusd.log
```

Le journal commence par `binaire : sha256 <64 hex>` (empreinte du binaire qui
tourne) et, avec `--debug`, une ligne « raison : A → B » à chaque changement de
raison.

### Options de la ligne de commande

| Option | Effet |
|--------|-------|
| `--config <chemin>` | fichier de configuration JSON |
| `--port <n>` | remplace le port HTTP (1 à 65535) |
| `--debug` | journalisation détaillée |
| `--foreground`, `-f` | écrit aussi le journal sur la sortie standard |
| `--once` | affiche l'état et les faits en JSON, puis quitte |
| `--watch` | affiche l'état en continu |
| `--no-webhook` | n'envoie aucun webhook (tests) |
| `--register` | enregistre l'agent auprès de macOS et affiche son état |
| `--unregister` | retire l'agent et affiche son état |
| `--status-service` | affiche l'état de l'agent (lecture seule), codes de sortie dans le tableau ci-dessus |
| `--agent` | lancement par launchd (démarre le daemon) |
| `--version`, `-v` | `macstatusd 0.6.0 (git …, <date>)`, ou « (compilation inconnue) » |
| `--help`, `-h` | usage, avec le chemin de configuration résolu |

### Champs de `/status`

| Champ | Contenu |
|-------|---------|
| `version` | version du binaire en cours |
| `state` | état publié, `"1"` ou `"0"` |
| `reason` | pourquoi l'état publié est ce qu'il est (liste plus bas) |
| `facts` | faits bruts : `system_asleep`, `display_asleep`, `display_evidence`, `displays`, `screensaver_active`, `screensaver_evidence`, `screensaver_running`, `hid_idle_seconds` (−1 si non lu), `session_locked`, `lock_evidence`, `console_user_logged_in`, `secure_input_active`… |
| `facts_verdict` | état que donnent les faits seuls |
| `facts_reason` | raison des faits seuls |
| `uptime_seconds` | secondes depuis le démarrage |
| `transitions` | nombre de changements d'état |
| `poll_interval_ms` | période de scrutation |
| `off_action` | action OFF configurée |
| `webhook` | diagnostic des pushs : `enabled`, `detail`, `confirmed`, `desired`, `suspended`, `failures_since_success`, `last_attempt`, `last_success`, et une entrée par cible dans `targets` (URL masquée, `method`, `phase`, réessais) |
| `session_context` | `aqua` (session graphique) ou `headless` |
| `publishing_allowed` | si les pushs sont autorisés |
| `publishing_reason` | pourquoi, ou pourquoi pas |
| `saver_detection` | `sac` ou `hôte` (voir plus haut) |
| `saver_dismissal` | comment l'économiseur est écarté |
| `saver_start` | comment il est démarré : `SACScreenSaverStartNow` ou `open -a ScreenSaverEngine` |
| `slow_calls` | lectures du système qui ont duré au moins 1 s depuis le démarrage : `{"<nom>": {"count": n, "max_seconds": x}}`, `{}` s'il n'y en a pas |
| `build` | `{"git": …, "built_at": …}`, null si inconnu |
| `service` | état d'enregistrement de l'agent (tableau plus haut) |
| `main_display` | identifiant de l'écran principal, ou `none` |
| `display_list` | les écrans : `id`, `main`, `asleep`, `placeholder` |
| `last_transition` | heure du dernier changement d'état (s'il y en a eu un) |
| `pending_command` | commande en cours de confirmation : `target`, `source`, `age_seconds`, `escalated` (seulement tant qu'il y en a une) |
| `shutting_down` | `true` pendant l'arrêt du daemon (seulement alors) |

`slow_calls` mesure le temps éveillé, veille exclue ; un gel du processus pendant
que le Mac est éveillé compte. Les noms sont `session`, `ecrans`,
`saisie_securisee`, `inactivite_hid` et `economiseur`. Un WARN « appel lent :
<nom> <durée> s (seuil 1.0 s) » est écrit au plus une fois par nom et par minute.

`reason` vaut l'une de ces valeurs : `desktop-ui`, `lock-screen-ui`,
`login-window-ui`, `display-asleep`, `system-asleep`, `no-display`,
`displays-reconfiguring` (aucun écran physique depuis moins de 5 s : l'état publié
tient), `locked-without-auth-ui`, `screensaver:<preuve>` (par exemple
`screensaver:sac`), `command:on`, `command:off/<action>`, `command:off/override`
(avec `off_command`). La ligne de journal d'une transition vers OFF causée par le
retour de l'économiseur finit par « — économiseur réaffiché — faits: … ».

## Désinstallation

```bash
./scripts/uninstall.sh [--app <chemin.app>] [--tout]
```

Le script retire l'agent (`--unregister`) et met l'app à la Corbeille (défaut
`~/Applications/macstatusd.app` ; l'app doit être sous `~/Applications`). La
configuration (jeton compris) et les journaux sont gardés ; `--tout` les met aussi
à la Corbeille. Rien n'est supprimé pour de bon : la « Corbeille » est un `mv` vers
`~/.Trash` (pas de « Remettre » dans le Finder). Le script refuse de tourner en
root et refuse tout chemin hors de `~/Applications` et de `~/Library`. Codes de
sortie : 0 réussi, 1 échec ou refus, 2 usage.

Depuis l'archive publiée, il n'y a pas de script : retirer l'agent, puis mettre
l'app à la Corbeille. L'app est dans `~/Applications` ou dans `/Applications`, selon
l'endroit où tu l'as mise :

```bash
~/Applications/macstatusd.app/Contents/MacOS/macstatusd --unregister
```

ou, si elle est dans `/Applications` :

```bash
/Applications/macstatusd.app/Contents/MacOS/macstatusd --unregister
```

`uninstall.sh` est dans le dépôt, pas dans l'archive, et il n'accepte qu'une app
sous `~/Applications`.

Les Réglages Système peuvent garder l'app dans « Autoriser en arrière-plan », inactive,
après la désinstallation : sous macOS 27, l'entrée y était encore des heures plus
tard. L'agent est bien parti : `launchctl list | grep macstatusd` ne le montre plus.

## Développement

### Tests

- `swift test` : tests unitaires de MacStatusCore (règles, moteur, webhook, HTTP, documentation).
- `./scripts/selftest.sh` : lance swift test, puis des contrôles sur des instances d'essai isolées.
- `./scripts/validate-live.sh` : validation guidée à travers les vrais états.

```bash
swift test
./scripts/selftest.sh
./scripts/validate-live.sh
```

`DocumentationTests` garde ces README alignés sur le code : chaque clé de
`Config.knownKeys` et chaque champ de premier niveau de `/status` doit figurer
entre accents graves dans les deux fichiers, et les deux fichiers doivent avoir la
même suite de titres.

`selftest.sh` lance d'abord `swift test`, puis démarre des instances d'essai
isolées du vrai daemon : elles écoutent sur 127.0.0.1 aux ports 19000-19999, leurs
commandes sont inertes (`/usr/bin/true`) et les webhooks vont à un faux récepteur
local. Par défaut il n'est pas intrusif et **ne démarre aucun faux économiseur** :
un faux process `ScreenSaverEngine` est visible de tout le Mac, donc un vrai
daemon en marche le verrait aussi, passerait à OFF et le pousserait à Home
Assistant. Les sections qui en ont besoin sont marquées SKIPPED. Variables
d'environnement :

- `SELFTEST_FAUX_ECONOMISEUR=1` : joue le faux économiseur. Seulement avec le vrai
  daemon **arrêté** : le script refuse si quelque chose répond sur le port 9090.
- `SELFTEST_IGNORER_VERROU=1` : une session verrouillée n'écarte plus les sections
  qui exigent un écran allumé (par exemple depuis une session distante).
- `SELFTEST_FORCER_ECRAN_ETEINT=1` : force la branche « écran éteint » sans rien
  éteindre.
- `SWIFT_SCRATCH=<dossier>` : dossier de compilation Swift, gardé après
  l'exécution. Il doit rester hors de `~/Documents` : la signature du `.xctest`
  échoue sous iCloud.

`validate-live.sh` demande d'accomplir les vraies actions (verrouiller, lancer
l'économiseur, éteindre l'écran, mettre en veille) et vérifie ce que macstatusd a
rapporté.

### Construire l'app

```bash
bash outils/assembler-app.sh [--binaire <chemin>] [--identifiant <id>] [--nom-support <nom>] \
                             [--sortie <dossier>] [--icone <icns>] [--signer <identité>|-]
```

Il construit `macstatusd.app` (`Contents/MacOS/macstatusd`, `Info.plist`,
`build-info.json`, l'icône, et le plist de l'agent dans
`Contents/Library/LaunchAgents/`), signée ad hoc par défaut, dans
`~/Library/Caches/macstatusd-build/app` (hors de `~/Documents`, où iCloud ajoute
des attributs que `codesign` refuse). La dernière ligne affichée est le chemin de
l'app. Il refuse de s'exécuter sans
l'icône (code de sortie 2). Un identifiant `com.djoko.macstatusd.<suffixe>` donne
une app nommée `macstatusd-<suffixe>.app`, ce qui permet aux builds d'essai de
vivre à côté de la vraie.

## Limites connues

- **Veille système** : rien ne tourne pendant la veille. `/state` est injoignable
  et `/wake` ne peut pas réveiller le Mac ; il faut le Wake-on-LAN. C'est pourquoi
  `off_action` vaut `screensaver` par défaut. Une application qui laisse expirer
  son avis de veille de 30 s retarde d'autant l'entrée en veille.
- **Avant la connexion** : l'agent appartient à la session graphique d'un
  utilisateur, il ne tourne donc pas avant qu'on se connecte (après un
  redémarrage, `/state` est injoignable jusque-là). Il ne doit pas tourner en root.
- **Plusieurs utilisateurs** : deux sessions ouvertes font deux instances pour un
  seul port ; la seconde réessaie en boucle sans planter, mais l'état publié est
  celui de l'instance qui tient le port.
- **Écran externe éteint physiquement** : macOS le tient pour allumé, donc l'état
  reste ON. Un Mac sans écran physique utilisé à distance (partage d'écran) passe
  à OFF `no-display` après 5 s.
- **Économiseurs hébergés par `legacyScreenSaver`** : détectés par le process
  hôte, ce qui exige la session graphique.
- **Fonctions privées de `login.framework`** : la détection et l'écartement
  reposent sur `SACScreenSaverIsRunning`, `SACScreenSaverStartNow` et
  `SACScreenSaverStopNow`. Elles rendent `0` (ou `22` pour l'arrêt) hors session
  et quand l'agent de session ne répond pas ; les replis ci-dessus ne couvrent
  qu'une fonction absente. L'arrêt natif agit sur l'écran : il ouvre un panneau
  par-dessus l'économiseur, qui revient 30 s plus tard, et seulement sur l'écran
  principal.
- **Réglage mixte** : quand l'arrêt natif n'a aucun effet visible, un faux ON
  de 30 s au plus est possible.
- **Après `/wake` écrans éteints** : macOS montre l'écran verrouillé, puis
  rééteint les écrans au bout de 30 s, sans relancer l'économiseur.
- **Invite qui clignote** : l'invite « Touch ID ou mot de passe » clignote pendant
  les 30 s d'un panneau ouvert par l'arrêt natif (rendu de `loginwindow`, sans
  activité HID ; sans effet sur l'état).
- **Échap sur l'écran de verrouillage** : écarter la superposition
  d'authentification avec Échap ne ramène pas l'état à OFF tout de suite ; il
  repasse à OFF après `saver_redisplay_idle_seconds` (30 s) d'inactivité, ou dès
  que l'écran s'endort.
- **Double-clic** : tant que l'agent tourne, un double-clic sur l'app n'ouvre rien
  (macOS réutilise l'instance en cours).
- **Apple silicon seulement** : le binaire est arm64 (Apple silicon), il n'y a pas de build Intel.
- **Corbeille des scripts** : c'est un `mv` vers `~/.Trash` ; le Finder n'a pas de
  « Remettre » pour ces fichiers.

## Signature et notarisation

Une version publiée est signée par un certificat Developer ID Application et
notariée par Apple (profil enregistré par `notarytool store-credentials`). Elle
est produite par :

```bash
bash outils/publier.sh [--repetition] X.Y.Z
```

Le script refuse un clone superficiel, et un arbre qui a des modifications suivies
ou dont `macstatusdVersion` n'est pas `X.Y.Z` (une répétition accepte `X.Y.Z` ou
`X.Y.Z-dev`, et n'importe quel arbre). Il lance d'abord les tests, retire les
symboles de débogage de l'exécutable (`strip -S`, ils portent des chemins
personnels), signe l'app (runtime renforcé), vérifie que l'archive ne porte aucune
donnée personnelle, une première fois avant de l'envoyer à Apple et une seconde
sur l'archive finale, notarise, agrafe, et écrit `build/publication/X.Y.Z/` (`macstatusd-X.Y.Z.zip`,
`SHA256SUMS`). `--repetition` fait la même chose avec une identité de répétition
(`com.djoko.macstatusd.repetition`) dans `build/repetition/X.Y.Z/`.
Environnement : `IDENTITE_SIGNATURE` (défaut `Developer ID Application`),
`NOTARISER` (défaut `1`), `PROFIL_NOTARISATION` (défaut `djoko-notarisation`).
Codes de sortie : 0 réussi, 1 refus ou échec, 2 usage. `build/` est ignoré par
git. Une app compilée depuis les sources n'est signée qu'ad hoc : macOS la traite
comme une autre app que la version publiée.

## Historique

`Versionning/` et `backtest+debug/` contiennent les versions 1 à 4.4.4 et les
outils de capture qui ont servi à repérer les signaux exploitables.
`macstatusdV4.4.4.swift` reste à la racine pour mémoire. Notes de version :
[NOTES-VERSIONS.md](NOTES-VERSIONS.md).

## Licence

MIT — voir [LICENSE](LICENSE).
