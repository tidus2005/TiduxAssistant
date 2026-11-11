#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFAudio
import CodexMobilityCore
import Foundation

enum MobileSessionStoreError: LocalizedError, Equatable, Sendable {
    case storageCapacityUnavailable
    case insufficientStorage(
        availableBytes: Int64,
        requiredBytes: Int64
    )

    var errorDescription: String? {
        switch self {
        case .storageCapacityUnavailable:
            return "无法读取设备可用空间，请释放一些存储空间后重试。"
        case let .insufficientStorage(availableBytes, requiredBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let available = formatter.string(fromByteCount: availableBytes)
            let required = formatter.string(fromByteCount: requiredBytes)
            return "可用空间仅 \(available)，至少需要 \(required) 才能安全保存本次录音。"
        }
    }
}

struct MobileAudioRecoverySummary: Equatable, Sendable {
    var recoveredManifestCount = 0
    var recoveredPartialSegmentCount = 0
    var unreadableFileCount = 0
    var structuralIssueCount = 0
}

struct MobileSessionLoadIssue: Equatable, Sendable {
    let directoryName: String
    let message: String
}

actor MobileSessionStore {
    nonisolated static let historyImportStagingPrefix =
        ".voice-history-external-import-"

    private enum HistoryBackup {
        static let sourceBundleIdentifier =
            "com.tidux.CodexWatchPet"
        static let allowedSourceBundleIdentifiers: Set<String> = [
            "com.tidux.FlowTypeMobile",
            sourceBundleIdentifier,
        ]
    }

    private enum FileName {
        static let transcript = "session.json"
        static let audioManifest = "audio-manifest.json"
        static let diagnostics = "diagnostics.json"
        static let audioDirectory = "Audio"
    }

    private let rootDirectory: URL
    private let historyBackupStagingDirectory: URL
    private let fileManager: FileManager
    private let capacityProvider:
        (@Sendable (URL) throws -> Int64)?
    private var mostRecentLoadIssues: [MobileSessionLoadIssue] = []

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        capacityProvider:
            (@Sendable (URL) throws -> Int64)? = nil,
        historyBackupStagingDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.capacityProvider = capacityProvider
        if let rootDirectory {
            self.rootDirectory = rootDirectory
            self.historyBackupStagingDirectory =
                historyBackupStagingDirectory
                    ?? rootDirectory.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".VoiceHistoryExports",
                            isDirectory: true
                        )
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.rootDirectory = applicationSupport
                .appendingPathComponent("Codex Watch Pet", isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
            let caches = fileManager.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.historyBackupStagingDirectory =
                historyBackupStagingDirectory
                    ?? caches
                        .appendingPathComponent(
                            "Codex Watch Pet",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "VoiceHistoryExports",
                            isDirectory: true
                        )
        }
    }

    func availableCapacityForImportantUsage() throws -> Int64 {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        if let capacityProvider {
            return try capacityProvider(rootDirectory)
        }
        let values = try rootDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard
            let available =
                values.volumeAvailableCapacityForImportantUsage
        else {
            throw MobileSessionStoreError.storageCapacityUnavailable
        }
        return available
    }

    @discardableResult
    func ensureRecordingCapacity(minimumBytes: Int64) throws -> Int64 {
        let available = try availableCapacityForImportantUsage()
        guard available >= minimumBytes else {
            throw MobileSessionStoreError.insufficientStorage(
                availableBytes: available,
                requiredBytes: minimumBytes
            )
        }
        return available
    }

