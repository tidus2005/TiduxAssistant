@testable import CodexMobilityMacFeature
import CodexMobilityCore
import Foundation
import Testing

@Suite("Mac app model startup ordering")
@MainActor
struct MacMobilityAppModelStartupTests {
    @Test
    func enabledModulesRemainStoppedUntilTheAppExplicitlyStarts() throws {
        let moduleStore = MobilityModuleConfigurationStore(
            platform: .macOS,
            persistence: StartupModuleConfigurationPersistence()
        )
        let mobilityStore = MacMobilityStore(
            sampler: StartupSystemSampler(),
            policyPersistence: StartupPolicyPersistence()
        )
        let model = MacMobilityAppModel(
            store: mobilityStore,
            moduleStore: moduleStore,
            credentialVault: EmptyMacCredentialStore()
        )
        defer { model.shutdown() }

        let voiceInput = try #require(
            moduleStore.catalog.descriptor(for: .voiceInput)
        )
        #expect(moduleStore.isEnabled(voiceInput))
        #expect(model.moduleRuntime.runningModuleIDs.isEmpty)

        // Combine publishes configuration changes synchronously. Neither this
        // update nor the initial value may start Fn/microphone ownership before
        // AppDelegate has resolved a running legacy FlowType instance.
        moduleStore.setModule(voiceInput, selected: false)
        moduleStore.setModule(voiceInput, selected: true)

        #expect(model.moduleRuntime.runningModuleIDs.isEmpty)
    }
}

private final class StartupModuleConfigurationPersistence:
    MobilityModuleConfigurationPersisting {
    private var configuration: MobilityModuleConfiguration?

    func loadConfiguration() throws -> MobilityModuleConfiguration? {
        configuration
    }

    func saveConfiguration(_ configuration: MobilityModuleConfiguration) throws {
        self.configuration = configuration
    }
}

private final class StartupPolicyPersistence: MobilityPolicyPersisting {
    private var policy: MobilityPolicy?

    func loadPolicy() -> MobilityPolicy? {
        policy
    }

    func savePolicy(_ policy: MobilityPolicy) {
        self.policy = policy
    }
}

private final class StartupSystemSampler: MacSystemSampling, @unchecked Sendable {
    func start() {}
    func stop() {}

    func sample(mode: MobilityModeStatus, now: Date) -> MobilityDeviceStatus {
        MobilityDeviceStatus(
            deviceID: UUID(uuidString: "FDCB3E35-143E-4B2D-AAB7-FE51CFEA622E")!,
            deviceName: "Startup Test Mac",
            battery: MobilityBatteryStatus(
                levelPercent: 100,
                isCharging: true,
                isOnExternalPower: true
            ),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            mode: mode,
            helperReady: true,
            observedAt: now
        )
    }
}

private struct EmptyMacCredentialStore: MobilityMacCredentialStoring {
    func issueCredential(
        deviceID: UUID,
        deviceName: String,
        pairedAt: Date
    ) throws -> MobilityMacPairingCredential {
        MobilityMacPairingCredential(
            deviceID: deviceID,
            deviceName: deviceName,
            token: "unused-test-token",
            pairedAt: pairedAt
        )
    }

    func pairedDevices() throws -> [MobilityMacPairedDevice] {
        []
    }

    func credential(for deviceID: UUID) throws -> MobilityMacPairingCredential? {
        nil
    }

    func credential(matchingToken token: String) throws -> MobilityMacPairingCredential? {
        nil
    }

    func revokeCredential(for deviceID: UUID) throws {}
}
