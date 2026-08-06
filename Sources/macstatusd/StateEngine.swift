import Foundation
import CoreGraphics

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
/// Toutes les mutations se font sur une file série unique : pas de course entre
/// les notifications système, le serveur HTTP et la boucle de scrutation.
final class StateEngine {
    let queue = DispatchQueue(label: "macstatusd.state")

    private let config: Config
    private let reader: SignalReader
    private let saver: ScreenSaverOracle
    private let webhook: WebhookClient
    private let actions: PowerActions

    private var facts = Facts()
    private var systemAsleep = false

    private var published: Bool?
    private var publishedReason = "startup"
    private var candidate: Bool?
    private var candidateReason = "startup"
    private var candidateSince = Date()

    private var intent: Intent?
    private var pollTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastTickAt = Date()
    private let startedAt = Date()
    private var transitions = 0
    private var lastTransitionAt: Date?

    private struct Intent {
        let target: Bool
        let issuedAt: Date
        let deadline: Date
        let source: String
        var escalated = false
    }

    init(config: Config, webhook: WebhookClient, actions: PowerActions) {
        self.config = config
        self.webhook = webhook
        self.actions = actions
        self.reader = SignalReader()
        self.saver = ScreenSaverOracle(
            minimumInterval: max(1.0, Double(config.pollIntervalMS) / 1000),
            dismissOnInput: config.saverDismissOnInput,
            dismissGrace: Double(config.saverDismissGraceMS) / 1000,
            redisplayIdle: Double(config.saverRedisplayIdleSeconds)
        )
    }

    // MARK: - Cycle de vie

    func start() {
        queue.async { [self] in
            refreshFacts()
            evaluate(immediate: true, force: true)
            logInfo("état initial: \(published == true ? "ON" : "OFF") (\(publishedReason)) — faits: \(factsSummary())")
            startPollTimer()
            startHeartbeatTimer()
        }
    }

