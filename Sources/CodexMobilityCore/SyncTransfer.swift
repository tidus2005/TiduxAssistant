import Foundation

public enum SyncTransferPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case offered
    case transferring
    case verifying
    case completed
    case cancelled
    case failed
}

public enum SyncBLETransferTuning {
    /// Builds endpoint capabilities from the actual CoreBluetooth write/notify limits.
    /// The default file chunk spans a small number of BLE frames to balance JSON overhead
    /// against retransmission cost; therefore it automatically grows with the negotiated MTU.
    public static func capabilities(
        maximumWriteValueLength: Int,
        maximumUpdateValueLength: Int,
        framesPerChunk: Int = 4,
        maximumWindowSize: Int = SyncProtocolLimits.defaultWindowSize
    ) throws -> SyncTransportCapabilities {
        let maximumFrameSize = min(maximumWriteValueLength, maximumUpdateValueLength)
        guard maximumFrameSize > MobilityFrameHeader.encodedLength else {
            throw SyncProtocolError.frameSizeTooSmall(maximumFrameSize)
        }
        let framePayload = maximumFrameSize - MobilityFrameHeader.encodedLength
        let preferredChunkSize = min(
            max(framePayload * max(framesPerChunk, 1), SyncProtocolLimits.minimumChunkSize),
            SyncProtocolLimits.maximumChunkSize
        )
        return SyncTransportCapabilities(
            maximumFrameSize: maximumFrameSize,
            preferredChunkSize: preferredChunkSize,
            maximumWindowSize: maximumWindowSize
        )
    }

    public static func negotiate(
        local: SyncTransportCapabilities,
        remote: SyncTransportCapabilities
    ) throws -> SyncTransferParameters {
        let maximumFrameSize = min(local.maximumFrameSize, remote.maximumFrameSize)
        guard maximumFrameSize > MobilityFrameHeader.encodedLength else {
            throw SyncProtocolError.frameSizeTooSmall(maximumFrameSize)
        }
        return SyncTransferParameters(
            maximumFrameSize: maximumFrameSize,
            chunkSize: min(local.preferredChunkSize, remote.preferredChunkSize),
            windowSize: min(local.maximumWindowSize, remote.maximumWindowSize)
        )
    }
}

public struct SyncInFlightRange: Codable, Equatable, Hashable, Sendable {
    public var offset: UInt64
    public var endOffset: UInt64

    public init(offset: UInt64, endOffset: UInt64) {
        self.offset = offset
        self.endOffset = endOffset
    }
}

public struct SyncSendState: Codable, Equatable, Sendable {
    public private(set) var metadata: SyncItemMetadata
    public private(set) var parameters: SyncTransferParameters
    public private(set) var phase: SyncTransferPhase
    public private(set) var nextOffset: UInt64
    public private(set) var acknowledgedOffset: UInt64
    public private(set) var peerAvailableWindow: Int
    public private(set) var inFlight: [SyncInFlightRange]

    public init(
        metadata: SyncItemMetadata,
        parameters: SyncTransferParameters,
        resumeOffset: UInt64 = 0
    ) throws {
        let metadata = try metadata.validated()
        guard resumeOffset <= metadata.byteSize else {
            throw SyncProtocolError.invalidResumeOffset(resumeOffset)
        }
        self.metadata = metadata
        self.parameters = parameters
        self.phase = resumeOffset == metadata.byteSize ? .verifying : .transferring
        self.nextOffset = resumeOffset
        self.acknowledgedOffset = resumeOffset
        self.peerAvailableWindow = parameters.windowSize
        self.inFlight = []
    }

    public var remainingBytes: UInt64 { metadata.byteSize - nextOffset }
    public var isReadyToSend: Bool {
        phase == .transferring
            && nextOffset < metadata.byteSize
            && inFlight.count < min(parameters.windowSize, peerAvailableWindow)
    }

    public mutating func makeChunk(_ data: Data) throws -> SyncChunk {
        guard phase == .transferring else {
            throw SyncProtocolError.invalidState(expected: .transferring, actual: phase)
        }
        guard isReadyToSend else { throw SyncProtocolError.windowFull }
        guard !data.isEmpty, data.count <= parameters.chunkSize else {
            throw SyncProtocolError.invalidChunkSize(data.count)
        }
        guard UInt64(data.count) <= remainingBytes else {
            throw SyncProtocolError.chunkExceedsItemSize
        }

        let offset = nextOffset
        let endOffset = offset + UInt64(data.count)
        let chunk = SyncChunk(
            transferID: metadata.transferID,
            offset: offset,
            data: data,
            isFinal: endOffset == metadata.byteSize
        )
        nextOffset = endOffset
        inFlight.append(SyncInFlightRange(offset: offset, endOffset: endOffset))
        if nextOffset == metadata.byteSize {
            phase = .verifying
        }
        return chunk
    }

