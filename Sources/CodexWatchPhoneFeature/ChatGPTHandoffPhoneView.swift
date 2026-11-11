import CodexWatchCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct ChatGPTHandoffPhoneView: View {
    @ObservedObject private var store: ChatGPTHandoffStore
    @Environment(\.openURL) private var openURL
    @State private var name = ""
    @State private var link = ""
    @State private var message: String?
    private let onSync: () -> Void

    public init(store: ChatGPTHandoffStore = .shared, onSync: @escaping () -> Void = {}) {
        self.store = store; self.onSync = onSync
    }

    public var body: some View {
        Form {
            Section("沿用现有 ChatGPT 账号") {
                Text("手表把听写内容送到这里。打开原会话后，在 ChatGPT 中粘贴、发送，或继续语音交流。")
                Text("草稿送达手机不代表已发送到 ChatGPT；回复仍在 ChatGPT 中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("指定原会话") {
                TextField("会话名称", text: $name).accessibilityIdentifier("chatgpt.name")
                TextField("https://chatgpt.com/c/…", text: $link)
                    .autocorrectionDisabled().accessibilityIdentifier("chatgpt.link")
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Text("在已登录的 ChatGPT 网页打开目标会话，复制地址栏链接。不要点“分享”创建公开链接。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存并同步到手表") {
                    do {
                        try store.setConversation(ChatGPTConversation(name: name, link: link))
                        onSync()
                        message = "已保存会话。请确认官方 ChatGPT 中登录的是你要使用的账号。"
                    } catch { message = error.localizedDescription }
                }.accessibilityIdentifier("chatgpt.save")
                if store.conversation != nil {
                    Button("移除会话配置", role: .destructive) {
                        try? store.setConversation(nil)
                        name = ""; link = ""; onSync()
                    }
                }
            }
            if let message { Section { Text(message).font(.caption) } }
            Section("手表送来的草稿 · \(store.drafts.count)") {
                if store.drafts.isEmpty { Text("暂无草稿").foregroundStyle(.secondary) }
                ForEach(store.drafts) { draft in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(draft.conversation.name).font(.headline)
                        Text(draft.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(draft.text).textSelection(.enabled)
                        Text("待在 ChatGPT 中发送").font(.caption).foregroundStyle(.orange)
                        Button("复制草稿并打开原会话") { open(draft) }
                        Button("删除草稿", role: .destructive) { store.remove(id: draft.id) }
                    }.padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("ChatGPT 接续")
        .onAppear { name = store.conversation?.name ?? ""; link = store.conversation?.url.absoluteString ?? "" }
    }

    private func open(_ draft: ChatGPTHandoffDraft) {
        guard let target = try? draft.conversation.validated() else { message = ChatGPTHandoffError.invalidLink.localizedDescription; return }
        #if os(iOS)
        UIPasteboard.general.setItems([["public.utf8-plain-text": draft.text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        #endif
        openURL(target.url) { accepted in
            message = accepted ? "已请求打开原会话。请检查账号和会话，粘贴并发送；尚未确认 ChatGPT 收到。" : "无法打开会话。草稿仍保留，请手动打开 ChatGPT。"
        }
    }
}
