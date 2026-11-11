import AVFAudio
import CodexMobilityCore
import Foundation
import XCTest
@testable import CodexMobilityPhoneFeature

@MainActor
final class RollingAudioRecorderTests: XCTestCase {
    private struct RejectingSink: SpeechAudioBufferSink {
        func offer(_ buffer: AVAudioPCMBuffer) -> Bool {
            false
        }

        var rejectionErrorDescription: String? {
            "测试拒绝"
        }
    }

    private enum TestError: Error {
        case couldNotCreateAudioFormat
        case couldNotCreateAudioBuffer
        case partialFileDidNotAppear
    }

    func testOfferUsesBoundedQueueAndRejectsAfterOverflow() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = try RollingAudioRecorder(
            sessionID: UUID(),
            directoryURL: root,
            segmentDuration: 3_600
        )
        let buffer = try makeBuffer(
            sampleRate: 8_000,
            frameCount: 64
        )

        var acceptedCount = 0
        var overflowed = false
        for _ in 0 ..< 10_000 {
            if recorder.offer(buffer) {
                acceptedCount += 1
            } else {
                overflowed = true
                break
            }
        }

        XCTAssertTrue(overflowed, "有界队列应在生产速度持续高于写入速度时拒绝输入")
        XCTAssertGreaterThan(acceptedCount, 0)
        XCTAssertLessThan(acceptedCount, 10_000)
        XCTAssertFalse(recorder.offer(buffer))
        XCTAssertNotNil(recorder.rejectionErrorDescription)

        let segments = try await recorder.finish(
            commitCurrentSegment: false
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].state, .partial)
        XCTAssertEqual(
            segments[0].frameCount,
            Int64(acceptedCount) * Int64(buffer.frameLength)
        )
    }

    func testFinishCommitsPartialCAFAndManifestCanRoundTrip() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID(
            uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
        )!
        let store = MobileSessionStore(rootDirectory: root)
        let audioDirectory = try await store.audioDirectory(
            sessionID: sessionID
        )
        let recorder = try RollingAudioRecorder(
            sessionID: sessionID,
            directoryURL: audioDirectory,
            segmentDuration: 60
        )
        let buffer = try makeBuffer(
            sampleRate: 8_000,
            frameCount: 800
        )

        XCTAssertTrue(recorder.offer(buffer))
        let partialURL = try await waitForPartialFile(
            in: audioDirectory
        )
        XCTAssertTrue(partialURL.lastPathComponent.hasSuffix(".caf.partial"))

        let segments = try await recorder.finish(
            commitCurrentSegment: true
        )

        XCTAssertEqual(segments.count, 1)
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segment.sequenceNumber, 0)
        XCTAssertEqual(segment.state, .committed)
        XCTAssertEqual(segment.frameCount, Int64(buffer.frameLength))
        XCTAssertEqual(segment.sampleRate, 8_000)
        XCTAssertEqual(segment.channelCount, 1)
        XCTAssertFalse(segment.fileName.hasSuffix(".partial"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: partialURL.path)
        )

        let committedURL = audioDirectory.appendingPathComponent(
            segment.fileName
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: committedURL.path)
        )
        let audioFile = try AVAudioFile(forReading: committedURL)
        XCTAssertEqual(audioFile.length, AVAudioFramePosition(buffer.frameLength))

        let manifest = MobileAudioManifest(
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSince1970: 5_000),
            segments: segments
        )
        try await store.save(manifest)

        let loadedManifest = try await store.loadAudioManifest(
            sessionID: sessionID
        )
        XCTAssertEqual(loadedManifest, manifest)

        let recoveryManifest = try RollingSegmentRecoveryManifest.build(
            fileNames: try FileManager.default.contentsOfDirectory(
                atPath: audioDirectory.path
            ),
            sessionID: sessionID,
            fileExtension: "caf"
        )
        XCTAssertEqual(
            recoveryManifest.committedFiles.map(\.fileName),
            [segment.fileName]
        )
        XCTAssertTrue(recoveryManifest.incompleteFiles.isEmpty)
        XCTAssertTrue(recoveryManifest.stalePartialFileNames.isEmpty)
    }

    func testSegmentDurationRollsAndFinishCommitsEveryCAF() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = try RollingAudioRecorder(
            sessionID: UUID(),
            directoryURL: root,
            segmentDuration: 0.05
        )
        let buffer = try makeBuffer(
            sampleRate: 1_000,
            frameCount: 40
        )

        XCTAssertTrue(recorder.offer(buffer))
        XCTAssertTrue(recorder.offer(buffer))

        let segments = try await recorder.finish(
            commitCurrentSegment: true
        )

        XCTAssertEqual(segments.map(\.sequenceNumber), [0, 1])
        XCTAssertEqual(segments.map(\.state), [.committed, .committed])
        XCTAssertEqual(segments.map(\.frameCount), [40, 40])
        for segment in segments {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root
                        .appendingPathComponent(segment.fileName)
                        .path
                )
            )
            XCTAssertFalse(segment.fileName.hasSuffix(".partial"))
        }
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasSuffix(".partial") }
        )
    }

    func testCaptureMonitorCountsFramesWithoutAudioRetention() throws {
        let monitor = MonitoredAudioBufferSink(downstream: nil)
        let buffer = try makeBuffer(
            sampleRate: 8_000,
            frameCount: 800
        )

        XCTAssertTrue(monitor.offer(buffer))
        XCTAssertTrue(monitor.offer(buffer))

        let snapshot = monitor.snapshot()
        XCTAssertEqual(snapshot.acceptedBufferCount, 2)
        XCTAssertEqual(snapshot.acceptedFrameCount, 1_600)
        XCTAssertEqual(snapshot.acceptedDuration, 0.2, accuracy: 0.001)
        XCTAssertNotNil(snapshot.lastAcceptedAt)
    }

    func testCaptureMonitorDoesNotCountRejectedDownstreamBuffer()
        throws
    {
        let monitor = MonitoredAudioBufferSink(
            downstream: RejectingSink()
        )
        let buffer = try makeBuffer(
            sampleRate: 8_000,
            frameCount: 800
        )

        XCTAssertFalse(monitor.offer(buffer))

        let snapshot = monitor.snapshot()
        XCTAssertEqual(snapshot.acceptedBufferCount, 0)
        XCTAssertEqual(snapshot.acceptedFrameCount, 0)
        XCTAssertEqual(
            monitor.rejectionErrorDescription,
            "测试拒绝"
        )
    }

    private func makeBuffer(
        sampleRate: Double,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TestError.couldNotCreateAudioFormat
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw TestError.couldNotCreateAudioBuffer
        }
        buffer.frameLength = frameCount
        return buffer
    }

    private func waitForPartialFile(in directory: URL) async throws -> URL {
        for _ in 0 ..< 200 {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            if let partial = files.first(where: {
                $0.lastPathComponent.hasSuffix(".caf.partial")
            }) {
                return partial
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError.partialFileDidNotAppear
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexWatchPet-RollingAudioRecorderTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
