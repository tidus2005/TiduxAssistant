import AppKit
import CodexMobilityCore
import SwiftUI

public struct MobilityMenuBarView: View {
    @ObservedObject private var store: MacMobilityStore
    @ObservedObject private var closedLidSessionController: MacClosedLidSessionController
    @ObservedObject private var hotspotAutomationStore: MacHotspotAutomationStore
    @ObservedObject private var moduleStore: MobilityModuleConfigurationStore
    @ObservedObject private var voiceInputStore: MacVoiceInputStore
    @ObservedObject private var powerPolicyStore: MacSystemPowerPolicyStore
    @ObservedObject private var remoteDashboard: MacRemoteDashboardController
    private let caffeineController: MacCaffeineController?
    private let pairingState: MobilityBLEPeripheralState
    private let onRegeneratePairingCode: () -> Void
    private let onOpenDashboard: () -> Void

    public init(
        store: MacMobilityStore,
        closedLidSessionController: MacClosedLidSessionController,
        hotspotAutomationStore: MacHotspotAutomationStore,
        moduleStore: MobilityModuleConfigurationStore,
        voiceInputStore: MacVoiceInputStore,
        powerPolicyStore: MacSystemPowerPolicyStore,
        remoteDashboard: MacRemoteDashboardController,
        caffeineController: MacCaffeineController? = nil,
        pairingState: MobilityBLEPeripheralState,
        onRegeneratePairingCode: @escaping () -> Void,
        onOpenDashboard: @escaping () -> Void
    ) {
        self.store = store
        self.closedLidSessionController = closedLidSessionController
        self.hotspotAutomationStore = hotspotAutomationStore
        self.moduleStore = moduleStore
        self.voiceInputStore = voiceInputStore
        self.powerPolicyStore = powerPolicyStore
        self.remoteDashboard = remoteDashboard
        self.caffeineController = caffeineController
        self.pairingState = pairingState
        self.onRegeneratePairingCode = onRegeneratePairingCode
        self.onOpenDashboard = onOpenDashboard
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            voiceInputQuickRow
            closedLidSessionCard
            if let caffeineController {
                DisclosureGroup("咖啡因 · 保持唤醒") {
                    MobilityCaffeineControls(controller: caffeineController)
                        .padding(.top, 8)
                }
            }
            statusGrid
            remoteDashboardRow

            if let error = closedLidSessionController.lastErrorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if closedLidSessionController.requiresTemporaryOverrideRecovery {
                        Button("重试恢复") {
                            Task {
                                await closedLidSessionController.retrySystemPolicyRecovery()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Divider()
            pairingRow
            footer
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            // A Personal Hotspot can finish DHCP while this menu is closed.
            // Refresh immediately instead of waiting for the idle 30-second poll.
            store.refreshNow()
            powerPolicyStore.refresh()
            remoteDashboard.refreshNetworkAddress()
        }
    }

    private var remoteDashboardRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title3)
                .foregroundStyle(remoteDashboard.servicePhase == .online ? .green : .orange)
                .frame(width: 34, height: 34)
                .background(
                    (remoteDashboard.servicePhase == .online ? Color.green : Color.orange)
                        .opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("手机 Web 控制台")
                    .font(.subheadline.weight(.semibold))
                Text(remoteDashboardStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 6)

            if remoteDashboard.servicePhase == .online,
               let shareURL = remoteDashboard.shareURL {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shareURL, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("复制 MyApps Hub 公网控制台链接")

                Button {
                    if let url = URL(string: shareURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "safari")
                }
                .help("在浏览器打开公网手机控制台")
            } else if remoteDashboard.servicePhase == .failed {
                Button("重试") {
                    remoteDashboard.stop()
                    remoteDashboard.start()
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            if let lanShareURL = remoteDashboard.lanShareURL {
                Button("复制局域网安全链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lanShareURL, forType: .string)
                }
            }
            Button("轮换 Hub 内部令牌") {
                remoteDashboard.rotateAccessLink()
            }
            .help("轮换 Hub 到应用的内部访问令牌")
            .disabled(remoteDashboard.servicePhase != .online)
        }
    }

    private var remoteDashboardStatusText: String {
        switch remoteDashboard.servicePhase {
        case .stopped:
            "已停止"
        case .starting:
            "正在启动受保护的本地服务…"
        case .online:
            switch remoteDashboard.publicAccessPhase {
            case .online:
                "MyApps Hub 在线 · \(remoteDashboard.publicURL ?? "3000")"
            case .checking:
                "正在检查 MyApps Hub 公网入口…"
            case .offline:
                "MyApps Hub 暂不可用 · 本机服务在线"
            case .disabled:
                remoteDashboard.lanURL ?? remoteDashboard.localURL ?? "服务在线"
            }
        case .failed:
            remoteDashboard.lastErrorMessage ?? "本地 Web 服务启动失败"
        }
    }

    private var voiceInputQuickRow: some View {
        HStack(spacing: 12) {
            Image(systemName: voiceInputSymbol)
                .font(.title3)
                .foregroundStyle(voiceInputTint)
                .frame(width: 34, height: 34)
                .background(voiceInputTint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("智能语音输入")
                    .font(.subheadline.weight(.semibold))
                Text(
                    moduleStore.isEnabled(.voiceInput)
                        ? voiceInputStore.statusMessage
                        : "模块已关闭，可在设置中重新启用。"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                Task { await voiceInputStore.toggleDictation() }
            } label: {
                Image(systemName: voiceInputStore.phase == .recording ? "stop.fill" : "mic.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .tint(voiceInputStore.phase == .recording ? .red : .accentColor)
            .disabled(
                !moduleStore.isEnabled(.voiceInput)
                    || (voiceInputStore.phase.isBusy && voiceInputStore.phase != .recording)
            )
            .help(voiceInputStore.phase == .recording ? "结束听写" : "开始听写")
        }
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.shield.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Tidux助手")
                    .font(.headline)
                Text("Mac 后台任务与手机热点守护")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("打开设置")
        }
    }

    private var closedLidSessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title3)
                    .foregroundStyle(baselineClosedLidTint)
                    .frame(width: 38, height: 38)
                    .background(baselineClosedLidTint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("合盖运行")
                        .font(.headline)
                    Text(baselineClosedLidStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if powerPolicyStore.isBusy
                    && closedLidSessionController.phase != .preparing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 38)
                } else {
                    Toggle(
                        "合盖运行",
                        isOn: Binding(
                            get: { closedLidSessionController.isBaselineToggleOn },
                            set: { enabled in
                                Task {
                                    await closedLidSessionController
                                        .setBaselineClosedLidEnabled(enabled)
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!closedLidSessionController.isBaselineToggleEnabled)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "macbook.and.iphone")
                    .font(.title2)
                    .foregroundStyle(sessionTint)
                    .frame(width: 38, height: 38)
                    .background(sessionTint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("移动办公模式")
                        .font(.headline)
                    if let expiresAt = closedLidSessionController.expiresAt,
                       closedLidSessionController.phase == .active {
                        HStack(spacing: 4) {
                            Text("剩余")
                            Text(expiresAt, style: .timer)
                                .monospacedDigit()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sessionTint)
                    }
                    Text(closedLidSessionController.statusMessage)
                        .font(.caption)
                        .foregroundStyle(
                            closedLidSessionController.phase == .failed
                                ? Color.orange
                                : .secondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if closedLidSessionController.phase == .stopping {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 38)
                } else {
                    HStack(spacing: 6) {
                        if closedLidSessionController.phase == .preparing {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Toggle(
                            "移动办公模式",
                            isOn: Binding(
                                get: { closedLidSessionController.isToggleOn },
                                set: { enabled in
                                    Task {
                                        await closedLidSessionController.setEnabled(enabled, mobileOffice: true)
                                    }
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!closedLidSessionController.isToggleEnabled)
                    }
                }
            }

            Picker("随行时长", selection: Binding(
                get: { Int(closedLidSessionController.selectedDuration / 60) },
                set: { closedLidSessionController.setDuration(Double($0) * 60) }
            )) {
                ForEach(MacClosedLidSessionController.durationMinutesChoices, id: \.self) { minutes in
                    Text(MacClosedLidSessionController.durationLabel(seconds: Double(minutes) * 60))
                        .tag(minutes)
                }
            }
            .disabled(!closedLidSessionController.canEditDuration)
            .help("保存为下次启动的时长；运行中如需更改，请先停止会话。")

            HStack(spacing: 8) {
                Label("合盖后台运行", systemImage: "moon.zzz.fill")
                Label("合盖关屏省电", systemImage: "macbook")
                Label("持续联网守护", systemImage: "wifi.exclamationmark")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text("所选时长内持续恢复网络，不因断网、低于普通电量阈值或 Codex 暂时退出而停止；到期、手动关闭或过热时停止。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("合盖后关闭显示器，后台任务继续运行；沿用系统锁屏设置。桌面截图与点击仍需要可用的显示会话。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "personalhotspot")
                Text("备用热点")
                Spacer()
                TextField("输入已保存的热点名称", text: hotspotSSIDBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .disabled(closedLidSessionController.phase != .off
                        && closedLidSessionController.phase != .failed)
            }
            .font(.caption)

            HotspotWiFiPermissionButton()

            Label(hotspotRuntimeStatusText, systemImage: hotspotStatusSymbol)
                .font(.caption2)
                .foregroundStyle(hotspotStatusColor)
                .lineLimit(2)

            Label(
                closedLidSessionController.remoteControlReadiness.displayName,
                systemImage: closedLidSessionController.remoteControlReadiness.isConnected
                    ? "iphone.radiowaves.left.and.right"
                    : "exclamationmark.icloud"
            )
            .font(.caption2)
            .foregroundStyle(
                closedLidSessionController.remoteControlReadiness.isConnected
                    ? Color.green
                    : remoteControlStatusColor
            )
            .lineLimit(2)

            Text("临时开关会覆盖“合盖运行”，到期、手动停止、启动失败或 App 重启后恢复启动前配置；不会主动切回旧 Wi‑Fi。首次需要 macOS 管理员验证。真实断线时只重连已保存热点。请保持机器通风。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(sessionTint.opacity(0.28), lineWidth: 1)
        }
    }

    private var statusGrid: some View {
        HStack(spacing: 8) {
            MobilityMenuStatusChip(
                title: "电池",
                value: store.status.battery.mobilityDisplayName,
                symbol: "battery.75percent",
                tint: .green
            )
            MobilityMenuStatusChip(
                title: "网络",
                value: store.status.network.mobilityDisplayName,
                symbol: "wifi",
                tint: store.status.network.isConnected ? .blue : .orange
            )
            MobilityMenuStatusChip(
                title: "Codex",
                value: store.status.codex.isRunning ? "运行中" : "未运行",
                symbol: "terminal",
                tint: store.status.codex.isRunning ? .purple : .secondary
            )
        }
    }

    @ViewBuilder
    private var pairingRow: some View {
        if pairingState.isPairingWindowOpen {
            HStack {
                Label("iPhone 配对码", systemImage: "iphone.gen3")
                Spacer()
                Text(pairingState.pairingCode)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
        } else {
            Button {
                onRegeneratePairingCode()
            } label: {
                Label("生成 iPhone 配对码", systemImage: "iphone.gen3.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                onOpenDashboard()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("打开仪表盘", systemImage: "rectangle.3.group")
            }

            Spacer()

            Text(appVersionText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            Button("退出") {
                closedLidSessionController.shutdown()
                store.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    private var appVersionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "local"
        return "v\(version) (\(build))"
    }

    private var sessionTint: Color {
        switch closedLidSessionController.phase {
        case .active: .green
        case .preparing, .stopping: .blue
        case .failed: .orange
        case .off: .secondary
        }
    }

    private var baselineClosedLidStatusText: String {
        if let baseline = closedLidSessionController.baselineClosedLidEnabled {
            return baseline
                ? "开 · 临时模式结束后仍保持开启"
                : "关 · 当前正被临时覆盖为开启"
        }
        switch powerPolicyStore.snapshot.state(for: .closedLidContinuity) {
        case .disabled:
            return "关 · 使用 macOS 普通睡眠行为"
        case .externallyEnabled:
            return "开 · 外部策略（不是临时开关造成）"
        case .appManaged:
            return "开 · App 管理"
        case .unsupported(let message), .unknown(let message):
            return message
        }
    }

    private var baselineClosedLidTint: Color {
        closedLidSessionController.isBaselineToggleOn ? .green : .secondary
    }

    private var remoteControlStatusColor: Color {
        closedLidSessionController.remoteControlReadiness == .notChecked
            ? .secondary
            : .orange
    }

    private var voiceInputSymbol: String {
        switch voiceInputStore.phase {
        case .recording:
            "waveform.circle.fill"
        case .preparing, .processing, .inserting:
            "sparkles"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle:
            "waveform.circle"
        }
    }

    private var voiceInputTint: Color {
        switch voiceInputStore.phase {
        case .recording:
            .red
        case .preparing, .processing, .inserting:
            .blue
        case .completed:
            .green
        case .failed:
            .orange
        case .idle:
            .purple
        }
    }

    private var hotspotSSIDBinding: Binding<String> {
        Binding(
            get: { closedLidSessionController.hotspotTargetName ?? "" },
            set: { value in
                var values = hotspotAutomationStore.preferredSSIDs
                if values.isEmpty {
                    values = [value]
                } else {
                    values[0] = value
                }
                hotspotAutomationStore.updatePreferredSSIDs(
                    text: values.joined(separator: "\n")
                )
            }
        )
    }

    private var hotspotStatusSymbol: String {
        if hasVerifiedSessionHotspot {
            return "wifi"
        }
        switch hotspotAutomationStore.snapshot.phase {
        case .monitoring where hotspotAutomationStore.snapshot.isNetworkAvailable:
            return "wifi"
        case .reconnecting, .waitingForConnectivity:
            return "arrow.clockwise"
        case .backingOff:
            return "exclamationmark.arrow.triangle.2.circlepath"
        default:
            return "personalhotspot"
        }
    }

    private var hotspotStatusColor: Color {
        if hasVerifiedSessionHotspot {
            return .green
        }
        switch hotspotAutomationStore.snapshot.phase {
        case .monitoring where hotspotAutomationStore.snapshot.isNetworkAvailable:
            return .green
        case .backingOff:
            return .orange
        default:
            return .secondary
        }
    }

    private var hotspotRuntimeStatusText: String {
        hasVerifiedSessionHotspot
            ? "当前计费热点路径可用，断线守护已开启"
            : hotspotAutomationStore.statusText
    }

    /// The closed-lid controller publishes `.active` only after its allow-listed
    /// join and live network preflight have both succeeded. The dedicated
    /// recovery monitor can take another callback cycle to publish its first
    /// snapshot, so use the already verified sampler frame during that short
    /// window instead of showing the contradictory “waiting for network” text.
    private var hasVerifiedSessionHotspot: Bool {
        guard closedLidSessionController.phase == .active else { return false }
        let network = store.status.network
        guard network.isConnected,
              network.kind == .wifi,
              network.isExpensive || network.isConstrained else {
            return false
        }
        switch hotspotAutomationStore.snapshot.phase {
        case .confirmingFailure, .reconnecting, .waitingForConnectivity, .backingOff:
            return false
        case .stopped, .monitoring:
            return true
        }
    }
}

private struct MobilityMenuStatusChip: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
