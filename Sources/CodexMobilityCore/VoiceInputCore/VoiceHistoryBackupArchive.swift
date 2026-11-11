import CryptoKit
import Foundation

public enum VoiceHistoryBackupArchiveError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case packageMustBeDirectory
    case invalidPackageExtension
    case symbolicLinkNotAllowed(String)
    case aliasNotAllowed(String)
    case unexpectedItem(String)
    case missingRequiredItem(String)
    case invalidArchiveManifest
    case unsupportedArchiveSchemaVersion(Int)
    case invalidManifestCounts
    case archiveLimitExceeded
    case nonCanonicalManifest
    case invalidSessionIdentifier(String)
    case duplicateSessionIdentifier(UUID)
    case invalidRelativePath(String)
    case duplicateRelativePath(String)
    case invalidSHA256(String)
    case fileSizeMismatch(String)
    case fileHashMismatch(String)
    case invalidSessionRecord(UUID)
    case nonTerminalSession(UUID)
    case invalidAudioManifest(UUID)
    case invalidAudioFileName(String)
    case conflictingSession(UUID)
    case insufficientStorage(requiredBytes: UInt64, availableBytes: UInt64)

    public var errorDescription: String? {
        switch self {
        case .packageMustBeDirectory:
            "历史备份必须是一个完整的目录包。"
        case .invalidPackageExtension:
            "历史备份文件扩展名不正确。"
        case let .symbolicLinkNotAllowed(path):
            "历史备份不允许包含符号链接：\(path)"
        case let .aliasNotAllowed(path):
            "历史备份不允许包含文件别名：\(path)"
        case let .unexpectedItem(path):
            "历史备份包含未知文件或目录：\(path)"
        case let .missingRequiredItem(path):
            "历史备份缺少必要文件：\(path)"
        case .invalidArchiveManifest:
            "历史备份清单无法读取。"
        case let .unsupportedArchiveSchemaVersion(version):
            "不支持历史备份格式版本 \(version)。"
        case .invalidManifestCounts:
            "历史备份清单中的数量或大小不一致。"
        case .archiveLimitExceeded:
            "历史备份超过安全导入上限。"
        case .nonCanonicalManifest:
            "历史备份清单不是规范格式。"
        case let .invalidSessionIdentifier(value):
            "历史备份包含非法会话标识：\(value)"
        case let .duplicateSessionIdentifier(id):
            "历史备份重复包含会话 \(id.uuidString.lowercased())。"
        case let .invalidRelativePath(path):
            "历史备份包含非法相对路径：\(path)"
        case let .duplicateRelativePath(path):
            "历史备份重复声明文件：\(path)"
        case let .invalidSHA256(path):
            "历史备份包含非法 SHA-256：\(path)"
        case let .fileSizeMismatch(path):
            "历史备份文件大小不匹配：\(path)"
        case let .fileHashMismatch(path):
            "历史备份文件校验失败：\(path)"
        case let .invalidSessionRecord(id):
            "历史备份中的会话记录无效：\(id.uuidString.lowercased())"
        case let .nonTerminalSession(id):
            "历史备份包含尚未安全结束的会话：\(id.uuidString.lowercased())"
        case let .invalidAudioManifest(id):
            "历史备份中的音频清单无效：\(id.uuidString.lowercased())"
        case let .invalidAudioFileName(path):
            "历史备份包含非法音频文件名：\(path)"
        case let .conflictingSession(id):
            "已有同标识但内容不同的会话：\(id.uuidString.lowercased())"
        case let .insufficientStorage(requiredBytes, availableBytes):
            "导入至少需要 \(requiredBytes) 字节空间，当前仅有 \(availableBytes) 字节。"
        }
    }
}

public struct VoiceHistoryBackupLimits: Equatable, Sendable {
    public var maximumSessionCount: Int
    public var maximumFileCount: Int
    public var maximumManifestBytes: UInt64
    public var maximumMetadataFileBytes: UInt64
    public var maximumTotalBytes: UInt64

    public init(
        maximumSessionCount: Int = 10_000,
        maximumFileCount: Int = 100_000,
        maximumManifestBytes: UInt64 = 16 * 1_024 * 1_024,
        maximumMetadataFileBytes: UInt64 = 16 * 1_024 * 1_024,
        maximumTotalBytes: UInt64 = 256 * 1_024 * 1_024 * 1_024
    ) {
        self.maximumSessionCount = maximumSessionCount
        self.maximumFileCount = maximumFileCount
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumMetadataFileBytes = maximumMetadataFileBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    public static let standard = Self()
}

public struct VoiceHistoryBackupExport: Equatable, Sendable {
    public let packageURL: URL
    public let manifest: VoiceHistoryBackupManifest

