import CodexMobilityCore
import SwiftUI

struct MobilityVoiceInputPanel: View {
    @ObservedObject private var store: MacVoiceInputStore
    private let descriptor: MobilityModuleDescriptor
    private let isSelected: Bool
    private let isEnabled: Bool
    private let experimentsEnabled: Bool

    init(
        store: MacVoiceInputStore,
        descriptor: MobilityModuleDescriptor,
        isSelected: Bool,
        isEnabled: Bool,
        experimentsEnabled: Bool
    ) {
        self.store = store
        self.descriptor = descriptor
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.experimentsEnabled = experimentsEnabled
    }

    var body: some View {
        MobilityModulePanelScaffold(
            descriptor: descriptor,
            isSelected: isSelected,
            isEnabled: isEnabled,
            experimentsEnabled: experimentsEnabled,
            statusText: phaseTitle,
            statusSymbol: statusSymbol,
            statusTint: statusTint
        ) {
            dictationCard
            transcriptCard
            permissionCard
            behaviorCard
        }
    }

    private var dictationCard: some View {
        MobilityPanelCard {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 68, height: 68)
                    .background(statusTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 5) {
                    Text(phaseTitle)
                        .font(.title3.weight(.semibold))
                    Text(store.statusMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                Button {
                    Task { await store.toggleDictation() }
                } label: {
                    Label(
                        store.phase == .recording ? "结束听写" : "开始听写",
                        systemImage: store.phase == .recording ? "stop.fill" : "mic.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(store.phase == .recording ? .red : .accentColor)
                .disabled(!isEnabled || (store.phase.isBusy && store.phase != .recording))
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            VoiceInputAudioLevelView(
                level: store.audioLevel,
                isActive: store.phase == .recording
            )
            .frame(height: 38)

            HStack {
                Label("语言：\(store.localeDisplayName)", systemImage: "character.bubble")
                Spacer()
                Label(
                    store.codexEnabled ? "Codex 智能整理" : "本地规则整理",
                    systemImage: store.codexEnabled ? "sparkles" : "text.quote"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var transcriptCard: some View {
        MobilityPanelCard(title: "最近文字", symbol: "text.quote") {
            HStack {
                if store.usedRawFallback {
                    Label("Codex 校验未通过，已回退本地整理", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !displayedText.isEmpty {
                    Button {
                        store.copyFinalTranscript()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .disabled(store.phase.isBusy)
                }
            }

            if !store.finalTranscript.isEmpty && !store.phase.isBusy {
                Label(store.deliveryState.title, systemImage: store.deliveryState == .inserted ? "checkmark.circle" : "info.circle")
                    .font(.caption).foregroundStyle(store.deliveryState == .inserted ? Color.green : .orange)
            }
            Text(displayedText.isEmpty ? "按一下 Fn，在任意文本框中开始说话。" : displayedText)
                .foregroundStyle(displayedText.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        }
    }

    private var permissionCard: some View {
        MobilityPanelCard(title: "系统权限", symbol: "checkmark.shield") {
            HStack(spacing: 12) {
                permissionItem(
                    title: "麦克风",
                    granted: store.permissions.microphoneGranted,
                    symbol: "mic"
                )
                permissionItem(
                    title: "辅助功能",
                    granted: store.permissions.accessibilityGranted,
                    symbol: "cursorarrow.motionlines"
                )
                permissionItem(
                    title: "Codex CLI",
                    granted: store.codexAvailable,
                    symbol: "terminal"
                )
            }

            HStack {
                Text("麦克风用于设备端转写；辅助功能用于监听 Fn、捕获并写回原文本框。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重新检查") {
                    Task { await store.refreshPermissions() }
                }
                .disabled(!isEnabled)
                if !store.permissions.allGranted {
                    Button("完成权限") {
                        Task { await store.requestPermissions() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEnabled)
                }
            }
        }
    }

    private var behaviorCard: some View {
        MobilityPanelCard(title: "工作方式", symbol: "waveform.and.mic") {
            Label("单独按下并松开 Fn 可开始或结束听写", systemImage: "command")
            Label("SpeechAnalyzer 与 DictationTranscriber 均在设备端运行", systemImage: "apple.intelligence")
            Label("密码框与安全输入场景禁止读取或写入", systemImage: "lock.shield")
            Label("Codex 失败或破坏实体时回退本地整理；数字改口冲突请手动复核", systemImage: "arrow.uturn.backward.circle")

            Divider()

            HStack {
                Text("音频不上传、不落盘。开启 Codex 后，文字可能发送至其配置的模型服务；目标失配时不会自动覆盖剪贴板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                SettingsLink {
                    Label("语音设置", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private var displayedText: String {
        if !store.liveTranscript.isEmpty {
            return store.liveTranscript
        }
        return store.finalTranscript
    }

    private var phaseTitle: String {
        store.phase == .completed ? store.deliveryState.title : store.phase.title
    }

    private var statusSymbol: String {
        switch store.phase {
        case .recording:
            "waveform.circle.fill"
        case .preparing, .processing:
            "sparkles"
        case .inserting:
            "text.cursor"
        case .completed:
            store.deliveryState == .inserted ? "checkmark.circle.fill" : "doc.text"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle:
            "waveform.circle"
        }
    }

    private var statusTint: Color {
        switch store.phase {
        case .recording:
            .red
        case .preparing, .processing, .inserting:
            .blue
        case .completed:
            store.deliveryState == .inserted ? .green : .orange
        case .failed:
            .orange
        case .idle:
            .secondary
        }
    }

    private func permissionItem(
        title: String,
        granted: Bool,
        symbol: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(granted ? Color.green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(granted ? "已就绪" : "需要处理")
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct VoiceInputAudioLevelView: View {
    let level: Double
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 4) {
                ForEach(0..<26, id: \.self) { index in
                    let normalizedIndex = Double(index) / 25
                    let distance = abs(normalizedIndex - 0.5)
                    let envelope = max(0.18, 1 - distance * 1.5)
                    let activeHeight = max(
                        4,
                        proxy.size.height * envelope * max(level, 0.18)
                    )

                    Capsule()
                        .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: isActive ? activeHeight : 4)
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("麦克风音量")
        .accessibilityValue("\(Int(level * 100))%")
    }
}
