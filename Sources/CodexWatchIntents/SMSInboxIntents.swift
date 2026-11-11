import AppIntents
import CodexWatchCore
import Foundation

public struct PrepareSMSForwardIntent: AppIntent {
    public static let title: LocalizedStringResource = "保存并准备短信转发"
    public static let description = IntentDescription("先保存并防重复，再返回转发文本。重复触发返回空文本，后续须判断非空才发送。来源编号可用时填入；否则同一发送人和正文在 15 分钟内只准备一次。发送结果未知时不会自动重发。")
    public static let openAppWhenRun = false
    @Parameter(title: "短信正文") public var body: String
    @Parameter(title: "发送人", default: "未知发送人") public var sender: String
    @Parameter(title: "来源编号", default: "") public var sourceID: String
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return .result(value: try SMSInboxStore.shared.prepareSMSForward(sender: sender, body: body, sourceID: id.isEmpty ? nil : id))
    }
}

public struct SaveReceivedMessageIntent: AppIntent {
    public static let title: LocalizedStringResource = "保存收到的短信"
    public static let description = IntentDescription("接收系统快捷指令传入的短信，在随行助手中保存。返回记录编号供邮件交接步骤使用；本操作不读取短信收件箱，也不发送邮件。")
    public static let openAppWhenRun = false
    @Parameter(title: "短信正文") public var body: String
    @Parameter(title: "发送人", default: "未知发送人") public var sender: String
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let saved = try SMSInboxStore.shared.save(sender: sender, body: body)
        return .result(value: saved.id.uuidString)
    }
}

public struct MarkMessageMailHandedOffIntent: AppIntent {
    public static let title: LocalizedStringResource = "标记短信已交给邮件"
    public static let description = IntentDescription("放在系统发送电子邮件操作之后。仅记录该操作成功返回，不代表 Gmail 已确认送达。")
    public static let openAppWhenRun = false
    @Parameter(title: "短信记录编号") public var recordID: String
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: recordID) else { throw SMSInboxError.missingRecord }
        try SMSInboxStore.shared.markMailHandedOff(id: id)
        return .result()
    }
}
