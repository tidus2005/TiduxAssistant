import Foundation
import Network

final class MacRemoteDashboardServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case ready
        case failed(String)
        case cancelled
    }

    private let port: UInt16
    private let router: MacRemoteDashboardRouter
    private let stateHandler: @Sendable (State) -> Void
    private let queue = DispatchQueue(
        label: "com.tidux.codex-watch-pet.web-dashboard",
        qos: .utility
    )
    private let lock = NSLock()
    private var listener: NWListener?
    private var webSocketClients: [UUID: WebSocketClient] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    private var snapshotBroadcastInFlight = false

    private struct WebSocketClient {
        let connection: NWConnection
        var receiveBuffer = Data()
        var isAuthenticated = false
    }

    init(
        port: UInt16,
        token: String,
        snapshotProvider: @escaping @Sendable () async -> MacRemoteDashboardSnapshot,
        actionHandler: @escaping @Sendable (
            MacRemoteDashboardActionRequest
        ) async -> MacRemoteDashboardActionResponse,
        screenLockHandler: @escaping @Sendable (
            MacRemoteDashboardHTTPRequest
        ) async -> MacRemoteDashboardHTTPResponse,
        fileHandler: @escaping @Sendable (
            MacRemoteDashboardHTTPRequest
        ) async -> MacRemoteDashboardHTTPResponse,
        stateHandler: @escaping @Sendable (State) -> Void
    ) {
        self.port = port
        self.router = MacRemoteDashboardRouter(
            token: token,
            snapshotProvider: snapshotProvider,
            actionHandler: actionHandler,
            screenLockHandler: screenLockHandler,
            fileHandler: fileHandler
        )
        self.stateHandler = stateHandler
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw MacRemoteDashboardServerError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: endpointPort
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [stateHandler] state in
            switch state {
            case .ready:
                stateHandler(.ready)
            case .failed(let error):
                stateHandler(.failed(error.localizedDescription))
            case .cancelled:
                stateHandler(.cancelled)
            case .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        startHeartbeat()
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        lock.unlock()
        listener?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
            let clients = self.webSocketClients.values.map(\.connection)
            self.webSocketClients.removeAll()
            clients.forEach { $0.cancel() }
        }
    }

    func broadcastSnapshot() {
        queue.async { [weak self] in
            self?.requestSnapshotBroadcast()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }

            if nextBuffer.count > MacRemoteDashboardHTTPRequest.maximumBytes {
                Self.send(.jsonError("请求内容过大。", status: 413), on: connection)
                return
            }

            switch MacRemoteDashboardHTTPRequest.parse(nextBuffer) {
            case .complete(let request):
                if request.path == MacRemoteDashboardWebSocketCodec.path {
                    self.beginWebSocket(request: request, on: connection)
                } else {
                    Task {
                        let response = await self.router.response(for: request)
                        Self.send(response, on: connection)
                    }
                }
            case .incomplete:
                if isComplete || error != nil {
                    Self.send(.jsonError("HTTP 请求不完整。", status: 400), on: connection)
                } else {
                    self.receive(on: connection, buffer: nextBuffer)
                }
            case .invalid(let message):
                Self.send(.jsonError(message, status: 400), on: connection)
            }
        }
    }

    private func beginWebSocket(
        request: MacRemoteDashboardHTTPRequest,
        on connection: NWConnection
    ) {
        let response: Data
        do {
            response = try MacRemoteDashboardWebSocketCodec.upgradeResponse(for: request)
        } catch {
            Self.send(
                .jsonError("WebSocket 握手无效。", status: 400),
                on: connection
            )
            return
        }

        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }
            let identifier = UUID()
            let isAuthenticated = self.router.isAuthorized(request)
            self.webSocketClients[identifier] = WebSocketClient(
                connection: connection,
                isAuthenticated: isAuthenticated
            )
            self.receiveWebSocket(identifier)
            if isAuthenticated {
                self.sendWebSocketStatus(
                    type: "ready",
                    message: "已通过 MyApps Hub 建立实时连接",
                    to: identifier
                )
                self.requestSnapshotBroadcast()
            }
        })
    }

    private func receiveWebSocket(_ identifier: UUID) {
        guard let client = webSocketClients[identifier] else { return }
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard var current = self.webSocketClients[identifier] else { return }
            if let data { current.receiveBuffer.append(data) }
            if current.receiveBuffer.count > MacRemoteDashboardWebSocketCodec.maximumFrameBytes {
                self.closeWebSocket(identifier, code: 1009, reason: "消息过大")
                return
            }

            var frames: [MacRemoteDashboardWebSocketFrame] = []
            do {
                while let frame = try MacRemoteDashboardWebSocketCodec.decodeClientFrame(
                    from: &current.receiveBuffer
                ) {
                    frames.append(frame)
                }
            } catch {
                self.closeWebSocket(identifier, code: 1002, reason: "协议错误")
                return
            }
            self.webSocketClients[identifier] = current

            for frame in frames where self.webSocketClients[identifier] != nil {
                self.handleWebSocketFrame(frame, from: identifier)
            }
            guard self.webSocketClients[identifier] != nil else { return }
            if isComplete || error != nil {
                self.removeWebSocket(identifier)
            } else {
                self.receiveWebSocket(identifier)
            }
        }
    }

    private func handleWebSocketFrame(
        _ frame: MacRemoteDashboardWebSocketFrame,
        from identifier: UUID
    ) {
        switch frame.opcode {
        case 0x1:
            authenticateWebSocketIfNeeded(identifier, payload: frame.payload)
        case 0x8:
            closeWebSocket(identifier, code: 1000, reason: "")
        case 0x9:
            sendWebSocketFrame(
                MacRemoteDashboardWebSocketCodec.encodeServerFrame(
                    opcode: 0xA,
                    payload: frame.payload
                ),
                to: identifier
            )
        case 0xA:
            break
        default:
            closeWebSocket(identifier, code: 1003, reason: "不支持的消息类型")
        }
    }

    private func authenticateWebSocketIfNeeded(
        _ identifier: UUID,
        payload: Data
    ) {
        guard var client = webSocketClients[identifier] else { return }
        guard !client.isAuthenticated else { return }
        guard let request = try? MacRemoteDashboardJSON.decoder.decode(
            MacRemoteDashboardWebSocketAuthentication.self,
            from: payload
        ),
              request.type == "authenticate",
              router.isAuthorizedToken(request.token) else {
            sendWebSocketStatus(
                type: "error",
                message: "访问令牌无效，请从 Mac 重新复制控制台链接。",
                to: identifier
            )
            closeWebSocket(identifier, code: 1008, reason: "认证失败")
            return
        }

        client.isAuthenticated = true
        webSocketClients[identifier] = client
        sendWebSocketStatus(type: "ready", message: "实时连接已建立", to: identifier)
        requestSnapshotBroadcast()
    }

    private func sendWebSocketStatus(
        type: String,
        message: String,
        to identifier: UUID
    ) {
        let envelope = MacRemoteDashboardWebSocketStatusEnvelope(
            type: type,
            message: message
        )
        guard let payload = try? MacRemoteDashboardJSON.encoder.encode(envelope) else {
            return
        }
        sendWebSocketFrame(
            MacRemoteDashboardWebSocketCodec.encodeServerFrame(
                opcode: 0x1,
                payload: payload
            ),
            to: identifier
        )
    }

    private func sendWebSocketFrame(_ frame: Data, to identifier: UUID) {
        guard let client = webSocketClients[identifier] else { return }
        client.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.removeWebSocket(identifier)
            }
        })
    }

    private func closeWebSocket(_ identifier: UUID, code: UInt16, reason: String) {
        guard let client = webSocketClients.removeValue(forKey: identifier) else {
            return
        }
        let frame = MacRemoteDashboardWebSocketCodec.encodeCloseFrame(
            code: code,
            reason: reason
        )
        client.connection.send(content: frame, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    private func removeWebSocket(_ identifier: UUID) {
        let client = webSocketClients.removeValue(forKey: identifier)
        client?.connection.cancel()
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let ping = MacRemoteDashboardWebSocketCodec.encodeServerFrame(
                opcode: 0x9,
                payload: Data("cwp".utf8)
            )
            for identifier in self.webSocketClients.keys {
                self.sendWebSocketFrame(ping, to: identifier)
            }
            self.requestSnapshotBroadcast()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func requestSnapshotBroadcast() {
        guard !snapshotBroadcastInFlight,
              webSocketClients.values.contains(where: \.isAuthenticated) else {
            return
        }
        snapshotBroadcastInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.router.snapshotProvider()
            let envelope = MacRemoteDashboardWebSocketSnapshotEnvelope(snapshot: snapshot)
            let payload = try? MacRemoteDashboardJSON.encoder.encode(envelope)
            self.queue.async { [weak self] in
                guard let self else { return }
                self.snapshotBroadcastInFlight = false
                guard let payload else { return }
                let frame = MacRemoteDashboardWebSocketCodec.encodeServerFrame(
                    opcode: 0x1,
                    payload: payload
                )
                for (identifier, client) in self.webSocketClients where client.isAuthenticated {
                    self.sendWebSocketFrame(frame, to: identifier)
                }
            }
        }
    }

    private static func send(
        _ response: MacRemoteDashboardHTTPResponse,
        on connection: NWConnection
    ) {
        guard let fileURL = response.fileURL else {
            connection.send(content: response.data, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            send(.jsonError("下载文件当前不可读。", status: 500), on: connection)
            return
        }
        connection.send(content: response.headerData, completion: .contentProcessed { error in
            guard error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            sendFile(
                handle: handle,
                remainingBytes: response.contentLength,
                on: connection
            )
        })
    }

    private static func sendFile(
        handle: FileHandle,
        remainingBytes: UInt64,
        on connection: NWConnection
    ) {
        guard remainingBytes > 0 else {
            try? handle.close()
            connection.cancel()
            return
        }

        let maximumBytes = Int(min(remainingBytes, 256 * 1_024))
        guard let chunk = try? handle.read(upToCount: maximumBytes),
              !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { error in
            guard error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            sendFile(
                handle: handle,
                remainingBytes: remainingBytes - UInt64(chunk.count),
                on: connection
            )
        })
    }
}

enum MacRemoteDashboardServerError: LocalizedError, Equatable, Sendable {
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "无效的手机 Web 控制台端口：\(port)。"
        }
    }
}

