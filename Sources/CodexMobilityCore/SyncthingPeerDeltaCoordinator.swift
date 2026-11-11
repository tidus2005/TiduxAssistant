import Foundation

/// A platform-owned, atomic change produced by the peer delta coordinator.
///
/// The adapter is responsible for staging the file beside its destination and
/// renaming it into place, or for durably applying the tombstone, before the
/// coordinator emits an acknowledgement to the peer.
public enum SyncthingPeerDeltaCommit: Equatable, Sendable {
    case file(SyncthingAtomicFileCommit)
    case deletion(SyncthingAtomicDeletionCommit)
}

/// Bridges the transport-independent delta state machine to platform storage.
///
/// Implementations are commonly actors. All storage operations are asynchronous
/// so the coordinator never assumes that an index or block is memory-backed.
public protocol SyncthingPeerDeltaAdapter: Sendable {
    /// Returns the current index for the same logical path, if it exists locally.
    func localIndex(
        folderID: String,
        relativePath: String
    ) async throws -> SyncthingFileIndex?

    /// Returns verified candidate block bytes that can be reused for `remoteIndex`.
    /// The coordinator and `SyncthingDeltaSession` re-hash every candidate before use.
    func reusableBlockData(
        folderID: String,
        remoteIndex: SyncthingFileIndex
    ) async throws -> [Data]

    /// Reads one exact block from a locally published file.
    func readBlock(
        folderID: String,
        index: SyncthingFileIndex,
        block: SyncthingBlockRequest
    ) async throws -> Data

    /// Durably and atomically applies an incoming file or tombstone.
    func commit(
        _ commit: SyncthingPeerDeltaCommit,
        folderID: String
    ) async throws

    /// Records the terminal acknowledgement for a locally published index.
    func outgoingTransferDidFinish(
        folderID: String,
        index: SyncthingFileIndex,
        acknowledgement: SyncthingPeerAcknowledgement
    ) async throws
}

public extension SyncthingPeerDeltaAdapter {
    func reusableBlockData(
        folderID: String,
        remoteIndex: SyncthingFileIndex
    ) async throws -> [Data] {
        []
    }

    func outgoingTransferDidFinish(
        folderID: String,
        index: SyncthingFileIndex,
        acknowledgement: SyncthingPeerAcknowledgement
    ) async throws {}
}

public enum SyncthingPeerIndexPublicationKind: Sendable {
    case fullIndex
    case update
}

public enum SyncthingPeerDeltaCoordinatorError: Error, Equatable, Sendable {
    case emptyFolderID
    case indexMustContainSingleEntry(actual: Int)
    case transferAlreadyActive(folderID: String)
    case transferIsBusy(folderID: String)
    case requiresFileBackedFallback(size: UInt64, maximumInMemorySize: UInt64)
    case noPublishedIndex(folderID: String)
    case requestPathMismatch(expected: String, actual: String)
    case requestedBlockWasNotPublished(SyncthingBlockRequest)
    case sourceBlockSizeMismatch(expected: Int, actual: Int)
    case sourceBlockHashMismatch(expected: String, actual: String)
    case noIncomingTransfer(folderID: String)
    case unexpectedResponseRequestID(UUID)
    case responseFolderMismatch(expected: String, actual: String)
    case responsePathMismatch(expected: String, actual: String)
    case responseBlockMismatch(
        expected: SyncthingBlockRequest,
        actual: SyncthingBlockRequest
    )
    case duplicateGeneratedRequestID(UUID)
    case unexpectedAcknowledgement(UUID)
    case invalidSessionState(folderID: String)
    case unsupportedMessage
}

