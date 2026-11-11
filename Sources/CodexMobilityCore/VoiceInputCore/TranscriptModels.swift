import Foundation

public enum TranscriptSegmentKind: String, Codable, Sendable {
    case partial
    case final
}

public enum TranscriptSegmentValidationError: Error, Equatable, Sendable {
    case emptyText
    case incompleteTiming
    case negativeStartOffset
    case endBeforeStart
}

/// One partial or final result produced by the speech recognizer.
///
/// Offsets are measured in seconds from the start of the recording session.
public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let sequenceNumber: UInt64
    public let kind: TranscriptSegmentKind
    public let text: String
    public let capturedAt: Date
    public let startOffset: TimeInterval?
    public let endOffset: TimeInterval?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        sequenceNumber: UInt64,
        kind: TranscriptSegmentKind,
        text: String,
        capturedAt: Date = Date(),
        startOffset: TimeInterval? = nil,
        endOffset: TimeInterval? = nil
    ) throws {
        try Self.validate(
            text: text,
            startOffset: startOffset,
            endOffset: endOffset
        )

        self.id = id
        self.sessionID = sessionID
        self.sequenceNumber = sequenceNumber
        self.kind = kind
        self.text = text
        self.capturedAt = capturedAt
        self.startOffset = startOffset
        self.endOffset = endOffset
    }

    public func finalized() throws -> Self {
        try Self(
            id: id,
            sessionID: sessionID,
            sequenceNumber: sequenceNumber,
            kind: .final,
            text: text,
            capturedAt: capturedAt,
            startOffset: startOffset,
            endOffset: endOffset
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case sequenceNumber
        case kind
        case text
        case capturedAt
        case startOffset
        case endOffset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedText = try container.decode(String.self, forKey: .text)
        let decodedStart = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .startOffset
        )
        let decodedEnd = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .endOffset
        )

        do {
            try Self.validate(
                text: decodedText,
                startOffset: decodedStart,
                endOffset: decodedEnd
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid transcript segment: \(error)"
                )
            )
        }

        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        sequenceNumber = try container.decode(
            UInt64.self,
            forKey: .sequenceNumber
        )
        kind = try container.decode(TranscriptSegmentKind.self, forKey: .kind)
        text = decodedText
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        startOffset = decodedStart
        endOffset = decodedEnd
    }

    private static func validate(
        text: String,
        startOffset: TimeInterval?,
        endOffset: TimeInterval?
    ) throws {
        guard !text.isEmpty else {
            throw TranscriptSegmentValidationError.emptyText
        }
        guard (startOffset == nil) == (endOffset == nil) else {
            throw TranscriptSegmentValidationError.incompleteTiming
        }
        guard let startOffset, let endOffset else { return }
        guard startOffset >= 0 else {
            throw TranscriptSegmentValidationError.negativeStartOffset
        }
        guard endOffset >= startOffset else {
            throw TranscriptSegmentValidationError.endBeforeStart
        }
    }
}

public enum TranscriptSessionRecordError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt16)
    case segmentBelongsToAnotherSession
    case duplicateSequenceNumber(UInt64)
    case sequenceNumbersNotIncreasing(previous: UInt64, current: UInt64)
    case finalSegmentAfterPartial
    case multiplePartialSegments
    case partialSegmentInTerminalSession
}

/// Durable transcript state for one recording session.
public struct TranscriptSessionRecord:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let session: RecordingSession
    public let segments: [TranscriptSegment]

    public var id: UUID { session.id }

    public var finalizedText: String {
        Self.assemble(
            segments.lazy
                .filter { $0.kind == .final }
                .map(\.text)
        )
    }

    public var partialText: String {
        segments.last(where: { $0.kind == .partial })?.text ?? ""
    }

    public var text: String {
        TranscriptText.join(finalizedText, partialText)
    }

    public init(
        session: RecordingSession,
        segments: [TranscriptSegment],
        schemaVersion: UInt16 = Self.currentSchemaVersion
    ) throws {
        try Self.validate(
            session: session,
            segments: segments,
            schemaVersion: schemaVersion
        )
        self.schemaVersion = schemaVersion
        self.session = session
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case session
        case segments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        let decodedSession = try container.decode(
            RecordingSession.self,
            forKey: .session
        )
        let decodedSegments = try container.decode(
            [TranscriptSegment].self,
            forKey: .segments
        )

        do {
            try Self.validate(
                session: decodedSession,
                segments: decodedSegments,
                schemaVersion: decodedVersion
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid transcript record: \(error)"
                )
            )
        }

        schemaVersion = decodedVersion
        session = decodedSession
        segments = decodedSegments
    }

    private static func validate(
        session: RecordingSession,
        segments: [TranscriptSegment],
        schemaVersion: UInt16
    ) throws {
        guard schemaVersion == currentSchemaVersion else {
            throw TranscriptSessionRecordError.unsupportedSchemaVersion(
                schemaVersion
            )
        }

        var sequences = Set<UInt64>()
        var previousSequence: UInt64?
        var encounteredPartial = false
        for segment in segments {
            guard segment.sessionID == session.id else {
                throw TranscriptSessionRecordError
                    .segmentBelongsToAnotherSession
            }
            guard sequences.insert(segment.sequenceNumber).inserted else {
                throw TranscriptSessionRecordError.duplicateSequenceNumber(
                    segment.sequenceNumber
                )
            }
            if let previousSequence,
               segment.sequenceNumber < previousSequence {
                throw TranscriptSessionRecordError
                    .sequenceNumbersNotIncreasing(
                        previous: previousSequence,
                        current: segment.sequenceNumber
                    )
            }
            previousSequence = segment.sequenceNumber

            if segment.kind == .partial {
                guard !encounteredPartial else {
                    throw TranscriptSessionRecordError.multiplePartialSegments
                }
                encounteredPartial = true
            } else if encounteredPartial {
                throw TranscriptSessionRecordError.finalSegmentAfterPartial
            }
        }

        if session.state.isTerminal, encounteredPartial {
            throw TranscriptSessionRecordError.partialSegmentInTerminalSession
        }
    }

    private static func assemble<S: Sequence>(_ parts: S) -> String
    where S.Element == String {
        parts.reduce(into: "") { accumulated, part in
            accumulated = TranscriptText.join(accumulated, part)
        }
    }
}

enum TranscriptText {
    static func join(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }
        guard
            let left = prefix.last,
            let right = suffix.first,
            !left.isWhitespace,
            !right.isWhitespace,
            needsBoundarySpace(left: left, right: right)
        else {
            return prefix + suffix
        }
        return prefix + " " + suffix
    }

    private static func needsBoundarySpace(
        left: Character,
        right: Character
    ) -> Bool {
        guard left.isASCII, right.isASCII else { return false }

        let closingPunctuation = CharacterSet(
            charactersIn: ".,;:!?)]}%>'’"
        )
        let openingPunctuation = CharacterSet(
            charactersIn: "([{<$#@'‘"
        )
        guard
            let leftScalar = left.unicodeScalars.first,
            let rightScalar = right.unicodeScalars.first,
            !openingPunctuation.contains(leftScalar),
            !closingPunctuation.contains(rightScalar)
        else {
            return false
        }
        return true
    }
}
