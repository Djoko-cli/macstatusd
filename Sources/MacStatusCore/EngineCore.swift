import Foundation

/// Moteur d'état : transforme les faits observés en un état ON/OFF stable.
///
/// Règles, dans l'ordre de priorité (première règle vraie décide) :
///
/// 1. commande HomeKit en cours et non encore confirmée → état demandé ;
/// 2. veille système → OFF ;
/// 3. écran éteint → OFF ;
/// 4. économiseur d'écran actif → OFF ;
/// 5. aucun écran connecté → OFF ;
/// 6. (option) session verrouillée sans champ d'authentification → OFF ;
/// 7. sinon → ON (bureau, application, écran de verrouillage visible,
///    fenêtre de login : dans tous ces cas une UI est accessible).
///
/// Le moteur n'a ni file ni minuterie. **Contrat : on l'appelle toujours depuis
/// une même file série** (celle de `EngineRunner` dans l'exécutable), ce qui
/// exclut toute course entre les notifications système, le serveur HTTP et la
/// scrutation. Les échéances (lissage, escalade, délai de confirmation, trou de
/// scrutation) se mesurent par `clock.monotonic()` et s'évaluent à chaque `tick()`.
public final class EngineCore {
    private let config: Config
    private let clock: Clock
    private let signals: SystemSignals
    private let saver: ScreenSaverOracle
    private let actions: CommandActions
    private let publisher: StatePublisher

    private var facts = Facts()
    private var systemAsleep = false
    /// Instant monotone de la dernière veille annoncée par `willSleep`, effacé au réveil.
    private var sleepStartedAt: Double?

    /// Délai maximal d'attente de la livraison OFF avant d'autoriser la veille.
    static let sleepDeliveryTimeout: Double = 1.5
    /// En deçà de cette durée de veille, le réveil ne force pas la republication.
    static let longSleepThreshold: Double = 30
    /// Délai maximal d'attente de la livraison OFF à l'arrêt (sous le filet de 3 s et l'`ExitTimeOut` de 5 s).
    static let shutdownDeliveryTimeout: Double = 2

    /// Vrai une fois `shutdown` appelé : le moteur ne publie ni n'agit plus, jamais.
    private var isShutDown = false

    private var published: Bool?
    private var publishedReason = "startup"
    private var candidate: Bool?
    private var candidateReason = "startup"
    /// Instant monotone où le candidat actuel est apparu.
    private var candidateSince: Double

    private var intent: Intent?
    /// Instant monotone du dernier cycle de scrutation.
    private var lastTickAt: Double
    private let startedAt: Double
    private var transitions = 0
    /// Heure murale de la dernière transition, pour /status.
    private var lastTransitionAt: Date?

    /// Commande en attente de confirmation. Instants monotones, en secondes.
    private struct Intent {
        let target: Bool
        let issuedAt: Double
        let deadline: Double
        let source: String
        var escalated = false
    }

    public init(config: Config,
                clock: Clock,
                signals: SystemSignals,
                oracle: ScreenSaverOracle,
                actions: CommandActions,
                publisher: StatePublisher) {
        self.config = config
        self.clock = clock
        self.signals = signals
        self.saver = oracle
        self.actions = actions
        self.publisher = publisher
        let now = clock.monotonic()
        candidateSince = now
        lastTickAt = now
        startedAt = now
    }

    // MARK: - Cycle de vie

    /// Premier relevé des faits et publication forcée de l'état initial.
    public func start() {
        refreshFacts()
        evaluate(immediate: true, force: true)
        logInfo("état initial: \(published == true ? "ON" : "OFF") (\(publishedReason)) — faits: \(factsSummary())")
    }

    /// Un cycle de scrutation : relit les faits et réévalue l'état.
    public func tick() {
        guard !isShutDown else { return }
        let now = clock.monotonic()
        let gap = now - lastTickAt
        lastTickAt = now

        // Un trou dans la scrutation signifie veille, gel ou surcharge : on
        // resynchronise au lieu de faire confiance à l'état mémorisé.
        let recovering = gap > max(10, Double(config.pollIntervalMS) / 1000 * 20)
        if recovering {
            logWarn("interruption de \(String(format: "%.1f", gap)) s détectée → resynchronisation")
            systemAsleep = false
            saver.noteNotification(active: false)
        }

        refreshFacts()
        evaluate(immediate: recovering, force: recovering)
    }

