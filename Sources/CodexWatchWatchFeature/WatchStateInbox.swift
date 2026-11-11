import CodexWatchCore
import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

public enum WatchCommandDeliveryRoute: String, Equatable, Sendable {
    case phone
    case directBridge
    case queued
    case unavailable
}

public protocol WatchBridgeServicing: Sendable {
    func send(command: BridgeCommand, configuration: BridgeConnectionConfiguration) async throws -> CommandResult
    func fetchSnapshot(configuration: BridgeConnectionConfiguration) async throws -> BridgeState
}

public struct WatchBridgeService: WatchBridgeServicing {
    public init() {}

    public func send(command: BridgeCommand, configuration: BridgeConnectionConfiguration) async throws -> CommandResult {
        try await BridgeHTTPClient(configuration: configuration).send(command: command)
    }

    public func fetchSnapshot(configuration: BridgeConnectionConfiguration) async throws -> BridgeState {
        try await BridgeHTTPClient(configuration: configuration).fetchSnapshot()
    }
}

@MainActor
public final class WatchStateInbox: NSObject, ObservableObject {
    @Published public private(set) var chatGPTHandoffStatus: String?
    @Published public private(set) var isSendingChatGPTDraft = false
    private var chatGPTDraftID: String?
    @Published public private(set) var state: BridgeState
    @Published public private(set) var lastCommand: BridgeCommand?
    @Published public private(set) var lastCommandDeliveryRoute: WatchCommandDeliveryRoute?
    @Published public private(set) var lastCommandResult: CommandResult?
    @Published public private(set) var lastCommandError: String?
    @Published public private(set) var queuedCommandCount: Int
    @Published public private(set) var queuedCommands: [WatchQueuedCommand]
    @Published public private(set) var lastReceivedAt: Date?
    @Published public private(set) var lastRefreshRequestedAt: Date?
    private let widgetStateStore: WidgetStateStore
    private let bridgeConnectionStore: BridgeConnectionStore
    private let commandRetryStore: WatchCommandRetryStore
    private let bridgeService: any WatchBridgeServicing
    private let hapticPlanner: AttentionHapticPlanner
    private let hapticPlayer: any WatchHapticPlaying
    private var hapticState: AttentionHapticPlannerState
    private var isRetryingQueuedCommands = false

    public init(
        state: BridgeState,
        widgetStateStore: WidgetStateStore = WidgetStateStore(),
        bridgeConnectionStore: BridgeConnectionStore = BridgeConnectionStore(),
        commandRetryStore: WatchCommandRetryStore = WatchCommandRetryStore(),
        bridgeService: any WatchBridgeServicing = WatchBridgeService(),
        hapticPlanner: AttentionHapticPlanner = AttentionHapticPlanner(),
        hapticPlayer: any WatchHapticPlaying = WatchHapticPlayer()
    ) {
        self.state = state
        self.lastReceivedAt = state.hasReceivedBridgeData ? state.generatedAt : nil
        let queuedCommands = commandRetryStore.load()
        self.queuedCommands = queuedCommands
        self.queuedCommandCount = queuedCommands.count
        self.widgetStateStore = widgetStateStore
        self.bridgeConnectionStore = bridgeConnectionStore
        self.commandRetryStore = commandRetryStore
        self.bridgeService = bridgeService
        self.hapticPlanner = hapticPlanner
        self.hapticPlayer = hapticPlayer
        self.hapticState = AttentionHapticPlannerState(seenEventIds: Set(state.events.map(\.id)))
        super.init()
        // Launching a widget must not replace the last received snapshot with an empty startup state.
        if state.hasReceivedBridgeData { persistForWidgets(state) }
        activate()
    }

