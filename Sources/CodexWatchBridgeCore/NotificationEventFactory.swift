import CodexWatchCore
import Foundation

public struct NotificationEventFactory: Sendable {
    public init() {}

    public func event(
        from payload: CodexNotificationPayload,
        fallbackSnapshot: TaskSnapshot?,
        sequence: Int64
    ) -> BridgeEvent {
        let kind = payload.kind.lowercased()
        let type: BridgeEventType
        let urgency: Urgency
        let mood: PetMood

        if kind.contains("fail") || kind.contains("error") {
            type = .turnFailed
            urgency = .high
            mood = .failed
        } else if kind.contains("approval") || kind.contains("permission") {
            type = .approvalRequested
            urgency = .high
            mood = .needsApproval
        } else if kind.contains("input") || kind.contains("blocked") || kind.contains("question") {
            type = .inputRequested
            urgency = .high
            mood = .needsInput
        } else if kind.contains("end") || kind.contains("complete") || kind.contains("done") {
            type = .turnCompleted
            urgency = .medium
            mood = .done
        } else {
            type = .turnProgress
            urgency = .medium
            mood = .thinking
        }

        let title = payload.title?.nonBlank
            ?? fallbackSnapshot?.title
            ?? "Codex update"
        let summary = payload.summary?.nonBlank
            ?? payload.rawStdin?.nonBlank
            ?? fallbackSnapshot?.lastSummary
            ?? "Codex reported \(payload.kind)."
        let threadId = payload.threadId?.nonBlank
            ?? fallbackSnapshot?.threadId
            ?? "codex-notify-\(payload.createdAt.timeIntervalSince1970)"

        return BridgeEvent(
            sequence: sequence,
            threadId: threadId,
            turnId: payload.turnId,
            type: type,
            title: title,
            summary: summary.trimmed(maxLength: 300),
            urgency: urgency,
            petMood: mood,
            actions: actions(for: type),
            createdAt: payload.createdAt
        )
    }

    private func actions(for type: BridgeEventType) -> [BridgeAction] {
        switch type {
        case .approvalRequested:
            [
                BridgeAction(kind: .approve, title: "Approve", summary: "Approve the pending Codex request.", requiresHoldConfirmation: true),
                BridgeAction(kind: .decline, title: "Decline", summary: "Decline the pending Codex request.", requiresHoldConfirmation: true, destructive: true)
            ]
        case .inputRequested:
            [
                BridgeAction(kind: .reply, title: "Reply", summary: "Send the missing information back to Codex.", requiresHoldConfirmation: true)
            ]
        case .turnCompleted, .turnFailed, .bridgeOffline:
            [
                BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac.")
            ]
        default:
            [
                BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac."),
                BridgeAction(kind: .snooze, title: "Snooze", summary: "Hide this update for now.")
            ]
        }
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func trimmed(maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength - 1)) + "..."
    }
}