    /// Battement de cœur : republie l'état courant, même déjà confirmé.
    public func heartbeat() {
        guard !isShutDown, let state = published else { return }
        logDebug("battement de cœur → republication de l'état \(state ? "1" : "0")")
        publisher.publish(state, force: true)
    }

    // MARK: - Faits

    private func refreshFacts() {
        var next = Facts()
        next.systemAsleep = systemAsleep

        let session = signals.session()
        next.sessionLocked = session.locked
        next.consoleUserLoggedIn = session.loggedIn
        next.onConsole = session.onConsole
        next.lockEvidence = session.evidence

        let display = signals.display()
        next.displayAsleep = display.asleep
        next.onlineDisplays = display.onlineCount
        next.displayEnumerationOK = display.enumerationOK

        next.hidIdleSeconds = signals.hidIdleSeconds()

        // Inutile de sonder l'économiseur quand une condition OFF plus
        // prioritaire est déjà vraie : c'est aussi le cas où le Mac est inactif
        // longtemps, autant ne pas le réveiller pour rien.
        if next.systemAsleep || next.displayAsleep {
            next.screenSaverActive = false
            next.screenSaverEvidence = "non-évalué"
        } else {
            let verdict = saver.verdict(now: clock.monotonic(), hidIdle: next.hidIdleSeconds)
            next.screenSaverActive = verdict.active
            next.screenSaverRunning = verdict.running
            next.screenSaverDismissed = verdict.dismissed
            next.screenSaverEvidence = verdict.evidence
        }

        next.secureInputActive = signals.secureInputActive()

        if next.asDictionary as NSDictionary != facts.asDictionary as NSDictionary {
            logDebug("faits: \(summary(of: next))")
        }
        facts = next
    }

    // MARK: - Décision

    private func factsVerdict() -> (state: Bool, reason: String) {
        if facts.systemAsleep { return (false, "system-asleep") }
        if facts.displayAsleep { return (false, "display-asleep") }
        if facts.screenSaverActive { return (false, "screensaver:\(facts.screenSaverEvidence)") }
        if facts.displayEnumerationOK && facts.onlineDisplays == 0 { return (false, "no-display") }
        if config.requireAuthUIWhenLocked && facts.sessionLocked && !facts.secureInputActive {
            return (false, "locked-without-auth-ui")
        }
        if facts.sessionLocked { return (true, "lock-screen-ui") }
        if !facts.consoleUserLoggedIn { return (true, "login-window-ui") }
        return (true, "desktop-ui")
    }

    /// Vrai si l'évaluation a appelé le publieur.
    @discardableResult
    private func evaluate(immediate: Bool, force: Bool = false) -> Bool {
        guard !isShutDown else { return false }
        let now = clock.monotonic()
        let factual = factsVerdict()
        var resolved = factual
        var bypassSettle = immediate

        if var current = intent {
            if factual.state == current.target {
                logInfo("commande \(current.source) confirmée par les faits en "
                        + "\(String(format: "%.1f", now - current.issuedAt)) s (\(factual.reason))")
                intent = nil
            } else if now >= current.deadline {
                logWarn("commande \(current.source) non confirmée après "
                        + "\(String(format: "%.1f", now - current.issuedAt)) s → retour aux faits (\(factual.reason))")
                intent = nil
            } else {
                if !current.escalated,
                   now - current.issuedAt >= Double(config.commandEscalateAfterMS) / 1000 {
                    current.escalated = true
                    escalate(current)
                }
                intent = current
                resolved = (current.target, "command:\(current.source)")
                bypassSettle = true
            }
        }

        if candidate != resolved.state {
            candidate = resolved.state
            candidateReason = resolved.reason
            candidateSince = now
        } else {
            candidateReason = resolved.reason
        }

        let settleMS = resolved.state ? config.settleOnMS : config.settleOffMS
        let stableFor = (now - candidateSince) * 1000
        let settled = bypassSettle || stableFor >= Double(settleMS)

        guard settled else { return false }

        if published != resolved.state {
            let previous = published
            published = resolved.state
            publishedReason = resolved.reason
            transitions += 1
            lastTransitionAt = clock.wall()
            logInfo("état \(previous.map { $0 ? "ON" : "OFF" } ?? "—") → "
                    + "\(resolved.state ? "ON" : "OFF") (\(resolved.reason)) — faits: \(factsSummary())")
            publisher.publish(resolved.state, force: false)
            return true
        } else if force, let state = published {
            publishedReason = resolved.reason
            publisher.publish(state, force: true)
            return true
        }
        return false
    }

