import CodexMobilityCore
import SwiftUI

struct MobilityTravelRuntimePanel: View {
    @ObservedObject private var store: MacMobilityStore
    @ObservedObject private var powerPolicyStore: MacSystemPowerPolicyStore
    private let descriptor: MobilityModuleDescriptor
    private let isSelected: Bool
    private let isEnabled: Bool
    private let experimentsEnabled: Bool

    init(
        store: MacMobilityStore,
        powerPolicyStore: MacSystemPowerPolicyStore,
        descriptor: MobilityModuleDescriptor,
        isSelected: Bool,
        isEnabled: Bool,
        experimentsEnabled: Bool
    ) {
        self.store = store
        self.powerPolicyStore = powerPolicyStore
        self.descriptor = descriptor
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.experimentsEnabled = experimentsEnabled
    }

    var body: some View {
        MobilityModulePanelScaffold(
            descriptor: descriptor,
            isSelected: isSelected,
            isEnabled: isEnabled,
            experimentsEnabled: experimentsEnabled,
            statusText: store.mode.phase.mobilityDisplayName,
            statusSymbol: store.mode.phase.mobilitySymbolName,
            statusTint: modeTint
        ) {
            modeControl
            policyGrid
            safetyCard
        }
    }

    private var modeControl: some View {
        MobilityPanelCard {
            HStack(spacing: 18) {
                Image(systemName: store.mode.phase.mobilitySymbolName)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(modeTint)
                    .frame(width: 68, height: 68)
                    .background(modeTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 5) {
                    Text("移动续跑 · \(store.mode.phase.mobilityDisplayName)")
                        .font(.title3.weight(.semibold))
                    Text(store.mode.detail ?? "保持 Codex 与必要网络活动，屏幕仍可自动熄灭。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                Button(store.mode.isEnabled ? "停止续跑" : "开始续跑") {
                    store.setMode(enabled: !store.mode.isEnabled, profile: .idleGuard)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(store.mode.isEnabled ? .red : .accentColor)
                .disabled(!isEnabled || store.mode.phase == .preflighting || store.mode.phase == .stopping)
                .accessibilityHint("普通模式只能防止空闲睡眠，不能阻止合盖睡眠")
            }

            let evaluation = MobilitySafetyEvaluation.evaluate(
                status: store.status,
                profile: .idleGuard,
                policy: store.policy
            )
            if !store.mode.isEnabled, !evaluation.isAllowed {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前启动条件未满足")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(evaluation.blockers, id: \.self) { blocker in
                        Label(safetyBlockerText(blocker), systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var policyGrid: some View {
        MobilityPanelCard(title: "自动停止策略", symbol: "shield.checkered") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                policyItem("截止电量", "\(store.policy.lowBatteryThresholdPercent)%", "battery.25percent")
                policyItem("最长运行", durationText, "timer")
                policyItem("断网宽限", graceText, "wifi.exclamationmark")
                policyItem(
                    "Codex 退出",
                    store.policy.requiresCodexRunning ? "自动停止" : "继续运行",
                    "sparkles"
                )
            }
            HStack {
                Text("电量、温度、断网和时限由 Mac 本地执行，不依赖手机保持连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Label("调整策略", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private var safetyCard: some View {
        MobilityPanelCard(title: "安全边界", symbol: "exclamationmark.shield") {
            Label(
                closedLidSafetyTitle,
                systemImage: closedLidSafetySymbol
            )
            .foregroundStyle(closedLidSafetyTint)
            Text(closedLidSafetyDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if closedLidState.isEnabled {
                Label(
                    "SleepDisabled 会跨 App 退出、崩溃和重启持续生效。低电量、温度、断网或超时自动停止只释放 Idle Guard，不会关闭该全局策略。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Idle Guard 与系统级合盖续跑是两个独立开关；后者只能在这台 Mac 上通过本 App 的“设置 > 电源”手动开关，iPhone 和远程端只读。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                SettingsLink {
                    Label("电源设置", systemImage: "power")
                }
            }
        }
    }

    private var closedLidState: MacPolicyControlState {
        powerPolicyStore.snapshot.state(for: .closedLidContinuity)
    }

    private var closedLidSafetyTitle: String {
        switch closedLidState {
        case .appManaged:
            "系统级合盖续跑已由本 App 管理"
        case .externallyEnabled:
            "系统级合盖续跑已由外部策略启用"
        case .disabled:
            "当前只有 Idle Guard；它不能单独阻止合盖睡眠"
        case .unsupported:
            "本机不支持系统级合盖续跑控制"
        case .unknown:
            "暂时无法确认系统级合盖续跑状态"
        }
    }

    private var closedLidSafetyDetail: String {
        switch closedLidState {
        case .appManaged:
            "公开 Idle Guard 负责防空闲睡眠；另一个系统级策略负责合盖后的后台运行。仍请把 Mac 放在稳定、通风的位置。"
        case .externallyEnabled:
            "当前合盖续跑来自已有系统配置，并不是公开 Idle Guard API 提供的能力。可在“电源”设置中查看来源或明确关闭。"
        case .disabled:
            "请保持屏幕盖打开或留缝。若要启用系统级策略，请前往“电源”设置并完成管理员验证。"
        case .unsupported(let reason), .unknown(let reason):
            reason
        }
    }

    private var closedLidSafetySymbol: String {
        switch closedLidState {
        case .appManaged: "checkmark.shield.fill"
        case .externallyEnabled: "arrow.triangle.branch"
        case .disabled: "exclamationmark.triangle.fill"
        case .unsupported: "nosign"
        case .unknown: "questionmark.diamond.fill"
        }
    }

    private var closedLidSafetyTint: Color {
        closedLidState.mobilityTint
    }

    private func policyItem(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var durationText: String {
        let minutes = Int(store.policy.maximumDurationSeconds / 60)
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
    }

    private var graceText: String {
        let minutes = Int(store.policy.networkDisconnectGraceSeconds / 60)
        return minutes == 0 ? "立即停止" : "\(minutes) 分钟"
    }

    private var modeTint: Color {
        switch store.mode.phase {
        case .active: .green
        case .degraded, .preflighting, .armed, .recovering: .orange
        case .blocked, .faulted: .red
        case .off, .stopping: .secondary
        }
    }

    private func safetyBlockerText(_ blocker: MobilitySafetyBlocker) -> String {
        switch blocker {
        case .batteryUnavailable: "无法读取 Mac 电量"
        case .insufficientBatteryReserve: "电量没有高于截止值至少 10%"
        case .networkUnavailable: "当前网络不可用"
        case .codexNotRunning: "没有检测到 Codex"
        case .thermalSerious: "系统热状态严重"
        case .thermalCritical: "系统热状态临界"
        case .thermalUnknown: "无法确认系统热状态"
        case .helperUnavailable: "所需 Helper 尚未就绪"
        }
    }
}
