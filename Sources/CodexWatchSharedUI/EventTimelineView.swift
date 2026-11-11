import CodexWatchCore
import SwiftUI

public struct EventTimelineView: View {
    public var events: [BridgeEvent]
    public var maxCount: Int
    public var onSelectThread: ((String) -> Void)?

    public init(
        events: [BridgeEvent],
        maxCount: Int = 8,
        onSelectThread: ((String) -> Void)? = nil
    ) {
        self.events = events
        self.maxCount = maxCount
        self.onSelectThread = onSelectThread
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recent Progress", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text("\(recentEvents.count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if recentEvents.isEmpty {
                ContentUnavailableView(
                    "No recent Codex updates",
                    systemImage: "clock",
                    description: Text("Progress will appear here after the bridge reports activity.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(recentEvents) { event in
                    rowContainer(for: event)
                }
            }
        }
    }

    private var recentEvents: [BridgeEvent] {
        Array(
            events
                .sorted { lhs, rhs in
                    if lhs.sequence == rhs.sequence {
                        lhs.createdAt > rhs.createdAt
                    } else {
                        lhs.sequence > rhs.sequence
                    }
                }
                .prefix(maxCount)
        )
    }

    @ViewBuilder
    private func rowContainer(for event: BridgeEvent) -> some View {
        if let onSelectThread {
            Button {
                onSelectThread(event.threadId)
            } label: {
                EventTimelineRow(event: event)
            }
            .buttonStyle(.plain)
        } else {
            EventTimelineRow(event: event)
        }
    }
}

private struct EventTimelineRow: View {
    var event: BridgeEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.petMood.symbolName)
                .font(.title3)
                .frame(width: 28, height: 28)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(event.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(event.type.displayName)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.16), in: Capsule())
                        .foregroundStyle(color)

                    if event.urgency == .high {
                        Label("Needs attention", systemImage: "bell.badge")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var color: Color {
        switch event.urgency {
        case .low: .secondary
        case .medium: .blue
        case .high: .red
        }
    }
}

private extension BridgeEventType {
    var displayName: String {
        switch self {
        case .threadStarted: "Started"
        case .turnProgress: "Progress"
        case .approvalRequested: "Approval"
        case .inputRequested: "Input"
        case .turnCompleted: "Done"
        case .turnFailed: "Failed"
        case .bridgeOffline: "Offline"
        }
    }
}

#Preview {
    EventTimelineView(
        events: [
            BridgeEvent(
                sequence: 2,
                threadId: "thread-active",
                type: .turnProgress,
                title: "Codex is editing files",
                summary: "Updated the Watch bridge and is running a verification build.",
                urgency: .medium,
                petMood: .tooling,
                actions: []
            ),
            BridgeEvent(
                sequence: 1,
                threadId: "thread-approval",
                type: .approvalRequested,
                title: "Approve command",
                summary: "A Codex command is waiting for approval.",
                urgency: .high,
                petMood: .needsApproval,
                actions: []
            )
        ]
    )
    .padding()
}
