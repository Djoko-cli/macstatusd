import XCTest
@testable import MacStatusCore

/// Règles d'accès (tâche 8) : classes de routes, contrôle de `Host`, d'origine, de méthode
/// et de jeton, dans cet ordre ; comparaison du jeton en temps constant ; boucle locale (R21).
final class AccessPolicyTests: XCTestCase {
    private let jeton = "jeton-essai-0123456789abcdef"

    private func politique(jeton: String? = nil, jetonEnQuery: Bool = false,
                           hotes: [String] = [], noms: [String] = []) -> AccessPolicy {
        AccessPolicy(authToken: jeton ?? self.jeton, allowQueryToken: jetonEnQuery,
                     allowedHosts: hotes, localNames: noms)
    }

    /// Requête déjà analysée. `host` à `nil` : pas d'en-tête `Host`.
    private func requete(_ chemin: String, methode: String = "GET", version: String = "HTTP/1.1",
                         host: String? = "192.0.2.10:9090", headers: [String: String] = [:],
                         query: [String: String] = [:], local: Bool = false) -> HTTPRequest {
        var entetes = headers
        if let host { entetes["host"] = host }
        return HTTPRequest(method: methode, target: chemin, path: chemin, version: version, query: query,
                           headers: entetes, peer: local ? "127.0.0.1" : "192.0.2.10", peerIsLoopback: local)
    }

    // MARK: - Points de vigilance

    func test_appelReelDeHA_accepte() {
        // GET /wake?action=WAKE, Host: <IPv4 LAN du Mac>:9090, X-Auth-Token, pair non local.
        let r = requete("/wake", host: "192.0.2.10:9090", headers: ["x-auth-token": jeton],
                        query: ["action": "WAKE"], local: false)
        XCTAssertEqual(politique().decide(r), .allow)
        // Le même appel sans jeton est refusé.
        XCTAssertEqual(politique().decide(requete("/wake", query: ["action": "WAKE"])),
                       .deny(status: 401, reason: "token"))
    }

    func test_requeteNavigateurCrossSite_refusee() {
        let r = requete("/wake", host: "127.0.0.1:9090",
                        headers: ["sec-fetch-site": "cross-site", "x-auth-token": jeton], local: true)
        XCTAssertEqual(politique().decide(r), .deny(status: 403, reason: "origin"))
    }

    func test_http10SansHost_avecJeton_accepte() {
        let r = requete("/off", version: "HTTP/1.0", host: nil, headers: ["x-auth-token": jeton])
        XCTAssertEqual(politique().decide(r), .allow)
        // Sans jeton, le même appel reste refusé : l'absence de `Host` n'ouvre rien.
        XCTAssertEqual(politique().decide(requete("/off", version: "HTTP/1.0", host: nil)),
                       .deny(status: 401, reason: "token"))
    }

    func test_hostRebinde_refuse() {
        let r = requete("/wake", host: "evil.example:9090", headers: ["x-auth-token": jeton], local: true)
        XCTAssertEqual(politique().decide(r), .deny(status: 403, reason: "host"))
        XCTAssertEqual(politique().decide(requete("/state", host: "evil.example", local: true)),
                       .deny(status: 403, reason: "host"))
    }

    func test_nomLocalDuMac_accepte() {
        let p = politique(noms: ["Mac-Essai.local"])
        for host in ["Mac-Essai.local:9090", "mac-essai.local", "MAC-ESSAI.LOCAL:9090"] {
            XCTAssertEqual(p.decide(requete("/wake", host: host, headers: ["x-auth-token": jeton])), .allow, host)
        }
        // Un autre nom en `.local` n'est pas celui du Mac.
        XCTAssertEqual(p.decide(requete("/wake", host: "Autre-Mac.local:9090", headers: ["x-auth-token": jeton])),
                       .deny(status: 403, reason: "host"))
    }

    // MARK: - Jeton

