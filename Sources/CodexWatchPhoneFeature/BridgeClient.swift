import CodexWatchCore
import Foundation

public struct BridgeClientConfiguration: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var sharedSecret: Data?

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!, bearerToken: String = "", sharedSecret: Data? = nil) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.sharedSecret = sharedSecret
    }
}

@MainActor
public final class BridgeClient: Sendable, BridgeTransporting {
    private let httpClient: BridgeHTTPClient
    public let route: BridgeTransportRoute
    public var isAvailable: Bool { true }
    public private(set) var serverIdentity: String?
    public private(set) var supportsCommandDeduplication = false

    public init(configuration: BridgeClientConfiguration, urlSession: URLSession = .shared, route: BridgeTransportRoute = .localNetwork) {
        self.route = route
        self.httpClient = BridgeHTTPClient(
            configuration: BridgeConnectionConfiguration(
                baseURL: configuration.baseURL,
                bearerToken: configuration.bearerToken,
                sharedSecretBase64: configuration.sharedSecret?.base64EncodedString() ?? ""
            ),
            urlSession: urlSession
        )
    }

    public func fetchSnapshot() async throws -> BridgeState {
        let state = try await httpClient.fetchSnapshot()
        serverIdentity = state.bridgeIdentity
        supportsCommandDeduplication = state.commandReceiptsSupported
        return state
    }

    public func send(command: BridgeCommand) async throws -> CommandResult {
        try await httpClient.send(command: command)
    }

    public func fetchReceipt(commandID: String) async throws -> CommandResult? {
        try await httpClient.fetchReceipt(commandID: commandID)
    }
}

public enum BridgeClientError: Error, LocalizedError, Equatable {
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            "Bridge request failed with HTTP \(status): \(message)"
        }
    }
}
