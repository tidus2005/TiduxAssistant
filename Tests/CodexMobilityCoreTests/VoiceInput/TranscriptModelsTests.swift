import Foundation
import XCTest
@testable import CodexMobilityCore

final class TranscriptModelsTests: XCTestCase {
    private let sessionID = UUID(
        uuidString: "33333333-3333-3333-3333-333333333333"
    )!
    private let origin = Date(timeIntervalSince1970: 3_000)

    func testSegmentCodableRoundTrip() throws {
        let segment = try TranscriptSegment(
            id: UUID(
                uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
            )!,
            sessionID: sessionID,
            sequenceNumber: 4,
            kind: .final,
            text: "测试内容",
            capturedAt: origin,
            startOffset: 1.25,
            endOffset: 2.5
        )

        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(
            TranscriptSegment.self,
            from: data
        )

        XCTAssertEqual(decoded, segment)
    }

    func testSegmentTimingValidation() {
        XCTAssertThrowsError(
            try TranscriptSegment(
                sessionID: sessionID,
                sequenceNumber: 0,
                kind: .final,
                text: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? TranscriptSegmentValidationError,
                .emptyText
            )
        }

        XCTAssertThrowsError(
            try TranscriptSegment(
                sessionID: sessionID,
                sequenceNumber: 0,
                kind: .final,
                text: "text",
                startOffset: 1,
                endOffset: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? TranscriptSegmentValidationError,
                .incompleteTiming
            )
        }

        XCTAssertThrowsError(
            try TranscriptSegment(
                sessionID: sessionID,
                sequenceNumber: 0,
                kind: .final,
                text: "text",
                startOffset: 2,
                endOffset: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? TranscriptSegmentValidationError,
                .endBeforeStart
            )
        }
    }

    func testRecordCodableRoundTripAndDerivedText() throws {
        var session = RecordingSession(
            id: sessionID,
            localeIdentifier: "en-US",
            createdAt: origin
        )
        try session.transition(to: .recording, at: origin)

        let segments = [
            try TranscriptSegment(
                sessionID: sessionID,
                sequenceNumber: 0,
                kind: .final,
                text: "Hello.",
                capturedAt: origin
            ),
            try TranscriptSegment(
                sessionID: sessionID,
                sequenceNumber: 1,
                kind: .partial,
                text: "Next",
                capturedAt: origin.addingTimeInterval(1)
            ),
        ]
        let record = try TranscriptSessionRecord(
            session: session,
            segments: segments
        )

        XCTAssertEqual(record.finalizedText, "Hello.")
        XCTAssertEqual(record.partialText, "Next")
        XCTAssertEqual(record.text, "Hello. Next")

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(
            TranscriptSessionRecord.self,
            from: data
        )
        XCTAssertEqual(decoded, record)
    }

    func testRecordRejectsForeignAndDuplicateSegments() throws {
        let session = RecordingSession(
            id: sessionID,
            localeIdentifier: "zh-CN",
            createdAt: origin
        )
        let foreign = try TranscriptSegment(
            sessionID: UUID(),
            sequenceNumber: 0,
            kind: .final,
            text: "foreign"
        )
        XCTAssertThrowsError(
            try TranscriptSessionRecord(
                session: session,
                segments: [foreign]
            )
        ) { error in
            XCTAssertEqual(
                error as? TranscriptSessionRecordError,
                .segmentBelongsToAnotherSession
            )
        }

        let first = try TranscriptSegment(
            sessionID: sessionID,
            sequenceNumber: 0,
            kind: .final,
            text: "first"
        )
        let duplicate = try TranscriptSegment(
            sessionID: sessionID,
            sequenceNumber: 0,
            kind: .final,
            text: "duplicate"
        )
        XCTAssertThrowsError(
            try TranscriptSessionRecord(
                session: session,
                segments: [first, duplicate]
            )
        ) { error in
            XCTAssertEqual(
                error as? TranscriptSessionRecordError,
                .duplicateSequenceNumber(0)
            )
        }
    }

    func testRecordRejectsOutOfOrderSegments() throws {
        let session = RecordingSession(
            id: sessionID,
            localeIdentifier: "zh-CN",
            createdAt: origin
        )
        let second = try TranscriptSegment(
            sessionID: sessionID,
            sequenceNumber: 2,
            kind: .final,
            text: "second"
        )
        let first = try TranscriptSegment(
            sessionID: sessionID,
            sequenceNumber: 1,
            kind: .final,
            text: "first"
        )

        XCTAssertThrowsError(
            try TranscriptSessionRecord(
                session: session,
                segments: [second, first]
            )
        ) { error in
            XCTAssertEqual(
                error as? TranscriptSessionRecordError,
                .sequenceNumbersNotIncreasing(previous: 2, current: 1)
            )
        }
    }

    func testTerminalRecordRejectsPartialSegment() throws {
        var session = RecordingSession(
            id: sessionID,
            localeIdentifier: "zh-CN",
            createdAt: origin
        )
        try session.transition(to: .recording, at: origin)
        try session.transition(to: .stopping, at: origin)
        try session.transition(to: .completed, at: origin)

        let partial = try TranscriptSegment(
            sessionID: sessionID,
            sequenceNumber: 0,
            kind: .partial,
            text: "not durable"
        )

        XCTAssertThrowsError(
            try TranscriptSessionRecord(
                session: session,
                segments: [partial]
            )
        ) { error in
            XCTAssertEqual(
                error as? TranscriptSessionRecordError,
                .partialSegmentInTerminalSession
            )
        }
    }
}
