@testable import CodexMobilityMacFeature
import CodexMobilityCore
import Foundation
import Testing

@Suite("Mac Mobility module runtime")
@MainActor
struct MacMobilityModuleRuntimeTests {
    @Test
    func repeatedApplyStartsAndStopsOnlyOnStateTransitions() throws {
        let descriptor = try makeDescriptor(
            id: "com.example.mobility.runtime",
            tier: .standard
        )
        let store = try makeStore(descriptors: [descriptor])
        let log = LifecycleLog()
        let adapter = RecordingAdapter(moduleID: descriptor.id, log: log)
        let runtime = try MacMobilityModuleRuntime(
            configurationStore: store,
            adapters: [adapter]
        )

        runtime.applyConfiguration()
        runtime.applyConfiguration()
        #expect(log.entries == ["start:\(descriptor.id.rawValue)"])
        #expect(runtime.runningModuleIDs == [descriptor.id])

        store.setModule(descriptor, selected: false)
        runtime.applyConfiguration()
        runtime.applyConfiguration()
        #expect(log.entries == [
            "start:\(descriptor.id.rawValue)",
            "stop:\(descriptor.id.rawValue)"
        ])
        #expect(!runtime.isRunning(descriptor.id))

        store.setModule(descriptor, selected: true)
        runtime.applyConfiguration()
        #expect(log.entries == [
            "start:\(descriptor.id.rawValue)",
            "stop:\(descriptor.id.rawValue)",
            "start:\(descriptor.id.rawValue)"
        ])
    }

    @Test
    func experimentalAdapterRequiresBothStoreGates() throws {
        let descriptor = try makeDescriptor(
            id: "com.example.mobility.runtime-labs",
            tier: .experimental
        )
        let store = try makeStore(descriptors: [descriptor])
        let log = LifecycleLog()
        let runtime = try MacMobilityModuleRuntime(
            configurationStore: store,
            adapters: [RecordingAdapter(moduleID: descriptor.id, log: log)]
        )

        runtime.applyConfiguration()
        store.setModule(descriptor, selected: true)
        runtime.applyConfiguration()
        #expect(log.entries.isEmpty)

        store.setExperimentalModulesEnabled(true)
        runtime.applyConfiguration()
        #expect(log.entries == ["start:\(descriptor.id.rawValue)"])

        store.setExperimentalModulesEnabled(false)
        runtime.applyConfiguration()
        #expect(log.entries == [
            "start:\(descriptor.id.rawValue)",
            "stop:\(descriptor.id.rawValue)"
        ])
    }

    @Test
    func configuredDescriptorWithoutRegisteredCodeCannotExecute() throws {
        let compiledDescriptor = try makeDescriptor(
            id: "com.example.mobility.compiled",
            tier: .standard
        )
        let configuredDescriptor = try makeDescriptor(
            id: "com.friend.mobility.config-only",
            tier: .standard
        )
        let builtInCatalog = try MobilityModuleCatalog(builtIn: [compiledDescriptor])
        let manifest = try MobilityModuleManifest(modules: [configuredDescriptor])
        let catalog = try builtInCatalog.adding(manifest: manifest)
        let store = makeStore(catalog: catalog)
        let log = LifecycleLog()
        let runtime = try MacMobilityModuleRuntime(
            configurationStore: store,
            adapters: [RecordingAdapter(moduleID: compiledDescriptor.id, log: log)]
        )

        #expect(store.isEnabled(configuredDescriptor.id))
        runtime.applyConfiguration()

        #expect(runtime.registeredModuleIDs == [compiledDescriptor.id])
        #expect(runtime.runningModuleIDs == [compiledDescriptor.id])
        #expect(log.entries == ["start:\(compiledDescriptor.id.rawValue)"])
    }

    @Test
    func duplicateRegistrationIsRejectedWithoutReplacingOriginalAdapter() throws {
        let descriptor = try makeDescriptor(
            id: "com.example.mobility.duplicate",
            tier: .standard
        )
        let store = try makeStore(descriptors: [descriptor])
        let originalLog = LifecycleLog()
        let replacementLog = LifecycleLog()
        let runtime = try MacMobilityModuleRuntime(configurationStore: store)

        try runtime.register(RecordingAdapter(moduleID: descriptor.id, log: originalLog))
        #expect(throws: MacMobilityModuleRuntimeError.duplicateModuleID(descriptor.id)) {
            try runtime.register(
                RecordingAdapter(moduleID: descriptor.id, log: replacementLog)
            )
        }

        runtime.applyConfiguration()
        #expect(originalLog.entries == ["start:\(descriptor.id.rawValue)"])
        #expect(replacementLog.entries.isEmpty)
    }

    @Test
    func unregisterAndStopAllAreIdempotent() throws {
        let first = try makeDescriptor(
            id: "com.example.mobility.first",
            tier: .standard
        )
        let second = try makeDescriptor(
            id: "com.example.mobility.second",
            tier: .standard
        )
        let store = try makeStore(descriptors: [first, second])
        let log = LifecycleLog()
        let runtime = try MacMobilityModuleRuntime(
            configurationStore: store,
            adapters: [
                RecordingAdapter(moduleID: first.id, log: log),
                RecordingAdapter(moduleID: second.id, log: log)
            ]
        )
        runtime.applyConfiguration()

        runtime.unregister(first.id)
        runtime.unregister(first.id)
        runtime.stopAll()
        runtime.stopAll()

        #expect(log.entries == [
            "start:\(first.id.rawValue)",
            "start:\(second.id.rawValue)",
            "stop:\(first.id.rawValue)",
            "stop:\(second.id.rawValue)"
        ])
        #expect(runtime.runningModuleIDs.isEmpty)
        #expect(runtime.registeredModuleIDs == [second.id])
    }

    private func makeStore(
        descriptors: [MobilityModuleDescriptor]
    ) throws -> MobilityModuleConfigurationStore {
        makeStore(catalog: try MobilityModuleCatalog(builtIn: descriptors))
    }

    private func makeStore(
        catalog: MobilityModuleCatalog
    ) -> MobilityModuleConfigurationStore {
        MobilityModuleConfigurationStore(
            catalog: catalog,
            platform: .macOS,
            persistence: InMemoryModuleConfigurationPersistence()
        )
    }

    private func makeDescriptor(
        id rawID: String,
        tier: MobilityModuleTier
    ) throws -> MobilityModuleDescriptor {
        let id = try #require(MobilityModuleID(rawValue: rawID))
        let capability = try #require(
            MobilityModuleCapability(rawValue: "example.\(id.rawValue.split(separator: ".").last ?? "module")")
        )
        return try MobilityModuleDescriptor(
            id: id,
            title: "Runtime test module",
            summary: "A compiled adapter used by the Mac runtime test suite.",
            symbolName: "puzzlepiece.extension",
            tier: tier,
            supportedPlatforms: [.macOS],
            capabilities: [capability]
        )
    }
}

@MainActor
private final class LifecycleLog {
    var entries: [String] = []
}

@MainActor
private final class RecordingAdapter: MacMobilityModuleAdapter {
    let moduleID: MobilityModuleID
    private let log: LifecycleLog

    init(moduleID: MobilityModuleID, log: LifecycleLog) {
        self.moduleID = moduleID
        self.log = log
    }

    func start() {
        log.entries.append("start:\(moduleID.rawValue)")
    }

    func stop() {
        log.entries.append("stop:\(moduleID.rawValue)")
    }
}

private final class InMemoryModuleConfigurationPersistence:
    MobilityModuleConfigurationPersisting {
    private var configuration: MobilityModuleConfiguration?

    func loadConfiguration() throws -> MobilityModuleConfiguration? {
        configuration
    }

    func saveConfiguration(_ configuration: MobilityModuleConfiguration) throws {
        self.configuration = configuration
    }
}
