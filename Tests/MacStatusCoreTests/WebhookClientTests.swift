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

    func test_urlInvalide_estMasqueeAuJournalEtDansLeStatut() {
        var config = Config()
        config.enabled = true
        config.webhookBaseURL = "http://u:secret@192.0.2.10 :8123/api/webhook/abc123"
        let client = WebhookClient(config: config, transport: transport, scheduler: planificateur, clock: horloge)
        client.publish(true, force: false)
        XCTAssertTrue(transport.requetes.isEmpty)
        let textes = journal.lines.map { $0.1 } + [(client.statusDictionary["detail"] as? String) ?? ""]
        XCTAssertTrue(textes.contains { $0.contains("<url invalide>") })
        XCTAssertFalse(textes.contains { $0.contains("secret") || $0.contains("abc123") })
    }

    func test_echecDuTransport_nExposePasLUrlConfiguree() {
        var config = Config()
        config.enabled = true
        config.webhookBaseURL = "http://u:secret@192.0.2.10:8123/api/webhook/abc123"
        config.accessoryID = "mac"
        config.webhookRetries = 0
        let client = WebhookClient(config: config, transport: transport, scheduler: planificateur, clock: horloge)
        transport.reponseParDefaut = .failed(detail: "échec sur http://u:secret@192.0.2.10:8123/api/webhook/abc123?accessoryId=mac&state=true")
        client.publish(true, force: false)
        let textes = journal.lines.map { $0.1 } + [(client.statusDictionary["detail"] as? String) ?? ""]
        XCTAssertTrue(textes.contains { $0.contains("<masqué>") })
        XCTAssertFalse(textes.contains { $0.contains("secret") || $0.contains("abc123") || $0.contains("accessoryId") })
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
        // Pendant que le premier envoi est en vol, l'état bascule plusieurs fois (doublons
        // compris) et finit sur « false ».
        client.publish(false, force: false)
        client.publish(true, force: false)
        client.publish(true, force: false)
        client.publish(false, force: false)
        client.publish(true, force: false)
        client.publish(false, force: false)
        XCTAssertEqual(transport.requetes.count, 1, "un seul envoi en vol à la fois")

        transport.terminerEnAttente()
        // Les basculements intermédiaires ont fusionné : seul le dernier (« false ») part ensuite.
        XCTAssertEqual(transport.requetes.map { $0.url.query }, [
            "accessoryId=mac&state=true",
            "accessoryId=mac&state=false",
        ])
        transport.terminerEnAttente()
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "0")
        XCTAssertEqual(client.statusDictionary["in_flight"] as? Bool, false)
    }

    /// R20 : le dernier état voulu diffère du premier intermédiaire. Une mise en file du premier
    /// changement (au lieu du dernier) enverrait « false » ; la fusion n'envoie rien de plus,
    /// puisque le dernier état voulu est celui qui était en vol.
    func test_changementsFusionnes_dernierEtatDifferentDuPremierIntermediaire() {
        transport.differe = true
        let client = creerClient()
        client.publish(true, force: false)
        client.publish(false, force: false)   // premier intermédiaire
        client.publish(true, force: false)
        client.publish(false, force: false)
        client.publish(true, force: false)    // dernier : différent du premier intermédiaire
        transport.terminerEnAttente()
        XCTAssertEqual(transport.requetes.map { $0.url.query }, ["accessoryId=mac&state=true"])
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "1")
        XCTAssertEqual(planificateur.pending, 0)
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

        // Série rapide terminée : aucun envoi supplémentaire jusqu'à t + 14 s ; seul le réessai
        // lent attend, 15 s après l'abandon.
        planificateur.runDue(at: 14)
        XCTAssertEqual(transport.requetes.count, 4)
        XCTAssertEqual(planificateur.echeances, [22.5])
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

    func test_nouvelEtatPendantLeReessai_partToutDeSuite_etLeReessaiPerimeNeFaitRien() {
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
        XCTAssertEqual(planificateur.echeances, [15], "seul le réessai lent attend")
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

    func test_attente_rienALivrer_repondToutDeSuite() {
        let client = creerClient()
        var resultat: Bool?
        client.notifyWhenDelivered(timeout: 1.5) { resultat = $0 }
        XCTAssertEqual(resultat, true)
    }

    func test_attente_livraisonConfirmee_repondVrai_etAnnuleLeDelai() {
        transport.differe = true
        let client = creerClient()
        client.publish(false, force: false)
        var reponses: [Bool] = []
        client.notifyWhenDelivered(timeout: 1.5) { reponses.append($0) }
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
        client.notifyWhenDelivered(timeout: 1.5) { reponses.append($0) }

        planificateur.runDue(at: 1.4)
        XCTAssertTrue(reponses.isEmpty)
        planificateur.runDue(at: 1.5)
        XCTAssertEqual(reponses, [false])

        transport.terminerEnAttente()
        XCTAssertEqual(reponses, [false])
    }

    func test_attente_retireeALEcheance() {
        transport.differe = true
        let client = creerClient()
        client.publish(false, force: false)
        var reponses: [Bool] = []
        client.notifyWhenDelivered(timeout: 1.5) { reponses.append($0) }
        client.notifyWhenDelivered(timeout: 3) { reponses.append($0) }
        XCTAssertEqual(client.pendingDeliveryNotifications, 2)

        planificateur.runDue(at: 1.5)
        XCTAssertEqual(reponses, [false])
        XCTAssertEqual(client.pendingDeliveryNotifications, 1)

        transport.terminerEnAttente()
        XCTAssertEqual(reponses, [false, true])
        XCTAssertEqual(client.pendingDeliveryNotifications, 0)
        planificateur.runDue(at: 10)
        XCTAssertEqual(reponses, [false, true])
    }

    func test_attente_echecDefinitif_repondFauxSansAttendreLeDelai() {
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let client = creerClient(essais: 0)
        // Le faux transport répond dans l'appel : on s'inscrit donc avant l'envoi
        // en le retenant, puis on libère la réponse d'échec.
        transport.differe = true
        client.publish(false, force: false)
        var reponses: [Bool] = []
        client.notifyWhenDelivered(timeout: 1.5) { reponses.append($0) }
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
            client.notifyWhenDelivered(timeout: 1.5) {
                reponse = $0
                terminee.fulfill()
            }
            // La réponse du transport arrive plus tard, sur la même file.
            file.async { transportDiffere.terminerEnAttente() }
        }
        wait(for: [terminee], timeout: 2)
        XCTAssertEqual(reponse, true)
    }

    // MARK: - Tâche 15 : plusieurs cibles

    private func cible(_ hote: String, _ methode: String = "GET", entetes: [String: String] = [:]) -> WebhookTarget {
        WebhookTarget(url: methode == "GET" ? "http://\(hote):51828/" : "http://\(hote):8123/api/webhook/webhook-essai-abc123",
                      method: methode, headers: entetes)
    }

    private func creerClient(cibles: [WebhookTarget], essais: Int = 3, sonde: LocalNetworkProbe? = nil) -> WebhookClient {
        var config = Config()
        config.enabled = true
        config.webhookTargets = cibles
        config.accessoryID = "mac"
        config.webhookRetries = essais
        return WebhookClient(config: config, transport: transport, scheduler: planificateur, clock: horloge, probe: sonde)
    }

    private func entreeCible(_ client: WebhookClient, _ index: Int) -> [String: Any] {
        ((client.statusDictionary["targets"] as? [[String: Any]]) ?? [])[safe: index] ?? [:]
    }

    func test_deuxCibles_unePanne_lAutreConfirmee() {
        transport.reponsesParHote["192.0.2.11"] = .failed(detail: "hors ligne")
        let client = creerClient(cibles: [cible("192.0.2.10"), cible("192.0.2.11", "POST")])
        client.publish(true, force: false)
        XCTAssertEqual(transport.requetes(vers: "192.0.2.10").count, 1)
        XCTAssertEqual(transport.requetes(vers: "192.0.2.11").count, 1)
        XCTAssertEqual(entreeCible(client, 0)["confirmed"] as? String, "1")
        XCTAssertNil(entreeCible(client, 1)["confirmed"])
        XCTAssertNil(client.statusDictionary["confirmed"], "pas d'état confirmé commun tant qu'une cible manque")

        // La cible en panne réessaie seule ; l'autre n'est pas renvoyée.
        planificateur.runDue(at: 0.5)
        XCTAssertEqual(transport.requetes(vers: "192.0.2.11").count, 2)
        XCTAssertEqual(transport.requetes(vers: "192.0.2.10").count, 1)

        // Une cible bloquée (réponse qui n'arrive pas) ne retarde pas l'autre : le nouvel état
        // part tout de suite vers la cible saine.
        transport.reponsesParHote["192.0.2.11"] = nil
        transport.hotesDifferes = ["192.0.2.11"]
        planificateur.runDue(at: 2.5)
        XCTAssertEqual(transport.requetes(vers: "192.0.2.11").count, 3)
        XCTAssertEqual(transport.reponsesEnAttente, 1)
        client.publish(false, force: false)
        XCTAssertEqual(transport.requetes(vers: "192.0.2.10").map { $0.url.query },
                       ["accessoryId=mac&state=true", "accessoryId=mac&state=false"])
        XCTAssertEqual(entreeCible(client, 0)["confirmed"] as? String, "0")
        XCTAssertEqual(transport.requetes(vers: "192.0.2.11").count, 3, "toujours une seule requête en vol par cible")

        // La réponse retenue (pour « true ») arrive : « false » part aussitôt vers cette cible.
        transport.terminerEnAttente(hote: "192.0.2.11")
        XCTAssertEqual(transport.requetes(vers: "192.0.2.11").count, 4)
        transport.terminerEnAttente(hote: "192.0.2.11")
        XCTAssertEqual(entreeCible(client, 1)["confirmed"] as? String, "0")
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "0")
    }

    /// Quatrième point de vigilance : la cible injoignable pendant des heures, puis de retour,
    /// reçoit l'état voulu au plus tard au réessai lent suivant (≤ 60 s), sans battement de cœur.
    func test_cibleRevenue_estResynchroniseeParLeReessaiLent() {
        for retour in [8.0, 20.0, 23.0, 40.0, 53.0, 100.0, 3_600.0, 4 * 3_600.0] {
            horloge = TestClock(t: 0)
            planificateur = TestScheduler(clock: horloge)
            transport = FakeTransport(clock: horloge)
            transport.reponseParDefaut = .failed(detail: "hors ligne")
            let client = creerClient(cibles: [cible("192.0.2.20", "POST")], essais: 3)
            client.publish(true, force: false)
            planificateur.runDue(at: retour)
            transport.reponseParDefaut = .delivered(status: 200)
            let envoisAvant = transport.requetes.count
            planificateur.runDue(at: retour + 60)
            XCTAssertEqual(entreeCible(client, 0)["confirmed"] as? String, "1", "retour à t=\(retour)")
            XCTAssertEqual(transport.requetes.count, envoisAvant + 1, "un seul envoi suffit (retour à t=\(retour))")
            if let confirme = transport.instants.last {
                XCTAssertLessThanOrEqual(confirme - retour, 60, "retour à t=\(retour)")
            }
        }
        // Calendrier : série rapide (0 ; 0,5 ; 2,5 ; 7,5), abandon, puis 15 s, 30 s, et 60 s ensuite.
        journal.lines = []
        horloge = TestClock(t: 0)
        planificateur = TestScheduler(clock: horloge)
        transport = FakeTransport(clock: horloge)
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let client = creerClient(cibles: [cible("192.0.2.20")], essais: 3)
        client.publish(true, force: false)
        planificateur.runDue(at: 300)
        XCTAssertEqual(transport.instants, [0, 0.5, 2.5, 7.5, 22.5, 52.5, 112.5, 172.5, 232.5, 292.5])
        XCTAssertEqual(journal.lines.filter { $0.0 == .error && $0.1.contains("abandonné") }.count, 1,
                       "une seule ligne d'abandon par épisode")
        transport.reponseParDefaut = .delivered(status: 200)
        planificateur.runDue(at: 360)
        XCTAssertTrue(journal.lines.contains { $0.0 == .info && $0.1.contains("de retour après") }, "\(journal.lines)")
        XCTAssertEqual(planificateur.pending, 0, "plus aucun réessai une fois l'état confirmé")
    }

    func test_minuteriePerimee_sansEffet() {
        planificateur.ignorerAnnulations = true
        transport.script = [.failed(detail: "échec")]
        let client = creerClient(cibles: [cible("192.0.2.10")])
        client.publish(true, force: false)            // échec → réessai rapide à 0,5 s
        client.publish(false, force: false)           // nouvel envoi, confirmé : la minuterie est périmée
        XCTAssertEqual(transport.requetes.count, 2)
        planificateur.runDue(at: 30)
        XCTAssertEqual(transport.requetes.count, 2, "la minuterie périmée ne renvoie rien")
        XCTAssertEqual(entreeCible(client, 0)["confirmed"] as? String, "0")

        // Même chose pour le réessai lent : la cible revient par le réseau avant son échéance.
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let autre = creerClient(cibles: [cible("192.0.2.11")], essais: 0)
        autre.publish(true, force: false)            // abandon → réessai lent à 45 s (30 + 15)
        transport.reponseParDefaut = .delivered(status: 200)
        autre.networkBecameAvailable()
        XCTAssertEqual(transport.requetes(vers: "192.0.2.11").count, 2)
        planificateur.runDue(at: 200)
        XCTAssertEqual(transport.requetes(vers: "192.0.2.11").count, 2, "le réessai lent périmé ne renvoie rien")
    }

    func test_reseauRevenu_renvoieImmediatement() {
        transport.reponseParDefaut = .failed(detail: "réseau absent")
        let client = creerClient(cibles: [cible("192.0.2.10"), cible("192.0.2.11")], essais: 3)
        client.publish(true, force: false)
        planificateur.runDue(at: 10)                  // les deux cibles ont abandonné
        XCTAssertEqual(transport.requetes.count, 8)
        transport.reponseParDefaut = .delivered(status: 200)
        client.networkBecameAvailable()
        XCTAssertEqual(transport.requetes.count, 10, "chaque cible non confirmée renvoie tout de suite")
        XCTAssertEqual(Array(transport.instants.suffix(2)), [10, 10])
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "1")
        XCTAssertEqual(planificateur.pending, 0)

        // Une cible confirmée n'est pas renvoyée ; une rafale d'avis ne fait rien de plus.
        for _ in 0..<5 { client.networkBecameAvailable() }
        XCTAssertEqual(transport.requetes.count, 10)

        // La tentative revient à 0 : après un retour du réseau, la série rapide recommence entière.
        transport.reponseParDefaut = .failed(detail: "réseau absent")
        client.publish(false, force: false)
        planificateur.runDue(at: 30)                  // abandon des deux cibles
        planificateur.runDue(at: 40)
        let avant = transport.requetes.count
        client.networkBecameAvailable()
        XCTAssertEqual(transport.requetes.count, avant + 2)
        for _ in 0..<5 { client.networkBecameAvailable() }
        XCTAssertEqual(transport.requetes.count, avant + 2, "pas de rafale : une requête en vol ou un avis trop proche ne renvoie rien")
        planificateur.runDue(at: 40.5)
        XCTAssertEqual(transport.requetes.count, avant + 4, "premier réessai rapide à +0,5 s")
    }

    /// Tâche 16 : tant que le moteur interdit les envois, ni publication, ni réessai (rapide ou lent),
    /// ni relance au retour du réseau, ni envoi d'arrêt ; la levée ne renvoie rien d'elle-même.
    func test_envoisSuspendus_aucunReessaiNiRelanceNiPublication() {
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let client = creerClient(cibles: [cible("192.0.2.10")], essais: 0)
        client.publish(true, force: false)               // abandon aussitôt → réessai lent à +15 s
        XCTAssertEqual(transport.requetes.count, 1)
        XCTAssertEqual(planificateur.pending, 1)

        client.setSendingSuspended(true)
        XCTAssertEqual(planificateur.pending, 0, "la minuterie du réessai lent est retirée")
        XCTAssertEqual(client.statusDictionary["suspended"] as? Bool, true)
        XCTAssertEqual(entreeCible(client, 0)["phase"] as? String, "suspendu")
        transport.reponseParDefaut = .delivered(status: 200)
        planificateur.runDue(at: 600)
        client.networkBecameAvailable()
        client.publish(true, force: true)
        client.publish(false, force: false)
        client.publishBeforeExit(false)
        XCTAssertEqual(transport.requetes.count, 1, "aucun envoi tant que c'est suspendu")

        client.setSendingSuspended(false)
        XCTAssertEqual(transport.requetes.count, 1, "la levée ne renvoie rien d'elle-même")
        XCTAssertEqual(client.statusDictionary["suspended"] as? Bool, false)
        client.publish(false, force: true)
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertEqual(transport.requetes.last?.url.absoluteString,
                       "http://192.0.2.10:51828/?accessoryId=mac&state=false")
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "0")
    }

    /// Une requête en vol au moment de la suspension n'est pas annulée, mais son échec ne planifie
    /// aucun réessai, et sa réussite ne relance rien.
    func test_envoisSuspendus_requeteEnVol_sonEchecNePlanifieRien() {
        transport.differe = true
        let client = creerClient(cibles: [cible("192.0.2.10")], essais: 3)
        client.publish(true, force: false)
        XCTAssertEqual(transport.reponsesEnAttente, 1)
        client.setSendingSuspended(true)
        XCTAssertEqual(transport.annulations.count, 0, "la requête en vol n'est pas annulée")

        transport.script = [.failed(detail: "coupé")]
        transport.terminerEnAttente()
        XCTAssertEqual(planificateur.pending, 0, "aucun réessai planifié pendant la suspension")
        planificateur.runDue(at: 600)
        XCTAssertEqual(transport.requetes.count, 1)

        // Réponse réussie d'un état périmé : le nouvel état voulu ne part pas non plus, suspendu.
        client.setSendingSuspended(false)
        transport.script = []
        client.publish(true, force: true)                 // en vol
        client.publish(false, force: false)               // voulu, derrière la requête en vol
        XCTAssertEqual(transport.requetes.count, 2)
        client.setSendingSuspended(true)
        transport.terminerEnAttente()                     // l'état 1 est confirmé, mais 0 est voulu
        XCTAssertEqual(transport.requetes.count, 2, "le nouvel état attend la fin de la suspension")
    }

    func test_post_corpsJSON() throws {
        let jeton = "Bearer jeton-essai-0123456789abcdef"
        let client = creerClient(cibles: [cible("192.0.2.30", "POST", entetes: ["Authorization": jeton])])
        client.publish(true, force: false)
        let requete = try XCTUnwrap(transport.requetes.first)
        XCTAssertEqual(requete.method, "POST")
        XCTAssertEqual(requete.url.absoluteString, "http://192.0.2.30:8123/api/webhook/webhook-essai-abc123",
                       "en POST, l'URL est celle de la cible, sans requête")
        XCTAssertEqual(requete.headers["Content-Type"], "application/json")
        XCTAssertEqual(requete.headers["Authorization"], jeton)
        XCTAssertEqual(requete.headers["User-Agent"], "macstatusd/\(macstatusdVersion)")
        let corps = try XCTUnwrap(requete.body)
        let objet = try XCTUnwrap(JSONSerialization.jsonObject(with: corps) as? [String: Any])
        XCTAssertEqual(objet["accessoryId"] as? String, "mac")
        XCTAssertEqual((objet["state"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() }, true,
                       "state est un booléen JSON")
        XCTAssertEqual(objet["state"] as? Bool, true)
        XCTAssertEqual(objet.count, 2)

        client.publish(false, force: false)
        let second = try XCTUnwrap(transport.requetes.last?.body)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: second) as? [String: Any])?["state"] as? Bool, false)

        // En GET, ni corps ni Content-Type.
        let get = creerClient(cibles: [cible("192.0.2.31")])
        get.publish(true, force: false)
        XCTAssertNil(transport.requetes.last?.body)
        XCTAssertNil(transport.requetes.last?.headers["Content-Type"])

        // Secrets : ni l'identifiant du webhook, ni l'en-tête, au journal ou dans /status.
        transport.reponseParDefaut = .failed(detail: "échec vers http://192.0.2.30:8123/api/webhook/webhook-essai-abc123 (\(jeton))")
        client.publish(true, force: false)
        let statut = String(describing: client.statusDictionary)
        let textes = journal.lines.map { $0.1 } + [statut]
        XCTAssertFalse(textes.contains { $0.contains("webhook-essai-abc123") || $0.contains("0123456789abcdef") }, "\(textes)")
        XCTAssertTrue(statut.contains("http://192.0.2.30:8123/api/webhook/<masqué>"), statut)
        XCTAssertFalse(statut.contains("Authorization"), "les en-têtes n'apparaissent jamais dans /status")
    }

    func test_404_detailAccessoryIdInconnu() {
        transport.reponseParDefaut = .delivered(status: 404)
        let client = creerClient(cibles: [cible("192.0.2.10")], essais: 0)
        client.publish(true, force: false)
        XCTAssertEqual(entreeCible(client, 0)["detail"] as? String, "HTTP 404 : accessoryId inconnu de la cible")
        XCTAssertTrue(journal.lines.contains { $0.1.contains("accessoryId inconnu de la cible") })
        XCTAssertNil(entreeCible(client, 0)["confirmed"])
    }

    func test_redirection_estUnEchec() {
        transport.reponseParDefaut = .delivered(status: 302)
        let client = creerClient(cibles: [cible("192.0.2.10")], essais: 0)
        client.publish(true, force: false)
        XCTAssertEqual(entreeCible(client, 0)["detail"] as? String, "HTTP 302 : redirection refusée")
        XCTAssertNil(entreeCible(client, 0)["confirmed"])
    }

    func test_toutCode2xx_confirme() {
        for code in [200, 201, 202, 204, 299] {
            transport.reponseParDefaut = .delivered(status: code)
            let client = creerClient(cibles: [cible("192.0.2.10")])
            client.publish(true, force: false)
            XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "1", "HTTP \(code)")
        }
    }

    func test_battementDeCoeurSansChangement_journaliseEnDebug() {
        let client = creerClient(cibles: [cible("192.0.2.10")])
        client.publish(true, force: false)
        XCTAssertEqual(journal.lines.filter { $0.0 == .info && $0.1.contains("confirmé") }.count, 1)

        journal.lines = []
        client.publish(true, force: true)
        client.publish(true, force: true)
        XCTAssertEqual(transport.requetes.count, 3)
        XCTAssertFalse(journal.lines.contains { $0.0 != .debug }, "battement de cœur : DEBUG seulement \(journal.lines)")
        XCTAssertTrue(journal.lines.contains { $0.0 == .debug && $0.1.contains("reconfirmé") })

        // Un état confirmé qui change : INFO.
        journal.lines = []
        client.publish(false, force: false)
        XCTAssertTrue(journal.lines.contains { $0.0 == .info && $0.1.contains("confirmé") && $0.1.contains("état=0") })

        // Un retour après panne : INFO, avec la durée de la panne.
        journal.lines = []
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        client.publish(false, force: true)
        planificateur.runDue(at: 100)
        transport.reponseParDefaut = .delivered(status: 200)
        client.publish(false, force: true)
        let retour = journal.lines.first { $0.0 == .info && $0.1.contains("de retour après") }
        XCTAssertNotNil(retour, "\(journal.lines)")
        XCTAssertTrue(retour?.1.contains("1 min 40 s") ?? false, retour?.1 ?? "")
    }

    // MARK: - Tâche 15 : arrêt (ajouts 1 et 2)

    /// Ajout 1 (R40), précisé par le lot 2 (point 6) : à l'arrêt, l'ON en vol n'est pas annulé
    /// tout de suite. Muet, il est annulé à 500 ms, et OFF part alors vers chaque cible.
    func test_avantDepart_ONmuet_estAnnuleA500ms_OFFPartEnsuite() {
        transport.differe = true
        let client = creerClient(cibles: [cible("192.0.2.10"), cible("192.0.2.11", "POST")])
        client.publish(true, force: false)
        XCTAssertEqual(transport.requetes.count, 2)
        var reponses: [Bool] = []
        client.publishBeforeExit(false)
        client.notifyWhenDelivered(timeout: 2) { reponses.append($0) }
        XCTAssertEqual(transport.annulations.count, 0, "l'ON en vol garde sa chance")
        XCTAssertEqual(transport.requetes.count, 2, "OFF n'est pas encore parti")
        planificateur.runDue(at: 0.4)
        XCTAssertEqual(transport.annulations.count, 0, "rien avant 500 ms")
        planificateur.runDue(at: 0.5)
        XCTAssertEqual(transport.annulations.count, 2, "chaque ON encore en vol est annulé à 500 ms")
        XCTAssertEqual(transport.requetes.count, 4, "OFF part aussitôt vers chaque cible")
        XCTAssertEqual(Array(transport.instants.suffix(2)), [0.5, 0.5])
        XCTAssertTrue(transport.requetes[2].url.absoluteString.hasSuffix("state=false"))
        XCTAssertTrue(journal.lines.contains { $0.0 == .info && $0.1.contains("annulée pour l'arrêt") }, "\(journal.lines)")
        transport.terminerEnAttente()
        XCTAssertEqual(reponses, [], "toutes les cibles doivent confirmer")
        transport.terminerEnAttente()
        XCTAssertEqual(reponses, [true])
        // Un OFF déjà en vol n'est pas annulé pour être renvoyé.
        client.publish(true, force: false)
        client.publishBeforeExit(true)
        planificateur.runDue(at: 5)
        XCTAssertEqual(transport.annulations.count, 2)
    }

    /// Lot 2, point 6 : un ON qui aboutit à 300 ms (dans la grâce) est suivi de OFF par le chemin
    /// normal ; rien n'est annulé, et la minuterie de grâce ne touche pas l'OFF en vol.
    func test_avantDepart_ONquiAboutitA300ms_OFFPartApresLui() {
        transport.differe = true
        let client = creerClient(cibles: [cible("192.0.2.10")])
        client.publish(true, force: false)
        var reponses: [Bool] = []
        client.publishBeforeExit(false)
        client.notifyWhenDelivered(timeout: 2) { reponses.append($0) }
        XCTAssertEqual(transport.requetes.count, 1, "OFF attend la réponse de l'ON")
        planificateur.runDue(at: 0.3)
        transport.terminerEnAttente()   // l'ON aboutit à 300 ms
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertTrue(transport.requetes[0].url.absoluteString.hasSuffix("state=true"))
        XCTAssertTrue(transport.requetes[1].url.absoluteString.hasSuffix("state=false"), "OFF après l'ON")
        XCTAssertEqual(transport.instants, [0, 0.3])
        XCTAssertEqual(reponses, [])
        planificateur.runDue(at: 0.5)
        XCTAssertEqual(transport.annulations.count, 0, "la grâce ne touche pas l'OFF en vol")
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertEqual(planificateur.pending, 1, "seule l'attente de livraison reste planifiée")
        transport.terminerEnAttente()
        XCTAssertEqual(reponses, [true])
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "0")
    }

    /// Lot 2, point 6 : une minuterie de grâce déjà partie malgré son annulation (course) est
    /// périmée par la génération : elle n'annule pas l'OFF en vol.
    func test_avantDepart_minuterieDeGracePerimee_neToucheRien() {
        planificateur.ignorerAnnulations = true
        transport.differe = true
        let client = creerClient(cibles: [cible("192.0.2.10")])
        client.publish(true, force: false)
        client.publishBeforeExit(false)
        transport.terminerEnAttente()   // l'ON aboutit : OFF part
        XCTAssertEqual(transport.requetes.count, 2)
        planificateur.runDue(at: 0.5)   // la minuterie de grâce passe quand même
        XCTAssertEqual(transport.annulations.count, 0)
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertEqual(transport.reponsesEnAttente, 1, "l'OFF reste en vol")
    }

    /// Lot 2, point 6 : un ON qui échoue pendant la grâce laisse partir OFF tout de suite.
    func test_avantDepart_ONquiEchoueDansLaGrace_OFFPartToutDeSuite() {
        transport.differe = true
        transport.reponsesParHote["192.0.2.10"] = .failed(detail: "hors ligne")
        let client = creerClient(cibles: [cible("192.0.2.10")])
        client.publish(true, force: false)
        var reponses: [Bool] = []
        client.publishBeforeExit(false)
        client.notifyWhenDelivered(timeout: 2) { reponses.append($0) }
        transport.reponsesParHote["192.0.2.10"] = .delivered(status: 200)
        planificateur.runDue(at: 0.2)
        transport.terminerEnAttente()   // l'ON échoue
        XCTAssertEqual(transport.requetes.count, 2)
        XCTAssertTrue(transport.requetes[1].url.absoluteString.hasSuffix("state=false"))
        XCTAssertEqual(transport.instants, [0, 0.2])
        planificateur.runDue(at: 0.6)
        XCTAssertEqual(transport.annulations.count, 0)
        transport.terminerEnAttente()
        XCTAssertEqual(reponses, [true])
    }

    /// Ajout 2 : `webhook_retries = 0`, l'ON en vol échoue alors que l'état voulu est devenu OFF :
    /// OFF part quand même, tout de suite.
    func test_essais0_echecPendantUnChangement_nAbandonnePasLeNouvelEtat() {
        transport.differe = true
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let client = creerClient(cibles: [cible("192.0.2.10")], essais: 0)
        client.publish(true, force: false)
        client.publish(false, force: false)
        transport.terminerEnAttente()
        XCTAssertEqual(transport.requetes.map { $0.url.query },
                       ["accessoryId=mac&state=true", "accessoryId=mac&state=false"])
        // OFF échoue à son tour : l'abandon garde OFF pour le réessai lent.
        transport.terminerEnAttente()
        XCTAssertEqual(planificateur.echeances, [15])
        transport.differe = false
        transport.reponseParDefaut = .delivered(status: 200)
        planificateur.runDue(at: 15)
        XCTAssertEqual(transport.requetes.last?.url.query, "accessoryId=mac&state=false")
        XCTAssertEqual(client.statusDictionary["confirmed"] as? String, "0")

        // À l'arrêt, l'ON a déjà échoué (rien à annuler, réessai lent en attente) : la tentative
        // OFF part quand même, tout de suite, et sa confirmation termine l'attente.
        transport.differe = true
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let autre = creerClient(cibles: [cible("192.0.2.11")], essais: 0)
        autre.publish(true, force: false)
        transport.terminerEnAttente(hote: "192.0.2.11")   // ON échoue : réessai lent
        XCTAssertEqual(planificateur.pending, 1)
        transport.reponsesParHote["192.0.2.11"] = .delivered(status: 200)
        var reponses: [Bool] = []
        autre.publishBeforeExit(false)
        autre.notifyWhenDelivered(timeout: 2) { reponses.append($0) }
        XCTAssertEqual(transport.requetes(vers: "192.0.2.11").last?.url.query, "accessoryId=mac&state=false")
        XCTAssertEqual(planificateur.pending, 1, "le réessai lent est remplacé par l'attente du délai")
        transport.terminerEnAttente(hote: "192.0.2.11")
        XCTAssertEqual(reponses, [true])
    }

    // MARK: - Tâche 15 : attente de livraison (ajouts 3 et 4)

    /// Ajout 3 : aucune cible, client désactivé ou URL inutilisable : `false` tout de suite.
    func test_attente_aucuneCibleOuRienAEnvoyer_repondFauxToutDeSuite() {
        var reponses: [Bool] = []
        creerClient(actif: false).notifyWhenDelivered(timeout: 2) { reponses.append($0) }
        creerClient(cibles: []).notifyWhenDelivered(timeout: 2) { reponses.append($0) }
        let degrade = WebhookClient(config: Config.degraded(), transport: transport, scheduler: planificateur, clock: horloge)
        degrade.publish(false, force: true)
        degrade.notifyWhenDelivered(timeout: 2) { reponses.append($0) }
        var config = Config()
        config.enabled = true
        config.webhookBaseURL = "http://192.0.2.10 :51828/"
        let invalide = WebhookClient(config: config, transport: transport, scheduler: planificateur, clock: horloge)
        invalide.publish(false, force: true)
        invalide.notifyWhenDelivered(timeout: 2) { reponses.append($0) }
        XCTAssertEqual(reponses, [false, false, false, false], "sans attendre l'échéance")
        XCTAssertTrue(transport.requetes.isEmpty, "mode dégradé et URL invalide : rien n'est envoyé")
        XCTAssertEqual(planificateur.pending, 0)
    }

    /// Ajout 4 : plusieurs attentes simultanées sur deux cibles, dont une qui expire avant la
    /// livraison ; les autres attendent que toutes les cibles aient confirmé.
    func test_attentesSimultanees_deuxCibles_uneExpireAvantLaLivraison() {
        transport.differe = true
        let client = creerClient(cibles: [cible("192.0.2.10"), cible("192.0.2.11")])
        client.publish(false, force: false)
        var reponses: [String] = []
        client.notifyWhenDelivered(timeout: 1.5) { reponses.append("a:\($0)") }
        client.notifyWhenDelivered(timeout: 3) { reponses.append("b:\($0)") }
        client.notifyWhenDelivered(timeout: 10) { reponses.append("c:\($0)") }
        planificateur.runDue(at: 1.5)
        XCTAssertEqual(reponses, ["a:false"])
        XCTAssertEqual(client.pendingDeliveryNotifications, 2)
        transport.terminerEnAttente(hote: "192.0.2.10")
        XCTAssertEqual(reponses, ["a:false"], "une seule cible confirmée : on attend encore")
        transport.terminerEnAttente(hote: "192.0.2.11")
        XCTAssertEqual(reponses, ["a:false", "b:true", "c:true"])
        XCTAssertEqual(client.pendingDeliveryNotifications, 0)
        planificateur.runDue(at: 20)
        XCTAssertEqual(reponses.count, 3)
    }

    /// Une cible abandonnée ne fait pas couper l'attente avant que l'autre ait répondu ; le
    /// résultat est alors `false`.
    func test_attente_uneCibleAbandonnee_resultatFauxApresLAutre() {
        transport.hotesDifferes = ["192.0.2.10"]
        transport.reponsesParHote["192.0.2.11"] = .failed(detail: "hors ligne")
        let client = creerClient(cibles: [cible("192.0.2.10"), cible("192.0.2.11")], essais: 0)
        client.publish(false, force: false)
        var reponses: [Bool] = []
        client.notifyWhenDelivered(timeout: 2) { reponses.append($0) }
        XCTAssertEqual(reponses, [], "la première cible est encore en vol")
        transport.terminerEnAttente(hote: "192.0.2.10")
        XCTAssertEqual(reponses, [false])
    }

    /// Lot 2, point 10 : l'accord du message d'abandon suit le nombre d'essais.
    func test_abandon_accordDuNombreDEssais() {
        transport.reponseParDefaut = .failed(detail: "hors ligne")
        let un = creerClient(cibles: [cible("192.0.2.10")], essais: 0)
        un.publish(true, force: false)
        let abandonUn = journal.lines.first { $0.1.contains("abandonné après") }
        XCTAssertTrue(abandonUn?.1.contains("abandonné après 1 essai —") ?? false, "\(journal.lines)")

        journal.lines = []
        let quatre = creerClient(cibles: [cible("192.0.2.11")], essais: 3)
        quatre.publish(true, force: false)
        planificateur.runDue(at: 100)
        let abandonQuatre = journal.lines.first { $0.1.contains("abandonné après") && $0.1.contains("192.0.2.11") }
        XCTAssertTrue(abandonQuatre?.1.contains("abandonné après 4 essais —") ?? false, "\(journal.lines)")
    }

    // MARK: - Tâche 15 : accès au réseau local

    func test_sondeReseauLocal_uneFoisParEpisode_versLaCibleSeulement() {
        let sonde = FakeProbe()
        sonde.refuse = true
        let horsLigne = WebhookOutcome.failed(detail: "hors ligne",
                                              error: TransportError(domain: NSURLErrorDomain, code: -1009))
        transport.reponseParDefaut = horsLigne
        let client = creerClient(cibles: [cible("192.0.2.40")], essais: 3, sonde: sonde)
        client.publish(true, force: false)
        planificateur.runDue(at: 100)
        XCTAssertEqual(sonde.sondes.count, 1, "une seule sonde par épisode d'échec")
        XCTAssertEqual(sonde.sondes.first?.host, "192.0.2.40")
        XCTAssertEqual(sonde.sondes.first?.port, 51828)
        let refus = journal.lines.filter { $0.0 == .error && $0.1.contains("accès au réseau local refusé") }
        XCTAssertEqual(refus.count, 1, "\(journal.lines)")
        XCTAssertTrue(journal.lines.contains { $0.1.contains("NSURLErrorDomain") && $0.1.contains("-1009") },
                      "domaine et code journalisés")

        // Fin de l'épisode (succès), puis nouvel épisode : une nouvelle sonde.
        transport.reponseParDefaut = .delivered(status: 200)
        planificateur.runDue(at: 200)
        transport.reponseParDefaut = WebhookOutcome.failed(detail: "refusée",
                                                           error: TransportError(domain: NSURLErrorDomain, code: -1004))
        client.publish(false, force: false)
        XCTAssertEqual(sonde.sondes.count, 2)

        // Une autre erreur (délai dépassé, -1001) ne sonde pas ; une sonde qui ne refuse pas ne dit rien.
        let autreSonde = FakeProbe()
        transport.reponseParDefaut = .failed(detail: "délai", error: TransportError(domain: NSURLErrorDomain, code: -1001))
        let autre = creerClient(cibles: [cible("192.0.2.41")], essais: 0, sonde: autreSonde)
        autre.publish(true, force: false)
        XCTAssertEqual(autreSonde.sondes.count, 0)
        transport.reponseParDefaut = horsLigne
        autre.publish(false, force: false)
        XCTAssertEqual(autreSonde.sondes.count, 1)
        XCTAssertEqual(journal.lines.filter { $0.1.contains("accès au réseau local refusé") }.count, 2)
    }

    // MARK: - Tâche 15 : /status

    func test_statut_uneEntreeParCible_URLMasquee_sansEnTetes() throws {
        transport.reponsesParHote["192.0.2.11"] = .failed(detail: "hors ligne")
        let client = creerClient(cibles: [cible("192.0.2.10"),
                                          cible("192.0.2.11", "POST", entetes: ["X-Cle": "jeton-essai-0123456789abcdef"])],
                                 essais: 0)
        client.publish(true, force: false)
        let cibles = try XCTUnwrap(client.statusDictionary["targets"] as? [[String: Any]])
        XCTAssertEqual(cibles.count, 2)
        XCTAssertEqual(cibles[0]["url"] as? String, "http://192.0.2.10:51828/")
        XCTAssertEqual(cibles[0]["method"] as? String, "GET")
        XCTAssertEqual(cibles[0]["confirmed"] as? String, "1")
        XCTAssertEqual(cibles[1]["url"] as? String, "http://192.0.2.11:8123/api/webhook/<masqué>")
        XCTAssertEqual(cibles[1]["method"] as? String, "POST")
        XCTAssertEqual(cibles[1]["phase"] as? String, "réessai lent")
        XCTAssertEqual(cibles[1]["failures_since_success"] as? Int, 1)
        XCTAssertNotNil(cibles[1]["next_retry_seconds"])
        let texte = String(describing: client.statusDictionary)
        XCTAssertFalse(texte.contains("0123456789abcdef") || texte.contains("X-Cle") || texte.contains("webhook-essai"), texte)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(client.statusDictionary))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
