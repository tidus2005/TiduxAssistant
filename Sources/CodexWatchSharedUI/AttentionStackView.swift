import CodexWatchCore
import SwiftUI

public struct AttentionStackView: View {
    public var snapshots: [TaskSnapshot]
    public var maxCount: Int
    public var onSelect: (TaskSnapshot) -> Void

    public init(
        snapshots: [TaskSnapshot],
        maxCount: Int = 3,
        onSelect: @escaping (TaskSnapshot) -> Void = { _ in }
    ) {
        self.snapshots = snapshots
        self.maxCount = maxCount
        self.onSelect = onSelect
    }

    public var body: some View {
        let items = snapshots.attentionQueue(limit: maxCount)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label("Attention", systemImage: "bell.badge")
                        .font(.headline)
                    Spacer(minLength: 4)
                    Text("\(snapshots.filter(\.needsAttention).count)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }

                ForEach(items) { snapshot in
                    Button {
                        onSelect(snapshot)
                    } label: {
                        AttentionRow(snapshot: snapshot)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct AttentionRow: View {
    var snapshot: TaskSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .font(.headline)
                .frame(width: 24, height: 24)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(snapshot.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 2)
                    Text(snapshot.status.displayName)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.16), in: Capsule())
                        .foregroundStyle(color)
                        .lineLimit(1)
                }

                Text(snapshot.pendingRequest?.summary ?? snapshot.lastSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var symbolName: String {
        if let pending = snapshot.pendingRequest {
            return switch pending.requiredAction {
            case .reply:
                "text.bubble"
            case .approve:
                "checkmark.shield"
            case .decline:
                "xmark.shield"
            case .cancel:
                "xmark.circle"
            case .interrupt:
                "stop.circle"
            case .openOnMac:
                "macwindow"
            case .snooze:
                "bell.slash"
            case .startThread:
                "plus.bubble"
            case .continueThread:
                "arrowshape.turn.up.right"
            }
        }
        return snapshot.petMood.symbolName
    }

    private var color: Color {
        switch snapshot.status {
        case .waitingForInput:
            .blue
        case .waitingForApproval:
            .red
        case .failed:
            .pink
        case .offline:
            .gray
        case .active, .runningTool:
            .orange
        case .completed:
            .green
        case .idle:
            .secondary
        }
    }
}

#Preview {
    AttentionStackView(snapshots: [.sampleActive, .sampleApproval, .sampleInput])
        .padding()
}
