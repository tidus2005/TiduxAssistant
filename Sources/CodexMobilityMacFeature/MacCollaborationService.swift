import CodexMobilityCore
import CodexWatchCore
import Foundation

/// Only forwards to this Mac's loopback bridge. Phones cannot choose an arbitrary proxy destination.
public final class MacCollaborationService: Sendable {
    private struct Pairing: Decodable { let token: String; let sharedSecret: String }
    private let baseURL: URL
    private let pairingURL: URL
    private let session: URLSession

    public init(
        baseURL: URL? = nil,
        pairingURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-watch-pet/pairing.json"),
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL ?? Self.configuredBaseURL(pairingURL.deletingLastPathComponent()); self.pairingURL = pairingURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        self.session = session ?? URLSession(configuration: configuration)
    }

    private static func configuredBaseURL(_ directory: URL) -> URL {
        if let text = try? String(contentsOf: directory.appendingPathComponent("bridge.env"), encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("export CWP_BRIDGE_URL=") }),
           let raw = line.split(separator: "=", maxSplits: 1).last,
           let url = URL(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))),
           url.scheme == "http", url.host == "127.0.0.1" { return url }
        return URL(string: "http://127.0.0.1:8766")!
    }

    public func handle(_ message: CollaborationRequest) async -> CollaborationResponse {
        do {
            guard baseURL.host == "127.0.0.1", (message.body?.count ?? 0) <= 64 * 1_024 else {
                throw CollaborationTransportError.invalidResponse
            }
            let pairing = try JSONDecoder().decode(Pairing.self, from: Data(contentsOf: pairingURL))
            var request: URLRequest
            switch message.method {
            case .companion:
                throw CollaborationTransportError.invalidResponse
            case .snapshot:
                request = URLRequest(url: baseURL.appending(path: "snapshot"))
            case .receipt:
                guard let id = message.commandID, !id.isEmpty, id.count <= 128 else {
                    throw CollaborationTransportError.invalidResponse
                }
                request = URLRequest(url: baseURL.appending(path: "receipts").appending(component: id))
            case .command:
                guard let body = message.body,
                      let secret = Data(base64Encoded: pairing.sharedSecret) else {
                    throw CollaborationTransportError.invalidResponse
                }
                let command = try JSONDecoder.codexWatchPet.decode(BridgeCommand.self, from: body)
                request = URLRequest(url: baseURL.appending(path: "commands"))
                request.httpMethod = "POST"
                request.httpBody = try JSONEncoder.codexWatchPet.encode(command)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(try CommandSigner().sign(command, secret: secret), forHTTPHeaderField: "X-CWP-Signature")
            }
            request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
            let (rawData, response) = try await session.data(for: request)
            var data = rawData
            if message.method == .snapshot, let state = try? JSONDecoder.codexWatchPet.decode(BridgeState.self, from: data) {
                data = try JSONEncoder.codexWatchPetLine.encode(state)
            }
            guard data.count <= 256 * 1_024 else { throw CollaborationTransportError.rejected("快照过大，请使用局域网通道刷新。") }
            return CollaborationResponse(requestID: message.id, status: (response as? HTTPURLResponse)?.statusCode ?? 502, body: data).compressedIfUseful()
        } catch {
            return CollaborationResponse(requestID: message.id, status: 503,
                body: Data("Mac Codex Bridge 暂不可达：\(error.localizedDescription)".utf8))
        }
    }
}
