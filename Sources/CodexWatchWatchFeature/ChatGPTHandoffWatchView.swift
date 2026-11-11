import CodexWatchCore
import SwiftUI

public struct ChatGPTHandoffWatchView: View {
    @ObservedObject private var inbox: WatchStateInbox
    @ObservedObject private var store = ChatGPTHandoffStore.shared
    @State private var text = ""
    @State private var review: ChatGPTHandoffDraft?
    @State private var error: String?
    public init(inbox: WatchStateInbox) { self.inbox = inbox }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("ChatGPT 原会话", systemImage: "bubble.left.and.bubble.right").font(.headline)
                if let conversation = store.conversation {
                    Text(conversation.name).font(.caption)
                    TextField("说话或输入内容", text: $text).accessibilityIdentifier("chatgpt.dictate")
                    Text("点输入框使用系统听写。").font(.caption2).foregroundStyle(.secondary)
                    Button("检查并送到手机") {
                        do { review = try ChatGPTHandoffDraft(conversation: conversation, text: text); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inbox.isSendingChatGPTDraft)
                        .accessibilityIdentifier("chatgpt.review")
                } else {
                    Text("先在 iPhone 随行 App → 工具 → ChatGPT 接续，保存原会话链接。").font(.caption)
                }
                Text("手机收到后，在 ChatGPT 中发送并继续语音。回复暂不回传手表。").font(.caption2).foregroundStyle(.secondary)
                if let message = error ?? inbox.chatGPTHandoffStatus { Text(message).font(.caption).foregroundStyle(.cyan) }
                Button("刷新配置") { inbox.requestRefresh() }
            }.padding(.horizontal)
        }
        .navigationTitle("ChatGPT 接续")
        .task { inbox.requestRefresh() }
        .sheet(item: $review) { draft in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("确认草稿").font(.headline)
                    Text(draft.conversation.name).font(.caption)
                    Text(draft.conversation.url.absoluteString).font(.caption2)
                    Text(draft.text).font(.caption)
                    Text("仅保存到手机，不会自动在 ChatGPT 发送。").font(.caption2).foregroundStyle(.secondary)
                    Button("确认送到手机") {
                        guard store.conversation == draft.conversation, Date().timeIntervalSince(draft.createdAt) <= 120 else {
                            error = "会话配置已变化或确认已过期，请重新检查。"; review = nil; return
                        }
                        inbox.sendChatGPTDraft(draft)
                        review = nil
                    }.disabled(inbox.isSendingChatGPTDraft).accessibilityIdentifier("chatgpt.confirm")
                    Button("取消", role: .cancel) { review = nil }
                }.padding()
            }
        }
    }
}