    /// Redemande l'état publié, sans `force` : le publieur n'envoie que si l'état confirmé
    /// diffère (envoi perdu, abandonné ou encore en vol), et ne fait rien sinon.
    private func ensurePublished() {
        guard !isShutDown, let state = published else { return }
        publisher.publish(state, force: false)
    }

    /// Une commande dont les faits ne confirment pas l'effet est réessayée une
    /// fois, par un moyen plus contraignant, à mi‑parcours du délai imparti.
    private func escalate(_ intent: Intent) {
        if intent.target == false {
            guard config.offEscalateToDisplaySleep else {
                logWarn("commande \(intent.source) sans effet observé (escalade désactivée)")
                return
            }
            logWarn("commande \(intent.source) sans effet observé → escalade: extinction de l'écran")
            actions.displaySleep()
            return
        }
        if facts.screenSaverActive && config.stopScreensaverOnWake {
            logWarn("commande \(intent.source) sans effet observé → escalade: arrêt de l'économiseur")
            actions.stopScreenSaver()
            return
        }
        logWarn("commande \(intent.source) sans effet observé → escalade: nouvelle tentative de réveil")
        actions.wake()
    }

    // MARK: - Événements système

    /// Veille imminente. OFF est publié tout de suite, puis `allow` est appelé une fois la
    /// livraison confirmée, ou au plus tard après `sleepDeliveryTimeout` (1,5 s). L'attente est
    /// un rappel (`notifyWhenDelivered`) : `willSleep` rend la main aussitôt et la file reste
    /// libre de recevoir la réponse du webhook. OFF déjà confirmé : rien n'est envoyé et `allow`
    /// part sans attendre.
    ///
    /// La commande en cours est oubliée : la veille l'emporte sur elle, et un ON en attente ne
    /// doit pas être publié au moment où le Mac s'endort.
    public func willSleep(_ allow: @escaping () -> Void) {
        guard !isShutDown else {
            logInfo("veille imminente pendant l'arrêt → autorisée sans attente")
            allow()
            return
        }
        logInfo("veille imminente → publication OFF avant gel du daemon")
        systemAsleep = true
        sleepStartedAt = clock.monotonic()
        intent = nil
        refreshFacts()
        if !evaluate(immediate: true) {
            // OFF était déjà publié : on s'assure seulement qu'il est confirmé.
            ensurePublished()
        }
        publisher.notifyWhenDelivered(timeout: Self.sleepDeliveryTimeout) { delivered in
            if delivered {
                logInfo("veille : OFF confirmé → veille autorisée")
            } else {
                logWarn("veille : OFF non confirmé en \(Self.sleepDeliveryTimeout) s → veille autorisée quand même")
            }
            allow()
        }
    }

    public func handle(_ event: SystemEvent) {
        guard !isShutDown else { return }
        switch event {
        case .systemDidWake:
            // La commande en cours est gardée : un /wake réveille le Mac, et ce réveil ne doit
            // pas effacer la commande qui l'a causé (elle s'escalade et attend les faits).
            let now = clock.monotonic()
            let slept = sleepStartedAt.map { now - $0 }
            sleepStartedAt = nil
            systemAsleep = false
            saver.noteNotification(active: false)
            refreshFacts()
            // Après une veille longue, Homebridge a pu perdre l'état : on le force. Après une
            // veille courte (ou de durée inconnue : second avis de réveil), on ne renvoie que si
            // l'état confirmé diffère. Les trous de scrutation restent rattrapés par `tick()`.
            let long = slept.map { $0 >= Self.longSleepThreshold } ?? false
            if let slept {
                logInfo("réveil après \(String(format: "%.1f", slept)) s de veille"
                        + (long ? " → republication forcée" : ""))
            }
            if !evaluate(immediate: true, force: long) {
                ensurePublished()
            }
        case .systemWillNotSleep:
            // Veille annulée : ni réveil ni nouvel état. La commande en cours et la notification
            // de l'économiseur restent ; l'état revient par le lissage habituel.
            systemAsleep = false
            sleepStartedAt = nil
            refreshFacts()
            evaluate(immediate: false)
        case .screenSaverDidStart:
            saver.noteNotification(active: true)
            refreshFacts()
            evaluate(immediate: false)
        case .screenSaverDidStop:
            saver.noteNotification(active: false)
            refreshFacts()
            evaluate(immediate: false)
        case .screensDidSleep, .screensDidWake, .screenLocked, .screenUnlocked,
             .sessionActive, .sessionInactive, .saverProcessChanged:
            refreshFacts()
            evaluate(immediate: false)
        }
    }

