import Foundation
import XCTest
@testable import CodexMobilityPhoneFeature

@MainActor
final class MobileVoiceInputPreferenceTests: XCTestCase {
    func testLocaleAndAudioRetentionPersistAcrossModelInstances() throws {
        let suiteName =
            "MobileVoiceInputPreferenceTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            preferences.removePersistentDomain(forName: suiteName)
        }

        let first = MobileAppModel(preferences: preferences)
        first.selectedLocaleIdentifier = "ja-JP"
        first.keepAudio = false

        let restored = MobileAppModel(preferences: preferences)
        XCTAssertEqual(restored.selectedLocaleIdentifier, "ja-JP")
        XCTAssertFalse(restored.keepAudio)
    }

    func testUnsupportedStoredLocaleFallsBackToSimplifiedChinese()
        throws
    {
        let suiteName =
            "MobileVoiceInputPreferenceTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            preferences.removePersistentDomain(forName: suiteName)
        }
        preferences.set(
            "not-a-supported-locale",
            forKey:
                "com.tidux.CodexWatchPet.voiceInput.localeIdentifier"
        )

        let model = MobileAppModel(preferences: preferences)

        XCTAssertEqual(model.selectedLocaleIdentifier, "zh-CN")
    }

    func testRecordingScreenRequestsAreMonotonic() {
        let runtime = MobilityVoiceInputRuntime()

        XCTAssertEqual(runtime.recordingScreenRequestID, 0)
        runtime.requestRecordingScreen()
        runtime.requestRecordingScreen()

        XCTAssertEqual(runtime.recordingScreenRequestID, 2)
    }

    func testRecordingScreenRequestPopsDetailAndSelectsRecording() {
        var navigation = MobileRootNavigationState(
            selectedSection: .history
        )
        navigation.path.append("history-detail")

        navigation.showRecordingScreen()

        XCTAssertEqual(navigation.path.count, 0)
        XCTAssertEqual(navigation.selectedSection, .recording)
    }
}
