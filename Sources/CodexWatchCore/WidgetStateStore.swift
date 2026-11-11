import Foundation

public enum CodexWatchWidgetConstants {
    public static let kind = "CodexWatchPetWidget"
    public static var kinds: [String] { WatchCollaborationComponent.allCases.map(\.widgetKind) }
    public static let appGroupIdentifier = "group.com.tidux.CodexWatchPet"
}

public struct WidgetStateStore {
    private static let stateKey = "codexWatchPet.bridgeState"
    private static let savedAtKey = "codexWatchPet.bridgeStateSavedAt"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? WidgetStateStore.makeDefaultUserDefaults()
    }

    public func save(_ state: BridgeState) throws {
        let data = try JSONEncoder.codexWatchPet.encode(state)
        defaults.set(data, forKey: Self.stateKey)
        defaults.set(Date(), forKey: Self.savedAtKey)
        defaults.synchronize()
    }

    public func load() -> BridgeState? {
        guard let data = defaults.data(forKey: Self.stateKey) else {
            return nil
        }
        return try? JSONDecoder.codexWatchPet.decode(BridgeState.self, from: data)
    }

    public func savedAt() -> Date? {
        defaults.object(forKey: Self.savedAtKey) as? Date
    }

    public func clear() {
        defaults.removeObject(forKey: Self.stateKey)
        defaults.removeObject(forKey: Self.savedAtKey)
        defaults.synchronize()
    }

    private static func makeDefaultUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: CodexWatchWidgetConstants.appGroupIdentifier) ?? .standard
    }
}

public extension BridgeState {
    var widgetSnapshot: TaskSnapshot? {
        let sorted = snapshots.sortedByAttention()
        if let actionable = sorted.first(where: { $0.pendingRequest != nil || $0.status == .waitingForInput || $0.status == .waitingForApproval }) {
            return actionable
        }
        if let unsnoozedAttention = sorted.first(where: { $0.needsAttention && !$0.isSnoozed }) {
            return unsnoozedAttention
        }
        if let unsnoozed = sorted.first(where: { !$0.isSnoozed }) {
            return unsnoozed
        }
        return sorted.first
    }
}

public struct WidgetSnapshotPresentation: Equatable, Sendable {
    public var symbolName: String
    public var title: String
    public var detail: String
    public var status: String
    public var shortStatus: String
    public var isSnoozed: Bool

    public init(
        symbolName: String,
        title: String,
        detail: String,
        status: String,
        shortStatus: String,
        isSnoozed: Bool
    ) {
        self.symbolName = symbolName
        self.title = title
        self.detail = detail
        self.status = status
        self.shortStatus = shortStatus
        self.isSnoozed = isSnoozed
    }
}

public extension TaskSnapshot {
    func widgetPresentation(savedAt: Date?, now: Date = Date()) -> WidgetSnapshotPresentation {
        let freshness = SyncFreshness(savedAt: savedAt, now: now)
        let snoozed = isSnoozed(at: now)
        let baseDetail = widgetBaseDetail(now: now)
        let detail = freshness.isStale ? "\(freshness.displayName) - \(baseDetail)" : baseDetail
        let status = widgetStatusName(snoozed: snoozed, freshness: freshness)
        let shortStatus = freshness.status == .stale ? freshness.shortDisplayName : widgetShortStatusName(snoozed: snoozed)

        return WidgetSnapshotPresentation(
            symbolName: snoozed ? "bell.slash" : petMood.symbolName,
            title: title,
            detail: detail,
            status: status,
            shortStatus: shortStatus,
            isSnoozed: snoozed
        )
    }

    private func widgetBaseDetail(now: Date) -> String {
        if let pendingRequest {
            return pendingRequest.summary
        }
        if let snoozedUntil, snoozedUntil > now {
            return "Snoozed \(snoozedUntil.timeIntervalSince(now).widgetDurationLabel) - \(lastSummary)"
        }
        return lastSummary
    }

    private func widgetStatusName(snoozed: Bool, freshness: SyncFreshness) -> String {
        let statusName = snoozed ? "Snoozed" : status.displayName
        return freshness.isStale ? "\(statusName) - \(freshness.shortDisplayName)" : statusName
    }

    private func widgetShortStatusName(snoozed: Bool) -> String {
        if snoozed {
            return "Soon"
        }
        switch status {
        case .idle: return "Idle"
        case .active: return "Run"
        case .runningTool: return "Tool"
        case .waitingForInput: return "Input"
        case .waitingForApproval: return "OK?"
        case .completed: return "Done"
        case .failed: return "Fail"
        case .offline: return "Off"
        }
    }
}

private extension TimeInterval {
    var widgetDurationLabel: String {
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
