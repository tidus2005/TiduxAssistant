import Combine
import Foundation

public struct ChatGPTConversation: Codable, Hashable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, link: String) throws {
        guard let parts = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", ["chatgpt.com", "chat.openai.com"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil else { throw ChatGPTHandoffError.invalidLink }
        let path = parts.path.split(separator: "/").map(String.init)
        let validPath = (path.count == 2 && path[0] == "c") || (path.count == 4 && path[0] == "g" && path[2] == "c" && path[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        guard validPath, let id = path.last, UUID(uuidString: id) != nil,
              let url = URL(string: "https://chatgpt.com/" + path.joined(separator: "/")) else { throw ChatGPTHandoffError.invalidLink }
        self.url = url
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = title.isEmpty ? "我的 ChatGPT 会话" : String(title.prefix(80))
    }

    public func validated() throws -> Self { try Self(name: name, link: url.absoluteString) }
}

public struct ChatGPTHandoffDraft: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let conversation: ChatGPTConversation
    public let text: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, conversation: ChatGPTConversation, text: String, createdAt: Date = Date()) throws {
        self.conversation = try conversation.validated()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4000 else { throw ChatGPTHandoffError.invalidText }
        self.id = id
        self.text = trimmed
        self.createdAt = createdAt
    }
}

public struct ChatGPTHandoffReceipt: Codable, Sendable {
    public let draftID: String
    public let receivedOnPhone: Bool
    public let message: String
    public init(draftID: String, receivedOnPhone: Bool, message: String) {
        self.draftID = draftID; self.receivedOnPhone = receivedOnPhone; self.message = message
    }
}

public enum ChatGPTHandoffError: LocalizedError {
    case invalidLink, invalidText, staleDraft, targetChanged, inboxFull, identifierConflict
    public var errorDescription: String? {
        switch self {
        case .invalidLink: "请粘贴 ChatGPT 原会话的 https://chatgpt.com/c/… 地址，不使用共享链接。"
        case .invalidText: "请输入 1 至 4000 字的内容。"
        case .staleDraft: "这份草稿已过期，请重新检查内容和目标会话。"
        case .targetChanged: "手机上的目标会话已改变，请同步后重新检查。"
        case .inboxFull: "手机有 20 份待处理草稿，请先处理或删除。"
        case .identifierConflict: "草稿编号冲突，请重新检查。"
        }
    }
}

@MainActor
public final class ChatGPTHandoffStore: ObservableObject {
    public static let shared = ChatGPTHandoffStore()
    @Published public private(set) var conversation: ChatGPTConversation?
    @Published public private(set) var drafts: [ChatGPTHandoffDraft]
    private let defaults: UserDefaults
    private static let conversationKey = "chatgptHandoff.conversation.v1"
    private static let draftsKey = "chatgptHandoff.drafts.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        conversation = defaults.data(forKey: Self.conversationKey)
            .flatMap { try? JSONDecoder.codexWatchPet.decode(ChatGPTConversation.self, from: $0) }
            .flatMap { try? $0.validated() }
        drafts = defaults.data(forKey: Self.draftsKey)
            .flatMap { try? JSONDecoder.codexWatchPet.decode([ChatGPTHandoffDraft].self, from: $0) } ?? []
        drafts = drafts.filter { Date().timeIntervalSince($0.createdAt) < 7 * 86400 }
        persistDrafts()
    }

    public func setConversation(_ value: ChatGPTConversation?) throws {
        conversation = try value?.validated()
        if let conversation { defaults.set(try JSONEncoder.codexWatchPet.encode(conversation), forKey: Self.conversationKey) }
        else { defaults.removeObject(forKey: Self.conversationKey) }
    }

    public func receive(_ draft: ChatGPTHandoffDraft, now: Date = Date()) throws {
        _ = try ChatGPTHandoffDraft(id: draft.id, conversation: draft.conversation, text: draft.text, createdAt: draft.createdAt)
        if let existing = drafts.first(where: { $0.id == draft.id }) {
            guard existing == draft else { throw ChatGPTHandoffError.identifierConflict }
            return
        }
        guard now.timeIntervalSince(draft.createdAt) <= 120, draft.createdAt.timeIntervalSince(now) <= 5 else { throw ChatGPTHandoffError.staleDraft }
        guard conversation == draft.conversation else { throw ChatGPTHandoffError.targetChanged }
        guard drafts.count < 20 else { throw ChatGPTHandoffError.inboxFull }
        drafts.insert(draft, at: 0)
        persistDrafts()
    }

    public func remove(id: String) { drafts.removeAll { $0.id == id }; persistDrafts() }
    private func persistDrafts() { if let data = try? JSONEncoder.codexWatchPet.encode(drafts) { defaults.set(data, forKey: Self.draftsKey) } }
}
