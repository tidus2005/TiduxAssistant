import SwiftUI

struct MobilityCaffeinePanel: View {
    @ObservedObject var controller: MacCaffeineController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("咖啡因").font(.largeTitle.bold())
                        Text("让屏幕和电脑保持唤醒，安心运行桌面任务。")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                }
                GroupBox {
                    MobilityCaffeineControls(controller: controller)
                        .padding(12)
                }
                Text("咖啡因可独立开启，也会随移动办公自动开启。移动办公结束后，恢复此前独立开启的咖啡因剩余时间。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("手动锁屏、合盖或公司强制锁屏仍可能中断桌面操作。退出助手后咖啡因自动结束，下次打开时由你手动开启。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("咖啡因")
    }
}

struct MobilityCaffeineControls: View {
    @ObservedObject var controller: MacCaffeineController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { controller.isActive }, set: { controller.setEnabled($0) })) {
                Label("咖啡因 · 保持唤醒", systemImage: "cup.and.saucer.fill")
                    .font(.headline)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("caffeine-toggle")
            .disabled(controller.isManagedByMobileOffice)

            Picker("开启时长", selection: Binding(get: { controller.mode }, set: { controller.setMode($0) })) {
                Text("一直开启").tag(MacCaffeineDurationMode.indefinite)
                Text("定时关闭").tag(MacCaffeineDurationMode.timed)
            }
            .pickerStyle(.radioGroup)
            .disabled(controller.isActive)

            if controller.mode == .timed {
                Picker("时长", selection: Binding(
                    get: { controller.durationMinutes }, set: { controller.setDurationMinutes($0) }
                )) {
                    ForEach(MacCaffeineController.durationChoices, id: \.self) { minutes in
                        Text(minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时").tag(minutes)
                    }
                }
                .disabled(controller.isActive)
                .accessibilityIdentifier("caffeine-duration")
            }

            HStack {
                Text(controller.status)
                if let deadline = controller.expiresAt {
                    Spacer()
                    Text("剩余")
                    Text(deadline, style: .timer).monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(controller.isActive ? Color.green : .secondary)
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text(controller.isManagedByMobileOffice ? "由移动办公管理；关闭移动办公后可独立设置。" : controller.isActive ? "调整时长前请先关闭开关。" : "选好时长，再打开开关。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
