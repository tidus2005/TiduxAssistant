import Foundation

public enum BridgeEventType: String, Codable, CaseIterable, Sendable {
    case threadStarted = "thread.started"
    case turnProgress = "turn.progress"
    case approvalRequested = "approval.requested"
    case inputRequested = "input.requested"
    case turnCompleted = "turn.completed"
    case turnFailed = "turn.failed"
    case bridgeOffline = "bridge.offline"
}

public enum BridgeCommandType: String, Codable, CaseIterable, Sendable {
    case startThread
    case continueThread
    case approve
    case decline
    case cancel
    case interrupt
    case openOnMac
    case snooze
}

public enum PetMood: String, Codable, CaseIterable, Sendable {
    case idle
    case thinking
    case tooling
    case needsInput
    case needsApproval
    case done
    case failed
    case offline

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .tooling: "Using tools"
        case .needsInput: "Needs input"
        case .needsApproval: "Needs approval"
        case .done: "Done"
        case .failed: "Failed"
        case .offline: "Offline"
        }
    }

    public var symbolName: String {
        switch self {
        case .idle: "sparkles"
        case .thinking: "brain.head.profile"
        case .tooling: "hammer"
        case .needsInput: "text.bubble"
        case .needsApproval: "checkmark.shield"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .offline: "wifi.slash"
        }
    }
}

public enum Urgency: String, Codable, CaseIterable, Comparable, Sendable {
    case low
    case medium
    case high

    public static func < (lhs: Urgency, rhs: Urgency) -> Bool {
        lhs.rank < rhs.rank
    }

    public var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}

public enum BridgeActionKind: String, Codable, CaseIterable, Sendable {
    case reply
    case continueThread
    case approve
    case decline
    case cancel
    case interrupt
    case openOnMac
    case snooze
    case startThread
}

public struct BridgeAction: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: BridgeActionKind
    public var title: String
    public var summary: String
    public var requiresHoldConfirmation: Bool
    public var destructive: Bool

    public init(
        id: String = UUID().uuidString,
        kind: BridgeActionKind,
        title: String,
        summary: String,
        requiresHoldConfirmation: Bool = false,
        destructive: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.requiresHoldConfirmation = requiresHoldConfirmation
        self.destructive = destructive
    }
}

public struct BridgeEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sequence: Int64
    public var threadId: String
    public var turnId: String?
    public var type: BridgeEventType
    public var title: String
    public var summary: String
    public var urgency: Urgency
    public var petMood: PetMood
    public var actions: [BridgeAction]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sequence: Int64,
        threadId: String,
        turnId: String? = nil,
        type: BridgeEventType,
        title: String,
        summary: String,
        urgency: Urgency,
        petMood: PetMood,
        actions: [BridgeAction],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sequence = sequence
        self.threadId = threadId
        self.turnId = turnId
        self.type = type
        self.title = title
        self.summary = summary
        self.urgency = urgency
        self.petMood = petMood
        self.actions = actions
        self.createdAt = createdAt
    }
}

public struct CommandConfirmation: Codable, Hashable, Sendable {
    public var confirmedAt: Date
    public var method: String
    public var displayedSummary: String
    public var riskAccepted: Bool

    public init(
        confirmedAt: Date = Date(),
        method: String = "hold",
        displayedSummary: String,
        riskAccepted: Bool
    ) {
        self.confirmedAt = confirmedAt
        self.method = method
        self.displayedSummary = displayedSummary
        self.riskAccepted = riskAccepted
    }
}

public struct BridgeCommand: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var type: BridgeCommandType
    public var threadId: String?
    public var turnId: String?
    public var payload: [String: String]
    public var clientNonce: String
    public var confirmation: CommandConfirmation?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        type: BridgeCommandType,
        threadId: String? = nil,
        turnId: String? = nil,
        payload: [String: String] = [:],
        clientNonce: String = UUID().uuidString,
        confirmation: CommandConfirmation? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.threadId = threadId
        self.turnId = turnId
        self.payload = payload
        self.clientNonce = clientNonce
        self.confirmation = confirmation
        self.createdAt = createdAt
    }
}

public struct CommandResult: Codable, Hashable, Sendable {
    public var commandId: String
    public var accepted: Bool
    public var message: String
    public var auditId: String?

    public init(commandId: String, accepted: Bool, message: String, auditId: String? = nil) {
        self.commandId = commandId
        self.accepted = accepted
        self.message = message
        self.auditId = auditId
    }
}

public enum LiveControlConnectionState: String, Codable, CaseIterable, Sendable {
    case disabled
    case connecting
    case connected
    case disconnected
}

public struct LiveControlStatus: Codable, Hashable, Sendable {
    public var state: LiveControlConnectionState
    public var pendingRequestCount: Int
    public var lastConnectedAt: Date?
    public var lastDisconnectedAt: Date?
    public var lastError: String?

    public init(
        state: LiveControlConnectionState,
        pendingRequestCount: Int = 0,
        lastConnectedAt: Date? = nil,
        lastDisconnectedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.state = state
        self.pendingRequestCount = pendingRequestCount
        self.lastConnectedAt = lastConnectedAt
        self.lastDisconnectedAt = lastDisconnectedAt
        self.lastError = lastError
    }

    public static var disabled: LiveControlStatus {
        LiveControlStatus(state: .disabled)
    }

    public var isDegraded: Bool {
        state == .connecting || state == .disconnected
    }

    public var displayName: String {
        switch state {
        case .disabled:
            "Live control off"
        case .connecting:
            "Live control connecting"
        case .connected:
            pendingRequestCount > 0 ? "Live control ready · \(pendingRequestCount)" : "Live control ready"
        case .disconnected:
            "Live control disconnected"
        }
    }

    public var symbolName: String {
        switch state {
        case .disabled:
            "wifi.slash"
        case .connecting:
            "arrow.triangle.2.circlepath"
        case .connected:
            "link"
        case .disconnected:
            "wifi.exclamationmark"
        }
    }
}
