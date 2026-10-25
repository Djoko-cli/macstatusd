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
        guard let state = published else { return }
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

    private func evaluate(immediate: Bool, force: Bool = false) {
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

        guard settled else { return }

        if published != resolved.state {
            let previous = published
            published = resolved.state
            publishedReason = resolved.reason
            transitions += 1
            lastTransitionAt = clock.wall()
            logInfo("état \(previous.map { $0 ? "ON" : "OFF" } ?? "—") → "
                    + "\(resolved.state ? "ON" : "OFF") (\(resolved.reason)) — faits: \(factsSummary())")
            publisher.publish(resolved.state, force: false)
        } else if force, let state = published {
            publishedReason = resolved.reason
            publisher.publish(state, force: true)
        }
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

    /// Veille imminente : OFF est publié avant le gel du daemon, puis `allow()`
    /// est appelé, une fois, avant le retour. C'est à l'appelant d'y attendre la
    /// livraison de l'état s'il le souhaite (l'exécuteur le fait, borné à 1,5 s).
    public func willSleep(_ allow: @escaping () -> Void) {
        logInfo("veille imminente → publication OFF avant gel du daemon")
        systemAsleep = true
        intent = nil
        refreshFacts()
        evaluate(immediate: true)
        allow()
    }

    public func handle(_ event: SystemEvent) {
        switch event {
        case .systemDidWake:
            systemAsleep = false
            intent = nil
            saver.noteNotification(active: false)
            refreshFacts()
            evaluate(immediate: true, force: true)
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

    // MARK: - Commandes

    /// État publié, identique à ce qui a été poussé vers Homebridge.
    public var currentState: Bool {
        published ?? factsVerdict().state
    }

    /// Commande OFF. Idempotente : un doublon reçu pendant une intention OFF en cours ne fait
    /// rien (ni action, ni nouvelle échéance) ; une intention ON en cours est remplacée.
    public func requestOff(source: String) {
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