    public mutating func acknowledge(_ acknowledgement: SyncAcknowledgement) throws {
        guard acknowledgement.transferID == metadata.transferID else {
            throw SyncProtocolError.wrongTransfer(
                expected: metadata.transferID,
                actual: acknowledgement.transferID
            )
        }
        let offset = acknowledgement.nextExpectedOffset
        guard offset >= acknowledgedOffset, offset <= nextOffset else {
            throw SyncProtocolError.acknowledgementOutOfRange(offset)
        }
        if offset != acknowledgedOffset,
           !inFlight.contains(where: { $0.endOffset == offset }) {
            throw SyncProtocolError.acknowledgementOutOfRange(offset)
        }
        acknowledgedOffset = offset
        peerAvailableWindow = acknowledgement.availableWindow
        inFlight.removeAll { $0.endOffset <= offset }
    }

    public mutating func resume(at offset: UInt64) throws {
        guard offset <= metadata.byteSize else {
            throw SyncProtocolError.invalidResumeOffset(offset)
        }
        nextOffset = offset
        acknowledgedOffset = offset
        peerAvailableWindow = parameters.windowSize
        inFlight.removeAll(keepingCapacity: false)
        phase = offset == metadata.byteSize ? .verifying : .transferring
    }

    public func senderFinishedMessage() throws -> SyncCompletion {
        guard nextOffset == metadata.byteSize else {
            throw SyncProtocolError.incompleteTransfer(expected: metadata.byteSize, actual: nextOffset)
        }
        return SyncCompletion(
            transferID: metadata.transferID,
            totalBytes: metadata.byteSize,
            sha256: metadata.sha256,
            stage: .senderFinished
        )
    }

    public mutating func markReceiverStored(_ completion: SyncCompletion) throws {
        guard completion.transferID == metadata.transferID else {
            throw SyncProtocolError.wrongTransfer(
                expected: metadata.transferID,
                actual: completion.transferID
            )
        }
        guard completion.stage == .receiverStored else {
            throw SyncProtocolError.invalidCompletionStage(completion.stage)
        }
        guard completion.totalBytes == metadata.byteSize else {
            throw SyncProtocolError.incompleteTransfer(
                expected: metadata.byteSize,
                actual: completion.totalBytes
            )
        }
        guard SyncSHA256.constantTimeEqual(completion.sha256, metadata.sha256) else {
            throw SyncProtocolError.checksumMismatch(
                expected: metadata.sha256,
                actual: completion.sha256
            )
        }
        if let storedRelativePath = completion.storedRelativePath {
            _ = try SyncRelativePath.normalize(storedRelativePath)
        }
        phase = .completed
        inFlight.removeAll(keepingCapacity: false)
    }

    public mutating func cancel() {
        phase = .cancelled
        inFlight.removeAll(keepingCapacity: false)
    }

    public mutating func fail() {
        phase = .failed
        inFlight.removeAll(keepingCapacity: false)
    }
}

public struct SyncReceiveProgress: Codable, Equatable, Hashable, Sendable {
    public var acknowledgement: SyncAcknowledgement
    public var shouldWrite: Bool
    public var isDuplicate: Bool

    public init(
        acknowledgement: SyncAcknowledgement,
        shouldWrite: Bool,
        isDuplicate: Bool
    ) {
        self.acknowledgement = acknowledgement
        self.shouldWrite = shouldWrite
        self.isDuplicate = isDuplicate
    }
}

public struct SyncReceiveState: Codable, Equatable, Sendable {
    public private(set) var metadata: SyncItemMetadata
    public private(set) var parameters: SyncTransferParameters
    public private(set) var phase: SyncTransferPhase
    public private(set) var expectedOffset: UInt64

    public init(
        metadata: SyncItemMetadata,
        parameters: SyncTransferParameters,
        resumeOffset: UInt64 = 0
    ) throws {
        let metadata = try metadata.validated()
        guard resumeOffset <= metadata.byteSize else {
            throw SyncProtocolError.invalidResumeOffset(resumeOffset)
        }
        self.metadata = metadata
        self.parameters = parameters
        self.phase = resumeOffset == metadata.byteSize ? .verifying : .transferring
        self.expectedOffset = resumeOffset
    }

