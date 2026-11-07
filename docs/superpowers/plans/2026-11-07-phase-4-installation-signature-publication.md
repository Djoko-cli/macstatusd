# Plan 4 — Installation, documentation, signature et publication (lots 6 à 8), reliquats du banc 2

> **Pour les agents qui exécutent :** sous-compétence requise, `superpowers:subagent-driven-development`
> (recommandée) ou `superpowers:executing-plans`, tâche par tâche. Les étapes se cochent (`- [ ]`).

**But :** macstatusd 0.6.0 s'installe sans `sudo`, comme une app d'arrière-plan visible et réglable dans les
Réglages Système. Il est documenté en anglais et en français, signé par le Developer ID de Djoko, notarisé et
publié sur GitHub. Avant cela, trois reliquats du banc 2 : OFF par la commande native de l'économiseur (R84),
ON sans retard au réveil (R85) et les mineurs parqués.

**Architecture :**
- `macstatusd.app` (`LSUIElement`) vit dans `~/Applications`. Elle porte le plist de son agent
  (`Contents/Library/LaunchAgents/com.djoko.macstatusd.plist`, clé `BundleProgram`) et l'enregistre par
  `SMAppService.agent(plistName:)`. Les chemins :
  - la config (600) et le marqueur `restart-pending` sous `~/Library/Application Support/<nom>` ;
  - les journaux sous `~/Library/Logs/<nom>`.

  `<nom>` vient de l'`Info.plist` (clé `MacstatusdSupportName`) : une app d'essai ou de répétition ne lit
  jamais la vraie config.
- Les règles testables sont des fonctions pures de `MacStatusCore` : chemins, version de compilation,
  validation des commandes de remplacement, état d'enregistrement, mode de lancement, appels lents, lectures
  tolérantes aux blocages. L'exécutable garde ServiceManagement, login.framework, CryptoKit et AppKit.
- Les scripts se testent par des bancs bash hermétiques :
  - un `HOME` d'essai ;
  - de faux `launchctl`, `sudo`, `curl` et `open` en tête du `PATH` ;
  - une app d'essai dont le binaire note ses arguments.

  `outils/publication.py` (Python 3.9, bibliothèque standard) reprend les fonctions génériques du module
  d'Amaran, et se teste par `unittest`.

**Outils :**
- Swift 6.4 (`swift-tools-version: 5.9`, mode de langage 5), XCTest, ServiceManagement, CryptoKit ;
- bash et `/usr/bin/python3` 3.9.6 ;
- `codesign`, `xcrun notarytool`, `xcrun stapler`, `spctl`, `ditto`, `iconutil` et `sips`.

Tous ces outils sont présents (vérifié le 07/11).

**Spec :** `docs/superpowers/specs/2026-10-25-correctifs-audit-design.md`. Les parties concernées :
- les lots 6, 7 et 8 (§6) ;
- les décisions C2 à C4, C16, C18, C20, C22, D7 à D9 ;
- §7 (jeton) et §8 (vérification) ;
- §9 : F09, F10, F22, F25, F29, F35, F36, F63, F68, F80 et F83.

Sources locales, ignorées par git. Elles portent des mesures réelles : n'en recopier aucune valeur.
- Registre du plan 3, `.superpowers/sdd/2026-10-31-phase-3-economiseur-efficience/progress.md` : R84 à R88, et la
  rubrique « Pour le README (plan 4) ».
- Relectures du même dossier : `task-3-review.md` (section « Mineur (8) ») et `task-5-review.md` (M4).
- Banc 2 : `.superpowers/banc/banc-2-2026-11-06/resultats.md` (A6, B6) et `soir/daemon-banc.log`.
- Constats de l'audit : `.superpowers/audit/audit-2026-09-25.md` (chercher `## Fnn`).
- Fiche de passation d'Amaran, hors dépôt : `~/Dev/amaran/.superpowers/notarisation/passation-developer-id.md`.

**Hors de ce plan (plan 5, lot 9) :**
- La commande de transfert du jeton vers HA (C18). Elle ne sert qu'à l'étape 2 du lot 9, et sa forme dépend de
  `secrets.yaml`, que seule la session HA connaît. Écrite à l'aveugle, elle risquerait d'empêcher HA de
  démarrer.
- La migration réelle du Mac de Djoko.
- La valeur réelle de `saver_redisplay_idle_seconds` (R62).

## Contraintes globales

- Cible `.macOS(.v13)`, aucune dépendance externe. Commentaires, journaux et sorties en français.
- **Anonymat** : aucun identifiant réel dans le code, les tests, la doc ou les commits. Valeurs d'essai inventées
  et reconnaissables :
  - jeton `00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff` ;
  - identifiants `com.djoko.macstatusd.essai` et `com.djoko.macstatusd.repetition` ;
  - faux titulaire « Prénom Nom » et fausse équipe `ABCDE12345` ;
  - hôtes `192.0.2.x` ;
  - chemins `/private/tmp/…` ou `/home/exemple/…`, jamais `/Users/<nom>`.

  Garde `pre-push` installée, `--no-verify` interdit.
- **Signature** :
  - Le nom légal et l'équipe ne figurent que dans la signature d'une version publiée.
  - Toute sortie de `codesign`, `security`, `notarytool`, `spctl`, `stapler` et `log` passe par un masque par la
    forme, après retrait des échappements `\=` : `\([A-Z0-9]{10}\)`, `[A-Z0-9]{10}\.` en tête d'un identifiant,
    `[0-9A-Fa-f]{40}`, le libellé qui suit `Developer ID Application:`, `Apple Development:` ou
    `Apple Distribution:`, et les adresses e-mail.
  - Dans une session de Claude : `… 2>&1 | ~/.claude/outils/masquer`.
  - Un seul certificat « Developer ID Application » dans le trousseau, choisi par ce préfixe (compte vérifié le
    07/11 : 1). Un seul profil de notarisation, `djoko-notarisation`.
  - L'exigence de signature, et tout ce qui porte l'équipe, restent sous `build/`, ignoré par git.
- **Secrets** :
  - Le jeton n'est jamais affiché, ni journalisé, ni mis dans une URL.
  - Il est fait de 32 octets aléatoires en hexadécimal.
  - Son fichier est créé vide, passé en 600, puis écrit. Ses droits se relisent ensuite par `stat -f %Lp`.
  - Un test qui vérifie l'absence du jeton dans une sortie compte ses occurrences sans jamais l'imprimer
    (`grep -c -F`), y compris dans son message d'échec.
- **Instance réelle intouchée** pendant tout le plan. Sur `127.0.0.1:9090`, seulement `GET /state`, `/status` et
  `/health`. Rien sous `/opt/macstatusd`, dans sa config ou dans son agent. Rien non plus dans
  `~/Library/Application Support/macstatusd`, ni dans `~/Applications/macstatusd.app`. Les essais avec Djoko
  utilisent l'identité d'essai (`com.djoko.macstatusd.essai`) ou celle de répétition
  (`com.djoko.macstatusd.repetition`), avec leurs propres dossiers.
- **Aucun test automatique** :
  - n'appelle `SMAppService.register()` ni `unregister()` : ils changent les Réglages de Djoko ;
  - n'appelle `SACScreenSaverStartNow` ni `SACScreenSaverStopNow` ;
  - ne rallume l'écran, ne lance ni n'écarte l'économiseur, ne met le Mac en veille.

  Les scripts se testent dans un `HOME` d'essai sous `/private/tmp/macstatusd-plan4/`, avec de faux outils en
  tête du `PATH`.
- **Instances d'essai** :
  - écoute sur `127.0.0.1`, `--port` de la plage 19000–19999 en ligne de commande ;
  - `off_command` et `wake_command` à `["/usr/bin/true"]`, `off_escalate_to_display_sleep: false`,
    `stop_screensaver_on_wake: false`, jeton d'essai ;
  - `CFFIXED_USER_HOME` et `MACSTATUSD_SUPPORT_DIR` sous `/private/tmp/macstatusd-plan4/` ;
  - arrêt par PID.

  Config d'essai préparée par le contrôleur avant la tâche 1 : `.superpowers/banc/config-essai-plan4.json` (hors
  de `/private/tmp`, que le système purge).
- Jamais de `pkill`, `killall` ni `kill` par motif de nom.
- Un process lancé par launchd ne lit ni n'écrit rien sous `~/Documents` (TCC) : un agent de banc range son
  binaire, sa config et son journal sous `~/Library/Application Support/<nom du banc>`.
