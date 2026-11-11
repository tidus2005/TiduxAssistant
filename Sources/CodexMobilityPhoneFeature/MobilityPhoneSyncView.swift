import CodexMobilityCore
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(PhotosUI)
import CoreTransferable
import PhotosUI

private struct MobilityPickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .data) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexWatchPet-PhotoImport", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let proposedName = received.file.lastPathComponent
            let fileName = proposedName.isEmpty ? "来自照片的文件" : proposedName
            let destination = directory.appendingPathComponent(fileName, isDirectory: false)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return MobilityPickedMediaFile(url: destination)
        }
    }
}

public extension MobilityPhoneSyncStore {
    func enqueuePhotoPickerItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                guard let imported = try await item.loadTransferable(type: MobilityPickedMediaFile.self) else {
                    throw CocoaError(.fileReadUnknown)
                }
                defer { try? FileManager.default.removeItem(at: imported.url.deletingLastPathComponent()) }
                await enqueueFiles([imported.url])
            } catch {
                reportImportError(error)
            }
        }
    }
}
#endif

@MainActor
public struct MobilityPhoneSyncView: View {
    @ObservedObject private var store: MobilityPhoneSyncStore
    @State private var isFileImporterPresented = false
    @State private var isPreparingMedia = false
    #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(PhotosUI)
    @State private var selectedPhotos: [PhotosPickerItem] = []
    #endif

