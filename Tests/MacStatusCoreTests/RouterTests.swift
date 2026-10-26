import XCTest
@testable import MacStatusCore

/// Routage HTTP : routes, codes, corps, types de contenu et règles d'accès.
/// Tâche 7 : 400 pour toute `ParseError`, 404 avant tout, 405 avec `Allow`.
/// Tâche 8 : `AccessPolicy.decide` avant toute route connue.
/// Tâche 9 : journal des refus borné par pair (voir `RateLimitsTests`).
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
        for chemin in ["/sleep", "/off", "/wake", "/on", "/resync"] {
            // Un routeur par chemin : 15 refus d'un même pair le feraient interdire (tâche 9).
            let r = routeur(jeton: jeton)
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

    // MARK: - Tâche 8, tour 1

    func test_pointDeVigilance1_octetsBrutsDeHA_200EtRequestOn() throws {
        // Octets exacts de l'appel de Home Assistant, du parseur au moteur, pair du LAN.
        let octets = Data("GET /wake?action=WAKE HTTP/1.1\r\nHost: 192.0.2.10:9090\r\nX-Auth-Token: \(jeton)\r\n\r\n".utf8)
        let analysee = RequestParser.parse(head: octets).map { requete -> HTTPRequest in
            var requete = requete
            requete.peer = "192.0.2.10"
            requete.peerIsLoopback = false
            return requete
        }
        let requete = try analysee.get()
        XCTAssertEqual(requete.path, "/wake")
        XCTAssertEqual(requete.query, ["action": "WAKE"])
        XCTAssertNil(requete.headers["origin"])
        let reponse = routeur(jeton: jeton).handle(analysee)
        XCTAssertEqual(reponse.status, 200)
        XCTAssertEqual(texte(reponse), "OK")
        XCTAssertEqual(moteur.appels, [.on("192.0.2.10")])
        XCTAssertTrue(avertissements.isEmpty, "\(avertissements)")
    }

    func test_masquageDeLaQuery() {
        XCTAssertEqual(redactingQuery("GET /off?token=jeton-essai-0123456789abcdef HTTP/1.1"), "GET /off?…")
        XCTAssertEqual(redactingQuery("/wake?action=WAKE"), "/wake?…")
        XCTAssertEqual(redactingQuery("GET /off HTTP/1.1"), "GET /off HTTP/1.1")
        XCTAssertEqual(redactingQuery("?"), "?…")
        // Tâche 8, tour 2 : `?` suivi d'un caractère combinant (un seul graphème, qui n'est pas
        // « ? »), et `?` encodé `%3F` ou `%3f`.
        XCTAssertEqual(redactingQuery("/wake?\u{0301}token=\(jeton)"), "/wake?…")
        XCTAssertEqual(redactingQuery("/wake%3Ftoken=\(jeton)"), "/wake?…")
        XCTAssertEqual(redactingQuery("/wake%3ftoken=\(jeton)"), "/wake?…")
        XCTAssertEqual(redactingQuery("/a%3F?b"), "/a?…")
        XCTAssertEqual(redactingQuery("/a?b%3Fc"), "/a?…")
        XCTAssertEqual(redactingQuery("/a%3"), "/a%3")
        XCTAssertEqual(redactingQuery("/a%2F"), "/a%2F")
    }

    func test_cheminJournalise_routeConnueSeulement() {
        XCTAssertEqual(loggablePath("/wake"), "/wake")
        XCTAssertEqual(loggablePath("/state"), "/state")
        for chemin in ["/wake%3Ftoken=\(jeton)", "/inconnu/\(jeton)", "/WAKE", "/wake/", "", "/wake?token=\(jeton)"] {
            XCTAssertEqual(loggablePath(chemin), "<inconnu>", chemin)
        }
    }

    func test_journal_formesPiegees_neContiennentJamaisLeJeton() {
        // Tâche 8, tour 2 : chaque forme qui faisait passer le jeton au journal DEBUG.
        let r = routeur(jeton: jeton)
        let tetes = [
            "GET /wake?\u{0301}token=\(jeton) HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n",   // ? + combinant
            "GET /wake%3Ftoken=\(jeton) HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n",         // ? encodé %3F
            "GET /wake%3ftoken=\(jeton) HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n",         // ? encodé %3f
            "X-Auth-Token: \(jeton)\r\nHost: 192.0.2.10\r\n\r\n",                       // en-tête en 1re ligne
            "X-Auth-Token: \(jeton) HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n",              // idem, en trois mots
            "GET /inconnu/\(jeton) HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n",              // cible inconnue
            "GET /\(jeton) HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n",                       // cible inconnue
        ]
        for tete in tetes {
            let octets = Data(tete.utf8)
            let analysee = RequestParser.parse(head: octets).map { requete -> HTTPRequest in
                var requete = requete
                requete.peer = "192.0.2.10"
                return requete
            }
            logReceivedRequest(analysee, head: octets, peer: "192.0.2.10")
            XCTAssertTrue([400, 404].contains(r.handle(analysee).status), tete)
        }
        XCTAssertEqual(capture.lines.count, tetes.count, "\(capture.lines)")
        XCTAssertFalse(capture.lines.contains { $0.1.contains("jeton-essai") }, "\(capture.lines)")
        XCTAssertFalse(capture.lines.contains { $0.1.contains("token") }, "\(capture.lines)")
        // Refusée par l'analyseur : motif, méthode si elle est valide, longueur, pair.
        let refus = capture.lines[0].1
        XCTAssertTrue(refus.contains("invalidTarget") && refus.contains("GET") && refus.contains("octets")
                      && refus.contains("192.0.2.10"), refus)
        let entete = capture.lines[3].1
        XCTAssertTrue(entete.contains("malformedRequestLine") && !entete.contains("X-Auth"), entete)
        // Acceptée par l'analyseur, chemin inconnu : `<inconnu>`.
        XCTAssertTrue(capture.lines[1].1.contains("GET <inconnu>"), capture.lines[1].1)
        XCTAssertTrue(capture.lines[5].1.contains("GET <inconnu>"), capture.lines[5].1)
    }

    func test_journal_routeur_cheminDeLaRouteSeulement_jamaisLaCible() {
        // La cible et la requête portent le jeton ; le routeur ne journalise que la route. Ce test
        // échoue si le routeur journalise `target` (ou toute forme non réduite à la route).
        let r = routeur(jeton: jeton)
        func piegee(_ jetonEntete: String, pair: String) -> HTTPRequest {
            HTTPRequest(method: "GET", target: "/wake?token=\(jeton)", path: "/wake", version: "HTTP/1.1",
                        query: ["token": jeton], headers: ["host": "192.0.2.10:9090", "x-auth-token": jetonEntete],
                        peer: pair, peerIsLoopback: false)
        }
        // Refus 401 (premier refus, puis interdiction) et refus du seau des commandes.
        for _ in 0..<10 { XCTAssertEqual(r.handle(piegee("faux", pair: "192.0.2.10")).status, 401) }
        let codes = (0..<11).map { _ in r.handle(piegee(jeton, pair: "192.0.2.20")).status }
        XCTAssertEqual(codes.last, 429)
        XCTAssertEqual(avertissements.count, 3, "\(avertissements)")
        XCTAssertTrue(avertissements.allSatisfy { $0.contains("/wake") }, "\(avertissements)")
        XCTAssertFalse(avertissements.contains { $0.contains("jeton-essai") || $0.contains("?") }, "\(avertissements)")
    }

    func test_journal_requeteMalFormee_neContientJamaisLeJeton() {
        let r = routeur(jeton: jeton)
        let tetes = [
            "GET /off?token=\(jeton) HTTP/1.1 en-trop\r\nHost: 192.0.2.10\r\n\r\n",   // ligne mal formée
            "GET /off?token=\(jeton) HTTP/2.0\r\nHost: 192.0.2.10\r\n\r\n",            // version refusée
            "get /off?token=\(jeton) HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n",            // méthode refusée
            "GET /off?token=\(jeton)&token=x HTTP/1.1\r\nHost: 192.0.2.10\r\n\r\n",    // clé en double
            "GET /off?token=\(jeton) HTTP/1.1\r\n\r\n",                                   // sans Host
            "GET /off?token=\(jeton) HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",          // Host en double
            "GET /off?token=\(jeton)\u{1B}[31m HTTP/1.1\r\nHost: a\r\n\r\n",           // cible non imprimable
        ]
        for tete in tetes {
            let octets = Data(tete.utf8)
            let analysee = RequestParser.parse(head: octets)
            XCTAssertNotNil(analysee.failureValue, tete)
            logReceivedRequest(analysee, head: octets, peer: "192.0.2.10")
            XCTAssertEqual(r.handle(analysee).status, 400, tete)
        }
        XCTAssertEqual(capture.lines.count, tetes.count)
        // Ni la cible ni la ligne de requête : seulement le motif, la méthode, la longueur, le pair.
        XCTAssertTrue(capture.lines.allSatisfy { $0.1.hasPrefix("HTTP refusée (") && $0.1.contains("octets") },
                      "\(capture.lines)")
        XCTAssertFalse(capture.lines.contains { $0.1.contains("/off") }, "\(capture.lines)")
        XCTAssertFalse(capture.lines.contains { $0.1.contains("jeton-essai") }, "\(capture.lines)")
        XCTAssertFalse(capture.lines.contains { $0.1.contains("\u{1B}") })
    }

    func test_journal_refusDAccesEtRequeteAcceptee_neContiennentJamaisLeJeton() {
        let r = routeur(jeton: jeton)
        // Jeton dans l'URL refusé par défaut : 401 journalisé, chemin seul.
        let refusee = Data("GET /off?token=\(jeton) HTTP/1.1\r\nHost: 192.0.2.10:9090\r\n\r\n".utf8)
        let analysee = RequestParser.parse(head: refusee)
        logReceivedRequest(analysee, head: refusee, peer: "192.0.2.10")
        XCTAssertEqual(r.handle(analysee).status, 401)
        // Requête acceptée avec le jeton dans l'URL (option active).
        let acceptee = routeur(jeton: jeton, jetonEnQuery: true)
        logReceivedRequest(analysee, head: refusee, peer: "192.0.2.10")
        XCTAssertEqual(acceptee.handle(analysee).status, 200)
        XCTAssertFalse(capture.lines.isEmpty)
        XCTAssertFalse(capture.lines.contains { $0.1.contains("jeton-essai") }, "\(capture.lines)")
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

// MARK: - Tâche 12 : mode dégradé (config invalide)

final class RouterDegradedModeTests: XCTestCase {
    private let jeton = "jeton-essai-0123456789abcdef"
    private let raison = "Unexpected end of file around line 1, column 40."
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

    /// Routeur construit comme `main.swift` le fait pour une config tronquée.
    private func routeurDegrade() -> Router {
        let lu = Config.parse(data: Data(#"{"auth_token": "jeton-essai-0123456789abcdef", "port":"#.utf8))
        guard case .invalid = lu.origin else { XCTFail("origine \(lu.origin)"); return Router(config: lu.config, engine: moteur) }
        return Router(config: lu.config, engine: moteur, origin: .invalid(reason: raison))
    }

    private func requete(_ chemin: String, methode: String = "GET", headers: [String: String] = [:],
                         local: Bool) -> HTTPRequest {
        HTTPRequest(method: methode, target: chemin, path: chemin, version: "HTTP/1.1",
                    headers: headers.merging(["host": "127.0.0.1:9090"]) { valeur, _ in valeur },
                    peer: local ? "127.0.0.1" : "192.0.2.10", peerIsLoopback: local)
    }

    private func texte(_ reponse: HTTPResponse) -> String { String(decoding: reponse.body, as: UTF8.self) }

    func test_modeDegrade_commandesEt503() {
        let r = routeurDegrade()
        let commandes = Route.allCases.filter { $0.routeClass == .command }.map(\.rawValue)
        XCTAssertEqual(Set(commandes), ["/sleep", "/off", "/wake", "/on", "/resync"])

        // Commandes et /health : 503 pour tous, avec ou sans jeton, avant la politique d'accès
        // (méthode, Origin, Host et jeton ne changent rien).
        let variantes: [(String, [String: String], Bool)] = [
            ("GET", [:], true), ("GET", [:], false),
            ("GET", ["x-auth-token": jeton], true), ("GET", ["x-auth-token": jeton], false),
            ("GET", ["x-auth-token": "faux"], false),
            ("POST", [:], true), ("GET", ["origin": "http://192.0.2.99"], true),
            ("GET", ["sec-fetch-site": "cross-site"], true), ("GET", ["host": "attaquant.example"], true),
        ]
        for chemin in commandes + ["/health"] {
            for (methode, entetes, local) in variantes {
                let reponse = r.handle(requete(chemin, methode: methode, headers: entetes, local: local))
                let cas = "\(methode) \(chemin) \(entetes) local=\(local)"
                XCTAssertEqual(reponse.status, 503, cas)
                XCTAssertEqual(reponse.reasonPhrase, "Service Unavailable", cas)
                XCTAssertEqual(texte(reponse), "config invalide", cas)
            }
        }
        // Aucune commande n'atteint le moteur.
        XCTAssertTrue(moteur.appels.isEmpty, "\(moteur.appels)")

        // Un 503 n'est pas un échec d'accès : aucun pair n'est interdit, rien au journal.
        for _ in 0..<(Router.failureLimit + 5) { _ = r.handle(requete("/wake", local: false)) }
        XCTAssertEqual(r.handle(requete("/wake", local: false)).status, 503)
        XCTAssertTrue(capture.lines.isEmpty, "\(capture.lines)")

        // 400 et 404 passent toujours en premier.
        XCTAssertEqual(r.handle(.failure(.missingHost)).status, 400)
        XCTAssertEqual(r.handle(requete("/inconnu", local: true)).status, 404)
        XCTAssertEqual(r.handle(requete("/WAKE", local: true)).status, 404)
    }

    func test_modeDegrade_lecturesSoumisesALaPolitique() throws {
        let r = routeurDegrade()
        moteur.etat = false

        // Boucle locale sans jeton : servies.
        let etat = r.handle(requete("/state", local: true))
        XCTAssertEqual(etat.status, 200)
        XCTAssertEqual(texte(etat), "0")

        let statut = r.handle(requete("/status", local: true))
        XCTAssertEqual(statut.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: statut.body) as? [String: Any])
        XCTAssertEqual(json["config_error"] as? String, raison)
        XCTAssertEqual(json["faux"] as? Bool, true, "le reste de l'instantané est gardé")

        // Hors boucle locale : aucun jeton n'a été lu du fichier invalide → 403, même avec l'ancien jeton.
        XCTAssertEqual(r.handle(requete("/state", local: false)).status, 403)
        XCTAssertEqual(r.handle(requete("/status", headers: ["x-auth-token": jeton], local: false)).status, 403)
        // Page web du Mac : refusée par la politique.
        XCTAssertEqual(r.handle(requete("/status", headers: ["sec-fetch-site": "cross-site"], local: true)).status, 403)
        XCTAssertFalse(moteur.appels.contains { if case .off = $0 { return true }; if case .on = $0 { return true }; return $0 == .resync })
    }

    func test_modeNormal_niConfigErrorNi503() throws {
        for origine in [ConfigOrigin.file, .defaultsAbsent] {
            moteur = FakeEngine()
            var config = Config()
            config.authToken = jeton
            let r = Router(config: config, engine: moteur, origin: origine)
            XCTAssertEqual(r.handle(requete("/health", local: false)).status, 200)
            XCTAssertEqual(r.handle(requete("/wake", headers: ["x-auth-token": jeton], local: false)).status, 200)
            let statut = r.handle(requete("/status", local: true))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: statut.body) as? [String: Any])
            XCTAssertNil(json["config_error"], "\(origine)")
        }
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let erreur) = self { return erreur }
        return nil
    }
}
