#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI

@MainActor
struct MobileRecordingView: View {
    let model: MobileAppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                recordingSummary
                transcriptCard

                if !model.capability.isReady {
                    capabilityCard
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            recordingControls
        }
        .navigationTitle("现场记录")
        .accessibilityIdentifier(
            MobileAccessibilityIdentifier.recordingScreen
        )
    }

    private var recordingSummary: some View {
        MobileSectionCard {
            VStack(spacing: 16) {
                HStack {
                    Label(model.phase.title, systemImage: phaseSymbol)
                        .font(.headline)
                        .foregroundStyle(phaseTint)
                        .accessibilityIdentifier(
                            MobileAccessibilityIdentifier.recordingPhase
                        )

                    Spacer()

                    Text(model.elapsedLabel)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .accessibilityLabel("录音时长")
                        .accessibilityValue(model.elapsedLabel)
                        .accessibilityIdentifier(
                            MobileAccessibilityIdentifier.recordingElapsed
                        )
                }

                ProgressView(value: model.audioLevel, total: 1)
                    .tint(model.isRecording ? .red : .accentColor)
                    .animation(
                        .linear(duration: 0.12),
                        value: model.audioLevel
                    )
                    .accessibilityLabel("当前音量")
                    .accessibilityValue(audioLevelAccessibilityValue)
                    .accessibilityIdentifier(
                        MobileAccessibilityIdentifier.recordingAudioLevel
                    )

                Text(model.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(
                        MobileAccessibilityIdentifier.recordingStatus
                    )
            }
        }
    }

    private var transcriptCard: some View {
        MobileSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("实时文字", systemImage: "text.quote")
                        .font(.headline)

                    Spacer()

                    if model.isRecording {
                        Text("设备端")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                }

                Text(model.displayedTranscript)
                    .font(.body)
                    .foregroundStyle(hasTranscript ? .primary : .secondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 180,
                        alignment: .topLeading
                    )
                    .textSelection(.enabled)
                    .accessibilityLabel("转写内容")
                    .accessibilityIdentifier(
                        MobileAccessibilityIdentifier.recordingTranscript
                    )
            }
        }
    }

    private var capabilityCard: some View {
        MobileSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "本地语音能力尚未就绪",
                    systemImage: "arrow.down.circle"
                )
                .font(.headline)

                Text(capabilityDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await model.prepareSpeechAssets()
                    }
                } label: {
                    Label(
                        "准备本地语音模型",
                        systemImage: "sparkles"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.phase.isBusy || model.isRecording)
                .accessibilityIdentifier(
                    MobileAccessibilityIdentifier.prepareSpeechAssets
                )
            }
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    await model.toggleRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(model.isRecording ? .red : .accentColor)
                        .frame(width: 76, height: 76)

                    Image(
                        systemName: model.isRecording
                            ? "stop.fill"
                            : "mic.fill"
                    )
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canToggleRecording)
            .opacity(model.canToggleRecording ? 1 : 0.55)
            .accessibilityLabel(
                model.isRecording ? "停止录音" : "开始录音"
            )
            .accessibilityHint(
                model.isRecording
                    ? "停止并保存当前录音"
                    : "开始设备端语音转写"
            )
            .accessibilityValue(model.phase.title)
            .accessibilityIdentifier(
                MobileAccessibilityIdentifier.recordingToggle
            )

            Text(model.isRecording ? "点击停止并保存" : "点击开始记录")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var hasTranscript: Bool {
        !model.liveTranscript.isEmpty || !model.finalTranscript.isEmpty
    }

    private var phaseSymbol: String {
        switch model.phase {
        case .idle:
            "checkmark.circle"
        case .preparing:
            "hourglass"
        case .recording:
            "waveform.circle.fill"
        case .stopping:
            "ellipsis.circle"
        case .finalizationDelayed:
            "clock.badge.exclamationmark"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var phaseTint: Color {
        switch model.phase {
        case .recording:
            .red
        case .completed:
            .green
        case .failed:
            .orange
        case .finalizationDelayed:
            .orange
        case .idle, .preparing, .stopping:
            .primary
        }
    }

    private var audioLevelAccessibilityValue: String {
        "\(Int((model.audioLevel * 100).rounded()))%"
    }

    private var capabilityDescription: String {
        if let errorMessage = model.capability.errorMessage {
            return errorMessage
        }
        return "首次使用需要允许麦克风权限，并下载适用于"
            + " \(model.selectedLocaleIdentifier) 的设备端模型。"
    }
}
#endif
