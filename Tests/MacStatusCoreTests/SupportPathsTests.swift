import XCTest
@testable import MacStatusCore

/// Plan 4, tâche 4 (C2) : les dossiers de l'espace utilisateur, sans `/opt` ni `sudo`.
final class SupportPathsTests: XCTestCase {
    private let home = "/home/exemple"

    func test_cheminsParDefaut_sousLeDossierPersonnel() {
        let chemins = SupportPaths.resolve(environment: [:], bundleSupportName: nil, home: home)
        XCTAssertEqual(chemins.name, "macstatusd")
        XCTAssertEqual(chemins.support, "/home/exemple/Library/Application Support/macstatusd")
        XCTAssertEqual(chemins.config, "/home/exemple/Library/Application Support/macstatusd/config.json")
        XCTAssertEqual(chemins.logs, "/home/exemple/Library/Logs/macstatusd")
    }

    func test_variableDeSupport_lEmporte() {
        let chemins = SupportPaths.resolve(environment: ["MACSTATUSD_SUPPORT_DIR": "/private/tmp/essai/support"],
                                           bundleSupportName: nil, home: home)
        XCTAssertEqual(chemins.support, "/private/tmp/essai/support")
        XCTAssertEqual(chemins.config, "/private/tmp/essai/support/config.json")
        // Le journal ne suit pas la variable : il reste sous le dossier personnel.
        XCTAssertEqual(chemins.logs, "/home/exemple/Library/Logs/macstatusd")

        let vide = SupportPaths.resolve(environment: ["MACSTATUSD_SUPPORT_DIR": ""], bundleSupportName: nil, home: home)
        XCTAssertEqual(vide.support, "/home/exemple/Library/Application Support/macstatusd", "variable vide ignorée")
    }

    func test_nomDuPaquet_donneLesDossiers() {
        let chemins = SupportPaths.resolve(environment: [:], bundleSupportName: "macstatusd-essai", home: home)
        XCTAssertEqual(chemins.name, "macstatusd-essai")
        XCTAssertEqual(chemins.support, "/home/exemple/Library/Application Support/macstatusd-essai")
        XCTAssertEqual(chemins.config, "/home/exemple/Library/Application Support/macstatusd-essai/config.json")
        XCTAssertEqual(chemins.logs, "/home/exemple/Library/Logs/macstatusd-essai")
    }

    func test_nomInvalide_retombeSurMacstatusd() {
        for invalide in ["../x", "a/b", "", ".", ".."] {
            let chemins = SupportPaths.resolve(environment: [:], bundleSupportName: invalide, home: home)
            XCTAssertEqual(chemins.name, "macstatusd", "nom \"\(invalide)\"")
            XCTAssertEqual(chemins.support, "/home/exemple/Library/Application Support/macstatusd", "nom \"\(invalide)\"")
            XCTAssertEqual(chemins.logs, "/home/exemple/Library/Logs/macstatusd", "nom \"\(invalide)\"")
        }
    }
}