    private func startPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(config.pollIntervalMS) / 1000
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        pollTimer = timer
    }

    private func startHeartbeatTimer() {
        guard config.heartbeatSeconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(config.heartbeatSeconds)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, let state = published else { return }
            logDebug("battement de cœur → republication de l'état \(state ? "1" : "0")")
            webhook.publish(state, force: true)
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func tick() {
        let now = Date()
        let gap = now.timeIntervalSince(lastTickAt)
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

    // MARK: - Faits

    private func refreshFacts() {
        var next = Facts()
        next.systemAsleep = systemAsleep

        let session = reader.sessionState()
        next.sessionLocked = session.locked
        next.consoleUserLoggedIn = session.loggedIn
        next.lockEvidence = session.evidence

        let display = reader.displayState()
        next.displayAsleep = display.asleep
        next.onlineDisplays = display.onlineCount
        next.displayEnumerationOK = display.enumerationOK

        next.hidIdleSeconds = reader.hidIdleSeconds()

        // Inutile de sonder l'économiseur quand une condition OFF plus
        // prioritaire est déjà vraie : c'est aussi le cas où le Mac est inactif
        // longtemps, autant ne pas le réveiller pour rien.
        if next.systemAsleep || next.displayAsleep {
            next.screenSaverActive = false
            next.screenSaverEvidence = "non-évalué"
        } else {
            let verdict = saver.verdict(hidIdle: next.hidIdleSeconds)
            next.screenSaverActive = verdict.active
            next.screenSaverRunning = verdict.running
            next.screenSaverDismissed = verdict.dismissed
            next.screenSaverEvidence = verdict.evidence
        }

        next.secureInputActive = reader.secureInputActive()

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
        let now = Date()
        let factual = factsVerdict()
        var resolved = factual
        var bypassSettle = immediate

        if var current = intent {
            if factual.state == current.target {
                logInfo("commande \(current.source) confirmée par les faits en "
                        + "\(String(format: "%.1f", now.timeIntervalSince(current.issuedAt))) s (\(factual.reason))")
                intent = nil
            } else if now >= current.deadline {
                logWarn("commande \(current.source) non confirmée après "
                        + "\(String(format: "%.1f", now.timeIntervalSince(current.issuedAt))) s → retour aux faits (\(factual.reason))")
                intent = nil
            } else {
                if !current.escalated,
                   now.timeIntervalSince(current.issuedAt) >= Double(config.commandEscalateAfterMS) / 1000 {
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
        let stableFor = now.timeIntervalSince(candidateSince) * 1000
        let settled = bypassSettle || stableFor >= Double(settleMS)

        guard settled else { return }

        if published != resolved.state {
            let previous = published
            published = resolved.state
            publishedReason = resolved.reason
            transitions += 1
            lastTransitionAt = now
            logInfo("état \(previous.map { $0 ? "ON" : "OFF" } ?? "—") → "
                    + "\(resolved.state ? "ON" : "OFF") (\(resolved.reason)) — faits: \(factsSummary())")
            webhook.publish(resolved.state)
        } else if force, let state = published {
            publishedReason = resolved.reason
            webhook.publish(state, force: true)
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

    func attach(to watcher: PowerWatcher) {
        watcher.onWillSleep = { [weak self] allow in
            guard let self else { allow(); return }
            logInfo("veille imminente → publication OFF avant gel du daemon")
            systemAsleep = true
            intent = nil
            refreshFacts()
            evaluate(immediate: true)
            webhook.waitForDelivery(timeout: 1.5)
            allow()
        }

        watcher.onEvent = { [weak self] event in
            guard let self else { return }
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
    }

    // MARK: - API (serveur HTTP)

    /// État publié, identique à ce qui a été poussé vers Homebridge.
    var currentState: Bool {
        queue.sync { published ?? factsVerdict().state }
    }

    func requestOff(source: String = "homekit") {
        queue.async { [self] in
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
            intent = Intent(target: false,
                            issuedAt: Date(),
                            deadline: Date().addingTimeInterval(Double(config.commandConfirmTimeoutMS) / 1000),
                            source: "off/\(action.rawValue)")
            actions.runOff(action)
            evaluate(immediate: true)
        }
    }

    func requestOn(source: String = "homekit") {
        queue.async { [self] in
            logInfo("commande ON (\(source))")
            intent = Intent(target: true,
                            issuedAt: Date(),
                            deadline: Date().addingTimeInterval(Double(config.commandConfirmTimeoutMS) / 1000),
                            source: "on")
            actions.wake()
            // Un économiseur actif ne s'arrête pas toujours sur simple activité
            // déclarée : on le termine dans le même geste, comme le ferait une
            // frappe clavier.
            if facts.screenSaverActive && config.stopScreensaverOnWake {
                actions.stopScreenSaver()
            }
            evaluate(immediate: true)
        }
    }

    func resync() {
        queue.async { [self] in
            systemAsleep = false
            saver.noteNotification(active: false)
            refreshFacts()
            evaluate(immediate: true, force: true)
        }
    }

    func statusSnapshot() -> [String: Any] {
        queue.sync {
            var dict: [String: Any] = [
                "version": macstatusdVersion,
                "state": (published ?? factsVerdict().state) ? "1" : "0",
                "reason": publishedReason,
                "facts": facts.asDictionary,
                "facts_verdict": factsVerdict().state ? "1" : "0",
                "uptime_seconds": Int(Date().timeIntervalSince(startedAt)),
                "transitions": transitions,
                "poll_interval_ms": config.pollIntervalMS,
                "off_action": config.offAction.rawValue,
                "webhook": webhook.statusDictionary,
                "session_context": CGSessionAvailable() ? "aqua" : "headless",
            ]
            if let lastTransitionAt {
                dict["last_transition"] = ISO8601DateFormatter().string(from: lastTransitionAt)
            }
            if let intent {
                dict["pending_command"] = [
                    "target": intent.target ? "1" : "0",
                    "source": intent.source,
                    "age_seconds": Int(Date().timeIntervalSince(intent.issuedAt)),
                    "escalated": intent.escalated,
                ]
            }
            return dict
        }
    }

    /// Instantané des faits pour `--once` / `--watch` (hors serveur HTTP).
    func inspect() -> (state: Bool, reason: String, facts: Facts) {
        queue.sync {
            refreshFacts()
            let verdict = factsVerdict()
            return (published ?? verdict.state, verdict.reason, facts)
        }
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

/// Indique si le process voit une session graphique (LaunchAgent Aqua) ou non
/// (LaunchDaemon) : utile pour diagnostiquer les signaux disponibles.
func CGSessionAvailable() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return dict["kCGSSessionUserIDKey"] != nil
}
