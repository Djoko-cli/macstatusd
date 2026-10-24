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
        CoreLog.sink = nil
        logError("perdu"); logInfo("perdu aussi")
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
        XCTAssertEqual(escapeForLog("Pièce 1 → /wake?action=WAKE \\u{1B}"), "Pièce 1 → /wake?action=WAKE \\u{1B}")
        XCTAssertEqual(escapeForLog("\u{A0}é"), "\u{A0}é")
        XCTAssertEqual(escapeForLog(""), "")
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
        })
    }

    func test_niveau_parseEtOrdre() {
        XCTAssertEqual(LogLevel.parse("DEBUG"), .debug)
        XCTAssertEqual(LogLevel.parse("warning"), .warn)
        XCTAssertEqual(LogLevel.parse("n'importe quoi"), .info)
        XCTAssertTrue(LogLevel.error < LogLevel.debug)
        XCTAssertEqual(LogLevel.warn.tag, "WARN ")
    }
}
