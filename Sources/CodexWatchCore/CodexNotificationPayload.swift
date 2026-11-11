import Foundation

public struct CodexNotificationPayload: Codable, Hashable, Sendable {
    public var source: String
    public var kind: String
    public var threadId: String?
    public var turnId: String?
    public var title: String?
    public var summary: String?
    public var cwd: String?
    public var rawArgs: [String]
    public var rawStdin: String?
    public var createdAt: Date

    public init(
        source: String = "codex-notify",
        kind: String,
        threadId: String? = nil,
        turnId: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        cwd: String? = nil,
        rawArgs: [String] = [],
        rawStdin: String? = nil,
        createdAt: Date = Date()
    ) {
        self.source = source
        self.kind = kind
        self.threadId = threadId
        self.turnId = turnId
        self.title = title
        self.summary = summary
        self.cwd = cwd
        self.rawArgs = rawArgs
        self.rawStdin = rawStdin
        self.createdAt = createdAt
    }
}
