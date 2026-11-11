import CodexMobilityCore
import Foundation

public enum MobilityPhoneSyncTransferStatus: String, Codable, Equatable, Hashable, Sendable {
    case queued
    case waitingForConnection
    case negotiating
    case transferring
    case verifying
    case failed

    public var isActive: Bool {
        switch self {
        case .queued, .waitingForConnection, .negotiating, .transferring, .verifying:
            true
        case .failed:
            false
        }
    }
}

public struct MobilityPhoneSyncTransfer: Codable, Equatable, Identifiable, Sendable {
    public var metadata: SyncItemMetadata
    public var status: MobilityPhoneSyncTransferStatus
    public var confirmedBytes: UInt64
    public var negotiatedChunkSize: Int
    public var errorMessage: String?
    public var updatedAt: Date

    public var id: UUID { metadata.transferID }
    public var fileName: String { SyncRelativePath.fileName(in: metadata.relativePath) }
    public var progress: Double {
        guard metadata.byteSize > 0 else {
            return status == .verifying ? 1 : 0
        }
        return min(max(Double(confirmedBytes) / Double(metadata.byteSize), 0), 1)
    }

    public init(
        metadata: SyncItemMetadata,
        status: MobilityPhoneSyncTransferStatus = .queued,
        confirmedBytes: UInt64 = 0,
        negotiatedChunkSize: Int = 16 * 1_024,
        errorMessage: String? = nil,
        updatedAt: Date = .now
    ) {
        self.metadata = metadata
        self.status = status
        self.confirmedBytes = min(confirmedBytes, metadata.byteSize)
        self.negotiatedChunkSize = min(
            max(negotiatedChunkSize, SyncProtocolLimits.minimumChunkSize),
            SyncProtocolLimits.maximumChunkSize
        )
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

public enum MobilityPhoneSyncResultStatus: String, Codable, Equatable, Hashable, Sendable {
    case completed
    case completedWithWarning
    case cancelled
    case failed
}

public struct MobilityPhoneSyncResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var direction: SyncDirection
    public var fileName: String
    public var byteSize: UInt64
    public var status: MobilityPhoneSyncResultStatus
    public var detail: String
    public var completedAt: Date
    public var localURL: URL?

    public init(
        id: UUID,
        direction: SyncDirection,
        fileName: String,
        byteSize: UInt64,
        status: MobilityPhoneSyncResultStatus,
        detail: String,
        completedAt: Date = .now,
        localURL: URL? = nil
    ) {
        self.id = id
        self.direction = direction
        self.fileName = fileName
        self.byteSize = byteSize
        self.status = status
        self.detail = detail
        self.completedAt = completedAt
        self.localURL = localURL
    }
}

public enum MobilityPhoneSyncError: LocalizedError, Equatable, Sendable {
    case fileTooLarge(name: String, size: UInt64, maximum: UInt64)
    case invalidDirection
    case unknownTransfer(UUID)
    case invalidOffset(expected: UInt64, actual: UInt64)
    case checksumMismatch(name: String)
    case fileUnavailable(name: String)
    case photoLibraryDenied
    case photoImportFailed(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let name, let size, let maximum):
            "“\(name)”大小为 \(Self.byteCount(size))，超过单文件上限 \(Self.byteCount(maximum))。"
        case .invalidDirection:
            "收到方向不正确的同步请求。"
        case .unknownTransfer:
            "收到未知文件的同步数据，请重新连接后重试。"
        case .invalidOffset(let expected, let actual):
            "同步断点不一致：应从 \(expected) 字节继续，实际为 \(actual) 字节。"
        case .checksumMismatch(let name):
            "“\(name)”校验失败，文件未写入收件箱。"
        case .fileUnavailable(let name):
            "找不到待发送文件“\(name)”，请重新选择。"
        case .photoLibraryDenied:
            "没有“添加到照片”权限；文件已保留在“文件”App 的 Codex Sync Inbox。"
        case .photoImportFailed(let reason):
            "无法添加到照片：\(reason)；文件仍保留在“文件”App。"
        case .storage(let reason):
            "同步存储失败：\(reason)"
        }
    }

    private static func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
