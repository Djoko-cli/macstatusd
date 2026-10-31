# Plan 3 — Économiseur sous macOS 27, écrans, veille avortée, efficience (lots 4 et 5)

> **Pour les agents qui exécutent :** sous-compétence requise, `superpowers:subagent-driven-development`
> (recommandée) ou `superpowers:executing-plans`, tâche par tâche. Les étapes se cochent (`- [ ]`).

**But :** le daemon voit l'économiseur lancé par l'inactivité sous macOS 27, et un ON l'écarte vraiment.
Il ne se trompe plus sur l'écran fantôme, ni sur une veille qui n'aboutit pas. Écran allumé, il coûte
moins de la moitié du CPU actuel, et son journal et `/status` disent ce qu'il a vu.

**Architecture :**
- La session d'économiseur vient de `SACScreenSaverIsRunning` (login.framework, chargée dynamiquement)
  ou du process `ScreenSaverEngine`. Les notifications ne font qu'accélérer, jamais foi seules.
- L'oracle reste une classe pure de `MacStatusCore`. Il lit les signaux par le protocole
  `SystemSignals`, et reçoit du moteur les instants « arrêt natif » et « réveil système ».
- Les règles fines sont des fonctions pures du cœur, testées : hôte de repli, code retour de SAC,
  politique de scan des process, topologie des écrans. L'exécutable ne garde que les appels système.

**Outils :** Swift 6.x, `swift-tools-version: 5.9`, mode de langage 5, XCTest, aucune dépendance externe ;
`dlopen`/`dlsym` pour login.framework.

**Spec :** `docs/superpowers/specs/2026-10-25-correctifs-audit-design.md` : lot 4 (depuis « Règle retenue
après le banc 1 »), lot 5, décisions C19 et C23 à C26, section 9. Mesures du banc 1, local :
`.superpowers/banc/banc-1-2026-10-31/resultats.md`. Constats, local : `.superpowers/audit/audit-2026-09-25.md`
(chercher `## Fnn`). Ces deux fichiers contiennent des mesures réelles : n'en recopier aucune valeur.

## Contraintes globales

- Cible `.macOS(.v13)`, aucune dépendance externe. Commentaires, journaux et sorties en français.
- Anonymat : aucun identifiant réel dans le code, les tests, les commits. Valeurs d'essai inventées et
  reconnaissables : PID `4242`, écrans `0x1`, `0x2`, fournisseur `0x1234`, modèle `0x5678`, chemins
  `/private/tmp/…` ou `/home/exemple/…`, jamais `/Users/<nom>` (la garde le refuse). Garde `pre-push`
  installée, `--no-verify` interdit.
- Commandes exécutables telles quelles sous zsh.
- **Instance réelle intouchée** : sur `127.0.0.1:9090`, seulement `GET /state`, `/status`, `/health`. Rien
  sous `/opt/macstatusd`, ni dans sa config, ni dans launchd.
- **Instances d'essai** :
  - écoute sur `127.0.0.1`, `--port` de la plage 19000–19999 **en ligne de commande** ;
  - `off_command` et `wake_command` à `["/usr/bin/true"]`, `off_escalate_to_display_sleep: false`,
    `stop_screensaver_on_wake: false`, jeton d'essai ;
  - `CFFIXED_USER_HOME` et `MACSTATUSD_SUPPORT_DIR` sous `/private/tmp/macstatusd-plan3/` ;
  - arrêt par PID à la fin de chaque étape.
  Config d'essai préparée par le contrôleur avant la tâche 1 : `/private/tmp/macstatusd-plan3/config-essai.json`.
- Jamais de `pkill`, `killall` ni `kill` par motif de nom.
- Aucun faux process visible du système (`ScreenSaverEngine`…) tant que le daemon réel tourne.
  `scripts/selftest.sh` ne se lance jamais avec `SELFTEST_FAUX_ECONOMISEUR=1`, et toujours ainsi, `/health`
  de l'instance réelle contrôlé avant et après :
  `SELFTEST_IGNORER_VERROU=1 SWIFT_SCRATCH=/private/tmp/macstatusd-plan3/selftest bash scripts/selftest.sh`.
- `swift build` et `swift test` toujours avec `--scratch-path /private/tmp/macstatusd-plan3/build`.
- **Aucun test automatique** ne rallume l'écran, ne lance ni n'écarte l'économiseur, ne met le Mac en veille.
  Aucun test ni aucune instance d'essai n'appelle `SACScreenSaverStopNow` ou `SACScreenSaverStartNow`, qui
  agissent sur l'écran. `SACScreenSaverIsRunning` est une lecture : `--once` peut l'appeler.
- Aucun réglage du système modifié (`defaults write`, `pmset` en écriture) : Djoko les change à la main.
- Un process lancé par launchd ne lit ni n'écrit rien sous `~/Documents` (TCC).
- Aucun envoi hors de `127.0.0.1` pendant les tests. Aucun push : `correctifs-audit` reste locale.
- Plus aucun `CGWindowList` pour l'économiseur : sans l'autorisation d'enregistrer l'écran, les noms de
  fenêtres sont vides, et les fenêtres de loginwindow existent aussi sur un simple verrouillage (banc 1).
- `macstatusdVersion` reste `"0.6.0-dev"`.
- Chaque commit se termine par `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` ; auteur et
  committer en noreply.
- README, `architecture.txt` et notes de version ne changent pas ici (lot 7, plan 4). Chaque changement
  visible (clé, défaut, raison, champ de `/status`) va au registre, rubrique « Pour le README (plan 4) ».
- **Relecture de chaque tâche** : en plus des tests, le relecteur lance une fois le nouveau binaire en
  lecture seule et compare ses faits à `curl -s 127.0.0.1:9090/status` :
  `CFFIXED_USER_HOME=/private/tmp/macstatusd-plan3/home MACSTATUSD_SUPPORT_DIR=/private/tmp/macstatusd-plan3/support "$(swift build --scratch-path /private/tmp/macstatusd-plan3/build --show-bin-path)/macstatusd" --once --port 19390 --config /private/tmp/macstatusd-plan3/config-essai.json`.

