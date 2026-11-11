import XCTest
@testable import CodexMobilityMacFeature

final class SpeechTextAssemblyTests: XCTestCase {
    func testFailureTeardownNeverAwaitsTheFailingWorkerItself() {
        let conversionFailure = SpeechFailureTeardownPlan.plan(for: .conversion)
        XCTAssertFalse(conversionFailure.awaitConversion)
        XCTAssertTrue(conversionFailure.cancelResults)
        XCTAssertTrue(conversionFailure.awaitResults)

        let resultsFailure = SpeechFailureTeardownPlan.plan(for: .results)
        XCTAssertFalse(resultsFailure.awaitResults)
        XCTAssertTrue(resultsFailure.cancelConversion)
        XCTAssertTrue(resultsFailure.awaitConversion)

        let captureFailure = SpeechFailureTeardownPlan.plan(for: .capture)
        XCTAssertTrue(captureFailure.cancelConversion)
        XCTAssertTrue(captureFailure.cancelResults)
        XCTAssertTrue(captureFailure.awaitConversion)
        XCTAssertTrue(captureFailure.awaitResults)
    }

    func testBackendSelectionPrefersSpeechTranscriber() {
        let speechLocale = Locale(identifier: "zh_CN")
        let dictationLocale = Locale(identifier: "zh-CN")

        XCTAssertEqual(
            SpeechBackendSelector.select(
                requestedLocale: Locale(identifier: "zh-CN"),
                speechLocale: speechLocale,
                dictationLocale: dictationLocale
            ),
            .speech(speechLocale)
        )
    }

    func testBackendSelectionFallsBackToDictation() {
        let dictationLocale = Locale(identifier: "en_US")

        XCTAssertEqual(
            SpeechBackendSelector.select(
                requestedLocale: Locale(identifier: "en-US"),
                speechLocale: nil,
                dictationLocale: dictationLocale
            ),
            .dictation(dictationLocale)
        )
    }

    func testBackendSelectionRejectsUnsupportedLocale() {
        XCTAssertNil(
            SpeechBackendSelector.select(
                requestedLocale: Locale(identifier: "fr-FR"),
                speechLocale: nil,
                dictationLocale: nil
            )
        )
    }

    func testBackendSelectionTrustsAppleEquivalentSpeechLocale() {
        let speechLocale = Locale(identifier: "zh-Hans")

        XCTAssertEqual(
            SpeechBackendSelector.select(
                requestedLocale: Locale(identifier: "zh-CN"),
                speechLocale: speechLocale,
                dictationLocale: Locale(identifier: "zh_CN")
            ),
            .speech(speechLocale)
        )
    }

    func testVolatileResultReplacesPreviousPartial() {
        var assembly = SpeechTextAssembly()

        _ = assembly.accept("hello wor", isFinal: false)
        let update = assembly.accept("hello world", isFinal: false)

        XCTAssertEqual(update.finalizedText, "")
        XCTAssertEqual(update.volatileText, "hello world")
        XCTAssertEqual(update.text, "hello world")
        XCTAssertFalse(update.isFinal)
    }

    func testFinalResultCommitsAndClearsVolatileText() {
        var assembly = SpeechTextAssembly()

        _ = assembly.accept("hello wor", isFinal: false)
        let update = assembly.accept("hello world", isFinal: true)

        XCTAssertEqual(update.finalizedText, "hello world")
        XCTAssertEqual(update.volatileText, "")
        XCTAssertEqual(update.text, "hello world")
        XCTAssertTrue(update.isFinal)
    }

    func testEnglishFinalSegmentsReceiveBoundarySpace() {
        var assembly = SpeechTextAssembly()

        _ = assembly.accept("Hello.", isFinal: true)
        let update = assembly.accept("How are you?", isFinal: true)

        XCTAssertEqual(update.text, "Hello. How are you?")
    }

    func testChineseSegmentsAreNotSeparatedArtificially() {
        var assembly = SpeechTextAssembly()

        _ = assembly.accept("你好", isFinal: true)
        let update = assembly.accept("世界", isFinal: true)

        XCTAssertEqual(update.text, "你好世界")
    }

    func testExistingWhitespaceAndPunctuationArePreserved() {
        var assembly = SpeechTextAssembly()

        _ = assembly.accept("Hello ", isFinal: true)
        _ = assembly.accept("world", isFinal: true)
        let update = assembly.accept("!", isFinal: true)

        XCTAssertEqual(update.text, "Hello world!")
    }

    func testAudioLevelIsClampedToUnitRange() {
        let assembly = SpeechTextAssembly()

        XCTAssertEqual(assembly.update(audioLevel: -1, isFinal: false).audioLevel, 0)
        XCTAssertEqual(assembly.update(audioLevel: 2, isFinal: false).audioLevel, 1)
    }
}
