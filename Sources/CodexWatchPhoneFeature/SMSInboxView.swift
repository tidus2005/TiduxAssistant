#if os(iOS)
import CodexWatchCore
import SwiftUI

public struct SMSInboxView: View {
    @ObservedObject private var store = SMSInboxStore.shared
    @State private var showCodesOnly = false
    @State private var deleting: SavedSMS?
    @State private var issue: String?
    @Environment(\.scenePhase) private var phase
    public init() {}
    public var body: some View {
        List {
            Section {
                Text("由系统“收到信息”自动化传入。只记录启用后命中触发条件的新信息，不读取历史收件箱。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("只看验证码", isOn: $showCodesOnly)
                NavigationLink("转发到另一台手机") {
                    List {
                        Text("收到信息自动化设为“立即运行”。添加“保存并准备短信转发”，正文使用触发信息，发送人使用实际来源。")
                        Text("判断返回文本有任何值，再用系统“发送信息”发送到你自己的固定号码，并关闭“显示编写表单”。重复触发返回空文本，不发送。")
                        Text("有来源编号时按编号防重复；没有编号时，同一发送人和正文在 15 分钟内只准备一次。发送前即记录，发生超时或中断也不会自动连发；这种情况可能漏发，需要人工核对。")
                        Text("锁屏运行需在重启后至少解锁过一次，并已允许快捷指令运行。最终以真机锁屏收到短信后的结果为准。")
                    }.navigationTitle("短信转发")
                }
                NavigationLink("配置短信到 Gmail") {
                    List {
                        Text("1. 快捷指令 → 自动化 → 收到信息，配置实际支持的发送人或正文条件。")
                        Text("2. 添加“保存收到的短信”，正文和发送人选择本次触发的信息变量。")
                        Text("3. 添加系统“发送电子邮件”，正文用原短信，收件人固定为你的 Gmail；关闭编辑表单后先做测试。")
                        Text("4. 添加“标记短信已交给邮件”，记录编号选第 2 步输出。")
                        Text("只有人工测试邮件在 Gmail 收到后，才能确认出口可用。系统邮件排队不等于送达；锁屏与所有短信覆盖需分别验证。")
                    }.navigationTitle("短信自动化")
                }
                if let issue = issue ?? store.error { Text(issue).foregroundStyle(.orange) }
            }
            Section("短信记录 · \(store.messages.count)") {
                if store.messages.isEmpty { Text("暂无记录。可以先用人工测试内容验证自动化。") }
                ForEach(store.messages.filter { !showCodesOnly || $0.verificationCode != nil }) { message in
                    NavigationLink {
                        List {
                            Text(message.sender).font(.headline)
                            Text(message.receivedAt.formatted()).font(.caption)
                            if let code = message.verificationCode { Text("识别到验证码：\(code)").textSelection(.enabled) }
                            Text(message.body).textSelection(.enabled)
                            if message.smsForwardReservedAt != nil { Text("已准备短信转发 · 不自动重发 · 未确认送达") }
                            Text(message.mailHandedOffAt == nil ? "尚无邮件交接记录" : "已交给系统邮件，尚未核实 Gmail 送达")
                            Button("删除本地记录", role: .destructive) { deleting = message }
                        }.navigationTitle("短信详情")
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(message.sender); Spacer(); Text(message.receivedAt, style: .time).font(.caption) }
                            Text(message.verificationCode == nil ? "短信 · 点开查看内容" : "验证码 · ••••••")
                                .font(.subheadline)
                            Text(message.mailHandedOffAt == nil ? "已保存 · 未确认转发" : "已交给邮件 · 待确认送达")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle("短信与验证码")
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    do { try store.reload() } catch { issue = error.localizedDescription }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            .confirmationDialog("删除这条短信的本地副本？Gmail 中的邮件不会被删除。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除", role: .destructive) {
                    do { if let deleting { try store.delete(id: deleting.id) } } catch { issue = error.localizedDescription }
                    deleting = nil
                }
            }
    }
}
#endif
