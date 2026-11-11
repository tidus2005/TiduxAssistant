import CodexWatchCore
import CodexWatchSharedUI
import SwiftUI

public struct PhoneRootView: View {
    @ObservedObject private var store: CodexWatchStore
    private var onSettings: (() -> Void)?
    private var onConnect: (() -> Void)?
    @State private var showsComposer = false
    @State private var task: TaskSnapshot?

    public init(store: CodexWatchStore, onSettings: (() -> Void)? = nil, onConnect: (() -> Void)? = nil) {
        self.store = store
        self.onSettings = onSettings
        self.onConnect = onConnect
    }

    private var tasks: [TaskSnapshot] { store.state.snapshots.sortedByAttention() }
    private var needsAttention: [TaskSnapshot] { tasks.filter { $0.pendingRequest != nil } }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    connectionCard
                    Button { showsComposer = true } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "waveform").font(.title2)
                                .frame(width: 48, height: 48).background(.white.opacity(0.16), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text("有什么想交给 AI？").font(.headline)
                                Text("说一句话，开始一个任务").font(.subheadline).opacity(0.85)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "plus")
                        }
                        .padding(20).foregroundStyle(.white)
                        .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain).accessibilityIdentifier("collaboration.compose")

                    if !needsAttention.isEmpty {
                        taskSection("需要你", subtitle: "\(needsAttention.count) 项待处理", tasks: needsAttention)
                    }
                    if tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(store.state.bridgeOnline ? "准备好与你协作" : "连接后，从这里开始", systemImage: "sparkles")
                                .font(.title3.weight(.semibold))
                            Text(store.state.bridgeOnline ? "交代一个任务，在这里或手表上查看进展。需要你回答或审批时，会及时提醒。" : "先连接 Mac，再发送提问。连接恢复前，已有内容会保留。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            HStack(spacing: 20) {
                                Label("随时提问", systemImage: "bubble.left")
                                Label("掌握进展", systemImage: "chart.bar.xaxis")
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 24))
                    } else {
                        taskSection("最近任务", subtitle: "\(tasks.count) 个", tasks: tasks)
                    }
                    if let result = store.lastCommandResult {
                        Label(result.accepted ? "Mac 已接收，等待任务更新" : result.message,
                              systemImage: result.accepted ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(result.accepted ? Color.secondary : Color.orange)
                    }
                }.padding(20)
            }
            .background(Color.phoneCanvas)
            .navigationTitle("协作")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { onSettings?() } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("连接与通知设置")
                }
            }
            .refreshable { await store.refresh() }
            .onChange(of: store.state.snapshots) { _, snapshots in
                if let current = task { task = snapshots.first { $0.threadId == current.threadId } }
            }
            .sheet(isPresented: $showsComposer) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if !store.state.bridgeOnline { connectionCard }
                            ControlPanelView(snapshot: nil, onCommand: store.send)
                                .disabled(!store.state.bridgeOnline)
                        }.padding(20)
                    }.navigationTitle("新任务").navigationBarTitleDisplayModeInlineIfPhone()
                    .toolbar { Button("完成") { showsComposer = false } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(item: $task) { snapshot in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(snapshot.title).font(.title2.weight(.bold))
                            Label(snapshot.status.collaborationDisplayName, systemImage: snapshot.petMood.symbolName)
                                .font(.subheadline).foregroundStyle(.blue)
                            Text(snapshot.lastSummary).textSelection(.enabled)
                            if !store.state.bridgeOnline { connectionCard }
                            ControlPanelView(snapshot: snapshot, onCommand: store.send)
                                .disabled(!store.state.bridgeOnline)
                        }.padding(20)
                    }.navigationTitle("任务详情").navigationBarTitleDisplayModeInlineIfPhone()
                    .toolbar { Button("完成") { task = nil } }
                }
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: store.state.bridgeOnline ? "laptopcomputer" : "link")
                    .font(.title3).foregroundStyle(store.state.bridgeOnline ? .blue : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.state.bridgeOnline ? "Mac 已连接" : store.isRefreshing ? "正在连接 Mac…" : "连接你的 Mac")
                        .font(.headline)
                    Text(store.state.bridgeOnline ? "通过\(store.connectionStatus)同步" : "提问和任务进展需要先连接 Mac")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if store.isRefreshing { ProgressView().controlSize(.small) }
                else if store.state.bridgeOnline { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if !store.state.bridgeOnline {
                Button { onConnect?() } label: {
                    Label("连接 Mac", systemImage: "laptopcomputer.and.iphone").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                if onConnect == nil { Text("请到“设备”页添加 Mac。").font(.caption).foregroundStyle(.secondary) }
                if let error = store.errorMessage {
                    DisclosureGroup("连接诊断") { Text(error).font(.caption).foregroundStyle(.secondary) }
                        .font(.caption)
                }
            }
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 24))
    }

    private func taskSection(_ title: String, subtitle: String, tasks: [TaskSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.title3.weight(.bold)); Spacer(); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(tasks) { snapshot in
                    Button { task = snapshot; store.selectedSnapshot = snapshot } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: snapshot.petMood.symbolName).font(.title3).foregroundStyle(.blue).frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(snapshot.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                if (snapshot.pendingRequest?.summary ?? snapshot.lastSummary) != snapshot.title {
                                    Text(snapshot.pendingRequest?.summary ?? snapshot.lastSummary)
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text(snapshot.status.collaborationDisplayName).font(.caption.weight(.medium)).foregroundStyle(.blue)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if snapshot.id != tasks.last?.id { Divider().padding(.leading, 56) }
                }
            }.background(.background, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

private extension Color {
    static var phoneCanvas: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color.secondary.opacity(0.06)
        #endif
    }
}
private extension View {
    @ViewBuilder func navigationBarTitleDisplayModeInlineIfPhone() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#Preview { PhoneRootView(store: .preview) }
