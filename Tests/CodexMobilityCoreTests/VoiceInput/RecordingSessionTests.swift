import Foundation
import XCTest
@testable import CodexMobilityCore

final class RecordingSessionTests: XCTestCase {
    private let sessionID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testValidLifecycleRecordsStableTimestamps() throws {
        var session = RecordingSession(
            id: sessionID,
            localeIdentifier: "zh-CN",
            createdAt: origin
        )

        try session.transition(to: .recording, at: origin.addingTimeInterval(1))
        try session.transition(to: .paused, at: origin.addingTimeInterval(2))
        try session.transition(to: .recording, at: origin.addingTimeInterval(3))
        try session.transition(to: .stopping, at: origin.addingTimeInterval(4))
        try session.transition(to: .completed, at: origin.addingTimeInterval(5))

        XCTAssertEqual(session.state, .completed)
        XCTAssertEqual(session.startedAt, origin.addingTimeInterval(1))
        XCTAssertEqual(session.endedAt, origin.addingTimeInterval(5))
        XCTAssertEqual(session.updatedAt, origin.addingTimeInterval(5))
        XCTAssertTrue(session.state.isTerminal)
    }

    func testIllegalAndTerminalTransitionsAreRejected() throws {
        var session = RecordingSession(
            id: sessionID,
            localeIdentifier: "en-US",
            createdAt: origin
        )

        XCTAssertThrowsError(
            try session.transition(
                to: .completed,
                at: origin.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? RecordingSessionTransitionError,
                .illegalTransition(from: .preparing, to: .completed)
            )
        }

        try session.transition(to: .cancelled, at: origin.addingTimeInterval(2))
        XCTAssertThrowsError(
            try session.transition(
                to: .recording,
                at: origin.addingTimeInterval(3)
            )
        )
    }

    func testFailureIsRequiredOnlyForFailedState() throws {
        var missingFailure = RecordingSession(
            localeIdentifier: "zh-CN",
            createdAt: origin
        )
        XCTAssertThrowsError(
            try missingFailure.transition(
                to: .failed,
                at: origin.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? RecordingSessionTransitionError,
                .failureRequired
            )
        }

        let failure = RecordingSessionFailure(
            code: "audio-interrupted",
            message: "Audio input stopped."
        )
        try missingFailure.transition(
            to: .failed,
            at: origin.addingTimeInterval(2),
            failure: failure
        )
        XCTAssertEqual(missingFailure.failure, failure)

        var unexpectedFailure = RecordingSession(
            localeIdentifier: "zh-CN",
            createdAt: origin
        )
        XCTAssertThrowsError(
            try unexpectedFailure.transition(
                to: .recording,
                at: origin.addingTimeInterval(1),
                failure: failure
            )
        ) { error in
            XCTAssertEqual(
                error as? RecordingSessionTransitionError,
                .unexpectedFailure
            )
        }
    }

    func testTransitionTimestampsCannotMoveBackwards() throws {
        var session = RecordingSession(
            localeIdentifier: "zh-CN",
            createdAt: origin
        )
        try session.transition(to: .recording, at: origin.addingTimeInterval(2))

        XCTAssertThrowsError(
            try session.transition(
                to: .stopping,
                at: origin.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? RecordingSessionTransitionError,
                .timestampMovedBackwards
            )
        }
    }

    func testSessionCodableRoundTripPreservesLifecycle() throws {
        var session = RecordingSession(
            id: sessionID,
            localeIdentifier: "zh-CN",
            createdAt: origin
        )
        try session.transition(to: .recording, at: origin.addingTimeInterval(1))
        try session.transition(to: .stopping, at: origin.addingTimeInterval(2))

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(
            RecordingSession.self,
            from: data
        )

        XCTAssertEqual(decoded, session)
    }

    func testDecoderRejectsImpossibleTerminalRecord() throws {
        let json = """
        {
          "id": "\(sessionID.uuidString)",
          "localeIdentifier": "zh-CN",
          "createdAt": 0,
          "updatedAt": 1,
          "state": "completed"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        XCTAssertThrowsError(
            try decoder.decode(
                RecordingSession.self,
                from: Data(json.utf8)
            )
        )
    }
}
