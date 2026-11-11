import CodexWatchCore
import SwiftUI
import WristArenaFeature

/// One glance, one primary action. Secondary tools live below task destinations.
public struct WatchRootView: View {
    @ObservedObject private var inbox: WatchStateInbox
    @State private var activeRoute: WatchCollaborationRoute?
    @State private var showsTools = false
    @State private var pendingRoute: WatchCollaborationRoute?
    @Environment(\.scenePhase) private var scenePhase

    public init(inbox: WatchStateInbox = WatchStateInbox.live) { self.inbox = inbox }
    private var connection: CompanionConnectionPresentation {
        CompanionConnectionPresentation(bridgeOnline: inbox.state.bridgeOnline, savedAt: inbox.state.generatedAt)
    }
    private var tasks: [TaskSnapshot] { inbox.state.snapshots.sortedByAttention() }
    private var approvals: Int { tasks.filter { $0.status == .waitingForApproval }.count }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    #if os(watchOS)
                    NavigationLink { WatchJournalView() } label: {
                        Label("实时记录", systemImage: "waveform.circle").font(.caption)
                    }.accessibilityIdentifier("journal.open")
                    #endif
                    HStack(spacing: 6) {
                        Circle().fill(connection.canSend ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(connection.title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }.accessibilityIdentifier("watch.connection")
                    Button { activeRoute = .init(component: .ask) } label: {
                        Label("快速提问", systemImage: "waveform").frame(maxWidth: .infinity, minHeight: 22)
                    }.buttonStyle(.borderedProminent).tint(.blue)
                        .accessibilityIdentifier("assistant.open")
                    VStack(spacing: 6) {
                        destination("任务进度", detail: "\(tasks.count)", symbol: "list.bullet.rectangle", component: .progress)
                        destination("待我审批", detail: approvals == 0 ? "暂无" : "\(approvals)", symbol: "checkmark.shield", component: .approvals)
                    }
                    if let task = tasks.first {
                        Button { activeRoute = .init(component: .ask, threadID: task.threadId) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.status.collaborationDisplayName).font(.caption2).foregroundStyle(.blue)
                                Text(task.title).font(.caption.weight(.semibold)).lineLimit(2)
                                Text(task.lastSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                        }.buttonStyle(.plain)
                    }
                    if inbox.queuedCommandCount > 0 {
                        Label("\(inbox.queuedCommandCount) 条待核实", systemImage: "clock.badge.exclamationmark")
                            .font(.caption2).foregroundStyle(.orange)
                        Button("检查发送记录") { showsTools = true }.font(.caption2)
                    }
                    Button { showsTools = true } label: {
                        Label("更多", systemImage: "ellipsis").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(.horizontal, 2)
            }
            .navigationTitle("随行")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { inbox.requestRefresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("刷新 Mac 状态")
                }
            }
            .sheet(isPresented: $showsTools, onDismiss: {
                if let pendingRoute { activeRoute = pendingRoute; self.pendingRoute = nil }
            }) {
                NavigationStack {
                    List {
                        NavigationLink("显示与朗读") { WristReplySettingsView() }
                        Button { pendingRoute = .init(component: .arena); showsTools = false } label: {
                            Label("表盘大作战", systemImage: "gamecontroller")
                        }
                        Button { pendingRoute = .init(component: .overview); showsTools = false } label: {
                            Label("添加表盘组件", systemImage: "applewatch")
                        }.accessibilityIdentifier("collaboration.guide")
                        NavigationLink {
                            List {
                                Text(connection.title).font(.headline)
                                Text(connection.detail).font(.caption)
                                Text("Mac → iPhone → 手表，任务与回复逐段同步。").font(.caption2).foregroundStyle(.secondary)
                                Button("刷新连接") { inbox.requestRefresh() }
                            }.navigationTitle("连接帮助")
                        } label: { Label("连接帮助", systemImage: "link") }
                        NavigationLink { ChatGPTHandoffWatchView(inbox: inbox) } label: {
                            Label("接续 ChatGPT", systemImage: "bubble.left.and.bubble.right")
                        }
                        if inbox.queuedCommandCount > 0 {
                            Section("发送记录") {
                                ForEach(inbox.queuedCommands) { record in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(record.command.payload["prompt"] ?? "待核实操作").font(.caption).lineLimit(2)
                                        if let error = record.lastError { Text(error).font(.caption2).foregroundStyle(.secondary) }
                                        Button("移除记录", role: .destructive) { inbox.discardQueuedCommand(id: record.id) }
                                    }
                                }
                                Button("重试非授权操作") { Task { await inbox.retryQueuedCommands() } }
                            }
                        }
                    }.navigationTitle("更多")
                }
            }
            .sheet(item: $activeRoute) { route in
                Group {
                    switch route.component {
                    case .arena: ArenaWatchView(attentionCount: inbox.state.unreadHighUrgencyCount) { activeRoute = nil }
                    case .ask:
                        if let thread = route.threadID { WatchVoiceAssistantView(inbox: inbox, threadID: thread) }
                        else { WatchQuickAskView(inbox: inbox) }
                    case .progress, .approvals:
                        WatchCollaborationTasksView(inbox: inbox, component: route.component, preferredThreadID: route.threadID)
                    case .overview:
                        WatchFaceGuideView { component in activeRoute = component == .overview ? nil : .init(component: component) }
                    }
                }.id(route.id)
            }
        }
        .onOpenURL { url in
            guard let route = WatchCollaborationRoute(url: url) else { return }
            activeRoute = route.component == .overview ? nil : route
            inbox.requestRefresh()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                inbox.requestRefresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func destination(_ title: String, detail: String, symbol: String, component: WatchCollaborationComponent) -> some View {
        Button { activeRoute = .init(component: component) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.blue).frame(width: 22)
                Text(title).font(.caption.weight(.medium))
                Spacer(minLength: 0)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 12).frame(minHeight: 44)
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}
#Preview { WatchRootView(inbox: .preview) }
