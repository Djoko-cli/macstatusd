# Plan 2 — Socle testable, sécurité HTTP et résilience (lots 1 à 3)

> **Pour les agents qui exécutent :** sous-compétence requise, `superpowers:subagent-driven-development`
> (recommandée) ou `superpowers:executing-plans`, tâche par tâche. Les étapes se cochent (`- [ ]`).

**But :** la logique de macstatusd devient une bibliothèque testée par XCTest. Le serveur HTTP n'obéit
plus qu'à un appelant authentifié et légitime. Le daemon résiste aux pannes relevées par l'audit.

**Architecture :** une cible bibliothèque `MacStatusCore` porte toute la logique sans effet de bord :
- config, moteur d'état, oracle de l'économiseur ;
- analyse HTTP, règles d'accès, limites ;
- client webhook.

Elle reçoit ses dépendances par protocoles : horloge, planificateur, signaux système, actions, transport.
L'exécutable `macstatusd` ne garde que les adaptateurs du système (IOKit, CoreGraphics, NSWorkspace,
`Process`, `NWListener`, `URLSession`, fichier de journal) et le câblage. Moteur et webhook partagent
une seule file série.

**Outils :** Swift 6.x, `swift-tools-version: 5.9`, mode de langage 5, XCTest, aucune dépendance externe.

**Spec :** `docs/superpowers/specs/2026-10-25-correctifs-audit-design.md` (lots 1, 2, 3 ; décisions C4 à
C9, C12, C14 à C16). Détail des constats, local : `.superpowers/audit/audit-2026-09-25.md` (chercher
`## Fnn`). Ce fichier contient des mesures réelles : n'en recopier aucune valeur.

## Contraintes globales

- Cible `.macOS(.v13)`, aucune dépendance externe. Commentaires, journaux et sorties en français.
- Anonymat : aucun identifiant réel dans le code, les tests, les commits. Valeurs d'essai inventées et
  reconnaissables (`192.0.2.10`, `jeton-essai-0123456789abcdef`, `Pièce 1`). La garde `pre-push` du plan
  1 est installée ; `--no-verify` interdit.
- Commandes exécutables telles quelles sous zsh : aucune dépendance au découpage d'une variable non citée.
- **L'instance réelle n'est jamais touchée** : sur `127.0.0.1:9090`, seulement `GET /state`, `/status` et
  `/health`. Les instances de test écoutent sur `127.0.0.1` et sur un port de la plage 19000–19999, avec
  `off_command` et `wake_command` à `["/usr/bin/true"]`, `off_escalate_to_display_sleep: false` et
  `stop_screensaver_on_wake: false`. Elles sont arrêtées à la fin de chaque étape.
- Aucun test automatique ne rallume l'écran, ne lance l'économiseur ni ne met le Mac en veille.
- Chaque commit se termine par la ligne d'attribution du projet ; auteur et committer en noreply.
- Version : `macstatusdVersion` passe à `"0.6.0-dev"` à la tâche 1, et à `"0.6.0"` seulement au plan 4.
- **Relecture de chaque tâche** : en plus des tests, le relecteur lance une fois le nouveau binaire en
  lecture seule sur le vrai Mac, avec `.build/debug/macstatusd --once --config <config d'essai>`. Il
  compare ses faits à ceux de l'instance réelle (`curl -s 127.0.0.1:9090/status`), parce que les faux
  signaux ne disent pas tout.

## Points de vigilance

1. **L'appel réel de HA** : `GET /wake?action=WAKE`, `Host: <IPv4 littérale>:9090`, en-tête
   `X-Auth-Token`, ni `Origin` ni `Sec-Fetch-*`. Il doit passer (200). Test `test_appelReelDeHA_accepte`
   (tâche 8).
2. **Une page web du Mac** qui vise `127.0.0.1` avec `Sec-Fetch-Site: cross-site` : refusée avant tout
   contrôle du jeton (403). Test `test_requeteNavigateurCrossSite_refusee` (tâche 8).
3. **Un client HTTP/1.0 sans `Host`** (vieux script, `curl --http1.0`), avec le bon jeton : accepté. Le
   DNS rebinding exige un `Host`. Test `test_http10SansHost_avecJeton_accepte` (tâche 8).
4. **HA injoignable pendant des heures, puis de retour** : l'état voulu arrive au plus tard au réessai
   lent suivant (≤ 60 s), sans attendre le battement de cœur. Test
   `test_cibleRevenue_estResynchroniseeParLeReessaiLent` (tâche 15).
5. **Config durcie puis cassée par une virgule** : le daemon n'écoute plus qu'en boucle locale, les
   commandes et `/health` répondent 503. Il ne retombe jamais en écoute ouverte sans jeton. Tests
   `test_jsonInvalide_donneModeDegrade` (tâche 12) et `test_modeDegrade_commandesEt503` (tâche 12).

---

## Lot 1 — Socle testable

### Tâche 1 : cible `MacStatusCore`, config et journalisation

**Fichiers :**
- Modifier : `Package.swift`
- Créer : `Sources/MacStatusCore/Config.swift` (déplacé de `Sources/macstatusd/Config.swift`),
  `Sources/MacStatusCore/Logging.swift`, `Sources/MacStatusCore/Version.swift` (déplacé)
- Modifier : `Sources/macstatusd/Log.swift` (devient le récepteur fichier), tous les fichiers de
  `Sources/macstatusd/` (`import MacStatusCore`)
- Test : `Tests/MacStatusCoreTests/ConfigTests.swift`, `Tests/MacStatusCoreTests/Support/Fakes.swift`

**Interfaces :**
- Produit (`MacStatusCore`, public) :
  - `enum LogLevel: Int, Comparable { case error, warn, info, debug; static func parse(_: String) -> LogLevel; var tag: String }` ;
  - `protocol LogSink: AnyObject { func log(_ level: LogLevel, _ message: String) }` ;
  - `enum CoreLog { static var sink: LogSink? }` ;
  - `func logError(_:)`, `logWarn(_:)`, `logInfo(_:)`, `logDebug(_:)`, qui écrivent dans `CoreLog.sink` ;
  - `struct Config` et `enum OffAction`, tels qu'aujourd'hui, `public` ;
  - `static func Config.parse(data: Data?) -> (config: Config, warnings: [String])`, que
    `Config.load(path:)` appelle après la lecture du fichier ;
  - `let macstatusdVersion = "0.6.0-dev"`.
