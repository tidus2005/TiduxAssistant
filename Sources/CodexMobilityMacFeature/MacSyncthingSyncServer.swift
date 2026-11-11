import CodexMobilityCore
import Combine
import Foundation
import Network

private enum MacSyncthingSyncServerError: LocalizedError {
    case helloTimedOut

    var errorDescription: String? {
        switch self {
        case .helloTimedOut:
            "等待已加密连接发送设备身份超时。"
        }
    }
}

public enum MacSyncthingSyncServerPhase: Equatable, Sendable {
    case stopped
    case waitingForPairing
    case starting
    case advertising
    case failed
}

public struct MacSyncthingSyncServerState: Equatable, Sendable {
    public var phase: MacSyncthingSyncServerPhase
    public var serviceName: String
    public var activeConnectionCount: Int
    public var authenticatedPeerDeviceIDs: [UUID]
    public var lastErrorMessage: String?

    public init(
        phase: MacSyncthingSyncServerPhase = .stopped,
        serviceName: String,
        activeConnectionCount: Int = 0,
        authenticatedPeerDeviceIDs: [UUID] = [],
        lastErrorMessage: String? = nil
    ) {
        self.phase = phase
        self.serviceName = serviceName
        self.activeConnectionCount = activeConnectionCount
        self.authenticatedPeerDeviceIDs = authenticatedPeerDeviceIDs
        self.lastErrorMessage = lastErrorMessage
    }

    public var isAdvertising: Bool { phase == .advertising }
}

enum MacSyncthingPeerListenerState: Equatable, Sendable {
    case starting
    case waiting(String)
    case ready
    case failed(String)
    case stopped
}

protocol MacSyncthingPeerConnectionProtocol: Sendable {
    func receive() async throws -> SyncthingPeerMessage?
    func send(_ message: SyncthingPeerMessage) async throws
    func close(_ close: SyncthingPeerClose) async throws
    func cancel() async
}

@MainActor
protocol MacSyncthingPeerListening: AnyObject {
    func start(
        serviceName: String,
        credentials: [SyncthingPeerCredential],
        onConnection: @escaping @Sendable (any MacSyncthingPeerConnectionProtocol) async -> Void,
        onStateChange: @escaping @Sendable (MacSyncthingPeerListenerState) -> Void,
        onConnectionError: @escaping @Sendable (String) -> Void
    ) async throws

    func stop() async
    func listeningPort() async -> UInt16?
}

extension MacSyncthingPeerListening {
    func listeningPort() async -> UInt16? { nil }
}

private struct MacSyncthingNetworkPeerConnection: MacSyncthingPeerConnectionProtocol {
    let peer: SyncthingPeerConnection

    func receive() async throws -> SyncthingPeerMessage? {
        try await peer.receive()
    }

    func send(_ message: SyncthingPeerMessage) async throws {
        try await peer.send(message)
    }

    func close(_ close: SyncthingPeerClose) async throws {
        try await peer.close(close)
    }

    func cancel() async {
        await peer.cancel()
    }
}

@MainActor
private final class MacSyncthingNetworkPeerListener: MacSyncthingPeerListening {
    private var peerListener: SyncthingPeerListener?

    func listeningPort() async -> UInt16? { await peerListener?.port?.rawValue }

    func start(
        serviceName: String,
        credentials: [SyncthingPeerCredential],
        onConnection: @escaping @Sendable (any MacSyncthingPeerConnectionProtocol) async -> Void,
        onStateChange: @escaping @Sendable (MacSyncthingPeerListenerState) -> Void,
        onConnectionError: @escaping @Sendable (String) -> Void
    ) async throws {
        let peerListener = SyncthingPeerListener(
            serviceName: serviceName,
            credentials: credentials
        )
        self.peerListener = peerListener

        do {
            try await peerListener.start(
                onConnection: { peer in
                    await onConnection(MacSyncthingNetworkPeerConnection(peer: peer))
                },
                onConnectionError: { error in
                    onConnectionError(String(describing: error))
                },
                onStateChange: { networkState in
                    let state: MacSyncthingPeerListenerState = switch networkState {
                    case .setup:
                        .starting
                    case .waiting(let error):
                        .waiting(error.debugDescription)
                    case .ready:
                        .ready
                    case .failed(let error):
                        .failed(error.debugDescription)
                    case .cancelled:
                        .stopped
                    @unknown default:
                        .failed("未知的本地网络监听状态。")
                    }
                    onStateChange(state)
                }
            )
        } catch {
            self.peerListener = nil
            throw error
        }
    }

