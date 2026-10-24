import XCTest
@testable import MacStatusCore

/// Routage HTTP : routes, codes, corps, types de contenu et règles d'accès.
/// Tâche 7 : 400 pour toute `ParseError`, 404 avant tout, 405 avec `Allow`.
/// Tâche 8 : `AccessPolicy.decide` avant toute route connue, une ligne WARN par refus.
final class RouterTests: XCTestCase {
    private let jeton = "jeton-essai-0123456789abcdef"
    private var moteur: FakeEngine!
    private var capture: CaptureLog!
    private var ancienRecepteur: LogSink?

    override func setUp() {
        super.setUp()
        moteur = FakeEngine()
        capture = CaptureLog()
        ancienRecepteur = CoreLog.sink
        CoreLog.sink = capture
    }

    override func tearDown() {
        CoreLog.sink = ancienRecepteur
        super.tearDown()
    }

    private func routeur(jeton: String = "", jetonEnQuery: Bool = false, noms: [String] = []) -> Router {
        var config = Config()
        config.authToken = jeton
        config.allowQueryToken = jetonEnQuery
        return Router(config: config, engine: moteur, localNames: noms)
    }

    /// `local` : pair en boucle locale (127.0.0.1), sinon pair du LAN (192.0.2.10).
    private func requete(_ chemin: String, methode: String = "GET",
                         query: [String: String] = [:], headers: [String: String] = [:],
                         local: Bool = false) -> HTTPRequest {
        HTTPRequest(method: methode, target: chemin, path: chemin, version: "HTTP/1.1",
                    query: query, headers: headers.merging(["host": "192.0.2.10:9090"]) { valeur, _ in valeur },
                    peer: local ? "127.0.0.1" : "192.0.2.10", peerIsLoopback: local)
    }

    /// Lignes WARN écrites par le routeur.
    private var avertissements: [String] { capture.lines.filter { $0.0 == .warn }.map { $0.1 } }

    private func texte(_ reponse: HTTPResponse) -> String {
        String(decoding: reponse.body, as: UTF8.self)
    }

    // MARK: - Lectures

    func test_routes_stateStatusHealth() throws {
        let r = routeur()

        moteur.etat = true
        var reponse = r.handle(requete("/state", local: true))
        XCTAssertEqual(reponse.status, 200)
        XCTAssertEqual(reponse.contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(texte(reponse), "1")

        moteur.etat = false
        XCTAssertEqual(texte(r.handle(requete("/state", local: true))), "0")

        reponse = r.handle(requete("/health"))
        XCTAssertEqual(reponse.status, 200)
        XCTAssertEqual(reponse.contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(texte(reponse), "OK")

        reponse = r.handle(requete("/status", local: true))
        XCTAssertEqual(reponse.status, 200)
        XCTAssertEqual(reponse.contentType, "application/json; charset=utf-8")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reponse.body) as? [String: Any])
        XCTAssertEqual(json["faux"] as? Bool, true)
        XCTAssertEqual(json["etat"] as? String, "1")
        // Format historique : indenté, clés triées.
        XCTAssertEqual(texte(reponse), "{\n  \"etat\" : \"1\",\n  \"faux\" : true\n}")
    }

    func test_lecturesEnBoucleLocale_sansJeton_memeAvecJetonConfigure() {
        let r = routeur(jeton: jeton)
        XCTAssertEqual(r.handle(requete("/state", local: true)).status, 200)
        XCTAssertEqual(r.handle(requete("/status", local: true)).status, 200)
        XCTAssertEqual(r.handle(requete("/health", local: true)).status, 200)
        XCTAssertEqual(r.handle(requete("/health")).status, 200)
        XCTAssertEqual(moteur.appels, [.etat, .instantane])
    }

    func test_lecturesDistantes_exigentLeJeton() {
        let r = routeur(jeton: jeton)
        for chemin in ["/state", "/status"] {
            let reponse = r.handle(requete(chemin))
            XCTAssertEqual(reponse.status, 401, chemin)
            XCTAssertEqual(texte(reponse), "unauthorized", chemin)
        }
        XCTAssertTrue(moteur.appels.isEmpty)
        XCTAssertEqual(r.handle(requete("/state", headers: ["x-auth-token": jeton])).status, 200)
        XCTAssertEqual(r.handle(requete("/status", headers: ["authorization": "Bearer \(jeton)"])).status, 200)
        XCTAssertEqual(moteur.appels, [.etat, .instantane])
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
        let analysee = RequestParser.parse(head: Data("GET /state HTTP/1.0".utf8))
        // Pair non local (l'analyseur laisse `peerIsLoopback` à false) et aucun jeton configuré : 403.
        XCTAssertEqual(routeur().handle(analysee).status, 403)
        let locale = analysee.map { requete -> HTTPRequest in
            var requete = requete
            requete.peerIsLoopback = true
            return requete
        }
        XCTAssertEqual(routeur().handle(locale).status, 200)
    }

