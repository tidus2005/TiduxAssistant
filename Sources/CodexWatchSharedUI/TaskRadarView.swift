import CodexWatchCore
import SwiftUI

public struct TaskRadarView: View {
    public var snapshots: [TaskSnapshot]
    public var onSelect: (TaskSnapshot) -> Void

    public init(snapshots: [TaskSnapshot], onSelect: @escaping (TaskSnapshot) -> Void = { _ in }) {
        self.snapshots = snapshots
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Task Radar", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Text("\(snapshots.count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if snapshots.isEmpty {
                ContentUnavailableView("No active Codex tasks", systemImage: "moon.zzz", description: Text("The bridge has not reported any task yet."))
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(snapshots) { snapshot in
                    Button {
                        onSelect(snapshot)
                    } label: {
                        TaskRow(snapshot: snapshot)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

public struct TaskRow: View {
    public var snapshot: TaskSnapshot

    public init(snapshot: TaskSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: snapshot.petMood.symbolName)
                .font(.title3)
                .frame(width: 28, height: 28)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(snapshot.status.displayName)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.16), in: Capsule())
                        .foregroundStyle(color)
                }
                Text(snapshot.lastSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let snoozedUntil = snapshot.snoozedUntil, snapshot.isSnoozed {
                    Label("Snoozed until \(snoozedUntil.formatted(date: .omitted, time: .shortened))", systemImage: "bell.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if let pending = snapshot.pendingRequest {
                    Label(pending.summary, systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var color: Color {
        switch snapshot.urgency {
        case .low: .secondary
        case .medium: .blue
        case .high: .red
        }
    }
}

#Preview {
    TaskRadarView(snapshots: [.sampleApproval, .sampleActive])
        .padding()
}