    func stop() async {
        guard let peerListener else { return }
        await peerListener.stop()
        self.peerListener = nil
    }
}

@MainActor
public final class MacSyncthingSyncServer: ObservableObject {
    public typealias TransferHandler = @MainActor @Sendable (
        _ message: SyncWireMessage,
        _ phoneDeviceID: UUID
    ) async -> [SyncWireMessage]
    typealias DeltaRouterFactory = @Sendable () -> any MacSyncthingDeltaRouting
    typealias PendingOffersProvider = @MainActor @Sendable () async -> [SyncWireMessage]

    @Published public private(set) var state: MacSyncthingSyncServerState

    private let localDeviceID: UUID
    private let localDeviceName: String
    private let credentialStore: any MobilityMacCredentialStoring
    private let listener: any MacSyncthingPeerListening
    private let transferHandler: TransferHandler
    private let deltaRouterFactory: DeltaRouterFactory?
    private let pendingOffersProvider: PendingOffersProvider?
    private let listenerRestartDelay: Duration
    private let helloTimeout: Duration

    private var wantsRunning = false
    private var configurationGeneration: UInt64 = 0
    private var configuredCredentials: [UUID: SyncthingPeerCredential] = [:]
    private var connections: [UUID: any MacSyncthingPeerConnectionProtocol] = [:]
    private var authenticatedDeviceIDs: [UUID: UUID] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var deltaRouters: [UUID: any MacSyncthingDeltaRouting] = [:]
    private var publicationConnectionID: UUID?
    private var streamingConnections: Set<UUID> = []
    private var listenerRestartTask: Task<Void, Never>?
    private var seenHelloNonces: [UUID: Date] = [:]
    private let helloNonceRetention: TimeInterval = 10 * 60

    public convenience init(
        localDeviceID: UUID,
        localDeviceName: String,
        credentialStore: any MobilityMacCredentialStoring = MobilityMacCredentialVault(),
        wireController: MacFileSyncWireController,
        serviceName: String? = nil
    ) {
        let deltaAdapter = MacSyncthingDeltaAdapter(
            store: wireController.store,
            localDeviceID: localDeviceID
        )
        self.init(
            localDeviceID: localDeviceID,
            localDeviceName: localDeviceName,
            credentialStore: credentialStore,
            listener: MacSyncthingNetworkPeerListener(),
            serviceName: serviceName,
            deltaRouterFactory: {
                MacSyncthingDeltaRouter(adapter: deltaAdapter)
            },
            pendingOffersProvider: { [weak wireController] in
                guard let wireController else { return [] }
                return await wireController.pendingOffers(transportProfile: .localNetwork)
            },
            transferHandler: { [weak wireController] message, phoneDeviceID in
                guard let wireController else { return [] }
                return await wireController.handle(
                    message,
                    from: phoneDeviceID,
                    transportProfile: .localNetwork
                )
            }
        )
    }

    init(
        localDeviceID: UUID,
        localDeviceName: String,
        credentialStore: any MobilityMacCredentialStoring,
        listener: any MacSyncthingPeerListening,
        serviceName: String? = nil,
        listenerRestartDelay: Duration = .seconds(2),
        helloTimeout: Duration = .seconds(6),
        deltaRouterFactory: DeltaRouterFactory? = nil,
        pendingOffersProvider: PendingOffersProvider? = nil,
        transferHandler: @escaping TransferHandler
    ) {
        self.localDeviceID = localDeviceID
        self.localDeviceName = localDeviceName
        self.credentialStore = credentialStore
        self.listener = listener
        self.listenerRestartDelay = listenerRestartDelay
        self.helloTimeout = helloTimeout
        self.deltaRouterFactory = deltaRouterFactory
        self.pendingOffersProvider = pendingOffersProvider
        self.transferHandler = transferHandler

        let advertisedName = serviceName ?? Self.defaultServiceName(
            deviceName: localDeviceName,
            deviceID: localDeviceID
        )
        self.state = MacSyncthingSyncServerState(serviceName: advertisedName)
    }

