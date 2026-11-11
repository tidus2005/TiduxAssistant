import CodexWatchCore
import Foundation

#if os(watchOS)
import WatchKit
#endif

public protocol WatchHapticPlaying: Sendable {
    func play(_ haptic: AttentionHapticKind)
}

public struct WatchHapticPlayer: WatchHapticPlaying {
    public init() {}

    public func play(_ haptic: AttentionHapticKind) {
        #if os(watchOS)
        let type: WKHapticType = switch haptic {
        case .notification: .notification
        case .success: .success
        case .failure: .failure
        }
        WKInterfaceDevice.current().play(type)
        #endif
    }
}