## Points de vigilance

1. **Simple verrouillage** (⌃⌘Q) : SAC faux, fenêtres de loginwindow et pointeur présents. Attendu : ON
   (`lock-screen-ui`), jamais `screensaver`. Test `test_verrouillageSimple_sansSAC_resteSurLEcranDeVerrouillage`
   (tâche 2).
2. **Notifications forgées ou orphelines** :
   - un `didstart` sans SAC ni hôte expire en 5 s, sans OFF ;
   - une paire `didstop`/`didstart` forgée pendant la saisie du mot de passe ne réarme rien ;
   - une rafale ne coûte qu'un rafraîchissement par 250 ms.

   Tests `test_didstartNonCorrobore_expireSansOFF`, `test_paireForgeePendantLaSaisie_resteEcarte`,
   `test_rafaleDeNotifications_unRafraichissementPar250ms` (tâche 2).
3. **SAC absent** (macOS futur) : avertissement au démarrage. Un hôte lancé après `didstart` ouvre la
   session, un hôte plus ancien jamais. Tests `test_sansSAC_avertissementAuDemarrage`,
   `test_sansSAC_hoteLanceApresDidstart_ouvreLaSession`, `test_sansSAC_hoteAncien_neCorroborePas` (tâche 2).
4. **Veille qui n'aboutit pas, réveil sombre** :
   - une frappe plus de 2 s après l'annonce met fin à la veille ;
   - le clic qui a demandé la veille, non ;
   - une entrée en veille retardée de 29 s sans activité reste OFF, sans rattrapage ;
   - un réveil sombre, écran éteint, reste OFF.

   Tests `test_frappeApresLAnnonce_metFinALaVeille`, `test_frappeAvantLAnnonce_neMetPasFinALaVeille`,
   `test_entreeEnVeilleRetardee_pasDeRattrapageAvant120s`, `test_reveilSombre_ecranEteint_resteOFF` (tâche 5).
5. **Écran fantôme seul** (réveil capot fermé, dock débranché) : l'état publié tient 5 s, puis `no-display`.
   Fantôme principal et écrans physiques éteints : `display-asleep`. Tests
   `test_ecranFantomeSeul_tient5sPuisNoDisplay`, `test_fantomePrincipal_ecransPhysiquesEteints_displayAsleep`
   (tâche 4).

Ordre : 1 → 2 → 3 (il consomme `noteDismissed`) → 4 → 5 → 6 (il garde la lecture HID de la tâche 5) → 7 → 8.

---

## Lot 4 — Économiseur d'écran

### Tâche 1 : signaux de l'économiseur sous macOS 27

C23, F75.

**Fichiers :**
- Créer : `Sources/MacStatusCore/SaverProcesses.swift`
- Modifier : `Sources/MacStatusCore/SystemSignals.swift`, `Sources/macstatusd/LiveSystemSignals.swift`,
  `Sources/MacStatusCore/EngineCore.swift` (indices de scan seulement)
- Test : `Tests/MacStatusCoreTests/SaverProcessesTests.swift` (créer), `Support/Fakes.swift`,
  `EngineCoreTests.swift`

**Interfaces :**
- Produit, dans `SystemSignals.swift` :
  - `public struct SaverHost: Equatable { public var pid: Int32; public var launchedSecondsAgo: Double }`,
    avec un `init` public ;
  - au protocole `SystemSignals` :
    - `func saverSessionFlag() -> Bool?` : `SACScreenSaverIsRunning`. Vrai pendant une session
      d'économiseur, panneau compris ; faux hors session, y compris sur un simple verrouillage ; `nil` si
      la fonction manque ou rend un code inattendu ;
    - `func saverHosts() -> [SaverHost]` : process de l'utilisateur dont le chemin satisfait
      `SaverHostRule.isHost(path:)`. Appelé seulement en repli (SAC `nil`) ;
    - `func saverProcessHint()` : indice de lancement ou de fin d'un process d'économiseur. La lecture
      suivante de `saverEnginePID()` refait un scan complet ;
  - `saverEnginePID()` ne voit plus que les process de l'utilisateur (`getuid()`) ;
  - `saverWindow()` et `WindowVerdict` restent jusqu'à la tâche 2.
- Produit, dans `SaverProcesses.swift` :
  - `public enum SaverHostRule { public static func isHost(path: String) -> Bool }`. Vrai si le chemin
    commence par `/System/Library/` et :
    - contient `/ScreenSaver.framework/PlugIns/` (hôtes `legacyScreenSaver`, arm64 et `-x86_64`) ;
    - ou vaut `/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine` ;
    - ou contient `/Computer Name.appex/Contents/MacOS/` (hôte de « Message », chemin complet confirmé au
      banc, tâche 8).

    Jamais `WallpaperAerialsExtension` ni les autres extensions `Wallpaper*`, présentes en permanence ;
  - `public enum SaverSessionFlag { public static func from(returnCode: Int32) -> Bool? }` : `1` → vrai,
    `0` → faux, tout autre code → `nil` ;
  - `public struct SaverProcessScanPolicy` : `public static let fullScanInterval: Double = 5`,
    `public init()`, `public mutating func noteHint()`, `public mutating func shouldScan(now: Double) -> Bool`.
    `shouldScan` rend vrai au premier appel, après un indice, ou quand `fullScanInterval` s'est écoulé
    depuis le dernier scan accordé ; il note alors le scan accordé.
