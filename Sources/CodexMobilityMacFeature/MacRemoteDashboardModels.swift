import Foundation

public enum MacRemoteDashboardServicePhase: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case online
    case failed
}

public enum MacRemoteDashboardPublicAccessPhase: String, Codable, Equatable, Sendable {
    case disabled
    case checking
    case online
    case offline
}

public struct MacRemoteDashboardActivity: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var detail: String?
    public var accent: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        detail: String? = nil,
        accent: String = "neutral"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.detail = detail
        self.accent = accent
    }
}

public struct MacRemoteDashboardBatterySnapshot: Codable, Equatable, Sendable {
    public var levelPercent: Int?
    public var isCharging: Bool
    public var isOnExternalPower: Bool
    public var estimatedMinutesRemaining: Int?
    public var displayName: String
}

public struct MacRemoteDashboardTemperaturePoint: Codable, Equatable, Sendable {
    public var recordedAt: Date
    public var celsius: Double

    public init(recordedAt: Date, celsius: Double) {
        self.recordedAt = recordedAt
        self.celsius = celsius
    }
}

public struct MacRemoteDashboardThermalSnapshot: Codable, Equatable, Sendable {
    public var state: String
    public var displayName: String
    public var detail: String
    public var temperatureCelsius: Double?
    public var temperatureSource: String?
    public var history: [MacRemoteDashboardTemperaturePoint]
    public var historyWindowSeconds: TimeInterval
    public var sampleIntervalSeconds: TimeInterval

    public init(
        state: String,
        displayName: String,
        detail: String,
        temperatureCelsius: Double? = nil,
        temperatureSource: String? = nil,
        history: [MacRemoteDashboardTemperaturePoint] = [],
        historyWindowSeconds: TimeInterval = 12 * 60 * 60,
        sampleIntervalSeconds: TimeInterval = 60
    ) {
        self.state = state
        self.displayName = displayName
        self.detail = detail
        self.temperatureCelsius = temperatureCelsius
        self.temperatureSource = temperatureSource
        self.history = history
        self.historyWindowSeconds = historyWindowSeconds
        self.sampleIntervalSeconds = sampleIntervalSeconds
    }
}

public struct MacRemoteDashboardNetworkSnapshot: Codable, Equatable, Sendable {
    public var kind: String
    public var displayName: String
    public var isConnected: Bool
    public var interfaceName: String?
    public var connectedAt: Date?
    public var connectedDurationSeconds: TimeInterval?
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var detail: String
}

public struct MacRemoteDashboardCodexSnapshot: Codable, Equatable, Sendable {
    public var isRunning: Bool
    public var activeTaskCount: Int
    public var lastActivityAt: Date?
    public var detail: String
}

public struct MacRemoteDashboardToggleSnapshot: Codable, Equatable, Sendable {
    public var isOn: Bool
    public var isEnabled: Bool
    public var isBusy: Bool
    public var status: String
    public var source: String?
}

public struct MacRemoteDashboardTemporarySessionSnapshot: Codable, Equatable, Sendable {
    public var phase: String
    public var isOn: Bool
    public var isEnabled: Bool
    public var isBusy: Bool
    public var status: String
    public var expiresAt: Date?
    public var overridesBaseline: Bool
    public var durationSeconds: TimeInterval? = nil
}

public struct MacRemoteDashboardHotspotSnapshot: Codable, Equatable, Sendable {
    public var targetName: String?
    public var phase: String
    public var status: String
    public var isNetworkAvailable: Bool
    public var reconnectAttempt: Int
    public var nextActionAt: Date?
}

public struct MacRemoteDashboardRemoteControlSnapshot: Codable, Equatable, Sendable {
    public var isConnected: Bool
    public var status: String
}

public struct MacRemoteDashboardScreenLockSnapshot: Codable, Equatable, Sendable {
    public var batteryDisplaySleepMinutes: Int?
    public var powerAdapterDisplaySleepMinutes: Int?
    public var requiresPassword: Bool?
    public var passwordDelaySeconds: Int?
    public var isConfigurable: Bool
    public var lidCloseLockDelaySeconds: Int?
    public var isLidClosed: Bool?
    public var pendingLidCloseLockAt: Date?
    public var lidCloseLockStatus: String
    public var agentDesktopEnabled: Bool? = nil
    public var agentDesktopActive: Bool? = nil
    public var agentDesktopStatus: String? = nil
    public var status: String

