#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI

@MainActor
struct MobileRootView: View {
    let model: MobileAppModel
    let showsRecordingIndicator: Bool
    let recordingScreenRequestID: UInt64

    @State private var navigationState = MobileRootNavigationState()

    init(
        model: MobileAppModel,
        showsRecordingIndicator: Bool = true,
        recordingScreenRequestID: UInt64 = 0
    ) {
        self.model = model
        self.showsRecordingIndicator = showsRecordingIndicator
        self.recordingScreenRequestID = recordingScreenRequestID
    }

    var body: some View {
        NavigationStack(path: $navigationState.path) {
            Group {
                switch navigationState.selectedSection {
                case .recording:
                    MobileRecordingView(model: model)
                case .history:
                    MobileHistoryView(model: model)
                case .settings:
                    MobileSettingsView(model: model)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if showsRecordingIndicator, model.isRecording {
                        GlobalRecordingIndicator(
                            elapsedLabel: model.elapsedLabel
                        ) {
                            showRecordingScreen()
                        }
                    }

                    Picker(
                        "听写页面",
                        selection: $navigationState.selectedSection
                    ) {
                        Label("录音", systemImage: "waveform")
                            .tag(MobileRootSection.recording)
                            .accessibilityIdentifier(
                                MobileAccessibilityIdentifier.recordingTab
                            )
                        Label(
                            "历史",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .tag(MobileRootSection.history)
                        .accessibilityIdentifier(
                            MobileAccessibilityIdentifier.historyTab
                        )
                        Label("设置", systemImage: "gearshape")
                            .tag(MobileRootSection.settings)
                            .accessibilityIdentifier(
                                MobileAccessibilityIdentifier.settingsTab
                            )
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier(
                        MobileAccessibilityIdentifier.rootTabView
                    )
                }
            }
        }
        .onChange(of: recordingScreenRequestID) {
            showRecordingScreen()
        }
    }

    private func showRecordingScreen() {
        navigationState.showRecordingScreen()
    }
}

struct GlobalRecordingIndicator: View {
    let elapsedLabel: String
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibilitySizeLabel
                } else {
                    standardLabel
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundStyle(.white)
            .background(Color.red)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在录音")
        .accessibilityValue("已录制 \(elapsedLabel)")
        .accessibilityHint("轻点返回录音页面")
        .accessibilityIdentifier(
            MobileAccessibilityIdentifier.globalRecordingIndicator
        )
    }

    private var standardLabel: some View {
        HStack(spacing: 10) {
            Label("正在录音", systemImage: "record.circle.fill")
                .font(.headline)

            Spacer(minLength: 8)

            Text(elapsedLabel)
                .font(.headline.monospacedDigit())

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
        }
    }

    private var accessibilitySizeLabel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("正在录音", systemImage: "record.circle.fill")
                .font(.headline)

            HStack(spacing: 8) {
                Text("已录制 \(elapsedLabel)")
                    .font(.body.monospacedDigit())

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
    }
}

enum MobileRootSection: Hashable {
    case recording
    case history
    case settings
}

struct MobileRootNavigationState {
    var selectedSection: MobileRootSection = .recording
    var path = NavigationPath()

    mutating func showRecordingScreen() {
        path = NavigationPath()
        selectedSection = .recording
    }
}

#Preview {
    MobileRootView(model: MobileAppModel())
}
#endif
