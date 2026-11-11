import Foundation
import XCTest
@testable import CodexMobilityCore

final class VoiceHistoryBackupArchiveTests: XCTestCase {
    private static let sourceBundleIdentifier = "com.tidux.FlowTypeMobile"

    func testCompleteBackupImportsAudioAndIsIdempotent() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("Source", isDirectory: true)
        let exports = workspace.appendingPathComponent("Exports", isDirectory: true)
        let destination = workspace.appendingPathComponent("Destination", isDirectory: true)
        let importStaging = workspace.appendingPathComponent("ImportStaging", isDirectory: true)
        let sessionID = UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        )!
        let fixture = try writeSession(
            id: sessionID,
            text: "完整历史",
            root: source,
            includesAudio: true
        )

        let export = try VoiceHistoryBackupArchive.createStagedBackup(
            sourceSessionsDirectory: source,
            stagingParentDirectory: exports,
            includeAudio: true,
            sourceBundleIdentifier: Self.sourceBundleIdentifier,
            sourceAppVersion: "0.1.0",
            sourceAppBuild: "2",
            createdAt: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(export.manifest.sessionCount, 1)
        XCTAssertEqual(
            export.manifest.sessions[0].files.map(\.relativePath),
            [
                "Sessions/\(sessionID.uuidString.lowercased())/Audio/"
                    + fixture.audioFileName!,
                "Sessions/\(sessionID.uuidString.lowercased())/"
                    + "audio-manifest.json",
                "Sessions/\(sessionID.uuidString.lowercased())/"
                    + "diagnostics.json",
                "Sessions/\(sessionID.uuidString.lowercased())/session.json",
            ]
        )

        let validated = try VoiceHistoryBackupArchive.validate(
            packageURL: export.packageURL
        )
        let first = try VoiceHistoryBackupArchive.importValidatedBackup(
            validated,
            destinationSessionsDirectory: destination,
            stagingParentDirectory: importStaging,
            allowedSourceBundleIdentifiers: [Self.sourceBundleIdentifier],
            storageSafetyMargin: 0
        )
        XCTAssertEqual(first.importedSessionIDs, [sessionID])
        XCTAssertTrue(first.skippedSessionIDs.isEmpty)
        XCTAssertTrue(first.conflictingSessionIDs.isEmpty)

        let importedAudio = destination
            .appendingPathComponent(sessionID.uuidString.lowercased())
            .appendingPathComponent("Audio")
            .appendingPathComponent(fixture.audioFileName!)
        XCTAssertEqual(
            try Data(contentsOf: importedAudio),
            fixture.audioBytes
        )

        let second = try VoiceHistoryBackupArchive.importValidatedBackup(
            validated,
            destinationSessionsDirectory: destination,
            stagingParentDirectory: importStaging,
            allowedSourceBundleIdentifiers: [Self.sourceBundleIdentifier],
            storageSafetyMargin: 0
        )
        XCTAssertTrue(second.importedSessionIDs.isEmpty)
        XCTAssertEqual(second.skippedSessionIDs, [sessionID])
        XCTAssertTrue(second.conflictingSessionIDs.isEmpty)
    }

    func testTextOnlyBackupExcludesAudioAndManifest() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("Source", isDirectory: true)
        let exports = workspace.appendingPathComponent("Exports", isDirectory: true)
        let sessionID = UUID(
            uuidString: "22222222-2222-2222-2222-222222222222"
        )!
        _ = try writeSession(
            id: sessionID,
            text: "只迁移文字",
            root: source,
            includesAudio: true
        )

        let export = try VoiceHistoryBackupArchive.createStagedBackup(
            sourceSessionsDirectory: source,
            stagingParentDirectory: exports,
            includeAudio: false,
            sourceBundleIdentifier: Self.sourceBundleIdentifier,
            sourceAppVersion: "0.1.0",
            sourceAppBuild: "2"
        )
        let paths = export.manifest.sessions[0].files.map(\.relativePath)
        XCTAssertEqual(
            paths,
            [
                "Sessions/\(sessionID.uuidString.lowercased())/"
                    + "diagnostics.json",
                "Sessions/\(sessionID.uuidString.lowercased())/session.json",
            ]
        )
        XCTAssertNoThrow(
            try VoiceHistoryBackupArchive.validate(
                packageURL: export.packageURL
            )
        )
    }

    func testValidationRejectsHashMismatch() throws {
        let fixture = try makeExportedFixture(
            id: UUID(
                uuidString: "33333333-3333-3333-3333-333333333333"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let diagnostics = fixture.export.packageURL
            .appendingPathComponent("Sessions")
            .appendingPathComponent(fixture.sessionID.uuidString.lowercased())
            .appendingPathComponent("diagnostics.json")
        try Data("{\"ok\":null}".utf8).write(to: diagnostics)

        XCTAssertThrowsError(
            try VoiceHistoryBackupArchive.validate(
                packageURL: fixture.export.packageURL
            )
        ) { error in
            guard
                case .fileHashMismatch =
                    error as? VoiceHistoryBackupArchiveError
            else {
                return XCTFail("预期 hash mismatch，实际为 \(error)")
            }
        }
    }

    func testValidationRejectsPathTraversalInManifest() throws {
        let fixture = try makeExportedFixture(
            id: UUID(
                uuidString: "44444444-4444-4444-4444-444444444444"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try rewriteManifest(at: fixture.export.packageURL) { manifest in
            let originalSession = manifest.sessions[0]
            let originalFile = originalSession.files[0]
            let maliciousFile = VoiceHistoryBackupFileEntry(
                relativePath:
                    "Sessions/\(fixture.sessionID.uuidString.lowercased())/"
                    + "../session.json",
                byteCount: originalFile.byteCount,
                sha256: originalFile.sha256
            )
            let files = [maliciousFile] +
                Array(originalSession.files.dropFirst())
            return replacing(
                manifest,
                sessions: [
                    VoiceHistoryBackupSessionEntry(
                        sessionID: originalSession.sessionID,
                        files: files.sorted {
                            $0.relativePath < $1.relativePath
                        }
                    ),
                ]
            )
        }

        XCTAssertThrowsError(
            try VoiceHistoryBackupArchive.validate(
                packageURL: fixture.export.packageURL
            )
        ) { error in
            guard
                case .invalidRelativePath =
                    error as? VoiceHistoryBackupArchiveError
            else {
                return XCTFail("预期 path traversal，实际为 \(error)")
            }
        }
    }

    func testValidationRejectsSymbolicLink() throws {
        let fixture = try makeExportedFixture(
            id: UUID(
                uuidString: "55555555-5555-5555-5555-555555555555"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let sessionDirectory = fixture.export.packageURL
            .appendingPathComponent("Sessions")
            .appendingPathComponent(fixture.sessionID.uuidString.lowercased())
        let diagnostics = sessionDirectory
            .appendingPathComponent("diagnostics.json")
        let outside = fixture.workspace.appendingPathComponent("outside.json")
        try Data("{\"ok\":true}".utf8).write(to: outside)
        try FileManager.default.removeItem(at: diagnostics)
        try FileManager.default.createSymbolicLink(
            at: diagnostics,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try VoiceHistoryBackupArchive.validate(
                packageURL: fixture.export.packageURL
            )
        ) { error in
            guard
                case .symbolicLinkNotAllowed =
                    error as? VoiceHistoryBackupArchiveError
            else {
                return XCTFail("预期拒绝 symlink，实际为 \(error)")
            }
        }
    }

    func testSameUUIDWithDifferentContentIsConflictAndNeverOverwritten()
        throws
    {
        let fixture = try makeExportedFixture(
            id: UUID(
                uuidString: "66666666-6666-6666-6666-666666666666"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let destination = fixture.workspace
            .appendingPathComponent("Destination", isDirectory: true)
        let staging = fixture.workspace
            .appendingPathComponent("ImportStaging", isDirectory: true)
        let validated = try VoiceHistoryBackupArchive.validate(
            packageURL: fixture.export.packageURL
        )
        _ = try VoiceHistoryBackupArchive.importValidatedBackup(
            validated,
            destinationSessionsDirectory: destination,
            stagingParentDirectory: staging,
            allowedSourceBundleIdentifiers: [Self.sourceBundleIdentifier],
            storageSafetyMargin: 0
        )
        let destinationDiagnostics = destination
            .appendingPathComponent(fixture.sessionID.uuidString.lowercased())
            .appendingPathComponent("diagnostics.json")
        let divergent = Data("{\"local\":\"different\"}".utf8)
        try divergent.write(to: destinationDiagnostics)

        let result = try VoiceHistoryBackupArchive.importValidatedBackup(
            validated,
            destinationSessionsDirectory: destination,
            stagingParentDirectory: staging,
            allowedSourceBundleIdentifiers: [Self.sourceBundleIdentifier],
            storageSafetyMargin: 0
        )
        XCTAssertTrue(result.importedSessionIDs.isEmpty)
        XCTAssertTrue(result.skippedSessionIDs.isEmpty)
        XCTAssertEqual(result.conflictingSessionIDs, [fixture.sessionID])
        XCTAssertEqual(
            try Data(contentsOf: destinationDiagnostics),
            divergent
        )
    }

    func testValidationRejectsNonCanonicalUUIDDirectory() throws {
        let fixture = try makeExportedFixture(
            id: UUID(
                uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
            )!
        )
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let sessions = fixture.export.packageURL.appendingPathComponent(
            "Sessions"
        )
        let canonical = sessions.appendingPathComponent(
            fixture.sessionID.uuidString.lowercased()
        )
        let invalid = sessions.appendingPathComponent("not-a-uuid")
        try FileManager.default.moveItem(at: canonical, to: invalid)

        XCTAssertThrowsError(
            try VoiceHistoryBackupArchive.validate(
                packageURL: fixture.export.packageURL
            )
        ) { error in
            guard
                case .invalidSessionIdentifier =
                    error as? VoiceHistoryBackupArchiveError
            else {
                return XCTFail("预期拒绝非法 UUID，实际为 \(error)")
            }
        }
    }

    func testExportRejectsInvalidAudioManifestNumbersAndSequence() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("Source", isDirectory: true)
        let exports = workspace.appendingPathComponent("Exports", isDirectory: true)
        let sessionID = UUID(
            uuidString: "77777777-7777-7777-7777-777777777777"
        )!
        let fixture = try writeSession(
            id: sessionID,
            text: "非法音频清单",
            root: source,
            includesAudio: true
        )
        let manifestURL = source
            .appendingPathComponent(sessionID.uuidString.lowercased())
            .appendingPathComponent("audio-manifest.json")
        let invalid = TestAudioManifest(
            schemaVersion: 1,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSince1970: 1_100),
            segments: [
                TestAudioSegment(
                    sequenceNumber: 0,
                    fileName: fixture.audioFileName!,
                    state: .committed,
                    frameCount: -1,
                    sampleRate: 16_000,
                    channelCount: 1
                ),
            ]
        )
        try encoder().encode(invalid).write(to: manifestURL)

        XCTAssertThrowsError(
            try VoiceHistoryBackupArchive.createStagedBackup(
                sourceSessionsDirectory: source,
                stagingParentDirectory: exports,
                includeAudio: true,
                sourceBundleIdentifier: Self.sourceBundleIdentifier,
                sourceAppVersion: "0.1.0",
                sourceAppBuild: "2"
            )
        ) { error in
            XCTAssertEqual(
                error as? VoiceHistoryBackupArchiveError,
                .invalidAudioManifest(sessionID)
            )
        }
    }

    private struct SessionFixture {
        let audioFileName: String?
        let audioBytes: Data
    }

    private struct ExportedFixture {
        let workspace: URL
        let sessionID: UUID
        let export: VoiceHistoryBackupExport
    }

    private struct TestAudioSegment: Codable {
        let sequenceNumber: UInt64
        let fileName: String
        let state: RollingSegmentFileState
        let frameCount: Int64
        let sampleRate: Double
        let channelCount: UInt32
    }

    private struct TestAudioManifest: Codable {
        let schemaVersion: Int
        let sessionID: UUID
        let updatedAt: Date
        let segments: [TestAudioSegment]
    }

    private func makeExportedFixture(id: UUID) throws -> ExportedFixture {
        let workspace = try makeWorkspace()
        let source = workspace.appendingPathComponent("Source", isDirectory: true)
        let exports = workspace.appendingPathComponent("Exports", isDirectory: true)
        _ = try writeSession(
            id: id,
            text: "fixture",
            root: source,
            includesAudio: true
        )
        let export = try VoiceHistoryBackupArchive.createStagedBackup(
            sourceSessionsDirectory: source,
            stagingParentDirectory: exports,
            includeAudio: true,
            sourceBundleIdentifier: Self.sourceBundleIdentifier,
            sourceAppVersion: "0.1.0",
            sourceAppBuild: "2"
        )
        return ExportedFixture(
            workspace: workspace,
            sessionID: id,
            export: export
        )
    }

    private func writeSession(
        id: UUID,
        text: String,
        root: URL,
        includesAudio: Bool
    ) throws -> SessionFixture {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var session = RecordingSession(
            id: id,
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
        let record = try TranscriptSessionRecord(
            session: session,
            segments: [
                try TranscriptSegment(
                    sessionID: id,
                    sequenceNumber: 0,
                    kind: .final,
                    text: text,
                    capturedAt: createdAt.addingTimeInterval(2)
                ),
            ]
        )
        let directory = root.appendingPathComponent(
            id.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encoder().encode(record).write(
            to: directory.appendingPathComponent("session.json")
        )
        try Data("{\"ok\":true}".utf8).write(
            to: directory.appendingPathComponent("diagnostics.json")
        )

        guard includesAudio else {
            return SessionFixture(audioFileName: nil, audioBytes: Data())
        }
        let audioName = try RollingSegmentFileNaming.fileName(
            sessionID: id,
            sequenceNumber: 0,
            fileExtension: "caf",
            state: .committed
        )
        let audioBytes = Data((0 ..< 4_097).map { UInt8($0 % 251) })
        let audioDirectory = directory.appendingPathComponent(
            "Audio",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )
        try audioBytes.write(
            to: audioDirectory.appendingPathComponent(audioName)
        )
        let audioManifest = TestAudioManifest(
            schemaVersion: 1,
            sessionID: id,
            updatedAt: createdAt.addingTimeInterval(3),
            segments: [
                TestAudioSegment(
                    sequenceNumber: 0,
                    fileName: audioName,
                    state: .committed,
                    frameCount: 4_096,
                    sampleRate: 16_000,
                    channelCount: 1
                ),
            ]
        )
        try encoder().encode(audioManifest).write(
            to: directory.appendingPathComponent("audio-manifest.json")
        )
        return SessionFixture(
            audioFileName: audioName,
            audioBytes: audioBytes
        )
    }

    private func rewriteManifest(
        at packageURL: URL,
        transform: (VoiceHistoryBackupManifest)
            -> VoiceHistoryBackupManifest
    ) throws {
        let url = packageURL.appendingPathComponent("archive.json")
        let manifest = try decoder().decode(
            VoiceHistoryBackupManifest.self,
            from: Data(contentsOf: url)
        )
        try encoder().encode(transform(manifest)).write(
            to: url,
            options: .atomic
        )
    }

    private func replacing(
        _ manifest: VoiceHistoryBackupManifest,
        sessions: [VoiceHistoryBackupSessionEntry]
    ) -> VoiceHistoryBackupManifest {
        VoiceHistoryBackupManifest(
            sourceBundleIdentifier: manifest.sourceBundleIdentifier,
            sourceAppVersion: manifest.sourceAppVersion,
            sourceAppBuild: manifest.sourceAppBuild,
            createdAt: manifest.createdAt,
            totalBytes: manifest.totalBytes,
            sessions: sessions
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VoiceHistoryBackupTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
