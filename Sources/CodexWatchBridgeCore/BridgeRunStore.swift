import CodexWatchCore
import Foundation

public enum BridgeRunStatus: String, Codable, Sendable {
    case running
    case interrupted
    case completed
    case failed
}

public struct BridgeRunRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var commandId: String
    public var threadId: String
    public var commandType: BridgeCommandType
    public var title: String
    public var prompt: String
    public var cwd: String
    public var pid: Int32
    public var logFile: String
    public var status: BridgeRunStatus
    public var lastLogLineCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        commandId: String,
        threadId: String,
        commandType: BridgeCommandType,
        title: String,
        prompt: String,
        cwd: String,
        pid: Int32,
        logFile: String,
        status: BridgeRunStatus = .running,
        lastLogLineCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.commandId = commandId
        self.threadId = threadId
        self.commandType = commandType
        self.title = title
        self.prompt = prompt
        self.cwd = cwd
        self.pid = pid
        self.logFile = logFile
        self.status = status
        self.lastLogLineCount = lastLogLineCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case commandId
        case threadId
        case commandType
        case title
        case prompt
        case cwd
        case pid
        case logFile
        case status
        case lastLogLineCount
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.commandId = try container.decode(String.self, forKey: .commandId)
        self.threadId = try container.decode(String.self, forKey: .threadId)
        self.commandType = try container.decode(BridgeCommandType.self, forKey: .commandType)
        self.title = try container.decode(String.self, forKey: .title)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.cwd = try container.decode(String.self, forKey: .cwd)
        self.pid = try container.decode(Int32.self, forKey: .pid)
        self.logFile = try container.decode(String.self, forKey: .logFile)
        self.status = try container.decode(BridgeRunStatus.self, forKey: .status)
        self.lastLogLineCount = try container.decodeIfPresent(Int.self, forKey: .lastLogLineCount) ?? 0
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public struct BridgeRunStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [BridgeRunRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.codexWatchPet.decode([BridgeRunRecord].self, from: data)
    }

    public func find(threadId: String) throws -> BridgeRunRecord? {
        try load()
            .filter { $0.threadId == threadId && $0.status == .running }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    public func upsert(_ record: BridgeRunRecord) throws {
        var records = try load()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records = Array(records.sorted { $0.updatedAt < $1.updatedAt }.suffix(100))
        try save(records)
    }

    private func save(_ records: [BridgeRunRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.codexWatchPet.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}
