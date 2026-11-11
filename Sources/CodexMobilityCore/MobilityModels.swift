import Foundation

public enum MobilityThermalState: String, Codable, CaseIterable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public enum MobilityTemperatureSource: String, Codable, CaseIterable, Hashable, Sendable {
    /// Highest valid Apple Silicon die sensor exposed by the local HID sensor service.
    case chipMaximum
    /// Battery-pack temperature, used only when die sensors are unavailable.
    case battery
}

public enum MobilityNetworkKind: String, Codable, CaseIterable, Hashable, Sendable {
    case offline
    case wifi
    case ethernet
    case cellular
    case other
    case unknown
}

public enum MobilityModeProfile: String, Codable, CaseIterable, Hashable, Sendable {
    case idleGuard
    case closedLidLabs
}

public enum MobilityModePhase: String, Codable, CaseIterable, Hashable, Sendable {
    case off
    case preflighting
    case armed
    case active
    case degraded
    case stopping
    case blocked
    case faulted
    case recovering
}

public struct MobilityBatteryStatus: Codable, Equatable, Hashable, Sendable {
    public var levelPercent: Int?
    public var isCharging: Bool
    public var isOnExternalPower: Bool
    public var estimatedMinutesRemaining: Int?

    public init(
        levelPercent: Int? = nil,
        isCharging: Bool = false,
        isOnExternalPower: Bool = false,
        estimatedMinutesRemaining: Int? = nil
    ) {
        self.levelPercent = levelPercent.map { min(max($0, 0), 100) }
        self.isCharging = isCharging
        self.isOnExternalPower = isOnExternalPower
        self.estimatedMinutesRemaining = estimatedMinutesRemaining.map { max($0, 0) }
    }
}

public struct MobilityNetworkStatus: Codable, Equatable, Hashable, Sendable {
    public var kind: MobilityNetworkKind
    public var isConnected: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var interfaceName: String?
    public var disconnectedSince: Date?

    public init(
        kind: MobilityNetworkKind = .unknown,
        isConnected: Bool = false,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        interfaceName: String? = nil,
        disconnectedSince: Date? = nil
    ) {
        self.kind = kind
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaceName = interfaceName
        self.disconnectedSince = disconnectedSince
    }
}

public struct MobilityCodexStatus: Codable, Equatable, Hashable, Sendable {
    public var isRunning: Bool
    public var activeTaskCount: Int
    public var lastActivityAt: Date?
    public var detail: String?

    public init(
        isRunning: Bool = false,
        activeTaskCount: Int = 0,
        lastActivityAt: Date? = nil,
        detail: String? = nil
    ) {
        self.isRunning = isRunning
        self.activeTaskCount = max(activeTaskCount, 0)
        self.lastActivityAt = lastActivityAt
        self.detail = detail
    }
}

public struct MobilityPolicy: Codable, Equatable, Hashable, Sendable {
    public static let minimumAllowedBatteryPercent = 20
    public static let maximumAllowedBatteryPercent = 80
    public static let minimumAllowedDurationSeconds: TimeInterval = 15 * 60
    public static let maximumAllowedDurationSeconds: TimeInterval = 4 * 60 * 60
    public static let maximumAllowedNetworkGraceSeconds: TimeInterval = 30 * 60
    public static let startupBatteryReservePercent = 10

    public static let recommended = MobilityPolicy(
        lowBatteryThresholdPercent: 35,
        maximumDurationSeconds: 2 * 60 * 60,
        networkDisconnectGraceSeconds: 10 * 60,
        requiresCodexRunning: true
    )

    public var lowBatteryThresholdPercent: Int
    public var maximumDurationSeconds: TimeInterval
    public var networkDisconnectGraceSeconds: TimeInterval
    public var requiresCodexRunning: Bool

    public init(
        lowBatteryThresholdPercent: Int = 35,
        maximumDurationSeconds: TimeInterval = 2 * 60 * 60,
        networkDisconnectGraceSeconds: TimeInterval = 10 * 60,
        requiresCodexRunning: Bool = true
    ) {
        self.lowBatteryThresholdPercent = lowBatteryThresholdPercent
        self.maximumDurationSeconds = maximumDurationSeconds
        self.networkDisconnectGraceSeconds = networkDisconnectGraceSeconds
        self.requiresCodexRunning = requiresCodexRunning
    }

    public func normalized() -> MobilityPolicy {
        MobilityPolicy(
            lowBatteryThresholdPercent: min(
                max(lowBatteryThresholdPercent, Self.minimumAllowedBatteryPercent),
                Self.maximumAllowedBatteryPercent
            ),
            maximumDurationSeconds: Self.clampFinite(
                maximumDurationSeconds,
                fallback: Self.recommended.maximumDurationSeconds,
                lowerBound: Self.minimumAllowedDurationSeconds,
                upperBound: Self.maximumAllowedDurationSeconds
            ),
            networkDisconnectGraceSeconds: Self.clampFinite(
                networkDisconnectGraceSeconds,
                fallback: Self.recommended.networkDisconnectGraceSeconds,
                lowerBound: 0,
                upperBound: Self.maximumAllowedNetworkGraceSeconds
            ),
            requiresCodexRunning: requiresCodexRunning
        )
    }

