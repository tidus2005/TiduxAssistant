import Foundation

extension SyncProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .itemTooLarge:
            "文件超过当前同步的单文件上限。"
        case .invalidSHA256:
            "文件摘要格式无效。"
        case .wrongTransfer:
            "文件分片属于另一项传输。"
        case .invalidResumeOffset(let offset):
            "断点位置无效（\(offset) 字节）。"
        case .invalidChunkSize(let size):
            "文件分片大小无效（\(size) 字节）。"
        case .unexpectedOffset(let expected, let actual):
            "文件分片位置不连续（应为 \(expected)，收到 \(actual)）。"
        case .chunkExceedsItemSize:
            "文件分片超过发送方声明的文件大小。"
        case .invalidFinalChunk:
            "文件末尾标记与实际大小不一致。"
        case .checksumMismatch:
            "文件校验失败，未写入最终位置。"
        case .incompleteTransfer(let expected, let actual):
            "文件尚未完整接收（应为 \(expected)，当前 \(actual) 字节）。"
        case .invalidCompletionStage:
            "文件完成确认顺序不正确。"
        case .acknowledgementOutOfRange(let offset):
            "对端确认了无效的文件位置（\(offset) 字节）。"
        case .frameSizeTooSmall(let size):
            "蓝牙可用分片过小（\(size) 字节）。"
        case .windowFull:
            "蓝牙发送窗口正忙，请等待确认。"
        case .invalidState:
            "文件传输当前状态不允许此操作。"
        }
    }
}