    public mutating func receive(_ chunk: SyncChunk) throws -> SyncReceiveProgress {
        guard phase == .transferring || phase == .verifying else {
            throw SyncProtocolError.invalidState(expected: .transferring, actual: phase)
        }
        guard chunk.transferID == metadata.transferID else {
            throw SyncProtocolError.wrongTransfer(expected: metadata.transferID, actual: chunk.transferID)
        }
        guard !chunk.data.isEmpty, chunk.data.count <= parameters.chunkSize else {
            throw SyncProtocolError.invalidChunkSize(chunk.data.count)
        }
        let actualChunkChecksum = SyncSHA256.hexDigest(chunk.data)
        guard SyncSHA256.constantTimeEqual(chunk.checksumSHA256, actualChunkChecksum) else {
            throw SyncProtocolError.checksumMismatch(
                expected: chunk.checksumSHA256,
                actual: actualChunkChecksum
            )
        }
        let byteCount = UInt64(chunk.data.count)
        guard chunk.offset <= UInt64.max - byteCount else {
            throw SyncProtocolError.chunkExceedsItemSize
        }
        let endOffset = chunk.offset + byteCount
        guard endOffset <= metadata.byteSize else {
            throw SyncProtocolError.chunkExceedsItemSize
        }

        if chunk.offset < expectedOffset, endOffset <= expectedOffset {
            return progress(shouldWrite: false, isDuplicate: true)
        }
        guard phase == .transferring else {
            throw SyncProtocolError.invalidState(expected: .transferring, actual: phase)
        }
        guard chunk.offset == expectedOffset else {
            throw SyncProtocolError.unexpectedOffset(expected: expectedOffset, actual: chunk.offset)
        }
        guard chunk.isFinal == (endOffset == metadata.byteSize) else {
            throw SyncProtocolError.invalidFinalChunk
        }

        expectedOffset = endOffset
        if expectedOffset == metadata.byteSize {
            phase = .verifying
        }
        return progress(shouldWrite: true, isDuplicate: false)
    }

    public mutating func resume(at offset: UInt64) throws {
        guard offset <= metadata.byteSize else {
            throw SyncProtocolError.invalidResumeOffset(offset)
        }
        expectedOffset = offset
        phase = offset == metadata.byteSize ? .verifying : .transferring
    }

    /// Verifies the sender declaration and the digest calculated from the complete staged file,
    /// then returns the receiver's durable-store acknowledgement.
    public mutating func finalize(
        _ completion: SyncCompletion,
        calculatedSHA256: String,
        storedRelativePath: String
    ) throws -> SyncCompletion {
        guard phase == .verifying else {
            throw SyncProtocolError.invalidState(expected: .verifying, actual: phase)
        }
        guard completion.transferID == metadata.transferID else {
            throw SyncProtocolError.wrongTransfer(expected: metadata.transferID, actual: completion.transferID)
        }
        guard completion.stage == .senderFinished else {
            throw SyncProtocolError.invalidCompletionStage(completion.stage)
        }
        guard expectedOffset == metadata.byteSize, completion.totalBytes == metadata.byteSize else {
            throw SyncProtocolError.incompleteTransfer(
                expected: metadata.byteSize,
                actual: min(expectedOffset, completion.totalBytes)
            )
        }
        guard SyncSHA256.constantTimeEqual(completion.sha256, metadata.sha256) else {
            throw SyncProtocolError.checksumMismatch(
                expected: metadata.sha256,
                actual: completion.sha256
            )
        }
        let calculatedSHA256 = calculatedSHA256.lowercased()
        guard SyncSHA256.constantTimeEqual(calculatedSHA256, metadata.sha256) else {
            throw SyncProtocolError.checksumMismatch(
                expected: metadata.sha256,
                actual: calculatedSHA256
            )
        }
        let storedRelativePath = try SyncRelativePath.normalize(storedRelativePath)
        phase = .completed
        return SyncCompletion(
            transferID: metadata.transferID,
            totalBytes: metadata.byteSize,
            sha256: metadata.sha256,
            stage: .receiverStored,
            storedRelativePath: storedRelativePath
        )
    }

    public mutating func cancel() { phase = .cancelled }
    public mutating func fail() { phase = .failed }

    private func progress(shouldWrite: Bool, isDuplicate: Bool) -> SyncReceiveProgress {
        SyncReceiveProgress(
            acknowledgement: SyncAcknowledgement(
                transferID: metadata.transferID,
                nextExpectedOffset: expectedOffset,
                availableWindow: parameters.windowSize
            ),
            shouldWrite: shouldWrite,
            isDuplicate: isDuplicate
        )
    }
}
