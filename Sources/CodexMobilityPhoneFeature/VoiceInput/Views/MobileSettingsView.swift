#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import Observation
import SwiftUI

@MainActor
struct MobileSettingsView: View {
    let model: MobileAppModel
    @State private var includeAudioInHistoryBackup = true
    @State private var historyBackupTransfer:
        MobileVoiceHistoryBackupTransfer?
    @State private var isPresentingHistoryExporter = false
    @State private var isPresentingHistoryImporter = false
    @State private var historyTransferFeedback: String?

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker(
                    "转写语言",
                    selection: $model.selectedLocaleIdentifier
                ) {
                    ForEach(MobileLocaleOption.allCases) { option in
                        Text(option.title).tag(option.identifier)
                    }
                }
                .disabled(!canChangeRecordingSettings)
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier.settingsLocale
                )

                Toggle(
                    "保留原始音频分段",
                    isOn: $model.keepAudio
                )
                .disabled(!canChangeRecordingSettings)
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier.settingsKeepAudio
                )
            } header: {
                Text("录音")
            } footer: {
                Text(
                    "关闭后只保存设备端转写文字。"
                        + "更改语言可能需要下载新的本地模型。"
                )
            }

            Section("设备端语音能力") {
                capabilityRow(
                    title: "麦克风",
                    value: model.capability.microphonePermission.title,
                    isHealthy: model.capability.microphonePermission == .granted
                )
                capabilityRow(
                    title: "SpeechTranscriber",
                    value: model.capability.speechTranscriberAvailable
                        ? "可用"
                        : "不可用",
                    isHealthy: model.capability.speechTranscriberAvailable
                )
                capabilityRow(
                    title: "解析语言",
                    value: model.capability.resolvedLocaleIdentifier
                        ?? "不支持",
                    isHealthy:
                        model.capability.resolvedLocaleIdentifier != nil
                )
                capabilityRow(
                    title: "语音后端",
                    value: model.capability.backend?.title ?? "未选择",
                    isHealthy: model.capability.backend != nil
                )
                capabilityRow(
                    title: "模型状态",
                    value: model.capability.assetState.title,
                    isHealthy: model.capability.assetState == .installed
                )
                capabilityRow(
                    title: "模型保留",
                    value: model.capability.localeReserved ? "是" : "否",
                    isHealthy: model.capability.localeReserved
                )

                if model.capability.maximumReservedLocales > 0 {
                    LabeledContent(
                        "设备保留上限",
                        value:
                            "\(model.capability.maximumReservedLocales) 种语言"
                    )
                }

                if let errorMessage = model.capability.errorMessage {
                    Label(
                        errorMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(
                        MobileAccessibilityIdentifier.settingsCapabilityError
                    )
                }

                Button {
                    Task {
                        await model.refreshCapabilities()
                    }
                } label: {
                    Label("刷新能力状态", systemImage: "arrow.clockwise")
                }
                .disabled(
                    model.phase.isBusy ||
                    model.isRecording ||
                    model.isStartOperationInFlight
                )
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier.settingsRefreshCapabilities
                )

                Button {
                    Task {
                        await model.prepareSpeechAssets()
                    }
                } label: {
                    Label("准备本地语音模型", systemImage: "sparkles")
                }
                .disabled(
                    model.phase.isBusy ||
                    model.isRecording ||
                    model.isStartOperationInFlight
                )
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier.settingsPrepareAssets
                )
            }

            Section {
                LabeledContent(
                    "可用空间",
                    value: MobileViewFormat.byteCount(
                        model.availableStorageBytes
                    )
                )
                LabeledContent(
                    "录音前安全门槛",
                    value: MobileViewFormat.byteCount(
                        MobileAppModel.minimumRecordingStorageBytes
                    )
                )

                Button {
                    Task {
                        await model.refreshStorageCapacity()
                    }
                } label: {
                    Label("刷新可用空间", systemImage: "internaldrive")
                }
                .disabled(
                    model.phase.isBusy ||
                    model.isRecording ||
                    model.isStartOperationInFlight
                )
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier
                        .settingsRefreshStorage
                )
            } header: {
                Text("设备存储")
            } footer: {
                Text(
                    "保留原始音频时，Codex Watch Pet 会在开始前和录音期间"
                        + "检查空间，空间不足会明确停止并保留已落盘内容。"
                )
            }

            Section {
                Toggle(
                    "备份原始音频分段",
                    isOn: $includeAudioInHistoryBackup
                )
                .disabled(!canChangeRecordingSettings)

                Button {
                    prepareHistoryExport()
                } label: {
                    if model.isHistoryTransferInProgress {
                        HStack {
                            ProgressView()
                            Text("正在处理历史备份…")
                        }
                    } else {
                        Label(
                            "导出完整历史",
                            systemImage: "archivebox"
                        )
                    }
                }
                .disabled(!canChangeRecordingSettings)
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier
                        .settingsExportHistory
                )

                Divider()

                Button {
                    historyTransferFeedback = nil
                    isPresentingHistoryImporter = true
                } label: {
                    if model.isHistoryTransferInProgress {
                        HStack {
                            ProgressView()
                            Text("正在校验并导入…")
                        }
                    } else {
                        Label(
                            "从 FlowType 备份导入",
                            systemImage: "square.and.arrow.down"
                        )
                    }
                }
                .disabled(!canChangeRecordingSettings)
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier
                        .settingsImportHistory
                )

                if let historyTransferFeedback {
                    Text(historyTransferFeedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("语音历史备份")
            } footer: {
                Text(
                    "导出可用于当前 App 的日常备份，也兼容旧 FlowType 的"
                        + " .flowtypebackup。导入会校验全部路径、大小和 SHA-256；"
                        + "相同记录跳过，同 UUID 但内容不同的记录只报告冲突，绝不覆盖。"
                )
            }

            Section("运行诊断") {
                if model.diagnostics.isEmpty {
                    Text("暂无诊断信息。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        Array(model.diagnostics.enumerated()),
                        id: \.offset
                    ) { _, diagnostic in
                        Text(diagnostic)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                ShareLink(
                    item: model.shareableDiagnosticReportText,
                    subject: Text("Codex Watch Pet 真机诊断报告")
                ) {
                    Label(
                        "分享诊断 JSON",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier
                        .settingsShareDiagnostics
                )

                Text(
                    "报告不包含录音或转写正文；会包含设备系统、"
                        + "语音能力、会话状态、峰值内存和 thermal 状态。"
                        + "设备可用空间仅在本页显示，不会加入分享报告。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Text(
                    "语音识别在设备端完成。Codex Watch Pet 仅在你主动开始录音后"
                        + "访问麦克风。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                NavigationLink {
                    MobilePrivacyPolicyView()
                } label: {
                    Label(
                        "隐私政策",
                        systemImage: "hand.raised"
                    )
                }
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier
                        .settingsPrivacyPolicy
                )
            }
        }
        .navigationTitle("设置与诊断")
        .onChange(of: model.selectedLocaleIdentifier) {
            Task {
                await model.refreshCapabilities()
            }
        }
        .fileExporter(
            isPresented: $isPresentingHistoryExporter,
            item: historyBackupTransfer,
            contentTypes: [.flowTypeVoiceHistoryBackup],
            defaultFilename: defaultHistoryBackupFilename
        ) { result in
            switch result {
            case .success:
                historyTransferFeedback = "历史备份已保存。"
            case let .failure(error):
                historyTransferFeedback =
                    "保存历史备份失败：\(error.localizedDescription)"
            }
            historyBackupTransfer = nil
        } onCancellation: {
            historyTransferFeedback = "已取消保存；现有历史没有变化。"
            historyBackupTransfer = nil
        }
        .fileImporter(
            isPresented: $isPresentingHistoryImporter,
            allowedContentTypes: [.flowTypeVoiceHistoryBackup]
        ) { result in
            switch result {
            case let .success(packageURL):
                importHistory(from: packageURL)
            case let .failure(error):
                historyTransferFeedback =
                    "选择历史备份失败：\(error.localizedDescription)"
            }
        }
    }

    private var defaultHistoryBackupFilename: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return "CodexWatchPet-语音历史-\(formatter.string(from: Date()))"
    }

    private func prepareHistoryExport() {
        historyTransferFeedback = nil
        Task {
            do {
                let export = try await model.exportHistoryBackup(
                    includeAudio: includeAudioInHistoryBackup
                )
                historyBackupTransfer = MobileVoiceHistoryBackupTransfer(
                    packageURL: export.packageURL
                )
                isPresentingHistoryExporter = true
            } catch {
                historyTransferFeedback =
                    "准备历史备份失败：\(error.localizedDescription)"
            }
        }
    }

    private var canChangeRecordingSettings: Bool {
        guard
            !model.isStartOperationInFlight,
            !model.isHistoryTransferInProgress
        else {
            return false
        }
        switch model.phase {
        case .idle, .completed, .failed:
            return true
        case .preparing,
             .recording,
             .stopping,
             .finalizationDelayed:
            return false
        }
    }

    private func importHistory(from packageURL: URL) {
        Task {
            do {
                let result = try await model.importHistoryBackup(
                    from: packageURL
                )
                historyTransferFeedback =
                    "导入完成：新增 \(result.importedSessionIDs.count) 条，"
                    + "跳过 \(result.skippedSessionIDs.count) 条，"
                    + "冲突 \(result.conflictingSessionIDs.count) 条。"
            } catch {
                historyTransferFeedback =
                    "导入历史备份失败：\(error.localizedDescription)"
            }
        }
    }

    private func capabilityRow(
        title: String,
        value: String,
        isHealthy: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)

            Spacer(minLength: 8)

            Image(
                systemName: isHealthy
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle"
            )
            .foregroundStyle(isHealthy ? .green : .secondary)

            Text(value)
                .foregroundStyle(isHealthy ? .green : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private enum MobileLocaleOption: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case english = "en-US"
    case japanese = "ja-JP"

    var id: String { rawValue }
    var identifier: String { rawValue }

    var title: String {
        switch self {
        case .simplifiedChinese:
            "简体中文"
        case .traditionalChinese:
            "繁體中文"
        case .english:
            "English"
        case .japanese:
            "日本語"
        }
    }
}
#endif
