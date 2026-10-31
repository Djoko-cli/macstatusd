import XCTest
@testable import MacStatusCore

/// Règle de l'économiseur d'écran sous macOS 27, sans économiseur réel ni frappe humaine : les sondes
/// sont des faux signaux, `now` et `hidIdle` sont explicites.
///
/// Mesuré au banc du 31/10 : `SACScreenSaverIsRunning` vaut 1 pendant toute une session d'économiseur,
/// panneau de connexion compris, et 0 hors session, y compris sur un simple verrouillage ; `didstart`
/// arrive au début, `didstop` seulement au déverrouillage ; aucune notification n'accompagne le panneau ;
/// macOS revient à l'économiseur 30 s après la dernière activité.
///
/// Le scénario nominal de macOS 26.5 (process `ScreenSaverEngine`, PID 4242) reste valable avec la source
/// `process` ; une session ne se ferme plus qu'à la deuxième lecture de suite sans source.
final class ScreenSaverOracleTests: XCTestCase {
    private let t0 = 1000.0
    private var signaux: FakeSignals!
    private var journal: CaptureLog!
    private var ancienRecepteur: LogSink?

    override func setUp() {
        super.setUp()
        signaux = FakeSignals()
        journal = CaptureLog()
        ancienRecepteur = CoreLog.sink
        CoreLog.sink = journal
    }

    override func tearDown() {
        CoreLog.sink = ancienRecepteur
        super.tearDown()
    }

    /// Oracle aux valeurs par défaut : grâce de 1,5 s, retour à l'économiseur après 30 s.
    private func nouvelOracle(ecartement: Bool = true) -> ScreenSaverOracle {
        ScreenSaverOracle(dismissOnInput: ecartement, signals: signaux)
    }

    /// Lignes du journal qui contiennent `fragment` (de ce niveau, s'il est donné).
    private func lignes(_ niveau: LogLevel? = nil, contenant fragment: String) -> Int {
        journal.lines.filter { (niveau == nil || $0.0 == niveau) && $0.1.contains(fragment) }.count
    }

    // MARK: - Scénario nominal de macOS 26.5 (source process)

    /// Scénario nominal rejoué jusqu'au démarrage de l'économiseur (PID 4242).
    private func demarrer(_ oracle: ScreenSaverOracle) {
        _ = oracle.verdict(now: t0, hidIdle: 3.0)
        signaux.pidEconomiseur = 4242
        _ = oracle.verdict(now: t0 + 1, hidIdle: 4.0)
    }

    /// Nominal rejoué jusqu'à la frappe qui écarte l'économiseur (t0 + 15).
    private func jusquALaFrappe(_ oracle: ScreenSaverOracle) -> ScreenSaverOracle.Verdict {
        demarrer(oracle)
        _ = oracle.verdict(now: t0 + 10, hidIdle: 13.0)
        return oracle.verdict(now: t0 + 15, hidIdle: 0.2)
    }

    /// Nominal rejoué jusqu'au réaffichage (t0 + 120), puis déverrouillage (t0 + 130) : le process
    /// disparaît, et la deuxième lecture de suite sans lui ferme la session.
    private func jusquAuDeverrouillage(_ oracle: ScreenSaverOracle) -> ScreenSaverOracle.Verdict {
        _ = jusquALaFrappe(oracle)
        _ = oracle.verdict(now: t0 + 20, hidIdle: 1.0)
        _ = oracle.verdict(now: t0 + 120, hidIdle: 95)
        signaux.pidEconomiseur = 0
        XCTAssertTrue(oracle.verdict(now: t0 + 130, hidIdle: 0.1).running, "une lecture sans source ne ferme rien")
        return oracle.verdict(now: t0 + 130.5, hidIdle: 0.6)
    }

    func test_aucunEconomiseur_estInactif() {
        let verdict = nouvelOracle().verdict(now: t0, hidIdle: 3.0)
        XCTAssertFalse(verdict.active)
        XCTAssertFalse(verdict.running)
        XCTAssertEqual(verdict.evidence, "none")
    }

