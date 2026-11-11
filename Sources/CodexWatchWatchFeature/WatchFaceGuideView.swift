import CodexWatchCore
import SwiftUI

struct WatchFaceGuideView: View {
    let onOpen: (WatchCollaborationComponent) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("AI 协作表盘") {
                    Text("长按系统表盘 → 编辑 → 复杂功能，选择随行助手的小组件。")
                        .font(.caption)
                    Text("圆形、长方形、单行、角落组件可按表盘槽位组合。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("可添加的组件") {
                    ForEach(WatchCollaborationComponent.allCases) { component in
                        Button { onOpen(component) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(component.title, systemImage: component.symbolName)
                                Text(component.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("推荐组合") {
                    Text("大位置放任务进度，小位置放快速提问、待我审批和大作战。")
                        .font(.caption)
                    Text("表盘更新由系统调度；点按可打开 App 刷新。过期缓存会标注待更新。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.navigationTitle("表盘组件")
        }
    }
}
