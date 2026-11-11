@testable import CodexMobilityMacFeature
import CodexMobilityCore
import Testing

@Suite("Mac dashboard navigation")
struct MobilityDashboardNavigationTests {
    @Test
    func validSelectionIsPreserved() throws {
        let travel = try makeDescriptor(id: .travelRuntime, sortOrder: 20)
        let files = try makeDescriptor(id: .fileSync, sortOrder: 30)

        let selection = MobilityDashboardNavigation.resolvedSelection(
            preferredRawValue: files.id.rawValue,
            descriptors: [travel, files]
        )

        #expect(selection == files.id.rawValue)
    }

    @Test
    func invalidSelectionFallsBackToTravelRuntime() throws {
        let status = try makeDescriptor(id: .deviceStatus, sortOrder: 10)
        let travel = try makeDescriptor(id: .travelRuntime, sortOrder: 20)

        let selection = MobilityDashboardNavigation.resolvedSelection(
            preferredRawValue: "com.example.mobility.removed",
            descriptors: [status, travel]
        )

        #expect(selection == travel.id.rawValue)
    }

    @Test
    func missingTravelRuntimeFallsBackToFirstDescriptor() throws {
        let first = try makeDescriptor(id: .deviceStatus, sortOrder: 10)
        let second = try makeDescriptor(id: .fileSync, sortOrder: 30)

        #expect(
            MobilityDashboardNavigation.resolvedSelection(
                preferredRawValue: nil,
                descriptors: [first, second]
            ) == first.id.rawValue
        )
        #expect(
            MobilityDashboardNavigation.resolvedSelection(
                preferredRawValue: nil,
                descriptors: []
            ) == nil
        )
    }

    @Test
    func experimentsAndUnavailableModulesRemainVisibleInCatalogOrder() throws {
        let standard = try makeDescriptor(
            id: .deviceStatus,
            tier: .standard,
            sortOrder: 30
        )
        let experiment = try makeDescriptor(
            id: .hotspotAutomation,
            tier: .experimental,
            sortOrder: 10
        )
        let unavailable = try makeDescriptor(
            id: .closedLidLabs,
            tier: .experimental,
            isAvailable: false,
            sortOrder: 20
        )
        let phoneOnly = try makeDescriptor(
            id: try #require(MobilityModuleID(rawValue: "com.example.mobility.phone-only")),
            supportedPlatforms: [.iOS],
            sortOrder: 0
        )
        let catalog = try MobilityModuleCatalog(
            builtIn: [standard, unavailable, phoneOnly, experiment]
        )
        let configuration = MobilityModuleConfiguration(
            experimentalModulesEnabled: false,
            moduleOverrides: [standard.id: false]
        )

        let descriptors = MobilityDashboardNavigation.descriptors(
            catalog: catalog,
            configuration: configuration,
            platform: .macOS
        )

        #expect(descriptors.map(\.id) == [experiment.id, unavailable.id, standard.id])
        #expect(
            MobilityDashboardNavigation.state(
                for: experiment,
                configuration: configuration,
                platform: .macOS
            ) == .experimentalLocked
        )
        #expect(
            MobilityDashboardNavigation.state(
                for: unavailable,
                configuration: configuration,
                platform: .macOS
            ) == .unavailable(reason: "Test-only unavailable module.")
        )
        #expect(
            MobilityDashboardNavigation.state(
                for: standard,
                configuration: configuration,
                platform: .macOS
            ) == .disabled
        )
    }

    @Test
    func configuredFutureDescriptorIsIncludedAndGroupedByTier() throws {
        let travel = try makeDescriptor(id: .travelRuntime, sortOrder: 20)
        let futureID = try #require(
            MobilityModuleID(rawValue: "com.friend.mobility.future-module")
        )
        let future = try makeDescriptor(
            id: futureID,
            tier: .experimental,
            sortOrder: 15
        )
        let catalog = try MobilityModuleCatalog(
            builtIn: [travel],
            configured: [future]
        )

        let descriptors = MobilityDashboardNavigation.descriptors(
            catalog: catalog,
            configuration: MobilityModuleConfiguration(),
            platform: .macOS
        )
        let sections = MobilityDashboardNavigation.sections(descriptors: descriptors)

        #expect(descriptors.map(\.id) == [future.id, travel.id])
        #expect(sections.map(\.tier) == [.standard, .experimental])
        #expect(sections[0].descriptors.map(\.id) == [travel.id])
        #expect(sections[1].descriptors.map(\.id) == [future.id])
    }

    private func makeDescriptor(
        id: MobilityModuleID,
        tier: MobilityModuleTier = .standard,
        supportedPlatforms: Set<MobilityModulePlatform> = [.macOS],
        isAvailable: Bool = true,
        sortOrder: Int
    ) throws -> MobilityModuleDescriptor {
        try MobilityModuleDescriptor(
            id: id,
            title: id.rawValue,
            summary: "Dashboard navigation test module.",
            symbolName: "square.grid.2x2",
            tier: tier,
            supportedPlatforms: supportedPlatforms,
            capabilities: [],
            isAvailable: isAvailable,
            unavailableReason: isAvailable ? nil : "Test-only unavailable module.",
            sortOrder: sortOrder
        )
    }
}
