import CodexWatchCore
import Darwin
import Foundation
import Security

public enum AppServerJSONRPCID: Codable, Hashable, Sendable {
    case string(String)
    case int(Int64)

    public var stableString: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }

    init?(jsonValue: Any) {
        if let value = jsonValue as? String {
            self = .string(value)
        } else if let value = jsonValue as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            self = .int(value.int64Value)
        } else {
            return nil
        }
    }
}

public struct AppServerApprovalRequest: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: AppServerRequestKind
    public var rawRequestId: AppServerJSONRPCID
    public var threadId: String
    public var turnId: String
    public var itemId: String
    public var approvalId: String?
    public var command: String?
    public var cwd: String?
    public var reason: String?
    public var grantRoot: String?
    public var questionIds: [String]
    public var summary: String
    public var createdAt: Date

    public init(
        kind: AppServerRequestKind = .commandApproval,
        rawRequestId: AppServerJSONRPCID,
        threadId: String,
        turnId: String,
        itemId: String,
        approvalId: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        reason: String? = nil,
        grantRoot: String? = nil,
        questionIds: [String] = [],
        summary: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = "appserver:\(rawRequestId.stableString)"
        self.kind = kind
        self.rawRequestId = rawRequestId
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.approvalId = approvalId
        self.command = command
        self.cwd = cwd
        self.reason = reason
        self.grantRoot = grantRoot
        self.questionIds = questionIds
        self.summary = summary ?? Self.makeSummary(kind: kind, reason: reason, command: command, grantRoot: grantRoot)
        self.createdAt = createdAt
    }

    public static func makeSummary(kind: AppServerRequestKind, reason: String?, command: String?, grantRoot: String?) -> String {
        if let reason = reason?.singleLineTrimmed, !reason.isEmpty {
            return reason
        }
        if kind == .fileChangeApproval {
            if let grantRoot = grantRoot?.singleLineTrimmed, !grantRoot.isEmpty {
                return "Approve file changes under \(grantRoot.shortened(to: 140))."
            }
            return "Codex wants to apply file changes before continuing."
        }
        if kind == .userInput {
            if let command = command?.singleLineTrimmed, !command.isEmpty {
                return command.shortened(to: 180)
            }
            return "Codex needs your input before it can continue."
        }
        if let command = command?.singleLineTrimmed, !command.isEmpty {
            return "Approve command: \(command.shortened(to: 180))"
        }
        return "Codex is waiting for approval before it can continue."
    }
}

public enum AppServerRequestKind: String, Codable, Hashable, Sendable {
    case commandApproval
    case fileChangeApproval
    case userInput
}

public struct AppServerApprovalResolution: Hashable, Sendable {
    public var delivered: Bool
    public var message: String
    public var request: AppServerApprovalRequest?

    public init(delivered: Bool, message: String, request: AppServerApprovalRequest?) {
        self.delivered = delivered
        self.message = message
        self.request = request
    }
}

public protocol AppServerApprovalRouting: Sendable {
    func start()
    func pendingApprovals() -> [AppServerApprovalRequest]
    func liveControlStatus() -> LiveControlStatus
    func resolveApproval(requestId: String, approved: Bool) throws -> AppServerApprovalResolution
    func resolveUserInput(requestId: String, answer: String) throws -> AppServerApprovalResolution
}

public final class AppServerApprovalStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [AppServerApprovalRequest] {
        try lock.withLocking {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder.codexWatchPet.decode([AppServerApprovalRequest].self, from: data)
        }
    }

    public func upsert(_ request: AppServerApprovalRequest) throws {
        try lock.withLocking {
            var requests = try loadUnlocked()
            requests.removeAll { $0.id == request.id }
            requests.append(request)
            try saveUnlocked(requests.sorted { $0.createdAt < $1.createdAt })
        }
    }

    public func remove(id: String) throws {
        try lock.withLocking {
            var requests = try loadUnlocked()
            requests.removeAll { $0.id == id || $0.rawRequestId.stableString == id }
            try saveUnlocked(requests)
        }
    }

    public func find(id: String) throws -> AppServerApprovalRequest? {
        try load().first { $0.id == id || $0.rawRequestId.stableString == id }
    }

    @discardableResult
    public func prune(olderThan cutoff: Date) throws -> [AppServerApprovalRequest] {
        try lock.withLocking {
            let requests = try loadUnlocked()
            let expired = requests.filter { $0.createdAt < cutoff }
            guard !expired.isEmpty else { return [] }
            try saveUnlocked(requests.filter { $0.createdAt >= cutoff })
            return expired
        }
    }

    private func loadUnlocked() throws -> [AppServerApprovalRequest] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.codexWatchPet.decode([AppServerApprovalRequest].self, from: data)
    }

    private func saveUnlocked(_ requests: [AppServerApprovalRequest]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.codexWatchPet.encode(requests)
        try data.write(to: fileURL, options: .atomic)
    }
}

