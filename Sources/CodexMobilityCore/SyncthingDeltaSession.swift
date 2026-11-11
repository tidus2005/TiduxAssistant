import Foundation

public enum SyncthingDeltaSessionError: Error, Equatable, Sendable {
    case remoteIndexIsTombstone
    case indexPathMismatch(local: String, remote: String)
    case fileTooLargeForMemory(UInt64)
    case unexpectedRelativePath(expected: String, actual: String)
    case blockOutOfBounds(offset: UInt64, size: Int, fileSize: UInt64)
    case unexpectedBlock(offset: UInt64)
    case duplicateBlock(offset: UInt64)
    case blockMetadataMismatch(
        expected: SyncthingBlockRequest,
        actual: SyncthingBlockRequest
    )
    case blockSizeMismatch(offset: UInt64, expected: Int, actual: Int)
    case blockHashMismatch(offset: UInt64, expected: String, actual: String)
    case wholeFileHashMismatch(expected: String, actual: String)
    case sessionAlreadyComplete
}

public enum SyncthingReconciliationReason: Equatable, Sendable {
    case noLocalIndex
    case identicalContent
    case equalVersion
    case equalVersionContentMismatch
    case localVersionDominates
    case remoteVersionDominates
    case concurrentContent
    case concurrentRemoteDeletion
    case concurrentLocalDeletion
    case concurrentDeletions
}

public enum SyncthingReconciliationAction: Equatable, Sendable {
    /// The local entry is already current, or is the safer winner of a conflict.
    case keepLocal
    /// Download and atomically commit the remote content at this relative path.
    case applyRemote(relativePath: String)
    /// Atomically remove the local path after persisting the remote tombstone.
    case deleteLocal(relativePath: String)
}

public struct SyncthingReconciliationDecision: Equatable, Sendable {
    public let action: SyncthingReconciliationAction
    public let relation: SyncthingVersionRelation?
    public let reason: SyncthingReconciliationReason

    public init(
        action: SyncthingReconciliationAction,
        relation: SyncthingVersionRelation?,
        reason: SyncthingReconciliationReason
    ) {
        self.action = action
        self.relation = relation
        self.reason = reason
    }
}

