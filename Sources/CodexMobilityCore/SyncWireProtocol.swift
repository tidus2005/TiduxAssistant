import Foundation

public enum SyncDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case phoneToMac
    case macToPhone
}

public enum SyncMediaType: String, Codable, CaseIterable, Hashable, Sendable {
    case image
    case video
    case file
}

public enum SyncProtocolLimits {
    public static let maximumItemSize: UInt64 = 2 * 1_024 * 1_024 * 1_024
    public static let maximumRelativePathUTF8Bytes = 1_024
    public static let maximumPathComponentUTF8Bytes = 255
    public static let minimumChunkSize = 32
    public static let maximumChunkSize = 64 * 1_024
    public static let defaultWindowSize = 4
    public static let maximumWindowSize = 16
}

public struct SyncItemMetadata: Codable, Equatable, Hashable, Sendable {
    public var transferID: UUID
    public var direction: SyncDirection
    public var mediaType: SyncMediaType
    public var relativePath: String
    public var byteSize: UInt64
    public var modifiedAt: Date
    public var sha256: String

    public init(
        transferID: UUID = UUID(),
        direction: SyncDirection,
        mediaType: SyncMediaType,
        relativePath: String,
        byteSize: UInt64,
        modifiedAt: Date,
        sha256: String
    ) {
        self.transferID = transferID
        self.direction = direction
        self.mediaType = mediaType
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.sha256 = sha256.lowercased()
    }

    public func validated() throws -> SyncItemMetadata {
        guard byteSize <= SyncProtocolLimits.maximumItemSize else {
            throw SyncProtocolError.itemTooLarge(byteSize)
        }
        guard SyncSHA256.isValidHexDigest(sha256) else {
            throw SyncProtocolError.invalidSHA256(sha256)
        }
        var copy = self
        copy.relativePath = try SyncRelativePath.normalize(relativePath)
        copy.sha256 = sha256.lowercased()
        return copy
    }
}

public struct SyncTransportCapabilities: Codable, Equatable, Hashable, Sendable {
    public var maximumFrameSize: Int
    public var preferredChunkSize: Int
    public var maximumWindowSize: Int

    public init(
        maximumFrameSize: Int,
        preferredChunkSize: Int,
        maximumWindowSize: Int = SyncProtocolLimits.defaultWindowSize
    ) {
        self.maximumFrameSize = max(maximumFrameSize, 1)
        self.preferredChunkSize = min(
            max(preferredChunkSize, SyncProtocolLimits.minimumChunkSize),
            SyncProtocolLimits.maximumChunkSize
        )
        self.maximumWindowSize = min(max(maximumWindowSize, 1), SyncProtocolLimits.maximumWindowSize)
    }
}

public struct SyncOfferRequest: Codable, Equatable, Hashable, Sendable {
    public var requestID: UUID
    public var requestedDirection: SyncDirection
    public var knownTransferIDs: [UUID]

    public init(
        requestID: UUID = UUID(),
        requestedDirection: SyncDirection = .macToPhone,
        knownTransferIDs: [UUID] = []
    ) {
        self.requestID = requestID
        self.requestedDirection = requestedDirection
        self.knownTransferIDs = knownTransferIDs
    }
}

public struct SyncOffer: Codable, Equatable, Hashable, Sendable {
    public var metadata: SyncItemMetadata
    public var capabilities: SyncTransportCapabilities

    public init(metadata: SyncItemMetadata, capabilities: SyncTransportCapabilities) {
        self.metadata = metadata
        self.capabilities = capabilities
    }
}

public struct SyncTransferParameters: Codable, Equatable, Hashable, Sendable {
    public var maximumFrameSize: Int
    public var chunkSize: Int
    public var windowSize: Int

    public init(maximumFrameSize: Int, chunkSize: Int, windowSize: Int) {
        self.maximumFrameSize = max(maximumFrameSize, 1)
        self.chunkSize = min(
            max(chunkSize, SyncProtocolLimits.minimumChunkSize),
            SyncProtocolLimits.maximumChunkSize
        )
        self.windowSize = min(max(windowSize, 1), SyncProtocolLimits.maximumWindowSize)
    }
}

public struct SyncAcceptance: Codable, Equatable, Hashable, Sendable {
    public var transferID: UUID
    public var acceptedRelativePath: String
    public var resumeOffset: UInt64
    public var parameters: SyncTransferParameters

    public init(
        transferID: UUID,
        acceptedRelativePath: String,
        resumeOffset: UInt64 = 0,
        parameters: SyncTransferParameters
    ) {
        self.transferID = transferID
        self.acceptedRelativePath = acceptedRelativePath
        self.resumeOffset = resumeOffset
        self.parameters = parameters
    }
}

