import Combine
import CodexMobilityCore
import Darwin
import Foundation
import IOKit

public enum MacSystemPolicyControl: String, CaseIterable, Hashable, Sendable {
    case closedLidContinuity
    case displaySleepOnLidClose
    case requirePasswordAfterDisplaySleep
    case keepExternalDisplayActive
}

public enum MacPolicyControlState: Equatable, Sendable {
    case disabled
    case externallyEnabled
    case appManaged
    case unsupported(String)
    case unknown(String)

    public var isEnabled: Bool {
        switch self {
        case .externallyEnabled, .appManaged:
            true
        case .disabled, .unsupported, .unknown:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .disabled: "已关闭"
        case .externallyEnabled: "外部策略"
        case .appManaged: "App 管理"
        case .unsupported: "不支持"
        case .unknown: "状态未知"
        }
    }
}

public struct MacSystemPowerPolicySnapshot: Equatable, Sendable {
    public var sleepDisabled: Bool?
    public var displaySleepOnLidClose: Bool?
    public var requirePasswordAfterDisplaySleep: Bool?
    public var keepExternalDisplayActive: Bool?
    public var legacyConfigurationAvailable: Bool
    public var lidGuardRunning: Bool
    public var managedControls: Set<MacSystemPolicyControl>
    public var observedAt: Date

    public init(
        sleepDisabled: Bool? = nil,
        displaySleepOnLidClose: Bool? = nil,
        requirePasswordAfterDisplaySleep: Bool? = nil,
        keepExternalDisplayActive: Bool? = nil,
        legacyConfigurationAvailable: Bool = false,
        lidGuardRunning: Bool = false,
        managedControls: Set<MacSystemPolicyControl> = [],
        observedAt: Date = Date()
    ) {
        self.sleepDisabled = sleepDisabled
        self.displaySleepOnLidClose = displaySleepOnLidClose
        self.requirePasswordAfterDisplaySleep = requirePasswordAfterDisplaySleep
        self.keepExternalDisplayActive = keepExternalDisplayActive
        self.legacyConfigurationAvailable = legacyConfigurationAvailable
        self.lidGuardRunning = lidGuardRunning
        self.managedControls = managedControls
        self.observedAt = observedAt
    }

    public func state(for control: MacSystemPolicyControl) -> MacPolicyControlState {
        let value: Bool?
        switch control {
        case .closedLidContinuity:
            value = sleepDisabled
        case .displaySleepOnLidClose:
            guard legacyConfigurationAvailable else {
                return .unsupported("没有检测到本机 Continuity 合盖策略配置。")
            }
            guard lidGuardRunning else {
                return .unknown("配置存在，但合盖策略服务当前没有运行。")
            }
            value = displaySleepOnLidClose
        case .requirePasswordAfterDisplaySleep:
            guard legacyConfigurationAvailable else {
                return .unsupported("没有检测到本机 Continuity 合盖策略配置。")
            }
            guard lidGuardRunning else {
                return .unknown("配置存在，但合盖策略服务当前没有运行。")
            }
            value = requirePasswordAfterDisplaySleep
        case .keepExternalDisplayActive:
            guard legacyConfigurationAvailable else {
                return .unsupported("没有检测到本机 Continuity 合盖策略配置。")
            }
            guard lidGuardRunning else {
                return .unknown("配置存在，但合盖策略服务当前没有运行。")
            }
            value = keepExternalDisplayActive
        }

        guard let value else {
            return .unknown("暂时无法读取当前系统状态。")
        }
        guard value else { return .disabled }
        return managedControls.contains(control) ? .appManaged : .externallyEnabled
    }

    public static let loading = Self()
}

public struct MacClosedLidContinuityLease: Equatable, Sendable {
    public static let twoHours: TimeInterval = 2 * 60 * 60

    public let startedAt: Date
    public let expiresAt: Date
    public let didEnableSystemPolicy: Bool

    public init(
        startedAt: Date,
        expiresAt: Date,
        didEnableSystemPolicy: Bool
    ) {
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.didEnableSystemPolicy = didEnableSystemPolicy
    }
}

public enum MacSystemPowerPolicyError: Error, LocalizedError, Equatable, Sendable {
    case authorizationCancelled
    case authorizationFailed
    case commandFailed(String)
    case commandTimedOut
    case verificationFailed
    case legacyConfigurationUnavailable
    case legacyPolicyRestartFailed
    case unsafeConfiguration(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationCancelled:
            "已取消管理员验证，系统设置没有改变。"
        case .authorizationFailed:
            "管理员验证失败，系统设置没有改变。"
        case .commandFailed(let message):
            message
        case .commandTimedOut:
            "操作等待超时，已停止对应的系统命令。"
        case .verificationFailed:
            "系统命令已返回，但复查结果与目标状态不一致。"
        case .legacyConfigurationUnavailable:
            "没有找到这台 Mac 的 Continuity 合盖策略配置。"
        case .legacyPolicyRestartFailed:
            "无法重新加载 Continuity 合盖策略服务。"
        case .unsafeConfiguration(let message):
            message
        case .rollbackFailed(let message):
            "操作失败，并且无法确认已经恢复原配置：\(message)"
        }
    }
}

