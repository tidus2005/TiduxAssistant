import CodexWatchCore
import SwiftUI

public struct WristReplySettingsView: View {
    @AppStorage(WristReplyPolicy.headphonesKey) private var headphones = false
    @AppStorage(WristReplyPolicy.speakerKey) private var speaker = false
    @AppStorage(WristReplyPolicy.conciseKey) private var concise = true
    public init() {}
    public var body: some View {
        Form {
            Toggle("精简显示", isOn: $concise)
            Toggle("耳机连接时自动朗读", isOn: $headphones)
            Toggle("允许手表自动外放", isOn: $speaker)
            Text("仅控制随行 App 内收到的回复。耳机断开即停止朗读；录音或 App 后台时不自动播报。官方 ChatGPT 的语音由它自己的设置控制。")
                .font(.caption2).foregroundStyle(.secondary)
        }.navigationTitle("显示与朗读")
    }
}
