import Combine
import Foundation

/// A stable, reverse-DNS-style identifier for a Mobility module.
///
/// IDs are persisted, so they must never be derived from a display name. Valid IDs use
/// lowercase ASCII letters, digits, dots and hyphens, for example
/// `com.example.mobility.weather`.
public struct MobilityModuleID: RawRepresentable, Codable, Hashable, Sendable, Identifiable,
    Comparable, CustomStringConvertible {
    public let rawValue: String

    public var id: String { rawValue }
    public var description: String { rawValue }

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func isValid(_ value: String) -> Bool {
        guard (3...128).contains(value.utf8.count) else { return false }

        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }

        return components.allSatisfy { component in
            guard let first = component.utf8.first,
                  let last = component.utf8.last,
                  Self.isLowercaseASCIIAlphaNumeric(first),
                  Self.isLowercaseASCIIAlphaNumeric(last) else {
                return false
            }
            return component.utf8.allSatisfy {
                Self.isLowercaseASCIIAlphaNumeric($0) || $0 == Character("-").asciiValue
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Mobility module identifier: \(value)"
            )
        }
        self = identifier
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isLowercaseASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (Character("a").asciiValue!...Character("z").asciiValue!).contains(byte)
            || (Character("0").asciiValue!...Character("9").asciiValue!).contains(byte)
    }
}

/// A capability identifier stays open-ended so a configuration manifest can describe a
/// module without requiring a new enum case in the shared package.
public struct MobilityModuleCapability: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public init?(rawValue: String) {
        guard MobilityModuleID.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let capability = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Mobility capability identifier: \(value)"
            )
        }
        self = capability
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum MobilityModuleTier: String, Codable, CaseIterable, Hashable, Sendable {
    case standard
    case experimental
}

public enum MobilityModulePlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case iOS = "ios"
    case macOS = "macos"
    case watchOS = "watchos"

    public static var current: Self {
        #if os(macOS)
        .macOS
        #elseif os(watchOS)
        .watchOS
        #else
        .iOS
        #endif
    }
}

public enum MobilityModuleDescriptorError: Error, Equatable, LocalizedError {
    case emptyTitle
    case titleTooLong
    case summaryTooLong
    case invalidSymbolName
    case missingPlatform
    case tooManyCapabilities
    case unavailableWithoutReason

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "模块名称不能为空。"
        case .titleTooLong: "模块名称不能超过 80 个字符。"
        case .summaryTooLong: "模块说明不能超过 300 个字符。"
        case .invalidSymbolName: "模块图标名称不合法。"
        case .missingPlatform: "模块至少要声明一个支持的平台。"
        case .tooManyCapabilities: "单个模块最多声明 16 项能力。"
        case .unavailableWithoutReason: "不可用模块必须说明原因。"
        }
    }
}

/// Data-only metadata used by settings and by runtime composition.
///
/// A descriptor does not load executable code. An app target still owns the implementation
/// for each capability, which keeps third-party configuration declarative and reviewable.
public struct MobilityModuleDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: MobilityModuleID
    public let title: String
    public let summary: String
    public let symbolName: String
    public let tier: MobilityModuleTier
    public let supportedPlatforms: Set<MobilityModulePlatform>
    public let capabilities: Set<MobilityModuleCapability>
    public let isEnabledByDefault: Bool
    public let isAvailable: Bool
    public let unavailableReason: String?
    public let sortOrder: Int

    public init(
        id: MobilityModuleID,
        title: String,
        summary: String,
        symbolName: String,
        tier: MobilityModuleTier,
        supportedPlatforms: Set<MobilityModulePlatform>,
        capabilities: Set<MobilityModuleCapability>,
        isEnabledByDefault: Bool? = nil,
        isAvailable: Bool = true,
        unavailableReason: String? = nil,
        sortOrder: Int = 0
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSymbol = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = unavailableReason?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedTitle.isEmpty else { throw MobilityModuleDescriptorError.emptyTitle }
        guard normalizedTitle.count <= 80 else { throw MobilityModuleDescriptorError.titleTooLong }
        guard normalizedSummary.count <= 300 else { throw MobilityModuleDescriptorError.summaryTooLong }
        guard !normalizedSymbol.isEmpty, normalizedSymbol.count <= 80 else {
            throw MobilityModuleDescriptorError.invalidSymbolName
        }
        guard !supportedPlatforms.isEmpty else { throw MobilityModuleDescriptorError.missingPlatform }
        guard capabilities.count <= 16 else { throw MobilityModuleDescriptorError.tooManyCapabilities }
        if !isAvailable, normalizedReason?.isEmpty != false {
            throw MobilityModuleDescriptorError.unavailableWithoutReason
        }

        self.id = id
        self.title = normalizedTitle
        self.summary = normalizedSummary
        self.symbolName = normalizedSymbol
        self.tier = tier
        self.supportedPlatforms = supportedPlatforms
        self.capabilities = capabilities
        self.isEnabledByDefault = isEnabledByDefault ?? (tier == .standard)
        self.isAvailable = isAvailable
        self.unavailableReason = normalizedReason
        self.sortOrder = sortOrder
    }

    public func supports(_ platform: MobilityModulePlatform) -> Bool {
        supportedPlatforms.contains(platform)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case summary
        case symbolName
        case tier
        case supportedPlatforms
        case capabilities
        case isEnabledByDefault
        case isAvailable
        case unavailableReason
        case sortOrder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(MobilityModuleID.self, forKey: .id),
            title: container.decode(String.self, forKey: .title),
            summary: container.decode(String.self, forKey: .summary),
            symbolName: container.decode(String.self, forKey: .symbolName),
            tier: container.decode(MobilityModuleTier.self, forKey: .tier),
            supportedPlatforms: container.decode(Set<MobilityModulePlatform>.self, forKey: .supportedPlatforms),
            capabilities: container.decodeIfPresent(Set<MobilityModuleCapability>.self, forKey: .capabilities) ?? [],
            isEnabledByDefault: container.decodeIfPresent(Bool.self, forKey: .isEnabledByDefault),
            isAvailable: container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true,
            unavailableReason: container.decodeIfPresent(String.self, forKey: .unavailableReason),
            sortOrder: container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(tier, forKey: .tier)
        try container.encode(supportedPlatforms, forKey: .supportedPlatforms)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(isEnabledByDefault, forKey: .isEnabledByDefault)
        try container.encode(isAvailable, forKey: .isAvailable)
        try container.encodeIfPresent(unavailableReason, forKey: .unavailableReason)
        try container.encode(sortOrder, forKey: .sortOrder)
    }
}

