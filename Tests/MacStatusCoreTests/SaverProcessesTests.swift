import XCTest
@testable import MacStatusCore

/// Règles pures de l'économiseur sous macOS 27 : quels process l'hébergent, comment lire le drapeau de
/// session (`SACScreenSaverIsRunning`) et à quel rythme balayer la table des process. Rien n'est lu du
/// système : les chemins sont ceux relevés au banc, les instants sont donnés à la main.
///
/// Les instants des tests de politique sont des puissances de deux (0,5 ; 4,5 ; 5…) : exacts en binaire,
/// pour que les bornes tombent juste.
final class SaverProcessesTests: XCTestCase {
    // MARK: - Hôtes d'économiseur

    /// Les trois hôtes vus au banc : `legacyScreenSaver` (arm64 et Rosetta), `ScreenSaverEngine`
    /// (économiseur commandé) et l'extension « Computer Name » (économiseur « Message »).
    func test_regleHote_reconnaitLesHotesDuBanc() {
        let hotes = [
            "/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver-x86_64.appex/Contents/MacOS/legacyScreenSaver-x86_64",
            "/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex/Contents/MacOS/legacyScreenSaver",
            "/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine",
            "/System/Library/ExtensionKit/Extensions/Computer Name.appex/Contents/MacOS/Computer Name",
        ]
        for chemin in hotes {
            XCTAssertTrue(SaverHostRule.isHost(path: chemin), chemin)
        }
    }

    /// Le fond d'écran tourne en permanence (extensions `Wallpaper*`) : il ne dit rien de l'économiseur.
    /// Un exécutable du même nom hors de `/System/Library/` est une copie, pas un hôte.
    func test_regleHote_refuseLeFondDEcranEtLesCopies() {
        let refuses = [
            "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension",
            "/System/Library/ExtensionKit/Extensions/Wallpaper.appex/Contents/MacOS/Wallpaper",
            "/private/tmp/ScreenSaverEngine",
            "/home/exemple/ScreenSaver.framework/PlugIns/x",
        ]
        for chemin in refuses {
            XCTAssertFalse(SaverHostRule.isHost(path: chemin), chemin)
        }
    }

    /// Les trois motifs reconnus ne comptent que sous `/System/Library/` : la même arborescence copiée
    /// ailleurs (un dossier d'essai, un volume monté, un chemin qui n'en a que la fin) est refusée.
    func test_regleHote_refuseLesMemesMotifsHorsDeSystemLibrary() {
        let copies = [
            "/home/exemple/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex/Contents/MacOS/legacyScreenSaver",
            "/private/tmp/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine",
            "/home/exemple/Computer Name.appex/Contents/MacOS/Computer Name",
            "/Volumes/Copie/System/Library/ExtensionKit/Extensions/Computer Name.appex/Contents/MacOS/Computer Name",
            "System/Library/ExtensionKit/Extensions/Computer Name.appex/Contents/MacOS/Computer Name",
        ]
        for chemin in copies {
            XCTAssertFalse(SaverHostRule.isHost(path: chemin), chemin)
        }
    }

    /// `ScreenSaverEngine` se reconnaît à son chemin entier, pas à un fragment : un autre exécutable de
    /// l'app, un nom voisin ou une chaîne vide ne passent pas.
    func test_regleHote_ScreenSaverEngine_cheminExactSeulement() {
        let refuses = [
            "",
            "/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine2",
            "/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/Autre",
            "/System/Library/CoreServices/Autre.app/Contents/MacOS/ScreenSaverEngine",
            "/System/Library/CoreServices/ScreenSaverEngine.app",
        ]
        for chemin in refuses {
            XCTAssertFalse(SaverHostRule.isHost(path: chemin), chemin)
        }
    }

    /// Le noyau tronque le nom court de « ScreenSaverEngine » : 16 caractères dans `p_comm` (table des
    /// process), 15 dans `pbi_comm` (`proc_pidinfo`). Les deux lectures doivent le reconnaître : mesuré
    /// sur macOS 27, un préfixe de 16 caractères ne reconnaîtrait jamais le nom lu par `proc_pidinfo`,
    /// et le PID gardé serait déclaré périmé à chaque lecture.
    func test_nomCourtDuMoteur_reconnuTronqueA16Et15Caracteres() {
        XCTAssertTrue(SaverHostRule.isEngine(shortName: "ScreenSaverEngin"), "p_comm, 16 caractères")
        XCTAssertTrue(SaverHostRule.isEngine(shortName: "ScreenSaverEngi"), "pbi_comm, 15 caractères")
        XCTAssertTrue(SaverHostRule.isEngine(shortName: "ScreenSaverEngine"), "nom entier")
    }

    func test_nomCourtDuMoteur_refuseLesAutresNoms() {
        let refuses = ["", "ScreenSaver", "ScreenSaverEn", "legacyScreenSave", "Computer Name",
                       "WallpaperAerials", "screensaverengin"]
        for nom in refuses {
            XCTAssertFalse(SaverHostRule.isEngine(shortName: nom), nom)
        }
    }

