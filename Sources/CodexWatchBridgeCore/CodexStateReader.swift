import CodexWatchCore
import Foundation

public struct ThreadRecord: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var cwd: String
    public var updatedAt: Date
    public var preview: String
    public var tokensUsed: Int
    public var goalStatus: String?

    public init(
        id: String,
        title: String,
        cwd: String,
        updatedAt: Date,
        preview: String,
        tokensUsed: Int,
        goalStatus: String? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.preview = preview
        self.tokensUsed = tokensUsed
        self.goalStatus = goalStatus
    }
}

public struct CodexStateReader: Sendable {
    public var codexHome: URL
    public var shell: ShellRunning

    public init(codexHome: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex"), shell: ShellRunning = ProcessShellRunner()) {
        self.codexHome = codexHome
        self.shell = shell
    }

    public func readRecentThreads(limit: Int = 20) throws -> [ThreadRecord] {
        let stateDB = codexHome.appendingPathComponent("state_5.sqlite").path
        let query = """
        select
            id,
            substr(title, 1, 256) as title,
            substr(cwd, 1, 512) as cwd,
            updated_at,
            substr(preview, 1, 512) as preview,
            tokens_used
        from threads
        where archived = 0
        order by updated_at desc
        limit \(max(1, limit));
        """
        let result = try shell.run("/usr/bin/sqlite3", arguments: ["-json", "-readonly", stateDB, query], input: nil)
        guard result.status == 0 else {
            throw BridgeError.sqlite(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let rows = try JSONDecoder().decode([ThreadRow].self, from: Data(result.stdout.utf8))
        var records = rows.map { row in
            ThreadRecord(
                id: row.id,
                title: row.title,
                cwd: row.cwd,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(row.updatedAt)),
                preview: row.preview,
                tokensUsed: row.tokensUsed
            )
        }

        let goals = (try? readGoals()) ?? [:]
        for index in records.indices {
            records[index].goalStatus = goals[records[index].id]
        }
        return records
    }

    public func makeSnapshots(limit: Int = 20, now: Date = Date()) throws -> [TaskSnapshot] {
        try readRecentThreads(limit: limit).map { record in
            let status = Self.taskStatus(goalStatus: record.goalStatus, updatedAt: record.updatedAt, now: now)
            return TaskSnapshot(
                id: record.id,
                threadId: record.id,
                title: record.title.isEmpty ? "Untitled Codex task" : record.title,
                cwd: record.cwd,
                status: status,
                lastSummary: record.preview.trimmedPreview(maxLength: 240),
                tokensUsed: record.tokensUsed,
                lastSyncedAt: now,
                updatedAt: record.updatedAt,
                urgency: Self.urgency(for: status, updatedAt: record.updatedAt, now: now)
            )
        }
    }

    private func readGoals() throws -> [String: String] {
        let goalsDB = codexHome.appendingPathComponent("goals_1.sqlite").path
        guard FileManager.default.fileExists(atPath: goalsDB) else { return [:] }
        let query = "select thread_id, status from thread_goals;"
        let result = try shell.run("/usr/bin/sqlite3", arguments: ["-json", "-readonly", goalsDB, query], input: nil)
        guard result.status == 0 else {
            return [:]
        }
        let rows = try JSONDecoder().decode([GoalRow].self, from: Data(result.stdout.utf8))
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.threadId, $0.status) })
    }

    private struct ThreadRow: Decodable {
        var id: String
        var title: String
        var cwd: String
        var updatedAt: Int
        var preview: String
        var tokensUsed: Int

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case cwd
            case updatedAt = "updated_at"
            case preview
            case tokensUsed = "tokens_used"
        }
    }

    private struct GoalRow: Decodable {
        var threadId: String
        var status: String

        enum CodingKeys: String, CodingKey {
            case threadId = "thread_id"
            case status
        }
    }

    static func taskStatus(goalStatus: String?, updatedAt: Date, now: Date) -> TaskStatus {
        switch goalStatus {
        case "blocked":
            return .waitingForInput
        case "complete":
            return .completed
        case "active":
            return now.timeIntervalSince(updatedAt) < 300 ? .active : .idle
        case "usage_limited", "budget_limited":
            return .waitingForApproval
        case "paused":
            return .idle
        default:
            return now.timeIntervalSince(updatedAt) < 120 ? .active : .idle
        }
    }

    static func urgency(for status: TaskStatus, updatedAt: Date, now: Date) -> Urgency {
        switch status {
        case .waitingForApproval, .waitingForInput, .failed:
            return .high
        case .completed:
            return now.timeIntervalSince(updatedAt) < 600 ? .medium : .low
        case .active, .runningTool:
            return .medium
        case .idle, .offline:
            return .low
        }
    }
}

private extension String {
    func trimmedPreview(maxLength: Int) -> String {
        let collapsed = split(whereSeparator: \.isNewline).joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "..."
    }
}

public enum BridgeError: Error, LocalizedError, Equatable {
    case sqlite(String)
    case invalidRequest(String)
    case unauthorized(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            "SQLite read failed: \(message)"
        case .invalidRequest(let message):
            "Invalid request: \(message)"
        case .unauthorized(let message):
            "Unauthorized: \(message)"
        case .unsupported(let message):
            "Unsupported: \(message)"
        }
    }
}
