import CodexWatchCore
import SwiftUI
import WidgetKit

public struct CodexCollaborationWidget: Widget {
    private let component: WatchCollaborationComponent
    public init() { component = .ask }
    public init(component: WatchCollaborationComponent) { self.component = component }

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: component.widgetKind, provider: CodexWatchWidgetProvider()) { entry in
            WatchCollaborationWidgetView(component: component, entry: entry)
        }
        .configurationDisplayName(component.title)
        .description(component.detail)
        .supportedFamilies(CodexWatchPetWidget.supportedFamilies)
    }
}

#if os(watchOS)
#Preview("快速提问 · 圆形", as: .accessoryCircular) {
    CodexCollaborationWidget(component: .ask)
} timeline: {
    CodexWatchWidgetEntry(date: Date(), snapshot: .sampleActive, highUrgencyCount: 0,
                         bridgeOnline: true, savedAt: Date())
}

#Preview("待审批 · 长方形", as: .accessoryRectangular) {
    CodexCollaborationWidget(component: .approvals)
} timeline: {
    CodexWatchWidgetEntry(date: Date(), snapshot: .sampleApproval, highUrgencyCount: 1,
                         bridgeOnline: true, savedAt: Date())
}
#endif

struct WatchCollaborationWidgetView: View {
    let component: WatchCollaborationComponent
    let entry: CodexWatchWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var summary: WatchCollaborationSummary {
        WatchCollaborationSummary(snapshots: entry.snapshots, bridgeOnline: entry.bridgeOnline,
                                  savedAt: entry.savedAt, now: entry.date)
    }
    private var accent: Color {
        guard renderingMode == .fullColor else { return .primary }
        switch component {
        case .overview, .ask: return .cyan
        case .progress: return .indigo
        case .approvals: return summary.approvalTasks.isEmpty ? .green : .orange
        case .arena: return .mint
        }
    }
    private var metric: String {
        switch component {
        case .ask: "提问"
        case .arena: "开玩"
        case .approvals: "\(summary.approvalTasks.count)"
        case .overview: "\(summary.runningTasks.count)"
        case .progress:
            summary.runningTasks.isEmpty ? (summary.progressTask?.status.collaborationDisplayName ?? "—") : "\(summary.runningTasks.count)"
        }
    }
    private var headline: String {
        switch component {
        case .ask: "说一句，交给 AI"
        case .arena: "等 AI 时，来一局"
        case .approvals: summary.approvalTasks.first?.title ?? "暂无待审批"
        case .progress: summary.progressTask?.title ?? "暂无任务"
        case .overview: "\(summary.runningTasks.count) 运行 · \(summary.approvalTasks.count) 待审批"
        }
    }
    private var detail: String {
        switch component {
        case .ask: "听写后检查并发送给 Codex"
        case .arena: summary.approvalTasks.isEmpty ? "点按进入表盘大作战" : "\(summary.approvalTasks.count) 项审批待处理"
        case .approvals: summary.approvalTasks.first?.pendingRequest?.summary ?? "点按查看最新请求"
        case .progress:
            if let task = summary.progressTask { "\(task.status.collaborationDisplayName) · \(task.lastSummary)" }
            else { "点按查看任务列表" }
        case .overview: summary.inputTasks.isEmpty ? "点按打开协作中心" : "\(summary.inputTasks.count) 项需要你回答"
        }
    }
    private var label: String {
        switch component {
        case .overview: "运行中"
        case .progress: summary.runningTasks.isEmpty ? "任务状态" : "运行中"
        case .approvals: "待审批"
        case .ask: "快速提问"
        case .arena: "大作战"
        }
    }
    private var isStateWidget: Bool { component != .ask && component != .arena }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryInline:
                Label(isStateWidget ? "\(label) \(metric) · \(summary.connectionLabel)" : component.title,
                      systemImage: component.symbolName)
            #if os(watchOS)
            case .accessoryCorner:
                Image(systemName: component.symbolName)
                    .font(.title2.weight(.semibold))
                    .widgetAccentable()
                    .widgetLabel {
                        Text(isStateWidget && (summary.freshness.isStale || !summary.bridgeOnline) ? "待更新" : "\(metric) \(label)")
                    }
            #endif
            default: rectangular
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(summary.route(for: component).url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(component.title)，\(headline)，\(isStateWidget ? summary.connectionLabel : detail)")
        .privacySensitive(isStateWidget)
    }

    private var circular: some View {
        ZStack(alignment: .topTrailing) {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: component.symbolName).font(.caption.weight(.semibold)).widgetAccentable()
                Text(isStateWidget && summary.freshness.status == .noData ? "—" : metric)
                    .font(.system(size: isStateWidget ? 22 : 15, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7).lineLimit(1)
                Text(isStateWidget && (summary.freshness.isStale || !summary.bridgeOnline) ? "待更新" : label)
                    .font(.system(size: 8, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }.foregroundStyle(accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if component == .overview, !summary.approvalTasks.isEmpty {
                Text(summary.approvalTasks.count > 9 ? "9+" : "\(summary.approvalTasks.count)")
                    .font(.system(size: 9, weight: .bold))
                    .padding(3).background(.orange, in: Circle()).foregroundStyle(.black)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(component.title, systemImage: component.symbolName)
                .font(.caption2.weight(.bold)).foregroundStyle(accent).widgetAccentable()
            Text(headline).font(.caption.weight(.semibold)).lineLimit(1).privacySensitive()
            Text(detail).font(.caption2).lineLimit(1).privacySensitive()
            if isStateWidget {
                Text(summary.connectionLabel).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
