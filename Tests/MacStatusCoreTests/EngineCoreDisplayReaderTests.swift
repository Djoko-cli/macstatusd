import XCTest
@testable import MacStatusCore

/// Lecteur des écrans d'essai : `readNow` exécute sur place et compte ; `readLater` garde les travaux, que le test
/// lance à la main (la relecture d'arrière-plan « part » et « finit » quand il le décide).
final class FauxLecteurEcrans: DisplayReadRunner {
    private(set) var lecturesImmediates = 0
    private(set) var travaux: [() -> Void] = []
    /// Retours en attente sur la file du moteur (le faux `deliver`).
    private(set) var livraisons: [() -> Void] = []

    func readNow(_ work: () -> DisplaySnapshot) -> DisplaySnapshot {
        lecturesImmediates += 1
        return work()
    }

    func readLater(_ work: @escaping () -> Void) {
        travaux.append(work)
    }

    func deliver(_ work: @escaping () -> Void) {
        livraisons.append(work)
    }

    /// Les relectures d'arrière-plan s'exécutent (leurs résultats attendent leur livraison).
    func finirLesRelectures() {
        let enCours = travaux
        travaux.removeAll()
        enCours.forEach { $0() }
    }

    /// Les résultats reviennent sur la file du moteur.
    func livrer() {
        let enCours = livraisons
        livraisons.removeAll()
        enCours.forEach { $0() }
    }

    /// Relecture finie puis livrée.
    func relireEtLivrer() {
        finirLesRelectures()
        livrer()
    }
}

/// Plan 4, tâche 2, étape 10 (R85, banc 4) : les écrans se lisent hors de la file du moteur, sans jamais servir un
/// relevé d'avant la veille.
final class EngineCoreDisplayReaderTests: EngineCoreTestCase {
    private var lecteur: FauxLecteurEcrans!

    override func setUp() {
        super.setUp()
        lecteur = FauxLecteurEcrans()
    }

    /// Moteur câblé comme l'exécuteur, avec le faux lecteur ; démarré (première lecture synchrone).
    private func moteurAvecLecteur() -> EngineCore {
        let config = Config()
        let oracle = ScreenSaverOracle(dismissOnInput: config.saverDismissOnInput,
                                       dismissGrace: config.saverDismissGrace,
                                       redisplayIdle: Double(config.saverRedisplayIdleSeconds),
                                       signals: signaux)
        let core = EngineCore(config: config, clock: horloge, signals: signaux, oracle: oracle,
                              actions: actions, publisher: publieur,
                              displayRunner: lecteur, deliver: { [lecteur] in lecteur!.deliver($0) })
        core.setListenerStatus(.ready)
        core.start()
        return core
    }

    private func verdictDesFaits(_ core: EngineCore) -> String? {
        core.statusSnapshot()["facts_reason"] as? String
    }

    func test_ecrans_premiereLecture_synchrone() {
        _ = moteurAvecLecteur()
        XCTAssertEqual(lecteur.lecturesImmediates, 1)
        XCTAssertEqual(signaux.lecturesEcrans, 1)
        XCTAssertTrue(lecteur.travaux.isEmpty, "la première lecture ne part pas en arrière-plan")
    }

    func test_ecrans_lectureSuivante_rendLeReleveGarde_uneSeuleRelecture() {
        let core = moteurAvecLecteur()
        for _ in 0..<3 { scruter(core, 0.5) }
        XCTAssertEqual(lecteur.travaux.count, 1, "trois ticks pendant une relecture en vol : un seul départ")
        XCTAssertEqual(lecteur.lecturesImmediates, 1)
        XCTAssertEqual(signaux.lecturesEcrans, 1, "le moteur n'a pas lu lui-même")
    }

    func test_ecrans_retourDeRelecture_recalculeSansNouvelleLecture() {
        let core = moteurAvecLecteur()
        scruter(core, 0.5)
        XCTAssertEqual(verdictDesFaits(core), "desktop-ui")
        signaux.etatEcran.asleep = true
        lecteur.relireEtLivrer()
        XCTAssertEqual(verdictDesFaits(core), "display-asleep", "les faits suivent le nouveau relevé")
        XCTAssertEqual(signaux.lecturesEcrans, 2)
        XCTAssertEqual(lecteur.lecturesImmediates, 1)
        XCTAssertTrue(lecteur.travaux.isEmpty, "aucune relecture de plus tant qu'aucun tick ne passe")
        scruter(core, 0.5)
        XCTAssertEqual(lecteur.travaux.count, 1, "le tick suivant relance une relecture")
    }

