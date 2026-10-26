import XCTest
import MacStatusCore
@testable import macstatusd

/// Journal fichier de l'exécutable (`Log`) : rotation, échecs signalés une fois, descripteur sûr.
/// Chaque test a son propre dossier temporaire, sa propre instance de `Log` et une horloge manuelle ;
/// aucun journal réel n'est touché.
final class LogFichierTests: XCTestCase {
    private var dossier: URL!
    private var fichier: URL!
    private var journal: Log!
    private var instant: UInt64 = 1_000_000_000_000
    private var signalements: [String] = []

    override func setUpWithError() throws {
        dossier = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstatusd-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        fichier = dossier.appendingPathComponent("j.log")
        signalements = []
        instant = 1_000_000_000_000
        journal = Log()
        journal.now = { [unowned self] in self.instant }
        journal.report = { [unowned self] in self.signalements.append($0) }
    }

    override func tearDown() {
        journal?.configure(level: .info, file: nil, echoToStdout: false)
        if let dossier {
            chmod(dossier.path, 0o700)
            try? FileManager.default.removeItem(at: dossier)
        }
        unsetenv(Log.maxBytesEnvironmentKey)
        super.tearDown()
    }

    private func ecrire(_ n: Int, taille: Int = 100) {
        journal.log(.info, "ligne \(n) " + String(repeating: "x", count: taille))
    }

    private func contenu(_ chemin: String) -> String {
        (try? String(contentsOfFile: chemin, encoding: .utf8)) ?? ""
    }

    /// Numéros des lignes « ligne N » d'un fichier, dans l'ordre du fichier.
    private func numeros(_ chemin: String) -> [Int] {
        contenu(chemin).split(separator: "\n").compactMap { ligne in
            guard let range = ligne.range(of: "ligne ") else { return nil }
            return Int(ligne[range.upperBound...].prefix { $0.isNumber })
        }
    }

    // MARK: - Rotation

    /// Les générations se suivent dans l'ordre : le journal courant est le plus récent, `.1` le précédent,
    /// jusqu'à `.5` ; jamais de `.6`, et aucune ligne n'est perdue ni dupliquée entre deux fichiers voisins.
    func test_generations_ordreDuPlusRecentAuPlusAncien() {
        journal.configure(level: .info, file: fichier, echoToStdout: false, maxBytes: 4096)
        for n in 1...400 { ecrire(n) }
        journal.flush()

        let chemins = [fichier.path] + (1...5).map { fichier.path + ".\($0)" }
        for chemin in chemins {
            XCTAssertTrue(FileManager.default.fileExists(atPath: chemin), chemin)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fichier.path + ".6"))
        let parFichier = chemins.map(numeros)
        for (indice, lignes) in parFichier.enumerated() {
            XCTAssertFalse(lignes.isEmpty, chemins[indice])
            XCTAssertEqual(lignes, lignes.sorted(), "lignes en ordre dans \(chemins[indice])")
        }
        XCTAssertEqual(parFichier[0].last, 400)
        // Chaque fichier finit juste avant le début du plus récent : suite continue, sans trou ni doublon.
        for indice in 1..<parFichier.count {
            XCTAssertEqual(parFichier[indice].last.map { $0 + 1 }, parFichier[indice - 1].first,
                           "\(chemins[indice]) puis \(chemins[indice - 1])")
        }
        for chemin in chemins {
            var info = stat()
            XCTAssertEqual(stat(chemin, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600, chemin)
        }
    }