    // MARK: - Drapeau de session (SACScreenSaverIsRunning)

    /// La valeur passe par le code de retour : 1 pendant une session d'économiseur, 0 hors session. Tout
    /// autre code est un signe que la fonction a changé : le drapeau n'est pas disponible.
    func test_codeRetourSAC_unVrai_zeroFaux_autreIndisponible() {
        XCTAssertEqual(SaverSessionFlag.from(returnCode: 1), true)
        XCTAssertEqual(SaverSessionFlag.from(returnCode: 0), false)
        XCTAssertNil(SaverSessionFlag.from(returnCode: -1))
        XCTAssertNil(SaverSessionFlag.from(returnCode: 2))
    }

    // MARK: - Politique de balayage des process

    func test_politiqueDeScan_premierAppelPuisToutesLes5s() {
        XCTAssertEqual(SaverProcessScanPolicy.fullScanInterval, 5)
        var politique = SaverProcessScanPolicy()
        XCTAssertTrue(politique.shouldScan(now: 0))
        XCTAssertFalse(politique.shouldScan(now: 0.5))
        XCTAssertFalse(politique.shouldScan(now: 4.9))
        XCTAssertTrue(politique.shouldScan(now: 5.0))
    }

    /// L'intervalle se compte depuis le dernier scan accordé, non depuis le dernier appel : les refus
    /// n'avancent rien.
    func test_politiqueDeScan_lIntervalleSeCompteDepuisLeDernierScanAccorde() {
        var politique = SaverProcessScanPolicy()
        XCTAssertTrue(politique.shouldScan(now: 10))
        XCTAssertFalse(politique.shouldScan(now: 14.5))
        XCTAssertFalse(politique.shouldScan(now: 14.75))
        XCTAssertTrue(politique.shouldScan(now: 15))
        XCTAssertFalse(politique.shouldScan(now: 19.5))
        XCTAssertTrue(politique.shouldScan(now: 20))
    }

    /// Un indice accorde un scan tout de suite, une fois ; le scan accordé repart de zéro pour l'échéance.
    func test_politiqueDeScan_indiceForceUnScan() {
        var politique = SaverProcessScanPolicy()
        XCTAssertTrue(politique.shouldScan(now: 0))
        XCTAssertFalse(politique.shouldScan(now: 1))

        politique.noteHint()
        XCTAssertTrue(politique.shouldScan(now: 1.5), "l'indice accorde un scan avant l'échéance")
        XCTAssertFalse(politique.shouldScan(now: 2), "un indice ne sert qu'une fois")

        // L'échéance de 5 s repart du scan accordé par l'indice (1,5), non du premier (0).
        XCTAssertFalse(politique.shouldScan(now: 6))
        XCTAssertTrue(politique.shouldScan(now: 6.5))
    }

    /// Plusieurs indices avant la lecture suivante ne valent qu'un scan.
    func test_politiqueDeScan_plusieursIndicesNeValentQuUnScan() {
        var politique = SaverProcessScanPolicy()
        XCTAssertTrue(politique.shouldScan(now: 0))
        politique.noteHint()
        politique.noteHint()
        politique.noteHint()
        XCTAssertTrue(politique.shouldScan(now: 0.5))
        XCTAssertFalse(politique.shouldScan(now: 1))
    }

    /// Un indice qui précède le tout premier appel ne change rien : le premier appel est déjà accordé.
    func test_politiqueDeScan_indiceAvantLePremierAppel() {
        var politique = SaverProcessScanPolicy()
        politique.noteHint()
        XCTAssertTrue(politique.shouldScan(now: 0))
        XCTAssertFalse(politique.shouldScan(now: 0.5), "l'indice a été consommé par le premier scan")
    }

    // MARK: - Lecture qui échoue : une ligne par panne

    /// R61 a : la table des process se relit toutes les 5 s. Une panne ne fait pas une ligne par essai : un WARN au
    /// premier échec, un INFO à la première lecture réussie qui suit, rien entre les deux. Une panne nouvelle, plus
    /// tard, se signale de nouveau.
    func test_lectureQuiEchoue_unAvertissementParPannePuisUnRetour() {
        var lecture = ReadFailureEpisode()
        XCTAssertEqual(lecture.note(succeeded: true), .unchanged, "rien à dire quand tout va bien")
        XCTAssertEqual(lecture.note(succeeded: true), .unchanged)

        XCTAssertEqual(lecture.note(succeeded: false), .failureStarted, "premier échec : on le dit")
        XCTAssertEqual(lecture.note(succeeded: false), .unchanged, "la panne dure : pas une ligne par essai")
        XCTAssertEqual(lecture.note(succeeded: false), .unchanged)

        XCTAssertEqual(lecture.note(succeeded: true), .recovered, "la lecture revient : on le dit une fois")
        XCTAssertEqual(lecture.note(succeeded: true), .unchanged)

        XCTAssertEqual(lecture.note(succeeded: false), .failureStarted, "une panne nouvelle se signale de nouveau")
        XCTAssertEqual(lecture.note(succeeded: true), .recovered)
    }
}
