import SwiftUI

public struct MacFileSyncDashboardSection: View {
    @ObservedObject private var store: MacFileSyncStore

    public init(store: MacFileSyncStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            directoryHeader

            if let error = store.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.directoryURL != nil {
                summary
                queueSection
                recentSection
            } else {
                ContentUnavailableView(
                    "选择一个同步目录",
                    systemImage: "folder.badge.plus",
                    description: Text("iPhone 发来的文件会安全写入此目录；目录中新建或修改且已稳定的文件会排队发回 iPhone。")
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            }

            Label(
                "不超过 256 MiB 的文件由 Bonjour 发现对端，并通过 Network.framework 点对点通道只请求缺失的 SHA-256 数据块；整文件校验后从临时 staging 原子提交。更大的文件使用 file-backed 蓝牙 fallback。",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var directoryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: store.isWatching ? "folder.fill.badge.gearshape" : "folder")
                .font(.title2)
                .foregroundStyle(store.isWatching ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.directoryURL?.lastPathComponent ?? "未配置同步目录")
                    .font(.headline)
                Text(store.directoryDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            if store.directoryURL != nil {
                Toggle(
                    "同步",
                    isOn: Binding(
                        get: { store.isEnabled },
                        set: { enabled in store.setEnabled(enabled) }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()

                Button("在 Finder 中打开") {
                    store.revealDirectory()
                }
            }

            Button(store.directoryURL == nil ? "选择目录" : "更换目录") {
                store.chooseDirectory()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            summaryPill(
                title: "发往 iPhone",
                value: "\(store.pendingOutgoingCount)",
                symbol: "arrow.up.circle.fill",
                tint: .blue
            )
            summaryPill(
                title: "来自 iPhone",
                value: "\(store.activeIncomingCount)",
                symbol: "arrow.down.circle.fill",
                tint: .green
            )
            summaryPill(
                title: "目录监听",
                value: store.isWatching ? "开启" : "暂停",
                symbol: store.isWatching ? "eye.fill" : "pause.circle.fill",
                tint: store.isWatching ? .green : .secondary
            )
        }
    }

    @ViewBuilder
    private var queueSection: some View {
        if !store.queue.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("当前队列")
                    .font(.subheadline.weight(.semibold))
                ForEach(store.queue.prefix(5)) { item in
                    queueRow(item)
                }
                if store.queue.count > 5 {
                    Text("另有 \(store.queue.count - 5) 项等待处理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !store.recentResults.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("最近结果")
                    .font(.subheadline.weight(.semibold))
                ForEach(store.recentResults.prefix(4)) { result in
                    HStack(spacing: 9) {
                        Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.succeeded ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.relativePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(result.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(result.occurredAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func queueRow(_ item: MacSyncQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: item.direction == .toPhone ? "iphone.and.arrow.forward" : "macbook.and.iphone")
                    .foregroundStyle(item.direction == .toPhone ? .blue : .green)
                Text(item.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(Self.byteFormatter.string(fromByteCount: Int64(item.byteCount)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if item.phase == .transferring, item.byteCount > 0 {
                ProgressView(
                    value: Double(item.transferredByteCount),
                    total: Double(item.byteCount)
                )
                .progressViewStyle(.linear)
            } else {
                Text(item.detail ?? "等待传输")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func summaryPill(
        title: String,
        value: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.35), in: Capsule())
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
}
