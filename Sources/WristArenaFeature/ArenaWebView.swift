#if os(iOS) || os(macOS)
import SwiftUI
import WebKit

/// The original offline V0.8 game, packaged with the app. No server, account or remote scripts.
public struct ArenaWebView: View {
    public var isActive: Bool
    private var onReturnToAssistant: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    public init(isActive: Bool = true, onReturnToAssistant: (() -> Void)? = nil) {
        self.isActive = isActive; self.onReturnToAssistant = onReturnToAssistant
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("表盘大作战", systemImage: "gamecontroller.fill").font(.headline)
                Spacer()
                if let onReturnToAssistant {
                    Button("回到 Codex", action: onReturnToAssistant)
                        .accessibilityIdentifier("arena.returnAssistant")
                }
            }.padding()
            LocalArenaWebContent(isActive: isActive && scenePhase == .active)
        }
        .navigationTitle("表盘大作战")
    }
}
@MainActor
private final class ArenaWebCoordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // This self-contained game never needs to leave its bundled file origin.
        navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }
}
@MainActor
private func makeArenaWebView(coordinator: ArenaWebCoordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let view = WKWebView(frame:.zero, configuration:configuration)
    view.navigationDelegate = coordinator
    view.isInspectable = false
    if let url = Bundle.module.url(forResource:"native", withExtension:"html", subdirectory:"Web") {
        view.loadFileURL(url, allowingReadAccessTo:url.deletingLastPathComponent())
    }
    return view
}
#if os(iOS)
private struct LocalArenaWebContent: UIViewRepresentable {
    var isActive: Bool
    func makeCoordinator() -> ArenaWebCoordinator { ArenaWebCoordinator() }
    func makeUIView(context: Context) -> WKWebView { makeArenaWebView(coordinator:context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {
        if !isActive { view.evaluateJavaScript("window.__codexPause?.()", completionHandler:nil) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: ArenaWebCoordinator) {
        view.evaluateJavaScript("window.__codexPause?.()", completionHandler:nil)
    }
}
#else
private struct LocalArenaWebContent: NSViewRepresentable {
    var isActive: Bool
    func makeCoordinator() -> ArenaWebCoordinator { ArenaWebCoordinator() }
    func makeNSView(context: Context) -> WKWebView { makeArenaWebView(coordinator:context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {
        if !isActive { view.evaluateJavaScript("window.__codexPause?.()", completionHandler:nil) }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: ArenaWebCoordinator) {
        view.evaluateJavaScript("window.__codexPause?.()", completionHandler:nil)
    }
}
#endif
#endif