    func test_economiseurDemarre_sansActiviteDepuis_donneOFF() {
        let oracle = nouvelOracle()
        _ = oracle.verdict(now: t0, hidIdle: 3.0)
        signaux.pidEconomiseur = 4242
        let verdict = oracle.verdict(now: t0 + 1, hidIdle: 4.0)
        XCTAssertTrue(verdict.active)
        XCTAssertTrue(verdict.running)
        XCTAssertFalse(verdict.dismissed)
        XCTAssertEqual(verdict.evidence, "process")
    }

    func test_economiseurQuiTourneSeulDepuis10s_resteOFF() {
        let oracle = nouvelOracle()
        demarrer(oracle)
        let verdict = oracle.verdict(now: t0 + 10, hidIdle: 13.0)
        XCTAssertTrue(verdict.active)
    }

    func test_activiteApresDemarrage_ecarteEtDoncON() {
        let verdict = jusquALaFrappe(nouvelOracle())
        XCTAssertFalse(verdict.active)
        XCTAssertTrue(verdict.running)
        XCTAssertTrue(verdict.dismissed)
    }

    func test_activiteApresDemarrage_donneLaPreuveExplicite() {
        let verdict = jusquALaFrappe(nouvelOracle())
        XCTAssertEqual(verdict.evidence, "process+écarté-par-activité")
    }

    func test_saisieDuMotDePasse_resteON() {
        let oracle = nouvelOracle()
        _ = jusquALaFrappe(oracle)
        let verdict = oracle.verdict(now: t0 + 20, hidIdle: 1.0)
        XCTAssertFalse(verdict.active)
    }

    func test_inactiviteProlongee_reaffichageEtRetourOFF() {
        let oracle = nouvelOracle()
        _ = jusquALaFrappe(oracle)
        _ = oracle.verdict(now: t0 + 20, hidIdle: 1.0)
        let verdict = oracle.verdict(now: t0 + 120, hidIdle: 95)
        XCTAssertTrue(verdict.active)
    }

    func test_inactiviteProlongee_donneLaPreuveDeReaffichage() {
        let oracle = nouvelOracle()
        _ = jusquALaFrappe(oracle)
        _ = oracle.verdict(now: t0 + 20, hidIdle: 1.0)
        let verdict = oracle.verdict(now: t0 + 120, hidIdle: 95)
        XCTAssertEqual(verdict.evidence, "process+réaffiché")
    }

    func test_economiseurTermine_estInactif() {
        let verdict = jusquAuDeverrouillage(nouvelOracle())
        XCTAssertFalse(verdict.active)
        XCTAssertFalse(verdict.running)
        XCTAssertEqual(verdict.evidence, "none")
    }

    func test_redemarrageAvecNouveauPID_donneOFFMalgreActiviteRecente() {
        let oracle = nouvelOracle()
        _ = jusquAuDeverrouillage(oracle)
        signaux.pidEconomiseur = 4243
        let verdict = oracle.verdict(now: t0 + 140, hidIdle: 0.1)
        XCTAssertTrue(verdict.active)
    }

    func test_activiteApresRedemarrage_donneON() {
        let oracle = nouvelOracle()
        _ = jusquAuDeverrouillage(oracle)
        signaux.pidEconomiseur = 4243
        _ = oracle.verdict(now: t0 + 140, hidIdle: 0.1)
        let verdict = oracle.verdict(now: t0 + 145, hidIdle: 0.1)
        XCTAssertFalse(verdict.active)
    }

    func test_ecartementDesactive_ignoreLActivite() {
        signaux.pidEconomiseur = 4242
        let verdict = nouvelOracle(ecartement: false).verdict(now: t0, hidIdle: 0.0)
        XCTAssertTrue(verdict.active)
    }

    func test_ecartementDesactive_suitQuandMemeLeProcess() {
        signaux.pidEconomiseur = 4242
        let oracle = nouvelOracle(ecartement: false)
        _ = oracle.verdict(now: t0, hidIdle: 0.0)
        signaux.pidEconomiseur = 0
        _ = oracle.verdict(now: t0 + 1, hidIdle: 0.0)
        let verdict = oracle.verdict(now: t0 + 1.5, hidIdle: 0.0)
        XCTAssertFalse(verdict.active)
        XCTAssertFalse(verdict.running)
    }

