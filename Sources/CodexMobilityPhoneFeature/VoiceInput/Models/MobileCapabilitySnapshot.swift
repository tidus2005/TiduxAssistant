#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation

enum MobileMicrophonePermission: String, Codable, Sendable {
    case undetermined
    case granted
    case denied
    case unknown

    var title: String {
        switch self {
        case .undetermined:
            "尚未请求"
        case .granted:
            "已允许"
        case .denied:
            "已拒绝"
        case .unknown:
            "未知"
        }
    }
}

enum MobileSpeechBackend: String, Codable, Sendable {
    case speechTranscriber
    case dictationTranscriber

    var title: String {
        switch self {
        case .speechTranscriber:
            "SpeechTranscriber"
        case .dictationTranscriber:
            "DictationTranscriber"
        }
    }
}

enum MobileSpeechAssetState: String, Codable, Sendable {
    case unknown
    case unsupported
    case supported
    case downloading
    case installed
    case failed

    var title: String {
        switch self {
        case .unknown:
            "尚未检查"
        case .unsupported:
            "不支持"
        case .supported:
            "可以安装"
        case .downloading:
            "下载中"
        case .installed:
            "已安装"
        case .failed:
            "检查失败"
        }
    }
}

struct MobileSpeechCapabilitySnapshot: Equatable, Sendable {
    var microphonePermission: MobileMicrophonePermission = .undetermined
    var speechTranscriberAvailable = false
    var requestedLocaleIdentifier = "zh-CN"
    var resolvedLocaleIdentifier: String?
    var backend: MobileSpeechBackend?
    var assetState: MobileSpeechAssetState = .unknown
    var localeReserved = false
    var maximumReservedLocales = 0
    var errorMessage: String?

    var isReady: Bool {
        microphonePermission == .granted &&
            resolvedLocaleIdentifier != nil &&
            assetState == .installed &&
            localeReserved &&
            errorMessage == nil
    }
}
#endif
