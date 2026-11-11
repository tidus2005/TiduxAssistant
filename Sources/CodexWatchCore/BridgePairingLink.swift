import Foundation

public struct BridgePairingLink: Codable, Hashable, Sendable {
    public var bridgeURL: URL
    public var token: String
    public var sharedSecret: String

    public init(bridgeURL: URL, token: String, sharedSecret: String) {
        self.bridgeURL = bridgeURL
        self.token = token
        self.sharedSecret = sharedSecret
    }

    public init(link: String) throws {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BridgePairingLinkError.invalidURL
        }
        guard components.scheme == "codexwatchpet", components.host == "pair" else {
            throw BridgePairingLinkError.invalidScheme
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard let bridge = items["bridge"], let bridgeURL = URL(string: bridge), bridgeURL.scheme?.hasPrefix("http") == true else {
            throw BridgePairingLinkError.missingBridgeURL
        }
        guard let token = items["token"], !token.isEmpty else {
            throw BridgePairingLinkError.missingToken
        }
        guard let secret = items["secret"], Data(base64Encoded: secret) != nil else {
            throw BridgePairingLinkError.invalidSecret
        }

        self.bridgeURL = bridgeURL
        self.token = token
        self.sharedSecret = secret
    }

    public var link: String {
        var components = URLComponents()
        components.scheme = "codexwatchpet"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "bridge", value: bridgeURL.absoluteString),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "secret", value: sharedSecret)
        ]
        return components.url?.absoluteString ?? ""
    }
}

public enum BridgePairingLinkError: Error, LocalizedError, Equatable {
    case invalidURL
    case invalidScheme
    case missingBridgeURL
    case missingToken
    case invalidSecret

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Pairing link is not a valid URL."
        case .invalidScheme:
            "Pairing link must start with codexwatchpet://pair."
        case .missingBridgeURL:
            "Pairing link is missing a bridge URL."
        case .missingToken:
            "Pairing link is missing a token."
        case .invalidSecret:
            "Pairing link has an invalid shared secret."
        }
    }
}