- `FakeSignals` : `drapeauSAC: Bool? = false`, `hotes: [SaverHost] = []`, `indicesProcess` (nombre
  d'appels de `saverProcessHint()`).
- `EngineCore` appelle `signals.saverProcessHint()` avant de relire les faits, dans deux cas :
  - dans `handle(_:)`, sur `.screenSaverDidStart`, `.screenSaverDidStop` et `.saverProcessChanged` ;
  - dans `requestOff`, juste après `actions.runOff(.screensaver)`.

- [x] **Étape 1 : tests.**
  - `test_regleHote_reconnaitLesHotesDuBanc` : vrai pour
    `/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver-x86_64.appex/Contents/MacOS/legacyScreenSaver-x86_64`,
    pour la même chose sans `-x86_64`, pour le chemin de `ScreenSaverEngine`, et pour
    `/System/Library/ExtensionKit/Extensions/Computer Name.appex/Contents/MacOS/Computer Name`.
  - `test_regleHote_refuseLeFondDEcranEtLesCopies` : faux pour
    `/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension`,
    `/System/Library/ExtensionKit/Extensions/Wallpaper.appex/Contents/MacOS/Wallpaper`,
    `/private/tmp/ScreenSaverEngine` et `/home/exemple/ScreenSaver.framework/PlugIns/x`.
  - `test_codeRetourSAC_unVrai_zeroFaux_autreIndisponible` : `1`, `0`, `-1`, `2`.
  - `test_politiqueDeScan_premierAppelPuisToutesLes5s` : `shouldScan(now:)` vrai à `0`, faux à `0.5` et
    `4.9`, vrai à `5.0`.
  - `test_politiqueDeScan_indiceForceUnScan`.
  - `test_didstart_demandeUnScanDesProcess` et `test_offParEconomiseur_demandeUnScanDesProcess` :
    `indicesProcess` monte.
- [x] **Étape 2 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : échec de compilation.
- [x] **Étape 3 : mettre en œuvre.** Les trois types purs, puis le protocole et les faux. Dans `LiveSystemSignals` :
  - **SAC** : `login.framework` ouvert une fois (`dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY)`),
    `SACScreenSaverIsRunning` résolu par `dlsym` en `@convention(c) (UnsafeMutablePointer<UInt8>) -> Int32`.
    On l'appelle avec un octet valide ; sa valeur passe par le retour (banc 1 : l'octet n'est jamais
    écrit). Un code inattendu est journalisé une fois par valeur.
  - **`saverEnginePID()`** :
    - PID en cache, revalidé par `proc_pidinfo(PROC_PIDTBSDINFO)` : préfixe `ScreenSaverEngin` de
      `pbi_comm`, et `pbi_uid == getuid()` ;
    - sans PID valide, scan `KERN_PROC_UID` sur `getuid()`, seulement si `SaverProcessScanPolicy.shouldScan`
      l'accorde ; `saverProcessHint()` appelle `noteHint()`.
  - **`saverHosts()`** : scan `KERN_PROC_UID`, chemin par `proc_pidpath`, âge tiré de `kp_proc.p_starttime`.
  - **`runningProcesses()`**, qui parcourait tous les utilisateurs, disparaît.
- [x] **Étape 4 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : OK.
- [x] **Étape 5 : commit** « Économiseur : signaux SAC, hôtes et PID de l'utilisateur seulement ».

### Tâche 2 : oracle de l'économiseur sous macOS 27

F03, F17, F46, F67 ; C23, C25.

**Fichiers :**
- Modifier :
  - `Sources/MacStatusCore/ScreenSaverOracle.swift`, réécrit ;
  - `SystemSignals.swift`, où `saverWindow()` et `WindowVerdict` disparaissent ;
  - `EngineCore.swift` ;
  - `Config.swift` : `saverRedisplayIdleSeconds = 30` ;
  - `Sources/macstatusd/LiveSystemSignals.swift`, sans `saverWindow()` ;
  - `Sources/macstatusd/EngineRunner.swift`, pour la construction de l'oracle.
- Test : `ScreenSaverOracleTests.swift` (réécrit), `EngineCoreTests.swift`, `ConfigTests.swift`, `Support/Fakes.swift`

**Interfaces :**
- Consomme (tâche 1) : `saverSessionFlag()`, `saverEnginePID()`, `saverHosts()`, `SaverHost`.
- Produit :
  - `ScreenSaverOracle.init(dismissOnInput: Bool = true, dismissGrace: Double = 1.5, redisplayIdle: Double = 30, signals: SystemSignals)`.
    Plus de `minimumInterval` ;
  - `noteDidStart(now: Double)`, `noteDidStop(now: Double)`, `noteDismissed(now: Double)` (arrêt natif
    demandé par le moteur, tâche 3) et `noteSystemWake()`. `noteNotification(active:)` disparaît ;
  - `verdict(now:hidIdle:) -> Verdict`, de même structure (`active`, `running`, `dismissed`, `evidence`) ;
  - `static let corroborationWindow: Double = 5`, `static let hostLaunchTolerance: Double = 1`,
    `static let incoherenceLogInterval: Double = 60` ;
  - preuves (`evidence`, jointes par `+`) : `sac`, `process` ou `notification+hôte`, suivies de
    `écarté-par-activité`, `écarté-par-commande` ou `réaffiché`. Hors session : `none` ;
  - `EngineCore.notificationRefreshMinInterval: Double = 0.25` (statique) ;
  - `statusSnapshot()["saver_detection"]` : `"sac"`, ou `"hôte"` si `saverSessionFlag()` rend `nil`.
- `FakeSignals` : `fenetreEconomiseur` disparaît ; compteur `lecturesSession` (appels de `session()`).

**Règle du verdict.** Elle remplace la règle par fenêtre, et les tests ne la fixent pas entièrement :

