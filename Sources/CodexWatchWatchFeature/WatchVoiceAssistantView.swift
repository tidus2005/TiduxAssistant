import AVFoundation
import CodexWatchCore
import SwiftUI

@MainActor
final class WatchReplySpeaker: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var routeObserver: NSObjectProtocol?
    init() {
        #if os(watchOS) || os(iOS)
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.stop() }
            }
        }
        #endif
    }
    func speakAutomatically(_ text: String, active: Bool) {
        #if os(watchOS)
        let recording = WatchJournalRecorder.shared.recording
        #else
        let recording = false
        #endif
        #if os(watchOS) || os(iOS)
        let headphones = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
        if WristReplyPolicy.shouldPlay(headphones: headphones,
                                      autoHeadphones: UserDefaults.standard.bool(forKey: WristReplyPolicy.headphonesKey),
                                      autoSpeaker: UserDefaults.standard.bool(forKey: WristReplyPolicy.speakerKey),
                                      recording: recording, active: active) { speak(text) }
        #endif
    }
    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: String(text.prefix(3000)))
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

public struct WatchVoiceAssistantView: View {
    @ObservedObject private var inbox: WatchStateInbox
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speaker = WatchReplySpeaker()
    @State private var threadID: String
    @State private var transcript = ""
    @State private var review: AssistantCommandDraft?
    @State private var error: String?
    @State private var sentCommandID: String?
    @State private var awaitingReplyAfter: Date?
    @State private var showsTaskPicker = false

    public init(inbox: WatchStateInbox, threadID: String?) {
        self.inbox = inbox
        _threadID = State(initialValue: threadID ?? "")
    }

    private var snapshot: TaskSnapshot? { inbox.state.snapshots.first { $0.threadId == threadID } }
    private var isSending: Bool {
        guard let sentCommandID, inbox.lastCommand?.id == sentCommandID else { return false }
        return inbox.lastCommandResult?.commandId != sentCommandID && inbox.lastCommandError == nil
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    taskSummary
                    Divider()
                    replyComposer
                    requestActions
                    deliveryStatus
                    moreActions
                }.padding(.horizontal, 2)
            }
            .navigationTitle("任务对话")
            .navigationDestination(isPresented: $showsTaskPicker) {
                List(inbox.state.snapshots) { task in
                    Button {
                        threadID = task.threadId
                        showsTaskPicker = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(task.title).lineLimit(2)
                            Text(task.status.collaborationDisplayName).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.navigationTitle("选择任务")
            }
            .sheet(item: $review) { draft in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("确认本次操作").font(.headline)
                        Text(draft.summary).font(.caption)
                        Text("仅确认当前请求；发送回执不代表任务完成。").font(.caption2).foregroundStyle(.secondary)
                        Button("确认发送") { confirm(draft) }.disabled(isSending || !inbox.state.bridgeOnline)
                            .accessibilityIdentifier("assistant.confirm")
                        Button("取消", role: .cancel) { review = nil }
                    }.padding()
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    inbox.requestRefresh()
                    try? await Task.sleep(for: .seconds(8))
                }
            }
            .onChange(of: threadID) { _, _ in
                speaker.stop(); awaitingReplyAfter = nil; review = nil; transcript = ""; error = nil
            }
            .onChange(of: inbox.state.events) { _, events in
                guard scenePhase == .active, let after = awaitingReplyAfter, let commandID = sentCommandID,
                      let reply = events.filter({ $0.threadId == threadID && $0.createdAt > after && $0.type == .turnCompleted && $0.id.hasPrefix("run-\(commandID)-") }).max(by: { $0.createdAt < $1.createdAt }) else { return }
                awaitingReplyAfter = nil
                speaker.speakAutomatically(reply.summary, active: scenePhase == .active)
            }
            .onChange(of: inbox.lastCommandResult) { _, result in
                if result?.commandId == sentCommandID && result?.accepted == false { awaitingReplyAfter = nil }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { speaker.stop() } }
            .onDisappear { speaker.stop() }
        }
    }

    @ViewBuilder
    private var taskSummary: some View {
        if let snapshot {
            Text(snapshot.title).font(.headline).lineLimit(3)
            Label(snapshot.status.collaborationDisplayName, systemImage: snapshot.petMood.symbolName)
                .font(.caption2).foregroundStyle(.blue)
            Text(snapshot.lastSummary).font(.body)
            Button { speaker.speak(snapshot.lastSummary) } label: {
                Label("朗读最新回复", systemImage: "speaker.wave.2")
            }.font(.caption).accessibilityIdentifier("assistant.speak")
        } else {
            Text("选择一个任务，继续对话。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var canReply: Bool {
        snapshot != nil && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending && CompanionConnectionPresentation(bridgeOnline: inbox.state.bridgeOnline, savedAt: inbox.state.generatedAt).canSend
    }
    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("说话或输入回复", text: $transcript).accessibilityIdentifier("assistant.dictate")
            Button(isSending ? "正在发送…" : "检查回复") { stage(.continueThread) }
                .buttonStyle(.borderedProminent).tint(.blue).disabled(!canReply)
                .accessibilityIdentifier("assistant.review")
        }
    }
    @ViewBuilder
    private var requestActions: some View {
        if let pending = snapshot?.pendingRequest {
            Text(pending.summary).font(.caption)
            if pending.requiredAction == .approve {
                Button("检查并授权") { stage(.approve) }.tint(.blue)
                Button("拒绝操作", role: .destructive) { stage(.decline) }
            }
        }
    }
    @ViewBuilder
    private var deliveryStatus: some View {
        if let id = sentCommandID, let receipt = inbox.lastCommandResult, receipt.commandId == id {
            Text(receipt.accepted ? "Mac 已接收，等待任务更新" : receipt.message)
                .font(.caption2).foregroundStyle(.secondary)
        }
        if let message = error ?? inbox.lastCommandError {
            Text(message).font(.caption2).foregroundStyle(.orange)
        }
        if !inbox.state.bridgeOnline {
            Label("Mac 未连接", systemImage: "link").font(.caption).foregroundStyle(.orange)
            Text("请在 iPhone“设备”页连接 Mac。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var moreActions: some View {
        NavigationLink {
            List {
            Button("选择其他任务") { showsTaskPicker = true }.accessibilityIdentifier("assistant.task")
            Button("刷新任务") { inbox.requestRefresh() }
            NavigationLink("朗读与显示设置") { WristReplySettingsView() }
            Button("停止朗读") { speaker.stop() }
            if snapshot?.status == .active || snapshot?.status == .runningTool {
                Button("停止当前任务", role: .destructive) { stage(.interrupt) }
            }
            NavigationLink { ChatGPTHandoffWatchView(inbox: inbox) } label: { Text("接续 ChatGPT") }
            }.navigationTitle("任务操作")
        } label: { Label("更多操作", systemImage: "ellipsis") }
        .font(.caption)
    }

    private func stage(_ type: BridgeCommandType) {
        guard let snapshot else { return }
        do { review = try AssistantCommandDraft(snapshot: snapshot, type: type, text: type == .continueThread ? transcript : ""); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func confirm(_ draft: AssistantCommandDraft) {
        do {
            let command = try draft.confirmed(for: snapshot)
            sentCommandID = command.id
            awaitingReplyAfter = command.type == .continueThread && command.payload["requestId"] == nil ? Date() : nil
            inbox.send(command)
            review = nil
            error = nil
        } catch { self.error = error.localizedDescription; review = nil }
    }

}