public final class CodexAppServerApprovalRouter: AppServerApprovalRouting, @unchecked Sendable {
    private let store: AppServerApprovalStore
    private let transport: CodexAppServerWebSocketTransport
    private let maxRequestAgeSeconds: TimeInterval
    private let lock = NSLock()
    private var didStart = false

    public init(
        socketPath: String = NSHomeDirectory() + "/.codex/app-server-control/app-server-control.sock",
        bridgeHome: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-watch-pet"),
        maxRequestAgeSeconds: TimeInterval = 30 * 60
    ) {
        self.store = AppServerApprovalStore(fileURL: bridgeHome.appendingPathComponent("appserver-approvals.json"))
        self.transport = CodexAppServerWebSocketTransport(socketPath: socketPath)
        self.maxRequestAgeSeconds = maxRequestAgeSeconds
    }

    public init(
        store: AppServerApprovalStore,
        transport: CodexAppServerWebSocketTransport,
        maxRequestAgeSeconds: TimeInterval = 30 * 60
    ) {
        self.store = store
        self.transport = transport
        self.maxRequestAgeSeconds = maxRequestAgeSeconds
    }

    public func start() {
        let shouldStart = lock.withLocking {
            guard !didStart else { return false }
            didStart = true
            return true
        }
        guard shouldStart else { return }

        transport.start(
            onApprovalRequest: { [store] request in
                try? store.upsert(request)
            },
            onRequestResolved: { [store] requestId in
                try? store.remove(id: requestId)
            }
        )
    }