public enum MobilityModuleManifestError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case tooManyModules(Int)
    case duplicateModuleID(MobilityModuleID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "不支持模块配置版本 \(version)。"
        case .tooManyModules(let count):
            "模块配置包含 \(count) 项，超过 64 项上限。"
        case .duplicateModuleID(let id):
            "模块 ID 重复：\(id.rawValue)。"
        }
    }
}

/// Portable JSON configuration that friends can copy and customize.
public struct MobilityModuleManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumModuleCount = 64

    public let schemaVersion: Int
    public let modules: [MobilityModuleDescriptor]

    public init(schemaVersion: Int = Self.currentSchemaVersion, modules: [MobilityModuleDescriptor]) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MobilityModuleManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        guard modules.count <= Self.maximumModuleCount else {
            throw MobilityModuleManifestError.tooManyModules(modules.count)
        }

        var seen = Set<MobilityModuleID>()
        for module in modules where !seen.insert(module.id).inserted {
            throw MobilityModuleManifestError.duplicateModuleID(module.id)
        }

        self.schemaVersion = schemaVersion
        self.modules = modules
    }

    public static func decode(_ data: Data, using decoder: JSONDecoder = JSONDecoder()) throws -> Self {
        try decoder.decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case modules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            modules: container.decode([MobilityModuleDescriptor].self, forKey: .modules)
        )
    }
}

public struct MobilityModuleCatalog: Sendable {
    public let descriptors: [MobilityModuleDescriptor]

    public init(
        builtIn: [MobilityModuleDescriptor],
        configured: [MobilityModuleDescriptor] = []
    ) throws {
        let combined = builtIn + configured
        guard combined.count <= MobilityModuleManifest.maximumModuleCount else {
            throw MobilityModuleManifestError.tooManyModules(combined.count)
        }

        var seen = Set<MobilityModuleID>()
        for descriptor in combined where !seen.insert(descriptor.id).inserted {
            throw MobilityModuleManifestError.duplicateModuleID(descriptor.id)
        }

        descriptors = combined.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    public func descriptor(for id: MobilityModuleID) -> MobilityModuleDescriptor? {
        descriptors.first { $0.id == id }
    }

    public func descriptors(
        for platform: MobilityModulePlatform,
        tier: MobilityModuleTier? = nil
    ) -> [MobilityModuleDescriptor] {
        descriptors.filter { descriptor in
            descriptor.supports(platform) && tier.map { descriptor.tier == $0 } != false
        }
    }

    public func adding(manifest: MobilityModuleManifest) throws -> Self {
        try Self(builtIn: descriptors, configured: manifest.modules)
    }
}

public struct MobilityModuleConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var experimentalModulesEnabled: Bool
    public var moduleOverrides: [MobilityModuleID: Bool]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        experimentalModulesEnabled: Bool = false,
        moduleOverrides: [MobilityModuleID: Bool] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.experimentalModulesEnabled = experimentalModulesEnabled
        self.moduleOverrides = moduleOverrides
    }

    /// The toggle value shown for one descriptor. Experiments are always off until the user
    /// explicitly enables the individual module, regardless of manifest defaults.
    public func isSelected(_ descriptor: MobilityModuleDescriptor) -> Bool {
        switch descriptor.tier {
        case .standard:
            moduleOverrides[descriptor.id] ?? descriptor.isEnabledByDefault
        case .experimental:
            moduleOverrides[descriptor.id] == true
        }
    }

    public func isEnabled(
        _ descriptor: MobilityModuleDescriptor,
        on platform: MobilityModulePlatform
    ) -> Bool {
        guard descriptor.isAvailable, descriptor.supports(platform), isSelected(descriptor) else {
            return false
        }
        if descriptor.tier == .experimental, !experimentalModulesEnabled {
            return false
        }
        return true
    }

    public mutating func setSelected(_ selected: Bool, for id: MobilityModuleID) {
        moduleOverrides[id] = selected
    }
}

