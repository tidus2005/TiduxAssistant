import CryptoKit
import Foundation
import Security

struct TranscriptSession: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion = "0.1.0"
    var id = UUID()
    var createdAt = Date()
    var locale: String
    var engine = "apple.speech"
    var targetApp: String?
    var rawText: String
    var polishedText: String?
    var deliveredText: String?
    var tone: String = AppTone.faithful.rawValue
    var dictionaryVersion: String?
    var delivery: DeliveryState = .retainedOnly
    var audioIncluded = false
}

protocol HistoryKeyProviding {
    func key() throws -> SymmetricKey
}

struct KeychainHistoryKeyProvider: HistoryKeyProviding {
    var service = "com.tidux.CodexWatchPet.voice-history.v1"
    var account = "aes-gcm-256"

    func key() throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecAttrSynchronizable as String: false]
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw HistoryError.keychain(status) }
        let key = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem { return try self.key() }
        guard added == errSecSuccess else { throw HistoryError.keychain(added) }
        return key
    }
}

enum HistoryError: LocalizedError {
    case keychain(OSStatus), invalidRecord
    var errorDescription: String? {
        switch self {
        case let .keychain(status): "无法访问历史加密密钥（Keychain \(status)），未写入明文。"
        case .invalidRecord: "历史记录格式无效，原加密文件未覆盖。"
        }
    }
}

/// One authenticated encrypted file, containing an array of frozen-schema
/// transcript sessions. No audio field/payload and no plaintext staging file.
struct HistoryRepository {
    let url: URL
    let keyProvider: any HistoryKeyProviding
    var retention: TimeInterval = 7 * 24 * 60 * 60
    private static let authenticatedContext = Data("TiduxVoice.history.0.1.0".utf8)

    init(directory: URL = VoiceStorage.directory, keyProvider: any HistoryKeyProviding = KeychainHistoryKeyProvider()) {
        url = directory.appendingPathComponent("history.enc")
        self.keyProvider = keyProvider
    }

    func load(now: Date = Date()) throws -> [TranscriptSession] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let data = try AES.GCM.open(sealed, using: keyProvider.key(), authenticating: Self.authenticatedContext)
        let records = try VoiceStorage.decoder().decode([TranscriptSession].self, from: data)
        guard records.allSatisfy({ $0.schemaVersion == "0.1.0" && !$0.audioIncluded }) else { throw HistoryError.invalidRecord }
        let retained = records.filter { $0.createdAt >= now.addingTimeInterval(-retention) }
        if records.count != retained.count { try save(retained) }
        return retained
    }

    func record(_ session: TranscriptSession, enabled: Bool, now: Date = Date()) throws {
        guard enabled else { return } // does not even create a Keychain key
        guard !session.audioIncluded, session.schemaVersion == "0.1.0" else { throw HistoryError.invalidRecord }
        var records = try load(now: now)
        records.removeAll { $0.id == session.id }
        records.append(session)
        records.sort { $0.createdAt > $1.createdAt }
        try save(Array(records.prefix(200)))
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func save(_ records: [TranscriptSession]) throws {
        guard !records.isEmpty else { try clear(); return }
        let plaintext = try VoiceStorage.encoder().encode(records)
        let sealed = try AES.GCM.seal(plaintext, using: keyProvider.key(), authenticating: Self.authenticatedContext)
        guard let combined = sealed.combined else { throw HistoryError.invalidRecord }
        try VoiceStorage.write(combined, to: url)
    }
}