- Selftest toujours ainsi, `/health` de l'instance réelle contrôlé avant et après, jamais avec
  `SELFTEST_FAUX_ECONOMISEUR=1` :
  `SELFTEST_IGNORER_VERROU=1 SWIFT_SCRATCH=/private/tmp/macstatusd-plan4/selftest bash scripts/selftest.sh`.
- `swift build` et `swift test` toujours avec `--scratch-path /private/tmp/macstatusd-plan4/build`.
- Aucun réglage du système modifié (`defaults write`, `pmset` en écriture).
- Aucun envoi hors de `127.0.0.1` pendant les tests. Hors des tests, deux exceptions :
  - la notarisation (tâches 10 et 11) envoie l'app à Apple (D9) ;
  - le banc 3 (tâche 10) envoie à l'adresse de réseau local du Mac lui-même.

  Aucun push avant l'accord « publie 0.6.0 » (tâche 11).
- `macstatusdVersion` reste `"0.6.0-dev"` jusqu'à la tâche 11.
- Python : version 3.9 (pas de `match`), bibliothèque standard. Tests par `python3 -m unittest`, jamais pytest,
  absent du Mac.
- Scripts : `#!/bin/bash`, lancés par `bash`, chaque expansion de chemin entre guillemets.
- Chaque commit finit par la ligne `Co-Authored-By:` du modèle qui l'écrit. Auteur et committer en noreply.
- Les README changent à la tâche 9. Avant, chaque changement visible va au registre du plan 4, rubrique « Pour
  le README » : clé, défaut, champ de `/status`, option de la CLI, message.
- **Relecture de chaque tâche** : en plus des tests, le relecteur lance une fois le nouveau binaire en lecture
  seule et compare ses faits à `curl -s 127.0.0.1:9090/status` :
  `CFFIXED_USER_HOME=/private/tmp/macstatusd-plan4/home MACSTATUSD_SUPPORT_DIR=/private/tmp/macstatusd-plan4/support "$(swift build --scratch-path /private/tmp/macstatusd-plan4/build --show-bin-path)/macstatusd" --once --port 19390 --config .superpowers/banc/config-essai-plan4.json`.

## Points de vigilance

1. **Migration d'une installation ancienne.** L'ancienne config de `/opt` est en 644, appartient à root, n'a pas
   de jeton et porte `webhook_base_url`. Attendu :
   - une config neuve en 600, avec un jeton généré ;
   - `webhook_targets` repris de l'ancienne URL ;
   - l'ancien agent retiré, retrouvé par son contenu et non par son libellé ;
   - un leurre au libellé voisin laissé en place.

   Cas `migration` et `leurre` de `outils/tests/test-install.sh` (tâche 7).
2. **Relance d'`install.sh`, ou mise à jour.** Attendu :
   - le jeton, la config et l'enregistrement sont gardés ;
   - `restart-pending` est posé avant le remplacement de l'app (C16), donc pas d'aller-retour OFF puis ON.

   Cas `relance` (tâche 7).
3. **Agent coupé par Djoko dans les Réglages.** Attendu :
   - `--status-service` dit où le réactiver ;
   - `install.sh` le dit aussi, sans appeler `register()` en boucle ;
   - `/status` le montre.

   Tests `test_etatDuService_aApprouver_ditOuLeReactiver` et `test_status_porteLEtatDuService` (tâche 6), cas
   `a-approuver` (tâche 7).
4. **Le jeton ne s'affiche nulle part** : ni par `--preparer-jeton`, ni par `install.sh`, `--status-service`,
   `/status`, le journal, les erreurs ou la publication. Cas `jeton-cache` (tâche 7), tests de la tâche 8,
   contrôle du banc 3 (tâche 10).
5. **Runtime renforcé de l'app notarisée.** Il doit garder intacts :
   - le chargement de login.framework ;
   - le lancement de `pmset`, `caffeinate`, `open` et `killall` ;
   - l'écoute HTTP et l'envoi vers le réseau local.

   Sans quoi la version publiée perdrait l'économiseur en silence. Étape « runtime » du banc 3 (tâche 10) :
   `/status` doit dire `saver_detection` = `sac`, `saver_dismissal` = `SACScreenSaverStopNow` et `saver_start` =
   `SACScreenSaverStartNow`.

Ordre : tâches 1 à 11, dans l'ordre. Djoko est requis :
- tâche 2, étape 3 ;
- tâche 5, étape 5 ;
- tâche 6, étape 1 ;
- toute la tâche 10 ;
- tâche 11, étapes 5 à 9.

---

## Reliquats du banc 2

### Tâche 1 : OFF par la commande native de l'économiseur (R84)

**Fichiers :**
- Modifier : `Sources/MacStatusCore/Commands.swift` (énumération et protocole `CommandActions`)
- Modifier : `Sources/macstatusd/PowerActions.swift` (`startScreenSaver()`, résolution du symbole)
- Modifier : `Sources/MacStatusCore/EngineCore.swift` (journal de démarrage, `/status`), `Sources/macstatusd/main.swift` (`--once`)
- Tests : `Tests/MacStatusCoreTests/EngineCoreSaverTests.swift`, `Tests/MacStatusCoreTests/Support/Fakes.swift`

**Interfaces :**
- Produit :
  - `public enum ScreenSaverStart: String { case native = "SACScreenSaverStartNow"; case openApp = "open -a ScreenSaverEngine" }` ;
  - `var screenSaverStart: ScreenSaverStart { get }` dans `CommandActions` ;
  - un champ `saver_start` dans `/status` et dans `--once`.

**Fait vérifié :** `SACScreenSaverStartNow` a la forme `@convention(c) () -> Int32`. Au banc 2 (A6),
`.superpowers/banc/outils/saver-ctl.swift demarrage` l'a appelée et a obtenu 0. Ont suivi un `didstart` avec
`runFromPref`, puis le verrou, comme après l'inactivité.

- [x] **Étape 1 : tests rouges**
  - `test_demarrage_annonceLeMoyenDeDemarrage_natif` : `FakeActions.screenSaverStart = .native`. Attendu :
    - le journal contient l'INFO « économiseur : moyen de démarrage SACScreenSaverStartNow (commande du système) » ;
    - `statusSnapshot()["saver_start"]` vaut `"SACScreenSaverStartNow"`.
  - `test_demarrage_sansStartNow_annonceLeRepli` : `.openApp`. Attendu :
    - le WARN « SACScreenSaverStartNow indisponible → repli open -a ScreenSaverEngine » ;
    - `saver_start` vaut `"open -a ScreenSaverEngine"`.
- [x] **Étape 2 :** `swift test --scratch-path /private/tmp/macstatusd-plan4/build --filter EngineCoreSaverTests`.
  Attendu : échec de compilation, `screenSaverStart` inconnu.
- [x] **Étape 3 : mise en œuvre**
  - Dans le moteur, l'annonce de démarrage s'écrit à côté de celle du moyen d'écartement
    (`EngineCore.swift`, vers la ligne 207). Elle s'ajoute aussi à `statusSnapshot()` et à `--once`.
  - Dans `PowerActions`, le symbole se résout une fois, à la création, par `LoginFramework.symbol`, comme
    `SACScreenSaverStopNow`. `startScreenSaver()` appelle la fonction sur `queue`, avec trois sorties :
    - code 0 : INFO « économiseur: SACScreenSaverStartNow appelé (code 0) » ;
    - code ≠ 0 : WARN « économiseur: SACScreenSaverStartNow a rendu le code N → repli open -a ScreenSaverEngine »,
      puis `open -a` ;
    - symbole absent : `open -a`, comme aujourd'hui.

  La règle « session déjà verrouillée → extinction de l'écran » de `requestOff` reste telle quelle. Son
  comportement avec la commande native se vérifie au banc 3.
- [x] **Étape 4 :** suite complète (`swift test --scratch-path /private/tmp/macstatusd-plan4/build`). Attendu : tout
  vert, 524 tests et plus.
- [x] **Étape 5 :** registre du plan 4, rubrique « Pour le README » : moyen de démarrage, champ `saver_start`,
  messages. Puis commit « Plan 4 : OFF par SACScreenSaverStartNow, repli open -a (R84) ».

