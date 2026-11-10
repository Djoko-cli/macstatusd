# Notes de version / Release notes

## 0.6.0

**English**

Released on 10 November 2026.

What changes when you update from 0.5:

- **The token is required.** Commands need `X-Auth-Token` (or `Authorization: Bearer`), and reads from another machine too. Without `auth_token`, only the Mac itself is served. `install.sh` generates a token of 64 hexadecimal characters into the configuration (mode 600) and never prints it. The Home Assistant `rest_command` entries must send it.
- **macstatusd is now an app.** It lives in `~/Applications` and appears in System Settings > General > Login Items & Extensions, where it must be allowed once. Register it with a double-click or `macstatusd --register`; `--unregister` and `--status-service` complete the set. No `sudo` anywhere.
- **macOS asks again** for access to the local network and for the firewall, once, because the signature identity changed.
- **The old agent is found by its content and replaced.** The old agent of `/opt/macstatusd` is removed with `launchctl bootout`, and its plist and old logs go to the Trash; if its label is already `com.djoko.macstatusd`, it is stopped before the 0.6 is registered. The configuration is migrated (`webhook_base_url` becomes `webhook_targets`). The command that removes `/opt/macstatusd` is printed, never run. The 0.5 logs contain the webhook URL: if you removed the old agent by hand, put them in the Trash yourself.
- **New locations.** Configuration: `~/Library/Application Support/macstatusd/config.json`. Log: `~/Library/Logs/macstatusd/macstatusd.log`. Nothing under `/opt`.

New:

- Several webhook targets (`webhook_targets`, GET or POST, per-target headers) for Home Assistant, plus a generic http-webhooks example.
- Release signed with a Developer ID and notarized; `outils/publier.sh`.
- Screen saver detection rewritten on `SACScreenSaverIsRunning` (private `login.framework`), native start and stop, `saver_redisplay_idle_seconds` is now 30; no screen recording permission.
- New `/status` fields: `facts_reason`, `saver_detection`, `saver_dismissal`, `saver_start`, `slow_calls`, `build`, `service`, `main_display`, `display_list`; new options `--register`, `--unregister`, `--status-service`, `--agent`; `--version` shows the git commit and build date.
- Access hardening: `Host` and browser-origin checks, rate limits, connection cap, degraded mode on an invalid configuration.
- `off_command` and `wake_command` must be absolute executable paths; their exit code is logged.
- Apple silicon (arm64) only: the binary has no Intel build.

**Français**

Publiée le 10 novembre 2026.

Ce qui change à la mise à jour depuis la 0.5 :

- **Le jeton est exigé.** Les commandes demandent `X-Auth-Token` (ou `Authorization: Bearer`), et les lectures venues d'une autre machine aussi. Sans `auth_token`, seul le Mac lui-même est servi. `install.sh` génère un jeton de 64 caractères hexadécimaux dans la configuration (droits 600) et ne l'affiche jamais. Les `rest_command` de Home Assistant doivent l'envoyer.
- **macstatusd est maintenant une app.** Elle vit dans `~/Applications` et apparaît dans Réglages Système > Général > Ouverture et extensions, où il faut l'autoriser une fois. Pour l'enregistrer : un double-clic ou `macstatusd --register` ; `--unregister` et `--status-service` complètent le jeu. Aucun `sudo`.
- **macOS redemande** l'accès au réseau local et l'autorisation du pare-feu, une fois, parce que l'identité de signature change.
- **L'ancien agent est retrouvé par son contenu et remplacé.** L'ancien agent de `/opt/macstatusd` est retiré par `launchctl bootout`, et son plist et ses anciens journaux vont à la Corbeille ; si son libellé est déjà `com.djoko.macstatusd`, il est arrêté avant l'enregistrement de la 0.6. La configuration est migrée (`webhook_base_url` devient `webhook_targets`). La commande qui supprime `/opt/macstatusd` est affichée, jamais lancée. Les journaux de la 0.5 contiennent l'URL du webhook : si l'ancien agent a été retiré à la main, les mettre soi-même à la Corbeille.
- **Nouveaux emplacements.** Configuration : `~/Library/Application Support/macstatusd/config.json`. Journal : `~/Library/Logs/macstatusd/macstatusd.log`. Plus rien sous `/opt`.

Nouveautés :

- Plusieurs cibles de webhook (`webhook_targets`, GET ou POST, en-têtes par cible) pour Home Assistant, et un exemple générique http-webhooks.
- Version signée par un Developer ID et notariée ; `outils/publier.sh`.
- Détection de l'économiseur réécrite sur `SACScreenSaverIsRunning` (`login.framework`, privée), démarrage et arrêt natifs, `saver_redisplay_idle_seconds` vaut désormais 30 ; aucune autorisation d'enregistrement de l'écran.
- Nouveaux champs de `/status` : `facts_reason`, `saver_detection`, `saver_dismissal`, `saver_start`, `slow_calls`, `build`, `service`, `main_display`, `display_list` ; nouvelles options `--register`, `--unregister`, `--status-service`, `--agent` ; `--version` montre le commit git et la date de compilation.
- Accès durci : contrôles de `Host` et d'origine de navigateur, limites de débit, plafond de connexions, mode dégradé sur configuration invalide.
- `off_command` et `wake_command` doivent être des chemins absolus exécutables ; leur code de sortie est journalisé.
- Apple silicon (arm64) seulement : le binaire n'a pas de build Intel.

## 0.5.0

**English**

First version of the rewrite.

- The state no longer comes from reading `loginwindow`'s private log: every fact (system sleep, display off, screen saver, session lock) comes from an observable API with an independent fallback.
- Screen saver running is told apart from screen saver on screen, using keyboard and mouse activity.
- Debounced, self-healing state; OFF pushed before sleep; commands verified against facts; periodic heartbeat.
- Endpoints `/state`, `/status`, `/health`, `/wake`, `/sleep`, `/resync`; webhook push to Homebridge (http-webhooks); token, `Host` check and loopback rules.
- Installed in `/opt/macstatusd` as a LaunchAgent.

**Français**

Première version de la réécriture.

- L'état ne vient plus de la lecture du journal privé de `loginwindow` : chaque fait (veille système, écran éteint, économiseur, verrouillage de la session) vient d'une API observable, avec un repli indépendant.
- L'économiseur en cours se distingue de l'économiseur à l'écran, d'après l'activité clavier et souris.
- État anti-rebond et auto-réparateur ; OFF poussé avant la veille ; commandes vérifiées par les faits ; battement de cœur périodique.
- Routes `/state`, `/status`, `/health`, `/wake`, `/sleep`, `/resync` ; push webhook vers Homebridge (http-webhooks) ; jeton, contrôle du `Host` et règles de la boucle locale.
- Installée dans `/opt/macstatusd` comme LaunchAgent.
