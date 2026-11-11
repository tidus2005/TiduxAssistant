import CodexMobilityCore

/// Pure navigation state for the Mac module sidebar.
///
/// Visibility is intentionally independent from module enablement. A disabled experiment or an
/// unavailable module still needs a stable sidebar destination so its detail panel can explain how
/// to enable or unlock it.
public enum MobilityDashboardNavigation {
    public enum ModuleState: Equatable, Sendable {
        case enabled
        case disabled
        case experimentalLocked
        case unavailable(reason: String)

        public var isLocked: Bool {
            switch self {
            case .enabled, .disabled:
                false
            case .experimentalLocked, .unavailable:
                true
            }
        }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let tier: MobilityModuleTier
        public let descriptors: [MobilityModuleDescriptor]

        public var id: MobilityModuleTier { tier }

        public init(
            tier: MobilityModuleTier,
            descriptors: [MobilityModuleDescriptor]
        ) {
            self.tier = tier
            self.descriptors = descriptors
        }
    }

    /// Returns every descriptor for the current platform in catalog order.
    ///
    /// `configuration` is accepted alongside the catalog so callers have one stable navigation
    /// entry point as module preferences evolve. It must not filter sidebar destinations.
    public static func descriptors(
        catalog: MobilityModuleCatalog,
        configuration: MobilityModuleConfiguration,
        platform: MobilityModulePlatform
    ) -> [MobilityModuleDescriptor] {
        _ = configuration
        return catalog.descriptors(for: platform)
    }

    /// Keeps a persisted selection when it is still visible, otherwise prefers Travel Runtime and
    /// finally the first visible module.
    public static func resolvedSelection(
        preferredRawValue: String?,
        descriptors: [MobilityModuleDescriptor]
    ) -> String? {
        if let preferredRawValue,
           descriptors.contains(where: { $0.id.rawValue == preferredRawValue }) {
            return preferredRawValue
        }

        if descriptors.contains(where: { $0.id == .travelRuntime }) {
            return MobilityModuleID.travelRuntime.rawValue
        }

        return descriptors.first?.id.rawValue
    }

    /// Stable standard-then-experimental sections while preserving descriptor order within a tier.
    public static func sections(
        descriptors: [MobilityModuleDescriptor]
    ) -> [Section] {
        MobilityModuleTier.allCases.compactMap { tier in
            let members = descriptors.filter { $0.tier == tier }
            return members.isEmpty ? nil : Section(tier: tier, descriptors: members)
        }
    }

    public static func state(
        for descriptor: MobilityModuleDescriptor,
        configuration: MobilityModuleConfiguration,
        platform: MobilityModulePlatform
    ) -> ModuleState {
        guard descriptor.supports(platform) else {
            return .unavailable(reason: "当前平台不支持此模块。")
        }
        guard descriptor.isAvailable else {
            return .unavailable(reason: descriptor.unavailableReason ?? "当前不可用。")
        }
        if descriptor.tier == .experimental,
           !configuration.experimentalModulesEnabled {
            return .experimentalLocked
        }
        return configuration.isEnabled(descriptor, on: platform) ? .enabled : .disabled
    }
}