    func test_commandeSansJeton_401_memeEnBoucleLocale() {
        for chemin in ["/sleep", "/off", "/wake", "/on", "/resync"] {
            XCTAssertEqual(politique().decide(requete(chemin, host: "127.0.0.1:9090", local: true)),
                           .deny(status: 401, reason: "token"), chemin)
        }
    }

    func test_lectureEnBoucleLocale_sansJeton_acceptee() {
        for chemin in ["/state", "/status"] {
            for methode in ["GET", "HEAD"] {
                XCTAssertEqual(politique().decide(requete(chemin, methode: methode, host: "127.0.0.1:9090", local: true)),
                               .allow, "\(methode) \(chemin)")
            }
        }
        // En boucle locale, même un jeton faux ne gêne pas une lecture.
        XCTAssertEqual(politique().decide(requete("/state", headers: ["x-auth-token": "faux"], local: true)), .allow)
    }

    func test_lectureDistante_sansJeton_401() {
        for chemin in ["/state", "/status"] {
            XCTAssertEqual(politique().decide(requete(chemin)), .deny(status: 401, reason: "token"), chemin)
            XCTAssertEqual(politique().decide(requete(chemin, headers: ["x-auth-token": "faux"])),
                           .deny(status: 401, reason: "token"), chemin)
            XCTAssertEqual(politique().decide(requete(chemin, headers: ["x-auth-token": jeton])), .allow, chemin)
        }
    }

    func test_jetonEnQuery_refuseParDefaut_accepteSiOption() {
        let r = requete("/wake", query: ["token": jeton])
        XCTAssertEqual(politique().decide(r), .deny(status: 401, reason: "token"))
        XCTAssertEqual(politique(jetonEnQuery: true).decide(r), .allow)
        XCTAssertEqual(politique(jetonEnQuery: true).decide(requete("/wake", query: ["token": "faux"])),
                       .deny(status: 401, reason: "token"))
    }

    func test_enTetePrioritaireSurQuery() {
        // Le premier jeton présent décide, dans l'ordre : X-Auth-Token, Authorization, requête.
        let p = politique(jetonEnQuery: true)
        XCTAssertEqual(p.decide(requete("/wake", headers: ["x-auth-token": jeton], query: ["token": "faux"])), .allow)
        XCTAssertEqual(p.decide(requete("/wake", headers: ["x-auth-token": "faux"], query: ["token": jeton])),
                       .deny(status: 401, reason: "token"))
        XCTAssertEqual(p.decide(requete("/wake", headers: ["x-auth-token": "faux", "authorization": "Bearer \(jeton)"])),
                       .deny(status: 401, reason: "token"))
    }

    func test_bearerSansCasse() {
        for valeur in ["Bearer \(jeton)", "bearer \(jeton)", "BEARER \(jeton)", "Bearer   \(jeton)"] {
            XCTAssertEqual(politique().decide(requete("/off", headers: ["authorization": valeur])), .allow, valeur)
        }
        for valeur in ["Basic \(jeton)", "Bearer", "Bearer ", "Bearer faux", jeton, "Bearer\(jeton)"] {
            XCTAssertEqual(politique().decide(requete("/off", headers: ["authorization": valeur])),
                           .deny(status: 401, reason: "token"), valeur)
        }
    }

    func test_jetonFauxOuDeLongueurDifferente_401() {
        for faux in ["", "j", "jeton-essai-0123456789abcdeX", jeton + "0", String(jeton.dropLast()), jeton.uppercased()] {
            XCTAssertEqual(politique().decide(requete("/wake", headers: ["x-auth-token": faux])),
                           .deny(status: 401, reason: "token"), faux)
        }
    }

    func test_sansJetonConfigure_distant_403_local_allow() {
        let p = politique(jeton: "")
        for chemin in ["/state", "/status", "/wake", "/off", "/resync"] {
            XCTAssertEqual(p.decide(requete(chemin)), .deny(status: 403, reason: "no-token-configured"), chemin)
            // Un jeton fourni ne change rien : il n'y a rien à comparer.
            XCTAssertEqual(p.decide(requete(chemin, headers: ["x-auth-token": jeton])),
                           .deny(status: 403, reason: "no-token-configured"), chemin)
            XCTAssertEqual(p.decide(requete(chemin, host: "127.0.0.1:9090", local: true)), .allow, chemin)
        }
    }