public struct SyncResume: Codable, Equatable, Hashable, Sendable {
    public var transferID: UUID
    public var nextOffset: UInt64

    public init(transferID: UUID, nextOffset: UInt64) {
        self.transferID = transferID
        self.nextOffset = nextOffset
    }
}

public struct SyncChunk: Codable, Equatable, Hashable, Sendable {
    public var transferID: UUID
    public var offset: UInt64
    public var data: Data
    public var checksumSHA256: String
    public var isFinal: Bool

    public init(
        transferID: UUID,
        offset: UInt64,
        data: Data,
        checksumSHA256: String? = nil,
        isFinal: Bool = false
    ) {
        self.transferID = transferID
        self.offset = offset
        self.data = data
        self.checksumSHA256 = (checksumSHA256 ?? SyncSHA256.hexDigest(data)).lowercased()
        self.isFinal = isFinal
    }
}

public struct SyncAcknowledgement: Codable, Equatable, Hashable, Sendable {
    public var transferID: UUID
    public var nextExpectedOffset: UInt64
    public var availableWindow: Int

    public init(
        transferID: UUID,
        nextExpectedOffset: UInt64,
        availableWindow: Int = SyncProtocolLimits.defaultWindowSize
    ) {
        self.transferID = transferID
        self.nextExpectedOffset = nextExpectedOffset
        self.availableWindow = min(max(availableWindow, 0), SyncProtocolLimits.maximumWindowSize)
    }
}

public enum SyncCompletionStage: String, Codable, CaseIterable, Hashable, Sendable {
    /// The sender has emitted every byte. The receiver still has to verify and commit the file.
    case senderFinished
    /// The receiver verified the digest and durably committed the file at `storedRelativePath`.
    case receiverStored
}

public struct SyncCompletion: Codable, Equatable, Hashable, Sendable {
    public var transferID: UUID
    public var totalBytes: UInt64
    public var sha256: String
    public var stage: SyncCompletionStage
    public var storedRelativePath: String?

    public init(
        transferID: UUID,
        totalBytes: UInt64,
        sha256: String,
        stage: SyncCompletionStage = .senderFinished,
        storedRelativePath: String? = nil
    ) {
        self.transferID = transferID
        self.totalBytes = totalBytes
        self.sha256 = sha256.lowercased()
        self.stage = stage
        self.storedRelativePath = storedRelativePath
    }

    public var isVerifiedAndStored: Bool { stage == .receiverStored }
}

public struct SyncCancellation: Codable, Equatable, Hashable, Sendable {
    public var transferID: UUID
    public var reason: String

    public init(transferID: UUID, reason: String) {
        self.transferID = transferID
        self.reason = reason
    }
}

public enum SyncFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case invalidPath
    case itemTooLarge
    case checksumMismatch
    case conflict
    case unavailable
    case permissionDenied
    case protocolViolation
    case io
}

public struct SyncFailure: Codable, Equatable, Hashable, Sendable {
    public var transferID: UUID?
    public var code: SyncFailureCode
    public var message: String
    public var retryable: Bool

    public init(
        transferID: UUID? = nil,
        code: SyncFailureCode,
        message: String,
        retryable: Bool = false
    ) {
        self.transferID = transferID
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public enum SyncWireMessage: Codable, Equatable, Hashable, Sendable {
    case requestOffers(SyncOfferRequest)
    case offer(SyncOffer)
    case accept(SyncAcceptance)
    case resume(SyncResume)
    case chunk(SyncChunk)
    case ack(SyncAcknowledgement)
    case complete(SyncCompletion)
    case cancel(SyncCancellation)
    case failure(SyncFailure)
}

public enum SyncProtocolError: Error, Equatable, Sendable {
    case itemTooLarge(UInt64)
    case invalidSHA256(String)
    case wrongTransfer(expected: UUID, actual: UUID)
    case invalidResumeOffset(UInt64)
    case invalidChunkSize(Int)
    case unexpectedOffset(expected: UInt64, actual: UInt64)
    case chunkExceedsItemSize
    case invalidFinalChunk
    case checksumMismatch(expected: String, actual: String)
    case incompleteTransfer(expected: UInt64, actual: UInt64)
    case invalidCompletionStage(SyncCompletionStage)
    case acknowledgementOutOfRange(UInt64)
    case frameSizeTooSmall(Int)
    case windowFull
    case invalidState(expected: SyncTransferPhase, actual: SyncTransferPhase)
}

public struct SyncJSONCodec: Sendable {
    public init() {}

    public func encode(_ message: SyncWireMessage) throws -> Data {
        try Self.makeEncoder().encode(message)
    }

    public func decode(_ data: Data) throws -> SyncWireMessage {
        try Self.makeDecoder().decode(SyncWireMessage.self, from: data)
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
