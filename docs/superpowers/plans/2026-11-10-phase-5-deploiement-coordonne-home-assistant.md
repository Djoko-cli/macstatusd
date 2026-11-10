# Plan 5 — Déploiement coordonné de la 0.6.0 avec Home Assistant (lot 9)

> **Pour les agents qui exécutent :** sous-compétence requise, `superpowers:executing-plans` (recommandée : la
> plupart des étapes se font avec Djoko et la session HA), et `superpowers:subagent-driven-development` pour la
> tâche 2. Les étapes se cochent (`- [ ]`).

**But :** la 0.6.0 publiée (étiquette `v0.6.0`) remplace la 0.5 sur le vrai Mac de Djoko. HA commande le Mac avec
le jeton et reçoit son état sur un nouvel identifiant de webhook. À chaque étape, la maison garde un chemin qui
marche, et un retour arrière reste possible jusqu'à la tâche 8.

**Architecture :**
- Deux commandes d'exploitation locales, dans `.superpowers/ops/` (ignoré par git, C18), font passer les secrets
  entre le Mac et HA par `ssh ha`, sans jamais les afficher :
  - `transferer-jeton.sh` : jeton du Mac → clé `X-Auth-Token` du secret `macbook_entetes` de HA ;
  - `transferer-push.sh` : secret `macbook_push_url` de HA → cible de `webhook_targets` du Mac.
- L'installation suit le chemin public du README, « Updating from 0.5 » : `install.sh --app` avec l'app
  notarisée de la page de version, ancien préfixe par défaut (`/opt/macstatusd`).
- HA reste à sa session (dépôt `maison-ha`, paquets générés) : elle reçoit un préavis avant chaque étape qui la
  touche, et elle seule modifie sa configuration générée, vérifie et redémarre HA, avec l'accord de Djoko.

**Outils :** bash ; `/usr/bin/python3` 3.9 sur le Mac ; `ssh ha` (alias présent) et `jq` sur HA (ni `python3` ni
`yq`) ; `install.sh`, `uninstall.sh` et `validate-live.sh` de la 0.6.0 ; `gh`, `shasum`, `ditto`, `stapler`,
`spctl`.

**Spec :** `docs/superpowers/specs/2026-10-25-correctifs-audit-design.md` : §4 (contexte HA), lot 9 (§6), §7
(contrat avec HA, transfert du jeton), §8 (banc de bout en bout) ; décisions C4 à C7, C16 à C18, D5, D6.

**État de départ, vérifié le 10/11 :**
- **Le préalable du lot 9 est fait depuis le 28/10** (dépôt `maison-ha`, plan de sa phase 5, Task 10) :
  l'accessoire « MacBook Pro » et la plateforme http-webhooks ont quitté Homebridge, et le push de la 0.5 va au
  webhook de HA.
- **Côté HA**, l'automatisation `remplacant_macbook_pro_etat_recu` (webhook, GET et POST, `local_only`, mode
  `queued`) lit `trigger.query.state` et alimente `input_boolean.remplacant_macbook_pro_etat`, qui donne son état
  à `switch.macbook_pro`. `rest_command.macbook_reveil` et `macbook_veille` prennent leurs en-têtes du secret
  `macbook_entetes`.
- **Dans `secrets.yaml`**, `macbook_entetes`, `macbook_push_url` et `macbook_webhook_id` existent, une ligne
  chacun. `macbook_entetes` est un dictionnaire en ligne, vide (`{}`). Sonde : `ssh ha` en lecture seule, aucune
  valeur affichée.
- **La 0.6.0 poussera en GET**, avec `?state=` : `install.sh` migre `webhook_base_url` en
  `[{"url": …, "method": "GET"}]` (`scripts/install.sh:184-189`), et l'automatisation lit déjà la requête. La note
  de `maison-ha` qui prévoyait un POST JSON (`docs/BACKLOG.md:271-277`) n'est donc pas un préalable.
- **Une config migrée écoute sur toutes les interfaces** (`bind_address` vide par défaut,
  `Sources/MacStatusCore/Config.swift:197`) : HA joint le Mac comme aujourd'hui, sur le port 9090.
- **Sur le Mac**, l'instance réelle tourne en 0.5 (`/status` : version 5.0.0, push confirmé). Le libellé de
  l'ancien agent fait 20 caractères. La commande de transfert du jeton prévue au lot 6 n'existe pas encore :
  `.superpowers/ops/` ne contient que le script de réécriture de l'historique.
- **L'identifiant de webhook actuel a été affiché une fois** (incident du 09/11 côté `maison-ha`) : le nouvel
  identifiant de la tâche 6 le rend inutile.