public protocol MobilityModuleConfigurationPersisting: AnyObject {
    func loadConfiguration() throws -> MobilityModuleConfiguration?
    func saveConfiguration(_ configuration: MobilityModuleConfiguration) throws
}

public final class UserDefaultsMobilityModuleConfigurationPersistence:
    MobilityModuleConfigurationPersisting {
    public static let suiteName = "com.tidux.codex-mobility.modules"
    public static let configurationKey = "mobilityModules.configuration.v1"

    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public convenience init() {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else {
            preconditionFailure("Unable to create the Codex Mobility module preferences suite")
        }
        self.init(defaults: defaults)
    }

    public init(
        defaults: UserDefaults,
        key: String = UserDefaultsMobilityModuleConfigurationPersistence.configurationKey,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.key = key
        self.encoder = encoder
        self.decoder = decoder
    }

    public func loadConfiguration() throws -> MobilityModuleConfiguration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let configuration = try decoder.decode(MobilityModuleConfiguration.self, from: data)
        guard configuration.schemaVersion == MobilityModuleConfiguration.currentSchemaVersion else {
            throw MobilityModuleManifestError.unsupportedSchemaVersion(configuration.schemaVersion)
        }
        return configuration
    }

    public func saveConfiguration(_ configuration: MobilityModuleConfiguration) throws {
        defaults.set(try encoder.encode(configuration), forKey: key)
    }
}

/// Main-actor state used by settings and by runtime composition. Persist-first updates prevent
/// the UI from claiming a module is enabled when its configuration could not be saved.
@MainActor
public final class MobilityModuleConfigurationStore: ObservableObject {
    public let catalog: MobilityModuleCatalog
    public let platform: MobilityModulePlatform

    @Published public private(set) var configuration: MobilityModuleConfiguration
    @Published public private(set) var persistenceErrorMessage: String?

    private let persistence: any MobilityModuleConfigurationPersisting

    public init(
        catalog: MobilityModuleCatalog = .builtIn,
        platform: MobilityModulePlatform = .current,
        persistence: any MobilityModuleConfigurationPersisting =
            UserDefaultsMobilityModuleConfigurationPersistence()
    ) {
        self.catalog = catalog
        self.platform = platform
        self.persistence = persistence

        do {
            configuration = try persistence.loadConfiguration() ?? MobilityModuleConfiguration()
            persistenceErrorMessage = nil
        } catch {
            configuration = MobilityModuleConfiguration()
            persistenceErrorMessage = error.localizedDescription
        }
    }

    public func descriptors(tier: MobilityModuleTier? = nil) -> [MobilityModuleDescriptor] {
        catalog.descriptors(for: platform, tier: tier)
    }

    public func isSelected(_ descriptor: MobilityModuleDescriptor) -> Bool {
        configuration.isSelected(descriptor)
    }

    public func isEnabled(_ descriptor: MobilityModuleDescriptor) -> Bool {
        configuration.isEnabled(descriptor, on: platform)
    }

    public func isEnabled(_ id: MobilityModuleID) -> Bool {
        catalog.descriptor(for: id).map(isEnabled) ?? false
    }

    public func setExperimentalModulesEnabled(_ enabled: Bool) {
        var next = configuration
        next.experimentalModulesEnabled = enabled
        persist(next)
    }

    public func setModule(_ descriptor: MobilityModuleDescriptor, selected: Bool) {
        guard descriptor.supports(platform), descriptor.isAvailable else { return }
        var next = configuration
        next.setSelected(selected, for: descriptor.id)
        persist(next)
    }