    /// Une rotation impossible (dossier en lecture seule) n'est pas retentée à chaque ligne : elle l'est
    /// après `maxBytes` octets de plus, ou après 60 s. Un seul signalement par épisode, et les
    /// générations existantes restent intactes tant qu'elle échoue.
    func test_rotationRatee_retenteeApresMaxBytesOu60s() throws {
        try XCTSkipIf(getuid() == 0, "root passe outre les droits du dossier")
        journal.configure(level: .info, file: fichier, echoToStdout: false, maxBytes: 4096)
        ecrire(0)
        journal.flush()
        // Une génération déjà présente : une rotation ratée ne doit pas la décaler ni la perdre.
        try "ancienne génération\n".write(toFile: fichier.path + ".1", atomically: false, encoding: .utf8)
        XCTAssertEqual(chmod(dossier.path, 0o500), 0)

        func taille() -> Int {
            (try? FileManager.default.attributesOfItem(atPath: fichier.path)[.size] as? Int) ?? 0
        }
        var n = 1
        while journal.rotationAttempts == 0, n < 200 { ecrire(n); n += 1; journal.flush() }
        XCTAssertEqual(journal.rotationAttempts, 1, "première rotation tentée au dépassement")
        let apresPremierEchec = taille()
        XCTAssertGreaterThan(apresPremierEchec, 4096)

        for _ in 0..<10 { ecrire(n); n += 1 }
        journal.flush()
        XCTAssertEqual(journal.rotationAttempts, 1, "pas de nouvelle tentative avant +maxBytes ou 60 s")

        // Une nouvelle tentative dès que maxBytes octets de plus ont été écrits, pas avant ; elle échoue encore.
        while journal.rotationAttempts == 1, n < 1000 { ecrire(n); n += 1; journal.flush() }
        XCTAssertEqual(journal.rotationAttempts, 2, "tentative après +maxBytes octets")
        let ecart = taille() - apresPremierEchec
        XCTAssertGreaterThanOrEqual(ecart, 4096)
        XCTAssertLessThan(ecart, 4096 + 200, "juste après le seuil, pas bien plus tard")

        for _ in 0..<5 { ecrire(n); n += 1 }
        journal.flush()
        XCTAssertEqual(journal.rotationAttempts, 2)
        instant += 61 * 1_000_000_000
        ecrire(n); n += 1
        journal.flush()
        XCTAssertEqual(journal.rotationAttempts, 3, "tentative après 60 s")

        XCTAssertEqual(signalements.count, 1, "un seul signalement pour l'épisode : \(signalements)")
        XCTAssertTrue(signalements.first?.contains("rotation") ?? false, "\(signalements)")
        XCTAssertEqual(contenu(fichier.path + ".1"), "ancienne génération\n", "générations intactes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fichier.path + ".2"))

        // Dossier rétabli : la rotation réussit à la tentative suivante, et l'épisode est clos.
        XCTAssertEqual(chmod(dossier.path, 0o700), 0)
        instant += 61 * 1_000_000_000
        ecrire(n); n += 1
        journal.flush()
        XCTAssertEqual(journal.rotationAttempts, 4)
        XCTAssertTrue(contenu(fichier.path + ".1").contains("ligne 1 "), "rotation réussie")
        XCTAssertEqual(contenu(fichier.path + ".2"), "ancienne génération\n")
        XCTAssertLessThan((try? FileManager.default.attributesOfItem(atPath: fichier.path)[.size] as? Int) ?? 0, 4096)
    }

    // MARK: - Échecs signalés une fois

    /// Écriture impossible à chaque fois (descripteur ouvert en lecture seule : `EBADF`), alors que
    /// l'ouverture réussit à chaque réouverture (60 s) : c'est le même épisode, un seul signalement.
    func test_echecDEcritureRepete_unSeulSignalement() throws {
        try Data().write(to: fichier)
        journal.opener = { open($0, O_RDONLY | O_CLOEXEC) }
        journal.configure(level: .info, file: fichier, echoToStdout: false)
        ecrire(1); journal.flush()
        XCTAssertEqual(signalements.count, 1, "\(signalements)")
        XCTAssertTrue(signalements[0].contains("écriture impossible"), signalements[0])
        for n in 2...4 {
            instant += 61 * 1_000_000_000
            ecrire(n); journal.flush()
        }
        XCTAssertEqual(signalements.count, 1, "même épisode : \(signalements)")
    }

    /// Une écriture réussie clôt l'épisode : l'échec suivant est signalé de nouveau.
    func test_ecritureReussie_clotLEpisode() throws {
        try XCTSkipIf(getuid() == 0, "root passe outre les droits du dossier")
        XCTAssertEqual(chmod(dossier.path, 0o500), 0)
        journal.configure(level: .info, file: fichier, echoToStdout: false)
        XCTAssertEqual(signalements.count, 1, "ouverture impossible : \(signalements)")
        ecrire(1); journal.flush()
        XCTAssertEqual(signalements.count, 1, "pas de réouverture avant 60 s")

        XCTAssertEqual(chmod(dossier.path, 0o700), 0)
        instant += 61 * 1_000_000_000
        ecrire(2); journal.flush()
        XCTAssertEqual(numeros(fichier.path), [2], "journal rouvert et écrit")

        // Fichier supprimé et dossier verrouillé : la comparaison d'inode (toutes les 100 écritures)
        // force une réouverture, qui échoue : nouvel épisode, nouveau signalement.
        try FileManager.default.removeItem(at: fichier)
        XCTAssertEqual(chmod(dossier.path, 0o500), 0)
        for n in 3..<(3 + Log.checkEveryWrites + 5) { ecrire(n) }
        journal.flush()
        XCTAssertEqual(signalements.count, 2, "\(signalements)")
    }

    // MARK: - Descripteur sûr

    /// Si l'entrée standard est fermée, `open` rendrait 0 : le journal ne doit jamais occuper un
    /// descripteur standard (l'écho écrit sur 1, la rotation ferme son descripteur).
    func test_descripteurStandard_jamaisPourLeJournal() throws {
        let sauvegarde = dup(STDIN_FILENO)
        try XCTSkipIf(sauvegarde < 0, "entrée standard indisponible")
        close(STDIN_FILENO)
        journal.configure(level: .info, file: fichier, echoToStdout: false)
        let descripteur = journal.openDescriptor
        ecrire(1); journal.flush()
        journal.configure(level: .info, file: nil, echoToStdout: false)
        dup2(sauvegarde, STDIN_FILENO)
        close(sauvegarde)

        XCTAssertGreaterThan(descripteur, 2, "descripteur du journal")
        XCTAssertEqual(numeros(fichier.path), [1], "le journal s'écrit quand même")
    }

    // MARK: - Taille de rotation d'essai

    func test_tailleDeRotationReduite_ligneInfoAuDemarrage() {
        setenv(Log.maxBytesEnvironmentKey, "8192", 1)
        journal.configure(level: .info, file: fichier, echoToStdout: false)
        journal.flush()
        let texte = contenu(fichier.path)
        XCTAssertTrue(texte.contains("INFO") && texte.contains(Log.maxBytesEnvironmentKey) && texte.contains("8192"),
                      texte)

        // Sans la variable : aucune ligne de ce genre.
        unsetenv(Log.maxBytesEnvironmentKey)
        let autre = dossier.appendingPathComponent("autre.log")
        journal.configure(level: .info, file: autre, echoToStdout: false)
        journal.flush()
        XCTAssertFalse(contenu(autre.path).contains(Log.maxBytesEnvironmentKey))

        // Valeur inutilisable : avertissement, la taille par défaut reste.
        setenv(Log.maxBytesEnvironmentKey, "12", 1)
        let invalide = dossier.appendingPathComponent("invalide.log")
        journal.configure(level: .info, file: invalide, echoToStdout: false)
        journal.flush()
        let texteInvalide = contenu(invalide.path)
        XCTAssertTrue(texteInvalide.contains("WARN") && texteInvalide.contains(Log.maxBytesEnvironmentKey), texteInvalide)
    }
}
