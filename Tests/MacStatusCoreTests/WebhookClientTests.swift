import XCTest
@testable import MacStatusCore

/// Client webhook : l'URL, la fusion des changements, les réessais, la
/// resynchronisation forcée et l'attente de livraison. Aucun réseau, aucune
/// attente réelle : transport et planificateur sont simulés.
final class WebhookClientTests: XCTestCase {
    private var horloge: TestClock!
    private var planificateur: TestScheduler!
    private var transport: FakeTransport!
    private var journal: CaptureLog!
    private var ancienRecepteur: LogSink?

    override func setUp() {
        super.setUp()
        horloge = TestClock(t: 0)
        planificateur = TestScheduler(clock: horloge)
        transport = FakeTransport(clock: horloge)
        journal = CaptureLog()
        ancienRecepteur = CoreLog.sink
        CoreLog.sink = journal
    }

    override func tearDown() {
        CoreLog.sink = ancienRecepteur
        super.tearDown()
    }

    private func creerClient(actif: Bool = true, essais: Int = 3) -> WebhookClient {
        var config = Config()
        config.enabled = actif
        config.webhookBaseURL = "http://192.0.2.10:51828/"
        config.accessoryID = "mac"
        config.webhookRetries = essais
        return WebhookClient(config: config, transport: transport, scheduler: planificateur, clock: horloge)
    }

    // MARK: - Requête

    func test_urlEstConstruiteAvecAccessoryIdEtState() {
        let client = creerClient()
        client.publish(true, force: false)
        XCTAssertEqual(transport.requetes.map { $0.url.absoluteString },
                       ["http://192.0.2.10:51828/?accessoryId=mac&state=true"])
        XCTAssertEqual(transport.requetes[0].method, "GET")
        XCTAssertEqual(transport.requetes[0].headers, ["User-Agent": "macstatusd/\(macstatusdVersion)"])

        client.publish(false, force: false)
        XCTAssertEqual(transport.requetes.last?.url.absoluteString,
                       "http://192.0.2.10:51828/?accessoryId=mac&state=false")
    }

    func test_identifiantAvecCaracteresSpeciaux_estEncode() {
        var config = Config()
        config.enabled = true
        config.webhookBaseURL = "http://192.0.2.10:51828/"
        config.accessoryID = "Mac de Pièce 1"
        let client = WebhookClient(config: config, transport: transport, scheduler: planificateur, clock: horloge)
        client.publish(true, force: false)
        XCTAssertEqual(transport.requetes.first?.url.absoluteString,
                       "http://192.0.2.10:51828/?accessoryId=Mac%20de%20Pi%C3%A8ce%201&state=true")
    }

    func test_desactive_nEnvoieRien() {
        let client = creerClient(actif: false)
        client.publish(true, force: true)
        XCTAssertTrue(transport.requetes.isEmpty)
        XCTAssertEqual(client.statusDictionary["enabled"] as? Bool, false)
        XCTAssertEqual(client.statusDictionary["detail"] as? String, "désactivé par la configuration")
    }

    // MARK: - Fusion des changements