    public func reset() {
        persist(MobilityModuleConfiguration())
    }

    /// Replaces the complete persisted configuration in one transaction.
    /// Temporary modes use this to restore the exact pre-session selection
    /// instead of trying to infer which individual toggles they changed.
    @discardableResult
    public func restore(_ configuration: MobilityModuleConfiguration) -> Bool {
        persist(configuration)
        return persistenceErrorMessage == nil && self.configuration == configuration
    }

    private func persist(_ next: MobilityModuleConfiguration) {
        do {
            try persistence.saveConfiguration(next)
            configuration = next
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }
}

public extension MobilityModuleID {
    static let deviceStatus = required("com.tidux.mobility.device-status")
    static let travelRuntime = required("com.tidux.mobility.travel-runtime")
    static let fileSync = required("com.tidux.mobility.file-sync")
    static let voiceInput = required("com.tidux.mobility.voice-input")
    static let closedLidLabs = required("com.tidux.mobility.closed-lid-labs")
    static let hotspotAutomation = required("com.tidux.mobility.hotspot-automation")

    private static func required(_ value: String) -> Self {
        guard let identifier = Self(rawValue: value) else {
            preconditionFailure("Invalid built-in Mobility module ID: \(value)")
        }
        return identifier
    }
}

public extension MobilityModuleCapability {
    static let deviceStatus = required("mobility.device-status")
    static let travelRuntime = required("mobility.travel-runtime")
    static let fileSync = required("mobility.file-sync")
    static let voiceInput = required("mobility.voice-input")
    static let closedLidContinuity = required("mobility.closed-lid-continuity")
    static let hotspotAutomation = required("mobility.hotspot-automation")

    private static func required(_ value: String) -> Self {
        guard let capability = Self(rawValue: value) else {
            preconditionFailure("Invalid built-in Mobility capability ID: \(value)")
        }
        return capability
    }
}

public extension MobilityModuleCatalog {
    static let builtIn: Self = {
        do {
            return try Self(
                builtIn: [
                    MobilityModuleDescriptor(
                        id: .deviceStatus,
                        title: "设备状态",
                        summary: "查看 Mac 的电池、网络、温度和 Codex 运行状态。",
                        symbolName: "gauge.with.dots.needle.67percent",
                        tier: .standard,
                        supportedPlatforms: [.macOS, .iOS],
                        capabilities: [.deviceStatus],
                        sortOrder: 10
                    ),
                    MobilityModuleDescriptor(
                        id: .travelRuntime,
                        title: "移动联网运行",
                        summary: "管理低功耗 Idle Guard、安全停止条件和手机端控制。",
                        symbolName: "laptopcomputer.and.iphone",
                        tier: .standard,
                        supportedPlatforms: [.macOS, .iOS],
                        capabilities: [.travelRuntime],
                        sortOrder: 20
                    ),
                    MobilityModuleDescriptor(
                        id: .fileSync,
                        title: "双向文件同步",
                        summary: "在 Mac 同步目录与 iPhone 文件、照片之间传输内容。",
                        symbolName: "arrow.triangle.2.circlepath",
                        tier: .standard,
                        supportedPlatforms: [.macOS, .iOS],
                        capabilities: [.fileSync],
                        sortOrder: 30
                    ),
                    MobilityModuleDescriptor(
                        id: .voiceInput,
                        title: "智能语音输入",
                        summary: "按 Fn 在任意文本框听写，使用设备端语音模型，并可由 Codex 整理后原位写回。",
                        symbolName: "waveform.badge.mic",
                        tier: .standard,
                        supportedPlatforms: [.macOS, .iOS],
                        capabilities: [.voiceInput],
                        sortOrder: 40
                    ),
                    MobilityModuleDescriptor(
                        id: .closedLidLabs,
                        title: "合盖持续运行",
                        summary: "集中查看和管理系统级合盖续跑、Idle Guard 与合盖显示策略。",
                        symbolName: "macbook.and.iphone",
                        tier: .experimental,
                        supportedPlatforms: [.macOS],
                        capabilities: [.closedLidContinuity],
                        isAvailable: true,
                        sortOrder: 100
                    ),
                    MobilityModuleDescriptor(
                        id: .hotspotAutomation,
                        title: "热点自动重连",
                        summary: "Wi-Fi 断开后，低频重连已由 macOS 保存凭据的 iPhone 热点。",
                        symbolName: "personalhotspot",
                        tier: .experimental,
                        supportedPlatforms: [.macOS],
                        capabilities: [.hotspotAutomation],
                        isAvailable: true,
                        sortOrder: 110
                    )
                ]
            )
        } catch {
            preconditionFailure("Invalid built-in Mobility module catalog: \(error)")
        }
    }()
}
