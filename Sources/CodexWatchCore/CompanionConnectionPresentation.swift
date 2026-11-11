import Foundation

/// A received phone context is not proof that the Mac is reachable.
public struct CompanionConnectionPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case offline, stale, connected }
    public let phase: Phase
    public let title: String
    public let detail: String
    public let symbol: String

    public init(bridgeOnline: Bool, savedAt: Date?, now: Date = Date()) {
        if !bridgeOnline {
            phase = .offline
            title = "等待连接 Mac"
            detail = "在 iPhone 的“设备”页连接你的 Mac。"
            symbol = "laptopcomputer.trianglebadge.exclamationmark"
        } else if savedAt.map({ now.timeIntervalSince($0) > 90 }) ?? true {
            phase = .stale
            title = "状态需要刷新"
            detail = "显示上次记录，刷新后确认任务状态。"
            symbol = "clock.arrow.circlepath"
        } else {
            phase = .connected
            title = "Mac 已连接"
            detail = "任务与回复已同步。"
            symbol = "checkmark.circle.fill"
        }
    }

    public var canSend: Bool { phase == .connected }
}
