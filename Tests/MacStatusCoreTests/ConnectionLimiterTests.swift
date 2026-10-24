import XCTest
@testable import MacStatusCore

/// Tâche 10 : plafond de connexions (32 au total, 8 par pair), journal borné des refus,
/// adresse d'écoute (`bind_address`) et message « à l'écoute sur … ».
final class ConnectionLimiterTests: XCTestCase {

    // MARK: - Plafond de connexions

    func test_limite32Total_8ParPair() {
        let limiteur = ConnectionLimiter(maxTotal: 32, maxPerPeer: 8)

        // Un pair : 8 places, la 9e est refusée.
        for i in 1...8 { XCTAssertTrue(limiteur.acquire(peer: "192.0.2.10"), "connexion \(i)") }
        XCTAssertFalse(limiteur.acquire(peer: "192.0.2.10"), "9e connexion du même pair")
        XCTAssertEqual(limiteur.count(peer: "192.0.2.10"), 8)

        // Même pair sous une autre écriture (port, IPv4 mappée) : toujours refusé.
        XCTAssertFalse(limiteur.acquire(peer: "192.0.2.10:51000"))
        XCTAssertFalse(limiteur.acquire(peer: "::ffff:192.0.2.10"))
        XCTAssertFalse(limiteur.acquire(peer: "[::ffff:c000:20a]:51000"))

        // 3 autres pairs complètent jusqu'à 32 ; au-delà, refus pour tout le monde.
        for pair in ["192.0.2.11", "192.0.2.12", "fd00::1"] {
            for i in 1...8 { XCTAssertTrue(limiteur.acquire(peer: pair), "\(pair) connexion \(i)") }
        }
        XCTAssertEqual(limiteur.activeCount, 32)
        XCTAssertFalse(limiteur.acquire(peer: "192.0.2.99"), "33e connexion, pair neuf")
        XCTAssertFalse(limiteur.acquire(peer: "fd00::2"))
        XCTAssertEqual(limiteur.activeCount, 32)
        XCTAssertEqual(limiteur.count(peer: "192.0.2.99"), 0, "un refus ne compte pas")
    }

    func test_releaseLibereUnePlace() {
        let limiteur = ConnectionLimiter(maxTotal: 32, maxPerPeer: 8)
        for _ in 1...8 { XCTAssertTrue(limiteur.acquire(peer: "192.0.2.10")) }
        XCTAssertFalse(limiteur.acquire(peer: "192.0.2.10"))

        // Libérée sous une autre écriture du même pair : la place revient.
        limiteur.release(peer: "::ffff:192.0.2.10")
        XCTAssertEqual(limiteur.count(peer: "192.0.2.10"), 7)
        XCTAssertTrue(limiteur.acquire(peer: "192.0.2.10:51001"))
        XCTAssertFalse(limiteur.acquire(peer: "192.0.2.10"))

        // Tout libérer : le pair est oublié, le total revient à zéro.
        for _ in 1...8 { limiteur.release(peer: "192.0.2.10") }
        XCTAssertEqual(limiteur.activeCount, 0)
        XCTAssertEqual(limiteur.trackedPeerCount, 0)
    }

    func test_releaseEnTrop_nInventeAucunePlace() {
        let limiteur = ConnectionLimiter(maxTotal: 2, maxPerPeer: 2)
        limiteur.release(peer: "192.0.2.10")          // jamais acquise : sans effet
        XCTAssertEqual(limiteur.activeCount, 0)
        XCTAssertTrue(limiteur.acquire(peer: "192.0.2.10"))
        limiteur.release(peer: "192.0.2.10")
        limiteur.release(peer: "192.0.2.10")          // double libération : sans effet
        XCTAssertEqual(limiteur.activeCount, 0)
        XCTAssertTrue(limiteur.acquire(peer: "192.0.2.10"))
        XCTAssertTrue(limiteur.acquire(peer: "192.0.2.11"))
        XCTAssertFalse(limiteur.acquire(peer: "192.0.2.12"), "plafond total toujours tenu")
    }

    func test_valeursParDefaut() {
        XCTAssertEqual(ConnectionLimiter.defaultMaxTotal, 32)
        XCTAssertEqual(ConnectionLimiter.defaultMaxPerPeer, 8)
    }

    // MARK: - Journal borné des refus

