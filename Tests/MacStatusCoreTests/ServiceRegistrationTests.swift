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

    func test_alerteDuFinder_selonLEtat_dansLesDeuxLangues() {
        XCTAssertEqual(ServiceState.enabled.finderAlertText(registerFailed: false, preferEnglish: false),
                       "macstatusd tourne en arrière-plan. Réglages : Général > Ouverture et extensions.")
        XCTAssertEqual(ServiceState.enabled.finderAlertText(registerFailed: false, preferEnglish: true),
                       "macstatusd runs in the background. Settings: General > Login Items & Extensions.")
        XCTAssertEqual(ServiceState.requiresApproval.finderAlertText(registerFailed: false, preferEnglish: false),
                       "macstatusd attend ton autorisation : Réglages Système > Général > Ouverture et extensions.")
        XCTAssertEqual(ServiceState.requiresApproval.finderAlertText(registerFailed: false, preferEnglish: true),
                       "macstatusd needs your approval: System Settings > General > Login Items & Extensions.")
        XCTAssertEqual(ServiceState.notFound.finderAlertText(registerFailed: false, preferEnglish: false),
                       "macstatusd n'a pas pu s'enregistrer : introuvable : l'app doit être dans ~/Applications ou /Applications.")
        XCTAssertEqual(ServiceState.notRegistered.finderAlertText(registerFailed: false, preferEnglish: true),
                       "macstatusd could not register: non enregistré : lancer macstatusd --register.")
    }

    func test_alerteDuFinder_registerEnEchec_ditQueLEnregistrementAEchoue_sauf_a_autoriser() {
        // Un état « activé » après un register() en échec n'affiche pas de bonne nouvelle ; « à autoriser » garde son texte.
        XCTAssertEqual(ServiceState.enabled.finderAlertText(registerFailed: true, preferEnglish: false),
                       "macstatusd n'a pas pu s'enregistrer : activé.")
        // Agent coupé dans les Réglages : register() lève, mais l'utilisateur doit autoriser, et l'alerte le dit.
        XCTAssertEqual(ServiceState.requiresApproval.finderAlertText(registerFailed: true, preferEnglish: true),
                       "macstatusd needs your approval: System Settings > General > Login Items & Extensions.")
        XCTAssertEqual(ServiceState.requiresApproval.finderAlertText(registerFailed: true, preferEnglish: false),
                       "macstatusd attend ton autorisation : Réglages Système > Général > Ouverture et extensions.")
    }

    func test_etatDuService_aApprouver_ditOuLeReactiver() {
        XCTAssertEqual(ServiceState.requiresApproval.message,
                       "à autoriser : Réglages Système > Général > Ouverture et extensions")
        XCTAssertEqual(ServiceState.requiresApproval.exitCode, 3)
    }

    private let prod = "com.djoko.macstatusd"

    func test_modeDeLancement_agent() {
        XCTAssertEqual(LaunchMode.decide(arguments: ["--agent"], environment: [:], bundleIdentifier: prod), .agent)
        // L'argument l'emporte sur l'environnement.
        XCTAssertEqual(LaunchMode.decide(arguments: ["--agent"],
                                         environment: ["XPC_SERVICE_NAME": "application.com.djoko.macstatusd.1.2"],
                                         bundleIdentifier: prod),
                       .agent)
    }

    func test_modeDeLancement_finder() {
        let environnement = ["XPC_SERVICE_NAME": "application.com.djoko.macstatusd.640044241.640044246"]
        XCTAssertEqual(LaunchMode.decide(arguments: [], environment: environnement, bundleIdentifier: prod), .finder)
        // L'app d'essai, dont l'identifiant contient des points : reconnue par son propre identifiant.
        XCTAssertEqual(LaunchMode.decide(
            arguments: [],
            environment: ["XPC_SERVICE_NAME": "application.com.djoko.macstatusd.essai.640044241.640044246"],
            bundleIdentifier: "com.djoko.macstatusd.essai"), .finder)
    }

    func test_modeDeLancement_enfantDUneAutreApp_ligneDeCommande() {
        XCTAssertEqual(LaunchMode.decide(arguments: [],
                                         environment: ["XPC_SERVICE_NAME": "application.com.exemple.Editeur.1.2"],
                                         bundleIdentifier: "com.djoko.macstatusd.essai"), .commandLine)
    }

    func test_modeDeLancement_sansIdentifiant_ligneDeCommande() {
        let environnement = ["XPC_SERVICE_NAME": "application.com.djoko.macstatusd.essai.1.2"]
        XCTAssertEqual(LaunchMode.decide(arguments: [], environment: environnement, bundleIdentifier: nil),
                       .commandLine)
        XCTAssertEqual(LaunchMode.decide(arguments: [], environment: environnement, bundleIdentifier: ""),
                       .commandLine)
    }

    func test_modeDeLancement_enfantDeLAppDEssai_pasLaProduction() {
        XCTAssertEqual(LaunchMode.decide(
            arguments: [],
            environment: ["XPC_SERVICE_NAME": "application.com.djoko.macstatusd.essai.1.2"],
            bundleIdentifier: prod), .commandLine)
    }

    func test_modeDeLancement_ligneDeCommande() {
        XCTAssertEqual(LaunchMode.decide(arguments: [], environment: [:], bundleIdentifier: prod), .commandLine)
        XCTAssertEqual(LaunchMode.decide(arguments: ["--once"], environment: [:], bundleIdentifier: prod),
                       .commandLine)
        // Un label d'agent (sans « application. ») n'est pas un lancement par le Finder.
        XCTAssertEqual(LaunchMode.decide(arguments: [], environment: ["XPC_SERVICE_NAME": "com.djoko.macstatusd"],
                                         bundleIdentifier: prod), .commandLine)
        // Avec une option, même sous le Finder : ligne de commande.
        XCTAssertEqual(LaunchMode.decide(arguments: ["--once"],
                                         environment: ["XPC_SERVICE_NAME": "application.com.djoko.macstatusd.1.2"],
                                         bundleIdentifier: prod), .commandLine)
    }
}
