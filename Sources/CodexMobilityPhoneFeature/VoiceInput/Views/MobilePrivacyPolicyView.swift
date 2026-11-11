#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI

struct MobilePrivacyPolicyView: View {
    var body: some View {
        List {
            policySection(
                title: "麦克风与设备端转写",
                systemImage: "mic",
                text:
                    "Codex Watch Pet 只在你明确点击开始录音后访问麦克风。"
                    + "语音转写使用 Apple 的设备端 Speech 模型；"
                    + "Codex Watch Pet 不把录音或转写发送到自己的服务器。"
            )

            policySection(
                title: "本机保存",
                systemImage: "internaldrive",
                text:
                    "转写记录保存在这台 iPhone 的 App 容器中。"
                    + "开启“保留原始音频分段”时，音频也会保存在本机；"
                    + "关闭后只保存文字。你可以在历史记录中左滑删除单条记录；"
                    + "卸载 App 也会删除全部本机数据。"
            )

            policySection(
                title: "分享由你发起",
                systemImage: "square.and.arrow.up",
                text:
                    "只有你主动使用系统分享面板时，所选文字或诊断报告才会"
                    + "交给你选择的其他 App。可分享诊断不包含录音、转写正文"
                    + "或设备精确可用空间。"
            )

            policySection(
                title: "Apple 管理的模型",
                systemImage: "apple.logo",
                text:
                    "所需语音模型由 Apple 的系统框架检查、下载和管理。"
                    + "Codex Watch Pet 不保存 Apple 账户凭证，也不请求旧版"
                    + " SFSpeechRecognizer 的云端识别授权。"
            )

            Section {
                Text("更新日期：2026 年 7 月 31 日")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policySection(
        title: String,
        systemImage: String,
        text: String
    ) -> some View {
        Section {
            Text(text)
                .font(.body)
        } header: {
            Label(title, systemImage: systemImage)
        }
    }
}

#Preview {
    NavigationStack {
        MobilePrivacyPolicyView()
    }
}
#endif
