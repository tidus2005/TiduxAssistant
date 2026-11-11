import AVFAudio
import CodexMobilityCore
import Foundation
import XCTest
@testable import CodexMobilityPhoneFeature

@MainActor
final class MobileSessionStoreTests: XCTestCase {
    private enum TestError: Error {
        case couldNotCreateAudioFormat
        case couldNotCreateAudioBuffer
    }

    func testRecordingCapacityPreflightUsesObservableThreshold()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MobileSessionStore(
            rootDirectory: root,
            capacityProvider: { _ in 128 * 1_024 * 1_024 }
        )

        let available = try await store
            .availableCapacityForImportantUsage()
        XCTAssertEqual(available, 128 * 1_024 * 1_024)
        let acceptedCapacity = try await store.ensureRecordingCapacity(
            minimumBytes: 64 * 1_024 * 1_024
        )
        XCTAssertEqual(acceptedCapacity, available)

        do {
            _ = try await store.ensureRecordingCapacity(
                minimumBytes: 256 * 1_024 * 1_024
            )
            XCTFail("空间不足时必须阻止开始录音")
        } catch let error as MobileSessionStoreError {
            XCTAssertEqual(
                error,
                .insufficientStorage(
                    availableBytes: available,
                    requiredBytes: 256 * 1_024 * 1_024
                )
            )
        }
    }

    func testSaveAndLoadRecordsAndAudioManifest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MobileSessionStore(rootDirectory: root)
        let older = try makeCompletedRecord(
            sessionID: UUID(
                uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
            )!,
            createdAt: Date(timeIntervalSince1970: 1_000),
            text: "较早的记录"
        )
        let newer = try makeCompletedRecord(
            sessionID: UUID(
                uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
            )!,
            createdAt: Date(timeIntervalSince1970: 2_000),
            text: "较新的记录"
        )

        try await store.save(older)
        try await store.save(newer)

        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded, [newer, older])

        let manifest = MobileAudioManifest(
            sessionID: newer.session.id,
            updatedAt: Date(timeIntervalSince1970: 2_010),
            segments: [
                MobileAudioSegment(
                    sequenceNumber: 0,
                    fileName: "segment.caf",
                    state: .committed,
                    frameCount: 16_000,
                    sampleRate: 16_000,
                    channelCount: 1
                ),
            ]
        )
        try await store.save(manifest)

        let loadedManifest = try await store.loadAudioManifest(
            sessionID: newer.session.id
        )
        XCTAssertEqual(loadedManifest, manifest)
    }

    func testDeleteSessionRemovesTranscriptAudioAndDiagnostics()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MobileSessionStore(rootDirectory: root)
        let record = try makeCompletedRecord(
            sessionID: UUID(),
            createdAt: Date(timeIntervalSince1970: 2_200),
            text: "待删除"
        )
        try await store.save(record)
        let audioDirectory = try await store.audioDirectory(
            sessionID: record.id
        )
        try Data("audio".utf8).write(
            to: audioDirectory.appendingPathComponent(
                "test.caf.partial"
            )
        )
        try await store.saveDiagnosticReport(
            "{\"test\":true}",
            sessionID: record.id
        )

        try await store.deleteSession(sessionID: record.id)

        let remainingRecords = try await store.loadAll()
        let remainingManifest = try await store.loadAudioManifest(
            sessionID: record.id
        )
        XCTAssertTrue(remainingRecords.isEmpty)
        XCTAssertNil(remainingManifest)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: audioDirectory
                    .deletingLastPathComponent()
                    .path
            )
        )
        try await store.deleteSession(sessionID: record.id)
    }

    func testCorruptSessionIsIsolatedFromValidHistory()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MobileSessionStore(rootDirectory: root)
        let valid = try makeCompletedRecord(
            sessionID: UUID(),
            createdAt: Date(timeIntervalSince1970: 2_500),
            text: "仍然可见"
        )
        try await store.save(valid)

        let corruptDirectory = root.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: corruptDirectory,
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(
            to: corruptDirectory.appendingPathComponent(
                "session.json"
            ),
            options: .atomic
        )

        let loaded = try await store.loadAll()
        let issues = await store.loadIssues()

        XCTAssertEqual(loaded, [valid])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(
            issues[0].directoryName,
            corruptDirectory.lastPathComponent
        )
    }

    func testRecoverInterruptedSessionCommitsPartialAndPersistsFailure()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MobileSessionStore(rootDirectory: root)
        let interruptedID = UUID(
            uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        )!
        let origin = Date(timeIntervalSince1970: 3_000)

        var interruptedSession = RecordingSession(
            id: interruptedID,
            localeIdentifier: "zh-CN",
            createdAt: origin
        )
        try interruptedSession.transition(
            to: .recording,
            at: origin.addingTimeInterval(1)
        )
        let interruptedRecord = try TranscriptSessionRecord(
            session: interruptedSession,
            segments: [
                try TranscriptSegment(
                    sessionID: interruptedID,
                    sequenceNumber: 0,
                    kind: .final,
                    text: "已经完成。",
                    capturedAt: origin.addingTimeInterval(2)
                ),
                try TranscriptSegment(
                    sessionID: interruptedID,
                    sequenceNumber: 1,
                    kind: .partial,
                    text: "最后一段尚未落盘",
                    capturedAt: origin.addingTimeInterval(3)
                ),
            ]
        )
        let completed = try makeCompletedRecord(
            sessionID: UUID(
                uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
            )!,
            createdAt: Date(timeIntervalSince1970: 4_000),
            text: "正常结束"
        )

        try await store.save(interruptedRecord)
        try await store.save(completed)

        let recoveredRecords = try await store.recoverInterruptedSessions()
        let recovered = try XCTUnwrap(
            recoveredRecords.first {
                $0.session.id == interruptedID
            }
        )

        XCTAssertEqual(recovered.session.state, .failed)
        XCTAssertEqual(recovered.session.failure?.code, "process_interrupted")
        XCTAssertEqual(
            recovered.session.failure?.message,
            "上一次录音未正常结束，已保留当时的音频和文字。"
        )
        XCTAssertNotNil(recovered.session.endedAt)
        XCTAssertGreaterThanOrEqual(
            recovered.session.updatedAt,
            interruptedSession.updatedAt
        )
        XCTAssertEqual(recovered.segments.map(\.kind), [.final, .final])
        XCTAssertEqual(
            recovered.segments.map(\.text),
            ["已经完成。", "最后一段尚未落盘"]
        )
        XCTAssertEqual(recovered.partialText, "")
        XCTAssertEqual(recovered.text, "已经完成。最后一段尚未落盘")

        let untouched = try XCTUnwrap(
            recoveredRecords.first {
                $0.session.id == completed.session.id
            }
        )
        XCTAssertEqual(untouched, completed)

        let persistedRecords = try await store.loadAll()
        let persisted = try XCTUnwrap(
            persistedRecords.first {
                $0.session.id == interruptedID
            }
        )
        XCTAssertEqual(persisted.session.state, .failed)
        XCTAssertEqual(persisted.session.failure?.code, "process_interrupted")
        XCTAssertEqual(persisted.segments.map(\.kind), [.final, .final])
        XCTAssertEqual(persisted.text, "已经完成。最后一段尚未落盘")
    }

    func testRecoverPreparingCheckpointAsFailedSession() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = RecordingSession(
            localeIdentifier: "zh-CN",
            createdAt: Date(timeIntervalSince1970: 5_000)
        )
        let record = try TranscriptSessionRecord(
            session: session,
            segments: []
        )
        let store = MobileSessionStore(rootDirectory: root)
        try await store.save(record)

        let recoveredRecords =
            try await store.recoverInterruptedSessions()
        let recovered = try XCTUnwrap(
            recoveredRecords.first {
                $0.session.id == session.id
            }
        )

        XCTAssertEqual(recovered.session.state, .failed)
        XCTAssertEqual(
            recovered.session.failure?.code,
            "process_interrupted"
        )
        XCTAssertTrue(recovered.segments.isEmpty)
    }

    func testRecoverAudioManifestPreservesPartialCAF() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID(
            uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        )!
        let origin = Date(timeIntervalSince1970: 6_000)
        var session = RecordingSession(
            id: sessionID,
            localeIdentifier: "zh-CN",
            createdAt: origin
        )
        try session.transition(
            to: .recording,
            at: origin.addingTimeInterval(1)
        )
        let record = try TranscriptSessionRecord(
            session: session,
            segments: []
        )
        let store = MobileSessionStore(rootDirectory: root)
        try await store.save(record)

        let audioDirectory = try await store.audioDirectory(
            sessionID: sessionID
        )
        let recorder = try RollingAudioRecorder(
            sessionID: sessionID,
            directoryURL: audioDirectory,
            segmentDuration: 60
        )
        let buffer = try makeAudioBuffer(
            sampleRate: 8_000,
            frameCount: 800
        )
        XCTAssertTrue(recorder.offer(buffer))
        let originalSegments = try await recorder.finish(
            commitCurrentSegment: false
        )
        XCTAssertEqual(originalSegments.map(\.state), [.partial])
        let manifestBeforeRecovery =
            try await store.loadAudioManifest(sessionID: sessionID)
        XCTAssertNil(manifestBeforeRecovery)

        let recoveredRecords =
            try await store.recoverInterruptedSessions()
        let summary = try await store.recoverAudioManifests(
            for: recoveredRecords
        )

        XCTAssertEqual(summary.recoveredManifestCount, 1)
        XCTAssertEqual(summary.recoveredPartialSegmentCount, 1)
        XCTAssertEqual(summary.unreadableFileCount, 0)
        let loadedManifest =
            try await store.loadAudioManifest(sessionID: sessionID)
        let manifest = try XCTUnwrap(loadedManifest)
        XCTAssertEqual(manifest.segments.count, 1)
        XCTAssertEqual(manifest.segments[0].state, .partial)
        XCTAssertEqual(manifest.segments[0].frameCount, 800)
        XCTAssertEqual(manifest.segments[0].sampleRate, 8_000)
    }

    func testRecoverAudioManifestRebuildsEmptyAndStaleFileLists()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID(
            uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
        )!
        let record = try makeCompletedRecord(
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: 6_500),
            text: "空清单不能遮住已有录音"
        )
        let store = MobileSessionStore(rootDirectory: root)
        try await store.save(record)

        let audioDirectory = try await store.audioDirectory(
            sessionID: sessionID
        )
        let recorder = try RollingAudioRecorder(
            sessionID: sessionID,
            directoryURL: audioDirectory,
            segmentDuration: 60
        )
        let buffer = try makeAudioBuffer(
            sampleRate: 8_000,
            frameCount: 800
        )
        XCTAssertTrue(recorder.offer(buffer))
        let originalSegments = try await recorder.finish(
            commitCurrentSegment: true
        )
        let originalSegment = try XCTUnwrap(originalSegments.first)
        let sourceURL = audioDirectory.appendingPathComponent(
            originalSegment.fileName
        )
        let sourceData = try Data(contentsOf: sourceURL)

        try await store.save(
            MobileAudioManifest(
                sessionID: sessionID,
                segments: []
            )
        )
        let emptySummary = try await store.recoverAudioManifests(
            for: [record]
        )
        XCTAssertEqual(emptySummary.recoveredManifestCount, 1)
        XCTAssertEqual(emptySummary.structuralIssueCount, 1)
        let recoveredEmptyManifest = try await store.loadAudioManifest(
            sessionID: sessionID
        )
        XCTAssertEqual(
            recoveredEmptyManifest?.segments.map(\.fileName),
            [originalSegment.fileName]
        )

        let staleFileName = try RollingSegmentFileNaming.fileName(
            sessionID: sessionID,
            sequenceNumber: 1,
            fileExtension: "caf",
            state: .committed
        )
        try await store.save(
            MobileAudioManifest(
                sessionID: sessionID,
                segments: [
                    MobileAudioSegment(
                        sequenceNumber: 1,
                        fileName: staleFileName,
                        state: .committed,
                        frameCount: 800,
                        sampleRate: 8_000,
                        channelCount: 1
                    ),
                ]
            )
        )
        let staleSummary = try await store.recoverAudioManifests(
            for: [record]
        )
        XCTAssertEqual(staleSummary.recoveredManifestCount, 1)
        XCTAssertEqual(staleSummary.structuralIssueCount, 1)
        let recoveredStaleManifest = try await store.loadAudioManifest(
            sessionID: sessionID
        )
        XCTAssertEqual(
            recoveredStaleManifest?.segments.map(\.fileName),
            [originalSegment.fileName]
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testRecoverAudioManifestRebuildsCorruptManifestWithoutMutatingCAF()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID(
            uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
        )!
        let record = try makeCompletedRecord(
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: 7_000),
            text: "需要恢复音频清单"
        )
        let store = MobileSessionStore(rootDirectory: root)
        try await store.save(record)

        let audioDirectory = try await store.audioDirectory(
            sessionID: sessionID
        )
        let recorder = try RollingAudioRecorder(
            sessionID: sessionID,
            directoryURL: audioDirectory,
            segmentDuration: 60
        )
        let buffer = try makeAudioBuffer(
            sampleRate: 8_000,
            frameCount: 800
        )
        XCTAssertTrue(recorder.offer(buffer))
        let originalSegments = try await recorder.finish(
            commitCurrentSegment: true
        )
        XCTAssertEqual(originalSegments.map(\.state), [.committed])

        let sourceURL = audioDirectory.appendingPathComponent(
            try XCTUnwrap(originalSegments.first).fileName
        )
        let sourceData = try Data(contentsOf: sourceURL)
        let manifestURL = root
            .appendingPathComponent(
                sessionID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("audio-manifest.json")
        try Data("{not-json".utf8).write(
            to: manifestURL,
            options: .atomic
        )

        let summary = try await store.recoverAudioManifests(
            for: [record]
        )

        XCTAssertEqual(summary.recoveredManifestCount, 1)
        XCTAssertEqual(summary.structuralIssueCount, 1)
        XCTAssertEqual(summary.unreadableFileCount, 0)
        let loadedManifest = try await store.loadAudioManifest(
            sessionID: sessionID
        )
        let manifest = try XCTUnwrap(loadedManifest)
        XCTAssertEqual(manifest.sessionID, sessionID)
        XCTAssertEqual(manifest.segments.count, 1)
        XCTAssertEqual(
            manifest.segments[0].fileName,
            sourceURL.lastPathComponent
        )
        XCTAssertEqual(manifest.segments[0].state, .committed)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))

        let mismatchedManifest = MobileAudioManifest(
            sessionID: UUID(),
            segments: manifest.segments
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(mismatchedManifest).write(
            to: manifestURL,
            options: .atomic
        )

        let mismatchedSummary = try await store.recoverAudioManifests(
            for: [record]
        )
        XCTAssertEqual(mismatchedSummary.recoveredManifestCount, 1)
        XCTAssertEqual(mismatchedSummary.structuralIssueCount, 1)
        let rebuiltManifest = try await store.loadAudioManifest(
            sessionID: sessionID
        )
        XCTAssertEqual(rebuiltManifest?.sessionID, sessionID)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testHistoryImportCopiesExternalPackageAndRefreshesModel()
        async throws
    {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceRoot = workspace.appendingPathComponent(
            "LegacySessions",
            isDirectory: true
        )
        let destinationRoot = workspace.appendingPathComponent(
            "CurrentSessions",
            isDirectory: true
        )
        let backupStaging = workspace.appendingPathComponent(
            "BackupStaging",
            isDirectory: true
        )
        let sourceStore = MobileSessionStore(
            rootDirectory: sourceRoot
        )
        let record = try makeCompletedRecord(
            sessionID: UUID(
                uuidString:
                    "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD"
            )!,
            createdAt: Date(timeIntervalSince1970: 9_000),
            text: "从 FlowType 迁移的记录"
        )
        try await sourceStore.save(record)
        let export = try VoiceHistoryBackupArchive
            .createStagedBackup(
                sourceSessionsDirectory: sourceRoot,
                stagingParentDirectory: backupStaging,
                includeAudio: false,
                sourceBundleIdentifier:
                    "com.tidux.FlowTypeMobile",
                sourceAppVersion: "1.0",
                sourceAppBuild: "1"
            )

        let destinationStore = MobileSessionStore(
            rootDirectory: destinationRoot,
            capacityProvider: { _ in 1_024 * 1_024 * 1_024 }
        )
        let model = MobileAppModel(
            sessionStore: destinationStore
        )
        let result = try await model.importHistoryBackup(
            from: export.packageURL
        )

        XCTAssertEqual(result.importedSessionIDs, [record.id])
        XCTAssertTrue(result.skippedSessionIDs.isEmpty)
        XCTAssertTrue(result.conflictingSessionIDs.isEmpty)
        XCTAssertEqual(model.history, [record])
        let persistedHistory = try await destinationStore.loadAll()
        XCTAssertEqual(persistedHistory, [record])
        XCTAssertFalse(model.isHistoryTransferInProgress)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: export.packageURL.path
            )
        )
        XCTAssertTrue(
            try historyImportStagingItems(in: workspace).isEmpty
        )
    }

    func testHistoryImportCleansStaleAndFailedOperationStaging()
        async throws
    {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let destinationRoot = workspace.appendingPathComponent(
            "CurrentSessions",
            isDirectory: true
        )
        let staleDirectory = workspace.appendingPathComponent(
            MobileSessionStore.historyImportStagingPrefix
                + "interrupted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staleDirectory,
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(
            to: staleDirectory.appendingPathComponent("partial-copy")
        )
        let invalidExternalPackage = workspace
            .appendingPathComponent(
                "InvalidExternal",
                isDirectory: true
            )
            .appendingPathExtension("flowtypebackup")
        try FileManager.default.createDirectory(
            at: invalidExternalPackage,
            withIntermediateDirectories: true
        )
        try Data("invalid".utf8).write(
            to: invalidExternalPackage.appendingPathComponent(
                "unexpected-file"
            )
        )
        let store = MobileSessionStore(
            rootDirectory: destinationRoot,
            capacityProvider: { _ in 1_024 * 1_024 * 1_024 }
        )

        do {
            _ = try await store.importHistoryBackup(
                from: invalidExternalPackage
            )
            XCTFail("无效外部包必须在本地副本校验阶段被拒绝")
        } catch let error as VoiceHistoryBackupArchiveError {
            XCTAssertEqual(
                error,
                .unexpectedItem("unexpected-file")
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staleDirectory.path
            )
        )
        XCTAssertTrue(
            try historyImportStagingItems(in: workspace).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: invalidExternalPackage.path
            )
        )
    }

    func testCurrentAppHistoryExportRoundTripsIntoFreshStore()
        async throws
    {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceRoot = workspace.appendingPathComponent(
            "SourceSessions",
            isDirectory: true
        )
        let destinationRoot = workspace.appendingPathComponent(
            "DestinationSessions",
            isDirectory: true
        )
        let staging = workspace.appendingPathComponent(
            "BackupStaging",
            isDirectory: true
        )
        let sourceStore = MobileSessionStore(rootDirectory: sourceRoot)
        let record = try makeCompletedRecord(
            sessionID: UUID(
                uuidString:
                    "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB"
            )!,
            createdAt: Date(timeIntervalSince1970: 9_500),
            text: "合并后的 App 也能备份自己的历史"
        )
        try await sourceStore.save(record)

        let sourceModel = MobileAppModel(sessionStore: sourceStore)
        let export = try await sourceModel.exportHistoryBackup(
            includeAudio: false,
            stagingParentDirectory: staging
        )

        XCTAssertEqual(
            export.manifest.sourceBundleIdentifier,
            "com.tidux.CodexWatchPet"
        )
        XCTAssertEqual(export.manifest.sessions.map(\.sessionID), [record.id])
        let validated = try VoiceHistoryBackupArchive.validate(
            packageURL: export.packageURL
        )
        XCTAssertEqual(validated.manifest, export.manifest)

        let destinationStore = MobileSessionStore(
            rootDirectory: destinationRoot,
            capacityProvider: { _ in 1_024 * 1_024 * 1_024 }
        )
        let destinationModel = MobileAppModel(
            sessionStore: destinationStore
        )
        let firstImport = try await destinationModel.importHistoryBackup(
            from: export.packageURL
        )
        XCTAssertEqual(firstImport.importedSessionIDs, [record.id])
        XCTAssertEqual(destinationModel.history, [record])

        let secondImport = try await destinationModel.importHistoryBackup(
            from: export.packageURL
        )
        XCTAssertTrue(secondImport.importedSessionIDs.isEmpty)
        XCTAssertEqual(secondImport.skippedSessionIDs, [record.id])
        XCTAssertTrue(secondImport.conflictingSessionIDs.isEmpty)
    }

    func testHistoryExportCleanupRemovesOnlyOwnedPackages()
        async throws
    {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let root = workspace.appendingPathComponent(
            "Sessions",
            isDirectory: true
        )
        let staging = workspace.appendingPathComponent(
            "Exports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        let stalePackage = staging
            .appendingPathComponent(
                "FlowType-History-stale",
                isDirectory: true
            )
            .appendingPathExtension(
                VoiceHistoryBackupFormat.fileExtension
            )
        try FileManager.default.createDirectory(
            at: stalePackage,
            withIntermediateDirectories: true
        )
        let unrelatedFile = staging.appendingPathComponent("keep-me.txt")
        try Data("keep".utf8).write(to: unrelatedFile)

        let store = MobileSessionStore(
            rootDirectory: root,
            historyBackupStagingDirectory: staging
        )
        try await store.save(
            makeCompletedRecord(
                sessionID: UUID(),
                createdAt: Date(timeIntervalSince1970: 9_600),
                text: "待备份"
            )
        )

        let first = try await store.createHistoryBackup(
            includeAudio: false,
            sourceAppVersion: "1.0",
            sourceAppBuild: "1"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stalePackage.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: first.packageURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedFile.path)
        )

        let second = try await store.createHistoryBackup(
            includeAudio: false,
            sourceAppVersion: "1.0",
            sourceAppBuild: "1"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first.packageURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: second.packageURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedFile.path)
        )

        try await store.cleanupHistoryBackupStaging()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: second.packageURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedFile.path)
        )
    }

    func testHistoryTransferBlocksRecordingAndRecordingBlocksTransfer()
        async throws
    {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = MobileAppModel(
            sessionStore: MobileSessionStore(rootDirectory: workspace)
        )

        model.phase = .recording
        do {
            _ = try await model.exportHistoryBackup(
                includeAudio: false,
                stagingParentDirectory: workspace
            )
            XCTFail("录音期间必须拒绝历史导出")
        } catch let error as MobileHistoryTransferError {
            XCTAssertEqual(error, .recordingLifecycleInProgress)
        }
        XCTAssertFalse(model.isHistoryTransferInProgress)

        do {
            _ = try await model.importHistoryBackup(
                from: workspace.appendingPathComponent(
                    "missing.flowtypebackup"
                )
            )
            XCTFail("录音期间必须拒绝历史导入")
        } catch let error as MobileHistoryTransferError {
            XCTAssertEqual(error, .recordingLifecycleInProgress)
        }
        XCTAssertFalse(model.isHistoryTransferInProgress)

        model.phase = .idle
        model.isHistoryTransferInProgress = true
        XCTAssertFalse(model.canToggleRecording)
    }

    private func makeCompletedRecord(
        sessionID: UUID,
        createdAt: Date,
        text: String
    ) throws -> TranscriptSessionRecord {
        var session = RecordingSession(
            id: sessionID,
            localeIdentifier: "zh-CN",
            createdAt: createdAt
        )
        try session.transition(
            to: .recording,
            at: createdAt.addingTimeInterval(1)
        )
        try session.transition(
            to: .stopping,
            at: createdAt.addingTimeInterval(2)
        )
        try session.transition(
            to: .completed,
            at: createdAt.addingTimeInterval(3)
        )
        return try TranscriptSessionRecord(
            session: session,
            segments: [
                try TranscriptSegment(
                    sessionID: sessionID,
                    sequenceNumber: 0,
                    kind: .final,
                    text: text,
                    capturedAt: createdAt.addingTimeInterval(2)
                ),
            ]
        )
    }

    private func historyImportStagingItems(
        in directory: URL
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(
                MobileSessionStore.historyImportStagingPrefix
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexWatchPet-MobileSessionStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeAudioBuffer(
        sampleRate: Double,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TestError.couldNotCreateAudioFormat
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw TestError.couldNotCreateAudioBuffer
        }
        buffer.frameLength = frameCount
        return buffer
    }
}