    public init(
        packageURL: URL,
        manifest: VoiceHistoryBackupManifest
    ) {
        self.packageURL = packageURL
        self.manifest = manifest
    }
}

public struct VoiceHistoryBackupValidatedSession:
    Equatable,
    Sendable
{
    public let sessionID: UUID
    public let directoryURL: URL
    public let files: [VoiceHistoryBackupFileEntry]

    public init(
        sessionID: UUID,
        directoryURL: URL,
        files: [VoiceHistoryBackupFileEntry]
    ) {
        self.sessionID = sessionID
        self.directoryURL = directoryURL
        self.files = files
    }
}

public struct VoiceHistoryBackupValidationResult:
    Equatable,
    Sendable
{
    public let packageURL: URL
    public let manifest: VoiceHistoryBackupManifest
    public let sessions: [VoiceHistoryBackupValidatedSession]

    public init(
        packageURL: URL,
        manifest: VoiceHistoryBackupManifest,
        sessions: [VoiceHistoryBackupValidatedSession]
    ) {
        self.packageURL = packageURL
        self.manifest = manifest
        self.sessions = sessions
    }
}

public struct VoiceHistoryBackupImportResult:
    Equatable,
    Sendable
{
    public let importedSessionIDs: [UUID]
    public let skippedSessionIDs: [UUID]
    public let conflictingSessionIDs: [UUID]

    public init(
        importedSessionIDs: [UUID],
        skippedSessionIDs: [UUID],
        conflictingSessionIDs: [UUID]
    ) {
        self.importedSessionIDs = importedSessionIDs
        self.skippedSessionIDs = skippedSessionIDs
        self.conflictingSessionIDs = conflictingSessionIDs
    }
}

/// Creates and validates the on-disk package shared by legacy FlowType and the
/// combined Codex Watch Pet App's ongoing export/import flow.
///
/// All audio hashing is streaming. The engine deliberately accepts filesystem
/// URLs instead of `Data` so a long recording is never materialized in memory.
public enum VoiceHistoryBackupArchive {
    private enum Name {
        static let transcript = "session.json"
        static let audioManifest = "audio-manifest.json"
        static let diagnostics = "diagnostics.json"
        static let audioDirectory = "Audio"
        static let importStagingPrefix = ".voice-history-import-"
    }

    private struct BackupAudioSegment: Decodable {
        let sequenceNumber: UInt64
        let fileName: String
        let state: RollingSegmentFileState
        let frameCount: Int64
        let sampleRate: Double
        let channelCount: UInt32
    }

    private struct BackupAudioManifest: Decodable {
        let schemaVersion: Int
        let sessionID: UUID
        let updatedAt: Date
        let segments: [BackupAudioSegment]
    }

    private struct InspectedSession {
        let id: UUID
        let directoryURL: URL
        let fileURLs: [String: URL]
    }

