#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(UIKit)
import SwiftUI
import UIKit

@MainActor
public struct MobileInputMethodSetupView: View {
    @Environment(\.openURL) private var openURL
    @State private var testText = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("手机输入法注册与测试", systemImage: "keyboard")
                .font(.headline)

            Text("安装包含 Codex 输入法扩展的版本后，需要由你在 iOS 系统设置中手动启用。Apple 不允许 App 自动替你添加或切换键盘。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                setupStep(1, "打开“设置 > 通用 > 键盘 > 键盘”。")
                setupStep(2, "轻点“添加新键盘”，选择“Codex 输入法”（Codex Watch Pet）。")
                setupStep(3, "回到下方测试框，长按地球键切换输入法。")
            }

            Button {
                guard let settingsURL = URL(
                    string: UIApplication.openSettingsURLString
                ) else {
                    return
                }
                openURL(settingsURL)
            } label: {
                Label("打开系统设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("系统只允许打开设置入口，仍需手动进入键盘页面")

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("输入法测试框")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !testText.isEmpty {
                        Button("清空") {
                            testText = ""
                        }
                        .font(.caption)
                    }
                }

                TextEditor(text: $testText)
                    .frame(minHeight: 110)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(alignment: .topLeading) {
                        if testText.isEmpty {
                            Text("在这里测试刚启用的输入法……")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("输入法测试框")
                    .accessibilityIdentifier("mobile.inputMethod.testField")
            }

            Label(
                "无需打开“允许完全访问”。测试文字只保留在当前页面，不会作为截图注释导出或发送到 Mac。",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityIdentifier("mobile.inputMethod.setup")
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(number) 步，\(text)")
    }
}

#Preview("输入法注册") {
    ScrollView {
        MobileInputMethodSetupView()
            .padding()
    }
}
#endif