## Contraintes globales

- **Anonymat.** Aucune valeur réelle dans le dépôt, ni dans un commit ou un message : jeton, URL ou identifiant de
  webhook, adresses et noms d'hôte, libellé de l'ancien agent. Les commandes d'exploitation et leurs tests vivent
  dans `.superpowers/ops/` (C18). La garde `pre-push` reste active ; `--no-verify` est interdit.
- **Aucun secret affiché.** Les commandes n'impriment que des confirmations : clé écrite, longueur, empreintes
  identiques ou non, droits. Aucun secret en argument de commande, visible par `ps` : entrée standard, ou fichier
  temporaire en 600 supprimé à la sortie.
- **`secrets.yaml` de HA.** Sauvegarde horodatée dans `/config/.sauvegardes-secrets` avant toute écriture ; une
  seule ligne écrite, puis relue par `jq` ; `ha core check` avant tout redémarrage ; redémarrage de HA seulement
  sur l'accord de Djoko (§4, §7).
- **Le jeton ne va que dans HA** (C17).
- **Préavis à la session HA** avant chaque étape qui la touche (tâches 1, 4, 6, 7 et 8).
- **Sur le vrai Mac**, `install.sh`, `uninstall.sh`, `sudo` et les réglages sont lancés par Djoko. Claude lance les
  commandes d'exploitation dans un onglet du Terminal, sur l'ordre de Djoko, avec un guetteur essayé avant. Les
  sorties de `codesign`, `spctl` et `stapler` passent par `~/.claude/outils/masquer`.
- **Retour arrière possible jusqu'à la tâche 8** : `/opt/macstatusd`, la sauvegarde de `secrets.yaml` et l'ancien
  plist (à la Corbeille) restent en place jusque-là.