struct MacRemoteDashboardRouter: Sendable {
    let token: String
    let snapshotProvider: @Sendable () async -> MacRemoteDashboardSnapshot
    let actionHandler: @Sendable (
        MacRemoteDashboardActionRequest
    ) async -> MacRemoteDashboardActionResponse
    let screenLockHandler: @Sendable (
        MacRemoteDashboardHTTPRequest
    ) async -> MacRemoteDashboardHTTPResponse
    let fileHandler: @Sendable (
        MacRemoteDashboardHTTPRequest
    ) async -> MacRemoteDashboardHTTPResponse

    init(
        token: String,
        snapshotProvider: @escaping @Sendable () async -> MacRemoteDashboardSnapshot,
        actionHandler: @escaping @Sendable (
            MacRemoteDashboardActionRequest
        ) async -> MacRemoteDashboardActionResponse,
        screenLockHandler: @escaping @Sendable (
            MacRemoteDashboardHTTPRequest
        ) async -> MacRemoteDashboardHTTPResponse = { _ in
            .jsonError("自动锁屏服务尚未连接。", status: 503)
        },
        fileHandler: @escaping @Sendable (
            MacRemoteDashboardHTTPRequest
        ) async -> MacRemoteDashboardHTTPResponse = { _ in
            .jsonError("文件同步服务尚未连接。", status: 503)
        }
    ) {
        self.token = token
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.screenLockHandler = screenLockHandler
        self.fileHandler = fileHandler
    }

