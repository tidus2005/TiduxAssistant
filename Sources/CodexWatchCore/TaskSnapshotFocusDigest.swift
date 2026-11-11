import Foundation

public struct TaskFocusDigestItem: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct TaskFocusDigest: Hashable, Sendable {
    public var headline: String
    public var detail: String
    public var items: [TaskFocusDigestItem]

    public init(headline: String, detail: String, items: [TaskFocusDigestItem]) {
        self.headline = headline
        self.detail = detail
        self.items = items
    }
}

public extension TaskSnapshot {
    func focusDigest(now: Date = Date()) -> TaskFocusDigest {
        var items = [
            TaskFocusDigestItem(label: "Status", value: status.displayName)
        ]

        if let pendingRequest {
            items.append(TaskFocusDigestItem(label: "Needs", value: pendingRequest.requiredAction.focusDigestName))
            items.append(TaskFocusDigestItem(label: "Request", value: pendingRequest.id.shortFocusIdentifier))
            items.append(TaskFocusDigestItem(label: "Waiting", value: pendingRequest.createdAt.elapsedLabel(until: now)))
            items.append(contentsOf: pendingRequest.focusMetadataItems)
        }

        if let elapsedSeconds {
            items.append(TaskFocusDigestItem(label: "Runtime", value: elapsedSeconds.durationLabel))
        }

        if let tokensUsed {
            items.append(TaskFocusDigestItem(label: "Tokens", value: tokensUsed.compactCountLabel))
        }

        if let estimatedCostUSD {
            items.append(TaskFocusDigestItem(label: "Cost", value: "$\(estimatedCostUSD.compactMoneyLabel)"))
        }

        if let folderName = cwd.focusFolderName {
            items.append(TaskFocusDigestItem(label: "Folder", value: folderName.shortFocusIdentifier))
        }

        if let snoozedUntil, snoozedUntil > now {
            items.append(TaskFocusDigestItem(label: "Snoozed", value: snoozedUntil.timeIntervalSince(now).durationLabel))
        }

        return TaskFocusDigest(
            headline: pendingRequest?.title.nonBlank ?? status.displayName,
            detail: pendingRequest?.summary.nonBlank ?? lastSummary.nonBlank ?? "No recent Codex detail.",
            items: Array(items.prefix(9))
        )
    }
}

private extension PendingRequest {
    var focusMetadataItems: [TaskFocusDigestItem] {
        var items: [TaskFocusDigestItem] = []

        if let requestKind = metadata["requestKind"]?.requestKindLabel {
            items.append(TaskFocusDigestItem(label: "Type", value: requestKind))
            if metadata["requestKind"] == "fileChangeApproval" {
                items.append(TaskFocusDigestItem(label: "Risk", value: "File changes"))
            }
        }
        if let grantRoot = metadata["grantRoot"]?.focusPathLabel {
            items.append(TaskFocusDigestItem(label: "Scope", value: grantRoot))
        }
        if let command = metadata["command"]?.singleLineFocus {
            items.append(TaskFocusDigestItem(label: "Command", value: command.shortFocusIdentifier))
        }
        if let cwd = metadata["cwd"]?.focusPathLabel {
            items.append(TaskFocusDigestItem(label: "CWD", value: cwd))
        }
        if let questionIds = metadata["questionIds"]?.singleLineFocus {
            items.append(TaskFocusDigestItem(label: "Questions", value: questionIds.shortFocusIdentifier))
        }
        if let approvalId = metadata["approvalId"]?.singleLineFocus {
            items.append(TaskFocusDigestItem(label: "Approval", value: approvalId.shortFocusIdentifier))
        }

        return items
    }
}

private extension BridgeActionKind {
    var focusDigestName: String {
        switch self {
        case .reply:
            "Reply"
        case .continueThread:
            "Continue"
        case .approve:
            "Approve"
        case .decline:
            "Decline"
        case .cancel:
            "Cancel"
        case .interrupt:
            "Stop"
        case .openOnMac:
            "Open Mac"
        case .snooze:
            "Snooze"
        case .startThread:
            "Start"
        }
    }
}

private extension Date {
    func elapsedLabel(until date: Date) -> String {
        max(0, date.timeIntervalSince(self)).durationLabel
    }
}

private extension TimeInterval {
    var durationLabel: String {
        let totalSeconds = max(0, Int(rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}

private extension Int {
    var compactCountLabel: String {
        if self >= 1_000_000 {
            return "\(self / 1_000_000)m"
        }
        if self >= 1_000 {
            return "\(self / 1_000)k"
        }
        return "\(self)"
    }
}

private extension Decimal {
    var compactMoneyLabel: String {
        NSDecimalNumber(decimal: self).stringValue
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var focusFolderName: String? {
        guard let value = nonBlank else { return nil }
        let last = URL(fileURLWithPath: value).lastPathComponent
        return last.isEmpty ? value : last
    }

    var singleLineFocus: String? {
        nonBlank?.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    var requestKindLabel: String? {
        switch self {
        case "commandApproval":
            "Command"
        case "fileChangeApproval":
            "File change"
        case "userInput":
            "Input"
        default:
            singleLineFocus
        }
    }

    var focusPathLabel: String? {
        guard let value = nonBlank else { return nil }
        let url = URL(fileURLWithPath: value)
        let last = url.lastPathComponent
        if last.isEmpty {
            return value.shortFocusIdentifier
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        let label = parent.isEmpty ? last : "\(parent)/\(last)"
        return label.shortFocusIdentifier
    }

    var shortFocusIdentifier: String {
        guard count > 28 else { return self }
        return String(prefix(25)) + "..."
    }
}
