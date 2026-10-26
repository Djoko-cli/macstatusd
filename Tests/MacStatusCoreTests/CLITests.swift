import XCTest
@testable import MacStatusCore

/// Tâche 12 : la ligne de commande validée, essayée sur le vrai binaire (`macstatusd`, construit
/// à côté du paquet de tests). Chaque lancement porte `--once` et un `--config` d'essai : même en
/// cas de régression, le binaire n'écoute pas, ne lit pas la vraie config et n'envoie rien.
final class CLITests: XCTestCase {
    private var binaire: URL!
    private var dossier: URL!

    override func setUpWithError() throws {
        let candidat = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("macstatusd")
        guard FileManager.default.isExecutableFile(atPath: candidat.path) else {
            throw XCTSkip("binaire macstatusd introuvable à côté du paquet de tests (\(candidat.path))")
        }
        binaire = candidat
        dossier = FileManager.default.temporaryDirectory.appendingPathComponent("macstatusd-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dossier { try? FileManager.default.removeItem(at: dossier) }
        super.tearDown()
    }

    /// Lance le binaire, attend sa fin (10 s au plus, puis arrêt de ce seul processus).
    ///
    /// stdout et stderr sont lus en parallèle, chacun sur sa file : un tube plein (64 Kio) ne
    /// bloque pas le binaire pendant qu'on attend l'autre, et l'attente de 10 s porte sur la fin
    /// du processus, pas sur une lecture qui pourrait ne jamais finir.
    private func lancer(_ arguments: [String]) throws -> (code: Int32, sortie: String, erreurs: String) {
        let process = Process()
        process.executableURL = binaire
        process.arguments = arguments
        let sortie = Pipe(), erreurs = Pipe()
        process.standardOutput = sortie
        process.standardError = erreurs
        process.standardInput = FileHandle.nullDevice
        let fin = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in fin.signal() }
        try process.run()

        let lectures = DispatchGroup()
        let verrou = NSLock()
        var octetsSortie = Data(), octetsErreurs = Data()
        DispatchQueue.global().async(group: lectures) {
            let lu = sortie.fileHandleForReading.readDataToEndOfFile()
            verrou.lock(); octetsSortie = lu; verrou.unlock()
        }
        DispatchQueue.global().async(group: lectures) {
            let lu = erreurs.fileHandleForReading.readDataToEndOfFile()
            verrou.lock(); octetsErreurs = lu; verrou.unlock()
        }

        if fin.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            XCTFail("\(arguments) : pas de fin au bout de 10 s")
            if fin.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = fin.wait(timeout: .now() + 2)
            }
        }
        // Le processus est fini : ses tubes se ferment, les lectures rendent la main. Un
        // petit-fils qui aurait hérité d'un tube ne doit pas bloquer le test pour autant.
        if lectures.wait(timeout: .now() + 2) == .timedOut {
            XCTFail("\(arguments) : tubes encore ouverts après la fin du processus")
        }
        verrou.lock(); defer { verrou.unlock() }
        return (process.terminationStatus, String(decoding: octetsSortie, as: UTF8.self),
                String(decoding: octetsErreurs, as: UTF8.self))
    }

    /// Tâche 12, tour 1 : un stderr plus gros que le tampon d'un tube (64 Kio) ne bloque pas
    /// `lancer` (les deux tubes sont lus en parallèle).
    func test_grosStderr_neBloquePas() throws {
        let fichier = dossier.appendingPathComponent("config.json")
        // 3000 clés inconnues de 40 caractères : un avertissement d'environ 130 Kio sur stderr.
        let cles = (0..<3000).map { String(format: "\"cle-inconnue-essai-%026d\": 1", $0) }
        try Data(("{" + cles.joined(separator: ", ") + "}").utf8).write(to: fichier)
        let r = try lancer(["--once", "--config", fichier.path])
        XCTAssertEqual(r.code, 0)
        XCTAssertGreaterThan(r.erreurs.utf8.count, 100_000)
        XCTAssertTrue(r.erreurs.contains("clés de config inconnues"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(r.sortie.utf8)) as? [String: Any], r.sortie)
    }

    func test_optionsSansValeurOuPortInvalide_code2() throws {
        let absent = dossier.appendingPathComponent("absent.json").path
        let cas: [([String], String)] = [
            (["--once", "--config"], "--config"),
            (["--once", "--config", ""], "--config"),
            (["--once", "--config", "--port", "19190"], "--config"),
            (["--once", "--config", absent, "--port"], "--port"),
            (["--once", "--config", absent, "--port", "0"], "--port"),
            (["--once", "--config", absent, "--port", "65536"], "--port"),
            (["--once", "--config", absent, "--port", "70000"], "--port"),
            (["--once", "--config", absent, "--port", "abc"], "--port"),
            (["--once", "--config", absent, "--port", "-1"], "--port"),
        ]
        for (arguments, option) in cas {
            let r = try lancer(arguments)
            XCTAssertEqual(r.code, 2, "\(arguments)")
            XCTAssertTrue(r.erreurs.contains(option), "\(arguments) : \(r.erreurs)")
            XCTAssertTrue(r.sortie.isEmpty, "\(arguments) : rien sur la sortie standard, \(r.sortie)")
        }
    }

    func test_once_afficheLesAvertissementsEtConfigError() throws {
        let fichier = dossier.appendingPathComponent("config.json")
        try Data(#"{"auth_token": "jeton-essai-0123456789abcdef", "port":"#.utf8).write(to: fichier)
        let r = try lancer(["--once", "--config", fichier.path, "--port", "19190"])
        XCTAssertEqual(r.code, 0, r.erreurs)
        XCTAssertTrue(r.erreurs.contains("illisible") && r.erreurs.contains(fichier.path), r.erreurs)
        XCTAssertFalse(r.erreurs.contains("0123456789abcdef"), r.erreurs)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.sortie.utf8)) as? [String: Any], r.sortie)
        XCTAssertNotNil(json["config_error"] as? String)

        // Config valide avec une valeur hors bornes : l'avertissement n'est plus perdu.
        try Data(#"{"poll_interval_ms": 10}"#.utf8).write(to: fichier)
        let v = try lancer(["--once", "--config", fichier.path])
        XCTAssertEqual(v.code, 0, v.erreurs)
        XCTAssertTrue(v.erreurs.contains("poll_interval_ms"), v.erreurs)
        let jsonValide = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(v.sortie.utf8)) as? [String: Any])
        XCTAssertNil(jsonValide["config_error"])
    }
}