    // MARK: - Méthode

    func test_head_surCommande_405() {
        for chemin in ["/sleep", "/off", "/wake", "/on", "/resync"] {
            XCTAssertEqual(politique().decide(requete(chemin, methode: "HEAD", headers: ["x-auth-token": jeton])),
                           .deny(status: 405, reason: "method"), chemin)
        }
    }

    func test_autreMethode_405_avantLeJeton() {
        for methode in ["POST", "PUT", "DELETE", "OPTIONS"] {
            XCTAssertEqual(politique().decide(requete("/wake", methode: methode)), .deny(status: 405, reason: "method"))
            XCTAssertEqual(politique().decide(requete("/state", methode: methode)), .deny(status: 405, reason: "method"))
        }
    }

    // MARK: - Ordre des règles

    func test_health_toujoursAccepte() {
        let p = politique()
        XCTAssertEqual(p.decide(requete("/health")), .allow)
        XCTAssertEqual(p.decide(requete("/health", host: "evil.example",
                                        headers: ["origin": "http://evil.example", "sec-fetch-site": "cross-site"])),
                       .allow)
        XCTAssertEqual(p.decide(requete("/health", methode: "HEAD")), .allow)
        XCTAssertEqual(politique(jeton: "").decide(requete("/health")), .allow)
    }

    func test_ordre_hostPuisOriginePuisMethodePuisJeton() {
        let p = politique()
        // Host faux + origine + mauvaise méthode + pas de jeton → host.
        XCTAssertEqual(p.decide(requete("/wake", methode: "POST", host: "evil.example", headers: ["origin": "x"])),
                       .deny(status: 403, reason: "host"))
        // Host bon, origine + mauvaise méthode → origin.
        XCTAssertEqual(p.decide(requete("/wake", methode: "POST", headers: ["origin": "x"])),
                       .deny(status: 403, reason: "origin"))
        // Host et origine bons, mauvaise méthode, pas de jeton → method.
        XCTAssertEqual(p.decide(requete("/wake", methode: "HEAD")), .deny(status: 405, reason: "method"))
        // Sans jeton configuré, le refus d'origine passe aussi avant celui de la boucle locale.
        XCTAssertEqual(politique(jeton: "").decide(requete("/state", headers: ["origin": "x"])),
                       .deny(status: 403, reason: "origin"))
    }

    // MARK: - Origine

    func test_origin_refuse_memeDeLaMemeOrigine() {
        for origine in ["http://127.0.0.1:9090", "http://evil.example", "null", ""] {
            let r = requete("/wake", host: "127.0.0.1:9090", headers: ["origin": origine, "x-auth-token": jeton], local: true)
            XCTAssertEqual(politique().decide(r), .deny(status: 403, reason: "origin"), origine)
        }
    }

    func test_secFetchSite() {
        // `none` : l'utilisateur a tapé l'adresse lui-même. Toute autre valeur vient d'une page.
        XCTAssertEqual(politique().decide(requete("/wake", headers: ["sec-fetch-site": "none", "x-auth-token": jeton])),
                       .allow)
        for site in ["same-origin", "same-site", "cross-site", "", "inconnu"] {
            XCTAssertEqual(politique().decide(requete("/wake", headers: ["sec-fetch-site": site, "x-auth-token": jeton])),
                           .deny(status: 403, reason: "origin"), site)
        }
    }

    // MARK: - Host

    func test_hostLitteraux_acceptes() {
        let p = politique()
        for host in ["192.0.2.10:9090", "192.0.2.10", "127.0.0.1:9090", "198.51.100.1:9090",
                     "[::1]:9090", "[::1]", "[fd00::1]:9090", "[::ffff:192.0.2.10]:9090",
                     "localhost:9090", "localhost", "LocalHost:9090", "192.0.2.10:"] {
            XCTAssertEqual(p.decide(requete("/wake", host: host, headers: ["x-auth-token": jeton])), .allow, host)
        }
    }

