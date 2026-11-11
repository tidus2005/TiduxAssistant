import Foundation

public struct AuditLogEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var commandId: String
    public var commandType: BridgeCommandType
    public var threadId: String?
    public var result: String
    public var message: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        commandId: String,
        commandType: BridgeCommandType,
        threadId: String?,
        result: String,
        message: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.commandId = commandId
        self.commandType = commandType
        self.threadId = threadId
        self.result = result
        self.message = message
        self.createdAt = createdAt
    }
}
