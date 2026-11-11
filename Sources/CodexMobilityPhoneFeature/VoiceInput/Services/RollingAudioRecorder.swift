#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFAudio
import CodexMobilityCore
import Foundation
import Synchronization

struct MobileAudioSegment: Codable, Equatable, Sendable {
    let sequenceNumber: UInt64
    let fileName: String
    let state: RollingSegmentFileState
    let frameCount: Int64
    let sampleRate: Double
    let channelCount: UInt32

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }
}

struct MobileAudioManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessionID: UUID
    let updatedAt: Date
    let segments: [MobileAudioSegment]

    init(
        sessionID: UUID,
        updatedAt: Date = Date(),
        segments: [MobileAudioSegment]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.updatedAt = updatedAt
        self.segments = segments
    }
}

struct MonitoredAudioCaptureSnapshot: Equatable, Sendable {
    let acceptedBufferCount: UInt64
    let acceptedFrameCount: Int64
    let acceptedDuration: TimeInterval
    let lastAcceptedAt: Date?
}

/// Counts capture callbacks even when the user has disabled audio retention.
///
/// This wrapper stays on the real-time path, so it only forwards the buffer and
/// updates a small mutex-protected value. It never allocates files or performs
/// asynchronous work from the render callback.
final class MonitoredAudioBufferSink:
    SpeechAudioBufferSink,
    @unchecked Sendable
{
    private struct State: Sendable {
        var acceptedBufferCount: UInt64 = 0
        var acceptedFrameCount: Int64 = 0
        var acceptedDuration: TimeInterval = 0
        var lastAcceptedAt: Date?
    }

    private let downstream: (any SpeechAudioBufferSink)?
    private let state = Mutex(State())

    init(downstream: (any SpeechAudioBufferSink)?) {
        self.downstream = downstream
    }

    func offer(_ buffer: AVAudioPCMBuffer) -> Bool {
        if let downstream, !downstream.offer(buffer) {
            return false
        }

        let frameCount = Int64(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        let duration = sampleRate > 0
            ? Double(frameCount) / sampleRate
            : 0
        state.withLock { value in
            value.acceptedBufferCount &+= 1
            value.acceptedFrameCount += frameCount
            value.acceptedDuration += duration
            value.lastAcceptedAt = Date()
        }
        return true
    }

    var rejectionErrorDescription: String? {
        downstream?.rejectionErrorDescription
    }

    func snapshot() -> MonitoredAudioCaptureSnapshot {
        state.withLock { value in
            MonitoredAudioCaptureSnapshot(
                acceptedBufferCount: value.acceptedBufferCount,
                acceptedFrameCount: value.acceptedFrameCount,
                acceptedDuration: value.acceptedDuration,
                lastAcceptedAt: value.lastAcceptedAt
            )
        }
    }
}

enum RollingAudioRecorderError: LocalizedError, Sendable {
    case invalidSegmentDuration
    case queueOverflow
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSegmentDuration:
            "音频分段时长必须大于零。"
        case .queueOverflow:
            "音频文件写入速度跟不上麦克风，录音已停止以避免静默丢失内容。"
        case let .writerFailed(message):
            "音频文件写入失败：\(message)"
        }
    }
}

/// Mirrors read-only microphone buffers into rolling CAF files.
///
/// `offer(_:)` is called from the Core Audio real-time callback. It only
/// performs a bounded `AsyncStream` yield; all filesystem work happens in the
/// detached worker.
final class RollingAudioRecorder: SpeechAudioBufferSink, @unchecked Sendable {
    private struct LifecycleState: Sendable {
        var isClosed = false
        var commitCurrentSegment = false
        var failureMessage: String?
    }

    private final class SharedState: @unchecked Sendable {
        let lifecycle = Mutex(LifecycleState())
    }

    private let continuation: AsyncStream<AudioBufferEnvelope>.Continuation
    private let workerTask: Task<[MobileAudioSegment], Error>
    private let sharedState: SharedState

    init(
        sessionID: UUID,
        directoryURL: URL,
        segmentDuration: TimeInterval = 300
    ) throws {
        guard segmentDuration > 0 else {
            throw RollingAudioRecorderError.invalidSegmentDuration
        }

        let pair = AsyncStream<AudioBufferEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(64)
        )
        continuation = pair.continuation
        let sharedState = SharedState()
        self.sharedState = sharedState

