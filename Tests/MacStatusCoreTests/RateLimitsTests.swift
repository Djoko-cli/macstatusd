import XCTest
@testable import MacStatusCore

/// Tâche 9 : seau des commandes, traqueur des échecs d'accès, identité du pair, et leur
/// place dans le routeur (traqueur avant la politique, seau avant une commande autorisée).
final class RateLimitsTests: XCTestCase {
    private let jeton = "jeton-essai-0123456789abcdef"
    private var horloge: TestClock!
    private var moteur: FakeEngine!
    private var capture: CaptureLog!
    private var ancienRecepteur: LogSink?

    override func setUp() {
        super.setUp()
        horloge = TestClock(t: 1000)
        moteur = FakeEngine()
        capture = CaptureLog()
        ancienRecepteur = CoreLog.sink
        CoreLog.sink = capture
    }

    override func tearDown() {
        CoreLog.sink = ancienRecepteur
        super.tearDown()
    }

    private func routeur() -> Router {
        var config = Config()
        config.authToken = jeton
        return Router(config: config, engine: moteur, clock: horloge)
    }

    private func requete(_ chemin: String, jeton: String? = nil, pair: String = "192.0.2.10",
                         headers: [String: String] = [:], local: Bool = false) -> HTTPRequest {
        var entetes = headers.merging(["host": "192.0.2.10:9090"]) { valeur, _ in valeur }
        if let jeton { entetes["x-auth-token"] = jeton }
        return HTTPRequest(method: "GET", target: chemin, path: chemin, version: "HTTP/1.1",
                           headers: entetes, peer: pair, peerIsLoopback: local)
    }

    private var avertissements: [String] { capture.lines.filter { $0.0 == .warn }.map { $0.1 } }

    // MARK: - Seau

    func test_seau_rafaleDe10_puis429_puisRecharge5ParSeconde() {
        let r = routeur()
        let codes = (0..<15).map { _ in r.handle(requete("/wake", jeton: jeton)).status }
        XCTAssertEqual(codes, Array(repeating: 200, count: 10) + Array(repeating: 429, count: 5))
        XCTAssertEqual(moteur.appels.count, 10)

        let refus = r.handle(requete("/off", jeton: jeton))
        XCTAssertEqual(refus.status, 429)
        XCTAssertEqual(String(decoding: refus.body, as: UTF8.self), "too many requests")
        XCTAssertEqual(refus.reasonPhrase, "Too Many Requests")
        XCTAssertEqual(refus.contentType, "text/plain; charset=utf-8")

        // Une seconde plus tard : 5 jetons de plus, pas un de plus.
        horloge.advance(1)
        let apres = (0..<6).map { _ in r.handle(requete("/wake", jeton: jeton)).status }
        XCTAssertEqual(apres, [200, 200, 200, 200, 200, 429])
        XCTAssertEqual(moteur.appels.count, 15)

        // Longtemps après : la rafale revient, plafonnée à 10.
        horloge.advance(3600)
        let rafale = (0..<11).map { _ in r.handle(requete("/resync", jeton: jeton)).status }
        XCTAssertEqual(rafale, Array(repeating: 200, count: 10) + [429])
    }

    func test_seau_lecturesEtHealth_nYPassentPas() {
        let r = routeur()
        for _ in 0..<10 { XCTAssertEqual(r.handle(requete("/off", jeton: jeton)).status, 200) }
        XCTAssertEqual(r.handle(requete("/off", jeton: jeton)).status, 429)
        // Seau vide : lectures et /health servies quand même.
        for _ in 0..<20 {
            XCTAssertEqual(r.handle(requete("/state", jeton: jeton)).status, 200)
            XCTAssertEqual(r.handle(requete("/status", local: true)).status, 200)
            XCTAssertEqual(r.handle(requete("/health")).status, 200)
        }
    }

    func test_seau_globalPourTousLesPairs() {
        let r = routeur()
        for i in 0..<10 {
            XCTAssertEqual(r.handle(requete("/wake", jeton: jeton, pair: "192.0.2.\(i + 1)")).status, 200)
        }
        XCTAssertEqual(r.handle(requete("/wake", jeton: jeton, pair: "192.0.2.99")).status, 429)
    }

