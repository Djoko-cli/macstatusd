import XCTest
@testable import MacStatusCore

final class LoggingTests: XCTestCase {
    private var ancienRecepteur: LogSink?

    override func setUp() {
        super.setUp()
        ancienRecepteur = CoreLog.sink
    }

    override func tearDown() {
        CoreLog.sink = ancienRecepteur
        super.tearDown()
    }

    func test_lesFonctionsLibres_ecriventDansLeRecepteur() {
        let capture = CaptureLog()
        CoreLog.sink = capture
        logError("e"); logWarn("w"); logInfo("i"); logDebug("d")
        XCTAssertEqual(capture.lines.map { $0.0 }, [.error, .warn, .info, .debug])
        XCTAssertEqual(capture.lines.map { $0.1 }, ["e", "w", "i", "d"])
    }

    func test_sansRecepteur_rienNEstEcritEtRienNePlante() {
        let capture = CaptureLog()
        CoreLog.sink = capture
        logInfo("capté")
        XCTAssertEqual(capture.lines.count, 1, "le récepteur branché reçoit bien")
        CoreLog.sink = nil
        logError("perdu"); logWarn("perdu"); logInfo("perdu aussi"); logDebug("perdu encore")
        XCTAssertEqual(capture.lines.map { $0.1 }, ["capté"], "rien n'est capté une fois le récepteur retiré")
    }

    /// `off_command` / `wake_command` au journal : l'exécutable (échappé) et le nombre d'arguments,
    /// jamais les arguments (ils peuvent porter un jeton ou une adresse).
    func test_resumeDeCommande_executableEtNombreDArgumentsSeulement() {
        let resume = commandSummaryForLog(["/usr/local/bin/outil", "--jeton", "jeton-essai-0123456789abcdef", "198.51.100.7"])
        XCTAssertEqual(resume, "/usr/local/bin/outil + 3 arguments")
        XCTAssertFalse(resume.contains("jeton-essai"))
        XCTAssertFalse(resume.contains("198.51.100.7"))
        XCTAssertEqual(commandSummaryForLog(["/usr/bin/true"]), "/usr/bin/true + 0 argument")
        XCTAssertEqual(commandSummaryForLog(["/bin/echo", "x"]), "/bin/echo + 1 argument")
        // L'exécutable lui-même est échappé : il ne peut ni couper la ligne ni glisser une séquence.
        XCTAssertEqual(commandSummaryForLog(["/home/exemple/a\nb\u{1B}", "x"]),
                       "/home/exemple/a\\u{0A}b\\u{1B} + 1 argument")
        XCTAssertEqual(commandSummaryForLog([]), "(commande vide)")
    }

    func test_escapeForLog() {
        XCTAssertEqual(escapeForLog("a\u{1B}b\nc"), "a\\u{1B}b\\u{0A}c")
        XCTAssertEqual(escapeForLog(String(repeating: "x", count: 250)).count, 201)
    }

    func test_escapeForLog_caracteresEchappes() {
        XCTAssertEqual(escapeForLog("\u{00}\r\n\u{1F}"), "\\u{00}\\u{0D}\\u{0A}\\u{1F}")
        XCTAssertEqual(escapeForLog("\u{7F}\u{80}\u{85}\u{9F}"), "\\u{7F}\\u{80}\\u{85}\\u{9F}")
        XCTAssertEqual(escapeForLog("a\u{2028}b\u{2029}c"), "a\\u{2028}b\\u{2029}c")
    }

    func test_escapeForLog_tabulationEtTexteOrdinaireGardes() {
        XCTAssertEqual(escapeForLog("a\tb"), "a\tb")
        XCTAssertEqual(escapeForLog("Pièce 1 → /wake?action=WAKE"), "Pièce 1 → /wake?action=WAKE")
        XCTAssertEqual(escapeForLog("\u{A0}é"), "\u{A0}é")
        XCTAssertEqual(escapeForLog(""), "")
    }

    func test_escapeForLog_antislashDouble_uneCibleLitteraleNImitePasUnEchappement() {
        // Un antislash littéral est doublé : `\u{0A}` au journal est une vraie fin de ligne,
        // `\\u{0A}` le texte « \u{0A} » reçu tel quel.
        XCTAssertEqual(escapeForLog("\\"), "\\\\")
        XCTAssertEqual(escapeForLog("a\\u{0A}b"), "a\\\\u{0A}b")
        XCTAssertEqual(escapeForLog("\n"), "\\u{0A}")
        XCTAssertNotEqual(escapeForLog("\\u{0A}"), escapeForLog("\n"))
        // Le doublement compte dans la limite, et ne se coupe pas en deux.
        XCTAssertEqual(escapeForLog("a\\b", limit: 3), "a\\\\…")
        XCTAssertEqual(escapeForLog("a\\b", limit: 2), "a…")
    }

    func test_escapeForLog_marquesBidirectionnelles() {
        // U+202A–U+202E (incorporations et remplacements) et U+2066–U+2069 (isolats) :
        // elles réordonnent l'affichage d'un journal lu dans un terminal ou un éditeur.
        XCTAssertEqual(escapeForLog("a\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}b"),
                       "a\\u{202A}\\u{202B}\\u{202C}\\u{202D}\\u{202E}b")
        XCTAssertEqual(escapeForLog("\u{2066}\u{2067}\u{2068}\u{2069}"),
                       "\\u{2066}\\u{2067}\\u{2068}\\u{2069}")
        // Les voisins immédiats des deux plages restent intacts.
        XCTAssertEqual(escapeForLog("\u{2065}\u{206A}\u{2029}\u{202F}"), "\u{2065}\u{206A}\\u{2029}\u{202F}")
    }

