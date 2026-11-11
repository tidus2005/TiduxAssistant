import CodexMobilityCore

@MainActor
protocol MacVoiceInputLifecycle: AnyObject {
    func start() async
    func refreshPermissions() async
    func shutdown()
}

extension MacVoiceInputStore: MacVoiceInputLifecycle {}

@MainActor
final class MacVoiceInputModuleAdapter: MacMobilityModuleAdapter {
    let moduleID: MobilityModuleID = .voiceInput

    private let store: any MacVoiceInputLifecycle
    private var startupTask: Task<Void, Never>?
    private var activationRefreshTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var isEnabled = false

    init(store: any MacVoiceInputLifecycle) {
        self.store = store
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        startupTask = Task { [weak self, store] in
            guard let self else { return }
            await store.start()
            guard generation == self.lifecycleGeneration else { return }
            self.startupTask = nil
        }
    }

    func applicationDidBecomeActive() {
        guard isEnabled else { return }
        let generation = lifecycleGeneration
        let pendingStartup = startupTask
        activationRefreshTask?.cancel()
        activationRefreshTask = Task { [weak self, store] in
            await pendingStartup?.value
            guard !Task.isCancelled else { return }
            guard let self,
                  self.isEnabled,
                  generation == self.lifecycleGeneration else {
                return
            }
            await store.refreshPermissions()
            guard !Task.isCancelled,
                  self.isEnabled,
                  generation == self.lifecycleGeneration else {
                return
            }
            self.activationRefreshTask = nil
        }
    }

    func stop() {
        isEnabled = false
        lifecycleGeneration &+= 1
        startupTask?.cancel()
        startupTask = nil
        activationRefreshTask?.cancel()
        activationRefreshTask = nil
        store.shutdown()
    }
}