```text
sources :
  SAC vrai                          → « sac »
  saverEnginePID() ≠ 0              → « process »
  SAC nil (repli) : didstart en attente depuis t0, et un hôte lancé à t0 − 1 s ou après, vu avant
                    t0 + 5 s → hôte retenu (PID) ; tant qu'il vit et sans didstop → « notification+hôte »
attente de didstart, dans tous les modes : expirée à t0 + 5 s sans corroboration, journalisée une fois
session :
  ouverte dès qu'une source est vue ; à l'ouverture, début = occupé depuis = now, arrêt natif oublié
  fermée à la première lecture sans source si un didstop est arrivé depuis la dernière lecture positive,
  sinon à la deuxième lecture de suite sans source (une lecture SAC isolée à 0 ne ferme rien)
  didstop pendant que SAC est vrai : incohérent → WARN au plus une fois par 60 s, puis ignoré
panneau, seulement si dismissOnInput :
  dernière frappe connue = now − hidIdle quand hidIdle ≥ 0, sinon la dernière valeur lue
  activités retenues :
    - la dernière frappe connue, si elle suit « occupé depuis » et début + dismissGrace
    - l'arrêt natif, s'il suit « occupé depuis » (sans grâce)
  aucune → économiseur seul (active)
  now − la plus récente ≥ redisplayIdle → occupé depuis = now, arrêt natif oublié, « réaffiché », active
  sinon → dismissed : « écarté-par-commande » si l'arrêt natif est le plus récent, sinon « écarté-par-activité »
noteSystemWake : oublie l'attente de didstart ; une session établie reste, relue au verdict suivant
```

**Moteur :**
- `handle(.screenSaverDidStart)` → `saver.noteDidStart(now:)` ; `handle(.screenSaverDidStop)` →
  `saver.noteDidStop(now:)`. Pour ces deux événements, et pour `.screenLocked` et `.screenUnlocked`, les
  faits ne sont relus et l'état réévalué que si la dernière relecture due à un de ces événements date de
  250 ms au moins. Le tick suivant rattrape le reste.
- Au réveil (`systemDidWake`, trou de scrutation, réveil perdu) et dans `resync()` : `saver.noteSystemWake()`,
  à la place de `noteNotification(active: false)`.
- `start()` : si `signals.saverSessionFlag() == nil`, WARN « économiseur : SACScreenSaverIsRunning
  indisponible → repli sur l'hôte apparu après didstart ; les paysages aériens ne seront pas détectés ».

- [x] **Étape 1 : tests de l'oracle** (`ScreenSaverOracleTests`, réécrit). Garder les cas de l'ancien
  scénario nominal encore valables avec la source `process` (PID 4242), en ajoutant une seconde lecture
  là où la fin de session est attendue. Retirer les deux cas de fenêtre. Ajouter :
  - `test_sacVrai_sansActivite_economiseurSeul` : preuve `sac`, `active` ;
  - `test_sacVraiPuisFrappe_panneauDoncON` : `sac+écarté-par-activité` ;
  - `test_panneau_revientALEconomiseurApres30s` : avec le défaut de 30 s, `hidIdle` 29.5 → écarté, 30 →
    `active`, `réaffiché` ;
  - `test_frappeJusteApresLeRetour_compteSansGrace` : réaffiché, puis une frappe 0,5 s après → écarté ;
  - `test_arretNatif_panneauPendant30s` : `noteDismissed(now: t)` → `écarté-par-commande` ; à t + 30 → `réaffiché` ;
  - `test_arretNatifAvantLaSession_neComptePas` ;
  - `test_ecartementDesactive_ignoreFrappeEtArretNatif` ;
  - `test_uneLectureSACAZero_neFermePasLaSession` et `test_deuxLecturesSACAZero_fermentLaSession` ;
  - `test_didstopSansSource_fermeImmediatement` ;
  - `test_didstopPendantSACVrai_ignoreEtJournaliseUneFoisParMinute` : un WARN pour deux `didstop` à 10 s
    d'écart, un second après 60 s ;
  - `test_didstartNonCorrobore_expireSansOFF` : SAC faux pendant 6 s → jamais `running`, une seule ligne
    d'expiration ;
  - `test_paireForgeePendantLaSaisie_resteEcarte` : SAC vrai et panneau, puis `noteDidStop` et `noteDidStart`
    → toujours écarté ;
  - `test_sansSAC_hoteLanceApresDidstart_ouvreLaSession` : `drapeauSAC = nil`, `didstart` à t0, hôte
    `launchedSecondsAgo: 0.2` lu à t0 + 0.45 → `notification+hôte` ;
  - `test_sansSAC_hoteAncien_neCorroborePas` : hôte lancé 600 s plus tôt ;
  - `test_sansSAC_didstopFermeLaSession` et `test_sansSAC_hoteDisparu_fermeLaSession` ;
  - `test_processSeul_ouvreLaSession` : SAC faux, PID 4242 → `process` ;
  - `test_inactiviteIndisponible_gardeLEcartement` : `hidIdle` −1 pendant deux lectures après une frappe
    → toujours écarté ;
  - `test_ecranRallumeSansFrappe_economiseurSeul` : verdicts suspendus 10 min, puis `hidIdle` 600 → `active` ;
  - `test_reveilSysteme_gardeLaSessionSAC` : `noteSystemWake()`, SAC toujours vrai → `running`, sans
    réarmement : la frappe d'avant compte toujours ;
  - `test_reveilSysteme_oublieLeDidstartEnAttente` (repli).

  Ces cas couvrent les scénarios 1 à 7 de F67. Le 8 (fenêtres) devient sans objet : il est remplacé par
  les fonctions pures des tâches 1 et 4.
- [x] **Étape 2 : tests du moteur et de la config.**
  - `test_economiseurDInactivite_publieOFF` (F03) : bureau, `didstart`, SAC vrai, inactivité de 30 s →
    OFF `screensaver:sac` après le lissage ;
  - `test_verrouillageSimple_sansSAC_resteSurLEcranDeVerrouillage` ;
  - `test_reveilAvecSessionSAC_resteOFF` ;
  - `test_rafaleDeNotifications_unRafraichissementPar250ms` : 10 `didstart` en 0,2 s → une seule
    relecture de `session()` hors tick ;
  - `test_sansSAC_avertissementAuDemarrage` ;
  - `test_statusDitLaSourceDeDetection` ;
  - `test_redisplayParDefaut30s` (`ConfigTests`).
