import XCTest
@testable import MacStatusCore

/// Analyse de l'en-tête HTTP : comportement historique, tolérant, conservé tel quel.
final class RequestParserTests: XCTestCase {
    private func analyser(_ texte: String) -> HTTPRequest? {
        RequestParser.parse(head: Data(texte.utf8))
    }

    func test_parse_ligneEtEnTetesEtQuery() throws {
        let requete = try XCTUnwrap(analyser(
            "get /wake?action=WAKE&token=jeton%20essai&vide&k= HTTP/1.1\r\nHost: 192.0.2.10:9090\r\nX-Auth-Token:  jeton-essai-0123456789abcdef \r\nsans deux-points"))
        XCTAssertEqual(requete.method, "GET")
        XCTAssertEqual(requete.target, "/wake?action=WAKE&token=jeton%20essai&vide&k=")
        XCTAssertEqual(requete.path, "/wake")
        XCTAssertEqual(requete.version, "HTTP/1.1")
        XCTAssertEqual(requete.query, ["action": "WAKE", "token": "jeton essai", "vide": "", "k": ""])
        XCTAssertEqual(requete.headers, ["host": "192.0.2.10:9090",
                                         "x-auth-token": "jeton-essai-0123456789abcdef"])
        XCTAssertEqual(requete.peer, "?")
        XCTAssertFalse(requete.peerIsLoopback)
    }

    func test_parse_finsDeLigneSimples_etVersionAbsente() throws {
        let requete = try XCTUnwrap(analyser("HEAD /state\nHost: exemple.test\n"))
        XCTAssertEqual(requete.method, "HEAD")
        XCTAssertEqual(requete.path, "/state")
        XCTAssertEqual(requete.version, "")
        XCTAssertEqual(requete.headers["host"], "exemple.test")
    }

    func test_parse_enTeteRepete_ladernierGagne() throws {
        let requete = try XCTUnwrap(analyser("GET / HTTP/1.1\r\nX-Auth-Token: a\r\nx-auth-token: b"))
        XCTAssertEqual(requete.headers["x-auth-token"], "b")
    }

    func test_parse_cheminSansQuery() throws {
        let requete = try XCTUnwrap(analyser("GET /status HTTP/1.1"))
        XCTAssertEqual(requete.path, "/status")
        XCTAssertEqual(requete.target, "/status")
        XCTAssertTrue(requete.query.isEmpty)
    }

    func test_parse_entreesInvalides_renvoientNil() {
        XCTAssertNil(analyser(""))
        XCTAssertNil(analyser("GET"))
        XCTAssertNil(analyser("\r\n\r\n"))
        XCTAssertNil(RequestParser.parse(head: Data([0xFF, 0xFE, 0x20, 0x2F])))
    }
}