    func test_journalDesRefus_premierPuisUneParMinute() {
        let horloge = TestClock(t: 1000)
        let porte = PeriodicLogGate(period: 60, clock: horloge)
        XCTAssertEqual(porte.note(), 1, "premier refus : une ligne")
        for _ in 1...50 { XCTAssertNil(porte.note()) }
        horloge.advance(59)
        XCTAssertNil(porte.note())
        horloge.advance(1)
        XCTAssertEqual(porte.note(), 52, "ligne suivante : refus comptés depuis la précédente")
        XCTAssertNil(porte.note())
        horloge.advance(-10)                          // horloge qui recule : une ligne, pas de blocage
        XCTAssertEqual(porte.note(), 2)
    }

    // MARK: - Adresse d'écoute

    func test_adresseEcoute_valeursAcceptees() {
        XCTAssertEqual(ListenAddress(bindAddress: ""), .dualStack)
        XCTAssertEqual(ListenAddress(bindAddress: "::"), .dualStack)
        XCTAssertEqual(ListenAddress(bindAddress: "0:0::0"), .dualStack)
        XCTAssertEqual(ListenAddress(bindAddress: "0.0.0.0"), .allIPv4)
        XCTAssertEqual(ListenAddress(bindAddress: "127.0.0.1"), .ipv4("127.0.0.1"))
        XCTAssertEqual(ListenAddress(bindAddress: "192.0.2.10"), .ipv4("192.0.2.10"))
        XCTAssertEqual(ListenAddress(bindAddress: "::1"), .ipv6("::1"))
        XCTAssertEqual(ListenAddress(bindAddress: "FD00:0::1"), .ipv6("fd00::1"))
        XCTAssertEqual(ListenAddress(bindAddress: "localhost"), .ipv4("127.0.0.1"))
        for invalide in ["foo", "Mac-Essai.local", "127.0.0.l", " 127.0.0.1", "127.0.0.1:9090",
                         "[::1]", "::1%lo0", "256.0.0.1", "1.2.3"] {
            XCTAssertNil(ListenAddress(bindAddress: invalide), invalide)
        }
    }

    func test_messageEcoute_exact() {
        XCTAssertEqual(ListenAddress.dualStack.description(port: 9090), "[::]:9090 (IPv4+IPv6, toutes interfaces)")
        XCTAssertEqual(ListenAddress.allIPv4.description(port: 9090), "0.0.0.0:9090 (IPv4 seulement, toutes interfaces)")
        XCTAssertEqual(ListenAddress.ipv4("127.0.0.1").description(port: 19090), "127.0.0.1:19090")
        XCTAssertEqual(ListenAddress.ipv6("::1").description(port: 19090), "[::1]:19090")
    }

    func test_config_bindAddress_canoniqueOuDefautAvecAvertissement() {
        func lire(_ valeur: String) -> (String, [String]) {
            let json = "{\"bind_address\": \"\(valeur)\"}"
            let r = Config.parse(data: Data(json.utf8))
            return (r.config.bindAddress, r.warnings)
        }
        XCTAssertEqual(lire("::").0, "::")
        XCTAssertEqual(lire("0.0.0.0").0, "0.0.0.0")
        XCTAssertEqual(lire("127.0.0.1").0, "127.0.0.1")
        XCTAssertEqual(lire("FD00::1").0, "fd00::1")
        XCTAssertEqual(lire("localhost").0, "127.0.0.1")
        XCTAssertTrue(lire("::").1.isEmpty)
        XCTAssertTrue(lire("").1.isEmpty)

        // Valeur invalide : défaut actuel (""), avec un avertissement qui la cite.
        let (adresse, avertissements) = lire("Mac-Essai.local")
        XCTAssertEqual(adresse, Config().bindAddress)
        XCTAssertEqual(adresse, "")
        XCTAssertTrue(avertissements.contains { $0.contains("bind_address") && $0.contains("Mac-Essai.local") },
                      "\(avertissements)")

        // Pas une chaîne : défaut, avec avertissement.
        let r = Config.parse(data: Data(#"{"bind_address": 127}"#.utf8))
        XCTAssertEqual(r.config.bindAddress, "")
        XCTAssertTrue(r.warnings.contains { $0.contains("bind_address") }, "\(r.warnings)")
    }
}