- Commits du contrôleur : `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Les commandes d'exploitation
  ne sont jamais commitées.

## Points de relecture

1. **Écriture ratée de `secrets.yaml` : HA ne redémarre plus.** Attendu : sauvegarde avant l'écriture, une seule
   ligne changée (diff vérifié), relecture par `jq`, `ha core check` vert avant le redémarrage, restauration
   automatique en cas d'échec. Testé à la tâche 2.
2. **Jeton différent des deux côtés : HA ne peut plus commander le Mac (401).** Attendu : empreintes SHA-256
   comparées des deux côtés, sans affichage, au transfert (tâche 4) et en fin de banc (tâche 7).
3. **Identifiant de webhook inconnu : HA répond quand même 200.** Attendu : la vérification lit le changement de
   `input_boolean.remplacant_macbook_pro_etat`, jamais le seul code HTTP (tâches 6 et 7).
4. **Invite « Réseau local » refusée, ou pare-feu : HA ne joint plus le Mac.** Attendu : `/status` le dit (F57), la
   commande depuis HA échoue de façon visible, et la marche à suivre pour réautoriser est donnée (tâche 5).
5. **La 0.6.0 se comporte mal sur le vrai Mac.** Attendu : un retour à la 0.5 écrit et possible jusqu'à la tâche 8
   (tâche 5, retour arrière).

---

### Tâche 1 : état des lieux et app de la page de version

**Fichiers :**
- Créer : `.superpowers/deploiement-0.6.0/etat-des-lieux.md` (local, ignoré par git)
- Télécharger dans : `~/Library/Caches/macstatusd-deploiement-0.6.0/`

- [x] **Étape 1 : télécharger et vérifier l'app publiée.** `gh release download v0.6.0 --repo Djoko-cli/macstatusd
  -D ~/Library/Caches/macstatusd-deploiement-0.6.0`, puis `shasum -a 256 -c SHA256SUMS`, `ditto -x -k` dans `x/`,
  `xcrun stapler validate` et `spctl -a -vv` sur `x/macstatusd.app`, sorties masquées. Attendu : somme OK,
  « The validate action worked! », « accepted », « source=Notarized Developer ID ».
- [x] **Étape 2 : relever l'état du Mac, en lecture seule.** `/status` de l'instance réelle (version, push
  confirmé, aucune URL) ; ancien agent trouvé par son contenu (`ProgramArguments[0]` vaut
  `/opt/macstatusd/macstatusd`), libellé lu sans affichage ; aucune config 0.6 encore
  (`~/Library/Application Support/macstatusd/config.json` absent) ; contenu de `~/Library/Logs/macstatusd/` et du
  fichier `~/Library/Logs/macstatusd.log` (noms, tailles, dates), qui peuvent porter l'ancienne URL. Attendu :
  conforme à l'état de départ ; sinon, arrêt et rapport à Djoko.
- [x] **Étape 3 : relever l'état de HA, en lecture seule.** Par `ssh ha` : les trois secrets présents, forme de
  `macbook_entetes` (une ligne, objet JSON), `jq` présent, existence de `/config/.sauvegardes-secrets`. Attendu :
  l'état de départ. Écart : arrêt.
- [x] **Étape 4 : préavis à la session HA.** Djoko le transmet, ou message direct si elle est ouverte sur ce Mac :
  le plan, les étapes qui la touchent, et ce qu'elle aura à faire aux tâches 4, 6, 7 et 8.

**Critère de sortie :** app publiée vérifiée, états du Mac et de HA conformes et notés, préavis envoyé.

### Tâche 2 : commandes d'exploitation, tests d'abord

**Fichiers (tous locaux, ignorés par git) :**
- Créer : `.superpowers/ops/transferer-jeton.sh`, `.superpowers/ops/transferer-push.sh`
- Créer : `.superpowers/ops/tests/test-ops.sh`
- Créer : `.superpowers/ops/tests/faux/ssh` (exécute la commande distante dans un `/config` d'essai, et journalise
  ses arguments) et `.superpowers/ops/tests/faux/launchctl`

**Interfaces :**
- `transferer-jeton.sh [--verifier]` : lit `auth_token` dans la config de la 0.6 (`$MACSTATUSD_CONFIG`, défaut
  `~/Library/Application Support/macstatusd/config.json`) et l'envoie par l'entrée standard à `$SSH` (défaut
  `ssh ha`). Côté HA (`$CONFIG_HA`, défaut `/config`), la valeur en ligne de `macbook_entetes` reçoit
  `X-Auth-Token` par fusion `jq`, les autres en-têtes gardés.
  - Sortie : « macbook_entetes : X-Auth-Token écrit (64 caractères), N en-tête(s), sauvegarde <nom> », puis
    « empreintes identiques : oui|non ».
  - `--verifier` contrôle tout et n'écrit rien ; si HA a déjà un `X-Auth-Token`, il compare les empreintes
    (« empreintes identiques : oui|non »).
  - Codes : 0 succès ; 1 précondition (ligne absente ou en double, valeur qui n'est pas un objet JSON sur une
    ligne, `jq` absent, jeton absent ou qui n'est pas 64 caractères hexadécimaux) ; 2 écriture ou relecture
    ratée, sauvegarde restaurée.
- `transferer-push.sh [--verifier]` : lit la valeur de `macbook_push_url` par `$SSH` et l'écrit dans la config du
  Mac : `webhook_targets` = `[{"url": <url>, "method": "GET"}]`, autres clés gardées. Avant l'écriture, une
  sauvegarde `config.json.avant-push-<date>` en 600 ; après, droits 600 vérifiés, puis
  `launchctl kickstart -k gui/<uid>/com.djoko.macstatusd`.
  - Sortie : « webhook_targets : URL écrite (N caractères), hôte inchangé : oui|non ».
  - `--verifier` et codes : comme ci-dessus.

- [x] **Étape 1 : la trace avant le faux** (compléments de tests, règle 5). Par `ssh ha`, en lecture seule : shell de
  connexion, présence et options de `cp -p`, `mv`, `mktemp`, `sha256sum` et `jq --rawfile`, propriétaire et
  droits de `secrets.yaml`. Le faux `ssh` reproduit ce relevé (shell, outils), pas davantage. Relevé noté dans
  `etat-des-lieux.md`.
- [x] **Étape 2 : écrire les tests, rouges.** Valeurs inventées seulement (jeton `0000…0001`, URL
  `http://192.0.2.20:8123/api/webhook/essai`) :
  - `jeton-dict-vide` : `{}` devient `{"X-Auth-Token":"<jeton>"}`, une seule ligne changée, sauvegarde créée
    avant l'écriture, code 0 ;
  - `jeton-autres-entetes` : un `{"User-Agent":"x"}` existant est gardé ;
  - `jeton-remplace` : une ancienne valeur de `X-Auth-Token` est remplacée ;
  - `jeton-bloc-refuse` : `macbook_entetes:` suivi d'un bloc YAML → code 1, fichier identique (empreinte) ;
  - `jeton-absent` et `jeton-mauvaise-forme` → code 1, rien d'écrit ;
  - `jeton-jamais-affiche` : le jeton n'apparaît ni dans la sortie, ni dans les arguments journalisés par le faux
    `ssh`. Le test compte les occurrences sans jamais imprimer la valeur, même en échec ;
  - `jeton-ecriture-ratee` : panne simulée sur le chemin lu (le `mv` final échoue) → code 2, `secrets.yaml`
    identique à l'original ;
  - `verifier-n-ecrit-rien` : `--verifier` → code 0, aucun fichier modifié (empreintes) ;
  - `push-ecrit` : `webhook_targets` remplacé, autres clés et droits 600 gardés, sauvegarde en 600, un seul
    `kickstart` ;
  - `push-jamais-affiche` : l'URL n'apparaît dans aucune sortie ;
  - `push-secret-absent` → code 1, config identique.

  Lancer `bash .superpowers/ops/tests/test-ops.sh` ; attendu : échecs, les scripts n'existant pas.
