# Correctifs de l'audit de macstatusd, version 0.6.0 — conception

- **Date :** 25/10/2026
- **Demande :** Djoko (« go pour tout », 25/10/2026)
- **Version visée :** 0.6.0 (D7)
- **Statut :** à valider par Djoko
- **Audit de référence :** audit multi-agents du 25/09/2026 sur le commit `7e54123`
  (90 constats après fusion, 63 confirmés par des vérificateurs contradictoires, 27 réfutés).
  Le détail (scénarios, mesures, avis des vérificateurs sur chaque correctif) est dans
  `.superpowers/audit/audit-2026-09-25.md`, local et ignoré par git, car il contient des
  mesures réelles du réseau de Djoko. Ce document n'en reprend que des formes anonymes.

## 1. Intention

macstatusd dit à la maison si le Mac montre une interface utilisable (ON) ou non (OFF), et
laisse la maison l'éteindre ou le rallumer. L'audit a montré trois choses :

1. **N'importe qui sur un réseau joignable peut commander le Mac**, et une simple page web
   aussi (commandes GET sans authentification, sans contrôle de l'en-tête Host).
2. **La fonction centrale rate un cas courant** : un économiseur lancé par l'inactivité, sous
   macOS 27, n'est pas détecté. L'état reste ON une dizaine de minutes à chaque fois.
3. Une série de défauts de résilience (pas d'OFF à l'arrêt, plantage si le disque est plein,
   réveil qui efface une commande en cours…) et un coût de scrutation qu'on peut diviser par 2 à 3.

Djoko veut que tout soit corrigé. En parallèle, il fait de **Home Assistant le back-end
unique** de la maison : HomeKit reste l'interface, et l'interrupteur « MacBook Pro » y est
désormais un accessoire ponté depuis HA. La session « Migration Home Assistant » en est garante.
Les correctifs doivent donc servir HA, et ne pas casser la transition.

## 2. Objectifs, non-objectifs, anti-objectifs

**Objectifs**

- Chacun des 63 constats confirmés reçoit un traitement explicite : corrigé, adapté (avec la
  raison) ou décliné (avec la raison). Table complète en section 9.
- La définition de l'état ne change pas : écran de verrouillage visible, bureau, application
  ou fenêtre de login = ON ; économiseur seul à l'écran, écran éteint, veille, aucun écran = OFF.
- HA pilote le Mac par `rest_command` (en ajoutant un en-tête), et reçoit un état conforme à
  cette définition.
- Le dépôt public devient conforme à la règle d'anonymat de Djoko, historique compris (D4).
- Les tests ne dépendent plus de l'état de l'écran, et la logique centrale est testée par XCTest.
- macstatusd devient une app d'arrière-plan signée par le Developer ID de Djoko et notarisée (D9),
  enregistrée comme les services d'origine de macOS (C20).

**Non-objectifs**

- La limite connue de la touche Échap sur l'écran de verrouillage. Elle demande une capture
  dédiée et reste un chantier à part, même si le lot 4 touche la même zone.
- Une interface graphique : l'app reste sans fenêtre ni icône dans le Dock. Elle n'a d'icône que
  dans les Réglages et le Finder.
- Les mises à jour automatiques (Sparkle) : une nouvelle version s'installe par `install.sh` ou
  depuis une version publiée sur GitHub.
- Une intégration HA sur mesure (MQTT, découverte automatique) : les mécanismes natifs de HA
  (webhook, `rest_command`, capteur REST) suffisent.

**Anti-objectifs** (ce qui ferait échouer le chantier même si tout « marche »)

- Casser `switch.macbook_pro` de HA sans transition coordonnée.
- Afficher un secret dans une session, un journal ou un commit.
- Une régression de la détection : en particulier un faux OFF permanent sur le bureau (piège
  signalé par les vérificateurs de F03 : le préfixe de process `legacyScreenSave` désigne aussi
  l'hôte qui dessine le fond d'écran).
- Un correctif qui empire l'expérience native, par exemple garder l'écran allumé plus longtemps
  que macOS ne le ferait.

## 3. Contraintes

- **macOS 27.0.1 « Golden Gate » (26A434)**, Apple Silicon, en mode capot fermé avec plusieurs
  écrans externes. La sonde de juillet tournait sous 26.5 ; les vérificateurs de l'audit ont mesuré
  une 27.0 (26A428), alors que le contexte qui leur était donné annonçait 26. **Tout constat qui
  dépend du comportement du système** (F03, F16, F50, F57, F69, et le comportement de
  `SACScreenSaverIsRunning`) **est revérifié sur la version courante** pendant la relecture de son
  lot, ou au banc.
- Toolchain Swift 6.x, `swift-tools-version: 5.9`, mode de langage Swift 5, aucune dépendance
  externe. Cible `macOS(.v13)` conservée.
- Agent de la session Aqua (et non LaunchDaemon), désormais enregistré par `SMAppService` (C20) :
  c'est ce qui donne accès aux écrans, aux notifications d'économiseur et à la session.
- **Signature** (règle de Djoko, 12/10/2026) : un seul certificat « Developer ID Application »,
  choisi par ce préfixe, jamais par son nom complet ; un seul profil de notarisation,
  `djoko-notarisation`. Le nom légal de Djoko et son équipe ne figurent que dans la signature des
  versions publiées : ni dans le dépôt, ni dans un commit, une note ou un journal affiché. Tout ce
  que montrent les outils est masqué (`<titulaire>`, `<equipe>`). Méthode de référence : la fiche
  de passation d'Amaran, adaptée au lot 8.
- **Anonymat** (règle de Djoko, 12/10/2026) : identité git noreply, garde `pre-push`, aucun
  identifiant réel dans un fichier ou un message de commit (prénom et nom, e-mail personnel, IP
  réelles, noms d'hôte, chemins `/Users/<nom>`). Djoko s'appelle Djoko dans le dépôt.
- **Secrets** (règle du 09/10/2026) : le jeton n'est jamais affiché. Il est saisi ou transféré
  dans un onglet du Terminal (`read` masqué ou lecture directe de fichier), écrit avec des droits
  600, et aucune session ne le voit.
- L'instance réelle ne doit pas être perturbée pendant le développement : tests sur des ports
  réservés, et aucun test automatique qui rallume l'écran ou lance l'économiseur. Les essais
  réels se font au banc, avec Djoko.

## 4. Le contexte Home Assistant

Ce que fait HA aujourd'hui, d'après le dépôt de la migration (lecture du 25/10) :

- `rest_command.macbook_reveil` → `GET http://<mac>:9090/wake?action=WAKE`, et
  `rest_command.macbook_veille` → `GET …/sleep?action=SLEEP`. Adresses et en-têtes vivent dans
  `secrets.yaml` de HA.
- `switch.macbook_pro` est un interrupteur de modèle dont l'état est
  `binary_sensor.macbook_pro_active`, le capteur « Active » de l'app compagnon HA du Mac. Il est
  ponté vers HomeKit par le « Pont général HA ».
- Homebridge (plugin http-webhooks) reçoit encore le push de macstatusd. Il reste en service pour
  d'autres accessoires, mais son accessoire « MacBook Pro » sera retiré (D6).
- Les deux `rest_command` adressent le Mac par une **IPv4 littérale**. Leurs en-têtes viennent déjà
  du secret `macbook_entetes`, un dictionnaire ; le jeton y entrera sous la forme
  `{"X-Auth-Token": "…"}`. Recharger les `rest_command` demande un redémarrage de HA, avec l'accord
  de Djoko.

**Écart de sémantique.** D'après sa documentation, le capteur « Active » de l'app compagnon est
inactif quand le Mac « is showing the login screen » (Locked) et quand « input devices haven't
been used in a number of minutes » (Idle). C'est contraire à la définition de Djoko. Un ON envoyé
depuis HomeKit sur un Mac verrouillé rallume l'écran de verrouillage, mais l'interrupteur retombe
à OFF ; une vidéo regardée sans toucher au clavier fait passer l'interrupteur à OFF. La question a
été posée à la session HA (25/10), avec deux voies que macstatusd peut servir (section 7). **Djoko
a retenu la voie A (D5).** La voie B reste décrite pour mémoire, mais elle n'est pas à construire.

**Bascule avant la 0.6.0.** Le format de push de la version en place (5.0.0) fonctionne tel quel
sur un webhook de HA. Le jour du retrait de l'accessoire de Homebridge (D6), si la 0.6.0 n'est pas
encore déployée, la bascule se fait avec la 5.0.0. Une commande dans un onglet du Terminal lit
l'URL du push dans le secret `macbook_push_url` de HA par `ssh ha`, sans l'afficher, puis l'écrit
dans `webhook_base_url`, après une sauvegarde de la config, et relance l'agent. La session HA crée
ce secret et le webhook juste avant la Task 10 et prévient ; Claude lance l'onglet sur l'ordre de
Djoko, vérifie au journal que le push est confirmé (HTTP 2xx), puis la session HA vérifie
l'`input_boolean`. Cette opération est hors des lots : elle ne dépend pas du chantier.

**Limite de cette bascule.** La 5.0.0 écrit `webhook_base_url` en clair à chaque démarrage, dans son
journal et dans `os_log` en public (`main.swift:152-155`, `Log.swift:123-126`). Sa config
appartient à root en 644 (`install.sh:54`). La commande de bascule rend donc la config à
l'utilisateur en 600 (`sudo` une fois, tapé par Djoko). À l'installation de la 0.6.0, la session
HA tire un **nouvel** identifiant de webhook, ce qui rend l'ancien inutile s'il traîne dans un
journal ; la migration supprime aussi les anciens journaux de la 5.0.0.

## 5. Décisions

### 5.1 Décisions de Djoko

| | Décision |
|---|---|
| D1 | Corriger tous les constats confirmés de l'audit (25/10). |
| D2 | HA devient le back-end unique ; HomeKit reste l'interface (25/10). |
| D3 | HomeKit OFF lance l'économiseur d'écran par défaut, pour que ON reste possible (choix du 30/07, inchangé). |
| D4 | **Recréer le dépôt public avec un historique anonyme** (25/10). Lot 0. |
| D7 | **La prochaine version est la 0.6.0** (25/10) : les numéros 5 et 6 exagéraient l'évolution d'un daemon numéroté trop vite à ses débuts. Dans l'historique réécrit, la version initiale 5.0.0 devient 0.5.0 (C21). |
| D8 | **Libellé et identifiant `com.djoko.macstatusd`** (25/10), à la place de l'ancien, qui contient le prénom réel. |
| D9 | **Signature par le Developer ID de Djoko et notarisation** (25/10). Lot 8. |
| D5 | **Voie A** pour l'état de `switch.macbook_pro` : macstatusd pousse vers un webhook de HA (`local_only`, GET et POST acceptés, lit `?state=`), qui alimente un `input_boolean` (choix rapporté par la session HA, 25/10). |
| D6 | Homebridge **reste** (PS5, Sync Box). Seul son accessoire « MacBook Pro » (http-webhooks) sera retiré, au premier lot d'échanges de la phase 5 de la migration (Task 10), sur l'ordre de Djoko. Ce jour-là, le push de macstatusd bascule vers HA. |

### 5.2 Décisions de Claude, à vérifier en relisant

| | Décision | Raison |
|---|---|---|
| C2 | **Installation en espace utilisateur, sans aucun `sudo`** : l'app dans `~/Applications/macstatusd.app`, la config (600) sous `~/Library/Application Support/macstatusd/`, les journaux sous `~/Library/Logs/macstatusd/`. | F80 : la propriété root de `/opt` n'apportait aucune intégrité (le plist utilisateur choisit le binaire et la config). Supprime d'un coup F10 et le cœur de F35, et permet une config en 600. |
| C3 | **Identifiant `com.djoko.macstatusd` partout** (D8) : identifiant de l'app, libellé de l'agent, sous-système `os_log`. Migration automatique de l'ancien agent par `install.sh`. | Anonymat. |
| C4 | **Le jeton est toujours présent** : généré à l'installation ou à la migration s'il manque (32 octets aléatoires en hexadécimal), jamais affiché. | F01 : la config déployée n'en a pas, et `install.sh` conservait la config existante telle quelle. |
| C5 | **Règles d'accès.** Commandes (`/sleep`, `/off`, `/wake`, `/on`, `/resync`) : jeton exigé, quelle que soit la provenance. Lectures (`/state`, `/status`) : libres depuis la boucle locale, jeton exigé sinon. `/health` : libre. Sans jeton configuré (config modifiée à la main) : tout est limité à la boucle locale, avec un avertissement au démarrage. | Un jeton dans un en-tête bloque aussi le CSRF, sans dépendre des navigateurs. |
| C6 | **Jeton accepté par en-tête seulement** (`X-Auth-Token`, ou `Authorization: Bearer`). `?token=` refusé par défaut ; option `allow_query_token` pour la compatibilité. Comparaison à temps constant. | F25. HA et Homebridge savent envoyer des en-têtes. |
| C7 | **Contrôle de Host** sur toutes les routes sauf `/health` : littéraux IP, `localhost`, les noms `.local` du Mac (nom local de SCDynamicStore) et la liste `allowed_hosts`. Refus des requêtes porteuses d'`Origin`, ou de `Sec-Fetch-Site` différent de `none`. HEAD → 405 sur les commandes. | F02 (DNS rebinding, CSRF). Le client HTTP de HA n'envoie ni `Origin` ni `Sec-Fetch-*`. |
| C8 | **Commandes idempotentes et bornées.** Un doublon reçu pendant qu'une commande de même sens est en cours ne relance rien et **ne repousse pas son échéance** (sinon l'escalade ne part jamais, avis des vérificateurs de F07). La dernière commande de sens opposé l'emporte (F13). Seau à jetons global sur les commandes (5/s, rafale 10) → 429. | F07, F13, F43. |
| C9 | **Webhook : confirmation sur tout 2xx, sans redirection suivie, réponse plafonnée à 4 Kio.** On n'exige **pas** un corps JSON `success: true` (proposition de F53) : un webhook HA répond 200 sans corps. | F53, F54, adaptés à HA. |
| C10 | **F89 décliné** : pas de battement de cœur « en lecture ». C'est un mécanisme propre à http-webhooks, et une requête sans `state` sur un webhook HA ne porte rien d'utile. Le battement de cœur en écriture reste ; côté HA il ne coûte pas d'écriture disque (l'historique de HA n'enregistre que les changements). | Transition vers HA. |
| C11 | **F15 décliné** (« écran rallumé par macOS sans personne devant → ON ») : la définition de Djoko compte l'écran de verrouillage visible comme ON. | Respect de la définition. |
| C12 | **F14 traité par une option `wake_hold_seconds`, désactivée par défaut** (0 = comportement actuel). Sur session verrouillée, macOS rendort l'écran au bout d'environ 30 s ; le retenir plus longtemps irait contre le comportement natif. | Expérience native d'abord. |
| C13 | **F88 traité hors code**, côté HA. Relevé du 25/10 dans les journaux du Mac (du 2 au 25/10) : 1 406 commandes ON et aucune OFF. Elles venaient de Homebridge jusqu'au 23/10 (environ 55 par jour), puis de HA à partir du 22/10 (jusqu'à 95 par jour), avec un écart médian de 7 min 30 s. Chacune rallume les écrans et repousse la veille par inactivité (C15). Source identifiée par la session HA (25/10) : deux automatisations d'éclairage de la pièce du Mac, migrées de Maison le 22/10, appellent `rest_command.macbook_reveil` à chaque détection de présence. C'est voulu sur le principe (réveiller le Mac en entrant), mais chaque mouvement le refaisait. **Réglé côté HA le 25/10 à 01 h 17** sur décision de Djoko : réveil seulement à l'arrivée (présence qui passe à « présent », ou mouvement pendant une présence « absent »). À vérifier dans le journal du Mac : 1 à 2 ON par arrivée. C8 et C15 restent utiles. | Constat de configuration, pas de code. |
| C14 | **Socle testable d'abord** (F23) : la logique passe dans une cible bibliothèque `MacStatusCore` (horloge, sources de faits, actions et transport injectés), testée par XCTest (`swift test`). L'exécutable `macstatusd` devient une fine couche de câblage. | Tous les autres lots s'appuient dessus pour écrire leurs tests d'abord. |
| C15 | **Assertion d'activité de `/wake`** : vérifier au banc sa durée réelle (relevé d'une autre session : « Timeout will fire in 1572 secs ») et la relâcher dès que l'état est confirmé ou à l'arrêt, pour ne pas bloquer la veille par inactivité pendant une demi-heure après chaque ON. | Constat hors audit, relevé le 25/10 dans deux sessions de diagnostic. |
| C16 | **OFF à l'arrêt, sauf redémarrage prévu de l'agent.** OFF est publié à l'extinction, au redémarrage du Mac et à la fermeture de session (menu Pomme > Fermer la session). Le simple verrouillage n'est pas concerné : la session reste ouverte et macstatusd continue de tourner. À la fermeture de session, la fenêtre de login est visible (ON selon la définition), mais macstatusd ne tourne plus et ne pourrait exécuter aucune commande : OFF dit mieux ce que la maison peut faire. Un redémarrage prévu de l'agent (`install.sh`, mise à jour, `kickstart`) pose d'abord un marqueur, `restart-pending` dans le dossier de l'application : l'agent qui s'arrête le voit, le supprime et ne publie rien, ce qui évite un aller-retour OFF puis ON. Aucune automatisation de HA ne réagit à un OFF du Mac (vérifié par la session HA, 25/10) : un OFF à la fermeture de session n'a pas d'effet physique. | F04, et les réserves de ses trois vérificateurs. |
| C17 | **La 0.6.0 est déployée après le retrait de l'accessoire « MacBook Pro » de Homebridge (D6).** Le jeton n'a donc à aller que dans HA, jamais dans la config de Homebridge, où il serait en clair. | Simplifie le lot 9 ; c'est l'ordre annoncé par la session HA (Task 10 dans les jours qui viennent). |
| C18 | **Commandes d'exploitation liées à la maison de Djoko** (bascule du push en 5.0.0, transfert du jeton vers HA) : dans `.superpowers/ops/`, local et ignoré par git, jamais dans le dépôt public. | Elles décrivent son installation HA. |
| C20 | **macstatusd devient une app d'arrière-plan** (`macstatusd.app`, `LSUIElement`, ni fenêtre ni Dock) qui enregistre son agent par `SMAppService` : plist de l'agent dans le paquet, `BundleProgram`, même session Aqua et mêmes clés de relance (`KeepAlive`, `ProcessType`). L'app apparaît dans **Réglages > Général > Ouverture et extensions**, avec son nom et son icône, et Djoko peut l'y couper. Son `Info.plist` porte la description de l'invite « Réseau local » (`NSLocalNetworkUsageDescription`). Elle a une icône dans le style des autres apps de Djoko, validée par lui avant toute compilation signée. Quelqu'un qui clone le dépôt peut toujours compiler et installer sans certificat (signature ad hoc). | Règle de Djoko « l'expérience native avant tout » : c'est l'intégration d'origine d'un service d'arrière-plan depuis macOS 13. Une app se notarise avec agrafage, et une identité de signature stable garde les autorisations (Réseau local, pare-feu) d'une mise à jour à l'autre, alors qu'une signature ad hoc change à chaque compilation. |
| C21 | **Version initiale renommée 0.5.0 dans l'historique réécrit** (`Version.swift`, titres des README, message du premier commit), pour une suite 0.5.0 → 0.6.0 cohérente. Les prototypes de `Versionning/` gardent leurs noms d'origine, comme archives. | D7 ; l'historique est réécrit de toute façon (D4). |
| C22 | **Compilations de travail en signature ad hoc** (tests, instances de test sur ports réservés). Seule l'app installée par Djoko et les versions publiées portent le Developer ID. | Les tests n'ont besoin d'aucune autorisation du système ; la notarisation prend plusieurs minutes. |
| C23 | **Session d'économiseur établie par `SACScreenSaverIsRunning`** (ou par un process `ScreenSaverEngine`), jamais par les fenêtres ni par le seul process hôte. | Banc 1 (31/10) : SAC vaut 1 pendant chaque session et 0 sur un simple verrouillage ; les fenêtres de loginwindow et le pointeur existent dans les deux cas. |
| C24 | **`/wake` écarte l'économiseur par `SACScreenSaverStopNow`**, `killall` en repli. | Banc 1 : seule méthode qui fasse apparaître le panneau ; les autres laissaient l'économiseur et publiaient un faux ON. |
| C25 | **`saver_redisplay_idle_seconds` : défaut 30** (au lieu de 90). | Banc 1 : retour à l'économiseur 30 s après la dernière frappe ou le dernier arrêt natif, mesuré cinq fois sous 27.0.1. |
| C26 | **Veille avortée** par une frappe postérieure à l'annonce ou par un déverrouillage ; filet du réveil perdu porté de 35 à 120 s. | Banc 1 (B5, B6) : une veille annulée laissait le daemon à OFF 14 s ; une entrée en veille de 29 s a déclenché le rattrapage à tort. |
| C19 | **Banc du lot 4 sur deux économiseurs** : l'actuel, tiers et x86_64 (hôte `legacyScreenSaver-x86_64`), et un économiseur d'Apple (hôte arm64 `legacyScreenSaver`, celui du piège du faux OFF permanent). L'hôte est identifié par son chemin complet et son instant de lancement, jamais par le seul nom. | Avis des vérificateurs de F03 ; Rosetta sera restreint après macOS 27. |

