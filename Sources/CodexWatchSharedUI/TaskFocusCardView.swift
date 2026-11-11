import CodexWatchCore
import SwiftUI

public struct TaskFocusCardView: View {
    public var snapshot: TaskSnapshot?

    public init(snapshot: TaskSnapshot?) {
        self.snapshot = snapshot
    }

    public var body: some View {
        if let snapshot {
            let digest = snapshot.focusDigest()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label("Focus", systemImage: snapshot.petMood.symbolName)
                        .font(.caption.weight(.bold))
                    Spacer(minLength: 4)
                    Text(snapshot.status.displayName)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(color(for: snapshot))
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(digest.headline)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(for: snapshot))
                        .lineLimit(1)
                    Text(digest.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                VStack(spacing: 4) {
                    ForEach(digest.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(item.value)
                                .font(.caption2.weight(.semibold))
                                .multilineTextAlignment(.trailing)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func color(for snapshot: TaskSnapshot) -> Color {
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
    TaskFocusCardView(snapshot: .sampleApproval)
        .padding()
}
