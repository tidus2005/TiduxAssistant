import XCTest
@testable import CodexMobilityPhoneFeature

final class MobileSpeechUpdateTelemetryTests: XCTestCase {
    func testFinalMatchingVisiblePartialStillCountsAsFinal() {
        var telemetry = MobileSpeechUpdateTelemetry()

        let partial = SpeechTranscriptionUpdate(
            finalizedText: "",
            volatileText: "你好",
            text: "你好",
            isFinal: false,
            audioLevel: 0.2
        )
        let final = SpeechTranscriptionUpdate(
            finalizedText: "你好",
            volatileText: "",
            text: "你好",
            isFinal: true,
            audioLevel: 0.1
        )

        XCTAssertEqual(telemetry.classify(partial), .partial)
        XCTAssertEqual(telemetry.classify(partial), .unchanged)
        XCTAssertEqual(telemetry.classify(final), .final)
    }

    func testFinalOnlyUpdateIsNotMisclassifiedAsPartial() {
        var telemetry = MobileSpeechUpdateTelemetry()
        let final = SpeechTranscriptionUpdate(
            finalizedText: "直接完成",
            volatileText: "",
            text: "直接完成",
            isFinal: true,
            audioLevel: 0
        )

        XCTAssertEqual(telemetry.classify(final), .final)
    }

    func testResetAllowsSamePartialToBeCountedForNewRun() {
        var telemetry = MobileSpeechUpdateTelemetry()
        let partial = SpeechTranscriptionUpdate(
            finalizedText: "",
            volatileText: "新会话",
            text: "新会话",
            isFinal: false,
            audioLevel: 0
        )

        XCTAssertEqual(telemetry.classify(partial), .partial)
        telemetry.reset()
        XCTAssertEqual(telemetry.classify(partial), .partial)
    }

    func testFailureRecoveryPrefersFinalTranscriptTail() {
        XCTAssertEqual(
            MobileRecordingTextRecovery.preservedText(
                finalTranscript: "包含最终尾句",
                liveTranscript: "较旧 partial"
            ),
            "包含最终尾句"
        )
        XCTAssertEqual(
            MobileRecordingTextRecovery.preservedText(
                finalTranscript: "",
                liveTranscript: "仅有 partial"
            ),
            "仅有 partial"
        )
    }
}
