import CodexMobilityCore
import CodexMobilityPhoneFeature
import CodexWatchCore
import Foundation

@MainActor
public final class BluetoothBridgeTransport: BridgeTransporting {
    public let route = BridgeTransportRoute.bluetooth
    private let store: MobilityPhoneStore
    private var fetchedPeripheralID: UUID?
    private var cachedIdentity: String?
    private var supportsReceipts = false
    public var serverIdentity: String? {
        fetchedPeripheralID == store.state.connectionPhase.peripheralIdentifier ? cachedIdentity : nil
    }
    public var supportsCommandDeduplication: Bool { serverIdentity != nil && supportsReceipts }
    public var isAvailable: Bool { store.isCollaborationReady }
    public init(store: MobilityPhoneStore) { self.store = store }

    public func fetchSnapshot() async throws -> BridgeState {
        let peripheralID = store.state.connectionPhase.peripheralIdentifier
        let data = try await exchange(CollaborationRequest(method: .snapshot))
        let state = try JSONDecoder.codexWatchPet.decode(BridgeState.self, from: data)
        fetchedPeripheralID = peripheralID
        cachedIdentity = state.bridgeIdentity
        supportsReceipts = state.commandReceiptsSupported
        return state
    }
    public func send(command: BridgeCommand) async throws -> CodexWatchCore.CommandResult {
        let data = try await exchange(CollaborationRequest(method: .command,
            body: JSONEncoder.codexWatchPetLine.encode(command), commandID: command.id))
        return try JSONDecoder.codexWatchPet.decode(CodexWatchCore.CommandResult.self, from: data)
    }
    public func fetchReceipt(commandID: String) async throws -> CodexWatchCore.CommandResult? {
        let data = try await exchange(CollaborationRequest(method: .receipt, commandID: commandID))
        return try JSONDecoder.codexWatchPet.decode(CodexWatchCore.CommandResult?.self, from: data)
    }
    private func exchange(_ request: CollaborationRequest) async throws -> Data {
        let response: CollaborationResponse
        let timeout: Duration = request.method == .receipt ? .seconds(3) : (request.method == .snapshot ? .seconds(6) : .seconds(10))
        do { response = try await store.requestCollaboration(request, timeout: timeout) }
        catch CollaborationTransportError.unavailable { throw BridgeDeliveryError.unavailable }
        guard response.requestID == request.id else { throw CollaborationTransportError.invalidResponse }
        guard (200..<300).contains(response.status) else {
            let message = String(data: response.body, encoding: .utf8) ?? "Mac 返回错误。"
            if response.status == 503 { throw CollaborationTransportError.rejected(message) }
            throw BridgeDeliveryError.rejected(message)
        }
        return try response.decodedBody()
    }
}
