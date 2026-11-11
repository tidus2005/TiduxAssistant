import AppKit
import CodexMobilityMacFeature
import SwiftUI

@MainActor
private enum MacAppContext {
    static let model = MacMobilityAppModel()
    static let caffeine = model.caffeineController
    static let remoteDashboard = MacRemoteDashboardController(
        store: model.store,
        powerPolicyStore: model.powerPolicyStore,
        closedLidSessionController: model.closedLidSessionController,
        lidCloseLockController: model.lidCloseLockController,
        hotspotStore: model.hotspotAutomationStore,
        fileSyncStore: model.fileSyncStore
    )
    static var dashboardWindow: NSWindow?

    static func copyRemoteDashboardLink() {
        guard let link = remoteDashboard.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    static func copyLANRemoteDashboardLink() {
        guard let link = remoteDashboard.lanShareURL ?? remoteDashboard.localShareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    static func openRemoteDashboard() {
        guard let link = remoteDashboard.shareURL,
              let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    static func showDashboard() {
        let window: NSWindow
        if let existing = dashboardWindow {
            window = existing
        } else {
            let hostingController = NSHostingController(
                rootView: MacDashboardRootView(model: model)
            )
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.identifier = NSUserInterfaceItemIdentifier("mobility-dashboard")
            window.title = "Tidux助手"
            window.contentMinSize = NSSize(width: 900, height: 620)
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.center()
            dashboardWindow = window
        }

        window.makeKeyAndOrderFront(nil)
    }
}

private struct MacDashboardRootView: View {
    @ObservedObject var model: MacMobilityAppModel

    var body: some View {
        MobilityDashboardView(
            store: model.store,
            moduleStore: model.moduleStore,
            powerPolicyStore: model.powerPolicyStore,
            voiceInputStore: model.voiceInputStore,
            fileSyncStore: model.fileSyncStore,
            hotspotAutomationStore: model.hotspotAutomationStore,
            closedLidSessionController: model.closedLidSessionController,
            caffeineController: MacAppContext.caffeine,
            pairingState: model.bluetoothState,
            pairedDevices: model.pairedDevices,
            pairingManagementErrorMessage: model.pairingManagementErrorMessage,
            onRegeneratePairingCode: model.regeneratePairingCode,
            onRevokePairedDevice: model.revokePairedDevice
        )
    }
}

private struct MobilityMenuBarLabel: View {
    @ObservedObject var store: MacMobilityStore

    var body: some View {
        Label(
            "Tidux助手",
            systemImage: store.mode.phase.mobilitySymbolName
        )
    }
}

@MainActor
final class CodexWatchPetMacAppDelegate: NSObject, NSApplicationDelegate {
    private static let legacyBundleIdentifier = "com.tidux.flowtype"
    private var singleInstanceLock: MacSingleInstanceLock?
    private var legacyLaunchObserver: NSObjectProtocol?

    override init() {
        do {
            singleInstanceLock = try MacSingleInstanceLock.acquire()
        } catch MacSingleInstanceLockError.alreadyRunning {
            Self.activateExistingInstance()
            exit(EXIT_SUCCESS)
        } catch {
            NSLog(
                "CodexWatchPet single-instance startup failed: %@",
                error.localizedDescription
            )
            exit(EXIT_FAILURE)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        observeLegacyFlowTypeLaunches()
        guard resolveLegacyFlowTypeConflict() else {
            NSApp.terminate(nil)
            return
        }
        MacAppContext.model.onShowDashboard = MacAppContext.showDashboard
        MacAppContext.model.start()
        MacAppContext.remoteDashboard.start()
        MacAppContext.showDashboard()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MacAppContext.showDashboard()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MacAppContext.model.applicationDidBecomeActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let legacyLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                legacyLaunchObserver
            )
            self.legacyLaunchObserver = nil
        }
        MacAppContext.remoteDashboard.stop()
        MacAppContext.model.shutdown()
        MacAppContext.caffeine.stop()
    }

    private static func activateExistingInstance() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.tidux.CodexWatchPet.mac")
            .first { $0.processIdentifier != currentPID }

        _ = existingApp?.activate(options: [.activateAllWindows])
    }

    private func resolveLegacyFlowTypeConflict() -> Bool {
        let legacyApplications = NSWorkspace.shared.runningApplications
            .filter(Self.isLegacyFlowType)
            .filter { !$0.isTerminated }
        guard !legacyApplications.isEmpty else { return true }

        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "旧版 FlowType 正在运行"
        confirmation.informativeText =
            "FlowType 和 Tidux助手不能同时监听 Fn 与麦克风。"
            + "继续会正常退出旧版 FlowType，不会删除它的历史或设置。"
        confirmation.addButton(withTitle: "退出 FlowType 并继续")
        confirmation.addButton(withTitle: "退出 Tidux助手")
        guard confirmation.runModal() == .alertFirstButtonReturn else {
            return false
        }

        guard terminateLegacyApplications(legacyApplications) else {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "无法退出旧版 FlowType"
            failure.informativeText =
                "请手动退出 FlowType 后再打开 Tidux助手；"
                + "为避免重复监听，本次不会启动语音输入。"
            failure.addButton(withTitle: "退出")
            failure.runModal()
            return false
        }
        return true
    }

    private func observeLegacyFlowTypeLaunches() {
        legacyLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleLegacyFlowTypeLaunch(application)
            }
        }
    }

    private func handleLegacyFlowTypeLaunch(
        _ application: NSRunningApplication
    ) {
        guard Self.isLegacyFlowType(application),
              !application.isTerminated else {
            return
        }

        NSLog(
            "Stopping legacy FlowType pid=%d to preserve the single voice-input owner",
            application.processIdentifier
        )
        guard terminateLegacyApplications([application]) else {
            MacAppContext.model.shutdown()

            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "检测到无法退出的旧版 FlowType"
            failure.informativeText =
                "为避免两个程序同时监听 Fn 与麦克风，Tidux助手将退出。"
            failure.addButton(withTitle: "退出")
            failure.runModal()
            NSApp.terminate(nil)
            return
        }
    }

    private func terminateLegacyApplications(
        _ applications: [NSRunningApplication]
    ) -> Bool {
        for application in applications {
            _ = application.terminate()
        }

        let deadline = Date().addingTimeInterval(3)
        while applications.contains(where: { !$0.isTerminated }),
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return applications.allSatisfy(\.isTerminated)
    }

    private static func isLegacyFlowType(
        _ application: NSRunningApplication
    ) -> Bool {
        if application.bundleIdentifier == legacyBundleIdentifier {
            return true
        }

        guard application.bundleIdentifier == nil,
              application.executableURL?.lastPathComponent == "FlowType",
              let executablePath = application.executableURL?.path else {
            return false
        }
        return executablePath.contains("/FlowType/.build/")
    }
}

