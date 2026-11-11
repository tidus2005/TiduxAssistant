import AppKit
import CodexMobilityCore
import Combine
import Foundation

@MainActor
public final class MacFileSyncStore: ObservableObject {
    @Published public private(set) var directoryURL: URL?
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var queue: [MacSyncQueueItem] = []
    @Published public private(set) var recentResults: [MacSyncRecentResult] = []
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var isWatching = false

    public var outgoingOffersDidChange: (@MainActor @Sendable () -> Void)?

    private let preferences: any MacSyncDirectoryPreferencePersisting
    private let directoryChooser: any MacSyncDirectoryChoosing
    private let watcherPollingInterval: TimeInterval
    private let watcherStableInterval: TimeInterval
    private let maximumFileSize: UInt64
    private var engine: MacSyncFileTransferEngine?
    private var watcher: MacSyncDirectoryWatcher?
    private var incomingMetadataByID: [UUID: SyncItemMetadata] = [:]
    private var isUsingSecurityScope = false
    private var hasStarted = false
    private var moduleAccessEnabled = true
    private var moduleAccessGeneration: UInt64 = 0

    public init(
        preferences: any MacSyncDirectoryPreferencePersisting = UserDefaultsMacSyncDirectoryPreferences(),
        directoryChooser: any MacSyncDirectoryChoosing = MacSyncOpenPanelDirectoryChooser(),
        watcherPollingInterval: TimeInterval = MacSyncDirectoryWatcher.defaultFallbackScanInterval,
        watcherStableInterval: TimeInterval = 1.2,
        maximumFileSize: UInt64 = MacSyncFileTransferEngine.defaultMaximumFileSize
    ) {
        self.preferences = preferences
        self.directoryChooser = directoryChooser
        self.watcherPollingInterval = watcherPollingInterval
        self.watcherStableInterval = watcherStableInterval
        self.maximumFileSize = maximumFileSize
        self.isEnabled = preferences.loadIsEnabled()
    }

    public var directoryDisplayName: String {
        directoryURL?.path(percentEncoded: false) ?? "尚未选择目录"
    }

    public var pendingOutgoingCount: Int {
        queue.count { $0.direction == .toPhone }
    }

    public var activeIncomingCount: Int {
        queue.count { $0.direction == .toMac }
    }

    public var isOperational: Bool {
        moduleAccessEnabled && isEnabled && directoryURL != nil && engine != nil
    }

    func resumeModuleAccess() {
        guard !moduleAccessEnabled else { return }
        moduleAccessEnabled = true
        moduleAccessGeneration &+= 1
    }

    func suspendModuleAccess() {
        guard moduleAccessEnabled else { return }
        moduleAccessEnabled = false
        moduleAccessGeneration &+= 1
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard let bookmark = preferences.loadBookmark() else { return }
        let generation = moduleAccessGeneration

        do {
            let resolved = try MacSyncDirectoryBookmark.resolve(bookmark)
            if resolved.isStale {
                preferences.saveBookmark(try MacSyncDirectoryBookmark.make(for: resolved.url))
            }
            Task { @MainActor [weak self] in
                try? await self?.activateDirectory(
                    resolved.url,
                    expectedGeneration: generation
                )
            }
        } catch {
            lastErrorMessage = "无法恢复同步目录：\(error.localizedDescription)"
        }
    }

