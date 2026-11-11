import Foundation

public enum TranscriptAssemblerError: Error, Equatable, Sendable {
    case sequenceNumberExhausted
}

public struct TranscriptAssemblySnapshot: Codable, Equatable, Sendable {
    public let finalizedSegments: [TranscriptSegment]
    public let partialSegment: TranscriptSegment?
    public let finalizedText: String
    public let partialText: String
    public let text: String
    public let lastUpdateWasFinal: Bool

    public var segments: [TranscriptSegment] {
        finalizedSegments + (partialSegment.map { [$0] } ?? [])
    }
}

/// Deterministically assembles progressive recognition events.
///
/// A partial event replaces the previous partial at the current sequence
/// number. A final event appends one durable segment and advances the sequence.
public struct TranscriptAssembler: Equatable, Sendable {
    public let sessionID: UUID
    public private(set) var finalizedSegments: [TranscriptSegment]
    public private(set) var partialSegment: TranscriptSegment?
    public private(set) var nextSequenceNumber: UInt64

    public init(sessionID: UUID) {
        self.sessionID = sessionID
        self.finalizedSegments = []
        self.partialSegment = nil
        self.nextSequenceNumber = 0
    }

    public init(record: TranscriptSessionRecord) {
        sessionID = record.session.id
        finalizedSegments = record.segments.filter { $0.kind == .final }
        partialSegment = record.segments.last { $0.kind == .partial }
        if let lastSequence = record.segments.last?.sequenceNumber {
            let incremented = lastSequence.addingReportingOverflow(1)
            nextSequenceNumber = incremented.overflow
                ? UInt64.max
                : incremented.partialValue
        } else {
            nextSequenceNumber = 0
        }
    }

    @discardableResult
    public mutating func accept(
        _ text: String,
        isFinal: Bool,
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        startOffset: TimeInterval? = nil,
        endOffset: TimeInterval? = nil
    ) throws -> TranscriptAssemblySnapshot {
        guard !text.isEmpty else {
            partialSegment = nil
            return snapshot(lastUpdateWasFinal: isFinal)
        }
        guard nextSequenceNumber < UInt64.max else {
            throw TranscriptAssemblerError.sequenceNumberExhausted
        }

        let segment = try TranscriptSegment(
            id: id,
            sessionID: sessionID,
            sequenceNumber: nextSequenceNumber,
            kind: isFinal ? .final : .partial,
            text: text,
            capturedAt: capturedAt,
            startOffset: startOffset,
            endOffset: endOffset
        )

        if isFinal {
            finalizedSegments.append(segment)
            partialSegment = nil
            nextSequenceNumber += 1
        } else {
            partialSegment = segment
        }
        return snapshot(lastUpdateWasFinal: isFinal)
    }

    /// Converts the current partial into a durable final segment.
    @discardableResult
    public mutating func commitPartial() throws -> TranscriptAssemblySnapshot {
        if let partialSegment {
            guard nextSequenceNumber < UInt64.max else {
                throw TranscriptAssemblerError.sequenceNumberExhausted
            }
            finalizedSegments.append(try partialSegment.finalized())
            self.partialSegment = nil
            nextSequenceNumber += 1
        }
        return snapshot(lastUpdateWasFinal: true)
    }

    @discardableResult
    public mutating func discardPartial() -> TranscriptAssemblySnapshot {
        partialSegment = nil
        return snapshot(lastUpdateWasFinal: false)
    }

    public func snapshot(
        lastUpdateWasFinal: Bool = false
    ) -> TranscriptAssemblySnapshot {
        let finalizedText = finalizedSegments.reduce(into: "") {
            $0 = TranscriptText.join($0, $1.text)
        }
        let partialText = partialSegment?.text ?? ""
        return TranscriptAssemblySnapshot(
            finalizedSegments: finalizedSegments,
            partialSegment: partialSegment,
            finalizedText: finalizedText,
            partialText: partialText,
            text: TranscriptText.join(finalizedText, partialText),
            lastUpdateWasFinal: lastUpdateWasFinal
        )
    }

    public func record(for session: RecordingSession) throws
        -> TranscriptSessionRecord
    {
        try TranscriptSessionRecord(
            session: session,
            segments: snapshot().segments
        )
    }
}
