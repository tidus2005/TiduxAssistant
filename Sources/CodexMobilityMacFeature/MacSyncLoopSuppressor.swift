import Foundation

public actor MacSyncLoopSuppressor {
    private struct Entry: Sendable {
        var sha256: String
        var expiresAt: Date
    }

    public static let defaultLifetime: TimeInterval = 10 * 60

    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]

    public init(lifetime: TimeInterval = MacSyncLoopSuppressor.defaultLifetime) {
        self.lifetime = max(lifetime, 1)
    }

    public func record(relativePath: String, sha256: String, now: Date = Date()) {
        purgeExpired(at: now)
        entries[relativePath] = Entry(
            sha256: sha256.lowercased(),
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }

    public func shouldSuppress(relativePath: String, sha256: String, now: Date = Date()) -> Bool {
        purgeExpired(at: now)
        guard let entry = entries[relativePath], entry.sha256 == sha256.lowercased() else {
            return false
        }
        entries.removeValue(forKey: relativePath)
        return true
    }

    private func purgeExpired(at now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }
}
