import Foundation

/// Détermine si l'économiseur d'écran **occupe seul l'écran**, sous macOS 27.
///
/// Deux questions distinctes :
///
/// 1. *Une session d'économiseur est-elle en cours ?* Trois sources, dans cet ordre :
///    - `SACScreenSaverIsRunning` (login.framework) : vrai pendant toute la session, panneau de connexion
///      compris ; faux hors session, y compris sur un simple verrouillage (banc du 31/10), et aussi quand l'agent
///      de session ne répond pas (le repli ci-dessous ne couvre pas cette panne : seul le WARN « didstart non
///      corroboré » la trahit) → `sac` ;
///    - le process `ScreenSaverEngine` de l'utilisateur, qui n'existe que pour l'économiseur commandé
///      → `process` ;
///    - en repli, si SAC est indisponible : un hôte d'économiseur (`SaverHostRule`) lancé au plus
///      `hostLaunchTolerance` secondes avant un `didstart`, et vu moins de `corroborationWindow` secondes
///      après lui. Retenu par son PID, il fait foi tant qu'il vit et qu'aucun `didstop` n'arrive
///      → `notification+hôte`. Les paysages aériens, hébergés par des extensions qui ne sont pas des
///      hôtes, échappent à ce repli.
///
///    Une notification seule ne prouve rien : `DistributedNotificationCenter` ne dit pas qui l'a postée.
///    Un `didstart` que rien ne corrobore expire au bout de `corroborationWindow` secondes (une ligne au
///    journal), sans OFF. La session s'ouvre dès qu'une source est vue ; elle se ferme à la deuxième
///    lecture de suite sans source (une lecture isolée à 0 ne ferme rien), ou dès la première tant qu'un
///    `didstop` attend. Un `didstop` reçu alors que SAC vaut encore 1 attend jusqu'à `didStopSettleDelay`
///    secondes que SAC retombe à 0 (il y retombe d'ordinaire dans la demi-seconde, parfois après la lecture que
///    la notification déclenche) : sans avertissement, la première lecture sans source ferme alors la session.
///    Si SAC vaut toujours 1 à l'échéance, le `didstop` est incohérent : averti (au plus une fois par minute),
///    puis ignoré.
///
/// 2. *Est-il encore seul à l'écran ?* Une frappe ou un mouvement fait apparaître le panneau de connexion
///    **par-dessus un économiseur qui continue de tourner** : SAC reste à 1 et aucune notification n'est
///    postée. Les signaux sont l'activité matérielle (`HIDIdleTime`, lisible même session verrouillée) et
///    l'arrêt natif demandé par le moteur (`noteDismissed`). Une activité retenue signifie que le panneau
///    est affiché, c'est-à-dire une UI accessible → ON. macOS revient à l'économiseur `redisplayIdle`
///    secondes après la dernière activité (30 s mesurées) : l'économiseur est alors « réaffiché ».
///
/// La preuve (`Verdict.evidence`) nomme la source, suivie de `écarté-par-activité`,
/// `écarté-par-commande` ou `réaffiché` ; `none` hors session.
///
/// Les instants sont des secondes de fonctionnement hors veille (`Clock.awake()`), comme `HIDIdleTime`, pas des dates.
/// À n'utiliser que depuis la file série du moteur d'état.
public final class ScreenSaverOracle {
    public struct Verdict {
        /// Économiseur seul à l'écran (ce qui décide de l'état OFF).
        public var active: Bool
        /// Session d'économiseur en cours, panneau par-dessus ou non.
        public var running: Bool
        /// La session est en cours, mais une activité ou un arrêt natif l'a recouverte du panneau.
        public var dismissed: Bool
        public var evidence: String
    }