@main
struct CodexWatchPetMacApp: App {
    @NSApplicationDelegateAdaptor(CodexWatchPetMacAppDelegate.self) private var appDelegate
    @StateObject private var model = MacAppContext.model

    var body: some Scene {
        MenuBarExtra {
            MobilityMenuBarView(
                store: model.store,
                closedLidSessionController: model.closedLidSessionController,
                hotspotAutomationStore: model.hotspotAutomationStore,
                moduleStore: model.moduleStore,
                voiceInputStore: model.voiceInputStore,
                powerPolicyStore: model.powerPolicyStore,
                remoteDashboard: MacAppContext.remoteDashboard,
                caffeineController: MacAppContext.caffeine,
                pairingState: model.bluetoothState,
                onRegeneratePairingCode: model.regeneratePairingCode,
                onOpenDashboard: MacAppContext.showDashboard
            )
        } label: {
            MobilityMenuBarLabel(store: model.store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MobilitySettingsView(
                store: model.store,
                fileSyncStore: model.fileSyncStore,
                moduleStore: model.moduleStore,
                powerPolicyStore: model.powerPolicyStore,
                lidCloseLockController: model.lidCloseLockController,
                hotspotAutomationStore: model.hotspotAutomationStore,
                voiceInputStore: model.voiceInputStore
            )
        }
        .commands {
            CommandMenu("手机控制台") {
                Button("复制公网安全访问链接") {
                    MacAppContext.copyRemoteDashboardLink()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(MacAppContext.remoteDashboard.shareURL == nil)

                Button("复制局域网安全访问链接") {
                    MacAppContext.copyLANRemoteDashboardLink()
                }
                .disabled(
                    MacAppContext.remoteDashboard.lanShareURL == nil
                        && MacAppContext.remoteDashboard.localShareURL == nil
                )

                Button("在浏览器打开公网控制台") {
                    MacAppContext.openRemoteDashboard()
                }
                .disabled(MacAppContext.remoteDashboard.shareURL == nil)
            }
        }
    }
}
