import Foundation

/// The lifecycle of one microphone recording.
///
/// `RecordingSession` is intentionally a value type so it can be owned by an
/// actor, persisted, or transferred between Apple platforms without adding
/// shared mutable state to the core module.
public enum RecordingSessionState: String, Codable, CaseIterable, Sendable {
    case preparing
    case recording
    case paused
    case stopping
    case completed
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .preparing, .recording, .paused, .stopping:
            false
        }
    }

    public func canTransition(to destination: Self) -> Bool {
        switch (self, destination) {
        case (.preparing, .recording),
             (.preparing, .cancelled),
             (.preparing, .failed),
             (.recording, .paused),
             (.recording, .stopping),
             (.recording, .cancelled),
             (.recording, .failed),
             (.paused, .recording),
             (.paused, .stopping),
             (.paused, .cancelled),
             (.paused, .failed),
             (.stopping, .completed),
             (.stopping, .cancelled),
             (.stopping, .failed):
            true
        default:
            false
        }
    }
}

public struct RecordingSessionFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum RecordingSessionTransitionError: Error, Equatable, Sendable {
    case illegalTransition(
        from: RecordingSessionState,
        to: RecordingSessionState
    )
    case timestampBeforeCreation
    case timestampMovedBackwards
    case failureRequired
    case unexpectedFailure
}

/// Serializable state for a single recording session.
public struct RecordingSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let localeIdentifier: String
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var state: RecordingSessionState
    public private(set) var failure: RecordingSessionFailure?

    public init(
        id: UUID = UUID(),
        localeIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.localeIdentifier = localeIdentifier
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.startedAt = nil
        self.endedAt = nil
        self.state = .preparing
        self.failure = nil
    }

    /// Applies one validated lifecycle transition.
    ///
    /// A failure is required only when entering `.failed`. Timestamps are
    /// monotonic so records remain suitable for crash recovery and diagnostics.
    public mutating func transition(
        to destination: RecordingSessionState,
        at timestamp: Date = Date(),
        failure suppliedFailure: RecordingSessionFailure? = nil
    ) throws {
        guard state.canTransition(to: destination) else {
            throw RecordingSessionTransitionError.illegalTransition(
                from: state,
                to: destination
            )
        }
        guard timestamp >= createdAt else {
            throw RecordingSessionTransitionError.timestampBeforeCreation
        }
        guard timestamp >= updatedAt else {
            throw RecordingSessionTransitionError.timestampMovedBackwards
        }

        if destination == .failed {
            guard suppliedFailure != nil else {
                throw RecordingSessionTransitionError.failureRequired
            }
        } else if suppliedFailure != nil {
            throw RecordingSessionTransitionError.unexpectedFailure
        }

        state = destination
        updatedAt = timestamp
        failure = suppliedFailure

        if destination == .recording, startedAt == nil {
            startedAt = timestamp
        }
        if destination.isTerminal {
            endedAt = timestamp
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case localeIdentifier
        case createdAt
        case updatedAt
        case startedAt
        case endedAt
        case state
        case failure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        localeIdentifier = try container.decode(
            String.self,
            forKey: .localeIdentifier
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        state = try container.decode(RecordingSessionState.self, forKey: .state)
        failure = try container.decodeIfPresent(
            RecordingSessionFailure.self,
            forKey: .failure
        )

        do {
            try validateDecodedState()
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid recording session: \(error)"
                )
            )
        }
    }

    private func validateDecodedState() throws {
        guard updatedAt >= createdAt else {
            throw RecordingSessionTransitionError.timestampMovedBackwards
        }
        if let startedAt {
            guard startedAt >= createdAt, startedAt <= updatedAt else {
                throw RecordingSessionTransitionError.timestampMovedBackwards
            }
        }
        if let endedAt {
            guard endedAt >= createdAt, endedAt <= updatedAt else {
                throw RecordingSessionTransitionError.timestampMovedBackwards
            }
        }

        switch state {
        case .preparing:
            guard startedAt == nil, endedAt == nil else {
                throw RecordingSessionTransitionError.illegalTransition(
                    from: .preparing,
                    to: .preparing
                )
            }
        case .recording, .paused, .stopping:
            guard startedAt != nil, endedAt == nil else {
                throw RecordingSessionTransitionError.illegalTransition(
                    from: state,
                    to: state
                )
            }
        case .completed:
            guard startedAt != nil, endedAt != nil else {
                throw RecordingSessionTransitionError.illegalTransition(
                    from: .completed,
                    to: .completed
                )
            }
        case .cancelled, .failed:
            guard endedAt != nil else {
                throw RecordingSessionTransitionError.illegalTransition(
                    from: state,
                    to: state
                )
            }
        }

        if state == .failed {
            guard failure != nil else {
                throw RecordingSessionTransitionError.failureRequired
            }
        } else {
            guard failure == nil else {
                throw RecordingSessionTransitionError.unexpectedFailure
            }
        }
    }
}