    func test_inactiviteIndisponible_neConclutPasALEcartement() {
        signaux.pidEconomiseur = 4242
        let verdict = nouvelOracle().verdict(now: t0, hidIdle: -1)
        XCTAssertTrue(verdict.active)
    }

    func test_inactiviteIndisponible_suitLeProcess() {
        signaux.pidEconomiseur = 4242
        let oracle = nouvelOracle()
        _ = oracle.verdict(now: t0, hidIdle: -1)
        signaux.pidEconomiseur = 0
        _ = oracle.verdict(now: t0 + 1, hidIdle: -1)
        let verdict = oracle.verdict(now: t0 + 1.5, hidIdle: -1)
        XCTAssertFalse(verdict.active)
        XCTAssertFalse(verdict.running)
    }

    // MARK: - Session par SAC et panneau de connexion

    /// Session SAC ouverte à t0, sans activité depuis 5 min : l'économiseur d'inactivité de macOS 27.
    private func sessionSAC(_ oracle: ScreenSaverOracle) {
        signaux.drapeauSAC = true
        let ouverture = oracle.verdict(now: t0, hidIdle: 300)
        XCTAssertTrue(ouverture.active)
        XCTAssertEqual(ouverture.evidence, "sac")
    }

    /// Session SAC, puis une frappe à t0 + 10 : le panneau de connexion recouvre l'économiseur.
    private func panneauSAC(_ oracle: ScreenSaverOracle) {
        sessionSAC(oracle)
        XCTAssertTrue(oracle.verdict(now: t0 + 10, hidIdle: 0).dismissed)
    }

    func test_sacVrai_sansActivite_economiseurSeul() {
        signaux.drapeauSAC = true
        let oracle = nouvelOracle()
        let verdict = oracle.verdict(now: t0, hidIdle: 300)
        XCTAssertTrue(verdict.active)
        XCTAssertTrue(verdict.running)
        XCTAssertFalse(verdict.dismissed)
        XCTAssertEqual(verdict.evidence, "sac")
        let suite = oracle.verdict(now: t0 + 60, hidIdle: 360)
        XCTAssertTrue(suite.active)
        XCTAssertEqual(suite.evidence, "sac")
        XCTAssertEqual(signaux.lecturesHotes, 0, "les hôtes ne se lisent qu'en repli, sans SAC")
    }

    func test_sacVraiPuisFrappe_panneauDoncON() {
        let oracle = nouvelOracle()
        sessionSAC(oracle)
        // Une frappe dans la grâce de 1,5 s qui suit l'ouverture ne compte pas.
        let pendantLaGrace = oracle.verdict(now: t0 + 1, hidIdle: 0)
        XCTAssertTrue(pendantLaGrace.active)
        XCTAssertEqual(pendantLaGrace.evidence, "sac")

        let verdict = oracle.verdict(now: t0 + 10, hidIdle: 0.2)
        XCTAssertFalse(verdict.active)
        XCTAssertTrue(verdict.running)
        XCTAssertTrue(verdict.dismissed)
        XCTAssertEqual(verdict.evidence, "sac+écarté-par-activité")
    }

    func test_panneau_revientALEconomiseurApres30s() {
        let oracle = nouvelOracle()
        panneauSAC(oracle)
        let avant = oracle.verdict(now: t0 + 39.5, hidIdle: 29.5)
        XCTAssertFalse(avant.active)
        XCTAssertTrue(avant.dismissed)
        XCTAssertEqual(avant.evidence, "sac+écarté-par-activité")

        let retour = oracle.verdict(now: t0 + 40, hidIdle: 30)
        XCTAssertTrue(retour.active)
        XCTAssertTrue(retour.running)
        XCTAssertFalse(retour.dismissed)
        XCTAssertEqual(retour.evidence, "sac+réaffiché")

        let ensuite = oracle.verdict(now: t0 + 45, hidIdle: 35)
        XCTAssertTrue(ensuite.active)
        XCTAssertEqual(ensuite.evidence, "sac")
    }