/// Drives one Syncthing-style block transfer per folder and direction.
///
/// The actor consumes and produces `SyncthingPeerMessage` values only; it has no
/// dependency on Network.framework or either platform feature target. Incoming
/// files are assembled with `SyncthingDeltaSession`, which intentionally caps
/// in-memory files at `maximumInMemoryFileSize`. Callers should fall back to the
/// existing file-backed `.transfer` path when `requiresFileBackedFallback` is thrown.
public actor SyncthingPeerDeltaCoordinator<Adapter: SyncthingPeerDeltaAdapter> {
    public static var maximumInMemoryFileSize: UInt64 {
        SyncthingDeltaSession.maximumInMemoryFileSize
    }

    private struct OutgoingTransfer: Sendable {
        let messageID: UUID
        let index: SyncthingFileIndex
    }

    private struct IncomingTransfer: Sendable {
        let sourceMessageID: UUID
        let remoteIndex: SyncthingFileIndex
        var session: SyncthingDeltaSession
        var pendingRequests: [UUID: SyncthingBlockRequest]
    }

    private let adapter: Adapter
    private let requestIDGenerator: @Sendable () -> UUID
    private var outgoingByFolder: [String: OutgoingTransfer] = [:]
    private var incomingByFolder: [String: IncomingTransfer] = [:]
    private var preparingIncomingFolders: Set<String> = []
    private var committingIncomingFolders: Set<String> = []
    private var acknowledgingMessageIDs: Set<UUID> = []

    public init(
        adapter: Adapter,
        requestIDGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.adapter = adapter
        self.requestIDGenerator = requestIDGenerator
    }

    /// Publishes one file index. The returned message must be sent before serving
    /// block requests for that folder.
    public func publish(
        folderID: String,
        index: SyncthingFileIndex,
        kind: SyncthingPeerIndexPublicationKind = .fullIndex,
        messageID: UUID = UUID()
    ) throws -> SyncthingPeerMessage {
        try validate(folderID: folderID)
        guard outgoingByFolder[folderID] == nil else {
            throw SyncthingPeerDeltaCoordinatorError.transferAlreadyActive(folderID: folderID)
        }

        outgoingByFolder[folderID] = OutgoingTransfer(
            messageID: messageID,
            index: index
        )
        switch kind {
        case .fullIndex:
            return .index(SyncthingPeerIndex(
                messageID: messageID,
                folderID: folderID,
                sequence: index.sequence,
                entries: [index]
            ))
        case .update:
            return .indexUpdate(SyncthingPeerIndexUpdate(
                messageID: messageID,
                folderID: folderID,
                sequence: index.sequence,
                entries: [index]
            ))
        }
    }

    public func receive(_ message: SyncthingPeerMessage) async throws -> [SyncthingPeerMessage] {
        switch message {
        case let .index(index):
            return try await receiveIndex(
                messageID: index.messageID,
                folderID: index.folderID,
                entries: index.entries
            )
        case let .indexUpdate(update):
            return try await receiveIndex(
                messageID: update.messageID,
                folderID: update.folderID,
                entries: update.entries
            )
        case let .blockRequest(request):
            return [try await receiveBlockRequest(request)]
        case let .blockResponse(response):
            return try await receiveBlockResponse(response)
        case let .ack(acknowledgement):
            try await receiveAcknowledgement(acknowledgement)
            return []
        case .hello, .close, .transfer:
            throw SyncthingPeerDeltaCoordinatorError.unsupportedMessage
        }
    }

    private func receiveIndex(
        messageID: UUID,
        folderID: String,
        entries: [SyncthingFileIndex]
    ) async throws -> [SyncthingPeerMessage] {
        try validate(folderID: folderID)
        guard entries.count == 1 else {
            throw SyncthingPeerDeltaCoordinatorError.indexMustContainSingleEntry(
                actual: entries.count
            )
        }
        guard incomingByFolder[folderID] == nil,
              !preparingIncomingFolders.contains(folderID),
              !committingIncomingFolders.contains(folderID) else {
            throw SyncthingPeerDeltaCoordinatorError.transferAlreadyActive(folderID: folderID)
        }

        preparingIncomingFolders.insert(folderID)
        do {
            let remoteIndex = entries[0]
            guard remoteIndex.deleted || remoteIndex.size <= Self.maximumInMemoryFileSize else {
                throw SyncthingPeerDeltaCoordinatorError.requiresFileBackedFallback(
                    size: remoteIndex.size,
                    maximumInMemorySize: Self.maximumInMemoryFileSize
                )
            }
            let localIndex = try await adapter.localIndex(
                folderID: folderID,
                relativePath: remoteIndex.relativePath
            )
            let decision = try SyncthingDeltaReconciler.decide(
                remoteIndex: remoteIndex,
                localIndex: localIndex
            )

            switch decision.action {
            case .keepLocal:
                preparingIncomingFolders.remove(folderID)
                return [acceptedAcknowledgement(for: messageID)]

            case let .deleteLocal(relativePath):
                committingIncomingFolders.insert(folderID)
                preparingIncomingFolders.remove(folderID)
                do {
                    try await adapter.commit(
                        .deletion(SyncthingAtomicDeletionCommit(
                            relativePath: relativePath,
                            tombstone: remoteIndex
                        )),
                        folderID: folderID
                    )
                    committingIncomingFolders.remove(folderID)
                    return [acceptedAcknowledgement(for: messageID)]
                } catch {
                    committingIncomingFolders.remove(folderID)
                    throw error
                }

            case let .applyRemote(relativePath):
                let reusableBlocks = try await adapter.reusableBlockData(
                    folderID: folderID,
                    remoteIndex: remoteIndex
                )
                let session = try SyncthingDeltaSession(
                    remoteIndex: remoteIndex,
                    targetRelativePath: relativePath,
                    locallyAvailableBlocks: reusableBlocks
                )

                if let commit = session.commit {
                    committingIncomingFolders.insert(folderID)
                    preparingIncomingFolders.remove(folderID)
                    do {
                        try await adapter.commit(.file(commit), folderID: folderID)
                        committingIncomingFolders.remove(folderID)
                        return [acceptedAcknowledgement(for: messageID)]
                    } catch {
                        committingIncomingFolders.remove(folderID)
                        throw error
                    }
                }

                var pending: [UUID: SyncthingBlockRequest] = [:]
                for block in session.pendingRequests {
                    let requestID = requestIDGenerator()
                    guard pending.updateValue(block, forKey: requestID) == nil else {
                        throw SyncthingPeerDeltaCoordinatorError.duplicateGeneratedRequestID(
                            requestID
                        )
                    }
                }
                guard !pending.isEmpty else {
                    throw SyncthingPeerDeltaCoordinatorError.invalidSessionState(
                        folderID: folderID
                    )
                }
                incomingByFolder[folderID] = IncomingTransfer(
                    sourceMessageID: messageID,
                    remoteIndex: remoteIndex,
                    session: session,
                    pendingRequests: pending
                )
                preparingIncomingFolders.remove(folderID)

                return pending
                    .sorted { lhs, rhs in
                        if lhs.value.offset == rhs.value.offset {
                            return lhs.key.uuidString < rhs.key.uuidString
                        }
                        return lhs.value.offset < rhs.value.offset
                    }
                    .map { requestID, block in
                        .blockRequest(SyncthingPeerBlockRequest(
                            requestID: requestID,
                            folderID: folderID,
                            relativePath: remoteIndex.relativePath,
                            block: block
                        ))
                    }
            }
        } catch {
            preparingIncomingFolders.remove(folderID)
            throw error
        }
    }

    private func receiveBlockRequest(
        _ request: SyncthingPeerBlockRequest
    ) async throws -> SyncthingPeerMessage {
        try validate(folderID: request.folderID)
        guard let transfer = outgoingByFolder[request.folderID] else {
            throw SyncthingPeerDeltaCoordinatorError.noPublishedIndex(
                folderID: request.folderID
            )
        }
        guard request.relativePath == transfer.index.relativePath else {
            throw SyncthingPeerDeltaCoordinatorError.requestPathMismatch(
                expected: transfer.index.relativePath,
                actual: request.relativePath
            )
        }
        guard transfer.index.blocks.contains(where: {
            SyncthingBlockRequest(block: $0) == request.block
        }) else {
            throw SyncthingPeerDeltaCoordinatorError.requestedBlockWasNotPublished(
                request.block
            )
        }

        let data = try await adapter.readBlock(
            folderID: request.folderID,
            index: transfer.index,
            block: request.block
        )
        guard data.count == request.block.size else {
            throw SyncthingPeerDeltaCoordinatorError.sourceBlockSizeMismatch(
                expected: request.block.size,
                actual: data.count
            )
        }
        let actualHash = SyncSHA256.hexDigest(data)
        guard SyncSHA256.constantTimeEqual(actualHash, request.block.sha256) else {
            throw SyncthingPeerDeltaCoordinatorError.sourceBlockHashMismatch(
                expected: request.block.sha256,
                actual: actualHash
            )
        }

        return .blockResponse(SyncthingPeerBlockResponse(
            requestID: request.requestID,
            folderID: request.folderID,
            relativePath: request.relativePath,
            block: request.block,
            data: data
        ))
    }

    private func receiveBlockResponse(
        _ response: SyncthingPeerBlockResponse
    ) async throws -> [SyncthingPeerMessage] {
        try validate(folderID: response.folderID)
        if committingIncomingFolders.contains(response.folderID) {
            throw SyncthingPeerDeltaCoordinatorError.transferIsBusy(
                folderID: response.folderID
            )
        }

        guard var transfer = incomingByFolder[response.folderID] else {
            if let expectedFolder = incomingByFolder.first(where: {
                $0.value.pendingRequests[response.requestID] != nil
            })?.key {
                throw SyncthingPeerDeltaCoordinatorError.responseFolderMismatch(
                    expected: expectedFolder,
                    actual: response.folderID
                )
            }
            throw SyncthingPeerDeltaCoordinatorError.noIncomingTransfer(
                folderID: response.folderID
            )
        }
        guard let expectedBlock = transfer.pendingRequests[response.requestID] else {
            throw SyncthingPeerDeltaCoordinatorError.unexpectedResponseRequestID(
                response.requestID
            )
        }
        guard response.relativePath == transfer.remoteIndex.relativePath else {
            throw SyncthingPeerDeltaCoordinatorError.responsePathMismatch(
                expected: transfer.remoteIndex.relativePath,
                actual: response.relativePath
            )
        }
        guard response.block == expectedBlock else {
            throw SyncthingPeerDeltaCoordinatorError.responseBlockMismatch(
                expected: expectedBlock,
                actual: response.block
            )
        }

        let originalTransfer = transfer
        let completedCommit = try transfer.session.receive(
            block: response.block,
            data: response.data
        )
        transfer.pendingRequests.removeValue(forKey: response.requestID)

        guard let completedCommit else {
            guard !transfer.pendingRequests.isEmpty else {
                throw SyncthingPeerDeltaCoordinatorError.invalidSessionState(
                    folderID: response.folderID
                )
            }
            incomingByFolder[response.folderID] = transfer
            return []
        }
        guard transfer.pendingRequests.isEmpty else {
            throw SyncthingPeerDeltaCoordinatorError.invalidSessionState(
                folderID: response.folderID
            )
        }

        incomingByFolder[response.folderID] = transfer
        committingIncomingFolders.insert(response.folderID)
        do {
            try await adapter.commit(.file(completedCommit), folderID: response.folderID)
            incomingByFolder.removeValue(forKey: response.folderID)
            committingIncomingFolders.remove(response.folderID)
            return [acceptedAcknowledgement(for: transfer.sourceMessageID)]
        } catch {
            incomingByFolder[response.folderID] = originalTransfer
            committingIncomingFolders.remove(response.folderID)
            throw error
        }
    }

    private func receiveAcknowledgement(
        _ acknowledgement: SyncthingPeerAcknowledgement
    ) async throws {
        guard !acknowledgingMessageIDs.contains(acknowledgement.acknowledgedMessageID),
              let match = outgoingByFolder.first(where: {
                  $0.value.messageID == acknowledgement.acknowledgedMessageID
              }) else {
            throw SyncthingPeerDeltaCoordinatorError.unexpectedAcknowledgement(
                acknowledgement.acknowledgedMessageID
            )
        }

        let folderID = match.key
        let transfer = match.value
        acknowledgingMessageIDs.insert(acknowledgement.acknowledgedMessageID)
        do {
            try await adapter.outgoingTransferDidFinish(
                folderID: folderID,
                index: transfer.index,
                acknowledgement: acknowledgement
            )
            if outgoingByFolder[folderID]?.messageID == transfer.messageID {
                outgoingByFolder.removeValue(forKey: folderID)
            }
            acknowledgingMessageIDs.remove(acknowledgement.acknowledgedMessageID)
        } catch {
            acknowledgingMessageIDs.remove(acknowledgement.acknowledgedMessageID)
            throw error
        }
    }

    private func validate(folderID: String) throws {
        guard !folderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SyncthingPeerDeltaCoordinatorError.emptyFolderID
        }
    }

    private func acceptedAcknowledgement(for messageID: UUID) -> SyncthingPeerMessage {
        .ack(SyncthingPeerAcknowledgement(
            acknowledgedMessageID: messageID,
            status: .accepted
        ))
    }
}
