@testable import CodexWatchWatchFeature
import CodexWatchCore
import Foundation
import Testing

enum StubWatchBridgeError: Error, LocalizedError {
    case offline

    var errorDescription: String? {
        switch self {
        case .offline:
            "bridge offline"
        }
    }
}

actor StubWatchBridgeService: WatchBridgeServicing {
    var sentCommands: [BridgeCommand] = []
    var fetchedSnapshots = 0
    var result = CommandResult(commandId: "command", accepted: true, message: "sent")
    var sendError: Error?
    var snapshot = BridgeState(
        snapshots: [.sampleActive],
        events: [],
        unreadHighUrgencyCount: 0,
        bridgeOnline: true,
        pairStatus: PairStatus(paired: true)
    )

    func send(command: BridgeCommand, configuration: BridgeConnectionConfiguration) async throws -> CommandResult {
        if let sendError {
            throw sendError
        }
        sentCommands.append(command)
        return CommandResult(commandId: command.id, accepted: result.accepted, message: result.message)
    }

    func fetchSnapshot(configuration: BridgeConnectionConfiguration) async throws -> BridgeState {
        fetchedSnapshots += 1
        return snapshot
    }

    func setSendError(_ error: Error?) {
        sendError = error
    }
}

@Suite("Watch state inbox")
@MainActor
struct WatchStateInboxTests {
    @Test
    func emptyStartupPreservesWidgetSnapshotAndOriginalFreshness() throws {
        let suite = "WatchWidgetLaunch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetStateStore(defaults: defaults)
        let cached = BridgeState(snapshots: [.sampleApproval], events: [], unreadHighUrgencyCount: 1,
                                 bridgeOnline: true, pairStatus: PairStatus(paired: true))
        try store.save(cached)
        let persisted = store.load()
        let savedAt = store.savedAt()
        _ = WatchStateInbox(state: BridgeState(snapshots: [], events: [], unreadHighUrgencyCount: 0,
                                              bridgeOnline: false, pairStatus: PairStatus(paired: false)),
            widgetStateStore: store, bridgeConnectionStore: BridgeConnectionStore(defaults: defaults),
            commandRetryStore: WatchCommandRetryStore(defaults: defaults), bridgeService: StubWatchBridgeService())
        #expect(store.load() == persisted)
        #expect(store.savedAt() == savedAt)
    }