    /// Délai (s) laissé à une source pour corroborer un `didstart` (et, en repli, à l'hôte pour être vu).
    public static let corroborationWindow: Double = 5
    /// Un hôte lancé jusqu'à cette durée (s) avant le `didstart` le corrobore encore.
    public static let hostLaunchTolerance: Double = 1
    /// Intervalle minimal (s) entre deux avertissements « didstop incohérent ».
    public static let incoherenceLogInterval: Double = 60
    /// Délai (s) laissé à SAC pour retomber à 0 après un `didstop`. Au banc, il y retombe dans la demi-seconde, mais
    /// pas toujours avant la lecture que la notification déclenche : le `didstop` attend, sans avertir.
    public static let didStopSettleDelay: Double = 2

    private struct Session {
        /// Ouverture : la grâce sur l'activité ne court qu'une fois, depuis cet instant.
        let begin: Double
        /// Depuis quand l'économiseur occupe l'écran : l'ouverture, puis chaque réaffichage.
        var occupiedSince: Double
        /// Dernière source vue, gardée pendant une lecture isolée sans source.
        var source: String
        /// La lecture précédente n'a vu aucune source : la suivante sans source ferme la session.
        var missedReading = false
    }

    /// Source vue à une lecture, et si elle corrobore un `didstart` en attente.
    private struct Source {
        let name: String
        let corroborates: Bool
    }

    private let dismissOnInput: Bool
    private let dismissGrace: Double
    private let redisplayIdle: Double
    private let signals: SystemSignals

    private var session: Session?
    /// Dernière frappe connue : `now − hidIdle` à la dernière lecture où l'inactivité était lisible.
    private var lastKnownInput: Double?
    /// Arrêt natif demandé par le moteur ; oublié à l'ouverture d'une session et à chaque réaffichage.
    private var nativeStopAt: Double?
    /// `didstart` en attente de corroboration : l'instant du plus récent.
    private var pendingDidStartAt: Double?
    /// `didstop` en attente, avec l'instant où il est arrivé. Une lecture sans source, ou dont la source n'est pas
    /// SAC, le consomme. Avec SAC à 1, il attend jusqu'à `didStopSettleDelay` secondes (`settleDidStop`).
    private var didStopAt: Double?
    /// Repli sans SAC : PID de l'hôte retenu après un `didstart`, jusqu'à sa disparition ou un `didstop`.
    private var retainedHostPID: Int32?
    /// Instant du dernier avertissement « didstop incohérent ».
    private var lastIncoherenceWarningAt: Double?

    public init(dismissOnInput: Bool = true,
                dismissGrace: Double = 1.5,
                redisplayIdle: Double = 30,
                signals: SystemSignals) {
        self.dismissOnInput = dismissOnInput
        self.dismissGrace = dismissGrace
        self.redisplayIdle = redisplayIdle
        self.signals = signals
    }

    // MARK: - Notifications et commandes

    /// `com.apple.screensaver.didstart` : n'ouvre rien à lui seul, il attend sa corroboration (voir
    /// `verdict`). Un nouveau `didstart` relance l'attente. Il ne touche jamais à une session établie :
    /// une paire `didstop`/`didstart` forgée pendant la saisie du mot de passe ne réarme rien.
    public func noteDidStart(now: Double) {
        pendingDidStartAt = now
    }

    /// `com.apple.screensaver.didstop` : la première lecture qui ne voit aucune source ferme la session
    /// (SAC à 1, il attend que SAC retombe : voir `didStopSettleDelay`). Il met fin à la preuve de l'hôte
    /// retenu et à l'attente d'un `didstart` : un économiseur annoncé puis arrêté n'ouvre plus de session,
    /// même si son hôte s'attarde.
    public func noteDidStop(now: Double) {
        didStopAt = now
        pendingDidStartAt = nil
        retainedHostPID = nil
    }

    /// Arrêt natif de l'économiseur, demandé par le moteur : le panneau de connexion s'affiche par-dessus.
    public func noteDismissed(now: Double) {
        nativeStopAt = now
    }