    public static func createStagedBackup(
        sourceSessionsDirectory: URL,
        stagingParentDirectory: URL,
        includeAudio: Bool,
        sourceBundleIdentifier: String,
        sourceAppVersion: String,
        sourceAppBuild: String,
        createdAt: Date = Date(),
        limits: VoiceHistoryBackupLimits = .standard,
        fileManager: FileManager = .default
    ) throws -> VoiceHistoryBackupExport {
        try fileManager.createDirectory(
            at: sourceSessionsDirectory,
            withIntermediateDirectories: true
        )
        try requireDirectory(
            sourceSessionsDirectory,
            displayPath: VoiceHistoryBackupFormat.sessionsDirectoryName
        )
        try fileManager.createDirectory(
            at: stagingParentDirectory,
            withIntermediateDirectories: true
        )
        try requireDirectory(
            stagingParentDirectory,
            displayPath: stagingParentDirectory.lastPathComponent
        )

        let packageURL = stagingParentDirectory
            .appendingPathComponent(
                "FlowType-History-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            .appendingPathExtension(VoiceHistoryBackupFormat.fileExtension)
        let packageSessionsURL = packageURL.appendingPathComponent(
            VoiceHistoryBackupFormat.sessionsDirectoryName,
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: packageSessionsURL,
                withIntermediateDirectories: true
            )

            let sourceSessions = try inspectSourceSessions(
                at: sourceSessionsDirectory,
                includeAudio: includeAudio,
                limits: limits,
                fileManager: fileManager
            )
            guard sourceSessions.count <= limits.maximumSessionCount else {
                throw VoiceHistoryBackupArchiveError.archiveLimitExceeded
            }

            var entries: [VoiceHistoryBackupSessionEntry] = []
            var totalBytes: UInt64 = 0
            var totalFileCount = 0

            for sourceSession in sourceSessions {
                let destinationDirectory = packageSessionsURL
                    .appendingPathComponent(
                        sourceSession.id.uuidString.lowercased(),
                        isDirectory: true
                    )
                try fileManager.createDirectory(
                    at: destinationDirectory,
                    withIntermediateDirectories: true
                )

                var fileEntries: [VoiceHistoryBackupFileEntry] = []
                for relativeSessionPath in sourceSession.fileURLs.keys.sorted() {
                    guard
                        let sourceURL =
                            sourceSession.fileURLs[relativeSessionPath]
                    else {
                        continue
                    }
                    let destinationURL = destinationDirectory
                        .appendingPathComponent(relativeSessionPath)
                    try fileManager.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(
                        at: sourceURL,
                        to: destinationURL
                    )

                    let packageRelativePath = [
                        VoiceHistoryBackupFormat.sessionsDirectoryName,
                        sourceSession.id.uuidString.lowercased(),
                        relativeSessionPath,
                    ].joined(separator: "/")
                    let digest = try streamingSHA256(
                        of: destinationURL
                    )
                    totalBytes = try addingWithoutOverflow(
                        totalBytes,
                        digest.byteCount
                    )
                    totalFileCount += 1
                    guard
                        totalBytes <= limits.maximumTotalBytes,
                        totalFileCount <= limits.maximumFileCount
                    else {
                        throw VoiceHistoryBackupArchiveError
                            .archiveLimitExceeded
                    }
                    fileEntries.append(
                        VoiceHistoryBackupFileEntry(
                            relativePath: packageRelativePath,
                            byteCount: digest.byteCount,
                            sha256: digest.sha256
                        )
                    )
                }
                entries.append(
                    VoiceHistoryBackupSessionEntry(
                        sessionID: sourceSession.id,
                        files: fileEntries.sorted {
                            $0.relativePath < $1.relativePath
                        }
                    )
                )
            }

            let sortedEntries = entries.sorted {
                canonicalUUID($0.sessionID) < canonicalUUID($1.sessionID)
            }
            let manifest = VoiceHistoryBackupManifest(
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceAppVersion: sourceAppVersion,
                sourceAppBuild: sourceAppBuild,
                createdAt: createdAt,
                totalBytes: totalBytes,
                sessions: sortedEntries
            )
            let manifestURL = packageURL.appendingPathComponent(
                VoiceHistoryBackupFormat.manifestFileName
            )
            try backupEncoder().encode(manifest).write(
                to: manifestURL,
                options: .atomic
            )

            let validated = try validate(
                packageURL: packageURL,
                limits: limits,
                fileManager: fileManager
            )
            return VoiceHistoryBackupExport(
                packageURL: packageURL,
                manifest: validated.manifest
            )
        } catch {
            try? fileManager.removeItem(at: packageURL)
            throw error
        }
    }