struct MacSystemPowerPolicyFacts: Equatable, Sendable {
    var sleepDisabled: Bool?
    var displaySleepOnLidClose: Bool?
    var requirePasswordAfterDisplaySleep: Bool?
    var keepExternalDisplayActive: Bool?
    var legacyConfigurationAvailable: Bool
    var lidGuardRunning: Bool
}

protocol MacSystemPowerPolicyBackend: Sendable {
    func loadFacts() async -> MacSystemPowerPolicyFacts
    func setClosedLidContinuity(enabled: Bool) async throws
    func recoverInterruptedClosedLidSession(baselineEnabled: Bool) async throws
    func beginClosedLidContinuityLease(
        duration: TimeInterval,
        now: Date
    ) async throws -> MacClosedLidContinuityLease
    func renewClosedLidContinuityLease(_ lease: MacClosedLidContinuityLease, expiresAt: Date) async throws -> MacClosedLidContinuityLease
    func endClosedLidContinuityLease(_ lease: MacClosedLidContinuityLease) async throws
    func setLegacyControl(_ control: MacSystemPolicyControl, enabled: Bool) async throws
}

extension MacSystemPowerPolicyBackend {
    func renewClosedLidContinuityLease(_ lease: MacClosedLidContinuityLease, expiresAt: Date) async throws -> MacClosedLidContinuityLease {
        throw MacSystemPowerPolicyError.commandFailed("当前系统组件不支持合盖租约续期。")
    }

    func recoverInterruptedClosedLidSession(baselineEnabled: Bool) async throws {
        try await setClosedLidContinuity(enabled: baselineEnabled)
    }
}

@MainActor
public final class MacSystemPowerPolicyStore: ObservableObject {
    static let managedControlsDefaultsKey =
        "com.tidux.codex-mobility.system-power.managed-controls.v1"

    @Published public private(set) var snapshot: MacSystemPowerPolicySnapshot = .loading
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var lastActionMessage: String?
    @Published public private(set) var activeClosedLidLease: MacClosedLidContinuityLease?

    private let backend: any MacSystemPowerPolicyBackend
    private let defaults: UserDefaults

    public convenience init() {
        self.init(
            backend: LocalMacSystemPowerPolicyBackend(),
            defaults: .standard
        )
    }

    init(
        backend: any MacSystemPowerPolicyBackend,
        defaults: UserDefaults
    ) {
        self.backend = backend
        self.defaults = defaults
    }