/// Resolves one remote index entry without touching the file system.
///
/// Concurrent live files preserve the local file and give the remote file a
/// deterministic Syncthing-style conflict name. A live file wins over a
/// concurrent tombstone so a delete cannot silently discard an edit.
public enum SyncthingDeltaReconciler {
    public static func decide(
        remoteIndex: SyncthingFileIndex,
        localIndex: SyncthingFileIndex?
    ) throws -> SyncthingReconciliationDecision {
        guard let localIndex else {
            return SyncthingReconciliationDecision(
                action: remoteIndex.deleted
                    ? .deleteLocal(relativePath: remoteIndex.relativePath)
                    : .applyRemote(relativePath: remoteIndex.relativePath),
                relation: nil,
                reason: .noLocalIndex
            )
        }

        guard localIndex.relativePath == remoteIndex.relativePath else {
            throw SyncthingDeltaSessionError.indexPathMismatch(
                local: localIndex.relativePath,
                remote: remoteIndex.relativePath
            )
        }

        let relation = remoteIndex.version.relation(to: localIndex.version)

        // A reconnect or restored app installation may have the bytes but not the
        // original vector-clock database. Content identity is still sufficient to
        // avoid downloading or creating a conflict copy. The platform can persist
        // or merge the remote vector after acknowledging the index.
        if remoteIndex.deleted == localIndex.deleted {
            let hasIdenticalContent: Bool
            if remoteIndex.deleted {
                hasIdenticalContent = true
            } else {
                hasIdenticalContent = remoteIndex.size == localIndex.size
                    && remoteIndex.wholeFileSHA256.map { remoteDigest in
                        localIndex.wholeFileSHA256.map {
                            SyncSHA256.constantTimeEqual(remoteDigest, $0)
                        } ?? false
                    } == true
            }
            if hasIdenticalContent {
                return SyncthingReconciliationDecision(
                    action: .keepLocal,
                    relation: relation,
                    reason: .identicalContent
                )
            }
        }

        switch relation {
        case .equal:
            // Equal vector clocks with different bytes indicate lost/corrupt local
            // history (for example, a file whose mtime was deliberately preserved).
            // Never silently discard either live payload in that state.
            if remoteIndex.deleted {
                return SyncthingReconciliationDecision(
                    action: .keepLocal,
                    relation: relation,
                    reason: .equalVersionContentMismatch
                )
            }
            if localIndex.deleted {
                return SyncthingReconciliationDecision(
                    action: .applyRemote(relativePath: remoteIndex.relativePath),
                    relation: relation,
                    reason: .equalVersionContentMismatch
                )
            }
            let conflictPath = try SyncthingPlanner.conflictRelativePath(
                for: remoteIndex.relativePath,
                modifiedAt: remoteIndex.modifiedAt,
                deviceID: remoteIndex.deviceID
            )
            return SyncthingReconciliationDecision(
                action: .applyRemote(relativePath: conflictPath),
                relation: relation,
                reason: .equalVersionContentMismatch
            )

        case .dominated:
            return SyncthingReconciliationDecision(
                action: .keepLocal,
                relation: relation,
                reason: .localVersionDominates
            )

        case .dominates:
            return SyncthingReconciliationDecision(
                action: remoteIndex.deleted
                    ? .deleteLocal(relativePath: remoteIndex.relativePath)
                    : .applyRemote(relativePath: remoteIndex.relativePath),
                relation: relation,
                reason: .remoteVersionDominates
            )

        case .concurrent:
            if remoteIndex.deleted {
                return SyncthingReconciliationDecision(
                    action: .keepLocal,
                    relation: relation,
                    reason: localIndex.deleted
                        ? .concurrentDeletions
                        : .concurrentRemoteDeletion
                )
            }

            if localIndex.deleted {
                return SyncthingReconciliationDecision(
                    action: .applyRemote(relativePath: remoteIndex.relativePath),
                    relation: relation,
                    reason: .concurrentLocalDeletion
                )
            }

            let conflictPath = try SyncthingPlanner.conflictRelativePath(
                for: remoteIndex.relativePath,
                modifiedAt: remoteIndex.modifiedAt,
                deviceID: remoteIndex.deviceID
            )
            return SyncthingReconciliationDecision(
                action: .applyRemote(relativePath: conflictPath),
                relation: relation,
                reason: .concurrentContent
            )
        }
    }
}

/// A fully verified file image. The platform layer can write `data` to a
/// sibling temporary file and rename it over `relativePath` atomically.
public struct SyncthingAtomicFileCommit: Equatable, Sendable {
    public let relativePath: String
    public let data: Data
    public let remoteIndex: SyncthingFileIndex
    public let verifiedSHA256: String

    public init(
        relativePath: String,
        data: Data,
        remoteIndex: SyncthingFileIndex,
        verifiedSHA256: String
    ) {
        self.relativePath = relativePath
        self.data = data
        self.remoteIndex = remoteIndex
        self.verifiedSHA256 = verifiedSHA256
    }
}

public struct SyncthingAtomicDeletionCommit: Equatable, Sendable {
    public let relativePath: String
    public let tombstone: SyncthingFileIndex

    public init(relativePath: String, tombstone: SyncthingFileIndex) {
        self.relativePath = relativePath
        self.tombstone = tombstone
    }
}

public enum SyncthingDeltaPreparation: Sendable {
    case noChange(SyncthingReconciliationDecision)
    case deletion(
        SyncthingAtomicDeletionCommit,
        decision: SyncthingReconciliationDecision
    )
    case transfer(
        SyncthingDeltaSession,
        decision: SyncthingReconciliationDecision
    )
}