    func test_hostMalformeOuInconnu_refuse() {
        let p = politique()
        for host in ["", "evil.example", "evil.example:9090", "192.0.2.10.evil.example", "localhost.evil.example",
                     "::1", "[::1", "[::1]x", "[::1]:x", "192.0.2.10:abc", "192.0.2.10:90:90",
                     "[evil.example]:9090", "[192.0.2.10]:9090", "999.0.0.1", "192.0.2", "192.0.2.10.",
                     "1234.0.0.1", "+1.2.3.4", "[fe80::1%25en0]:9090", "[fe80::1%en0]", "localhost.", " localhost",
                     // Adresses non spécifiées (tâche 8, tour 1) : elles ne désignent aucun hôte.
                     "0.0.0.0", "0.0.0.0:9090", "[::]", "[::]:9090", "[0:0:0:0:0:0:0:0]:9090",
                     // Non spécifiée mappée (tâche 8, tour 2) : `::ffff:0.0.0.0`, sous toute écriture.
                     "[::ffff:0.0.0.0]", "[::ffff:0.0.0.0]:9090", "[::ffff:0:0]", "[::FFFF:0:0]:9090",
                     "[0:0:0:0:0:ffff:0:0]:9090"] {
            XCTAssertEqual(p.decide(requete("/wake", host: host, headers: ["x-auth-token": jeton])),
                           .deny(status: 403, reason: "host"), host)
        }
    }

    func test_hostSyntaxeInvalide_refuse_memeSiAutorise() {
        // L'analyseur ne valide pas la valeur de `Host` : la politique le fait avant toute comparaison.
        let p = politique(hotes: ["a b c", "x@y", "a,b", "h"])
        for host in ["a b c", "x@y", "a,b", "h:1:2", "x@192.0.2.10", "192.0.2.10,evil.example", "a\tb",
                     "évian.example", "[::1]:1:2", "[::1] "] {
            XCTAssertEqual(p.decide(requete("/wake", host: host, headers: ["x-auth-token": jeton])),
                           .deny(status: 403, reason: "host"), host)
        }
        XCTAssertEqual(p.decide(requete("/wake", host: "h:1", headers: ["x-auth-token": jeton])), .allow)
    }

    func test_hostAutoriseParLaConfig_sansCasse() {
        let p = politique(hotes: ["Passerelle.Example"])
        XCTAssertEqual(p.decide(requete("/wake", host: "passerelle.example:9090", headers: ["x-auth-token": jeton])),
                       .allow)
        XCTAssertEqual(p.decide(requete("/wake", host: "autre.example:9090", headers: ["x-auth-token": jeton])),
                       .deny(status: 403, reason: "host"))
    }

    // MARK: - Classes de routes

    func test_classify() {
        XCTAssertEqual(RouteClass.classify(path: "/health"), .health)
        XCTAssertEqual(RouteClass.classify(path: "/state"), .read)
        XCTAssertEqual(RouteClass.classify(path: "/status"), .read)
        for chemin in ["/sleep", "/off", "/wake", "/on", "/resync"] {
            XCTAssertEqual(RouteClass.classify(path: chemin), .command, chemin)
        }
        for chemin in ["/", "", "/inconnu", "/STATE", "/state/", "/health/", "/wake%20"] {
            XCTAssertEqual(RouteClass.classify(path: chemin), .unknown, chemin)
        }
    }

    func test_tableDesRoutes_estLaSeuleSourceDesChemins() {
        // Les huit chemins servis, ni plus ni moins : ajouter une route change ce test à dessein.
        XCTAssertEqual(Set(Route.allCases.map { $0.rawValue }),
                       ["/health", "/state", "/status", "/sleep", "/off", "/wake", "/on", "/resync"])
        for route in Route.allCases {
            XCTAssertEqual(RouteClass.classify(path: route.rawValue), route.routeClass, route.rawValue)
            XCTAssertNotEqual(route.routeClass, .unknown, route.rawValue)
        }
    }

