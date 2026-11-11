import AppKit
import CodexMobilityCore
import SwiftUI

struct MobilityPowerAndLidSettingsView: View {
    @ObservedObject private var mobilityStore: MacMobilityStore
    @ObservedObject private var moduleStore: MobilityModuleConfigurationStore
    @ObservedObject private var powerPolicyStore: MacSystemPowerPolicyStore
    @ObservedObject private var lidCloseLockController: MacLidCloseLockController
    @StateObject private var screenLockSettings: MobilityScreenLockSettingsModel

    init(
        mobilityStore: MacMobilityStore,
        moduleStore: MobilityModuleConfigurationStore,
        powerPolicyStore: MacSystemPowerPolicyStore,
        lidCloseLockController: MacLidCloseLockController
    ) {
        self.mobilityStore = mobilityStore
        self.moduleStore = moduleStore
        self.powerPolicyStore = powerPolicyStore
        self.lidCloseLockController = lidCloseLockController
        _screenLockSettings = StateObject(
            wrappedValue: MobilityScreenLockSettingsModel()
        )
    }

    var body: some View {
        Form {
            Section("续跑能力") {
                MobilityPowerPolicyRows(
                    controls: [.closedLidContinuity],
                    store: powerPolicyStore,
                    closedLidEnableAllowed: moduleStore.mobilityClosedLidEnableAllowed,
                    closedLidEnableBlockedReason: moduleStore.mobilityClosedLidEnableBlockedReason
                )
                MobilityIdleGuardControlRow(
                    store: mobilityStore,
                    enableAllowed: moduleStore.mobilityIdleGuardEnableAllowed,
                    enableBlockedReason: moduleStore.mobilityIdleGuardEnableBlockedReason
                )
            }

            Section("AI 桌面操作") {
                MobilityAgentDesktopSettingsView(controller: lidCloseLockController.agentDesktopController)
            }

            Section("自动关闭显示器与密码") {
                Picker("使用电池时关闭屏幕", selection: $screenLockSettings.batteryMinutes) {
                    MobilityScreenLockSettingsModel.displaySleepOptions
                }
                Picker("接入电源时关闭屏幕", selection: $screenLockSettings.powerMinutes) {
                    MobilityScreenLockSettingsModel.displaySleepOptions
                }
                LabeledContent("关闭屏幕后需要密码") {
                    Text(screenLockSettings.passwordDescription)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("打开“锁定屏幕”系统设置…") {
                    screenLockSettings.openLockScreenSystemSettings()
                }
                HStack {
                    Text(screenLockSettings.status)
                        .font(.caption)
                        .foregroundStyle(screenLockSettings.lastSaveSucceeded == false ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if screenLockSettings.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") {
                            Task { await screenLockSettings.save() }
                        }
                    }
                }
                Text("电池与接电的显示器关闭时间可由本 App 保存；锁屏密码策略只读，必须在这台 Mac 的“系统设置 → 锁定屏幕”中修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("合盖行为") {
                MobilityPowerPolicyRows(
                    controls: [
                        .displaySleepOnLidClose,
                        .requirePasswordAfterDisplaySleep,
                        .keepExternalDisplayActive
                    ],
                    store: powerPolicyStore
                )
                Picker(
                    "合盖后锁定屏幕",
                    selection: Binding(
                        get: { lidCloseLockController.delaySeconds ?? -1 },
                        set: { value in
                            try? lidCloseLockController.updateDelaySeconds(
                                value < 0 ? nil : value
                            )
                        }
                    )
                ) {
                    Text("不由助手锁屏（系统策略仍生效）").tag(-1)
                    Text("立即").tag(0)
                    Text("15 秒后").tag(15)
                    Text("30 秒后").tag(30)
                    Text("1 分钟后").tag(60)
                    Text("5 分钟后").tag(300)
                    Text("15 分钟后").tag(900)
                }
                Text(lidCloseLockController.snapshot().status)
                    .font(.caption)
                    .foregroundStyle(
                        lidCloseLockController.lastErrorMessage == nil
                            ? Color.secondary
                            : Color.orange
                    )
                    .fixedSize(horizontal: false, vertical: true)
                Text("合盖会先立即关闭显示器；延迟到期前开盖会取消本次锁屏。若系统的“屏幕唤醒后要求密码”更早，实际会按较早时间要求密码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = powerPolicyStore.lastErrorMessage {
                Section("操作未完成") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else if let actionMessage = powerPolicyStore.lastActionMessage {
                Section("最近操作") {
                    Label(actionMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("状态说明") {
                Text("“App 管理”表示这项设置由 Tidux助手最近一次成功切换；“外部策略”表示系统已生效，但最初由其他工具或管理员配置。首次使用需要管理员验证来安装受限系统助手，后续切换不再重复询问密码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(
                    "SleepDisabled 是 Mac 全局策略；开启后会跨 App 退出、崩溃与重启持续生效，必须在这台 Mac 上通过本 App 的“设置 > 电源”手动关闭。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                Text("低电量、温度、断网、超时或 Codex 退出触发的自动停止，只会释放 App 的 Idle Guard，不会自动关闭系统级 SleepDisabled。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("首次安装系统助手必须在这台 Mac 上完成；管理员密码只由 macOS 系统对话框处理，App 不会保存。安装后，本机和受保护的手机 Web 控制台都复用该助手的固定命令白名单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("合盖续跑会增加耗电与发热。不要把正在运行的 Mac 放入不通风的包内；关闭外部策略前请确认没有其他程序依赖它。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await powerPolicyStore.refreshNow()
            await screenLockSettings.refresh()
        }
    }
}

@MainActor
private final class MobilityScreenLockSettingsModel: ObservableObject {
    static let displaySleepValues = [0, 1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 150, 180]

    @Published var batteryMinutes = 10
    @Published var powerMinutes = 10
    @Published var passwordDelaySeconds = 0
    @Published var passwordDescription = "正在读取"
    @Published var status = "正在读取 macOS 实际配置"
    @Published var isBusy = false
    @Published var lastSaveSucceeded: Bool?

    private let service = MacRemoteDashboardScreenLockService()

    @ViewBuilder
    static var displaySleepOptions: some View {
        ForEach(displaySleepValues, id: \.self) { minutes in
            Text(minutes == 0 ? "永不" : Self.minutesDescription(minutes))
                .tag(minutes)
        }
    }

    func refresh() async {
        let snapshot = await service.load()
        apply(snapshot)
    }

    func save() async {
        guard !isBusy else { return }
        isBusy = true
        lastSaveSucceeded = nil
        status = "正在写入并回读 macOS 实际配置…"
        let response = await service.apply(
            MacRemoteDashboardScreenLockUpdateRequest(
                batteryDisplaySleepMinutes: batteryMinutes,
                powerAdapterDisplaySleepMinutes: powerMinutes,
                passwordDelaySeconds: passwordDelaySeconds < 0 ? nil : passwordDelaySeconds
            )
        )
        apply(response.settings)
        lastSaveSucceeded = response.ok
        status = response.ok ? response.message : "保存失败：\(response.message)"
        isBusy = false
    }

    func openLockScreenSystemSettings() {
        guard let lockScreenURL = URL(
            string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
        ) else { return }
        if !NSWorkspace.shared.open(lockScreenURL) {
            _ = NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/System Settings.app")
            )
        }
    }

    private func apply(_ snapshot: MacRemoteDashboardScreenLockSnapshot) {
        if let value = snapshot.batteryDisplaySleepMinutes { batteryMinutes = value }
        if let value = snapshot.powerAdapterDisplaySleepMinutes { powerMinutes = value }
        passwordDelaySeconds = snapshot.requiresPassword == false
            ? -1
            : snapshot.passwordDelaySeconds ?? 0
        passwordDescription = Self.passwordDescription(
            requiresPassword: snapshot.requiresPassword,
            delaySeconds: snapshot.passwordDelaySeconds
        )
        status = snapshot.status
    }

    private static func passwordDescription(
        requiresPassword: Bool?,
        delaySeconds: Int?
    ) -> String {
        guard let requiresPassword else { return "无法读取" }
        guard requiresPassword else { return "当前不需要密码" }
        return switch delaySeconds {
        case 0: "立即"
        case 5: "5 秒后"
        case 60: "1 分钟后"
        case 300: "5 分钟后"
        case 900: "15 分钟后"
        case 3_600: "1 小时后"
        case 14_400: "4 小时后"
        case 28_800: "8 小时后"
        case .some(let seconds): "\(seconds) 秒后"
        case nil: "等待时间未知"
        }
    }

    private static func minutesDescription(_ minutes: Int) -> String {
        switch minutes {
        case 60: "1 小时"
        case 90: "1.5 小时"
        case 120: "2 小时"
        case 150: "2.5 小时"
        case 180: "3 小时"
        default: "\(minutes) 分钟"
        }
    }
}

struct MobilityPowerPolicyRows: View {
    let controls: [MacSystemPolicyControl]
    @ObservedObject var store: MacSystemPowerPolicyStore
    var closedLidEnableAllowed = false
    var closedLidEnableBlockedReason: String?

    @State private var pendingConfirmation: MobilityPowerPolicyConfirmation?

    var body: some View {
        ForEach(controls, id: \.self) { control in
            MobilityPowerPolicyControlRow(
                control: control,
                state: store.snapshot.state(for: control),
                isBusy: store.isBusy,
                allowsEnabling: control != .closedLidContinuity || closedLidEnableAllowed,
                enableBlockedReason: control == .closedLidContinuity
                    ? closedLidEnableBlockedReason
                    : nil,
                onChange: { enabled in
                    requestChange(control, enabled: enabled)
                }
            )
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "确认修改系统策略",
            isPresented: confirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button(
                pendingConfirmation?.actionTitle ?? "确认关闭",
                role: pendingConfirmation?.actionRole
            ) {
                guard let confirmation = pendingConfirmation else { return }
                pendingConfirmation = nil
                apply(confirmation.control, enabled: confirmation.targetEnabled)
            }
            Button("取消", role: .cancel) {
                pendingConfirmation = nil
            }
        } message: {
            Text(pendingConfirmation?.message ?? "")
        }
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { isPresented in
                if !isPresented { pendingConfirmation = nil }
            }
        )
    }

    private func requestChange(_ control: MacSystemPolicyControl, enabled: Bool) {
        guard control != .closedLidContinuity || !enabled || closedLidEnableAllowed else {
            return
        }
        let state = store.snapshot.state(for: control)
        if let confirmation = MobilityPowerPolicyConfirmation(
            control: control,
            currentState: state,
            targetEnabled: enabled
        ) {
            pendingConfirmation = confirmation
            return
        }
        apply(control, enabled: enabled)
    }

    private func apply(_ control: MacSystemPolicyControl, enabled: Bool) {
        Task {
            if control == .closedLidContinuity {
                await store.setClosedLidContinuityEnabled(enabled)
            } else {
                await store.setLegacyControl(control, enabled: enabled)
            }
        }
    }
}

struct MobilityPowerPolicyControlRow: View {
    let control: MacSystemPolicyControl
    let state: MacPolicyControlState
    let isBusy: Bool
    let allowsEnabling: Bool
    let enableBlockedReason: String?
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: control.mobilitySymbolName)
                .foregroundStyle(state.mobilityTint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(control.mobilityTitle)
                    Label(state.displayName, systemImage: state.mobilitySymbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(state.mobilityTint)
                        .labelStyle(.titleAndIcon)
                }
                Text(control.mobilityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = state.mobilityReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !state.isEnabled,
                          !allowsEnabling,
                          let enableBlockedReason {
                    Text(enableBlockedReason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34)
            } else if state.mobilityCanChange && (state.isEnabled || allowsEnabling) {
                Toggle(
                    control.mobilityTitle,
                    isOn: Binding(
                        get: { state.isEnabled },
                        set: { enabled in onChange(enabled) }
                    )
                )
                .labelsHidden()
            } else if state.mobilityCanChange {
                Label("需开启 Labs", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help(enableBlockedReason ?? "请先开启对应的实验模块。")
            } else {
                Label("只读", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("当前状态无法确认，不会把它当作“已关闭”。")
            }
        }
        .padding(.vertical, 3)
    }
}

extension MobilityModuleConfigurationStore {
    var mobilityIdleGuardEnableAllowed: Bool {
        isEnabled(.travelRuntime)
    }

    var mobilityIdleGuardEnableBlockedReason: String? {
        mobilityIdleGuardEnableAllowed
            ? nil
            : "请先在“模块”设置中开启“移动联网运行”。已运行的 Idle Guard 仍可在此关闭。"
    }

    var mobilityClosedLidEnableAllowed: Bool {
        isEnabled(.closedLidLabs)
    }

    var mobilityClosedLidEnableBlockedReason: String? {
        guard !mobilityClosedLidEnableAllowed else { return nil }
        guard configuration.experimentalModulesEnabled else {
            return "请先在“模块”设置中打开“允许实验模块”。已开启的系统策略仍可在此关闭。"
        }
        guard configuration.moduleOverrides[.closedLidLabs] == true else {
            return "请先在“模块”设置中单独开启“合盖续跑实验室”。已开启的系统策略仍可在此关闭。"
        }
        return "当前平台或模块配置不允许开启此实验功能；已开启的系统策略仍可在此关闭。"
    }
}

struct MobilityIdleGuardControlRow: View {
    @ObservedObject var store: MacMobilityStore
    var enableAllowed = true
    var enableBlockedReason: String?

    private var state: MacPolicyControlState {
        if store.isAssertionActive { return .appManaged }
        switch store.mode.phase {
        case .faulted, .blocked:
            return .unknown(store.mode.detail ?? "Idle Guard 未能启动。")
        case .preflighting, .armed, .active, .degraded, .stopping, .recovering:
            return .unknown(store.mode.detail ?? "Idle Guard 状态正在变化。")
        case .off:
            return .disabled
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(state.mobilityTint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("Idle Guard")
                    Label(state.displayName, systemImage: state.mobilitySymbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(state.mobilityTint)
                }
                Text("使用公开 IOKit 接口防止空闲睡眠；它不修改系统全局电源设置，也不能单独阻止合盖睡眠。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = state.mobilityReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if !state.isEnabled, !enableAllowed, let enableBlockedReason {
                    Text(enableBlockedReason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            if store.mode.phase == .preflighting
                || store.mode.phase == .stopping
                || store.mode.phase == .recovering {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34)
            } else if state.mobilityCanChange && (state.isEnabled || enableAllowed) {
                Toggle(
                    "Idle Guard",
                    isOn: Binding(
                        get: { store.mode.isEnabled },
                        set: { enabled in
                            store.setMode(enabled: enabled, profile: .idleGuard)
                        }
                    )
                )
                .labelsHidden()
            } else if state.mobilityCanChange {
                Label("模块已关闭", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help(enableBlockedReason ?? "请先开启移动联网运行模块。")
            } else if store.mode.phase == .blocked || store.mode.phase == .faulted {
                Button("重试") {
                    store.setMode(enabled: true, profile: .idleGuard)
                }
                .disabled(!enableAllowed)
                .help("重新执行安全检查并尝试启动 Idle Guard")
            } else {
                Label("只读", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct MobilityPowerPolicyConfirmation: Equatable {
    let control: MacSystemPolicyControl
    let targetEnabled: Bool
    let title: String
    let message: String
    let actionTitle: String
    let actionRole: ButtonRole?

    init?(
        control: MacSystemPolicyControl,
        currentState: MacPolicyControlState,
        targetEnabled: Bool
    ) {
        if control == .closedLidContinuity, targetEnabled {
            self.control = control
            self.targetEnabled = true
            self.title = "开启系统级合盖续跑？"
            self.message = "SleepDisabled 开启后会在 App 退出、崩溃或自动停止 Idle Guard 后继续生效。请确保 Mac 通风，使用完成后回到这台 Mac，通过本 App 的“设置 > 电源”手动关闭。"
            self.actionTitle = "了解并开启"
            self.actionRole = nil
            return
        }

        guard !targetEnabled else { return nil }

        if control == .requirePasswordAfterDisplaySleep {
            self.control = control
            self.targetEnabled = false
            self.title = "关闭唤醒密码？"
            self.message = currentState == .externallyEnabled
                ? "这项安全设置由外部策略开启。关闭后，屏幕睡眠或熄屏后唤醒将不再要求密码，并会修改现有 Continuity 配置。"
                : "关闭后，屏幕睡眠或熄屏后唤醒将不再要求密码。请确认这符合你的设备安全要求。"
            self.actionTitle = "关闭唤醒密码"
            self.actionRole = .destructive
            return
        }

        if control == .closedLidContinuity, currentState.isEnabled {
            self.control = control
            self.targetEnabled = false
            self.title = currentState == .externallyEnabled
                ? "关闭外部合盖策略？"
                : "关闭系统级合盖续跑？"
            self.message = "关闭后，MacBook 合盖时可能恢复系统睡眠，正在运行的 Codex 任务和网络连接可能暂停。若它由其他工具启用，这也会修改那个工具依赖的全局策略。"
            self.actionTitle = "仍然关闭"
            self.actionRole = .destructive
            return
        }

        guard currentState == .externallyEnabled else { return nil }
        self.control = control
        self.targetEnabled = false
        self.title = "关闭外部策略？"
        self.message = "“\(control.mobilityTitle)”当前由其他工具或管理员配置。继续会修改现有系统策略，可能影响依赖它的其他程序。"
        self.actionTitle = "仍然关闭"
        self.actionRole = .destructive
    }
}

extension MacSystemPolicyControl {
    var mobilityTitle: String {
        switch self {
        case .closedLidContinuity: "系统级合盖续跑"
        case .displaySleepOnLidClose: "合盖且无外接屏时熄屏"
        case .requirePasswordAfterDisplaySleep: "屏幕唤醒后要求密码"
        case .keepExternalDisplayActive: "有外接屏时保持外屏工作"
        }
    }

    var mobilityDescription: String {
        switch self {
        case .closedLidContinuity:
            "首次管理员授权安装受限系统助手，后续免密码控制 SleepDisabled；与 Idle Guard 相互独立。"
        case .displaySleepOnLidClose:
            "确认合盖且没有外接显示器后，仅请求一次关闭显示器。"
        case .requirePasswordAfterDisplaySleep:
            "显示器睡眠或熄屏后，重新唤醒时立即要求输入密码。"
        case .keepExternalDisplayActive:
            "检测到外接显示器时，不执行合盖熄屏动作，保留桌面模式。"
        }
    }

    var mobilitySymbolName: String {
        switch self {
        case .closedLidContinuity: "macbook.and.iphone"
        case .displaySleepOnLidClose: "display"
        case .requirePasswordAfterDisplaySleep: "lock.display"
        case .keepExternalDisplayActive: "display.2"
        }
    }
}

extension MacPolicyControlState {
    var mobilityTint: Color {
        switch self {
        case .appManaged: .green
        case .externallyEnabled: .blue
        case .disabled: .secondary
        case .unsupported, .unknown: .orange
        }
    }

    var mobilitySymbolName: String {
        switch self {
        case .appManaged: "checkmark.circle.fill"
        case .externallyEnabled: "arrow.triangle.branch"
        case .disabled: "circle"
        case .unsupported: "nosign"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var mobilityReason: String? {
        switch self {
        case .unsupported(let reason), .unknown(let reason): reason
        case .disabled, .externallyEnabled, .appManaged: nil
        }
    }

    var mobilityCanChange: Bool {
        switch self {
        case .disabled, .externallyEnabled, .appManaged: true
        case .unsupported, .unknown: false
        }
    }
}