    public func send(_ command: BridgeCommand) {
        lastCommand = command
        lastCommandError = nil
        lastCommandResult = nil
        #if canImport(WatchConnectivity)
        if let data = try? JSONEncoder.codexWatchPet.encode(command),
           WCSession.isSupported(),
           WCSession.default.isReachable {
            lastCommandDeliveryRoute = .phone
            WCSession.default.sendMessage(
                [WatchConnectivityMessageKey.bridgeCommand: data],
                replyHandler: { [weak self] reply in
                    let data = reply[WatchConnectivityMessageKey.bridgeCommandResult] as? Data
                    Task { @MainActor in self?.receiveCommandReceipt(data, commandID: command.id) }
                },
                errorHandler: { [weak self] _ in
                    Task { @MainActor in
                        // A lost reply does not prove that the phone did not execute it.
                        self?.receiveCommandReceipt(nil, commandID: command.id)
                    }
                }
            )
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard let self, self.lastCommand?.id == command.id,
                      self.lastCommandResult == nil, self.lastCommandError == nil else { return }
                self.receiveCommandReceipt(nil, commandID: command.id)
            }
            return
        }
        #endif
        Task {
            await sendDirectToBridge(command)
        }
    }

    public func sendChatGPTDraft(_ draft: ChatGPTHandoffDraft) {
        guard !isSendingChatGPTDraft else { return }
        chatGPTDraftID = draft.id
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.isReachable,
              let data = try? JSONEncoder.codexWatchPet.encode(draft) else {
            chatGPTHandoffStatus = "手机暂不可达。请打开 iPhone 上的随行 App 后重试；尚未发送到 ChatGPT。"
            return
        }
        isSendingChatGPTDraft = true
        chatGPTHandoffStatus = "等待手机保存草稿…"
        WCSession.default.sendMessage([WatchConnectivityMessageKey.chatGPTDraft: data], replyHandler: { [weak self] reply in
            let data = reply[WatchConnectivityMessageKey.chatGPTReceipt] as? Data
            Task { @MainActor in self?.receiveChatGPTReceipt(data, draftID: draft.id) }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.receiveChatGPTReceipt(nil, draftID: draft.id) }
        })
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, self.chatGPTDraftID == draft.id, self.isSendingChatGPTDraft else { return }
            self.receiveChatGPTReceipt(nil, draftID: draft.id)
        }
        #else
        chatGPTHandoffStatus = "需要配对的 iPhone 来接续 ChatGPT。"
        #endif
    }

    private func receiveChatGPTReceipt(_ data: Data?, draftID: String) {
        guard chatGPTDraftID == draftID else { return }
        isSendingChatGPTDraft = false
        guard let data, let receipt = try? JSONDecoder.codexWatchPet.decode(ChatGPTHandoffReceipt.self, from: data),
              receipt.draftID == draftID else {
            chatGPTHandoffStatus = "未收到手机回执，请先查看手机的 ChatGPT 草稿列表；尚未确认保存。"
            return
        }
        chatGPTHandoffStatus = receipt.message
    }

    func receiveCommandReceipt(_ data: Data?, commandID: String) {
        guard lastCommand?.id == commandID else { return }
        guard let data, let result = try? JSONDecoder.codexWatchPet.decode(CommandResult.self, from: data),
              result.commandId == commandID else {
            lastCommandError = "未取得回执，操作可能已送达。请刷新并核实任务；不会自动重复授权。"
            return
        }
        lastCommandResult = result
        lastCommandError = result.accepted ? nil : result.message
        requestRefresh()
    }

    func sendDirectToBridge(_ command: BridgeCommand) async {
        lastCommand = command
        lastCommandResult = nil
        guard let configuration = bridgeConnectionStore.load() else {
            lastCommandDeliveryRoute = .unavailable
            lastCommandResult = nil
            lastCommandError = "Pair Codex Watch Pet on iPhone and sync to Watch first."
            return
        }

        lastCommandDeliveryRoute = .directBridge
        lastCommandError = nil
        do {
            let result = try await bridgeService.send(command: command, configuration: configuration)
            guard lastCommand?.id == command.id else { return }
            guard result.commandId == command.id else {
                lastCommandError = "回执与当前操作不匹配，请刷新后核实。"
                return
            }
            lastCommandResult = result
            guard result.accepted else { return }
            if let refreshedState = try? await bridgeService.fetchSnapshot(configuration: configuration) {
                apply(state: refreshedState)
            }
        } catch {
            guard lastCommand?.id == command.id else { return }
            queueForRetry(command, error: error.localizedDescription)
        }
    }

    public func retryQueuedCommands() async {
        guard !isRetryingQueuedCommands else { return }
        isRetryingQueuedCommands = true
        defer {
            isRetryingQueuedCommands = false
        }

        reloadQueuedCommands()
        let records = queuedCommands
        guard !records.isEmpty else { return }
        guard let configuration = bridgeConnectionStore.load() else {
            lastCommandDeliveryRoute = .unavailable
            lastCommandResult = nil
            lastCommandError = "Pair Codex Watch Pet on iPhone and sync to Watch first."
            return
        }

        var shouldRefresh = false
        for record in records {
            guard !record.command.requiresHighImpactConfirmation else {
                lastCommandError = "待确认操作不会自动重发，请刷新任务、核实结果后重新确认。"
                continue
            }
            let command = retryCommand(from: record.command)
            lastCommand = command
            lastCommandDeliveryRoute = .directBridge
            lastCommandError = nil
            do {
                let result = try await bridgeService.send(command: command, configuration: configuration)
                lastCommandResult = result
                commandRetryStore.remove(id: record.id)
                if result.accepted {
                    shouldRefresh = true
                } else {
                    lastCommandError = result.message
                }
            } catch {
                var failedRecord = record
                failedRecord.attemptCount += 1
                failedRecord.lastAttemptAt = Date()
                failedRecord.lastError = error.localizedDescription
                commandRetryStore.update(failedRecord)
                lastCommandDeliveryRoute = .queued
                lastCommandResult = nil
                lastCommandError = error.localizedDescription
            }
        }

        reloadQueuedCommands()
        guard shouldRefresh,
              let refreshedState = try? await bridgeService.fetchSnapshot(configuration: configuration) else {
            return
        }
        apply(state: refreshedState)
    }

    @discardableResult
    func retryQueuedCommandsIfNeeded() -> Task<Void, Never>? {
        guard queuedCommands.contains(where: { !$0.command.requiresHighImpactConfirmation }),
              !isRetryingQueuedCommands else { return nil }
        return Task {
            await retryQueuedCommands()
        }
    }

    public func discardQueuedCommand(id: String) {
        commandRetryStore.remove(id: id)
        reloadQueuedCommands()
        if queuedCommandCount == 0, lastCommandDeliveryRoute == .queued {
            lastCommandDeliveryRoute = nil
            lastCommandError = nil
        }
    }

    private func queueForRetry(_ command: BridgeCommand, error: String) {
        commandRetryStore.enqueue(command, error: error)
        reloadQueuedCommands()
        lastCommandDeliveryRoute = .queued
        lastCommandResult = nil
        lastCommandError = command.requiresHighImpactConfirmation
            ? "未取得回执，请核实任务后重新确认。待确认操作不会自动重发。\(error)" : error
    }

    private func reloadQueuedCommands() {
        queuedCommands = commandRetryStore.load()
        queuedCommandCount = queuedCommands.count
    }

    private func retryCommand(from command: BridgeCommand, now: Date = Date()) -> BridgeCommand {
        var command = command
        command.id = UUID().uuidString
        command.clientNonce = UUID().uuidString
        command.createdAt = now
        return command
    }

    public func requestRefresh() {
        lastRefreshRequestedAt = Date()
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            let message: [String: Any] = [WatchConnectivityMessageKey.bridgeRefreshRequest: true]
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(message, replyHandler: nil)
            } else if !WCSession.default.outstandingUserInfoTransfers.contains(where: {
                $0.userInfo[WatchConnectivityMessageKey.bridgeRefreshRequest] != nil
            }) {
                WCSession.default.transferUserInfo(message)
            }
        }
        #endif
        if let configuration = bridgeConnectionStore.load() {
            Task {
                if let refreshedState = try? await bridgeService.fetchSnapshot(configuration: configuration) {
                    apply(state: refreshedState)
                }
            }
        }
        retryQueuedCommandsIfNeeded()
    }

    private func apply(data: Data) {
        guard let decoded = try? JSONDecoder.codexWatchPet.decode(BridgeState.self, from: data) else {
            return
        }
        apply(state: decoded)
    }

    private func apply(state decoded: BridgeState) {
        let snoozedThreadIds = Set(decoded.snapshots.filter { $0.isSnoozed && $0.pendingRequest == nil }.map(\.threadId))
        let result = hapticPlanner.plan(
            for: decoded.events,
            state: hapticState,
            suppressingThreadIds: snoozedThreadIds
        )
        hapticState = result.state
        lastReceivedAt = Date()
        state = decoded
        persistForWidgets(decoded)
        if let haptic = result.haptic {
            hapticPlayer.play(haptic)
        }
        retryQueuedCommandsIfNeeded()
    }

    private func persistForWidgets(_ state: BridgeState) {
        try? widgetStateStore.save(state)
        #if canImport(WidgetKit)
        for kind in CodexWatchWidgetConstants.kinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        #endif
    }

    private func apply(connectionData: Data) {
        guard let configuration = try? JSONDecoder.codexWatchPet.decode(BridgeConnectionConfiguration.self, from: connectionData) else {
            return
        }
        bridgeConnectionStore.save(configuration)
    }

    func applySyncPayload(stateData: Data?, connectionData: Data?, chatGPTData: Data? = nil) {
        if let chatGPTData {
            do {
                let value = try JSONDecoder.codexWatchPet.decode(ChatGPTConversation?.self, from: chatGPTData)
                try ChatGPTHandoffStore.shared.setConversation(value)
            } catch { chatGPTHandoffStatus = "ChatGPT 会话配置无效，请在手机重新保存。" }
        }
        if let connectionData {
            apply(connectionData: connectionData)
        }
        if let stateData {
            apply(data: stateData)
        }
    }

    func applySyncMessage(_ message: [String: Any]) {
        applySyncPayload(
            stateData: message[WatchConnectivityMessageKey.bridgeState] as? Data,
            connectionData: message[WatchConnectivityMessageKey.bridgeConnection] as? Data,
            chatGPTData: message[WatchConnectivityMessageKey.chatGPTConversation] as? Data
        )
    }

    private func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        #endif
    }

    public static var preview: WatchStateInbox {
        WatchStateInbox(
            state: BridgeState(
                snapshots: [.sampleInput, .sampleApproval, .sampleActive],
                events: [
                    BridgeEvent(
                        sequence: 1,
                        threadId: "thread-approval",
                        type: .approvalRequested,
                        title: "Approval needed",
                        summary: "A Codex command is waiting on the Mac.",
                        urgency: .high,
                        petMood: .needsApproval,
                        actions: []
                    ),
                    BridgeEvent(
                        sequence: 2,
                        threadId: "thread-input",
                        type: .inputRequested,
                        title: "Missing input",
                        summary: "Choose whether to prioritize the Watch app, complication, or Mac bridge.",
                        urgency: .high,
                        petMood: .needsInput,
                        actions: []
                    )
                ],
                unreadHighUrgencyCount: 2,
                bridgeOnline: true,
                pairStatus: PairStatus(paired: true, deviceName: "Preview")
            )
        )
    }

    public static var live: WatchStateInbox {
        WatchStateInbox(
            state: BridgeState(
                snapshots: [],
                events: [],
                unreadHighUrgencyCount: 0,
                bridgeOnline: false,
                pairStatus: PairStatus(paired: false)
            )
        )
    }
}