    // MARK: - Arrêt

    /// Arrêt du daemon (SIGTERM, SIGINT, SIGHUP). Verrouille le moteur : plus aucune publication,
    /// aucune action (réveil, OFF, économiseur), aucun battement de cœur ni nouvelle évaluation ;
    /// les lectures (`currentState`, `statusSnapshot`, `inspect`) restent possibles.
    ///
    /// Avec `publishOff`, OFF est publié en `force`, ce qui remplace l'état voulu même si une
    /// requête est en vol (le client l'envoie dès que celle-ci rend la main), puis `done` part à la
    /// livraison, ou après `shutdownDeliveryTimeout` (2 s) au plus. Sans `publishOff` (redémarrage
    /// prévu, mode dégradé, option désactivée), `done` part tout de suite. `done` est appelé
    /// exactement une fois par appel, sur la file du moteur. Un second appel ne publie rien.
    public func shutdown(publishOff: Bool, _ done: @escaping () -> Void) {
        guard !isShutDown else {
            logInfo("arrêt déjà en cours")
            done()
            return
        }
        isShutDown = true
        intent = nil
        guard publishOff else {
            logInfo("arrêt : aucune publication OFF")
            done()
            return
        }
        logInfo("arrêt : publication OFF avant de partir")
        published = false
        publishedReason = "shutdown"
        publisher.publish(false, force: true)
        publisher.notifyWhenDelivered(timeout: Self.shutdownDeliveryTimeout) { delivered in
            if delivered {
                logInfo("arrêt : OFF confirmé")
            } else {
                logWarn("arrêt : OFF non confirmé en \(Self.shutdownDeliveryTimeout) s → départ quand même")
            }
            done()
        }
    }

    // MARK: - Commandes

    /// État publié, identique à ce qui a été poussé vers Homebridge.
    public var currentState: Bool {
        published ?? factsVerdict().state
    }

    /// Commande OFF. Idempotente : un doublon reçu pendant une intention OFF en cours ne fait
    /// rien (ni action, ni nouvelle échéance) ; une intention ON en cours est remplacée.
    public func requestOff(source: String) {
        guard !isShutDown else {
            logInfo("commande OFF (\(source)) ignorée : arrêt en cours")
            return
        }
        if isPending(target: false) {
            logInfo("commande OFF (\(source)) → commande OFF déjà en cours, ignorée")
            return
        }
        refreshFacts()
        let factual = factsVerdict()
        if factual.state == false {
            logInfo("commande OFF (\(source)) → déjà OFF (\(factual.reason)), aucune action")
            intent = nil
            evaluate(immediate: true)
            return
        }

        // Mesuré sur macOS 26 : `open -a ScreenSaverEngine` reste sans effet
        // quand la session est déjà verrouillée. Plutôt que d'attendre
        // l'escalade, on éteint directement l'écran — même résultat OFF, et
        // toujours réversible par /wake.
        var action = config.offAction
        if action == .screensaver, facts.sessionLocked, !actions.hasOffOverride {
            logInfo("session déjà verrouillée : l'économiseur ne peut pas être lancé → extinction de l'écran")
            action = .displaySleep
        }

        logInfo("commande OFF (\(source)) → action=\(action.rawValue)")
        intent = makeIntent(target: false, source: "off/\(action.rawValue)")
        actions.runOff(action)
        evaluate(immediate: true)
    }