- [x] **Étape 3 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : échecs.
- [x] **Étape 4 : mettre en œuvre.**
- [x] **Étape 5 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`, puis le selftest des
  contraintes globales** — attendu : OK. La section du faux économiseur est sautée, comme toujours.
  `--once` en lecture seule : `facts.screensaver_evidence` vaut `none`, et `saver_detection` `sac`.
- [x] **Étape 6 : commit** « Économiseur : session par SAC, notifications corroborées, panneau de 30 s ».

### Tâche 3 : écarter l'économiseur par la commande du système

C24, R49, R52.

**Fichiers :**
- Modifier : `Sources/MacStatusCore/Commands.swift`, `Sources/macstatusd/PowerActions.swift`, `EngineCore.swift`
- Test : `EngineCoreTests.swift`, `Support/Fakes.swift`

**Interfaces :**
- Consomme (tâche 2) : `ScreenSaverOracle.noteDismissed(now:)`.
- Produit :
  - `public enum ScreenSaverDismissal: String { case native = "SACScreenSaverStopNow"; case processKill = "killall ScreenSaverEngine" }` ;
  - `CommandActions.screenSaverDismissal: ScreenSaverDismissal { get }`, connu dès la création ;
  - `CommandActions.dismissScreenSaver()`, qui ne bloque jamais ; `stopScreenSaver()` disparaît ;
  - `FakeActions.moyenEcartement`, `.native` par défaut, et l'appel `.dismissScreenSaver` à la place de
    `.stopScreenSaver` ;
  - `statusSnapshot()["saver_dismissal"]` : la `rawValue` du moyen.
- **Moteur** : `private func dismissSaver(now: Double)` appelle `actions.dismissScreenSaver()`, puis
  `saver.noteDismissed(now:)` si le moyen est `.native`. Un `killall` n'écarte rien sous macOS 27 : la
  confirmation attend alors les faits. Quand `stop_screensaver_on_wake` est vrai, trois chemins l'appellent :
  - `requestOn`, quand il crée une intention ON alors que l'économiseur est seul à l'écran, après `wakeNow()` ;
  - `requestOn` sur un Mac déjà ON dont l'économiseur tourne (panneau supposé visible, branche R30). Si
    macOS est déjà revenu à l'économiseur, l'arrêt natif ravive le panneau pour 30 s ;
  - l'escalade d'un ON dont l'économiseur est encore seul à l'écran.

  Le réveil léger (R49) reste réservé aux cas sans session d'économiseur.
- `start()` journalise le moyen une fois. Natif : INFO. Repli : WARN « SACScreenSaverStopNow indisponible
  → repli killall ScreenSaverEngine, sans effet sous macOS 27 sur l'économiseur d'inactivité ».
- **`PowerActions`** :
  - `SACScreenSaverStopNow` résolu à la création, en `@convention(c) () -> Int32`, et appelé sur la file
    des actions ; code journalisé, `0` attendu ;
  - R52 : un seul `caffeinate` à la fois ; s'il tourne encore, le précédent est arrêté par son PID avant
    d'en lancer un autre ;
  - nom de la retenue en ASCII : `"macstatusd retenue d'ecran"`. `pmset -g assertions` affichait mal l'accent.

- [x] **Étape 1 : tests.**
  - `test_onSurEconomiseurSeul_ecarteParLeSystemeEtConfirme` : session SAC et intention ON → `.wake` puis
    `.dismissScreenSaver` ; l'évaluation suivante confirme ON par `écarté-par-commande` ;
  - `test_onSurEconomiseurSeul_repliKillall_attendLesFaits` : moyen `.processKill` → aucun écartement
    supposé, l'intention reste en attente ;
  - `test_onAvecStopDesactive_nEcartePas` ;
  - `test_onSurMacDejaON_economiseurEnMarche_ecarteAussi` ;
  - `test_escaladeOn_economiseurEncoreSeul_ecarteEncore` ;
  - `test_reveilLegerPuisOFF_relacheEtExecuteLOFF` (R52) ;
  - `test_demarrage_journaliseLeMoyenDEcartement` : INFO s'il est natif, WARN pour le repli.
- [x] **Étape 2 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : échecs.
- [x] **Étape 3 : mettre en œuvre.** `PowerActions` ne se teste pas ici : il se vérifie à la lecture, puis au banc.
- [x] **Étape 4 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : OK.
- [x] **Étape 5 : commit** « Économiseur : un ON l'écarte par SACScreenSaverStopNow ».

### Tâche 4 : écran fantôme, extinction et topologie

F16, F50, F90.

**Fichiers :**
- Créer : `Sources/MacStatusCore/DisplayTopology.swift`
- Modifier : `SystemSignals.swift`, `Facts.swift`, `EngineCore.swift`, `Sources/macstatusd/LiveSystemSignals.swift`
- Test : `Tests/MacStatusCoreTests/DisplayTopologyTests.swift` (créer), `EngineCoreTests.swift`, `Support/Fakes.swift`

**Interfaces :**
- Produit :
  - `public struct DisplayInfo: Equatable` : `id`, `vendor` et `model` en `UInt32`, `asleep` et `isMain`
    en `Bool`, et `var isPlaceholder: Bool` (fournisseur et modèle du fantôme) ;
  - `public struct DisplaySnapshot { public var displays: [DisplayInfo]; public var enumerationOK: Bool }` ;
  - le protocole remplace `display() -> DisplayState` par `displaySnapshot() -> DisplaySnapshot` ;
  - `DisplayState` gagne `evidence: String` (`main`, `all`, `screensDidSleep`, `awake` ou `none`) et
    `displays: [DisplayInfo]` ; `onlineCount` ne compte plus que les écrans physiques ;
  - `public enum DisplayTopology` :
    - `placeholderVendor: UInt32 = 0x756E6B6E` et `placeholderModel: UInt32 = 0x76697274` ;
    - `static func state(_ snapshot: DisplaySnapshot, screensAsleepNotified: Bool) -> DisplayState` ;
    - `static func summary(_ displays: [DisplayInfo]) -> String`, par exemple `0x5*,0x2z,0x9v`
      (`*` principal, `z` endormi, `v` fantôme), et `none` pour une liste vide ;
  - `Facts.displayEvidence` et `Facts.displays`. `asDictionary` gagne `display_evidence` et `displays` (le
    résumé). `statusSnapshot()` gagne `main_display` (hexadécimal) et `display_list`
    (`[{"id": "0x5", "main": true, "asleep": false, "placeholder": false}]`).
- **Règle de `DisplayTopology.state`.** Les écrans physiques sont ceux qui ne sont pas le fantôme.
  - Aucun écran physique : `asleep` faux, `onlineCount` 0, preuve `none`.
  - Écran principal physique et endormi : `main`.
  - Sinon, tous les écrans physiques endormis : `all`.
  - Sinon, avis `screensDidSleep` et au moins un écran physique endormi : `screensDidSleep`. Un écran
    virtuel resté éveillé ne retient plus l'état ON.
  - Sinon : `awake`.
- **Moteur** :
  - `screensAsleepNotified` devient vrai sur `.screensDidSleep`. Il redevient faux sur `.screensDidWake`,
    `.systemDidWake` et `resync()`, ou dès qu'aucun écran physique n'est endormi ;
  - `static let noDisplayHoldSeconds: Double = 5`, avec `noPhysicalDisplaySince`. Énumération réussie et
    aucun écran physique depuis moins de 5 s : `(published ?? false, "displays-reconfiguring")`. Depuis 5 s
    ou plus : `(false, "no-display")`. Cette règle prend la place de l'ancienne règle `no-display` ;
  - INFO « écrans : <résumé> » quand l'ensemble des écrans, l'écran principal ou la présence du fantôme
    change. Pas quand un écran s'endort ou se réveille.
- **`LiveSystemSignals.displaySnapshot()`** : `CGGetOnlineDisplayList`, `CGMainDisplayID`, et
  `CGDisplayIsAsleep` pour chaque écran. `CGDisplayVendorNumber` et `CGDisplayModelNumber` sont lus une
  fois par identifiant, puis gardés en cache.
- **`FakeSignals`** : `ecrans: DisplaySnapshot`. `etatEcran` devient un raccourci calculé, pour que les
  tests existants gardent leur sens : `DisplayState(asleep: a, onlineCount: n, enumerationOK: ok)` produit
  n écrans physiques `0x1`…, de fournisseur `0x1234` et de modèle `0x5678`, le premier principal, tous
  `asleep: a`.

- [x] **Étape 1 : tests de la topologie.**
  - `test_fantome_reconnuParFournisseurEtModele` ;
  - `test_fantomeSeul_aucunEcranPhysique` ;
  - `test_fantomePrincipal_ecransPhysiquesEteints_displayAsleep` (`all`) ;
  - `test_principalPhysiqueEteint_suffit` (`main`) ;
  - `test_ecranVirtuelEveille_avisDuSysteme_departage` : avis, un écran physique endormi, un écran
    principal éveillé de fournisseur `0x4321` → endormi, `screensDidSleep` ;
  - `test_avisDuSystemeSansEcranEndormi_neDitRien` ;
  - `test_resume_principalEndormiEtFantome`.
- [x] **Étape 2 : tests du moteur.**
  - `test_ecranFantomeSeul_tient5sPuisNoDisplay` : ON publié, puis le fantôme seul. ON tient jusqu'à 5 s,
    puis OFF `no-display` après le lissage ;
  - `test_ecranFantomeAuReveil_resteOFFJusquAuxEcransPhysiques` : OFF de veille, réveil sur le fantôme
    seul → `displays-reconfiguring`, OFF ; puis les écrans physiques → ON ;
  - `test_avisEcransEteints_effaceQuandUnEcranSeReveille` ;
  - `test_topologie_journaliseeAuChangement` : une ligne INFO quand un écran s'ajoute, aucune quand il s'endort ;
  - `test_statusDonneLaTopologie`.

  Les tests existants qui attendent `no-display` tout de suite avancent désormais l'horloge de 5 s ; le
  rapport les nomme.
- [x] **Étape 3 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : échecs.
- [x] **Étape 4 : mettre en œuvre.**
- [x] **Étape 5 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : OK.
  `--once` : `display_list` donne autant d'écrans physiques que le Mac en a, et aucun fantôme écran allumé.
- [x] **Étape 6 : commit** « Écrans : fantôme exclu, avis d'extinction, topologie dans /status ».

### Tâche 5 : veille avortée et réveils sombres

C26.

**Fichiers :**
- Modifier : `EngineCore.swift`
- Test : `EngineCoreTests.swift`

**Interfaces :**
- Produit : `static let sleepAbortInputMargin: Double = 2` ; `lostWakeDelay` passe de 35 à 120.
- **Fin de veille sans IOKit.** Pendant une veille en cours (`sleepInProgress`), la veille prend fin dans
  deux cas :
  - une frappe ou un mouvement suit l'annonce de plus de 2 s : `now − hidIdle > début + 2` ;
  - la session, vue verrouillée depuis l'annonce, est relue déverrouillée.
- **Effets** :
  - `systemAsleep = false`, et la fin de la veille notée, comme pour un réveil traité ;
  - INFO « fin de la veille sans avis de réveil (activité 15.0 s après l'annonce) », ou
    « (session déverrouillée) » ;
  - puis une évaluation non immédiate. L'avis IOKit qui arrive ensuite ne force rien.

  Vérifié à chaque `tick()`, après le rattrapage, et sur `.screenUnlocked` (un avis écarté par le délai
  de 250 ms est rattrapé au tick suivant).
- Ces règles lisent `hidIdleSeconds` pendant une veille en cours : la tâche 6 garde cette lecture.

- [ ] **Étape 1 : tests.**
  - `test_frappeApresLAnnonce_metFinALaVeille` : annonce à t, `hidIdle` 0.3 à t + 15 → fin de veille, ON
    après le lissage ;
  - `test_frappeAvantLAnnonce_neMetPasFinALaVeille` : `hidIdle` 1.5 à t + 1, puis 0.2 à t + 1.5 → veille
    gardée ;
  - `test_deverrouillageApresLAnnonce_metFinALaVeille` ;
  - `test_sessionJamaisVerrouillee_avisDeDeverrouillage_neMetPasFin` ;
  - `test_entreeEnVeilleRetardee_pasDeRattrapageAvant120s` : ticks pendant 29 s sans activité →
    `system-asleep`, et aucun « réveil non signalé » avant 120 s ;
  - `test_avisIOKitApresLaFin_neForcePas` ;
  - `test_reveilSombre_ecranEteint_resteOFF` : `systemDidWake` écran éteint → OFF `display-asleep`, aucun ON publié.

  Les tests existants du réveil perdu passent de 35 s à 120 s.
- [ ] **Étape 2 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre.**
- [ ] **Étape 4 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : OK.
- [ ] **Étape 5 : commit** « Veille : fin sur activité ou déverrouillage, filet du réveil perdu à 120 s ».

---

## Lot 5 — Efficience et observabilité

### Tâche 6 : coût de la scrutation

F76, F78 ; F75 est fait à la tâche 1. Objectif de la spec : tick écran allumé ≤ 0,35 % d'un cœur.

**Fichiers :**
- Modifier : `Sources/macstatusd/LiveSystemSignals.swift`, `EngineCore.swift`
- Test : `EngineCoreTests.swift`, `Support/Fakes.swift`
- Mesures, local : `.superpowers/sdd/2026-10-31-plan-3-economiseur-efficience/mesures-cpu.md`

**Interfaces :**
- `session()` n'appelle `CGSessionCopyCurrentDictionary` que si `registryRoot == 0`, ou si
  `IOConsoleUsers` est absent ou illisible. Pas s'il existe sans entrée à la console : c'est la fenêtre
  de login en changement rapide d'utilisateur. `ConsoleOwnership.decide` reçoit alors `cgSession: nil`.
- `hidIdleSeconds()` : le service `IOHIDSystem` est résolu une fois (`IOServiceGetMatchingService`) et
  libéré au `deinit`. Il est résolu de nouveau si la lecture échoue.
- `refreshFacts()` ne lit `hidIdleSeconds()` que si l'oracle est évalué (ni veille, ni écran éteint), ou
  pendant une veille en cours (tâche 5). Sinon, `hidIdleSeconds = -1`.
- `statusSnapshot()` relit `hidIdleSeconds()` à chaque appel pour `facts.hid_idle_seconds`.
- `FakeSignals` : compteur `lecturesHID`.

- [ ] **Étape 1 : tests.** `test_ecranEteint_neLitPasLInactivite`, `test_veilleEnCours_litLInactivite`,
  `test_statusRelitLInactivite`.
- [ ] **Étape 2 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre.**
- [ ] **Étape 4 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : OK.
- [ ] **Étape 5 : mesurer.**
  - Deux binaires en release :
    - la base du plan, le commit noté au registre avant la tâche 1, construit dans un worktree sous
      `/private/tmp/macstatusd-plan3/base` ;
    - la tête de la branche.
  - Chacun tourne 10 min en instance d'essai, l'un après l'autre, dans la même session : ports 19310 et
    19311, écran allumé, sans économiseur.
  - CPU : `ps -o time= -p <PID>` au début et à la fin ; part d'un cœur = Δcpu / 600 s × 100.
  - `/status` est relu toutes les 60 s. Un `display_asleep` ou un `screensaver_running` vrai annule la
    mesure, qui est refaite.
  - La base doit retrouver l'ordre de grandeur de l'audit (0,76 à 0,91 %). Sinon, l'écart de méthode est
    noté, et seule la comparaison entre les deux binaires compte.
  - Attendu : la tête ≤ 0,35 %, et au moins deux fois moins que la base. Sinon, `sample <PID> 10` (lecture
    seule) sur la tête, et le poste dominant est noté au registre avant toute autre mesure.
- [ ] **Étape 6 : commit** « Efficience : CGSession en repli, service HID gardé, lecture à la demande ».
  Les mesures restent locales.

### Tâche 7 : observabilité et code mort

F71, F44, F70.

**Fichiers :**
- Modifier :
  - cœur : `Facts.swift`, `Logging.swift`, `EngineCore.swift`, `Config.swift`, `WebhookClient.swift`,
    `Router.swift` ;
  - exécutable : `Sources/macstatusd/LiveSystemSignals.swift`, `main.swift`, `EngineRunner.swift`,
    `URLSessionTransport.swift`.
- Test : `EngineCoreTests.swift`, `LoggingTests.swift`, `ConfigTests.swift`, `RouterTests.swift`, `Support/Fakes.swift`

**Interfaces :**
- **F71** :
  - `Facts.sameDecision(as: Facts) -> Bool` compare toutes les valeurs sauf `hidIdleSeconds`, et
    `refreshFacts` n'écrit « faits: » que quand elle rend faux ;
  - `CoreLog.debugEnabled: Bool`, vrai par défaut, et fixé une fois par `main.swift` avant le démarrage
    des files ; `logDebug(_ m: @autoclosure () -> String)` ;
  - dans `main.swift`, l'écho sur la sortie standard suit `isTTY || options.foreground`, et plus `--debug`.
- **F44** :
  - une fois l'état stable et inchangé, `publishedReason` suit la raison courante, sans republication
    (DEBUG quand elle change) ;
  - un OFF surchargé a la source `off/override` ;
  - `statusSnapshot()` gagne `facts_reason`.
- **F70** :
  - `candidateReason` disparaît ;
  - les durées en secondes sont calculées dans `Config` (`pollInterval`, `commandConfirmTimeout`,
    `commandEscalateAfter`, `saverDismissGrace`, `webhookTimeout`), à la place des `Double(config.xxxMS) / 1000` ;
  - `ISO8601DateFormatter` devient statique, dans le moteur et dans le webhook ;
  - `CGSessionAvailable()` est renommée `isAquaSession()` ;
  - `requestOff(source:)` et `requestOn(source:)` deviennent `requestOff(peer:)` et `requestOn(peer:)`,
    dans le moteur, `EngineFacade` et le routeur : `source` désigne aussi l'étiquette d'une intention.

- [ ] **Étape 1 : tests.**
  - `test_faits_memeDecisionMalgreLInactivite` ;
  - `test_faits_ligneDeDebugSeulementAuChangement` : dix ticks où seul `hidIdle` change → aucune ligne « faits: » ;
  - `test_logDebug_nEvaluePasLeMessageSiCoupe` ;
  - `test_raisonSuitLesFaitsSansRepublier` : `command:on`, confirmé, puis `lock-screen-ui` sans nouvelle publication ;
  - `test_offSurcharge_sourceOverride` ;
  - `test_statusDonneLaRaisonDesFaits` ;
  - `test_config_dureesEnSecondes`.
- [ ] **Étape 2 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre.**
- [ ] **Étape 4 : `swift test --scratch-path /private/tmp/macstatusd-plan3/build`, puis le selftest des
  contraintes globales** — attendu : OK.
- [ ] **Étape 5 : commit** « Observabilité : faits comparables, raison à jour, code mort retiré ».

---

## Banc de validation

### Tâche 8 : banc 2 avec Djoko

Le contrôleur mène ce banc avec Djoko ; aucun sous-agent. Le protocole est écrit d'abord, dans la forme
du banc 1 (qui fait quoi, étapes, attendu, si ça rate) : `.superpowers/banc/protocole-banc-2.md`, local.

Mise en place :
- l'instance de banc tourne sur le binaire de la tête, avec les vraies actions (`stop_screensaver_on_wake`
  et `off_escalate_to_display_sleep` à vrai) ;
- elle écoute sur 19400, et n'envoie qu'au récepteur de 19401 ;
- la sonde tourne, et le daemon réel reste en marche.

Contrôles :

1. **A3, paysages aériens lancés par l'inactivité** : OFF `screensaver:sac`. Une frappe → ON
   (`écarté-par-activité`). 30 s sans rien → OFF (`réaffiché`). Déverrouillage → ON `desktop-ui`.
2. **`/wake` sur chacune des trois familles**, économiseur lancé par l'inactivité puis commandé : le
   panneau apparaît et ON est confirmé (`écarté-par-commande`). Sans geste, l'économiseur revient, et OFF
   environ 30 s plus tard.
3. **`/sleep` puis `/wake` 0,3 s après** (B4) : état final ON, panneau visible.
4. **Réglage mixte** (Message au centre, l'économiseur tiers sur les côtés) : ce que montre l'arrêt natif.
   La décision va au registre : limite documentée, ou parade.
5. **`/wake` sur un économiseur d'inactivité dont le contrôleur a éteint les écrans** (`pmset
   displaysleepnow`) : ce qui s'affiche, et l'état confirmé.
6. **B5 rejoué** : « fin de la veille sans avis de réveil » au moment de la frappe, et plus d'OFF pendant
   que Djoko est actif.
7. **B6 rejoué**, après le correctif de PTZBot s'il est déployé : aucun rattrapage à tort.
8. **`SACScreenSaverStartNow`** (`saver-ctl demarrage`) sur le bureau : lance-t-il l'économiseur réglé,
   écran par écran, comme l'inactivité ? Si oui, la proposition pour l'action OFF va au registre (plan 4
   ou suivant).
9. **Séquence C du banc 1** : fermeture de session (C16).
10. **Chemin complet de l'hôte de Message** (`ps -o comm= -p <PID>`, lecture seule). `SaverHostRule` est
    corrigée si besoin, avec son test, dans un commit à part.
11. En option, la nuit : coût du tick écran éteint, même méthode qu'à la tâche 6.

- [ ] **Étape 1 :** protocole écrit, et lu par Djoko.
- [ ] **Étape 2 :** banc mené. Remise en état : Djoko remet ses réglages ; le contrôleur arrête la sonde,
  l'instance et le récepteur par leur PID, puis vérifie `/health` de l'instance réelle et que les ports
  19400 et 19401 sont libres.
- [ ] **Étape 3 :** résultats dans `.superpowers/banc/banc-2-<date>/resultats.md`, et décisions au
  registre. Chaque correction : un test, puis un commit.

---

## Fin du plan 3

- [ ] Relecture de toute la branche par Opus, avant le report sur `main` : concurrence, faux ON et faux OFF,
  appels de login.framework.
- [ ] Vérification finale :
  - `swift test --scratch-path /private/tmp/macstatusd-plan3/build` → tout OK ;
  - selftest des contraintes globales, écran allumé puis écran éteint → aucun échec ;
  - `--once` sur le vrai Mac → des faits cohérents avec ceux de l'instance réelle.
- [ ] Registre, rubrique « Pour le README (plan 4) », complète :
  - `saver_redisplay_idle_seconds` à 30 ;
  - preuves `sac`, `process`, `notification+hôte`, `écarté-par-commande` ;
  - raisons `displays-reconfiguring` et `command:off/override` ;
  - champs `saver_detection`, `saver_dismissal`, `display_evidence`, `display_list`, `main_display` et
    `facts_reason` ;
  - `stop_screensaver_on_wake`, qui commande désormais l'arrêt natif ;
  - la dépendance aux fonctions privées de login.framework, et ses replis ;
  - la limite du réglage mixte ;
  - l'écho de `--debug` ;
  - la fin des fenêtres comme preuve.