        workerTask = Task.detached(priority: .utility) {
            do {
                var worker = RollingAudioFileWorker(
                    sessionID: sessionID,
                    directoryURL: directoryURL,
                    segmentDuration: segmentDuration
                )
                let segments = try await worker.run(stream: pair.stream) {
                    sharedState.lifecycle.withLock { state in
                        state.commitCurrentSegment
                    }
                }
                return segments
            } catch {
                sharedState.lifecycle.withLock { state in
                    state.failureMessage = error.localizedDescription
                    state.isClosed = true
                }
                throw RollingAudioRecorderError.writerFailed(
                    error.localizedDescription
                )
            }
        }
    }

    func offer(_ buffer: AVAudioPCMBuffer) -> Bool {
        let canAccept = sharedState.lifecycle.withLock { state in
            !state.isClosed && state.failureMessage == nil
        }
        guard canAccept else { return false }

        switch continuation.yield(AudioBufferEnvelope(buffer: buffer)) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            sharedState.lifecycle.withLock { state in
                state.failureMessage =
                    RollingAudioRecorderError.queueOverflow.localizedDescription
                state.isClosed = true
            }
            continuation.finish()
            return false
        @unknown default:
            sharedState.lifecycle.withLock { state in
                state.failureMessage =
                    RollingAudioRecorderError.queueOverflow.localizedDescription
                state.isClosed = true
            }
            continuation.finish()
            return false
        }
    }

    var rejectionErrorDescription: String? {
        sharedState.lifecycle.withLock { state in
            state.failureMessage
        }
    }

    func finish(commitCurrentSegment: Bool) async throws
        -> [MobileAudioSegment]
    {
        sharedState.lifecycle.withLock { state in
            state.commitCurrentSegment = commitCurrentSegment
            state.isClosed = true
        }
        continuation.finish()
        return try await workerTask.value
    }
}

private struct AudioBufferEnvelope: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private struct RollingAudioFileWorker {
    private let sessionID: UUID
    private let directoryURL: URL
    private let segmentDuration: TimeInterval

    private var sequenceNumber: UInt64 = 0
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var partialURL: URL?
    private var framesWritten: AVAudioFramePosition = 0
    private var completedSegments: [MobileAudioSegment] = []

    init(
        sessionID: UUID,
        directoryURL: URL,
        segmentDuration: TimeInterval
    ) {
        self.sessionID = sessionID
        self.directoryURL = directoryURL
        self.segmentDuration = segmentDuration
    }

    mutating func run(
        stream: AsyncStream<AudioBufferEnvelope>,
        commitOnEnd: () -> Bool
    ) async throws -> [MobileAudioSegment] {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        do {
            for await envelope in stream {
                try append(envelope.buffer)
            }
            try closeCurrentSegment(commit: commitOnEnd())
            return completedSegments
        } catch {
            try? closeCurrentSegment(commit: false)
            throw error
        }
    }

    private mutating func append(_ buffer: AVAudioPCMBuffer) throws {
        if let fileFormat, fileFormat != buffer.format {
            try closeCurrentSegment(commit: true)
        }

        let maximumFrames = AVAudioFramePosition(
            max(1, buffer.format.sampleRate * segmentDuration)
        )
        if framesWritten > 0,
           framesWritten + AVAudioFramePosition(buffer.frameLength) >
           maximumFrames {
            try closeCurrentSegment(commit: true)
        }

        if file == nil {
            try openSegment(format: buffer.format)
        }
        guard let file else {
            throw RollingAudioRecorderError.writerFailed(
                "没有可用的 AVAudioFile。"
            )
        }
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    private mutating func openSegment(format: AVAudioFormat) throws {
        let fileName = try RollingSegmentFileNaming.fileName(
            sessionID: sessionID,
            sequenceNumber: sequenceNumber,
            fileExtension: "caf",
            state: .partial
        )
        let url = directoryURL.appendingPathComponent(fileName)

        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        fileFormat = format
        partialURL = url
        framesWritten = 0
    }

    private mutating func closeCurrentSegment(commit: Bool) throws {
        guard
            file != nil,
            let fileFormat,
            let partialURL
        else {
            return
        }

        file = nil
        let state: RollingSegmentFileState
        let finalURL: URL
        if commit {
            let committedName = try RollingSegmentFileNaming.fileName(
                sessionID: sessionID,
                sequenceNumber: sequenceNumber,
                fileExtension: "caf",
                state: .committed
            )
            finalURL = directoryURL.appendingPathComponent(committedName)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(
                at: partialURL,
                to: finalURL
            )
            state = .committed
        } else {
            finalURL = partialURL
            state = .partial
        }

        completedSegments.append(
            MobileAudioSegment(
                sequenceNumber: sequenceNumber,
                fileName: finalURL.lastPathComponent,
                state: state,
                frameCount: Int64(framesWritten),
                sampleRate: fileFormat.sampleRate,
                channelCount: fileFormat.channelCount
            )
        )
        sequenceNumber += 1
        self.fileFormat = nil
        self.partialURL = nil
        framesWritten = 0
    }
}
#endif
