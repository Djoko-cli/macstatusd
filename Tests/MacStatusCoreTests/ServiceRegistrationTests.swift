import XCTest
@testable import MacStatusCore

/// Tâche 6 (C20) : état du service enregistré et mode de lancement. Aucun test n'appelle SMAppService
/// (`register()` et `unregister()` changent les Réglages de l'utilisateur) : seuls les types purs sont essayés.
final class ServiceRegistrationTests: XCTestCase {
    func test_etatDuService_correspondanceDesCodes() {
        XCTAssertEqual(ServiceState(rawStatus: 0), .notRegistered)
        XCTAssertEqual(ServiceState(rawStatus: 1), .enabled)
        XCTAssertEqual(ServiceState(rawStatus: 2), .requiresApproval)
        XCTAssertEqual(ServiceState(rawStatus: 3), .notFound)
        XCTAssertEqual(ServiceState(rawStatus: 7), .unknown)
        XCTAssertEqual(ServiceState.requiresApproval.rawValue, "requires-approval")
        XCTAssertEqual(ServiceState.notRegistered.rawValue, "not-registered")
        XCTAssertEqual(ServiceState.notFound.rawValue, "not-found")
        XCTAssertEqual(ServiceState.enabled.exitCode, 0)
        XCTAssertEqual(ServiceState.notRegistered.exitCode, 4)
        XCTAssertEqual(ServiceState.notFound.exitCode, 5)
        XCTAssertEqual(ServiceState.unknown.exitCode, 1)
        XCTAssertEqual(ServiceState.enabled.message, "activé")
        XCTAssertEqual(ServiceState.notRegistered.message, "non enregistré : lancer macstatusd --register")
        XCTAssertEqual(ServiceState.notFound.message,
                       "introuvable : l'app doit être dans ~/Applications ou /Applications")
        XCTAssertEqual(ServiceState.message(rawStatus: 7), "inconnu (code 7)")
        XCTAssertEqual(ServiceState.message(rawStatus: 1), "activé")
    }

    func test_etatDuService_aApprouver_ditOuLeReactiver() {
        XCTAssertEqual(ServiceState.requiresApproval.message,
                       "à autoriser : Réglages Système > Général > Ouverture et extensions")
        XCTAssertEqual(ServiceState.requiresApproval.exitCode, 3)
    }

    func test_modeDeLancement_agent() {
        XCTAssertEqual(LaunchMode.decide(arguments: ["--agent"], environment: [:]), .agent)
        // L'argument l'emporte sur l'environnement.
        XCTAssertEqual(LaunchMode.decide(arguments: ["--agent"],
                                         environment: ["XPC_SERVICE_NAME": "application.com.djoko.macstatusd.1.2"]),
                       .agent)
    }

    func test_modeDeLancement_finder() {
        let environnement = ["XPC_SERVICE_NAME": "application.com.djoko.macstatusd.640044241.640044246"]
        XCTAssertEqual(LaunchMode.decide(arguments: [], environment: environnement), .finder)
    }

    func test_modeDeLancement_ligneDeCommande() {
        XCTAssertEqual(LaunchMode.decide(arguments: [], environment: [:]), .commandLine)
        XCTAssertEqual(LaunchMode.decide(arguments: ["--once"], environment: [:]), .commandLine)
        // Un label d'agent (sans « application. ») n'est pas un lancement par le Finder.
        XCTAssertEqual(LaunchMode.decide(arguments: [], environment: ["XPC_SERVICE_NAME": "com.djoko.macstatusd"]),
                       .commandLine)
        // Avec une option, même sous le Finder : ligne de commande.
        XCTAssertEqual(LaunchMode.decide(arguments: ["--once"],
                                         environment: ["XPC_SERVICE_NAME": "application.x.1.2"]), .commandLine)
    }
}
