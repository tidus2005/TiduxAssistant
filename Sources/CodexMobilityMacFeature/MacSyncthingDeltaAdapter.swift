import CodexMobilityCore
import Foundation

enum MacSyncthingDeltaAdapterError: Error, Equatable, Sendable {
    case invalidFolderID(String)
    case invalidDirection
    case outgoingTransferNotFound(UUID)
    case outgoingMetadataMismatch(UUID)
    case invalidBlockRange(offset: UInt64, size: Int)
    case sourceChanged(String)
    case sourceReadFailed(String)
}

extension MacSyncthingDeltaAdapterError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidFolderID:
            "增量同步的传输标识无效。"
        case .invalidDirection:
            "增量同步方向与 Mac 端不匹配。"
        case .outgoingTransferNotFound:
            "待发送文件已不在同步队列中。"
        case .outgoingMetadataMismatch:
            "待发送文件在建立增量索引前发生了变化。"
        case let .invalidBlockRange(offset, size):
            "请求的文件块范围无效（\(offset) + \(size)）。"
        case let .sourceChanged(path):
            "建立增量索引时文件发生变化：\(path)"
        case let .sourceReadFailed(message):
            "读取增量同步文件失败：\(message)"
        }
    }
}

/// Mac storage implementation for the transport-independent delta coordinator.
/// All durable writes are delegated back to `MacFileSyncStore` so the existing
/// staging, loop suppression and observable UI state remain authoritative.
actor MacSyncthingDeltaAdapter: SyncthingPeerDeltaAdapter {
    private struct ExistingFile: Sendable {
        let url: URL
        let size: UInt64
        let modifiedAt: Date
    }

    private let store: MacFileSyncStore
    private let localDeviceID: String
    private var rememberedIndexesByPath: [String: SyncthingFileIndex] = [:]

    init(store: MacFileSyncStore, localDeviceID: UUID) {
        self.store = store
        self.localDeviceID = localDeviceID.uuidString.lowercased()
    }

    func makeOutgoingIndex(metadata: SyncItemMetadata) async throws -> SyncthingFileIndex {
        let metadata = try metadata.validated()
        guard metadata.direction == .macToPhone else {
            throw MacSyncthingDeltaAdapterError.invalidDirection
        }
        guard let descriptor = await store.outgoingDescriptors().first(where: {
            $0.transferID == metadata.transferID
        }) else {
            throw MacSyncthingDeltaAdapterError.outgoingTransferNotFound(metadata.transferID)
        }
        guard descriptor.relativePath == metadata.relativePath,
              descriptor.byteCount == metadata.byteSize,
              descriptor.modifiedAt == metadata.modifiedAt,
              SyncSHA256.constantTimeEqual(descriptor.sha256, metadata.sha256) else {
            throw MacSyncthingDeltaAdapterError.outgoingMetadataMismatch(metadata.transferID)
        }

        let blockSize = SyncthingBlockSizePolicy.blockSize(forByteSize: descriptor.byteCount)
        var blocks: [SyncthingBlockInfo] = []
        var wholeHasher = SyncSHA256Hasher()
        var offset: UInt64 = 0
        while offset < descriptor.byteCount {
            let requested = Int(min(UInt64(blockSize), descriptor.byteCount - offset))
            let data = try await store.readOutgoingDeltaBlock(
                transferID: descriptor.transferID,
                offset: offset,
                maximumBytes: requested
            )
            guard data.count == requested else {
                throw MacSyncthingDeltaAdapterError.sourceChanged(descriptor.relativePath)
            }
            wholeHasher.update(data)
            blocks.append(try SyncthingBlockInfo(
                offset: offset,
                size: data.count,
                sha256: SyncSHA256.hexDigest(data)
            ))
            offset += UInt64(data.count)
        }

        let wholeHash = wholeHasher.finalize()
        guard SyncSHA256.constantTimeEqual(wholeHash, descriptor.sha256) else {
            throw MacSyncthingDeltaAdapterError.sourceChanged(descriptor.relativePath)
        }
        let sequence = sequenceValue(modifiedAt: descriptor.modifiedAt)
        let index = try SyncthingFileIndex(
            relativePath: descriptor.relativePath,
            size: descriptor.byteCount,
            modifiedAt: descriptor.modifiedAt,
            wholeFileSHA256: wholeHash,
            blocks: blocks,
            deviceID: localDeviceID,
            version: SyncthingVersionVector(counters: [localDeviceID: sequence]),
            sequence: sequence
        )
        rememberedIndexesByPath[index.relativePath] = index
        return index
    }

    func localIndex(
        folderID: String,
        relativePath: String
    ) async throws -> SyncthingFileIndex? {
        _ = try transferID(from: folderID)
        let normalizedPath = try MacSyncFileUtilities.normalizedRelativePath(relativePath)
        guard let file = try await existingFile(relativePath: normalizedPath) else {
            if let remembered = rememberedIndexesByPath[normalizedPath], remembered.deleted {
                return remembered
            }
            return nil
        }
        let snapshot = try buildIndex(for: file, relativePath: normalizedPath)
        if let remembered = rememberedIndexesByPath[snapshot.relativePath],
           remembered.size == snapshot.size,
           remembered.wholeFileSHA256 == snapshot.wholeFileSHA256,
           !remembered.deleted {
            return remembered
        }
        return snapshot
    }

    func reusableBlockData(
        folderID: String,
        remoteIndex: SyncthingFileIndex
    ) async throws -> [Data] {
        _ = try transferID(from: folderID)
        guard !remoteIndex.deleted,
              let file = try await existingFile(relativePath: remoteIndex.relativePath) else {
            return []
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file.url)
        } catch {
            throw MacSyncthingDeltaAdapterError.sourceReadFailed(error.localizedDescription)
        }
        defer { try? handle.close() }

        var reusable: [Data] = []
        do {
            for block in remoteIndex.blocks {
                guard let end = block.endOffset, end <= file.size else { continue }
                try handle.seek(toOffset: block.offset)
                let data = try readExactly(block.size, from: handle)
                if data.count == block.size,
                   SyncSHA256.matches(data, expectedHexDigest: block.sha256) {
                    reusable.append(data)
                }
            }
        } catch let error as MacSyncthingDeltaAdapterError {
            throw error
        } catch {
            throw MacSyncthingDeltaAdapterError.sourceReadFailed(error.localizedDescription)
        }
        try ensureUnchanged(file)
        return reusable
    }

    func readBlock(
        folderID: String,
        index: SyncthingFileIndex,
        block: SyncthingBlockRequest
    ) async throws -> Data {
        let transferID = try transferID(from: folderID)
        guard let descriptor = await store.outgoingDescriptors().first(where: {
            $0.transferID == transferID
        }) else {
            throw MacSyncthingDeltaAdapterError.outgoingTransferNotFound(transferID)
        }
        guard descriptor.relativePath == index.relativePath,
              descriptor.byteCount == index.size,
              descriptor.modifiedAt == index.modifiedAt,
              descriptor.sha256 == index.wholeFileSHA256 else {
            throw MacSyncthingDeltaAdapterError.outgoingMetadataMismatch(transferID)
        }
        guard let end = endOffset(offset: block.offset, size: block.size),
              end <= descriptor.byteCount else {
            throw MacSyncthingDeltaAdapterError.invalidBlockRange(
                offset: block.offset,
                size: block.size
            )
        }
        return try await store.readOutgoingDeltaBlock(
            transferID: transferID,
            offset: block.offset,
            maximumBytes: block.size
        )
    }

    func commit(
        _ commit: SyncthingPeerDeltaCommit,
        folderID: String
    ) async throws {
        let transferID = try transferID(from: folderID)
        switch commit {
        case let .file(fileCommit):
            try await store.applySyncthingFile(fileCommit, transferID: transferID)
            rememberedIndexesByPath[fileCommit.relativePath] = try index(
                fileCommit.remoteIndex,
                replacingRelativePath: fileCommit.relativePath
            )

        case let .deletion(deletionCommit):
            try await store.applySyncthingDeletion(deletionCommit, transferID: transferID)
            rememberedIndexesByPath[deletionCommit.relativePath] = try index(
                deletionCommit.tombstone,
                replacingRelativePath: deletionCommit.relativePath
            )
        }
    }

    func outgoingTransferDidFinish(
        folderID: String,
        index: SyncthingFileIndex,
        acknowledgement: SyncthingPeerAcknowledgement
    ) async throws {
        _ = index
        let transferID = try transferID(from: folderID)
        switch acknowledgement.status {
        case .accepted:
            do {
                try await store.markOutgoingCompleted(transferID: transferID)
            } catch MacFileSyncError.transferNotFound {
                // Multiple authenticated peers may acknowledge the same publication.
                // The first acknowledgement already made the queue transition durable.
            }
        case .rejected:
            await store.markSyncthingOutgoingRejected(
                transferID: transferID,
                reason: acknowledgement.detail ?? "iPhone 拒绝了增量文件"
            )
        }
    }

    private func transferID(from folderID: String) throws -> UUID {
        guard let transferID = SyncthingTransferFolderID.transferID(from: folderID) else {
            throw MacSyncthingDeltaAdapterError.invalidFolderID(folderID)
        }
        return transferID
    }

    private func existingFile(relativePath: String) async throws -> ExistingFile? {
        let operational = await store.isOperational
        guard operational else { throw MacFileSyncError.syncDisabled }
        guard let rootURL = await store.directoryURL else {
            throw MacFileSyncError.directoryUnavailable
        }
        let normalized = try MacSyncFileUtilities.normalizedRelativePath(relativePath)
        let url = normalized.split(separator: "/").reduce(rootURL.standardizedFileURL) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try MacSyncFileUtilities.ensureExistingParentsAreSafe(for: url, rootURL: rootURL)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MacFileSyncError.unsafeRelativePath(normalized)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            throw MacSyncthingDeltaAdapterError.sourceReadFailed("无法读取文件属性")
        }
        return ExistingFile(url: url, size: size, modifiedAt: modifiedAt)
    }

    private func buildIndex(
        for file: ExistingFile,
        relativePath: String
    ) throws -> SyncthingFileIndex {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file.url)
        } catch {
            throw MacSyncthingDeltaAdapterError.sourceReadFailed(error.localizedDescription)
        }
        defer { try? handle.close() }

        let blockSize = SyncthingBlockSizePolicy.blockSize(forByteSize: file.size)
        var blocks: [SyncthingBlockInfo] = []
        var hasher = SyncSHA256Hasher()
        var offset: UInt64 = 0
        do {
            while offset < file.size {
                let count = Int(min(UInt64(blockSize), file.size - offset))
                let data = try readExactly(count, from: handle)
                guard data.count == count else {
                    throw MacSyncthingDeltaAdapterError.sourceChanged(relativePath)
                }
                hasher.update(data)
                blocks.append(try SyncthingBlockInfo(
                    offset: offset,
                    size: data.count,
                    sha256: SyncSHA256.hexDigest(data)
                ))
                offset += UInt64(data.count)
            }
        } catch let error as MacSyncthingDeltaAdapterError {
            throw error
        } catch {
            throw MacSyncthingDeltaAdapterError.sourceReadFailed(error.localizedDescription)
        }
        try ensureUnchanged(file)

        let sequence = sequenceValue(modifiedAt: file.modifiedAt)
        return try SyncthingFileIndex(
            relativePath: relativePath,
            size: file.size,
            modifiedAt: file.modifiedAt,
            wholeFileSHA256: hasher.finalize(),
            blocks: blocks,
            deviceID: localDeviceID,
            version: SyncthingVersionVector(counters: [localDeviceID: sequence]),
            sequence: sequence
        )
    }

    private func readExactly(_ byteCount: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        result.reserveCapacity(byteCount)
        while result.count < byteCount {
            guard let chunk = try handle.read(upToCount: byteCount - result.count),
                  !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }
        return result
    }

    private func ensureUnchanged(_ file: ExistingFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value
        let modifiedAt = attributes[.modificationDate] as? Date
        guard size == file.size, modifiedAt == file.modifiedAt else {
            throw MacSyncthingDeltaAdapterError.sourceChanged(file.url.lastPathComponent)
        }
    }

    private func index(
        _ source: SyncthingFileIndex,
        replacingRelativePath relativePath: String
    ) throws -> SyncthingFileIndex {
        try SyncthingFileIndex(
            relativePath: relativePath,
            size: source.size,
            modifiedAt: source.modifiedAt,
            wholeFileSHA256: source.wholeFileSHA256,
            blocks: source.blocks,
            deviceID: source.deviceID,
            version: source.version,
            sequence: source.sequence,
            deleted: source.deleted
        )
    }

    private func sequenceValue(modifiedAt: Date) -> UInt64 {
        let milliseconds = modifiedAt.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 1 else { return 1 }
        guard milliseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(milliseconds.rounded(.down))
    }

    private func endOffset(offset: UInt64, size: Int) -> UInt64? {
        guard size > 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(size))
        return overflow ? nil : end
    }
}

