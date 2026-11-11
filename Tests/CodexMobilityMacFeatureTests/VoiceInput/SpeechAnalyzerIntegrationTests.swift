import AVFoundation
import Foundation
import Speech
import XCTest
@testable import CodexMobilityMacFeature

final class SpeechAnalyzerIntegrationTests: XCTestCase {
    func testOnDeviceModelTranscribesSyntheticChineseSpeech() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEX_WATCH_PET_RUN_SPEECH_INTEGRATION"] == "1"
            || environment["FLOWTYPE_RUN_SPEECH_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "Set CODEX_WATCH_PET_RUN_SPEECH_INTEGRATION=1 to use the on-device model."
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexWatchPet-Speech-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let audioURL = temporaryDirectory.appendingPathComponent("sample.aiff")
        let speechSynthesizer = Process()
        speechSynthesizer.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speechSynthesizer.arguments = [
            "-v", "Tingting",
            "-o", audioURL.path,
            "你好，今天我们测试语音输入。",
        ]
        try speechSynthesizer.run()
        speechSynthesizer.waitUntilExit()
        XCTAssertEqual(speechSynthesizer.terminationStatus, 0)

        let requestedLocale = Locale(identifier: "zh-CN")
        let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        )
        let locale = try XCTUnwrap(supportedLocale)
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        let modules: [any SpeechModule] = [transcriber]

        if let installationRequest = try await AssetInventory
            .assetInstallationRequest(supporting: modules) {
            try await installationRequest.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        let audioFile = try AVAudioFile(forReading: audioURL)
        async let collectedTranscript: String = {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }()

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let transcript = try await collectedTranscript

        print("Real on-device SpeechAnalyzer transcript: \(transcript)")
        XCTAssertTrue(transcript.contains("今天"), transcript)
        XCTAssertTrue(transcript.contains("测试"), transcript)
        XCTAssertTrue(transcript.contains("语音"), transcript)
    }
}
