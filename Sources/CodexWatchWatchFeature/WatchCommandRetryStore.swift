import CodexWatchCore
import Foundation

public struct WatchQueuedCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var command: BridgeCommand
    public var attemptCount: Int
    public var firstQueuedAt: Date
    public var lastAttemptAt: Date?
    public var lastError: String?

    public init(
        id: String,
        command: BridgeCommand,
        attemptCount: Int = 0,
        firstQueuedAt: Date = Date(),
        lastAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.command = command
        self.attemptCount = attemptCount
        self.firstQueuedAt = firstQueuedAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }
}

public struct WatchCommandRetryStore {
    private static let key = "codexWatchPet.watchQueuedCommands"
    private let defaults: UserDefaults
    private let maxQueuedCommands: Int

    public init(defaults: UserDefaults = .standard, maxQueuedCommands: Int = 12) {
        self.defaults = defaults
        self.maxQueuedCommands = maxQueuedCommands
    }

    public func load() -> [WatchQueuedCommand] {
        guard let data = defaults.data(forKey: Self.key),
              let records = try? JSONDecoder.codexWatchPet.decode([WatchQueuedCommand].self, from: data) else {
            return []
        }
        return records
    }

    public func enqueue(_ command: BridgeCommand, error: String?, now: Date = Date()) {
        var records = load()
        if let index = records.firstIndex(where: { $0.id == command.id }) {
            records[index].attemptCount += 1
            records[index].lastAttemptAt = now
            records[index].lastError = error
        } else {
            records.append(
                WatchQueuedCommand(
                    id: command.id,
                    command: command,
                    attemptCount: 1,
                    firstQueuedAt: now,
                    lastAttemptAt: now,
                    lastError: error
                )
            )
        }
        save(Array(records.suffix(maxQueuedCommands)))
    }

    public func update(_ record: WatchQueuedCommand) {
        var records = load()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        save(Array(records.suffix(maxQueuedCommands)))
    }

    public func remove(id: String) {
        save(load().filter { $0.id != id })
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.synchronize()
    }

    private func save(_ records: [WatchQueuedCommand]) {
        let data = try? JSONEncoder.codexWatchPet.encode(records)
        defaults.set(data, forKey: Self.key)
        defaults.synchronize()
    }
}