    func test_frappeJusteApresLeRetour_compteSansGrace() {
        let oracle = nouvelOracle()
        panneauSAC(oracle)
        XCTAssertEqual(oracle.verdict(now: t0 + 40, hidIdle: 30).evidence, "sac+réaffiché")
        let verdict = oracle.verdict(now: t0 + 40.5, hidIdle: 0)
        XCTAssertFalse(verdict.active)
        XCTAssertTrue(verdict.dismissed)
        XCTAssertEqual(verdict.evidence, "sac+écarté-par-activité")
    }

    func test_arretNatif_panneauPendant30s() {
        let oracle = nouvelOracle()
        sessionSAC(oracle)
        oracle.noteDismissed(now: t0 + 20)
        let ecarte = oracle.verdict(now: t0 + 20, hidIdle: 320)
        XCTAssertFalse(ecarte.active)
        XCTAssertTrue(ecarte.dismissed)
        XCTAssertEqual(ecarte.evidence, "sac+écarté-par-commande")
        XCTAssertEqual(oracle.verdict(now: t0 + 49.5, hidIdle: 349.5).evidence, "sac+écarté-par-commande")

        let retour = oracle.verdict(now: t0 + 50, hidIdle: 350)
        XCTAssertTrue(retour.active)
        XCTAssertEqual(retour.evidence, "sac+réaffiché")
        XCTAssertEqual(oracle.verdict(now: t0 + 51, hidIdle: 351).evidence, "sac", "arrêt natif oublié au retour")
    }

    /// L'activité la plus récente nomme l'écart et fait courir les 30 s.
    func test_frappeApresLArretNatif_ecarteParActivite() {
        let oracle = nouvelOracle()
        sessionSAC(oracle)
        oracle.noteDismissed(now: t0 + 20)
        XCTAssertEqual(oracle.verdict(now: t0 + 20, hidIdle: 320).evidence, "sac+écarté-par-commande")
        XCTAssertEqual(oracle.verdict(now: t0 + 25, hidIdle: 0).evidence, "sac+écarté-par-activité")
        XCTAssertTrue(oracle.verdict(now: t0 + 54.5, hidIdle: 29.5).dismissed)
        XCTAssertEqual(oracle.verdict(now: t0 + 55, hidIdle: 30).evidence, "sac+réaffiché")

        // Une frappe, puis un arrêt natif : c'est la commande, la plus récente.
        _ = oracle.verdict(now: t0 + 60, hidIdle: 0)
        oracle.noteDismissed(now: t0 + 62)
        XCTAssertEqual(oracle.verdict(now: t0 + 62, hidIdle: 2).evidence, "sac+écarté-par-commande")
    }

    /// L'arrêt natif n'attend pas la grâce de l'ouverture, réservée aux frappes.
    func test_arretNatifJusteApresLOuverture_compteSansGrace() {
        let oracle = nouvelOracle()
        sessionSAC(oracle)
        oracle.noteDismissed(now: t0 + 0.5)
        let verdict = oracle.verdict(now: t0 + 0.5, hidIdle: 300.5)
        XCTAssertTrue(verdict.dismissed)
        XCTAssertEqual(verdict.evidence, "sac+écarté-par-commande")
    }

    func test_arretNatifAvantLaSession_neComptePas() {
        let oracle = nouvelOracle()
        XCTAssertFalse(oracle.verdict(now: t0 - 5, hidIdle: 295).running)
        // Noté juste avant l'ouverture, au même instant : oublié à l'ouverture.
        oracle.noteDismissed(now: t0)
        signaux.drapeauSAC = true
        let verdict = oracle.verdict(now: t0, hidIdle: 300)
        XCTAssertTrue(verdict.active)
        XCTAssertFalse(verdict.dismissed)
        XCTAssertEqual(verdict.evidence, "sac")
        XCTAssertEqual(oracle.verdict(now: t0 + 1, hidIdle: 301).evidence, "sac")
    }

