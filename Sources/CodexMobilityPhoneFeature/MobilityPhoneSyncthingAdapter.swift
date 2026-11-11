import CodexMobilityCore
import Foundation

public enum MobilityPhoneSyncthingDeltaError: LocalizedError, Equatable, Sendable {
    case inactivePeerConnection
    case staleConnectionGeneration
    case invalidTransferFolderID(String)
    case unknownTransfer(UUID)
    case transferNotClaimed(UUID)
    case peerMessageSendFailed
    case storeReleased

    public var errorDescription: String? {
        switch self {
        case .inactivePeerConnection:
            "Syncthing 点对点连接尚未就绪。"
        case .staleConnectionGeneration:
            "同步连接已经更新，已丢弃旧连接的消息。"
        case .invalidTransferFolderID(let folderID):
            "收到无效的同步传输标识：\(folderID)"
        case .unknownTransfer:
            "找不到对应的同步文件，请重新连接后重试。"
        case .transferNotClaimed:
            "该文件未被当前 Syncthing 连接接管。"
        case .peerMessageSendFailed:
            "无法通过当前 Syncthing 连接发送消息。"
        case .storeReleased:
            "同步存储已经关闭。"
        }
    }
}

/// Generation-bound storage bridge. A coordinator from an old connection cannot
/// commit bytes or complete a queue entry after a reconnect replaces it.
actor MobilityPhoneSyncthingAdapter: SyncthingPeerDeltaAdapter {
    private weak var store: MobilityPhoneSyncStore?
    private let generation: UInt64

    init(store: MobilityPhoneSyncStore, generation: UInt64) {
        self.store = store
        self.generation = generation
    }

    func localIndex(
        folderID: String,
        relativePath: String
    ) async throws -> SyncthingFileIndex? {
        guard let store else { throw MobilityPhoneSyncthingDeltaError.storeReleased }
        return try await store.syncthingLocalIndex(
            folderID: folderID,
            relativePath: relativePath,
            generation: generation
        )
    }

    func reusableBlockData(
        folderID: String,
        remoteIndex: SyncthingFileIndex
    ) async throws -> [Data] {
        guard let store else { throw MobilityPhoneSyncthingDeltaError.storeReleased }
        return try await store.syncthingReusableBlockData(
            folderID: folderID,
            remoteIndex: remoteIndex,
            generation: generation
        )
    }

    func readBlock(
        folderID: String,
        index: SyncthingFileIndex,
        block: SyncthingBlockRequest
    ) async throws -> Data {
        guard let store else { throw MobilityPhoneSyncthingDeltaError.storeReleased }
        return try await store.syncthingReadBlock(
            folderID: folderID,
            index: index,
            block: block,
            generation: generation
        )
    }

    func commit(
        _ commit: SyncthingPeerDeltaCommit,
        folderID: String
    ) async throws {
        guard let store else { throw MobilityPhoneSyncthingDeltaError.storeReleased }
        try await store.syncthingCommit(
            commit,
            folderID: folderID,
            generation: generation
        )
    }

    func outgoingTransferDidFinish(
        folderID: String,
        index: SyncthingFileIndex,
        acknowledgement: SyncthingPeerAcknowledgement
    ) async throws {
        guard let store else { throw MobilityPhoneSyncthingDeltaError.storeReleased }
        try await store.syncthingOutgoingTransferDidFinish(
            folderID: folderID,
            index: index,
            acknowledgement: acknowledgement,
            generation: generation
        )
    }
}
