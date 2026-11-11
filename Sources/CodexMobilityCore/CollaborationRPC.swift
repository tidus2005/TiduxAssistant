import Foundation
import Compression

/// Small, authenticated control messages. File contents retain the resumable file protocol.
public struct CollaborationRequest: Codable, Equatable, Hashable, Sendable {
    public enum Method: String, Codable, Sendable { case snapshot, command, receipt, companion }
    public var id: UUID
    public var method: Method
    public var body: Data?
    public var commandID: String?

    public init(id: UUID = UUID(), method: Method, body: Data? = nil, commandID: String? = nil) {
        self.id = id; self.method = method; self.body = body; self.commandID = commandID
    }
}

public struct CollaborationResponse: Codable, Equatable, Hashable, Sendable {
    public var requestID: UUID
    public var status: Int
    public var body: Data
    public var compression: String?

    public init(requestID: UUID, status: Int, body: Data = Data(), compression: String? = nil) {
        self.requestID = requestID; self.status = status; self.body = body; self.compression = compression
    }

    public func compressedIfUseful() -> Self {
        guard compression == nil, body.count > 4 * 1_024, body.count <= 256 * 1_024 else { return self }
        var output = Data(count: body.count + 64)
        let capacity = output.count
        let count = output.withUnsafeMutableBytes { destination in
            body.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0, count < body.count else { return self }
        return Self(requestID: requestID, status: status, body: output.prefix(count), compression: "lzfse")
    }

    public func decodedBody() throws -> Data {
        let limit = 256 * 1_024
        guard body.count <= limit else { throw CollaborationTransportError.invalidResponse }
        guard let compression else { return body }
        guard compression == "lzfse", !body.isEmpty else { throw CollaborationTransportError.invalidResponse }
        var output = Data(count: limit + 1)
        let count = output.withUnsafeMutableBytes { destination in
            body.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, limit + 1,
                    source.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0, count <= limit else { throw CollaborationTransportError.invalidResponse }
        return output.prefix(count)
    }
}

public enum CollaborationTransportError: Error, LocalizedError, Sendable {
    case unavailable
    case timedOut
    case disconnected
    case invalidResponse
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "通道暂不可用。"
        case .timedOut: "等待 Mac 回执超时；操作可能已经送达。"
        case .disconnected: "连接已断开；操作结果需核实。"
        case .invalidResponse: "Mac 返回了无法识别的回执。"
        case .rejected(let reason): reason
        }
    }
}
