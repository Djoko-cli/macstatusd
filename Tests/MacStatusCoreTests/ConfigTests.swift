import XCTest
@testable import MacStatusCore

final class ConfigTests: XCTestCase {
    func test_fichierAbsent_donneLesDefautsEtUnAvertissement() {
        let r = Config.parse(data: nil)
        XCTAssertFalse(r.config.enabled); XCTAssertEqual(r.config.port, 9090)
        XCTAssertEqual(r.warnings.count, 1)
    }

    func test_clesConnues_sontLues() {
        let json = #"{"enabled":true,"webhook_base_url":"http://192.0.2.10:51828","port":"9191","settle_off_ms":900}"#
        let r = Config.parse(data: Data(json.utf8))
        XCTAssertTrue(r.config.enabled); XCTAssertEqual(r.config.port, 9191); XCTAssertEqual(r.config.settleOffMS, 900)
    }

    func test_bornes_sontAppliquees() {        // poll_interval_ms 10 → 100, settle_on_ms 99999 → 10000
        let r = Config.parse(data: Data(#"{"poll_interval_ms":10,"settle_on_ms":99999}"#.utf8))
        XCTAssertEqual(r.config.pollIntervalMS, 100); XCTAssertEqual(r.config.settleOnMS, 10_000)
    }

    func test_cleInconnue_donneUnAvertissement() {
        let r = Config.parse(data: Data(#"{"prot":9090}"#.utf8))
        XCTAssertTrue(r.warnings.contains { $0.contains("prot") })
    }

    func test_accesHTTP_defautsEtLecture() {
        let defauts = Config.parse(data: Data("{}".utf8)).config
        XCTAssertFalse(defauts.allowQueryToken)
        XCTAssertEqual(defauts.allowedHosts, [])
        let json = #"{"allow_query_token":true,"allowed_hosts":["Passerelle.Example","mac-essai.example"]}"#
        let r = Config.parse(data: Data(json.utf8))
        XCTAssertTrue(r.config.allowQueryToken)
        XCTAssertEqual(r.config.allowedHosts, ["Passerelle.Example", "mac-essai.example"])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
    }

    func test_allowedHosts_dUnAutreType_defautEtAvertissement() {
        for json in [#"{"allowed_hosts":"passerelle.example"}"#, #"{"allowed_hosts":[1,2]}"#] {
            let r = Config.parse(data: Data(json.utf8))
            XCTAssertEqual(r.config.allowedHosts, [], json)
            XCTAssertTrue(r.warnings.contains { $0.contains("allowed_hosts") }, json)
        }
    }

    func test_offActionInconnue_garderLeDefaut() {
        XCTAssertEqual(Config.parse(data: Data(#"{"off_action":"nimporte"}"#.utf8)).config.offAction, .screensaver)
    }

    // --- Ajouts : `load(path:)` doit continuer à citer le chemin dans ses avertissements ---

    func test_load_fichierAbsent_citeLeChemin() {
        let chemin = "/chemin/inexistant/config-essai.json"
        let r = Config.load(path: chemin)
        XCTAssertEqual(r.warnings.count, 1)
        guard let avertissement = r.warnings.first else { return }
        XCTAssertTrue(avertissement.contains(chemin), "avertissement sans chemin : \(avertissement)")
        XCTAssertTrue(avertissement.contains("introuvable"))
        XCTAssertFalse(r.config.enabled)
    }

    func test_load_jsonInvalide_citeLeChemin() throws {
        let dossier = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstatusd-essai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dossier) }
        let fichier = dossier.appendingPathComponent("config.json")
        // JSON tronqué. Attention : la virgule finale `{"port": 9191,}` est acceptée par le
        // JSONSerialization de macOS, elle ne sert donc pas de JSON invalide.
        try Data(#"{"port": 9191"#.utf8).write(to: fichier)

        let r = Config.load(path: fichier.path)
        XCTAssertEqual(r.warnings.count, 1)
        guard let avertissement = r.warnings.first else { return }
        XCTAssertTrue(avertissement.contains(fichier.path), "avertissement sans chemin : \(avertissement)")
        XCTAssertTrue(avertissement.contains("illisible"))
        XCTAssertEqual(r.config.port, 9090)
    }

    func test_parse_jsonInvalide_donneLesDefautsEtUnAvertissement() {
        let r = Config.parse(data: Data(#"{"port": 9191"#.utf8))
        XCTAssertEqual(r.config.port, 9090)
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertTrue(r.warnings.first?.contains("illisible") ?? false)
    }
}