**Contrôle du relecteur :** lire `startScreenSaver()` en entier, avec ses trois sorties (code 0, code ≠ 0, symbole
absent). Le comptage réel des appels se fait au banc 3 (tâche 10, étape R84), Djoko présent : une erreur
d'interposition y serait sans dommage.

### Tâche 2 : ON sans retard après un réveil (R85)

**Constat du banc 2 (B6), à lire dans `soir/daemon-banc.log` entre 00:18:29 et 00:18:39 :**
- Le trou couvert par la veille termine la veille (`noteWake`), et les faits disent bientôt « écrans allumés,
  écran verrouillé ».
- L'avis de NSWorkspace, dont l'évaluation est immédiate, ne publie pourtant pas ON. Le moteur n'écrit rien
  pendant 6,9 s, alors que le moniteur réseau, lui, journalise. Il reprend juste après « écrans : » avec les
  trois écrans, et ON part dans la même milliseconde que l'avis d'IOKit.

Hypothèse : une lecture du système bloque la file du moteur, le temps que le serveur de fenêtres rende les
écrans externes. Ce peut être `displaySnapshot()` (CoreGraphics), `session()` ou `secureInputActive()`
(`CGSessionCopyCurrentDictionary`). C'est **à mesurer sur la machine avant le correctif** (étapes 1 à 3).

**Fichiers :**
- Créer : `Sources/MacStatusCore/SlowCalls.swift`, `Sources/MacStatusCore/CachedSignals.swift`
- Modifier : `Sources/MacStatusCore/EngineCore.swift` (mesure des lectures de `refreshFacts()`, `/status`, événement
  `.signalsRefreshed`), `Sources/MacStatusCore/Commands.swift` (`SystemEvent`)
- Modifier : `Sources/macstatusd/EngineRunner.swift` (câblage : exécuteur d'arrière-plan, poste de l'événement)
- Tests : `Tests/MacStatusCoreTests/SlowCallsTests.swift`, `Tests/MacStatusCoreTests/CachedSignalsTests.swift`,
  `Tests/MacStatusCoreTests/EngineCoreSaverTests.swift`

