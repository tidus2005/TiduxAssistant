import CodexMobilityCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
public struct MobilityPhoneRootView: View {
    @ObservedObject private var store: MobilityPhoneStore
    #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AccessorySetupKit)
    @ObservedObject private var accessorySetupCoordinator: MobilityAccessorySetupCoordinator
    #endif
    @State private var presentedSheet: SheetDestination?
    @State private var accessoryToRepair: UUID?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AccessorySetupKit)
    public init(
        store: MobilityPhoneStore,
        accessorySetupCoordinator: MobilityAccessorySetupCoordinator
    ) {
        self.store = store
        self.accessorySetupCoordinator = accessorySetupCoordinator
    }
    #else
    public init(store: MobilityPhoneStore) {
        self.store = store
    }
    #endif

    public var body: some View {
        NavigationStack {
            content
            .navigationTitle("设备")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if store.state.lastKnownStatus == nil {
                            store.rescan()
                        } else {
                            store.refreshStatus()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(store.state.lastKnownStatus == nil ? "重新扫描 Mac" : "刷新 Mac 状态")
                }
            }
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .pairing(let identifier, let computerName):
                MobilityPairingSheet(
                    store: store,
                    peripheralIdentifier: identifier,
                    computerName: computerName
                )
            case .policy(let policy):
                MobilityPolicySheet(store: store, policy: policy)
            }
        }
        .onAppear(perform: synchronizePresentedSheet)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.start() }
        }
        .onChange(of: store.pairingState) { _, _ in
            synchronizePresentedSheet()
        }
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AccessorySetupKit)
        .confirmationDialog("重新配对此 Mac？", isPresented: Binding(
            get: { accessoryToRepair != nil }, set: { if !$0 { accessoryToRepair = nil } }
        ), titleVisibility: .visible) {
            Button("重新配对") {
                if let identifier = accessoryToRepair {
                    accessorySetupCoordinator.repairAccessory(identifier: identifier)
                }
                accessoryToRepair = nil
            }
            Button("取消", role: .cancel) { accessoryToRepair = nil }
        } message: {
            Text("将重建这台 Mac 的系统蓝牙关联，并重新输入 Mac 配对码。已保存的记录和文件会保留。")
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let status = store.state.lastKnownStatus {
            statusDashboard(status)
        } else {
            discoveryContent
        }
    }

    private var discoveryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("把 Mac 带到手边").font(.title2.weight(.bold))
                    Text("连接一次，随时交代任务、查看进展。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                bluetoothGuidance
                #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AccessorySetupKit)
                accessorySetupCard
                #endif
                if store.state.bluetoothAvailability == .poweredOn { connectionSummary }
                errorBanner

                if store.state.computers.isEmpty && store.state.bluetoothAvailability == .poweredOn {
                    ContentUnavailableView {
                        Label("正在寻找 Mac", systemImage: "laptopcomputer.and.iphone")
                    } description: {
                        Text("请在 Mac 端开启 Codex 随行，然后让两台设备保持在蓝牙范围内。")
                    } actions: {
                        ProgressView()
                            .accessibilityLabel("正在扫描")
                        Button("重新扫描") {
                            store.rescan()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if !store.state.computers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("2 · 连接与配对")
                            .font(.headline)

                        ForEach(store.state.computers) { computer in
                            Button {
                                store.connect(to: computer.id)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "laptopcomputer")
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                        .frame(width: 34)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(computer.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(signalDescription(computer))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: signalSymbol(computer))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(16)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("连接 \(computer.name)，\(signalDescription(computer))")
                        }
                    }
                }

                if case .ready(let identifier) = store.state.connectionPhase,
                   store.pairingState.requiresCode {
                    Button {
                        presentedSheet = .pairing(
                            identifier: identifier,
                            computerName: store.pairingState.computerName ?? "Mac"
                        )
                    } label: {
                        Label("输入 6 位配对码", systemImage: "lock.badge.clock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                backgroundExpectation
            }
            .padding()
        }
    }

    private func statusDashboard(_ status: MobilityDeviceStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusHeader(status)
                NavigationLink { MobilityPhoneDashboardView(store: store) } label: {
                    Label("Mac 控制台", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AccessorySetupKit)
                DisclosureGroup("设备配对管理") { accessorySetupCard }
                #endif
                errorBanner
                statusGrid(status)
                modeControl(status)
                labsCard(status)
                backgroundExpectation
            }
            .padding()
        }
        .refreshable {
            store.refreshStatus()
        }
    }

    private func statusHeader(_ status: MobilityDeviceStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.deviceName)
                        .font(.title2.weight(.bold))
                    Text(connectionPhaseText)
                        .font(.subheadline)
                        .foregroundStyle(connectionPhaseColor)
                }
                Spacer()
                Image(systemName: store.state.isStale ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(store.state.isStale ? .orange : .green)
                    .accessibilityHidden(true)
            }

            if let staleSince = store.state.staleSince {
                Label {
                    Text("状态已过期 · \(staleSince, style: .relative)起未更新")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("显示的是上次已知状态，等待 Mac 更新")
            } else if let lastStatusAt = store.state.lastStatusAt {
                Text("更新于 \(lastStatusAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func statusGrid(_ status: MobilityDeviceStatus) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
            MobilityStatusTile(
                title: "Mac 电池",
                value: batteryValue(status),
                detail: batteryDetail(status),
                symbol: batterySymbol(status.battery.levelPercent),
                color: batteryColor(status)
            )
            MobilityStatusTile(
                title: "网络",
                value: networkValue(status.network),
                detail: networkDetail(status.network),
                symbol: status.network.isConnected ? "network" : "wifi.slash",
                color: status.network.isConnected ? .green : .red
            )
            MobilityStatusTile(
                title: "温度",
                value: MobilityTelemetryPresentation.temperatureValue(status),
                detail: MobilityTelemetryPresentation.temperatureSource(status)
                    + " · 热压力" + thermalValue(status.thermalState),
                symbol: thermalSymbol(status.thermalState),
                color: thermalColor(status.thermalState)
            )
            MobilityStatusTile(
                title: "Codex",
                value: status.codex.isRunning ? "运行中" : "未运行",
                detail: codexDetail(status.codex),
                symbol: status.codex.isRunning ? "terminal.fill" : "terminal",
                color: status.codex.isRunning ? .green : .orange
            )
            MobilityStatusTile(
                title: "合盖续跑",
                value: status.mode.isEnabled && status.mode.profile == .closedLidLabs ? "已开启" : "未开启",
                detail: status.mode.profile == .closedLidLabs && status.mode.isEnabled
                    ? "限时会话 · 仍受电量与温控保护" : "请在 Mac 开启移动办公模式",
                symbol: "laptopcomputer",
                color: status.mode.isEnabled && status.mode.profile == .closedLidLabs ? .green : .secondary
            )
        }
    }

    private func modeControl(_ status: MobilityDeviceStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("移动办公模式", isOn: Binding(
                get: { store.dashboard?.mobileOfficeOn ?? false },
                set: { enabled in
                    Task { await store.performDashboard(.mobileOffice(enabled: enabled,
                        durationMinutes: store.dashboard?.durationMinutes ?? 120)) }
                }
            )).disabled(store.dashboard == nil || store.dashboardBusy || store.state.isStale)
            if let dashboard = store.dashboard {
                Text(dashboard.mobileOfficeStatus).font(.caption).foregroundStyle(.secondary)
                if dashboard.mobileOfficeOn, let expiry = dashboard.expiresAt {
                    LabeledContent("本次会话剩余") { Text(expiry, style: .timer).monospacedDigit() }
                }
            } else {
                Button("读取 Mac 运行配置") { Task { await store.performDashboard(.snapshot) } }
            }
            NavigationLink("时长、热点和更多控制") { MobilityPhoneDashboardView(store: store) }
            Divider()
            HStack {
                Text("Idle Guard 安全策略").font(.subheadline)
                Spacer()
                Button("调整") { presentedSheet = .policy(status.mode.policy) }
                    .disabled(store.state.hasPendingPolicyCommand || store.state.isStale)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func labsCard(_ status: MobilityDeviceStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("合盖持续运行", systemImage: "flask")
                    .font(.headline)
                Spacer()
                Text(status.helperReady ? "Mac 系统策略已开启" : "需要在 Mac 配置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.helperReady ? Color.green : .secondary)
            }
            Text(
                status.helperReady
                    ? "Mac 已检测到系统级合盖续跑策略。已完成授权后可从手机控制台调整；如需管理员认证，请在 Mac 本机确认。低电量或温度停机不会自动关闭该系统全局策略。"
                    : "请在 Mac App 的“电源”设置中完成管理员验证。普通 Idle Guard 只能防止空闲睡眠。"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var backgroundExpectation: some View {
        Label {
            #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AccessorySetupKit)
            Text(accessoryBackgroundExpectationText)
            #else
            Text("iPhone 的蓝牙后台连接与状态恢复是尽力而为。iOS 可能挂起或终止 App；重新打开后会自动尝试重连。")
            #endif
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AccessorySetupKit)
    private var accessorySetupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: accessorySetupSymbol)
                    .font(.title2)
                    .foregroundStyle(accessorySetupColor)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text("1 · 添加你的 Mac")
                        .font(.headline)
                    Text(accessorySetupStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if accessorySetupCoordinator.state.isPickerBusy
                    || accessorySetupCoordinator.state.phase == .activating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("系统配件授权处理中")
                }
            }

            Text("让 Mac 打开随行助手，点击下方按钮，在系统窗口中选择它。然后输入 Mac 上的 6 位配对码。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !accessorySetupCoordinator.state.authorizedAccessories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(accessorySetupCoordinator.state.authorizedAccessories) { accessory in
                        Label(accessory.displayName, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Button("重新配对此 Mac") { accessoryToRepair = accessory.id }
                            .font(.caption)
                            .disabled(accessorySetupCoordinator.isRepairing || accessorySetupCoordinator.state.isPickerBusy)
                    }
                }
            }

            if let error = accessorySetupCoordinator.state.lastErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        accessorySetupCoordinator.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭系统授权错误")
                }
            }

            Button {
                accessorySetupCoordinator.showSystemPicker()
            } label: {
                Label(
                    accessorySetupCoordinator.state.isPickerBusy ? "正在寻找 Mac…" : "添加 Mac",
                    systemImage: "plus.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                accessorySetupCoordinator.state.isPickerBusy
            )
            .accessibilityHint("打开 Apple 的配件选择器，只显示广播 Codex 随行服务的 Mac")
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var accessorySetupStatusText: String {
        let count = accessorySetupCoordinator.state.authorizedAccessories.count
        return switch accessorySetupCoordinator.state.phase {
        case .inactive: "准备系统授权"
        case .activating: "正在初始化系统授权"
        case .active where count == 0: "尚未通过系统添加 Mac"
        case .active: "系统已授权 \(count) 台 Mac"
        case .invalidated: "点“添加 Mac”重新连接系统授权"
        }
    }

    private var accessorySetupSymbol: String {
        if !accessorySetupCoordinator.state.authorizedAccessories.isEmpty {
            return "checkmark.shield.fill"
        }
        if accessorySetupCoordinator.state.phase == .invalidated {
            return "exclamationmark.shield.fill"
        }
        return "shield.lefthalf.filled"
    }

    private var accessorySetupColor: Color {
        if !accessorySetupCoordinator.state.authorizedAccessories.isEmpty { return .green }
        if accessorySetupCoordinator.state.phase == .invalidated { return .orange }
        return .accentColor
    }

    private var accessoryBackgroundExpectationText: String {
        if accessorySetupCoordinator.state.authorizedAccessories.isEmpty {
            return "首次连接：系统添加 Mac → 输入配对码 → 开始协作。"
        }
        return "离开后会尝试自动重连。若状态长时间未更新，重新打开 App 刷新。"
    }
    #endif

    @ViewBuilder
    private var errorBanner: some View {
        if let error = store.state.lastErrorMessage {
            DisclosureGroup("连接诊断") {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("清除提示") { store.clearError() }.font(.caption)
            }.font(.subheadline).padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var connectionSummary: some View {
        HStack(spacing: 10) {
            if case .connecting = store.state.connectionPhase {
                ProgressView()
                    .controlSize(.small)
            } else if case .discovering = store.state.connectionPhase {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(connectionPhaseText)
                    .font(.headline)
                Text("蓝牙优先，网络连接备用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var bluetoothGuidance: some View {
        if store.state.bluetoothAvailability != .poweredOn {
            VStack(alignment: .leading, spacing: 12) {
                Label(bluetoothGuidanceTitle, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.headline)
                Text(bluetoothGuidanceDetail).font(.subheadline).foregroundStyle(.secondary)
                #if os(iOS)
                Button("打开 App 设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.bordered)
                #endif
                Button("重新检查连接") { store.rescan() }.font(.subheadline)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var bluetoothGuidanceTitle: String {
        switch store.state.bluetoothAvailability {
        case .unauthorized: "需要蓝牙授权"
        case .poweredOff: "蓝牙连接尚未就绪"
        case .unsupported: "当前设备不支持蓝牙连接"
        case .unknown, .resetting: "正在准备蓝牙"
        case .poweredOn: "蓝牙已就绪"
        }
    }
    private var bluetoothGuidanceDetail: String {
        switch store.state.bluetoothAvailability {
        case .unauthorized: "先用下方“添加 Mac”完成系统授权。若曾拒绝权限，请到 App 设置允许蓝牙。"
        case .poweredOff: "请到 iPhone“设置 → 蓝牙”确认蓝牙已打开，然后用下方“添加 Mac”完成授权。仅手表保持连接，不代表 App 的蓝牙已可用。"
        case .unsupported: "你仍可在协作页的连接设置中配置网络连接。"
        case .unknown, .resetting: "稍候会自动寻找 Mac。你也可以先使用下方系统添加入口。"
        case .poweredOn: "可以寻找附近的 Mac。"
        }
    }

    private func synchronizePresentedSheet() {
        switch store.pairingState {
        case .required(let identifier, let name), .rejected(let identifier, let name, _):
            if presentedSheet == nil {
                presentedSheet = .pairing(identifier: identifier, computerName: name)
            }
        case .paired:
            if case .pairing = presentedSheet {
                presentedSheet = nil
            }
        case .idle, .submitting:
            break
        }
    }

    private var connectionPhaseText: String {
        switch store.state.connectionPhase {
        case .idle: "等待蓝牙"
        case .scanning: "正在扫描"
        case .connecting: "正在连接 Mac"
        case .discovering: "正在建立安全通道"
        case .ready: store.state.isStale ? "蓝牙已连接 · 等待最新状态" : "Mac 已连接 · 蓝牙"
        case .reconnecting: "连接中断，正在自动重连"
        }
    }

    private var connectionPhaseColor: Color {
        switch store.state.connectionPhase {
        case .ready: store.state.isStale ? .orange : .green
        case .connecting, .discovering, .reconnecting: .orange
        case .idle, .scanning: .secondary
        }
    }

    private func batteryValue(_ status: MobilityDeviceStatus) -> String {
        status.battery.levelPercent.map { "\($0)%" } ?? "未知"
    }

    private func batteryDetail(_ status: MobilityDeviceStatus) -> String {
        if status.battery.isCharging { return "正在充电" }
        if status.battery.isOnExternalPower { return "已接电源" }
        if let minutes = status.battery.estimatedMinutesRemaining { return "约 \(minutes) 分钟" }
        return "使用电池"
    }

    private func batterySymbol(_ level: Int?) -> String {
        guard let level else { return "battery.0percent" }
        return switch level {
        case 76...100: "battery.100percent"
        case 51...75: "battery.75percent"
        case 26...50: "battery.50percent"
        case 1...25: "battery.25percent"
        default: "battery.0percent"
        }
    }

    private func batteryColor(_ status: MobilityDeviceStatus) -> Color {
        guard let level = status.battery.levelPercent else { return .secondary }
        if level <= status.mode.policy.lowBatteryThresholdPercent { return .red }
        if level <= status.mode.policy.lowBatteryThresholdPercent + MobilityPolicy.startupBatteryReservePercent { return .orange }
        return .green
    }

    private func networkValue(_ network: MobilityNetworkStatus) -> String {
        guard network.isConnected else { return "已断开" }
        if network.kind == .wifi && network.isExpensive { return "疑似手机热点" }
        return switch network.kind {
        case .offline: "离线"
        case .wifi: "Wi‑Fi"
        case .ethernet: "有线网络"
        case .cellular: "蜂窝中继"
        case .other: "其他网络"
        case .unknown: "已连接"
        }
    }

    private func networkDetail(_ network: MobilityNetworkStatus) -> String {
        if !network.isConnected, let disconnectedSince = network.disconnectedSince {
            return "断开于 \(disconnectedSince.formatted(date: .omitted, time: .shortened))"
        }
        if network.isConstrained { return "低数据模式" }
        if network.isExpensive { return "计费网络" }
        return network.interfaceName ?? (network.isConnected ? "网络可用" : "等待网络")
    }

    private func thermalValue(_ state: MobilityThermalState) -> String {
        switch state {
        case .nominal: "正常"
        case .fair: "偏热"
        case .serious: "过热"
        case .critical: "严重过热"
        case .unknown: "未知"
        }
    }

    private func thermalDetail(_ state: MobilityThermalState) -> String {
        switch state {
        case .nominal: "可持续运行"
        case .fair: "系统可能降频"
        case .serious: "建议停止模式"
        case .critical: "将触发安全停止"
        case .unknown: "等待 Mac 上报"
        }
    }

    private func thermalSymbol(_ state: MobilityThermalState) -> String {
        switch state {
        case .nominal: "thermometer.low"
        case .fair: "thermometer.medium"
        case .serious, .critical: "thermometer.high"
        case .unknown: "thermometer.variable"
        }
    }

    private func thermalColor(_ state: MobilityThermalState) -> Color {
        switch state {
        case .nominal: .green
        case .fair: .orange
        case .serious, .critical: .red
        case .unknown: .secondary
        }
    }

    private func codexDetail(_ codex: MobilityCodexStatus) -> String {
        if codex.activeTaskCount > 0 { return "\(codex.activeTaskCount) 个活跃任务" }
        return codex.detail ?? (codex.isRunning ? "当前空闲" : "需要先启动 Codex")
    }

    private func modePhaseText(_ phase: MobilityModePhase) -> String {
        switch phase {
        case .off: "已关闭"
        case .preflighting: "正在安全检查"
        case .armed: "已就绪"
        case .active: "运行中"
        case .degraded: "降级运行"
        case .stopping: "正在停止"
        case .blocked: "已被安全策略阻止"
        case .faulted: "运行异常"
        case .recovering: "正在恢复"
        }
    }

    private func modeColor(_ phase: MobilityModePhase) -> Color {
        switch phase {
        case .active, .armed: .green
        case .preflighting, .degraded, .stopping, .recovering: .orange
        case .blocked, .faulted: .red
        case .off: .secondary
        }
    }

    private func safetyBlockerText(_ blocker: MobilitySafetyBlocker) -> String {
        switch blocker {
        case .batteryUnavailable: "无法读取电池电量"
        case .insufficientBatteryReserve: "电量没有高出截止线至少 10%"
        case .networkUnavailable: "Mac 当前没有可用网络"
        case .codexNotRunning: "策略要求 Codex 正在运行"
        case .thermalSerious: "Mac 温度过高"
        case .thermalCritical: "Mac 严重过热"
        case .thermalUnknown: "无法读取 Mac 温度"
        case .helperUnavailable: "系统辅助组件未就绪"
        }
    }

    private func policySummary(_ policy: MobilityPolicy) -> String {
        let durationMinutes = Int(policy.maximumDurationSeconds / 60)
        let graceMinutes = Int(policy.networkDisconnectGraceSeconds / 60)
        return "\(policy.lowBatteryThresholdPercent)% 截止 · 最长 \(durationMinutes) 分钟 · 断网宽限 \(graceMinutes) 分钟"
    }

    private func signalDescription(_ computer: MobilityDiscoveredComputer) -> String {
        if computer.lastSeenAt == .distantPast {
            return "已配对 · 等待 Mac 出现"
        }
        let rssi = computer.signalStrength
        return switch rssi {
        case -55...0: "信号很好"
        case -70 ..< -55: "信号良好"
        case -85 ..< -70: "信号较弱"
        default: "信号很弱"
        }
    }

    private func signalSymbol(_ computer: MobilityDiscoveredComputer) -> String {
        if computer.lastSeenAt == .distantPast { return "wifi.slash" }
        return computer.signalStrength >= -70 ? "wifi" : "wifi.exclamationmark"
    }

    private enum SheetDestination: Identifiable, Equatable {
        case pairing(identifier: UUID, computerName: String)
        case policy(MobilityPolicy)

        var id: String {
            switch self {
            case .pairing: "pairing"
            case .policy: "policy"
            }
        }
    }
}

private struct MobilityStatusTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.bold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)，\(detail)")
    }
}

@MainActor
private struct MobilityPairingSheet: View {
    @ObservedObject var store: MobilityPhoneStore
    let peripheralIdentifier: UUID
    let computerName: String
    @Environment(\.dismiss) private var dismiss
    @State private var pairingCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 42))
                            .foregroundStyle(.tint)
                        Text("配对 \(computerName)")
                            .font(.title3.weight(.bold))
                        Text("输入 Mac 端显示的 6 位数字。配对成功后，令牌只保存在这台 iPhone 的钥匙串。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("配对码") {
                    TextField("000000", text: $pairingCode)
                        .font(.system(.title, design: .monospaced).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textContentType(.oneTimeCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .onChange(of: pairingCode) { _, value in
                            pairingCode = String(value.filter(\.isNumber).prefix(6))
                        }
                        .accessibilityLabel("6 位配对码")
                }

                if case .rejected(_, _, let reason) = store.pairingState {
                    Section {
                        Label(reason, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        store.submitPairingCode(pairingCode)
                    } label: {
                        HStack {
                            Spacer()
                            if case .submitting = store.pairingState {
                                ProgressView()
                                    .controlSize(.small)
                                Text("等待 Mac 确认")
                            } else {
                                Text("安全配对")
                            }
                            Spacer()
                        }
                    }
                    .disabled(
                        !MobilityPhoneMessageFactory.isValidPairingCode(pairingCode)
                        || isSubmitting
                    )
                }
            }
            .navigationTitle("连接 Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后") { dismiss() }
                }
            }
            .onChange(of: store.pairingState) { _, next in
                if case .paired(let identifier, _) = next, identifier == peripheralIdentifier {
                    dismiss()
                }
            }
        }
    }

    private var isSubmitting: Bool {
        if case .submitting = store.pairingState { true } else { false }
    }
}

@MainActor
private struct MobilityPolicySheet: View {
    @ObservedObject var store: MobilityPhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var batteryFloorPercent: Int
    @State private var maximumRunMinutes: Int
    @State private var networkGraceMinutes: Int
    @State private var requiresCodexRunning: Bool

    init(store: MobilityPhoneStore, policy: MobilityPolicy) {
        self.store = store
        let policy = policy.normalized()
        _batteryFloorPercent = State(initialValue: policy.lowBatteryThresholdPercent)
        _maximumRunMinutes = State(initialValue: Int(policy.maximumDurationSeconds / 60))
        _networkGraceMinutes = State(initialValue: Int(policy.networkDisconnectGraceSeconds / 60))
        _requiresCodexRunning = State(initialValue: policy.requiresCodexRunning)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("自动停止") {
                    Stepper(value: $batteryFloorPercent, in: 20...80, step: 5) {
                        LabeledContent("截止电量", value: "\(batteryFloorPercent)%")
                    }
                    Stepper(value: $maximumRunMinutes, in: 15...240, step: 15) {
                        LabeledContent("最长时长", value: durationText)
                    }
                    Stepper(value: $networkGraceMinutes, in: 0...30, step: 1) {
                        LabeledContent("断网宽限", value: networkGraceMinutes == 0 ? "立即停止" : "\(networkGraceMinutes) 分钟")
                    }
                }

                Section("任务条件") {
                    Toggle("要求 Codex 正在运行", isOn: $requiresCodexRunning)
                    Text("开启后，Codex 退出或不再运行时，Mac 会按安全策略停止随行模式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Label("为了预留启动安全空间，开启模式时的实际电量需至少高于截止线 10%。", systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("安全策略")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updatePolicy(
                            MobilityPolicy(
                                lowBatteryThresholdPercent: batteryFloorPercent,
                                maximumDurationSeconds: TimeInterval(maximumRunMinutes * 60),
                                networkDisconnectGraceSeconds: TimeInterval(networkGraceMinutes * 60),
                                requiresCodexRunning: requiresCodexRunning
                            )
                        )
                        dismiss()
                    }
                }
            }
        }
    }

    private var durationText: String {
        if maximumRunMinutes < 60 { return "\(maximumRunMinutes) 分钟" }
        let hours = maximumRunMinutes / 60
        let minutes = maximumRunMinutes % 60
        return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分钟"
    }
}