    func test_seau_commandeRefuseeParLaPolitique_neConsommePas() {
        let r = routeur()
        // Neuf refus (sous le seuil d'interdiction) : aucun jeton du seau n'est pris.
        for _ in 0..<9 { XCTAssertEqual(r.handle(requete("/wake", jeton: "faux")).status, 401) }
        let codes = (0..<11).map { _ in r.handle(requete("/wake", jeton: jeton, pair: "192.0.2.20")).status }
        XCTAssertEqual(codes, Array(repeating: 200, count: 10) + [429])
    }

    func test_seau_horlogeQuiRecule_neCreePasDeJetons() {
        let seau = TokenBucket(rate: 5, burst: 10, clock: horloge)
        for _ in 0..<10 { XCTAssertTrue(seau.take()) }
        XCTAssertFalse(seau.take())
        horloge.t -= 100
        XCTAssertFalse(seau.take())
        horloge.t += 100.2
        XCTAssertTrue(seau.take())
        XCTAssertFalse(seau.take())
    }

    func test_seau_journal_borne() {
        let r = routeur()
        for _ in 0..<1000 { _ = r.handle(requete("/wake", jeton: jeton)) }
        let lignes = avertissements.filter { $0.contains("débit") }
        XCTAssertEqual(lignes.count, 1, "\(lignes)")
        horloge.advance(61)
        for _ in 0..<1000 { _ = r.handle(requete("/wake", jeton: jeton)) }
        let ensuite = avertissements.filter { $0.contains("débit") }
        XCTAssertEqual(ensuite.count, 2, "\(ensuite)")
        // La deuxième ligne compte les commandes refusées depuis la première.
        XCTAssertTrue(ensuite[1].contains("990"), ensuite[1])
    }

    // MARK: - Traqueur

    func test_dixEchecsEn60s_interditPendant60s() {
        let traqueur = AuthFailureTracker(limit: 10, window: 60, banFor: 60, clock: horloge)
        for i in 1...9 {
            let r = traqueur.recordFailure(peer: "192.0.2.10")
            XCTAssertFalse(r.banned, "\(i)")
            XCTAssertEqual(r.count, i)
            horloge.advance(5)
        }
        XCTAssertFalse(traqueur.isBanned(peer: "192.0.2.10"))
        let dixieme = traqueur.recordFailure(peer: "192.0.2.10")
        XCTAssertTrue(dixieme.banned)
        XCTAssertEqual(dixieme.count, 10)
        XCTAssertTrue(traqueur.isBanned(peer: "192.0.2.10"))
        XCTAssertFalse(traqueur.isBanned(peer: "192.0.2.11"))

        horloge.advance(59.5)
        XCTAssertTrue(traqueur.isBanned(peer: "192.0.2.10"))
        horloge.advance(0.5)
        XCTAssertFalse(traqueur.isBanned(peer: "192.0.2.10"))
        // Les échecs d'avant l'interdiction sont oubliés : on repart de 1.
        XCTAssertEqual(traqueur.recordFailure(peer: "192.0.2.10").count, 1)
    }

    func test_echecsEtales_auDelaDe60s_pasDInterdiction() {
        let traqueur = AuthFailureTracker(limit: 10, window: 60, banFor: 60, clock: horloge)
        for _ in 0..<30 {
            XCTAssertFalse(traqueur.recordFailure(peer: "192.0.2.10").banned)
            horloge.advance(7)   // 9 échecs au plus dans toute fenêtre de 60 s
        }
        XCTAssertFalse(traqueur.isBanned(peer: "192.0.2.10"))
    }

