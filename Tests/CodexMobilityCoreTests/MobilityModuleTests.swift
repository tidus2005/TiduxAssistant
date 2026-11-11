import CodexMobilityCore
import Foundation
import Testing

@Suite("Mobility module architecture")
struct MobilityModuleTests {
    @Test
    func stableIdentifiersRejectNamesThatWouldDriftOrEscapeConfiguration() throws {
        #expect(MobilityModuleID(rawValue: "com.example.mobility.weather") != nil)
        #expect(MobilityModuleID(rawValue: "Weather Module") == nil)
        #expect(MobilityModuleID(rawValue: "com.example..weather") == nil)
        #expect(MobilityModuleID(rawValue: "com.example.weather-") == nil)
        #expect(MobilityModuleID(rawValue: "COM.EXAMPLE.WEATHER") == nil)

        let invalidJSON = Data(#""com.example.Bad""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MobilityModuleID.self, from: invalidJSON)
        }
    }

    @Test
    func standardModulesAreOnByDefaultButExperimentsNeedBothExplicitSwitches() throws {
        let standard = try makeDescriptor(
            id: "com.example.mobility.standard",
            tier: .standard
        )
        let experiment = try makeDescriptor(
            id: "com.example.mobility.experiment",
            tier: .experimental
        )
        var configuration = MobilityModuleConfiguration()

        #expect(configuration.isEnabled(standard, on: .macOS))
        #expect(!configuration.isSelected(experiment))
        #expect(!configuration.isEnabled(experiment, on: .macOS))

        configuration.experimentalModulesEnabled = true
        #expect(!configuration.isEnabled(experiment, on: .macOS))

        configuration.setSelected(true, for: experiment.id)
        #expect(configuration.isSelected(experiment))
        #expect(configuration.isEnabled(experiment, on: .macOS))

        configuration.experimentalModulesEnabled = false
        #expect(!configuration.isEnabled(experiment, on: .macOS))
    }

    @Test
    func platformAndAvailabilityAreHardRuntimeGates() throws {
        let iPhoneOnly = try makeDescriptor(
            id: "com.example.mobility.iphone-only",
            tier: .standard,
            platforms: [.iOS]
        )
        let unavailable = try makeDescriptor(
            id: "com.example.mobility.unavailable",
            tier: .standard,
            isAvailable: false,
            unavailableReason: "Adapter is not installed."
        )
        let configuration = MobilityModuleConfiguration()

        #expect(!configuration.isEnabled(iPhoneOnly, on: .macOS))
        #expect(configuration.isEnabled(iPhoneOnly, on: .iOS))
        #expect(!configuration.isEnabled(unavailable, on: .macOS))
    }

