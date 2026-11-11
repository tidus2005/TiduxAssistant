import XCTest
@testable import CodexMobilityCore

final class RecordingRunCoordinatorTests: XCTestCase {
    func testBeginCreatesActiveGenerationThatAcceptsUpdates() {
        var coordinator = RecordingRunCoordinator()

        XCTAssertNil(coordinator.activeGeneration)
        XCTAssertFalse(coordinator.acceptsUpdate(for: 1))

        let generation = coordinator.begin()

        XCTAssertEqual(generation, 1)
        XCTAssertEqual(coordinator.activeGeneration, generation)
        XCTAssertTrue(coordinator.acceptsUpdate(for: generation))
        XCTAssertNil(coordinator.claimedTerminalPath)
    }

    func testStopWinsAndRejectsConcurrentFailureTerminalPath() {
        var coordinator = RecordingRunCoordinator()
        let generation = coordinator.begin()

        XCTAssertEqual(
            coordinator.claimTerminal(.stop, for: generation),
            .accepted
        )
        XCTAssertEqual(
            coordinator.claimTerminal(.failure, for: generation),
            .alreadyClaimed(.stop)
        )
        XCTAssertTrue(coordinator.ownsTerminal(.stop, for: generation))
        XCTAssertFalse(coordinator.ownsTerminal(.failure, for: generation))
        XCTAssertFalse(coordinator.acceptsUpdate(for: generation))
    }

    func testFailureWinsAndRejectsConcurrentStopTerminalPath() {
        var coordinator = RecordingRunCoordinator()
        let generation = coordinator.begin()

        XCTAssertEqual(
            coordinator.claimTerminal(.failure, for: generation),
            .accepted
        )
        XCTAssertEqual(
            coordinator.claimTerminal(.stop, for: generation),
            .alreadyClaimed(.failure)
        )
        XCTAssertTrue(coordinator.ownsTerminal(.failure, for: generation))
        XCTAssertFalse(coordinator.acceptsUpdate(for: generation))
    }

    func testNewGenerationRejectsOldUpdatesAndTerminalClaims() {
        var coordinator = RecordingRunCoordinator()
        let oldGeneration = coordinator.begin()
        let currentGeneration = coordinator.begin()

        XCTAssertNotEqual(oldGeneration, currentGeneration)
        XCTAssertFalse(coordinator.acceptsUpdate(for: oldGeneration))
        XCTAssertEqual(
            coordinator.claimTerminal(.failure, for: oldGeneration),
            .staleGeneration
        )
        XCTAssertFalse(
            coordinator.ownsTerminal(.failure, for: oldGeneration)
        )

        XCTAssertTrue(coordinator.acceptsUpdate(for: currentGeneration))
        XCTAssertEqual(
            coordinator.claimTerminal(.stop, for: currentGeneration),
            .accepted
        )
    }

    func testBeginClearsTerminalClaimFromPreviousGeneration() {
        var coordinator = RecordingRunCoordinator()
        let firstGeneration = coordinator.begin()
        XCTAssertTrue(
            coordinator
                .claimTerminal(.failure, for: firstGeneration)
                .isAccepted
        )

        let secondGeneration = coordinator.begin()

        XCTAssertNil(coordinator.claimedTerminalPath)
        XCTAssertTrue(coordinator.acceptsUpdate(for: secondGeneration))
        XCTAssertFalse(coordinator.acceptsUpdate(for: firstGeneration))
    }

    func testRepeatedClaimReportsExistingOwnerWithoutChangingIt() {
        var coordinator = RecordingRunCoordinator()
        let generation = coordinator.begin()
        XCTAssertTrue(
            coordinator.claimTerminal(.stop, for: generation).isAccepted
        )

        XCTAssertEqual(
            coordinator.claimTerminal(.stop, for: generation),
            .alreadyClaimed(.stop)
        )
        XCTAssertEqual(coordinator.claimedTerminalPath, .stop)
    }
}