    public static func validate(
        packageURL: URL,
        limits: VoiceHistoryBackupLimits = .standard,
        fileManager: FileManager = .default
    ) throws -> VoiceHistoryBackupValidationResult {
        guard
            packageURL.pathExtension ==
                VoiceHistoryBackupFormat.fileExtension
        else {
            throw VoiceHistoryBackupArchiveError.invalidPackageExtension
        }
        try requireDirectory(packageURL, displayPath: packageURL.lastPathComponent)

        let rootItems = try safeContents(
            of: packageURL,
            relativeTo: packageURL,
            fileManager: fileManager
        )
        let allowedRootItems: Set<String> = [
            VoiceHistoryBackupFormat.manifestFileName,
            VoiceHistoryBackupFormat.sessionsDirectoryName,
        ]
        for item in rootItems where
            !allowedRootItems.contains(item.lastPathComponent)
        {
            throw VoiceHistoryBackupArchiveError.unexpectedItem(
                item.lastPathComponent
            )
        }

        let manifestURL = packageURL.appendingPathComponent(
            VoiceHistoryBackupFormat.manifestFileName
        )
        let sessionsURL = packageURL.appendingPathComponent(
            VoiceHistoryBackupFormat.sessionsDirectoryName,
            isDirectory: true
        )
        try requireRegularFile(
            manifestURL,
            displayPath: VoiceHistoryBackupFormat.manifestFileName
        )
        try requireDirectory(
            sessionsURL,
            displayPath: VoiceHistoryBackupFormat.sessionsDirectoryName
        )

        let manifestSize = try regularFileSize(manifestURL)
        guard manifestSize <= limits.maximumManifestBytes else {
            throw VoiceHistoryBackupArchiveError.archiveLimitExceeded
        }
        let manifest: VoiceHistoryBackupManifest
        do {
            manifest = try backupDecoder().decode(
                VoiceHistoryBackupManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw VoiceHistoryBackupArchiveError.invalidArchiveManifest
        }
        guard
            manifest.archiveSchemaVersion ==
                VoiceHistoryBackupFormat.archiveSchemaVersion
        else {
            throw VoiceHistoryBackupArchiveError
                .unsupportedArchiveSchemaVersion(
                    manifest.archiveSchemaVersion
                )
        }
        guard
            manifest.sessionCount == manifest.sessions.count,
            manifest.sessionCount <= limits.maximumSessionCount,
            manifest.totalBytes <= limits.maximumTotalBytes
        else {
            throw VoiceHistoryBackupArchiveError.invalidManifestCounts
        }
        guard
            !manifest.sourceBundleIdentifier.isEmpty,
            !manifest.sourceAppVersion.isEmpty,
            !manifest.sourceAppBuild.isEmpty
        else {
            throw VoiceHistoryBackupArchiveError.invalidArchiveManifest
        }

        let sortedManifestSessions = manifest.sessions.sorted {
            canonicalUUID($0.sessionID) < canonicalUUID($1.sessionID)
        }
        guard manifest.sessions == sortedManifestSessions else {
            throw VoiceHistoryBackupArchiveError.nonCanonicalManifest
        }

        var seenSessionIDs = Set<UUID>()
        var seenRelativePaths = Set<String>()
        var declaredBytes: UInt64 = 0
        var declaredFileCount = 0
        for session in manifest.sessions {
            guard seenSessionIDs.insert(session.sessionID).inserted else {
                throw VoiceHistoryBackupArchiveError
                    .duplicateSessionIdentifier(session.sessionID)
            }
            guard
                session.files == session.files.sorted(by: {
                    $0.relativePath < $1.relativePath
                })
            else {
                throw VoiceHistoryBackupArchiveError.nonCanonicalManifest
            }
            for file in session.files {
                try validateManifestPath(
                    file.relativePath,
                    expectedSessionID: session.sessionID
                )
                guard
                    seenRelativePaths.insert(file.relativePath).inserted
                else {
                    throw VoiceHistoryBackupArchiveError
                        .duplicateRelativePath(file.relativePath)
                }
                guard isCanonicalSHA256(file.sha256) else {
                    throw VoiceHistoryBackupArchiveError.invalidSHA256(
                        file.relativePath
                    )
                }
                declaredBytes = try addingWithoutOverflow(
                    declaredBytes,
                    file.byteCount
                )
                declaredFileCount += 1
                guard
                    declaredBytes <= limits.maximumTotalBytes,
                    declaredFileCount <= limits.maximumFileCount
                else {
                    throw VoiceHistoryBackupArchiveError.archiveLimitExceeded
                }
            }
        }
        guard declaredBytes == manifest.totalBytes else {
            throw VoiceHistoryBackupArchiveError.invalidManifestCounts
        }

        let actualSessionDirectories = try safeContents(
            of: sessionsURL,
            relativeTo: packageURL,
            fileManager: fileManager
        )
        guard
            actualSessionDirectories.count == manifest.sessions.count
        else {
            throw VoiceHistoryBackupArchiveError.invalidManifestCounts
        }

        let entryByID = Dictionary(
            uniqueKeysWithValues: manifest.sessions.map {
                ($0.sessionID, $0)
            }
        )
        var validatedSessions: [VoiceHistoryBackupValidatedSession] = []
        var actualPaths = Set<String>()

        for directoryURL in actualSessionDirectories {
            let directoryName = directoryURL.lastPathComponent
            guard
                let sessionID = UUID(uuidString: directoryName),
                directoryName == canonicalUUID(sessionID)
            else {
                throw VoiceHistoryBackupArchiveError
                    .invalidSessionIdentifier(directoryName)
            }
            guard let entry = entryByID[sessionID] else {
                throw VoiceHistoryBackupArchiveError.unexpectedItem(
                    relativePath(of: directoryURL, from: packageURL)
                )
            }
            try requireDirectory(
                directoryURL,
                displayPath: relativePath(of: directoryURL, from: packageURL)
            )

            let inspected = try inspectSessionDirectory(
                directoryURL,
                sessionID: sessionID,
                relativePrefix: [
                    VoiceHistoryBackupFormat.sessionsDirectoryName,
                    directoryName,
                ].joined(separator: "/"),
                limits: limits,
                fileManager: fileManager
            )
            let entryPaths = Set(entry.files.map(\.relativePath))
            let inspectedPaths = Set(inspected.fileURLs.keys)
            guard entryPaths == inspectedPaths else {
                let unexpected = inspectedPaths
                    .subtracting(entryPaths)
                    .sorted()
                    .first
                if let unexpected {
                    throw VoiceHistoryBackupArchiveError.unexpectedItem(
                        unexpected
                    )
                }
                let missing = entryPaths
                    .subtracting(inspectedPaths)
                    .sorted()
                    .first ?? directoryName
                throw VoiceHistoryBackupArchiveError.missingRequiredItem(
                    missing
                )
            }

            let entriesByPath = Dictionary(
                uniqueKeysWithValues: entry.files.map {
                    ($0.relativePath, $0)
                }
            )
            for (path, fileURL) in inspected.fileURLs {
                guard let fileEntry = entriesByPath[path] else {
                    throw VoiceHistoryBackupArchiveError.unexpectedItem(path)
                }
                let size = try regularFileSize(fileURL)
                guard size == fileEntry.byteCount else {
                    throw VoiceHistoryBackupArchiveError.fileSizeMismatch(path)
                }
                let digest = try streamingSHA256(of: fileURL)
                guard digest.sha256 == fileEntry.sha256 else {
                    throw VoiceHistoryBackupArchiveError.fileHashMismatch(path)
                }
                actualPaths.insert(path)
            }
            validatedSessions.append(
                VoiceHistoryBackupValidatedSession(
                    sessionID: sessionID,
                    directoryURL: directoryURL,
                    files: entry.files
                )
            )
        }

        guard actualPaths == seenRelativePaths else {
            throw VoiceHistoryBackupArchiveError.invalidManifestCounts
        }
        return VoiceHistoryBackupValidationResult(
            packageURL: packageURL,
            manifest: manifest,
            sessions: validatedSessions.sorted {
                canonicalUUID($0.sessionID) <
                    canonicalUUID($1.sessionID)
            }
        )
    }

    /// Validates, stages and commits sessions one at a time.
    ///
    /// A process termination can leave already-moved sessions in place. A
    /// retry is safe because byte-identical sessions are skipped.
    public static func importValidatedBackup(
        _ validated: VoiceHistoryBackupValidationResult,
        destinationSessionsDirectory: URL,
        stagingParentDirectory: URL,
        allowedSourceBundleIdentifiers: Set<String>,
        availableCapacity: UInt64? = nil,
        storageSafetyMargin: UInt64 = 64 * 1_024 * 1_024,
        limits: VoiceHistoryBackupLimits = .standard,
        fileManager: FileManager = .default
    ) throws -> VoiceHistoryBackupImportResult {
        if
            !allowedSourceBundleIdentifiers.isEmpty,
            !allowedSourceBundleIdentifiers.contains(
                validated.manifest.sourceBundleIdentifier
            )
        {
            throw VoiceHistoryBackupArchiveError.invalidArchiveManifest
        }
        if let availableCapacity {
            let required = try addingWithoutOverflow(
                validated.manifest.totalBytes,
                storageSafetyMargin
            )
            guard availableCapacity >= required else {
                throw VoiceHistoryBackupArchiveError.insufficientStorage(
                    requiredBytes: required,
                    availableBytes: availableCapacity
                )
            }
        }

        try fileManager.createDirectory(
            at: destinationSessionsDirectory,
            withIntermediateDirectories: true
        )
        try requireDirectory(
            destinationSessionsDirectory,
            displayPath: destinationSessionsDirectory.lastPathComponent
        )
        try fileManager.createDirectory(
            at: stagingParentDirectory,
            withIntermediateDirectories: true
        )
        try requireDirectory(
            stagingParentDirectory,
            displayPath: stagingParentDirectory.lastPathComponent
        )

        let operationStagingURL = stagingParentDirectory
            .appendingPathComponent(
                Name.importStagingPrefix + UUID().uuidString.lowercased(),
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: operationStagingURL,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: operationStagingURL)
        }

        // Copy and re-validate every session before mutating the destination.
        var stagedURLs: [UUID: URL] = [:]
        for session in validated.sessions {
            let stagedURL = operationStagingURL.appendingPathComponent(
                canonicalUUID(session.sessionID),
                isDirectory: true
            )
            try fileManager.copyItem(
                at: session.directoryURL,
                to: stagedURL
            )
            try verifyStandaloneSession(
                directoryURL: stagedURL,
                entry: VoiceHistoryBackupSessionEntry(
                    sessionID: session.sessionID,
                    files: session.files
                ),
                limits: limits,
                fileManager: fileManager
            )
            stagedURLs[session.sessionID] = stagedURL
        }

        var imported: [UUID] = []
        var skipped: [UUID] = []
        var conflicts: [UUID] = []

        for session in validated.sessions {
            let destinationURL = destinationSessionsDirectory
                .appendingPathComponent(
                    canonicalUUID(session.sessionID),
                    isDirectory: true
                )
            if fileManager.fileExists(atPath: destinationURL.path) {
                if
                    try existingSessionMatches(
                        directoryURL: destinationURL,
                        entry: VoiceHistoryBackupSessionEntry(
                            sessionID: session.sessionID,
                            files: session.files
                        ),
                        limits: limits,
                        fileManager: fileManager
                    )
                {
                    skipped.append(session.sessionID)
                } else {
                    conflicts.append(session.sessionID)
                }
                continue
            }
            guard let stagedURL = stagedURLs[session.sessionID] else {
                throw VoiceHistoryBackupArchiveError
                    .missingRequiredItem(canonicalUUID(session.sessionID))
            }
            try fileManager.moveItem(
                at: stagedURL,
                to: destinationURL
            )
            imported.append(session.sessionID)
        }

        return VoiceHistoryBackupImportResult(
            importedSessionIDs: imported,
            skippedSessionIDs: skipped,
            conflictingSessionIDs: conflicts
        )
    }