    public func listeningPort() async -> UInt16? { await listener.listeningPort() }

    public func start() async {
        guard !wantsRunning else { return }
        wantsRunning = true
        await reconfigureListener()
    }

    /// Rebuilds the TLS listener from the current Keychain credential set.
    /// Existing sessions for removed or token-rotated devices are cancelled first.
    public func refreshCredentials() async {
        guard wantsRunning else { return }
        listenerRestartTask?.cancel()
        listenerRestartTask = nil
        await reconfigureListener()
    }

    /// Publishes queued files to one authenticated phone. Files up to the in-memory
    /// delta limit become hashed indexes. Larger files remain on the BLE file-backed
    /// path and are intentionally not offered over this P2P connection.
    public func publish(_ messages: [SyncWireMessage]) async {
        guard wantsRunning, !messages.isEmpty else { return }

        let preferredConnectionID = preferredPublicationConnectionID()
        let targets = preferredConnectionID.flatMap { connectionID in
            authenticatedDeviceIDs[connectionID].flatMap { deviceID in
                connections[connectionID].map { [(connectionID, deviceID, $0)] }
            }
        } ?? []
        var failedConnectionIDs: Set<UUID> = []

        for (connectionID, deviceID, connection) in targets {
            do {
                guard try isCurrentlyPaired(deviceID: deviceID) else {
                    failedConnectionIDs.insert(connectionID)
                    continue
                }
                try await sendP2PMessages(
                    messages,
                    connectionID: connectionID,
                    connection: connection
                )
            } catch {
                failedConnectionIDs.insert(connectionID)
                state.lastErrorMessage = error.localizedDescription
            }
        }

        if !failedConnectionIDs.isEmpty {
            for connectionID in failedConnectionIDs {
                connectionTasks[connectionID]?.cancel()
                if let connection = connections[connectionID] {
                    await connection.cancel()
                }
                connectionTasks[connectionID] = nil
                connections[connectionID] = nil
                authenticatedDeviceIDs[connectionID] = nil
            streamingConnections.remove(connectionID)
                deltaRouters[connectionID] = nil
                if publicationConnectionID == connectionID {
                    publicationConnectionID = nil
                }
            }
            publishConnectionState()
        }
    }

    public func stop() async {
        guard wantsRunning || state.phase != .stopped else { return }
        suspend()
        let stopGeneration = configurationGeneration
        await listener.stop()
        guard !Task.isCancelled,
              !wantsRunning,
              stopGeneration == configurationGeneration else {
            return
        }
        await disconnectSessions(where: { _ in true })
        guard !Task.isCancelled,
              !wantsRunning,
              stopGeneration == configurationGeneration else {
            return
        }
        configuredCredentials.removeAll()
        seenHelloNonces.removeAll()
        deltaRouters.removeAll()
        publicationConnectionID = nil
        publishState(phase: .stopped, lastErrorMessage: nil)
    }

    /// Closes the data-plane gate synchronously before asynchronous listener and
    /// connection teardown begins. Module switches call this on the main actor,
    /// so no new transfer or delta commit can enter during the teardown window.
    func suspend() {
        if wantsRunning {
            configurationGeneration &+= 1
        }
        wantsRunning = false
        listenerRestartTask?.cancel()
        listenerRestartTask = nil
        for task in connectionTasks.values {
            task.cancel()
        }
    }

