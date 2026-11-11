import AppKit
import SwiftUI

public enum OverlayPanelState: Equatable, Sendable {
    case idle
    case recording(text: String, level: Double)
    case processing(text: String)
    case result(text: String)
    case error(text: String)
}

/// Owns the combined App's transient, nonactivating voice-input HUD.
///
/// The panel is the narrow AppKit boundary. Its body stays in SwiftUI and can
/// be replaced through either `update(_:)` or the public view-builder update.
@MainActor
public final class OverlayPanelController {
    private static let panelSize = NSSize(width: 430, height: 68)
    private static let bottomInset: CGFloat = 42

    private let panel: NonActivatingOverlayPanel
    private let hostingView: NSHostingView<AnyView>
    private var hideTask: Task<Void, Never>?
    private var state: OverlayPanelState = .idle
    private var presentationScreen: NSScreen?

    public init() {
        let contentRect = NSRect(origin: .zero, size: Self.panelSize)
        panel = NonActivatingOverlayPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = NSHostingView(
            rootView: AnyView(OverlayBarView(state: .idle))
        )

        configurePanel()
    }

    public var isVisible: Bool {
        panel.isVisible
    }

    public var currentState: OverlayPanelState {
        state
    }

    /// Updates the built-in SwiftUI HUD and presents it without activating
    /// this App or disturbing the target application's first responder.
    public func update(_ newState: OverlayPanelState) {
        hideTask?.cancel()
        hideTask = nil
        state = newState

        guard newState != .idle else {
            hostingView.rootView = AnyView(OverlayBarView(state: .idle))
            hideImmediately()
            return
        }

        hostingView.rootView = AnyView(OverlayBarView(state: newState))
        showWithoutActivation()
    }

    /// Public narrow bridge for callers that need to supply a custom SwiftUI
    /// representation while retaining this controller's focus-safe panel.
    public func update<Content: View>(
        @ViewBuilder content: () -> Content
    ) {
        hideTask?.cancel()
        hideTask = nil
        hostingView.rootView = AnyView(content())
        showWithoutActivation()
    }

    public func showRecording(text: String = "", level: Double = 0) {
        update(.recording(text: text, level: min(max(level, 0), 1)))
    }

    public func showProcessing(text: String = "") {
        update(.processing(text: text))
    }

    public func showResult(text: String = "已写入") {
        update(.result(text: text))
        hide(after: 1.4)
    }

    public func showError(text: String) {
        update(.error(text: text))
        hide(after: 2.8)
    }

    public func hide() {
        hideTask?.cancel()
        hideTask = nil
        state = .idle
        hideImmediately()
    }

    /// Schedules a nonblocking hide. A subsequent update cancels this timer.
    public func hide(after delay: TimeInterval) {
        hideTask?.cancel()

        guard delay > 0 else {
            hide()
            return
        }

        hideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else {
                return
            }
            self.state = .idle
            self.hideTask = nil
            self.hideImmediately()
        }
    }

    private func configurePanel() {
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hostingView.autoresizingMask = [.width, .height]
    }

    private func showWithoutActivation() {
        if presentationScreen == nil {
            presentationScreen = screenAtPointer()
        }
        positionOnRelevantScreen()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.order(.above, relativeTo: 0)
        }
    }

    private func hideImmediately() {
        panel.orderOut(nil)
        presentationScreen = nil
    }

    private func positionOnRelevantScreen() {
        guard let screen = presentationScreen ?? screenAtPointer() else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - Self.panelSize.width / 2,
            y: visibleFrame.minY + Self.bottomInset
        )
        panel.setFrameOrigin(origin)
    }

    private func screenAtPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first {
            NSMouseInRect(pointer, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

@MainActor
private final class NonActivatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private struct OverlayBarView: View {
    let state: OverlayPanelState

    private var title: String {
        switch state {
        case .idle:
            return "Codex 语音输入"
        case let .recording(text, _):
            return text.isEmpty ? "正在聆听" : text
        case let .processing(text):
            return text.isEmpty ? "正在整理" : text
        case let .result(text):
            return text.isEmpty ? "已写入" : text
        case let .error(text):
            return text.isEmpty ? "未能完成" : text
        }
    }

    private var systemImage: String {
        switch state {
        case .idle:
            return "waveform"
        case .recording:
            return "mic.fill"
        case .processing:
            return "sparkles"
        case .result:
            return "checkmark"
        case .error:
            return "exclamationmark"
        }
    }

    private var accent: Color {
        switch state {
        case .idle:
            return .secondary
        case .recording:
            return .red
        case .processing:
            return .purple
        case .result:
            return .green
        case .error:
            return .orange
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.16))
                    .frame(width: 36, height: 36)

                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailingStatus
        }
        .padding(.horizontal, 15)
        .frame(width: 430, height: 60)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .frame(width: 430, height: 68)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch state {
        case let .recording(_, level):
            AudioMeter(level: level, color: accent)
                .frame(width: 45, height: 25)
                .accessibilityLabel("麦克风音量")
                .accessibilityValue("\(Int(min(max(level, 0), 1) * 100))%")
        case .processing:
            ProgressView()
                .controlSize(.small)
                .tint(accent)
        case .result, .error, .idle:
            EmptyView()
        }
    }
}

private struct AudioMeter: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                let distance = abs(Double(index) - 3) / 3
                let envelope = 1 - (distance * 0.48)
                let normalizedLevel = max(0.12, min(level, 1))

                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 4 + (18 * normalizedLevel * envelope))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