    public init(
        batteryDisplaySleepMinutes: Int?,
        powerAdapterDisplaySleepMinutes: Int?,
        requiresPassword: Bool?,
        passwordDelaySeconds: Int?,
        isConfigurable: Bool,
        lidCloseLockDelaySeconds: Int? = nil,
        isLidClosed: Bool? = nil,
        pendingLidCloseLockAt: Date? = nil,
        lidCloseLockStatus: String = "合盖锁屏尚未连接",
        status: String
    ) {
        self.batteryDisplaySleepMinutes = batteryDisplaySleepMinutes
        self.powerAdapterDisplaySleepMinutes = powerAdapterDisplaySleepMinutes
        self.requiresPassword = requiresPassword
        self.passwordDelaySeconds = passwordDelaySeconds
        self.isConfigurable = isConfigurable
        self.lidCloseLockDelaySeconds = lidCloseLockDelaySeconds
        self.isLidClosed = isLidClosed
        self.pendingLidCloseLockAt = pendingLidCloseLockAt
        self.lidCloseLockStatus = lidCloseLockStatus
        self.status = status
    }

    public static func unavailable(_ message: String) -> Self {
        Self(
            batteryDisplaySleepMinutes: nil,
            powerAdapterDisplaySleepMinutes: nil,
            requiresPassword: nil,
            passwordDelaySeconds: nil,
            isConfigurable: false,
            status: message
        )
    }

    func merging(lidCloseLock: MacLidCloseLockSnapshot?) -> Self {
        guard let lidCloseLock else { return self }
        var copy = self
        copy.lidCloseLockDelaySeconds = lidCloseLock.delaySeconds
        copy.isLidClosed = lidCloseLock.isLidClosed
        copy.pendingLidCloseLockAt = lidCloseLock.pendingLockAt
        copy.lidCloseLockStatus = lidCloseLock.status
        copy.agentDesktopEnabled = lidCloseLock.agentDesktopEnabled
        copy.agentDesktopActive = lidCloseLock.agentDesktopActive
        copy.agentDesktopStatus = lidCloseLock.agentDesktopStatus
        return copy
    }
}

public struct MacRemoteDashboardScreenLockUpdateRequest: Codable, Equatable, Sendable {
    public var batteryDisplaySleepMinutes: Int
    public var powerAdapterDisplaySleepMinutes: Int
    /// Echo the currently read password policy. A request that changes this
    /// value is rejected; macOS requires changing it locally in System Settings.
    public var passwordDelaySeconds: Int?
    public var lidCloseLockDelaySeconds: Int?

    public init(
        batteryDisplaySleepMinutes: Int,
        powerAdapterDisplaySleepMinutes: Int,
        passwordDelaySeconds: Int?,
        lidCloseLockDelaySeconds: Int? = nil
    ) {
        self.batteryDisplaySleepMinutes = batteryDisplaySleepMinutes
        self.powerAdapterDisplaySleepMinutes = powerAdapterDisplaySleepMinutes
        self.passwordDelaySeconds = passwordDelaySeconds
        self.lidCloseLockDelaySeconds = lidCloseLockDelaySeconds
    }
}

public struct MacRemoteDashboardScreenLockResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var settings: MacRemoteDashboardScreenLockSnapshot

    public init(
        ok: Bool,
        message: String,
        settings: MacRemoteDashboardScreenLockSnapshot
    ) {
        self.ok = ok
        self.message = message
        self.settings = settings
    }
}

public struct MacRemoteDashboardSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var deviceName: String
    public var observedAt: Date
    public var appStartedAt: Date
    public var appUptimeSeconds: TimeInterval
    public var battery: MacRemoteDashboardBatterySnapshot
    public var thermal: MacRemoteDashboardThermalSnapshot
    public var network: MacRemoteDashboardNetworkSnapshot
    public var codex: MacRemoteDashboardCodexSnapshot
    public var baselineClosedLid: MacRemoteDashboardToggleSnapshot
    public var temporarySession: MacRemoteDashboardTemporarySessionSnapshot
    public var hotspot: MacRemoteDashboardHotspotSnapshot
    public var remoteControl: MacRemoteDashboardRemoteControlSnapshot
    public var screenLock: MacRemoteDashboardScreenLockSnapshot
    public var filesVersion: UInt64
    public var activities: [MacRemoteDashboardActivity]
}

public enum MacRemoteDashboardActionKind: String, Codable, Equatable, Sendable {
    case setBaselineClosedLid
    case setTemporaryTwoHourSession
}

public struct MacRemoteDashboardActionRequest: Codable, Equatable, Sendable {
    public var action: MacRemoteDashboardActionKind
    public var enabled: Bool
    public var durationSeconds: TimeInterval?
    public var mobileOffice: Bool?

    public init(action: MacRemoteDashboardActionKind, enabled: Bool, durationSeconds: TimeInterval? = nil,
                mobileOffice: Bool? = nil) {
        self.action = action
        self.enabled = enabled
        self.durationSeconds = durationSeconds
        self.mobileOffice = mobileOffice
    }
}

public struct MacRemoteDashboardActionResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var snapshot: MacRemoteDashboardSnapshot

    public init(ok: Bool, message: String, snapshot: MacRemoteDashboardSnapshot) {
        self.ok = ok
        self.message = message
        self.snapshot = snapshot
    }
}
