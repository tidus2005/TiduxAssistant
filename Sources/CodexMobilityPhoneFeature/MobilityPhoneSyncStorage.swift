import CodexMobilityCore
import Foundation

struct MobilityPhoneSyncStorage: Sendable {
    enum StorageError: LocalizedError, Equatable {
        case invalidFileName
        case invalidOffset(expected: Int64, actual: Int64)
        case invalidBlockRange(offset: UInt64, size: Int)
        case fileChangedWhileIndexing(expected: UInt64, actual: UInt64)

        var errorDescription: String? {
            switch self {
            case .invalidFileName:
                "文件名无效。"
            case .invalidOffset(let expected, let actual):
                "同步断点不一致：应从 \(expected) 字节继续，实际收到 \(actual) 字节。"
            case .invalidBlockRange(let offset, let size):
                "同步块超出文件范围（偏移 \(offset)，长度 \(size)）。"
            case .fileChangedWhileIndexing(let expected, let actual):
                "建立同步索引时文件发生变化（预期 \(expected) 字节，实际 \(actual) 字节）。"
            }
        }
    }

    let rootDirectory: URL
    let outgoingDirectory: URL
    let incomingDirectory: URL
    let inboxDirectory: URL
    let stateURL: URL

    private var fileManager: FileManager { .default }

    init(
        rootDirectory: URL,
        inboxDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        self.rootDirectory = rootDirectory
        self.outgoingDirectory = rootDirectory.appendingPathComponent("Outgoing", isDirectory: true)
        self.incomingDirectory = rootDirectory.appendingPathComponent("Incoming", isDirectory: true)
        self.inboxDirectory = inboxDirectory
        self.stateURL = rootDirectory.appendingPathComponent("phone-sync-state.json")
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outgoingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
    }

    static func live(fileManager: FileManager = .default) throws -> MobilityPhoneSyncStorage {
        guard
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first,
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        else {
            throw CocoaError(.fileNoSuchFile)
        }

        return try MobilityPhoneSyncStorage(
            rootDirectory: applicationSupport
                .appendingPathComponent("CodexWatchPet", isDirectory: true)
                .appendingPathComponent("FileSync", isDirectory: true),
            inboxDirectory: documents.appendingPathComponent("Codex Sync Inbox", isDirectory: true),
            fileManager: fileManager
        )
    }