    private func reconfigureListener() async {
        listenerRestartTask = nil
        configurationGeneration &+= 1
        let generation = configurationGeneration

        // Stop first so a credential that was just revoked can no longer establish a
        // fresh TLS session while the Keychain is being re-read.
        await listener.stop()
        guard wantsRunning, generation == configurationGeneration else { return }

        do {
            let credentials = try loadAllCredentials()
            let nextCredentials = Dictionary(
                credentials.map { ($0.deviceID, $0) },
                uniquingKeysWith: { _, newest in newest }
            )
            let invalidatedDeviceIDs = Set(configuredCredentials.keys).filter {
                nextCredentials[$0] != configuredCredentials[$0]
            }
            configuredCredentials = nextCredentials

            // Connections that have not completed hello cannot be attributed safely;
            // close them whenever the PSK set changes as well.
            if !invalidatedDeviceIDs.isEmpty {
                await disconnectSessions { deviceID in
                    deviceID == nil || deviceID.map(invalidatedDeviceIDs.contains) == true
                }
            }

            guard !credentials.isEmpty else {
                publishState(phase: .waitingForPairing, lastErrorMessage: nil)
                return
            }

            publishState(phase: .starting, lastErrorMessage: nil)
            try await listener.start(
                serviceName: state.serviceName,
                credentials: credentials,
                onConnection: { [weak self] connection in
                    await self?.accept(connection, generation: generation)
                },
                onStateChange: { [weak self] listenerState in
                    Task { @MainActor [weak self] in
                        self?.handle(listenerState, generation: generation)
                    }
                },
                onConnectionError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.recordConnectionError(message, generation: generation)
                    }
                }
            )
        } catch {
            guard generation == configurationGeneration else { return }
            configuredCredentials.removeAll()
            publishState(phase: .failed, lastErrorMessage: error.localizedDescription)
            scheduleListenerRestart(generation: generation)
        }
    }

    private func loadAllCredentials() throws -> [SyncthingPeerCredential] {
        try credentialStore.pairedDevices().compactMap { device in
            guard let credential = try credentialStore.credential(for: device.deviceID) else {
                return nil
            }
            return SyncthingPeerCredential(
                deviceID: credential.deviceID,
                pairingToken: credential.token
            )
        }
    }

    private func accept(
        _ connection: any MacSyncthingPeerConnectionProtocol,
        generation: UInt64
    ) async {
        guard wantsRunning, generation == configurationGeneration else {
            await connection.cancel()
            return
        }

        let connectionID = UUID()
        connections[connectionID] = connection
        publishConnectionState()
        connectionTasks[connectionID] = Task { @MainActor [weak self] in
            await self?.runConnection(connectionID: connectionID, connection: connection)
        }
    }

    private func runConnection(
        connectionID: UUID,
        connection: any MacSyncthingPeerConnectionProtocol
    ) async {
        defer { finishConnection(connectionID) }

        do {
            guard let firstMessage = try await receiveFirstMessage(from: connection) else { return }
            guard wantsRunning, !Task.isCancelled else {
                await connection.cancel()
                return
            }
            guard case .hello(let hello) = firstMessage else {
                try? await connection.close(
                    SyncthingPeerClose(
                        code: .unauthorized,
                        reason: "必须先完成已配对设备握手。"
                    )
                )
                return
            }

            guard let credential = try currentCredential(deviceID: hello.deviceID) else {
                try? await connection.close(
                    SyncthingPeerClose(
                        code: .unauthorized,
                        reason: "该手机未与此 Mac 配对。"
                    )
                )
                return
            }

            do {
                try SyncthingPeerAuthentication.requireValid(
                    hello,
                    expectedLocalDeviceID: localDeviceID,
                    pairingToken: credential.token
                )
                guard consumeHelloNonce(hello.nonce) else {
                    throw SyncthingPeerAuthenticationError.invalidAuthenticationProof
                }
            } catch {
                let code: SyncthingPeerCloseCode
                if case SyncthingPeerAuthenticationError.unsupportedProtocolVersion = error {
                    code = .protocolError
                } else {
                    code = .unauthorized
                }
                try? await connection.close(
                    SyncthingPeerClose(
                        code: code,
                        reason: "P2P 设备身份证明无效或已重放。"
                    )
                )
                return
            }

            authenticatedDeviceIDs[connectionID] = hello.deviceID
            if hello.folderIDs.contains("codex-media-stream-v1") { streamingConnections.insert(connectionID) }
            if let deltaRouterFactory {
                deltaRouters[connectionID] = deltaRouterFactory()
            }
            if publicationConnectionID == nil {
                publicationConnectionID = connectionID
            }
            publishConnectionState()
            try await connection.send(
                .hello(
                    try SyncthingPeerAuthentication.makeHello(
                        senderDeviceID: localDeviceID,
                        intendedPeerDeviceID: hello.deviceID,
                        deviceName: localDeviceName,
                        pairingToken: credential.token
                    )
                )
            )
            if publicationConnectionID == connectionID,
               let pendingOffersProvider {
                let pendingOffers = await pendingOffersProvider()
                guard wantsRunning, !Task.isCancelled else {
                    await connection.cancel()
                    return
                }
                try await sendP2PMessages(
                    pendingOffers,
                    connectionID: connectionID,
                    connection: connection
                )
            }

            while wantsRunning, !Task.isCancelled, let message = try await connection.receive() {
                switch message {
                case .transfer(let transfer):
                    guard wantsRunning,
                          try isCurrentlyPaired(deviceID: hello.deviceID) else {
                        await connection.cancel()
                        return
                    }
                    let responses = await transferHandler(transfer, hello.deviceID)
                    guard wantsRunning,
                          !Task.isCancelled,
                          try isCurrentlyPaired(deviceID: hello.deviceID) else {
                        await connection.cancel()
                        return
                    }
                    try await sendP2PMessages(
                        responses,
                        connectionID: connectionID,
                        connection: connection
                    )

                case .close:
                    return

                case .hello:
                    try? await connection.close(
                        SyncthingPeerClose(
                            code: .protocolError,
                            reason: "一个连接只能发送一次 hello。"
                        )
                    )
                    return

                case .index, .indexUpdate, .blockRequest, .blockResponse, .ack:
                    guard wantsRunning,
                          try isCurrentlyPaired(deviceID: hello.deviceID),
                          let deltaRouter = deltaRouters[connectionID] else {
                        await connection.cancel()
                        return
                    }
                    let responses = try await deltaRouter.receive(message)
                    for response in responses {
                        guard wantsRunning,
                              !Task.isCancelled,
                              try isCurrentlyPaired(deviceID: hello.deviceID) else {
                            await connection.cancel()
                            return
                        }
                        try await connection.send(response)
                    }
                }
            }
        } catch is CancellationError {
            await connection.cancel()
        } catch {
            if !Task.isCancelled {
                state.lastErrorMessage = error.localizedDescription
            }
            await connection.cancel()
        }
    }

    private func sendP2PMessages(
        _ messages: [SyncWireMessage],
        connectionID: UUID,
        connection: any MacSyncthingPeerConnectionProtocol
    ) async throws {
        var advertisedOffers = 0
        for message in messages {
            guard wantsRunning, !Task.isCancelled else {
                throw CancellationError()
            }
            if case let .offer(offer) = message {
                if streamingConnections.contains(connectionID) {
                    guard advertisedOffers < 32 else { continue }
                    advertisedOffers += 1
                    try await connection.send(.transfer(message))
                    continue
                }
                guard offer.metadata.byteSize <= SyncthingDeltaSession.maximumInMemoryFileSize,
                      let deltaRouter = deltaRouters[connectionID] else {
                    // Older clients do not advertise the streaming extension.
                    continue
                }

                let deltaMessage: SyncthingPeerMessage?
                do {
                    deltaMessage = try await deltaRouter.publish(offer)
                } catch {
                    // A changed source or stale queue item should not tear down an otherwise
                    // healthy peer. Actual network send failures below still propagate.
                    state.lastErrorMessage = error.localizedDescription
                    continue
                }
                if let deltaMessage {
                    guard wantsRunning, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    try await connection.send(deltaMessage)
                }
                continue
            }

            try await connection.send(.transfer(message))
        }
    }

    private func preferredPublicationConnectionID() -> UUID? {
        if let publicationConnectionID,
           authenticatedDeviceIDs[publicationConnectionID] != nil,
           connections[publicationConnectionID] != nil {
            return publicationConnectionID
        }
        let next = authenticatedDeviceIDs.keys
            .filter { connections[$0] != nil }
            .sorted { $0.uuidString < $1.uuidString }
            .first
        publicationConnectionID = next
        return next
    }

    private func isCurrentlyPaired(deviceID: UUID) throws -> Bool {
        try currentCredential(deviceID: deviceID) != nil
    }

    private func receiveFirstMessage(
        from connection: any MacSyncthingPeerConnectionProtocol
    ) async throws -> SyncthingPeerMessage? {
        let timeout = helloTimeout
        return try await withThrowingTaskGroup(of: SyncthingPeerMessage?.self) { group in
            group.addTask { try await connection.receive() }
            group.addTask {
                try await Task.sleep(for: timeout)
                await connection.cancel()
                throw MacSyncthingSyncServerError.helloTimedOut
            }
            defer { group.cancelAll() }
            guard let firstResult = try await group.next() else { return nil }
            return firstResult
        }
    }

    private func currentCredential(deviceID: UUID) throws -> MobilityMacPairingCredential? {
        guard let configured = configuredCredentials[deviceID],
              let current = try credentialStore.credential(for: deviceID),
              current.token == configured.pairingToken else {
            return nil
        }
        return current
    }

    private func consumeHelloNonce(_ nonce: UUID, now: Date = Date()) -> Bool {
        seenHelloNonces = seenHelloNonces.filter {
            now.timeIntervalSince($0.value) <= helloNonceRetention
        }
        guard seenHelloNonces[nonce] == nil else { return false }
        seenHelloNonces[nonce] = now
        return true
    }

    private func disconnectSessions(where shouldDisconnect: (UUID?) -> Bool) async {
        let connectionIDs = connections.keys.filter {
            shouldDisconnect(authenticatedDeviceIDs[$0])
        }
        for connectionID in connectionIDs {
            connectionTasks[connectionID]?.cancel()
            if let connection = connections[connectionID] {
                await connection.cancel()
            }
            connectionTasks[connectionID] = nil
            connections[connectionID] = nil
            authenticatedDeviceIDs[connectionID] = nil
            streamingConnections.remove(connectionID)
            deltaRouters[connectionID] = nil
            if publicationConnectionID == connectionID {
                publicationConnectionID = nil
            }
        }
        publishConnectionState()
    }

    private func finishConnection(_ connectionID: UUID) {
        connectionTasks[connectionID] = nil
        connections[connectionID] = nil
        authenticatedDeviceIDs[connectionID] = nil
            streamingConnections.remove(connectionID)
        deltaRouters[connectionID] = nil
        if publicationConnectionID == connectionID {
            publicationConnectionID = nil
        }
        publishConnectionState()
    }

    private func handle(
        _ listenerState: MacSyncthingPeerListenerState,
        generation: UInt64
    ) {
        guard wantsRunning, generation == configurationGeneration else { return }
        switch listenerState {
        case .starting:
            publishState(phase: .starting, lastErrorMessage: nil)
        case .waiting(let message):
            publishState(phase: .starting, lastErrorMessage: message)
        case .ready:
            publishState(phase: .advertising, lastErrorMessage: nil)
        case .failed(let message):
            publishState(phase: .failed, lastErrorMessage: message)
            scheduleListenerRestart(generation: generation)
        case .stopped:
            if wantsRunning {
                publishState(phase: .failed, lastErrorMessage: "本地 P2P 监听已停止。")
                scheduleListenerRestart(generation: generation)
            }
        }
    }

    private func scheduleListenerRestart(generation: UInt64) {
        guard wantsRunning, generation == configurationGeneration else { return }
        listenerRestartTask?.cancel()
        let delay = listenerRestartDelay
        listenerRestartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.wantsRunning,
                  generation == self.configurationGeneration else {
                return
            }
            await self.reconfigureListener()
        }
    }

    private func recordConnectionError(_ message: String, generation: UInt64) {
        guard wantsRunning, generation == configurationGeneration else { return }
        state.lastErrorMessage = message
    }

    private func publishConnectionState() {
        state.activeConnectionCount = connections.count
        state.authenticatedPeerDeviceIDs = Array(Set(authenticatedDeviceIDs.values)).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    private func publishState(
        phase: MacSyncthingSyncServerPhase,
        lastErrorMessage: String?
    ) {
        state.phase = phase
        state.lastErrorMessage = lastErrorMessage
        publishConnectionState()
    }

    private static func defaultServiceName(deviceName: String, deviceID: UUID) -> String {
        let prefix = "Tidux助手 - "
        let maximumServiceNameUTF8Bytes = 63
        let cleanName = deviceName
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let normalized = String(String.UnicodeScalarView(cleanName))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            let availableBytes = maximumServiceNameUTF8Bytes - prefix.utf8.count
            return prefix + truncateUTF8(normalized, maximumBytes: availableBytes)
        }
        return prefix + String(deviceID.uuidString.prefix(8))
    }

    private static func truncateUTF8(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumBytes else { break }
            result = candidate
        }
        return result
    }
}
