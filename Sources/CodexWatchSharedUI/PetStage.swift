import CodexWatchCore
import SwiftUI

public struct PetStage: View {
    public var snapshot: TaskSnapshot?

    public init(snapshot: TaskSnapshot?) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(stageGradient)
                    .frame(width: 118, height: 118)
                    .shadow(color: accent.opacity(0.28), radius: 18, y: 8)

                VStack(spacing: 8) {
                    Image(systemName: mood.symbolName)
                        .font(.system(size: 34, weight: .semibold))
                        .symbolEffect(.pulse, options: .repeating, value: mood)
                    Text(mood.displayName)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Codex pet status \(mood.displayName)")

            VStack(spacing: 4) {
                Text(snapshot?.title ?? "准备好与你协作")
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(snapshot?.lastSummary ?? "新的任务和进展会显示在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var mood: PetMood {
        snapshot?.petMood ?? .idle
    }

    private var accent: Color {
        switch mood {
        case .idle: .cyan
        case .thinking: .indigo
        case .tooling: .orange
        case .needsInput: .blue
        case .needsApproval: .red
        case .done: .green
        case .failed: .pink
        case .offline: .gray
        }
    }

    private var stageGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accent.opacity(0.62), .black.opacity(0.9)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview {
    PetStage(snapshot: .sampleApproval)
        .padding()
}
