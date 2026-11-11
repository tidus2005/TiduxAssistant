#if os(iOS) && !targetEnvironment(macCatalyst)
import CodexMobilityCore
import SwiftUI

@MainActor
struct MobileHistoryView: View {
    let model: MobileAppModel

    @State private var pendingDeletionID: UUID?

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView {
                    Label(
                        "还没有记录",
                        systemImage: "waveform.badge.plus"
                    )
                } description: {
                    Text("完成一次录音后，文字记录会显示在这里。")
                } actions: {
                    Button("重新加载") {
                        Task {
                            await model.reloadHistory()
                        }
                    }
                    .accessibilityIdentifier(
                        MobileAccessibilityIdentifier.historyReload
                    )
                }
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier.historyEmpty
                )
            } else {
                historyList
            }
        }
        .navigationTitle("历史记录")
        .accessibilityIdentifier(
            MobileAccessibilityIdentifier.historyScreen
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await model.reloadHistory()
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier.historyReload
                )
            }
        }
    }

    private var historyList: some View {
        List(model.history) { record in
            NavigationLink {
                MobileSessionDetailView(record: record)
            } label: {
                MobileHistoryRow(record: record)
            }
            .accessibilityLabel(historyAccessibilityLabel(for: record))
            .accessibilityIdentifier(
                MobileAccessibilityIdentifier.historyRow(record.id)
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDeletionID = record.id
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await model.reloadHistory()
        }
        .accessibilityIdentifier(
            MobileAccessibilityIdentifier.historyList
        )
        .confirmationDialog(
            "永久删除这条记录？",
            isPresented: deletionConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("删除记录与音频", role: .destructive) {
                guard let id = pendingDeletionID else { return }
                pendingDeletionID = nil
                Task {
                    await model.deleteHistorySession(id: id)
                }
            }
            Button("取消", role: .cancel) {
                pendingDeletionID = nil
            }
        } message: {
            Text("转写、原始音频分段和诊断文件都会从这台 iPhone 删除，无法恢复。")
        }
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionID = nil
                }
            }
        )
    }

    private func historyAccessibilityLabel(
        for record: TranscriptSessionRecord
    ) -> String {
        let transcript = record.text.isEmpty ? "暂无文字" : record.text
        return "\(record.session.state.mobileTitle)，\(transcript)"
    }
}

private struct MobileHistoryRow: View {
    let record: TranscriptSessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    record.session.createdAt,
                    format: .dateTime
                        .year()
                        .month()
                        .day()
                        .hour()
                        .minute()
                )
                .font(.headline)

                Spacer()

                MobileSessionStateBadge(state: record.session.state)
            }

            Text(record.text.isEmpty ? "暂无转写内容" : record.text)
                .font(.subheadline)
                .foregroundStyle(record.text.isEmpty ? .secondary : .primary)
                .lineLimit(3)

            HStack(spacing: 12) {
                Label(
                    record.session.localeIdentifier,
                    systemImage: "globe"
                )
                Label(
                    "\(record.segments.count) 段",
                    systemImage: "text.alignleft"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
#endif