    func test_cheminInconnu_refuseParPrudence() {
        // Le routeur répond 404 sans appeler `decide` ; appelée quand même, elle ferme.
        XCTAssertEqual(politique().decide(requete("/inconnu", headers: ["x-auth-token": jeton], local: true)),
                       .deny(status: 404, reason: "unknown"))
    }

    // MARK: - Comparaison en temps constant

    func test_constantTimeEquals() {
        XCTAssertTrue(constantTimeEquals("", ""))
        XCTAssertTrue(constantTimeEquals(jeton, jeton))
        XCTAssertTrue(constantTimeEquals("é", "é"))
        XCTAssertFalse(constantTimeEquals(jeton, ""))
        XCTAssertFalse(constantTimeEquals("", jeton))
        XCTAssertFalse(constantTimeEquals(jeton, jeton + "0"))
        XCTAssertFalse(constantTimeEquals(jeton + "0", jeton))
        XCTAssertFalse(constantTimeEquals(jeton, "jeton-essai-0123456789abcdeX"))
        XCTAssertFalse(constantTimeEquals("Xeton-essai-0123456789abcdef", jeton))
        XCTAssertFalse(constantTimeEquals("a", "b"))
        // Même préfixe, octet nul en plus : la longueur compte.
        XCTAssertFalse(constantTimeEquals("a", "a\u{0}"))
    }

    // MARK: - Boucle locale (Ruling R21)

    func test_isLoopbackAddress_IPv4() {
        XCTAssertTrue(isLoopbackAddress([127, 0, 0, 1]))
        XCTAssertTrue(isLoopbackAddress([127, 5, 6, 7]))
        XCTAssertTrue(isLoopbackAddress([127, 255, 255, 255]))
        XCTAssertFalse(isLoopbackAddress([192, 0, 2, 10]))
        XCTAssertFalse(isLoopbackAddress([128, 0, 0, 1]))
        XCTAssertFalse(isLoopbackAddress([0, 0, 0, 0]))
    }

    func test_isLoopbackAddress_IPv6() {
        let boucle: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let mappee127: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 0, 0, 1]
        let mappee127x: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 9, 9, 9]
        let mappeeLAN: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 192, 0, 2, 10]
        let quelconque: [UInt8] = [0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let nulle = [UInt8](repeating: 0, count: 16)
        // IPv4 compatible (dépréciée) ::127.0.0.1 : pas une boucle locale.
        let compatible127: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1]
        XCTAssertTrue(isLoopbackAddress(boucle))
        XCTAssertTrue(isLoopbackAddress(mappee127))
        XCTAssertTrue(isLoopbackAddress(mappee127x))
        XCTAssertFalse(isLoopbackAddress(mappeeLAN))
        XCTAssertFalse(isLoopbackAddress(quelconque))
        XCTAssertFalse(isLoopbackAddress(nulle))
        XCTAssertFalse(isLoopbackAddress(compatible127))
    }

    func test_isLoopbackAddress_tailleInattendue_false() {
        XCTAssertFalse(isLoopbackAddress([]))
        XCTAssertFalse(isLoopbackAddress([127]))
        XCTAssertFalse(isLoopbackAddress([127, 0, 0]))
        XCTAssertFalse(isLoopbackAddress([127, 0, 0, 1, 0]))
        XCTAssertFalse(isLoopbackAddress([UInt8](repeating: 0, count: 15) + [1, 0]))
    }

    // MARK: - Écoute limitée à la boucle locale

    func test_bindAddressIsLoopbackOnly() {
        for adresse in ["127.0.0.1", "127.5.6.7", "::1", "localhost", "LOCALHOST", "::ffff:127.0.0.1"] {
            XCTAssertTrue(bindAddressIsLoopbackOnly(adresse), adresse)
        }
        for adresse in ["", "0.0.0.0", "::", "192.0.2.10", "fd00::1", "Mac-Essai.local", "evil.example", "::1%lo0"] {
            XCTAssertFalse(bindAddressIsLoopbackOnly(adresse), adresse)
        }
    }
}
