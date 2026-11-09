import XCTest
@testable import MacStatusCore

/// Tests du moteur d'état pour l'économiseur d'écran (plan 3 et banc 2) : indices de scan, oracle,
/// veille, écrans. Même fixture que `EngineCoreTests`, héritée de `EngineCoreTestCase`.
final class EngineCoreSaverTests: EngineCoreTestCase {

    // MARK: - Indices de scan des process d'économiseur (plan 3, tâche 1)

    /// Ruling R55 : l'événement donne son indice une seule fois, AVANT que le moteur relise les faits.
    /// Sinon la relecture qu'il déclenche pourrait ne pas chercher le process tout neuf.
    private func verifierUnIndiceAvantLaRelecture(_ evenement: SystemEvent,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        let core = moteur()
        core.start()
        XCTAssertEqual(signaux.indicesProcess, 0, "aucun indice au démarrage", file: file, line: line)
        let lecturesAvant = signaux.lecturesPID

        core.handle(evenement)

        XCTAssertEqual(signaux.indicesProcess, 1, file: file, line: line)
        XCTAssertEqual(signaux.lecturesPIDAuxIndices, [lecturesAvant],
                       "l'indice précède la relecture des faits", file: file, line: line)
        XCTAssertGreaterThan(signaux.lecturesPID, lecturesAvant, "la relecture a bien lieu", file: file, line: line)
    }

    func test_didstart_demandeUnScanDesProcess() {
        verifierUnIndiceAvantLaRelecture(.screenSaverDidStart)
    }

    func test_didstop_demandeUnScanDesProcess() {
        verifierUnIndiceAvantLaRelecture(.screenSaverDidStop)
    }

    func test_processEconomiseurChange_demandeUnScanDesProcess() {
        verifierUnIndiceAvantLaRelecture(.saverProcessChanged)
    }

    /// Un indice par scrutation annulerait la politique de balayage (un scan toutes les 5 s) : ni la
    /// scrutation ordinaire ni les autres événements n'en donnent.
    func test_scrutationEtAutresEvenements_neDonnentAucunIndice() {
        let core = moteur()
        core.start()
        for _ in 0..<4 { scruter(core, 0.5) }
        let autres: [SystemEvent] = [.systemWillNotSleep, .screensDidSleep, .screensDidWake, .screenLocked,
                                     .screenUnlocked, .sessionActive, .sessionInactive, .systemDidWake]
        for evenement in autres { core.handle(evenement) }
        core.resync()
        XCTAssertEqual(signaux.indicesProcess, 0)
        XCTAssertGreaterThan(signaux.lecturesPID, 0, "les faits ont bien été relus")
    }

    /// L'OFF par économiseur lance `ScreenSaverEngine` : la lecture suivante doit le chercher tout de
    /// suite, sans attendre l'échéance du balayage.
    func test_offParEconomiseur_demandeUnScanDesProcess() {
        let core = moteur()
        core.start()
        XCTAssertEqual(signaux.indicesProcess, 0)

        core.requestOff(peer: "essai")

        XCTAssertEqual(actions.appels, [.runOff(.screensaver)])
        XCTAssertEqual(signaux.indicesProcess, 1)
    }

