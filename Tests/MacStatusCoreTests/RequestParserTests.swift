import XCTest
@testable import MacStatusCore

/// Analyse stricte de l'en-tête HTTP : toute entrée hors norme est refusée avec une
/// `ParseError` précise, que le routeur transforme en 400.
final class RequestParserTests: XCTestCase {
    private func parse(_ texte: String) -> Result<HTTPRequest, ParseError> {
        RequestParser.parse(head: Data(texte.utf8))
    }

    private func requete(_ texte: String, file: StaticString = #filePath, line: UInt = #line) throws -> HTTPRequest {
        switch parse(texte) {
        case .success(let requete): return requete
        case .failure(let erreur):
            XCTFail("refus inattendu: \(erreur)", file: file, line: line)
            throw erreur
        }
    }

    // MARK: - Brief

    func test_ligneEnTroisElements() { XCTAssertEqual(parse("GET / \r\n\r\n"), .failure(.malformedRequestLine)) }
    func test_methodeSensibleALaCasse() { XCTAssertEqual(parse("get / HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n"), .failure(.invalidMethod)) }
    func test_version20_refusee() { XCTAssertEqual(parse("GET / HTTP/2.0\r\nHost: x\r\n\r\n"), .failure(.unsupportedVersion)) }
    func test_http11SansHost_refuse() { XCTAssertEqual(parse("GET /state HTTP/1.1\r\n\r\n"), .failure(.missingHost)) }
    func test_http10SansHost_accepte() { XCTAssertNotNil(try? parse("GET /state HTTP/1.0\r\n\r\n").get()) }
    func test_cibleNonImprimable_refusee() { XCTAssertEqual(parse("GET /a\u{1B}[31m HTTP/1.1\r\nHost: x\r\n\r\n"), .failure(.invalidTarget)) }

    // MARK: - Appel réel de Home Assistant

