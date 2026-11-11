import Foundation

/// Versioned, portable container shared by legacy FlowType migration and
/// ongoing Codex Watch Pet voice-history backups.
///
/// The manifest protects archive integrity, not provenance. Importers must
/// still treat every path and byte in the package as untrusted input.
public enum VoiceHistoryBackupFormat {
    public static let archiveSchemaVersion = 1
    public static let contentTypeIdentifier =
        "com.tidux.flowtype.voice-history-backup"
    public static let fileExtension = "flowtypebackup"
    public static let manifestFileName = "archive.json"
    public static let sessionsDirectoryName = "Sessions"
}

public struct VoiceHistoryBackupFileEntry:
    Codable,
    Equatable,
    Sendable
{
    public let relativePath: String
    public let byteCount: UInt64
    public let sha256: String

    public init(
        relativePath: String,
        byteCount: UInt64,
        sha256: String
    ) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct VoiceHistoryBackupSessionEntry:
    Codable,
    Equatable,
    Sendable
{
    public let sessionID: UUID
    public let files: [VoiceHistoryBackupFileEntry]

    public init(
        sessionID: UUID,
        files: [VoiceHistoryBackupFileEntry]
    ) {
        self.sessionID = sessionID
        self.files = files
    }
}

public struct VoiceHistoryBackupManifest:
    Codable,
    Equatable,
    Sendable
{
    public let archiveSchemaVersion: Int
    public let sourceBundleIdentifier: String
    public let sourceAppVersion: String
    public let sourceAppBuild: String
    public let createdAt: Date
    public let sessionCount: Int
    public let totalBytes: UInt64
    public let sessions: [VoiceHistoryBackupSessionEntry]

    public init(
        sourceBundleIdentifier: String,
        sourceAppVersion: String,
        sourceAppBuild: String,
        createdAt: Date = Date(),
        totalBytes: UInt64,
        sessions: [VoiceHistoryBackupSessionEntry]
    ) {
        self.archiveSchemaVersion =
            VoiceHistoryBackupFormat.archiveSchemaVersion
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceAppVersion = sourceAppVersion
        self.sourceAppBuild = sourceAppBuild
        self.createdAt = createdAt
        self.sessionCount = sessions.count
        self.totalBytes = totalBytes
        self.sessions = sessions
    }
}
