import Foundation
import XCTest
@testable import CodexMobilityPhoneFeature

@MainActor
final class MobileDiagnosticReportTests: XCTestCase {
    func testReportContainsAcceptanceMetricsWithoutTranscriptText()
        throws
    {
        var capability = MobileSpeechCapabilitySnapshot()
        capability.microphonePermission = .granted
        capability.requestedLocaleIdentifier = "zh-CN"
        capability.resolvedLocaleIdentifier = "zh_CN"
        capability.backend = .dictationTranscriber
        capability.assetState = .installed
        capability.localeReserved = true

        let report = MobileDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 7_000),
            phase: .recording,
            statusMessage: "正在倾听",
            selectedLocaleIdentifier: "zh-CN",
            capability: capability,
            keepAudio: true,
            availableStorageBytes: 900_000_000,
            minimumRecordingStorageBytes: 256_000_000,
            activeSession: nil,
            elapsedSeconds: 30,
            peakThermalState: "fair",
            firstPartialLatencyMilliseconds: 420,
            partialUpdateCount: 12,
            finalUpdateCount: 3,
            finalizationDurationMilliseconds: 800,
            recordedAudioFrameCount: 1_440_000,
            recordedAudioDurationSeconds: 30,
            recordingStartAvailableStorageBytes: 950_000_000,
            recordingEndAvailableStorageBytes: 900_000_000,
            recordingStartResidentMemoryBytes: 60_000_000,
            recordingEndResidentMemoryBytes: 62_000_000,
            peakResidentMemoryBytes: 64_000_000,
            localeReservationObservedDuringRecording: true,
            localeReservationReleasedAfterRecording: true,
            diagnostics: ["测试诊断"]
        )

        let text = try report.formattedJSON()

        XCTAssertTrue(text.contains("\"schemaVersion\" : 2"))
        XCTAssertTrue(
            text.contains("\"firstPartialLatencyMilliseconds\" : 420")
        )
        XCTAssertFalse(text.contains("\"transcript\""))
        XCTAssertTrue(
            text.contains(
                "\"localeReservationObservedDuringRecording\" : true"
            )
        )
        XCTAssertTrue(
            text.contains(
                "\"localeReservationReleasedAfterRecording\" : true"
            )
        )
        XCTAssertTrue(
            text.contains(
                "\"recordingStartResidentMemoryBytes\" : 60000000"
            )
        )
        XCTAssertTrue(
            text.contains(
                "\"recordingEndResidentMemoryBytes\" : 62000000"
            )
        )
        XCTAssertFalse(report.hardwareIdentifier.isEmpty)
        XCTAssertFalse(report.operatingSystemVersionString.isEmpty)
    }

    func testShareableReportOmitsDeviceStorageSignals() {
        let model = MobileAppModel()
        model.availableStorageBytes = 900_000_000
        model.recordingStartAvailableStorageBytes = 950_000_000
        model.recordingEndAvailableStorageBytes = 900_000_000
        model.statusMessage = "可用空间仅 900 MB"
        model.diagnostics = [
            "磁盘空间不足：900 MB",
            "语音后端：SpeechTranscriber",
        ]

        let text = model.shareableDiagnosticReportText

        XCTAssertFalse(text.contains("950000000"))
        XCTAssertFalse(text.contains("900000000"))
        XCTAssertFalse(text.contains("空间不足"))
        XCTAssertTrue(text.contains("语音后端"))
    }
}
