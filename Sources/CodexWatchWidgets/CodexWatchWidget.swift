import CodexWatchCore
import SwiftUI
import WidgetKit

public struct CodexWatchWidgetEntry: TimelineEntry {
    public var date: Date
    public var snapshot: TaskSnapshot?
    public var highUrgencyCount: Int
    public var bridgeOnline: Bool
    public var savedAt: Date?
    public var snapshots: [TaskSnapshot]

    public init(
        date: Date,
        snapshot: TaskSnapshot?,
        highUrgencyCount: Int,
        bridgeOnline: Bool,
        savedAt: Date?,
        snapshots: [TaskSnapshot]? = nil
    ) {
        self.date = date
        self.snapshot = snapshot
        self.highUrgencyCount = highUrgencyCount
        self.bridgeOnline = bridgeOnline
        self.savedAt = savedAt
        self.snapshots = snapshots ?? snapshot.map { [$0] } ?? []
    }
}

public struct CodexWatchWidgetProvider: TimelineProvider {
    private let store: WidgetStateStore

    public init(store: WidgetStateStore = WidgetStateStore()) {
        self.store = store
    }

    public func placeholder(in context: Context) -> CodexWatchWidgetEntry {
        CodexWatchWidgetEntry(date: Date(), snapshot: .sampleActive, highUrgencyCount: 0, bridgeOnline: true, savedAt: Date())
    }

    public func getSnapshot(in context: Context, completion: @escaping (CodexWatchWidgetEntry) -> Void) {
        if context.isPreview {
            completion(CodexWatchWidgetEntry(date: Date(), snapshot: .sampleApproval, highUrgencyCount: 1, bridgeOnline: true, savedAt: Date()))
        } else {
            completion(entry(date: Date()))
        }
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<CodexWatchWidgetEntry>) -> Void) {
        let now = Date()
        let entry = entry(date: now)
        var entries = [entry]
        if let savedAt = entry.savedAt {
            let expiresAt = savedAt.addingTimeInterval(601)
            if expiresAt > now {
                var expired = entry
                expired.date = expiresAt
                entries.append(expired)
            }
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(300))))
    }

    private func entry(date: Date) -> CodexWatchWidgetEntry {
        guard let state = store.load() else {
            return CodexWatchWidgetEntry(date: date, snapshot: nil, highUrgencyCount: 0, bridgeOnline: false, savedAt: nil)
        }
        return CodexWatchWidgetEntry(
            date: date,
            snapshot: state.widgetSnapshot,
            highUrgencyCount: state.unreadHighUrgencyCount,
            bridgeOnline: state.bridgeOnline,
            savedAt: store.savedAt() ?? state.generatedAt,
            snapshots: state.snapshots
        )
    }
}

public struct CodexWatchWidgetView: View {
    public var entry: CodexWatchWidgetEntry
    @Environment(\.widgetFamily) private var widgetFamily

    public init(entry: CodexWatchWidgetEntry) {
        self.entry = entry
    }

    public var body: some View {
        Group {
            switch widgetFamily {
            case .accessoryCircular:
                circularComplication
            case .accessoryRectangular:
                rectangularComplication
            default:
                smallWidget
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var presentation: CodexWidgetPresentation {
        CodexWidgetPresentation(entry: entry)
    }

    private var circularComplication: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(presentation.accent.opacity(0.18))

            VStack(spacing: 3) {
                Image(systemName: presentation.symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(presentation.accent)
                Text(presentation.shortStatus)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(5)

            if let badgeText = presentation.badgeText {
                Text(badgeText)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(.red, in: Circle())
                    .offset(x: 1, y: -1)
            }
        }
    }

    private var rectangularComplication: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(presentation.accent)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(presentation.status)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(presentation.accent)
                        .lineLimit(1)
                    if let badgeText = presentation.badgeText {
                        Text(badgeText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                    }
                }
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(presentation.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(presentation.accent)
                Spacer()
                if let badgeText = presentation.badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.red, in: Circle())
                }
            }
            Text(presentation.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Text(presentation.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(presentation.status)
                .font(.caption2.weight(.bold))
                .foregroundStyle(presentation.accent)
                .lineLimit(1)
        }
    }
}

private struct CodexWidgetPresentation {
    var symbolName: String
    var title: String
    var detail: String
    var status: String
    var shortStatus: String
    var accent: Color
    var badgeText: String?

    init(entry: CodexWatchWidgetEntry) {
        if let snapshot = entry.snapshot {
            let widget = snapshot.widgetPresentation(savedAt: entry.savedAt, now: entry.date)
            self.symbolName = widget.symbolName
            self.title = widget.title
            self.detail = widget.detail
            self.status = widget.status
            self.shortStatus = widget.shortStatus
            self.accent = snapshot.status.widgetAccent(
                urgency: snapshot.urgency,
                highUrgencyCount: entry.highUrgencyCount,
                isSnoozed: widget.isSnoozed
            )
        } else {
            let freshness = SyncFreshness(savedAt: entry.savedAt, now: entry.date)
            self.symbolName = entry.bridgeOnline ? "sparkles" : "wifi.slash"
            self.title = entry.bridgeOnline ? "Codex idle" : "Bridge offline"
            self.detail = freshness.displayName
            self.status = entry.bridgeOnline ? "Idle" : "Offline"
            self.shortStatus = freshness.status == .noData ? "No sync" : (entry.bridgeOnline ? "Idle" : "Off")
            self.accent = entry.bridgeOnline ? .cyan : .secondary
        }
        self.badgeText = entry.highUrgencyCount > 0 ? "\(entry.highUrgencyCount)" : nil
    }
}

private extension TaskStatus {
    func widgetAccent(urgency: Urgency, highUrgencyCount: Int, isSnoozed: Bool) -> Color {
        if isSnoozed {
            return .orange
        }
        if urgency == .high || highUrgencyCount > 0 {
            switch self {
            case .waitingForInput: return .blue
            case .waitingForApproval: return .red
            case .failed, .offline: return .pink
            default: return .red
            }
        }

        return switch self {
        case .idle: .cyan
        case .active: .indigo
        case .runningTool: .orange
        case .waitingForInput: .blue
        case .waitingForApproval: .red
        case .completed: .green
        case .failed: .pink
        case .offline: .secondary
        }
    }
}

public struct CodexWatchPetWidget: Widget {
    public let kind = CodexWatchWidgetConstants.kind

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexWatchWidgetProvider()) { entry in
            WatchCollaborationWidgetView(component: .overview, entry: entry)
        }
        .configurationDisplayName("AI 协作")
        .description("查看运行任务和待处理事项。")
        .supportedFamilies(Self.supportedFamilies)
    }

    static var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner]
        #elseif os(macOS)
        [.systemSmall]
        #else
        [.accessoryCircular, .accessoryRectangular, .systemSmall]
        #endif
    }
}