    public static func streamingSHA256(
        of fileURL: URL,
        chunkSize: Int = 1_024 * 1_024
    ) throws -> (sha256: String, byteCount: UInt64) {
        precondition(chunkSize > 0)
        try requireRegularFile(
            fileURL,
            displayPath: fileURL.lastPathComponent
        )
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
            byteCount = try addingWithoutOverflow(
                byteCount,
                UInt64(data.count)
            )
        }
        let digest = hasher.finalize()
        return (
            digest.map { String(format: "%02x", $0) }.joined(),
            byteCount
        )
    }

    private static func inspectSourceSessions(
        at sessionsURL: URL,
        includeAudio: Bool,
        limits: VoiceHistoryBackupLimits,
        fileManager: FileManager
    ) throws -> [InspectedSession] {
        let items = try safeContents(
            of: sessionsURL,
            relativeTo: sessionsURL,
            fileManager: fileManager
        )
        var result: [InspectedSession] = []
        for item in items {
            let name = item.lastPathComponent
            guard
                let id = UUID(uuidString: name),
                name == canonicalUUID(id)
            else {
                throw VoiceHistoryBackupArchiveError
                    .invalidSessionIdentifier(name)
            }
            try requireDirectory(item, displayPath: name)
            let inspected = try inspectSessionDirectory(
                item,
                sessionID: id,
                relativePrefix: "",
                includeAudio: includeAudio,
                limits: limits,
                fileManager: fileManager
            )
            result.append(
                InspectedSession(
                    id: id,
                    directoryURL: item,
                    fileURLs: inspected.fileURLs
                )
            )
        }
        return result.sorted {
            canonicalUUID($0.id) < canonicalUUID($1.id)
        }
    }

