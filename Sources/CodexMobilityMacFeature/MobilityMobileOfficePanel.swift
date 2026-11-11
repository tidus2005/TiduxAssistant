import CodexMobilityCore
import SwiftUI

/// A local-only composition of the existing leased power, network recovery and
/// desktop protections. It does not grant any new remote execution authority.
struct MobilityMobileOfficePanel: View {
    @ObservedObject var session: MacClosedLidSessionController
    @ObservedObject var hotspot: MacHotspotAutomationStore
    @ObservedObject var store: MacMobilityStore
    @ObservedObject var power: MacSystemPowerPolicyStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 18) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("移动办公模式").font(.largeTitle.weight(.bold))
                        Text("开启模式，再合上电脑；可用 Wi-Fi 优先，手机热点备用。")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("移动办公模式", isOn: Binding(
                        get: { session.isToggleOn },
                        set: { enabled in
                            Task { await session.setEnabled(enabled, mobileOffice: true) }
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.large)
                    .disabled(!session.isToggleEnabled || session.phase == .stopping)
                    .padding(.top, 12)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            if session.isBusy { ProgressView().controlSize(.small) }
                            Label(phaseTitle, systemImage: session.phase == .active ? "checkmark.circle" : "power")
                                .font(.headline)
                            Spacer()
                            if session.phase == .active, let deadline = session.expiresAt {
                                Text("剩余")
                                Text(deadline, style: .timer).monospacedDigit()
                            } else if session.phase == .active && session.isIndefinite {
                                Text("无限 · 手动结束").foregroundStyle(.secondary)
                            }
                        }
                        Text(session.statusMessage).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if session.phase == .failed && session.requiresTemporaryOverrideRecovery {
                            Button("恢复上次会话配置") {
                                Task { await session.retrySystemPolicyRecovery() }
                            }.disabled(session.isBusy)
                        }
                        Divider()
                        Picker("本次办公时长", selection: Binding(
                            get: { Int(session.selectedDuration / 60) },
                            set: { session.setDuration(Double($0) * 60) }
                        )) {
                            ForEach(MacClosedLidSessionController.durationMinutesChoices, id: \.self) { minutes in
                                Text(MacClosedLidSessionController.durationLabel(seconds: Double(minutes) * 60))
                                    .tag(minutes)
                            }
                        }.disabled(!session.canEditDuration)
                        Text("咖啡因默认随本模式开启，时长与本次办公一致。选择无限后，持续到手动关闭；到期或关闭后恢复启动前的合盖策略；断网和普通低电量阈值不会结束本次会话。过热、耗尽电量或系统关机会中断运行。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }

                if let caffeine = session.caffeine {
                    MobileOfficeCaffeineStatus(controller: caffeine)
                }
                GroupBox("运行保障") {
                    VStack(alignment: .leading, spacing: 14) {
                        statusRow("合盖续跑", symbol: "laptopcomputer",
                            detail: power.snapshot.sleepDisabled == true
                                ? "系统合盖运行已开启" : "开启模式时申请限时系统合盖运行",
                            ready: session.phase == .active && power.snapshot.sleepDisabled == true)
                        Divider()
                        statusRow("Wi-Fi 与备用热点", symbol: "personalhotspot",
                            detail: hotspot.statusText,
                            ready: session.phase == .active && hotspot.snapshot.isNetworkAvailable)
                        if session.phase == .active, let issue = hotspot.lastConnectionErrorMessage {
                            Text("启动热点连接尚未确认：" + issue + " 当前可用 Wi-Fi 会继续保留，断线后继续重连热点。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Text("备用热点").foregroundStyle(.secondary)
                            TextField("已保存的手机热点名称", text: Binding(
                                get: { hotspot.preferredSSIDs.first ?? "" },
                                set: { hotspot.updatePreferredSSIDs(text: $0) }
                            )).textFieldStyle(.roundedBorder)
                                .disabled(!session.canEditDuration)
                        }
                        HotspotWiFiPermissionButton()
                        Divider()
                        if let desktop = session.agentDesktop {
                            MobileOfficeDesktopProtectionView(controller: desktop, session: session)
                        } else {
                            statusRow("后台运行", symbol: "display",
                                detail: "未配置桌面保活；熄屏或锁屏后不能保证 Computer Use。",
                                ready: false)
                        }
                        Divider()
                        statusRow("Mac 远控服务", symbol: "iphone.radiowaves.left.and.right",
                            detail: session.remoteControlReadiness.displayName,
                            ready: session.phase == .active && session.remoteControlReadiness.isConnected)
                    }.padding(10)
                }

                GroupBox("途中怎样运行") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("网络中断后持续重试热点；已有可用网络时保持连接，避免反复切换。", systemImage: "arrow.triangle.2.circlepath")
                        Label("沿用现有 VPN、代理和 DNS；网站登录与公司网络权限继续由原有配置提供。", systemImage: "network.badge.shield.half.filled")
                        Label("启用 AI 桌面操作时，合盖只调暗内屏；关闭该选项时，合盖熄屏省电。系统密码策略保持不变。", systemImage: "desktopcomputer")
                        Label("电脑需要保持通风。请勿在密闭电脑包中持续高负载运行。", systemImage: "thermometer.medium")
                        Text("系统合盖运行与桌面操作是两项能力。Computer Use 仍依赖可截图的显示会话，浏览器后台访问也依赖网站登录和网络；合盖效果需在本机实测。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).padding(10)
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("移动办公")
        .task {
            store.refreshNow()
            power.refresh()
            await session.agentDesktop?.checkReadiness(preservingImmediateLockPolicy: true)
        }
    }

    private var phaseTitle: String {
        switch session.phase {
        case .off: "准备出发"
        case .preparing: "正在准备移动办公"
        case .active: "移动办公运行中"
        case .stopping: "正在恢复配置"
        case .failed: "需要处理后重试"
        }
    }

    private func statusRow(_ title: String, symbol: String, detail: String, ready: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(ready ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }
}

private struct MobileOfficeCaffeineStatus: View {
    @ObservedObject var controller: MacCaffeineController
    var body: some View {
        GroupBox {
            Label(controller.isActive ? controller.status : "咖啡因 · 开启移动办公时自动启用",
                  systemImage: "cup.and.saucer.fill")
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            if let error = controller.errorMessage { Text(error).foregroundStyle(.orange) }
        }
    }
}

private struct MobileOfficeDesktopProtectionView: View {
    @ObservedObject var controller: MacAgentDesktopController
    @ObservedObject var session: MacClosedLidSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("合盖保留 AI 桌面操作", isOn: Binding(
                get: { controller.isEnabled },
                set: { controller.setEnabled($0) }
            ))
            .disabled(!session.canEditDuration)
            Text(controller.isEnabled
                 ? "合盖调暗内屏，暂停助手主动熄屏和锁屏；不会自动解锁或修改系统密码设置。"
                 : "仅保持后台任务；合盖时熄屏，Computer Use 可能因锁屏中断。")
                .font(.callout).foregroundStyle(.secondary)
            if controller.isEnabled {
                Label(controller.isActive ? controller.status : "桌面保活未运行；需要在解锁状态重新启动本模式。",
                      systemImage: controller.isActive ? "display" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(controller.isActive && !controller.needsAttention ? Color.secondary : Color.orange)
            }
        }
    }
}