    func test_escapeForLog_methodeLongue_estBorneAvecLaLimiteDe16() {
        // Cas du journal HTTP : la méthode (lettres majuscules, sans autre borne) est coupée à 16.
        XCTAssertEqual(escapeForLog(String(repeating: "A", count: 5000), limit: 16),
                       String(repeating: "A", count: 16) + "…")
        XCTAssertEqual(escapeForLog("GET", limit: 16), "GET")
    }

    func test_escapeForLog_troncature() {
        XCTAssertEqual(escapeForLog(String(repeating: "x", count: 200)), String(repeating: "x", count: 200))
        XCTAssertEqual(escapeForLog("abcdef", limit: 3), "abc…")
        XCTAssertEqual(escapeForLog("abc", limit: 3), "abc")
        // La limite porte sur le texte échappé, et un échappement n'est jamais coupé.
        XCTAssertEqual(escapeForLog("ab\u{1B}cd", limit: 8), "ab\\u{1B}…")
        XCTAssertEqual(escapeForLog("ab\u{1B}cd", limit: 7), "ab…")
        XCTAssertEqual(escapeForLog("\u{1B}", limit: 6), "\\u{1B}")
    }

    func test_escapeForLog_sortieSansCaractereDeControle() {
        var tout = ""
        for valeur in 0...0x3000 { if let s = Unicode.Scalar(valeur) { tout.unicodeScalars.append(s) } }
        let sortie = escapeForLog(tout, limit: Int.max)
        XCTAssertFalse(sortie.unicodeScalars.contains {
            ($0.value < 0x20 && $0 != "\t") || (0x7F...0x9F).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029
                || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
        })
    }

    func test_niveau_parseEtOrdre() {
        XCTAssertEqual(LogLevel.parse("DEBUG"), .debug)
        XCTAssertEqual(LogLevel.parse("warning"), .warn)
        XCTAssertEqual(LogLevel.parse("n'importe quoi"), .info)
        XCTAssertTrue(LogLevel.error < LogLevel.debug)
        XCTAssertEqual(LogLevel.warn.tag, "WARN ")
    }

    // MARK: - redactURL

    func test_redactURL_motDePasseEtIdentifiantDeWebhook() {
        XCTAssertEqual(redactURL("http://u:secret@192.0.2.10:8123/api/webhook/abc123"),
                       "http://u:***@192.0.2.10:8123/api/webhook/<masqué>")
    }

    func test_redactURL_requeteMasqueeEnEntier() {
        XCTAssertEqual(redactURL("http://192.0.2.10:51828/?accessoryId=mac&state=true"),
                       "http://192.0.2.10:51828/?<masqué>")
        XCTAssertEqual(redactURL("http://192.0.2.10/hook?token=jeton-essai-0123456789abcdef"),
                       "http://192.0.2.10/hook?<masqué>")
        // La partie requête vide compte aussi : elle peut être suivie d'un fragment secret.
        XCTAssertEqual(redactURL("http://192.0.2.10/hook#jeton"), "http://192.0.2.10/hook#<masqué>")
    }

    func test_redactURL_hoteEtPortRestentVisibles_cheminOrdinaireGarde() {
        XCTAssertEqual(redactURL("https://ha.exemple.test:8123/hook"), "https://ha.exemple.test:8123/hook")
        XCTAssertEqual(redactURL("http://192.0.2.10:51828/"), "http://192.0.2.10:51828/")
        XCTAssertEqual(redactURL("http://[fd00::1]:8123/api/webhook/abc"), "http://[fd00::1]:8123/api/webhook/<masqué>")
    }

    func test_redactURL_identifiantSeulEstMasque() {
        // Un « utilisateur » seul est souvent le jeton lui-même (https://<jeton>@hôte).
        XCTAssertEqual(redactURL("https://jeton-essai-0123456789abcdef@192.0.2.10/hook"), "https://***@192.0.2.10/hook")
    }

    func test_redactURL_segmentApresWebhookSeulementMasque() {
        XCTAssertEqual(redactURL("http://192.0.2.10/api/webhook/abc/suite"), "http://192.0.2.10/api/webhook/<masqué>/suite")
        XCTAssertEqual(redactURL("http://192.0.2.10/api/webhook"), "http://192.0.2.10/api/webhook")
        XCTAssertEqual(redactURL("http://192.0.2.10/api/autre/abc"), "http://192.0.2.10/api/autre/abc")
    }

    func test_redactURL_invalide() {
        XCTAssertEqual(redactURL("pas une url du tout"), "<url invalide>")
        XCTAssertEqual(redactURL(""), "<url invalide>")
        XCTAssertEqual(redactURL("jeton-essai-0123456789abcdef"), "<url invalide>")
        XCTAssertEqual(redactURL("http://"), "<url invalide>")
        XCTAssertEqual(redactURL("/api/webhook/abc123"), "<url invalide>")
        XCTAssertEqual(redactURL("http://u:secret@ho st/x"), "<url invalide>")
    }
}