    func response(
        for request: MacRemoteDashboardHTTPRequest
    ) async -> MacRemoteDashboardHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(
                MacRemoteDashboardPage.html,
                allowsSameOriginFraming:
                    request.queryItems["embeddedDebugViewport"] == "440x860"
            )

        case ("GET", "/health"), ("GET", "/api/health"):
            return .jsonObject(["status": "ok", "service": "codex-watch-pet-web"])

        case ("GET", "/api/status"):
            guard isAuthorized(request) else {
                return .jsonError("访问令牌无效，请从 Mac 重新复制控制台链接。", status: 401)
            }
            return .jsonEncodable(await snapshotProvider())

        case ("POST", "/api/action"):
            guard isAuthorized(request) else {
                return .jsonError("访问令牌无效，请从 Mac 重新复制控制台链接。", status: 401)
            }
            do {
                let action = try MacRemoteDashboardJSON.decoder.decode(
                    MacRemoteDashboardActionRequest.self,
                    from: request.body
                )
                let result = await actionHandler(action)
                return .jsonEncodable(result, status: result.ok ? 200 : 409)
            } catch {
                return .jsonError("控制请求格式无效。", status: 400)
            }

        case ("GET", "/api/screen-lock"), ("POST", "/api/screen-lock"):
            guard isAuthorized(request) else {
                return .jsonError("访问令牌无效，请从 Mac 重新复制控制台链接。", status: 401)
            }
            return await screenLockHandler(request)