    /// Réveil du système : l'attente d'un `didstart` et celle d'un `didstop` sont oubliées. Une session
    /// établie reste ; ses sources sont relues au verdict suivant.
    public func noteSystemWake() {
        pendingDidStartAt = nil
        didStopAt = nil
    }

    // MARK: - Verdict

    /// `now` est un instant `Clock.awake()` en secondes ; `hidIdle`, les secondes depuis la dernière activité
    /// matérielle, -1 si elles sont illisibles.
    public func verdict(now: Double, hidIdle: Double) -> Verdict {
        if hidIdle >= 0 { lastKnownInput = now - hidIdle }
        let flag = signals.saverSessionFlag()
        let source = readSource(flag: flag, now: now)
        settlePendingDidStart(source: source, flag: flag, now: now)
        updateSession(source: source?.name, flag: flag, now: now)

        guard var current = session else {
            return Verdict(active: false, running: false, dismissed: false, evidence: "none")
        }
        var dismissed = false
        var panel: String?
        if dismissOnInput, let latest = latestActivity(in: current) {
            if now - latest.at >= redisplayIdle {
                // Plus rien depuis `redisplayIdle` : macOS est revenu à l'économiseur.
                current.occupiedSince = now
                session = current
                nativeStopAt = nil
                panel = "réaffiché"
            } else {
                dismissed = true
                panel = latest.byCommand ? "écarté-par-commande" : "écarté-par-activité"
            }
        }
        return Verdict(active: !dismissed,
                       running: true,
                       dismissed: dismissed,
                       evidence: panel.map { "\(current.source)+\($0)" } ?? current.source)
    }

    /// Sources dans l'ordre : SAC, process, puis l'hôte en repli. SAC à 0 (disponible) exclut le repli.
    private func readSource(flag: Bool?, now: Double) -> Source? {
        if flag == true { return Source(name: "sac", corroborates: true) }
        if signals.saverEnginePID() != 0 { return Source(name: "process", corroborates: true) }
        guard flag == nil else { return nil }
        return hostSource(now: now)
    }

    /// Repli sans SAC. `saverHosts()` balaie la table des process : il n'est lu que pendant l'attente d'un
    /// `didstart`, ou pour vérifier que l'hôte retenu vit encore. Seul un hôte nouvellement retenu
    /// corrobore le `didstart` ; l'hôte d'une session déjà ouverte ne prouve pas qu'un autre est né.
    private func hostSource(now: Double) -> Source? {
        // Invariant (R88) : `launchedSecondsAgo` est un âge mural, `now` et `pendingDidStartAt` sont sur l'horloge hors
        // veille. Leur différence n'est juste que si l'attente (5 s) ne traverse aucune veille ; `noteSystemWake()`
        // oublie l'attente au réveil, ce qui garantit cette condition.
        let waitingSince = pendingDidStartAt.flatMap { now - $0 < Self.corroborationWindow ? $0 : nil }
        guard waitingSince != nil || retainedHostPID != nil else { return nil }
        let hosts = signals.saverHosts()
        if let t0 = waitingSince {
            let earliestLaunch = t0 - Self.hostLaunchTolerance
            if let fresh = hosts.filter({ now - $0.launchedSecondsAgo >= earliestLaunch })
                .min(by: { $0.launchedSecondsAgo < $1.launchedSecondsAgo }) {
                if retainedHostPID != fresh.pid {
                    logDebug("économiseur : hôte \(fresh.pid) lancé après didstart → retenu")
                }
                retainedHostPID = fresh.pid
                return Source(name: "notification+hôte", corroborates: true)
            }
        }
        guard let pid = retainedHostPID else { return nil }
        if hosts.contains(where: { $0.pid == pid }) {
            return Source(name: "notification+hôte", corroborates: false)
        }
        retainedHostPID = nil
        logDebug("économiseur : hôte retenu \(pid) disparu")
        return nil
    }

