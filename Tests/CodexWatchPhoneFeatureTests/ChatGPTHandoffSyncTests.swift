@testable import CodexWatchPhoneFeature
import CodexWatchCore
import Foundation
import Testing

@Suite("ChatGPT phone handoff sync")
@MainActor
struct ChatGPTHandoffSyncTests {
    @Test func phoneReceiptMeansSavedDraftAndSettingsSyncWithoutBridge() throws {
        let suite = "HandoffSync-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatGPTHandoffStore(defaults: defaults)
        let conversation = try ChatGPTConversation(name: "会话", link: "https://chatgpt.com/c/aaff1234-1234-1234-1234-123456789abc")
        try store.setConversation(conversation)
        let service = WatchSyncService(bridgeConnectionStore: BridgeConnectionStore(defaults: defaults), chatGPTHandoffStore: store)
        let draft = try ChatGPTHandoffDraft(conversation: conversation, text: "测试草稿")
        let receipt = service.receiveChatGPTDraft(draft)
        #expect(receipt.receivedOnPhone)
        #expect(receipt.message.contains("尚未发送到 ChatGPT"))
        #expect(store.drafts.count == 1)
        let state = BridgeState(snapshots: [], events: [], unreadHighUrgencyCount: 0, bridgeOnline: false, pairStatus: PairStatus(paired: false))
        let message = try service.makeSyncMessage(state: state)
        let data = try #require(message[WatchConnectivityMessageKey.chatGPTConversation] as? Data)
        #expect(try JSONDecoder.codexWatchPet.decode(ChatGPTConversation.self, from: data) == conversation)
        try store.setConversation(nil)
        let reset = try service.makeSyncMessage(state: state)
        let resetData = try #require(reset[WatchConnectivityMessageKey.chatGPTConversation] as? Data)
        #expect(try JSONDecoder.codexWatchPet.decode(ChatGPTConversation?.self, from: resetData) == nil)
    }
}
