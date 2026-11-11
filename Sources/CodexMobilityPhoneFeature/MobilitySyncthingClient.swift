import CodexMobilityCore
import Combine
import Foundation

#if canImport(Network)
@preconcurrency import Network

public enum MobilitySyncthingClientState: Equatable, Sendable {
    case idle
    case browsing
    case connecting
    case ready(computerName: String)
    case failed(String)
}

public enum MobilitySyncthingClientError: LocalizedError, Equatable, Sendable {
    case connectionTimedOut
    case remoteClosedBeforeHello
    case expectedHello
    case unsupportedProtocol(UInt16)
    case unexpectedComputer(expected: String, actual: UUID)
    case invalidStoredComputerIdentifier(String)
    case noPairedComputer

    public var errorDescription: String? {
        switch self {
        case .connectionTimedOut:
            "连接 Mac 超时，等待局域网或点对点链路恢复。"
        case .remoteClosedBeforeHello:
            "Mac 在身份确认前关闭了同步连接。"
        case .expectedHello:
            "Mac 返回了无效的同步握手。"
        case .unsupportedProtocol(let version):
            "Mac 的同步协议版本不兼容（\(version)）。"
        case .unexpectedComputer(let expected, let actual):
            "发现的 Mac 身份不匹配（期望 \(expected)，实际 \(actual.uuidString)）。"
        case .invalidStoredComputerIdentifier(let value):
            "已保存的 Mac 身份无效（\(value)），请重新配对。"
        case .noPairedComputer:
            "请先通过蓝牙与 Mac 完成配对。"
        }
    }
}

/// iPhone-side Syncthing-like fast path.
///
/// Bluetooth remains the pairing and control channel. This client discovers the paired
/// Mac with Bonjour and moves file protocol messages over TLS-PSK on Wi-Fi, Personal
/// Hotspot when routable. It never trusts Bonjour metadata;
/// the Keychain pairing token authenticates TLS and the first peer hello is pinned to the
/// Mac identifier stored during pairing.
@MainActor
public final class MobilitySyncthingClient: ObservableObject {
    public static let lanCapabilities = SyncTransportCapabilities(
        maximumFrameSize: SyncthingPeerProtocolLimits.maximumMessageSize,
        preferredChunkSize: SyncProtocolLimits.maximumChunkSize,
        maximumWindowSize: SyncProtocolLimits.maximumWindowSize
    )

    @Published public private(set) var state: MobilitySyncthingClientState = .idle
    @Published public private(set) var lastErrorMessage: String?

    public var onTransferMessage: (@MainActor @Sendable (SyncWireMessage) -> Void)?
    public var onPeerMessage: (@MainActor @Sendable (
        SyncthingPeerMessage
    ) async throws -> [SyncthingPeerMessage])?
    public var onConnectionReady: (@MainActor @Sendable () -> Void)?
    public var onConnectionClosed: (@MainActor @Sendable () -> Void)?

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private let credentialVault: any MobilityCredentialVault
    private let localDeviceID: UUID
    private let localDeviceName: String
    private let browser: SyncthingPeerBrowser

    private var credentials: [MobilityPairingCredential] = []
    private var latestEndpoints: [NWEndpoint] = []
    private var pairedHintEndpoints: [NWEndpoint] = []