    func test_appelReelDeHA_analyse() throws {
        let r = try requete("GET /wake?action=WAKE HTTP/1.1\r\nHost: 192.0.2.10:9090\r\n"
            + "X-Auth-Token: jeton-essai-0123456789abcdef\r\nUser-Agent: HomeAssistant/2026.10\r\n"
            + "Accept: */*\r\nAccept-Encoding: gzip, deflate\r\n\r\n")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.target, "/wake?action=WAKE")
        XCTAssertEqual(r.path, "/wake")
        XCTAssertEqual(r.version, "HTTP/1.1")
        XCTAssertEqual(r.query, ["action": "WAKE"])
        XCTAssertEqual(r.headers["host"], "192.0.2.10:9090")
        XCTAssertEqual(r.headers["x-auth-token"], "jeton-essai-0123456789abcdef")
        XCTAssertEqual(r.headers["accept-encoding"], "gzip, deflate")
        XCTAssertEqual(r.peer, "?")
        XCTAssertFalse(r.peerIsLoopback)
    }

    func test_sansFinDEnTete_commeLeDonneLAdaptateur() throws {
        // L'adaptateur coupe l'en-tête avant `\r\n\r\n` : le parseur l'accepte avec ou sans.
        let r = try requete("GET /state HTTP/1.1\r\nHost: 192.0.2.10:9090")
        XCTAssertEqual(r.path, "/state")
        XCTAssertEqual(r.headers, ["host": "192.0.2.10:9090"])
    }

    func test_http10SansHost_champsRemplis() throws {
        let r = try requete("HEAD /health HTTP/1.0\r\n\r\n")
        XCTAssertEqual(r.method, "HEAD")
        XCTAssertEqual(r.version, "HTTP/1.0")
        XCTAssertTrue(r.headers.isEmpty)
    }

    // MARK: - Ligne de requête

    func test_ligneDeRequeteMalFormee() {
        for texte in ["", "\r\n\r\n", "GET", "GET /state", "GET /state HTTP/1.1 en-trop",
                      "GET  /state HTTP/1.1", " GET /state HTTP/1.1", "GET /state HTTP/1.1 ",
                      "GET\t/state\tHTTP/1.1"] {
            XCTAssertEqual(parse(texte + "\r\nHost: x\r\n\r\n"), .failure(.malformedRequestLine), texte.debugDescription)
        }
    }

    func test_versionsRefusees() {
        for version in ["HTTP/2.0", "HTTP/0.9", "HTTP/1.2", "http/1.1", "HTTP/1", "FOO"] {
            XCTAssertEqual(parse("GET / \(version)\r\nHost: x\r\n\r\n"), .failure(.unsupportedVersion), version)
        }
    }

    func test_methodes_majusculesSeulement() {
        for methode in ["get", "Get", "HEAd", "G3T", "GET!", "GÉT"] {
            XCTAssertEqual(parse("\(methode) /state HTTP/1.1\r\nHost: x\r\n\r\n"), .failure(.invalidMethod), methode)
        }
    }

    func test_methodeInconnueEnMajuscules_laisseeAuRouteur() throws {
        // R22 (d) : POST sur un chemin connu donne 405, pas 400 : le parseur le laisse passer.
        XCTAssertEqual(try requete("POST /state HTTP/1.1\r\nHost: x\r\n\r\n").method, "POST")
        XCTAssertEqual(try requete("OPTIONS /wake HTTP/1.1\r\nHost: x\r\n\r\n").method, "OPTIONS")
    }

    // MARK: - Cible

    func test_ciblesRefusees() {
        for cible in ["state", "*", "http://192.0.2.10:9090/state", "/a\u{7F}", "/é", "/a%", "/a%2", "/a%zz",
                      "/a#frag", "/state?x=%", "/state?x=%G0", "/state?%0A=1", "/state?x=%1B[31m",
                      "/state?x=%FF", "/state?x=%7F", "/state?=1"] {
            XCTAssertEqual(parse("GET \(cible) HTTP/1.1\r\nHost: x\r\n\r\n"), .failure(.invalidTarget), cible.debugDescription)
        }
    }

    func test_cleDeQueryEnDouble_refusee() {
        // R22 (b), y compris quand le double n'apparaît qu'après décodage.
        XCTAssertEqual(parse("GET /wake?token=a&token=b HTTP/1.1\r\nHost: x\r\n\r\n"), .failure(.invalidTarget))
        XCTAssertEqual(parse("GET /wake?token=a&%74oken=b HTTP/1.1\r\nHost: x\r\n\r\n"), .failure(.invalidTarget))
        XCTAssertEqual(parse("GET /wake?a&a HTTP/1.1\r\nHost: x\r\n\r\n"), .failure(.invalidTarget))
    }

    func test_query_decodageStrict_plusLitteral() throws {
        // R22 (c) : `+` reste littéral, `%2B` donne aussi `+`, `%20` donne une espace.
        let r = try requete("GET /wake?token=jeton%20essai&a+b=c+d&p=%2B&vide&k=&&x=%C3%A9 HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertEqual(r.path, "/wake")
        XCTAssertEqual(r.target, "/wake?token=jeton%20essai&a+b=c+d&p=%2B&vide&k=&&x=%C3%A9")
        XCTAssertEqual(r.query, ["token": "jeton essai", "a+b": "c+d", "p": "+", "vide": "", "k": "", "x": "é"])
    }

    func test_cheminNonDecode() throws {
        // Le chemin reste brut : `/st%61te` ne désigne pas `/state` (comportement historique).
        let r = try requete("GET /st%61te HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertEqual(r.path, "/st%61te")
        XCTAssertTrue(r.query.isEmpty)
    }

    func test_queryVide() throws {
        let r = try requete("GET /status? HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertEqual(r.path, "/status")
        XCTAssertTrue(r.query.isEmpty)
    }

    // MARK: - En-têtes

    func test_enTeteSansDeuxPoints_refuse() {
        // R22 (a)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: x\r\nsans deux-points\r\n\r\n"), .failure(.malformedHeader))
    }

    func test_crIsole_refuse() {
        // R22 (a) : un `\r` seul n'est ni un séparateur ni un caractère permis.
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: x\rX-Auth-Token: y\r\n\r\n"), .failure(.malformedHeader))
        XCTAssertEqual(parse("GET / HTTP/1.1\rHost: x\r\n\r\n"), .failure(.malformedRequestLine))
    }

    func test_lfIsole_refuse() {
        XCTAssertEqual(parse("GET / HTTP/1.1\nHost: x\n\n"), .failure(.malformedRequestLine))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: x\nX-A: b\r\n\r\n"), .failure(.malformedHeader))
    }

    func test_enTetesMalFormes() {
        for ligne in [": sans nom", "Host : espace avant les deux-points", " Suite: repliée", "\tSuite: repliée",
                      "Nom Espace: v", "X-A: valeur\u{01}", "X-A: valeur\u{7F}", "X-A: a\u{1B}[31m", "Nom\u{00}: v",
                      "Nom(é): v"] {
            XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: x\r\n\(ligne)\r\n\r\n"), .failure(.malformedHeader),
                           ligne.debugDescription)
        }
    }

    func test_hostEnDouble_refuse() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: a\r\nhost: b\r\n\r\n"), .failure(.malformedHeader))
    }

    func test_http11HostVide_refuse() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost:\r\n\r\n"), .failure(.missingHost))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost:  \t \r\n\r\n"), .failure(.missingHost))
    }

    func test_valeurs_espacesRetires_tabulationPermise() throws {
        let r = try requete("GET / HTTP/1.1\r\nHost: x\r\nX-Auth-Token: \t jeton-essai-0123456789abcdef \t\r\n"
            + "X-B: a\tb\r\nX-Vide:\r\n\r\n")
        XCTAssertEqual(r.headers, ["host": "x", "x-auth-token": "jeton-essai-0123456789abcdef",
                                   "x-b": "a\tb", "x-vide": ""])
    }

    func test_enTeteRepete_leDernierGagne() throws {
        // Hors des en-têtes d'accès, comportement historique gardé : le dernier gagne.
        let r = try requete("GET / HTTP/1.1\r\nHost: x\r\nX-A: a\r\nx-a: b\r\n\r\n")
        XCTAssertEqual(r.headers["x-a"], "b")
    }

    func test_enTetesDAccesEnDouble_refuses() {
        // Tâche 8, tour 1 : un doublon pourrait être lu différemment par un relais et par le daemon.
        for (nom, valeur) in [("Origin", "http://a.example"), ("Sec-Fetch-Site", "none"),
                              ("X-Auth-Token", "jeton-essai-0123456789abcdef"),
                              ("Authorization", "Bearer jeton-essai-0123456789abcdef")] {
            XCTAssertEqual(parse("GET /wake HTTP/1.1\r\nHost: x\r\n\(nom): \(valeur)\r\n\(nom.lowercased()): \(valeur)\r\n\r\n"),
                           .failure(.malformedHeader), nom)
            XCTAssertNotNil(try? parse("GET /wake HTTP/1.1\r\nHost: x\r\n\(nom): \(valeur)\r\n\r\n").get(), nom)
        }
        // Les deux en-têtes de jeton ensemble restent admis : la politique prend `X-Auth-Token`.
        XCTAssertNotNil(try? parse("GET /wake HTTP/1.1\r\nHost: x\r\nX-Auth-Token: a\r\nAuthorization: Bearer b\r\n\r\n").get())
    }

    func test_enTeteNonUTF8_refuse() {
        var octets = Data("GET / HTTP/1.1\r\nHost: x\r\nX-A: ".utf8)
        octets.append(contentsOf: [0xFF, 0xFE])
        octets.append(contentsOf: Array("\r\n\r\n".utf8))
        XCTAssertEqual(RequestParser.parse(head: octets), .failure(.malformedHeader))
        XCTAssertEqual(RequestParser.parse(head: Data([0xFF, 0xFE, 0x20, 0x2F])), .failure(.malformedRequestLine))
    }

    func test_valeurUTF8_acceptee() throws {
        XCTAssertEqual(try requete("GET / HTTP/1.1\r\nHost: x\r\nX-Piece: Pièce 1\r\n\r\n").headers["x-piece"], "Pièce 1")
    }

    func test_corpsApresLaFinDEnTete_ignore() throws {
        let r = try requete("GET /state HTTP/1.1\r\nHost: x\r\n\r\nGARBAGE\u{1B}\r\nsans deux-points")
        XCTAssertEqual(r.path, "/state")
        XCTAssertEqual(r.headers, ["host": "x"])
    }
}