/// Pure in-memory state machine for a single Syncthing-style block download.
///
/// Local block data is content-addressed by SHA-256 and may satisfy any remote
/// block with the same size and digest. Remaining blocks are exposed as exact
/// requests. No partial result is returned until every block and the whole-file
/// digest have been verified.
public struct SyncthingDeltaSession: Sendable {
    /// This reference state machine assembles in memory. Platform integrations must use
    /// file-backed staging above this size rather than risking iPhone memory pressure.
    public static let maximumInMemoryFileSize: UInt64 = 256 * 1_024 * 1_024

    public let remoteIndex: SyncthingFileIndex
    public let targetRelativePath: String

    private var blocksByOffset: [UInt64: Data]
    private var completedCommit: SyncthingAtomicFileCommit?
    private let locallyReusedOffsets: Set<UInt64>

    public static func prepare(
        remoteIndex: SyncthingFileIndex,
        localIndex: SyncthingFileIndex?,
        locallyAvailableBlocks: [Data] = []
    ) throws -> SyncthingDeltaPreparation {
        let decision = try SyncthingDeltaReconciler.decide(
            remoteIndex: remoteIndex,
            localIndex: localIndex
        )
        switch decision.action {
        case .keepLocal:
            return .noChange(decision)

        case let .deleteLocal(relativePath):
            return .deletion(
                SyncthingAtomicDeletionCommit(
                    relativePath: relativePath,
                    tombstone: remoteIndex
                ),
                decision: decision
            )

        case let .applyRemote(relativePath):
            return .transfer(
                try SyncthingDeltaSession(
                    remoteIndex: remoteIndex,
                    targetRelativePath: relativePath,
                    locallyAvailableBlocks: locallyAvailableBlocks
                ),
                decision: decision
            )
        }
    }

    public init(
        remoteIndex: SyncthingFileIndex,
        targetRelativePath: String? = nil,
        locallyAvailableBlocks: [Data] = []
    ) throws {
        guard !remoteIndex.deleted else {
            throw SyncthingDeltaSessionError.remoteIndexIsTombstone
        }
        guard remoteIndex.size <= Self.maximumInMemoryFileSize else {
            throw SyncthingDeltaSessionError.fileTooLargeForMemory(remoteIndex.size)
        }

        let targetRelativePath = try SyncRelativePath.normalize(
            targetRelativePath ?? remoteIndex.relativePath
        )
        var cacheByHash: [String: [Data]] = [:]
        for data in locallyAvailableBlocks {
            cacheByHash[SyncSHA256.hexDigest(data), default: []].append(data)
        }

        var blocksByOffset: [UInt64: Data] = [:]
        var locallyReusedOffsets: Set<UInt64> = []
        for block in remoteIndex.blocks {
            guard let candidates = cacheByHash[block.sha256],
                  let data = candidates.first(where: { $0.count == block.size }) else {
                continue
            }
            blocksByOffset[block.offset] = data
            locallyReusedOffsets.insert(block.offset)
        }

        self.remoteIndex = remoteIndex
        self.targetRelativePath = targetRelativePath
        self.blocksByOffset = blocksByOffset
        self.locallyReusedOffsets = locallyReusedOffsets
        self.completedCommit = nil
        self.completedCommit = try makeCommitIfComplete()
    }

    public var pendingRequests: [SyncthingBlockRequest] {
        remoteIndex.blocks.compactMap { block in
            blocksByOffset[block.offset] == nil ? SyncthingBlockRequest(block: block) : nil
        }
    }

    public var requestedBlocks: [SyncthingBlockRequest] { pendingRequests }
    public var isComplete: Bool { completedCommit != nil }
    public var commit: SyncthingAtomicFileCommit? { completedCommit }
    public var reusedBlockCount: Int { locallyReusedOffsets.count }
    public var assembledBlockCount: Int { blocksByOffset.count }

