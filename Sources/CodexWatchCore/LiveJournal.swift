import Foundation

/// Metadata only. Audio and transcripts never travel in diagnostic logs.
public struct JournalClip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var transcript: String?
    public var summary: String?
    public var issue: String?
    public var phase: Phase
    public enum Phase: String, Codable, Sendable {
        case waitingForPhone, waitingForTranscription, transcribing, waitingForSummary, ready, failed
        public var title: String {
            switch self {
            case .waitingForPhone: "待同步"
            case .waitingForTranscription: "待转写"
            case .transcribing: "正在转写"
            case .waitingForSummary: "原文已就绪 · 待总结"
            case .ready: "已整理"
            case .failed: "需重试"
            }
        }
    }
    public init(id: UUID = UUID(), sessionID: UUID, startedAt: Date, endedAt: Date) throws {
        guard endedAt >= startedAt, endedAt.timeIntervalSince(startedAt) <= 120 else { throw JournalError.invalidClip }
        self.id = id; self.sessionID = sessionID; self.startedAt = startedAt; self.endedAt = endedAt
        phase = .waitingForPhone
    }
    public var audioName: String { id.uuidString + ".m4a" }
    public var resumePhase: Phase { transcript == nil ? .waitingForTranscription : .waitingForSummary }
    public func validated() throws -> Self {
        _ = try Self(id: id, sessionID: sessionID, startedAt: startedAt, endedAt: endedAt)
        return self
    }
}

/// Drain newly arrived clips too, but never spin on an unavailable local model.
public struct JournalProcessingPass {
    private var attempted: Set<UUID> = []
    public init() {}
    public mutating func next(in clips: [JournalClip]) -> UUID? {
        guard let clip = clips.first(where: {
            !attempted.contains($0.id) && [.waitingForTranscription, .waitingForSummary].contains($0.phase)
        }) else { return nil }
        attempted.insert(clip.id)
        return clip.id
    }
}

public enum JournalError: LocalizedError {
    case invalidClip, storageFull, localSpeechUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidClip: "录音片段信息无效。"
        case .storageFull: "录音储存空间已达上限，请先同步或删除已保存片段。"
        case .localSpeechUnavailable: "本机中文语音识别暂不可用。音频已保留，请准备本地语音模型后重试。"
        }
    }
}

public enum JournalFiles {
    public static let metadataKey = "journal.clip.v1"
    public static func directory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LiveJournal", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return root
    }
    public static func load(from directory: URL) throws -> [JournalClip] {
        let url = directory.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([JournalClip].self, from: Data(contentsOf: url))
    }
    public static func save(_ clips: [JournalClip], to directory: URL) throws {
        let data = try JSONEncoder().encode(clips)
        #if os(iOS) || os(watchOS)
        try data.write(to: directory.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        #endif
    }
    public static func audioBytes(in directory: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "m4a" }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