    func stage(sourceURL: URL, transferID: UUID, fileName: String) throws -> URL {
        let safeName = try Self.safeFileName(fileName)
        let transferDirectory = outgoingDirectory
            .appendingPathComponent(transferID.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        let destination = transferDirectory.appendingPathComponent(safeName, isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    func stagedURL(transferID: UUID, fileName: String) throws -> URL {
        outgoingDirectory
            .appendingPathComponent(transferID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(try Self.safeFileName(fileName), isDirectory: false)
    }

    func removeStagedFile(at fileURL: URL) throws {
        guard fileURL.standardizedFileURL.path.hasPrefix(outgoingDirectory.standardizedFileURL.path) else {
            return
        }
        let parent = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: parent.path) {
            try fileManager.removeItem(at: parent)
        }
    }

    func partialURL(for transferID: UUID) -> URL {
        incomingDirectory
            .appendingPathComponent(transferID.uuidString.lowercased())
            .appendingPathExtension("partial")
    }

    func partialSize(for transferID: UUID) throws -> Int64 {
        let url = partialURL(for: transferID)
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        return try Self.fileSize(at: url)
    }

    func prepareIncomingPartial(transferID: UUID) throws {
        let url = partialURL(for: transferID)
        guard !fileManager.fileExists(atPath: url.path) else { return }
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func writeIncomingChunk(_ data: Data, transferID: UUID, offset: Int64) throws -> Int64 {
        let partial = partialURL(for: transferID)
        if !fileManager.fileExists(atPath: partial.path) {
            guard offset == 0 else {
                throw StorageError.invalidOffset(expected: 0, actual: offset)
            }
            fileManager.createFile(atPath: partial.path, contents: nil)
        }

        let handle = try FileHandle(forUpdating: partial)
        defer { try? handle.close() }
        let currentSize = try handle.seekToEnd()
        guard currentSize == UInt64(offset) else {
            throw StorageError.invalidOffset(expected: Int64(currentSize), actual: offset)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return offset + Int64(data.count)
    }

    func incomingChunkMatches(_ data: Data, transferID: UUID, offset: UInt64) throws -> Bool {
        let partial = partialURL(for: transferID)
        guard fileManager.fileExists(atPath: partial.path) else { return false }
        let handle = try FileHandle(forReadingFrom: partial)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: data.count) == data
    }

    func readOutgoingChunk(
        transferID: UUID,
        fileName: String,
        offset: UInt64,
        maximumLength: Int
    ) throws -> Data {
        let url = try stagedURL(transferID: transferID, fileName: fileName)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maximumLength) ?? Data()
    }

    func makeOutgoingSyncthingIndex(
        metadata: SyncItemMetadata,
        deviceID: String
    ) throws -> SyncthingFileIndex {
        let fileURL = try stagedURL(
            transferID: metadata.transferID,
            fileName: SyncRelativePath.fileName(in: metadata.relativePath)
        )
        let index = try makeSyncthingIndex(
            fileURL: fileURL,
            relativePath: metadata.relativePath,
            modifiedAt: metadata.modifiedAt,
            deviceID: deviceID
        )
        guard index.size == metadata.byteSize else {
            throw StorageError.fileChangedWhileIndexing(
                expected: metadata.byteSize,
                actual: index.size
            )
        }
        guard let wholeHash = index.wholeFileSHA256,
              SyncSHA256.constantTimeEqual(wholeHash, metadata.sha256) else {
            throw MobilityPhoneSyncError.checksumMismatch(
                name: SyncRelativePath.fileName(in: metadata.relativePath)
            )
        }
        return index
    }

    func localSyncthingIndex(
        relativePath: String,
        deviceID: String
    ) throws -> SyncthingFileIndex? {
        let fileName = try Self.safeFileName(SyncRelativePath.fileName(in: relativePath))
        let fileURL = inboxDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        return try makeSyncthingIndex(
            fileURL: fileURL,
            relativePath: relativePath,
            modifiedAt: values.contentModificationDate ?? .now,
            deviceID: deviceID
        )
    }

    func readOutgoingSyncthingBlock(
        transferID: UUID,
        fileName: String,
        block: SyncthingBlockRequest
    ) throws -> Data {
        let url = try stagedURL(transferID: transferID, fileName: fileName)
        return try readExactBlock(at: url, block: block)
    }

    /// Finds content-addressed blocks in both a previously visible Files copy and
    /// a resumable legacy partial. `SyncthingDeltaSession` hashes them again before use.
    func reusableSyncthingBlockData(
        transferID: UUID,
        remoteIndex: SyncthingFileIndex
    ) throws -> [Data] {
        let fileName = try Self.safeFileName(
            SyncRelativePath.fileName(in: remoteIndex.relativePath)
        )
        let visibleFile = inboxDirectory.appendingPathComponent(fileName, isDirectory: false)
        let partialFile = partialURL(for: transferID)
        let candidates = [visibleFile, partialFile].filter {
            fileManager.fileExists(atPath: $0.path)
        }
        guard !candidates.isEmpty else { return [] }

        var reusable: [Data] = []
        reusable.reserveCapacity(remoteIndex.blocks.count)
        for blockInfo in remoteIndex.blocks {
            let request = SyncthingBlockRequest(block: blockInfo)
            for candidate in candidates {
                guard let data = try? readExactBlock(at: candidate, block: request),
                      SyncSHA256.matches(data, expectedHexDigest: request.sha256) else {
                    continue
                }
                reusable.append(data)
                break
            }
        }
        return reusable
    }

    /// Commits a fully verified in-memory image through a sibling temporary file.
    /// Moving the sibling into place is atomic on the Files inbox volume.
    func commitSyncthingFile(_ commit: SyncthingAtomicFileCommit) throws -> URL {
        let remoteFileName = try Self.safeFileName(
            SyncRelativePath.fileName(in: commit.remoteIndex.relativePath)
        )
        let existingRemoteURL = inboxDirectory.appendingPathComponent(
            remoteFileName,
            isDirectory: false
        )
        if fileManager.fileExists(atPath: existingRemoteURL.path),
           let existingHash = try? Self.sha256Hex(at: existingRemoteURL),
           SyncSHA256.constantTimeEqual(existingHash, commit.verifiedSHA256) {
            return existingRemoteURL
        }

        let destination = try finalizedInboxURL(
            fileName: SyncRelativePath.fileName(in: commit.relativePath)
        )
        let temporaryURL = inboxDirectory
            .appendingPathComponent(".codexsync-\(UUID().uuidString.lowercased())")
            .appendingPathExtension("partial")
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try commit.data.write(to: temporaryURL, options: .atomic)
        let storedHash = try Self.sha256Hex(at: temporaryURL)
        guard SyncSHA256.constantTimeEqual(storedHash, commit.verifiedSHA256) else {
            throw MobilityPhoneSyncError.checksumMismatch(
                name: destination.lastPathComponent
            )
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func commitSyncthingDeletion(_ commit: SyncthingAtomicDeletionCommit) throws {
        let fileName = try Self.safeFileName(
            SyncRelativePath.fileName(in: commit.relativePath)
        )
        let destination = inboxDirectory.appendingPathComponent(fileName, isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
    }

    func finalizedInboxURL(fileName: String) throws -> URL {
        let safeName = try Self.safeFileName(fileName)
        let requested = inboxDirectory.appendingPathComponent(safeName, isDirectory: false)
        guard fileManager.fileExists(atPath: requested.path) else { return requested }

        let stem = requested.deletingPathExtension().lastPathComponent
        let pathExtension = requested.pathExtension
        var suffix = 2
        while true {
            let candidateName = pathExtension.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(pathExtension)"
            let candidate = inboxDirectory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    func finalizeIncoming(transferID: UUID, fileName: String) throws -> URL {
        let source = partialURL(for: transferID)
        let destination = try finalizedInboxURL(fileName: fileName)
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    func commitIncoming(transferID: UUID, to destination: URL) throws {
        let source = partialURL(for: transferID)
        try fileManager.moveItem(at: source, to: destination)
    }

    func removeIncomingPartial(transferID: UUID) throws {
        let url = partialURL(for: transferID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return Int64(values.fileSize ?? 0)
    }

    static func sha256Hex(at url: URL) throws -> String {
        try SyncSHA256.hexDigest(fileAt: url, readChunkSize: 1_048_576)
    }

    static func safeFileName(_ proposedName: String) throws -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.contains("/"),
            !trimmed.contains("\\"),
            !trimmed.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F })
        else {
            throw StorageError.invalidFileName
        }
        let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        let invalidNames: Set<String> = ["", ".", ".."]
        guard
            !invalidNames.contains(lastComponent),
            !lastComponent.contains("/"),
            !lastComponent.contains(":"),
            lastComponent.utf8.count <= 240
        else {
            throw StorageError.invalidFileName
        }
        return lastComponent
    }

    private func makeSyncthingIndex(
        fileURL: URL,
        relativePath: String,
        modifiedAt: Date,
        deviceID: String
    ) throws -> SyncthingFileIndex {
        let byteSize = UInt64(max(try Self.fileSize(at: fileURL), 0))
        let blockSize = SyncthingBlockSizePolicy.blockSize(forByteSize: byteSize)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var blocks: [SyncthingBlockInfo] = []
        blocks.reserveCapacity(Int(SyncthingBlockSizePolicy.blockCount(
            forByteSize: byteSize,
            blockSize: blockSize
        )))
        var wholeFileHasher = SyncSHA256Hasher()
        var offset: UInt64 = 0
        while let data = try handle.read(upToCount: blockSize), !data.isEmpty {
            wholeFileHasher.update(data)
            blocks.append(try SyncthingBlockInfo(
                offset: offset,
                size: data.count,
                sha256: SyncSHA256.hexDigest(data)
            ))
            offset += UInt64(data.count)
        }
        guard offset == byteSize else {
            throw StorageError.fileChangedWhileIndexing(expected: byteSize, actual: offset)
        }

        let counter = Self.versionCounter(for: modifiedAt)
        return try SyncthingFileIndex(
            relativePath: relativePath,
            size: byteSize,
            modifiedAt: modifiedAt,
            wholeFileSHA256: wholeFileHasher.finalize(),
            blocks: blocks,
            deviceID: deviceID,
            version: SyncthingVersionVector(counters: [deviceID: counter]),
            sequence: counter
        )
    }

    private func readExactBlock(
        at fileURL: URL,
        block: SyncthingBlockRequest
    ) throws -> Data {
        guard block.size > 0 else {
            throw StorageError.invalidBlockRange(offset: block.offset, size: block.size)
        }
        let fileSize = UInt64(max(try Self.fileSize(at: fileURL), 0))
        let (endOffset, overflow) = block.offset.addingReportingOverflow(UInt64(block.size))
        guard !overflow, endOffset <= fileSize else {
            throw StorageError.invalidBlockRange(offset: block.offset, size: block.size)
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: block.offset)
        let data = try handle.read(upToCount: block.size) ?? Data()
        guard data.count == block.size else {
            throw StorageError.invalidBlockRange(offset: block.offset, size: block.size)
        }
        return data
    }

    private static func versionCounter(for date: Date) -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 1 else { return 1 }
        if milliseconds >= Double(UInt64.max) { return UInt64.max }
        return UInt64(milliseconds.rounded(.down))
    }
}
