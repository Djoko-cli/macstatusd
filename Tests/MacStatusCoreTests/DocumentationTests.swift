import XCTest
@testable import MacStatusCore

/// Garde les deux README alignés sur le code (clés de config, champs de `/status`) et entre eux
/// (même suite de titres), et les notes de version dans l'ordre anglais puis français.
final class DocumentationTests: EngineCoreTestCase {
    /// Racine du dépôt, d'après l'emplacement de ce fichier (Tests/MacStatusCoreTests/…).
    private var racine: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func lire(_ nom: String) throws -> String {
        try String(contentsOf: racine.appendingPathComponent(nom), encoding: .utf8)
    }

    /// Niveaux des titres Markdown (nombre de `#`), hors blocs de code.
    private func niveauxDeTitres(_ texte: String) -> [Int] {
        var dansBloc = false
        var niveaux: [Int] = []
        for ligne in texte.split(separator: "\n", omittingEmptySubsequences: false) {
            if ligne.hasPrefix("```") { dansBloc.toggle(); continue }
            guard !dansBloc, ligne.hasPrefix("#") else { continue }
            let dieses = ligne.prefix(while: { $0 == "#" }).count
            if dieses <= 6, ligne.dropFirst(dieses).hasPrefix(" ") { niveaux.append(dieses) }
        }
        return niveaux
    }

    func test_chaqueCleDeConfig_estDecriteDansLesDeuxReadme() throws {
        for nom in ["README.md", "README.fr.md"] {
            let texte = try lire(nom)
            let absentes = Config.knownKeys.sorted().filter { !texte.contains("`\($0)`") }
            XCTAssertTrue(absentes.isEmpty, "\(nom) : clé(s) de config non décrite(s) : \(absentes.joined(separator: ", "))")
        }
    }

    func test_chaqueChampDeStatus_estDecritDansLesDeuxReadme() throws {
        let champs = moteur().statusSnapshot().keys.sorted()
        XCTAssertFalse(champs.isEmpty)
        for nom in ["README.md", "README.fr.md"] {
            let texte = try lire(nom)
            let absents = champs.filter { !texte.contains("`\($0)`") }
            XCTAssertTrue(absents.isEmpty, "\(nom) : champ(s) de /status non décrit(s) : \(absents.joined(separator: ", "))")
        }
    }

    /// Champs de `/status` absents d'un moteur au repos (voir `statusSnapshot()`) : ajoutés seulement
    /// quand l'arrêt est en cours, après une transition, ou pendant qu'une commande se confirme.
    private let champsOptionnelsDeStatus = [
        "shutting_down", "last_transition", "pending_command",
        "target", "source", "age_seconds", "escalated",
    ]

    func test_chaqueChampOptionnelDeStatus_estDecritDansLesDeuxReadme() throws {
        for nom in ["README.md", "README.fr.md"] {
            let texte = try lire(nom)
            let absents = champsOptionnelsDeStatus.filter { !texte.contains("`\($0)`") }
            XCTAssertTrue(absents.isEmpty, "\(nom) : champ(s) optionnel(s) de /status non décrit(s) : \(absents.joined(separator: ", "))")
        }
    }

    func test_lesDeuxReadme_ontLaMemeSuiteDeTitres() throws {
        let anglais = niveauxDeTitres(try lire("README.md"))
        let francais = niveauxDeTitres(try lire("README.fr.md"))
        XCTAssertFalse(anglais.isEmpty)
        XCTAssertEqual(anglais, francais, "README.md et README.fr.md n'ont pas la même suite de niveaux de titre")
    }

    func test_notesDeVersion_anglaisPuisFrancais() throws {
        let texte = try lire("NOTES-VERSIONS.md")
        var versions: [String] = []
        var sections: [[String]] = []
        for ligne in texte.split(separator: "\n", omittingEmptySubsequences: false) {
            if ligne.hasPrefix("## ") {
                versions.append(String(ligne.dropFirst(3)))
                sections.append([])
            } else if !sections.isEmpty {
                sections[sections.count - 1].append(String(ligne))
            }
        }
        XCTAssertEqual(versions, ["0.6.0", "0.5.0"], "NOTES-VERSIONS.md : sections attendues 0.6.0 puis 0.5.0")
        for (version, lignes) in zip(versions, sections) {
            let anglais = lignes.firstIndex(of: "**English**")
            let francais = lignes.firstIndex(of: "**Français**")
            XCTAssertNotNil(anglais, "\(version) : ligne **English** absente")
            XCTAssertNotNil(francais, "\(version) : ligne **Français** absente")
            if let anglais, let francais {
                XCTAssertLessThan(anglais, francais, "\(version) : **English** doit précéder **Français**")
            }
        }
    }

    func test_readme_lienVersLAutreLangue() throws {
        let enTete = { (texte: String) in texte.split(separator: "\n").prefix(3).joined(separator: "\n") }
        XCTAssertTrue(enTete(try lire("README.md")).contains("(README.fr.md)"), "README.md : lien vers README.fr.md absent en tête")
        XCTAssertTrue(enTete(try lire("README.fr.md")).contains("(README.md)"), "README.fr.md : lien vers README.md absent en tête")
    }
}