    private static func inspectSessionDirectory(
        _ directoryURL: URL,
        sessionID: UUID,
        relativePrefix: String,
        includeAudio: Bool = true,
        limits: VoiceHistoryBackupLimits,
        fileManager: FileManager
    ) throws -> InspectedSession {
        try requireDirectory(
            directoryURL,
            displayPath: relativePrefix.isEmpty
                ? canonicalUUID(sessionID)
                : relativePrefix
        )
        let items = try safeContents(
            of: directoryURL,
            relativeTo: directoryURL,
            fileManager: fileManager
        )
        var fileURLs: [String: URL] = [:]
        var audioDirectoryURL: URL?

        for item in items {
            let name = item.lastPathComponent
            switch name {
            case Name.transcript, Name.diagnostics:
                try requireRegularFile(item, displayPath: name)
                let size = try regularFileSize(item)
                guard size <= limits.maximumMetadataFileBytes else {
                    throw VoiceHistoryBackupArchiveError.archiveLimitExceeded
                }
                fileURLs[path(relativePrefix, name)] = item
            case Name.audioManifest:
                guard includeAudio else { continue }
                try requireRegularFile(item, displayPath: name)
                let size = try regularFileSize(item)
                guard size <= limits.maximumMetadataFileBytes else {
                    throw VoiceHistoryBackupArchiveError.archiveLimitExceeded
                }
                fileURLs[path(relativePrefix, name)] = item
            case Name.audioDirectory:
                guard includeAudio else { continue }
                try requireDirectory(item, displayPath: name)
                audioDirectoryURL = item
            default:
                throw VoiceHistoryBackupArchiveError.unexpectedItem(
                    path(relativePrefix, name)
                )
            }
        }

        let transcriptPath = path(relativePrefix, Name.transcript)
        guard fileURLs[transcriptPath] != nil else {
            throw VoiceHistoryBackupArchiveError.missingRequiredItem(
                transcriptPath
            )
        }

        if let audioDirectoryURL {
            let audioItems = try safeContents(
                of: audioDirectoryURL,
                relativeTo: directoryURL,
                fileManager: fileManager
            )
            for audioURL in audioItems {
                try requireRegularFile(
                    audioURL,
                    displayPath: audioURL.lastPathComponent
                )
                guard
                    let parsed = RollingSegmentFileNaming.parse(
                        audioURL.lastPathComponent
                    ),
                    parsed.sessionID == sessionID,
                    parsed.fileExtension == "caf"
                else {
                    throw VoiceHistoryBackupArchiveError
                        .invalidAudioFileName(
                            path(
                                relativePrefix,
                                Name.audioDirectory,
                                audioURL.lastPathComponent
                            )
                        )
                }
                fileURLs[
                    path(
                        relativePrefix,
                        Name.audioDirectory,
                        audioURL.lastPathComponent
                    )
                ] = audioURL
            }
        }

        try validateSessionSemantics(
            sessionID: sessionID,
            fileURLs: fileURLs,
            relativePrefix: relativePrefix
        )
        return InspectedSession(
            id: sessionID,
            directoryURL: directoryURL,
            fileURLs: fileURLs
        )
    }