    public func pendingApprovals() -> [AppServerApprovalRequest] {
        _ = try? store.prune(olderThan: expirationCutoff())
        return ((try? store.load()) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    public func liveControlStatus() -> LiveControlStatus {
        _ = try? store.prune(olderThan: expirationCutoff())
        let pendingCount = ((try? store.load()) ?? []).count
        return transport.status(pendingRequestCount: pendingCount)
    }

    public func resolveApproval(requestId: String, approved: Bool) throws -> AppServerApprovalResolution {
        guard let request = try store.find(id: requestId), request.kind != .userInput else {
            return AppServerApprovalResolution(
                delivered: false,
                message: "No matching live Codex approval request was found for \(requestId).",
                request: nil
            )
        }
        if isExpired(request) {
            try store.remove(id: request.id)
            return AppServerApprovalResolution(
                delivered: false,
                message: "The live Codex approval request expired on the bridge. Open Codex on Mac to reconcile it.",
                request: request
            )
        }

        let decision = approved ? "accept" : "decline"
        do {
            try transport.sendApprovalResponse(rawRequestId: request.rawRequestId, decision: decision)
            try store.remove(id: request.id)
            return AppServerApprovalResolution(
                delivered: true,
                message: approvalMessage(kind: request.kind, approved: approved),
                request: request
            )
        } catch {
            return AppServerApprovalResolution(
                delivered: false,
                message: "Could not deliver the live Codex approval response: \(error.localizedDescription)",
                request: request
            )
        }
    }

    public func resolveUserInput(requestId: String, answer: String) throws -> AppServerApprovalResolution {
        guard let request = try store.find(id: requestId), request.kind == .userInput else {
            return AppServerApprovalResolution(
                delivered: false,
                message: "No matching live Codex input request was found for \(requestId).",
                request: nil
            )
        }
        if isExpired(request) {
            try store.remove(id: request.id)
            return AppServerApprovalResolution(
                delivered: false,
                message: "The live Codex input request expired on the bridge. Open Codex on Mac to reconcile it.",
                request: request
            )
        }

        guard request.questionIds.count <= 1 else {
            return AppServerApprovalResolution(delivered: false, message: "请在 Mac 上逐题回答，不能将同一段语音提交给多个问题。", request: request)
        }
        let questionIds = request.questionIds.isEmpty ? ["answer"] : request.questionIds
        do {
            try transport.sendUserInputResponse(rawRequestId: request.rawRequestId, questionIds: questionIds, answer: answer)
            try store.remove(id: request.id)
            return AppServerApprovalResolution(
                delivered: true,
                message: "Reply sent to the live Codex app-server request.",
                request: request
            )
        } catch {
            return AppServerApprovalResolution(
                delivered: false,
                message: "Could not deliver the live Codex reply: \(error.localizedDescription)",
                request: request
            )
        }
    }

    private func isExpired(_ request: AppServerApprovalRequest) -> Bool {
        request.createdAt < expirationCutoff()
    }

    private func expirationCutoff() -> Date {
        Date().addingTimeInterval(-maxRequestAgeSeconds)
    }

    private func approvalMessage(kind: AppServerRequestKind, approved: Bool) -> String {
        switch (kind, approved) {
        case (.fileChangeApproval, true):
            "File-change approval sent to the live Codex app-server request."
        case (.fileChangeApproval, false):
            "File-change decline sent to the live Codex app-server request."
        case (_, true):
            "Approval sent to the live Codex app-server request."
        case (_, false):
            "Decline sent to the live Codex app-server request."
        }
    }
}

public enum AppServerApprovalTransportError: Error, LocalizedError, Equatable {
    case socketPathTooLong
    case connectFailed(String)
    case handshakeFailed(String)
    case disconnected
    case writeFailed
    case invalidFrame

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong:
            return "Codex app-server socket path is too long."
        case .connectFailed(let path):
            return "Could not connect to Codex app-server socket at \(path)."
        case .handshakeFailed(let message):
            return "Codex app-server websocket handshake failed: \(message)"
        case .disconnected:
            return "Codex app-server websocket is not connected."
        case .writeFailed:
            return "Could not write to Codex app-server websocket."
        case .invalidFrame:
            return "Received an invalid Codex app-server websocket frame."
        }
    }
}

