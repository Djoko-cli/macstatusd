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

    func test_niveau_parseEtOrdre() {
        XCTAssertEqual(LogLevel.parse("DEBUG"), .debug)
        XCTAssertEqual(LogLevel.parse("warning"), .warn)
        XCTAssertEqual(LogLevel.parse("n'importe quoi"), .info)
        XCTAssertTrue(LogLevel.error < LogLevel.debug)
        XCTAssertEqual(LogLevel.warn.tag, "WARN ")
    }
}