    private static func validateSessionSemantics(
        sessionID: UUID,
        fileURLs: [String: URL],
        relativePrefix: String
    ) throws {
        let transcriptPath = path(relativePrefix, Name.transcript)
        guard let transcriptURL = fileURLs[transcriptPath] else {
            throw VoiceHistoryBackupArchiveError.missingRequiredItem(
                transcriptPath
            )
        }
        let record: TranscriptSessionRecord
        do {
            record = try backupDecoder().decode(
                TranscriptSessionRecord.self,
                from: Data(contentsOf: transcriptURL)
            )
        } catch {
            throw VoiceHistoryBackupArchiveError.invalidSessionRecord(
                sessionID
            )
        }
        guard record.session.id == sessionID else {
            throw VoiceHistoryBackupArchiveError.invalidSessionRecord(
                sessionID
            )
        }
        guard record.session.state.isTerminal else {
            throw VoiceHistoryBackupArchiveError.nonTerminalSession(
                sessionID
            )
        }

        let manifestPath = path(relativePrefix, Name.audioManifest)
        let audioPrefix = path(relativePrefix, Name.audioDirectory) + "/"
        let audioPaths = fileURLs.keys
            .filter { $0.hasPrefix(audioPrefix) }
            .sorted()
        guard let audioManifestURL = fileURLs[manifestPath] else {
            if !audioPaths.isEmpty {
                throw VoiceHistoryBackupArchiveError.invalidAudioManifest(
                    sessionID
                )
            }
            return
        }

        let manifest: BackupAudioManifest
        do {
            manifest = try backupDecoder().decode(
                BackupAudioManifest.self,
                from: Data(contentsOf: audioManifestURL)
            )
        } catch {
            throw VoiceHistoryBackupArchiveError.invalidAudioManifest(
                sessionID
            )
        }
        guard
            manifest.schemaVersion == 1,
            manifest.sessionID == sessionID,
            manifest.updatedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw VoiceHistoryBackupArchiveError.invalidAudioManifest(
                sessionID
            )
        }

