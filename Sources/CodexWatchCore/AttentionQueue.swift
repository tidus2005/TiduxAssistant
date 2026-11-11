import Foundation

public extension TaskSnapshot {
    var needsAttention: Bool {
        needsAttention(at: Date())
    }

    func needsAttention(at date: Date) -> Bool {
        if isSnoozed(at: date), pendingRequest == nil, status != .waitingForInput, status != .waitingForApproval {
            return false
        }

        return pendingRequest != nil
            || status == .waitingForInput
            || status == .waitingForApproval
            || status == .failed
            || status == .offline
            || urgency == .high
    }

    var isSnoozed: Bool {
        isSnoozed(at: Date())
    }

    func isSnoozed(at date: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > date
    }

    var attentionRank: Int {
        switch status {
        case .waitingForInput:
            70
        case .waitingForApproval:
            65
        case .failed:
            55
        case .offline:
            50
        case .runningTool:
            35
        case .active:
            30
        case .completed:
            10
        case .idle:
            0
        }
    }

    static func isHigherAttention(_ lhs: TaskSnapshot, than rhs: TaskSnapshot) -> Bool {
        if lhs.attentionRank != rhs.attentionRank {
            return lhs.attentionRank > rhs.attentionRank
        }
        if lhs.urgency != rhs.urgency {
            return lhs.urgency > rhs.urgency
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

public extension Collection where Element == TaskSnapshot {
    func sortedByAttention() -> [TaskSnapshot] {
        sorted { TaskSnapshot.isHigherAttention($0, than: $1) }
    }

    func attentionQueue(limit: Int = 4) -> [TaskSnapshot] {
        Array(
            sortedByAttention()
                .filter(\.needsAttention)
                .prefix(Swift.max(0, limit))
        )
    }
}

public extension BridgeState {
    func latestPendingRequest(requiring action: BridgeActionKind) -> TaskSnapshot? {
        snapshots
            .filter { $0.pendingRequest?.requiredAction == action }
            .sortedByAttention()
            .first
    }
}
