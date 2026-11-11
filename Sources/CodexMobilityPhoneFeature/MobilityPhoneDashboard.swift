import CodexMobilityCore
import Foundation
import SwiftUI

extension MobilityPhoneStore {
    @discardableResult
    public func performDashboard(_ action: CompanionDashboardAction) async -> Bool {
        guard !dashboardBusy else { return false }
        dashboardBusy = true
        defer { dashboardBusy = false }
        do {
            let response = try await requestCollaboration(CollaborationRequest(method: .companion,
                body: try JSONEncoder().encode(action)), timeout: .seconds(action == .snapshot ? 12 : 60))
            guard response.status == 200 else {
                throw CollaborationTransportError.rejected("请先更新 Mac 端随行助手以使用远程控制台。")
            }
            let reply = try JSONDecoder().decode(CompanionDashboardReply.self, from: response.decodedBody())
            dashboard = reply.snapshot
            if action != .snapshot || !reply.ok { dashboardMessage = reply.message }
            dashboardDidRefresh?(reply.snapshot)
            return reply.ok
        } catch {
            dashboardMessage = error.localizedDescription
            return false
        }
    }
}

@MainActor
public struct MobilityPhoneDashboardView: View {
    @ObservedObject var store: MobilityPhoneStore
    @State private var duration = 120
    @State private var caffeineMinutes = 240
    @State private var hotspot = ""
    @State private var confirmsMacMicrophone = false
    public init(store: MobilityPhoneStore) { self.store = store }

    public var body: some View {
        Form {
            if let state = store.dashboard {
                Section("移动办公") {
                    Toggle("移动办公模式", isOn: Binding(get: { state.mobileOfficeOn }, set: {
                        run(.mobileOffice(enabled: $0, durationMinutes: duration))
                    }))
                    Picker("本次时长", selection: $duration) {
                        ForEach(Array(stride(from: 15, through: 240, by: 15)), id: \.self) { value in
                            Text("\(value) 分钟").tag(value)
                        }
                    }.disabled(state.mobileOfficeOn)
                    if let expires = state.expiresAt, state.mobileOfficeOn {
                        LabeledContent("剩余") { Text(expires, style: .timer).monospacedDigit() }
                    }
                    Text(state.mobileOfficeStatus).font(.caption).foregroundStyle(.secondary)
                    Toggle("基础合盖运行", isOn: Binding(get: { state.baselineOn }, set: { run(.baselineClosedLid($0)) }))
                        .disabled(!state.baselineCanChange)
                }
                Section {
                    Toggle("保持唤醒", isOn: Binding(get: { state.caffeineOn }, set: {
                        run(.caffeine(enabled: $0, durationMinutes: caffeineMinutes == 0 ? nil : caffeineMinutes))
                    }))
                    Picker("唤醒时长", selection: $caffeineMinutes) {
                        Text("直到手动关闭").tag(0)
                        ForEach([15, 30, 60, 120, 240, 480, 720, 1440], id: \.self) {
                            Text("\($0) 分钟").tag($0)
                        }
                    }.disabled(state.caffeineOn)
                    Text(state.caffeineStatus).font(.caption).foregroundStyle(.secondary)
                } header: { Text("咖啡因") } footer: {
                    Text("保持系统与显示器唤醒；合盖续跑请使用移动办公。不会修改密码或锁屏策略。")
                }
                Section("热点连接") {
                    TextField("已保存的手机热点名称", text: $hotspot)
                    Button("保存热点名称") { run(.setHotspotName(hotspot)) }.disabled(state.mobileOfficeOn)
                    Button("让 Mac 连接手机热点") { run(.connectHotspot) }
                    Text(state.hotspotStatus).font(.caption).foregroundStyle(.secondary)
                    Text("请在 iPhone 设置中打开个人热点。保持 VPN、节点和代理规则不变。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Mac 语音输入") {
                    Button(state.voiceRecording ? "停止 Mac 听写" : "开始 Mac 听写") {
                        if state.voiceRecording { run(.toggleMacDictation) }
                        else { confirmsMacMicrophone = true }
                    }
                    Text(state.voiceStatus).font(.caption).foregroundStyle(.secondary)
                    Text("这里控制 Mac 麦克风；用手机说话请进入底部“听写”。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Mac 功能模块") {
                    ForEach(state.modules) { module in
                        Toggle(module.title, isOn: Binding(get: { module.enabled }, set: {
                            run(.setModule(id: module.id, enabled: $0))
                        })).disabled(!module.canChange)
                    }
                }
                Section("Mac 上打开") {
                    Button("打开接收文件夹") { run(.revealInbox) }
                    Text(state.inboxPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("打开 Mac 仪表盘") { run(.showDashboard) }
                }
                Section {
                    Text("系统权限、接收目录选择、密码保护与设备解绑需在 Mac 本机确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Mac 回读时间") { Text(state.observedAt, style: .time) }
                }
            } else {
                ContentUnavailableView("连接 Mac 控制台", systemImage: "laptopcomputer.and.iphone",
                    description: Text("完成蓝牙配对后，可在这里管理 Mac 顶部菜单中的运行功能。"))
                Button("重新连接") { run(.snapshot) }
            }
            if let message = store.dashboardMessage {
                Section("操作回执") { Text(message).font(.subheadline) }
            }
        }
        .disabled(store.dashboardBusy)
        .overlay { if store.dashboardBusy { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
        .navigationTitle("Mac 控制台")
        .toolbar { Button("刷新") { run(.snapshot) } }
        .confirmationDialog("在 Mac 开始录音？", isPresented: $confirmsMacMicrophone, titleVisibility: .visible) {
            Button("开始 Mac 听写") { run(.toggleMacDictation) }
        } message: { Text("使用 Mac 的麦克风，转写内容会输入 Mac 当前文本框。") }
        .task {
            await store.performDashboard(.snapshot)
            if let state = store.dashboard { duration = state.durationMinutes; hotspot = state.hotspotName }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
                await store.performDashboard(.snapshot)
            }
        }
    }
    private func run(_ action: CompanionDashboardAction) { Task { await store.performDashboard(action) } }
}
