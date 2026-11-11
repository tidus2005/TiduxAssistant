import Foundation

public struct SyncthingPeerCredential: Codable, Equatable, Hashable, Sendable {
    public var deviceID: UUID
    public var pairingToken: String

    public init(deviceID: UUID, pairingToken: String) {
        self.deviceID = deviceID
        self.pairingToken = pairingToken
    }
}

public enum SyncthingPeerTransportError: Error, Equatable, Sendable {
    case missingCredentials
    case pairingTokenTooShort(deviceID: UUID)
    case alreadyStarted
    case notStarted
    case credentialsLocked
    case concurrentReceive
    case handshakeTimedOut
    case pendingConnectionLimitReached(maximum: Int)
    case connectionFailed(String)
    case connectionCancelled
}

extension SyncthingPeerTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "没有可用的已配对设备凭据。"
        case .pairingTokenTooShort:
            "配对凭据强度不足，请重新配对。"
        case .alreadyStarted:
            "点对点网络服务已经启动。"
        case .notStarted:
            "点对点网络服务尚未启动。"
        case .credentialsLocked:
            "网络服务运行期间不能直接修改配对凭据。"
        case .concurrentReceive:
            "同一连接出现了重复接收任务。"
        case .handshakeTimedOut:
            "点对点加密握手超时。"
        case .pendingConnectionLimitReached:
            "等待身份验证的连接过多，已拒绝新的连接。"
        case .connectionFailed(let detail):
            "点对点连接失败：\(detail)"
        case .connectionCancelled:
            "点对点连接已取消。"
        }
    }
}

#if canImport(Network)
import Dispatch
import Network
import Security

/// TLS-only Network.framework configuration shared by clients and listeners.
///
/// Every connection uses TLS-PSK with the random pairing token as the shared secret.
/// The paired device UUID is the public PSK identity. Network.framework's documented PSK
/// configuration uses TLS 1.2 PSK suites, so the protocol is pinned to the DHE-PSK
/// AES-GCM suite below. DHE supplies per-session forward secrecy; there is deliberately
/// no plaintext fallback or unsupported TLS 1.3 external-PSK claim.
public enum SyncthingPeerTLSConfiguration {
    public static let applicationProtocol = "codexsync/1"

    public static func parameters(
        credentials: some Sequence<SyncthingPeerCredential>,
        includePeerToPeer: Bool = false
    ) throws -> NWParameters {
        var credentialsByDeviceID: [UUID: SyncthingPeerCredential] = [:]
        for credential in credentials {
            credentialsByDeviceID[credential.deviceID] = credential
        }
        guard !credentialsByDeviceID.isEmpty else {
            throw SyncthingPeerTransportError.missingCredentials
        }

        let tls = NWProtocolTLS.Options()
        let securityOptions = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(securityOptions, applicationProtocol)
        sec_protocol_options_append_tls_ciphersuite(
            securityOptions,
            tls_ciphersuite_t(rawValue: TLS_DHE_PSK_WITH_AES_128_GCM_SHA256)!
        )

        // Require possession of a currently paired token on every new connection. In
        // particular, a revoked token must not remain usable through a cached TLS ticket.
        sec_protocol_options_set_tls_tickets_enabled(securityOptions, false)
        sec_protocol_options_set_tls_resumption_enabled(securityOptions, false)

        for credential in credentialsByDeviceID.values.sorted(by: {
            $0.deviceID.uuidString < $1.deviceID.uuidString
        }) {
            let key = try SyncthingPeerAuthentication.pairingKeyData(
                from: credential.pairingToken
            )
            let identity = Data(credential.deviceID.uuidString.lowercased().utf8)
            let keyDispatchData = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identityDispatchData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(
                securityOptions,
                keyDispatchData as dispatch_data_t,
                identityDispatchData as dispatch_data_t
            )
        }

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = includePeerToPeer
        return parameters
    }
}