- Produit (`Tests/.../Support/Fakes.swift`) : `final class CaptureLog: LogSink { var lines: [(LogLevel, String)] }`.

- [x] **Étape 1 : `Package.swift`** — trois cibles : `.target(name: "MacStatusCore", path: "Sources/MacStatusCore")`,
  `.executableTarget(name: "macstatusd", dependencies: ["MacStatusCore"], path: "Sources/macstatusd")`,
  `.testTarget(name: "MacStatusCoreTests", dependencies: ["MacStatusCore"], path: "Tests/MacStatusCoreTests")`.
- [x] **Étape 2 : tests de caractérisation de la config**, écrits contre le comportement actuel :

```swift
func test_fichierAbsent_donneLesDefautsEtUnAvertissement() {
    let r = Config.parse(data: nil)
    XCTAssertFalse(r.config.enabled); XCTAssertEqual(r.config.port, 9090)
    XCTAssertEqual(r.warnings.count, 1)
}
func test_clesConnues_sontLues() {
    let json = #"{"enabled":true,"webhook_base_url":"http://192.0.2.10:51828","port":"9191","settle_off_ms":900}"#
    let r = Config.parse(data: Data(json.utf8))
    XCTAssertTrue(r.config.enabled); XCTAssertEqual(r.config.port, 9191); XCTAssertEqual(r.config.settleOffMS, 900)
}
func test_bornes_sontAppliquees() {        // poll_interval_ms 10 → 100, settle_on_ms 99999 → 10000
    let r = Config.parse(data: Data(#"{"poll_interval_ms":10,"settle_on_ms":99999}"#.utf8))
    XCTAssertEqual(r.config.pollIntervalMS, 100); XCTAssertEqual(r.config.settleOnMS, 10_000)
}
func test_cleInconnue_donneUnAvertissement() {
    let r = Config.parse(data: Data(#"{"prot":9090}"#.utf8))
    XCTAssertTrue(r.warnings.contains { $0.contains("prot") })
}
func test_offActionInconnue_garderLeDefaut() {
    XCTAssertEqual(Config.parse(data: Data(#"{"off_action":"nimporte"}"#.utf8)).config.offAction, .screensaver)
}
```

- [x] **Étape 3 : `swift test --filter ConfigTests`** — attendu : échec de compilation (`MacStatusCore`
  absent).
- [x] **Étape 4 : déplacer et rendre public** `Config.swift`, `Version.swift` et le niveau de journal ;
  `Log.swift` (exécutable) implémente `LogSink` et `main.swift` fait `CoreLog.sink = Log.shared`.
- [x] **Étape 5 : `swift build && swift test --filter ConfigTests`** — attendu : build OK, 5 tests OK.
- [x] **Étape 6 : commit** « Socle : cible MacStatusCore, config et journal ».

### Tâche 2 : horloge, planificateur et oracle de l'économiseur

**Fichiers :**
- Créer : `Sources/MacStatusCore/Clock.swift`, `Sources/MacStatusCore/Scheduler.swift`,
  `Sources/MacStatusCore/SystemSignals.swift`, `Sources/MacStatusCore/Facts.swift` (types seulement)