    func refresh() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        let facts = await backend.loadFacts()
        publish(facts)
    }

    @discardableResult
    func setClosedLidContinuityEnabled(_ enabled: Bool) async -> Bool {
        guard activeClosedLidLease == nil else {
            lastErrorMessage = "请先关闭“定时合盖续跑”，再修改持久系统策略。"
            return false
        }
        return await mutate(.closedLidContinuity, enabled: enabled) {
            try await backend.setClosedLidContinuity(enabled: enabled)
        }
    }

    @discardableResult
    func recoverInterruptedClosedLidSession(baselineEnabled: Bool) async -> Bool {
        guard !isBusy, activeClosedLidLease == nil else { return false }
        isBusy = true
        lastErrorMessage = nil
        lastActionMessage = nil
        defer { isBusy = false }

        do {
            try await backend.recoverInterruptedClosedLidSession(
                baselineEnabled: baselineEnabled
            )
            let facts = await backend.loadFacts()
            publish(facts)
            guard snapshot.sleepDisabled == baselineEnabled else {
                throw MacSystemPowerPolicyError.verificationFailed
            }
            if !baselineEnabled {
                setManagedControl(.closedLidContinuity, managed: false)
            }
            lastActionMessage = baselineEnabled
                ? "已恢复覆盖前的合盖运行配置。"
                : "已恢复覆盖前的普通睡眠配置。"
            return true
        } catch {
            let facts = await backend.loadFacts()
            publish(facts)
            lastErrorMessage = Self.errorMessage(error)
            return false
        }
    }

    func beginClosedLidContinuityLease(
        duration: TimeInterval = MacClosedLidContinuityLease.twoHours,
        now: Date = Date()
    ) async -> MacClosedLidContinuityLease? {
        guard !isBusy, activeClosedLidLease == nil else { return nil }
        isBusy = true
        lastErrorMessage = nil
        lastActionMessage = nil
        defer { isBusy = false }

        var acquiredLease: MacClosedLidContinuityLease?
        do {
            let lease = try await backend.beginClosedLidContinuityLease(
                duration: duration,
                now: now
            )
            acquiredLease = lease
            activeClosedLidLease = lease
            if lease.didEnableSystemPolicy {
                var managed = loadManagedControls()
                managed.insert(.closedLidContinuity)
                saveManagedControls(managed)
            }
            let facts = await backend.loadFacts()
            publish(facts)
            guard snapshot.sleepDisabled == true else {
                throw MacSystemPowerPolicyError.verificationFailed
            }
            lastActionMessage = lease.didEnableSystemPolicy
                ? "定时系统合盖租约已开启，到期自动恢复。"
                : "沿用已有系统合盖策略；随行会话结束时不会改动原策略。"
            return lease
        } catch {
            let operationError = error
            var reportedError = operationError
            var shouldRetainLeaseForRetry = false
            if let acquiredLease {
                do {
                    try await backend.endClosedLidContinuityLease(acquiredLease)
                } catch {
                    shouldRetainLeaseForRetry = true
                    reportedError = MacSystemPowerPolicyError.rollbackFailed(
                        "租约启动失败：\(Self.errorMessage(operationError))；"
                            + "系统策略回滚失败：\(Self.errorMessage(error))"
                    )
                }
            }
            activeClosedLidLease = shouldRetainLeaseForRetry ? acquiredLease : nil
            let facts = await backend.loadFacts()
            publish(facts)
            if let acquiredLease, acquiredLease.didEnableSystemPolicy {
                setManagedControl(
                    .closedLidContinuity,
                    managed: shouldRetainLeaseForRetry
                )
            }
            lastErrorMessage = Self.errorMessage(reportedError)
            return nil
        }
    }

    func renewClosedLidContinuityLease(expiresAt: Date) async -> MacClosedLidContinuityLease? {
        guard !isBusy, let current = activeClosedLidLease else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let renewed = try await backend.renewClosedLidContinuityLease(current, expiresAt: expiresAt)
            activeClosedLidLease = renewed
            publish(await backend.loadFacts())
            guard snapshot.sleepDisabled == true else { throw MacSystemPowerPolicyError.verificationFailed }
            return renewed
        } catch {
            lastErrorMessage = Self.errorMessage(error)
            return nil
        }
    }

    @discardableResult
    func endClosedLidContinuityLease() async -> Bool {
        guard let lease = activeClosedLidLease else { return true }
        guard !isBusy else { return false }
        isBusy = true
        lastErrorMessage = nil
        lastActionMessage = nil
        defer { isBusy = false }

        do {
            try await backend.endClosedLidContinuityLease(lease)
            let facts = await backend.loadFacts()
            publish(facts)
            let expectedEnabled = !lease.didEnableSystemPolicy
            guard snapshot.sleepDisabled == expectedEnabled else {
                throw MacSystemPowerPolicyError.verificationFailed
            }
            activeClosedLidLease = nil
            if lease.didEnableSystemPolicy {
                setManagedControl(.closedLidContinuity, managed: false)
            }
            lastActionMessage = lease.didEnableSystemPolicy
                ? "定时系统合盖租约已结束，睡眠策略已恢复。"
                : "随行会话已结束，原有系统合盖策略保持不变。"
            return true
        } catch {
            let facts = await backend.loadFacts()
            publish(facts)
            if lease.didEnableSystemPolicy {
                setManagedControl(.closedLidContinuity, managed: true)
            }
            lastErrorMessage = Self.errorMessage(error)
            return false
        }
    }

    @discardableResult
    func setLegacyControl(
        _ control: MacSystemPolicyControl,
        enabled: Bool
    ) async -> Bool {
        precondition(control != .closedLidContinuity)
        return await mutate(control, enabled: enabled) {
            try await backend.setLegacyControl(control, enabled: enabled)
        }
    }

    private func mutate(
        _ control: MacSystemPolicyControl,
        enabled: Bool,
        operation: () async throws -> Void
    ) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        lastErrorMessage = nil
        lastActionMessage = nil
        defer { isBusy = false }

        do {
            try await operation()
            var managed = loadManagedControls()
            if enabled {
                managed.insert(control)
            } else {
                managed.remove(control)
            }
            saveManagedControls(managed)
            let facts = await backend.loadFacts()
            publish(facts)

            let verified = snapshot.state(for: control).isEnabled == enabled
            guard verified else {
                throw MacSystemPowerPolicyError.verificationFailed
            }
            lastActionMessage = enabled ? "设置已开启。" : "设置已关闭。"
            return true
        } catch {
            let facts = await backend.loadFacts()
            publish(facts)
            lastErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return false
        }
    }

    private func publish(_ facts: MacSystemPowerPolicyFacts) {
        var managed = loadManagedControls()
        if facts.sleepDisabled != true {
            managed.remove(.closedLidContinuity)
        }
        if facts.displaySleepOnLidClose != true {
            managed.remove(.displaySleepOnLidClose)
        }
        if facts.requirePasswordAfterDisplaySleep != true {
            managed.remove(.requirePasswordAfterDisplaySleep)
        }
        if facts.keepExternalDisplayActive != true {
            managed.remove(.keepExternalDisplayActive)
        }
        saveManagedControls(managed)

        snapshot = MacSystemPowerPolicySnapshot(
            sleepDisabled: facts.sleepDisabled,
            displaySleepOnLidClose: facts.displaySleepOnLidClose,
            requirePasswordAfterDisplaySleep: facts.requirePasswordAfterDisplaySleep,
            keepExternalDisplayActive: facts.keepExternalDisplayActive,
            legacyConfigurationAvailable: facts.legacyConfigurationAvailable,
            lidGuardRunning: facts.lidGuardRunning,
            managedControls: managed,
            observedAt: Date()
        )
    }

    private func loadManagedControls() -> Set<MacSystemPolicyControl> {
        let values = defaults.stringArray(forKey: Self.managedControlsDefaultsKey) ?? []
        return Set(values.compactMap(MacSystemPolicyControl.init(rawValue:)))
    }

    private func saveManagedControls(_ controls: Set<MacSystemPolicyControl>) {
        defaults.set(controls.map(\.rawValue).sorted(), forKey: Self.managedControlsDefaultsKey)
    }

    private func setManagedControl(
        _ control: MacSystemPolicyControl,
        managed: Bool
    ) {
        var controls = loadManagedControls()
        if managed {
            controls.insert(control)
        } else {
            controls.remove(control)
        }
        saveManagedControls(controls)
        snapshot.managedControls = controls
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

enum MacSystemPowerPolicyProbe {
    static func sleepDisabled() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        let value = IORegistryEntryCreateCFProperty(
            service,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        return (value as? NSNumber)?.boolValue
    }
}

actor LocalMacSystemPowerPolicyBackend: MacSystemPowerPolicyBackend {
    private static let lidGuardLabel = "com.openclaw.continuity.lid-guard"
    private static let standardCommandTimeout: TimeInterval = 15
    private static let leasePollIntervalMicroseconds: useconds_t = 250_000
    private static let leaseReleaseTimeout: TimeInterval = 15

    private let configURL: URL
    private let userID: uid_t
    private let privilegedPowerHelper: MacPrivilegedPowerHelper

    init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/continuity/config.env"),
        userID: uid_t = getuid()
    ) {
        self.configURL = configURL
        self.userID = userID
        self.privilegedPowerHelper = MacPrivilegedPowerHelper(userID: userID)
    }

    func loadFacts() async -> MacSystemPowerPolicyFacts {
        let pmset = try? Self.run(
            "/usr/bin/pmset",
            arguments: ["-g"],
            timeout: Self.standardCommandTimeout
        )
        let sleepDisabled = pmset.flatMap { result in
            guard result.exitCode == 0 else { return nil }
            return Self.parseSleepDisabled(result.output)
        } ?? MacSystemPowerPolicyProbe.sleepDisabled()

        let configurationSnapshot = try? secureConfigurationSnapshot()
        let configurationText = configurationSnapshot.flatMap {
            String(data: $0.data, encoding: .utf8)
        }
        let configuration = configurationText.map(ContinuityLidPolicyConfiguration.init(text:))
        let actualPasswordRequirement = readActualPasswordRequirementIfAvailable()
        let launchState = try? Self.run(
            "/bin/launchctl",
            arguments: ["print", "gui/\(userID)/\(Self.lidGuardLabel)"],
            timeout: Self.standardCommandTimeout
        )

        return MacSystemPowerPolicyFacts(
            sleepDisabled: sleepDisabled,
            displaySleepOnLidClose: configuration?.displaySleepOnLidClose,
            // The launch agent writes this preference as a side effect. Report
            // what macOS actually enforces, not merely what config.env requests.
            requirePasswordAfterDisplaySleep: actualPasswordRequirement,
            keepExternalDisplayActive: configuration?.keepExternalDisplayActive,
            legacyConfigurationAvailable: configurationText != nil,
            lidGuardRunning: launchState?.exitCode == 0
        )
    }

    func setClosedLidContinuity(enabled: Bool) async throws {
        let previousValue = try readSleepDisabledFromPMSet()
        guard previousValue != enabled else { return }

        do {
            try privilegedPowerHelper.execute(.setSleepDisabled(enabled))
            guard try readSleepDisabledFromPMSet() == enabled else {
                throw MacSystemPowerPolicyError.verificationFailed
            }
        } catch {
            let originalError = error
            do {
                let currentValue: Bool?
                do {
                    currentValue = try readSleepDisabledFromPMSet()
                } catch {
                    currentValue = nil
                }

                // A cancelled prompt normally leaves the setting untouched. If the
                // actual state cannot be confirmed, prefer a fixed compensating
                // command over assuming the global power policy is still safe.
                if currentValue != previousValue {
                    try privilegedPowerHelper.execute(.setSleepDisabled(previousValue))
                }
                guard try readSleepDisabledFromPMSet() == previousValue else {
                    throw MacSystemPowerPolicyError.verificationFailed
                }
            } catch {
                throw MacSystemPowerPolicyError.rollbackFailed(
                    "系统级合盖续跑原值为 \(previousValue ? "开启" : "关闭")；"
                        + "补偿操作失败：\(Self.errorMessage(error))"
                )
            }
            throw originalError
        }
    }

    func recoverInterruptedClosedLidSession(baselineEnabled: Bool) async throws {
        let markerPath = Self.closedLidLeaseMarkerPath(userID: userID)
        if FileManager.default.fileExists(atPath: markerPath) {
            Self.signalClosedLidLeaseEnd(userID: userID)
            let deadline = Date().addingTimeInterval(Self.leaseReleaseTimeout)
            while Date() < deadline {
                if (try? readSleepDisabledFromPMSet()) == baselineEnabled {
                    return
                }
                usleep(Self.leasePollIntervalMicroseconds)
            }
        }

        if privilegedPowerHelper.hasLeaseState {
            try privilegedPowerHelper.execute(.endLease)
        }

        if (try? readSleepDisabledFromPMSet()) != baselineEnabled {
            try await setClosedLidContinuity(enabled: baselineEnabled)
        }
        guard try readSleepDisabledFromPMSet() == baselineEnabled else {
            throw MacSystemPowerPolicyError.verificationFailed
        }
    }

    func beginClosedLidContinuityLease(
        duration: TimeInterval,
        now: Date
    ) async throws -> MacClosedLidContinuityLease {
        let normalizedDuration = Self.normalizedLeaseDuration(duration)
        let expiresAt = now.addingTimeInterval(normalizedDuration)
        var previousValue = try readSleepDisabledFromPMSet()
        let legacyMarkerPath = Self.closedLidLeaseMarkerPath(userID: userID)
        if FileManager.default.fileExists(atPath: legacyMarkerPath) {
            if previousValue {
                // A previous App instance may have exited while its system
                // LaunchDaemon was still protecting the machine. End that
                // lease completely before starting a fresh deadline.
                Self.signalClosedLidLeaseEnd(userID: userID)
                let deadline = Date().addingTimeInterval(Self.leaseReleaseTimeout)
                while Date() < deadline, previousValue {
                    usleep(Self.leasePollIntervalMicroseconds)
                    previousValue = (try? readSleepDisabledFromPMSet()) ?? true
                }
                guard !previousValue else {
                    throw MacSystemPowerPolicyError.commandFailed(
                        "上一段合盖租约尚未完成回滚，请稍后重试。"
                    )
                }
            } else {
                // Authorization may have been cancelled after the unprivileged
                // marker was created but before a system job was installed.
                Self.signalClosedLidLeaseEnd(userID: userID)
            }
        }
        guard !previousValue else {
            return MacClosedLidContinuityLease(
                startedAt: now,
                expiresAt: expiresAt,
                didEnableSystemPolicy: false
            )
        }

        do {
            try privilegedPowerHelper.execute(
                .beginLease(
                    baselineEnabled: previousValue,
                    expiresAt: expiresAt
                )
            )
            guard try readSleepDisabledFromPMSet() else {
                throw MacSystemPowerPolicyError.verificationFailed
            }
            return MacClosedLidContinuityLease(
                startedAt: now,
                expiresAt: expiresAt,
                didEnableSystemPolicy: true
            )
        } catch {
            if privilegedPowerHelper.hasLeaseState {
                try? privilegedPowerHelper.execute(.endLease)
            }
            throw error
        }
    }

    func renewClosedLidContinuityLease(_ lease: MacClosedLidContinuityLease, expiresAt: Date) async throws -> MacClosedLidContinuityLease {
        guard expiresAt > Date(), expiresAt.timeIntervalSinceNow <= 4 * 60 * 60 + 60 else {
            throw MacSystemPowerPolicyError.commandFailed("合盖保护续期时长无效。")
        }
        if lease.didEnableSystemPolicy {
            try privilegedPowerHelper.execute(.renewLease(expiresAt: expiresAt))
        }
        guard try readSleepDisabledFromPMSet() else { throw MacSystemPowerPolicyError.verificationFailed }
        return MacClosedLidContinuityLease(startedAt: lease.startedAt, expiresAt: expiresAt,
                                          didEnableSystemPolicy: lease.didEnableSystemPolicy)
    }

    func endClosedLidContinuityLease(_ lease: MacClosedLidContinuityLease) async throws {
        guard lease.didEnableSystemPolicy else { return }
        // Preserve compatibility with a two-hour lease created by a build from
        // before the persistent helper migration.
        Self.signalClosedLidLeaseEnd(userID: userID)
        if privilegedPowerHelper.hasLeaseState {
            try privilegedPowerHelper.execute(.endLease)
        }

        let deadline = Date().addingTimeInterval(Self.leaseReleaseTimeout)
        while Date() < deadline {
            if (try? readSleepDisabledFromPMSet()) == false {
                return
            }
            usleep(Self.leasePollIntervalMicroseconds)
        }
        throw MacSystemPowerPolicyError.commandFailed(
            "定时租约已收到停止信号，但系统合盖策略未在 15 秒内恢复；请打开 Mac 后在“设置 > 电源”复查。"
        )
    }

    func setLegacyControl(
        _ control: MacSystemPolicyControl,
        enabled: Bool
    ) async throws {
        guard control != .closedLidContinuity else {
            throw MacSystemPowerPolicyError.commandFailed("系统级合盖续跑必须使用管理员授权通道。")
        }

        let original = try secureConfigurationSnapshot()
        guard let originalText = String(data: original.data, encoding: .utf8) else {
            throw MacSystemPowerPolicyError.unsafeConfiguration(
                "Continuity 合盖策略配置不是有效的 UTF-8 文本，已拒绝修改。"
            )
        }
        let configuration = ContinuityLidPolicyConfiguration(text: originalText)
        let originalPasswordRequirement = control == .requirePasswordAfterDisplaySleep
            ? try readActualPasswordRequirement()
            : nil
        let updated = configuration.updating(control: control, enabled: enabled)
        let updatedData = Data(updated.utf8)
        var didReplaceConfiguration = false

        do {
            try secureAtomicReplaceConfiguration(
                with: updatedData,
                mode: original.mode,
                expectedCurrent: original,
                didReplace: &didReplaceConfiguration
            )
            try restartAndVerifyLidGuard()

            let verified = try secureConfigurationSnapshot()
            guard verified.data == updatedData,
                  verified.mode == original.mode,
                  verified.owner == userID,
                  let verifiedText = String(data: verified.data, encoding: .utf8) else {
                throw MacSystemPowerPolicyError.verificationFailed
            }
            let verifiedConfiguration = ContinuityLidPolicyConfiguration(text: verifiedText)
            guard verifiedConfiguration.value(for: control) == enabled else {
                throw MacSystemPowerPolicyError.verificationFailed
            }
            if control == .requirePasswordAfterDisplaySleep {
                try waitForActualPasswordRequirement(enabled)
            }
        } catch {
            let originalError = error
            guard didReplaceConfiguration else { throw originalError }

            do {
                let current = try secureConfigurationSnapshot()
                guard current.data == updatedData,
                      current.mode == original.mode,
                      current.owner == userID else {
                    throw MacSystemPowerPolicyError.unsafeConfiguration(
                        "配置在事务期间又被其他程序修改，已拒绝覆盖该外部更改。"
                    )
                }
                var rollbackReplacedConfiguration = false
                try secureAtomicReplaceConfiguration(
                    with: original.data,
                    mode: original.mode,
                    expectedCurrent: current,
                    didReplace: &rollbackReplacedConfiguration
                )
                guard rollbackReplacedConfiguration else {
                    throw MacSystemPowerPolicyError.verificationFailed
                }
                try restartAndVerifyLidGuard()

                let restored = try secureConfigurationSnapshot()
                guard restored.data == original.data,
                      restored.mode == original.mode,
                      restored.owner == original.owner else {
                    throw MacSystemPowerPolicyError.verificationFailed
                }
                if let originalPasswordRequirement {
                    try waitForActualPasswordRequirement(originalPasswordRequirement)
                }
            } catch {
                throw MacSystemPowerPolicyError.rollbackFailed(
                    "原操作失败：\(Self.errorMessage(originalError))；"
                        + "配置回滚失败：\(Self.errorMessage(error))"
                )
            }
            throw originalError
        }
    }

    private func readSleepDisabledFromPMSet() throws -> Bool {
        let result = try Self.run(
            "/usr/bin/pmset",
            arguments: ["-g"],
            timeout: Self.standardCommandTimeout
        )
        guard result.exitCode == 0 else {
            throw MacSystemPowerPolicyError.commandFailed("无法读取当前系统级合盖续跑状态。")
        }
        guard let value = Self.parseSleepDisabled(result.output)
                ?? MacSystemPowerPolicyProbe.sleepDisabled() else {
            throw MacSystemPowerPolicyError.commandFailed("系统没有返回可识别的合盖续跑状态。")
        }
        return value
    }

    static func closedLidLeaseMarkerPath(userID: uid_t) -> String {
        "/private/var/tmp/com.tidux.codex-watch-pet.closed-lid-\(userID).lease"
    }

    static func signalClosedLidLeaseEnd(userID: uid_t) {
        let path = closedLidLeaseMarkerPath(userID: userID)
        if unlink(path) != 0, errno != ENOENT {
            // The watchdog still has a hard deadline. A failed early signal is
            // surfaced by the read-back timeout in `endClosedLidContinuityLease`.
        }
    }

    private static func normalizedLeaseDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return MacClosedLidContinuityLease.twoHours }
        return min(
            max(duration, MobilityPolicy.minimumAllowedDurationSeconds),
            MobilityPolicy.maximumAllowedDurationSeconds
        )
    }

    private func restartAndVerifyLidGuard() throws {
        let restart = try Self.run(
            "/bin/launchctl",
            arguments: [
                "kickstart",
                "-k",
                "gui/\(userID)/\(Self.lidGuardLabel)"
            ],
            timeout: Self.standardCommandTimeout
        )
        guard restart.exitCode == 0 else {
            throw MacSystemPowerPolicyError.legacyPolicyRestartFailed
        }

        for _ in 0..<20 {
            let state = try Self.run(
                "/bin/launchctl",
                arguments: ["print", "gui/\(userID)/\(Self.lidGuardLabel)"],
                timeout: Self.standardCommandTimeout
            )
            if state.exitCode == 0 { return }
            usleep(100_000)
        }
        throw MacSystemPowerPolicyError.legacyPolicyRestartFailed
    }

    private func readActualPasswordRequirementIfAvailable() -> Bool? {
        do {
            return try readActualPasswordRequirement()
        } catch {
            return nil
        }
    }

    private func readActualPasswordRequirement() throws -> Bool {
        let currentHost = try readDefaultsBoolean(arguments: [
            "-currentHost", "read", "com.apple.screensaver", "askForPassword"
        ])
        let global = try readDefaultsBoolean(arguments: [
            "read", "com.apple.screensaver", "askForPassword"
        ])
        guard currentHost == global else {
            throw MacSystemPowerPolicyError.verificationFailed
        }
        return currentHost
    }

    private func waitForActualPasswordRequirement(_ expected: Bool) throws {
        for attempt in 0..<20 {
            if (try? readActualPasswordRequirement()) == expected { return }
            if attempt < 19 { usleep(100_000) }
        }
        throw MacSystemPowerPolicyError.verificationFailed
    }

    private func readDefaultsBoolean(arguments: [String]) throws -> Bool {
        let result = try Self.run(
            "/usr/bin/defaults",
            arguments: arguments,
            timeout: Self.standardCommandTimeout
        )
        guard result.exitCode == 0 else {
            throw MacSystemPowerPolicyError.commandFailed(
                "无法读取 macOS 屏幕睡眠密码偏好。"
            )
        }
        switch result.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            throw MacSystemPowerPolicyError.commandFailed(
                "macOS 返回了无法识别的屏幕睡眠密码偏好。"
            )
        }
    }

    private struct SecureConfigurationSnapshot: Equatable {
        let data: Data
        let mode: mode_t
        let owner: uid_t
        let device: dev_t
        let inode: ino_t
    }

    private func secureConfigurationSnapshot() throws -> SecureConfigurationSnapshot {
        var pathStatus = stat()
        guard lstat(configURL.path, &pathStatus) == 0 else {
            if errno == ENOENT {
                throw MacSystemPowerPolicyError.legacyConfigurationUnavailable
            }
            throw MacSystemPowerPolicyError.unsafeConfiguration(
                "无法安全读取 Continuity 合盖策略配置：\(Self.posixMessage())"
            )
        }
        guard (pathStatus.st_mode & S_IFMT) != S_IFLNK else {
            throw MacSystemPowerPolicyError.unsafeConfiguration(
                "Continuity 合盖策略配置是符号链接，已拒绝修改。"
            )
        }
        guard (pathStatus.st_mode & S_IFMT) == S_IFREG else {
            throw MacSystemPowerPolicyError.unsafeConfiguration(
                "Continuity 合盖策略配置不是普通文件，已拒绝修改。"
            )
        }
        guard pathStatus.st_uid == userID else {
            throw MacSystemPowerPolicyError.unsafeConfiguration(
                "Continuity 合盖策略配置不属于当前用户，已拒绝修改。"
            )
        }

        let descriptor = open(configURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MacSystemPowerPolicyError.unsafeConfiguration(
                "无法安全打开 Continuity 合盖策略配置：\(Self.posixMessage())"
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        do {
            var descriptorStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0 else {
                throw MacSystemPowerPolicyError.unsafeConfiguration(
                    "无法复查 Continuity 合盖策略配置：\(Self.posixMessage())"
                )
            }
            guard (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
                  descriptorStatus.st_uid == userID,
                  descriptorStatus.st_dev == pathStatus.st_dev,
                  descriptorStatus.st_ino == pathStatus.st_ino else {
                throw MacSystemPowerPolicyError.unsafeConfiguration(
                    "Continuity 合盖策略配置在读取期间发生变化，已拒绝修改。"
                )
            }

            let data = try handle.readToEnd() ?? Data()
            try handle.close()
            return SecureConfigurationSnapshot(
                data: data,
                mode: descriptorStatus.st_mode & mode_t(0o7777),
                owner: descriptorStatus.st_uid,
                device: descriptorStatus.st_dev,
                inode: descriptorStatus.st_ino
            )
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func secureAtomicReplaceConfiguration(
        with data: Data,
        mode: mode_t,
        expectedCurrent: SecureConfigurationSnapshot,
        didReplace: inout Bool
    ) throws {
        let directory = configURL.deletingLastPathComponent()
        let temporaryName = ".\(configURL.lastPathComponent).codex-mobility.XXXXXX"
        var template = Array(directory.appendingPathComponent(temporaryName).path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw MacSystemPowerPolicyError.commandFailed(
                "无法创建安全的配置临时文件：\(Self.posixMessage())"
            )
        }
        let temporaryPath = Self.stringFromNullTerminatedBytes(template)
        var shouldRemoveTemporaryFile = true
        defer {
            if descriptor >= 0 { close(descriptor) }
            if shouldRemoveTemporaryFile { unlink(temporaryPath) }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw MacSystemPowerPolicyError.commandFailed(
                "无法限制配置临时文件权限：\(Self.posixMessage())"
            )
        }
        try Self.writeAll(data, to: descriptor)
        guard fchmod(descriptor, mode) == 0 else {
            throw MacSystemPowerPolicyError.commandFailed(
                "无法恢复配置文件权限：\(Self.posixMessage())"
            )
        }
        guard fsync(descriptor) == 0 else {
            throw MacSystemPowerPolicyError.commandFailed(
                "无法将配置安全写入磁盘：\(Self.posixMessage())"
            )
        }

        // Re-open with O_NOFOLLOW immediately before rename and compare the
        // exact snapshot, so an external edit is never silently overwritten.
        let current = try secureConfigurationSnapshot()
        guard current == expectedCurrent else {
            throw MacSystemPowerPolicyError.unsafeConfiguration(
                "Continuity 合盖策略配置在保存前已被其他程序修改，本次操作已取消。"
            )
        }

        guard rename(temporaryPath, configURL.path) == 0 else {
            throw MacSystemPowerPolicyError.commandFailed(
                "无法原子替换 Continuity 合盖策略配置：\(Self.posixMessage())"
            )
        }
        shouldRemoveTemporaryFile = false
        didReplace = true
        try Self.synchronizeDirectory(directory)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw MacSystemPowerPolicyError.commandFailed(
                        "无法写入 Continuity 合盖策略配置：\(Self.posixMessage())"
                    )
                }
                guard count > 0 else {
                    throw MacSystemPowerPolicyError.commandFailed(
                        "写入 Continuity 合盖策略配置时没有取得进展。"
                    )
                }
                offset += count
            }
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MacSystemPowerPolicyError.commandFailed(
                "无法打开 Continuity 配置目录进行落盘确认：\(Self.posixMessage())"
            )
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw MacSystemPowerPolicyError.commandFailed(
                "无法确认 Continuity 配置目录已经落盘：\(Self.posixMessage())"
            )
        }
    }

    static func parseSleepDisabled(_ output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let components = line.split(whereSeparator: \.isWhitespace)
            guard components.count >= 2,
                  components[0].caseInsensitiveCompare("SleepDisabled") == .orderedSame else {
                continue
            }
            switch components[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        var template = Array(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-mobility-process.XXXXXX")
                .path
                .utf8CString
        )
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw MacSystemPowerPolicyError.commandFailed(
                "无法创建命令输出临时文件：\(Self.posixMessage())"
            )
        }
        let outputPath = Self.stringFromNullTerminatedBytes(template)
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            unlink(outputPath)
            throw MacSystemPowerPolicyError.commandFailed(
                "无法限制命令输出文件权限：\(Self.posixMessage())"
            )
        }

        let outputHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? outputHandle.close()
            unlink(outputPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < terminationDeadline {
                usleep(50_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw MacSystemPowerPolicyError.commandTimedOut
        }
        process.waitUntilExit()
        try outputHandle.synchronize()
        try outputHandle.close()
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        return ProcessResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func stringFromNullTerminatedBytes(_ bytes: [CChar]) -> String {
        String(
            decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}

struct ProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String
}

struct ContinuityLidPolicyConfiguration: Equatable, Sendable {
    private static let displaySleepKey = "LID_GUARD_ENABLE_DISPLAY_SLEEP"
    private static let requirePasswordKey = "LID_GUARD_ENABLE_LOCK"
    private static let keepExternalKey = "LID_GUARD_KEEP_EXTERNAL_ACTIVE"
    private static let preserveExternalKey = "LID_GUARD_PRESERVE_EXTERNAL_DISPLAY"
    private static let legacyKeepExternalKey = "LID_GUARD_SKIP_ON_AC_EXTERNAL"

    let text: String
    private let values: [String: [String]]

    init(text: String) {
        self.text = text
        self.values = Self.parseValues(text)
    }

    var displaySleepOnLidClose: Bool? {
        boolValue(Self.displaySleepKey, default: true)
    }

    var requirePasswordAfterDisplaySleep: Bool? {
        boolValue(Self.requirePasswordKey, default: true)
    }

    var keepExternalDisplayActive: Bool? {
        if values[Self.keepExternalKey] != nil {
            return boolValue(Self.keepExternalKey, default: true)
        }
        if values[Self.preserveExternalKey] != nil {
            return boolValue(Self.preserveExternalKey, default: true)
        }
        return boolValue(Self.legacyKeepExternalKey, default: true)
    }

    func value(for control: MacSystemPolicyControl) -> Bool? {
        switch control {
        case .closedLidContinuity:
            nil
        case .displaySleepOnLidClose:
            displaySleepOnLidClose
        case .requirePasswordAfterDisplaySleep:
            requirePasswordAfterDisplaySleep
        case .keepExternalDisplayActive:
            keepExternalDisplayActive
        }
    }

    func updating(control: MacSystemPolicyControl, enabled: Bool) -> String {
        let key: String
        switch control {
        case .closedLidContinuity:
            return text
        case .displaySleepOnLidClose:
            key = Self.displaySleepKey
        case .requirePasswordAfterDisplaySleep:
            key = Self.requirePasswordKey
        case .keepExternalDisplayActive:
            key = Self.keepExternalKey
        }

        let replacement = "\(key)=\(enabled ? "1" : "0")"
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var replaced = false
        lines = lines.compactMap { line in
            guard Self.key(in: line) == key else { return line }
            guard !replaced else { return nil }
            replaced = true
            return replacement
        }
        if !replaced {
            if lines.last == "" { lines.removeLast() }
            lines.append(replacement)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func boolValue(_ key: String, default defaultValue: Bool) -> Bool? {
        guard let occurrences = values[key] else { return defaultValue }
        guard occurrences.count == 1, let rawValue = occurrences.first else { return nil }
        switch rawValue.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func parseValues(_ text: String) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let rawLine = String(line)
            guard let key = key(in: rawLine),
                  let separator = rawLine.firstIndex(of: "=") else { continue }
            var value = rawLine[rawLine.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.first == "\"" && value.last == "\""
                || value.first == "'" && value.last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            values[key, default: []].append(value)
        }
        return values
    }

    private static func key(in line: String) -> String? {
        var candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.hasPrefix("#") else { return nil }
        if candidate.hasPrefix("export ") {
            candidate.removeFirst("export ".count)
        }
        guard let separator = candidate.firstIndex(of: "=") else { return nil }
        let key = candidate[..<separator].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return key
    }
}