    func test_ecartementDesactive_ignoreFrappeEtArretNatif() {
        signaux.drapeauSAC = true
        let oracle = nouvelOracle(ecartement: false)
        XCTAssertTrue(oracle.verdict(now: t0, hidIdle: 300).active)
        let frappe = oracle.verdict(now: t0 + 10, hidIdle: 0)
        XCTAssertTrue(frappe.active)
        XCTAssertFalse(frappe.dismissed)
        XCTAssertEqual(frappe.evidence, "sac")

        oracle.noteDismissed(now: t0 + 11)
        let commande = oracle.verdict(now: t0 + 11, hidIdle: 1)
        XCTAssertTrue(commande.active)
        XCTAssertEqual(commande.evidence, "sac")
        XCTAssertEqual(oracle.verdict(now: t0 + 60, hidIdle: 50).evidence, "sac", "ni écart ni réaffichage")
    }

    // MARK: - Fermeture de la session

    func test_uneLectureSACAZero_neFermePasLaSession() {
        let oracle = nouvelOracle()
        panneauSAC(oracle)
        signaux.drapeauSAC = false
        let isolee = oracle.verdict(now: t0 + 10.5, hidIdle: 0.5)
        XCTAssertTrue(isolee.running)
        XCTAssertTrue(isolee.dismissed)
        XCTAssertEqual(isolee.evidence, "sac+écarté-par-activité")

        signaux.drapeauSAC = true
        let reprise = oracle.verdict(now: t0 + 11, hidIdle: 1)
        XCTAssertTrue(reprise.dismissed, "la session continue, sans réarmement : la frappe compte toujours")
        XCTAssertEqual(reprise.evidence, "sac+écarté-par-activité")
    }

    func test_deuxLecturesSACAZero_fermentLaSession() {
        let oracle = nouvelOracle()
        sessionSAC(oracle)
        signaux.drapeauSAC = false
        XCTAssertTrue(oracle.verdict(now: t0 + 0.5, hidIdle: 300.5).running)
        let fermee = oracle.verdict(now: t0 + 1, hidIdle: 301)
        XCTAssertFalse(fermee.running)
        XCTAssertFalse(fermee.active)
        XCTAssertFalse(fermee.dismissed)
        XCTAssertEqual(fermee.evidence, "none")

        // Une nouvelle session repart de zéro : l'activité d'avant son ouverture ne l'écarte pas.
        signaux.drapeauSAC = true
        let nouvelle = oracle.verdict(now: t0 + 2, hidIdle: 0.2)
        XCTAssertTrue(nouvelle.active)
        XCTAssertEqual(nouvelle.evidence, "sac")
    }

    func test_didstopSansSource_fermeImmediatement() {
        let oracle = nouvelOracle()
        panneauSAC(oracle)
        signaux.drapeauSAC = false
        oracle.noteDidStop(now: t0 + 20)
        let verdict = oracle.verdict(now: t0 + 20, hidIdle: 0.5)
        XCTAssertFalse(verdict.running)
        XCTAssertFalse(verdict.active)
        XCTAssertEqual(verdict.evidence, "none")
        XCTAssertEqual(lignes(.warn, contenant: "didstop"), 0)
    }

    func test_didstopPendantSACVrai_ignoreEtJournaliseUneFoisParMinute() {
        XCTAssertEqual(ScreenSaverOracle.incoherenceLogInterval, 60)
        let oracle = nouvelOracle()
        sessionSAC(oracle)
        oracle.noteDidStop(now: t0 + 1)
        XCTAssertTrue(oracle.verdict(now: t0 + 1, hidIdle: 301).running)
        XCTAssertEqual(lignes(.warn, contenant: "didstop"), 1)

        oracle.noteDidStop(now: t0 + 11)
        XCTAssertTrue(oracle.verdict(now: t0 + 11, hidIdle: 311).running)
        XCTAssertEqual(lignes(.warn, contenant: "didstop"), 1, "au plus un avertissement par minute")

        // Ignoré, il ne ferme rien plus tard : une lecture SAC isolée à 0 laisse la session ouverte.
        signaux.drapeauSAC = false
        XCTAssertTrue(oracle.verdict(now: t0 + 11.5, hidIdle: 311.5).running)

        signaux.drapeauSAC = true
        oracle.noteDidStop(now: t0 + 61)
        XCTAssertTrue(oracle.verdict(now: t0 + 61, hidIdle: 361).running)
        XCTAssertEqual(lignes(.warn, contenant: "didstop"), 2)
    }

