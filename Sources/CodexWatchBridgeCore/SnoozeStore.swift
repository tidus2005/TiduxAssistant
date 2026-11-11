import CodexWatchCore
import Foundation

public struct SnoozeRecord: Codable, Hashable, Sendable {
    public var threadId: String
    public var commandId: String
    public var createdAt: Date
    public var snoozedUntil: Date

    public init(
        threadId: String,
        commandId: String,
        createdAt: Date = Date(),
        snoozedUntil: Date
    ) {
        self.threadId = threadId
        self.commandId = commandId
        self.createdAt = createdAt
        self.snoozedUntil = snoozedUntil
    }
}

public struct SnoozeStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [SnoozeRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.codexWatchPet.decode([SnoozeRecord].self, from: data)
    }

    public func active(now: Date = Date()) throws -> [String: SnoozeRecord] {
        let active = try load().filter { $0.snoozedUntil > now }
        return Dictionary(active.map { ($0.threadId, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.snoozedUntil >= rhs.snoozedUntil ? lhs : rhs
        })
    }

    public func upsert(_ record: SnoozeRecord) throws {
        var records = try load().filter { $0.threadId != record.threadId }
        records.append(record)
        records = Array(records.sorted { $0.snoozedUntil < $1.snoozedUntil }.suffix(200))
        try save(records)
    }

    public func pruneExpired(now: Date = Date()) throws {
        let records = try load().filter { $0.snoozedUntil > now }
        try save(records)
    }

    private func save(_ records: [SnoozeRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.codexWatchPet.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}
