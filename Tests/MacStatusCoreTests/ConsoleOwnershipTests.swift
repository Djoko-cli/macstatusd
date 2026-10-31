import XCTest
@testable import MacStatusCore

/// Lot 3, point 1 : la décision « cette session est-elle à la console ? » est une fonction pure.
/// Une console occupée par un autre uid bloque ; un registre muet (introuvable, propriété absente,
/// liste vide) se rabat sur la session graphique courante, puis laisse passer.
final class ConsoleOwnershipTests: XCTestCase {
    private let uid: UInt32 = 501

    /// Une entrée d'`IOConsoleUsers` : `owner == nil` laisse la clé de propriétaire absente.
    private func entree(console: Bool, owner: UInt32?) -> [String: Any] {
        var entree: [String: Any] = [ConsoleOwnership.onConsoleKey: NSNumber(value: console)]
        if let owner { entree[ConsoleOwnership.userIDKey] = NSNumber(value: owner) }
        return entree
    }

    /// Le dictionnaire de `CGSessionCopyCurrentDictionary`.
    private func session(console: Bool?, owner: UInt32? = 501) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let console { dict[ConsoleOwnership.onConsoleKey] = NSNumber(value: console) }
        if let owner { dict[ConsoleOwnership.userIDKey] = NSNumber(value: owner) }
        return dict
    }

    private func decider(registre: [[String: Any]]? = nil, cg: [String: Any]? = nil,
                         uid: UInt32? = nil) -> ConsoleOwnership.Verdict {
        ConsoleOwnership.decide(consoleUsers: registre, cgSession: cg, uid: uid ?? self.uid)
    }

    // MARK: - Le registre répond

    func test_registre_consoleDeLUtilisateur_estALaConsole() {
        let verdict = decider(registre: [entree(console: false, owner: 502), entree(console: true, owner: 501)])
        XCTAssertEqual(verdict, .init(onConsole: true, source: .registry))
    }

    func test_registre_consoleDUnAutreUtilisateur_bloque() {
        let verdict = decider(registre: [entree(console: true, owner: 502), entree(console: false, owner: 501)])
        XCTAssertEqual(verdict, .init(onConsole: false, source: .registry))
    }

    /// Le registre qui répond fait foi : un repli CGSession optimiste ne le contredit pas.
    func test_registre_autreUtilisateur_neSeLaisseJamaisContredireParLeRepli() {
        let verdict = decider(registre: [entree(console: true, owner: 502)], cg: session(console: true))
        XCTAssertEqual(verdict, .init(onConsole: false, source: .registry))
    }

    func test_registre_proprietaireIllisible_neBloquePas() {
        XCTAssertEqual(decider(registre: [entree(console: true, owner: nil)]),
                       .init(onConsole: true, source: .registry))
    }

    func test_registre_root_toutesLesConsolesComptent() {
        XCTAssertEqual(decider(registre: [entree(console: true, owner: 502)], uid: 0),
                       .init(onConsole: true, source: .registry))
    }

    // MARK: - Le registre ne répond pas : repli sur CGSession

    func test_registreIntrouvable_cgSessionALaConsole() {
        XCTAssertEqual(decider(registre: nil, cg: session(console: true)),
                       .init(onConsole: true, source: .cgSession))
    }

    func test_registreAbsent_cgSessionPasALaConsole_bloque() {
        XCTAssertEqual(decider(registre: nil, cg: session(console: false)),
                       .init(onConsole: false, source: .cgSession))
    }

    func test_listeVide_cgSessionDecide() {
        XCTAssertEqual(decider(registre: [], cg: session(console: true)),
                       .init(onConsole: true, source: .cgSession))
        XCTAssertEqual(decider(registre: [], cg: session(console: false)),
                       .init(onConsole: false, source: .cgSession))
    }

    /// Une liste sans aucune entrée à la console ne dit rien de la nôtre : même repli.
    func test_listeSansEntreeALaConsole_cgSessionDecide() {
        let registre = [entree(console: false, owner: 501)]
        XCTAssertEqual(decider(registre: registre, cg: session(console: true)),
                       .init(onConsole: true, source: .cgSession))
    }

    func test_cgSession_proprietaireAutre_bloque() {
        XCTAssertEqual(decider(registre: nil, cg: session(console: true, owner: 502)),
                       .init(onConsole: false, source: .cgSession))
    }

    func test_cgSession_root_neBloquePas() {
        XCTAssertEqual(decider(registre: nil, cg: session(console: false), uid: 0),
                       .init(onConsole: true, source: .cgSession))
    }

    // MARK: - Aucune source : on laisse passer

    func test_aucuneSource_laissePasser() {
        XCTAssertEqual(decider(), .init(onConsole: true, source: .none))
        XCTAssertEqual(decider(registre: []), .init(onConsole: true, source: .none))
    }

    func test_cgSessionSansLaCle_laissePasser() {
        XCTAssertEqual(decider(registre: nil, cg: session(console: nil)),
                       .init(onConsole: true, source: .none))
        XCTAssertEqual(decider(registre: nil, cg: [:]), .init(onConsole: true, source: .none))
    }

    func test_valeurDeMauvaisType_estIgnoree() {
        let registre: [[String: Any]] = [[ConsoleOwnership.onConsoleKey: "oui"]]
        XCTAssertEqual(decider(registre: registre), .init(onConsole: true, source: .none))
    }

    // MARK: - À quoi sert la session graphique (plan 3, tâche 6)

    private func role(_ registre: [[String: Any]]?) -> ConsoleOwnership.CGSessionRole {
        ConsoleOwnership.cgSessionRole(consoleUsers: registre)
    }

    /// Le cas courant : une entrée du registre est à la console, elle fait foi pour le verrouillage, l'ouverture de
    /// session et la console. `CGSessionCopyCurrentDictionary` (un appel IPC au serveur de fenêtres) n'est pas lue,
    /// que cette entrée soit celle de l'utilisateur ou celle d'un autre compte : dans ce cas le registre répond
    /// aussi, et c'est un blocage.
    func test_cgSession_pasLue_quandUneEntreeEstALaConsole() {
        XCTAssertEqual(role([entree(console: true, owner: 501)]), .notRead)
        XCTAssertEqual(role([entree(console: false, owner: 502), entree(console: true, owner: 501)]), .notRead)
        XCTAssertEqual(role([entree(console: true, owner: 502)]), .notRead)
        XCTAssertEqual(role([entree(console: true, owner: nil)]), .notRead)
    }

    /// Le registre ne répond pas (introuvable, `IOConsoleUsers` absent ou illisible) : CGSession est la seule autre
    /// source, pour le verrouillage, l'ouverture de session et la console. Repli complet.
    func test_cgSession_repliComplet_quandLeRegistreNeRepondPas() {
        XCTAssertEqual(role(nil), .fullFallback)
    }

    /// Le registre répond mais aucune entrée n'est à la console (fenêtre de connexion d'un changement rapide
    /// d'utilisateur, liste vide) : la session graphique est celle de l'agent, passée en arrière-plan. Elle ne sert
    /// qu'à la décision de console, jamais au verrouillage ni à l'ouverture de session de la console.
    func test_cgSession_pourLaDecisionSeulement_quandAucuneEntreeNEstALaConsole() {
        XCTAssertEqual(role([entree(console: false, owner: 501)]), .verdictOnly)
        XCTAssertEqual(role([entree(console: false, owner: 501), entree(console: false, owner: 502)]), .verdictOnly)
        XCTAssertEqual(role([]), .verdictOnly)
    }

    /// Même lecture que `decide` : une clé « console » qui n'est pas un booléen ne désigne aucune entrée à la console.
    func test_cgSession_valeurDeMauvaisType_neDesigneAucuneEntreeALaConsole() {
        XCTAssertEqual(role([[ConsoleOwnership.onConsoleKey: "oui"]]), .verdictOnly)
        XCTAssertEqual(role([[:]]), .verdictOnly)
    }

    /// Le piège de la fiche d'origine : sans entrée à la console, ne pas lire CGSession donnerait un laisser-passer à
    /// `decide`, et une session passée en arrière-plan publierait. Lue, elle dit « pas à la console » et bloque.
    func test_sansEntreeALaConsole_sessionEnArrierePlan_bloqueLaPublication() {
        let registre = [entree(console: false, owner: 501)]
        XCTAssertEqual(role(registre), .verdictOnly)
        XCTAssertEqual(decider(registre: registre, cg: session(console: false)),
                       .init(onConsole: false, source: .cgSession))
        XCTAssertEqual(decider(registre: registre, cg: nil), .init(onConsole: true, source: .none),
                       "sans la session graphique, rien ne bloque : c'est pourquoi elle est lue dans ce cas")
    }

    /// La règle et `decide` ne divergent pas : quand la règle dit de ne pas lire CGSession, aucune session graphique
    /// ne peut changer le verdict. Pour chaque uid, y compris root.
    func test_cgSessionPasLue_nePeutJamaisChangerLeVerdict() {
        let registres: [[[String: Any]]] = [
            [entree(console: true, owner: 501)],
            [entree(console: true, owner: 502)],
            [entree(console: true, owner: nil)],
            [entree(console: false, owner: 501), entree(console: true, owner: 502)],
        ]
        let sessions: [[String: Any]?] = [nil, session(console: true), session(console: false),
                                          session(console: true, owner: 502), [:]]
        for registre in registres {
            XCTAssertEqual(role(registre), .notRead, "\(registre)")
            for uid: UInt32 in [0, 501, 502] {
                let sansSession = decider(registre: registre, cg: nil, uid: uid)
                for cg in sessions {
                    XCTAssertEqual(decider(registre: registre, cg: cg, uid: uid), sansSession,
                                   "uid \(uid), registre \(registre), session \(String(describing: cg))")
                }
            }
        }
    }
}
