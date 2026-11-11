import Foundation
import XCTest
@testable import CodexMobilityCore

final class TranscriptAssemblerTests: XCTestCase {
    private let sessionID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
    private let origin = Date(timeIntervalSince1970: 2_000)

    func testPartialReplacesPreviousPartialWithoutAdvancingSequence() throws {
        var assembler = TranscriptAssembler(sessionID: sessionID)

        _ = try assembler.accept(
            "hello wor",
            isFinal: false,
            capturedAt: origin
        )
        let update = try assembler.accept(
            "hello world",
            isFinal: false,
            capturedAt: origin.addingTimeInterval(0.1)
        )

        XCTAssertEqual(update.finalizedText, "")
        XCTAssertEqual(update.partialText, "hello world")
        XCTAssertEqual(update.text, "hello world")
        XCTAssertEqual(update.partialSegment?.sequenceNumber, 0)
        XCTAssertEqual(assembler.nextSequenceNumber, 0)
        XCTAssertFalse(update.lastUpdateWasFinal)
    }

    func testFinalCommitsAndClearsPartial() throws {
        var assembler = TranscriptAssembler(sessionID: sessionID)

        _ = try assembler.accept(
            "hello wor",
            isFinal: false,
            capturedAt: origin
        )
        let update = try assembler.accept(
            "hello world",
            isFinal: true,
            capturedAt: origin.addingTimeInterval(1)
        )

        XCTAssertEqual(update.finalizedText, "hello world")
        XCTAssertEqual(update.partialText, "")
        XCTAssertEqual(update.text, "hello world")
        XCTAssertNil(update.partialSegment)
        XCTAssertEqual(update.finalizedSegments.count, 1)
        XCTAssertEqual(assembler.nextSequenceNumber, 1)
        XCTAssertTrue(update.lastUpdateWasFinal)
    }

    func testBoundarySpacingHandlesEnglishChineseAndPunctuation() throws {
        var assembler = TranscriptAssembler(sessionID: sessionID)

        _ = try assembler.accept("Hello.", isFinal: true)
        _ = try assembler.accept("How are you", isFinal: true)
        _ = try assembler.accept("?", isFinal: true)
        _ = try assembler.accept("你好", isFinal: true)
        let update = try assembler.accept("世界", isFinal: true)

        XCTAssertEqual(update.text, "Hello. How are you?你好世界")
    }

    func testCommitAndDiscardPartialAreExplicit() throws {
        var assembler = TranscriptAssembler(sessionID: sessionID)

        _ = try assembler.accept("keep me", isFinal: false)
        let committed = try assembler.commitPartial()
        XCTAssertEqual(committed.finalizedText, "keep me")
        XCTAssertEqual(assembler.nextSequenceNumber, 1)

        _ = try assembler.accept("discard me", isFinal: false)
        let discarded = assembler.discardPartial()
        XCTAssertEqual(discarded.text, "keep me")
        XCTAssertEqual(assembler.nextSequenceNumber, 1)
    }

    func testEmptyUpdateClearsPartialWithoutCreatingSegment() throws {
        var assembler = TranscriptAssembler(sessionID: sessionID)
        _ = try assembler.accept("temporary", isFinal: false)

        let update = try assembler.accept("", isFinal: false)

        XCTAssertNil(update.partialSegment)
        XCTAssertTrue(update.segments.isEmpty)
        XCTAssertEqual(assembler.nextSequenceNumber, 0)
    }

    func testAssemblerCreatesRecordAndRestoresPendingPartial() throws {
        var session = RecordingSession(
            id: sessionID,
            localeIdentifier: "en-US",
            createdAt: origin
        )
        try session.transition(to: .recording, at: origin)

        var assembler = TranscriptAssembler(sessionID: sessionID)
        _ = try assembler.accept("one", isFinal: true)
        _ = try assembler.accept("two", isFinal: false)
        let record = try assembler.record(for: session)

        let restored = TranscriptAssembler(record: record)

        XCTAssertEqual(restored.sessionID, sessionID)
        XCTAssertEqual(restored.finalizedSegments.map(\.text), ["one"])
        XCTAssertEqual(restored.partialSegment?.text, "two")
        XCTAssertEqual(restored.nextSequenceNumber, 2)
        XCTAssertEqual(restored.snapshot().text, "one two")
    }
}
