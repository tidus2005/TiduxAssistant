import Foundation
import XCTest
@testable import CodexMobilityCore

final class RollingSegmentFilesTests: XCTestCase {
    private let sessionID = UUID(
        uuidString: "44444444-4444-4444-4444-444444444444"
    )!

    func testCanonicalCommittedAndPartialNamesRoundTrip() throws {
        let committedName = try RollingSegmentFileNaming.fileName(
            sessionID: sessionID,
            sequenceNumber: 42,
            fileExtension: "caf",
            state: .committed
        )
        let partialName = try RollingSegmentFileNaming.fileName(
            sessionID: sessionID,
            sequenceNumber: 42,
            fileExtension: "caf",
            state: .partial
        )

        XCTAssertEqual(
            committedName,
            "flowtype.44444444-4444-4444-4444-444444444444.000000000042.caf"
        )
        XCTAssertEqual(partialName, committedName + ".partial")
        XCTAssertEqual(
            RollingSegmentFileNaming.parse(committedName),
            RollingSegmentFile(
                sessionID: sessionID,
                sequenceNumber: 42,
                fileExtension: "caf",
                state: .committed,
                fileName: committedName
            )
        )
        XCTAssertEqual(
            RollingSegmentFileNaming.parse(partialName)?.state,
            .partial
        )
    }

    func testInvalidNamesAndExtensionsAreRejected() {
        XCTAssertThrowsError(
            try RollingSegmentFileNaming.fileName(
                sessionID: sessionID,
                sequenceNumber: 0,
                fileExtension: "../caf",
                state: .committed
            )
        )
        XCTAssertThrowsError(
            try RollingSegmentFileNaming.fileName(
                sessionID: sessionID,
                sequenceNumber:
                    RollingSegmentFileNaming.maximumSequenceNumber + 1,
                fileExtension: "caf",
                state: .committed
            )
        )
        XCTAssertNil(
            RollingSegmentFileNaming.parse(
                "/tmp/flowtype.44444444-4444-4444-4444-444444444444." +
                    "000000000000.caf"
            )
        )
        XCTAssertNil(
            RollingSegmentFileNaming.parse(
                "flowtype.44444444-4444-4444-4444-444444444444.0.caf"
            )
        )
    }

    func testRecoveryManifestOrdersFilesAndReportsGaps() throws {
        let zero = try name(sequence: 0, state: .committed)
        let staleZero = try name(sequence: 0, state: .partial)
        let two = try name(sequence: 2, state: .partial)
        let five = try name(sequence: 5, state: .committed)
        let otherSession = try RollingSegmentFileNaming.fileName(
            sessionID: UUID(
                uuidString: "55555555-5555-5555-5555-555555555555"
            )!,
            sequenceNumber: 0,
            fileExtension: "caf",
            state: .committed
        )

        let manifest = try RollingSegmentRecoveryManifest.build(
            fileNames: [
                five,
                "notes.txt",
                two,
                staleZero,
                zero,
                zero,
                otherSession,
            ],
            sessionID: sessionID,
            fileExtension: "caf"
        )

        XCTAssertEqual(
            manifest.committedFiles.map(\.sequenceNumber),
            [0, 5]
        )
        XCTAssertEqual(
            manifest.incompleteFiles.map(\.sequenceNumber),
            [2]
        )
        XCTAssertEqual(manifest.stalePartialFileNames, [staleZero])
        XCTAssertEqual(manifest.duplicateSequenceNumbers, [0])
        XCTAssertEqual(
            manifest.missingSequenceRanges,
            [
                SegmentSequenceRange(lowerBound: 1, upperBound: 1),
                SegmentSequenceRange(lowerBound: 3, upperBound: 4),
            ]
        )
        XCTAssertEqual(
            manifest.ignoredFileNames,
            [otherSession, "notes.txt"].sorted()
        )
        XCTAssertEqual(manifest.nextSequenceNumber, 6)
        XCTAssertFalse(manifest.isContiguous)
    }

    func testEmptyRecoveryManifestStartsAtZero() throws {
        let manifest = try RollingSegmentRecoveryManifest.build(
            fileNames: [],
            sessionID: sessionID,
            fileExtension: "caf"
        )

        XCTAssertEqual(manifest.nextSequenceNumber, 0)
        XCTAssertTrue(manifest.committedFiles.isEmpty)
        XCTAssertTrue(manifest.incompleteFiles.isEmpty)
        XCTAssertTrue(manifest.missingSequenceRanges.isEmpty)
        XCTAssertTrue(manifest.isContiguous)
    }

    func testManifestIsDeterministicForInputOrder() throws {
        let zero = try name(sequence: 0, state: .committed)
        let one = try name(sequence: 1, state: .partial)

        let forward = try RollingSegmentRecoveryManifest.build(
            fileNames: [zero, one, "ignored"],
            sessionID: sessionID,
            fileExtension: "caf"
        )
        let reverse = try RollingSegmentRecoveryManifest.build(
            fileNames: ["ignored", one, zero],
            sessionID: sessionID,
            fileExtension: "caf"
        )

        XCTAssertEqual(forward, reverse)
    }

    func testMaximumSequenceHasNoNextFileName() throws {
        let maximum = try name(
            sequence: RollingSegmentFileNaming.maximumSequenceNumber,
            state: .committed
        )

        let manifest = try RollingSegmentRecoveryManifest.build(
            fileNames: [maximum],
            sessionID: sessionID,
            fileExtension: "caf"
        )

        XCTAssertNil(manifest.nextSequenceNumber)
    }

    private func name(
        sequence: UInt64,
        state: RollingSegmentFileState
    ) throws -> String {
        try RollingSegmentFileNaming.fileName(
            sessionID: sessionID,
            sequenceNumber: sequence,
            fileExtension: "caf",
            state: state
        )
    }
}
