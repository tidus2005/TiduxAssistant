import CodexWatchCore
import CodexWatchSharedUI
import SwiftUI

struct WatchCollaborationTasksView: View {
    @ObservedObject var inbox: WatchStateInbox
    let component: WatchCollaborationComponent
    let preferredThreadID: String?
    @Environment(\.scenePhase) private var scenePhase

    private var summary: WatchCollaborationSummary {
        WatchCollaborationSummary(snapshots: inbox.state.snapshots, bridgeOnline: inbox.state.bridgeOnline,
                                  savedAt: inbox.lastReceivedAt)
    }
    private var tasks: [TaskSnapshot] {
        let candidates = component == .approvals ? summary.approvalTasks : summary.snapshots
        guard let preferredThreadID,
              let selected = candidates.first(where: { $0.threadId == preferredThreadID }) else { return candidates }
        return [selected] + candidates.filter { $0.threadId != preferredThreadID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(CompanionConnectionPresentation(bridgeOnline: inbox.state.bridgeOnline, savedAt: inbox.state.generatedAt).title).font(.caption2).foregroundStyle(.secondary)
                    if component == .approvals {
                        Text("\(tasks.count) 项待审批").font(.headline)
                        Text("打开具体请求，检查后再同意或拒绝。").font(.caption2)
                    } else {
                        Text("\(summary.runningTasks.count) 运行 · \(summary.approvalTasks.count) 待审批")
                            .font(.caption2)
                    }
                }
                if tasks.isEmpty {
                    Text(component == .approvals ? "暂无待审批请求" : "暂无同步任务")
                    Text(inbox.state.bridgeOnline ? "新的任务会显示在这里。" : "请在 iPhone“设备”页连接 Mac。").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in
                    NavigationLink {
                        WatchVoiceAssistantView(inbox: inbox, threadID: task.threadId)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(task.title, systemImage: task.petMood.symbolName).lineLimit(2)
                            Text(task.status.collaborationDisplayName).font(.caption2).foregroundStyle(.cyan)
                            Text(task.pendingRequest?.summary ?? task.lastSummary)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .accessibilityIdentifier("collaboration.task.\(task.threadId)")
                }
                Button("刷新状态") { inbox.requestRefresh() }
            }
            .navigationTitle(component.title)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    inbox.requestRefresh()
                    try? await Task.sleep(for: .seconds(8))
                }
            }
        }
    }
}
