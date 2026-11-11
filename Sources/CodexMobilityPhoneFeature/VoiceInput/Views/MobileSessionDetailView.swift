#if os(iOS) && !targetEnvironment(macCatalyst)
import CodexMobilityCore
import SwiftUI

struct MobileSessionDetailView: View {
    let record: TranscriptSessionRecord

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                overviewCard
                transcriptCard

                if let failure = record.session.failure {
                    failureCard(failure)
                }

                segmentsCard
                identifierCard
            }
            .padding()
        }
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !record.text.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: record.text) {
                        Label("分享文字", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier(
                        MobileAccessibilityIdentifier.detailShare
                    )
                }
            }
        }
    }

    private var overviewCard: some View {
        MobileSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    MobileSessionStateBadge(state: record.session.state)
                    Spacer()
                    Text(
                        record.session.createdAt,
                        format: .dateTime
                            .year()
                            .month()
                            .day()
                            .hour()
                            .minute()
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Divider()

                LabeledContent(
                    "语言",
                    value: record.session.localeIdentifier
                )
                LabeledContent(
                    "持续时间",
                    value: MobileViewFormat.duration(
                        from: record.session.startedAt,
                        to: record.session.endedAt
                            ?? record.session.updatedAt
                    )
                )
                LabeledContent(
                    "文字分段",
                    value: "\(record.segments.count)"
                )
            }
        }
        .accessibilityIdentifier(
            MobileAccessibilityIdentifier.detailOverview
        )
    }

    private var transcriptCard: some View {
        MobileSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("转写全文", systemImage: "text.quote")
                    .font(.headline)

                Text(record.text.isEmpty ? "本次记录没有转写文字。" : record.text)
                    .foregroundStyle(record.text.isEmpty ? .secondary : .primary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 140,
                        alignment: .topLeading
                    )
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier(
            MobileAccessibilityIdentifier.detailTranscript
        )
    }

    private func failureCard(
        _ failure: RecordingSessionFailure
    ) -> some View {
        MobileSectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "中断信息",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Text(failure.message)
                    .font(.subheadline)

                Text("错误代码：\(failure.code)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier(
            MobileAccessibilityIdentifier.detailFailure
        )
    }

    private var segmentsCard: some View {
        MobileSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("文字分段", systemImage: "list.number")
                    .font(.headline)

                if record.segments.isEmpty {
                    Text("没有可用的文字分段。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(record.segments) { segment in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("第 \(segment.sequenceNumber + 1) 段")
                                    .font(.caption.weight(.semibold))

                                Spacer()

                                Text(
                                    segment.kind == .final
                                        ? "已确认"
                                        : "未完成"
                                )
                                .font(.caption)
                                .foregroundStyle(
                                    segment.kind == .final
                                        ? .green
                                        : .orange
                                )
                            }

                            Text(segment.text)
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(
                            MobileAccessibilityIdentifier.detailSegment(
                                segment.id
                            )
                        )

                        if segment.id != record.segments.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier(
            MobileAccessibilityIdentifier.detailSegments
        )
    }

    private var identifierCard: some View {
        MobileSectionCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("会话标识")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(record.id.uuidString.lowercased())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(
            MobileAccessibilityIdentifier.detailSessionID
        )
    }
}
#endif