public actor SyncthingPeerConnection {
    private static let maximumReceiveChunkSize = 64 * 1_024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var frameDecoder = SyncthingPeerIncrementalFrameDecoder()
    private var pendingMessages: [SyncthingPeerMessage] = []
    private var isStarted = false
    private var isReceiving = false
    private var reachedEndOfStream = false
    private var didCloseOutput = false

    public init(connection: NWConnection, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.queue = queue ?? DispatchQueue(
            label: "com.tidux.codex-mobility.peer-connection.\(UUID().uuidString)"
        )
    }

    public nonisolated static func connect(
        to endpoint: NWEndpoint,
        credential: SyncthingPeerCredential,
        includePeerToPeer: Bool = false,
        queue: DispatchQueue? = nil
    ) async throws -> SyncthingPeerConnection {
        let parameters = try SyncthingPeerTLSConfiguration.parameters(
            credentials: [credential],
            includePeerToPeer: includePeerToPeer
        )
        let peer = SyncthingPeerConnection(
            connection: NWConnection(to: endpoint, using: parameters),
            queue: queue
        )
        try await peer.start()
        return peer
    }

    public func start() async throws {
        guard !isStarted else { throw SyncthingPeerTransportError.alreadyStarted }
        isStarted = true

        let connection = self.connection
        let queue = self.queue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let gate = SyncthingPeerReadyGate(continuation: continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.succeed()
                    case .failed(let error):
                        gate.fail(.connectionFailed(error.debugDescription))
                    case .cancelled:
                        gate.fail(.connectionCancelled)
                    case .waiting:
                        // Hotspot and AWDL paths can enter a temporary waiting state while
                        // routing changes. The caller/listener handshake deadline remains
                        // the single cancellation policy instead of creating retry storms.
                        break
                    case .setup, .preparing:
                        break
                    @unknown default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func send(_ message: SyncthingPeerMessage) async throws {
        guard isStarted else { throw SyncthingPeerTransportError.notStarted }
        guard !didCloseOutput else { throw SyncthingPeerTransportError.connectionCancelled }
        let frame = try SyncthingPeerFrameCodec().encode(message)
        let connection = self.connection

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: frame,
                contentContext: .defaultStream,
                isComplete: false,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: SyncthingPeerTransportError.connectionFailed(
                                error.debugDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Returns the next complete message, or `nil` after a clean peer EOF.
    /// Only one receive operation may be active for a connection at a time.
    public func receive() async throws -> SyncthingPeerMessage? {
        guard isStarted else { throw SyncthingPeerTransportError.notStarted }
        guard !isReceiving else { throw SyncthingPeerTransportError.concurrentReceive }
        isReceiving = true
        defer { isReceiving = false }

        if !pendingMessages.isEmpty {
            return pendingMessages.removeFirst()
        }
        if reachedEndOfStream {
            return nil
        }

        while true {
            let chunk = try await receiveChunk()
            if let data = chunk.data, !data.isEmpty {
                let payloads = try frameDecoder.append(data)
                let codec = SyncthingPeerJSONCodec()
                pendingMessages.append(contentsOf: try payloads.map(codec.decode))
            }

            if chunk.isComplete {
                reachedEndOfStream = true
                try frameDecoder.finish()
            }
            if !pendingMessages.isEmpty {
                return pendingMessages.removeFirst()
            }
            if reachedEndOfStream {
                return nil
            }
        }
    }

    /// Sends a protocol close message and then cleanly finishes the TCP output stream.
    public func close(_ close: SyncthingPeerClose = SyncthingPeerClose()) async throws {
        guard !didCloseOutput else { return }
        try await send(.close(close))
        didCloseOutput = true
        let connection = self.connection

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: SyncthingPeerTransportError.connectionFailed(
                                error.debugDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    public func cancel() {
        connection.cancel()
    }

    public var endpoint: NWEndpoint { connection.endpoint }

    private func receiveChunk() async throws -> SyncthingPeerReceiveChunk {
        let connection = self.connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SyncthingPeerReceiveChunk, any Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: Self.maximumReceiveChunkSize
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(
                            throwing: SyncthingPeerTransportError.connectionFailed(
                                error.debugDescription
                            )
                        )
                    } else {
                        continuation.resume(
                            returning: SyncthingPeerReceiveChunk(data: data, isComplete: isComplete)
                        )
                    }
                }
            }
        } onCancel: {
            // A receive continuation has no native Swift cancellation hook. Cancelling
            // the NWConnection guarantees its callback fires, so timeout task groups can
            // actually finish instead of waiting forever for a silent peer.
            connection.cancel()
        }
    }
}

public actor SyncthingPeerListener {
    public static let serviceType = "_codexsync._tcp"

    private let serviceName: String?
    private let includePeerToPeer: Bool
    private let handshakeTimeout: Duration
    private let maximumPendingConnections: Int
    private let queue: DispatchQueue
    private var credentialsByDeviceID: [UUID: SyncthingPeerCredential]
    private var listener: NWListener?
    private var isReady = false
    private var pendingConnectionTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        serviceName: String? = nil,
        credentials: [SyncthingPeerCredential] = [],
        includePeerToPeer: Bool = false,
        handshakeTimeout: Duration = .seconds(8),
        maximumPendingConnections: Int = 8,
        queue: DispatchQueue? = nil
    ) {
        self.serviceName = serviceName
        self.includePeerToPeer = includePeerToPeer
        self.handshakeTimeout = handshakeTimeout
        self.maximumPendingConnections = max(maximumPendingConnections, 1)
        self.credentialsByDeviceID = Dictionary(
            credentials.map { ($0.deviceID, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        self.queue = queue ?? DispatchQueue(label: "com.tidux.codex-mobility.peer-listener")
    }

    /// Adds or rotates one paired device PSK. Credentials are frozen after `start`.
    public func addCredential(_ credential: SyncthingPeerCredential) throws {
        guard listener == nil else { throw SyncthingPeerTransportError.credentialsLocked }
        // Validate immediately instead of waiting for listener startup.
        _ = try SyncthingPeerTLSConfiguration.parameters(credentials: [credential])
        credentialsByDeviceID[credential.deviceID] = credential
    }

    public func removeCredential(for deviceID: UUID) throws {
        guard listener == nil else { throw SyncthingPeerTransportError.credentialsLocked }
        credentialsByDeviceID.removeValue(forKey: deviceID)
    }

    public var credentialCount: Int { credentialsByDeviceID.count }

    public func start(
        onConnection: @escaping @Sendable (SyncthingPeerConnection) async -> Void,
        onConnectionError: @escaping @Sendable (SyncthingPeerTransportError) -> Void = { _ in },
        onStateChange: @escaping @Sendable (NWListener.State) -> Void = { _ in }
    ) throws {
        guard listener == nil else { throw SyncthingPeerTransportError.alreadyStarted }
        let parameters = try SyncthingPeerTLSConfiguration.parameters(
            credentials: credentialsByDeviceID.values,
            includePeerToPeer: includePeerToPeer
        )
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: serviceName,
            type: Self.serviceType
        )
        listener.stateUpdateHandler = { [weak self] state in
            onStateChange(state)
            Task { await self?.record(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.beginPendingConnection(
                    connection,
                    onConnection: onConnection,
                    onConnectionError: onConnectionError
                )
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for task in pendingConnectionTasks.values {
            task.cancel()
        }
        pendingConnectionTasks.removeAll()
        isReady = false
    }

    public var port: NWEndpoint.Port? { isReady ? listener?.port : nil }

    private func record(_ state: NWListener.State) {
        switch state {
        case .ready:
            isReady = true
        case .setup, .waiting:
            isReady = false
        case .failed, .cancelled:
            isReady = false
        @unknown default:
            isReady = false
        }
    }

    private func beginPendingConnection(
        _ connection: NWConnection,
        onConnection: @escaping @Sendable (SyncthingPeerConnection) async -> Void,
        onConnectionError: @escaping @Sendable (SyncthingPeerTransportError) -> Void
    ) {
        guard pendingConnectionTasks.count < maximumPendingConnections else {
            connection.cancel()
            onConnectionError(
                .pendingConnectionLimitReached(maximum: maximumPendingConnections)
            )
            return
        }

        let connectionID = UUID()
        let timeout = handshakeTimeout
        let task = Task { [weak self] in
            let peer = SyncthingPeerConnection(connection: connection)
            do {
                try await Self.start(peer, timeout: timeout)
                guard !Task.isCancelled else {
                    await peer.cancel()
                    await self?.finishPendingConnection(connectionID)
                    return
                }
                await onConnection(peer)
            } catch let error as SyncthingPeerTransportError {
                if !Task.isCancelled { onConnectionError(error) }
            } catch {
                if !Task.isCancelled {
                    onConnectionError(.connectionFailed(String(describing: error)))
                }
            }
            await self?.finishPendingConnection(connectionID)
        }
        pendingConnectionTasks[connectionID] = task
    }

    private func finishPendingConnection(_ connectionID: UUID) {
        pendingConnectionTasks[connectionID] = nil
    }

    private nonisolated static func start(
        _ peer: SyncthingPeerConnection,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await peer.start() }
            group.addTask {
                try await Task.sleep(for: timeout)
                await peer.cancel()
                throw SyncthingPeerTransportError.handshakeTimedOut
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw SyncthingPeerTransportError.connectionCancelled
            }
        }
    }
}

public actor SyncthingPeerBrowser {
    public static let serviceType = SyncthingPeerListener.serviceType

    private let queue: DispatchQueue
    private var browser: NWBrowser?

    public init(queue: DispatchQueue? = nil) {
        self.queue = queue ?? DispatchQueue(label: "com.tidux.codex-mobility.peer-browser")
    }

    public func start(
        onResultsChanged: @escaping @Sendable (Set<NWBrowser.Result>) -> Void,
        onStateChange: @escaping @Sendable (NWBrowser.State) -> Void = { _ in }
    ) throws {
        guard browser == nil else { throw SyncthingPeerTransportError.alreadyStarted }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = onStateChange
        browser.browseResultsChangedHandler = { results, _ in
            onResultsChanged(results)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

private struct SyncthingPeerReceiveChunk: Sendable {
    var data: Data?
    var isComplete: Bool
}

private final class SyncthingPeerReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func succeed() {
        takeContinuation()?.resume()
    }

    func fail(_ error: SyncthingPeerTransportError) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        defer { continuation = nil }
        return continuation
    }
}
#endif