    @Test
    func portableManifestAddsConfiguredModulesWithoutOverridingBuiltIns() throws {
        let friendModule = try makeDescriptor(
            id: "com.friend.mobility.trip-checklist",
            tier: .standard
        )
        let manifest = try MobilityModuleManifest(modules: [friendModule])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try MobilityModuleManifest.decode(data)
        let catalog = try MobilityModuleCatalog.builtIn.adding(manifest: decoded)

        #expect(catalog.descriptor(for: friendModule.id) == friendModule)
        #expect(catalog.descriptors(for: .macOS).contains { $0.id == friendModule.id })

        let conflicting = try MobilityModuleManifest(modules: [
            try makeDescriptor(id: MobilityModuleID.fileSync.rawValue, tier: .standard)
        ])
        #expect(throws: MobilityModuleManifestError.duplicateModuleID(.fileSync)) {
            try MobilityModuleCatalog.builtIn.adding(manifest: conflicting)
        }
    }

    @Test
    func builtInCatalogExposesHotspotAutomationAsAMacExperiment() throws {
        let hotspot = try #require(
            MobilityModuleCatalog.builtIn.descriptor(for: .hotspotAutomation)
        )

        #expect(hotspot.tier == .experimental)
        #expect(hotspot.capabilities == [.hotspotAutomation])
        #expect(hotspot.supportedPlatforms == [.macOS])
        #expect(hotspot.isAvailable)
        #expect(hotspot.unavailableReason == nil)
        #expect(MobilityModuleCatalog.builtIn.descriptors(for: .macOS).contains(hotspot))
        #expect(!MobilityModuleCatalog.builtIn.descriptors(for: .iOS).contains(hotspot))
    }

    @Test
    func builtInCatalogExposesClosedLidManagementAsAMacExperiment() throws {
        let closedLid = try #require(
            MobilityModuleCatalog.builtIn.descriptor(for: .closedLidLabs)
        )

        #expect(closedLid.tier == .experimental)
        #expect(closedLid.capabilities == [.closedLidContinuity])
        #expect(closedLid.supportedPlatforms == [.macOS])
        #expect(closedLid.isAvailable)
        #expect(closedLid.unavailableReason == nil)
        #expect(MobilityModuleCatalog.builtIn.descriptors(for: .macOS).contains(closedLid))
        #expect(!MobilityModuleCatalog.builtIn.descriptors(for: .iOS).contains(closedLid))
    }

    @Test
    func builtInCatalogExposesVoiceInputOnMacAndIPhone() throws {
        let voiceInput = try #require(
            MobilityModuleCatalog.builtIn.descriptor(for: .voiceInput)
        )

        #expect(voiceInput.tier == .standard)
        #expect(voiceInput.capabilities == [.voiceInput])
        #expect(voiceInput.supportedPlatforms == [.macOS, .iOS])
        #expect(voiceInput.isEnabledByDefault)
        #expect(voiceInput.isAvailable)
        #expect(
            MobilityModuleCatalog.builtIn
                .descriptors(for: .macOS)
                .contains(voiceInput)
        )
        #expect(
            MobilityModuleCatalog.builtIn
                .descriptors(for: .iOS)
                .contains(voiceInput)
        )
        #expect(
            !MobilityModuleCatalog.builtIn
                .descriptors(for: .watchOS)
                .contains(voiceInput)
        )
    }

    @Test
    func userDefaultsPersistenceRoundTripsTypedOverrides() throws {
        let suiteName = "MobilityModuleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = UserDefaultsMobilityModuleConfigurationPersistence(
            defaults: defaults,
            key: "test.modules"
        )
        let configuration = MobilityModuleConfiguration(
            experimentalModulesEnabled: true,
            moduleOverrides: [
                .fileSync: false,
                .closedLidLabs: true
            ]
        )

        try persistence.saveConfiguration(configuration)
        #expect(try persistence.loadConfiguration() == configuration)
    }

    @Test @MainActor
    func observableStorePersistsBeforePublishingSelections() throws {
        let experiment = try makeDescriptor(
            id: "com.example.mobility.persisted-experiment",
            tier: .experimental
        )
        let catalog = try MobilityModuleCatalog(builtIn: [experiment])
        let persistence = InMemoryModulePersistence()
        let store = MobilityModuleConfigurationStore(
            catalog: catalog,
            platform: .macOS,
            persistence: persistence
        )

        store.setExperimentalModulesEnabled(true)
        store.setModule(experiment, selected: true)

        #expect(store.isEnabled(experiment))
        #expect(persistence.configuration == store.configuration)
        #expect(persistence.saveCount == 2)
    }

    private func makeDescriptor(
        id rawID: String,
        tier: MobilityModuleTier,
        platforms: Set<MobilityModulePlatform> = [.macOS, .iOS],
        isAvailable: Bool = true,
        unavailableReason: String? = nil
    ) throws -> MobilityModuleDescriptor {
        let id = try #require(MobilityModuleID(rawValue: rawID))
        let capability = try #require(
            MobilityModuleCapability(rawValue: "example.\(id.rawValue.split(separator: ".").last ?? "module")")
        )
        return try MobilityModuleDescriptor(
            id: id,
            title: "Example module",
            summary: "Used by the module architecture test suite.",
            symbolName: "puzzlepiece.extension",
            tier: tier,
            supportedPlatforms: platforms,
            capabilities: [capability],
            isAvailable: isAvailable,
            unavailableReason: unavailableReason
        )
    }
}

private final class InMemoryModulePersistence: MobilityModuleConfigurationPersisting {
    var configuration: MobilityModuleConfiguration?
    var saveCount = 0

    func loadConfiguration() throws -> MobilityModuleConfiguration? {
        configuration
    }

    func saveConfiguration(_ configuration: MobilityModuleConfiguration) throws {
        self.configuration = configuration
        saveCount += 1
    }
}