public final class CodexAppServerWebSocketTransport: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "codex-watch-pet.app-server-approval", qos: .utility)
    private let fdLock = NSLock()
    private var fd: Int32 = -1
    private var connectionState: LiveControlConnectionState = .disconnected
    private var lastConnectedAt: Date?
    private var lastDisconnectedAt: Date?
    private var lastError: String?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func start(
        onApprovalRequest: @escaping @Sendable (AppServerApprovalRequest) -> Void,
        onRequestResolved: @escaping @Sendable (String) -> Void
    ) {
        queue.async { [self] in
            while true {
                do {
                    markConnecting()
                    try connectAndRead(onApprovalRequest: onApprovalRequest, onRequestResolved: onRequestResolved)
                } catch {
                    markDisconnected(error: error)
                    Thread.sleep(forTimeInterval: 5)
                }
            }
        }
    }

    public func status(pendingRequestCount: Int = 0) -> LiveControlStatus {
        fdLock.withLocking {
            LiveControlStatus(
                state: connectionState,
                pendingRequestCount: pendingRequestCount,
                lastConnectedAt: lastConnectedAt,
                lastDisconnectedAt: lastDisconnectedAt,
                lastError: lastError
            )
        }
    }

    public func sendApprovalResponse(rawRequestId: AppServerJSONRPCID, decision: String) throws {
        let message = ApprovalResponseMessage(id: rawRequestId, result: ApprovalDecisionResult(decision: decision))
        let data = try JSONEncoder.codexWatchPetLine.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppServerApprovalTransportError.writeFailed
        }
        try sendText(text)
    }

    public func sendUserInputResponse(rawRequestId: AppServerJSONRPCID, questionIds: [String], answer: String) throws {
        let answers = Dictionary(
            uniqueKeysWithValues: questionIds.map { id in
                (id, UserInputAnswer(answers: [answer]))
            }
        )
        let message = UserInputResponseMessage(id: rawRequestId, result: UserInputResult(answers: answers))
        let data = try JSONEncoder.codexWatchPetLine.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppServerApprovalTransportError.writeFailed
        }
        try sendText(text)
    }

    private func connectAndRead(
        onApprovalRequest: @escaping @Sendable (AppServerApprovalRequest) -> Void,
        onRequestResolved: @escaping @Sendable (String) -> Void
    ) throws {
        let connectedFD = try connectUnixSocket()
        fdLock.withLocking {
            fd = connectedFD
            connectionState = .connecting
        }
        defer {
            close(connectedFD)
            markDisconnected()
        }

        try performHandshake(fd: connectedFD)
        try sendInitialize()
        try readFrames(fd: connectedFD, onApprovalRequest: onApprovalRequest, onRequestResolved: onRequestResolved)
    }

    private func connectUnixSocket() throws -> Int32 {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw AppServerApprovalTransportError.connectFailed(socketPath)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(socketFD)
            throw AppServerApprovalTransportError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
            rawBuffer[pathBytes.count] = 0
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddress in
                connect(socketFD, sockAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(socketFD)
            throw AppServerApprovalTransportError.connectFailed(socketPath)
        }
        return socketFD
    }

    private func performHandshake(fd: Int32) throws {
        let key = randomWebSocketKey()
        let request = [
            "GET / HTTP/1.1",
            "Host: localhost",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "",
            ""
        ].joined(separator: "\r\n")
        try writeAll(Data(request.utf8), to: fd)

        var buffer = Data()
        while !buffer.contains(Data("\r\n\r\n".utf8)) {
            let chunk = try readSome(from: fd)
            guard !chunk.isEmpty else {
                throw AppServerApprovalTransportError.handshakeFailed("connection closed")
            }
            buffer.append(chunk)
            if buffer.count > 16 * 1024 {
                throw AppServerApprovalTransportError.handshakeFailed("response too large")
            }
        }
        guard let response = String(data: buffer, encoding: .utf8),
              response.contains("101 Switching Protocols") else {
            throw AppServerApprovalTransportError.handshakeFailed("unexpected response")
        }
    }

    private func sendInitialize() throws {
        let initialize = InitializeMessage(
            id: .string("codex-watch-pet-initialize"),
            params: InitializeParams(
                clientInfo: ClientInfo(name: "codex-watch-pet", title: "Codex Watch Pet", version: "0.1.0"),
                capabilities: InitializeCapabilities(
                    experimentalApi: true,
                    requestAttestation: false,
                    optOutNotificationMethods: []
                )
            )
        )
        try sendText(String(data: JSONEncoder.codexWatchPetLine.encode(initialize), encoding: .utf8) ?? "{}")
    }

    private func readFrames(
        fd: Int32,
        onApprovalRequest: @escaping @Sendable (AppServerApprovalRequest) -> Void,
        onRequestResolved: @escaping @Sendable (String) -> Void
    ) throws {
        var buffer = Data()
        while true {
            let chunk = try readSome(from: fd)
            guard !chunk.isEmpty else {
                throw AppServerApprovalTransportError.disconnected
            }
            buffer.append(chunk)

            while let frame = try decodeFrame(from: &buffer) {
                switch frame.opcode {
                case 0x1:
                    guard let text = String(data: frame.payload, encoding: .utf8) else { continue }
                    try processText(text, onApprovalRequest: onApprovalRequest, onRequestResolved: onRequestResolved)
                case 0x8:
                    throw AppServerApprovalTransportError.disconnected
                case 0x9:
                    try sendFrame(opcode: 0xA, payload: frame.payload)
                default:
                    continue
                }
            }
        }
    }

    private func processText(
        _ text: String,
        onApprovalRequest: @escaping @Sendable (AppServerApprovalRequest) -> Void,
        onRequestResolved: @escaping @Sendable (String) -> Void
    ) throws {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if object["id"] as? String == "codex-watch-pet-initialize" {
            guard object["error"] == nil, object["result"] != nil else {
                throw AppServerApprovalTransportError.handshakeFailed("Codex rejected client initialization")
            }
            try sendText(String(data: JSONEncoder.codexWatchPetLine.encode(InitializedNotification()), encoding: .utf8) ?? "{}")
            let currentFD = fdLock.withLocking { fd }
            markConnected(fd: currentFD)
            return
        }
        guard let method = object["method"] as? String else { return }

        if method == "item/commandExecution/requestApproval" {
            guard let idValue = object["id"],
                  let rawRequestId = AppServerJSONRPCID(jsonValue: idValue),
                  let paramsObject = object["params"],
                  let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
                  let params = try? JSONDecoder.codexWatchPet.decode(AppServerCommandExecutionRequestApprovalParams.self, from: paramsData) else {
                return
            }
            let createdAt = params.startedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) } ?? Date()
            onApprovalRequest(
                AppServerApprovalRequest(
                    kind: .commandApproval,
                    rawRequestId: rawRequestId,
                    threadId: params.threadId,
                    turnId: params.turnId,
                    itemId: params.itemId,
                    approvalId: params.approvalId,
                    command: params.command,
                    cwd: params.cwd,
                    reason: params.reason,
                    createdAt: createdAt
                )
            )
        } else if method == "item/fileChange/requestApproval" {
            guard let idValue = object["id"],
                  let rawRequestId = AppServerJSONRPCID(jsonValue: idValue),
                  let paramsObject = object["params"],
                  let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
                  let params = try? JSONDecoder.codexWatchPet.decode(AppServerFileChangeRequestApprovalParams.self, from: paramsData) else {
                return
            }
            let createdAt = params.startedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) } ?? Date()
            onApprovalRequest(
                AppServerApprovalRequest(
                    kind: .fileChangeApproval,
                    rawRequestId: rawRequestId,
                    threadId: params.threadId,
                    turnId: params.turnId,
                    itemId: params.itemId,
                    reason: params.reason,
                    grantRoot: params.grantRoot,
                    createdAt: createdAt
                )
            )
        } else if method == "item/tool/requestUserInput" {
            guard let idValue = object["id"],
                  let rawRequestId = AppServerJSONRPCID(jsonValue: idValue),
                  let paramsObject = object["params"],
                  let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
                  let params = try? JSONDecoder.codexWatchPet.decode(AppServerToolRequestUserInputParams.self, from: paramsData) else {
                return
            }
            onApprovalRequest(
                AppServerApprovalRequest(
                    kind: .userInput,
                    rawRequestId: rawRequestId,
                    threadId: params.threadId,
                    turnId: params.turnId,
                    itemId: params.itemId,
                    command: params.summary,
                    questionIds: params.questions.map(\.id),
                    createdAt: Date()
                )
            )
        } else if method == "serverRequest/resolved",
                  let params = object["params"] as? [String: Any],
                  let requestIdValue = params["requestId"],
                  let requestId = AppServerJSONRPCID(jsonValue: requestIdValue)?.stableString {
            onRequestResolved("appserver:\(requestId)")
        }
    }

    private func sendText(_ text: String) throws {
        try fdLock.withLocking {
            guard fd >= 0 else {
                throw AppServerApprovalTransportError.disconnected
            }
            try sendFrame(opcode: 0x1, payload: Data(text.utf8))
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data) throws {
        guard fd >= 0 else {
            throw AppServerApprovalTransportError.disconnected
        }
        var frame = Data()
        frame.append(0x80 | opcode)
        let length = payload.count
        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length <= UInt16.max {
            frame.append(0x80 | 126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF))
            }
        }

        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, mask.count, &mask)
        frame.append(contentsOf: mask)
        var maskedPayload = [UInt8](payload)
        for index in maskedPayload.indices {
            maskedPayload[index] ^= mask[index % 4]
        }
        frame.append(contentsOf: maskedPayload)
        try writeAll(frame, to: fd)
    }

    private func decodeFrame(from buffer: inout Data) throws -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.index(after: buffer.startIndex)]
        var offset = 2
        var length = Int(second & 0x7F)
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for index in 2..<10 {
                length = (length << 8) | Int(buffer[buffer.startIndex + index])
            }
            offset = 10
        }

        let isMasked = (second & 0x80) != 0
        var mask: [UInt8] = []
        if isMasked {
            guard buffer.count >= offset + 4 else { return nil }
            mask = Array(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + 4)])
            offset += 4
        }

        guard buffer.count >= offset + length else { return nil }
        var payload = Array(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + length)])
        if isMasked {
            for index in payload.indices {
                payload[index] ^= mask[index % 4]
            }
        }
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset + length))
        return WebSocketFrame(opcode: first & 0x0F, payload: Data(payload))
    }

    private func readSome(from fd: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count >= 0 else {
            throw AppServerApprovalTransportError.disconnected
        }
        return Data(buffer.prefix(count))
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
                guard count > 0 else {
                    throw AppServerApprovalTransportError.writeFailed
                }
                written += count
            }
        }
    }

    private func randomWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private func markConnecting() {
        fdLock.withLocking {
            connectionState = .connecting
            lastError = nil
        }
    }

    private func markConnected(fd connectedFD: Int32) {
        fdLock.withLocking {
            fd = connectedFD
            connectionState = .connected
            lastConnectedAt = Date()
            lastError = nil
        }
    }

    private func markDisconnected(error: Error? = nil) {
        fdLock.withLocking {
            fd = -1
            connectionState = .disconnected
            lastDisconnectedAt = Date()
            if let error {
                lastError = error.localizedDescription
            }
        }
    }
}

