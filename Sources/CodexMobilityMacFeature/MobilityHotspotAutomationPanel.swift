import CodexMobilityCore
import SwiftUI

struct MobilityHotspotAutomationPanel: View {
    @ObservedObject private var store: MacHotspotAutomationStore
    private let descriptor: MobilityModuleDescriptor
    private let isSelected: Bool
    private let isEnabled: Bool
    private let experimentsEnabled: Bool

    init(
        store: MacHotspotAutomationStore,
        descriptor: MobilityModuleDescriptor,
        isSelected: Bool,
        isEnabled: Bool,
        experimentsEnabled: Bool
    ) {
        self.store = store
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
            statusText: store.statusText,
            statusSymbol: statusSymbol,
            statusTint: statusColor
        ) {
            MobilityPanelCard(title: "首选热点", symbol: "personalhotspot") {
                HotspotAutomationSettingsSection(store: store)
                    .disabled(!isEnabled)
            }

            MobilityPanelCard(title: "工作方式", symbol: "bolt.horizontal.circle") {
                Label("结合 Wi-Fi 路径事件与实际互联网检测，识别已连接但无法访问", systemImage: "wave.3.right.circle")
                Label("连续失败后优先恢复目标热点，切网期间保留 VPN、代理和 DNS 策略", systemImage: "clock.arrow.2.circlepath")
                Label("连接凭据由系统提供，App 不保存密码", systemImage: "key.fill")
                Text("开启随行会话后，会尝试后台唤醒并重连已配置的 iPhone 热点。手机回来后将继续重试；需提前允许定位权限，以便 macOS 识别并连接目标 Wi-Fi。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusSymbol: String {
        switch store.snapshot.phase {
        case .monitoring where store.snapshot.isNetworkAvailable:
            "wifi"
        case .reconnecting, .waitingForConnectivity:
            "arrow.clockwise"
        case .backingOff:
            "exclamationmark.arrow.triangle.2.circlepath"
        default:
            "personalhotspot"
        }
    }

    private var statusColor: Color {
        switch store.snapshot.phase {
        case .monitoring where store.snapshot.isNetworkAvailable:
            .green
        case .backingOff:
            .orange
        default:
            .secondary
        }
    }
}

struct HotspotAutomationSettingsSection: View {
    @ObservedObject var store: MacHotspotAutomationStore
    @State private var preferredSSIDsText: String

    init(store: MacHotspotAutomationStore) {
        self.store = store
        _preferredSSIDsText = State(initialValue: store.preferredSSIDsText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                "iPhone 热点名称（每行一个）",
                text: $preferredSSIDsText,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)

            HStack {
                Label(store.statusText, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Spacer()
                Button("保存热点名称", action: save)
                    .controlSize(.small)
            }

            if let lastGoodSSID = store.snapshot.lastGoodSSID {
                LabeledContent("最近可用网络", value: lastGoodSSID)
                    .font(.caption)
            }
            if let attemptedSSID = store.snapshot.lastAttemptedSSID {
                LabeledContent("最近尝试", value: attemptedSSID)
                    .font(.caption)
            }
            if let nextActionAt = store.snapshot.nextActionAt {
                HStack(spacing: 4) {
                    Text("下次低频重试")
                    Text(nextActionAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HotspotWiFiPermissionButton()

            Text("只会连接已配置且 macOS 已保存的热点；系统返回的连接凭据仅在本次连接内存中使用，App 不保存或记录密码。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: store.preferredSSIDs) { _, values in
            preferredSSIDsText = values.joined(separator: "\n")
        }
    }

    private var statusSymbol: String {
        switch store.snapshot.phase {
        case .monitoring where store.snapshot.isNetworkAvailable:
            "wifi"
        case .reconnecting, .waitingForConnectivity:
            "arrow.clockwise"
        case .backingOff:
            "exclamationmark.arrow.triangle.2.circlepath"
        default:
            "personalhotspot"
        }
    }

    private var statusColor: Color {
        switch store.snapshot.phase {
        case .monitoring where store.snapshot.isNetworkAvailable:
            .green
        case .backingOff:
            .orange
        default:
            .secondary
        }
    }

    private func save() {
        store.updatePreferredSSIDs(text: preferredSSIDsText)
    }
}
