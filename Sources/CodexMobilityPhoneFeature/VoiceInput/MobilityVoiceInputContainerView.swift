#if os(iOS) && !targetEnvironment(macCatalyst)
import Observation
import SwiftUI

/// Process-owned voice-input state shared by the app shell and the voice tab.
///
/// Hoisting this runtime above the outer `TabView` keeps recording state and
/// lifecycle handling visible even while another Codex Watch Pet tab is open.
@MainActor
@Observable
public final class MobilityVoiceInputRuntime {
    let model: MobileAppModel
    private(set) var recordingScreenRequestID: UInt64 = 0

    public init() {
        self.model = MobileAppModel()
    }

    init(model: MobileAppModel) {
        self.model = model
    }

    public var isRecording: Bool {
        model.isRecording
    }

    public var elapsedLabel: String {
        model.elapsedLabel
    }

    public func prepare() async {
        await model.prepare()
    }

    public func handleScenePhase(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            model.handleAppReturnedToForeground()
        case .inactive:
            model.handleAppBecameInactive()
        case .background:
            let eventGeneration = model.beginBackgroundTransition()
            Task {
                await model.handleAppMovedToBackground(
                    eventGeneration: eventGeneration
                )
            }
        @unknown default:
            break
        }
    }

    public func requestRecordingScreen() {
        recordingScreenRequestID &+= 1
    }
}

/// The single app-facing entry point for iPhone voice input.
///
/// The no-argument initializer owns a standalone runtime. The unified
/// CodexWatchPet app injects its process-owned runtime so the outer app shell
/// can show the recording indicator across every top-level tab.
@MainActor
public struct MobilityVoiceInputContainerView: View {
    @State private var runtime: MobilityVoiceInputRuntime
    @Environment(\.scenePhase) private var scenePhase
    private let managesScenePhase: Bool

    public init() {
        _runtime = State(initialValue: MobilityVoiceInputRuntime())
        managesScenePhase = true
    }

    public init(runtime: MobilityVoiceInputRuntime) {
        _runtime = State(initialValue: runtime)
        managesScenePhase = false
    }

    public var body: some View {
        MobileRootView(
            model: runtime.model,
            showsRecordingIndicator: managesScenePhase,
            recordingScreenRequestID: runtime.recordingScreenRequestID
        )
            .task {
                await runtime.prepare()
            }
            .onChange(of: scenePhase) {
                if managesScenePhase {
                    runtime.handleScenePhase(scenePhase)
                }
            }
    }
}

/// App-shell recording banner that stays visible across all top-level tabs.
@MainActor
public struct MobilityVoiceInputRecordingIndicator: View {
    private let runtime: MobilityVoiceInputRuntime
    private let onOpenVoiceInput: () -> Void

    public init(
        runtime: MobilityVoiceInputRuntime,
        onOpenVoiceInput: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.onOpenVoiceInput = onOpenVoiceInput
    }

    public var body: some View {
        if runtime.isRecording {
            GlobalRecordingIndicator(
                elapsedLabel: runtime.elapsedLabel
            ) {
                runtime.requestRecordingScreen()
                onOpenVoiceInput()
            }
        }
    }
}
#endif
