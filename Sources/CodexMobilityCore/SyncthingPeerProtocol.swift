import Foundation

public enum SyncthingPeerProtocolLimits {
    /// Version 2 binds the application hello to both peer identities with an HMAC proof.
    public static let currentVersion: UInt16 = 2
    public static let frameHeaderSize = 4
    /// A 16 MiB block expands to about 21.4 MiB in JSON base64, so keep enough
    /// headroom for its authenticated metadata while still bounding allocations.
    public static let maximumMessageSize = 24 * 1_024 * 1_024
}

public struct SyncthingPeerHello: Codable, Equatable, Sendable {
    /// A source-compatible sentinel for model construction only. Authentication rejects it.
    public static let unboundPeerDeviceID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))

    public var messageID: UUID
    public var protocolVersion: UInt16
    public var deviceID: UUID
    public var intendedPeerDeviceID: UUID
    public var nonce: UUID
    public var deviceName: String
    public var folderIDs: [String]
    public var authenticationProof: String?

    public init(
        messageID: UUID = UUID(),
        protocolVersion: UInt16 = SyncthingPeerProtocolLimits.currentVersion,
        deviceID: UUID,
        intendedPeerDeviceID: UUID = Self.unboundPeerDeviceID,
        nonce: UUID = UUID(),
        deviceName: String,
        folderIDs: [String] = [],
        authenticationProof: String? = nil
    ) {
        self.messageID = messageID
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.intendedPeerDeviceID = intendedPeerDeviceID
        self.nonce = nonce
        self.deviceName = deviceName
        self.folderIDs = folderIDs
        self.authenticationProof = authenticationProof
    }
}

public struct SyncthingPeerIndex: Codable, Equatable, Sendable {
    public var messageID: UUID
    public var folderID: String
    public var sequence: UInt64
    public var entries: [SyncthingFileIndex]

    public init(
        messageID: UUID = UUID(),
        folderID: String,
        sequence: UInt64,
        entries: [SyncthingFileIndex]
    ) {
        self.messageID = messageID
        self.folderID = folderID
        self.sequence = sequence
        self.entries = entries
    }
}

public struct SyncthingPeerIndexUpdate: Codable, Equatable, Sendable {
    public var messageID: UUID
    public var folderID: String
    public var sequence: UInt64
    public var entries: [SyncthingFileIndex]

    public init(
        messageID: UUID = UUID(),
        folderID: String,
        sequence: UInt64,
        entries: [SyncthingFileIndex]
    ) {
        self.messageID = messageID
        self.folderID = folderID
        self.sequence = sequence
        self.entries = entries
    }
}

public struct SyncthingPeerBlockRequest: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var folderID: String
    public var relativePath: String
    public var block: SyncthingBlockRequest

    public init(
        requestID: UUID = UUID(),
        folderID: String,
        relativePath: String,
        block: SyncthingBlockRequest
    ) {
        self.requestID = requestID
        self.folderID = folderID
        self.relativePath = relativePath
        self.block = block
    }

    public var offset: UInt64 { block.offset }
    public var length: Int { block.size }
    public var expectedSHA256: String { block.sha256 }
}

public struct SyncthingPeerBlockResponse: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var folderID: String
    public var relativePath: String
    public var block: SyncthingBlockRequest
    public var data: Data

    public init(
        requestID: UUID,
        folderID: String,
        relativePath: String,
        block: SyncthingBlockRequest,
        data: Data
    ) {
        self.requestID = requestID
        self.folderID = folderID
        self.relativePath = relativePath
        self.block = block
        self.data = data
    }

    public var offset: UInt64 { block.offset }
    public var sha256: String { block.sha256 }
}

public enum SyncthingPeerAcknowledgementStatus: String, Codable, CaseIterable, Sendable {
    case accepted
    case rejected
}

public struct SyncthingPeerAcknowledgement: Codable, Equatable, Sendable {
    public var acknowledgedMessageID: UUID
    public var status: SyncthingPeerAcknowledgementStatus
    public var detail: String?

    public init(
        acknowledgedMessageID: UUID,
        status: SyncthingPeerAcknowledgementStatus = .accepted,
        detail: String? = nil
    ) {
        self.acknowledgedMessageID = acknowledgedMessageID
        self.status = status
        self.detail = detail
    }
}

public enum SyncthingPeerCloseCode: String, Codable, CaseIterable, Sendable {
    case normal
    case protocolError
    case unauthorized
    case shuttingDown
}

public struct SyncthingPeerClose: Codable, Equatable, Sendable {
    public var code: SyncthingPeerCloseCode
    public var reason: String?

    public init(code: SyncthingPeerCloseCode = .normal, reason: String? = nil) {
        self.code = code
        self.reason = reason
    }
}

