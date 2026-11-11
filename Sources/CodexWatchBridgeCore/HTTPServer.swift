import CodexWatchCore
import Foundation
import Network

public struct HTTPServerConfiguration: Sendable {
    public var host: String
    public var port: UInt16
    public var allowNetworkPairing: Bool

    public init(host: String = "127.0.0.1", port: UInt16 = 8765, allowNetworkPairing: Bool = false) {
        self.host = host
        self.port = port
        self.allowNetworkPairing = allowNetworkPairing
    }
}

public final class BridgeHTTPServer: @unchecked Sendable {
    private let configuration: HTTPServerConfiguration
    private let runtime: BridgeRuntime
    private var listener: NWListener?

    public init(configuration: HTTPServerConfiguration, runtime: BridgeRuntime) {
        self.configuration = configuration
        self.runtime = runtime
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        let port = NWEndpoint.Port(rawValue: configuration.port)!
        let listener: NWListener
        if configuration.host == "0.0.0.0" || configuration.host == "::" {
            listener = try NWListener(using: parameters, on: port)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.host), port: port)
            listener = try NWListener(using: parameters)
        }
        self.listener = listener
        listener.newConnectionHandler = { [configuration, runtime] connection in
            let client = HTTPClient(endpoint: connection.endpoint)
            connection.start(queue: .global())
            Self.receive(connection: connection) { request in
                let response = Self.handle(request: request, client: client, configuration: configuration, runtime: runtime)
                Self.send(response: response, on: connection)
            }
        }
        listener.start(queue: .global())
    }

    public func runForever() {
        dispatchMain()
    }

    private static func receive(
        connection: NWConnection,
        buffer: Data = Data(),
        completion: @escaping @Sendable (HTTPRequest) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = HTTPRequest(data: nextBuffer) {
                completion(request)
                return
            }

            if nextBuffer.count > 512 * 1024 {
                send(response: .badRequest("HTTP request is too large."), on: connection)
                return
            }

            receive(connection: connection, buffer: nextBuffer, completion: completion)
        }
    }

    private static func handle(
        request: HTTPRequest,
        client: HTTPClient,
        configuration: HTTPServerConfiguration,
        runtime: BridgeRuntime
    ) -> HTTPResponse {
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                let record = try runtime.ensurePairing()
                return try .json([
                    "status": "ok",
                    "tokenPreview": String(record.token.prefix(8)) + "..."
                ])
            case ("GET", "/pairing"):
                guard client.isLocal || configuration.allowNetworkPairing else {
                    return .error("Pairing is only available from the Mac. Copy the printed token and shared secret into the iPhone app.", status: 403)
                }
                let record = try runtime.ensurePairing()
                return try .json(record)
            case ("GET", let path) where path.hasPrefix("/receipts/"):
                try runtime.validateReadAccess(bearerToken: request.bearerToken, isLocalClient: client.isLocal)
                return try .json(runtime.commandReceipt(id: String(path.dropFirst("/receipts/".count))))
            case ("GET", "/snapshot"):
                try runtime.validateReadAccess(bearerToken: request.bearerToken, isLocalClient: client.isLocal)
                return try .json(runtime.snapshot())
            case ("GET", "/events"):
                try runtime.validateReadAccess(bearerToken: request.bearerToken, isLocalClient: client.isLocal)
                let since = request.query["since"].flatMap(Int64.init)
                return try .json(runtime.events(since: since))
            case ("POST", "/commands"):
                let command = try JSONDecoder.codexWatchPet.decode(BridgeCommand.self, from: request.body)
                let result = try runtime.submit(
                    command: command,
                    bearerToken: request.bearerToken,
                    signature: request.headers["x-cwp-signature"]
                )
                return try .json(result)
            case ("POST", "/notify"):
                guard client.isLocal else {
                    return .error("Codex notify ingestion only accepts local Mac requests.", status: 403)
                }
                let payload = try JSONDecoder.codexWatchPet.decode(CodexNotificationPayload.self, from: request.body)
                let event = try runtime.ingest(notification: payload)
                return try .json(event)
            default:
                return .notFound("No route for \(request.method) \(request.path)")
            }
        } catch let error as BridgeError {
            switch error {
            case .unauthorized:
                return .error(error.localizedDescription, status: 401)
            default:
                return .error(error.localizedDescription, status: 400)
            }
        } catch let error as CommandSecurityError {
            return .error("Command security check failed: \(error)", status: 401)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    private static func send(response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    var bearerToken: String? {
        guard let authorization = headers["authorization"] else { return nil }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return nil }
        return String(authorization.dropFirst(prefix.count))
    }

    init?(data: Data) {
        let separatorData = Data("\r\n\r\n".utf8)
        guard let separator = data.range(of: separatorData),
              let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        self.method = String(parts[0])

        let pathAndQuery = String(parts[1])
        let split = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        self.path = String(split[0])
        self.query = split.count == 2 ? Self.parseQuery(String(split[1])) : [:]
        self.headers = Dictionary(
            uniqueKeysWithValues: lines.dropFirst().compactMap { line in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return (key, value)
            }
        )
        let bodyStart = separator.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count - bodyStart >= contentLength else {
            return nil
        }
        self.body = contentLength > 0
            ? data[bodyStart..<(bodyStart + contentLength)]
            : Data()
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: query.split(separator: "&").map { item in
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pair[0]).removingPercentEncoding ?? String(pair[0])
            let value = pair.count == 2 ? (String(pair[1]).removingPercentEncoding ?? String(pair[1])) : ""
            return (key, value)
        })
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    var data: Data {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    var reason: String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        default: "Error"
        }
    }

    static func json<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json", body: try JSONEncoder.codexWatchPet.encode(value))
    }

    static func badRequest(_ message: String) -> HTTPResponse {
        error(message, status: 400)
    }

    static func notFound(_ message: String) -> HTTPResponse {
        error(message, status: 404)
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        let payload = ["error": message]
        let data = (try? JSONEncoder.codexWatchPet.encode(payload)) ?? Data("{\"error\":\"unknown\"}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }
}

public struct HTTPClient: Sendable {
    public var endpointDescription: String
    public var isLocal: Bool

    public init(endpoint: NWEndpoint) {
        self.endpointDescription = "\(endpoint)"
        self.isLocal = Self.isLocal(endpoint)
    }

    public static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .name(let name, _):
                return name == "localhost"
            case .ipv4(let address):
                let value = "\(address)"
                return value == "127.0.0.1" || value.hasPrefix("127.")
            case .ipv6(let address):
                return "\(address)" == "::1"
            @unknown default:
                return false
            }
        default:
            return false
        }
    }
}
