import Foundation

public enum MacFileSyncDirection: String, Codable, Equatable, Hashable, Sendable {
    case toPhone
    case toMac
}

public enum MacFileSyncTransferPhase: String, Codable, Equatable, Hashable, Sendable {
    case queued
    case transferring
    case completed
    case failed
}

public struct MacSyncFileDescriptor: Codable, Equatable, Hashable, Sendable {
    public var transferID: UUID
    public var relativePath: String
    public var byteCount: UInt64
    public var modifiedAt: Date
    public var sha256: String

    public init(
        transferID: UUID = UUID(),
        relativePath: String,
        byteCount: UInt64,
        modifiedAt: Date,
        sha256: String
    ) {
        self.transferID = transferID
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.sha256 = sha256.lowercased()
    }
}

public struct MacSyncDiscoveredFile: Equatable, Sendable {
    public var relativePath: String
    public var fileURL: URL
    public var byteCount: UInt64
    public var modifiedAt: Date
    public var sha256: String

    public init(
        relativePath: String,
        fileURL: URL,
        byteCount: UInt64,
        modifiedAt: Date,
        sha256: String
    ) {
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.sha256 = sha256.lowercased()
    }
}

public struct MacSyncQueueItem: Identifiable, Equatable, Sendable {
    public var id: UUID { transferID }
    public var transferID: UUID
    public var relativePath: String
    public var direction: MacFileSyncDirection
    public var byteCount: UInt64
    public var transferredByteCount: UInt64
    public var phase: MacFileSyncTransferPhase
    public var detail: String?
    public var updatedAt: Date

    public init(
        transferID: UUID,
        relativePath: String,
        direction: MacFileSyncDirection,
        byteCount: UInt64,
        transferredByteCount: UInt64 = 0,
        phase: MacFileSyncTransferPhase = .queued,
        detail: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.transferID = transferID
        self.relativePath = relativePath
        self.direction = direction
        self.byteCount = byteCount
        self.transferredByteCount = min(transferredByteCount, byteCount)
        self.phase = phase
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

public struct MacSyncCompletedTransfer: Equatable, Sendable {
    public var transferID: UUID
    public var relativePath: String
    public var fileURL: URL
    public var byteCount: UInt64
    public var sha256: String
    public var completedAt: Date
    public var reusedExistingFile: Bool

    public init(
        transferID: UUID,
        relativePath: String,
        fileURL: URL,
        byteCount: UInt64,
        sha256: String,
        completedAt: Date = Date(),
        reusedExistingFile: Bool = false
    ) {
        self.transferID = transferID
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
        self.completedAt = completedAt
        self.reusedExistingFile = reusedExistingFile
    }
}

public struct MacSyncRecentResult: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var relativePath: String
    public var direction: MacFileSyncDirection
    public var succeeded: Bool
    public var detail: String
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        relativePath: String,
        direction: MacFileSyncDirection,
        succeeded: Bool,
        detail: String,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.relativePath = relativePath
        self.direction = direction
        self.succeeded = succeeded
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

public enum MacFileSyncError: Error, Equatable, Sendable {
    case syncDisabled
    case directoryUnavailable
    case unsafeRelativePath(String)
    case unsupportedTemporaryFile(String)
    case invalidDigest
    case invalidDirection
    case fileTooLarge(maximumBytes: UInt64)
    case insufficientStorage
    case transferNotFound(UUID)
    case unexpectedOffset(expected: UInt64, received: UInt64)
    case chunkExceedsDeclaredSize
    case incompleteTransfer(expected: UInt64, actual: UInt64)
    case checksumMismatch(expected: String, actual: String)
    case sourceChanged(String)
    case sourceReadFailed(String)
    case destinationWriteFailed(String)
}

extension MacFileSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .syncDisabled:
            "文件同步尚未开启。"
        case .directoryUnavailable:
            "同步目录当前不可用，请重新选择。"
        case .unsafeRelativePath(let path):
            "文件路径不安全：\(path)"
        case .unsupportedTemporaryFile(let path):
            "已忽略临时或隐藏文件：\(path)"
        case .invalidDigest:
            "文件摘要格式无效。"
        case .invalidDirection:
            "文件传输方向与 Mac 端操作不匹配。"
        case .fileTooLarge(let maximumBytes):
            "文件超过当前单文件上限（\(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file))）。"
        case .insufficientStorage:
            "Mac 可用存储空间不足。"
        case .transferNotFound:
            "没有找到对应的文件传输。"
        case .unexpectedOffset(let expected, let received):
            "文件分片位置不连续（期望 \(expected)，收到 \(received)）。"
        case .chunkExceedsDeclaredSize:
            "文件分片超过声明的文件大小。"
        case .incompleteTransfer(let expected, let actual):
            "文件尚未接收完整（期望 \(expected)，当前 \(actual)）。"
        case .checksumMismatch:
            "文件 SHA-256 校验失败，未写入同步目录。"
        case .sourceChanged(let path):
            "发送期间源文件发生变化：\(path)"
        case .sourceReadFailed(let detail):
            "读取待发送文件失败：\(detail)"
        case .destinationWriteFailed(let detail):
            "写入同步目录失败：\(detail)"
        }
    }
}
