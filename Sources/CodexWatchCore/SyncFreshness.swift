import Foundation

public enum SyncFreshnessStatus: String, Codable, Equatable, Sendable {
    case noData
    case fresh
    case stale
}

public struct SyncFreshness: Equatable, Sendable {
    public var status: SyncFreshnessStatus
    public var ageSeconds: TimeInterval?
    public var staleAfterSeconds: TimeInterval

    public init(
        savedAt: Date?,
        now: Date = Date(),
        staleAfterSeconds: TimeInterval = 600
    ) {
        self.staleAfterSeconds = staleAfterSeconds
        guard let savedAt else {
            self.status = .noData
            self.ageSeconds = nil
            return
        }
        let age = max(0, now.timeIntervalSince(savedAt))
        self.ageSeconds = age
        self.status = age > staleAfterSeconds ? .stale : .fresh
    }

    public var isStale: Bool {
        status != .fresh
    }

    public var displayName: String {
        switch status {
        case .noData:
            "No sync yet"
        case .fresh:
            "Synced \(ageDisplayName)"
        case .stale:
            "Stale \(ageDisplayName)"
        }
    }

    public var shortDisplayName: String {
        switch status {
        case .noData:
            "No sync"
        case .fresh:
            ageShortDisplayName
        case .stale:
            "Old"
        }
    }

    public var symbolName: String {
        switch status {
        case .noData:
            "icloud.slash"
        case .fresh:
            "checkmark.icloud"
        case .stale:
            "clock.badge.exclamationmark"
        }
    }

    private var ageDisplayName: String {
        guard let ageSeconds else { return "" }
        if ageSeconds < 60 {
            return "now"
        }
        let minutes = Int(ageSeconds / 60)
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = max(1, minutes / 60)
        return "\(hours)h ago"
    }

    private var ageShortDisplayName: String {
        guard let ageSeconds else { return "No sync" }
        if ageSeconds < 60 {
            return "Now"
        }
        let minutes = Int(ageSeconds / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = max(1, minutes / 60)
        return "\(hours)h"
    }
}
