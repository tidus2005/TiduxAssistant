#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(PhotosUI) && canImport(UIKit)
import CodexMobilityCore
import PhotosUI
import SwiftUI
import UIKit

@MainActor
public struct ScreenshotAnnotationView: View {
    @ObservedObject private var syncStore: MobilityPhoneSyncStore
    @State private var model = ScreenshotAnnotationEditorModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var noteRequest: ScreenshotAnnotationNoteRequest?
    @State private var isSendingToMac = false
    @State private var showsClearConfirmation = false

    public init(store: MobilityPhoneSyncStore) {
        self.syncStore = store
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    introductionCard
                    sourcePickerCard

                    if model.hasSourceImage {
                        toolAndColorCard
                        canvasCard
                        annotationListCard
                        exportCard
                    }

                    MobileInputMethodSetupView()
                }
                .padding()
            }
            .navigationTitle("截图标注")
            .toolbar {
                if model.hasSourceImage {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.undoLastMark()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .disabled(model.marks.isEmpty)
                        .accessibilityLabel("撤销最后一条标注")
                    }
                }
            }
        }
        .sheet(item: $noteRequest) { request in
            ScreenshotAnnotationNoteSheet(request: request, model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "清空全部标注？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空全部标注", role: .destructive) {
                model.clearAllMarks()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会移除标记和说明，所选原图会继续保留。")
        }
        .alert("标注提示", isPresented: errorPresentation) {
            Button("知道了", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var introductionCard: some View {
        ScreenshotAnnotationSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("把截图直接变成开发修改单", systemImage: "rectangle.and.pencil.and.ellipsis")
                    .font(.headline)
                Text("选择应用截图，用矩形、圆形或手绘圈出问题；每次圈选都会立即要求填写说明。导出结果会把编号说明拼接在图片下方。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(
                    "全部处理都在本机完成；只有点击“发送到 Mac”后，生成的图片才会进入已配对设备的同步队列。",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var sourcePickerCard: some View {
        let pickerTitle = model.hasSourceImage ? "更换截图" : "从照片选择"

        return ScreenshotAnnotationSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: model.hasSourceImage ? "photo.fill" : "photo.badge.plus")
                        .font(.title2)
                        .foregroundStyle(model.hasSourceImage ? Color.green : Color.accentColor)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.hasSourceImage ? "截图已载入" : "选择一张应用截图")
                            .font(.headline)
                        Text(model.hasSourceImage
                            ? "更换图片会清空当前未导出的标注"
                            : "系统照片选择器不会授予整个照片库权限")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isImporting {
                        ProgressView()
                            .accessibilityLabel("正在读取截图")
                    }
                }

                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(
                        pickerTitle,
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isImporting || model.isExporting || isSendingToMac)
                .accessibilityIdentifier("screenshot.annotation.photoPicker")
                .onChange(of: selectedPhoto) { _, item in
                    guard let item else { return }
                    Task {
                        await model.importPhoto(item)
                        selectedPhoto = nil
                    }
                }

                if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("screenshot.annotation.status")
                }
            }
        }
    }

    private var toolAndColorCard: some View {
        ScreenshotAnnotationSectionCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("圈选工具")
                    .font(.headline)

                Picker("圈选工具", selection: $model.selectedTool) {
                    ForEach(ScreenshotAnnotationTool.allCases, id: \.self) { tool in
                        Label(tool.displayName, systemImage: tool.systemImage)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("screenshot.annotation.toolPicker")

                VStack(alignment: .leading, spacing: 8) {
                    Text("标记颜色 · \(model.selectedColor.displayName)")
                        .font(.subheadline.weight(.semibold))
                    ScreenshotAnnotationColorPicker(selection: $model.selectedColor)
                }

                Text("在下方图片范围内按住并拖动，松手后会立即弹出修改说明输入框。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canvasCard: some View {
        ScreenshotAnnotationSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("截图画布")
                        .font(.headline)
                    Spacer()
                    Text("\(model.marks.count) 条标注")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ScreenshotAnnotationCanvasView(model: model) { pending in
                    noteRequest = .new(pending)
                }
            }
        }
    }

    private var annotationListCard: some View {
        ScreenshotAnnotationSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("修改说明")
                        .font(.headline)
                    Spacer()
                    Button("撤销") {
                        model.undoLastMark()
                    }
                    .disabled(model.marks.isEmpty)
                    Button("清空", role: .destructive) {
                        showsClearConfirmation = true
                    }
                    .disabled(model.marks.isEmpty)
                }

                if model.marks.isEmpty {
                    ContentUnavailableView(
                        "还没有标注",
                        systemImage: "pencil.and.scribble",
                        description: Text("在上方截图中圈选需要修改的位置。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 130)
                } else {
                    ForEach(Array(model.marks.enumerated()), id: \.element.id) { offset, mark in
                        ScreenshotAnnotationMarkRow(
                            number: offset + 1,
                            mark: mark,
                            onEdit: {
                                noteRequest = .edit(mark: mark)
                            },
                            onDelete: {
                                model.removeMark(id: mark.id)
                            }
                        )
                    }
                }
            }
        }
    }

    private var exportCard: some View {
        ScreenshotAnnotationSectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("拼接预览与交付")
                        .font(.headline)
                    Spacer()
                    if model.isExporting || isSendingToMac {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let preview = model.composedPreview {
                    Image(uiImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        }
                        .accessibilityLabel("原图标记和下方注释清单的拼接预览")
                } else {
                    Text("完成第一条标注后，这里会显示“原图标记 + 下方编号说明”的完整预览。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
                        .multilineTextAlignment(.center)
                }

                Button {
                    model.exportToFiles()
                } label: {
                    Label("生成 PNG", systemImage: "photo.badge.checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canExport || isSendingToMac)
                .accessibilityIdentifier("screenshot.annotation.export")

                if let exportedAsset = model.exportedAsset {
                    HStack(spacing: 10) {
                        ShareLink(
                            item: exportedAsset.fileURL,
                            subject: Text("Codex Watch Pet 截图修改说明"),
                            message: Text("请按照图片中的编号标记和下方说明进行修改。")
                        ) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("screenshot.annotation.share")

                        Button {
                            Task { await sendExportToMac() }
                        } label: {
                            Label("发送到 Mac", systemImage: "laptopcomputer.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSendingToMac)
                        .accessibilityIdentifier("screenshot.annotation.sendToMac")
                    }

                    Text(exportedAsset.fileURL.lastPathComponent)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                Text("PNG 会保存在“文件 > 我的 iPhone > Codex Watch Pet > Screenshot Annotations”。发送到 Mac 后，即使连接暂时中断，也会保留在同步队列中等待重连。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                }
            }
        )
    }

    private func sendExportToMac() async {
        guard let asset = model.exportedAsset else { return }
        isSendingToMac = true
        defer { isSendingToMac = false }

        syncStore.clearError()
        let previousTransferIDs = Set(syncStore.outgoingTransfers.map(\.id))
        await syncStore.enqueueFiles([asset.fileURL])
        let queued = syncStore.outgoingTransfers.contains { transfer in
            !previousTransferIDs.contains(transfer.id)
                && transfer.fileName == asset.fileURL.lastPathComponent
        }
        if queued {
            model.reportSentToMac()
        } else {
            model.reportSyncFailure(
                syncStore.lastErrorMessage ?? "未能把标注图片加入同步队列，请稍后重试。"
            )
        }
    }
}

private struct ScreenshotAnnotationSectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
    }
}

private struct ScreenshotAnnotationMarkRow: View {
    let number: Int
    let mark: ScreenshotAnnotationMark
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(mark.stroke.color.prefersDarkText ? Color.black : Color.white)
                .frame(width: 28, height: 28)
                .background(mark.stroke.color.swiftUIColor, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Label(mark.stroke.tool.displayName, systemImage: mark.stroke.tool.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mark.stroke.color.swiftUIColor)
                Text(mark.note)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("编辑第 \(number) 条标注")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除第 \(number) 条标注")
            }
        }
        .padding(12)
        .background(
            Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screenshot.annotation.mark.\(number)")
    }
}

private struct ScreenshotAnnotationColorPicker: View {
    @Binding var selection: ScreenshotAnnotationColor

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ScreenshotAnnotationColor.allCases, id: \.self) { color in
                    Button {
                        selection = color
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 30, height: 30)
                            .overlay {
                                Circle()
                                    .stroke(Color.primary, lineWidth: selection == color ? 3 : 0)
                                    .padding(-4)
                            }
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.displayName)
                    .accessibilityValue(selection == color ? "已选择" : "未选择")
                    .accessibilityIdentifier("screenshot.annotation.color.\(color.rawValue)")
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct ScreenshotAnnotationNoteRequest: Identifiable {
    enum Mode {
        case new(PendingScreenshotAnnotation)
        case edit(markID: UUID)
    }

    let id: UUID
    let mode: Mode
    let title: String
    let initialNote: String
    let initialColor: ScreenshotAnnotationColor

    static func new(_ pending: PendingScreenshotAnnotation) -> Self {
        Self(
            id: pending.id,
            mode: .new(pending),
            title: "描述这处修改",
            initialNote: "",
            initialColor: pending.stroke.color
        )
    }

    static func edit(mark: ScreenshotAnnotationMark) -> Self {
        Self(
            id: mark.id,
            mode: .edit(markID: mark.id),
            title: "编辑修改说明",
            initialNote: mark.note,
            initialColor: mark.stroke.color
        )
    }
}

@MainActor
private struct ScreenshotAnnotationNoteSheet: View {
    private static let maximumNoteLength = 1_000

    let request: ScreenshotAnnotationNoteRequest
    let model: ScreenshotAnnotationEditorModel

    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var color: ScreenshotAnnotationColor
    @State private var validationMessage: String?
    @FocusState private var noteIsFocused: Bool

    init(
        request: ScreenshotAnnotationNoteRequest,
        model: ScreenshotAnnotationEditorModel
    ) {
        self.request = request
        self.model = model
        _note = State(initialValue: request.initialNote)
        _color = State(initialValue: request.initialColor)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $note)
                        .focused($noteIsFocused)
                        .frame(minHeight: 150)
                        .accessibilityLabel("修改说明")
                        .accessibilityIdentifier("screenshot.annotation.noteEditor")
                        .onChange(of: note) { _, value in
                            if value.count > Self.maximumNoteLength {
                                note = String(value.prefix(Self.maximumNoteLength))
                            }
                            validationMessage = nil
                        }

                    HStack {
                        Text("请明确说明期望修改成什么样。")
                        Spacer()
                        Text("\(note.count)/\(Self.maximumNoteLength)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("修改说明")
                }

                Section("标记颜色") {
                    ScreenshotAnnotationColorPicker(selection: $color)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(trimmedNote.isEmpty)
                    .accessibilityIdentifier("screenshot.annotation.noteSave")
                }
            }
            .onAppear {
                noteIsFocused = true
            }
        }
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let didSave: Bool
        switch request.mode {
        case .new(let pending):
            guard let recoloredStroke = ScreenshotAnnotationStroke(
                tool: pending.stroke.tool,
                color: color,
                points: pending.stroke.points
            ) else {
                validationMessage = "圈选数据无效，请取消后重新绘制。"
                return
            }
            didSave = model.commit(
                PendingScreenshotAnnotation(stroke: recoloredStroke),
                note: trimmedNote
            )
        case .edit(let markID):
            didSave = model.updateMark(
                id: markID,
                note: trimmedNote,
                color: color
            )
        }

        if didSave {
            dismiss()
        } else {
            validationMessage = "说明不能为空，请补充后重试。"
        }
    }
}

#Preview("截图标注空状态") {
    ScreenshotAnnotationView(store: MobilityPhoneSyncStore())
}
#endif