    /// Une extinction de l'écran, choisie ou imposée par la session verrouillée, ne lance aucun
    /// économiseur : rien à chercher.
    func test_offParExtinctionDEcran_neDemandePasDeScan() {
        var config = Config()
        config.offAction = .displaySleep
        let configuree = moteur(config)
        configuree.start()
        configuree.requestOff(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.displaySleep)])
        XCTAssertEqual(signaux.indicesProcess, 0)

        signaux = Self.signauxDeBureau()
        signaux.etatSession.locked = true
        actions = FakeActions()
        publieur = FakePublisher()
        let verrouillee = moteur()
        verrouillee.start()
        verrouillee.requestOff(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.displaySleep)], "session verrouillée : extinction de l'écran")
        XCTAssertEqual(signaux.indicesProcess, 0)
    }

    // MARK: - Économiseur sous macOS 27 (plan 3, tâche 2)

    /// F03 : l'économiseur d'inactivité de macOS 27 n'a pas de `ScreenSaverEngine` ; SAC le voit, et OFF
    /// part après le lissage de 800 ms.
    func test_economiseurDInactivite_publieOFF() {
        let core = moteur()
        core.start()
        XCTAssertTrue(core.currentState)

        signaux.drapeauSAC = true
        core.handle(.screenSaverDidStart)
        XCTAssertTrue(core.currentState, "OFF attend le lissage")
        signaux.inactiviteHID += 0.5
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
        signaux.inactiviteHID += 0.5
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "screensaver:sac")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false)])
    }

    /// Point de vigilance 1 : un simple verrouillage (⌃⌘Q) laisse SAC à 0. L'écran de verrouillage est une
    /// UI accessible : ON, jamais `screensaver`, même bien au-delà de 30 s sans activité.
    func test_verrouillageSimple_sansSAC_resteSurLEcranDeVerrouillage() {
        let core = moteur()
        core.start()
        signaux.etatSession.locked = true
        core.handle(.screenLocked)
        for _ in 0..<80 {
            signaux.inactiviteHID += 0.5
            scruter(core, 0.5)
        }
        XCTAssertTrue(core.currentState)
        // La raison publiée reste celle de la dernière transition (ON → ON n'en est pas une) : la raison
        // des faits se lit par `inspect()`.
        let lecture = core.inspect()
        XCTAssertTrue(lecture.state)
        XCTAssertEqual(lecture.reason, "lock-screen-ui")
        XCTAssertEqual(lecture.facts.screenSaverEvidence, "none")
        XCTAssertFalse(lecture.facts.screenSaverRunning)
        XCTAssertFalse(publieur.publications.contains { !$0.etat }, "aucun OFF")
    }

    /// Réveil du Mac pendant une session d'économiseur (SAC toujours à 1) : la session est gardée, l'état
    /// reste OFF, sans passer par ON.
    func test_reveilAvecSessionSAC_resteOFF() {
        let core = moteur()
        core.start()
        signaux.drapeauSAC = true
        core.handle(.screenSaverDidStart)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)

        core.willSleep {}
        horloge.advance(60)
        signaux.inactiviteHID += 60
        core.handle(.systemDidWake)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "screensaver:sac")
        for _ in 0..<10 {
            signaux.inactiviteHID += 0.5
            scruter(core, 0.5)
        }
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "screensaver:sac")
        XCTAssertFalse(publieur.publications.dropFirst().contains { $0.etat }, "aucun ON après l'état initial")
    }

    /// R82 (banc 2, B6) : `HIDIdleTime` ne compte pas la veille. Après une veille de 49 s sans frappe, l'oracle
    /// ne doit pas dater la dernière frappe comme récente : l'économiseur reste seul à l'écran, OFF.
    func test_veilleSansFrappe_neFaitPasCroireAUneActiviteRecente() {
        let core = moteur()
        core.start()
        // Économiseur lancé à la main, 5 s après la dernière frappe : cette frappe précède la session.
        signaux.inactiviteHID = 5
        signaux.drapeauSAC = true
        core.handle(.screenSaverDidStart)
        scruterSansActivite(core, 0.5)
        scruterSansActivite(core, 0.5)
        XCTAssertFalse(core.currentState)

        core.willSleep {}
        horloge.dormir(49)
        core.handle(.systemDidWake)
        for _ in 0..<10 {
            scruterSansActivite(core, 0.5)
        }
        XCTAssertFalse(core.currentState)
        let lecture = core.inspect()
        XCTAssertEqual(lecture.facts.screenSaverEvidence, "sac")
        XCTAssertFalse(lecture.facts.screenSaverDismissed, "la frappe d'avant la veille reste ancienne")
        XCTAssertFalse(publieur.publications.dropFirst().contains { $0.etat }, "aucun ON après l'état initial")
    }

    /// Témoin de R82 : une vraie frappe après le réveil écarte toujours l'économiseur.
    func test_veilleAvecFrappeApresLeReveil_ecarteLEconomiseur() {
        let core = moteur()
        core.start()
        // Économiseur lancé à la main, 5 s après la dernière frappe : cette frappe précède la session.
        signaux.inactiviteHID = 5
        signaux.drapeauSAC = true
        core.handle(.screenSaverDidStart)
        scruterSansActivite(core, 0.5)
        scruterSansActivite(core, 0.5)

        core.willSleep {}
        horloge.dormir(49)
        core.handle(.systemDidWake)
        scruterSansActivite(core, 0.5)
        signaux.inactiviteHID = 0.1
        scruter(core, 0.5)
        XCTAssertTrue(core.inspect().facts.screenSaverDismissed)
        XCTAssertEqual(core.inspect().facts.screenSaverEvidence, "sac+écarté-par-activité")
    }

    // MARK: - Horloge hors veille : les trois notifications de l'oracle (banc 2, R87)

    /// Économiseur lancé à la main (SAC à 1), session ouverte, puis une veille réelle de 600 s qui ne bouge que
    /// `monotonic`, réveil traité. Sert aux trois tests qui suivent : l'événement testé arrive APRÈS la veille.
    private func moteurApresUneVeilleSousEconomiseur() -> EngineCore {
        signaux.inactiviteHID = 5
        signaux.drapeauSAC = true
        let core = moteur()
        core.start()
        scruterSansActivite(core, 0.5)
        scruterSansActivite(core, 0.5)
        core.willSleep {}
        horloge.dormir(600)
        core.handle(.systemDidWake)
        scruterSansActivite(core, 0.5)
        return core
    }

    /// R87 : l'arrêt natif est daté sur l'horloge hors veille. Daté en `monotonic` après 600 s de veille, il serait
    /// « postérieur » à tout instant éveillé de la session : le panneau resterait écarté pour toujours au lieu de
    /// laisser revenir l'économiseur après `saver_redisplay_idle_seconds` (30 s) sans activité.
    func test_ecartementApresUneVeille_leLaisseRevenirApresLeDelaiDeReaffichage() {
        let core = moteurApresUneVeilleSousEconomiseur()
        core.requestOn(peer: "essai")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-commande")
        XCTAssertTrue(core.inspect().facts.screenSaverDismissed)

        for _ in 0..<62 { scruterSansActivite(core, 0.5) }   // 31 s éveillé, sans aucune activité
        XCTAssertFalse(core.inspect().facts.screenSaverDismissed, "l'économiseur est revenu : \(journal.lines)")
    }

    /// R87 : le `didstart` est daté sur l'horloge hors veille. Daté en `monotonic` après la veille, son attente
    /// de corroboration (5 s) ne s'écoulerait jamais : l'avertissement « non corroboré » n'arriverait pas.
    func test_didstartApresUneVeille_expireSansCorroboration() {
        signaux.drapeauSAC = nil
        let core = moteur()
        core.start()
        scruterSansActivite(core, 0.5)
        core.willSleep {}
        horloge.dormir(600)
        core.handle(.systemDidWake)
        scruterSansActivite(core, 0.5)

        core.handle(.screenSaverDidStart)
        for _ in 0..<14 { scruterSansActivite(core, 0.5) }   // 7 s éveillé, aucun hôte ni process
        XCTAssertTrue(journalContient("didstart non corroboré"), "\(journal.lines)")
    }

    /// R87 : le `didstop` est daté sur l'horloge hors veille. Daté en `monotonic` après la veille, l'attente de
    /// SAC (2 s) ne s'écoulerait jamais : l'avertissement « didstop incohérent » n'arriverait pas.
    func test_didstopApresUneVeille_sacResteA1_signaleLIncoherence() {
        let core = moteurApresUneVeilleSousEconomiseur()
        core.handle(.screenSaverDidStop)
        for _ in 0..<8 { scruterSansActivite(core, 0.5) }   // 4 s éveillé, SAC reste à 1
        XCTAssertTrue(journalContient("didstop reçu, mais SACScreenSaverIsRunning"), "\(journal.lines)")
    }

    /// Au réveil (avis IOKit, fin de veille sans avis, rattrapages du trou couvert et du réveil perdu), au trou de
    /// scrutation et à la resynchronisation, le moteur fait oublier à l'oracle le `didstart` en attente (repli sans
    /// SAC) : un hôte apparu ensuite n'ouvre pas de session, et l'attente oubliée n'expire pas.
    func test_reveilEtResynchronisation_oublientLeDidstartEnAttente() {
        let declencheurs: [(String, (EngineCore) -> Void)] = [
            ("avis de réveil", { $0.handle(.systemDidWake) }),
        ] + declencheursDeReveil
        for (nom, declencher) in declencheurs {
            journal.lines = []
            signaux = Self.signauxDeBureau()
            signaux.drapeauSAC = nil
            let core = moteur()
            core.start()
            core.handle(.screenSaverDidStart)
            declencher(core)
            XCTAssertFalse(journalContient("didstart non corroboré"), "\(nom) : l'attente oubliée n'expire pas")
            let lectures = signaux.lecturesHotes
            signaux.hotes = [SaverHost(pid: 4242, launchedSecondsAgo: 0.2)]
            for _ in 0..<4 { scruter(core, 0.5) }
            XCTAssertTrue(core.currentState, nom)
            XCTAssertEqual(signaux.lecturesHotes, lectures, "\(nom) : plus d'attente, les hôtes ne sont pas lus")
        }

        signaux = Self.signauxDeBureau()
        signaux.drapeauSAC = nil
        let core = moteur()
        core.start()
        core.handle(.screenSaverDidStart)
        scruter(core, 20)
        XCTAssertTrue(journalContient("interruption de 20.0 s détectée"))
        XCTAssertFalse(journalContient("didstart non corroboré"), "trou de scrutation : attente oubliée")
    }

    /// Point de vigilance 2 : une rafale de notifications ne coûte qu'une relecture des faits par 250 ms ;
    /// la scrutation rattrape le reste. L'indice de scan, lui, part à chaque notification (R55).
    /// Pas de 1/64 s : exacts en binaire, pour que la borne des 250 ms tombe juste.
    func test_rafaleDeNotifications_unRafraichissementPar250ms() {
        XCTAssertEqual(EngineCore.notificationRefreshMinInterval, 0.25)
        let core = moteur()
        core.start()
        let avant = signaux.lecturesSession

        // 10 didstart en 0,16 s.
        for _ in 0..<10 {
            core.handle(.screenSaverDidStart)
            horloge.advance(0.015625)
        }
        XCTAssertEqual(signaux.lecturesSession, avant + 1, "une seule relecture hors scrutation")
        XCTAssertEqual(signaux.indicesProcess, 10, "un indice par notification, avant le filtre")

        // didstop, verrouillage et déverrouillage partagent le même filtre.
        core.handle(.screenSaverDidStop)
        core.handle(.screenLocked)
        core.handle(.screenUnlocked)
        XCTAssertEqual(signaux.lecturesSession, avant + 1)
        XCTAssertEqual(signaux.indicesProcess, 11)

        // 250 ms après la dernière relecture due à une notification, la suivante relit les faits.
        horloge.advance(0.09375)
        core.handle(.screenLocked)
        XCTAssertEqual(signaux.lecturesSession, avant + 2)

        // La scrutation relit toujours, et ne compte pas pour le filtre.
        scruter(core, 0.5)
        XCTAssertEqual(signaux.lecturesSession, avant + 3)
        core.handle(.screenUnlocked)
        XCTAssertEqual(signaux.lecturesSession, avant + 4)
    }

    /// Point de vigilance 3 : sans SAC (macOS futur), un avertissement au démarrage, une seule fois.
    func test_sansSAC_avertissementAuDemarrage() {
        let message = "économiseur : SACScreenSaverIsRunning indisponible → repli sur l'hôte apparu après didstart ; "
            + "les paysages aériens ne seront pas détectés"
        let avecSAC = moteur()
        avecSAC.start()
        XCTAssertFalse(journal.lines.contains { $0.1 == message })

        signaux.drapeauSAC = nil
        let sansSAC = moteur()
        sansSAC.start()
        for _ in 0..<4 { scruter(sansSAC, 0.5) }
        sansSAC.handle(.screenSaverDidStart)
        XCTAssertEqual(journal.lines.filter { $0.0 == .warn && $0.1 == message }.count, 1)
    }

    /// `/status` dit comment l'économiseur est détecté : par SAC, ou par l'hôte apparu après didstart.
    func test_statusDitLaSourceDeDetection() {
        let core = moteur()
        core.start()
        XCTAssertEqual(core.statusSnapshot()["saver_detection"] as? String, "sac")
        signaux.drapeauSAC = true
        XCTAssertEqual(core.statusSnapshot()["saver_detection"] as? String, "sac")
        signaux.drapeauSAC = nil
        XCTAssertEqual(core.statusSnapshot()["saver_detection"] as? String, "hôte")
    }

    // MARK: - Écartement de l'économiseur par la commande du système (plan 3, tâche 3)

    /// C24 : un ON sur un économiseur seul à l'écran le réveille, puis l'écarte par la commande du système.
    /// Le panneau de connexion apparaît par-dessus l'économiseur, qui tourne encore (SAC reste à 1) : l'oracle
    /// compte l'arrêt natif comme une activité, sans grâce, et l'évaluation suivante confirme l'ON.
    func test_onSurEconomiseurSeul_ecarteParLeSystemeEtConfirme() {
        signaux.drapeauSAC = true
        let core = moteur()
        core.start()
        XCTAssertFalse(core.currentState, "économiseur seul à l'écran : OFF")
        XCTAssertEqual(preuveEconomiseur(core), "sac")

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "le réveil d'abord, puis l'écartement")
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "on")
        XCTAssertEqual(actions.appelsReveil, [], "R47 : rien n'est relâché dans l'évaluation du réveil")

        // L'évaluation suivante relit les faits : le panneau recouvre l'économiseur, l'ON est confirmé.
        scruterSansActivite(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("commande on confirmée par les faits en 0.5 s (desktop-ui)"))
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-commande")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "un seul écartement")
    }

    /// Repli sans `SACScreenSaverStopNow` : `killall ScreenSaverEngine` n'écarte rien de l'économiseur
    /// d'inactivité sous macOS 27. Aucun écartement n'est supposé (l'oracle n'est pas prévenu) : la
    /// confirmation attend les faits, ici la fin de la session.
    func test_onSurEconomiseurSeul_repliKillall_attendLesFaits() {
        actions.moyenEcartement = .processKill
        signaux.drapeauSAC = true
        let core = moteur()
        core.start()

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "le repli est lancé aussi")
        for _ in 0..<3 { scruterSansActivite(core, 0.5) }
        XCTAssertNotNil(commandeEnAttente(core), "aucun écartement supposé : l'intention attend les faits")
        XCTAssertEqual(preuveEconomiseur(core), "sac", "l'oracle n'a pas été prévenu d'un arrêt natif")
        XCTAssertTrue(core.currentState, "l'intention ON tient l'état")
        XCTAssertEqual(actions.appelsReveil, [])

        // La session se termine (deux lectures sans source de suite) : les faits confirment l'ON.
        signaux.drapeauSAC = false
        scruterSansActivite(core, 0.5)
        XCTAssertNotNil(commandeEnAttente(core), "une lecture sans source ne ferme pas la session")
        scruterSansActivite(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("commande on confirmée par les faits"))
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])
    }

    /// `stop_screensaver_on_wake` à faux : un ON réveille sans jamais écarter l'économiseur, ni à la commande
    /// ni à l'escalade (nouvelle tentative de réveil, comme avant).
    func test_onAvecStopDesactive_nEcartePas() {
        var config = Config()
        config.stopScreensaverOnWake = false
        signaux.drapeauSAC = true
        let core = moteur(config)
        core.start()

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        for _ in 0..<5 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(actions.appels, [.wake, .wake], "2,5 s : l'escalade renouvelle le réveil, sans écarter")
        XCTAssertTrue(journalContient("escalade: nouvelle tentative de réveil"))
        XCTAssertEqual(preuveEconomiseur(core), "sac")
        XCTAssertNotNil(commandeEnAttente(core))
    }

    /// Même option à faux, sur un Mac déjà ON dont l'économiseur tourne (R30) : le réveil seul.
    func test_onSurMacDejaON_stopDesactive_reveilSansEcartement() {
        var config = Config()
        config.stopScreensaverOnWake = false
        let core = moteur(config)
        mettreLePanneauSurUnEconomiseurSAC(core)

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertTrue(journalContient("économiseur en marche"))
    }

    /// Bureau, économiseur SAC, puis une frappe 2 s plus tard : le panneau recouvre l'économiseur, qui tourne
    /// encore. 20 s sans activité plus tard, l'oracle suppose encore le panneau visible (ON), alors que
    /// macOS a pu revenir à l'économiseur (R30). La dernière frappe date de `T0 + 2 s`, T0 étant l'instant
    /// du démarrage ; l'horloge est à `T0 + 22 s` au retour.
    private func mettreLePanneauSurUnEconomiseurSAC(_ core: EngineCore) {
        signaux.drapeauSAC = true
        core.start()
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertFalse(core.currentState)
        signaux.inactiviteHID = 0
        for _ in 0..<40 { scruterSansActivite(core, 0.5) }
        XCTAssertTrue(core.currentState, "le panneau est supposé visible")
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-activité")
        XCTAssertEqual(actions.appels, [])
    }

    /// R30 + C24 : le Mac est déjà ON (l'oracle suppose le panneau visible) mais l'économiseur tourne. /wake
    /// le réveille, sans intention, et l'écarte aussi par la commande du système : si macOS est déjà revenu
    /// à l'économiseur, le panneau reparaît pour 30 s de plus. Le réveil léger (R49) reste pour les cas sans
    /// session d'économiseur.
    func test_onSurMacDejaON_economiseurEnMarche_ecarteAussi() {
        var config = Config()
        config.saverRedisplayIdleSeconds = 30   // le défaut peut changer sans déplacer ce test en silence
        let core = moteur(config)
        mettreLePanneauSurUnEconomiseurSAC(core)

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])
        XCTAssertNil(commandeEnAttente(core), "aucune intention")
        XCTAssertTrue(core.currentState)
        XCTAssertTrue(journalContient("économiseur en marche"))
        XCTAssertFalse(journalContient("réveil léger"))

        // Sans l'arrêt natif, le panneau serait retiré 30 s après la frappe, soit à T0 + 32 s. Il tient 30 s
        // après l'arrêt : à T0 + 33 s, l'état est toujours ON.
        for _ in 0..<22 { scruterSansActivite(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-commande")
        // À T0 + 54 s, 32 s après l'arrêt, macOS est revenu à l'économiseur : OFF, sans nouvelle commande.
        for _ in 0..<42 { scruterSansActivite(core, 0.5) }
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(preuveEconomiseur(core), "sac")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])
    }

    /// R65 m5 : un ON qui remplace un OFF en cours n'écarte l'économiseur que s'il est seul à l'écran
    /// (`screenSaverActive`), pas quand le panneau le recouvre déjà (`screenSaverRunning` seul) : un appel natif de
    /// trop ferait reparaître l'économiseur.
    func test_onRemplacantUnOff_panneauDejaSurLEconomiseur_n_ecartePas() {
        let core = moteur()
        mettreLePanneauSurUnEconomiseurSAC(core)
        core.requestOff(peer: "essai")
        XCTAssertNotNil(commandeEnAttente(core), "un OFF est en cours")
        XCTAssertFalse(core.inspect().facts.screenSaverActive)
        XCTAssertTrue(core.inspect().facts.screenSaverRunning)

        core.requestOn(peer: "essai")
        XCTAssertFalse(actions.appels.contains(.dismissScreenSaver), "\(actions.appels)")
    }

    /// R86 : la transition causée par le retour de l'économiseur le dit dans sa ligne INFO. Le lissage de l'OFF
    /// (800 ms) laisse passer le verdict « réaffiché » : les faits de la ligne ne disent déjà plus que `sac`.
    func test_transitionCauseeParLeRetourDeLEconomiseur_ligneInfoDitReaffiche() {
        var config = Config()
        config.saverRedisplayIdleSeconds = 30   // le défaut peut changer sans déplacer ce test en silence
        let core = moteur(config)
        mettreLePanneauSurUnEconomiseurSAC(core)
        for _ in 0..<70 { scruterSansActivite(core, 0.5) }
        XCTAssertFalse(core.currentState)
        let lignes = journal.lines.filter { $0.0 == .info && $0.1.hasPrefix("état ON → OFF") }
        XCTAssertEqual(lignes.count, 1, "\(journal.lines)")
        XCTAssertTrue(lignes.first?.1.contains("réaffiché") ?? false, "\(lignes)")
    }

    /// Une transition qui n'a rien à voir avec l'économiseur ne parle pas de réaffichage, même après un retour
    /// d'économiseur antérieur et écarté depuis.
    func test_transitionSansRetourDeLEconomiseur_ligneInfoNeDitPasReaffiche() {
        var config = Config()
        config.saverRedisplayIdleSeconds = 30   // le défaut peut changer sans déplacer ce test en silence
        let core = moteur(config)
        mettreLePanneauSurUnEconomiseurSAC(core)
        for _ in 0..<70 { scruterSansActivite(core, 0.5) }   // retour de l'économiseur : OFF
        signaux.inactiviteHID = 0                              // une frappe l'écarte : ON
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertTrue(core.currentState)
        signaux.drapeauSAC = false                             // l'économiseur s'arrête, puis le Mac s'éteint
        core.willSleep {}
        let lignes = journal.lines.filter { $0.0 == .info && $0.1.hasPrefix("état ON → OFF") }
        XCTAssertEqual(lignes.count, 2, "\(journal.lines)")
        XCTAssertFalse(lignes.last?.1.contains("réaffiché") ?? true, "\(lignes)")
    }

    /// L'escalade d'un ON (2,5 s) dont l'économiseur est encore seul à l'écran l'écarte de nouveau, au lieu de
    /// renouveler le réveil. Ici le premier écartement n'a rien changé (repli `killall`, sans effet sous
    /// macOS 27 sur l'économiseur d'inactivité).
    func test_escaladeOn_economiseurEncoreSeul_ecarteEncore() {
        actions.moyenEcartement = .processKill
        signaux.drapeauSAC = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])

        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "2,0 s : pas d'escalade")

        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver, .dismissScreenSaver], "2,5 s : écarté de nouveau")
        XCTAssertEqual(commandeEnAttente(core)?["escalated"] as? Bool, true)
        XCTAssertTrue(journalContient("escalade: écartement de l'économiseur"), "\(journal.lines)")

        // Une seule escalade.
        for _ in 0..<10 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver, .dismissScreenSaver])
    }

    /// Écran éteint sous une session d'économiseur : au moment du ON, les faits ne voient pas l'économiseur
    /// (écran éteint : non évalué), donc rien n'est écarté. L'écran se rallume sur l'économiseur, seul à
    /// l'écran : l'escalade l'écarte par la commande du système, et l'évaluation suivante confirme l'ON.
    func test_escaladeOn_ecranRallumeSurEconomiseur_ecarteParLeSysteme() {
        signaux.drapeauSAC = true
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake], "écran éteint : l'économiseur n'est pas évalué, rien à écarter")

        signaux.etatEcran.asleep = false
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(preuveEconomiseur(core), "sac", "l'écran est rallumé sur l'économiseur")
        XCTAssertNotNil(commandeEnAttente(core))
        XCTAssertEqual(actions.appels, [.wake], "2,0 s : pas d'escalade")

        scruterSansActivite(core, 0.5)
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver], "2,5 s : l'escalade écarte l'économiseur")
        scruterSansActivite(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(preuveEconomiseur(core), "sac+écarté-par-commande")
        XCTAssertTrue(core.currentState)
    }

    /// R52 : un /wake sur un Mac déjà ON pose un réveil léger (jamais relâché dans la même évaluation). Un
    /// OFF qui arrive avant l'évaluation suivante le relâche, puis lance l'économiseur : l'assertion et son
    /// `caffeinate` ne survivent pas à l'OFF.
    func test_reveilLegerPuisOFF_relacheEtExecuteLOFF() {
        let core = moteur()
        core.start()

        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake])
        XCTAssertEqual(actions.appelsReveil, [], "le réveil léger tient jusqu'à l'évaluation suivante")

        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appelsReveil, [.releaseWake], "l'OFF relâche le réveil léger")
        XCTAssertEqual(actions.appels, [.wake, .runOff(.screensaver)], "puis exécute l'OFF")
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/screensaver")
        XCTAssertFalse(core.currentState)
        XCTAssertTrue(journalContient("assertion de réveil relâchée (commande OFF)"))

        // L'évaluation suivante ne relâche rien de plus.
        scruter(core, 0.5)
        XCTAssertEqual(actions.appelsReveil, [.releaseWake])
    }

    /// Le moyen d'écartement est journalisé une fois, au démarrage : INFO s'il est natif, WARN pour le repli.
    func test_demarrage_journaliseLeMoyenDEcartement() {
        let natif = moteur()
        natif.start()
        for _ in 0..<3 { scruter(natif, 0.5) }
        XCTAssertEqual(journal.lines.filter { $0.0 == .info && $0.1.contains("SACScreenSaverStopNow") }.count, 1)
        XCTAssertFalse(journal.lines.contains { $0.0 == .warn && $0.1.contains("SACScreenSaverStopNow") })

        journal.lines = []
        actions.moyenEcartement = .processKill
        let repli = moteur()
        repli.start()
        for _ in 0..<3 { scruter(repli, 0.5) }
        let avertissement = "SACScreenSaverStopNow indisponible → repli killall ScreenSaverEngine, "
            + "sans effet sous macOS 27 sur l'économiseur d'inactivité"
        XCTAssertEqual(journal.lines.filter { $0.0 == .warn && $0.1 == avertissement }.count, 1)
        XCTAssertFalse(journal.lines.contains { $0.0 == .info && $0.1.contains("SACScreenSaverStopNow") })
    }

    /// R65 m4 : avec `stop_screensaver_on_wake` à faux, le journal de démarrage ne laisse pas croire qu'un ON
    /// écartera l'économiseur, et le repli n'émet aucun avertissement.
    func test_demarrage_stopDesactive_dit_desactive_sansAvertissement() {
        var config = Config()
        config.stopScreensaverOnWake = false
        for moyen in [ScreenSaverDismissal.native, .processKill] {
            journal.lines = []
            actions.moyenEcartement = moyen
            moteur(config).start()
            let lignes = journal.lines.filter { $0.1.contains("écartement") }
            XCTAssertEqual(lignes.count, 1, "\(moyen) : \(journal.lines)")
            XCTAssertEqual(lignes.first?.0, .info, "\(moyen)")
            XCTAssertTrue(lignes.first?.1.contains("désactivé par stop_screensaver_on_wake") ?? false, "\(moyen)")
            XCTAssertFalse(journal.lines.contains { $0.0 == .warn && $0.1.contains("SACScreenSaverStopNow") })
        }
    }

    /// R65 m8 : la ligne « écartement demandé » part avant l'appel du système (un journal écrit après dirait
    /// faux si le process tombait dedans).
    func test_ecartement_journaliseAvantLAppel() {
        var journalAvantAppel: Bool?
        actions.surDismiss = { [self] in journalAvantAppel = journalContient("écartement demandé") }
        signaux.drapeauSAC = true
        let core = moteur()
        core.start()
        core.requestOn(peer: "essai")
        XCTAssertEqual(actions.appels, [.wake, .dismissScreenSaver])
        XCTAssertEqual(journalAvantAppel, true, "la ligne doit déjà être écrite à l'instant de l'appel")
    }

    /// `/status` dit par quel moyen l'économiseur est écarté : la commande du système, ou le repli.
    func test_statusDitLeMoyenDEcartement() {
        let natif = moteur()
        natif.start()
        XCTAssertEqual(natif.statusSnapshot()["saver_dismissal"] as? String, "SACScreenSaverStopNow")

        actions.moyenEcartement = .processKill
        let repli = moteur()
        repli.start()
        XCTAssertEqual(repli.statusSnapshot()["saver_dismissal"] as? String, "killall ScreenSaverEngine")
    }

    /// R84 : le moyen de démarrage de l'économiseur (OFF) est annoncé au démarrage et publié dans `/status`.
    func test_demarrage_annonceLeMoyenDeDemarrage_natif() {
        actions.screenSaverStart = .native
        let core = moteur()
        core.start()
        let annonce = "économiseur : moyen de démarrage SACScreenSaverStartNow (commande du système)"
        XCTAssertEqual(journal.lines.filter { $0.0 == .info && $0.1 == annonce }.count, 1)
        XCTAssertFalse(journal.lines.contains { $0.0 == .warn && $0.1.contains("SACScreenSaverStartNow") })
        XCTAssertEqual(core.statusSnapshot()["saver_start"] as? String, "SACScreenSaverStartNow")
    }

    func test_demarrage_sansStartNow_annonceLeRepli() {
        actions.screenSaverStart = .openApp
        let core = moteur()
        core.start()
        let avertissement = "SACScreenSaverStartNow indisponible → repli open -a ScreenSaverEngine"
        XCTAssertEqual(journal.lines.filter { $0.0 == .warn && $0.1 == avertissement }.count, 1)
        XCTAssertFalse(journal.lines.contains { $0.0 == .info && $0.1.contains("SACScreenSaverStartNow") })
        XCTAssertEqual(core.statusSnapshot()["saver_start"] as? String, "open -a ScreenSaverEngine")
    }

    // MARK: - Écrans : fantôme, extinction, topologie (plan 3, tâche 4)

    /// Instantané d'une énumération réussie.
    private func lister(_ ecrans: DisplayInfo...) -> DisplaySnapshot {
        DisplaySnapshot(displays: ecrans, enumerationOK: true)
    }

    /// Lignes INFO de topologie du journal.
    private func lignesEcrans() -> [String] {
        journal.lines.filter { $0.0 == .info && $0.1.hasPrefix("écrans :") }.map { $0.1 }
    }

    /// Un virtuel principal (fournisseur `0x4321`, que rien ne distingue d'un écran physique) qui reste éveillé
    /// quand l'écran physique s'endort.
    private var virtuelPrincipal: DisplayInfo {
        DisplayInfo(id: 1, vendor: 0x4321, model: 0x5678, asleep: false, isMain: true)
    }

    /// Point de vigilance 5 : au réveil capot fermé ou dock débranché, macOS ne montre plus que l'écran fantôme.
    /// L'état publié tient 5 s (`displays-reconfiguring`) : les écrans physiques reviennent d'eux-mêmes. Passé ce
    /// délai, plus aucun écran n'est là : `no-display`, publié après le lissage de 800 ms.
    func test_ecranFantomeSeul_tient5sPuisNoDisplay() {
        XCTAssertEqual(EngineCore.noDisplayHoldSeconds, 5)
        let core = moteur()
        core.start()
        XCTAssertTrue(core.currentState)

        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(core, 0.5)  // première lecture sans écran physique : le délai démarre
        let premiere = core.inspect()
        XCTAssertEqual(premiere.reason, "displays-reconfiguring")
        XCTAssertEqual(premiere.facts.onlineDisplays, 0)
        XCTAssertTrue(premiere.facts.displayEnumerationOK)
        XCTAssertEqual(core.statusSnapshot()["facts_verdict"] as? String, "1", "le verdict des faits tient l'ON")

        for _ in 0..<9 { scruter(core, 0.5) }  // 4,5 s après la première lecture
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false)], "rien n'est publié")

        scruter(core, 0.5)  // 5,0 s : le délai est écoulé, le lissage de l'OFF commence
        XCTAssertEqual(core.inspect().reason, "no-display")
        XCTAssertEqual(core.statusSnapshot()["facts_verdict"] as? String, "0")
        XCTAssertTrue(core.currentState, "OFF attend le lissage de 800 ms")
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "no-display")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false)])
    }

    /// Les écrans physiques reviennent avant la fin du délai : l'état publié n'a jamais bougé, aucun OFF.
    func test_ecranFantomeSeul_ecransPhysiquesDeRetourAvant5s_aucunOFF() {
        let core = moteur()
        core.start()
        signaux.ecrans = lister(.fantome(9, main: true))
        for _ in 0..<8 { scruter(core, 0.5) }  // 3,5 s après la première lecture
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")

        signaux.ecrans = lister(.physique(1, main: true), .fantome(9))
        for _ in 0..<20 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.inspect().reason, "desktop-ui")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false)])

        // Le délai est remis à zéro : un nouveau fantôme seul repart de 5 s.
        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(core, 0.5)
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")
    }

    /// Le Mac se réveille sur le fantôme seul : l'OFF de la veille tient (`displays-reconfiguring`) jusqu'au
    /// retour des écrans physiques, qui ramènent l'ON. Jamais d'ON sur le fantôme.
    func test_ecranFantomeAuReveil_resteOFFJusquAuxEcransPhysiques() {
        let core = moteur()
        core.start()
        core.willSleep {}
        XCTAssertFalse(core.currentState, "OFF de veille")

        horloge.advance(1)
        signaux.ecrans = lister(.fantome(9, main: true))
        core.handle(.systemDidWake)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")
        for _ in 0..<8 { scruter(core, 0.5) }  // 4 s sur le fantôme seul
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")
        XCTAssertEqual(publieur.publications.filter(\.etat).count, 1, "aucun ON depuis l'état initial")

        // Les écrans physiques reviennent : ON après le lissage de 300 ms.
        signaux.ecrans = lister(.physique(1, main: true), .physique(2), .fantome(9))
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publieur.publications.last, Publication(etat: true, force: false))
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "desktop-ui")
    }

    /// Point de vigilance 5, second volet : le fantôme est l'écran principal et reste éveillé, mais les écrans
    /// physiques s'éteignent : `display-asleep`.
    func test_fantomePrincipal_ecransPhysiquesEteints_moteurDitDisplayAsleep() {
        signaux.ecrans = lister(.fantome(9, main: true), .physique(1), .physique(2))
        let core = moteur()
        core.start()
        XCTAssertTrue(core.currentState)

        signaux.ecrans = lister(.fantome(9, main: true), .physique(1, asleep: true), .physique(2, asleep: true))
        scruter(core, 0.5)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "display-asleep")
        XCTAssertEqual(core.inspect().facts.displayEvidence, "all")
        XCTAssertTrue(journalContient("display_off=1(all)"), "les faits journalisés donnent la preuve")
    }

    /// L'avis `screensDidSleep` départage un virtuel resté éveillé : tant qu'un écran physique dort, l'affichage
    /// est éteint. Dès que plus aucun écran physique ne dort, l'avis est effacé : s'il se rendort sans nouvel
    /// avis, rien ne le retient plus.
    func test_avisEcransEteints_effaceQuandUnEcranSeReveille() {
        signaux.ecrans = lister(virtuelPrincipal, .physique(2))
        let core = moteur()
        core.start()
        XCTAssertTrue(core.currentState)

        // L'écran physique s'endort, sans avis : le virtuel principal éveillé garde l'état ON.
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "awake")

        // L'avis du système départage : écran éteint, OFF après le lissage.
        core.handle(.screensDidSleep)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep")
        XCTAssertTrue(core.inspect().facts.displayAsleep)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "display-asleep")

        // Plus aucun écran physique endormi : l'avis est effacé, l'ON revient.
        signaux.ecrans = lister(virtuelPrincipal, .physique(2))
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)

        // Il se rendort sans nouvel avis : l'ancien avis ne revient pas.
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        for _ in 0..<4 { scruter(core, 0.5) }
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "awake")
    }

    /// L'avis s'efface aussi sur le réveil des écrans et sur le réveil du système (avis IOKit, fin de veille sans
    /// avis, ou l'un des deux rattrapages de `tick()` : trou couvert par la veille, réveil perdu), même si un écran
    /// physique dort encore : l'avis dit alors une chose périmée. La resynchronisation, elle, le garde (M6).
    func test_avisEcransEteints_effaceParLesReveils() {
        let effaceurs: [(String, (EngineCore) -> Void)] = [
            ("réveil des écrans", { $0.handle(.screensDidWake) }),
            ("réveil du système", { $0.handle(.systemDidWake) }),
        ] + declencheursDeReveil
        for (nom, effacer) in effaceurs {
            signaux = Self.signauxDeBureau()
            signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
            let core = moteur()
            core.start()
            XCTAssertEqual(core.inspect().facts.displayEvidence, "awake", nom)
            core.handle(.screensDidSleep)
            XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep", nom)

            effacer(core)
            XCTAssertEqual(core.inspect().facts.displayEvidence, "awake", "\(nom) : l'avis est effacé")
        }
    }

    /// M6 (R75) : `/resync` ne relit que les faits, il n'est pas un réveil. L'avis d'extinction (écrans physiques
    /// éteints, virtuel principal éveillé) survit : l'OFF `display-asleep` tient, et aucun ON n'est publié de force.
    func test_resync_gardeLAvisDExtinction_avecEcranVirtuelEveille() {
        signaux.ecrans = lister(virtuelPrincipal, .physique(2))
        let core = moteur()
        core.start()
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        core.handle(.screensDidSleep)
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "display-asleep")

        core.resync()
        XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep", "l'avis a survécu à /resync")
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "display-asleep")
        XCTAssertEqual(publieur.publications.filter { $0.force && $0.etat }.count, 0, "\(publieur.publications)")
    }

    /// Une énumération qui échoue ne prouve rien (décision 2 de la tâche 4) : elle n'efface pas l'avis
    /// `screensDidSleep`. Sinon une seule lecture ratée ferait croire qu'aucun écran physique ne dort, et le virtuel
    /// resté éveillé retiendrait de nouveau l'état ON, l'écran physique étant toujours éteint.
    func test_enumerationRatee_neEffacePasLAvisDEcransEteints() {
        signaux.ecrans = lister(virtuelPrincipal, .physique(2))
        let core = moteur()
        core.start()
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        core.handle(.screensDidSleep)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep")

        // L'énumération échoue : liste vide, rien n'est prouvé, l'avis reste.
        signaux.ecrans = DisplaySnapshot(displays: [], enumerationOK: false)
        scruter(core, 0.5)
        XCTAssertFalse(core.inspect().facts.displayEnumerationOK)

        // Elle revient : le physique dort toujours, le virtuel principal est éveillé, l'avis tient encore.
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep", "l'avis a survécu à l'échec")
        for _ in 0..<3 { scruter(core, 0.5) }
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "display-asleep")

        // Il s'efface toujours, par ses voies ordinaires : plus aucun écran physique endormi.
        signaux.ecrans = lister(virtuelPrincipal, .physique(2))
        scruter(core, 0.5)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "awake")
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        XCTAssertEqual(core.inspect().facts.displayEvidence, "awake", "l'ancien avis ne revient pas")
    }

    /// Une ligne INFO « écrans : <résumé> » quand l'ensemble des écrans, l'écran principal ou la présence du
    /// fantôme change ; la première lecture est journalisée une fois. Aucune quand un écran s'endort ou se réveille,
    /// quand l'ordre de la liste change seul, ni pendant une énumération qui échoue.
    func test_topologie_journaliseeAuChangement() {
        let core = moteur()
        core.start()
        XCTAssertEqual(lignesEcrans(), ["écrans : 0x1*"], "première lecture, une seule fois")
        for _ in 0..<3 { scruter(core, 0.5) }
        XCTAssertEqual(lignesEcrans().count, 1, "rien ne change : rien n'est journalisé")

        // Un écran s'ajoute.
        signaux.ecrans = lister(.physique(1, main: true), .physique(2))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans(), ["écrans : 0x1*", "écrans : 0x1*,0x2"])

        // Un écran s'endort, puis tous, puis tous se réveillent : aucune ligne.
        signaux.ecrans = lister(.physique(1, main: true), .physique(2, asleep: true))
        scruter(core, 0.5)
        signaux.ecrans = lister(.physique(1, asleep: true, main: true), .physique(2, asleep: true))
        scruter(core, 0.5)
        core.handle(.screensDidSleep)
        signaux.ecrans = lister(.physique(1, main: true), .physique(2))
        core.handle(.screensDidWake)
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().count, 2, "endormir et réveiller ne journalise rien")

        // Le fantôme apparaît.
        signaux.ecrans = lister(.physique(1, main: true), .physique(2), .fantome(9))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x1*,0x2,0x9v")

        // L'écran principal change.
        signaux.ecrans = lister(.physique(1), .physique(2, main: true), .fantome(9))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x1,0x2*,0x9v")
        XCTAssertEqual(lignesEcrans().count, 4)

        // Même ensemble dans un autre ordre : rien.
        signaux.ecrans = lister(.fantome(9), .physique(2, main: true), .physique(1))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().count, 4, "l'ensemble des écrans est comparé, pas l'ordre de la liste")

        // Mêmes identifiants, même principal, mais l'écran 9 n'est plus le fantôme : sa présence change. Puis il
        // le redevient.
        signaux.ecrans = lister(.physique(9), .physique(2, main: true), .physique(1))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x9,0x2*,0x1")
        signaux.ecrans = lister(.fantome(9), .physique(2, main: true), .physique(1))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x9v,0x2*,0x1")
        XCTAssertEqual(lignesEcrans().count, 6)

        // Une énumération ratée ne prouve rien : ni ligne, ni topologie oubliée.
        signaux.ecrans = DisplaySnapshot(displays: [], enumerationOK: false)
        scruter(core, 0.5)
        signaux.ecrans = lister(.fantome(9), .physique(2, main: true), .physique(1))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().count, 6)

        // Le fantôme disparaît.
        signaux.ecrans = lister(.physique(1), .physique(2, main: true))
        scruter(core, 0.5)
        XCTAssertEqual(lignesEcrans().last, "écrans : 0x1,0x2*")
        XCTAssertEqual(lignesEcrans().count, 7)
    }

    /// Une énumération qui échoue ne prouve rien : elle ne démarre pas le délai de 5 s, et ne le remet pas à zéro.
    func test_enumerationRatee_neDemarreNiNeRemetAZeroLeDelaiDesEcrans() {
        let echec = DisplaySnapshot(displays: [], enumerationOK: false)

        // Elle ne le démarre pas : l'état tient (ON, rien n'est prouvé), le délai ne court qu'à la première
        // lecture réussie sans écran physique.
        signaux.ecrans = echec
        let core = moteur()
        core.start()
        for _ in 0..<8 { scruter(core, 0.5) }  // 4 s d'échecs
        XCTAssertEqual(core.inspect().reason, "desktop-ui")
        XCTAssertTrue(core.currentState)
        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(core, 0.5)  // le délai démarre ici
        for _ in 0..<8 { scruter(core, 0.5) }  // 4 s plus tard, 8,5 s après le premier échec
        XCTAssertEqual(core.inspect().reason, "displays-reconfiguring")

        // Elle ne le remet pas à zéro : 5 s après la première lecture sans écran physique, c'est fini.
        signaux = Self.signauxDeBureau()
        let autre = moteur()
        autre.start()
        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(autre, 0.5)  // le délai démarre ici
        for _ in 0..<4 { scruter(autre, 0.5) }  // 2 s plus tard
        signaux.ecrans = echec
        for _ in 0..<3 { scruter(autre, 0.5) }  // 3,5 s plus tard : lectures qui échouent
        XCTAssertEqual(autre.inspect().reason, "desktop-ui", "énumération ratée : rien n'est prouvé")
        signaux.ecrans = lister(.fantome(9, main: true))
        scruter(autre, 0.5)  // 4,0 s
        XCTAssertEqual(autre.inspect().reason, "displays-reconfiguring")
        scruter(autre, 0.5)  // 4,5 s
        XCTAssertEqual(autre.inspect().reason, "displays-reconfiguring")
        scruter(autre, 0.5)  // 5,0 s
        XCTAssertEqual(autre.inspect().reason, "no-display", "le délai a couru pendant l'échec")
    }

    /// `/status` donne la topologie : l'écran principal, la liste des écrans (fantôme compris) et, dans les faits,
    /// la preuve d'extinction, le résumé et le nombre d'écrans physiques.
    func test_statusDonneLaTopologie() {
        signaux.ecrans = lister(.physique(0x5, main: true), .physique(0x2, asleep: true), .fantome(0x9))
        let core = moteur()
        core.start()
        let status = core.statusSnapshot()

        XCTAssertEqual(status["main_display"] as? String, "0x5")
        let liste = status["display_list"] as? [[String: Any]]
        XCTAssertEqual(liste?.count, 3)
        let attendue: [[String: Any]] = [
            ["id": "0x5", "main": true, "asleep": false, "placeholder": false],
            ["id": "0x2", "main": false, "asleep": true, "placeholder": false],
            ["id": "0x9", "main": false, "asleep": false, "placeholder": true],
        ]
        XCTAssertEqual(liste.map { $0 as NSArray }, attendue as NSArray)

        let faits = status["facts"] as? [String: Any]
        XCTAssertEqual(faits?["displays"] as? String, "0x5*,0x2z,0x9v")
        XCTAssertEqual(faits?["display_evidence"] as? String, "awake")
        XCTAssertEqual(faits?["online_displays"] as? Int, 2, "le fantôme n'est pas compté")
        XCTAssertEqual(faits?["display_asleep"] as? Bool, false)

        // Aucun écran principal : « none », comme pour une liste vide.
        signaux.ecrans = lister(.physique(0x2), .fantome(0x9))
        _ = core.inspect()
        XCTAssertEqual(core.statusSnapshot()["main_display"] as? String, "none")
        signaux.ecrans = lister()
        _ = core.inspect()
        let vide = core.statusSnapshot()
        XCTAssertEqual(vide["main_display"] as? String, "none")
        XCTAssertEqual((vide["display_list"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((vide["facts"] as? [String: Any])?["displays"] as? String, "none")
    }

    // MARK: - Veille avortée et réveils sombres (plan 3, tâche 5)

    /// Faits tels que `/status` les publie, sans relire le système.
    private func faitsPublies(_ core: EngineCore) -> [String: Any] {
        core.statusSnapshot()["facts"] as? [String: Any] ?? [:]
    }

    /// `facts.system_asleep` de `/status`.
    private func veilleSignalee(_ core: EngineCore) -> Bool? {
        faitsPublies(core)["system_asleep"] as? Bool
    }

    /// Moteur démarré (ON publié), puis une veille annoncée à l'instant courant, rendu avec le moteur : OFF
    /// `system-asleep`. Le Mac reste éveillé, comme au banc du 31/10 : la scrutation continue de tourner.
    private func moteurEnVeille() -> (core: EngineCore, annonce: Double) {
        let core = moteur()
        core.start()
        core.willSleep {}
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(veilleSignalee(core), true)
        return (core, horloge.t)
    }

    /// La ligne INFO exacte de fin de veille sans avis de réveil, avec sa cause entre parenthèses.
    private func finDeVeilleJournalisee(_ cause: String) -> Bool {
        journal.lines.contains { $0.0 == .info && $0.1 == "fin de la veille sans avis de réveil (\(cause))" }
    }

    /// C26 : la veille annoncée n'aboutit pas, puis une frappe, plus de 2 s après l'annonce, met fin à la veille
    /// sans attendre IOKit. `system_asleep` retombe, une ligne INFO le dit, et ON revient après le lissage de
    /// 300 ms (l'évaluation n'est pas immédiate), sans republication forcée.
    func test_frappeApresLAnnonce_metFinALaVeille() {
        XCTAssertEqual(EngineCore.sleepAbortInputMargin, 2)
        let (core, annonce) = moteurEnVeille()
        for _ in 0..<29 { scruterSansActivite(core, 0.5) }   // 14,5 s sans activité depuis l'annonce
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("fin de la veille"))

        // Une frappe 0,3 s avant la lecture de t + 15 s : à t + 14,7 s.
        signaux.inactiviteHID = 0.3
        scruter(core, 0.5)
        XCTAssertEqual(horloge.t - annonce, 15)
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(finDeVeilleJournalisee("activité 14.7 s après l'annonce"), "\(journal.lines)")
        XCTAssertFalse(core.currentState, "évaluation non immédiate : ON attend le lissage de 300 ms")

        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "desktop-ui")
        XCTAssertEqual(publieur.publications, [Publication(etat: true, force: false),
                                               Publication(etat: false, force: false),
                                               Publication(etat: true, force: false)])
    }

    /// Le clic qui a demandé la veille précède l'annonce, ou la suit de moins de 2 s : il ne l'annule pas.
    func test_frappeAvantLAnnonce_neMetPasFinALaVeille() {
        let (core, _) = moteurEnVeille()
        signaux.inactiviteHID = 1.5
        scruter(core, 1)                // t + 1 s : dernière frappe à t − 0,5 s, avant l'annonce
        XCTAssertEqual(veilleSignalee(core), true)
        signaux.inactiviteHID = 0.2
        scruter(core, 0.5)              // t + 1,5 s : dernière frappe à t + 1,3 s, à moins de 2 s de l'annonce
        XCTAssertEqual(veilleSignalee(core), true)
        for _ in 0..<20 { scruterSansActivite(core, 0.5) }   // la dernière frappe reste à t + 1,3 s
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(core.currentState)
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// La borne de la marge est stricte : une frappe à 2,0 s pile de l'annonce n'y met pas fin, une frappe à 2,5 s si.
    func test_margeDeDeuxSecondes_borneStricte() {
        let (core, _) = moteurEnVeille()
        signaux.inactiviteHID = 0.5
        scruter(core, 2.5)              // t + 2,5 s : dernière frappe à t + 2,0 s exactement
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("fin de la veille"))

        signaux.inactiviteHID = 0.5
        scruter(core, 0.5)              // t + 3 s : dernière frappe à t + 2,5 s
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(finDeVeilleJournalisee("activité 2.5 s après l'annonce"), "\(journal.lines)")
    }

    /// R87 (R68 M3) : `HIDIdleTime` ne compte pas la veille. Clic « Suspendre » (inactivité de 1 s à l'annonce), puis
    /// une vraie veille de 8 s sans frappe : à la première scrutation, avant l'avis IOKit, `now − hidIdle` est
    /// reculé par la veille, mais aucune activité ne suit l'annonce. La veille n'est pas close comme avortée.
    func test_veilleReelleSansFrappe_neMetPasFinALaVeilleAvortee() {
        signaux.inactiviteHID = 1
        let (core, _) = moteurEnVeille()
        horloge.dormir(8)
        signaux.inactiviteHID = 2        // 1 s éveillé depuis le clic : la veille n'est pas comptée
        horloge.advance(1)
        core.tick()
        XCTAssertEqual(veilleSignalee(core), true, "\(journal.lines)")
        XCTAssertFalse(journalContient("fin de la veille"), "\(journal.lines)")
    }

    /// Témoin de R87 : même départ sans veille réelle (les deux horloges avancent ensemble), avec une vraie frappe
    /// 3 s après l'annonce : la veille est close comme avortée, avec le libellé d'avant.
    func test_frappeSansVeilleReelle_metFinALaVeilleAvortee_memeLibelle() {
        signaux.inactiviteHID = 1
        let (core, _) = moteurEnVeille()
        horloge.advance(3)
        signaux.inactiviteHID = 0
        core.tick()
        XCTAssertEqual(veilleSignalee(core), false, "\(journal.lines)")
        XCTAssertTrue(finDeVeilleJournalisee("activité 3.0 s après l'annonce"), "\(journal.lines)")
    }

    /// Une inactivité illisible (−1) ne prouve aucune frappe : elle ne met jamais fin à la veille (sans cette
    /// garde, `now + 1` passerait pour une activité postérieure à l'annonce).
    func test_inactiviteIllisible_neMetPasFinALaVeille() {
        let (core, _) = moteurEnVeille()
        signaux.inactiviteHID = -1
        for _ in 0..<20 { scruter(core, 0.5) }   // 10 s
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(core.currentState)
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// 0 est une inactivité lisible, et la frappe la plus nette (« il tape à l'instant ») : elle met fin à la veille,
    /// là où −1 (illisible) ne prouve rien. Verrouille la borne `≥ 0` de la lecture, que `> 0` laisserait passer.
    func test_inactiviteNulle_estUneFrappe_metFinALaVeille() {
        let (core, annonce) = moteurEnVeille()
        signaux.inactiviteHID = -1
        for _ in 0..<6 { scruter(core, 0.5) }   // 3 s d'inactivité illisible
        XCTAssertEqual(veilleSignalee(core), true)

        signaux.inactiviteHID = 0
        scruter(core, 0.5)                      // t + 3,5 s : la frappe est à l'instant de la lecture
        XCTAssertEqual(horloge.t - annonce, 3.5)
        XCTAssertEqual(veilleSignalee(core), false, "\(journal.lines)")
        XCTAssertTrue(finDeVeilleJournalisee("activité 3.5 s après l'annonce"), "\(journal.lines)")
    }

    /// C26 : une session vue verrouillée depuis l'annonce, puis relue déverrouillée, met fin à la veille — à la
    /// scrutation ou sur l'avis de déverrouillage, que le verrou précède l'annonce ou la suive. L'inactivité HID
    /// continue de croître : aucune frappe n'entre en compte, seule la règle du déverrouillage joue.
    func test_deverrouillageApresLAnnonce_metFinALaVeille() {
        let declencheurs: [(String, (EngineCore) -> Void)] = [
            ("scrutation", { self.scruterSansActivite($0, 0.5) }),
            ("avis de déverrouillage", { core in
                self.horloge.advance(0.5)
                self.signaux.inactiviteHID += 0.5
                core.handle(.screenUnlocked)
            }),
        ]
        for verrouAvantLAnnonce in [true, false] {
            for (nom, deverrouiller) in declencheurs {
                let cas = "\(nom), verrou \(verrouAvantLAnnonce ? "avant" : "après") l'annonce"
                signaux = Self.signauxDeBureau()
                publieur = FakePublisher()
                journal.lines = []
                signaux.etatSession.locked = verrouAvantLAnnonce
                let (core, _) = moteurEnVeille()
                if !verrouAvantLAnnonce {
                    signaux.etatSession.locked = true
                    scruterSansActivite(core, 0.5)   // la session est vue verrouillée après l'annonce
                }
                for _ in 0..<10 { scruterSansActivite(core, 0.5) }   // toujours verrouillée, aucune activité
                XCTAssertEqual(veilleSignalee(core), true, cas)
                XCTAssertFalse(journalContient("fin de la veille"), cas)

                signaux.etatSession.locked = false
                deverrouiller(core)
                XCTAssertEqual(veilleSignalee(core), false, cas)
                XCTAssertTrue(finDeVeilleJournalisee("session déverrouillée"), "\(cas) : \(journal.lines)")
                XCTAssertFalse(core.currentState, "\(cas) : évaluation non immédiate")
                scruterSansActivite(core, 0.5)
                XCTAssertTrue(core.currentState, cas)
                XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "desktop-ui", cas)
                XCTAssertEqual(publicationsForcees, 0, cas)
            }
        }
    }

    /// R85 (banc 3) : la fin d'une veille sans avis relit les faits sans relire les écrans, dont le relevé vient d'être
    /// fait. Chaque lecture des écrans après la première du tick coûte 1,45 s d'horloge d'essai (la relecture du banc
    /// avait tenu la file du moteur pendant le rallumage des écrans externes) : ON, session verrouillée, part au
    /// tick suivant, moins de `settle_on_ms` + un intervalle de scrutation après la première lecture, sans avis IOKit.
    func test_finDeVeilleSansAvis_reutiliseLaLectureDesEcrans_ONDansLeLissage() {
        signaux.etatSession.locked = true
        let (core, _) = moteurEnVeille()
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }   // verrouillée, aucune activité
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(core.currentState)

        var lecturesDuTick = 0
        var finDeLaPremiereLecture = 0.0
        signaux.surLectureEcrans = { [self] in
            lecturesDuTick += 1
            if lecturesDuTick == 1 { finDeLaPremiereLecture = horloge.t } else { horloge.advance(1.45) }
        }
        let avant = signaux.lecturesEcrans
        signaux.inactiviteHID = 0.3          // une frappe, bien plus de 2 s après l'annonce
        scruter(core, 0.5)
        XCTAssertEqual(signaux.lecturesEcrans - avant, 1, "\(journal.lines)")
        XCTAssertEqual(veilleSignalee(core), false, "\(journal.lines)")
        XCTAssertTrue(journalContient("fin de la veille sans avis de réveil (activité"), "\(journal.lines)")
        XCTAssertFalse(core.currentState, "évaluation non immédiate : ON attend le lissage")

        lecturesDuTick = 0
        scruterSansActivite(core, 0.5)
        XCTAssertTrue(core.currentState, "\(journal.lines)")
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "lock-screen-ui")
        XCTAssertLessThanOrEqual(horloge.t - finDeLaPremiereLecture, 0.3 + 0.5 + 0.001,
                                 "ON publié trop tard après la première lecture des écrans")
        XCTAssertFalse(journalContient("IOKit: réveil système"))
        XCTAssertEqual(publicationsForcees, 0)
    }

    /// Même défaut par le chemin du déverrouillage : session vue verrouillée pendant la veille, puis avis de
    /// déverrouillage (`refreshAfterNotification(…, endingAbortedSleep: true)`) : une seule lecture des écrans.
    func test_finDeVeilleParDeverrouillage_reutiliseLaLectureDesEcrans() {
        signaux.etatSession.locked = true
        let (core, _) = moteurEnVeille()
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(veilleSignalee(core), true)

        signaux.etatSession.locked = false
        horloge.advance(0.5)
        signaux.inactiviteHID += 0.5
        let avant = signaux.lecturesEcrans
        core.handle(.screenUnlocked)
        XCTAssertEqual(veilleSignalee(core), false, "\(journal.lines)")
        XCTAssertTrue(finDeVeilleJournalisee("session déverrouillée"), "\(journal.lines)")
        XCTAssertEqual(signaux.lecturesEcrans - avant, 1, "\(journal.lines)")
    }

    /// Un avis de déverrouillage seul ne prouve rien : la session n'a jamais été vue verrouillée depuis l'annonce.
    func test_sessionJamaisVerrouillee_avisDeDeverrouillage_neMetPasFin() {
        let (core, _) = moteurEnVeille()
        horloge.advance(1)
        signaux.inactiviteHID += 1
        core.handle(.screenUnlocked)
        for _ in 0..<10 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(core.currentState)
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// L'indicateur « session vue verrouillée » est remis à zéro à chaque annonce de veille : un verrou vu avant la
    /// seconde annonce (sans réveil entre les deux) ne compte plus.
    func test_nouvelleAnnonce_remetAZeroLaSessionVueVerrouillee() {
        signaux.etatSession.locked = true
        let (core, _) = moteurEnVeille()   // vue verrouillée à la première annonce
        signaux.etatSession.locked = false
        horloge.advance(1)
        signaux.inactiviteHID += 1
        core.willSleep {}                  // seconde annonce : la session est lue déverrouillée
        XCTAssertEqual(veilleSignalee(core), true)

        horloge.advance(1)
        signaux.inactiviteHID += 1
        core.handle(.screenUnlocked)
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// Un avis de déverrouillage écarté par le filtre de 250 ms n'est pas perdu : le tick suivant relit la session
    /// et met fin à la veille.
    func test_avisDeDeverrouillageEcarteParLeFiltre_rattrapeAuTickSuivant() {
        signaux.etatSession.locked = true
        let (core, _) = moteurEnVeille()
        horloge.advance(1)
        signaux.inactiviteHID += 1
        core.handle(.screenLocked)         // première relecture due à une notification : le filtre démarre
        horloge.advance(0.0625)
        signaux.inactiviteHID += 0.0625
        signaux.etatSession.locked = false
        core.handle(.screenUnlocked)       // écarté par le filtre : aucune relecture
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("fin de la veille"))

        scruterSansActivite(core, 0.5)
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(finDeVeilleJournalisee("session déverrouillée"), "\(journal.lines)")
    }

    /// Le trou de scrutation d'une veille réelle passe avant la règle de l'activité : un Mac qui dort 40 s puis
    /// se réveille sur une frappe suit le chemin du trou couvert (une seule publication forcée, veille de plus de
    /// 30 s), non la fin de veille sans avis.
    func test_trouCouvertParUneVeilleLongue_activiteAuReveil_pasDeFinSansAvis() {
        let core = moteurEcranEteint()
        core.willSleep {}
        horloge.advance(40)
        signaux.inactiviteHID = 0.3
        core.tick()
        XCTAssertTrue(journalContient("couverte par la veille"), "\(journal.lines)")
        XCTAssertFalse(journalContient("fin de la veille"), "\(journal.lines)")
        XCTAssertEqual(publicationsForcees, 1, "\(publieur.publications)")
        XCTAssertEqual(veilleSignalee(core), false)
    }

    /// Banc 1 (B6) : une entrée en veille retardée de 29 s ne déclenche aucun rattrapage du « réveil perdu » avant
    /// 120 s. La scrutation tourne sans activité : l'état reste OFF `system-asleep`.
    func test_entreeEnVeilleRetardee_pasDeRattrapageAvant120s() {
        let (core, annonce) = moteurEnVeille()
        for _ in 0..<58 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(horloge.t - annonce, 29)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.statusSnapshot()["reason"] as? String, "system-asleep")
        XCTAssertFalse(journalContient("réveil non signalé"))

        for _ in 0..<182 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(horloge.t - annonce, 120)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(journalContient("réveil non signalé"), "\(journal.lines)")
        XCTAssertFalse(journalContient("fin de la veille"))
    }

    /// Le cas du banc, en entier : l'entrée en veille tarde de 29 s, le Mac dort ensuite 8 s (daemon gelé) et se
    /// réveille 37 s après l'annonce — au-delà de l'ancien seuil de 35 s, mais avec un trou de scrutation de 8 s,
    /// sous le seuil de trou. Rien n'est rattrapé à tort : l'avis de réveil d'IOKit, en retard, est traité
    /// normalement (veille de plus de 30 s : republication forcée).
    func test_entreeEnVeilleRetardee_puisVeilleCourte_avisDeReveilTraiteNormalement() {
        let (core, annonce) = moteurEnVeille()
        for _ in 0..<58 { scruterSansActivite(core, 0.5) }
        horloge.advance(8)
        signaux.inactiviteHID += 8
        core.tick()
        XCTAssertEqual(horloge.t - annonce, 37)
        XCTAssertFalse(journalContient("réveil non signalé"), "\(journal.lines)")
        XCTAssertFalse(journalContient("interruption de"), "un trou de 8 s reste une scrutation normale")
        XCTAssertEqual(veilleSignalee(core), true)
        XCTAssertFalse(core.currentState)

        core.handle(.systemDidWake)
        XCTAssertTrue(journalContient("réveil après 37.0 s de veille → republication forcée"), "\(journal.lines)")
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(core.currentState)
    }

    /// R56 : l'avis IOKit qui arrive après la fin de veille sans avis trouve la fin posée. Il ne force rien, même
    /// après plus de 30 s de veille annoncée, et n'envoie rien de plus.
    func test_avisIOKitApresLaFin_neForcePas() {
        let (core, _) = moteurEnVeille()
        for _ in 0..<64 { scruterSansActivite(core, 0.5) }   // 32 s : un avis normal forcerait la republication
        signaux.inactiviteHID = 0.3
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertTrue(finDeVeilleJournalisee("activité 32.2 s après l'annonce"), "\(journal.lines)")
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publicationsForcees, 0, "\(publieur.publications)")
        let envois = publieur.envois.count

        core.handle(.systemDidWake)
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publicationsForcees, 0, "\(publieur.publications)")
        XCTAssertEqual(publieur.envois.count, envois, "rien de plus n'est envoyé")
        XCTAssertFalse(journalContient("réveil après"), "la fin est déjà posée : la durée n'est plus annoncée")
    }

    /// Réveil sombre (maintenance, Power Nap) : le système se réveille, les écrans restent éteints. L'avis de
    /// réveil laisse l'état OFF (`display-asleep`) : aucun ON n'est publié, ni au réveil ni ensuite, jusqu'au
    /// rallumage des écrans.
    func test_reveilSombre_ecranEteint_resteOFF() {
        let (core, _) = moteurEnVeille()
        horloge.advance(300)
        signaux.inactiviteHID += 300
        signaux.etatEcran.asleep = true
        core.handle(.systemDidWake)
        XCTAssertEqual(veilleSignalee(core), false)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "display-asleep")
        for _ in 0..<20 { scruterSansActivite(core, 0.5) }
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "display-asleep")
        XCTAssertFalse(publieur.publications.dropFirst().contains { $0.etat }, "aucun ON depuis l'état initial")

        // Les écrans se rallument : ON après le lissage de 300 ms.
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState)
    }

    /// Un trou de scrutation qu'aucune veille n'explique (gel, surcharge) n'est pas un réveil : l'avis d'écrans
    /// éteints tient, contrairement à ce que font les trous couverts par une veille et le réveil perdu. Un virtuel
    /// principal éveillé ne ramène donc pas l'ON tant que l'écran physique dort.
    func test_trouNonCouvert_gardeLAvisDEcransEteints() {
        signaux.ecrans = lister(virtuelPrincipal, .physique(2, asleep: true))
        let core = moteur()
        core.start()
        core.handle(.screensDidSleep)
        XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep")

        scruter(core, 15)
        XCTAssertTrue(journalContient("interruption de 15.0 s détectée → resynchronisation"), "\(journal.lines)")
        XCTAssertFalse(journalContient("couverte par la veille"))
        XCTAssertEqual(core.inspect().facts.displayEvidence, "screensDidSleep", "un gel n'est pas un réveil")
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(core.inspect().reason, "display-asleep")
    }

    // MARK: - Coût de la scrutation (plan 3, tâche 6)

    /// F78 : l'inactivité HID ne sert qu'à l'oracle de l'économiseur, que le moteur n'évalue ni pendant une veille ni
    /// écran éteint. Écran éteint, hors veille : aucune lecture, à aucun chemin de relecture des faits, et les faits
    /// gardés disent −1. Dès que l'écran se rallume, l'oracle revient et la lecture avec lui, une fois par relecture.
    func test_ecranEteint_neLitPasLInactivite() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        XCTAssertEqual(signaux.lecturesHID, 0, "le démarrage, écran éteint, ne lit pas l'inactivité")

        for _ in 0..<6 { scruterSansActivite(core, 0.5) }
        core.handle(.sessionActive)
        core.handle(.screensDidSleep)
        core.resync()
        XCTAssertEqual(signaux.lecturesHID, 0, "scrutations, notifications et resynchronisation, écran éteint")
        XCTAssertEqual(core.inspect().facts.hidIdleSeconds, -1, "non lue : −1")
        XCTAssertEqual(signaux.lecturesHID, 0, "`--once` et `--watch` ne la lisent pas non plus")
        XCTAssertEqual(core.inspect().reason, "display-asleep")

        signaux.etatEcran.asleep = false
        core.handle(.screensDidWake)
        XCTAssertEqual(signaux.lecturesHID, 1, "écran rallumé : l'oracle est évalué, l'inactivité est lue")
        scruterSansActivite(core, 0.5)
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(signaux.lecturesHID, 3, "une lecture par scrutation")
        XCTAssertEqual(core.inspect().facts.hidIdleSeconds, signaux.inactiviteHID, accuracy: 0.001)
        XCTAssertEqual(signaux.lecturesHID, 4)
    }

    /// L'écran se rendort après avoir été lu : les faits redisent −1, jamais la dernière valeur lue. (Écran éteint dès
    /// le départ, un −1 périmé ne se distinguerait pas d'un −1 neuf : il faut une valeur lue d'abord.)
    func test_ecranQuiSeRendort_inactiviteRedevientMoinsUn() {
        let core = moteur()
        core.start()
        scruterSansActivite(core, 0.5)
        XCTAssertGreaterThan(core.inspect().facts.hidIdleSeconds, 0, "écran allumé : l'inactivité est lue")
        signaux.etatEcran.asleep = true
        core.handle(.screensDidSleep)
        XCTAssertEqual(core.inspect().facts.hidIdleSeconds, -1, "écran éteint : non lue, pas la valeur d'avant")
    }

    /// Exception de la tâche 5 : pendant une veille en cours, l'inactivité est lue même si l'oracle ne l'est pas
    /// (veille, écran éteint) : la fin d'une veille qui n'aboutit pas en dépend. Une frappe plus de 2 s après
    /// l'annonce y met fin, écran éteint compris ; la veille finie, l'écran toujours éteint, la lecture s'arrête.
    func test_veilleEnCours_litLInactivite() {
        signaux.etatEcran.asleep = true      // l'écran éteint, seul, couperait la lecture
        let (core, annonce) = moteurEnVeille()
        let avant = signaux.lecturesHID
        for _ in 0..<4 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(horloge.t - annonce, 2)
        XCTAssertEqual(signaux.lecturesHID, avant + 4, "une lecture par scrutation pendant la veille en cours")
        XCTAssertEqual(veilleSignalee(core), true)

        signaux.inactiviteHID = 0.3          // une frappe 0,3 s avant la lecture de t + 2,5 s : à t + 2,2 s
        scruter(core, 0.5)
        XCTAssertEqual(veilleSignalee(core), false, "\(journal.lines)")
        XCTAssertTrue(finDeVeilleJournalisee("activité 2.2 s après l'annonce"), "\(journal.lines)")

        let apres = signaux.lecturesHID
        scruterSansActivite(core, 0.5)
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(signaux.lecturesHID, apres, "veille finie, écran toujours éteint : plus de lecture")
    }

    /// `/status` relit l'inactivité à chaque appel : les faits gardés ne la portent plus hors de l'oracle (−1), et
    /// `facts.hid_idle_seconds` ne montre ni le −1 des faits gardés, ni la valeur de la dernière scrutation.
    func test_statusRelitLInactivite() {
        signaux.etatEcran.asleep = true      // les faits gardés disent −1
        let core = moteur()
        core.start()
        scruter(core, 0.5)
        XCTAssertEqual(signaux.lecturesHID, 0)

        signaux.inactiviteHID = 12.5
        XCTAssertEqual(faitsPublies(core)["hid_idle_seconds"] as? Double, 12.5)
        signaux.inactiviteHID = 20
        XCTAssertEqual(faitsPublies(core)["hid_idle_seconds"] as? Double, 20)
        XCTAssertEqual(signaux.lecturesHID, 2, "une lecture par appel")

        signaux.etatEcran.asleep = false     // écran allumé : la valeur de la scrutation précédente est périmée aussi
        scruter(core, 0.5)
        signaux.inactiviteHID = 7
        XCTAssertEqual(faitsPublies(core)["hid_idle_seconds"] as? Double, 7)
        signaux.inactiviteHID = -1           // illisible : −1, comme avant
        XCTAssertEqual(faitsPublies(core)["hid_idle_seconds"] as? Double, -1)
    }

    // MARK: - Observabilité et code mort (plan 3, tâche 7)

    private func raisonPubliee(_ core: EngineCore) -> String? {
        core.statusSnapshot()["reason"] as? String
    }

    /// F71 : « mêmes faits » veut dire tous les faits sauf l'inactivité HID, qui change à chaque lecture sans rien
    /// décider. Chaque autre champ, changé seul, donne d'autres faits. Le décompte par réflexion échoue si un champ
    /// est ajouté à `Facts` sans être traité ici (et dans `sameDecision`).
    func test_faits_memeDecisionMalgreLInactivite() {
        let base = Facts()
        var inactif = base
        inactif.hidIdleSeconds = 42.5
        XCTAssertTrue(base.sameDecision(as: inactif), "l'inactivité seule ne change aucune décision")
        inactif.hidIdleSeconds = -1
        XCTAssertTrue(base.sameDecision(as: inactif), "illisible (−1) non plus")

        let changements: [(champ: String, modifier: (inout Facts) -> Void)] = [
            ("systemAsleep", { $0.systemAsleep.toggle() }),
            ("displayAsleep", { $0.displayAsleep.toggle() }),
            ("onlineDisplays", { $0.onlineDisplays += 1 }),
            ("displayEnumerationOK", { $0.displayEnumerationOK.toggle() }),
            ("displayEvidence", { $0.displayEvidence = "main" }),
            ("displays", { $0.displays = [.physique(1, main: true)] }),
            ("screenSaverActive", { $0.screenSaverActive.toggle() }),
            ("screenSaverEvidence", { $0.screenSaverEvidence = "sac" }),
            ("screenSaverRunning", { $0.screenSaverRunning.toggle() }),
            ("screenSaverDismissed", { $0.screenSaverDismissed.toggle() }),
            ("sessionLocked", { $0.sessionLocked.toggle() }),
            ("lockEvidence", { $0.lockEvidence = "IOConsoleLocked" }),
            ("consoleUserLoggedIn", { $0.consoleUserLoggedIn.toggle() }),
            ("onConsole", { $0.onConsole.toggle() }),
            ("secureInputActive", { $0.secureInputActive.toggle() }),
        ]
        for (champ, modifier) in changements {
            var autre = base
            modifier(&autre)
            XCTAssertFalse(base.sameDecision(as: autre), champ)
            XCTAssertFalse(autre.sameDecision(as: base), "\(champ), sens inverse")
            autre.hidIdleSeconds += 7
            XCTAssertFalse(base.sameDecision(as: autre), "\(champ), l'inactivité en plus ne l'efface pas")
        }
        XCTAssertEqual(changements.count + 1, Mirror(reflecting: base).children.count,
                       "un champ de Facts n'est pas traité ici (l'inactivité est le +1)")

        // La liste des écrans se compare en entier : un écran qui s'endort fait d'autres faits.
        var deux = base
        deux.displays = [.physique(1, main: true), .physique(2)]
        var identiques = base
        identiques.displays = [.physique(1, main: true), .physique(2)]
        XCTAssertTrue(deux.sameDecision(as: identiques))
        identiques.displays = [.physique(1, main: true), .physique(2, asleep: true)]
        XCTAssertFalse(deux.sameDecision(as: identiques))
    }

    /// F71 : l'inactivité change à chaque scrutation, écran allumé. La ligne DEBUG « faits: » ne part plus que
    /// pour un changement qui compte.
    func test_faits_ligneDeDebugSeulementAuChangement() {
        let core = moteur()
        core.start()
        func lignesFaits() -> [String] {
            journal.lines.filter { $0.0 == .debug && $0.1.hasPrefix("faits:") }.map { $0.1 }
        }
        let avant = lignesFaits().count
        XCTAssertGreaterThan(avant, 0, "la première lecture des faits est écrite")

        for _ in 0..<10 { scruterSansActivite(core, 0.5) }
        XCTAssertEqual(core.inspect().facts.hidIdleSeconds, 35, accuracy: 0.001, "l'inactivité a bien grandi de 5 s")
        XCTAssertEqual(lignesFaits().count, avant, "dix scrutations où seule l'inactivité change : aucune ligne")

        signaux.etatSession.locked = true
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(lignesFaits().count, avant + 1, "un vrai changement s'écrit, lui")
        XCTAssertTrue(lignesFaits().last?.contains("locked=1") ?? false, "\(lignesFaits())")
        scruterSansActivite(core, 0.5)
        XCTAssertEqual(lignesFaits().count, avant + 1, "et une seule fois")
    }

    /// F44 : une fois l'état stable et inchangé, la raison publiée suit la raison courante, sans republier. Avant,
    /// elle restait collée sur `command:on` (ou sur `displays-reconfiguring`) jusqu'à la transition suivante.
    func test_raisonSuitLesFaitsSansRepublier() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        XCTAssertEqual(raisonPubliee(core), "display-asleep")

        core.requestOn(peer: "essai")
        XCTAssertEqual(raisonPubliee(core), "command:on")
        XCTAssertTrue(core.currentState)
        let publications = publieur.publications

        // Les faits confirment la commande : la raison passe à celle des faits, l'état est le même.
        signaux.etatEcran.asleep = false
        scruter(core, 0.5)
        XCTAssertNil(commandeEnAttente(core))
        XCTAssertEqual(raisonPubliee(core), "desktop-ui")
        XCTAssertTrue(journal.lines.contains { $0.0 == .debug && $0.1 == "raison : command:on → desktop-ui" },
                      "\(journal.lines)")

        // La session se verrouille : toujours ON, la raison suit, rien n'est republié.
        signaux.etatSession.locked = true
        scruter(core, 0.5)
        XCTAssertEqual(raisonPubliee(core), "lock-screen-ui")
        XCTAssertTrue(core.currentState)
        XCTAssertEqual(publieur.publications, publications, "aucune nouvelle publication")
        XCTAssertTrue(journal.lines.contains { $0.0 == .debug && $0.1 == "raison : desktop-ui → lock-screen-ui" })
        let lignes = journal.lines.count
        scruter(core, 0.5)
        XCTAssertEqual(journal.lines.count, lignes, "rien ne change : rien n'est écrit")

        // Les écrans physiques disparaissent (seul le fantôme reste) : l'état publié tient, la raison le dit, puis elle
        // revient avec les écrans.
        signaux.etatSession.locked = false
        signaux.ecrans = DisplaySnapshot(displays: [.fantome(9, main: true)], enumerationOK: true)
        scruter(core, 0.5)
        XCTAssertEqual(raisonPubliee(core), "displays-reconfiguring")
        XCTAssertTrue(core.currentState)
        signaux.ecrans = DisplaySnapshot(displays: [.physique(1, main: true)], enumerationOK: true)
        scruter(core, 0.5)
        XCTAssertEqual(raisonPubliee(core), "desktop-ui")
        XCTAssertEqual(publieur.publications, publications, "toujours aucune publication")
    }

    /// F44 : `off_command` remplace l'action configurée. La source de l'intention, donc la raison publiée et le journal,
    /// dit `off/override`, et non `off/screensaver`, qui laisserait croire qu'un économiseur a été lancé.
    func test_offSurcharge_sourceOverride() {
        actions.hasOffOverride = true
        let core = moteur()
        core.start()

        core.requestOff(peer: "essai")
        XCTAssertEqual(actions.appels, [.runOff(.screensaver)], "l'action configurée est passée telle quelle")
        XCTAssertEqual(commandeEnAttente(core)?["source"] as? String, "off/override")
        XCTAssertEqual(raisonPubliee(core), "command:off/override")
        XCTAssertTrue(journalContient("commande OFF (essai) → action=override"), "\(journal.lines)")

        // Les faits ne confirment rien : retour aux faits à l'échéance, la source est dans la ligne d'échéance.
        for _ in 0..<24 { scruter(core, 0.5) }
        XCTAssertTrue(journalContient("commande off/override non confirmée après 12.0 s"), "\(journal.lines)")
    }

    /// F44 : la raison publiée ne suit pas un état candidat que le lissage n'a pas encore publié (OFF : 800 ms). Sans
    /// quoi `/status` dirait `state 1` avec la raison `display-asleep` : la raison ne suit les faits que pour l'état
    /// déjà publié.
    func test_raisonNeSuitPasUnEtatNonLisse() {
        let core = moteur()
        core.start()
        XCTAssertEqual(raisonPubliee(core), "desktop-ui")
        signaux.etatEcran.asleep = true
        scruter(core, 0.5)
        XCTAssertTrue(core.currentState, "OFF candidat, pas encore publié")
        XCTAssertEqual(raisonPubliee(core), "desktop-ui", "l'état publié est encore ON : sa raison ne change pas")
        scruter(core, 0.5)
        XCTAssertEqual(raisonPubliee(core), "desktop-ui")
        scruter(core, 0.5)
        XCTAssertFalse(core.currentState)
        XCTAssertEqual(raisonPubliee(core), "display-asleep")
    }

    /// F44 : `/status` donne la raison des faits seuls (`facts_reason`, celle que `--once` appelle `reason`) à côté de
    /// la raison publiée, qui peut être celle d'une commande.
    func test_statusDonneLaRaisonDesFaits() {
        signaux.etatEcran.asleep = true
        let core = moteur()
        core.start()
        var instantane = core.statusSnapshot()
        XCTAssertEqual(instantane["reason"] as? String, "display-asleep")
        XCTAssertEqual(instantane["facts_reason"] as? String, "display-asleep")

        // Une commande ON tient l'état ON alors que les faits disent encore OFF.
        core.requestOn(peer: "essai")
        instantane = core.statusSnapshot()
        XCTAssertEqual(instantane["state"] as? String, "1")
        XCTAssertEqual(instantane["reason"] as? String, "command:on")
        XCTAssertEqual(instantane["facts_verdict"] as? String, "0")
        XCTAssertEqual(instantane["facts_reason"] as? String, "display-asleep")

        // Les faits rejoignent la commande.
        signaux.etatEcran.asleep = false
        signaux.etatSession.locked = true
        scruter(core, 0.5)
        instantane = core.statusSnapshot()
        XCTAssertEqual(instantane["facts_reason"] as? String, "lock-screen-ui")
        XCTAssertEqual(instantane["facts_reason"] as? String, core.inspect().reason, "même raison que `--once`")
    }
}