    /// Un didstop sans session est consommé par la lecture qui suit : la session ouverte plus tard n'est
    /// ni « incohérente » ni fermée à sa première lecture isolée sans source.
    func test_didstopOrphelin_neComptePasPourLaSessionSuivante() {
        let oracle = nouvelOracle()
        oracle.noteDidStop(now: t0)
        XCTAssertFalse(oracle.verdict(now: t0, hidIdle: 300).running)
        signaux.drapeauSAC = true
        XCTAssertTrue(oracle.verdict(now: t0 + 60, hidIdle: 360).running)
        signaux.drapeauSAC = false
        XCTAssertTrue(oracle.verdict(now: t0 + 60.5, hidIdle: 360.5).running, "une lecture isolée ne ferme rien")
        XCTAssertEqual(lignes(.warn, contenant: "didstop"), 0)
    }

    // MARK: - Notifications non corroborées ou forgées

    func test_didstartNonCorrobore_expireSansOFF() {
        XCTAssertEqual(ScreenSaverOracle.corroborationWindow, 5)
        let oracle = nouvelOracle()
        oracle.noteDidStart(now: t0)
        for pas in 0...12 {
            let verdict = oracle.verdict(now: t0 + Double(pas) * 0.5, hidIdle: 300)
            XCTAssertFalse(verdict.running, "à t0 + \(Double(pas) * 0.5) s")
            XCTAssertFalse(verdict.active)
        }
        XCTAssertEqual(lignes(contenant: "didstart non corroboré"), 1)
        XCTAssertEqual(signaux.lecturesHotes, 0, "avec SAC, les hôtes ne sont jamais lus")
    }

    func test_paireForgeePendantLaSaisie_resteEcarte() {
        let oracle = nouvelOracle()
        panneauSAC(oracle)
        oracle.noteDidStop(now: t0 + 12)
        oracle.noteDidStart(now: t0 + 12)
        let verdict = oracle.verdict(now: t0 + 12, hidIdle: 0.5)
        XCTAssertFalse(verdict.active)
        XCTAssertTrue(verdict.dismissed)
        XCTAssertEqual(verdict.evidence, "sac+écarté-par-activité")
        XCTAssertTrue(oracle.verdict(now: t0 + 13, hidIdle: 1.5).dismissed, "rien n'est réarmé")
    }

    // MARK: - Repli sans SAC : hôte apparu après didstart