## 6. Les lots

Ordre d'exécution : chaque lot s'appuie sur les précédents. Le lot 0 vient avant tout commit, le
lot 1 avant tout correctif (il fournit les tests), le lot 8 après les lots 6 et 7 (icône, notes de
version), et le lot 9 ne se fait qu'avec la session HA.

### Feuille de route

Les lots se livrent en cinq phases. Chaque phase a son plan, du même numéro, dans
`docs/superpowers/plans/` (nom en `…-phase-N-….md`, pour que Jalons le rattache à sa phase). Une phase se
coche quand son plan est fini, banc compris.

- [x] Phase 1 : anonymisation du dépôt et garde (lot 0)
- [x] Phase 2 : socle testable, sécurité HTTP et résilience (lots 1 à 3)
- [x] Phase 3 : économiseur sous macOS 27, écrans, veille avortée et efficience (lots 4 et 5)
- [ ] Phase 4 : installation, documentation, signature et publication (lots 6 à 8)
- [ ] Phase 5 : déploiement coordonné avec Home Assistant (lot 9)

### Lot 0 — Anonymisation et garde

- Identité git du dépôt sur l'adresse noreply (déjà réglée localement le 25/10).
- Garde `pre-push` versionnée (`outils/pre-push`, installée par `outils/installer-garde.sh` via
  `core.hooksPath`) :
  - auteur et committer noreply sur chaque commit poussé, comme le modèle des autres dépôts de Djoko ;
  - refus de tout ajout, dans le diff poussé ou dans les messages de commit, d'un motif listé dans
    `garde.local.txt` (ignoré par git : prénom et nom réels, e-mail personnel, IP et noms d'hôte
    réels connus) ;
  - refus de motifs génériques : adresses IPv4 privées hors plages de documentation
    (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`), chemins `/Users/<nom>`, adresses e-mail
    hors noreply.
  - Essais de la garde avec des violations plantées **là où seule la garde peut les voir** : dans le
    message de commit, dans un fichier binaire, dans une ligne supprimée puis réintroduite, et dans
    un commit intermédiaire corrigé ensuite. Leçon d'une observation ouverte : des essais qui
    plaçaient la fuite là où une vérification annexe la voyait aussi passaient alors que la garde
    inspectait le mauvais objet.
- **Réécriture de l'historique (D4).** Les deux commits publiés sont rejoués un à un sur une
  nouvelle racine, avec leurs dates, et l'auteur et le committer passent à l'adresse noreply.
  - Dans leurs arbres : l'ancien libellé (`com.<prénom réel>.macstatusd`) devient `com.djoko.macstatusd`, fichier du plist
    compris ; l'IP d'exemple devient une IP de documentation (`192.0.2.10`) ; la version 5.0.0
    devient 0.5.0 (C21).
  - Dans les messages de commit : même version et mêmes remplacements.
  - L'ancien historique est gardé en paquet git dans `.superpowers/` (local : il contient les données
    réelles).
  - Vérification : la garde, appliquée à l'historique entier, ne trouve rien.
  - Le travail nouveau (cette conception comprise) part ensuite de cette racine.
- **Recréation du dépôt GitHub**, sous le même nom, une fois l'historique réécrit et vérifié.
  - Djoko supprime l'ancien dépôt, sur github.com ou avec `gh` après
    `gh auth refresh -s delete_repo` (le jeton actuel n'a pas ce droit). L'opération est
    irréversible : elle se fait sur son « go » explicite, au moment venu.
  - Claude recrée le dépôt (public, description en anglais, licence MIT) et pousse l'historique
    réécrit, garde installée.
  - Le dépôt n'a ni fork ni étoile : la suppression efface toutes les anciennes données, et aucune
    demande de purge à GitHub n'est nécessaire.

### Lot 1 — Socle testable

F23, F24, F66, F67, F81, F70 (en partie).

- Cible `MacStatusCore` : moteur d'état, oracle de l'économiseur, règles de décision, client
  webhook (transport injecté), analyse et règles d'accès HTTP, lecture de config. Une horloge
  injectée pour tous les délais.
- Cible de tests XCTest : les 17 vérifications actuelles de `--check-rules` y passent, puis les
  scénarios de F67 (didstart authentique sans process, paire didstop/didstart forgée, cycle sans
  preuve, didstart orphelin…).
- `scripts/selftest.sh` devient hermétique : il ne dépend plus de l'état de l'écran. Les sections
  qui en dépendent sont sautées et annoncées comme telles ; un `field()` en erreur ne passe plus
  à vide.
- Contrats de files vérifiés par `dispatchPrecondition` (F81).

### Lot 2 — Surface HTTP et authentification

F01, F02, F06, F07, F08, F25, F26, F28, F32, F69, F79.

- Décisions C4 à C8.
- Plafond de connexions : 32 au total, 8 par pair, décrémenté une seule fois à l'état final de la
  connexion (piège de double décompte relevé par les vérificateurs). Délai d'obtention des
  en-têtes : 2 s.
- Échecs d'authentification journalisés, une ligne par pair et par minute, et 429 pendant 60 s
  après 10 échecs en 60 s depuis un même pair.
- Analyseur strict : ligne de requête en 3 éléments, méthode sensible à la casse, version
  HTTP/1.0 ou 1.1, `Host` exigé en 1.1, cible en octets imprimables, en-tête `Allow` sur les 405.
- Journal : caractères de contrôle échappés, chemin tronqué à 200 caractères.
- Message d'écoute exact (IPv4 et IPv6, ou adresse liée) ; `bind_address` accepte `0.0.0.0`
  (IPv4 seul) et `::`.
- Options TCP appliquées sur la bonne couche du protocole (F69).

### Lot 3 — Résilience

F04, F05, F11, F12, F13, F18, F19, F20, F21, F29, F30, F39, F43, F53, F54, F55, F57, F61, F62, F64,
F72, F74, F14 (option).

- **Arrêt (F04, C16)** : sur SIGTERM, le moteur est verrouillé (plus aucune publication), OFF est
  publié en remplaçant une requête en vol, avec une attente bornée à 2 s, puis le journal est
  vidé. Le plist fixe `ExitTimeOut` à 5 s (il ne le fixait pas ; le délai par défaut de launchd est
  plus long). Option `publish_off_on_exit` (vrai par défaut), et marqueur de redémarrage prévu
  (C16).
- **Journal (F05, F61, F30)** : ouverture `O_APPEND|O_CLOEXEC`, écritures qui renvoient une erreur
  au lieu de lever une exception Objective-C, réouverture si le fichier a été remplacé ou
  supprimé (contrôle d'inode), 5 générations de 2 Mio, échec signalé une seule fois par `os_log`.
  Le battement de cœur ne s'écrit plus en INFO (F72).
- **Veille et réveil (F11, F12, F39, F74)** : seul `HasPoweredOn` vaut réveil, `WillNotSleep` est un
  événement distinct, et un réveil n'efface plus la commande en cours. Avant la veille, l'attente
  devient asynchrone (un seul appel garanti à l'acquittement) et n'envoie que si l'état confirmé
  diffère de l'état voulu. Pas de publication forcée à chaque veille : le Mac en fait des milliers
  par semaine.
- **Config (F18, F62, F64)** : un fichier absent garde les défauts ; un fichier illisible ou
  invalide passe en mode dégradé fermé (écoute locale seulement, commandes et `/health` en 503,
  `config_error` dans `/status`, erreur précise au journal). Valeurs corrigées en silence →
  avertissements. CLI validée.
- **Instance unique (F19)** : webhooks et battement de cœur seulement si le listener est prêt et la
  session sur la console. Le port reste le verrou.
- **Listener (F21)** : l'état `.waiting` est journalisé une fois, puis le listener est relancé au
  bout de 5 s.
- **Plusieurs cibles de push** (demande de la session HA, 25/10) : clé `webhook_targets`, une
  liste d'objets `{"url", "method", "headers"}`. Chaque cible a son propre état voulu/confirmé et ses
  propres réessais ; une cible en panne ne retarde jamais les autres. L'ancienne clé
  `webhook_base_url` reste acceptée comme cible unique.
- **Webhook (F20, F29, F53, F54, F55, F57)** : compteur de génération contre les réessais
  périmés, réessai lent après abandon (15, 30, puis 60 s) tant que l'état n'est pas confirmé,
  renvoi au retour du réseau (`NWPathMonitor`), décision C9, URL masquée dans les journaux, en-têtes
  configurables (`webhook_headers`, `webhook_method`), et domaine et code d'erreur journalisés
  (refus « Réseau local » reconnaissable).
- **Option `wake_hold_seconds`** (C12) et assertion d'activité relâchée (C15).

### Lot 4 — Économiseur d'écran

F03, F16, F17, F46, F50, et les scénarios de F67.

- **Banc d'abord (avec Djoko) : fait le 31/10/2026 (banc 1).** La sonde est mise à jour dans
  `diagnostics/`, avec une sortie dans `$TMPDIR` (F36). Les résultats sont rangés dans `.superpowers/banc/`.
  Trois familles d'économiseurs ont été vues sous 27.0.1 :
  - un économiseur tiers ancien, hébergé par `legacyScreenSaver-x86_64` sous Rosetta ;
  - l'extension moderne d'Apple « Message » (`Computer Name.appex`) ;
  - les paysages aériens, dessinés par `WallpaperAerialsExtension`, présente en permanence.

  Le choix de l'économiseur se fait par écran et par bureau (magasin `com.apple.wallpaper`).
- **Règle retenue après le banc 1** (elle remplace la règle visée, qui comptait sur une fenêtre
  d'économiseur) :
  - **Session d'économiseur** : `SACScreenSaverIsRunning` vrai, ou un process `ScreenSaverEngine`
    (économiseur commandé). Mesuré : SAC vaut 1 de `didstart` jusqu'au déverrouillage, panneau compris,
    et 0 pendant un simple verrouillage.
  - **Corroboration de `didstart`** : `didstart` sans corroboration dans les 5 s est expiré (F46).
    - La corroboration vient de SAC.
    - Si SAC manque, elle vient d'un hôte apparu après la notification.
    - Une notification seule ne fait jamais foi : n'importe quel process local peut la poster (F17).
  - **Fin de session** : `didstop`, ou SAC faux sur deux lectures de suite. Avec SAC vrai, un
    `didstop` est incohérent : il est journalisé et ignoré.
  - **Ce qui ne prouve jamais un économiseur** :
    - les fenêtres de loginwindow aux niveaux 2001 à 2004 et le pointeur, qui existent aussi sur un
      simple verrouillage ;
    - le seul process hôte (C19), qui peut s'attarder 27 min après un aperçu des Réglages, ou 26 s
      après un déverrouillage.

    Les **noms** de fenêtres ne sont pas lisibles sans l'autorisation d'enregistrer l'écran : le
    daemon ne s'en sert pas.
  - **Panneau par-dessus l'économiseur (ON)** : depuis la dernière frappe ou le dernier arrêt natif,
    pendant `saver_redisplay_idle_seconds`. Mesuré cinq fois sous 27.0.1 : 30 s, d'où un défaut
    ramené de 90 à 30. Ensuite, macOS revient à l'économiseur (OFF).
- **`SACScreenSaverIsRunning` est validé sous 27.0.1 (banc 1).** Appelé avec un pointeur valide, il
  rend 1 pendant la session et 0 hors session. L'octet n'est jamais écrit : la valeur passe par le
  retour. La fonction est chargée dynamiquement. Si elle manque, la corroboration passe par l'hôte
  apparu après `didstart` ; les paysages aériens, sans hôte propre, ne sont alors plus détectés, et le
  daemon le dit au démarrage.
- **Écarter l'économiseur lors d'un ON : `SACScreenSaverStopNow`** (login.framework, sans argument).
  - Au banc 1, la déclaration d'activité utilisateur, `caffeinate -u` et `killall ScreenSaverEngine`
    n'ont **rien changé à l'écran**, alors que le daemon publiait ON (faux ON, A1.8 et B4).
  - `SACScreenSaverStopNow` montre le panneau par-dessus l'économiseur, comme une frappe : vérifié sur
    l'économiseur tiers x86_64 et sur Message, lancés par l'inactivité ou commandés.
  - `killall ScreenSaverEngine` ne reste qu'en repli, si la fonction manque.
  - Limite connue : avec un réglage mixte par écran (Message au centre, l'économiseur tiers sur les
    côtés), l'arrêt natif n'a rien montré. Le daemon publiera ON pendant 30 s, à tort ; à revoir au
    banc de validation.
- Notifications horodatées, avec échéance quand rien ne les corrobore (F46) ; pas de réarmement par
  une paire forgée pour un même PID (F17).
- Écrans : l'écran fantôme du WindowServer est exclu (F16) ; `screensDidSleep` sert de source
  indépendante (F50).
- **Veille avortée et réveils sombres (banc 1)** :
  - Une veille annoncée (`WillSleep`) peut ne jamais aboutir : des pilotes et des process lents
    peuvent retarder l'entrée en veille de 30 s, et une frappe l'annule. Une frappe postérieure à
    l'annonce, ou un déverrouillage, met fin à la veille sans attendre IOKit.
  - Le rattrapage du « réveil perdu » (35 s) s'est déclenché à tort pendant une entrée en veille de
    29 s : il devient un filet à 120 s.

### Lot 5 — Efficience et observabilité

F75, F76, F78, F71, F44, F90, F70.

- PID de l'économiseur mis en cache et revalidé par `proc_pidinfo` ; scan complet seulement sur un
  indice (lancement d'app, `didstart`) ou toutes les 5 s en filet ; filtre sur l'UID de
  l'utilisateur (F75). Objectif : tick écran allumé ≤ 0,35 % d'un cœur (mesuré : 0,76 à 0,91 %).
- `CGSessionCopyCurrentDictionary` seulement en repli (F76) ; service `IOHIDSystem` résolu une seule
  fois, `HIDIdleTime` lu seulement quand l'oracle est évalué (F78).
- `Facts` comparables (F71), `reason` tenu à jour (F44), topologie des écrans dans `/status` (F90),
  code mort retiré (F70).

### Lot 6 — Installation et exécution

F09, F10, F22, F35, F36, F63, F80, F83, F29 (côté config).

- Décisions C2, C3, C4, C20.
- **Le paquet de l'app** : `outils/assembler-app.sh` construit `macstatusd.app` à partir de
  l'exécutable SwiftPM. Il contient :
  - `Contents/MacOS/macstatusd` ;
  - `Info.plist` (identifiant `com.djoko.macstatusd`, version 0.6.0, `LSUIElement`,
    `NSLocalNetworkUsageDescription` en anglais et en français) ;
  - l'icône ;
  - le plist de l'agent dans `Contents/Library/LaunchAgents/`.

  Signature : Developer ID si une telle identité est présente et demandée, ad hoc sinon (C22).
- **L'icône** : dessinée dans le style des autres apps de Djoko et validée par lui. Le script
  d'assemblage échoue si elle manque (règle « pas d'app sans icône »).
- **Enregistrement natif** : `macstatusd --register` et `--unregister` appellent
  `SMAppService.agent(plistName:)`. L'état d'enregistrement (activé, à approuver dans les Réglages,
  absent) est lisible par `--status-service` et dans `/status`.
- `install.sh` sans `sudo` : build, assemblage, copie dans `~/Applications`, enregistrement,
  migration depuis `/opt` (reprise de l'ancienne config, jeton repris ou généré, retrait de l'ancien
  agent, commande `sudo` affichée pour supprimer `/opt/macstatusd`, sans l'exécuter),
  vérification sur l'hôte et le port configurés (F63). Le marqueur de redémarrage prévu (C16) est
  posé avant tout remplacement de l'app.
- **L'ancien agent est retrouvé par son contenu, jamais par son libellé**, qui contient le prénom
  réel et que la garde du lot 0 refuserait : le plist de `~/Library/LaunchAgents` dont
  `ProgramArguments[0]` vaut `/opt/macstatusd/macstatusd`. Son libellé est lu dans ce fichier au
  moment du retrait (`launchctl bootout`), puis le fichier est supprimé.
- **Le jeton existe avant l'installation** : `install.sh --preparer-jeton` le génère dans la config
  de la 0.6.0 (600) sans rien installer d'autre. Le transfert vers HA (lot 9, étape 2) a donc lieu
  avant l'installation (étape 4), qui reprend ce jeton.
- `uninstall.sh` aligné (F35) ; `config.example.json` anonyme, webhook désactivé (F09).
- `off_command` et `wake_command` : chemin absolu exécutable vérifié, code de sortie journalisé
  (F22).
- Version traçable : `install.sh` écrit un `build-info.json` (version, `git describe`), lu au
  démarrage, exposé dans `/status` et `--version`, avec l'empreinte SHA-256 du binaire au journal
  (F83).
- Commande de transfert du jeton vers HA : locale, dans `.superpowers/ops/` (C18), lancée dans un
  onglet du Terminal, sans affichage (section 7).

### Lot 7 — Documentation et notes de version

F68.

- README anglais et français réécrits ensemble, même structure : contrat HA, exemple générique
  http-webhooks, installation sans `sudo`, app d'arrière-plan et Réglages, en-tête du jeton, accès,
  nouvelles options, signature.
- `NOTES-VERSIONS.md`, pour 0.5.0 (initiale) et 0.6.0, chaque version en bloc **English** puis bloc
  **Français**. La 0.6.0 dit ce qui change à la mise à jour :
  - le jeton est exigé ;
  - l'app apparaît dans les Réglages ;
  - macOS redemande une fois l'accès au Réseau local et l'autorisation du pare-feu, puisque
    l'identité de signature change ;
  - le libellé de l'agent change.

### Lot 8 — Signature, notarisation et publication

D9, d'après la fiche de passation d'Amaran, adaptée à une app SwiftPM sans Sparkle ni `.dmg`.

- **`outils/publier.sh`** (dépôt public, anonyme) :
  - assemble l'app en version de publication, puis la signe par l'unique identité
    « Developer ID Application », trouvée par préfixe, sujet et émetteur vérifiés ;
  - runtime renforcé, horodatage, `codesign --verify --strict` ;
  - `notarytool submit --keychain-profile djoko-notarisation --wait`, puis `stapler staple` et
    `spctl -a -vv` ;
  - archive `ditto` en `.zip`.
- **Le cliquet** : hors `--repetition`, une version publiée est toujours signée par le Developer ID
  et notarisée, sinon le script refuse.
- **Masquage** : toute sortie montrée (codesign, notarytool, spctl, erreurs) remplace le nom légal et
  l'équipe par `<titulaire>` et `<equipe>`. L'exigence de signature, qui contient l'équipe, reste
  dans `build/`, ignoré par git.
- **Garde d'anonymat de l'archive** : elle lit une copie de l'app dont la signature a été retirée
  (`codesign --remove-signature`), car la signature porte légitimement le nom légal. Un retrait raté
  est refusé, et les droits de l'app sont contrôlés à part.
- **Runtime renforcé et fonctions du daemon**, à vérifier au banc, sous 27.0.1 :
  - le chargement dynamique de `login.framework` (fonction privée de l'économiseur) ;
  - le lancement de `pmset`, `caffeinate`, `open` et `killall` ;
  - le serveur HTTP et le push vers le LAN.

  Aucune exception de droits n'est posée sans preuve qu'elle manque.
- **Tests du script** : masquage, cliquet et garde, avec des violations plantées là où seule la
  garde peut les voir.
- **Répétition N-1 → N, avec Djoko** : sur le vrai Mac, passage de la version en place (ad hoc) à
  la 0.6.0 signée et notarisée. On observe :
  - la notification d'élément d'arrière-plan ajouté ;
  - l'invite « Réseau local » et celle du pare-feu ;
  - la reprise de la config et du jeton.

  Le résultat va dans `.superpowers/banc/` et alimente les notes de version.
- **Publication** sur GitHub (version 0.6.0, archive agrafée, notes bilingues), seulement sur l'accord
  explicite de Djoko (« publie 0.6.0 »), depuis un clone neuf. On vérifie ensuite en ligne : archive
  identique, `stapler validate`, `spctl`.

### Lot 9 — Déploiement coordonné

Préalable : l'accessoire « MacBook Pro » de Homebridge est retiré et le push bascule vers HA avec
la 5.0.0 (C17, section 4).

1. Version 0.6.0 terminée, testée, signée et notarisée (lot 8), non déployée.
   `install.sh --preparer-jeton` génère le jeton.
2. Préavis à la session HA, puis transfert du jeton dans `macbook_entetes` (section 7).
3. La session HA vérifie la config (`ha core check`) et redémarre HA avec l'accord de Djoko.
   L'en-tête est sans effet tant que macstatusd ne l'exige pas.
4. Installation de la 0.6.0 signée et notarisée sur le Mac (migration de l'agent et de la config,
   reprise du jeton). Djoko accepte l'invite « Réseau local » et celle du pare-feu. La session HA tire
   un nouvel identifiant de webhook (section 4), transféré vers la nouvelle config par la même
   méthode.
5. Vérification depuis HA (ON, OFF, état), puis `validate-live.sh` au banc avec Djoko.
6. La migration de config transforme l'ancienne `webhook_base_url` (déjà la cible HA) en une
   cible de `webhook_targets`. La liste à plusieurs cibles reste disponible pour plus tard.

## 7. Contrat avec Home Assistant

**Commandes.** `GET /wake` (ou `/on`) et `GET /sleep` (ou `/off`), en-tête `X-Auth-Token`.
Réponses : 200 `OK` ; 401 jeton absent ou faux ; 403 Host ou origine refusés ; 405 méthode ; 429
rafale ou trop d'échecs ; 503 config invalide. Les paramètres de requête inconnus (`?action=WAKE`)
sont ignorés.

**État, voie A (événementielle, recommandée par Claude).** macstatusd pousse
`GET <url>?accessoryId=<id>&state=true|false` à chaque changement, puis toutes les 60 s, vers chaque
cible de `webhook_targets`. Côté HA : un déclencheur webhook (`local_only: true`, GET et POST
acceptés ; macstatusd utilise GET) qui lit `state` et met à jour un `input_boolean` servant d'état
à l'interrupteur. Options `method` (GET ou POST JSON) et `headers` par cible, pour plus tard.

**État, voie B (non retenue, pour mémoire).** `POST /state` renverrait
`{"on": true|false, "reason": "…"}` à un capteur REST de HA. Elle n'est pas à construire.
`GET /state` reste `1` ou `0`.

**Homebridge.** Plus concerné par la 0.6.0 : son accessoire « MacBook Pro » est retiré avant (C17).
Le README garde un exemple http-webhooks générique (`on_headers`, `off_headers`) pour les autres
utilisateurs du dépôt.

**Jeton.** Généré sur le Mac, jamais affiché. Transfert par un onglet du Terminal, sur préavis à la
session HA :
- lecture du jeton dans la config du Mac ;
- par `ssh ha`, sauvegarde de `secrets.yaml` dans `/config/.sauvegardes-secrets` ;
- **fusion** dans le dictionnaire existant `macbook_entetes` : clé `X-Auth-Token` ajoutée ou
  remplacée, les autres en-têtes conservés ;
- vérification que le fichier se relit, puis affichage d'une seule confirmation (clé écrite,
  longueur), jamais de la valeur.

Une écriture ratée dans `secrets.yaml` empêcherait HA de démarrer : la sauvegarde précède toute
écriture, et `ha core check` précède tout redémarrage.

## 8. Vérification

- **Tests d'abord** à chaque lot : XCTest sur le socle, `selftest.sh` pour l'intégration HTTP et
  webhook (instances sur ports réservés, faux Homebridge, faux webhook HA qui répond 200 sans
  corps), sans dépendance à l'écran.
- **Le faux économiseur ne suffit pas** (leçon d'une observation ouverte : des faux outils trop
  simples ont laissé passer des défauts réels). Chaque relecture de tâche exécute aussi le nouveau
  binaire en lecture seule sur le vrai Mac (port réservé, commandes neutralisées) pour comparer ses
  faits à ceux de l'instance réelle.
- **Mesure d'efficience** avant et après le lot 5, avec la même méthode que l'audit (coût par tick,
  écran allumé et éteint).
- **Banc avec Djoko** :
  - lot 4 (économiseur lancé par l'inactivité, deux économiseurs) ;
  - lot 8 (répétition N-1 → N de l'app signée et notarisée, invites du système) ;
  - `validate-live.sh` complet ;
  - bout en bout depuis HA (lot 9).
- **Signature** : `codesign --verify --strict`, `stapler validate` et `spctl` sur l'app (« Notarized
  Developer ID »), et garde d'anonymat de l'archive qui ne trouve rien. Rien de tout cela ne montre
  le nom légal ni l'équipe.
- **Relecture finale par Opus** avant le report sur `main`.

## 9. Traitement de chaque constat confirmé

| Constat | Lot | Traitement |
|---|---|---|
| F01 commandes sans authentification | 2, 6 | Corrigé : C4, C5, C6 |
| F02 CSRF et DNS rebinding | 2 | Corrigé : C7 |
| F03 économiseur lancé par l'inactivité | 4 | Corrigé après banc |
| F04 pas d'OFF à l'arrêt | 3 | Corrigé |
| F05 exception sur écriture du journal | 3 | Corrigé |
| F06 `/status` public | 2 | Corrigé : C5 |
| F07 commandes non fusionnées ni limitées | 2 | Corrigé : C8 |
| F08 pas de plafond de connexions | 2 | Corrigé |
| F09 exemple de config réel | 6 | Corrigé |
| F10 `sudo chown -R` | 6 | Supprimé avec C2 |
| F11 réveil qui efface la commande | 3 | Corrigé |
| F12 OFF avant veille non garanti | 3 | Corrigé |
| F13 bascule rapide ignorée | 3 | Corrigé : C8 |
| F14 écran rendormi après un ON verrouillé | 3 | Adapté : C12 |
| F15 écran rallumé par macOS | — | Décliné : C11 |
| F16 écran fantôme | 4 | Corrigé |
| F17 paire didstop/didstart forgée | 4 | Corrigé |
| F18 config invalide | 3 | Corrigé |
| F19 seconde instance qui publie | 3 | Corrigé |
| F20 pas de réessai après abandon | 3 | Corrigé |
| F21 listener en attente | 3 | Corrigé |
| F22 échecs des commandes de remplacement | 6 | Corrigé |
| F23 pas de tests du moteur | 1 | Corrigé : C14 |
| F24 selftest dépendant de l'écran | 1 | Corrigé |
| F25 jeton en query string, config lisible | 2, 6 | Corrigé : C2, C6 |
| F26 refus non journalisés | 2 | Corrigé |
| F28 injection dans le journal | 2 | Corrigé |
| F29 URL du webhook journalisée | 3, 6 | Corrigé |
| F30 une seule archive de journal | 3 | Corrigé |
| F32 message d'écoute inexact | 2 | Corrigé |
| F35 `uninstall.sh` sans garde-fou | 6 | Corrigé |
| F36 sonde dans `/tmp` fixe | 4, 6 | Corrigé |
| F39 attente bloquante avant veille | 3 | Corrigé |
| F43 ON sur Mac déjà ON | 3 | Corrigé : C8 |
| F44 `reason` figé | 5 | Corrigé |
| F46 didstart orphelin | 4 | Corrigé |
| F50 pas de source indépendante pour l'écran | 4 | Corrigé |
| F53 confirmation sur tout 2xx | 3 | Adapté : C9 |
| F54 réponse sans limite | 3 | Corrigé |
| F55 réessais périmés | 3 | Corrigé |
| F57 refus « Réseau local » indiscernable | 3 | Corrigé |
| F61 journal sans `O_APPEND` | 3 | Corrigé |
| F62 valeurs corrigées en silence | 3 | Corrigé |
| F63 vérification d'installation | 6 | Corrigé |
| F64 CLI | 3 | Corrigé |
| F66 `validate-live` et rotation | 1 | Corrigé |
| F67 scénarios d'échec non testés | 1, 4 | Corrigé |
| F68 contrat du README | 7 | Corrigé (HA et Homebridge) |
| F69 options TCP | 2 | Corrigé |
| F70 code mort | 5 | Corrigé |
| F71 détection de changement toujours vraie | 5 | Corrigé |
| F72 battement de cœur en INFO | 3 | Corrigé |
| F74 réveils traités plusieurs fois | 3 | Corrigé |
| F75 scan de tous les process | 5 | Corrigé |
| F76 double lecture de session | 5 | Corrigé |
| F78 service HID recherché à chaque tick | 5 | Corrigé |
| F79 analyseur permissif | 2 | Corrigé |
| F80 `/opt` sans intégrité | 6 | Corrigé : C2 |
| F81 contrats de files | 1 | Corrigé |
| F83 version non traçable | 6 | Corrigé |
| F88 ON non sollicités | — | Hors code : C13 |
| F89 battement de cœur en écriture | — | Décliné : C10 |
| F90 topologie des écrans | 5 | Corrigé |

## 10. Laissé au constructeur

- Découpage exact des fichiers et des types dans `MacStatusCore`, noms internes, organisation des
  tests.
- Paramètres fins non fixés ici (taille des seaux, délais de repli), dans l'esprit des valeurs
  données.
- Forme des messages de journal.

## 11. Questions ouvertes

Aucune. Réglées le 25/10 :
- par Djoko : historique recréé (D4), version 0.6.0 (D7), identifiant `com.djoko.macstatusd` (D8),
  signature et notarisation (D9) ;
- avec la session HA : source d'état (voie A, D5), forme de l'adresse (IPv4 littérale), sort de
  Homebridge (D6).

Reste à valider par Djoko en cours de route, sans bloquer le plan : l'icône de l'app (lot 6).

Ouvertes le 09/11/2026, pour après la 0.6.0 (constats des essais de R85, registre du plan 4) :
- **Gels du processus, Mac éveillé.** Le daemon voit des « interruption de 20 à 33 s détectée » sans veille qui les
  couvre, et les lectures en cours durent autant. Cause inconnue : processus suspendu ou système bloqué. C'est la
  piste restante pour le blocage de 6,9 s de B6, qui ne s'est pas reproduit en quatre essais.
- **Accusé de veille en retard.** À une veille du 09/11, le noyau a noté le daemon lent à accuser l'avis de veille
  (4,8 s et 6,4 s), alors que le daemon l'autorise 1 ms après l'avoir reçu : l'avis lui arrive en retard.
- **Retard d'entrée en veille d'environ 30 s.** Le plus souvent, une app tierce laisse expirer l'avis de veille (banc 2).
  Une fois, le retard est resté sans elle (essai 4 de R85) : cause inconnue. Le daemon n'y est pour rien.