    @Test
    func phoneReceiptMustMatchCurrentCommandAndAmbiguousDeliveryIsNotRetried() throws {
        let suite = "WatchReceipt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = WatchStateInbox(state: BridgeState(snapshots: [], events: [], unreadHighUrgencyCount: 0, bridgeOnline: false, pairStatus: PairStatus(paired: false)),
            widgetStateStore: WidgetStateStore(defaults: defaults), bridgeConnectionStore: BridgeConnectionStore(defaults: defaults),
            commandRetryStore: WatchCommandRetryStore(defaults: defaults), bridgeService: StubWatchBridgeService())
        let command = BridgeCommand(type: .approve)
        inbox.send(command)
        let oldResult = try JSONEncoder.codexWatchPet.encode(CommandResult(commandId: "old", accepted: true, message: "sent"))
        inbox.receiveCommandReceipt(oldResult, commandID: "old")
        #expect(inbox.lastCommandResult == nil)
        inbox.receiveCommandReceipt(nil, commandID: command.id)
        #expect(inbox.lastCommandError?.contains("可能已送达") == true)
        #expect(inbox.queuedCommands.isEmpty)
        let result = try JSONEncoder.codexWatchPet.encode(CommandResult(commandId: command.id, accepted: true, message: "sent"))
        inbox.receiveCommandReceipt(result, commandID: command.id)
        #expect(inbox.lastCommandResult?.accepted == true)
        #expect(inbox.lastCommandError == nil)
    }

    @Test
    func syncMessagePersistsBridgeConnectionForWatchIntents() throws {
        let suiteName = "CodexWatchPetWatchInboxTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let widgetDefaults = try #require(UserDefaults(suiteName: "\(suiteName)-widget"))
        widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        defer {
            widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        }

        let connectionStore = BridgeConnectionStore(defaults: defaults)
        let inbox = WatchStateInbox(
            state: BridgeState(
                snapshots: [],
                events: [],
                unreadHighUrgencyCount: 0,
                bridgeOnline: false,
                pairStatus: PairStatus(paired: false)
            ),
            widgetStateStore: WidgetStateStore(defaults: widgetDefaults),
            bridgeConnectionStore: connectionStore,
            commandRetryStore: WatchCommandRetryStore(defaults: defaults)
        )
        let configuration = BridgeConnectionConfiguration(
            baseURL: URL(string: "http://172.20.12.65:8766")!,
            bearerToken: "token",
            sharedSecretBase64: Data("secret".utf8).base64EncodedString()
        )
        let nextState = BridgeState(
            snapshots: [.sampleInput],
            events: [],
            unreadHighUrgencyCount: 1,
            bridgeOnline: true,
            pairStatus: PairStatus(paired: true)
        )

        inbox.applySyncMessage([
            WatchConnectivityMessageKey.bridgeConnection: try JSONEncoder.codexWatchPet.encode(configuration),
            WatchConnectivityMessageKey.bridgeState: try JSONEncoder.codexWatchPet.encode(nextState)
        ])
        let loaded = try #require(connectionStore.load())

        #expect(loaded.baseURL.absoluteString == "http://172.20.12.65:8766")
        #expect(loaded.bearerToken == "token")
        #expect(loaded.sharedSecret == Data("secret".utf8))
        #expect(inbox.state.snapshots.first?.threadId == "thread-input")
    }

    @Test
    func directBridgeSendUsesSyncedConnectionAndRefreshesState() async throws {
        let suiteName = "CodexWatchPetWatchDirectSendTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let widgetDefaults = try #require(UserDefaults(suiteName: "\(suiteName)-widget"))
        widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        defer {
            widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        }

        let connectionStore = BridgeConnectionStore(defaults: defaults)
        connectionStore.save(
            BridgeConnectionConfiguration(
                baseURL: URL(string: "http://172.20.12.65:8766")!,
                bearerToken: "token",
                sharedSecretBase64: Data("secret".utf8).base64EncodedString()
            )
        )
        let service = StubWatchBridgeService()
        let inbox = WatchStateInbox(
            state: BridgeState(
                snapshots: [],
                events: [],
                unreadHighUrgencyCount: 0,
                bridgeOnline: false,
                pairStatus: PairStatus(paired: false)
            ),
            widgetStateStore: WidgetStateStore(defaults: widgetDefaults),
            bridgeConnectionStore: connectionStore,
            commandRetryStore: WatchCommandRetryStore(defaults: defaults),
            bridgeService: service
        )
        let command = BridgeCommand(
            id: "watch-command",
            type: .approve,
            threadId: "thread-approval",
            payload: ["requestId": "appserver:42"],
            confirmation: CommandConfirmation(displayedSummary: "approve", riskAccepted: true)
        )

        await inbox.sendDirectToBridge(command)
        let sentCommands = await service.sentCommands
        let fetchedSnapshots = await service.fetchedSnapshots

        #expect(sentCommands.first == command)
        #expect(fetchedSnapshots == 1)
        #expect(inbox.lastCommandDeliveryRoute == .directBridge)
        #expect(inbox.lastCommandResult?.accepted == true)
        #expect(inbox.state.snapshots.first?.threadId == "thread-active")
    }

    @Test
    func directBridgeSendReportsUnavailableWhenConnectionIsMissing() async throws {
        let suiteName = "CodexWatchPetWatchDirectMissingConnectionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let widgetDefaults = try #require(UserDefaults(suiteName: "\(suiteName)-widget"))
        widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        defer {
            widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        }

        let service = StubWatchBridgeService()
        let inbox = WatchStateInbox(
            state: BridgeState(
                snapshots: [],
                events: [],
                unreadHighUrgencyCount: 0,
                bridgeOnline: false,
                pairStatus: PairStatus(paired: false)
            ),
            widgetStateStore: WidgetStateStore(defaults: widgetDefaults),
            bridgeConnectionStore: BridgeConnectionStore(defaults: defaults),
            commandRetryStore: WatchCommandRetryStore(defaults: defaults),
            bridgeService: service
        )

        await inbox.sendDirectToBridge(BridgeCommand(type: .openOnMac))
        let sentCommands = await service.sentCommands

        #expect(sentCommands.isEmpty)
        #expect(inbox.lastCommandDeliveryRoute == .unavailable)
        #expect(inbox.lastCommandResult == nil)
        #expect(inbox.lastCommandError == "Pair Codex Watch Pet on iPhone and sync to Watch first.")
    }

    @Test
    func directBridgeFailureQueuesCommandForRetry() async throws {
        let suiteName = "CodexWatchPetWatchRetryQueueTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let widgetDefaults = try #require(UserDefaults(suiteName: "\(suiteName)-widget"))
        widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        defer {
            widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        }

        let connectionStore = BridgeConnectionStore(defaults: defaults)
        connectionStore.save(
            BridgeConnectionConfiguration(
                baseURL: URL(string: "http://172.20.12.65:8766")!,
                bearerToken: "token",
                sharedSecretBase64: Data("secret".utf8).base64EncodedString()
            )
        )
        let retryStore = WatchCommandRetryStore(defaults: defaults)
        let service = StubWatchBridgeService()
        await service.setSendError(StubWatchBridgeError.offline)
        let inbox = WatchStateInbox(
            state: BridgeState(
                snapshots: [],
                events: [],
                unreadHighUrgencyCount: 0,
                bridgeOnline: false,
                pairStatus: PairStatus(paired: false)
            ),
            widgetStateStore: WidgetStateStore(defaults: widgetDefaults),
            bridgeConnectionStore: connectionStore,
            commandRetryStore: retryStore,
            bridgeService: service
        )
        let command = BridgeCommand(
            id: "queued-command",
            type: .approve,
            threadId: "thread-approval",
            payload: ["requestId": "appserver:42"],
            confirmation: CommandConfirmation(displayedSummary: "approve", riskAccepted: true)
        )

        await inbox.sendDirectToBridge(command)
        let queued = retryStore.load()

        #expect(queued.count == 1)
        #expect(queued.first?.command.id == command.id)
        #expect(queued.first?.command.type == command.type)
        #expect(queued.first?.command.threadId == command.threadId)
        #expect(queued.first?.command.payload["requestId"] == "appserver:42")
        #expect(inbox.queuedCommandCount == 1)
        #expect(inbox.queuedCommands.first?.id == "queued-command")
        #expect(inbox.lastCommandDeliveryRoute == .queued)
        #expect(inbox.lastCommandError?.contains("不会自动重发") == true)
    }

    @Test
    func queuedApprovalRequiresFreshReviewAndKeepsOriginalConfirmation() async throws {
        let suiteName = "CodexWatchPetWatchRetrySendTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let widgetDefaults = try #require(UserDefaults(suiteName: "\(suiteName)-widget"))
        widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        defer {
            widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        }

        let connectionStore = BridgeConnectionStore(defaults: defaults)
        connectionStore.save(
            BridgeConnectionConfiguration(
                baseURL: URL(string: "http://172.20.12.65:8766")!,
                bearerToken: "token",
                sharedSecretBase64: Data("secret".utf8).base64EncodedString()
            )
        )
        let retryStore = WatchCommandRetryStore(defaults: defaults)
        let oldDate = Date(timeIntervalSince1970: 1)
        let command = BridgeCommand(
            id: "queued-command",
            type: .approve,
            threadId: "thread-approval",
            payload: ["requestId": "appserver:42"],
            clientNonce: "old-nonce",
            confirmation: CommandConfirmation(confirmedAt: oldDate, displayedSummary: "approve", riskAccepted: true),
            createdAt: oldDate
        )
        retryStore.enqueue(command, error: "bridge offline", now: oldDate)
        let service = StubWatchBridgeService()
        let inbox = WatchStateInbox(
            state: BridgeState(
                snapshots: [],
                events: [],
                unreadHighUrgencyCount: 0,
                bridgeOnline: false,
                pairStatus: PairStatus(paired: false)
            ),
            widgetStateStore: WidgetStateStore(defaults: widgetDefaults),
            bridgeConnectionStore: connectionStore,
            commandRetryStore: retryStore,
            bridgeService: service
        )

        await inbox.retryQueuedCommands()
        let sentCommands = await service.sentCommands
        #expect(sentCommands.isEmpty)
        #expect(retryStore.load().first?.command.confirmation?.confirmedAt == oldDate)
        #expect(inbox.queuedCommandCount == 1)
        #expect(inbox.retryQueuedCommandsIfNeeded() == nil)
        #expect(inbox.lastCommandError?.contains("重新确认") == true)

    }

    @Test
    func retryQueuedCommandsIfNeededRunsQueuedRetry() async throws {
        let suiteName = "CodexWatchPetWatchAutoRetryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let widgetDefaults = try #require(UserDefaults(suiteName: "\(suiteName)-widget"))
        widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        defer {
            widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        }

        let connectionStore = BridgeConnectionStore(defaults: defaults)
        connectionStore.save(
            BridgeConnectionConfiguration(
                baseURL: URL(string: "http://172.20.12.65:8766")!,
                bearerToken: "token",
                sharedSecretBase64: Data("secret".utf8).base64EncodedString()
            )
        )
        let retryStore = WatchCommandRetryStore(defaults: defaults)
        retryStore.enqueue(
            BridgeCommand(
                id: "auto-retry-command",
                type: .snooze,
                threadId: "thread-input",
                payload: ["requestId": "appserver:input-live", "prompt": "Use TestFlight."],
                confirmation: CommandConfirmation(displayedSummary: "reply", riskAccepted: true)
            ),
            error: "bridge offline"
        )
        let service = StubWatchBridgeService()
        let inbox = WatchStateInbox(
            state: BridgeState(
                snapshots: [],
                events: [],
                unreadHighUrgencyCount: 0,
                bridgeOnline: false,
                pairStatus: PairStatus(paired: false)
            ),
            widgetStateStore: WidgetStateStore(defaults: widgetDefaults),
            bridgeConnectionStore: connectionStore,
            commandRetryStore: retryStore,
            bridgeService: service
        )

        let task = try #require(inbox.retryQueuedCommandsIfNeeded())
        await task.value
        let sentCommands = await service.sentCommands

        #expect(sentCommands.count == 1)
        #expect(retryStore.load().isEmpty)
        #expect(inbox.queuedCommandCount == 0)
        #expect(inbox.queuedCommands.isEmpty)
        #expect(inbox.lastCommandDeliveryRoute == .directBridge)
    }

    @Test
    func discardingQueuedCommandRemovesItFromStoreAndInbox() throws {
        let suiteName = "CodexWatchPetWatchDiscardQueuedTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let widgetDefaults = try #require(UserDefaults(suiteName: "\(suiteName)-widget"))
        widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        defer {
            widgetDefaults.removePersistentDomain(forName: "\(suiteName)-widget")
        }

        let retryStore = WatchCommandRetryStore(defaults: defaults)
        retryStore.enqueue(
            BridgeCommand(
                id: "discard-command",
                type: .decline,
                threadId: "thread-approval",
                payload: ["requestId": "appserver:42"],
                confirmation: CommandConfirmation(displayedSummary: "decline", riskAccepted: true)
            ),
            error: "bridge offline"
        )
        let inbox = WatchStateInbox(
            state: BridgeState(
                snapshots: [],
                events: [],
                unreadHighUrgencyCount: 0,
                bridgeOnline: false,
                pairStatus: PairStatus(paired: false)
            ),
            widgetStateStore: WidgetStateStore(defaults: widgetDefaults),
            bridgeConnectionStore: BridgeConnectionStore(defaults: defaults),
            commandRetryStore: retryStore,
            bridgeService: StubWatchBridgeService()
        )

        inbox.discardQueuedCommand(id: "discard-command")

        #expect(retryStore.load().isEmpty)
        #expect(inbox.queuedCommandCount == 0)
        #expect(inbox.queuedCommands.isEmpty)
    }
}