    /// Un `didstart` en attente est corroboré par la source de cette lecture ; sans elle, il expire au
    /// bout de `corroborationWindow` secondes, journalisé une fois.
    private func settlePendingDidStart(source: Source?, flag: Bool?, now: Double) {
        guard let started = pendingDidStartAt else { return }
        if let source, source.corroborates {
            pendingDidStartAt = nil
            logDebug("économiseur : didstart corroboré (\(source.name))")
        } else if now - started >= Self.corroborationWindow {
            pendingDidStartAt = nil
            let missing = flag == nil ? "aucun ScreenSaverEngine ni hôte lancé après lui"
                                      : "SACScreenSaverIsRunning à 0, aucun ScreenSaverEngine"
            logWarn("économiseur : didstart non corroboré en \(Int(Self.corroborationWindow)) s (\(missing)) "
                    + "→ ignoré, aucun OFF")
        }
    }

    /// Ouvre la session à la première source vue ; la ferme à la deuxième lecture de suite sans source, ou dès
    /// la première tant qu'un `didstop` attend. Le `didstop` est consommé par la première lecture sans source,
    /// ou dont la source n'est pas SAC ; avec SAC à 1, il attend (`settleDidStop`).
    private func updateSession(source: String?, flag: Bool?, now: Double) {
        if let source {
            settleDidStop(flag: flag, now: now)
            if var current = session {
                current.source = source
                current.missedReading = false
                session = current
            } else {
                session = Session(begin: now, occupiedSince: now, source: source)
                nativeStopAt = nil
                logDebug("économiseur : session ouverte (\(source))")
            }
        } else {
            let stopped = didStopAt != nil
            didStopAt = nil
            guard var current = session else { return }
            if stopped || current.missedReading {
                session = nil
                nativeStopAt = nil
                retainedHostPID = nil
                logDebug("économiseur : session fermée (\(stopped ? "didstop" : "deux lectures sans source"))")
            } else {
                current.missedReading = true
                session = current
            }
        }
    }

    /// Règle le sort du `didstop` en attente, devant une source vue à cette lecture. Une source autre que SAC
    /// (process, hôte) le consomme sans effet. SAC à 1 le fait attendre : SAC retombe d'ordinaire à 0 dans la
    /// demi-seconde qui suit le `didstop`, mais la lecture que la notification déclenche peut précéder cette chute.
    /// Passé `didStopSettleDelay`, SAC vaut toujours 1 : le `didstop` est incohérent, averti puis ignoré. La
    /// session reste ouverte, comme une lecture isolée à 0 la laisserait.
    private func settleDidStop(flag: Bool?, now: Double) {
        guard let stoppedAt = didStopAt else { return }
        if flag == true {
            guard now - stoppedAt >= Self.didStopSettleDelay else { return }
            warnIncoherentDidStop(now: now)
        }
        didStopAt = nil
    }

    private func warnIncoherentDidStop(now: Double) {
        if let last = lastIncoherenceWarningAt, now - last < Self.incoherenceLogInterval { return }
        lastIncoherenceWarningAt = now
        logWarn("économiseur : didstop reçu, mais SACScreenSaverIsRunning vaut toujours 1 après "
                + "\(Int(Self.didStopSettleDelay)) s → incohérent, ignoré (un avertissement par minute au plus)")
    }

    /// Activité la plus récente qui recouvre l'économiseur du panneau : la dernière frappe connue, si elle
    /// suit l'occupation et la grâce de l'ouverture ; l'arrêt natif, s'il suit l'occupation (sans grâce).
    /// À égalité, l'arrêt natif l'emporte.
    private func latestActivity(in session: Session) -> (at: Double, byCommand: Bool)? {
        var latest: (at: Double, byCommand: Bool)?
        if let input = lastKnownInput, input > session.occupiedSince, input > session.begin + dismissGrace {
            latest = (input, false)
        }
        if let stop = nativeStopAt, stop >= session.occupiedSince, stop >= (latest?.at ?? stop) {
            latest = (stop, true)
        }
        return latest
    }
}