    public func chooseDirectory() {
        guard let url = directoryChooser.chooseDirectory() else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.selectDirectory(url)
            } catch {
                self?.lastErrorMessage = error.localizedDescription
            }
        }
    }

    public func revealDirectory() {
        guard let directoryURL else { return }
        NSWorkspace.shared.open(directoryURL)
    }

    public func selectDirectory(_ url: URL) async throws {
        guard moduleAccessEnabled else { throw MacFileSyncError.syncDisabled }
        let generation = moduleAccessGeneration
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MacFileSyncError.directoryUnavailable
        }

        let bookmark = try MacSyncDirectoryBookmark.make(for: url)
        preferences.saveBookmark(bookmark)
        if !isEnabled {
            isEnabled = true
            preferences.saveIsEnabled(true)
        }
        try await activateDirectory(url, expectedGeneration: generation)
    }

    public func clearDirectory() async {
        await stopWatcher()
        stopSecurityScopedAccess()
        engine = nil
        directoryURL = nil
        queue.removeAll()
        incomingMetadataByID.removeAll()
        isWatching = false
        preferences.saveBookmark(nil)
        outgoingOffersDidChange?()
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        preferences.saveIsEnabled(enabled)
        lastErrorMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            if enabled {
                await self.startWatcherIfReady()
            } else {
                await self.stopWatcher()
            }
        }
    }

    public func outgoingDescriptors() async -> [MacSyncFileDescriptor] {
        guard moduleAccessEnabled, isEnabled, let engine else { return [] }
        return await engine.outgoingDescriptors()
    }

    public func outgoingOffers() async -> [SyncItemMetadata] {
        await outgoingDescriptors().map { $0.syncMetadata(direction: .macToPhone) }
    }

    @discardableResult
    func enqueueOutgoingDiscoveredFile(
        _ discovered: MacSyncDiscoveredFile
    ) async throws -> MacSyncFileDescriptor? {
        let engine = try activeEngine()
        guard let descriptor = try await engine.enqueueDiscoveredFile(discovered) else {
            return nil
        }
        didEnqueueOutgoing(descriptor)
        return descriptor
    }

    public func nextOutgoingChunk(
        transferID: UUID,
        offset: UInt64,
        maximumBytes: Int
    ) async throws -> Data {
        let engine = try activeEngine()
        let data = try await engine.nextOutgoingChunk(
            transferID: transferID,
            offset: offset,
            maximumBytes: maximumBytes
        )
        updateQueueItem(transferID: transferID) { item in
            item.phase = .transferring
            item.transferredByteCount = min(offset + UInt64(data.count), item.byteCount)
            item.detail = "正在发送到 iPhone"
        }
        return data
    }

    public func nextOutgoingSyncChunk(
        transferID: UUID,
        offset: UInt64,
        maximumBytes: Int
    ) async throws -> SyncChunk {
        let data = try await nextOutgoingChunk(
            transferID: transferID,
            offset: offset,
            maximumBytes: min(maximumBytes, SyncProtocolLimits.maximumChunkSize)
        )
        let descriptors = await outgoingDescriptors()
        let totalBytes = queue.first(where: { $0.transferID == transferID })?.byteCount
            ?? descriptors.first(where: { $0.transferID == transferID })?.byteCount
        guard !data.isEmpty else {
            throw SyncProtocolError.invalidChunkSize(0)
        }
        return SyncChunk(
            transferID: transferID,
            offset: offset,
            data: data,
            isFinal: totalBytes == offset + UInt64(data.count)
        )
    }

    /// Reads an outgoing source without advancing the legacy transfer UI. The delta
    /// adapter uses this both while hashing an index and while serving exact blocks.
    func readOutgoingDeltaBlock(
        transferID: UUID,
        offset: UInt64,
        maximumBytes: Int
    ) async throws -> Data {
        let engine = try activeEngine()
        return try await engine.nextOutgoingChunk(
            transferID: transferID,
            offset: offset,
            maximumBytes: maximumBytes
        )
    }

    public func markOutgoingCompleted(transferID: UUID) async throws {
        let engine = try activeEngine()
        let descriptor = try await engine.markOutgoingCompleted(transferID: transferID)
        queue.removeAll { $0.transferID == transferID }
        prependResult(
            MacSyncRecentResult(
                relativePath: descriptor.relativePath,
                direction: .toPhone,
                succeeded: true,
                detail: "已发送到 iPhone"
            )
        )
        outgoingOffersDidChange?()
    }

    public func markOutgoingCompleted(_ completion: SyncCompletion) async throws {
        guard completion.stage == .receiverStored else {
            throw SyncProtocolError.invalidCompletionStage(completion.stage)
        }
        let descriptors = await outgoingDescriptors()
        let descriptor = try descriptors.first {
            $0.transferID == completion.transferID
        }.orThrow(MacFileSyncError.transferNotFound(completion.transferID))
        guard completion.totalBytes == descriptor.byteCount else {
            throw SyncProtocolError.incompleteTransfer(
                expected: descriptor.byteCount,
                actual: completion.totalBytes
            )
        }
        guard SyncSHA256.constantTimeEqual(completion.sha256, descriptor.sha256) else {
            throw SyncProtocolError.checksumMismatch(
                expected: descriptor.sha256,
                actual: completion.sha256
            )
        }
        try await markOutgoingCompleted(transferID: completion.transferID)
    }

    public func markOutgoingFailed(transferID: UUID, reason: String) async {
        guard let engine else { return }
        let descriptor = try? await engine.markOutgoingFailed(transferID: transferID)
        let path = descriptor?.relativePath
            ?? queue.first(where: { $0.transferID == transferID })?.relativePath
            ?? "未知文件"
        queue.removeAll { $0.transferID == transferID }
        prependResult(
            MacSyncRecentResult(
                relativePath: path,
                direction: .toPhone,
                succeeded: false,
                detail: reason
            )
        )
        lastErrorMessage = reason
        outgoingOffersDidChange?()
    }

    /// Records a peer-level delta rejection without discarding the source descriptor.
    /// A rejection is not proof that the local file is obsolete; keeping it allows an
    /// explicit retry (or a later file-backed fallback) without losing the queued data.
    public func markSyncthingOutgoingRejected(transferID: UUID, reason: String) async {
        guard let descriptor = await outgoingDescriptors().first(where: {
            $0.transferID == transferID
        }) else {
            lastErrorMessage = reason
            return
        }
        updateQueueItem(transferID: transferID) { item in
            item.phase = .failed
            item.detail = reason
        }
        prependResult(MacSyncRecentResult(
            relativePath: descriptor.relativePath,
            direction: .toPhone,
            succeeded: false,
            detail: reason
        ))
        lastErrorMessage = reason
    }

    public func prepareIncoming(_ descriptor: MacSyncFileDescriptor) async throws -> UInt64 {
        let engine = try activeEngine()
        do {
            let offset = try await engine.prepareIncoming(descriptor)
            upsertQueueItem(
                MacSyncQueueItem(
                    transferID: descriptor.transferID,
                    relativePath: descriptor.relativePath,
                    direction: .toMac,
                    byteCount: descriptor.byteCount,
                    transferredByteCount: offset,
                    phase: .transferring,
                    detail: offset > 0 ? "正在从断点继续接收" : "正在从 iPhone 接收"
                )
            )
            return offset
        } catch {
            recordIncomingFailure(descriptor: descriptor, error: error)
            throw error
        }
    }

    public func prepareIncoming(_ metadata: SyncItemMetadata) async throws -> UInt64 {
        let metadata = try metadata.validated()
        guard metadata.direction == .phoneToMac else {
            throw MacFileSyncError.invalidDirection
        }
        let descriptor = try MacSyncFileDescriptor(metadata: metadata)
        let offset = try await prepareIncoming(descriptor)
        incomingMetadataByID[metadata.transferID] = metadata
        return offset
    }

    public func writeIncoming(
        transferID: UUID,
        offset: UInt64,
        data: Data
    ) async throws -> UInt64 {
        let engine = try activeEngine()
        do {
            let nextOffset = try await engine.writeIncoming(
                transferID: transferID,
                offset: offset,
                data: data
            )
            updateQueueItem(transferID: transferID) { item in
                item.phase = .transferring
                item.transferredByteCount = nextOffset
                item.detail = "正在从 iPhone 接收"
            }
            return nextOffset
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func writeIncoming(_ chunk: SyncChunk) async throws -> UInt64 {
        guard let metadata = incomingMetadataByID[chunk.transferID] else {
            throw MacFileSyncError.transferNotFound(chunk.transferID)
        }
        guard !chunk.data.isEmpty,
              chunk.data.count <= SyncProtocolLimits.maximumChunkSize else {
            throw SyncProtocolError.invalidChunkSize(chunk.data.count)
        }
        guard SyncSHA256.matches(chunk.data, expectedHexDigest: chunk.checksumSHA256) else {
            throw SyncProtocolError.checksumMismatch(
                expected: chunk.checksumSHA256,
                actual: SyncSHA256.hexDigest(chunk.data)
            )
        }
        let endOffset = chunk.offset + UInt64(chunk.data.count)
        guard endOffset <= metadata.byteSize else {
            throw SyncProtocolError.chunkExceedsItemSize
        }
        guard chunk.isFinal == (endOffset == metadata.byteSize) else {
            throw SyncProtocolError.invalidFinalChunk
        }
        if let engine,
           let currentOffset = await engine.incomingOffset(transferID: chunk.transferID),
           chunk.offset < currentOffset,
           endOffset <= currentOffset {
            return currentOffset
        }
        return try await writeIncoming(
            transferID: chunk.transferID,
            offset: chunk.offset,
            data: chunk.data
        )
    }

    public func completeIncoming(transferID: UUID) async throws -> MacSyncCompletedTransfer {
        let engine = try activeEngine()
        do {
            let completed = try await engine.completeIncoming(transferID: transferID)
            queue.removeAll { $0.transferID == transferID }
            prependResult(
                MacSyncRecentResult(
                    relativePath: completed.relativePath,
                    direction: .toMac,
                    succeeded: true,
                    detail: completed.reusedExistingFile ? "本地已有相同文件" : "已保存到 Mac"
                )
            )
            lastErrorMessage = nil
            incomingMetadataByID.removeValue(forKey: transferID)
            return completed
        } catch {
            let path = queue.first(where: { $0.transferID == transferID })?.relativePath ?? "未知文件"
            updateQueueItem(transferID: transferID) { item in
                item.phase = .failed
                item.detail = error.localizedDescription
            }
            lastErrorMessage = error.localizedDescription
            if case MacFileSyncError.checksumMismatch = error {
                queue.removeAll { $0.transferID == transferID }
                incomingMetadataByID.removeValue(forKey: transferID)
                prependResult(
                    MacSyncRecentResult(
                        relativePath: path,
                        direction: .toMac,
                        succeeded: false,
                        detail: error.localizedDescription
                    )
                )
            }
            throw error
        }
    }

    public func completeIncoming(_ completion: SyncCompletion) async throws -> SyncCompletion {
        guard completion.stage == .senderFinished else {
            throw SyncProtocolError.invalidCompletionStage(completion.stage)
        }
        guard let metadata = incomingMetadataByID[completion.transferID] else {
            throw MacFileSyncError.transferNotFound(completion.transferID)
        }
        guard completion.totalBytes == metadata.byteSize else {
            throw SyncProtocolError.incompleteTransfer(
                expected: metadata.byteSize,
                actual: completion.totalBytes
            )
        }
        guard SyncSHA256.constantTimeEqual(completion.sha256, metadata.sha256) else {
            throw SyncProtocolError.checksumMismatch(
                expected: metadata.sha256,
                actual: completion.sha256
            )
        }
        let completed = try await completeIncoming(transferID: completion.transferID)
        return SyncCompletion(
            transferID: completed.transferID,
            totalBytes: completed.byteCount,
            sha256: completed.sha256,
            stage: .receiverStored,
            storedRelativePath: completed.relativePath
        )
    }

    public func cancelIncoming(transferID: UUID, reason: String = "传输已取消") async {
        await engine?.cancelIncoming(transferID: transferID)
        incomingMetadataByID.removeValue(forKey: transferID)
        if let item = queue.first(where: { $0.transferID == transferID }) {
            prependResult(
                MacSyncRecentResult(
                    relativePath: item.relativePath,
                    direction: .toMac,
                    succeeded: false,
                    detail: reason
                )
            )
        }
        queue.removeAll { $0.transferID == transferID }
    }

    /// Commits a fully verified delta file through the same engine, loop suppressor,
    /// queue and recent-result state used by the legacy receiver.
    func applySyncthingFile(
        _ commit: SyncthingAtomicFileCommit,
        transferID: UUID
    ) async throws {
        let engine = try activeEngine()
        upsertQueueItem(
            MacSyncQueueItem(
                transferID: transferID,
                relativePath: commit.relativePath,
                direction: .toMac,
                byteCount: UInt64(commit.data.count),
                transferredByteCount: UInt64(commit.data.count),
                phase: .transferring,
                detail: "正在校验并保存增量文件"
            )
        )

        do {
            let completed = try await engine.commitVerifiedIncoming(
                transferID: transferID,
                relativePath: commit.relativePath,
                data: commit.data,
                modifiedAt: commit.remoteIndex.modifiedAt,
                sha256: commit.verifiedSHA256
            )
            let supersededTransferIDs = Set(try await engine.discardOutgoing(
                relativePath: completed.relativePath
            ))
            queue.removeAll {
                $0.transferID == transferID || supersededTransferIDs.contains($0.transferID)
            }
            prependResult(
                MacSyncRecentResult(
                    relativePath: completed.relativePath,
                    direction: .toMac,
                    succeeded: true,
                    detail: "已通过块校验并保存到 Mac"
                )
            )
            lastErrorMessage = nil
            outgoingOffersDidChange?()
        } catch {
            updateQueueItem(transferID: transferID) { item in
                item.phase = .failed
                item.detail = error.localizedDescription
            }
            prependResult(
                MacSyncRecentResult(
                    relativePath: commit.relativePath,
                    direction: .toMac,
                    succeeded: false,
                    detail: error.localizedDescription
                )
            )
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Applies an accepted tombstone and reports it through the normal Mac sync UI.
    func applySyncthingDeletion(
        _ commit: SyncthingAtomicDeletionCommit,
        transferID: UUID
    ) async throws {
        let engine = try activeEngine()
        upsertQueueItem(
            MacSyncQueueItem(
                transferID: transferID,
                relativePath: commit.relativePath,
                direction: .toMac,
                byteCount: 0,
                phase: .transferring,
                detail: "正在同步删除"
            )
        )

        do {
            let relativePath = try await engine.commitIncomingDeletion(
                transferID: transferID,
                relativePath: commit.relativePath
            )
            let supersededTransferIDs = Set(try await engine.discardOutgoing(
                relativePath: relativePath
            ))
            queue.removeAll {
                $0.transferID == transferID || supersededTransferIDs.contains($0.transferID)
            }
            prependResult(
                MacSyncRecentResult(
                    relativePath: relativePath,
                    direction: .toMac,
                    succeeded: true,
                    detail: "已同步 iPhone 的删除"
                )
            )
            lastErrorMessage = nil
            outgoingOffersDidChange?()
        } catch {
            updateQueueItem(transferID: transferID) { item in
                item.phase = .failed
                item.detail = error.localizedDescription
            }
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func shutdown() {
        hasStarted = false
        moduleAccessGeneration &+= 1
        let currentWatcher = watcher
        watcher = nil
        isWatching = false
        Task {
            await currentWatcher?.stop()
        }
        stopSecurityScopedAccess()
        engine = nil
    }

    private func activateDirectory(
        _ url: URL,
        expectedGeneration: UInt64
    ) async throws {
        guard moduleAccessEnabled,
              expectedGeneration == moduleAccessGeneration else {
            throw MacFileSyncError.syncDisabled
        }
        await stopWatcher()
        guard moduleAccessEnabled,
              expectedGeneration == moduleAccessGeneration else {
            throw MacFileSyncError.syncDisabled
        }
        stopSecurityScopedAccess()

        let normalizedURL = url.standardizedFileURL
        let acquiredSecurityScope = normalizedURL.startAccessingSecurityScopedResource()
        isUsingSecurityScope = acquiredSecurityScope
        do {
            let sharedSuppressor = MacSyncLoopSuppressor()
            let newEngine = try MacSyncFileTransferEngine(
                rootURL: normalizedURL,
                loopSuppressor: sharedSuppressor,
                maximumFileSize: maximumFileSize
            )
            let newWatcher = MacSyncDirectoryWatcher(
                rootURL: normalizedURL,
                pollingInterval: watcherPollingInterval,
                stableInterval: watcherStableInterval
            ) { [weak self] discovered in
                guard let self else { return }
                do {
                    _ = try await self.enqueueOutgoingDiscoveredFile(discovered)
                } catch {
                    await self.recordWatcherError(error)
                }
            }

            directoryURL = normalizedURL
            engine = newEngine
            watcher = newWatcher
            queue.removeAll()
            incomingMetadataByID.removeAll()
            lastErrorMessage = nil
            await startWatcherIfReady(expectedGeneration: expectedGeneration)
        } catch {
            if acquiredSecurityScope {
                normalizedURL.stopAccessingSecurityScopedResource()
            }
            isUsingSecurityScope = false
            throw error
        }
    }

    private func startWatcherIfReady(expectedGeneration: UInt64? = nil) async {
        let generation = expectedGeneration ?? moduleAccessGeneration
        guard moduleAccessEnabled,
              generation == moduleAccessGeneration,
              isEnabled,
              directoryURL != nil,
              let watcher else {
            isWatching = false
            return
        }
        await watcher.start()
        guard moduleAccessEnabled,
              generation == moduleAccessGeneration else {
            await watcher.stop()
            isWatching = false
            return
        }
        isWatching = true
    }

    private func stopWatcher() async {
        await watcher?.stop()
        isWatching = false
    }

    private func stopSecurityScopedAccess() {
        if isUsingSecurityScope {
            directoryURL?.stopAccessingSecurityScopedResource()
        }
        isUsingSecurityScope = false
    }

    private func activeEngine() throws -> MacSyncFileTransferEngine {
        guard moduleAccessEnabled, isEnabled else { throw MacFileSyncError.syncDisabled }
        guard let engine, directoryURL != nil else {
            throw MacFileSyncError.directoryUnavailable
        }
        return engine
    }

    private func didEnqueueOutgoing(_ descriptor: MacSyncFileDescriptor) {
        upsertQueueItem(
            MacSyncQueueItem(
                transferID: descriptor.transferID,
                relativePath: descriptor.relativePath,
                direction: .toPhone,
                byteCount: descriptor.byteCount,
                phase: .queued,
                detail: "等待 iPhone 接收"
            )
        )
        outgoingOffersDidChange?()
    }

    private func recordWatcherError(_ error: Error) {
        lastErrorMessage = error.localizedDescription
    }

    private func recordIncomingFailure(descriptor: MacSyncFileDescriptor, error: Error) {
        queue.removeAll { $0.transferID == descriptor.transferID }
        prependResult(
            MacSyncRecentResult(
                relativePath: descriptor.relativePath,
                direction: .toMac,
                succeeded: false,
                detail: error.localizedDescription
            )
        )
        lastErrorMessage = error.localizedDescription
    }

    private func upsertQueueItem(_ item: MacSyncQueueItem) {
        if let index = queue.firstIndex(where: { $0.transferID == item.transferID }) {
            queue[index] = item
        } else {
            queue.insert(item, at: 0)
        }
        if queue.count > 100 {
            queue.removeLast(queue.count - 100)
        }
    }

    private func updateQueueItem(
        transferID: UUID,
        update: (inout MacSyncQueueItem) -> Void
    ) {
        guard let index = queue.firstIndex(where: { $0.transferID == transferID }) else { return }
        update(&queue[index])
        queue[index].updatedAt = Date()
    }

    private func prependResult(_ result: MacSyncRecentResult) {
        recentResults.insert(result, at: 0)
        if recentResults.count > 30 {
            recentResults.removeLast(recentResults.count - 30)
        }
    }
}

private extension Optional {
    func orThrow(_ error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
