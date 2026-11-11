import Combine
import CryptoKit
import Foundation

public struct SavedSMS: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let receivedAt: Date
    public let sender: String
    public let body: String
    public let sourceID: String?
    public var mailHandedOffAt: Date?
    public var smsForwardReservedAt: Date?
    public var verificationCode: String? { SMSCodeDetector.extract(from: body) }
    public init(id: UUID = UUID(), receivedAt: Date = Date(), sender: String, body: String, sourceID: String? = nil) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 20_000,
              sender.count <= 256, (sourceID?.count ?? 0) <= 256 else { throw SMSInboxError.invalidMessage }
        self.id = id; self.receivedAt = receivedAt; self.sender = sender; self.body = body; self.sourceID = sourceID
    }
}

public enum SMSCodeDetector {
    public static func extract(from text: String) -> String? {
        let label = "(?:验证码|校验码|动态码|驗證碼|verification(?: code)?|one[- ]time(?: password| code)?|passcode|\\botp\\b|\\bcode\\b)"
        // Prefer a number attached to the code label, not an earlier date or order number.
        let number = "(?<![0-9])([0-9]{4,8})(?![0-9])"
        for pattern in [label + "[^0-9。.!！\\n]{0,16}" + number,
                        number + "[^0-9。.!！\\n]{0,16}" + label] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }
}

public enum SMSInboxError: LocalizedError {
    case invalidMessage, missingRecord, full
    public var errorDescription: String? {
        switch self {
        case .invalidMessage: "短信为空或长度超限，未保存。"
        case .missingRecord: "找不到对应短信，无法更新邮件交接状态。"
        case .full: "短信记录已达 2000 条，请先在随行助手清理。"
        }
    }
}

/// Intents and UI share the app's protected container. No SMS database access, cloud upload or body logging.
@MainActor
public final class SMSInboxStore: ObservableObject {
    public static let shared = SMSInboxStore()
    @Published public private(set) var messages: [SavedSMS] = []
    @Published public private(set) var error: String?
    private let file: URL?
    public init(directory: URL? = nil) {
        let root = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.appendingPathComponent("SMSInbox", isDirectory: true)
        file = root?.appendingPathComponent("messages.json")
        do {
            if let root {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            }
            try reload()
        } catch { self.error = "读取失败，原记录未删除：\(error.localizedDescription)" }
    }
    public func reload() throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        if FileManager.default.fileExists(atPath: file.path) { messages = try JSONDecoder().decode([SavedSMS].self, from: Data(contentsOf: file)) }
        error = nil
    }
    @discardableResult
    public func save(sender: String, body: String, sourceID: String? = nil, now: Date = Date()) throws -> SavedSMS {
        try reload()
        if let sourceID, !sourceID.isEmpty, let existing = messages.first(where: { $0.sourceID == sourceID }) {
            guard existing.sender == sender, existing.body == body else { throw SMSInboxError.invalidMessage }
            return existing
        }
        guard messages.count < 2000 else { throw SMSInboxError.full }
        let message = try SavedSMS(receivedAt: now, sender: sender, body: body, sourceID: sourceID)
        try persist([message] + messages)
        return message
    }
    public func markMailHandedOff(id: UUID, now: Date = Date()) throws {
        try reload()
        var updated = messages
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw SMSInboxError.missingRecord }
        updated[index].mailHandedOffAt = now
        try persist(updated)
    }
    /// Reserve BEFORE invoking Messages. Ambiguous sends are never automatically retried.
    /// A source ID deduplicates exactly; without one, identical sender/body is suppressed for 15 minutes.
    /// Claims survive deleting the visible message. Protected storage remains available after first unlock.
    public func prepareSMSForward(sender: String, body: String, sourceID: String? = nil, now: Date = Date()) throws -> String {
        guard !body.hasPrefix("[随行转发]") else { return "" }
        _ = try SavedSMS(sender: sender, body: body, sourceID: sourceID)
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        try reload()
        let claimsURL = file.deletingLastPathComponent().appendingPathComponent("sms-forward-claims.json")
        var claims: [String: Date] = [:]
        if FileManager.default.fileExists(atPath: claimsURL.path) {
            claims = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: claimsURL))
        }
        let stableID = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasID = stableID?.isEmpty == false
        let identity = hasID ? "id:" + stableID! : "body:" + sender + "\u{0}" + body
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let last = claims[key], hasID || now.timeIntervalSince(last) < 15 * 60 { return "" }
        guard claims[key] != nil || claims.count < 10_000 else { throw SMSInboxError.full }
        let saved = try save(sender: sender, body: body, sourceID: sourceID, now: now)
        claims[key] = now
        let data = try JSONEncoder().encode(claims)
        #if os(iOS) || os(watchOS)
        try data.write(to: claimsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: claimsURL, options: .atomic)
        #endif
        var updated = messages
        if let index = updated.firstIndex(where: { $0.id == saved.id }) { updated[index].smsForwardReservedAt = now }
        try persist(updated)
        return "[随行转发] " + sender + "\n" + body
    }
    public func delete(id: UUID) throws { try reload(); try persist(messages.filter { $0.id != id }) }
    private func persist(_ updated: [SavedSMS]) throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(updated)
        #if os(iOS) || os(watchOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        messages = updated; error = nil
    }
}
