import CodexWatchCore
@testable import CodexWatchPhoneFeature
import Foundation
import Testing

@MainActor
private final class LinkStub: BridgeTransporting {
    let route: BridgeTransportRoute
    var isAvailable = true
    var reads = 0; var sends = 0; var queries = 0
    var readError: Error?; var sendError: Error?
    var receipt: CommandResult?
    var serverIdentity: String?
    var supportsCommandDeduplication = false
    var lastSentCommand: BridgeCommand?
    var sendDelay: Duration?
    init(_ route: BridgeTransportRoute) { self.route = route }
    func fetchSnapshot() async throws -> BridgeState {
        reads += 1
        if let readError { throw readError }
        return BridgeState(snapshots: [], events: [], unreadHighUrgencyCount: 0, bridgeOnline: true,
            pairStatus: PairStatus(paired: true), bridgeIdentity: serverIdentity,
            commandReceiptsSupported: supportsCommandDeduplication)
    }
    func send(command: BridgeCommand) async throws -> CommandResult {
        sends += 1
        lastSentCommand = command
        if let sendDelay { try await Task.sleep(for: sendDelay) }
        if let sendError { throw sendError }
        return CommandResult(commandId: command.id, accepted: true, message: "ack")
    }
    func fetchReceipt(commandID: String) async throws -> CommandResult? { queries += 1; return receipt }
}

@Suite("Reliable bridge connection")
@MainActor
struct ReliableBridgeConnectionTests {
    @Test func bluetoothFirstEvenWhenConfiguredLast() async throws {
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork), remote = LinkStub(.remoteHTTPS)
        let client = ReliableBridgeConnection(); client.configure([remote, lan, ble])
        _ = try await client.fetchSnapshot()
        #expect(ble.reads == 1 && lan.reads == 0 && remote.reads == 0)
        #expect(client.activeRoute == .bluetooth)
    }
    @Test func readsFailOverAndRecoverPreferredTransportAfterCooldown() async throws {
        var now = Date()
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork)
        ble.readError = URLError(.timedOut)
        let client = ReliableBridgeConnection(now: { now }); client.configure([ble, lan])
        _ = try await client.fetchSnapshot(); _ = try await client.fetchSnapshot()
        #expect(ble.reads == 1 && lan.reads == 2)
        now = now.addingTimeInterval(16); ble.readError = nil
        _ = try await client.fetchSnapshot()
        #expect(ble.reads == 2 && client.activeRoute == .bluetooth)
    }
    @Test func definitelyUnavailableWriteCanTryNextTransport() async throws {
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork)
        ble.sendError = BridgeDeliveryError.unavailable
        let client = ReliableBridgeConnection(); client.configure([ble, lan])
        let command = BridgeCommand(type: .startThread)
        let result = try await client.send(command: command)
        #expect(result.commandId == command.id && result.accepted)
        #expect(ble.sends == 1 && lan.sends == 1)
    }
    @Test func lostReplyQueriesOtherRouteWithoutSendingAgain() async throws {
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork)
        let command = BridgeCommand(type: .startThread)
        ble.sendError = URLError(.timedOut)
        lan.receipt = CommandResult(commandId: command.id, accepted: true, message: "already executed")
        let client = ReliableBridgeConnection(); client.configure([ble, lan])
        let result = try await client.send(command: command)
        #expect(result.message == "already executed")
        #expect(ble.sends == 1 && lan.sends == 0 && lan.queries == 1)
    }
    @Test func unknownOutcomeNeverRepeatsApproval() async {
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork)
        ble.sendError = URLError(.networkConnectionLost)
        let client = ReliableBridgeConnection(); client.configure([ble, lan])
        do { _ = try await client.send(command: BridgeCommand(type: .approve)); Issue.record("Expected unknown outcome") }
        catch { #expect(error is BridgeDeliveryError) }
        #expect(ble.sends == 1 && lan.sends == 0)
    }
    @Test func upgradedSameMacCanRetryTheExactCommandOnStandbyRoute() async throws {
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork)
        ble.serverIdentity = "mac-A"; lan.serverIdentity = "mac-A"
        ble.supportsCommandDeduplication = true; lan.supportsCommandDeduplication = true
        ble.sendError = URLError(.networkConnectionLost)
        let client = ReliableBridgeConnection(); client.configure([ble, lan])
        let command = BridgeCommand(type: .startThread, payload: ["prompt": "same command"])
        let receipt = try await client.send(command: command)
        #expect(receipt.accepted)
        #expect(ble.lastSentCommand == command && lan.lastSentCommand == command)
        #expect(lan.sends == 1)
    }
    @Test func fallbackCannotExecuteOnAnotherMac() async throws {
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork)
        ble.serverIdentity = "mac-A"; lan.serverIdentity = "mac-B"
        ble.supportsCommandDeduplication = true; lan.supportsCommandDeduplication = true
        ble.sendError = URLError(.timedOut)
        let client = ReliableBridgeConnection(); client.configure([ble, lan])
        do { _ = try await client.send(command: BridgeCommand(type: .startThread)); Issue.record("Expected unknown outcome") }
        catch { #expect(error is BridgeDeliveryError) }
        #expect(lan.sends == 0 && lan.queries == 0)
    }
    @Test func snapshotFallbackPreservesPinnedMac() async throws {
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork)
        ble.serverIdentity = "mac-A"; lan.serverIdentity = "mac-B"
        let client = ReliableBridgeConnection(); client.configure([ble, lan])
        _ = try await client.fetchSnapshot()
        ble.readError = URLError(.timedOut)
        do { _ = try await client.fetchSnapshot(); Issue.record("Should reject another Mac") }
        catch { #expect(error is BridgeDeliveryError) }
    }
    @Test func cancellationDoesNotFallThroughToAnotherRoute() async {
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork)
        ble.readError = CancellationError()
        let client = ReliableBridgeConnection(); client.configure([ble, lan])
        do { _ = try await client.fetchSnapshot(); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(lan.reads == 0)
    }
    @Test func overallDeadlineFitsWatchReplyWindowWithoutUncontrolledRetry() async {
        let ble = LinkStub(.bluetooth), lan = LinkStub(.localNetwork)
        ble.sendDelay = .seconds(10)
        let client = ReliableBridgeConnection(commandTimeout: .milliseconds(10)); client.configure([ble, lan])
        do { _ = try await client.send(command: BridgeCommand(type: .startThread)); Issue.record("Expected deadline") }
        catch { #expect(error is BridgeDeliveryError) }
        #expect(ble.sends == 1 && lan.sends == 0)
    }
    @Test func failedRefreshMarksCachedStateOffline() async {
        let cached = BridgeState(snapshots: [.sampleActive], events: [], unreadHighUrgencyCount: 0,
                                 bridgeOnline: true, pairStatus: PairStatus(paired: true))
        let store = CodexWatchStore(initialState: cached)
        await store.refresh()
        #expect(!store.state.bridgeOnline)
        #expect(store.state.snapshots.count == 1)
    }
    @Test func phoneStoreUsesPairedBluetoothWithoutManualHTTPConfiguration() async {
        let ble = LinkStub(.bluetooth)
        let store = CodexWatchStore()
        store.configure(preferredTransports: [ble]); store.configure(client: nil)
        await store.refresh()
        #expect(store.state.bridgeOnline && store.connectionStatus == "蓝牙")
    }
}
