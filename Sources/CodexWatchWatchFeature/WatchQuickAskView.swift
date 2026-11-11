import CodexWatchCore
import SwiftUI

struct WatchQuickAskView: View {
    @ObservedObject var inbox: WatchStateInbox
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var draft: WatchQuestionDraft?
    @State private var error: String?
    @State private var sentCommandID: String?
    @State private var answer: String?
    @State private var expanded = false
    @AppStorage(WristReplyPolicy.conciseKey) private var concise = true
    @StateObject private var speaker = WatchReplySpeaker()

    private var canSend: Bool { CompanionConnectionPresentation(bridgeOnline: inbox.state.bridgeOnline, savedAt: inbox.state.generatedAt).canSend }

    private var waiting: Bool { sentCommandID != nil && answer == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let answer {
                        Label("回复", systemImage: "sparkles").font(.caption).foregroundStyle(.blue)
                        Text(concise && !expanded ? WristReplyPolicy.preview(answer) : answer).font(.body)
                        if concise && answer.count > 140 { Button(expanded ? "收起" : "查看全文") { expanded.toggle() }.font(.caption) }
                        Button { speaker.speak(answer) } label: { Label("朗读", systemImage: "speaker.wave.2") }
                        Button("停止朗读") { speaker.stop() }.font(.caption)
                        Button("再问一个") { sentCommandID = nil; self.answer = nil; text = "" }
                            .buttonStyle(.borderedProminent).tint(.blue)
                    } else {
                        Image(systemName: "waveform").font(.system(size: 28, weight: .medium)).foregroundStyle(.blue)
                            .accessibilityHidden(true)
                        Text("想让 AI 做什么？").font(.headline)
                        TextField("说话或输入", text: $text).accessibilityIdentifier("quickAsk.input")
                        Text("点击输入框，使用系统听写。")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button(waiting ? "等待回复…" : "下一步") {
                            do { draft = try WatchQuestionDraft(text: text); error = nil }
                            catch { self.error = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).tint(.blue)
                            .disabled(!canSend || waiting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("quickAsk.review")
                        if !canSend {
                            Label("先连接 Mac", systemImage: "link").font(.caption).foregroundStyle(.orange)
                            Text("在 iPhone“设备”页添加 Mac，再回到这里刷新。输入的内容会保留。")
                                .font(.caption2).foregroundStyle(.secondary)
                            Button("刷新连接") { inbox.requestRefresh() }.font(.caption)
                        }
                        if let sentCommandID {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(inbox.lastCommandResult?.commandId == sentCommandID && inbox.lastCommandResult?.accepted == true ? "Mac 已接收，正在处理" : "正在发送，等待回执")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if inbox.lastCommand?.id == sentCommandID, let message = inbox.lastCommandError {
                                Text(message).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                    if let error { Text(error).font(.caption2).foregroundStyle(.orange) }
                }.padding(.horizontal, 2)
            }
            .navigationTitle("快速提问")
            .sheet(item: $draft) { review in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("确认提问").font(.headline)
                        Text(review.text).font(.caption)
                        Text("将在 Mac 上新建任务。").font(.caption2)
                        Button("确认发送") {
                            do {
                                let command = try review.confirmed()
                                sentCommandID = command.id
                                answer = nil
                                inbox.send(command)
                                draft = nil
                            } catch { self.error = error.localizedDescription; draft = nil }
                        }.disabled(!canSend || waiting)
                        .accessibilityIdentifier("quickAsk.confirm")
                        Button("取消", role: .cancel) { draft = nil }
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
            .onChange(of: inbox.state.events) { _, events in
                guard let sentCommandID,
                      let reply = events.last(where: { $0.id.hasPrefix("run-\(sentCommandID)-") &&
                          ($0.type == .turnCompleted || $0.type == .turnFailed) }) else { return }
                answer = reply.summary
                speaker.speakAutomatically(reply.summary, active: scenePhase == .active)
            }
            .onChange(of: inbox.lastCommandResult) { _, result in
                if let result, result.commandId == sentCommandID, !result.accepted {
                    error = result.message
                    sentCommandID = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { speaker.stop() } }
            .onDisappear { speaker.stop() }
        }
    }
}