- [x] **Étape 3 : écrire les deux commandes,** jusqu'au vert.
- [x] **Étape 4 : preuve par mutation** (compléments de tests, règle 3) des cas verts dès l'écriture : sans la sauvegarde,
  ou en laissant passer un bloc YAML, au moins un cas devient rouge. Remise en état vérifiée par empreintes.
- [x] **Étape 5 : relecture par Opus** (secrets, sécurité) des deux scripts, de leurs tests et du relevé de
  l'étape 1. Contrôle de risque nommé (compléments de plans, règle 7) : le relecteur lance le banc avec le faux `ssh` qui
  journalise ses arguments, et cherche le jeton d'essai dans tous les journaux et sorties.

**Critère de sortie :** banc vert, mutations rouges, relecture sans critique ni important.

### Tâche 3 : préparer le jeton sur le Mac

- [x] **Étape 1 : Djoko lance**
  `cd ~/Documents/Dev/swift/macstatusd && ./scripts/install.sh --preparer-jeton; echo "code=$?"`. Attendu : la
  config de la 0.6.0 est créée par migration de la 0.5, avec une cible de `webhook_targets` en GET et un jeton de
  64 caractères hexadécimaux, fichier en 600 dans un dossier en 700. Rien d'autre n'est installé : la 0.5 tourne
  toujours.
- [x] **Étape 2 : vérifier sans afficher.** Droits 600 et 700 (`stat`) ; forme du jeton (longueur, hexadécimal) ;
  une cible en GET (longueur de l'URL seulement) ; `/status` de la 0.5 inchangé.
- [x] **Étape 3 : essai sur les vraies données, sans écriture** (compléments de tests, règle 6) :
  `transferer-jeton.sh --verifier` et `transferer-push.sh --verifier` contre le vrai HA. Attendu : code 0,
  confirmations seulement.

**Critère de sortie :** config 0.6 prête avec son jeton, rien d'installé, commandes d'exploitation validées
contre le vrai HA sans écriture.

### Tâche 4 : le jeton dans HA

- [x] **Étape 1 : préavis à la session HA** : le jeton entre dans `macbook_entetes` ; ensuite `ha core check`, puis
  redémarrage sur l'accord de Djoko. La 0.5 ignore l'en-tête : les commandes de HA continuent de marcher.
- [x] **Étape 2 :** sur l'ordre de Djoko, `transferer-jeton.sh` dans un onglet du Terminal, avec un guetteur.
  Attendu : « X-Auth-Token écrit (64 caractères) », « empreintes identiques : oui », code 0.
- [x] **Étape 3 : la session HA** lance `ha core check` (vert), puis redémarre HA avec l'accord de Djoko.
  Fait par un rechargement ciblé (`rest_command.reload`), sur décision de Djoko : redémarrage seulement si la tâche 5 montre un 401.
- [x] **Étape 4 : HA commande toujours le Mac (0.5).** La session HA appelle `rest_command.macbook_reveil` : la
  requête arrive au journal de la 0.5, servie en 200.

**Critère de sortie :** HA redémarré, en-tête en place, commandes toujours servies par la 0.5.
**Retour arrière :** restaurer la sauvegarde de `secrets.yaml`, `ha core check`, redémarrage avec l'accord de
Djoko.

### Tâche 5 : installer la 0.6.0

- [x] **Étape 1 : Djoko lance**, devant le Mac déverrouillé,
  `cd ~/Documents/Dev/swift/macstatusd && ./scripts/install.sh --app "$HOME/Library/Caches/macstatusd-deploiement-0.6.0/x/macstatusd.app"; echo "code=$?"`
  (ancien préfixe par défaut, `/opt/macstatusd`). Attendu :
  - « config existante gardée » et « jeton déjà présent » ;
  - « ancien agent retiré (libellé de 20 caractères) », plist et anciens journaux à la Corbeille ;
  - « activé », puis « Installé. Journal : ~/Library/Logs/macstatusd/macstatusd.log » ;
  - la commande `sudo rm -rf /opt/macstatusd` affichée, non lancée ; code 0.
- [x] **Étape 2 : invites du système.** Djoko accepte « Réseau local » et, s'il paraît, le pare-feu. Si
  l'enregistrement demande une autorisation (code 3) : Réglages Système > Général > Ouverture et extensions, puis
  l'étape 1 relancée (le README l'exige).
