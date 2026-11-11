#if os(watchOS)
import AVFoundation
import CodexWatchCore
import SwiftUI
import WatchConnectivity

@MainActor
public final class WatchJournalRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    public static let shared = WatchJournalRecorder()
    @Published public private(set) var recording = false
    @Published public private(set) var starting = false
    @Published public private(set) var clips: [JournalClip] = []
    @Published public private(set) var issue: String?
    private var recorder: AVAudioRecorder?
    private var currentID: UUID?
    private var startedAt: Date?
    private var sessionID = UUID()
    private var directory: URL?

    private override init() {
        super.init()
        do {
            let root = try JournalFiles.directory()
            clips = try JournalFiles.load(from: root); directory = root
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.lastPathComponent.hasSuffix(".pending.json") {
                guard var clip = try? JSONDecoder().decode(JournalClip.self, from: Data(contentsOf: url)),
                      let audio = try? AVAudioPlayer(contentsOf: root.appendingPathComponent(clip.audioName)), audio.duration > 0 else { continue }
                clip.endedAt = clip.startedAt.addingTimeInterval(min(120, audio.duration))
                if !clips.contains(where: { $0.id == clip.id }) { clips.append(clip) }
                try JournalFiles.save(clips, to: root)
                try? FileManager.default.removeItem(at: url)
            }
        } catch { directory = nil; issue = "无法读取录音队列，原文件未删除：\(error.localizedDescription)" }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.stop(); self.issue = "录音被系统打断，已保存完成的片段。请手动继续。"
            }
        }
    }

    public func start() async {
        guard !recording, !starting, directory != nil else { return }
        starting = true; defer { starting = false }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { @Sendable allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard allowed else { issue = "请在手表设置中允许随行使用麦克风。"; return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .default)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audio.activate(options: []) { @Sendable success, error in
                    if let error { continuation.resume(throwing: error) }
                    else if success { continuation.resume() }
                    else { continuation.resume(throwing: JournalError.localSpeechUnavailable) }
                }
            }
            sessionID = UUID(); issue = nil; recording = true
            try beginSegment(); publishStatus(); flushPending()
        } catch { stop(); issue = error.localizedDescription }
    }

    public func stop() {
        recording = false
        let previous = recorder; recorder = nil
        previous?.stop()
        finishSegment()
        try? AVAudioSession.sharedInstance().setActive(false)
        publishStatus()
    }

    private func beginSegment() throws {
        guard let directory else { throw JournalError.storageFull }
        guard JournalFiles.audioBytes(in: directory) < 256 * 1024 * 1024 else { throw JournalError.storageFull }
        let id = UUID()
        let start = Date()
        let pending = try JournalClip(id: id, sessionID: sessionID, startedAt: start, endedAt: start.addingTimeInterval(30))
        try JSONEncoder().encode(pending).write(to: directory.appendingPathComponent(id.uuidString + ".pending.json"), options: .atomic)
        let audio = try AVAudioRecorder(url: directory.appendingPathComponent(id.uuidString + ".m4a"), settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000
        ])
        audio.delegate = self
        guard audio.record(forDuration: 30) else { throw JournalError.localSpeechUnavailable }
        currentID = id; startedAt = start; recorder = audio
    }

    private func finishSegment() {
        guard let id = currentID, let start = startedAt, let directory else { return }
        currentID = nil; startedAt = nil
        do {
            let clip = try JournalClip(id: id, sessionID: sessionID, startedAt: start, endedAt: Date())
            clips.append(clip); try JournalFiles.save(clips, to: directory)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".pending.json"))
            flushPending()
        } catch { issue = "音频已留在手表，索引保存失败：\(error.localizedDescription)"; recording = false }
    }

    nonisolated public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let finishedID = UUID(uuidString: recorder.url.deletingPathExtension().lastPathComponent)
        Task { @MainActor in
            guard self.currentID == finishedID else { return }
            self.finishSegment()
            guard self.recording else { return }
            guard flag else { self.stop(); self.issue = "系统结束了录音，请检查已保存片段。"; return }
            do { try self.beginSegment(); self.publishStatus() }
            catch { self.stop(); self.issue = error.localizedDescription }
        }
    }

    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.stop(); self.issue = "录音编码失败，已停止；请检查已保存片段。" }
    }

    public func flushPending() {
        guard WCSession.default.activationState == .activated, let directory else { return }
        let scheduled = Set(WCSession.default.outstandingFileTransfers.compactMap { $0.file.metadata?["journal.id"] as? String })
        for clip in clips where !scheduled.contains(clip.id.uuidString) {
            guard let metadata = try? JSONEncoder().encode(clip) else { continue }
            WCSession.default.transferFile(directory.appendingPathComponent(clip.audioName), metadata: [JournalFiles.metadataKey: metadata, "journal.id": clip.id.uuidString])
        }
    }

    public func acknowledge(_ rawID: String) {
        guard let id = UUID(uuidString: rawID), let directory, let clip = clips.first(where: { $0.id == id }) else { return }
        do {
            let remaining = clips.filter { $0.id != id }
            try JournalFiles.save(remaining, to: directory)
            clips = remaining
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(clip.audioName))
        } catch { issue = "手机已收到，手表队列更新失败。" }
    }

    private func publishStatus() {
        guard WCSession.default.activationState == .activated else { return }
        let payload: [String: Any] = ["journal.recording": recording, "journal.updatedAt": Date().timeIntervalSince1970]
        WCSession.default.transferUserInfo(payload)
        if WCSession.default.isReachable { WCSession.default.sendMessage(payload, replyHandler: nil) }
    }
}

public struct WatchJournalView: View {
    @ObservedObject private var recorder = WatchJournalRecorder.shared
    public init() {}
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(recorder.recording ? "正在录音" : "实时记录", systemImage: recorder.recording ? "record.circle.fill" : "waveform")
                    .foregroundStyle(recorder.recording ? .red : .blue).font(.headline)
                Text("每 30 秒保存一段，送到手机转写和整理。离线时保留在手表。")
                    .font(.caption2).foregroundStyle(.secondary)
                if recorder.recording {
                    Button("暂停并保存", role: .destructive) { recorder.stop() }
                        .accessibilityIdentifier("journal.stop")
                } else {
                    Button(recorder.starting ? "正在准备…" : "开始实时记录") { Task { await recorder.start() } }
                        .disabled(recorder.starting).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("journal.start")
                }
                Text("待手机接收：\(recorder.clips.count) 段").font(.caption)
                if let issue = recorder.issue { Text(issue).font(.caption2).foregroundStyle(.orange) }
                Button("重试同步") { recorder.flushPending() }.font(.caption)
                Text("在手机“工具 → 实时记录”查看原文与今日时间线。录音会持续用电；系统打断后需手动继续。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.navigationTitle("实时记录")
    }
}
#endif
