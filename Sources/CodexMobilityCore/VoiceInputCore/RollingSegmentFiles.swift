import Foundation

public enum RollingSegmentFileState: String, Codable, Sendable {
    case committed
    case partial
}

public struct RollingSegmentFile: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let sequenceNumber: UInt64
    public let fileExtension: String
    public let state: RollingSegmentFileState
    public let fileName: String
}

public enum RollingSegmentFileNameError: Error, Equatable, Sendable {
    case invalidFileExtension
    case sequenceNumberTooLarge
}

/// Canonical, path-independent naming for rolling recording files.
///
/// Examples:
/// - `flowtype.<uuid>.000000000000.caf`
/// - `flowtype.<uuid>.000000000000.caf.partial`
public enum RollingSegmentFileNaming {
    public static let maximumSequenceNumber: UInt64 = 999_999_999_999

    public static func fileName(
        sessionID: UUID,
        sequenceNumber: UInt64,
        fileExtension: String,
        state: RollingSegmentFileState
    ) throws -> String {
        guard isValid(fileExtension: fileExtension) else {
            throw RollingSegmentFileNameError.invalidFileExtension
        }
        guard sequenceNumber <= maximumSequenceNumber else {
            throw RollingSegmentFileNameError.sequenceNumberTooLarge
        }

        let sequence = String(
            format: "%012llu",
            sequenceNumber
        )
        let base = [
            "flowtype",
            sessionID.uuidString.lowercased(),
            sequence,
            fileExtension.lowercased(),
        ].joined(separator: ".")
        return state == .partial ? base + ".partial" : base
    }

    public static func parse(_ fileName: String) -> RollingSegmentFile? {
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent else {
            return nil
        }

        let parts = fileName.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 4 || parts.count == 5 else { return nil }
        guard parts[0] == "flowtype" else { return nil }
        guard
            let sessionID = UUID(uuidString: String(parts[1])),
            String(parts[1]) == sessionID.uuidString.lowercased()
        else {
            return nil
        }

        let sequenceText = String(parts[2])
        guard
            sequenceText.count == 12,
            sequenceText.allSatisfy(\.isNumber),
            let sequenceNumber = UInt64(sequenceText),
            sequenceNumber <= maximumSequenceNumber
        else {
            return nil
        }

        let fileExtension = String(parts[3])
        guard
            fileExtension == fileExtension.lowercased(),
            isValid(fileExtension: fileExtension)
        else {
            return nil
        }

        let state: RollingSegmentFileState
        if parts.count == 5 {
            guard parts[4] == "partial" else { return nil }
            state = .partial
        } else {
            state = .committed
        }

        return RollingSegmentFile(
            sessionID: sessionID,
            sequenceNumber: sequenceNumber,
            fileExtension: fileExtension,
            state: state,
            fileName: fileName
        )
    }

    private static func isValid(fileExtension: String) -> Bool {
        (1 ... 12).contains(fileExtension.count) &&
            fileExtension.unicodeScalars.allSatisfy {
                CharacterSet.lowercaseLetters.contains($0) ||
                    CharacterSet.decimalDigits.contains($0)
            }
    }
}

public struct SegmentSequenceRange: Codable, Equatable, Sendable {
    public let lowerBound: UInt64
    public let upperBound: UInt64

    public init(lowerBound: UInt64, upperBound: UInt64) {
        precondition(lowerBound <= upperBound)
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

/// A deterministic plan for recovering a directory of rolling segment files.
///
/// The builder takes file names instead of touching the file system. Callers
/// decide whether incomplete files should be resumed, finalized, or discarded.
public struct RollingSegmentRecoveryManifest:
    Codable,
    Equatable,
    Sendable
{
    public let sessionID: UUID
    public let fileExtension: String
    public let committedFiles: [RollingSegmentFile]
    public let incompleteFiles: [RollingSegmentFile]
    public let stalePartialFileNames: [String]
    public let duplicateSequenceNumbers: [UInt64]
    public let missingSequenceRanges: [SegmentSequenceRange]
    public let ignoredFileNames: [String]
    public let nextSequenceNumber: UInt64?

    public var isContiguous: Bool {
        missingSequenceRanges.isEmpty
    }

    public static func build(
        fileNames: [String],
        sessionID: UUID,
        fileExtension: String
    ) throws -> Self {
        _ = try RollingSegmentFileNaming.fileName(
            sessionID: sessionID,
            sequenceNumber: 0,
            fileExtension: fileExtension,
            state: .committed
        )
        let normalizedExtension = fileExtension.lowercased()
        var matching: [RollingSegmentFile] = []
        var ignored: [String] = []

        for fileName in fileNames {
            guard
                let parsed = RollingSegmentFileNaming.parse(fileName),
                parsed.sessionID == sessionID,
                parsed.fileExtension == normalizedExtension
            else {
                ignored.append(fileName)
                continue
            }
            matching.append(parsed)
        }

        let grouped = Dictionary(grouping: matching, by: \.sequenceNumber)
        var committed: [RollingSegmentFile] = []
        var incomplete: [RollingSegmentFile] = []
        var stalePartials: [String] = []
        var duplicates: [UInt64] = []

        for sequence in grouped.keys.sorted() {
            guard let files = grouped[sequence] else { continue }
            let committedCandidates = files
                .filter { $0.state == .committed }
                .sorted { $0.fileName < $1.fileName }
            let partialCandidates = files
                .filter { $0.state == .partial }
                .sorted { $0.fileName < $1.fileName }

            if let winner = committedCandidates.first {
                committed.append(winner)
                stalePartials.append(contentsOf: partialCandidates.map(\.fileName))
                if committedCandidates.count + partialCandidates.count > 1 {
                    duplicates.append(sequence)
                }
            } else if let winner = partialCandidates.first {
                incomplete.append(winner)
                if partialCandidates.count > 1 {
                    duplicates.append(sequence)
                    stalePartials.append(
                        contentsOf: partialCandidates.dropFirst().map(\.fileName)
                    )
                }
            }
        }

        let sequences = grouped.keys.sorted()
        let missingRanges = missingRanges(in: sequences)
        let nextSequence: UInt64?
        if let maximum = sequences.last {
            nextSequence = maximum ==
                RollingSegmentFileNaming.maximumSequenceNumber
                ? nil
                : maximum + 1
        } else {
            nextSequence = 0
        }

        return Self(
            sessionID: sessionID,
            fileExtension: normalizedExtension,
            committedFiles: committed,
            incompleteFiles: incomplete,
            stalePartialFileNames: stalePartials.sorted(),
            duplicateSequenceNumbers: duplicates,
            missingSequenceRanges: missingRanges,
            ignoredFileNames: ignored.sorted(),
            nextSequenceNumber: nextSequence
        )
    }

    private static func missingRanges(
        in sequences: [UInt64]
    ) -> [SegmentSequenceRange] {
        guard let maximum = sequences.last, maximum > 0 else { return [] }

        var result: [SegmentSequenceRange] = []
        var expected: UInt64 = 0
        for sequence in sequences {
            if sequence > expected {
                result.append(
                    SegmentSequenceRange(
                        lowerBound: expected,
                        upperBound: sequence - 1
                    )
                )
            }
            if sequence < maximum {
                expected = sequence + 1
            }
        }
        return result
    }
}