**Interfaces :**
- Produit, étape 1 :
  - `public final class SlowCallMonitor`, avec `init(clock: Clock, log: …, threshold: Double = 1.0, warnEvery: Double = 60)`,
    `func measure<T>(_ name: String, _ body: () -> T) -> T` et `var snapshot: [String: [String: Any]]` ;
  - le WARN « appel lent : <nom> <durée> s (seuil 1.0 s) », au plus une fois par nom et par `warnEvery` ;
  - `snapshot` donne `{"<nom>": {"count": n, "max_seconds": x}}` pour les appels au-delà du seuil. C'est le champ
    `slow_calls` de `/status`.
  - Noms mesurés : `session`, `ecrans`, `saisie_securisee`, `inactivite_hid`, `economiseur` (le verdict de
    l'oracle, donc SAC et les hôtes).
- Produit, étape 5 :
  - `public protocol BackgroundRunner { func run(_ work: @escaping () -> Void) }` ;
  - `public final class CachedSignals: SystemSignals`, qui enveloppe un `SystemSignals` et un `BackgroundRunner`,
    avec `cached: Set<String>` (les noms désignés par la mesure) et un rappel `onRefreshed: () -> Void`.
  - Une lecture désignée rend la dernière valeur connue sans attendre. Elle lance une relecture sur le
    `runner`, sauf si une relecture est déjà en cours. À la fin de celle-ci, la valeur est gardée et
    `onRefreshed()` part une fois.
  - La toute première lecture est synchrone, car il n'existe encore aucune valeur. Les autres lectures passent
    telles quelles.
  - `SystemEvent.signalsRefreshed` donne, dans le moteur, `refreshFacts()` puis `evaluate(immediate: false)`.

- [x] **Étape 1 : mesure des lectures, tests rouges puis verts**
  - `test_appelLent_auDelaDuSeuil_avertitAvecSonNomEtSaDuree` : le faux `displaySnapshot` avance l'horloge
    d'essai de 7 s. Attendu : un WARN qui contient « appel lent : ecrans 7.0 s », et `slow_calls.ecrans.count`
    vaut 1.
  - `test_appelSousLeSeuil_rienAuJournal` : 0,5 s, aucun WARN, aucune entrée dans `slow_calls`.
  - `test_appelsLentsRepetes_unSeulAvertissementParMinute` : trois appels lents en 10 s donnent un WARN et un
    `count` de 3.

  Mise en œuvre : chaque lecture de `refreshFacts()` passe par `measure`. Commit « Plan 4 : mesure des lectures
  lentes du moteur (R85, étape de mesure) ».
- [ ] **Étape 2 :** binaire du banc recompilé dans `.superpowers/banc/bin/macstatusd-tete`. Agent du banc repris du
  banc 2 (`.superpowers/banc/agent-banc-2-session.plist`, config `config-banc-2-session.json`, récepteur sur
  127.0.0.1), préparé par le contrôleur.
- [ ] **Étape 3 : mesure avec Djoko** (5 min). Veille par le menu Pomme, 60 s d'attente, puis réveil au clavier.
  Relevé : les lignes « appel lent » et l'écart entre les faits « écrans allumés » et « état OFF → ON ». Le résultat
  va au registre, avec la décision :
  - **une lecture désignée** (≥ 1 s pendant le trou) : elle passe derrière `CachedSignals` (étapes 4 à 7) ;
  - **aucune** : arrêt de la tâche. Le contrôleur reprend le diagnostic, avec la méthode de débogage de Djoko, et le plan est
    amendé avant toute suite.
- [ ] **Étape 4 : tests rouges de `CachedSignals`**
  - `test_premiereLecture_synchrone` ;
  - `test_lectureSuivante_rendLaValeurGardee_etUneSeuleRelecture`, avec trois lectures pendant une relecture en
    cours ;
  - `test_finDeRelecture_valeurNeuve_etRappelUneFois` ;
  - `test_lectureNonDesignee_passeTelleQuelle`.

  Tous avec un `BackgroundRunner` d'essai, que le test vide à la main.
- [ ] **Étape 5 :** mettre en œuvre `CachedSignals`, puis le câbler dans `EngineRunner`. Le `runner` est une file
  série par lecture désignée, et `onRefreshed` poste `.signalsRefreshed` sur la file du moteur.
- [ ] **Étape 6 : test moteur de la séquence de B6, rouge sur le code de l'étape 1**
  `test_reveil_lectureDesEcransLente_ONDansLeLissage`. Il rejoue, dans l'ordre :
  - l'avis de veille ;
  - le trou couvert ;
  - un tick aux écrans allumés et à la session verrouillée ;
  - l'avis NSWorkspace, pendant que la lecture désignée « bloque » (relecture en attente dans le `runner`).

  Attendu : ON publié au plus `settle_on_ms` après l'avis, avant toute fin de relecture et avant l'avis d'IOKit.
  Mutation à rejouer : `cached` vide. Le test doit échouer, ON n'arrivant qu'après la relecture.
- [ ] **Étape 7 :** suite complète, puis selftest des contraintes globales, écran allumé. Registre : champ
  `slow_calls` et message « appel lent ». Commit « Plan 4 : lecture hors file de <nom>, ON sans attendre la fin du
  réveil (R85) ».

**Contrôle du relecteur :** concurrence.
- Toute valeur de `CachedSignals` se lit et s'écrit sur une seule file. Une relecture n'est jamais doublée.
- Aucun appel désigné ne reste synchrone sur la file du moteur. La vérification se fait par un `grep` des appels
  à `signals.` dans `EngineCore.swift`, avec un tableau de chaque appel et du chemin qu'il prend.
- Le banc 3 confirme (tâche 10, étape R85).

### Tâche 3 : mineurs parqués du plan 3 (M6, R88, R86)

**Fichiers :** `Sources/MacStatusCore/EngineCore.swift`, `Sources/MacStatusCore/ScreenSaverOracle.swift`, tests du
moteur (`EngineCoreTests.swift`, `EngineCoreSaverTests.swift`).

- [x] **Étape 1 : M6 (R75), `/resync` ne doit plus effacer l'avis d'extinction**
  - Test rouge `test_resync_gardeLAvisDExtinction_avecEcranVirtuelEveille` :
    - avis `screensDidSleep`, écrans physiques éteints, fantôme éveillé ;
    - puis `resync()`.

    Attendu : OFF `display-asleep` tenu, aucune publication forcée de ON.
  - Correctif : retirer `screensAsleepNotified = false` de `resync()`. `refreshFacts()` l'efface déjà quand aucun
    écran physique n'est éteint.
  - Mutation : remettre la ligne. Le test échoue.
- [x] **Étape 2 : R88.** À `ScreenSaverOracle.swift`, vers la ligne 192, l'âge mural d'un hôte se compare à un
  instant hors veille. C'est juste tant que l'attente d'un `didstart` (5 s) ne traverse aucune veille, et
  `noteSystemWake()` l'oublie.
  - Écrire cet invariant en commentaire à cette ligne.
  - Figer le test `test_veilleApresDidstart_attenteOubliee_hoteAncienNeCorroborePas`, s'il n'existe pas déjà
    sous un autre nom. La recherche se fait par `grep -n 'noteSystemWake' Tests/`.
  - Le test se prouve par mutation : retirer l'oubli dans `noteSystemWake()`.
- [x] **Étape 3 : R86.**
  - `réaffiché` absent de la ligne INFO de la transition : test sur une transition causée par le retour de
    l'économiseur, la ligne doit contenir « réaffiché ».
  - Mineurs m4, m5 et m8 de `task-3-review.md`, section « Mineur (8) ».
  - M4 de `task-5-review.md` : déclencheurs de réveil écrits deux fois, que la scission a pu déplacer, à
    retrouver par `grep`.

  Chacun est corrigé, ou écarté avec sa raison au rapport.
- [x] **Étape 4 :** suite complète. Un commit par point (M6, R88, R86).

---

## Lot 6 — Installation et exécution

### Tâche 4 : chemins de l'espace utilisateur, version traçable, commandes de remplacement (C2, F22, F83)

**Fichiers :**
- Créer : `Sources/MacStatusCore/SupportPaths.swift`, `Sources/MacStatusCore/BuildInfo.swift`,
  `Sources/MacStatusCore/CommandOverride.swift`
- Modifier : `Sources/MacStatusCore/Version.swift` (retirer la constante `macstatusdConfigPath = "/opt/macstatusd/config.json"`),
  `Sources/MacStatusCore/Shutdown.swift` (dossier de support), `Sources/MacStatusLog/Log.swift` (chemin par défaut),
  `Sources/MacStatusCore/Config.swift` (validation de `off_command`, `wake_command`), `Sources/macstatusd/main.swift`
  (`--help`, `--version`, empreinte au démarrage), `Sources/macstatusd/PowerActions.swift` (code de sortie),
  `Sources/MacStatusCore/EngineCore.swift` (`/status`)
- Tests : `Tests/MacStatusCoreTests/SupportPathsTests.swift`, `BuildInfoTests.swift`, `ConfigTests.swift`

**Interfaces :**
- Produit, `SupportPaths` :
  - `public struct SupportPaths: Equatable { public let name, support, config, logs: String }` ;
  - `public static func resolve(environment: [String: String], bundleSupportName: String?, home: String) -> SupportPaths` :
    - `name` vaut `bundleSupportName` s'il est non vide, sans `/` et différent de `.` et de `..`, sinon
      `"macstatusd"` ;
    - `support` vaut `MACSTATUSD_SUPPORT_DIR` s'il est non vide, sinon `home + "/Library/Application Support/" + name` ;
    - `config` vaut `support + "/config.json"`, et `logs` vaut `home + "/Library/Logs/" + name` ;
  - `bundleSupportName` se lit dans `Bundle.main` (clé `MacstatusdSupportName`, posée par la tâche 5).
- Produit, `BuildInfo` :
  - `public struct BuildInfo: Equatable { public let version, git, builtAt: String }`, avec
    `public static func parse(_ data: Data?) -> BuildInfo` (fichier `Contents/Resources/build-info.json`) et
    `public var versionLine: String` ;
  - `versionLine` donne « macstatusd 0.6.0-dev (git v0.5.0-90-g1234567, 2026-11-07) », ou « macstatusd 0.6.0-dev
    (compilation inconnue) » quand le fichier manque ou est illisible ;
  - dans `/status`, le champ `build`, `{"git": …, "built_at": …}`.
- Produit, `CommandOverride` :
  - `public static func validate(_ argv: [String], label: String, isExecutable: (String) -> Bool) -> (argv: [String], warning: String?)` ;
  - un `argv` vide reste vide, sans avertissement ;
  - un `argv[0]` relatif ou non exécutable donne `[]` et l'avertissement « off_command ignoré : <chemin échappé>
    n'est pas un chemin absolu exécutable » (ou « wake_command … »).

- [x] **Étape 1 : tests rouges**
  - `test_cheminsParDefaut_sousLeDossierPersonnel`, `test_variableDeSupport_lEmporte`,
    `test_nomDuPaquet_donneLesDossiers` (`macstatusd-essai`) et `test_nomInvalide_retombeSurMacstatusd` (`../x`,
    `a/b`, `""`) ;
  - `test_buildInfo_valide`, `test_buildInfo_absent_compilationInconnue`, `test_buildInfo_illisible_compilationInconnue` ;
  - `test_offCommandRelatif_ignoreAvecAvertissement`, `test_offCommandNonExecutable_ignore`,
    `test_offCommandAbsoluExecutable_garde` (`/usr/bin/true`).
- [x] **Étape 2 :** mise en œuvre.
  - Le chemin de config par défaut devient `SupportPaths.config`. Le marqueur et le journal suivent `SupportPaths`.
    `--help` montre le chemin résolu.
  - `--version` imprime `versionLine`.
  - Au démarrage, une ligne INFO « binaire : sha256 <64 hex> » (CryptoKit, sur `Bundle.main.executableURL`).
  - Dans `PowerActions.launch`, un `terminationHandler` journalise le code de sortie : INFO « <libellé> terminé
    (code 0) », WARN si le code est différent. Stdout et stderr restent jetés.
- [x] **Étape 3 : contrôles par `grep`**
  - F29 côté config : aucune sortie d'`install.sh`, de `--once` ou du journal de démarrage ne montre une URL de
    webhook.
  - F36 : `grep -rn '/tmp/' scripts diagnostics outils` ne trouve que des `mktemp`.
- [x] **Étape 4 :** suite complète, selftest (le chemin par défaut a changé, et le selftest passe `--config` à
  chaque instance), registre. Commit « Plan 4 : chemins de l'espace utilisateur, version traçable, commandes de
  remplacement vérifiées (C2, F22, F83) ».

### Tâche 5 : le paquet de l'app et son icône (C20, C22)

**Fichiers :**
- Créer : `outils/assembler-app.sh`, `outils/app/Info.plist` (gabarit), `outils/app/en.lproj/InfoPlist.strings`,
  `outils/app/fr.lproj/InfoPlist.strings`, `outils/app/agent.plist` (gabarit de l'agent),
  `outils/icone/dessiner-icone.swift`, `outils/icone/AppIcon.icns`, `outils/tests/test-assembler-app.sh`
- Modifier : `.gitignore` (ajouter `build/` : `git check-ignore build/x` ne trouve rien le 07/11)

**Interfaces :**
- Produit, `outils/assembler-app.sh` :
  - options `[--binaire <chemin>] [--identifiant <id>] [--nom-support <nom>] [--sortie <dossier>] [--icone <icns>] [--signer <identité>|-]`.
    Défauts : compilation `swift build -c release`, `com.djoko.macstatusd`, `macstatusd`, `build/app`,
    `outils/icone/AppIcon.icns` et signature ad hoc (`-`) ;
  - le nom de l'app est `macstatusd.app`, ou `macstatusd-<suffixe>.app` pour `com.djoko.macstatusd.<suffixe>`.
    Le script imprime le chemin de l'app sur sa dernière ligne.
- Contenu de l'`Info.plist` :
  - `CFBundleIdentifier`, `CFBundleName`, `CFBundleExecutable` (`macstatusd`), `CFBundlePackageType` (`APPL`) ;
  - `CFBundleShortVersionString`, partie numérique de `macstatusdVersion` (« 0.6.0 »), et `CFBundleVersion`
    (`git rev-list --count HEAD`) ;
  - `LSMinimumSystemVersion` 13.0, `LSUIElement` vrai, `CFBundleIconFile` `AppIcon` ;
  - `CFBundleDevelopmentRegion` `en`, `CFBundleLocalizations` `[en, fr]` ;
  - `NSLocalNetworkUsageDescription` (anglais dans le gabarit, français dans `fr.lproj`) ;
  - `MacstatusdSupportName`.
- Contenu de `Contents/Library/LaunchAgents/<id>.plist` :
  - `Label` <id>, `BundleProgram` `Contents/MacOS/macstatusd`, `ProgramArguments` `["macstatusd", "--agent"]` ;
  - `RunAtLoad`, `KeepAlive`, `ThrottleInterval` 5, `ExitTimeOut` 5, `ProcessType` `Interactive`,
    `LimitLoadToSessionType` `Aqua` ;
  - pas de `StandardOutPath` : un plist de paquet ne connaît pas le dossier personnel, et le daemon écrit son
    propre journal.

  Les clés que SMAppService honore sont à vérifier à la tâche 6, étape 1.
- Contenu de `Contents/Resources/build-info.json` : `version`, `git` (`git describe --always --dirty`), `built_at`
  (date UTC, ISO 8601).

- [x] **Étape 1 : banc rouge `outils/tests/test-assembler-app.sh`** (bash, sortie sous
  `/private/tmp/macstatusd-plan4/app-essai`). Cas :
  - `defauts` : chaque clé ci-dessus, relue par `PlistBuddy`, `build-info.json` lisible par
    `python3 -m json.tool`, puis `codesign --verify --strict` (ad hoc) ;
  - `identite-essai` : `--identifiant com.djoko.macstatusd.essai --nom-support macstatusd-essai` donne
    `macstatusd-essai.app`, le plist `com.djoko.macstatusd.essai.plist`, son `Label` et `MacstatusdSupportName` ;
  - `icone-absente` (piège) : `--icone` vers un fichier absent. Attendu : code 2 et la raison « icône absente :
    <chemin> (pas d'app sans icône) ».
- [x] **Étape 2 :** écrire `assembler-app.sh` et les gabarits, ajouter `build/` au `.gitignore`. Le banc passe, sauf
  `defauts`, qui attend l'icône.
- [x] **Étape 3 : calage du style**
  - Rendre en PNG de 1024 px les icônes des autres apps de Djoko installées sur le Mac, par un script jetable
    dans le dossier temporaire (`NSWorkspace.shared.icon(forFile:)`).
  - Relever leur forme, leur part du carré, leurs couleurs et leur densité.
- [x] **Étape 4 :** `outils/icone/dessiner-icone.swift` dessine la maîtresse de 1024 px (CoreGraphics, sans fichier
  d'entrée). Deux ou trois variantes, rendues aussi à 32 et à 16 px, et sur un canevas plus grand pour vérifier
  qu'aucune forme n'est coupée.
- [ ] **Étape 5 : validation par Djoko** (SendUserFile, rendu). Il choisit une variante, ou la fait reprendre. Sa
  réponse va au registre.
- [ ] **Étape 6 :** jeu d'icônes par `sips` (16 à 1024 px, en 1x et 2x), puis `iconutil -c icns`, qui donne
  `outils/icone/AppIcon.icns`. Le banc passe, cas `defauts` compris. Commit « Plan 4 : paquet macstatusd.app,
  icône validée par Djoko (C20) ».

**Contrôle du relecteur :** relancer le banc, puis `codesign -dvv` sur l'app d'essai, sortie masquée.

### Tâche 6 : enregistrement natif par SMAppService (C20)

**Faits vérifiés (07/11, script Swift jetable, sans enregistrement) :**
- `SMAppService.Status` vaut `notRegistered` = 0, `enabled` = 1, `requiresApproval` = 2, `notFound` = 3 ;
- un plist absent du paquet donne 3.

**Fichiers :**
- Créer : `Sources/MacStatusCore/ServiceRegistration.swift`, `Sources/macstatusd/ServiceRegistry.swift`
- Modifier : `Sources/macstatusd/main.swift`, `Sources/MacStatusCore/EngineCore.swift` (`/status`)
- Tests : `Tests/MacStatusCoreTests/ServiceRegistrationTests.swift`, `EngineCoreTests.swift`

**Interfaces :**
- Produit, l'état du service :
  - `public enum ServiceState: String { case enabled, requiresApproval = "requires-approval", notRegistered = "not-registered", notFound = "not-found", unknown }` ;
  - `init(rawStatus: Int)` : 0, 1, 2 et 3 comme ci-dessus, toute autre valeur donne `unknown` ;
  - `var message: String` :
    - « activé » ;
    - « à autoriser : Réglages Système > Général > Ouverture et extensions » ;
    - « non enregistré : lancer macstatusd --register » ;
    - « introuvable : l'app doit être dans ~/Applications ou /Applications » ;
    - « inconnu (code N) » ;
  - `var exitCode: Int32` : 0, 3, 4, 5 et 1, dans le même ordre.
- Produit, le mode de lancement :
  - `public enum LaunchMode { case agent, finder, commandLine }` et
    `public static func decide(arguments: [String], environment: [String: String]) -> LaunchMode` ;
  - `--agent` donne `agent` ;
  - sans argument, avec `XPC_SERVICE_NAME` qui commence par `application.` : `finder` ;
  - sinon `commandLine`, qui sans argument lance le daemon comme aujourd'hui.

  Ces deux valeurs de l'environnement sont à vérifier à l'étape 1.
- Produit, la CLI : `--register`, `--unregister` et `--status-service` impriment `message` et sortent par `exitCode`.
  `--agent` lance le daemon. En mode `finder`, l'app enregistre l'agent, montre une alerte (« macstatusd tourne en
  arrière-plan. Réglages : Général > Ouverture et extensions. », en anglais et en français), puis quitte.
- Produit, `/status` : le champ `service` (`ServiceState.rawValue`), relu à chaque appel par un fournisseur que le
  moteur reçoit. Par défaut, `{ .unknown }`.

- [x] **Étape 1 : essai jetable avec Djoko** (10 min)
  - App `com.djoko.macstatusd.essai`, assemblée par la tâche 5 (ad hoc), avec un binaire de travail qui sait
    `--register`.
  - Config d'essai écrite d'abord dans `~/Library/Application Support/macstatusd-essai/config.json` : port 19480,
    webhook coupé, jeton d'essai.
  - Relever :
    - le résultat de `register()` et la notification « Élément d'arrière-plan ajouté » ;
    - l'entrée dans les Réglages, avec son nom et son icône ;
    - `launchctl print gui/$UID/com.djoko.macstatusd.essai` : programme, arguments, type de session, relance ;
    - les clés honorées (`ProgramArguments`, `LimitLoadToSessionType`, `ProcessType`, `KeepAlive`) ;
    - `curl 127.0.0.1:19480/health` ;
    - le `XPC_SERVICE_NAME` vu par l'agent et par un lancement depuis le Finder ;
    - l'état après que Djoko coupe l'agent dans les Réglages (attendu : 2), puis le réactive ;
    - `unregister()` (attendu : 0) ;
    - le dossier d'essai à la Corbeille.

  Le résultat va dans `.superpowers/banc/banc-3-essai-smappservice.md`. Si une clé n'est pas honorée, ou si
  `XPC_SERVICE_NAME` diffère, le contrôleur décide de la correction des gabarits de la tâche 5 ou de `decide`
  avant l'étape 2.
- [x] **Étape 2 : tests rouges**
  - `test_etatDuService_correspondanceDesCodes`, avec 0 à 3 et 7 ;
  - `test_etatDuService_aApprouver_ditOuLeReactiver` (message et code 3) ;
  - `test_modeDeLancement_agent` (`--agent`) et `test_modeDeLancement_finder` (sans argument, variable relevée à
    l'étape 1) ;
  - `test_modeDeLancement_ligneDeCommande` (sans argument ni variable ; `--once`) ;
  - `test_status_porteLEtatDuService`.
- [x] **Étape 3 :** mise en œuvre. Les appels à SMAppService vivent dans `ServiceRegistry.swift`, qui n'est jamais
  appelé par un test.
- [x] **Étape 4 :** suite complète, registre (options de la CLI, champ `service`, messages). Commit « Plan 4 :
  enregistrement de l'agent par SMAppService, --register, --unregister, --status-service (C20) ».

**Contrôle du relecteur :**
- relire l'essai de l'étape 1 ;
- lancer `--status-service` sur l'app d'essai, réinstallée par le contrôleur s'il le faut. C'est une lecture
  seule ;
- vérifier, par un `grep`, qu'aucun test n'atteint `register()`.

### Tâche 7 : `install.sh` et `uninstall.sh` sans `sudo`, migration depuis `/opt` (C2 à C4, C16, F09, F10, F35, F63, F80)

**Fichiers :**
- Réécrire : `scripts/install.sh`, `scripts/uninstall.sh`
- Modifier : `config.example.json` (`enabled: false`, `webhook_base_url` retiré, `webhook_targets: []` ; F09)
- Supprimer : `launchd/com.djoko.macstatusd.plist` (remplacé par le gabarit de la tâche 5)
- Créer : `outils/tests/test-install.sh`, `outils/tests/faux/` (faux `launchctl`, `sudo`, `curl`, `open`, binaire
  d'app d'essai)

**Interfaces :**
- Produit, `install.sh [--app <chemin.app>] [--ancien-prefixe <dossier>] [--preparer-jeton] [--sans-verification]` :
  - refus en root, d'après `${MACSTATUSD_EUID:-$EUID}` (variable de test seulement) : message, code 1 ;
  - sans `--app` : compilation (`swift build -c release`), puis `outils/assembler-app.sh` ;
  - l'identité vient de l'app : `CFBundleIdentifier` et `MacstatusdSupportName`, par `PlistBuddy` ;
  - `--ancien-prefixe` vaut `/opt/macstatusd` par défaut.
- Produit, `uninstall.sh [--app <chemin.app>] [--tout]` :
  - refus en root ;
  - `--unregister`, puis l'app à la Corbeille ;
  - config et journaux gardés, ou mis à la Corbeille avec `--tout` ;
  - garde-fou : refus si un chemin calculé sort de `$HOME/Applications` ou de `$HOME/Library` (F35).

**Ce que fait `install.sh`, dans l'ordre :**
1. **Config.** Une config existante est gardée. Sinon, elle est migrée depuis `<ancien-prefixe>/config.json`
   (lecture seule), ou prise de `config.example.json`. La migration passe par `python3` et `json` :
   - les clés sont copiées ;
   - si `webhook_base_url` est non vide et `webhook_targets` absent, il donne
     `webhook_targets: [{"url": <base>, "method": "GET"}]`, comme le fait `Config.webhookTargets`, et
     `webhook_base_url` est retiré ;
   - une config illisible donne un message clair, avec le code 1, sans trace Python.
2. **Jeton** (C4). Un `auth_token` vide ou absent est remplacé par `secrets.token_hex(32)`. Le fichier est créé vide,
   passé en 600, puis écrit, et `stat -f %Lp` doit rendre 600. `--preparer-jeton` s'arrête là, et imprime
   seulement « jeton prêt dans <config> (64 caractères) » ou « jeton déjà présent dans <config> ».
3. **Marqueur** (C16). Si l'agent de cette identité est chargé (`launchctl print gui/$UID/<id>` réussit), poser
   `<support>/restart-pending`.
4. **Copie.** `ditto` vers un dossier voisin temporaire, puis `mv` vers `~/Applications/<NomApp>.app` : une copie
   ratée laisse l'ancienne app en place.
5. **Enregistrement.** `"<app>/Contents/MacOS/macstatusd" --register`. En cas « à autoriser », le message des
   Réglages s'affiche et le script finit par le code 0, sans réessayer.
6. **Ancien agent** (F80), retrouvé par son contenu, jamais par son libellé.
   - Le plist visé est, dans `~/Library/LaunchAgents/*.plist`, celui dont `ProgramArguments[0]` vaut
     `<ancien-prefixe>/macstatusd`.
   - Son `Label` se lit dans le fichier, puis `launchctl bootout gui/$UID/<Label>`, et le plist part à la Corbeille.
   - Le script n'affiche jamais le libellé (il contient le prénom réel de Djoko) : seulement « ancien agent
     retiré (libellé de N caractères) ».
   - Les journaux de `~/Library/Logs/macstatusd` d'avant l'installation partent aussi à la Corbeille (§4 de la
     spec : la 0.5.0 y écrivait l'URL du webhook en clair).
   - Le script affiche, sans l'exécuter, la commande `sudo rm -rf <ancien-prefixe>`.
7. **Vérification** (F63), sauf avec `--sans-verification`.
   - L'hôte vient de `bind_address` : `""`, `"::"` et `"0.0.0.0"` donnent `127.0.0.1`, sinon le littéral.
   - Le port vient de la config.
   - `curl -fsS --max-time 1 http://<hôte>:<port>/health`, 20 essais à 0,5 s d'écart.

- [x] **Étape 1 : banc rouge `outils/tests/test-install.sh`** (bash, hermétique)
  - Environnement : `HOME` d'essai, faux outils en tête du `PATH`. Chacun note ses appels. Le faux `sudo` échoue
    et note tout appel.
  - Ancien préfixe d'essai : sa config n'a pas de jeton et porte `webhook_base_url`. Un ancien agent d'essai
    pointe vers lui.
  - App d'essai `com.djoko.macstatusd.essai`. Son binaire est un script qui note ses arguments et rend « activé ».
  - Cas :
    - `installation-neuve` : config tirée de l'exemple, 600, jeton de 64 caractères hexadécimaux, un seul
      `--register`, aucun appel à `sudo` ;
    - `migration` : `webhook_targets` repris et `webhook_base_url` retiré, jeton généré, `bootout` avec le bon
      libellé, plist et anciens journaux à la Corbeille, commande `sudo` affichée et non lancée ;
    - `leurre` : un plist au libellé voisin dont le programme diffère reste en place ;
    - `relance` : le jeton ne change pas (empreinte SHA-256 égale), `restart-pending` est posé quand l'agent est
      chargé (le faux `launchctl print` rend 0), l'app est remplacée ;
    - `preparer-jeton` : config et jeton seulement, aucune app, aucun `--register` ;
    - `a-approuver` : le faux binaire rend le code 3. Attendu : le message des Réglages, le code 0, un seul
      `--register` ;
    - `refus-root` (`MACSTATUSD_EUID=0`) : code 1 ;
    - `hote-verifie` : `bind_address` `192.0.2.5` donne un `curl` vers cette adresse ;
    - `json-invalide` : code 1, message clair, aucun « Traceback » ;
    - `jeton-cache` : le jeton apparaît 0 fois dans la sortie de chaque cas (`grep -c -F`). Le message d'échec
      donne le nombre, jamais la valeur ;
    - `desinstallation` : `--unregister` appelé, app à la Corbeille, config gardée. Avec `--tout`, config et
      journaux à la Corbeille ;
    - `sans-sudo` : dans les deux scripts, aucune ligne n'appelle `sudo`, hors du texte affiché pour `/opt`.
- [x] **Étape 2 :** réécrire `install.sh` et `uninstall.sh`, retirer `launchd/`, modifier `config.example.json`.
  `ConfigTests`, qui lit l'exemple, doit rester vert.
- [x] **Étape 3 :** banc vert, suite complète, selftest, `bash outils/tests/test-garde.sh`. Registre : options des
  scripts, et ce que fait la migration. Commit « Plan 4 : install.sh et uninstall.sh sans sudo, migration depuis
  /opt (C2, C4, C16, F09, F10, F35, F63, F80) ».

**Contrôle du relecteur :** relire chaque sortie d'`install.sh` (codes de retour, messages), puis lancer le banc
deux fois de suite pour vérifier qu'il ne laisse rien hors de son dossier d'essai.

---

## Lot 8, outils — Signature, notarisation et publication

### Tâche 8 : `publication.py`, `publier.sh` et leurs tests (D9)

**Fichiers :**
- Créer : `outils/publication.py`, `outils/publier.sh`, `outils/tests/test_publication.py`

**Ce qui se reprend du module d'Amaran** (`git -C ~/Dev/amaran show main:apps/macos/Outils/publication.py`,
1 051 lignes, relu le 07/11) :
- les fonctions génériques, sous leur nom : `developer_id`, `empreinte_identite`, `certificat_du_trousseau`,
  `sujet_conforme`, `champs_rfc2253`, `sujet_developer_id`, `emetteur_developer_id`, `verifier_certificat`,
  `masquer_identite`, `motifs_personnels`, `chemins_personnels`, `copie_sans_signatures`, `lire_droits`,
  `verifier_droits`, `notariser` et la classe `Outils` (outils injectables) ;
- ce qui ne se reprend pas : tout ce qui touche Xcode, Sparkle, le flux et le `.dmg`.

**Interfaces :**
- Produit, `publier.sh [--repetition] <version>` :
  - exporte `IDENTITE_SIGNATURE` (« Developer ID Application » par défaut), `NOTARISER` (1) et
    `PROFIL_NOTARISATION` (`djoko-notarisation`) ;
  - le cliquet, hors `--repetition` : refus si `IDENTITE_SIGNATURE` ≠ « Developer ID Application » ou si
    `NOTARISER` ≠ 1 ;
  - refus sur un clone superficiel (`git rev-parse --is-shallow-repository`) ;
  - les tests, dans un environnement neutre : `env -i PATH=/usr/bin:/bin HOME="$HOME" python3 -m unittest discover -s outils/tests -p 'test_publication.py'`.
    Ils doivent passer avant toute suite ;
  - puis `python3 outils/publication.py [--repetition] <version>`.
- Produit, `publication.py <version> [--repetition]`, dans l'ordre :
  1. assemblage, par `outils/assembler-app.sh --signer -` ;
  2. signature, par l'unique identité trouvée par préfixe, avec sujet et émetteur vérifiés : d'abord le binaire,
     puis le paquet, avec `--options runtime` et `--timestamp`, sans `--deep`. Aucun fichier de droits : une
     exception ne s'ajoute qu'après la preuve, au banc 3, qu'elle manque ;
  3. `codesign --verify --strict -R <exigence>`, l'exigence étant écrite dans `build/` ;
  4. archive `ditto -c -k --keepParent`, puis `notarytool submit --keychain-profile <profil> --wait` ;
  5. `stapler staple` sur l'app, puis nouvelle archive, `spctl -a -vv -t exec` et `stapler validate` ;
  6. garde de l'archive finale, sur une copie dépouillée de ses signatures (`codesign --remove-signature`). Une
     copie dont le retrait rate est refusée. La garde cherche les chemins personnels et les motifs de
     `garde.local.txt` dans tout le contenu ; les droits de l'app se contrôlent à part.

  Produits dans `build/publication/<version>/` : `macstatusd-<version>.zip` et `SHA256SUMS`. Avec `--repetition` :
  identité `com.djoko.macstatusd.repetition`, nom de support `macstatusd-repetition`, dossier
  `build/repetition/<version>/`. Toute sortie montrée passe par `masquer_identite`.

- [x] **Étape 1 : tests rouges `test_publication.py`** (`unittest`, `Outils` remplacé par de faux outils qui notent
  leurs appels, environnement neutre recalculé à chaque test) :
  - `test_masque_titulaire_equipe_empreinte_et_courriel` : la sortie plantée contient « Developer ID Application:
    Prénom Nom (ABCDE12345) », `ABCDE12345.com.djoko.macstatusd`, une empreinte de 40 caractères hexadécimaux et
    un courriel. Attendu : aucune de ces quatre formes ne survit. Même chose pour le texte d'une exception ;
  - `test_identite_aucune_refus`, `test_identite_deux_refus`, `test_identite_emetteur_inconnu_refus` ;
  - `test_notarisation_exige_le_developer_id` : `NOTARISER=1` avec une signature ad hoc donne un refus ;
  - `test_garde_cheminPersonnel_dansUneRessource_refus` : un chemin personnel planté dans une ressource de la copie.
    Il est assemblé à l'exécution, comme dans `test-garde.sh`, pour que la garde ne refuse pas le test lui-même.
    Attendu : le refus nomme le fichier ;
  - `test_garde_titulaireDansLaSignatureSeulement_accepte` : le faux nom légal ne vit que dans la signature, la
    copie dépouillée passe ;
  - `test_garde_retraitDeSignatureRate_refus` ;
  - `test_ordre_des_gestes` : assembler, signer, vérifier, archiver, notariser, agrafer, réarchiver, évaluer, garder.
- [x] **Étape 2 : banc du cliquet** (`outils/tests/test-publier.sh`, bash). Refus pour `IDENTITE_SIGNATURE=-`, pour
  `NOTARISER=0` sans `--repetition`, et pour un clone superficiel. Acceptation de `--repetition` jusqu'aux tests.
  Les faux outils gardent tout le reste inerte.
- [x] **Étape 3 :** mise en œuvre, tous les tests verts. Commit « Plan 4 : outils de signature, de notarisation et
  de publication, cliquet et garde de l'archive (D9) ».

**Contrôle du relecteur :**
- Toutes les sorties de chaque fonction qui affiche passent par le masque, y compris celles des chemins
  d'erreur. La vérification énumère les `print` et les `raise`.
- Aucun appel réel à `codesign` ni à `notarytool` depuis un test, vérifié par un `grep` de `subprocess` dans
  `test_publication.py`.

---

## Lot 7 — Documentation et notes de version

### Tâche 9 : README anglais et français, notes de version, architecture (F68)

**Fichiers :**
- Réécrire : `README.md`, `README.fr.md`
- Créer : `NOTES-VERSIONS.md`, `Tests/MacStatusCoreTests/DocumentationTests.swift`
- Modifier : `architecture.txt`

**Contenu.** Même structure dans les deux langues, avec un lien vers l'autre langue en tête de chaque README :
- définition de ON et de OFF ;
- installation : depuis l'archive publiée (dans `~/Applications`, puis double-clic ou `--register`), ou depuis
  les sources (`./scripts/install.sh`) ;
- l'app dans les Réglages ;
- contrat HA (§7) : commandes avec `X-Auth-Token`, webhook de la voie A avec un exemple YAML générique ;
- exemple générique pour http-webhooks (`on_headers`, `off_headers`) ;
- jeton et règles d'accès (C5 à C7) ;
- toutes les options de la config, et tous les champs de `/status` ;
- détection de l'économiseur ;
- limites connues : toute la rubrique des registres des plans 3 et 4 ;
- signature et notarisation ;
- désinstallation et développement.

`NOTES-VERSIONS.md` : `## 0.6.0`, puis `## 0.5.0`. Chaque section a un bloc **English**, puis un bloc **Français**.
La 0.6.0 dit ce qui change à la mise à jour : la liste du lot 7, que le banc 3 vérifie.

- [x] **Étape 1 : tests rouges `DocumentationTests`**
  - `test_chaqueCleDeConfig_estDecriteDansLesDeuxReadme` : chaque clé de `Config.knownKeys`, entre accents graves ;
  - `test_chaqueChampDeStatus_estDecritDansLesDeuxReadme` : les clés du premier niveau de `statusSnapshot()`, sur
    un moteur d'essai ;
  - `test_lesDeuxReadme_ontLaMemeSuiteDeTitres` : la suite des niveaux de titre ;
  - `test_notesDeVersion_anglaisPuisFrancais` : chaque `## x.y.z` a une ligne `**English**` avant sa ligne
    `**Français**` ;
  - `test_readme_lienVersLAutreLangue`.

  Mutation à rejouer : retirer une clé de `README.fr.md`. Le premier test échoue et nomme la clé.
- [x] **Étape 2 :** écrire les deux README ensemble, puis `NOTES-VERSIONS.md` et `architecture.txt`. Aucune valeur
  réelle : adresses `192.0.2.x`, identifiants d'exemple.
- [x] **Étape 3 :** suite complète, et balayage de l'anonymat du diff (motifs de la garde, chemins personnels). Commit
  « Plan 4 : README anglais et français, notes de version 0.5.0 et 0.6.0, architecture (F68) ».

**Contrôle du relecteur :** suivre la section d'installation à la lettre, dans un `HOME` d'essai, avec l'app d'essai
de la tâche 7 et le faux `launchctl`. Chaque commande citée doit exister et faire ce que dit le texte.

---

## Banc de validation

### Tâche 10 : banc 3 avec Djoko — répétition N-1 → N signée et notarisée, R84, R85, runtime renforcé

**Lecture de la spec retenue :** la spec dit « sur le vrai Mac, passage de la version en place à la 0.6.0 ». La
répétition se fait bien sur le vrai Mac, mais sous l'identité de répétition, avec une copie N-1 de la version en
place, comme chez Amaran (fiche, §5). L'instance réelle et HA ne sont pas touchés. La vraie migration est
l'étape 4 du lot 9 (plan 5).

**Fichiers (locaux) :** `.superpowers/banc/banc-3-<date>/protocole.md`, `resultats.md` et les journaux.
**Fichiers (suivis) :** les corrections des README et des notes de version qui découlent du banc.

- [x] **Étape 1 : préparation par le contrôleur, sans Djoko**
  - **N-1 (0.5.0)** :
    - compilé depuis `ab4626d` (`git archive ab4626d | tar -x -C /private/tmp/macstatusd-plan4/n-1`) ;
    - binaire copié dans `~/Library/Application Support/macstatusd-repetition-ancien/opt/macstatusd`, avec sa
      config (port 19470, webhook vers un récepteur sur 127.0.0.1:19471, sans jeton) ;
    - agent `~/Library/LaunchAgents/com.djoko.macstatusd.repetition-ancien.plist`, dont `ProgramArguments[0]` est
      ce binaire.
  - **N** : `outils/publier.sh --repetition 0.6.0`, signé par le Developer ID et notarisé pour de vrai. Le
    journal défile dans un onglet du Terminal, avec un guetteur, sortie masquée.
  - **Bibliothèque d'interposition** : `.superpowers/banc/outils/interpose-sac.c`, environ 60 lignes de C. Elle
    intercepte `dlsym` pour `SACScreenSaverStartNow`, compte les appels et rend `SAC_CODE`. Elle intercepte aussi
    `posix_spawn` pour noter `argv` sans lancer `/usr/bin/open`. Elle sert sur une instance d'essai sans runtime
    renforcé.
- [x] **Étape 2 : répétition, avec Djoko**
  - L'agent N-1 tourne, et le récepteur reçoit l'état.
  - Djoko lance `./scripts/install.sh --app build/repetition/0.6.0/macstatusd-repetition.app --ancien-prefixe "$HOME/Library/Application Support/macstatusd-repetition-ancien/opt"`.
  - On relève :
    - la notification d'élément d'arrière-plan ajouté, avec son nom et son icône ;
    - l'entrée dans les Réglages ;
    - la config migrée : port repris, jeton généré, droits relus en 600 ;
    - l'agent N-1 retiré, et la commande `sudo` affichée, non lancée ;
    - `/health`.
  - Puis on fait viser au webhook l'adresse de réseau local du Mac, avec un récepteur à l'écoute sur toutes les
    interfaces, et l'écoute de l'app sur toutes les interfaces. On relève les invites « Réseau local » et pare-feu,
    que Djoko accepte.
- [x] **Étape 3 : R84.**
  - Un OFF par `curl`, en-tête lu dans un fichier 600 (`-H @fichier`). Attendu :
    - l'économiseur réglé de chaque écran, puis le verrou ;
    - un seul process `ScreenSaverEngine` ;
    - « SACScreenSaverStartNow appelé (code 0) » au journal.
  - Puis l'interposition, sur une instance d'essai : avec `SAC_CODE=0`, un appel et aucun `open`. Avec
    `SAC_CODE=22`, un appel, un `open` noté et le WARN.
  - Enfin, sur une session déjà verrouillée, l'extinction de l'écran s'applique toujours.
- [x] **Étape 4 : R85.** Veille par le menu Pomme, 60 s d'attente, réveil au clavier. Attendu : « état OFF → ON »
  moins d'1 s après les premiers faits « écrans allumés ».
- [ ] **Étape 5 : runtime renforcé.**
  - `/status` doit dire `saver_detection` = `sac`, `saver_dismissal` = `SACScreenSaverStopNow` et `saver_start` =
    `SACScreenSaverStartNow`.
  - `/wake` sur un économiseur : le panneau s'ouvre et `caffeinate` part.
  - OFF avec `off_action` = `displaySleep` : l'écran s'éteint.
  - L'envoi vers le réseau local est confirmé.
- [ ] **Étape 6 : coupure dans les Réglages.** Djoko coupe l'agent : `--status-service` dit « à autoriser… ». Puis il
  le réactive.
- [ ] **Étape 7 : désinstallation.** `scripts/uninstall.sh --app ~/Applications/macstatusd-repetition.app --tout`.
  Attendu : `launchctl print` échoue, l'entrée disparaît des Réglages, l'app et les dossiers sont à la Corbeille.
  Les restes de N-1 partent aussi à la Corbeille.
- [ ] **Étape 8 :** résultats dans `resultats.md`. Les corrections des README et de `NOTES-VERSIONS.md` (invites
  réellement vues, ordre) sont commitées. Registre.

**Critère de sortie :** les étapes 2 à 7 sont réussies, ou chaque écart est tranché au registre, avec sa correction
faite et refaite au banc.

---

## Publication

### Tâche 11 : relecture finale, fusion, puis publication de la 0.6.0

- [x] **Étape 1 : relecture finale de la branche par Opus**, de `6c0b992` à la tête. Risques nommés :
  - le jeton dans `install.sh` et la publication ;
  - le masque sur tous les chemins d'erreur ;
  - la concurrence de `CachedSignals` ;
  - la migration de l'ancien agent ;
  - les modes de lancement.

  Le paquet de relecture lui est remis avec son plan de lecture, en tranches mesurées par `wc -l`.
- [x] **Étape 2 :** corrections par un agent neuf, puis relecture ciblée.
- [x] **Étape 3 : vérification finale.**
  - `swift test` ;
  - selftest écran allumé, puis écran éteint ;
  - `bash outils/tests/test-assembler-app.sh`, `test-install.sh`, `test-publier.sh` et `test-garde.sh` ;
  - `python3 -m unittest discover -s outils/tests -p 'test_publication.py'` ;
  - `--once` comparé à l'instance réelle.
- [x] **Étape 4 : version.**
  - `grep -rn '0\.6\.0-dev' .` (hors `.build`, `.superpowers`) : classer chaque occurrence, à monter, historique à
    garder ou autre composant.
  - `macstatusdVersion` passe à `"0.6.0"`, et la date va dans `NOTES-VERSIONS.md`. Commit.
  - Fusion dans `main` en avance rapide : `git merge-base --is-ancestor main correctifs-audit`, puis
    `git update-ref refs/heads/main <tête> <ancienne valeur>`.
- [ ] **Étape 5 : arrêt. Attendre « publie 0.6.0 » de Djoko.**
- [ ] **Étape 6 : criblage de tout l'historique,** depuis un clone complet neuf dans
  `.superpowers/publication/clone-0.6.0`.
  - La garde `pre-push` passe sur tous les commits à pousser.
  - `git log -p --all` est passé au crible des motifs de `garde.local.txt`, et des valeurs vivantes lues à la
    source sans affichage : nom d'hôte et nom de l'ordinateur, adresse IPv4 locale du Mac, libellé de l'ancien
    agent, hôte du webhook de la config réelle, et forme d'une équipe.
  - Le rapport ne donne que des nombres et des positions, jamais une valeur.
- [ ] **Étape 7 : tests du clone de publication** (`swift test`, puis les tests de l'étape 3), avant tout script.
- [ ] **Étape 8 : publication.**
  - `git push origin main`, garde active.
  - `outils/publier.sh 0.6.0` dans un onglet du Terminal, avec un guetteur.
  - Étiquette `v0.6.0`, poussée.
  - `gh release create v0.6.0 build/publication/0.6.0/macstatusd-0.6.0.zip`, avec les notes de la 0.6.0, en
    anglais puis en français.
- [ ] **Étape 9 : vérification en ligne.** `gh release download`, `cmp` avec l'archive locale, décompression, puis
  `xcrun stapler validate` et `spctl -a -vv`, sortie masquée, ligne `origin=` comprise.

---

## Fin du plan 4

- [ ] Relecture finale par Opus faite et corrigée (tâche 11, étapes 1 et 2).
- [ ] Vérification finale (tâche 11, étape 3) : tout vert, avec les nombres au registre.
- [ ] README et notes de version alignés sur les registres des plans 3 et 4 : rubriques « Pour le README » vides de
  tout point non reporté.
- [ ] Version 0.6.0 publiée et vérifiée en ligne (tâche 11, étapes 8 et 9).
- [ ] Case « Phase 4 » cochée dans la feuille de route de la spec (§6). Instantané de Jalons sans avertissement.