        case (_, let path) where path == "/api/files" || path.hasPrefix("/api/files/"):
            guard isAuthorized(request) else {
                return .jsonError("访问令牌无效，请从 Mac 重新复制控制台链接。", status: 401)
            }
            return await fileHandler(request)

        default:
            return .jsonError("没有对应的控制台路径。", status: 404)
        }
    }

    func isAuthorized(_ request: MacRemoteDashboardHTTPRequest) -> Bool {
        guard let supplied = request.bearerToken else { return false }
        return isAuthorizedToken(supplied)
    }

    func isAuthorizedToken(_ supplied: String) -> Bool {
        Self.constantTimeEqual(supplied, token)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<count {
            difference |= Int(index < left.count ? left[index] : 0)
                ^ Int(index < right.count ? right[index] : 0)
        }
        return difference == 0
    }
}

struct MacRemoteDashboardHTTPRequest: Equatable, Sendable {
    static let maximumBytes = 1_280 * 1024

    enum ParseResult: Equatable, Sendable {
        case complete(MacRemoteDashboardHTTPRequest)
        case incomplete
        case invalid(String)
    }

    var method: String
    var path: String
    var queryItems: [String: String] = [:]
    var headers: [String: String]
    var body: Data

    var bearerToken: String? {
        guard let authorization = headers["authorization"] else { return nil }
        let components = authorization.split(separator: " ", maxSplits: 1)
        guard components.count == 2,
              components[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        return String(components[1])
    }

    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return .incomplete }
        guard let header = String(
            data: data[..<headerRange.lowerBound],
            encoding: .utf8
        ) else {
            return .invalid("HTTP 请求头不是有效的 UTF-8。")
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid("缺少 HTTP 请求行。")
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3 else {
            return .invalid("HTTP 请求行格式无效。")
        }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "POST" else {
            return .invalid("不支持该 HTTP 方法。")
        }
        let target = String(parts[1])
        guard let components = URLComponents(string: target),
              !components.path.isEmpty else {
            return .invalid("HTTP 请求路径无效。")
        }
        let path = components.path
        let queryItems = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let headers = Dictionary(
            lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let key = line[..<colon]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                return (key, value)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        guard let contentLength = Int(headers["content-length"] ?? "0"),
              contentLength >= 0,
              contentLength <= maximumBytes else {
            return .invalid("Content-Length 无效。")
        }
        let bodyStart = headerRange.upperBound
        guard data.count - bodyStart >= contentLength else { return .incomplete }
        let body = contentLength == 0
            ? Data()
            : data[bodyStart..<(bodyStart + contentLength)]
        return .complete(
            MacRemoteDashboardHTTPRequest(
                method: method,
                path: path,
                queryItems: queryItems,
                headers: headers,
                body: Data(body)
            )
        )
    }
}

struct MacRemoteDashboardHTTPResponse: Equatable, Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [String: String] = [:]
    var fileURL: URL? = nil
    var fileByteCount: UInt64? = nil
    var allowsSameOriginFraming = false

