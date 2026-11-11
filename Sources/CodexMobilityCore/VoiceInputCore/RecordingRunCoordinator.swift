/// Identifies the single code path that owns teardown for a recording run.
///
/// A successful stop can still decide to persist a failed session when one of
/// its own teardown steps throws. The important invariant is that only one
/// path performs terminal side effects for a generation.
public enum RecordingTerminalPath: Equatable {
    case stop
    case failure
}

/// The result of attempting to own terminal work for one recording generation.
public enum RecordingTerminalClaim: Equatable {
    case accepted
    case staleGeneration
    case alreadyClaimed(RecordingTerminalPath)

    public var isAccepted: Bool {
        self == .accepted
    }
}

/// Coordinates asynchronous callbacks belonging to successive recording runs.
///
/// This is deliberately a small value type. Its owner is responsible for
/// serializing mutation, which naturally fits a `@MainActor` app model.
///
/// Start each run with `begin()`, retain the returned generation in callbacks,
/// and gate those callbacks with `acceptsUpdate(for:)`. Before stop or failure
/// performs cleanup, it must first win `claimTerminal(_:for:)`.
public struct RecordingRunCoordinator {
    public typealias Generation = UInt64

    private var generationCounter: Generation = 0

    public private(set) var activeGeneration: Generation?
    public private(set) var claimedTerminalPath: RecordingTerminalPath?

    public init() {}

    /// Starts a new run and invalidates every callback from older runs.
    @discardableResult
    public mutating func begin() -> Generation {
        generationCounter &+= 1
        activeGeneration = generationCounter
        claimedTerminalPath = nil
        return generationCounter
    }

    /// Returns whether a non-terminal update still belongs to the active run.
    public func acceptsUpdate(for generation: Generation) -> Bool {
        activeGeneration == generation && claimedTerminalPath == nil
    }

    /// Attempts to become the only terminal path for the supplied generation.
    ///
    /// Generation validation happens first, so an old callback never observes
    /// or affects the terminal owner of a newer run.
    @discardableResult
    public mutating func claimTerminal(
        _ path: RecordingTerminalPath,
        for generation: Generation
    ) -> RecordingTerminalClaim {
        guard activeGeneration == generation else {
            return .staleGeneration
        }
        if let claimedTerminalPath {
            return .alreadyClaimed(claimedTerminalPath)
        }

        claimedTerminalPath = path
        return .accepted
    }

    /// Lets the winning path verify ownership after an asynchronous suspension.
    public func ownsTerminal(
        _ path: RecordingTerminalPath,
        for generation: Generation
    ) -> Bool {
        activeGeneration == generation && claimedTerminalPath == path
    }
}