    func test_journalDesEchecs_uneLigneParPairEtParMinute() {
        let traqueur = AuthFailureTracker(limit: 10, window: 60, banFor: 60, clock: horloge)
        XCTAssertTrue(traqueur.recordFailure(peer: "192.0.2.10").shouldLog)
        XCTAssertTrue(traqueur.recordFailure(peer: "192.0.2.11").shouldLog)
        for _ in 0..<5 {
            horloge.advance(1)
            XCTAssertFalse(traqueur.recordFailure(peer: "192.0.2.10").shouldLog)
        }
        horloge.advance(54)   // 59 s après la première ligne
        XCTAssertFalse(traqueur.recordFailure(peer: "192.0.2.10").shouldLog)
        horloge.advance(1)    // 60 s
        let r = traqueur.recordFailure(peer: "192.0.2.10")
        XCTAssertTrue(r.shouldLog)
        XCTAssertEqual(r.count, 7)

        // Par le routeur : 1 000 refus d'un même pair écrivent deux lignes, le premier refus et
        // l'interdiction ; les 990 requêtes interdites n'en écrivent aucune.
        let routeur = self.routeur()
        let codes = (0..<1000).map { _ in routeur.handle(requete("/wake", jeton: "faux", pair: "192.0.2.30")).status }
        XCTAssertEqual(Array(codes.prefix(10)), Array(repeating: 401, count: 10))
        XCTAssertEqual(Set(codes.dropFirst(10)), [429])
        let lignes = avertissements.filter { $0.contains("192.0.2.30") }
        XCTAssertEqual(lignes.count, 2, "\(lignes)")
        XCTAssertTrue(lignes[0].contains("401"), lignes[0])
        XCTAssertTrue(lignes[0].contains("1 échec"), lignes[0])
        XCTAssertTrue(lignes[1].contains("interdit"), lignes[1])
        XCTAssertTrue(lignes[1].contains("10 échecs"), lignes[1])
        XCTAssertTrue(moteur.appels.isEmpty)
    }

    func test_traqueur_plafonne_evinceLePlusAncien() {
        let traqueur = AuthFailureTracker(limit: 10, window: 60, banFor: 60, clock: horloge, maxPeers: 4)
        // Le pair 0 est interdit, puis les pairs 1 à 3 échouent une fois chacun.
        for _ in 0..<10 { _ = traqueur.recordFailure(peer: "pair-0") }
        XCTAssertTrue(traqueur.isBanned(peer: "pair-0"))
        for i in 1...3 {
            horloge.advance(1)
            _ = traqueur.recordFailure(peer: "pair-\(i)")
        }
        XCTAssertEqual(traqueur.peerCount, 4)
        // Un cinquième pair : le plus ancien (pair-0) est évincé, la table reste à 4.
        horloge.advance(1)
        _ = traqueur.recordFailure(peer: "pair-4")
        XCTAssertEqual(traqueur.peerCount, 4)
        XCTAssertFalse(traqueur.isBanned(peer: "pair-0"))
        XCTAssertEqual(traqueur.recordFailure(peer: "pair-2").count, 2)

        // 5 000 pairs distincts : jamais plus de 4 entrées.
        for i in 0..<5000 { _ = traqueur.recordFailure(peer: "autre-\(i)") }
        XCTAssertEqual(traqueur.peerCount, 4)
    }

    func test_traqueur_plafondParDefaut_1024() {
        let traqueur = AuthFailureTracker(limit: 10, window: 60, banFor: 60, clock: horloge)
        for i in 0..<3000 { _ = traqueur.recordFailure(peer: "198.51.100.\(i)") }
        XCTAssertEqual(traqueur.peerCount, 1024)
    }

    func test_traqueur_oublieLesPairsEchus() {
        let traqueur = AuthFailureTracker(limit: 10, window: 60, banFor: 60, clock: horloge)
        for i in 0..<50 { _ = traqueur.recordFailure(peer: "198.51.100.\(i)") }
        for _ in 0..<10 { _ = traqueur.recordFailure(peer: "192.0.2.10") }
        XCTAssertEqual(traqueur.peerCount, 51)
        // Fenêtre écoulée pour tous ; l'interdiction de 192.0.2.10 aussi.
        horloge.advance(61)
        _ = traqueur.recordFailure(peer: "203.0.113.1")
        XCTAssertEqual(traqueur.peerCount, 1)
    }

    func test_traqueur_interditMemeHealth_avant404Non() {
        let r = routeur()
        for _ in 0..<10 { XCTAssertEqual(r.handle(requete("/off", jeton: "faux")).status, 401) }
        for chemin in ["/health", "/state", "/status", "/off", "/wake"] {
            let reponse = r.handle(requete(chemin, jeton: jeton))
            XCTAssertEqual(reponse.status, 429, chemin)
            XCTAssertEqual(String(decoding: reponse.body, as: UTF8.self), "too many requests")
        }
        // Un chemin inconnu reste 404 : même réponse pour tout le monde, avant le traqueur.
        XCTAssertEqual(r.handle(requete("/inconnu")).status, 404)
        // Un autre pair n'est pas touché.
        XCTAssertEqual(r.handle(requete("/wake", jeton: jeton, pair: "192.0.2.11")).status, 200)
        // 60 s après l'interdiction, le pair est de nouveau servi.
        horloge.advance(60)
        XCTAssertEqual(r.handle(requete("/wake", jeton: jeton)).status, 200)
    }

