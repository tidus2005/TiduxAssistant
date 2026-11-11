import CodexMobilityCore
import Foundation

/// A lifecycle owned by code that is compiled and signed with the Mac app.
///
/// A JSON manifest can describe a module, but it cannot create an adapter. A module only
/// executes when an adapter with the same stable ID is explicitly registered here.
@MainActor
public protocol MacMobilityModuleAdapter: AnyObject {
    var moduleID: MobilityModuleID { get }

    func start()
    func stop()
}

public enum MacMobilityModuleRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case duplicateModuleID(MobilityModuleID)

    public var errorDescription: String? {
        switch self {
        case .duplicateModuleID(let id):
            "Mac 模块 adapter 重复注册：\(id.rawValue)。"
        }
    }
}

/// Reconciles a declarative module configuration with explicitly registered Mac adapters.
///
/// Call `applyConfiguration()` after a persisted setting changes. Reconciliation is
/// idempotent: an enabled adapter starts once, a disabled adapter stops once, and descriptors
/// without a compiled adapter are ignored.
@MainActor
public final class MacMobilityModuleRuntime {
    public let configurationStore: MobilityModuleConfigurationStore

    public var registeredModuleIDs: [MobilityModuleID] {
        adapters.keys.sorted()
    }

    public var runningModuleIDs: [MobilityModuleID] {
        runningIDs.sorted()
    }

    private var adapters: [MobilityModuleID: any MacMobilityModuleAdapter] = [:]
    private var runningIDs: Set<MobilityModuleID> = []

    public init(
        configurationStore: MobilityModuleConfigurationStore,
        adapters: [any MacMobilityModuleAdapter] = []
    ) throws {
        self.configurationStore = configurationStore
        for adapter in adapters {
            try register(adapter)
        }
    }

    /// Registers executable code that is already part of the signed app bundle.
    /// Registration never starts the adapter; `applyConfiguration()` remains the only gate.
    public func register(_ adapter: any MacMobilityModuleAdapter) throws {
        guard adapters[adapter.moduleID] == nil else {
            throw MacMobilityModuleRuntimeError.duplicateModuleID(adapter.moduleID)
        }
        adapters[adapter.moduleID] = adapter
    }

    /// Removes one adapter and stops it first when it is currently active.
    public func unregister(_ moduleID: MobilityModuleID) {
        if runningIDs.remove(moduleID) != nil {
            adapters[moduleID]?.stop()
        }
        adapters[moduleID] = nil
    }

    /// Applies the store's platform, availability, standard/experimental, and selection gates.
    public func applyConfiguration() {
        applyConfiguration(configurationStore.configuration)
    }

    /// Reconciles against the exact configuration emitted by `@Published`.
    /// `@Published` delivers its new value before the owning property can be
    /// read back, so subscribers should pass that value here instead of reading
    /// `configurationStore.configuration` synchronously from the callback.
    public func applyConfiguration(_ configuration: MobilityModuleConfiguration) {
        let moduleIDs = registeredModuleIDs

        // Stop disabled modules before starting newly enabled ones. This gives resource-owning
        // modules a deterministic hand-off when a configuration changes several toggles at once.
        for moduleID in moduleIDs
        where runningIDs.contains(moduleID) && !isEnabled(moduleID, in: configuration) {
            adapters[moduleID]?.stop()
            runningIDs.remove(moduleID)
        }

        for moduleID in moduleIDs
        where !runningIDs.contains(moduleID) && isEnabled(moduleID, in: configuration) {
            adapters[moduleID]?.start()
            runningIDs.insert(moduleID)
        }
    }

    /// Stops all active adapters without changing persisted module selections.
    public func stopAll() {
        for moduleID in runningModuleIDs {
            adapters[moduleID]?.stop()
        }
        runningIDs.removeAll()
    }

    public func isRunning(_ moduleID: MobilityModuleID) -> Bool {
        runningIDs.contains(moduleID)
    }

    private func isEnabled(
        _ moduleID: MobilityModuleID,
        in configuration: MobilityModuleConfiguration
    ) -> Bool {
        guard let descriptor = configurationStore.catalog.descriptor(for: moduleID) else {
            return false
        }
        return configuration.isEnabled(descriptor, on: configurationStore.platform)
    }
}
