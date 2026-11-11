import CodexMobilityCore
import Foundation

enum MacClosedLidSessionJournalPhase: String, Codable, Equatable, Sendable {
    case preparing
    case active
    case restoring
    case restoreFailed
}

struct MacClosedLidSessionJournal: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var sessionID: UUID
    var baselineSleepDisabled: Bool
    var baselineModuleConfiguration: MobilityModuleConfiguration
    var startedAt: Date
    var expiresAt: Date?
    var didEnableSystemPolicy: Bool?
    var phase: MacClosedLidSessionJournalPhase

    init(
        sessionID: UUID = UUID(),
        baselineSleepDisabled: Bool,
        baselineModuleConfiguration: MobilityModuleConfiguration,
        startedAt: Date,
        expiresAt: Date?,
        didEnableSystemPolicy: Bool? = nil,
        phase: MacClosedLidSessionJournalPhase = .preparing
    ) {
        self.sessionID = sessionID
        self.baselineSleepDisabled = baselineSleepDisabled
        self.baselineModuleConfiguration = baselineModuleConfiguration
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.didEnableSystemPolicy = didEnableSystemPolicy
        self.phase = phase
    }
}

protocol MacClosedLidSessionJournalPersisting: AnyObject {
    func loadJournal() throws -> MacClosedLidSessionJournal?
    func saveJournal(_ journal: MacClosedLidSessionJournal) throws
    func clearJournal() throws
}

final class UserDefaultsMacClosedLidSessionJournalPersistence:
    MacClosedLidSessionJournalPersisting {
    static let suiteName = "com.tidux.codex-mobility.closed-lid-session"
    static let journalKey = "temporaryOverrideJournal.v1"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    convenience init() {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else {
            preconditionFailure("Unable to create closed-lid session preferences")
        }
        self.init(defaults: defaults)
    }

    init(
        defaults: UserDefaults,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.encoder = encoder
        self.decoder = decoder
    }

    func loadJournal() throws -> MacClosedLidSessionJournal? {
        guard let data = defaults.data(forKey: Self.journalKey) else { return nil }
        let journal = try decoder.decode(MacClosedLidSessionJournal.self, from: data)
        guard journal.schemaVersion == MacClosedLidSessionJournal.currentSchemaVersion else {
            throw MacSystemPowerPolicyError.commandFailed(
                "临时覆盖恢复记录版本不受支持，请先恢复系统合盖配置。"
            )
        }
        return journal
    }

    func saveJournal(_ journal: MacClosedLidSessionJournal) throws {
        defaults.set(try encoder.encode(journal), forKey: Self.journalKey)
    }

    func clearJournal() throws {
        defaults.removeObject(forKey: Self.journalKey)
    }
}