private struct AppServerCommandExecutionRequestApprovalParams: Decodable {
    var threadId: String
    var turnId: String
    var itemId: String
    var approvalId: String?
    var command: String?
    var cwd: String?
    var reason: String?
    var startedAtMs: Int64?
}

private struct AppServerFileChangeRequestApprovalParams: Decodable {
    var threadId: String
    var turnId: String
    var itemId: String
    var grantRoot: String?
    var reason: String?
    var startedAtMs: Int64?
}

private struct AppServerToolRequestUserInputParams: Decodable {
    var threadId: String
    var turnId: String
    var itemId: String
    var questions: [AppServerToolRequestUserInputQuestion]

    var summary: String {
        questions.map(\.displaySummary).joined(separator: " ")
    }
}

private struct AppServerToolRequestUserInputQuestion: Decodable {
    var id: String
    var header: String
    var question: String
    var options: [AppServerToolRequestUserInputOption]?

    var displaySummary: String {
        var parts = [question.singleLineTrimmed]
        if let options, !options.isEmpty {
            let labels = options.map(\.label).joined(separator: " / ")
            parts.append("Options: \(labels)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct AppServerToolRequestUserInputOption: Decodable {
    var label: String
    var description: String
}

private struct WebSocketFrame {
    var opcode: UInt8
    var payload: Data
}

private struct ClientInfo: Encodable {
    var name: String
    var title: String?
    var version: String
}

private struct InitializeCapabilities: Encodable {
    var experimentalApi: Bool
    var requestAttestation: Bool
    var optOutNotificationMethods: [String]
}

private struct InitializeParams: Encodable {
    var clientInfo: ClientInfo
    var capabilities: InitializeCapabilities
}

private struct InitializeMessage: Encodable {
    var id: AppServerJSONRPCID
    var method = "initialize"
    var params: InitializeParams
}

private struct InitializedNotification: Encodable {
    var method = "initialized"
}

private struct ApprovalResponseMessage: Encodable {
    var id: AppServerJSONRPCID
    var result: ApprovalDecisionResult
}

private struct ApprovalDecisionResult: Encodable {
    var decision: String
}

private struct UserInputResponseMessage: Encodable {
    var id: AppServerJSONRPCID
    var result: UserInputResult
}

private struct UserInputResult: Encodable {
    var answers: [String: UserInputAnswer]
}

private struct UserInputAnswer: Encodable {
    var answers: [String]
}

private extension NSLock {
    func withLocking<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension String {
    var singleLineTrimmed: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func shortened(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(max(0, limit - 1))) + "..."
    }
}
