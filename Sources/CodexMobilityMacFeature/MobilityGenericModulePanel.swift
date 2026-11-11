import CodexMobilityCore
import SwiftUI

struct MobilityGenericModulePanel: View {
    let descriptor: MobilityModuleDescriptor
    let isSelected: Bool
    let isEnabled: Bool
    let experimentsEnabled: Bool

    var body: some View {
        MobilityModulePanelScaffold(
            descriptor: descriptor,
            isSelected: isSelected,
            isEnabled: isEnabled,
            experimentsEnabled: experimentsEnabled,
            statusText: isEnabled ? "模块已加载" : "模块未运行",
            statusSymbol: isEnabled ? "checkmark.circle.fill" : "puzzlepiece.extension",
            statusTint: isEnabled ? .green : .secondary
        ) {
            MobilityPanelCard(title: "模块能力", symbol: "shippingbox") {
                if descriptor.capabilities.isEmpty {
                    Text("此模块没有声明可执行 capability。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(descriptor.capabilities.sorted(), id: \.rawValue) { capability in
                        Label(capability.rawValue, systemImage: "checkmark.seal")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            MobilityPanelCard(title: "通用 Panel", symbol: "rectangle.3.group") {
                Text("配置加入的模块会自动获得这个 Tab。若需要专用控件，发行版还需把对应 Panel 与已编译、已签名的 adapter 一起注册；JSON 配置本身不会加载外部代码。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