    func prepareSessionDirectory(sessionID: UUID) throws -> URL {
        let directory = sessionDirectory(sessionID: sessionID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func audioDirectory(sessionID: UUID) throws -> URL {
        let directory = try prepareSessionDirectory(sessionID: sessionID)
            .appendingPathComponent(
                FileName.audioDirectory,
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func save(_ record: TranscriptSessionRecord) throws {
        let directory = try prepareSessionDirectory(
            sessionID: record.session.id
        )
        let url = directory.appendingPathComponent(FileName.transcript)
        try Self.encoder().encode(record).write(
            to: url,
            options: .atomic
        )
    }

    func save(_ manifest: MobileAudioManifest) throws {
        let directory = try prepareSessionDirectory(
            sessionID: manifest.sessionID
        )
        let url = directory.appendingPathComponent(FileName.audioManifest)
        try Self.encoder().encode(manifest).write(
            to: url,
            options: .atomic
        )
    }

    func saveDiagnosticReport(
        _ report: String,
        sessionID: UUID
    ) throws {
        let directory = try prepareSessionDirectory(
            sessionID: sessionID
        )
        let url = directory.appendingPathComponent(
            FileName.diagnostics
        )
        try Data(report.utf8).write(to: url, options: .atomic)
    }

    func deleteSession(sessionID: UUID) throws {
        let directory = sessionDirectory(sessionID: sessionID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    func loadAll() throws -> [TranscriptSessionRecord] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            mostRecentLoadIssues = []
            return []
        }

        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var records: [TranscriptSessionRecord] = []
        var issues: [MobileSessionLoadIssue] = []
        for directory in directories {
            do {
                let values = try directory.resourceValues(
                    forKeys: [.isDirectoryKey]
                )
                guard values.isDirectory == true else { continue }
                let url = directory.appendingPathComponent(
                    FileName.transcript
                )
                guard
                    fileManager.fileExists(atPath: url.path)
                else {
                    continue
                }
                let data = try Data(contentsOf: url)
                records.append(
                    try Self.decoder().decode(
                        TranscriptSessionRecord.self,
                        from: data
                    )
                )
            } catch {
                issues.append(
                    MobileSessionLoadIssue(
                        directoryName: directory.lastPathComponent,
                        message: error.localizedDescription
                    )
                )
            }
        }
        mostRecentLoadIssues = issues
        return records.sorted {
            $0.session.createdAt > $1.session.createdAt
        }
    }

    func loadIssues() -> [MobileSessionLoadIssue] {
        mostRecentLoadIssues
    }

    /// Produces a self-contained backup from the recovered local history.
    ///
    /// Interrupted sessions and durable CAF files are normalized before the
    /// archive engine scans the tree, so the combined App can back up both
    /// newly recorded history and records imported from legacy FlowType.
    func createHistoryBackup(
        stagingParentDirectory: URL? = nil,
        includeAudio: Bool,
        sourceAppVersion: String,
        sourceAppBuild: String
    ) throws -> VoiceHistoryBackupExport {
        let records = try recoverInterruptedSessions()
        _ = try recoverAudioManifests(for: records)
        let stagingDirectory =
            stagingParentDirectory ?? historyBackupStagingDirectory
        if stagingParentDirectory == nil {
            try cleanupHistoryBackupStaging()
        }
        return try VoiceHistoryBackupArchive.createStagedBackup(
            sourceSessionsDirectory: rootDirectory,
            stagingParentDirectory: stagingDirectory,
            includeAudio: includeAudio,
            sourceBundleIdentifier:
                HistoryBackup.sourceBundleIdentifier,
            sourceAppVersion: sourceAppVersion,
            sourceAppBuild: sourceAppBuild,
            fileManager: fileManager
        )
    }

    /// Removes only packages owned by a previous in-App export attempt.
    ///
    /// The current package intentionally survives the share sheet. Cleanup is
    /// deferred until the next launch or export so a File Provider can finish
    /// copying it after the user chooses a destination.
    func cleanupHistoryBackupStaging() throws {
        guard fileManager.fileExists(
            atPath: historyBackupStagingDirectory.path
        ) else {
            return
        }
        let items = try fileManager.contentsOfDirectory(
            at: historyBackupStagingDirectory,
            includingPropertiesForKeys: nil
        )
        for item in items where
            item.lastPathComponent.hasPrefix("FlowType-History-") &&
            item.pathExtension ==
                VoiceHistoryBackupFormat.fileExtension
        {
            try fileManager.removeItem(at: item)
        }
    }

    /// Imports a user-selected FlowType package through an app-owned snapshot.
    ///
    /// The security-scoped, coordinated access window only copies the package.
    /// Validation and import happen after that external access has ended, so a
    /// File Provider cannot change bytes between validation and staging.
    func importHistoryBackup(
        from packageURL: URL
    ) throws -> VoiceHistoryBackupImportResult {
        let stagingParentDirectory =
            rootDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: stagingParentDirectory,
            withIntermediateDirectories: true
        )
        try removeInterruptedHistoryImportStaging(
            in: stagingParentDirectory
        )
        guard
            packageURL.pathExtension ==
                VoiceHistoryBackupFormat.fileExtension
        else {
            throw VoiceHistoryBackupArchiveError
                .invalidPackageExtension
        }

        let operationDirectory = stagingParentDirectory
            .appendingPathComponent(
                Self.historyImportStagingPrefix
                    + UUID().uuidString.lowercased(),
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: operationDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? fileManager.removeItem(at: operationDirectory)
        }

        let localPackageURL = operationDirectory
            .appendingPathComponent(
                "SelectedHistory",
                isDirectory: true
            )
            .appendingPathExtension(
                VoiceHistoryBackupFormat.fileExtension
            )
        try copyCoordinatedHistoryBackup(
            from: packageURL,
            to: localPackageURL
        )

        let validated = try VoiceHistoryBackupArchive.validate(
            packageURL: localPackageURL,
            fileManager: fileManager
        )
        let available = try availableCapacityForImportantUsage()
        guard available >= 0 else {
            throw MobileSessionStoreError.storageCapacityUnavailable
        }
        return try VoiceHistoryBackupArchive.importValidatedBackup(
            validated,
            destinationSessionsDirectory: rootDirectory,
            stagingParentDirectory: operationDirectory,
            allowedSourceBundleIdentifiers:
                HistoryBackup.allowedSourceBundleIdentifiers,
            availableCapacity: UInt64(available),
            fileManager: fileManager
        )
    }

    private func copyCoordinatedHistoryBackup(
        from externalURL: URL,
        to localURL: URL
    ) throws {
        let hasSecurityScope =
            externalURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                externalURL.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyResult: Result<Void, Error>?
        coordinator.coordinate(
            readingItemAt: externalURL,
            options: [.withoutChanges],
            error: &coordinationError
        ) { coordinatedURL in
            copyResult = Result {
                try fileManager.copyItem(
                    at: coordinatedURL,
                    to: localURL
                )
            }
        }

        if let copyResult {
            return try copyResult.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func removeInterruptedHistoryImportStaging(
        in stagingParentDirectory: URL
    ) throws {
        let items = try fileManager.contentsOfDirectory(
            at: stagingParentDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in items where
            item.lastPathComponent.hasPrefix(
                Self.historyImportStagingPrefix
            )
        {
            try fileManager.removeItem(at: item)
        }
    }

    /// Marks sessions left active by a terminated process as failed while
    /// preserving their last partial text as a durable final segment.
    @discardableResult
    func recoverInterruptedSessions() throws -> [TranscriptSessionRecord] {
        var records = try loadAll()
        var changed = false

        for index in records.indices where
            !records[index].session.state.isTerminal {
            do {
                var session = records[index].session
                var assembler = TranscriptAssembler(
                    record: records[index]
                )
                _ = try assembler.commitPartial()
                let timestamp = max(Date(), session.updatedAt)
                try session.transition(
                    to: .failed,
                    at: timestamp,
                    failure: RecordingSessionFailure(
                        code: "process_interrupted",
                        message:
                            "上一次录音未正常结束，已保留当时的音频和文字。"
                    )
                )
                let recovered = try assembler.record(for: session)
                try save(recovered)
                records[index] = recovered
                changed = true
            } catch {
                mostRecentLoadIssues.append(
                    MobileSessionLoadIssue(
                        directoryName:
                            records[index].session.id.uuidString
                                .lowercased(),
                        message: error.localizedDescription
                    )
                )
            }
        }

        if changed {
            records.sort {
                $0.session.createdAt > $1.session.createdAt
            }
        }
        return records
    }

    func loadAudioManifest(sessionID: UUID) throws
        -> MobileAudioManifest?
    {
        let url = sessionDirectory(sessionID: sessionID)
            .appendingPathComponent(FileName.audioManifest)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder().decode(
            MobileAudioManifest.self,
            from: Data(contentsOf: url)
        )
    }

    /// Rebuilds missing manifests from durable CAF and CAF.partial files.
    ///
    /// No source audio is deleted or renamed. A partial segment remains
    /// explicitly marked partial so the history screen never presents an
    /// interrupted file as a fully committed recording.
    func recoverAudioManifests(
        for records: [TranscriptSessionRecord]
    ) throws -> MobileAudioRecoverySummary {
        var summary = MobileAudioRecoverySummary()

        for record in records {
            let sessionID = record.session.id
            let sessionDirectory = sessionDirectory(sessionID: sessionID)
            let manifestURL = sessionDirectory
                .appendingPathComponent(FileName.audioManifest)
            let audioDirectory = sessionDirectory.appendingPathComponent(
                FileName.audioDirectory,
                isDirectory: true
            )
            let hasAudioDirectory = fileManager.fileExists(
                atPath: audioDirectory.path
            )
            let recovery: RollingSegmentRecoveryManifest?
            if hasAudioDirectory {
                let names = try fileManager.contentsOfDirectory(
                    atPath: audioDirectory.path
                )
                recovery = try RollingSegmentRecoveryManifest.build(
                    fileNames: names,
                    sessionID: sessionID,
                    fileExtension: "caf"
                )
            } else {
                recovery = nil
            }

            if let recovery {
                summary.structuralIssueCount +=
                    recovery.stalePartialFileNames.count +
                    recovery.duplicateSequenceNumbers.count +
                    recovery.missingSequenceRanges.count
            }

            if fileManager.fileExists(atPath: manifestURL.path) {
                do {
                    let manifest = try Self.decoder().decode(
                        MobileAudioManifest.self,
                        from: Data(contentsOf: manifestURL)
                    )
                    if manifest.sessionID == sessionID {
                        if let recovery {
                            let recoverableFiles =
                                recovery.committedFiles +
                                recovery.incompleteFiles
                            let recoverableNames = Set(
                                recoverableFiles.map(\.fileName)
                            )
                            let manifestNames = Set(
                                manifest.segments.map(\.fileName)
                            )
                            if
                                manifest.segments.count ==
                                    recoverableFiles.count,
                                manifestNames == recoverableNames
                            {
                                continue
                            }
                        } else if manifest.segments.isEmpty {
                            continue
                        }
                    }
                } catch {
                    // A damaged manifest must not prevent recovery from the
                    // durable source audio files below.
                }
                summary.structuralIssueCount += 1
            }

            guard let recovery else { continue }
            let files =
                recovery.committedFiles +
                recovery.incompleteFiles
            var segments: [MobileAudioSegment] = []

            for file in files.sorted(by: {
                $0.sequenceNumber < $1.sequenceNumber
            }) {
                let url = audioDirectory.appendingPathComponent(
                    file.fileName
                )
                do {
                    let audioFile = try AVAudioFile(forReading: url)
                    segments.append(
                        MobileAudioSegment(
                            sequenceNumber: file.sequenceNumber,
                            fileName: file.fileName,
                            state: file.state,
                            frameCount: Int64(audioFile.length),
                            sampleRate:
                                audioFile.fileFormat.sampleRate,
                            channelCount:
                                audioFile.fileFormat.channelCount
                        )
                    )
                    if file.state == .partial {
                        summary.recoveredPartialSegmentCount += 1
                    }
                } catch {
                    summary.unreadableFileCount += 1
                }
            }

            guard !segments.isEmpty else { continue }
            try save(
                MobileAudioManifest(
                    sessionID: sessionID,
                    segments: segments
                )
            )
            summary.recoveredManifestCount += 1
        }

        return summary
    }

    private func sessionDirectory(sessionID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
