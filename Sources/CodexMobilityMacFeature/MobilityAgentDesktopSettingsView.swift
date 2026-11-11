import SwiftUI

struct MobilityAgentDesktopSettingsView: View {
    @ObservedObject var controller: MacAgentDesktopController

    var body: some View {
        Toggle("合盖不主动锁屏（AI 桌面操作模式）", isOn: Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
        ))
        .disabled(controller.isActive)
        Text("在定时随行期间暂停助手的合盖熄屏和锁屏，并防止显示器空闲休眠。关闭随行或到期会释放保活、恢复助手的合盖规则。请在启动随行前选择此选项。")
            .font(.caption)
            .foregroundStyle(.secondary)
        if controller.isEnabled {
            Text("系统密码策略由你控制。选择“1 小时后”等等待时间时，系统仍可能在熄屏满该时间后锁定，本模式不会延长它。选择“永不”会全局关闭熄屏密码保护，任何能接触电脑的人都可能访问桌面；随行结束不会自动恢复该系统设置。")
                .font(.caption)
                .foregroundStyle(.orange)
            HStack {
                Button("打开系统锁屏设置…") { controller.openSystemSettings() }
                Button("已完成设置，重新检查") {
                    Task { await controller.checkReadiness() }
                }
            }
            Text(controller.status)
                .font(.caption)
                .foregroundStyle(controller.needsAttention ? Color.orange : Color.secondary)
                .textSelection(.enabled)
            Text("不会自动解锁已有锁屏。系统熄屏、手动锁定、企业策略或无可用显示器仍可能中断 Computer Use；浏览器后台访问与桌面点击需分别验证。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
