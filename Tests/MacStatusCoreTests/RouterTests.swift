import XCTest
@testable import MacStatusCore

/// Routage HTTP : caractérisation du comportement historique (routes, codes, corps,
/// types de contenu, authentification actuelle). Aucune règle nouvelle ici.
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

    func test_methodeEnMinuscules_estDejaMajusculeParLAnalyseur() throws {
        let analysee = try XCTUnwrap(RequestParser.parse(head: Data("head /health HTTP/1.1".utf8)))
        XCTAssertEqual(routeur().handle(analysee).status, 200)
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

    func test_post_405() {
        let r = routeur(jeton: jeton)
        for methode in ["POST", "PUT", "DELETE", "OPTIONS", "PATCH"] {
            for chemin in ["/state", "/wake", "/inconnu"] {
                let reponse = r.handle(requete(chemin, methode: methode, headers: ["x-auth-token": jeton]))
                XCTAssertEqual(reponse.status, 405, "\(methode) \(chemin)")
                XCTAssertEqual(texte(reponse), "method not allowed")
            }
        }
        XCTAssertTrue(moteur.appels.isEmpty)
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