    private static func clampFinite(
        _ value: TimeInterval,
        fallback: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(max(value, lowerBound), upperBound)
    }
}

public struct MobilityModeStatus: Codable, Equatable, Hashable, Sendable {
    public var phase: MobilityModePhase
    public var profile: MobilityModeProfile
    public var policy: MobilityPolicy
    public var revision: UInt64
    public var startedAt: Date?
    public var expiresAt: Date?
    public var lastTransitionAt: Date
    public var detail: String?

    public init(
        phase: MobilityModePhase = .off,
        profile: MobilityModeProfile = .idleGuard,
        policy: MobilityPolicy = .recommended,
        revision: UInt64 = 0,
        startedAt: Date? = nil,
        expiresAt: Date? = nil,
        lastTransitionAt: Date = Date(),
        detail: String? = nil
    ) {
        self.phase = phase
        self.profile = profile
        self.policy = policy.normalized()
        self.revision = revision
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.lastTransitionAt = lastTransitionAt
        self.detail = detail
    }

    public var isEnabled: Bool {
        switch phase {
        case .off, .blocked, .faulted:
            false
        case .preflighting, .armed, .active, .degraded, .stopping, .recovering:
            true
        }
    }
}

public struct MobilityDeviceStatus: Codable, Equatable, Hashable, Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var battery: MobilityBatteryStatus
    public var network: MobilityNetworkStatus
    public var thermalState: MobilityThermalState
    public var temperatureCelsius: Double?
    public var temperatureSource: MobilityTemperatureSource?
    public var codex: MobilityCodexStatus
    public var mode: MobilityModeStatus
    public var helperReady: Bool
    public var observedAt: Date

    public init(
        deviceID: UUID,
        deviceName: String,
        battery: MobilityBatteryStatus,
        network: MobilityNetworkStatus,
        thermalState: MobilityThermalState,
        temperatureCelsius: Double? = nil,
        temperatureSource: MobilityTemperatureSource? = nil,
        codex: MobilityCodexStatus,
        mode: MobilityModeStatus = MobilityModeStatus(),
        helperReady: Bool = false,
        observedAt: Date = Date()
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.battery = battery
        self.network = network
        self.thermalState = thermalState
        self.temperatureCelsius = temperatureCelsius
        self.temperatureSource = temperatureSource
        self.codex = codex
        self.mode = mode
        self.helperReady = helperReady
        self.observedAt = observedAt
    }
}

public enum MobilitySafetyBlocker: String, Codable, CaseIterable, Hashable, Sendable {
    case batteryUnavailable
    case insufficientBatteryReserve
    case networkUnavailable
    case codexNotRunning
    case thermalSerious
    case thermalCritical
    case thermalUnknown
    case helperUnavailable
}

public struct MobilitySafetyEvaluation: Codable, Equatable, Hashable, Sendable {
    public var blockers: [MobilitySafetyBlocker]

    public init(blockers: [MobilitySafetyBlocker] = []) {
        self.blockers = Array(Set(blockers)).sorted { $0.rawValue < $1.rawValue }
    }

    public var isAllowed: Bool { blockers.isEmpty }

    public static func evaluate(
        status: MobilityDeviceStatus,
        profile: MobilityModeProfile,
        policy: MobilityPolicy? = nil
    ) -> MobilitySafetyEvaluation {
        let policy = (policy ?? status.mode.policy).normalized()
        var blockers: [MobilitySafetyBlocker] = []

        if let level = status.battery.levelPercent {
            let requiredLevel = min(
                policy.lowBatteryThresholdPercent + MobilityPolicy.startupBatteryReservePercent,
                100
            )
            if !status.battery.isOnExternalPower, level < requiredLevel {
                blockers.append(.insufficientBatteryReserve)
            }
        } else {
            blockers.append(.batteryUnavailable)
        }

        if !status.network.isConnected {
            blockers.append(.networkUnavailable)
        }
        if policy.requiresCodexRunning && !status.codex.isRunning {
            blockers.append(.codexNotRunning)
        }

        switch status.thermalState {
        case .serious:
            blockers.append(.thermalSerious)
        case .critical:
            blockers.append(.thermalCritical)
        case .unknown where profile == .closedLidLabs:
            blockers.append(.thermalUnknown)
        case .nominal, .fair, .unknown:
            break
        }

        if profile == .closedLidLabs && !status.helperReady {
            blockers.append(.helperUnavailable)
        }

        return MobilitySafetyEvaluation(blockers: blockers)
    }
}
