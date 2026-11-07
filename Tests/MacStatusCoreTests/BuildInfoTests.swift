import XCTest
@testable import MacStatusCore

/// Plan 4, tâche 4 (F22) : la version traçable (`--version`, `/status`).
final class BuildInfoTests: EngineCoreTestCase {
    private let valide = Data(#"{"version": "0.6.0-dev", "git": "v0.5.0-90-g1234567", "built_at": "2026-11-07"}"#.utf8)

    func test_buildInfo_valide() {
        let info = BuildInfo.parse(valide)
        XCTAssertEqual(info, BuildInfo(version: "0.6.0-dev", git: "v0.5.0-90-g1234567", builtAt: "2026-11-07"))
        XCTAssertEqual(info.versionLine, "macstatusd \(macstatusdVersion) (git v0.5.0-90-g1234567, 2026-11-07)")
    }

    func test_buildInfo_absent_compilationInconnue() {
        let info = BuildInfo.parse(nil)
        XCTAssertEqual(info, BuildInfo.unknown)
        XCTAssertEqual(info.versionLine, "macstatusd \(macstatusdVersion) (compilation inconnue)")
    }

    func test_buildInfo_illisible_compilationInconnue() {
        for illisible in ["", "pas du json", "[1, 2]", #"{"git": 3, "built_at": null}"#] {
            let info = BuildInfo.parse(Data(illisible.utf8))
            XCTAssertEqual(info.versionLine, "macstatusd \(macstatusdVersion) (compilation inconnue)", illisible)
        }
    }

    /// La version affichée est toujours la constante du binaire, jamais celle du fichier.
    func test_versionLine_neSuitPasLaVersionDuFichier() {
        let info = BuildInfo.parse(Data(#"{"version": "9.9.9", "git": "abc", "built_at": "2026-11-07"}"#.utf8))
        XCTAssertTrue(info.versionLine.hasPrefix("macstatusd \(macstatusdVersion) ("), info.versionLine)
    }

    func test_status_build_connu() {
        let core = moteur(build: BuildInfo.parse(valide))
        core.start()
        let build = core.statusSnapshot()["build"] as? [String: Any]
        XCTAssertEqual(build?["git"] as? String, "v0.5.0-90-g1234567")
        XCTAssertEqual(build?["built_at"] as? String, "2026-11-07")
    }

    /// Inconnu : le champ reste présent, ses deux valeurs valent null.
    func test_status_build_inconnu_valeursNulles() {
        let core = moteur(build: BuildInfo.parse(nil))
        core.start()
        let build = core.statusSnapshot()["build"] as? [String: Any]
        XCTAssertNotNil(build, "le champ build est toujours présent")
        XCTAssertEqual(build?.count, 2)
        XCTAssertTrue(build?["git"] is NSNull, "\(String(describing: build))")
        XCTAssertTrue(build?["built_at"] is NSNull, "\(String(describing: build))")
    }
}