    /// Accepts one exact block response. A non-nil return value is emitted only
    /// once the assembled file has passed its whole-file SHA-256 check.
    @discardableResult
    public mutating func receive(
        block actualBlock: SyncthingBlockRequest,
        data: Data
    ) throws -> SyncthingAtomicFileCommit? {
        guard let expectedInfo = remoteIndex.blocks.first(where: {
            $0.offset == actualBlock.offset
        }) else {
            guard let endOffset = endOffset(
                offset: actualBlock.offset,
                size: actualBlock.size
            ), actualBlock.offset < remoteIndex.size, endOffset <= remoteIndex.size else {
                throw SyncthingDeltaSessionError.blockOutOfBounds(
                    offset: actualBlock.offset,
                    size: actualBlock.size,
                    fileSize: remoteIndex.size
                )
            }
            throw SyncthingDeltaSessionError.unexpectedBlock(offset: actualBlock.offset)
        }

        if blocksByOffset[actualBlock.offset] != nil {
            throw SyncthingDeltaSessionError.duplicateBlock(offset: actualBlock.offset)
        }
        guard completedCommit == nil else {
            throw SyncthingDeltaSessionError.sessionAlreadyComplete
        }

        let expectedBlock = SyncthingBlockRequest(block: expectedInfo)
        guard actualBlock == expectedBlock else {
            throw SyncthingDeltaSessionError.blockMetadataMismatch(
                expected: expectedBlock,
                actual: actualBlock
            )
        }
        guard data.count == expectedBlock.size else {
            throw SyncthingDeltaSessionError.blockSizeMismatch(
                offset: expectedBlock.offset,
                expected: expectedBlock.size,
                actual: data.count
            )
        }

        let actualHash = SyncSHA256.hexDigest(data)
        guard SyncSHA256.constantTimeEqual(actualHash, expectedBlock.sha256) else {
            throw SyncthingDeltaSessionError.blockHashMismatch(
                offset: expectedBlock.offset,
                expected: expectedBlock.sha256,
                actual: actualHash
            )
        }

        blocksByOffset[expectedBlock.offset] = data
        completedCommit = try makeCommitIfComplete()
        return completedCommit
    }

    @discardableResult
    public mutating func receive(
        _ response: SyncthingPeerBlockResponse
    ) throws -> SyncthingAtomicFileCommit? {
        guard response.relativePath == remoteIndex.relativePath else {
            throw SyncthingDeltaSessionError.unexpectedRelativePath(
                expected: remoteIndex.relativePath,
                actual: response.relativePath
            )
        }
        return try receive(block: response.block, data: response.data)
    }

    private func makeCommitIfComplete() throws -> SyncthingAtomicFileCommit? {
        guard blocksByOffset.count == remoteIndex.blocks.count else { return nil }

        var data = Data()
        data.reserveCapacity(Int(remoteIndex.size))
        for block in remoteIndex.blocks {
            guard let blockData = blocksByOffset[block.offset] else { return nil }
            data.append(blockData)
        }

        let actualHash = SyncSHA256.hexDigest(data)
        let expectedHash = remoteIndex.wholeFileSHA256 ?? ""
        guard SyncSHA256.constantTimeEqual(actualHash, expectedHash) else {
            throw SyncthingDeltaSessionError.wholeFileHashMismatch(
                expected: expectedHash,
                actual: actualHash
            )
        }
        return SyncthingAtomicFileCommit(
            relativePath: targetRelativePath,
            data: data,
            remoteIndex: remoteIndex,
            verifiedSHA256: actualHash
        )
    }

    private func endOffset(offset: UInt64, size: Int) -> UInt64? {
        guard size > 0 else { return nil }
        let (endOffset, overflow) = offset.addingReportingOverflow(UInt64(size))
        return overflow ? nil : endOffset
    }
}
