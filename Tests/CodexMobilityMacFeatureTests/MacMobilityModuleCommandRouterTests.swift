@testable import CodexMobilityMacFeature
import CodexMobilityCore
import Foundation
import Testing

@Suite("Mac Mobility remote module gates")
@MainActor
struct MacMobilityModuleCommandRouterTests {
    @Test
    func remoteClosedLidProfileRequiresBothExperimentalGates() async throws {
        let moduleStore = MobilityModuleConfigurationStore(
            catalog: .builtIn,
            platform: .macOS,
            persistence: RouterConfigurationPersistence()
        )
        let downstream = RecordingMobilityCommandHandler()
        let router = MacMobilityModuleCommandRouter(
            moduleStore: moduleStore,
            downstream: downstream
        )

        var result = try await router.handleMobilityAction(
            .setMode(enabled: true, profile: .closedLidLabs)
        )
        #expect(!result.accepted)
        #expect(result.message.contains("合盖持续运行"))
        #expect(downstream.actions.isEmpty)

        let descriptor = try #require(moduleStore.catalog.descriptor(for: .closedLidLabs))
        moduleStore.setModule(descriptor, selected: true)
        result = try await router.handleMobilityAction(
            .setMode(enabled: true, profile: .closedLidLabs)
        )
        #expect(!result.accepted)
        #expect(downstream.actions.isEmpty)

        moduleStore.setExperimentalModulesEnabled(true)
        result = try await router.handleMobilityAction(
            .setMode(enabled: true, profile: .closedLidLabs)
        )
        #expect(result.accepted)
        #expect(downstream.actions == [.setMode(enabled: true, profile: .closedLidLabs)])
    }

    @Test
    func remoteIdleGuardProfileUsesTravelRuntimeGate() async throws {
        let moduleStore = MobilityModuleConfigurationStore(
            catalog: .builtIn,
            platform: .macOS,
            persistence: RouterConfigurationPersistence()
        )
        let downstream = RecordingMobilityCommandHandler()
        let router = MacMobilityModuleCommandRouter(
            moduleStore: moduleStore,
            downstream: downstream
        )

        let result = try await router.handleMobilityAction(
            .setMode(enabled: true, profile: .idleGuard)
        )

        #expect(result.accepted)
        #expect(downstream.actions == [.setMode(enabled: true, profile: .idleGuard)])
    }

    @Test
    func dedicatedBLEFileSyncPathRejectsDisabledModuleWithoutCallingDownstream() async throws {
        let moduleStore = MobilityModuleConfigurationStore(
            catalog: .builtIn,
            platform: .macOS,
            persistence: RouterConfigurationPersistence()
        )
        let downstream = RecordingMobilityCommandHandler()
        let router = MacMobilityModuleCommandRouter(
            moduleStore: moduleStore,
            downstream: downstream
        )
        let descriptor = try #require(moduleStore.catalog.descriptor(for: .fileSync))
        let message = SyncWireMessage.requestOffers(SyncOfferRequest())
        let phoneDeviceID = UUID()
        var callCount = 0

        moduleStore.setModule(descriptor, selected: false)
        let rejected = await router.handleFileSyncMessage(
            message,
            from: phoneDeviceID
        ) { _, _ in
            callCount += 1
            return []
        }

        #expect(callCount == 0)
        let failure = try #require(rejected.first?.failureValue)
        #expect(failure.code == .unavailable)
        #expect(failure.message.contains("双向文件同步"))
        #expect(failure.retryable == false)

        moduleStore.setModule(descriptor, selected: true)
        let accepted = await router.handleFileSyncMessage(
            message,
            from: phoneDeviceID
        ) { received, deviceID in
            callCount += 1
            #expect(received == message)
            #expect(deviceID == phoneDeviceID)
            return []
        }

        #expect(accepted.isEmpty)
        #expect(callCount == 1)
    }

    @Test
    func publicationGatesTrackVisibleStandardModuleSwitches() throws {
        let moduleStore = MobilityModuleConfigurationStore(
            catalog: .builtIn,
            platform: .macOS,
            persistence: RouterConfigurationPersistence()
        )
        let router = MacMobilityModuleCommandRouter(
            moduleStore: moduleStore,
            downstream: RecordingMobilityCommandHandler()
        )
        let status = try #require(moduleStore.catalog.descriptor(for: .deviceStatus))
        let fileSync = try #require(moduleStore.catalog.descriptor(for: .fileSync))

        #expect(router.allowsStatusPublication)
        #expect(router.allowsFileSync)

        moduleStore.setModule(status, selected: false)
        moduleStore.setModule(fileSync, selected: false)
        #expect(!router.allowsStatusPublication)
        #expect(!router.allowsFileSync)

        moduleStore.setModule(status, selected: true)
        moduleStore.setModule(fileSync, selected: true)
        #expect(router.allowsStatusPublication)
        #expect(router.allowsFileSync)
    }
}

private extension SyncWireMessage {
    var failureValue: SyncFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

@MainActor
private final class RecordingMobilityCommandHandler: MobilityMacCommandHandling {
    private(set) var actions: [Action] = []

    func handleMobilityAction(_ action: Action) async throws -> MobilityMacCommandOutcome {
        actions.append(action)
        return MobilityMacCommandOutcome(accepted: true, message: "accepted")
    }
}

private final class RouterConfigurationPersistence: MobilityModuleConfigurationPersisting {
    private var configuration: MobilityModuleConfiguration?

    func loadConfiguration() throws -> MobilityModuleConfiguration? {
        configuration
    }

    func saveConfiguration(_ configuration: MobilityModuleConfiguration) throws {
        self.configuration = configuration
    }
}