        var priorSequence: UInt64?
        var declaredAudioPaths = Set<String>()
        for segment in manifest.segments {
            guard
                segment.frameCount >= 0,
                segment.sampleRate.isFinite,
                segment.sampleRate > 0,
                segment.channelCount > 0
            else {
                throw VoiceHistoryBackupArchiveError.invalidAudioManifest(
                    sessionID
                )
            }
            if let priorSequence {
                guard segment.sequenceNumber > priorSequence else {
                    throw VoiceHistoryBackupArchiveError
                        .invalidAudioManifest(sessionID)
                }
            }
            priorSequence = segment.sequenceNumber
            guard
                let parsed = RollingSegmentFileNaming.parse(
                    segment.fileName
                ),
                parsed.sessionID == sessionID,
                parsed.fileExtension == "caf",
                parsed.sequenceNumber == segment.sequenceNumber,
                parsed.state == segment.state
            else {
                throw VoiceHistoryBackupArchiveError.invalidAudioFileName(
                    path(
                        relativePrefix,
                        Name.audioDirectory,
                        segment.fileName
                    )
                )
            }
            let audioPath = path(
                relativePrefix,
                Name.audioDirectory,
                segment.fileName
            )
            guard declaredAudioPaths.insert(audioPath).inserted else {
                throw VoiceHistoryBackupArchiveError.invalidAudioManifest(
                    sessionID
                )
            }
        }
        guard declaredAudioPaths == Set(audioPaths) else {
            throw VoiceHistoryBackupArchiveError.invalidAudioManifest(
                sessionID
            )
        }
    }

    private static func verifyStandaloneSession(
        directoryURL: URL,
        entry: VoiceHistoryBackupSessionEntry,
        limits: VoiceHistoryBackupLimits,
        fileManager: FileManager
    ) throws {
        let prefix = [
            VoiceHistoryBackupFormat.sessionsDirectoryName,
            canonicalUUID(entry.sessionID),
        ].joined(separator: "/")
        let inspected = try inspectSessionDirectory(
            directoryURL,
            sessionID: entry.sessionID,
            relativePrefix: prefix,
            limits: limits,
            fileManager: fileManager
        )
        let actualPaths = Set(inspected.fileURLs.keys)
        let declaredPaths = Set(entry.files.map(\.relativePath))
        guard actualPaths == declaredPaths else {
            throw VoiceHistoryBackupArchiveError.invalidManifestCounts
        }
        let entryByPath = Dictionary(
            uniqueKeysWithValues: entry.files.map {
                ($0.relativePath, $0)
            }
        )
        for (path, fileURL) in inspected.fileURLs {
            guard let expected = entryByPath[path] else {
                throw VoiceHistoryBackupArchiveError.unexpectedItem(path)
            }
            let digest = try streamingSHA256(of: fileURL)
            guard digest.byteCount == expected.byteCount else {
                throw VoiceHistoryBackupArchiveError.fileSizeMismatch(path)
            }
            guard digest.sha256 == expected.sha256 else {
                throw VoiceHistoryBackupArchiveError.fileHashMismatch(path)
            }
        }
    }

    private static func existingSessionMatches(
        directoryURL: URL,
        entry: VoiceHistoryBackupSessionEntry,
        limits: VoiceHistoryBackupLimits,
        fileManager: FileManager
    ) throws -> Bool {
        do {
            try verifyStandaloneSession(
                directoryURL: directoryURL,
                entry: entry,
                limits: limits,
                fileManager: fileManager
            )
            return true
        } catch {
            return false
        }
    }

    private static func validateManifestPath(
        _ relativePath: String,
        expectedSessionID: UUID
    ) throws {
        guard
            !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\\"),
            !relativePath.contains("\0")
        else {
            throw VoiceHistoryBackupArchiveError.invalidRelativePath(
                relativePath
            )
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard
            !components.contains(where: {
                $0.isEmpty || $0 == "." || $0 == ".."
            }),
            components.count == 3 || components.count == 4,
            components[0] ==
                VoiceHistoryBackupFormat.sessionsDirectoryName,
            components[1] == canonicalUUID(expectedSessionID)
        else {
            throw VoiceHistoryBackupArchiveError.invalidRelativePath(
                relativePath
            )
        }
        if components.count == 3 {
            guard [
                Name.transcript,
                Name.audioManifest,
                Name.diagnostics,
            ].contains(components[2]) else {
                throw VoiceHistoryBackupArchiveError.invalidRelativePath(
                    relativePath
                )
            }
        } else {
            guard
                components[2] == Name.audioDirectory,
                let parsed = RollingSegmentFileNaming.parse(components[3]),
                parsed.sessionID == expectedSessionID,
                parsed.fileExtension == "caf"
            else {
                throw VoiceHistoryBackupArchiveError.invalidRelativePath(
                    relativePath
                )
            }
        }
    }

    private static func safeContents(
        of directoryURL: URL,
        relativeTo rootURL: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        try requireDirectory(
            directoryURL,
            displayPath: relativePath(of: directoryURL, from: rootURL)
        )
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
            ],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for item in contents {
            try rejectLinkOrAlias(
                item,
                displayPath: relativePath(of: item, from: rootURL)
            )
        }
        return contents
    }

    private static func requireDirectory(
        _ url: URL,
        displayPath: String
    ) throws {
        try rejectLinkOrAlias(url, displayPath: displayPath)
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        guard values.isDirectory == true else {
            throw VoiceHistoryBackupArchiveError.packageMustBeDirectory
        }
    }

    private static func requireRegularFile(
        _ url: URL,
        displayPath: String
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceHistoryBackupArchiveError.missingRequiredItem(
                displayPath
            )
        }
        try rejectLinkOrAlias(url, displayPath: displayPath)
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey]
        )
        guard values.isRegularFile == true else {
            throw VoiceHistoryBackupArchiveError.unexpectedItem(displayPath)
        }
    }

    private static func rejectLinkOrAlias(
        _ url: URL,
        displayPath: String
    ) throws {
        let values = try url.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isAliasFileKey]
        )
        if values.isSymbolicLink == true {
            throw VoiceHistoryBackupArchiveError.symbolicLinkNotAllowed(
                displayPath
            )
        }
        if values.isAliasFile == true {
            throw VoiceHistoryBackupArchiveError.aliasNotAllowed(displayPath)
        }
    }

    private static func regularFileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else {
            throw VoiceHistoryBackupArchiveError.unexpectedItem(
                url.lastPathComponent
            )
        }
        return UInt64(size)
    }

    private static func relativePath(
        of url: URL,
        from rootURL: URL
    ) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        if itemPath == rootPath {
            return rootURL.lastPathComponent
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else {
            return itemPath
        }
        return String(itemPath.dropFirst(prefix.count))
    }

    private static func path(_ components: String...) -> String {
        components.filter { !$0.isEmpty }.joined(separator: "/")
    }

    private static func canonicalUUID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 &&
            value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }

    private static func addingWithoutOverflow(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw VoiceHistoryBackupArchiveError.archiveLimitExceeded
        }
        return result.partialValue
    }

    private static func backupEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func backupDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