    /// Commande ON. Idempotente : un doublon reçu pendant une intention ON en cours ne fait
    /// rien ; une intention OFF en cours est remplacée. Les faits sont relus d'abord : déjà ON et
    /// sans intention OFF en cours, rien n'est lancé (ni réveil, ni arrêt de l'économiseur), sauf
    /// si l'économiseur tourne encore (Ruling R30) : l'oracle le dit « écarté » jusqu'à 90 s
    /// après une frappe, alors que macOS a pu revenir à l'économiseur. Dans ce cas, un réveil
    /// est envoyé, sans intention (rien à confirmer : les faits disent déjà ON).
    public func requestOn(source: String) {
        guard !isShutDown else {
            logInfo("commande ON (\(source)) ignorée : arrêt en cours")
            return
        }
        if isPending(target: true) {
            logInfo("commande ON (\(source)) → commande ON déjà en cours, ignorée")
            return
        }
        refreshFacts()
        let factual = factsVerdict()
        if factual.state, !isPending(target: false) {
            intent = nil
            if facts.screenSaverRunning {
                logInfo("commande ON (\(source)) → ON selon les faits (\(factual.reason)), mais économiseur "
                        + "en marche (\(facts.screenSaverEvidence)) → réveil, sans intention")
                actions.wake()
            } else {
                logInfo("commande ON (\(source)) → déjà ON (\(factual.reason)), aucune action")
            }
            evaluate(immediate: true)
            return
        }

        logInfo("commande ON (\(source))")
        intent = makeIntent(target: true, source: "on")
        actions.wake()
        // Un économiseur actif ne s'arrête pas toujours sur simple activité
        // déclarée : on le termine dans le même geste, comme le ferait une
        // frappe clavier.
        if facts.screenSaverActive && config.stopScreensaverOnWake {
            actions.stopScreenSaver()
        }
        evaluate(immediate: true)
    }

    public func resync() {
        guard !isShutDown else { return }
        systemAsleep = false
        saver.noteNotification(active: false)
        refreshFacts()
        evaluate(immediate: true, force: true)
    }

    /// Vrai si une intention de ce sens attend encore sa confirmation (échéance non atteinte).
    private func isPending(target: Bool) -> Bool {
        guard let intent, intent.target == target else { return false }
        return clock.monotonic() < intent.deadline
    }

    private func makeIntent(target: Bool, source: String) -> Intent {
        let now = clock.monotonic()
        return Intent(target: target,
                      issuedAt: now,
                      deadline: now + Double(config.commandConfirmTimeoutMS) / 1000,
                      source: source)
    }

    // MARK: - Diagnostic

    public func statusSnapshot() -> [String: Any] {
        let now = clock.monotonic()
        var dict: [String: Any] = [
            "version": macstatusdVersion,
            "state": (published ?? factsVerdict().state) ? "1" : "0",
            "reason": publishedReason,
            "facts": facts.asDictionary,
            "facts_verdict": factsVerdict().state ? "1" : "0",
            "uptime_seconds": Int(now - startedAt),
            "transitions": transitions,
            "poll_interval_ms": config.pollIntervalMS,
            "off_action": config.offAction.rawValue,
            "webhook": publisher.statusDictionary,
            "session_context": signals.hasAquaSession() ? "aqua" : "headless",
        ]
        if isShutDown { dict["shutting_down"] = true }
        if let lastTransitionAt {
            dict["last_transition"] = ISO8601DateFormatter().string(from: lastTransitionAt)
        }
        if let intent {
            dict["pending_command"] = [
                "target": intent.target ? "1" : "0",
                "source": intent.source,
                "age_seconds": Int(now - intent.issuedAt),
                "escalated": intent.escalated,
            ]
        }
        return dict
    }

    /// Instantané des faits pour `--once` / `--watch` (hors serveur HTTP).
    public func inspect() -> (state: Bool, reason: String, facts: Facts) {
        refreshFacts()
        let verdict = factsVerdict()
        return (published ?? verdict.state, verdict.reason, facts)
    }

    private func factsSummary() -> String { summary(of: facts) }

    private func summary(of facts: Facts) -> String {
        "sleep=\(facts.systemAsleep ? 1 : 0) display_off=\(facts.displayAsleep ? 1 : 0) "
            + "saver=\(facts.screenSaverActive ? 1 : 0)(\(facts.screenSaverEvidence)) "
            + "saver_running=\(facts.screenSaverRunning ? 1 : 0) "
            + "hid_idle=\(String(format: "%.1f", facts.hidIdleSeconds)) "
            + "locked=\(facts.sessionLocked ? 1 : 0)(\(facts.lockEvidence)) "
            + "logged_in=\(facts.consoleUserLoggedIn ? 1 : 0) secure_input=\(facts.secureInputActive ? 1 : 0) "
            + "displays=\(facts.onlineDisplays)"
    }
}
