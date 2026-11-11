import CodexMobilityCore
import SwiftUI

struct MobilityModulePanelScaffold<Content: View>: View {
    let descriptor: MobilityModuleDescriptor
    let isSelected: Bool
    let isEnabled: Bool
    let experimentsEnabled: Bool
    let statusText: String
    let statusSymbol: String
    let statusTint: Color
    let content: Content

    init(
        descriptor: MobilityModuleDescriptor,
        isSelected: Bool,
        isEnabled: Bool,
        experimentsEnabled: Bool,
        statusText: String,
        statusSymbol: String,
        statusTint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.descriptor = descriptor
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.experimentsEnabled = experimentsEnabled
        self.statusText = statusText
        self.statusSymbol = statusSymbol
        self.statusTint = statusTint
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let accessMessage {
                    accessNotice(accessMessage)
                }
                content
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
        }
        .navigationTitle(descriptor.title)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: descriptor.symbolName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                .frame(width: 58, height: 58)
                .background(
                    (isEnabled ? Color.accentColor : Color.secondary).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(descriptor.title)
                        .font(.title2.weight(.bold))
                    moduleBadge
                }
                Text(descriptor.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            Label(statusText, systemImage: statusSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusTint)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(statusTint.opacity(0.1), in: Capsule())
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var moduleBadge: some View {
        Text(moduleStateText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(moduleStateTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(moduleStateTint.opacity(0.1), in: Capsule())
    }

    private var moduleStateText: String {
        if !descriptor.isAvailable { return "暂不可用" }
        if descriptor.tier == .experimental, !experimentsEnabled { return "Labs 未开启" }
        if !isSelected { return "模块已关闭" }
        return isEnabled ? "已开启" : "不可用"
    }

    private var moduleStateTint: Color {
        if isEnabled { return .green }
        if !descriptor.isAvailable { return .orange }
        return .secondary
    }

    private var accessMessage: String? {
        if !descriptor.isAvailable {
            return descriptor.unavailableReason ?? "当前构建尚未提供这个模块。"
        }
        if descriptor.tier == .experimental, !experimentsEnabled {
            return "这是实验模块。请先在设置的“模块”页打开“允许实验模块”，再明确开启此模块。"
        }
        if !isSelected {
            return "此模块当前已关闭。打开设置后可以重新启用，原有配置会被保留。"
        }
        return nil
    }

    private func accessNotice(_ message: String) -> some View {
        MobilityPanelCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: descriptor.isAvailable ? "lock.fill" : "exclamationmark.lock.fill")
                    .font(.title3)
                    .foregroundStyle(descriptor.isAvailable ? Color.secondary : .orange)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(moduleStateText)
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if descriptor.isAvailable {
                    SettingsLink {
                        Label("打开设置", systemImage: "gearshape")
                    }
                }
            }
        }
    }
}

struct MobilityPanelCard<Content: View>: View {
    let title: String?
    let symbol: String?
    let content: Content

    init(
        title: String? = nil,
        symbol: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Label(title, systemImage: symbol ?? "square.grid.2x2")
                    .font(.headline)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MobilityMacStatusTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }
}
