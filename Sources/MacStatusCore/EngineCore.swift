import Foundation

/// Moteur d'état : transforme les faits observés en un état ON/OFF stable.
///
/// Règles, dans l'ordre de priorité (première règle vraie décide) :
///
/// 1. commande HomeKit en cours et non encore confirmée → état demandé ;
/// 2. veille système → OFF ;
/// 3. écran éteint (un écran physique endormi, voir `DisplayTopology`) → OFF ;
/// 4. économiseur d'écran actif → OFF ;
/// 5. aucun écran physique → OFF, mais seulement `noDisplayHoldSeconds` (5 s) après la première lecture sans
///    écran : au réveil capot fermé ou dock débranché, macOS ne montre d'abord que l'écran fantôme, et l'état
///    publié tient d'ici que les écrans physiques reviennent (`displays-reconfiguring`) ;
/// 6. (option) session verrouillée sans champ d'authentification → OFF ;
/// 7. sinon → ON (bureau, application, écran de verrouillage visible,
///    fenêtre de login : dans tous ces cas une UI est accessible).
///
/// **Une seule instance publie.** Rien ne part vers les cibles (état, battement de cœur,
/// resynchronisation, réessais, OFF de veille ou d'arrêt) tant que deux conditions ne sont pas
/// réunies : le serveur HTTP détient son port (`setListenerStatus`, annoncé par l'exécuteur) et
/// la session est à la console (`Facts.onConsole`, relue à chaque rafraîchissement des faits). Une
/// seconde instance lancée par erreur, ou un daemon resté dans une session sans console, calcule
/// son état pour elle-même mais n'envoie rien. Au retour de l'autorisation, l'état courant est
/// publié une fois en `force`.
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
    /// Dernière veille annoncée par `willSleep` : son début, et la fin une fois le réveil traité
    /// (par `systemDidWake`, ou par `tick()` si l'avis de réveil manque). Gardée après le réveil,
    /// pour que `tick()` reconnaisse le trou de scrutation qu'elle a causé (R38). Effacée si la
    /// veille est annulée.
    private var lastSleep: SleepSpan?

    private struct SleepSpan {
        let start: Double
        var end: Double?
    }

    /// Délai maximal d'attente de la livraison OFF avant d'autoriser la veille.
    static let sleepDeliveryTimeout: Double = 1.5
    /// En deçà de cette durée de veille, le réveil ne force pas la republication.
    static let longSleepThreshold: Double = 30
    /// Délai maximal d'attente de la livraison OFF à l'arrêt (sous le filet de 3 s et l'`ExitTimeOut` de 5 s).
    static let shutdownDeliveryTimeout: Double = 2
    /// Au-delà de cette durée sans avis de réveil, `tick()` conclut que l'avis est perdu : la veille
    /// annoncée plus tôt ne peut pas durer (la scrutation tourne, donc le Mac est éveillé).
    static let lostWakeDelay: Double = 35
    /// Intervalle minimal entre deux relectures des faits dues à une notification (`didstart`, `didstop`,
    /// verrouillage, déverrouillage) : une rafale, forgée ou non, ne coûte qu'une relecture par 250 ms.
    /// La scrutation suivante rattrape le reste ; elle n'entre pas dans ce compte.
    static let notificationRefreshMinInterval: Double = 0.25
    /// Instant monotone de la dernière relecture due à une de ces notifications ; `nil` : aucune encore.
    private var lastNotificationRefreshAt: Double?

    // MARK: Écrans (plan 3, tâche 4)

    /// Durée pendant laquelle l'état publié tient quand l'énumération réussit mais ne montre plus aucun écran
    /// physique (seul le fantôme du système reste). Ensuite, `no-display`.
    static let noDisplayHoldSeconds: Double = 5
    /// Instant monotone de la première lecture réussie sans écran physique de la série en cours ; `nil` : des
    /// écrans physiques sont là. Une énumération ratée ne le démarre pas et ne le remet pas à zéro.
    private var noPhysicalDisplaySince: Double?
    /// Le système a annoncé `screensDidSleep` et un écran physique dort encore. Effacé au réveil des écrans, au
    /// réveil du système, à la resynchronisation, et dès qu'aucun écran physique n'est endormi.
    private var screensAsleepNotified = false
    /// Ce qui distingue deux topologies pour le journal : l'ensemble des écrans, le principal, la présence du
    /// fantôme. L'état de veille n'en fait pas partie.
    private struct DisplayLayout: Equatable {
        let ids: [UInt32]
        let mainID: UInt32?
        let hasPlaceholder: Bool
    }
    /// Dernière topologie journalisée ; `nil` avant la première lecture réussie.
    private var loggedDisplayLayout: DisplayLayout?

    /// Marge de couverture d'un trou de scrutation par une veille : deux périodes de scrutation,
    /// entre 1 et 3 s (bien moins que le seuil de trou, 10 s au moins).
    private var sleepCoverMargin: Double {
        min(3, max(1, 2 * Double(config.pollIntervalMS) / 1000))
    }

    /// Vrai une fois `shutdown` appelé : le moteur ne publie ni n'agit plus, jamais.
    private var isShutDown = false

    // MARK: Réveil maîtrisé (tâche 17)

    /// `actions.wake()` a posé une assertion que `actions.releaseWake()` n'a pas encore relâchée.
    private var wakeAssertionHeld = false
    /// Réveil sans intention (économiseur « écarté » : R30) : l'assertion tient jusqu'à cet instant
    /// monotone, ou jusqu'à ce que l'économiseur ait disparu. `nil` : le réveil a une intention.
    private var wakeSaverWaitUntil: Double?
    /// Retenue d'écran en cours (`actions.holdDisplay`) : instant monotone d'échéance. `nil` : aucune.
    private var displayHoldUntil: Double?
    /// Réveil léger (R49) : /wake sur un Mac déjà ON selon les faits, sans intention ni attente.
    /// L'assertion est relâchée à l'évaluation suivante.
    private var lightWake = false
    /// `wakeNow()` a eu lieu pendant l'évaluation en cours (ou juste avant elle) : rien n'est relâché
    /// avant l'évaluation suivante (R47). Remis à faux à la fin de chaque évaluation.
    private var wakeJustIssued = false
    /// Raison d'un relâchement remis à l'évaluation suivante par `wakeJustIssued`.
    private var deferredReleaseReason: String?

    // MARK: Autorisation de publier (tâche 16)

    /// Ce que le serveur HTTP a annoncé de son écoute ; `nil` tant qu'il n'a rien dit.
    private var listenerStatus: ListenerStatus?
    /// Les faits ont été lus au moins une fois (`onConsole` n'a de sens qu'ensuite).
    private var factsRead = false
    /// Dernier verdict journalisé ; `nil` avant la première lecture des faits.
    private var loggedAuthorization: (allowed: Bool, reason: String)?
    /// Une autorisation a déjà été accordée : sert au texte du journal d'arrêt.
    private var everAuthorized = false
    /// L'autorisation vient de revenir : la prochaine publication part en `force`, une seule fois.
    private var resumePending = false
    /// Intervalle minimal entre deux publications forcées de reprise : une écoute qui oscille
    /// (`.ready` / `.waiting`) ne doit pas inonder les cibles. Un retour trop proche attend l'échéance.
    static let resumeForceMinInterval: Double = 2
    /// Instant monotone de la dernière publication forcée de reprise ; `nil` : aucune encore.
    private var lastResumeForceAt: Double?
    /// Miroir de l'état de suspension demandé au publieur (il démarre non suspendu).
    private var publisherSuspended = false

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
        /// Pas de confirmation par les faits avant cet instant monotone. Sert à l'ON qui remplace un
        /// OFF dont l'action est partie : l'économiseur lancé par `open -a` peut démarrer après coup.
        var confirmNotBefore: Double = 0
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

    /// Premier relevé des faits et publication forcée de l'état initial. Le moyen d'écarter l'économiseur est
    /// journalisé une fois (INFO s'il est natif, WARN pour le repli), et, sans `SACScreenSaverIsRunning`, un
    /// avertissement unique annonce le repli de l'oracle de l'économiseur.
    public func start() {
        switch actions.screenSaverDismissal {
        case .native:
            logInfo("économiseur : moyen d'écartement SACScreenSaverStopNow (commande du système)")
        case .processKill:
            logWarn("SACScreenSaverStopNow indisponible → repli killall ScreenSaverEngine, "
                    + "sans effet sous macOS 27 sur l'économiseur d'inactivité")
        }
        if signals.saverSessionFlag() == nil {
            logWarn("économiseur : SACScreenSaverIsRunning indisponible → repli sur l'hôte apparu après didstart ; "
                    + "les paysages aériens ne seront pas détectés")
        }
        refreshFacts()
        evaluate(immediate: true, force: true)
        logInfo("état initial: \(published == true ? "ON" : "OFF") (\(publishedReason)) — faits: \(factsSummary())")
    }

    /// Un cycle de scrutation : relit les faits et réévalue l'état.
    ///
    /// Un trou dans la scrutation signifie veille, gel ou surcharge : on resynchronise au lieu de
    /// faire confiance à l'état mémorisé, avec une publication forcée. Sauf si le trou est
    /// couvert par la dernière veille (R38) : le tick précédent date au plus tôt de son début
    /// (moins la marge), et le tick courant au plus tard de son réveil (plus la marge).
    /// - réveil déjà traité : `tick()` ne force jamais, l'avis de réveil a décidé (forcé si la
    ///   veille a duré 30 s ou plus) ; sinon une veille longue forcerait deux fois ;
    /// - réveil pas encore traité (avis en retard ou perdu) : `tick()` le traite, et ne force que
    ///   si la veille a duré 30 s ou plus ; l'avis qui arrive ensuite ne force plus.
    public func tick() {
        guard !isShutDown else { return }
        let now = clock.monotonic()
        let previous = lastTickAt
        let gap = now - previous
        lastTickAt = now

        let recovering = gap > max(10, Double(config.pollIntervalMS) / 1000 * 20)
        var force = recovering
        var covered = false
        if recovering {
            let shown = String(format: "%.1f", gap)
            let margin = sleepCoverMargin
            if var sleep = lastSleep, previous >= sleep.start - margin, now <= (sleep.end ?? now) + margin {
                covered = true
                if sleep.end != nil {
                    force = false
                    logInfo("interruption de \(shown) s couverte par la veille (réveil déjà traité) "
                            + "→ resynchronisation sans republication forcée")
                } else {
                    let slept = now - sleep.start
                    force = slept >= Self.longSleepThreshold
                    sleep.end = now
                    lastSleep = sleep
                    logWarn("interruption de \(shown) s couverte par la veille, réveil non encore notifié "
                            + "(\(String(format: "%.1f", slept)) s de veille) → resynchronisation"
                            + (force ? ", republication forcée" : " sans republication forcée"))
                }
            } else {
                logWarn("interruption de \(shown) s détectée → resynchronisation")
            }
            systemAsleep = false
            saver.noteSystemWake()
        }

        // Réveil perdu : une veille courte (moins que le seuil de trou) dont ni `HasPoweredOn` ni
        // `didWake` ne sont arrivés laisserait `system_asleep` vrai pour toujours. Si la scrutation
        // tourne plus de `lostWakeDelay` après l'avis de veille, le Mac est éveillé : on le rattrape,
        // sans republication forcée.
        var lostWake = false
        if !recovering, systemAsleep, var sleep = lastSleep, sleep.end == nil,
           now - sleep.start > Self.lostWakeDelay {
            sleep.end = now
            lastSleep = sleep
            systemAsleep = false
            saver.noteSystemWake()
            lostWake = true
            logWarn("réveil non signalé : rattrapé (veille annoncée il y a \(String(format: "%.1f", now - sleep.start)) s)")
        }

        refreshFacts()
        if !evaluate(immediate: recovering || lostWake, force: force), covered || lostWake {
            // Pas de `force`, mais un état publié et non confirmé (envoi perdu avant le gel) repart.
            ensurePublished()
        }
    }

    /// Battement de cœur : republie l'état courant, même déjà confirmé.
    public func heartbeat() {
        guard !isShutDown, publishingAllowed, let state = published else { return }
        logDebug("battement de cœur → republication de l'état \(state ? "1" : "0")")
        emit(state, force: true)
    }

    // MARK: - Autorisation de publier

    /// Annonce l'état de l'écoute du serveur HTTP. Appelé depuis la file du moteur. Sans effet si
    /// l'annonce ne change rien. Au retour à `.ready` (la session étant à la console), l'état courant
    /// est publié en `force`, une seule fois, et au plus toutes les 2 s si l'écoute oscille.
    public func setListenerStatus(_ status: ListenerStatus) {
        guard !isShutDown, listenerStatus != status else { return }
        listenerStatus = status
        updateAuthorization()
        resumeIfNeeded()
    }

    /// Vrai si cette instance peut publier : port détenu et session à la console.
    public var publishingAllowed: Bool { authorizationVerdict().allowed }

    private func authorizationVerdict() -> (allowed: Bool, reason: String) {
        guard let listenerStatus else { return (false, "écoute en cours") }
        guard listenerStatus == .ready else { return (false, listenerStatus.blockedReason) }
        guard factsRead else { return (false, "faits non lus") }
        guard facts.onConsole else { return (false, "session hors console") }
        return (true, "prêt")
    }

    /// Journalise (INFO) chaque changement d'autorisation ou de raison, une fois, et suspend ou
    /// rend l'envoi au publieur (réessais, retour du réseau). Appelé à chaque rafraîchissement des
    /// faits et à chaque annonce du serveur.
    private func updateAuthorization() {
        guard factsRead else { return }
        let verdict = authorizationVerdict()
        if let last = loggedAuthorization, last.allowed == verdict.allowed, last.reason == verdict.reason { return }
        loggedAuthorization = verdict
        if verdict.allowed {
            logInfo("publication autorisée : \(verdict.reason)")
            everAuthorized = true
            // Le premier état publié part de lui-même (`start`) ; ensuite, un retour republie en force.
            resumePending = published != nil
        } else {
            logInfo("publication bloquée : \(verdict.reason)")
            resumePending = false
        }
        if publisherSuspended == verdict.allowed {
            publisherSuspended = !verdict.allowed
            publisher.setSendingSuspended(publisherSuspended)
        }
    }

    /// Seul point de sortie vers le publieur : rien ne part sans autorisation. La première
    /// publication après un retour d'autorisation est forcée, quelle que soit son origine, sauf si la
    /// dernière reprise forcée date de moins de 2 s : elle reste alors en attente (`resumePending`)
    /// et la publication part sans `force`.
    private func emit(_ state: Bool, force: Bool) {
        guard publishingAllowed else { return }
        let resumeDue = resumePending && resumeForceIsDue()
        let forced = force || resumeDue
        if resumeDue {
            logDebug("publication de l'état \(state ? "1" : "0") en force au retour de l'autorisation")
        }
        if forced, resumePending {
            // Une publication forcée, d'où qu'elle vienne, tient lieu de reprise.
            resumePending = false
            lastResumeForceAt = clock.monotonic()
        }
        publisher.publish(state, force: forced)
    }

    /// Le plancher de 2 s entre deux reprises forcées est-il passé ?
    private func resumeForceIsDue() -> Bool {
        guard let last = lastResumeForceAt else { return true }
        return clock.monotonic() - last >= Self.resumeForceMinInterval
    }

    /// Retour d'autorisation sans autre publication en route : l'état courant part en `force`,
    /// pourvu que le plancher entre deux reprises forcées soit passé (sinon, à la scrutation suivante).
    private func resumeIfNeeded() {
        guard resumePending, publishingAllowed, !isShutDown, let state = published,
              resumeForceIsDue() else { return }
        emit(state, force: true)
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

        let display = DisplayTopology.state(signals.displaySnapshot(), screensAsleepNotified: screensAsleepNotified)
        if screensAsleepNotified, !display.displays.contains(where: { !$0.isPlaceholder && $0.asleep }) {
            screensAsleepNotified = false
        }
        noteDisplays(display)
        next.displayAsleep = display.asleep
        next.onlineDisplays = display.onlineCount
        next.displayEnumerationOK = display.enumerationOK
        next.displayEvidence = display.evidence
        next.displays = display.displays

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
        factsRead = true
        updateAuthorization()
    }

    /// Suit les écrans d'une lecture à l'autre : le délai de `displays-reconfiguring`, et la ligne INFO
    /// « écrans : <résumé> » quand l'ensemble des écrans, l'écran principal ou la présence du fantôme change (la
    /// première lecture est journalisée aussi). Un écran qui s'endort ou se réveille ne change rien. Une
    /// énumération ratée ne prouve rien : ni délai, ni journal.
    private func noteDisplays(_ display: DisplayState) {
        guard display.enumerationOK else { return }
        if display.onlineCount == 0 {
            if noPhysicalDisplaySince == nil { noPhysicalDisplaySince = clock.monotonic() }
        } else {
            noPhysicalDisplaySince = nil
        }
        let layout = DisplayLayout(ids: display.displays.map(\.id).sorted(),
                                   mainID: display.displays.first(where: \.isMain)?.id,
                                   hasPlaceholder: display.displays.contains(where: \.isPlaceholder))
        guard layout != loggedDisplayLayout else { return }
        loggedDisplayLayout = layout
        logInfo("écrans : \(DisplayTopology.summary(display.displays))")
    }

    // MARK: - Décision

    private func factsVerdict() -> (state: Bool, reason: String) {
        if facts.systemAsleep { return (false, "system-asleep") }
        if facts.displayAsleep { return (false, "display-asleep") }
        if facts.screenSaverActive { return (false, "screensaver:\(facts.screenSaverEvidence)") }
        if facts.displayEnumerationOK && facts.onlineDisplays == 0 {
            // Plus d'écran physique, mais le fantôme du système reste : les écrans reviennent d'eux-mêmes au
            // réveil capot fermé ou dock débranché. L'état publié tient d'ici là.
            if let since = noPhysicalDisplaySince, clock.monotonic() - since < Self.noDisplayHoldSeconds {
                return (published ?? false, "displays-reconfiguring")
            }
            return (false, "no-display")
        }
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
        // R47 : un réveil n'est jamais relâché dans l'évaluation qui l'a lancé.
        defer { wakeJustIssued = false }
        guard !isShutDown else { return false }
        // Retour d'autorisation non servi par cette évaluation : l'état courant part en force.
        defer { resumeIfNeeded() }
        let now = clock.monotonic()
        let factual = factsVerdict()
        var resolved = factual
        var bypassSettle = immediate

        if var current = intent {
            if factual.state == current.target, now >= current.confirmNotBefore {
                logInfo("commande \(current.source) confirmée par les faits en "
                        + "\(String(format: "%.1f", now - current.issuedAt)) s (\(factual.reason))")
                intent = nil
                if current.target { onWakeConfirmed(now: now) }
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

        maintainWake(factual: factual, now: now)

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
            emit(resolved.state, force: false)
            return true
        } else if force, let state = published {
            publishedReason = resolved.reason
            emit(state, force: true)
            return true
        }
        return false
    }

    /// Redemande l'état publié, sans `force` : le publieur n'envoie que si l'état confirmé
    /// diffère (envoi perdu, abandonné ou encore en vol), et ne fait rien sinon.
    private func ensurePublished() {
        guard !isShutDown, let state = published else { return }
        emit(state, force: false)
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
            dismissSaver(now: clock.monotonic())
            return
        }
        logWarn("commande \(intent.source) sans effet observé → escalade: nouvelle tentative de réveil")
        wakeNow()
    }

    // MARK: - Réveil maîtrisé

    /// Seul point d'appel de `actions.wake()` : note que l'assertion qu'il pose est à relâcher.
    /// Avec `wake_command`, rien n'est posé : rien à relâcher, ni à journaliser.
    private func wakeNow() {
        wakeSaverWaitUntil = nil
        lightWake = false
        deferredReleaseReason = nil
        actions.wake()
        guard !actions.hasWakeOverride else { return }
        wakeAssertionHeld = true
        wakeJustIssued = true
    }

    /// Relâche l'assertion posée par `wake()`, une seule fois. Sans effet si rien n'est posé.
    private func releaseWakeAssertion(_ why: String) {
        guard wakeAssertionHeld else { return }
        wakeAssertionHeld = false
        wakeSaverWaitUntil = nil
        lightWake = false
        deferredReleaseReason = nil
        actions.releaseWake()
        logInfo("assertion de réveil relâchée (\(why))")
    }

    /// Levée de la retenue d'écran en cours, s'il y en a une.
    private func releaseDisplayHold(_ why: String) {
        guard displayHoldUntil != nil else { return }
        displayHoldUntil = nil
        actions.holdDisplay(seconds: 0)
        logInfo("retenue d'écran levée (\(why))")
    }

    /// Écarte l'économiseur par la commande du système (C24), puis, si le moyen est natif, prévient l'oracle :
    /// l'arrêt natif fait apparaître le panneau de connexion par-dessus un économiseur qui tourne encore, comme
    /// une frappe, sans que rien dans les faits ne le dise avant leur prochaine relecture. L'évaluation
    /// suivante confirme alors l'ON (preuve `écarté-par-commande`). Le repli `killall` n'écarte rien sous
    /// macOS 27 : rien n'est supposé, la confirmation attend les faits.
    /// Appelé seulement avec `stop_screensaver_on_wake` vrai.
    private func dismissSaver(now: Double) {
        let means = actions.screenSaverDismissal
        actions.dismissScreenSaver()
        switch means {
        case .native:
            saver.noteDismissed(now: now)
            logInfo("économiseur : écartement demandé (\(means.rawValue))")
        case .processKill:
            logInfo("économiseur : écartement demandé (\(means.rawValue)) : aucun effet supposé, les faits décideront")
        }
    }

    /// Un ON vient d'être confirmé par les faits : l'assertion de réveil a fini son travail et est
    /// relâchée. Puis, en option (`wake_hold_seconds > 0`) et sur une session verrouillée, l'écran
    /// est retenu : macOS le rendort vite sur l'écran de verrouillage. La retenue vient toujours
    /// après la confirmation, jamais dans `requestOn` : le chemin /wake n'attend rien.
    private func onWakeConfirmed(now: Double) {
        if wakeJustIssued {
            // R47 : confirmé dans l'évaluation même du réveil, il est relâché à la suivante.
            deferredReleaseReason = "ON confirmé par les faits"
        } else {
            releaseWakeAssertion("ON confirmé par les faits")
        }
        // Avec `wake_command`, `holdDisplay` ne pose rien (avertissement de config au démarrage).
        guard config.wakeHoldSeconds > 0, facts.sessionLocked, !actions.hasWakeOverride else { return }
        // Une nouvelle retenue remplace l'ancienne (c'est `holdDisplay` qui le garantit).
        displayHoldUntil = now + Double(config.wakeHoldSeconds)
        actions.holdDisplay(seconds: Double(config.wakeHoldSeconds))
        logInfo("retenue d'écran posée pour \(config.wakeHoldSeconds) s (session verrouillée)")
    }

    /// Appelé à chaque évaluation, une fois l'intention tranchée : relâche l'assertion d'une commande
    /// terminée sans confirmation (échéance, veille, remplacée) ou d'un réveil sans intention dont
    /// l'économiseur est parti, et lève la retenue d'écran à l'échéance, au déverrouillage ou à un OFF.
    private func maintainWake(factual: (state: Bool, reason: String), now: Double) {
        if wakeAssertionHeld, intent == nil, !wakeJustIssued {
            if lightWake {
                releaseWakeAssertion("réveil léger : évaluation suivante")
            } else if let until = wakeSaverWaitUntil {
                if !(now < until && facts.screenSaverRunning) {
                    releaseWakeAssertion("réveil sans intention : économiseur parti ou délai écoulé")
                }
            } else {
                releaseWakeAssertion(deferredReleaseReason ?? "commande terminée sans confirmation")
            }
        }
        guard let until = displayHoldUntil else { return }
        if now >= until {
            // L'assertion s'éteint d'elle-même à son échéance : rien à relâcher.
            displayHoldUntil = nil
            logInfo("retenue d'écran échue")
        } else if !facts.sessionLocked {
            releaseDisplayHold("session déverrouillée")
        } else if !factual.state {
            releaseDisplayHold("OFF")
        }
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
        // Deux avis de veille sans réveil entre eux : le début reste celui du premier.
        if lastSleep == nil || lastSleep?.end != nil {
            lastSleep = SleepSpan(start: clock.monotonic())
        }
        if let abandoned = intent {
            logInfo("intention \(abandoned.target ? "ON" : "OFF") abandonnée : veille")
            intent = nil
        }
        refreshFacts()
        if !evaluate(immediate: true) {
            // OFF était déjà publié : on s'assure seulement qu'il est confirmé.
            ensurePublished()
        }
        guard publishingAllowed else {
            // Une autre instance ou une autre session détient peut-être l'état : aucun OFF n'est
            // annoncé, et la veille n'attend rien.
            logInfo("veille : publication bloquée (\(authorizationVerdict().reason)) : aucun OFF envoyé "
                    + "→ veille autorisée")
            allow()
            return
        }
        let sent = publisher.hasUsableTarget
        publisher.notifyWhenDelivered(timeout: Self.sleepDeliveryTimeout) { delivered in
            let (confirmed, total) = self.publisher.deliveryCounts
            if !sent {
                logInfo("veille : OFF publié localement (webhooks coupés) : aucune cible → veille autorisée")
            } else if !delivered {
                logWarn("veille : " + Self.undeliveredText(confirmed: confirmed, total: total,
                                                           timeout: Self.sleepDeliveryTimeout)
                        + " → veille autorisée quand même")
            } else if self.published == false {
                logInfo("veille : OFF confirmé par \(confirmed)/\(total) cibles → veille autorisée")
            } else {
                // Une commande ON est arrivée entre-temps : c'est elle qui vient d'être livrée.
                logInfo("veille : état voulu redevenu ON avant la confirmation de OFF → veille autorisée")
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
            // Durée connue seulement pour le premier traitement du réveil d'une veille annoncée.
            var slept: Double?
            if var sleep = lastSleep, sleep.end == nil {
                slept = now - sleep.start
                sleep.end = now
                lastSleep = sleep
            }
            systemAsleep = false
            screensAsleepNotified = false
            saver.noteSystemWake()
            refreshFacts()
            // Après une veille longue, Homebridge a pu perdre l'état : on le force. Après une
            // veille courte (ou de durée inconnue : second avis de réveil, ou réveil déjà traité
            // par `tick()`), on ne renvoie que si l'état confirmé diffère. Le trou de scrutation
            // de la veille ne force plus dans `tick()` (R38).
            let long = slept.map { $0 >= Self.longSleepThreshold } ?? false
            if let slept {
                logInfo("réveil après \(String(format: "%.1f", slept)) s de veille"
                        + (long ? " → republication forcée" : ""))
            }
            if !evaluate(immediate: true, force: long) {
                ensurePublished()
            }
        case .systemWillNotSleep:
            // Veille annulée : ni réveil ni nouvel état. La commande en cours et le `didstart` en
            // attente de l'économiseur restent ; l'état revient par le lissage habituel.
            systemAsleep = false
            lastSleep = nil
            refreshFacts()
            evaluate(immediate: false)
        case .screenSaverDidStart:
            let now = clock.monotonic()
            saver.noteDidStart(now: now)
            // R55 : l'indice précède toute relecture, et le filtre de 250 ms, pour que la relecture cherche
            // le process tout neuf ; un scan que le filtre retarde est fait à la scrutation suivante.
            signals.saverProcessHint()
            refreshAfterNotification(now: now)
        case .screenSaverDidStop:
            let now = clock.monotonic()
            saver.noteDidStop(now: now)
            signals.saverProcessHint()
            refreshAfterNotification(now: now)
        case .saverProcessChanged:
            signals.saverProcessHint()
            refreshFacts()
            evaluate(immediate: false)
        case .screenLocked, .screenUnlocked:
            refreshAfterNotification(now: clock.monotonic())
        case .screensDidSleep:
            // Le système le dit : un écran physique au moins s'est endormi, même si un écran virtuel veille encore.
            screensAsleepNotified = true
            refreshFacts()
            evaluate(immediate: false)
        case .screensDidWake:
            screensAsleepNotified = false
            refreshFacts()
            evaluate(immediate: false)
        case .sessionActive, .sessionInactive:
            refreshFacts()
            evaluate(immediate: false)
        }
    }

    /// Relecture des faits et évaluation après une notification de l'économiseur ou du verrouillage, au
    /// plus une toutes les `notificationRefreshMinInterval` secondes.
    private func refreshAfterNotification(now: Double) {
        if let last = lastNotificationRefreshAt, now - last < Self.notificationRefreshMinInterval { return }
        lastNotificationRefreshAt = now
        refreshFacts()
        evaluate(immediate: false)
    }

    // MARK: - Arrêt

    /// Arrêt du daemon (SIGTERM, SIGINT, SIGHUP). Verrouille le moteur : plus aucune publication,
    /// aucune action (réveil, OFF, économiseur), aucun battement de cœur ni nouvelle évaluation ;
    /// les lectures (`currentState`, `statusSnapshot`, `inspect`) restent possibles.
    ///
    /// Avec `publishOff`, OFF est publié en `force` par `publishBeforeExit` : une requête ON en vol
    /// garde 500 ms pour aboutir (OFF part ensuite), puis est annulée ; `done` part à la livraison
    /// (toutes les cibles), ou après `shutdownDeliveryTimeout` (2 s) au plus. Sans `publishOff` (redémarrage
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
        // Rien ne doit survivre au daemon : l'assertion de réveil (relâchée même si le moteur la croit
        // déjà relâchée, la demande est sans effet sinon) et la retenue d'écran.
        wakeAssertionHeld = false
        wakeSaverWaitUntil = nil
        actions.releaseWake()
        releaseDisplayHold("arrêt")
        guard publishOff else {
            logInfo("arrêt : aucune publication OFF")
            done()
            return
        }
        guard publishingAllowed else {
            // Jamais autorisée : rien n'a été annoncé. Autorisée puis bloquée : une autre session
            // détient peut-être l'état. Dans les deux cas, un OFF d'arrêt serait faux ou nuisible.
            let why = everAuthorized ? "publication bloquée : \(authorizationVerdict().reason)"
                                     : "publication jamais autorisée"
            logInfo("arrêt : aucune publication OFF (\(why))")
            done()
            return
        }
        logInfo("arrêt : publication OFF avant de partir")
        published = false
        publishedReason = "shutdown"
        // Un ON en vol garde 500 ms pour aboutir (OFF part alors après lui) ; muet, il est annulé (R40).
        let sent = publisher.hasUsableTarget
        publisher.publishBeforeExit(false)
        publisher.notifyWhenDelivered(timeout: Self.shutdownDeliveryTimeout) { delivered in
            let (confirmed, total) = self.publisher.deliveryCounts
            if !sent {
                logInfo("arrêt : OFF publié localement (webhooks coupés) : aucune cible")
            } else if delivered {
                logInfo("arrêt : OFF confirmé par \(confirmed)/\(total) cibles")
            } else {
                logWarn("arrêt : " + Self.undeliveredText(confirmed: confirmed, total: total,
                                                          timeout: Self.shutdownDeliveryTimeout)
                        + " → départ quand même")
            }
            done()
        }
    }

    /// Texte d'une livraison incomplète à l'échéance : aucune cible n'a confirmé (« non confirmé »),
    /// ou seulement une partie (« confirmé par n/m cibles seulement »), sans nier celles qui ont répondu.
    private static func undeliveredText(confirmed: Int, total: Int, timeout: Double) -> String {
        confirmed == 0
            ? "OFF non confirmé en \(timeout) s (0/\(total) cibles)"
            : "OFF confirmé par \(confirmed)/\(total) cibles seulement en \(timeout) s"
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
        // Un OFF remplace tout ON en attente et met fin à la retenue d'écran.
        releaseWakeAssertion("commande OFF")
        releaseDisplayHold("commande OFF")
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
        // L'économiseur lancé crée un process `ScreenSaverEngine` : la lecture suivante le cherche tout
        // de suite. Une extinction de l'écran ou une veille n'en crée aucun.
        if action == .screensaver { signals.saverProcessHint() }
        evaluate(immediate: true)
    }

    /// Commande ON. Idempotente : un doublon reçu pendant une intention ON en cours ne fait
    /// rien ; une intention OFF en cours est remplacée. Les faits sont relus d'abord. Déjà ON et
    /// sans intention OFF en cours, aucune intention n'est créée et rien n'est attendu, mais un
    /// réveil part quand même :
    /// - économiseur encore en marche (Ruling R30) : l'oracle le dit « écarté » jusqu'à
    ///   `saver_redisplay_idle_seconds` (30 s par défaut) après une frappe, alors que macOS a pu revenir
    ///   à l'économiseur. L'assertion tient tant qu'il tourne, au plus un délai de commande. Avec
    ///   `stop_screensaver_on_wake`, il est aussi écarté par la commande du système : si macOS est déjà
    ///   revenu à l'économiseur, le panneau reparaît pour 30 s ;
    /// - sinon, réveil léger (Ruling R49), réservé aux cas sans session d'économiseur : les faits ne voient
    ///   ni l'économiseur lancé par l'inactivité sous macOS 27, ni l'écran assombri. L'assertion est
    ///   relâchée à l'évaluation suivante.
    ///
    /// Un ON qui remplace un OFF dont l'action est partie n'est pas confirmé avant
    /// `command_escalate_after_ms` : l'économiseur lancé par `open -a` peut démarrer après coup, et
    /// l'escalade s'en charge alors.
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
                wakeNow()
                // Rien à confirmer : l'assertion tient tant que l'économiseur tourne, au plus un délai de commande.
                if wakeAssertionHeld {
                    wakeSaverWaitUntil = clock.monotonic() + Double(config.commandConfirmTimeoutMS) / 1000
                }
                // macOS a pu revenir à l'économiseur, que le panneau supposé visible ne montre plus : l'arrêt
                // natif le fait reparaître pour `saver_redisplay_idle_seconds` de plus.
                if config.stopScreensaverOnWake {
                    dismissSaver(now: clock.monotonic())
                }
            } else {
                logInfo("commande ON (\(source)) → déjà ON (\(factual.reason)) : réveil léger, sans intention")
                wakeNow()
                lightWake = wakeAssertionHeld
            }
            evaluate(immediate: true)
            return
        }

        let replacesOff = isPending(target: false)
        var next = makeIntent(target: true, source: "on")
        if replacesOff {
            // L'action OFF est partie : l'économiseur peut encore démarrer. Pas de confirmation avant
            // le délai d'escalade, qui arrête l'économiseur s'il est apparu entre-temps.
            next.confirmNotBefore = next.issuedAt + Double(config.commandEscalateAfterMS) / 1000
            logInfo("commande ON (\(source)) → remplace l'OFF en cours : confirmation au plus tôt dans "
                    + "\(String(format: "%.1f", Double(config.commandEscalateAfterMS) / 1000)) s")
        } else {
            logInfo("commande ON (\(source))")
        }
        intent = next
        wakeNow()
        // Un économiseur seul à l'écran ne s'arrête pas sur simple activité déclarée : on l'écarte dans le
        // même geste, comme le ferait une frappe clavier. Les faits ne le verront qu'à la relecture suivante.
        if facts.screenSaverActive && config.stopScreensaverOnWake {
            dismissSaver(now: clock.monotonic())
        }
        evaluate(immediate: true)
    }

    public func resync() {
        guard !isShutDown else { return }
        screensAsleepNotified = false
        if sleepInProgress {
            // Une veille annoncée sans réveil : le Mac s'endort, `system_asleep` reste vrai.
            logDebug("resynchronisation pendant une veille annoncée : veille gardée")
        } else {
            systemAsleep = false
            saver.noteSystemWake()
        }
        refreshFacts()
        evaluate(immediate: true, force: true)
    }

    /// Une veille annoncée par `willSleep` n'a été suivie ni d'un réveil, ni d'une annulation.
    private var sleepInProgress: Bool {
        guard systemAsleep, let lastSleep else { return false }
        return lastSleep.end == nil
    }

    /// Le réseau est redevenu utilisable : le publieur renvoie l'état aux cibles non confirmées.
    /// Ignoré pendant l'arrêt : l'envoi d'arrêt a ses propres réessais, bornés.
    public func networkBecameAvailable() {
        guard !isShutDown else {
            logDebug("réseau de nouveau utilisable pendant l'arrêt : avis ignoré")
            return
        }
        publisher.networkBecameAvailable()
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
            "publishing_allowed": authorizationVerdict().allowed,
            "publishing_reason": authorizationVerdict().reason,
            "saver_detection": saverDetection,
            "saver_dismissal": actions.screenSaverDismissal.rawValue,
            "main_display": facts.displays.first(where: \.isMain)?.idText ?? "none",
            "display_list": facts.displays.map { display -> [String: Any] in
                ["id": display.idText, "main": display.isMain, "asleep": display.asleep,
                 "placeholder": display.isPlaceholder]
            },
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

    /// Comment l'économiseur est détecté : `sac` (`SACScreenSaverIsRunning`), ou `hôte` si la fonction
    /// manque (repli sur l'hôte apparu après `didstart`).
    private var saverDetection: String {
        signals.saverSessionFlag() == nil ? "hôte" : "sac"
    }

    /// Instantané des faits pour `--once` / `--watch` (hors serveur HTTP).
    public func inspect() -> (state: Bool, reason: String, facts: Facts) {
        refreshFacts()
        let verdict = factsVerdict()
        return (published ?? verdict.state, verdict.reason, facts)
    }

    private func factsSummary() -> String { summary(of: facts) }

    private func summary(of facts: Facts) -> String {
        "sleep=\(facts.systemAsleep ? 1 : 0) display_off=\(facts.displayAsleep ? 1 : 0)(\(facts.displayEvidence)) "
            + "saver=\(facts.screenSaverActive ? 1 : 0)(\(facts.screenSaverEvidence)) "
            + "saver_running=\(facts.screenSaverRunning ? 1 : 0) "
            + "hid_idle=\(String(format: "%.1f", facts.hidIdleSeconds)) "
            + "locked=\(facts.sessionLocked ? 1 : 0)(\(facts.lockEvidence)) "
            + "logged_in=\(facts.consoleUserLoggedIn ? 1 : 0) secure_input=\(facts.secureInputActive ? 1 : 0) "
            + "displays=\(facts.onlineDisplays)"
    }
}
