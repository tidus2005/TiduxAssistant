import Foundation

public enum AttentionHapticKind: String, Codable, Equatable, Sendable {
    case notification
    case success
    case failure
}

public struct AttentionHapticPlannerState: Equatable, Sendable {
    public var seenEventIds: Set<String>

    public init(seenEventIds: Set<String> = []) {
        self.seenEventIds = seenEventIds
    }
}

public struct AttentionHapticPlanResult: Equatable, Sendable {
    public var haptic: AttentionHapticKind?
    public var state: AttentionHapticPlannerState

    public init(haptic: AttentionHapticKind?, state: AttentionHapticPlannerState) {
        self.haptic = haptic
        self.state = state
    }
}

public struct AttentionHapticPlanner: Sendable {
    public var maxSeenEvents: Int

    public init(maxSeenEvents: Int = 500) {
        self.maxSeenEvents = maxSeenEvents
    }

    public func plan(
        for events: [BridgeEvent],
        state: AttentionHapticPlannerState
    ) -> AttentionHapticPlanResult {
        plan(for: events, state: state, suppressingThreadIds: [])
    }

    public func plan(
        for events: [BridgeEvent],
        state: AttentionHapticPlannerState,
        suppressingThreadIds: Set<String>
    ) -> AttentionHapticPlanResult {
        var nextState = state
        var planned: AttentionHapticKind?

        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            guard !nextState.seenEventIds.contains(event.id) else { continue }
            nextState.seenEventIds.insert(event.id)
            if suppressingThreadIds.contains(event.threadId),
               event.type != .approvalRequested,
               event.type != .inputRequested {
                continue
            }
            guard let haptic = haptic(for: event) else { continue }
            planned = strongest(planned, haptic)
        }

        if nextState.seenEventIds.count > maxSeenEvents {
            let recentEventIds = Set(events.sorted { $0.sequence > $1.sequence }.prefix(maxSeenEvents).map(\.id))
            nextState.seenEventIds = nextState.seenEventIds.intersection(recentEventIds)
        }

        return AttentionHapticPlanResult(haptic: planned, state: nextState)
    }

    private func haptic(for event: BridgeEvent) -> AttentionHapticKind? {
        switch event.type {
        case .approvalRequested, .inputRequested:
            .notification
        case .turnCompleted:
            event.urgency == .low ? nil : .success
        case .turnFailed, .bridgeOffline:
            .failure
        case .threadStarted, .turnProgress:
            event.urgency == .high ? .notification : nil
        }
    }

    private func strongest(_ lhs: AttentionHapticKind?, _ rhs: AttentionHapticKind) -> AttentionHapticKind {
        guard let lhs else { return rhs }
        return priority(rhs) >= priority(lhs) ? rhs : lhs
    }

    private func priority(_ haptic: AttentionHapticKind) -> Int {
        switch haptic {
        case .success: 0
        case .notification: 1
        case .failure: 2
        }
    }
}
