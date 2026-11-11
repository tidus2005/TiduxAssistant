import CodexMobilityCore
import Foundation

/// The safety sampler remains available to the dashboard, but disabling the
/// travel module always releases its power assertion and stops mobility mode.
@MainActor
final class MacTravelRuntimeModuleAdapter: MacMobilityModuleAdapter {
    let moduleID: MobilityModuleID = .travelRuntime

    private let store: MacMobilityStore

    init(store: MacMobilityStore) {
        self.store = store
    }

    func start() {}

    func stop() {
        if store.mode.isEnabled {
            store.stop(reason: "“移动联网运行”模块已在设置中关闭。")
        }
    }
}
