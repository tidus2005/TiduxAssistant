import Foundation

enum DictationPhase: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case processing
    case inserting
    case completed
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "准备就绪"
        case .preparing:
            return "正在准备"
        case .recording:
            return "正在聆听"
        case .processing:
            return "正在整理"
        case .inserting:
            return "正在写入"
        case .completed:
            return "已完成"
        case .failed:
            return "需要处理"
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .recording, .processing, .inserting:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }
}