public enum SyncthingPeerMessage: Codable, Equatable, Sendable {
    case hello(SyncthingPeerHello)
    case index(SyncthingPeerIndex)
    case indexUpdate(SyncthingPeerIndexUpdate)
    case blockRequest(SyncthingPeerBlockRequest)
    case blockResponse(SyncthingPeerBlockResponse)
    case ack(SyncthingPeerAcknowledgement)
    case close(SyncthingPeerClose)
    /// Carries the existing resumable, checksummed transfer state machine over TLS.
    case transfer(SyncWireMessage)
}

public struct SyncthingPeerJSONCodec: Sendable {
    public init() {}

    public func encode(_ message: SyncthingPeerMessage) throws -> Data {
        try Self.makeEncoder().encode(message)
    }

    public func decode(_ data: Data) throws -> SyncthingPeerMessage {
        try Self.makeDecoder().decode(SyncthingPeerMessage.self, from: data)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public enum SyncthingPeerFramingError: Error, Equatable, Sendable {
    case invalidFrameLength(Int)
    case messageTooLarge(actual: Int, maximum: Int)
    case truncatedFrame(bufferedBytes: Int)
}

/// Encodes one JSON message as a four-byte big-endian length followed by its payload.
public struct SyncthingPeerFrameCodec: Sendable {
    public init() {}

    public func encode(_ message: SyncthingPeerMessage) throws -> Data {
        try encode(payload: SyncthingPeerJSONCodec().encode(message))
    }

    public func encode(payload: Data) throws -> Data {
        guard !payload.isEmpty else {
            throw SyncthingPeerFramingError.invalidFrameLength(0)
        }
        guard payload.count <= SyncthingPeerProtocolLimits.maximumMessageSize else {
            throw SyncthingPeerFramingError.messageTooLarge(
                actual: payload.count,
                maximum: SyncthingPeerProtocolLimits.maximumMessageSize
            )
        }

        let count = UInt32(payload.count)
        var frame = Data(capacity: SyncthingPeerProtocolLimits.frameHeaderSize + payload.count)
        frame.append(UInt8(truncatingIfNeeded: count >> 24))
        frame.append(UInt8(truncatingIfNeeded: count >> 16))
        frame.append(UInt8(truncatingIfNeeded: count >> 8))
        frame.append(UInt8(truncatingIfNeeded: count))
        frame.append(payload)
        return frame
    }
}

/// Incrementally extracts length-delimited payloads from arbitrary TCP receive chunks.
public struct SyncthingPeerIncrementalFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }
    public var hasIncompleteFrame: Bool { !buffer.isEmpty }

    public mutating func append(_ data: Data) throws -> [Data] {
        if !data.isEmpty {
            buffer.append(data)
        }

        var payloads: [Data] = []
        var cursor = 0
        let headerSize = SyncthingPeerProtocolLimits.frameHeaderSize

        while buffer.count - cursor >= headerSize {
            let start = buffer.index(buffer.startIndex, offsetBy: cursor)
            let byte0 = UInt32(buffer[start]) << 24
            let byte1Index = buffer.index(start, offsetBy: 1)
            let byte1 = UInt32(buffer[byte1Index]) << 16
            let byte2Index = buffer.index(start, offsetBy: 2)
            let byte2 = UInt32(buffer[byte2Index]) << 8
            let byte3Index = buffer.index(start, offsetBy: 3)
            let byte3 = UInt32(buffer[byte3Index])
            let length = Int(byte0 | byte1 | byte2 | byte3)

            guard length > 0 else {
                buffer.removeAll(keepingCapacity: false)
                throw SyncthingPeerFramingError.invalidFrameLength(length)
            }
            guard length <= SyncthingPeerProtocolLimits.maximumMessageSize else {
                buffer.removeAll(keepingCapacity: false)
                throw SyncthingPeerFramingError.messageTooLarge(
                    actual: length,
                    maximum: SyncthingPeerProtocolLimits.maximumMessageSize
                )
            }

            let frameLength = headerSize + length
            guard buffer.count - cursor >= frameLength else { break }

            let payloadStart = buffer.index(start, offsetBy: headerSize)
            let payloadEnd = buffer.index(payloadStart, offsetBy: length)
            payloads.append(Data(buffer[payloadStart..<payloadEnd]))
            cursor += frameLength
        }

        if cursor > 0 {
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: cursor))
        }
        return payloads
    }

    public mutating func finish() throws {
        guard buffer.isEmpty else {
            let count = buffer.count
            buffer.removeAll(keepingCapacity: false)
            throw SyncthingPeerFramingError.truncatedFrame(bufferedBytes: count)
        }
    }
}
