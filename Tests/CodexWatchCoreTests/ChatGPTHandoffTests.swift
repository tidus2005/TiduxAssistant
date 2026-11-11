import CodexWatchCore
import Foundation
import Testing

@Suite("ChatGPT same-account handoff")
@MainActor
struct ChatGPTHandoffTests {
    let id = "aaff1234-1234-1234-1234-123456789abc"

    @Test func validatesPrivateConversationLinksAndDropsTrackingQuery() throws {
        let target = try ChatGPTConversation(name: "  开发讨论 ", link: "https://chatgpt.com/c/\(id)?utm_source=test#section")
        #expect(target.name == "开发讨论")
        #expect(target.url.absoluteString == "https://chatgpt.com/c/\(id)")
        #expect(try ChatGPTConversation(name: "", link: "https://chat.openai.com/c/\(id)").url == target.url)
        #expect(try ChatGPTConversation(name: "project", link: "https://chatgpt.com/g/g-p-example/c/\(id)").url.host == "chatgpt.com")
    }

    @Test func refusesSharedLinksCredentialsAndLookalikeHosts() {
        for url in ["http://chatgpt.com/c/\(id)", "https://chatgpt.com.evil.test/c/\(id)", "https://chatgpt.com/share/\(id)", "https://user@chatgpt.com/c/\(id)", "https://chatgpt.com:444/c/\(id)", "https://chatgpt.com/c/not-a-conversation", "https://example.com/c/\(id)"] {
            #expect(throws: ChatGPTHandoffError.self) { try ChatGPTConversation(name: "bad", link: url) }
        }
    }

    @Test func receivedDraftIsPersistentAndIdempotentButNotSentToChatGPT() throws {
        let suite = "HandoffTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatGPTHandoffStore(defaults: defaults)
        let conversation = try ChatGPTConversation(name: "test", link: "https://chatgpt.com/c/\(id)")
        try store.setConversation(conversation)
        let draft = try ChatGPTHandoffDraft(conversation: conversation, text: " hello ")
        try store.receive(draft)
        try store.receive(draft)
        #expect(store.drafts.count == 1)
        #expect(store.drafts.first?.text == "hello")
        #expect(ChatGPTHandoffStore(defaults: defaults).drafts.first?.id == draft.id)
        let collision = try ChatGPTHandoffDraft(id: draft.id, conversation: conversation, text: "different")
        #expect(throws: ChatGPTHandoffError.self) { try store.receive(collision) }
    }

    @Test func staleOrRetargetedDraftIsRejected() throws {
        let suite = "HandoffScopeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatGPTHandoffStore(defaults: defaults)
        let conversation = try ChatGPTConversation(name: "test", link: "https://chatgpt.com/c/\(id)")
        let now = Date()
        try store.setConversation(conversation)
        let stale = try ChatGPTHandoffDraft(conversation: conversation, text: "hello", createdAt: now.addingTimeInterval(-121))
        #expect(throws: ChatGPTHandoffError.self) { try store.receive(stale, now: now) }
        let draft = try ChatGPTHandoffDraft(conversation: conversation, text: "hello")
        try store.setConversation(nil)
        #expect(throws: ChatGPTHandoffError.self) { try store.receive(draft) }
        #expect(store.drafts.isEmpty)
    }
}