    func test_changementsFusionnes_seulLeDernierPart() {
        transport.differe = true
        let client = creerClient()
        client.publish(true, force: false)
        // Pendant que le premier envoi est en vol, l'état bascule trois fois.
        client.publish(false, force: false)
        client.publish(true, force: false)
        client.publish(false, force: false)
        XCTAssertEqual(transport.requetes.count, 1, "un seul envoi en vol à la fois")

        transport.terminerEnAttente()
        // Les basculements intermédiaires ont fusionné : seul « false » part ensuite.
        XCTAssertEqual(transport.requetes.map { $0.url.query }, [
            "accessoryId=mac&state=true",
            "accessoryId=mac&state=false",
        ])
        transport.terminerEnAttente()
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "0")
        XCTAssertEqual(client.statusDictionary["in_flight"] as? Bool, false)
    }

    func test_etatDejaConfirme_nEstPasReenvoye() {
        let client = creerClient()
        client.publish(true, force: false)
        client.publish(true, force: false)
        XCTAssertEqual(transport.requetes.count, 1)
    }

    // MARK: - Réessais

    func test_echec_reessaieA0_5s_2s_5s_puisAbandonne() {
        transport.reponseParDefaut = .failed(detail: "connexion refusée")
        let client = creerClient(essais: 3)
        client.publish(true, force: false)
        XCTAssertEqual(transport.requetes.count, 1)

        planificateur.runDue(at: 0.25)
        XCTAssertEqual(transport.requetes.count, 1, "premier réessai à +0,5 s")
        planificateur.runDue(at: 0.5)
        XCTAssertEqual(transport.requetes.count, 2)
        planificateur.runDue(at: 2.4)
        XCTAssertEqual(transport.requetes.count, 2, "deuxième réessai 2 s après le premier")
        planificateur.runDue(at: 2.5)
        XCTAssertEqual(transport.requetes.count, 3)
        planificateur.runDue(at: 7.4)
        XCTAssertEqual(transport.requetes.count, 3, "troisième réessai 5 s après le deuxième")
        planificateur.runDue(at: 7.5)
        XCTAssertEqual(transport.requetes.count, 4)

        // Série rapide terminée : aucun envoi supplémentaire jusqu'à t + 14 s.
        // (Le réessai lent viendra à la tâche 15 ; ce test ne dit rien d'après.)
        planificateur.runDue(at: 14)
        XCTAssertEqual(transport.requetes.count, 4)
        XCTAssertEqual(planificateur.pending, 0)
        XCTAssertTrue(journal.lines.contains { $0.0 == .error && $0.1.contains("abandonné après 4 essais") })
        XCTAssertEqual(client.statusDictionary["failures_since_success"] as? Int, 4)
    }

    func test_echec_instantsDesEnvois_enUnSeulSaut() {
        transport.reponseParDefaut = .failed(detail: "délai dépassé")
        let client = creerClient(essais: 3)
        client.publish(true, force: false)
        planificateur.runDue(at: 14)
        XCTAssertEqual(transport.instants, [0, 0.5, 2.5, 7.5])
    }

    func test_reponseHTTPHorsDe2xx_estUnEchecReessaye() {
        transport.script = [.delivered(status: 500), .delivered(status: 204)]
        let client = creerClient()
        client.publish(true, force: false)
        XCTAssertEqual(client.statusDictionary["detail"] as? String, "HTTP 500")
        XCTAssertNil(client.statusDictionary["confirmed"])
        planificateur.runDue(at: 0.5)
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "1")
        XCTAssertEqual(client.statusDictionary["failures_since_success"] as? Int, 0)
    }

    func test_nouvelEtatPendantLeReessai_partTouDeSuite_etLeReessaiPerimeNeFaitRien() {
        transport.script = [.failed(detail: "échec")]
        let client = creerClient()
        client.publish(true, force: false)
        XCTAssertEqual(transport.requetes.count, 1)
        XCTAssertEqual(planificateur.pending, 1, "un réessai attend")

        client.publish(false, force: false)
        XCTAssertEqual(transport.requetes.count, 2, "le nouvel état part sans attendre le réessai")
        XCTAssertEqual(planificateur.pending, 0, "le réessai périmé est annulé")
        planificateur.runDue(at: 30)
        XCTAssertEqual(transport.requetes.count, 2)
    }

    func test_abandon_puisNouvelleDemande_recommenceLaSerie() {
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let client = creerClient(essais: 0)
        client.publish(true, force: false)
        XCTAssertEqual(transport.requetes.count, 1)
        XCTAssertEqual(planificateur.pending, 0)
        // Le battement de cœur republie : l'envoi reprend.
        client.publish(true, force: true)
        XCTAssertEqual(transport.requetes.count, 2)
    }

    // MARK: - Resynchronisation forcée

    func test_force_reemetUnEtatDejaConfirme() {
        let client = creerClient()
        client.publish(true, force: false)
        client.publish(true, force: false)
        XCTAssertEqual(transport.requetes.count, 1)
        client.publish(true, force: true)
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "1")
    }

    // MARK: - Attente de livraison avant la veille

    func test_attente_riefALivrer_repondTouDeSuite() {
        let client = creerClient()
        var resultat: Bool?
        client.waitForDelivery(timeout: 1.5) { resultat = $0 }
        XCTAssertEqual(resultat, true)
    }

    func test_attente_livraisonConfirmee_repondVrai_etAnnuleLeDelai() {
        transport.differe = true
        let client = creerClient()
        client.publish(false, force: false)
        var reponses: [Bool] = []
        client.waitForDelivery(timeout: 1.5) { reponses.append($0) }
        XCTAssertTrue(reponses.isEmpty, "rien tant que l'envoi est en vol")

        transport.terminerEnAttente()
        XCTAssertEqual(reponses, [true])
        planificateur.runDue(at: 10)
        XCTAssertEqual(reponses, [true], "le délai annulé ne rappelle pas une seconde fois")
    }

    func test_attente_delaiDe1_5s_repondFaux_puisLivraisonTardiveNeRappellePas() {
        transport.differe = true
        let client = creerClient()
        client.publish(false, force: false)
        var reponses: [Bool] = []
        client.waitForDelivery(timeout: 1.5) { reponses.append($0) }

        planificateur.runDue(at: 1.4)
        XCTAssertTrue(reponses.isEmpty)
        planificateur.runDue(at: 1.5)
        XCTAssertEqual(reponses, [false])

        transport.terminerEnAttente()
        XCTAssertEqual(reponses, [false])
    }

    func test_attente_echecDefinitif_repondFauxSansAttendreLeDelai() {
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let client = creerClient(essais: 0)
        // Le faux transport répond dans l'appel : on s'inscrit donc avant l'envoi
        // en le retenant, puis on libère la réponse d'échec.
        transport.differe = true
        client.publish(false, force: false)
        var reponses: [Bool] = []
        client.waitForDelivery(timeout: 1.5) { reponses.append($0) }
        transport.terminerEnAttente()
        XCTAssertEqual(reponses, [false])
    }

    func test_attente_nBloquePasLaFile_rappelDepuisLaFileDuMoteur() {
        // Le client et son planificateur partagent une même file série : l'attente
        // doit rendre la main tout de suite, sinon la réponse ne pourrait jamais
        // arriver. Sur une vraie file, un rappel arrive pendant que l'appelant
        // est déjà revenu.
        let file = DispatchQueue(label: "essai.webhook.attente")
        let reel = DispatchScheduler(queue: file)
        let transportDiffere = FakeTransport()
        transportDiffere.differe = true
        var config = Config()
        config.enabled = true
        config.webhookBaseURL = "http://192.0.2.10:51828/"
        let client = WebhookClient(config: config, transport: transportDiffere, scheduler: reel, clock: SystemClock())

        let terminee = expectation(description: "attente terminée")
        var reponse: Bool?
        file.async {
            client.publish(false, force: false)
            client.waitForDelivery(timeout: 1.5) {
                reponse = $0
                terminee.fulfill()
            }
            // La réponse du transport arrive plus tard, sur la même file.
            file.async { transportDiffere.terminerEnAttente() }
        }
        wait(for: [terminee], timeout: 2)
        XCTAssertEqual(reponse, true)
    }
}