    func test_http10SansHost_commandeAvecJeton_200() {
        let analysee = RequestParser.parse(head: Data("GET /off HTTP/1.0\r\nX-Auth-Token: \(jeton)\r\n\r\n".utf8))
        XCTAssertEqual(routeur(jeton: jeton).handle(analysee).status, 200)
        XCTAssertEqual(moteur.appels, [.off("?")])
    }

    // MARK: - Commandes

    func test_commandeSansJetonConfigure_boucleLocale_appelleLeMoteur() {
        let r = routeur()
        for (chemin, attendu) in [("/sleep", FakeEngine.Appel.off("127.0.0.1")),
                                  ("/off", .off("127.0.0.1")),
                                  ("/wake", .on("127.0.0.1")),
                                  ("/on", .on("127.0.0.1")),
                                  ("/resync", .resync)] {
            let avant = moteur.appels.count
            let reponse = r.handle(requete(chemin, local: true))
            XCTAssertEqual(reponse.status, 200, chemin)
            XCTAssertEqual(reponse.contentType, "text/plain; charset=utf-8", chemin)
            XCTAssertEqual(texte(reponse), "OK", chemin)
            XCTAssertEqual(Array(moteur.appels.dropFirst(avant)), [attendu], chemin)
        }
    }

    func test_commandeSansJetonConfigure_distante_403_sansAppelDuMoteur() {
        let r = routeur()
        for chemin in ["/sleep", "/off", "/wake", "/on", "/resync", "/state", "/status"] {
            let reponse = r.handle(requete(chemin))
            XCTAssertEqual(reponse.status, 403, chemin)
            XCTAssertEqual(texte(reponse), "forbidden", chemin)
            XCTAssertEqual(reponse.reasonPhrase, "Forbidden", chemin)
        }
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_commandeAvecJeton_enTeteOuBearer_estAcceptee() {
        let r = routeur(jeton: jeton)
        XCTAssertEqual(r.handle(requete("/wake", headers: ["x-auth-token": jeton])).status, 200)
        XCTAssertEqual(r.handle(requete("/wake", headers: ["authorization": "bearer \(jeton)"])).status, 200)
        XCTAssertEqual(moteur.appels, [.on("192.0.2.10"), .on("192.0.2.10")])
    }

    func test_jetonEnQuery_refuseParDefaut_accepteSiOption() {
        XCTAssertEqual(routeur(jeton: jeton).handle(requete("/wake", query: ["token": jeton])).status, 401)
        XCTAssertTrue(moteur.appels.isEmpty)
        XCTAssertEqual(routeur(jeton: jeton, jetonEnQuery: true).handle(requete("/wake", query: ["token": jeton])).status,
                       200)
        XCTAssertEqual(moteur.appels, [.on("192.0.2.10")])
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

    func test_jetonEnQuery_ignoreParDefaut_lEnTeteDecide() {
        // Fin du comportement historique : un `?token=` faux ne masque plus un en-tête juste.
        let r = routeur(jeton: jeton)
        let reponse = r.handle(requete("/wake", query: ["token": "faux"], headers: ["x-auth-token": jeton]))
        XCTAssertEqual(reponse.status, 200)
    }

    func test_commandeEnHEAD_405_sansAppelDuMoteur() {
        let r = routeur(jeton: jeton)
        for chemin in ["/sleep", "/off", "/wake", "/on", "/resync"] {
            let reponse = r.handle(requete(chemin, methode: "HEAD", headers: ["x-auth-token": jeton]))
            XCTAssertEqual(reponse.status, 405, chemin)
            XCTAssertEqual(reponse.headers, ["Allow": "GET"], chemin)
        }
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_commandesIdempotentes_chaqueAppelEstTransmis() {
        let r = routeur()
        _ = r.handle(requete("/off", local: true))
        _ = r.handle(requete("/off", local: true))
        XCTAssertEqual(moteur.appels, [.off("127.0.0.1"), .off("127.0.0.1")])
    }

    // MARK: - Règles d'accès

    func test_origineOuSecFetch_403_avantLeJeton() {
        let r = routeur(jeton: jeton)
        for entetes in [["origin": "http://evil.example"], ["sec-fetch-site": "cross-site"],
                        ["sec-fetch-site": "same-origin"]] {
            let reponse = r.handle(requete("/wake", headers: entetes.merging(["x-auth-token": jeton]) { a, _ in a },
                                           local: true))
            XCTAssertEqual(reponse.status, 403, "\(entetes)")
            XCTAssertEqual(texte(reponse), "forbidden")
        }
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_pageWebDuMac_viaAnalyseur_403() {
        // Une page ouverte sur le Mac vise 127.0.0.1 : le navigateur ajoute Sec-Fetch-Site.
        let analysee = RequestParser.parse(head: Data(("GET /off HTTP/1.1\r\nHost: 127.0.0.1:9090\r\n"
            + "Sec-Fetch-Site: cross-site\r\nX-Auth-Token: \(jeton)\r\n\r\n").utf8)).map { requete -> HTTPRequest in
            var requete = requete
            requete.peer = "127.0.0.1"
            requete.peerIsLoopback = true
            return requete
        }
        XCTAssertEqual(routeur(jeton: jeton).handle(analysee).status, 403)
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_hostRebinde_403_nomLocalTransmis_200() {
        let r = routeur(jeton: jeton, noms: ["Mac-Essai.local"])
        var rebinde = requete("/off", headers: ["x-auth-token": jeton], local: true)
        rebinde.headers["host"] = "evil.example:9090"
        XCTAssertEqual(r.handle(rebinde).status, 403)
        XCTAssertTrue(moteur.appels.isEmpty)
        var nomLocal = rebinde
        nomLocal.headers["host"] = "Mac-Essai.local:9090"
        XCTAssertEqual(r.handle(nomLocal).status, 200)
        XCTAssertEqual(moteur.appels, [.off("127.0.0.1")])
    }

    func test_refus_uneLigneWARN_echappee_sansLeJeton() {
        let r = routeur(jeton: jeton)
        var reponse = r.handle(requete("/off", headers: ["x-auth-token": "jeton-essai-faux-0123456789"]))
        XCTAssertEqual(reponse.status, 401)
        XCTAssertEqual(avertissements.count, 1)
        let ligne = avertissements[0]
        XCTAssertTrue(ligne.contains("/off"), ligne)
        XCTAssertTrue(ligne.contains("192.0.2.10"), ligne)
        XCTAssertTrue(ligne.contains("401"), ligne)
        XCTAssertTrue(ligne.contains("token"), ligne)
        XCTAssertFalse(ligne.contains("jeton-essai"), ligne)

        // Pair hostile : ses caractères de contrôle sont échappés.
        var hostile = requete("/wake", headers: ["origin": "x", "x-auth-token": jeton])
        hostile.peer = "192.0.2.10\n\u{1B}[31mfaux"
        reponse = r.handle(hostile)
        XCTAssertEqual(reponse.status, 403)
        XCTAssertEqual(avertissements.count, 2)
        let deuxieme = avertissements[1]
        XCTAssertFalse(deuxieme.contains("\n"), deuxieme)
        XCTAssertFalse(deuxieme.contains("\u{1B}"), deuxieme)
        XCTAssertTrue(deuxieme.contains("\\u{0A}"), deuxieme)
        XCTAssertTrue(deuxieme.contains("origin"), deuxieme)
        XCTAssertFalse(deuxieme.contains(jeton), deuxieme)

        // Une requête acceptée n'écrit aucun avertissement.
        XCTAssertEqual(r.handle(requete("/wake", headers: ["x-auth-token": jeton])).status, 200)
        XCTAssertEqual(avertissements.count, 2)
        XCTAssertFalse(capture.lines.contains { $0.1.contains(jeton) })
    }

    func test_cheminInconnu_404_sansRegleDAcces() {
        // Même réponse pour tous : pas de jeton exigé, pas de contrôle de Host, pas de journal.
        let r = routeur(jeton: jeton)
        var requeteHostile = requete("/inconnu", methode: "POST", headers: ["origin": "http://evil.example"])
        requeteHostile.headers["host"] = "evil.example"
        XCTAssertEqual(r.handle(requeteHostile).status, 404)
        XCTAssertEqual(r.handle(requete("/inconnu")).status, 404)
        XCTAssertTrue(avertissements.isEmpty)
        XCTAssertTrue(moteur.appels.isEmpty)
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
        // Tâche 8 : les commandes n'acceptent que GET, d'où `Allow: GET`.
        let r = routeur(jeton: jeton)
        for methode in ["POST", "PUT", "DELETE", "OPTIONS", "PATCH", "TRACE", "CONNECT"] {
            for chemin in ["/state", "/status", "/health", "/sleep", "/off", "/wake", "/on", "/resync"] {
                let reponse = r.handle(requete(chemin, methode: methode, headers: ["x-auth-token": jeton]))
                XCTAssertEqual(reponse.status, 405, "\(methode) \(chemin)")
                XCTAssertEqual(texte(reponse), "method not allowed")
                let attendu = RouteClass.classify(path: chemin) == .command ? "GET" : "GET, HEAD"
                XCTAssertEqual(reponse.headers, ["Allow": attendu], "\(methode) \(chemin)")
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
        XCTAssertEqual(HTTPResponse.text("", status: 403).reasonPhrase, "Forbidden")
        XCTAssertEqual(HTTPResponse.text("", status: 404).reasonPhrase, "Not Found")
        XCTAssertEqual(HTTPResponse.text("", status: 405).reasonPhrase, "Method Not Allowed")
        XCTAssertEqual(HTTPResponse.text("", status: 413).reasonPhrase, "Payload Too Large")
        XCTAssertEqual(HTTPResponse.text("", status: 500).reasonPhrase, "Error")
    }
}