- [x] **Étape 3 : vérifier.** `/health` 200 sur 9090 ; `/status` : version 0.6.0, service activé, push confirmé
  (encore vers l'ancien identifiant) ; un seul processus `macstatusd`, celui de `~/Applications` ; plus aucun
  agent dont le programme est sous `/opt`.
- [x] **Étape 4 : commandes de HA avec le jeton.** Veille puis réveil par `rest_command` : code 200, au journal de
  la 0.6.0. Une requête sans en-tête, lancée par la session HA depuis HA : 401.
- [-] **Retour arrière (écrit, lancé seulement en cas de besoin, par Djoko) :**
  `./scripts/uninstall.sh --app ~/Applications/macstatusd.app` (config gardée) ; l'ancien plist remis de la
  Corbeille dans `~/Library/LaunchAgents`, puis `launchctl bootstrap gui/$(id -u) <plist>` ; `/health` vérifié.
  Non lancé : l'installation est vérifiée ; il reste possible jusqu'à la tâche 8.

**Critère de sortie :** 0.6.0 active, commandes de HA servies avec le jeton, refusées sans.

### Tâche 6 : nouvel identifiant de webhook

- [x] **Étape 1 : préavis**, puis la session HA tire un nouvel identifiant (`macbook_webhook_id` et
  `macbook_push_url`), recharge ce qu'il faut et prévient. Jusqu'à l'étape 2, le push de la 0.6.0 va à l'ancien
  identifiant, que HA n'écoute plus : l'`input_boolean` reste figé quelques minutes.
- [x] **Étape 2 :** sur l'ordre de Djoko, `transferer-push.sh` dans un onglet du Terminal. Attendu : « URL écrite »,
  « hôte inchangé : oui », agent relancé (marqueur posé, donc aucun OFF au redémarrage), code 0.
- [x] **Étape 3 : vérifier que l'`input_boolean` change**, puisque HA répond 200 même à un identifiant inconnu.
  OFF par `rest_command.macbook_veille` (économiseur), puis ON par `macbook_reveil` :
  `input_boolean.remplacant_macbook_pro_etat` passe à off puis à on, et `switch.macbook_pro` suit. La session HA
  relève les deux transitions.

**Critère de sortie :** l'état du Mac arrive à HA par le nouvel identifiant ; l'ancien ne sert plus.

### Tâche 7 : de bout en bout, puis banc avec Djoko

- [ ] **Étape 1 : depuis l'app Maison** (Djoko, sur l'iPhone) : l'interrupteur du Mac suit l'état ; OFF lance
  l'économiseur, ON l'écarte.
- [x] **Étape 2 : empreintes du jeton** comparées de nouveau, sans affichage : `transferer-jeton.sh --verifier`
  donne « empreintes identiques : oui ».
- [ ] **Étape 3 : `validate-live.sh` avec Djoko**, sur l'instance installée : cinq étapes manuelles (bureau,
  verrouillage, économiseur, écran éteint, veille), une dizaine de minutes, journal suivi dans un onglet.
  Attendu : chaque étape vérifiée.
- [ ] **Étape 4 :** résultats dans `.superpowers/deploiement-0.6.0/resultats.md`.

**Critère de sortie :** tout vert, sans retour arrière.

### Tâche 8 : nettoyage et clôture

- [ ] **Étape 1 : Djoko lance** `sudo rm -rf /opt/macstatusd` (Touch ID). Vérifier : dossier absent, `/health` 200.
- [ ] **Étape 2 : restes de la 0.5 qui portent l'ancienne URL** (relevés à la tâche 1, par exemple
  `~/Library/Logs/macstatusd.log`) : à la Corbeille, avec l'accord de Djoko.
- [ ] **Étape 3 : préavis de fin à la session HA.** La note `docs/BACKLOG.md:271-277` de `maison-ha` peut se fermer
  (la 0.6.0 pousse en GET). Les sauvegardes de `secrets.yaml` d'avant le jeton ne servent plus : elle décide de
  leur sort.
- [ ] **Étape 4 :** cocher la phase 5 dans la feuille de route de la spec (§6), instantané de Jalons sans
  avertissement, commit et push, garde active.

**Critère de sortie :** plus rien de la 0.5 sur le Mac, phase 5 cochée.
