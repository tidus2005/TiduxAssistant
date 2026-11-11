import XCTest

final class CodexWatchPetVoiceInputiOSSmokeTests: XCTestCase {
    func testTestHostLoads() {
        XCTAssertTrue(true)
    }

    func testPrivacyUsageDescriptionsAreBundled() throws {
        let microphone = try XCTUnwrap(
            Bundle.main.object(
                forInfoDictionaryKey: "NSMicrophoneUsageDescription"
            ) as? String
        )
        let speech = try XCTUnwrap(
            Bundle.main.object(
                forInfoDictionaryKey:
                    "NSSpeechRecognitionUsageDescription"
            ) as? String
        )

        XCTAssertFalse(microphone.isEmpty)
        XCTAssertFalse(speech.isEmpty)
        XCTAssertTrue(speech.contains("设备端语音模型"))
        let sourceRevision = try XCTUnwrap(
            Bundle.main.object(
                forInfoDictionaryKey: "CodexWatchPetVoiceInputSourceRevision"
            ) as? String
        )
        XCTAssertNotNil(
            sourceRevision.range(
                of: #"^sha256-[0-9a-f]{64}$"#,
                options: .regularExpression
            ),
            "候选构建必须注入由源码内容计算出的 SHA-256 revision"
        )

        let orientations = try XCTUnwrap(
            Bundle.main.object(
                forInfoDictionaryKey: "UISupportedInterfaceOrientations"
            ) as? [String]
        )
        XCTAssertEqual(
            Set(orientations),
            [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ]
        )
    }
}
