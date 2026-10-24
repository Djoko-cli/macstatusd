import XCTest
@testable import MacStatusCore

/// Routage HTTP : routes, codes, corps, types de contenu et authentification actuelle.
/// Depuis la tâche 7 : 400 pour toute `ParseError`, 404 avant 405, 405 avec `Allow`.
final class RouterTests: XCTestCase {
    private let jeton = "jeton-essai-0123456789abcdef"
    private var moteur: FakeEngine!

    override func setUp() {
        super.setUp()
        moteur = FakeEngine()
    }

    private func routeur(jeton: String = "") -> Router {
        var config = Config()
        config.authToken = jeton
        return Router(config: config, engine: moteur)
    }

    private func requete(_ chemin: String, methode: String = "GET",
                         query: [String: String] = [:], headers: [String: String] = [:],
                         peer: String = "192.0.2.10") -> HTTPRequest {
        HTTPRequest(method: methode, target: chemin, path: chemin, version: "HTTP/1.1",
                    query: query, headers: headers, peer: peer)
    }

    private func texte(_ reponse: HTTPResponse) -> String {
        String(decoding: reponse.body, as: UTF8.self)
    }

    // MARK: - Lectures

    func test_routes_stateStatusHealth() throws {
        let r = routeur()

        moteur.etat = true
        var reponse = r.handle(requete("/state"))
        XCTAssertEqual(reponse.status, 200)
        XCTAssertEqual(reponse.contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(texte(reponse), "1")

        moteur.etat = false
        XCTAssertEqual(texte(r.handle(requete("/state"))), "0")

        reponse = r.handle(requete("/health"))
        XCTAssertEqual(reponse.status, 200)
        XCTAssertEqual(reponse.contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(texte(reponse), "OK")

        reponse = r.handle(requete("/status"))
        XCTAssertEqual(reponse.status, 200)
        XCTAssertEqual(reponse.contentType, "application/json; charset=utf-8")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reponse.body) as? [String: Any])
        XCTAssertEqual(json["faux"] as? Bool, true)
        XCTAssertEqual(json["etat"] as? String, "1")
        // Format historique : indenté, clés triées.
        XCTAssertEqual(texte(reponse), "{\n  \"etat\" : \"1\",\n  \"faux\" : true\n}")
    }

    func test_lecturesSansJeton_memeAvecJetonConfigure() {
        let r = routeur(jeton: jeton)
        XCTAssertEqual(r.handle(requete("/state")).status, 200)
        XCTAssertEqual(r.handle(requete("/status")).status, 200)
        XCTAssertEqual(r.handle(requete("/health")).status, 200)
        XCTAssertTrue(moteur.appels.allSatisfy { $0 == .etat || $0 == .instantane })
    }

    func test_head_memeReponseQueGet_lAdaptateurRetireLeCorps() {
        let r = routeur()
        let get = r.handle(requete("/health", methode: "GET"))
        let head = r.handle(requete("/health", methode: "HEAD"))
        XCTAssertEqual(head.status, get.status)
        XCTAssertEqual(head.contentType, get.contentType)
        XCTAssertEqual(head.body, get.body)
        XCTAssertEqual(head.headers, get.headers)
    }

