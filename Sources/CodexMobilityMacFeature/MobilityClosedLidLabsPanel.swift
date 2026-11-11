import CodexMobilityCore
import SwiftUI

struct MobilityClosedLidLabsPanel: View {
    @ObservedObject private var mobilityStore: MacMobilityStore
    @ObservedObject private var moduleStore: MobilityModuleConfigurationStore
    @ObservedObject private var powerPolicyStore: MacSystemPowerPolicyStore
    private let descriptor: MobilityModuleDescriptor

    init(
        mobilityStore: MacMobilityStore,
        moduleStore: MobilityModuleConfigurationStore,
        powerPolicyStore: MacSystemPowerPolicyStore,
        descriptor: MobilityModuleDescriptor
    ) {
        self.mobilityStore = mobilityStore
        self.moduleStore = moduleStore
        self.powerPolicyStore = powerPolicyStore
        self.descriptor = descriptor
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                MobilityPanelCard(title: "续跑能力", symbol: "bolt.shield") {
                    MobilityPowerPolicyRows(
                        controls: [.closedLidContinuity],
                        store: powerPolicyStore,
                        closedLidEnableAllowed: moduleStore.mobilityClosedLidEnableAllowed,
                        closedLidEnableBlockedReason: moduleStore.mobilityClosedLidEnableBlockedReason
                    )
                    Divider()
                    MobilityIdleGuardControlRow(
                        store: mobilityStore,
                        enableAllowed: moduleStore.mobilityIdleGuardEnableAllowed,
                        enableBlockedReason: moduleStore.mobilityIdleGuardEnableBlockedReason
                    )
                }

                MobilityPanelCard(title: "合盖行为", symbol: "macbook") {
                    MobilityPowerPolicyRows(
                        controls: [
                            .displaySleepOnLidClose,
                            .requirePasswordAfterDisplaySleep,
                            .keepExternalDisplayActive
                        ],
                        store: powerPolicyStore
                    )
                }

                if let errorMessage = powerPolicyStore.lastErrorMessage {
                    MobilityPanelCard(title: "操作未完成", symbol: "exclamationmark.triangle.fill") {
                        Text(errorMessage)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                MobilityPanelCard(title: "使用边界", symbol: "exclamationmark.shield") {
                    Text("公开 Idle Guard 不能取消 MacBook 合盖睡眠；页面中显示的系统级能力来自经过管理员授权的系统策略或已存在的外部策略。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(
                        "系统级 SleepDisabled 会跨 App 退出、崩溃与重启持续生效；低电量、温度、断网和超时保护只会释放 Idle Guard，不会自动关闭它。使用后请在这台 Mac 上通过本 App 的“设置 > 电源”手动关闭。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    Label(
                        "iPhone、蓝牙及其他远程端仅可查看状态；系统策略只能在这台 Mac 本地切换，管理员密码由 macOS 处理且不会保存在 App 中。",
                        systemImage: "macbook.and.iphone"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Label("合盖续跑会增加耗电与发热，请保持通风，不要把运行中的 Mac 放进封闭包内。", systemImage: "thermometer.medium")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
        }
        .navigationTitle(descriptor.title)
        .task {
            await powerPolicyStore.refreshNow()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: descriptor.symbolName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(systemContinuityState.mobilityTint)
                .frame(width: 58, height: 58)
                .background(
                    systemContinuityState.mobilityTint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(descriptor.title)
                        .font(.title2.weight(.bold))
                    Text("系统策略")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.1), in: Capsule())
                }
                Text("分别控制系统级合盖续跑、Idle Guard、合盖熄屏、唤醒密码与外接显示器保护。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            Label(
                systemContinuityState.displayName,
                systemImage: systemContinuityState.mobilitySymbolName
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(systemContinuityState.mobilityTint)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(systemContinuityState.mobilityTint.opacity(0.1), in: Capsule())
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var systemContinuityState: MacPolicyControlState {
        powerPolicyStore.snapshot.state(for: .closedLidContinuity)
    }
}