private extension BridgeState {
    var hasReceivedBridgeData: Bool {
        bridgeOnline || !snapshots.isEmpty || !events.isEmpty
    }
}

#if canImport(WatchConnectivity)
extension WatchStateInbox: WCSessionDelegate {
    #if os(watchOS)
    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let id = userInfo["journal.ack"] as? String else { return }
        Task { @MainActor in WatchJournalRecorder.shared.acknowledge(id) }
    }
    #endif
    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            self.requestRefresh()
            #if os(watchOS)
            WatchJournalRecorder.shared.flushPending()
            #endif
        }
    }
    nonisolated public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        let context = session.receivedApplicationContext
        let stateData = context[WatchConnectivityMessageKey.bridgeState] as? Data
        let connectionData = context[WatchConnectivityMessageKey.bridgeConnection] as? Data
        let chatGPTData = context[WatchConnectivityMessageKey.chatGPTConversation] as? Data
        Task { @MainActor in
            self.applySyncPayload(stateData: stateData, connectionData: connectionData, chatGPTData: chatGPTData)
            self.requestRefresh()
            #if os(watchOS)
            WatchJournalRecorder.shared.flushPending()
            #endif
        }
    }

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {}
    #endif

    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let stateData = applicationContext[WatchConnectivityMessageKey.bridgeState] as? Data
        let connectionData = applicationContext[WatchConnectivityMessageKey.bridgeConnection] as? Data
        let chatGPTData = applicationContext[WatchConnectivityMessageKey.chatGPTConversation] as? Data
        Task { @MainActor in
            self.applySyncPayload(stateData: stateData, connectionData: connectionData, chatGPTData: chatGPTData)
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let stateData = message[WatchConnectivityMessageKey.bridgeState] as? Data
        let connectionData = message[WatchConnectivityMessageKey.bridgeConnection] as? Data
        let chatGPTData = message[WatchConnectivityMessageKey.chatGPTConversation] as? Data
        Task { @MainActor in
            self.applySyncPayload(stateData: stateData, connectionData: connectionData, chatGPTData: chatGPTData)
        }
    }
}
#endif