    func test_refus403_compteCommeEchec_405Non() {
        let r = routeur()
        // 403 d'origine (une page web) : comptés.
        for _ in 0..<10 {
            XCTAssertEqual(r.handle(requete("/off", jeton: jeton, headers: ["origin": "http://evil.example"])).status, 403)
        }
        XCTAssertEqual(r.handle(requete("/health")).status, 429)

        // 405 (mauvaise méthode) : pas comptés.
        let autre = routeur()
        for _ in 0..<30 {
            var post = requete("/off", jeton: jeton, pair: "192.0.2.40")
            post.method = "POST"
            XCTAssertEqual(autre.handle(post).status, 405)
        }
        XCTAssertEqual(autre.handle(requete("/health", pair: "192.0.2.40")).status, 200)
    }

    func test_formesDuPair_unSeulPair() {
        let r = routeur()
        let formes = ["192.0.2.10", "::ffff:192.0.2.10", "::FFFF:192.0.2.10", "::ffff:c000:20a",
                      "[::ffff:192.0.2.10]:51234", "192.0.2.10:51234"]
        for i in 0..<10 {
            XCTAssertEqual(r.handle(requete("/off", jeton: "faux", pair: formes[i % formes.count])).status, 401)
        }
        for forme in formes {
            XCTAssertEqual(r.handle(requete("/health", pair: forme)).status, 429, forme)
        }
    }

    func test_identiteDuPair() {
        XCTAssertEqual(peerIdentity("192.0.2.10"), "192.0.2.10")
        XCTAssertEqual(peerIdentity("192.0.2.10:51234"), "192.0.2.10")
        XCTAssertEqual(peerIdentity("::ffff:192.0.2.10"), "192.0.2.10")
        XCTAssertEqual(peerIdentity("::ffff:c000:20a"), "192.0.2.10")
        XCTAssertEqual(peerIdentity("[::ffff:192.0.2.10]:8080"), "192.0.2.10")
        XCTAssertEqual(peerIdentity("2001:DB8:0:0::1"), "2001:db8::1")
        XCTAssertEqual(peerIdentity("[2001:db8::1]:443"), "2001:db8::1")
        XCTAssertEqual(peerIdentity("fe80::1%en0"), "fe80::1")
        XCTAssertEqual(peerIdentity("::1"), "::1")
        // Ni IPv4 ni IPv6 : gardé tel quel, borné.
        XCTAssertEqual(peerIdentity("?"), "?")
        XCTAssertEqual(peerIdentity(String(repeating: "x", count: 500)).count, 128)
    }

    func test_journalDuTraqueur_echappeLePair() {
        let r = routeur()
        let hostile = "192.0.2.10\n\u{1B}[31mfaux"
        for _ in 0..<10 { _ = r.handle(requete("/off", jeton: "faux", pair: hostile)) }
        XCTAssertEqual(avertissements.count, 2)
        for ligne in avertissements {
            XCTAssertFalse(ligne.contains("\n"), ligne)
            XCTAssertFalse(ligne.contains("\u{1B}"), ligne)
            XCTAssertTrue(ligne.contains("\\u{0A}"), ligne)
            XCTAssertFalse(ligne.contains(jeton), ligne)
        }
    }

    func test_journal_pairsNombreux_debitGlobalBorne() {
        // Beaucoup d'adresses (IPv6 du LAN, par exemple) : le journal reste borné.
        let r = routeur()
        for i in 0..<1000 { _ = r.handle(requete("/off", jeton: "faux", pair: "2001:db8::\(String(i, radix: 16))")) }
        XCTAssertLessThanOrEqual(avertissements.count, 31, "\(avertissements.count)")
        // Une minute plus tard, une ligne signale les lignes omises.
        horloge.advance(60)
        _ = r.handle(requete("/off", jeton: "faux", pair: "2001:db8::ffff"))
        XCTAssertTrue(avertissements.last?.contains("omise") ?? false, avertissements.last ?? "")
    }
}