    func test_ecrans_relectureLanceeAvantLaVeille_jeteeApresLeReveil() {
        let core = moteurAvecLecteur()
        scruter(core, 0.5)
        XCTAssertEqual(lecteur.travaux.count, 1)
        core.willSleep {}
        horloge.advance(2)
        core.handle(.systemDidWake)
        XCTAssertEqual(verdictDesFaits(core), "desktop-ui")
        // La relecture partie avant la veille lit, bien après, des écrans endormis : son résultat est jeté.
        signaux.etatEcran.asleep = true
        lecteur.relireEtLivrer()
        XCTAssertEqual(verdictDesFaits(core), "desktop-ui", "relevé périmé jeté")
        scruter(core, 0.5)
        XCTAssertEqual(lecteur.travaux.count, 1, "le drapeau « en vol » est retombé : nouvelle relecture")
    }

    func test_reveilSombre_releveDAvantLaVeille_pasDeFauxON() {
        let core = moteurAvecLecteur()
        XCTAssertTrue(core.currentState)
        scruter(core, 0.5)               // relevé gardé : écran allumé, relecture en vol
        core.willSleep {}
        XCTAssertFalse(core.currentState)
        // Le Mac se réveille sans avis : les écrans réels sont endormis (réveil sombre).
        signaux.etatEcran.asleep = true
        horloge.advance(15)
        core.tick()                      // trou couvert par la veille : réveil
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(publieur.publications.filter { $0.etat }, [Publication(etat: true, force: false)],
                       "aucun ON publié après le premier (celui du démarrage) : \(publieur.publications)")
    }

    func test_veilleAnnoncee_lecturesSynchrones() {
        let core = moteurAvecLecteur()
        core.willSleep {}
        XCTAssertEqual(lecteur.lecturesImmediates, 2)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertEqual(lecteur.lecturesImmediates, 4, "pendant la veille annoncée, chaque lecture est synchrone")
        XCTAssertTrue(lecteur.travaux.isEmpty)
    }

    func test_finDeVeilleSansAvis_valideLeReleveDuTick() {
        let core = moteurAvecLecteur()
        core.willSleep {}
        horloge.advance(3)
        signaux.inactiviteHID = 0.3
        core.tick()                      // une frappe met fin à la veille annoncée
        XCTAssertTrue(journalContient("fin de la veille sans avis de réveil"), "\(journal.lines)")
        let lecturesApresLeTick = lecteur.lecturesImmediates
        scruter(core, 0.5)
        XCTAssertEqual(lecteur.lecturesImmediates, lecturesApresLeTick, "le tick suivant ne relit pas en bloquant")
        XCTAssertEqual(lecteur.travaux.count, 1)
    }

    func test_sequenceBanc4_ONDansLeLissageApresLesPremiersFaitsAllumes() {
        let core = moteurAvecLecteur()
        core.willSleep {}
        XCTAssertFalse(core.currentState)
        horloge.advance(2)
        signaux.etatEcran.asleep = true
        core.handle(.systemDidWake)      // lecture synchrone : écrans encore endormis
        XCTAssertEqual(verdictDesFaits(core), "display-asleep")
        scruter(core, 0.5)               // relevé gardé : endormi ; une relecture part
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(lecteur.travaux.count, 1)

        // Premiers faits « écrans allumés, session verrouillée », à l'instant t.
        signaux.etatEcran.asleep = false
        signaux.etatSession.locked = true
        let t = horloge.t
        lecteur.relireEtLivrer()
        XCTAssertFalse(core.currentState, "le lissage de 300 ms n'est pas écoulé à t")

        scruter(core, 0.5)               // t + 0,5 s : relevé gardé allumé, la relecture suivante n'est pas revenue
        XCTAssertEqual(horloge.t - t, 0.5)
        XCTAssertLessThanOrEqual((horloge.t - t) * 1000, Double(Config().settleOnMS) + 500)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "lock-screen-ui")
        XCTAssertEqual(lecteur.travaux.count, 1, "ON est parti avant la livraison de la relecture suivante")
    }

    func test_relectureLente_compteeDansSlowCalls() {
        let core = moteurAvecLecteur()
        scruter(core, 0.5)
        signaux.surLectureEcrans = { [horloge] in horloge!.advance(1.5) }
        lecteur.finirLesRelectures()
        let avant = core.statusSnapshot()["slow_calls"] as? [String: [String: Any]] ?? [:]
        XCTAssertNil(avant["ecrans"], "rien n'est compté avant la livraison")
        lecteur.livrer()
        let apres = core.statusSnapshot()["slow_calls"] as? [String: [String: Any]] ?? [:]
        XCTAssertEqual(apres["ecrans"]?["count"] as? Int, 1)
        XCTAssertEqual(apres["ecrans"]?["max_seconds"] as? Double, 1.5)
    }
}
