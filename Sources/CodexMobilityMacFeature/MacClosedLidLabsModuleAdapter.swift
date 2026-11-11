import CodexMobilityCore
import Foundation

/// Releases the App-owned Idle Guard when the closed-lid experiment is turned
/// off. The system-wide SleepDisabled policy is intentionally left untouched;
/// changing that policy remains an explicit, administrator-authorized Mac action.
@MainActor
final class MacClosedLidLabsModuleAdapter: MacMobilityModuleAdapter {
    let moduleID: MobilityModuleID = .closedLidLabs

    private let store: MacMobilityStore

    init(store: MacMobilityStore) {
        self.store = store
    }

    func start() {}

    func stop() {
        guard store.mode.profile == .closedLidLabs,
              store.mode.phase != .off else {
            return
        }
        store.stop(reason: "“合盖持续运行”实验模块已在设置中关闭。")
    }
}
