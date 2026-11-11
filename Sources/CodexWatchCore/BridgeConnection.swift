import Foundation

public enum BridgeConnectionKeys {
    public static let bridgeURL = "bridgeURL"
    public static let bridgeToken = "bridgeToken"
    public static let bridgeSecret = "bridgeSecret"
    public static let remoteBridgeURL = "remoteBridgeURL"
}

public struct BridgeConnectionConfiguration: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var sharedSecretBase64: String

    public init(baseURL: URL, bearerToken: String, sharedSecretBase64: String) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.sharedSecretBase64 = sharedSecretBase64
    }

    public var sharedSecret: Data? {
        Data(base64Encoded: sharedSecretBase64)
    }
}

public struct BridgeConnectionStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> BridgeConnectionConfiguration? {
        guard let urlString = defaults.string(forKey: BridgeConnectionKeys.bridgeURL),
              let url = URL(string: urlString),
              !urlString.isEmpty,
              let token = defaults.string(forKey: BridgeConnectionKeys.bridgeToken),
              !token.isEmpty else {
            return nil
        }
        let secret = defaults.string(forKey: BridgeConnectionKeys.bridgeSecret) ?? ""
        return BridgeConnectionConfiguration(baseURL: url, bearerToken: token, sharedSecretBase64: secret)
    }

    public func save(_ configuration: BridgeConnectionConfiguration) {
        defaults.set(configuration.baseURL.absoluteString, forKey: BridgeConnectionKeys.bridgeURL)
        defaults.set(configuration.bearerToken, forKey: BridgeConnectionKeys.bridgeToken)
        defaults.set(configuration.sharedSecretBase64, forKey: BridgeConnectionKeys.bridgeSecret)
        defaults.synchronize()
    }

    public func clear() {
        defaults.removeObject(forKey: BridgeConnectionKeys.bridgeURL)
        defaults.removeObject(forKey: BridgeConnectionKeys.bridgeToken)
        defaults.removeObject(forKey: BridgeConnectionKeys.bridgeSecret)
        defaults.synchronize()
    }
}

public final class BridgeHTTPClient: Sendable {
    private let configuration: BridgeConnectionConfiguration
    private let urlSession: URLSession
    private let signer = CommandSigner()

    public init(configuration: BridgeConnectionConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    public func fetchSnapshot() async throws -> BridgeState {
        var request = URLRequest(url: configuration.baseURL.appending(path: "snapshot"))
        request.timeoutInterval = 5
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder.codexWatchPet.decode(BridgeState.self, from: data)
    }

    public func send(command: BridgeCommand) async throws -> CommandResult {
        var request = URLRequest(url: configuration.baseURL.appending(path: "commands"))
        request.timeoutInterval = 8
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.codexWatchPet.encode(command)
        if let sharedSecret = configuration.sharedSecret {
            request.setValue(try signer.sign(command, secret: sharedSecret), forHTTPHeaderField: "X-CWP-Signature")
        }
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder.codexWatchPet.decode(CommandResult.self, from: data)
    }

    public func fetchReceipt(commandID: String) async throws -> CommandResult? {
        var request = URLRequest(url: configuration.baseURL.appending(path: "receipts").appending(component: commandID))
        request.timeoutInterval = 5
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder.codexWatchPet.decode(CommandResult?.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw BridgeHTTPClientError.http(status: http.statusCode, message: message)
        }
    }
}

public enum BridgeHTTPClientError: Error, LocalizedError, Equatable {
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            "Bridge request failed with HTTP \(status): \(message)"
        }
    }
}
