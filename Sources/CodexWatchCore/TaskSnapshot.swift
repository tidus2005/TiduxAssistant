import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case active
    case runningTool
    case waitingForInput
    case waitingForApproval
    case completed
    case failed
    case offline

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .active: "Active"
        case .runningTool: "Tool"
        case .waitingForInput: "Needs input"
        case .waitingForApproval: "Approval"
        case .completed: "Done"
        case .failed: "Failed"
        case .offline: "Offline"
        }
    }

    public var petMood: PetMood {
        switch self {
        case .idle: .idle
        case .active: .thinking
        case .runningTool: .tooling
        case .waitingForInput: .needsInput
        case .waitingForApproval: .needsApproval
        case .completed: .done
        case .failed: .failed
        case .offline: .offline
        }
    }
}

public struct PendingRequest: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var requiredAction: BridgeActionKind
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        title: String,
        summary: String,
        requiredAction: BridgeActionKind,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.requiredAction = requiredAction
        self.createdAt = createdAt
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case summary
        case requiredAction
        case createdAt
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.requiredAction = try container.decode(BridgeActionKind.self, forKey: .requiredAction)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

public struct TaskSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var threadId: String
    public var title: String
    public var cwd: String
    public var status: TaskStatus
    public var lastSummary: String
    public var pendingRequest: PendingRequest?
    public var elapsedSeconds: TimeInterval?
    public var tokensUsed: Int?
    public var estimatedCostUSD: Decimal?
    public var lastSyncedAt: Date
    public var updatedAt: Date
    public var petMood: PetMood
    public var urgency: Urgency
    public var snoozedUntil: Date?

    public init(
        id: String,
        threadId: String,
        title: String,
        cwd: String,
        status: TaskStatus,
        lastSummary: String,
        pendingRequest: PendingRequest? = nil,
        elapsedSeconds: TimeInterval? = nil,
        tokensUsed: Int? = nil,
        estimatedCostUSD: Decimal? = nil,
        lastSyncedAt: Date = Date(),
        updatedAt: Date = Date(),
        petMood: PetMood? = nil,
        urgency: Urgency,
        snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.title = title
        self.cwd = cwd
        self.status = status
        self.lastSummary = lastSummary
        self.pendingRequest = pendingRequest
        self.elapsedSeconds = elapsedSeconds
        self.tokensUsed = tokensUsed
        self.estimatedCostUSD = estimatedCostUSD
        self.lastSyncedAt = lastSyncedAt
        self.updatedAt = updatedAt
        self.petMood = petMood ?? status.petMood
        self.urgency = urgency
        self.snoozedUntil = snoozedUntil
    }
}

public struct BridgeState: Codable, Hashable, Sendable {
    public var snapshots: [TaskSnapshot]
    public var events: [BridgeEvent]
    public var unreadHighUrgencyCount: Int
    public var bridgeOnline: Bool
    public var pairStatus: PairStatus
    public var liveControlStatus: LiveControlStatus
    public var generatedAt: Date
    public var bridgeIdentity: String?
    public var commandReceiptsSupported: Bool

    public init(
        snapshots: [TaskSnapshot],
        events: [BridgeEvent],
        unreadHighUrgencyCount: Int,
        bridgeOnline: Bool,
        pairStatus: PairStatus,
        liveControlStatus: LiveControlStatus = .disabled,
        generatedAt: Date = Date(),
        bridgeIdentity: String? = nil,
        commandReceiptsSupported: Bool = false
    ) {
        self.snapshots = snapshots
        self.events = events
        self.unreadHighUrgencyCount = unreadHighUrgencyCount
        self.bridgeOnline = bridgeOnline
        self.pairStatus = pairStatus
        self.liveControlStatus = liveControlStatus
        self.generatedAt = generatedAt
        self.bridgeIdentity = bridgeIdentity
        self.commandReceiptsSupported = commandReceiptsSupported
    }

    private enum CodingKeys: String, CodingKey {
        case snapshots
        case events
        case unreadHighUrgencyCount
        case bridgeOnline
        case pairStatus
        case liveControlStatus
        case generatedAt
        case bridgeIdentity, commandReceiptsSupported
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.snapshots = try container.decode([TaskSnapshot].self, forKey: .snapshots)
        self.events = try container.decode([BridgeEvent].self, forKey: .events)
        self.unreadHighUrgencyCount = try container.decode(Int.self, forKey: .unreadHighUrgencyCount)
        self.bridgeOnline = try container.decode(Bool.self, forKey: .bridgeOnline)
        self.pairStatus = try container.decode(PairStatus.self, forKey: .pairStatus)
        self.liveControlStatus = try container.decodeIfPresent(LiveControlStatus.self, forKey: .liveControlStatus) ?? .disabled
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.bridgeIdentity = try container.decodeIfPresent(String.self, forKey: .bridgeIdentity)
        self.commandReceiptsSupported = try container.decodeIfPresent(Bool.self, forKey: .commandReceiptsSupported) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snapshots, forKey: .snapshots)
        try container.encode(events, forKey: .events)
        try container.encode(unreadHighUrgencyCount, forKey: .unreadHighUrgencyCount)
        try container.encode(bridgeOnline, forKey: .bridgeOnline)
        try container.encode(pairStatus, forKey: .pairStatus)
        try container.encode(liveControlStatus, forKey: .liveControlStatus)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(bridgeIdentity, forKey: .bridgeIdentity)
        try container.encode(commandReceiptsSupported, forKey: .commandReceiptsSupported)
    }
}

public struct PairStatus: Codable, Hashable, Sendable {
    public var paired: Bool
    public var deviceName: String?
    public var tokenPreview: String?
    public var pairedAt: Date?

    public init(paired: Bool, deviceName: String? = nil, tokenPreview: String? = nil, pairedAt: Date? = nil) {
        self.paired = paired
        self.deviceName = deviceName
        self.tokenPreview = tokenPreview
        self.pairedAt = pairedAt
    }
}

public extension TaskSnapshot {
    static var sampleActive: TaskSnapshot {
        TaskSnapshot(
            id: "sample-active",
            threadId: "thread-active",
            title: "Design Apple Watch assistant",
            cwd: "/Users/example/myapps",
            status: .active,
            lastSummary: "Codex is implementing the bridge and watch UI.",
            tokensUsed: 42_000,
            urgency: .medium
        )
    }

    static var sampleApproval: TaskSnapshot {
        TaskSnapshot(
            id: "sample-approval",
            threadId: "thread-approval",
            title: "Ship local bridge",
            cwd: "/Users/example/myapps/CodexWatchPet",
            status: .waitingForApproval,
            lastSummary: "A command needs approval before continuing.",
            pendingRequest: PendingRequest(
                title: "Approve command",
                summary: "Run bridge integration test with local Codex data.",
                requiredAction: .approve
            ),
            urgency: .high
        )
    }

    static var sampleInput: TaskSnapshot {
        TaskSnapshot(
            id: "sample-input",
            threadId: "thread-input",
            title: "Clarify launch scope",
            cwd: "/Users/example/myapps/CodexWatchPet",
            status: .waitingForInput,
            lastSummary: "Codex needs a decision before continuing.",
            pendingRequest: PendingRequest(
                title: "Missing input",
                summary: "Choose whether to prioritize the Watch app, complication, or Mac bridge.",
                requiredAction: .reply
            ),
            urgency: .high
        )
    }
}
