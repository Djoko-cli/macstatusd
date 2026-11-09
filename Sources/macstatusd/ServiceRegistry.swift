import AppKit
import Foundation
import MacStatusCore
import ServiceManagement

/// Enregistrement de l'agent du daemon auprès de macOS (SMAppService, C20). Seul fichier qui appelle SMAppService :
/// aucun test ne l'atteint, car `register()` et `unregister()` changent les Réglages de l'utilisateur.
enum ServiceRegistry {
    /// Le plist de l'agent se nomme d'après l'identifiant du paquet, dans `Contents/Library/LaunchAgents/`.
    /// `nil` hors d'un paquet `.app` (binaire lancé seul).
    private static func service() -> SMAppService? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        return SMAppService.agent(plistName: "\(identifier).plist")
    }

    /// État courant ; `notFound` hors d'un paquet.
    static func currentState() -> ServiceState {
        guard let service = service() else { return .notFound }
        return ServiceState(rawStatus: service.status.rawValue)
    }

    /// Enregistre l'agent, puis rend l'état obtenu. L'échec est rendu en texte.
    static func register() -> (state: ServiceState, failure: String?) {
        guard let service = service() else { return (.notFound, nil) }
        do {
            try service.register()
            return (currentState(), nil)
        } catch {
            return (currentState(), error.localizedDescription)
        }
    }

    static func unregister() -> (state: ServiceState, failure: String?) {
        guard let service = service() else { return (.notFound, nil) }
        do {
            try service.unregister()
            return (currentState(), nil)
        } catch {
            return (currentState(), error.localizedDescription)
        }
    }

    /// Options `--register`, `--unregister` et `--status-service` : imprime l'état, sort par son code.
    /// L'état est lu une seule fois, après l'action : message et code viennent de cette valeur.
    static func runCommand(_ option: String) -> Never {
        var failure: String?
        switch option {
        case "--register": failure = register().failure
        case "--unregister": failure = unregister().failure
        default: break
        }
        if let failure {
            FileHandle.standardError.write(Data("macstatusd: \(option) : \(failure)\n".utf8))
        }
        let status = service()?.status.rawValue
        print(status.map { ServiceState.message(rawStatus: $0) } ?? ServiceState.notFound.message)
        exit((status.map { ServiceState(rawStatus: $0) } ?? .notFound).exitCode)
    }

    /// Lancement par le Finder : enregistre l'agent, informe par une alerte fidèle à l'état relu, quitte. Le
    /// daemon, lui, tourne sous launchd.
    static func runFromFinder() -> Never {
        let registration = register()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        let french = Locale.preferredLanguages.first?.hasPrefix("fr") == true
        let alert = NSAlert()
        alert.messageText = registration.state.finderAlertText(registerFailed: registration.failure != nil,
                                                               preferEnglish: !french)
        alert.addButton(withTitle: "OK")
        alert.runModal()
        exit(registration.state.exitCode)
    }
}
