import Foundation

public struct TaskStateReducer: Sendable {
    public init() {}

    public func reduce(snapshots: [TaskSnapshot], event: BridgeEvent) -> [TaskSnapshot] {
        var indexed = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.threadId, $0) })
        let current = indexed[event.threadId]
        let status = status(for: event.type)
        let pending = pendingRequest(for: event)

        indexed[event.threadId] = TaskSnapshot(
            id: current?.id ?? event.threadId,
            threadId: event.threadId,
            title: event.title.isEmpty ? (current?.title ?? "Codex task") : event.title,
            cwd: current?.cwd ?? "",
            status: status,
            lastSummary: event.summary,
            pendingRequest: pending,
            elapsedSeconds: current?.elapsedSeconds,
            tokensUsed: current?.tokensUsed,
            estimatedCostUSD: current?.estimatedCostUSD,
            lastSyncedAt: Date(),
            updatedAt: event.createdAt,
            petMood: event.petMood,
            urgency: event.urgency
        )

        return indexed.values.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency {
                return lhs.urgency > rhs.urgency
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func status(for type: BridgeEventType) -> TaskStatus {
        switch type {
        case .threadStarted, .turnProgress:
            .active
        case .approvalRequested:
            .waitingForApproval
        case .inputRequested:
            .waitingForInput
        case .turnCompleted:
            .completed
        case .turnFailed:
            .failed
        case .bridgeOffline:
            .offline
        }
    }

    private func pendingRequest(for event: BridgeEvent) -> PendingRequest? {
        switch event.type {
        case .approvalRequested:
            PendingRequest(id: pendingRequestId(from: event), title: event.title, summary: event.summary, requiredAction: .approve, createdAt: event.createdAt)
        case .inputRequested:
            PendingRequest(id: pendingRequestId(from: event), title: event.title, summary: event.summary, requiredAction: .reply, createdAt: event.createdAt)
        default:
            nil
        }
    }

    private func pendingRequestId(from event: BridgeEvent) -> String {
        let prefix = "appserver-approval-"
        guard event.id.hasPrefix(prefix) else {
            return event.id
        }
        return String(event.id.dropFirst(prefix.count)).split(separator: "#", maxSplits: 1).first.map(String.init) ?? event.id
    }
}

public struct NotificationDecision: Equatable, Sendable {
    public var shouldNotify: Bool
    public var reason: String

    public init(shouldNotify: Bool, reason: String) {
        self.shouldNotify = shouldNotify
        self.reason = reason
    }
}

public struct NotificationPolicy: Sendable {
    public var progressCooldown: TimeInterval

    public init(progressCooldown: TimeInterval = 180) {
        self.progressCooldown = progressCooldown
    }

    public func decision(
        for event: BridgeEvent,
        previousEventForThread: BridgeEvent?,
        now: Date = Date()
    ) -> NotificationDecision {
        if event.urgency == .high {
            return NotificationDecision(shouldNotify: true, reason: "high urgency")
        }

        switch event.type {
        case .approvalRequested, .inputRequested:
            return NotificationDecision(shouldNotify: true, reason: "human action required")
        case .turnCompleted, .turnFailed:
            return NotificationDecision(shouldNotify: true, reason: "terminal state")
        case .turnProgress:
            guard let previousEventForThread else {
                return NotificationDecision(shouldNotify: true, reason: "first progress event")
            }
            let elapsed = now.timeIntervalSince(previousEventForThread.createdAt)
            return NotificationDecision(
                shouldNotify: elapsed >= progressCooldown,
                reason: elapsed >= progressCooldown ? "cooldown elapsed" : "progress throttled"
            )
        case .threadStarted:
            return NotificationDecision(shouldNotify: event.urgency != .low, reason: "thread started")
        case .bridgeOffline:
            return NotificationDecision(shouldNotify: true, reason: "bridge offline")
        }
    }
}

public struct PlannedNotification: Equatable, Sendable {
    public var event: BridgeEvent
    public var decision: NotificationDecision

    public init(event: BridgeEvent, decision: NotificationDecision) {
        self.event = event
        self.decision = decision
    }
}

public struct NotificationPlannerState: Equatable, Sendable {
    public var seenEventIds: Set<String>
    public var lastNotifiedEventByThread: [String: BridgeEvent]

    public init(
        seenEventIds: Set<String> = [],
        lastNotifiedEventByThread: [String: BridgeEvent] = [:]
    ) {
        self.seenEventIds = seenEventIds
        self.lastNotifiedEventByThread = lastNotifiedEventByThread
    }
}

public struct NotificationPlanResult: Equatable, Sendable {
    public var notifications: [PlannedNotification]
    public var state: NotificationPlannerState

    public init(notifications: [PlannedNotification], state: NotificationPlannerState) {
        self.notifications = notifications
        self.state = state
    }
}

public struct NotificationPlanner: Sendable {
    public var policy: NotificationPolicy
    public var maxSeenEvents: Int

    public init(policy: NotificationPolicy = NotificationPolicy(), maxSeenEvents: Int = 500) {
        self.policy = policy
        self.maxSeenEvents = maxSeenEvents
    }

    public func plan(
        for events: [BridgeEvent],
        state: NotificationPlannerState,
        now: Date = Date()
    ) -> NotificationPlanResult {
        var nextState = state
        var notifications: [PlannedNotification] = []

        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            guard !nextState.seenEventIds.contains(event.id) else { continue }
            nextState.seenEventIds.insert(event.id)

            guard event.urgency != .low else { continue }

            let previous = nextState.lastNotifiedEventByThread[event.threadId]
            let decision = policy.decision(for: event, previousEventForThread: previous, now: now)
            guard decision.shouldNotify else { continue }

            notifications.append(PlannedNotification(event: event, decision: decision))
            nextState.lastNotifiedEventByThread[event.threadId] = event
        }

        if nextState.seenEventIds.count > maxSeenEvents {
            let recentEventIds = Set(events.sorted { $0.sequence > $1.sequence }.prefix(maxSeenEvents).map(\.id))
            nextState.seenEventIds = nextState.seenEventIds.intersection(recentEventIds)
        }

        return NotificationPlanResult(notifications: notifications, state: nextState)
    }
}
