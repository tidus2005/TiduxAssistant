import CodexWatchCore
import Foundation

public struct ApprovalResponseRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var commandId: String
    public var threadId: String
    public var requestId: String?
    public var approved: Bool
    public var summary: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        commandId: String,
        threadId: String,
        requestId: String?,
        approved: Bool,
        summary: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.commandId = commandId
        self.threadId = threadId
        self.requestId = requestId
        self.approved = approved
        self.summary = summary
        self.createdAt = createdAt
    }
}

public struct ApprovalResponseStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load(limit: Int = 500) throws -> [ApprovalResponseRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder.codexWatchPet
        let records = text.split(separator: "\n").compactMap { line -> ApprovalResponseRecord? in
            try? decoder.decode(ApprovalResponseRecord.self, from: Data(line.utf8))
        }
        return Array(records.suffix(limit))
    }

    public func append(_ record: ApprovalResponseRecord) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.codexWatchPetLine.encode(record)
        var line = data
        line.append(0x0A)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
    }
}