    func test_methodeEnMinuscules_400() {
        // R22 (e) : la méthode est sensible à la casse ; `head` est refusée dès l'analyse.
        let analysee = RequestParser.parse(head: Data("head /health HTTP/1.1\r\nHost: 192.0.2.10:9090".utf8))
        XCTAssertEqual(analysee, .failure(.invalidMethod))
        let reponse = routeur().handle(analysee)
        XCTAssertEqual(reponse.status, 400)
        XCTAssertEqual(texte(reponse), "bad request")
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_appelReelDeHA_analyseEtRoute_200() {
        let r = routeur(jeton: jeton)
        let analysee = RequestParser.parse(head: Data(("GET /wake?action=WAKE HTTP/1.1\r\nHost: 192.0.2.10:9090\r\n"
            + "X-Auth-Token: \(jeton)\r\n\r\n").utf8)).map { requete -> HTTPRequest in
            var requete = requete
            requete.peer = "192.0.2.10"
            return requete
        }
        let reponse = r.handle(analysee)
        XCTAssertEqual(reponse.status, 200)
        XCTAssertEqual(texte(reponse), "OK")
        XCTAssertEqual(moteur.appels, [.on("192.0.2.10")])
    }

    func test_http10SansHost_route() {
        XCTAssertEqual(routeur().handle(RequestParser.parse(head: Data("GET /state HTTP/1.0".utf8))).status, 200)
    }

    // MARK: - Commandes

    func test_commandeSansJetonConfigure_appelleLeMoteur() {
        let r = routeur()
        for (chemin, attendu) in [("/sleep", FakeEngine.Appel.off("192.0.2.10")),
                                  ("/off", .off("192.0.2.10")),
                                  ("/wake", .on("192.0.2.10")),
                                  ("/on", .on("192.0.2.10")),
                                  ("/resync", .resync)] {
            let avant = moteur.appels.count
            let reponse = r.handle(requete(chemin))
            XCTAssertEqual(reponse.status, 200, chemin)
            XCTAssertEqual(reponse.contentType, "text/plain; charset=utf-8", chemin)
            XCTAssertEqual(texte(reponse), "OK", chemin)
            XCTAssertEqual(Array(moteur.appels.dropFirst(avant)), [attendu], chemin)
        }
    }

    func test_commandeAvecJeton_enteteOuQuery_estAcceptee() {
        let r = routeur(jeton: jeton)
        XCTAssertEqual(r.handle(requete("/wake", headers: ["x-auth-token": jeton])).status, 200)
        XCTAssertEqual(r.handle(requete("/wake", query: ["token": jeton])).status, 200)
        XCTAssertEqual(moteur.appels, [.on("192.0.2.10"), .on("192.0.2.10")])
    }

    func test_commandeAvecJetonAbsentOuFaux_401_sansAppelDuMoteur() {
        let r = routeur(jeton: jeton)
        for chemin in ["/sleep", "/off", "/wake", "/on", "/resync"] {
            var reponse = r.handle(requete(chemin))
            XCTAssertEqual(reponse.status, 401, chemin)
            XCTAssertEqual(texte(reponse), "unauthorized", chemin)
            XCTAssertEqual(reponse.contentType, "text/plain; charset=utf-8", chemin)
            reponse = r.handle(requete(chemin, headers: ["x-auth-token": "jeton-essai-0123456789abcdeX"]))
            XCTAssertEqual(reponse.status, 401, chemin)
            reponse = r.handle(requete(chemin, query: ["token": "court"]))
            XCTAssertEqual(reponse.status, 401, chemin)
        }
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_jetonDansLaQuery_passeAvantLEnTete_commeAvant() {
        // Comportement historique : si `?token=` existe, l'en-tête n'est pas regardé.
        let r = routeur(jeton: jeton)
        let reponse = r.handle(requete("/wake", query: ["token": "faux"], headers: ["x-auth-token": jeton]))
        XCTAssertEqual(reponse.status, 401)
    }

    func test_commandeEnHEAD_estExecutee_commeAvant() {
        let r = routeur()
        XCTAssertEqual(r.handle(requete("/resync", methode: "HEAD")).status, 200)
        XCTAssertEqual(moteur.appels, [.resync])
    }

    func test_commandesIdempotentes_chaqueAppelEstTransmis() {
        let r = routeur()
        _ = r.handle(requete("/off"))
        _ = r.handle(requete("/off"))
        XCTAssertEqual(moteur.appels, [.off("192.0.2.10"), .off("192.0.2.10")])
    }

    // MARK: - Erreurs

    func test_cheminInconnu_404() {
        let r = routeur()
        for chemin in ["/", "/inconnu", "/STATE", "/state/"] {
            let reponse = r.handle(requete(chemin))
            XCTAssertEqual(reponse.status, 404, chemin)
            XCTAssertEqual(texte(reponse), "not found", chemin)
            XCTAssertEqual(reponse.contentType, "text/plain; charset=utf-8", chemin)
        }
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_cheminConnu_autreMethode_405AvecAllow() {
        // R22 (d)
        let r = routeur(jeton: jeton)
        for methode in ["POST", "PUT", "DELETE", "OPTIONS", "PATCH", "TRACE", "CONNECT"] {
            for chemin in ["/state", "/status", "/health", "/sleep", "/off", "/wake", "/on", "/resync"] {
                let reponse = r.handle(requete(chemin, methode: methode, headers: ["x-auth-token": jeton]))
                XCTAssertEqual(reponse.status, 405, "\(methode) \(chemin)")
                XCTAssertEqual(texte(reponse), "method not allowed")
                XCTAssertEqual(reponse.headers, ["Allow": "GET, HEAD"], "\(methode) \(chemin)")
            }
        }
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_cheminInconnu_404_quelleQueSoitLaMethode() {
        // R22 (d) : le 404 passe avant le 405.
        let r = routeur(jeton: jeton)
        for methode in ["GET", "HEAD", "POST", "DELETE", "OPTIONS"] {
            for chemin in ["/inconnu", "/", "/STATE"] {
                let reponse = r.handle(requete(chemin, methode: methode))
                XCTAssertEqual(reponse.status, 404, "\(methode) \(chemin)")
                XCTAssertTrue(reponse.headers.isEmpty)
            }
        }
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_toutParseError_400() {
        let erreurs: [ParseError] = [.malformedRequestLine, .unsupportedVersion, .invalidMethod, .invalidTarget,
                                     .missingHost, .malformedHeader]
        for erreur in erreurs {
            let reponse = routeur().handle(.failure(erreur))
            XCTAssertEqual(reponse.status, 400, "\(erreur)")
            XCTAssertEqual(texte(reponse), "bad request")
            XCTAssertEqual(reponse.contentType, "text/plain; charset=utf-8")
            XCTAssertTrue(reponse.headers.isEmpty)
        }
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_methodNotAllowed() {
        let reponse = HTTPResponse.methodNotAllowed(allow: "GET, HEAD")
        XCTAssertEqual(reponse.status, 405)
        XCTAssertEqual(reponse.reasonPhrase, "Method Not Allowed")
        XCTAssertEqual(reponse.headers, ["Allow": "GET, HEAD"])
        XCTAssertEqual(texte(reponse), "method not allowed")
    }

    func test_enTeteDeReponse_serialise() {
        let reponse = HTTPResponse.methodNotAllowed(allow: "GET, HEAD")
        XCTAssertEqual(reponse.serializedHead(),
                       "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain; charset=utf-8\r\n"
                       + "Content-Length: 18\r\nCache-Control: no-store\r\nAllow: GET, HEAD\r\n"
                       + "Connection: close\r\n\r\n")
    }

    func test_enTeteDeReponse_CRLFFiltres() {
        var reponse = HTTPResponse.text("OK")
        reponse.headers = ["X-Injecte": "a\r\nSet-Cookie: x=1", "X-\nNom": "v", "X-Sain": "ok", "X-Cr": "a\rb"]
        let tete = reponse.serializedHead()
        XCTAssertFalse(tete.contains("Set-Cookie"))
        XCTAssertFalse(tete.contains("X-Injecte"))
        XCTAssertFalse(tete.contains("Nom"))
        XCTAssertFalse(tete.contains("X-Cr"))
        XCTAssertTrue(tete.contains("X-Sain: ok\r\n"))
        // Seuls les CRLF de structure restent : 6 lignes et la ligne vide finale.
        XCTAssertEqual(tete.utf8.filter { $0 == 0x0A }.count, 7)
        XCTAssertEqual(tete.utf8.filter { $0 == 0x0D }.count, 7)
    }

    func test_libellesDesCodes() {
        XCTAssertEqual(HTTPResponse.text("", status: 200).reasonPhrase, "OK")
        XCTAssertEqual(HTTPResponse.text("", status: 400).reasonPhrase, "Bad Request")
        XCTAssertEqual(HTTPResponse.text("", status: 401).reasonPhrase, "Unauthorized")
        XCTAssertEqual(HTTPResponse.text("", status: 404).reasonPhrase, "Not Found")
        XCTAssertEqual(HTTPResponse.text("", status: 405).reasonPhrase, "Method Not Allowed")
        XCTAssertEqual(HTTPResponse.text("", status: 413).reasonPhrase, "Payload Too Large")
        XCTAssertEqual(HTTPResponse.text("", status: 500).reasonPhrase, "Error")
    }
}