protocol MacSyncthingDeltaRouting: Sendable {
    func publish(_ offer: SyncOffer) async throws -> SyncthingPeerMessage?
    func receive(_ message: SyncthingPeerMessage) async throws -> [SyncthingPeerMessage]
}

/// One coordinator per authenticated connection keeps request IDs and folder state
/// isolated when more than one paired iPhone is connected.
actor MacSyncthingDeltaRouter: MacSyncthingDeltaRouting {
    private let adapter: MacSyncthingDeltaAdapter
    private let coordinator: SyncthingPeerDeltaCoordinator<MacSyncthingDeltaAdapter>
    private var activeTransferIDs: Set<UUID> = []
    private var transferIDByMessageID: [UUID: UUID] = [:]

    init(adapter: MacSyncthingDeltaAdapter) {
        self.adapter = adapter
        self.coordinator = SyncthingPeerDeltaCoordinator(adapter: adapter)
    }

    func publish(_ offer: SyncOffer) async throws -> SyncthingPeerMessage? {
        let metadata = try offer.metadata.validated()
        guard metadata.direction == .macToPhone else {
            throw MacSyncthingDeltaAdapterError.invalidDirection
        }
        guard metadata.byteSize <= SyncthingPeerDeltaCoordinator<MacSyncthingDeltaAdapter>
            .maximumInMemoryFileSize else {
            return nil
        }
        guard activeTransferIDs.insert(metadata.transferID).inserted else { return nil }

        do {
            let index = try await adapter.makeOutgoingIndex(metadata: metadata)
            let messageID = UUID()
            let message = try await coordinator.publish(
                folderID: SyncthingTransferFolderID.make(transferID: metadata.transferID),
                index: index,
                kind: .update,
                messageID: messageID
            )
            transferIDByMessageID[messageID] = metadata.transferID
            return message
        } catch {
            activeTransferIDs.remove(metadata.transferID)
            throw error
        }
    }

    func receive(_ message: SyncthingPeerMessage) async throws -> [SyncthingPeerMessage] {
        let acknowledgedMessageID: UUID? = if case let .ack(acknowledgement) = message {
            acknowledgement.acknowledgedMessageID
        } else {
            nil
        }
        let responses = try await coordinator.receive(message)
        if let acknowledgedMessageID,
           let transferID = transferIDByMessageID.removeValue(forKey: acknowledgedMessageID) {
            activeTransferIDs.remove(transferID)
        }
        return responses
    }
}