- Déplacer : `Sources/macstatusd/ScreenSaverOracle.swift` → `Sources/MacStatusCore/`
- Créer : `Sources/macstatusd/LiveSystemSignals.swift` (le `SignalReader` actuel, plus les sondes de
  l'oracle : process `ScreenSaverEngine`, fenêtres)
- Supprimer : `Sources/macstatusd/RuleCheck.swift`, l'option `--check-rules` de `main.swift`
- Test : `Tests/MacStatusCoreTests/ScreenSaverOracleTests.swift`

**Interfaces :**
- Produit (public) :
  - `protocol Clock: AnyObject { func monotonic() -> Double; func wall() -> Date }`, et sa mise en
    œuvre `final class SystemClock: Clock`. `monotonic()` lit `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`,
    qui compte aussi le temps de sommeil, en secondes ;
  - `protocol Cancellable { func cancel() }` et
    `protocol Scheduler: AnyObject { @discardableResult func schedule(after seconds: Double, _ work: @escaping () -> Void) -> Cancellable }`,
    mis en œuvre par `final class DispatchScheduler: Scheduler { init(queue: DispatchQueue) }` ;
  - `struct SessionState { var locked: Bool; var loggedIn: Bool; var onConsole: Bool; var evidence: String }` ;
  - `struct DisplayState { var asleep: Bool; var onlineCount: Int; var enumerationOK: Bool }` ;
  - `enum WindowVerdict { case visible, notVisible, unavailable }` ;
  - `protocol SystemSignals: AnyObject { func session() -> SessionState; func display() -> DisplayState; func hidIdleSeconds() -> Double; func secureInputActive() -> Bool; func saverEnginePID() -> Int32; func saverWindow() -> WindowVerdict }` ;
  - `struct Facts` (champs actuels, plus `onConsole: Bool`, lu dans `SessionState`) ;
  - `final class ScreenSaverOracle { init(minimumInterval: Double, dismissOnInput: Bool, dismissGrace: Double, redisplayIdle: Double, signals: SystemSignals); func noteNotification(active: Bool); func verdict(now: Double, hidIdle: Double) -> Verdict }`.
    Les instants deviennent des `Double` monotones, et les sondes sont lues dans `signals`.
- Produit (`Fakes.swift`) :
  - `final class TestClock: Clock { var t: Double; var date: Date; func advance(_ s: Double) }` ;
  - `final class TestScheduler: Scheduler { func runDue(at t: Double) }` : exécute les tâches échues, dans l'ordre ;
  - `final class FakeSignals: SystemSignals` : champs mutables, un par méthode.

- [x] **Étape 1 : porter les 17 vérifications de `RuleCheck.swift`** en tests XCTest, une par
  vérification. Mêmes scénarios, mêmes valeurs : grâce 1,5 s, réaffichage à 90 s, PID 4242 puis 5000.
  Noms en `test_<scénario>` (exemple : `test_activiteApresDemarrage_ecarteEtDoncON`).
- [x] **Étape 2 : `swift test --filter ScreenSaverOracleTests`** — attendu : échec de compilation.
- [x] **Étape 3 : déplacer l'oracle et introduire les protocoles** ; `LiveSystemSignals` réunit
  `SignalReader`, `runningProcesses()` et la lecture des fenêtres.
- [x] **Étape 4 : `swift test --filter ScreenSaverOracleTests`** — attendu : 17 tests OK.
- [x] **Étape 5 : commit** « Socle : horloge, signaux injectés, oracle testé par XCTest ».

### Tâche 3 : moteur d'état extrait (`EngineCore`) et son exécuteur

**Fichiers :**
- Créer : `Sources/MacStatusCore/EngineCore.swift`, `Sources/MacStatusCore/Commands.swift`
- Créer : `Sources/macstatusd/EngineRunner.swift` (file série, minuteries, contrats de file)
- Modifier : `Sources/macstatusd/StateEngine.swift` (supprimé, remplacé par les deux précédents),
  `PowerActions.swift` (adopte `CommandActions`), `PowerWatcher.swift` (émet des `SystemEvent`), `main.swift`
- Test : `Tests/MacStatusCoreTests/EngineCoreTests.swift`

**Interfaces :**
- Produit (public) :
  - `protocol CommandActions: AnyObject { var hasOffOverride: Bool { get }; func runOff(_: OffAction); func displaySleep(); func wake(); func stopScreenSaver() }` ;
  - `protocol StatePublisher: AnyObject { func publish(_ state: Bool, force: Bool); var statusDictionary: [String: Any] { get } }` ;
  - `enum SystemEvent { case systemDidWake, screensDidSleep, screensDidWake, screenSaverDidStart, screenSaverDidStop, screenLocked, screenUnlocked, sessionActive, sessionInactive, saverProcessChanged }` ;
  - `final class EngineCore { init(config: Config, clock: Clock, signals: SystemSignals, oracle: ScreenSaverOracle, actions: CommandActions, publisher: StatePublisher) }`, avec :
    - `func start()`, `func tick()`, `func handle(_ event: SystemEvent)`, `func willSleep(_ allow: @escaping () -> Void)` ;
    - `func requestOff(source: String)`, `func requestOn(source: String)`, `func resync()`, `func heartbeat()` ;
    - `var currentState: Bool`, `func statusSnapshot() -> [String: Any]`, `func inspect() -> (state: Bool, reason: String, facts: Facts)`.

    `EngineCore` n'a ni file ni minuterie : le contrat est qu'on l'appelle toujours depuis une même file.
- Produit (exécutable) : `final class EngineRunner`, qui possède `let queue = DispatchQueue(label: "macstatusd.state")`
  et les minuteries de scrutation et de battement de cœur. Il expose les mêmes opérations : `async` pour
  les commandes, `sync` pour les lectures, et `dispatchPrecondition(condition: .notOnQueue(queue))`
  avant chaque `sync`.
- Produit (`Fakes.swift`) : `FakeActions` (journal des appels) et `FakePublisher` (états publiés, avec `force`).

- [x] **Étape 1 : tests de caractérisation**, contre le comportement actuel :
  - `test_prioriteDesRegles` : faits construits par `FakeSignals`, une assertion par ligne du tableau
    ci-dessous ;

    | Faits | État | Raison |
    |---|---|---|
    | veille | OFF | `system-asleep` |
    | écran éteint | OFF | `display-asleep` |
    | économiseur actif | OFF | commence par `screensaver:` |
    | aucun écran (énumération OK) | OFF | `no-display` |
    | verrouillé | ON | `lock-screen-ui` |
    | pas de session ouverte | ON | `login-window-ui` |
    | bureau | ON | `desktop-ui` |
  - `test_lissage_offAttend800ms_onAttend300ms` ;
  - `test_commandeOff_confirmeeParLesFaits` ;
  - `test_commandeSansEffet_escaladeA2500ms_puisRetourAuxFaitsA12s` ;
  - `test_offSurSessionVerrouillee_eteintLEcran` ;
  - `test_dejaOff_aucuneAction` ;
  - `test_trouDeScrutation_au_dela_de_10s_resynchronise` ;
  - `test_battementDeCoeur_republieAvecForce`.
- [x] **Étape 2 : `swift test --filter EngineCoreTests`** — attendu : échec de compilation.
- [x] **Étape 3 : extraire `EngineCore`** de `StateEngine.swift`. Les `Date()` deviennent `clock.monotonic()`
  pour les durées et `clock.wall()` pour les horodatages affichés. `EngineRunner` porte la file, les
  minuteries et les contrats de file (F81).
- [x] **Étape 4 : `swift test`** — attendu : tous les tests OK ; puis `bash scripts/selftest.sh` sur les
  sections qui ne dépendent pas de l'écran — attendu : OK.
- [x] **Étape 5 : commit** « Socle : moteur d'état extrait et testé, file unique vérifiée ».

### Tâche 4 : client webhook testable

**Fichiers :**
- Déplacer : `Sources/macstatusd/Webhook.swift` → `Sources/MacStatusCore/WebhookClient.swift`
- Créer : `Sources/macstatusd/URLSessionTransport.swift`
- Test : `Tests/MacStatusCoreTests/WebhookClientTests.swift`

**Interfaces :**
- Produit (public) :
  - `struct WebhookRequest { let url: URL; let method: String; let headers: [String: String] }` ;
  - `enum WebhookOutcome { case delivered(status: Int); case failed(detail: String) }` ;
  - `protocol WebhookTransport: AnyObject { func send(_ request: WebhookRequest, _ completion: @escaping (WebhookOutcome) -> Void) }` ;
  - `final class WebhookClient: StatePublisher { init(config: Config, transport: WebhookTransport, scheduler: Scheduler, clock: Clock) }`.

  Il n'a plus de file propre : il vit sur la file du moteur, et le transport rappelle sur cette file.
- Produit (`Fakes.swift`) : `FakeTransport`, qui enregistre les requêtes et répond selon un script
  (`[WebhookOutcome]`).

- [x] **Étape 1 : tests de caractérisation :**
  - `test_urlEstConstruiteAvecAccessoryIdEtState` : `http://192.0.2.10:51828/?accessoryId=mac&state=true` ;
  - `test_changementsFusionnes_seulLeDernierPart` ;
  - `test_echec_reessaieA0_5s_2s_5s_puisAbandonne` ;
  - `test_force_reemetUnEtatDejaConfirme`.
- [x] **Étape 2 : `swift test --filter WebhookClientTests`** — attendu : échec de compilation.
- [x] **Étape 3 : déplacer et injecter** : délais par `scheduler`, envois par `transport`.
  `URLSessionTransport` reprend la session éphémère actuelle et rappelle sur la file reçue.
- [x] **Étape 4 : `swift test`** — attendu : tout OK.
- [x] **Étape 5 : commit** « Socle : client webhook injecté et testé ».

### Tâche 5 : analyse HTTP et routage testables

**Fichiers :**
- Créer : `Sources/MacStatusCore/HTTPMessage.swift` (`HTTPRequest`, `HTTPResponse`),
  `Sources/MacStatusCore/RequestParser.swift`, `Sources/MacStatusCore/Router.swift`
- Modifier : `Sources/macstatusd/HTTPServer.swift` (adaptateur `NWListener` seul), `main.swift`
- Test : `Tests/MacStatusCoreTests/RequestParserTests.swift`, `Tests/MacStatusCoreTests/RouterTests.swift`

**Interfaces :**
- Produit (public) :
  - `struct HTTPRequest { var method, target, path, version: String; var query: [String: String]; var headers: [String: String]; var peer: String; var peerIsLoopback: Bool }`.
    Les en-têtes sont en minuscules ; `peerIsLoopback` est calculé par l'adaptateur à partir du
    `NWEndpoint`, jamais à partir d'une chaîne ;
  - `struct HTTPResponse { var status: Int; var contentType: String; var body: Data; var headers: [String: String] }` ;
  - `enum RequestParser { static func parse(head: Data) -> HTTPRequest? }` : le comportement actuel ;
  - `protocol EngineFacade: AnyObject { var currentState: Bool { get }; func statusSnapshot() -> [String: Any]; func requestOff(source: String); func requestOn(source: String); func resync() }`,
    que `EngineRunner` adopte ;
  - `final class Router { init(config: Config, engine: EngineFacade); func handle(_ request: HTTPRequest) -> HTTPResponse }`.

- [x] **Étape 1 : tests de caractérisation** :
  - `test_parse_ligneEtEnTetesEtQuery` ;
  - `test_routes_stateStatusHealth` ;
  - `test_commandeSansJetonConfigure_appelleLeMoteur` ;
  - `test_cheminInconnu_404` ;
  - `test_post_405`.
- [x] **Étape 2 : `swift test --filter "RequestParserTests|RouterTests"`** — attendu : échec de compilation.
- [x] **Étape 3 : extraire** l'analyse et le routage ; l'adaptateur ne fait plus que lire, appeler `Router`
  et écrire.
- [x] **Étape 4 : `swift test`, puis `bash scripts/selftest.sh`** — attendu : OK.
- [x] **Étape 5 : commit** « Socle : analyse HTTP et routage testables ».

### Tâche 6 : selftest hermétique et critère de sortie du lot 1

F24, F66.

**Fichiers :**
- Modifier : `scripts/selftest.sh`, `scripts/validate-live.sh`

**Interfaces :** aucune nouvelle.

- [x] **Étape 1 : `selftest.sh`** :
  - lance d'abord `swift test` ;
  - lit `--once` au départ ; si l'écran est éteint, la session verrouillée ou le Mac en veille, il marque
    `SAUTÉ (écran éteint)` les sections qui en dépendent, sans les compter en échec ;
  - `field()` renvoie `__ERREUR__` si curl ou le JSON échoue, ce qui distingue « clé absente » d'« erreur ».
- [x] **Étape 2 : `validate-live.sh`** : la fenêtre d'observation du journal lit aussi `macstatusd.log.1`
  et filtre par horodatage, ce qui la rend sûre en cas de rotation.
- [x] **Étape 3 : critère de sortie du lot 1**, en trois commandes :
  - `swift test --list-tests 2>/dev/null | sed -E 's/^[^.]+\.([^/]+)\/.*/\1/' | sort | uniq -c` — attendu
    au moins : `ConfigTests` 5, `ScreenSaverOracleTests` 17, `EngineCoreTests` 8, `WebhookClientTests` 4,
    `RequestParserTests` 1, `RouterTests` 4. Aucun test d'un composant de `MacStatusCore` hors de
    `MacStatusCoreTests` ;
  - `grep -rln "import CoreGraphics\|import IOKit\|import AppKit\|import Network" Sources/MacStatusCore`
    — attendu : aucune ligne ;
  - `bash scripts/selftest.sh`, avec l'écran éteint comme allumé — attendu : aucun échec.
- [x] **Étape 4 : commit** « Tests : selftest hermétique, critère de sortie du socle ».

---

## Lot 2 — Surface HTTP et authentification

### Tâche 7 : analyseur strict et journal sûr

F79, F28.

**Fichiers :**
- Modifier : `Sources/MacStatusCore/RequestParser.swift`, `Sources/MacStatusCore/Logging.swift`,
  `Sources/MacStatusCore/HTTPMessage.swift`
- Test : `RequestParserTests.swift`, `Tests/MacStatusCoreTests/LoggingTests.swift`

**Interfaces :**
- Produit : `enum ParseError: Error { case malformedRequestLine, unsupportedVersion, invalidMethod, invalidTarget, missingHost }`
  et `RequestParser.parse(head: Data) -> Result<HTTPRequest, ParseError>`, qui remplace la version
  optionnelle.
- Produit : `func escapeForLog(_ s: String, limit: Int = 200) -> String`. Les caractères de contrôle (sauf
  la tabulation), `0x7F–0x9F`, `U+2028` et `U+2029` deviennent `\u{..}`, et la chaîne est tronquée à
  `limit` caractères avec `…`.
- Produit : `HTTPResponse.methodNotAllowed(allow: String)` → 405 avec l'en-tête `Allow`.

- [x] **Étape 1 : tests :**

```swift
func test_ligneEnTroisElements() { XCTAssertEqual(parse("GET / \r\n\r\n"), .failure(.malformedRequestLine)) }
func test_methodeSensibleALaCasse() { XCTAssertEqual(parse("get / HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n"), .failure(.invalidMethod)) }
func test_version20_refusee() { XCTAssertEqual(parse("GET / HTTP/2.0\r\nHost: x\r\n\r\n"), .failure(.unsupportedVersion)) }
func test_http11SansHost_refuse() { XCTAssertEqual(parse("GET /state HTTP/1.1\r\n\r\n"), .failure(.missingHost)) }
func test_http10SansHost_accepte() { XCTAssertNotNil(try? parse("GET /state HTTP/1.0\r\n\r\n").get()) }
func test_cibleNonImprimable_refusee() { XCTAssertEqual(parse("GET /a\u{1B}[31m HTTP/1.1\r\nHost: x\r\n\r\n"), .failure(.invalidTarget)) }
func test_escapeForLog() {
    XCTAssertEqual(escapeForLog("a\u{1B}b\nc"), "a\\u{1B}b\\u{0A}c")
    XCTAssertEqual(escapeForLog(String(repeating: "x", count: 250)).count, 201)
}
```

- [x] **Étape 2 : `swift test --filter "RequestParserTests|LoggingTests"`** — attendu : échecs.
- [x] **Étape 3 : mettre en œuvre.** `Router` répond 400 à toute `ParseError`, et 405 avec `Allow` ;
  l'adaptateur journalise le chemin par `escapeForLog`.
- [x] **Étape 4 : `swift test`** — attendu : OK.
- [x] **Étape 5 : commit** « HTTP : analyseur strict, journal sans caractères de contrôle ».

### Tâche 8 : jeton et règles d'accès

F01, F02, F06, F25 ; décisions C5, C6, C7.

**Fichiers :**
- Créer : `Sources/MacStatusCore/AccessPolicy.swift`
- Modifier : `Config.swift` (clés `allow_query_token` défaut `false`, `allowed_hosts` défaut `[]`),
  `Router.swift`
- Créer : `Sources/macstatusd/LocalNames.swift` (noms `.local` du Mac par SCDynamicStore, et nom d'hôte)
- Test : `Tests/MacStatusCoreTests/AccessPolicyTests.swift`, `RouterTests.swift`

**Interfaces :**
- Produit :
  - `enum RouteClass { case health, read, command, unknown }`, et `static func classify(path: String) -> RouteClass` :
    `/health` → `.health` ; `/state` et `/status` → `.read` ; `/sleep`, `/off`, `/wake`, `/on` et `/resync`
    → `.command` ;
  - `enum AccessDecision: Equatable { case allow; case deny(status: Int, reason: String) }` ;
  - `struct AccessPolicy { init(authToken: String, allowQueryToken: Bool, allowedHosts: [String], localNames: [String]); func decide(_ request: HTTPRequest) -> AccessDecision }` ;
  - `func constantTimeEquals(_ a: String, _ b: String) -> Bool`.

  `decide` applique ces règles, dans l'ordre :
  1. `.health` → `allow`.
  2. Contrôle de `Host`, sans le port ni les crochets IPv6. Il doit être un littéral IPv4 ou IPv6,
     `localhost`, un des `localNames` ou un des `allowedHosts` (sans casse). Sinon `deny(403, "host")`.
     Un `Host` absent (HTTP/1.0) passe ce contrôle.
  3. En-tête `origin` présent, ou `sec-fetch-site` présent et différent de `none` →
     `deny(403, "origin")`.
  4. Méthode : `.command` n'accepte que GET, sinon `deny(405, "method")`. `.read` accepte GET et HEAD.
  5. Jeton : on lit `x-auth-token`, ou `authorization` au format `Bearer <jeton>` (schéma sans casse), ou
     `query["token"]` si `allowQueryToken`.
     - Sans jeton configuré : `allow` si `peerIsLoopback`, sinon `deny(403, "no-token-configured")`.
     - Avec jeton : `.command` exige un jeton égal (`constantTimeEquals`), sinon `deny(401, "token")` ;
       `.read` passe si `peerIsLoopback` ou si le jeton est égal, sinon `deny(401, "token")`.

- [x] **Étape 1 : tests**, dont les trois premiers points de vigilance :
  - `test_appelReelDeHA_accepte` : GET `/wake?action=WAKE`, `Host: 192.0.2.10:9090`, bon jeton, pair non
    local → `allow` ;
  - `test_requeteNavigateurCrossSite_refusee` : `Host: 127.0.0.1:9090`, `Sec-Fetch-Site: cross-site`,
    bon jeton → `deny(403, "origin")` ;
  - `test_http10SansHost_avecJeton_accepte` ;
  - `test_hostRebinde_refuse` : `Host: evil.example:9090` → `deny(403, "host")` ;
  - `test_nomLocalDuMac_accepte` : `Host: Mac-Essai.local:9090` avec `localNames` = `["Mac-Essai.local"]` ;
  - `test_commandeSansJeton_401_memeEnBoucleLocale` ;
  - `test_lectureEnBoucleLocale_sansJeton_acceptee` ;
  - `test_lectureDistante_sansJeton_401` ;
  - `test_jetonEnQuery_refuseParDefaut_accepteSiOption` ;
  - `test_bearerSansCasse` : `authorization: bearer <jeton>` accepté ;
  - `test_head_surCommande_405` ;
  - `test_sansJetonConfigure_distant_403_local_allow` ;
  - `test_constantTimeEquals` : vrai seulement à l'égalité, longueurs différentes comprises.
- [x] **Étape 2 : `swift test --filter "AccessPolicyTests|RouterTests"`** — attendu : échecs.
- [x] **Étape 3 : mettre en œuvre.** `Router` appelle `decide` avant toute route. Au démarrage, si aucun
  jeton n'est configuré, le daemon journalise un WARN (un ERROR si l'écoute n'est pas limitée à la
  boucle locale).
- [x] **Étape 4 : `swift test`, puis `bash scripts/selftest.sh`**, cas jeton mis à jour : instance B
  avec `jeton-essai-0123456789abcdef` en en-tête — attendu : OK.
- [x] **Étape 5 : commit** « HTTP : jeton par en-tête, contrôle de Host et d'origine ».

### Tâche 9 : limites de débit et commandes idempotentes

F07, F13, F26, F43 ; décision C8. F13 et F43 appartiennent au lot 3 dans la conception ; ils sont
traités ici parce qu'ils touchent le même code.

**Fichiers :**
- Créer : `Sources/MacStatusCore/RateLimits.swift`
- Modifier : `Router.swift`, `EngineCore.swift`
- Test : `Tests/MacStatusCoreTests/RateLimitsTests.swift`, `EngineCoreTests.swift`

**Interfaces :**
- Produit :
  - `final class TokenBucket { init(rate: Double, burst: Int, clock: Clock); func take() -> Bool }` ;
  - `final class AuthFailureTracker { init(limit: Int, window: Double, banFor: Double, clock: Clock); func recordFailure(peer: String) -> (banned: Bool, shouldLog: Bool, count: Int); func isBanned(peer: String) -> Bool }`.
    `shouldLog` vaut vrai au plus une fois par pair et par minute.
- Valeurs : seau des commandes 5/s, rafale 10 ; échecs 10 en 60 s, puis interdiction pendant 60 s.
- Réponse : 429 `too many requests`.

- [x] **Étape 1 : tests :**
  - `test_seau_rafaleDe10_puis429_puisRecharge5ParSeconde` ;
  - `test_dixEchecsEn60s_interditPendant60s` ;
  - `test_journalDesEchecs_uneLigneParPairEtParMinute` ;
  - `EngineCoreTests.test_doublonOff_pendantUneCommandeOff_aucuneActionEtEcheanceInchangee` ;
  - `EngineCoreTests.test_onPuisOff_rapides_leDernierGagne` ;
  - `EngineCoreTests.test_onQuandDejaOn_aucuneAction`.
- [x] **Étape 2 : `swift test`** — attendu : échecs.
- [x] **Étape 3 : mettre en œuvre.** `Router` consulte le traqueur avant la politique (pair interdit →
  429) et le seau avant une commande. `EngineCore` :
  - ignore un doublon de même sens tant que l'intention est en cours ;
  - laisse une commande de sens opposé remplacer l'intention en cours ;
  - rafraîchit les faits avant un ON et ne fait rien si l'état est déjà ON et qu'aucune intention OFF
    n'est en cours.
- [x] **Étape 4 : `swift test`** — attendu : OK.
- [x] **Étape 5 : commit** « HTTP : limites de débit ; commandes idempotentes ».

### Tâche 10 : adaptateur d'écoute durci

F08, F32, F69, F21. F21 appartient au lot 3 dans la conception ; il est traité ici parce qu'il touche le
même fichier.

**Fichiers :**
- Créer : `Sources/MacStatusCore/ConnectionLimiter.swift`
- Modifier : `Sources/macstatusd/HTTPServer.swift`, `Config.swift` (`bind_address` accepte `0.0.0.0` et `::`)
- Test : `Tests/MacStatusCoreTests/ConnectionLimiterTests.swift`, `scripts/selftest.sh`

**Interfaces :**
- Produit : `final class ConnectionLimiter { init(maxTotal: Int, maxPerPeer: Int); func acquire(peer: String) -> Bool; func release(peer: String) }`.
  Valeurs : 32 au total, 8 par pair.
- Adaptateur :
  - délai d'obtention des en-têtes de 2 s ;
  - `release` appelé exactement une fois, à l'état final de la connexion (`.cancelled` ou `.failed`),
    protégé par un drapeau ;
  - options TCP posées par `NWParameters(tls: nil, tcp: tcpOptions)` ;
  - `.waiting(error)` journalisé une fois par épisode, puis `cancel()` et reprise au bout de 5 s si
    l'état ne change pas ;
  - le gestionnaire d'état ne touche `listener` que si c'est bien l'instance courante ;
  - message « à l'écoute sur … » exact : `[::]:<port> (IPv4+IPv6, toutes interfaces)`, ou l'adresse liée.

- [x] **Étape 1 : tests unitaires** : `test_limite32Total_8ParPair`, `test_releaseLibereUnePlace`. Puis
  `selftest.sh`, avec 3 nouveaux cas :
  - `connexions-pair` : 9 connexions ouvertes depuis 127.0.0.1, la 9e est refusée ;
  - `en-tetes-lents` : une connexion sans en-têtes est fermée en 2 à 3 s ;
  - `message-ecoute` : le journal contient `IPv4+IPv6`.
- [x] **Étape 2 : lancer les tests** — attendu : échecs.
- [x] **Étape 3 : mettre en œuvre.**
- [x] **Étape 4 : `swift test && bash scripts/selftest.sh`** — attendu : OK.
- [x] **Étape 5 : commit** « HTTP : plafond de connexions, délai d'en-têtes, écoute exacte ».

---

## Lot 3 — Résilience

### Tâche 11 : journal robuste

F05, F30, F61, et F29 (masquage des URL).

**Fichiers :**
- Modifier : `Sources/macstatusd/Log.swift`, `Sources/MacStatusCore/Logging.swift`
- Test : `Tests/MacStatusCoreTests/LoggingTests.swift`, `scripts/selftest.sh`

**Interfaces :**
- Produit (cœur) : `func redactURL(_ s: String) -> String`. Le mot de passe d'URL devient `***`, et la
  partie requête comme le dernier segment d'un chemin `/api/webhook/<id>` deviennent `<masqué>`. Une
  chaîne qui ne se lit pas comme une URL est entièrement masquée : `<url invalide>`.
- Exécutable :
  - ouverture par `open(path, O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC, 0o600)`, écriture par `write(2)` ;
  - un échec ferme le fichier, le signale une seule fois par `os_log`, puis retente l'ouverture au plus
    toutes les 60 s ;
  - toutes les 100 écritures, l'inode est comparé (`stat` contre `fstat`), et le fichier rouvert s'il a
    changé ou s'il a été supprimé ;
  - rotation en 5 générations (`.1` à `.5`) de 2 Mio ;
  - sortie standard et erreur standard écrites sans lever d'exception, et l'écho est coupé après un EPIPE.

- [ ] **Étape 1 : tests** :
  - `test_redactURL_motDePasseEtIdentifiantDeWebhook` :
    `http://u:secret@192.0.2.10:8123/api/webhook/abc123` → `http://u:***@192.0.2.10:8123/api/webhook/<masqué>` ;
  - `test_redactURL_invalide`.

  Puis `selftest.sh`, avec 3 nouveaux cas :
  - `journal-supprime` : le fichier de journal est supprimé pendant que l'instance tourne, et il est
    recréé ;
  - `journal-rotation` : 5 générations au plus ;
  - `stdout-ferme` : instance lancée en `-f | head -1`, toujours vivante 3 s plus tard.
- [ ] **Étape 2 : lancer les tests** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre** ; `main.swift` et le client webhook journalisent l'URL par `redactURL`.
- [ ] **Étape 4 : `swift test && bash scripts/selftest.sh`** — attendu : OK.
- [ ] **Étape 5 : commit** « Journal : écritures sans exception, réouverture, cinq générations ».

### Tâche 12 : config sûre et mode dégradé

F18, F62, F64.

**Fichiers :**
- Modifier : `Config.swift`, `Router.swift`, `main.swift`, `HTTPServer.swift`
- Test : `ConfigTests.swift`, `RouterTests.swift`

**Interfaces :**
- Produit :
  - `enum ConfigOrigin: Equatable { case file; case defaultsAbsent; case invalid(reason: String) }` ;
  - `Config.parse(data:)` retourne désormais `(config: Config, origin: ConfigOrigin, warnings: [String])`.
    `Config.load(path:)` distingue le fichier absent (`ENOENT` → `.defaultsAbsent`) du fichier illisible
    ou invalide (`.invalid`, avec l'erreur POSIX ou `NSDebugDescription`).
- En `.invalid` :
  - `bindAddress` est forcé à `127.0.0.1`, et les webhooks sont coupés ;
  - `Router` répond 503 `config invalide` aux commandes, et `/health` répond aussi 503 ;
  - `/status` expose `config_error`.
- Avertissements : une valeur hors bornes, un type inattendu ou une chaîne booléenne non reconnue
  donnent un avertissement nommé ; `0`, `false`, `no` et `off` sont acceptés. `off_command` et
  `wake_command` dont `argv[0]` n'est pas absolu donnent aussi un avertissement.
- CLI : `--config` ou `--port` sans valeur, ou un port hors de 1…65535, font sortir en code 2 avec un
  message.

- [ ] **Étape 1 : tests** :
  - `test_jsonInvalide_donneModeDegrade` : origine `.invalid`, `bindAddress == "127.0.0.1"`, `enabled == false` ;
  - `test_modeDegrade_commandesEt503` ;
  - `test_fichierAbsent_restePermissif` ;
  - `test_valeurHorsBornes_avertit` ;
  - `test_booleenChaine_offAccepte`.
- [ ] **Étape 2 : `swift test`** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre.**
- [ ] **Étape 4 : `swift test`** — attendu : OK.
- [ ] **Étape 5 : commit** « Config : mode dégradé fermé, avertissements nommés, CLI validée ».

### Tâche 13 : veille et réveil

F11, F12, F39, F74.

**Fichiers :**
- Modifier : `Sources/macstatusd/PowerWatcher.swift`, `EngineCore.swift`, `WebhookClient.swift`,
  `Commands.swift`
- Test : `EngineCoreTests.swift`, `WebhookClientTests.swift`

**Interfaces :**
- Produit :
  - `SystemEvent.systemWillNotSleep` ;
  - `StatePublisher.notifyWhenDelivered(timeout: Double, _ done: @escaping (Bool) -> Void)`, dont `done`
    est appelé exactement une fois (livré, échec définitif, ou délai écoulé), et dont l'attente est retirée
    à l'échéance ;
  - `EngineCore.willSleep(_ allow:)` devient asynchrone : il ne bloque plus la file. Il n'envoie que si
    l'état confirmé diffère de l'état voulu, et appelle `allow` par `notifyWhenDelivered(timeout: 1.5)`.
- `PowerWatcher` :
  - seul `kIOMessageSystemHasPoweredOn` donne `.systemDidWake` ; `WillPowerOn` reste au niveau DEBUG ;
  - `WillNotSleep` donne `.systemWillNotSleep` ;
  - `NSWorkspace.didWake` est ignoré si un réveil IOKit a été traité moins de 5 s plus tôt.
- `EngineCore` :
  - au réveil, il n'efface plus l'intention en cours ;
  - il force la publication seulement si la veille a duré au moins 30 s ou si l'état confirmé diffère ;
  - sur `.systemWillNotSleep` : `systemAsleep = false`, puis une évaluation non immédiate, sans toucher
    à l'intention.

- [ ] **Étape 1 : tests** :
  - `test_reveilPendantUneCommandeOn_conserveLIntention` ;
  - `test_veilleAnnulee_neToucheNiIntentionNiNotification` ;
  - `test_veille_attenteAsynchrone_allowAppeleUneSeuleFois` ;
  - `test_veille_offDejaConfirme_aucunEnvoi` ;
  - `test_reveilApresVeilleCourte_pasDePublicationForcee`.
- [ ] **Étape 2 : `swift test`** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre.**
- [ ] **Étape 4 : `swift test`** — attendu : OK.
- [ ] **Étape 5 : commit** « Veille : réveil fidèle à la commande, attente asynchrone ».

### Tâche 14 : arrêt propre

F04 ; décision C16.

**Fichiers :**
- Modifier : `EngineCore.swift`, `Sources/macstatusd/EngineRunner.swift`, `main.swift`,
  `launchd/com.djoko.macstatusd.plist` (`ExitTimeOut` à 5), `Config.swift` (`publish_off_on_exit`, défaut `true`)
- Test : `EngineCoreTests.swift`, `scripts/selftest.sh`

**Interfaces :**
- Produit : `EngineCore.shutdown(publishOff: Bool, _ done: @escaping () -> Void)`. Il verrouille le
  moteur : plus aucune publication ni action. Si `publishOff`, il publie OFF en `force`, en remplaçant une
  requête en vol, puis appelle `done` par `notifyWhenDelivered(timeout: 2)`.
- Marqueur : `~/Library/Application Support/macstatusd/restart-pending`. Au SIGTERM, s'il existe, il est
  supprimé et `publishOff` vaut `false`. Sinon `publishOff` vaut `config.publishOffOnExit`.
- `main.swift` : au signal, `EngineRunner.shutdown`, puis vidage du journal et `exit(0)`. L'appel
  asynchrone `server.stop()` est supprimé.

- [ ] **Étape 1 : tests** :
  - `test_arret_publieOff_puisPlusRien` (une évaluation après l'arrêt ne publie rien) ;
  - `test_arret_requeteEnVol_estRemplacee`.

  Puis `selftest.sh`, avec 2 nouveaux cas :
  - `sigterm-off` : SIGTERM à l'instance A, et le faux Homebridge reçoit `state=false` ;
  - `sigterm-marqueur` : marqueur posé dans un dossier d'essai (le chemin est configurable par la
    variable `MACSTATUSD_SUPPORT_DIR` pour les tests), et rien n'est reçu.
- [ ] **Étape 2 : lancer les tests** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre.**
- [ ] **Étape 4 : `swift test && bash scripts/selftest.sh`** — attendu : OK.
- [ ] **Étape 5 : commit** « Arrêt : OFF publié avant de partir, sauf redémarrage prévu ».

### Tâche 15 : webhook à plusieurs cibles et résilient

F20, F53, F54, F55, F57, F72 ; demande de la session HA.

**Fichiers :**
- Modifier : `WebhookClient.swift`, `Config.swift` (`webhook_targets`), `URLSessionTransport.swift`,
  `EngineCore.swift` (`statusSnapshot`)
- Test : `WebhookClientTests.swift`, `ConfigTests.swift`

**Interfaces :**
- Produit :
  - `struct WebhookTarget: Equatable { var url: String; var method: String; var headers: [String: String] }` ;
  - `Config.webhookTargets: [WebhookTarget]`. La clé `webhook_targets` est une liste
    d'objets `{url, method?, headers?}`. À défaut, `webhook_base_url` non vide donne une cible unique
    `{url, "GET", [:]}`.
- `WebhookClient` :
  - un état voulu/confirmé, une tentative, un compteur de génération et une minuterie de réessai **par
    cible** ;
  - une cible en panne ne retarde jamais une autre ;
  - après l'abandon, réessai lent à 15 s, 30 s, puis toutes les 60 s, tant que l'état n'est pas confirmé ;
  - une minuterie périmée (génération changée) ne fait rien ;
  - `func networkBecameAvailable()`, appelée par l'adaptateur quand `NWPathMonitor` passe à `.satisfied` :
    pour chaque cible non confirmée, la tentative revient à 0 et l'envoi part.
- Méthode POST : corps JSON `{"accessoryId": <id>, "state": <bool>}` avec `Content-Type: application/json`.
  En GET, le format reste `?accessoryId=<id>&state=true|false`.
- Confirmation : tout 2xx (décision C9). 404 → détail « accessoryId inconnu de la cible ». Redirections
  refusées (le délégué de session répond `completionHandler(nil)`). Corps limité à 4 Kio : la tâche est
  annulée au-delà. En échec, le domaine et le code `NSError` sont journalisés ; pour -1009 et -1004,
  un `NWConnection` sonde le chemin, et `unsatisfiedReason == .localNetworkDenied` donne une seule ligne
  ERROR « accès au réseau local refusé ».
- Journal : un succès qui ne change rien (battement de cœur) passe en DEBUG. Restent en INFO un état
  confirmé qui change et un retour après panne (avec la durée de la panne).
- `/status` : une entrée par cible, l'URL passée par `redactURL`.

- [ ] **Étape 1 : tests** :
  - `test_deuxCibles_unePanne_lAutreConfirmee` ;
  - `test_cibleRevenue_estResynchroniseeParLeReessaiLent` (quatrième point de vigilance : abandon,
    puis transport rétabli, état confirmé au plus tard à t + 60 s) ;
  - `test_minuteriePerimee_sansEffet` ;
  - `test_reseauRevenu_renvoieImmediatement` ;
  - `test_post_corpsJSON` ;
  - `test_404_detailAccessoryIdInconnu` ;
  - `test_battementDeCoeurSansChangement_journaliseEnDebug` ;
  - `ConfigTests.test_webhookBaseURL_devientUneCible` ;
  - `ConfigTests.test_webhookTargets_lus`.
- [ ] **Étape 2 : `swift test`** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre.** `URLSessionTransport` devient une session à délégué (redirection,
  plafond) ; `NWPathMonitor` vit dans l'exécutable.
- [ ] **Étape 4 : `swift test && bash scripts/selftest.sh`**, avec un faux webhook HA qui répond 200 sans
  corps — attendu : OK.
- [ ] **Étape 5 : commit** « Webhook : plusieurs cibles, réessai lent, retour du réseau, transport borné ».

### Tâche 16 : une seule instance publie

F19.

**Fichiers :**
- Modifier : `EngineCore.swift`, `Sources/macstatusd/HTTPServer.swift`, `EngineRunner.swift`
- Test : `EngineCoreTests.swift`

**Interfaces :**
- Produit : `EngineCore.setPublishingAllowed(_ allowed: Bool)`. L'exécuteur le passe à `listenerReady && facts.onConsole`.
  Tant qu'il est faux, aucune publication ni aucun battement de cœur ne part ; à son retour à vrai, l'état
  courant est publié en `force`.

- [ ] **Étape 1 : tests** : `test_publicationBloquee_tantQueListenerPasPret`,
  `test_publicationReprise_forceAuRetour`.
- [ ] **Étape 2 : `swift test`** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre.**
- [ ] **Étape 4 : `swift test`, puis `selftest.sh`**, avec le nouveau cas `deux-instances` : la seconde
  instance, sans port, ne publie rien — attendu : OK.
- [ ] **Étape 5 : commit** « Instance unique : seul le détenteur du port publie ».

### Tâche 17 : réveil maîtrisé

F14 (C12), C15.

**Fichiers :**
- Modifier : `Sources/macstatusd/PowerActions.swift`, `Commands.swift`, `EngineCore.swift`,
  `Config.swift` (`wake_hold_seconds`, défaut `0`, bornes 0…600)
- Test : `EngineCoreTests.swift`

**Interfaces :**
- Produit : `CommandActions.releaseWake()` et `CommandActions.holdDisplay(seconds: Double)`.
- `PowerActions.wake()` garde l'identifiant de l'assertion `UserIsActive`.
- `EngineCore` appelle `releaseWake()` quand une commande ON est confirmée par les faits, et à l'arrêt.
  Si `wake_hold_seconds > 0` et que la session est verrouillée, il appelle `holdDisplay(seconds:)` après
  le ON : `kIOPMAssertPreventUserIdleDisplaySleep` pendant ce délai, libérée à un OFF, au déverrouillage
  ou à l'échéance.

- [ ] **Étape 1 : tests** :
  - `test_onConfirme_libereLAssertion` ;
  - `test_wakeHold0_aucuneRetenue` ;
  - `test_wakeHold60_retenueSurSessionVerrouillee`.
- [ ] **Étape 2 : `swift test`** — attendu : échecs.
- [ ] **Étape 3 : mettre en œuvre.** Le banc du plan 3 vérifie la durée réelle de l'assertion ;
  `pmset -g assertions` (en lecture seule) le montre dans la relecture.
- [ ] **Étape 4 : `swift test && bash scripts/selftest.sh`** — attendu : OK.
- [ ] **Étape 5 : commit** « Réveil : assertion relâchée dès confirmation, retenue d'écran en option ».

---

## Fin du plan 2

- [ ] **Relecture de toute la branche par Opus** (sécurité et concurrence), avant le report sur `main`.
- [ ] **Vérification finale** :
  - `swift test` → tout OK ;
  - `bash scripts/selftest.sh`, écran allumé puis écran éteint → aucun échec ;
  - `.build/debug/macstatusd --once` sur le vrai Mac → des faits cohérents avec ceux de l'instance réelle.
