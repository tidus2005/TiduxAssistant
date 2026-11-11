import CodexMobilityCore

extension MacMobilityStore: MobilityMacCommandHandling {
    public func handleMobilityAction(_ action: Action) async throws -> MobilityMacCommandOutcome {
        switch action {
        case .requestStatus:
            refreshNow()
            return MobilityMacCommandOutcome(
                accepted: true,
                message: "状态已刷新。",
                status: status
            )

        case .setMode(let enabled, let profile):
            setMode(enabled: enabled, profile: profile)
            let accepted = enabled
                ? status.mode.phase == .active || status.mode.phase == .degraded
                : status.mode.phase == .off
            return MobilityMacCommandOutcome(
                accepted: accepted,
                message: accepted
                    ? (enabled ? "移动续跑已开启。" : "移动续跑已停止。")
                    : (status.mode.detail ?? "Mac 未能完成模式切换。"),
                status: status
            )

        case .updatePolicy(let policy):
            updatePolicy(policy)
            return MobilityMacCommandOutcome(
                accepted: true,
                message: "安全策略已更新。",
                status: status
            )

        case .fileSync, .collaboration:
            return MobilityMacCommandOutcome(
                accepted: false,
                message: "文件同步消息应由同步控制器处理。",
                status: nil
            )
        }
    }
}
