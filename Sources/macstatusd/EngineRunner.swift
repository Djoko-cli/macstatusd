import Foundation
import MacStatusCore

/// Exécuteur du moteur d'état : porte la file série unique, les minuteries de
/// scrutation et de battement de cœur, et fait respecter les contrats de file.
///
/// `EngineCore` n'a ni file ni minuterie ; il suppose qu'on l'appelle toujours
/// depuis la même file. Cette classe en est la seule porte d'entrée :
/// - les commandes (`requestOff`, `requestOn`, `resync`) partent en `async` ;
/// - les lectures (`currentState`, `statusSnapshot`, `inspect`) passent en
///   `sync`, toujours précédées de `dispatchPrecondition(.notOnQueue)` : un
///   `sync` lancé depuis la file elle-même bloquerait le daemon pour toujours ;
/// - les rappels du veilleur système arrivent déjà sur la file, ce que
///   `dispatchPrecondition(.onQueue)` vérifie.
final class EngineRunner {
    let queue = DispatchQueue(label: "macstatusd.state")

    private let config: Config
    private let webhook: WebhookClient
    private let core: EngineCore

    private var pollTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?

    init(config: Config, actions: PowerActions) {
        self.config = config
        // Le client webhook vit sur la file du moteur : transport et délais y rappellent.
        let clock = SystemClock()
        webhook = WebhookClient(config: config,
                                transport: URLSessionTransport(config: config, queue: queue),
                                scheduler: DispatchScheduler(queue: queue),
                                clock: clock)
        let signals = LiveSystemSignals()
        let oracle = ScreenSaverOracle(
            minimumInterval: max(1.0, Double(config.pollIntervalMS) / 1000),
            dismissOnInput: config.saverDismissOnInput,
            dismissGrace: Double(config.saverDismissGraceMS) / 1000,
            redisplayIdle: Double(config.saverRedisplayIdleSeconds),
            signals: signals
        )
        core = EngineCore(config: config, clock: clock, signals: signals, oracle: oracle,
                          actions: actions, publisher: webhook)
    }

    // MARK: - Cycle de vie

    func start() {
        queue.async { [self] in
            core.start()
            startPollTimer()
            startHeartbeatTimer()
        }
    }

    private func startPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(config.pollIntervalMS) / 1000
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.core.tick() }
        timer.resume()
        pollTimer = timer
    }

    private func startHeartbeatTimer() {
        guard config.heartbeatSeconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(config.heartbeatSeconds)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.core.heartbeat() }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - Événements système

    /// Le veilleur doit avoir été créé sur `queue` : ses rappels y arrivent.
    func attach(to watcher: PowerWatcher) {
        watcher.onWillSleep = { [weak self] allow in
            guard let self else { allow(); return }
            dispatchPrecondition(condition: .onQueue(queue))
            // Comme avant l'extraction : la veille n'est autorisée qu'une fois
            // l'état OFF livré à Homebridge, ou après 1,5 s au plus. L'attente est
            // un rappel : elle ne bloque pas la file, qui doit recevoir la réponse.
            core.willSleep { [webhook] in
                webhook.waitForDelivery(timeout: 1.5) { _ in allow() }
            }
        }

        watcher.onEvent = { [weak self] event in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(queue))
            core.handle(event)
        }
    }

    // MARK: - API (serveur HTTP, modes de diagnostic)

    /// État publié, identique à ce qui a été poussé vers Homebridge.
    var currentState: Bool {
        sync { core.currentState }
    }

    func requestOff(source: String = "homekit") {
        queue.async { [self] in core.requestOff(source: source) }
    }

    func requestOn(source: String = "homekit") {
        queue.async { [self] in core.requestOn(source: source) }
    }

    func resync() {
        queue.async { [self] in core.resync() }
    }

    func statusSnapshot() -> [String: Any] {
        sync { core.statusSnapshot() }
    }

    /// Instantané des faits pour `--once` / `--watch` (hors serveur HTTP).
    func inspect() -> (state: Bool, reason: String, facts: Facts) {
        sync { core.inspect() }
    }

    private func sync<T>(_ work: () -> T) -> T {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync(execute: work)
    }
}
