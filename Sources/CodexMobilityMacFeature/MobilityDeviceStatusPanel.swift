import CodexMobilityCore
import SwiftUI

struct MobilityDeviceStatusPanel: View {
    @ObservedObject private var store: MacMobilityStore
    private let descriptor: MobilityModuleDescriptor
    private let isSelected: Bool
    private let isEnabled: Bool
    private let experimentsEnabled: Bool
    private let pairingState: MobilityBLEPeripheralState
    private let pairedDevices: [MobilityMacPairedDevice]
    private let pairingManagementErrorMessage: String?
    private let onRegeneratePairingCode: () -> Void
    private let onRevokePairedDevice: (UUID) -> Void

    init(
        store: MacMobilityStore,
        descriptor: MobilityModuleDescriptor,
        isSelected: Bool,
        isEnabled: Bool,
        experimentsEnabled: Bool,
        pairingState: MobilityBLEPeripheralState,
        pairedDevices: [MobilityMacPairedDevice],
        pairingManagementErrorMessage: String?,
        onRegeneratePairingCode: @escaping () -> Void,
        onRevokePairedDevice: @escaping (UUID) -> Void
    ) {
        self.store = store
        self.descriptor = descriptor
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.experimentsEnabled = experimentsEnabled
        self.pairingState = pairingState
        self.pairedDevices = pairedDevices
        self.pairingManagementErrorMessage = pairingManagementErrorMessage
        self.onRegeneratePairingCode = onRegeneratePairingCode
        self.onRevokePairedDevice = onRevokePairedDevice
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("连接与设备").font(.largeTitle.weight(.bold))
                    Text("Mac 执行任务，iPhone 随时接续，Apple Watch 抬腕查看。")
                        .font(.title3).foregroundStyle(.secondary)
                }
                connectionOverview
                pairingCard
                pairedDevicesCard
                VStack(alignment: .leading, spacing: 12) {
                    Text("这台 Mac").font(.title2.weight(.semibold))
                    statusGrid
                }
            }.padding(28).frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle("连接与设备")
    }

    private var connectionOverview: some View {
        GroupBox {
            HStack(spacing: 20) {
                endpoint("Mac", subtitle: store.status.deviceName, symbol: "laptopcomputer")
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                endpoint("iPhone", subtitle: pairingState.connectedCentralCount > 0 ? "蓝牙通道已连接" : pairedDevices.isEmpty ? "尚未配对" : "等待重新连接", symbol: "iphone")
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                endpoint("Apple Watch", subtitle: "由 iPhone 同步", symbol: "applewatch")
            }.frame(maxWidth: .infinity).padding(18)
        }
    }

    private func endpoint(_ title: String, subtitle: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.blue)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
            MobilityMacStatusTile(
                title: "Mac 电池",
                value: store.status.battery.mobilityDisplayName,
                detail: "电池供电时到 \(store.policy.lowBatteryThresholdPercent)% 自动停止",
                symbol: batterySymbol,
                tint: batteryTint
            )
            MobilityMacStatusTile(
                title: "网络",
                value: store.status.network.mobilityDisplayName,
                detail: store.status.network.isConnected ? "Mac 当前网络路径可用" : "正在计算断网宽限",
                symbol: store.status.network.isConnected ? "network" : "wifi.slash",
                tint: store.status.network.isConnected ? .green : .red
            )
            MobilityMacStatusTile(
                title: "温度",
                value: store.status.thermalState.mobilityDisplayName,
                detail: store.status.thermalState == .nominal ? "系统热压力正常" : "严重或临界时自动停止",
                symbol: "thermometer.medium",
                tint: thermalTint
            )
            MobilityMacStatusTile(
                title: "Codex",
                value: store.status.codex.isRunning ? "正在运行" : "未检测到",
                detail: store.status.codex.detail ?? "按应用 bundle id 检测",
                symbol: store.status.codex.isRunning ? "terminal.fill" : "terminal",
                tint: store.status.codex.isRunning ? .green : .orange
            )
        }
    }

    private var pairingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("连接 iPhone", systemImage: "link").font(.title2.weight(.semibold))
                        Text("首次连接只需两步，以后会尝试自动重连。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(bluetoothLabel, systemImage: pairingState.isAdvertising ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.callout).foregroundStyle(pairingState.availability == .poweredOn ? Color.blue : Color.orange)
                }
                Divider()
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("1  在 iPhone 添加 Mac", systemImage: "iphone")
                            .font(.headline)
                        Text("打开随行 App 的“设备”页，点“添加 Mac”，在系统窗口中选择这台 Mac。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let error = pairingState.lastErrorMessage {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("2  输入安全配对码", systemImage: "number")
                            .font(.headline)
                        pairingStatus
                        Button(pairingState.isPairingWindowOpen ? "生成新配对码" : "开始配对") { onRegeneratePairingCode() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(pairingState.availability != .poweredOn)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if pairingState.availability != .poweredOn {
                    Text("请检查 Mac“系统设置 → 蓝牙”开关，以及“隐私与安全性 → 蓝牙”中的 Tidux助手权限。")
                        .font(.callout).foregroundStyle(.orange)
                }
            }.padding(16)
        }
    }

    private var bluetoothLabel: String {
        switch pairingState.availability {
        case .poweredOn: pairingState.isAdvertising ? "附近可发现" : "蓝牙已就绪"
        case .poweredOff: "Mac 蓝牙已关闭"
        case .unauthorized: "需要 Mac 蓝牙权限"
        case .unknown, .resetting: "正在准备蓝牙"
        case .unsupported: "蓝牙不可用"
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        if pairingState.isPairingWindowOpen {
            Text(pairingState.pairingCode)
                .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                .textSelection(.enabled)
            if let expiresAt = pairingState.pairingWindowExpiresAt {
                HStack(spacing: 0) {
                    Text("配对码有效期 ")
                    Text(expiresAt, style: .timer)
                    Text("，到期自动关闭。")
                }
                .foregroundStyle(.secondary)
            }
        } else if let lockedUntil = pairingState.pairingLockedUntil {
            Label("尝试过多，暂时锁定", systemImage: "lock.fill")
                .font(.headline)
            HStack(spacing: 0) {
                Text("可在 ")
                Text(lockedUntil, style: .timer)
                Text(" 后重试，或生成新码。")
            }
            .foregroundStyle(.secondary)
        } else {
            Label("尚未开放配对", systemImage: "lock.fill")
                .font(.headline)
            Text("点击下方按钮，生成有效 5 分钟的配对码。")
                .foregroundStyle(.secondary)
        }
    }

    private var pairedDevicesCard: some View {
        MobilityPanelCard(title: "已配对 iPhone", symbol: "person.crop.circle.badge.checkmark") {
            MobilityPairedDevicesView(
                devices: pairedDevices,
                errorMessage: pairingManagementErrorMessage,
                onRevoke: onRevokePairedDevice
            )
        }
    }

    private var batteryTint: Color {
        guard let level = store.status.battery.levelPercent else { return .secondary }
        if level <= store.policy.lowBatteryThresholdPercent { return .red }
        if level <= store.policy.lowBatteryThresholdPercent + 10 { return .orange }
        return .green
    }

    private var batterySymbol: String {
        if store.status.battery.isCharging { return "battery.100percent.bolt" }
        guard let level = store.status.battery.levelPercent else { return "battery.0percent" }
        if level > 75 { return "battery.100percent" }
        if level > 35 { return "battery.50percent" }
        return "battery.25percent"
    }

    private var thermalTint: Color {
        switch store.status.thermalState {
        case .nominal: .green
        case .fair: .orange
        case .serious, .critical: .red
        case .unknown: .secondary
        }
    }
}
