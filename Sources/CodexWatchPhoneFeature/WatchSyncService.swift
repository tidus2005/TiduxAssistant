import CodexWatchCore
import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

@MainActor
public final class WatchSyncService: NSObject {
    public var onCommand: ((BridgeCommand) -> Void)?
    public var onCommandWithResult: ((BridgeCommand) async -> CommandResult)?
    public var onRefreshRequest: (() -> Void)?
    private let bridgeConnectionStore: BridgeConnectionStore
    private let chatGPTHandoffStore: ChatGPTHandoffStore

    public init(bridgeConnectionStore: BridgeConnectionStore = BridgeConnectionStore(), chatGPTHandoffStore: ChatGPTHandoffStore = .shared) {
        self.bridgeConnectionStore = bridgeConnectionStore
        self.chatGPTHandoffStore = chatGPTHandoffStore
        super.init()
        activate()
    }

    public func sync(state: BridgeState) async throws {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let message = try makeSyncMessage(state: state)
        try WCSession.default.updateApplicationContext(message)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil)
        }
        #endif
    }

    func makeSyncMessage(state: BridgeState) throws -> [String: Any] {
        var message: [String: Any] = [
            WatchConnectivityMessageKey.chatGPTConversation: try JSONEncoder.codexWatchPet.encode(chatGPTHandoffStore.conversation),
            WatchConnectivityMessageKey.bridgeState: try JSONEncoder.codexWatchPet.encode(state)
        ]
        if let configuration = bridgeConnectionStore.load() {
            message[WatchConnectivityMessageKey.bridgeConnection] = try JSONEncoder.codexWatchPet.encode(configuration)
        }
        return message
    }

    func receiveChatGPTDraft(_ draft: ChatGPTHandoffDraft) -> ChatGPTHandoffReceipt {
        do {
            try chatGPTHandoffStore.receive(draft)
            return ChatGPTHandoffReceipt(draftID: draft.id, receivedOnPhone: true, message: "手机已保存草稿。请在随行 App 的 ChatGPT 接续页打开原会话并发送；尚未发送到 ChatGPT。")
        } catch {
            return ChatGPTHandoffReceipt(draftID: draft.id, receivedOnPhone: false, message: error.localizedDescription)
        }
    }

    private func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        #endif
    }
}

#if canImport(WatchConnectivity)
// WatchConnectivity's reply closure is invoked exactly once on the main actor.
private final class WatchReply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
    init(_ send: @escaping ([String: Any]) -> Void) { self.send = send }
}

extension WatchSyncService: WCSessionDelegate {
    #if os(iOS)
    nonisolated public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata?[JournalFiles.metadataKey] as? Data else { return }
        do {
            let (url, clip) = try PhoneJournalStore.stage(file.fileURL, metadata: metadata)
            Task { @MainActor in PhoneJournalStore.shared.receive(url, clip: clip) }
        } catch {
            // No ACK: the Watch retains its audio and can retry. Never log audio or transcript.
        }
    }
    private nonisolated func receiveJournalStatus(_ message: [String: Any]) -> Bool {
        guard let recording = message["journal.recording"] as? Bool,
              let timestamp = message["journal.updatedAt"] as? Double else { return false }
        Task { @MainActor in PhoneJournalStore.shared.receiveStatus(recording: recording, at: Date(timeIntervalSince1970: timestamp)) }
        return true
    }
    #endif
    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.onRefreshRequest?() }
    }
    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let data = message[WatchConnectivityMessageKey.chatGPTDraft] as? Data,
           let draft = try? JSONDecoder.codexWatchPet.decode(ChatGPTHandoffDraft.self, from: data) {
            let reply = WatchReply(replyHandler)
            Task { @MainActor in
                let receipt = self.receiveChatGPTDraft(draft)
                let data = try? JSONEncoder.codexWatchPet.encode(receipt)
                reply.send(data.map { [WatchConnectivityMessageKey.chatGPTReceipt: $0] } ?? [:])
            }
            return
        }
        guard let data = message[WatchConnectivityMessageKey.bridgeCommand] as? Data,
              let command = try? JSONDecoder.codexWatchPet.decode(BridgeCommand.self, from: data) else {
            replyHandler([:])
            return
        }
        let reply = WatchReply(replyHandler)
        Task { @MainActor in
            let result = await self.onCommandWithResult?(command)
                ?? CommandResult(commandId: command.id, accepted: false, message: "手机控制服务未就绪。")
            let data = try? JSONEncoder.codexWatchPet.encode(result)
            reply.send(data.map { [WatchConnectivityMessageKey.bridgeCommandResult: $0] } ?? [:])
        }
    }

    nonisolated public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.onRefreshRequest?() }
    }

    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        #if os(iOS)
        if receiveJournalStatus(message) { return }
        #endif
        if message[WatchConnectivityMessageKey.bridgeRefreshRequest] != nil {
            Task { @MainActor in
                self.onRefreshRequest?()
            }
            return
        }

        guard let data = message[WatchConnectivityMessageKey.bridgeCommand] as? Data,
              let command = try? JSONDecoder.codexWatchPet.decode(BridgeCommand.self, from: data) else { return }
        Task { @MainActor in
            self.onCommand?(command)
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        #if os(iOS)
        if receiveJournalStatus(userInfo) { return }
        #endif
        guard userInfo[WatchConnectivityMessageKey.bridgeRefreshRequest] != nil else { return }
        Task { @MainActor in
            self.onRefreshRequest?()
        }
    }

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            WCSession.default.activate()
        }
    }
    #endif
}
#endif