    /// SAC indisponible, `didstart` à t0, hôte lancé à t0 + 0,25 s et vu à t0 + 0,45 s.
    private func sessionHote(_ oracle: ScreenSaverOracle) {
        signaux.drapeauSAC = nil
        oracle.noteDidStart(now: t0)
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 0.2)]
        let ouverture = oracle.verdict(now: t0 + 0.45, hidIdle: 300)
        XCTAssertTrue(ouverture.running)
        XCTAssertEqual(ouverture.evidence, "notification+hôte")
    }

    func test_sansSAC_hoteLanceApresDidstart_ouvreLaSession() {
        signaux.drapeauSAC = nil
        let oracle = nouvelOracle()
        oracle.noteDidStart(now: t0)
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 0.2)]
        let verdict = oracle.verdict(now: t0 + 0.45, hidIdle: 300)
        XCTAssertTrue(verdict.active)
        XCTAssertTrue(verdict.running)
        XCTAssertEqual(verdict.evidence, "notification+hôte")

        // L'hôte vit : la session tient, sans ligne d'expiration.
        let suite = oracle.verdict(now: t0 + 30, hidIdle: 330)
        XCTAssertTrue(suite.active)
        XCTAssertEqual(suite.evidence, "notification+hôte")
        XCTAssertEqual(lignes(contenant: "didstart non corroboré"), 0)
    }

    func test_sansSAC_hoteLanceJusteAvantDidstart_compteDansLaTolerance() {
        XCTAssertEqual(ScreenSaverOracle.hostLaunchTolerance, 1)
        signaux.drapeauSAC = nil
        let oracle = nouvelOracle()
        oracle.noteDidStart(now: t0)
        // Lancé 1,2 s avant le didstart : hors tolérance.
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 1.7)]
        XCTAssertFalse(oracle.verdict(now: t0 + 0.5, hidIdle: 300).running)
        // Lancé 0,8 s avant : dans la tolérance.
        signaux.hotes = [SaverHost(pid: 4243, launchedSecondsAgo: 1.8)]
        let verdict = oracle.verdict(now: t0 + 1, hidIdle: 301)
        XCTAssertTrue(verdict.running)
        XCTAssertEqual(verdict.evidence, "notification+hôte")
    }

    func test_sansSAC_hoteAncien_neCorroborePas() {
        signaux.drapeauSAC = nil
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 600)]
        let oracle = nouvelOracle()
        oracle.noteDidStart(now: t0)
        for pas in 0...10 {
            XCTAssertFalse(oracle.verdict(now: t0 + Double(pas) * 0.5, hidIdle: 300).running)
        }
        XCTAssertEqual(lignes(contenant: "didstart non corroboré"), 1)
        let lectures = signaux.lecturesHotes
        XCTAssertGreaterThan(lectures, 0, "hôtes lus pendant l'attente")
        XCTAssertFalse(oracle.verdict(now: t0 + 6, hidIdle: 306).running)
        XCTAssertEqual(signaux.lecturesHotes, lectures, "attente expirée : les hôtes ne sont plus lus")
    }

    /// L'hôte doit être vu avant t0 + 5 s : à t0 + 5 s, l'attente a expiré.
    func test_sansSAC_hoteVuApres5s_neCorroborePas() {
        signaux.drapeauSAC = nil
        let oracle = nouvelOracle()
        oracle.noteDidStart(now: t0)
        XCTAssertFalse(oracle.verdict(now: t0 + 4.5, hidIdle: 304.5).running)
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 0.2)]
        XCTAssertFalse(oracle.verdict(now: t0 + 5, hidIdle: 305).running, "vu à t0 + 5 s : trop tard")
        XCTAssertEqual(lignes(contenant: "didstart non corroboré"), 1)
    }

    func test_sansSAC_didstopFermeLaSession() {
        let oracle = nouvelOracle()
        sessionHote(oracle)
        oracle.noteDidStop(now: t0 + 20)
        let verdict = oracle.verdict(now: t0 + 20, hidIdle: 0.3)
        XCTAssertFalse(verdict.running, "l'hôte vit encore, mais le didstop met fin à sa preuve")
        XCTAssertEqual(verdict.evidence, "none")
        XCTAssertEqual(lignes(.warn, contenant: "didstop"), 0, "sans SAC, un didstop n'est jamais incohérent")
    }

    func test_sansSAC_hoteDisparu_fermeLaSession() {
        let oracle = nouvelOracle()
        sessionHote(oracle)
        signaux.hotes = []
        XCTAssertTrue(oracle.verdict(now: t0 + 20, hidIdle: 320).running, "une lecture sans source ne ferme rien")
        let verdict = oracle.verdict(now: t0 + 20.5, hidIdle: 320.5)
        XCTAssertFalse(verdict.running)
        XCTAssertEqual(verdict.evidence, "none")
    }

    /// Un nouveau didstart, pendant une session, peut retenir un hôte né après lui : la session lui
    /// survit quand le premier hôte disparaît, sans réarmement (la frappe compte toujours).
    func test_sansSAC_nouveauDidstart_retientLeNouvelHote() {
        let oracle = nouvelOracle()
        sessionHote(oracle)
        XCTAssertTrue(oracle.verdict(now: t0 + 10, hidIdle: 0).dismissed)
        oracle.noteDidStart(now: t0 + 12)
        // Le nouvel hôte n'est pas encore lancé : l'ancien, toujours là, ne corrobore pas ce didstart.
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 12.5)]
        XCTAssertTrue(oracle.verdict(now: t0 + 12.5, hidIdle: 2.5).dismissed)
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 13),
                         SaverHost(pid: 4243, launchedSecondsAgo: 0.3)]
        XCTAssertTrue(oracle.verdict(now: t0 + 13, hidIdle: 3).dismissed)
        // Le premier hôte disparaît : deux lectures plus tard, le nouveau tient toujours la session.
        signaux.hotes = [SaverHost(pid: 4243, launchedSecondsAgo: 1.3)]
        XCTAssertTrue(oracle.verdict(now: t0 + 14, hidIdle: 4).running)
        let verdict = oracle.verdict(now: t0 + 14.5, hidIdle: 4.5)
        XCTAssertTrue(verdict.running, "le nouvel hôte tient la session")
        XCTAssertTrue(verdict.dismissed)
        XCTAssertEqual(verdict.evidence, "notification+hôte+écarté-par-activité")
        XCTAssertEqual(lignes(contenant: "didstart non corroboré"), 0)
    }

    /// Un didstop qui suit le didstart avant qu'un hôte soit vu : l'économiseur s'est arrêté, un hôte
    /// resté en vie ne doit plus ouvrir de session.
    func test_sansSAC_didstopAvantLHote_annuleLAttente() {
        signaux.drapeauSAC = nil
        let oracle = nouvelOracle()
        oracle.noteDidStart(now: t0)
        oracle.noteDidStop(now: t0 + 0.3)
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 0.2)]
        XCTAssertFalse(oracle.verdict(now: t0 + 0.5, hidIdle: 300).running)
        XCTAssertFalse(oracle.verdict(now: t0 + 6, hidIdle: 306).running)
        XCTAssertEqual(lignes(contenant: "didstart non corroboré"), 0, "annulée, l'attente n'expire pas")
    }

    // MARK: - Process seul

    func test_processSeul_ouvreLaSession() {
        signaux.pidEconomiseur = 4242
        let verdict = nouvelOracle().verdict(now: t0, hidIdle: 300)
        XCTAssertTrue(verdict.running)
        XCTAssertTrue(verdict.active)
        XCTAssertEqual(verdict.evidence, "process")
    }

    // MARK: - Inactivité illisible, écran éteint, réveil

    func test_inactiviteIndisponible_gardeLEcartement() {
        let oracle = nouvelOracle()
        panneauSAC(oracle)
        for instant in [t0 + 10.5, t0 + 11] {
            let verdict = oracle.verdict(now: instant, hidIdle: -1)
            XCTAssertTrue(verdict.dismissed)
            XCTAssertEqual(verdict.evidence, "sac+écarté-par-activité")
        }
    }

    /// Scénario 7 de F67 : écran éteint, le moteur ne consulte plus l'oracle ; il se rallume sans frappe.
    func test_ecranRallumeSansFrappe_economiseurSeul() {
        let oracle = nouvelOracle()
        panneauSAC(oracle)
        let verdict = oracle.verdict(now: t0 + 610, hidIdle: 600)
        XCTAssertTrue(verdict.active)
        XCTAssertTrue(verdict.running)
        XCTAssertFalse(verdict.dismissed)
        XCTAssertEqual(verdict.evidence, "sac+réaffiché")
    }

    func test_reveilSysteme_gardeLaSessionSAC() {
        let oracle = nouvelOracle()
        panneauSAC(oracle)
        oracle.noteSystemWake()
        let verdict = oracle.verdict(now: t0 + 12, hidIdle: 2)
        XCTAssertTrue(verdict.running)
        XCTAssertTrue(verdict.dismissed, "sans réarmement : la frappe d'avant compte toujours")
        XCTAssertEqual(verdict.evidence, "sac+écarté-par-activité")
    }

    func test_reveilSysteme_oublieLeDidstartEnAttente() {
        signaux.drapeauSAC = nil
        let oracle = nouvelOracle()
        oracle.noteDidStart(now: t0)
        oracle.noteSystemWake()
        signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 0.2)]
        XCTAssertFalse(oracle.verdict(now: t0 + 0.45, hidIdle: 300).running)
        XCTAssertFalse(oracle.verdict(now: t0 + 6, hidIdle: 306).running)
        XCTAssertEqual(signaux.lecturesHotes, 0, "aucune attente : les hôtes ne sont pas lus")
        XCTAssertEqual(lignes(contenant: "didstart non corroboré"), 0, "oubliée, l'attente n'expire pas")
    }
}