    /// Hints arrive over authenticated BLE; TLS and pinned device identity still authenticate the peer.
    public func updatePairedEndpoint(_ snapshot: CompanionDashboardSnapshot) {
        guard credentials.contains(where: { $0.computerIdentifier.lowercased() == snapshot.deviceID.uuidString.lowercased() }),
              let host = snapshot.fileHost, let port = snapshot.filePort, port > 0,
              Self.isPrivateIPv4(host) else { return }
        let next: [NWEndpoint] = [.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)]
        let changed = !pairedHintEndpoints.isEmpty && pairedHintEndpoints != next
        pairedHintEndpoints = next
        if changed { recoverNetworkConnection(); return }
        connectIfPossible()
    }

    nonisolated static func isPrivateIPv4(_ host: String) -> Bool {
        let fields = host.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let parts = fields.compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }

    private var activeConnection: SyncthingPeerConnection?
    private var connectionGeneration: UUID?
    private var hasStarted = false
    private var isBrowserStarted = false
    private var isConnecting = false
    private var connectionAttemptGeneration: UInt64 = 0
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var networkRecoveryTask: Task<Void, Never>?
    private var networkRecoveryID: UUID?
    private var reconnectAttempt = 0
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorID: UUID?
    private var lastPathSignature: String?
    private var networkAvailable = true

    public init(
        credentialVault: any MobilityCredentialVault = KeychainMobilityCredentialVault(),
        localDeviceID: UUID,
        localDeviceName: String,
        browser: SyncthingPeerBrowser = SyncthingPeerBrowser()
    ) {
        self.credentialVault = credentialVault
        self.localDeviceID = localDeviceID
        self.localDeviceName = localDeviceName
        self.browser = browser
    }

    public func start() {
        guard !hasStarted else {
            refreshCredentials()
            if activeConnection == nil { connectIfPossible() }
            return
        }
        hasStarted = true
        let monitor = NWPathMonitor()
        let monitorID = UUID()
        pathMonitorID = monitorID
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let usedTypes = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other]
                .filter { path.usesInterfaceType($0) }.map { String(describing: $0) }
            let signature = "\(path.status)|\(usedTypes)|\(path.availableInterfaces.map(\.name).sorted())|\(path.isExpensive)|\(path.isConstrained)"
            Task { @MainActor [weak self] in
                guard let self, self.hasStarted, self.pathMonitorID == monitorID else { return }
                let changed = self.lastPathSignature != nil && self.lastPathSignature != signature
                self.lastPathSignature = signature
                self.networkAvailable = available
                if changed || !available { self.recoverNetworkConnection() }
                else if available { self.connectIfPossible() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.tidux.codex-mobility.phone-path"))
        refreshCredentials()
    }

    /// Reloads Keychain pairing records after first pairing or credential rotation.
    public func refreshCredentials() {
        let previousCredentials = credentials
        let loadedCredentials: [MobilityPairingCredential]
        do {
            loadedCredentials = try credentialVault.allCredentials()
            lastErrorMessage = nil
        } catch {
            invalidateConnectionAttempt()
            credentials = []
            disconnectActiveConnectionForCredentialChange()
            state = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            return
        }

        credentials = loadedCredentials
        if loadedCredentials != previousCredentials {
            invalidateConnectionAttempt()
            disconnectActiveConnectionForCredentialChange()
            pairedHintEndpoints = []
        }

        guard !credentials.isEmpty else {
            isBrowserStarted = false
            Task { await browser.stop() }
            state = .idle
            lastErrorMessage = MobilitySyncthingClientError.noPairedComputer.localizedDescription
            return
        }
        Task { await beginBrowsingIfNeeded() }
    }

    @discardableResult
    public func send(_ message: SyncWireMessage) -> Bool {
        sendPeerMessage(.transfer(message))
    }

    /// Sends an index/block message on the current authenticated connection.
    /// The captured generation prevents a failed old send from closing a newer connection.
    @discardableResult
    public func send(_ message: SyncthingPeerMessage) -> Bool {
        sendPeerMessage(message)
    }

    private func sendPeerMessage(_ message: SyncthingPeerMessage) -> Bool {
        guard let connection = activeConnection, let generation = connectionGeneration else {
            return false
        }
        Task {
            do {
                try await connection.send(message)
            } catch {
                await connection.cancel()
                handleConnectionLoss(error, generation: generation)
            }
        }
        return true
    }

    public func stop() {
        hasStarted = false
        pathMonitor?.cancel()
        pathMonitor = nil
        pathMonitorID = nil
        lastPathSignature = nil
        networkAvailable = true
        reconnectTask?.cancel(); reconnectTask = nil
        networkRecoveryTask?.cancel(); networkRecoveryTask = nil
        networkRecoveryID = nil
        pairedHintEndpoints = []
        invalidateConnectionAttempt()
        isConnecting = false
        latestEndpoints = []
        let connection = activeConnection
        activeConnection = nil
        connectionGeneration = nil
        let wasReady = isReady
        state = .idle

        Task {
            await browser.stop()
            await connection?.cancel()
        }
        isBrowserStarted = false
        if wasReady { onConnectionClosed?() }
    }

    private func beginBrowsingIfNeeded() async {
        guard hasStarted, networkAvailable, activeConnection == nil, !isBrowserStarted, !credentials.isEmpty else {
            return
        }
        isBrowserStarted = true
        state = .browsing

        do {
            try await browser.start(
                onResultsChanged: { [weak self] results in
                    Task { @MainActor [weak self] in
                        self?.receiveBrowserResults(results)
                    }
                },
                onStateChange: { [weak self] browserState in
                    guard case .failed(let error) = browserState else { return }
                    Task { @MainActor [weak self] in
                        self?.handleBrowserFailure(error)
                    }
                }
            )
        } catch {
            isBrowserStarted = false
            state = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            scheduleReconnect()
        }
    }

    private func receiveBrowserResults(_ results: Set<NWBrowser.Result>) {
        latestEndpoints = results.map(\.endpoint).sorted {
            String(describing: $0) < String(describing: $1)
        }
        connectIfPossible()
    }

    private func connectIfPossible() {
        guard hasStarted,
              networkAvailable, networkRecoveryTask == nil,
              activeConnection == nil,
              !isConnecting,
              !(pairedHintEndpoints + latestEndpoints).isEmpty,
              !credentials.isEmpty else {
            return
        }

        isConnecting = true
        reconnectTask?.cancel(); reconnectTask = nil
        state = .connecting
        let endpoints = pairedHintEndpoints + latestEndpoints
        let candidateCredentials = credentials
        connectionAttemptGeneration &+= 1
        let attemptGeneration = connectionAttemptGeneration

        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastError: Error = MobilitySyncthingClientError.connectionTimedOut
            for endpoint in endpoints {
                for credential in candidateCredentials {
                    guard !Task.isCancelled,
                          self.hasStarted,
                          self.connectionAttemptGeneration == attemptGeneration else {
                        return
                    }
                    do {
                        let connection = try await Self.connect(
                            endpoint: endpoint,
                            credential: credential,
                            localDeviceID: self.localDeviceID,
                            localDeviceName: self.localDeviceName
                        )
                        guard !Task.isCancelled,
                              self.hasStarted,
                              self.connectionAttemptGeneration == attemptGeneration,
                              self.credentials.contains(credential),
                              self.activeConnection == nil else {
                            await connection.cancel()
                            return
                        }
                        self.connectTask = nil
                        self.accept(
                            connection,
                            credential: credential
                        )
                        return
                    } catch {
                        lastError = error
                    }
                }
            }
            guard !Task.isCancelled,
                  self.hasStarted,
                  self.connectionAttemptGeneration == attemptGeneration else {
                return
            }
            self.connectTask = nil
            self.isConnecting = false
            self.lastErrorMessage = lastError.localizedDescription
            self.state = .browsing
            self.scheduleReconnect()
        }
    }

    nonisolated static func connect(
        endpoint: NWEndpoint,
        credential: MobilityPairingCredential,
        localDeviceID: UUID,
        localDeviceName: String,
        includePeerToPeer: Bool = false,
        handshakeTimeout: Duration = .seconds(6)
    ) async throws -> SyncthingPeerConnection {
        guard let expectedID = UUID(uuidString: credential.computerIdentifier) else {
            throw MobilitySyncthingClientError.invalidStoredComputerIdentifier(
                credential.computerIdentifier
            )
        }
        let peerCredential = SyncthingPeerCredential(
            deviceID: localDeviceID,
            pairingToken: credential.token
        )
        let connection = try await withTimeout(timeout: handshakeTimeout) {
            try await SyncthingPeerConnection.connect(
                to: endpoint,
                credential: peerCredential,
                includePeerToPeer: includePeerToPeer
            )
        }

        do {
            let localHello = try SyncthingPeerAuthentication.makeHello(
                senderDeviceID: localDeviceID,
                intendedPeerDeviceID: expectedID,
                deviceName: localDeviceName,
                folderIDs: ["codex-sync", "codex-media-stream-v1"],
                pairingToken: credential.token
            )
            try await connection.send(
                .hello(localHello)
            )
            guard let firstMessage = try await withTimeout(timeout: handshakeTimeout, operation: {
                try await connection.receive()
            }) else {
                throw MobilitySyncthingClientError.remoteClosedBeforeHello
            }
            guard case .hello(let hello) = firstMessage else {
                throw MobilitySyncthingClientError.expectedHello
            }
            guard hello.protocolVersion == SyncthingPeerProtocolLimits.currentVersion else {
                throw MobilitySyncthingClientError.unsupportedProtocol(hello.protocolVersion)
            }
            guard expectedID == hello.deviceID else {
                throw MobilitySyncthingClientError.unexpectedComputer(
                    expected: credential.computerIdentifier,
                    actual: hello.deviceID
                )
            }
            try SyncthingPeerAuthentication.requireValid(
                hello,
                expectedLocalDeviceID: localDeviceID,
                pairingToken: credential.token
            )
            return connection
        } catch {
            await connection.cancel()
            throw error
        }
    }

    private func accept(
        _ connection: SyncthingPeerConnection,
        credential: MobilityPairingCredential
    ) {
        let generation = UUID()
        activeConnection = connection
        connectionGeneration = generation
        isConnecting = false
        reconnectAttempt = 0
        reconnectTask?.cancel(); reconnectTask = nil
        lastErrorMessage = nil
        state = .ready(computerName: credential.computerName)
        onConnectionReady?()

        Task {
            await browser.stop()
            isBrowserStarted = false
            await receiveLoop(connection, generation: generation)
        }
    }

    private func receiveLoop(
        _ connection: SyncthingPeerConnection,
        generation: UUID
    ) async {
        do {
            while let message = try await connection.receive() {
                guard connectionGeneration == generation else { return }
                switch message {
                case .transfer(let transfer):
                    onTransferMessage?(transfer)
                case .close:
                    handleConnectionLoss(nil, generation: generation)
                    return
                case .index, .indexUpdate, .blockRequest, .blockResponse, .ack:
                    guard let onPeerMessage else { continue }
                    let responses = try await onPeerMessage(message)
                    guard connectionGeneration == generation else { return }
                    for response in responses {
                        try await connection.send(response)
                    }
                case .hello:
                    // The destination-bound hello is consumed before this loop starts.
                    continue
                }
            }
            handleConnectionLoss(nil, generation: generation)
        } catch {
            handleConnectionLoss(error, generation: generation)
        }
    }

    private func handleConnectionLoss(_ error: Error?, generation: UUID) {
        guard connectionGeneration == generation else { return }
        let wasReady = isReady
        let connection = activeConnection
        activeConnection = nil
        connectionGeneration = nil
        isConnecting = false
        if let error {
            lastErrorMessage = error.localizedDescription
        }
        state = credentials.isEmpty ? .idle : .browsing
        if wasReady { onConnectionClosed?() }
        Task { await connection?.cancel() }
        scheduleReconnect()
    }

    private func handleBrowserFailure(_ error: NWError) {
        isBrowserStarted = false
        lastErrorMessage = error.localizedDescription
        state = .failed(error.localizedDescription)
        Task {
            await browser.stop()
            scheduleReconnect()
        }
    }

    private func invalidateConnectionAttempt() {
        connectionAttemptGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        isConnecting = false
    }

    private func disconnectActiveConnectionForCredentialChange() {
        guard let connection = activeConnection else { return }
        let wasReady = isReady
        activeConnection = nil
        connectionGeneration = nil
        state = credentials.isEmpty ? .idle : .browsing
        Task { await connection.cancel() }
        if wasReady { onConnectionClosed?() }
    }

    private func scheduleReconnect() {
        guard hasStarted, networkAvailable, activeConnection == nil, !credentials.isEmpty,
              reconnectTask == nil, networkRecoveryTask == nil else { return }
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30)
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.reconnectTask = nil
            guard self.hasStarted, self.activeConnection == nil else { return }
            if self.isBrowserStarted {
                self.connectIfPossible()
            } else {
                await self.beginBrowsingIfNeeded()
                self.connectIfPossible()
            }
        }
    }

    /// Path changes and authenticated BLE address updates invalidate the old socket.
    /// File state is durable; operation payloads are never replayed here.
    private func recoverNetworkConnection() {
        guard hasStarted else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempt = 0
        invalidateConnectionAttempt()
        let generation = connectionAttemptGeneration
        let connection = activeConnection
        let wasReady = isReady
        activeConnection = nil
        connectionGeneration = nil
        latestEndpoints = []
        state = .browsing
        if wasReady { onConnectionClosed?() }
        networkRecoveryTask?.cancel()
        let recoveryID = UUID()
        networkRecoveryID = recoveryID
        networkRecoveryTask = Task { [weak self] in
            await connection?.cancel()
            guard let self else { return }
            defer {
                if self.networkRecoveryID == recoveryID {
                    self.networkRecoveryID = nil
                    self.networkRecoveryTask = nil
                    self.scheduleReconnect()
                }
            }
            guard !Task.isCancelled, self.networkRecoveryID == recoveryID else { return }
            await self.browser.stop()
            self.isBrowserStarted = false
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard self.hasStarted, self.connectionAttemptGeneration == generation else { return }
            self.networkRecoveryTask = nil
            guard self.networkAvailable else { return }
            await self.beginBrowsingIfNeeded()
            self.connectIfPossible()
        }
    }

    private nonisolated static func withTimeout<T: Sendable>(
        timeout: Duration = .seconds(6),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MobilitySyncthingClientError.connectionTimedOut
            }
            guard let result = try await group.next() else {
                throw MobilitySyncthingClientError.connectionTimedOut
            }
            group.cancelAll()
            return result
        }
    }
}
#endif