    var data: Data {
        headerData + body
    }

    var contentLength: UInt64 {
        fileByteCount ?? UInt64(body.count)
    }

    var headerData: Data {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(contentLength)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Pragma: no-cache\r\n"
        header += "Referrer-Policy: no-referrer\r\n"
        header += "X-Content-Type-Options: nosniff\r\n"
        header += allowsSameOriginFraming
            ? "X-Frame-Options: SAMEORIGIN\r\n"
            : "X-Frame-Options: DENY\r\n"
        let frameAncestors = allowsSameOriginFraming ? "'self'" : "'none'"
        header += "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors \(frameAncestors); base-uri 'none'; form-action 'none'\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8)
    }

    private var reason: String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        default: "Error"
        }
    }

    static func html(
        _ html: String,
        allowsSameOriginFraming: Bool = false
    ) -> Self {
        Self(
            status: 200,
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8),
            allowsSameOriginFraming: allowsSameOriginFraming
        )
    }

    static func jsonObject(_ value: [String: String], status: Int = 200) -> Self {
        let data = (try? MacRemoteDashboardJSON.encoder.encode(value))
            ?? Data("{\"error\":\"encoding\"}".utf8)
        return Self(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func jsonEncodable<T: Encodable>(_ value: T, status: Int = 200) -> Self {
        do {
            return Self(
                status: status,
                contentType: "application/json; charset=utf-8",
                body: try MacRemoteDashboardJSON.encoder.encode(value)
            )
        } catch {
            return jsonError("无法编码控制台状态。", status: 500)
        }
    }

    static func jsonError(_ message: String, status: Int) -> Self {
        jsonObject(["error": message], status: status)
    }

    static func binary(
        _ data: Data,
        contentType: String,
        extraHeaders: [String: String] = [:]
    ) -> Self {
        Self(
            status: 200,
            contentType: contentType,
            body: data,
            extraHeaders: extraHeaders
        )
    }

    static func file(
        _ fileURL: URL,
        byteCount: UInt64,
        contentType: String,
        downloadName: String
    ) -> Self {
        let fallbackName = downloadName.unicodeScalars.map { scalar -> Character in
            guard scalar.isASCII,
                  scalar.value >= 0x20,
                  scalar.value != 0x22,
                  scalar.value != 0x5C else {
                return "_"
            }
            return Character(String(scalar))
        }
        let quotedName = String(fallbackName).isEmpty ? "download" : String(fallbackName)
        let encodedName = downloadName.utf8.map { byte -> String in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                return String(UnicodeScalar(byte))
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
        return Self(
            status: 200,
            contentType: contentType,
            body: Data(),
            extraHeaders: [
                "Content-Disposition": "attachment; filename=\"\(quotedName)\"; filename*=UTF-8''\(encodedName)"
            ],
            fileURL: fileURL,
            fileByteCount: byteCount
        )
    }
}

enum MacRemoteDashboardJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