    public init(store: MobilityPhoneSyncStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    connectionCard
                    importActions
                    if store.usesDualChannelRouting {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(store.isPeerConnectionReady ? "Wi-Fi 高速通道已连接" : store.highSpeedStatus,
                                systemImage: store.isPeerConnectionReady ? "wifi" : "personalhotspot")
                                .font(.subheadline)
                            if !store.isPeerConnectionReady {
                                Button("重试高速连接") { store.requestHighSpeedConnection?() }
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    queueSection
                    if store.pausedLegacyIncomingCount > 0 {
                        Text("已暂停 \(store.pausedLegacyIncomingCount) 项历史自动接收任务。原文件和断点保留，不会自动下载整个 Mac 文件夹。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !store.availableMacFiles.isEmpty {
                        DisclosureGroup("从 Mac 接收（按需选择）") {
                            ForEach(store.availableMacFiles, id: \.metadata.transferID) { offer in
                                Button {
                                    store.receiveMacFile(offer)
                                } label: {
                                    HStack {
                                        Text(offer.metadata.relativePath).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.down.circle")
                                    }
                                }.padding(.vertical, 4)
                            }
                            Text("仅列出本批候选，点选后才接收文件。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    recentSection
                    storageNote
                }
                .padding()
            }
            .navigationTitle("传送")
            .toolbar {
                if !store.recentResults.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("清除记录") {
                            store.clearRecentResults()
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await store.enqueueFiles(urls) }
            case .failure(let error):
                store.reportImportError(error)
            }
        }
        .alert("同步提示", isPresented: errorPresentation) {
            Button("知道了", role: .cancel) {
                store.clearError()
            }
        } message: {
            Text(store.lastErrorMessage ?? "未知错误")
        }
    }

    private var connectionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: store.isConnectionReady
                ? "iphone.and.arrow.forward.outward"
                : "antenna.radiowaves.left.and.right.slash")
                .font(.title2)
                .foregroundStyle(store.isConnectionReady ? .green : .orange)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.isConnectionReady ? "Mac 已连接" : "等待 Mac 连接")
                    .font(.headline)
                Text(store.isConnectionReady
                    ? "64 KB 以内走蓝牙；照片和视频优先通过加密 Wi-Fi 传送"
                    : "可以先选择文件；前台连接恢复后会继续处理队列")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isImporting || isPreparingMedia {
                ProgressView()
                    .accessibilityLabel("正在准备文件")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

    }

    @ViewBuilder
    private var importActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发送到 Mac")
                .font(.headline)

            #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(PhotosUI)
            PhotosPicker(
                selection: $selectedPhotos,
                maxSelectionCount: 20,
                matching: .any(of: [.images, .videos])
            ) {
                actionRow(
                    title: "选择照片或视频",
                    detail: "可多选；系统选择器不会授予整个照片库权限",
                    symbol: "photo.on.rectangle.angled",
                    tint: .blue
                )
            }
            .buttonStyle(.plain)
            .disabled(isPreparingMedia)
            if !selectedPhotos.isEmpty {
                Button {
                    let selection = selectedPhotos
                    isPreparingMedia = true
                    Task {
                        await store.enqueuePhotoPickerItems(selection)
                        selectedPhotos = []
                        isPreparingMedia = false
                    }
                } label: {
                    Label(isPreparingMedia ? "正在准备照片与视频…" : "传送 \(selectedPhotos.count) 个项目", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).disabled(isPreparingMedia)
            }
            #endif

            Button {
                isFileImporterPresented = true
            } label: {
                actionRow(
                    title: "选择文件",
                    detail: "从 iCloud Drive、我的 iPhone 或文件提供商多选",
                    symbol: "folder.badge.plus",
                    tint: .indigo
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("传输队列")
                .font(.headline)

            if store.transfers.isEmpty {
                ContentUnavailableView(
                    "队列为空",
                    systemImage: "arrow.left.arrow.right.circle",
                    description: Text("从上方选择文件，或在 Mac 同步目录中放入文件。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(store.transfers) { transfer in
                    transferRow(transfer)
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !store.recentResults.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("最近结果")
                    .font(.headline)
                ForEach(store.recentResults) { result in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: resultSymbol(result.status))
                            .foregroundStyle(resultColor(result.status))
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.fileName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(result.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(result.completedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        #if os(iOS) && !targetEnvironment(macCatalyst)
                        if let url = result.localURL {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("共享 \(result.fileName)")
                        }
                        #endif
                    }
                    .padding(14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private var storageNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("接收位置", systemImage: "tray.and.arrow.down")
                .font(.subheadline.weight(.semibold))
            Text("Mac 发来的所有文件先完整校验，再保存到“文件”App / 我的 iPhone / Codex Watch Pet / Codex Sync Inbox。目前按文件名平铺保存，不保留 Mac 子目录层级。图片和视频随后尝试添加到“照片”；即使相册写入失败，Files 副本仍会保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("单文件上限 \(formattedBytes(store.maximumFileSize))。大文件按块从磁盘读取，接收后校验；网络中断保留队列和接收进度。传输时请保持 App 在前台，iOS 后台不保证持续传输。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    nonisolated private func actionRow(
        title: String,
        detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .contentShape(Rectangle())
    }

    private func transferRow(_ transfer: MobilityPhoneSyncTransfer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: transfer.metadata.direction == .phoneToMac
                    ? "arrow.up.doc"
                    : "arrow.down.doc")
                    .foregroundStyle(transfer.metadata.direction == .phoneToMac ? .blue : .green)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text("\(transfer.metadata.direction == .phoneToMac ? "发往 Mac" : "来自 Mac") · \(formattedBytes(transfer.metadata.byteSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusLabel(transfer.status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(transfer.status == .failed ? .red : .secondary)
            }

            if store.usesDualChannelRouting {
                Text(routeLabel(transfer)).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: transfer.progress)
                .accessibilityLabel("\(transfer.fileName) 进度")
                .accessibilityValue("\(Int(transfer.progress * 100))%")

            HStack {
                Text("\(formattedBytes(transfer.confirmedBytes)) / \(formattedBytes(transfer.metadata.byteSize))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if transfer.status == .failed {
                    Button("重试") {
                        store.retry(transfer.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("取消", role: .destructive) {
                    store.cancel(transfer.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let error = transfer.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { store.lastErrorMessage != nil },
            set: { isPresented in
                if !isPresented { store.clearError() }
            }
        )
    }

    private func routeLabel(_ transfer: MobilityPhoneSyncTransfer) -> String {
        switch store.transferRoutes[transfer.id] {
        case .bluetooth: "蓝牙 · 小文件通道"
        case .localNetwork: "Wi-Fi · 加密高速通道"
        case .waitingForNetwork: "等待 Wi-Fi / 手机热点 · 进度已保留"
        case nil: "等待自动选择通道"
        }
    }

    private func statusLabel(_ status: MobilityPhoneSyncTransferStatus) -> String {
        switch status {
        case .queued: "已排队"
        case .waitingForConnection: "等待连接"
        case .negotiating: "正在协商"
        case .transferring: "传输中"
        case .verifying: "正在校验"
        case .failed: "失败"
        }
    }

    private func resultSymbol(_ status: MobilityPhoneSyncResultStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .completedWithWarning: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private func resultColor(_ status: MobilityPhoneSyncResultStatus) -> Color {
        switch status {
        case .completed: .green
        case .completedWithWarning: .orange
        case .cancelled: .secondary
        case .failed: .red
        }
    }

    private func formattedBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
