import CodexMobilityCore
import Foundation

/// Owns every Mac-side file-sync service as one module lifecycle, preventing a
/// disabled UI module from leaving the local-network server running.
@MainActor
final class MacFileSyncModuleAdapter: MacMobilityModuleAdapter {
    let moduleID: MobilityModuleID = .fileSync

    private let store: MacFileSyncStore
    private let server: MacSyncthingSyncServer
    private var lifecycleTask: Task<Void, Never>?

    init(store: MacFileSyncStore, server: MacSyncthingSyncServer) {
        self.store = store
        self.server = server
        store.suspendModuleAccess()
    }

    func start() {
        store.resumeModuleAccess()
        store.start()
        lifecycleTask?.cancel()
        lifecycleTask = Task { [server] in
            guard !Task.isCancelled else { return }
            await server.start()
        }
    }

    func stop() {
        server.suspend()
        store.suspendModuleAccess()
        store.shutdown()
        lifecycleTask?.cancel()
        lifecycleTask = Task { [server] in
            guard !Task.isCancelled else { return }
            await server.stop()
        }
    }

    func refreshCredentials() {
        lifecycleTask?.cancel()
        lifecycleTask = Task { [server] in
            guard !Task.isCancelled else { return }
            await server.refreshCredentials()
        }
    }
}
