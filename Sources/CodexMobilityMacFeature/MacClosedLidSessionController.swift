import CodexMobilityCore
import Combine
import Darwin
import Foundation
import OSLog

public enum MacClosedLidSessionPhase: String, Equatable, Sendable {
    case off
    case preparing
    case active
    case stopping
    case failed
}

public enum MacClosedLidSessionError: Error, LocalizedError, Equatable, Sendable {
    case hotspotNotConfigured
    case moduleConfigurationFailed(String)
    case hotspotConnectionFailed(String)
    case hotspotRouteUnavailable(String)
    case systemLeaseFailed(String)
    case mobilityPreflightFailed(String)
    case recoveryJournalFailed(String)
    case moduleConfigurationRestoreFailed(String)
    case interruptedSessionRecoveryFailed(String)
    case systemLeaseReleaseFailed(String)
    case startAndSystemLeaseReleaseFailed(start: String, release: String)

    public var errorDescription: String? {
        switch self {
        case .hotspotNotConfigured:
            "请先在“热点自动重连”中填写 iPhone 5G 热点名称，并确保它已保存在 macOS 首选网络中。"
        case .moduleConfigurationFailed(let message):
            "无法启用合盖与热点模块：\(message)"
        case .hotspotConnectionFailed(let message):
            "无法连接已保存的 5G 手机热点：\(message)"
        case .hotspotRouteUnavailable(let message):
            "手机热点已关联，但网络路径尚未就绪：\(message)"
        case .systemLeaseFailed(let message):
            "无法开启 定时系统合盖租约：\(message)"
        case .mobilityPreflightFailed(let message):
            "合盖续航预检未通过：\(message)"
        case .recoveryJournalFailed(let message):
            "无法保存临时覆盖恢复记录：\(message)"
        case .moduleConfigurationRestoreFailed(let message):
            "系统合盖策略已处理，但模块配置恢复失败：\(message)"
        case .interruptedSessionRecoveryFailed(let message):
            "上次临时覆盖尚未恢复：\(message)"
        case .systemLeaseReleaseFailed(let message):
            "会话已停止，但系统合盖策略回滚失败：\(message)"
        case .startAndSystemLeaseReleaseFailed(let start, let release):
            "合盖续航启动失败：\(start)；且系统合盖策略回滚失败：\(release)"
        }
    }
}

public protocol MacDisplaySleepRequesting: Sendable {
    func requestDisplaySleep() async throws
}

public struct ProcessMacDisplaySleepRequester: MacDisplaySleepRequesting {
    public init() {}

    public func requestDisplaySleep() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                process.arguments = ["displaysleepnow"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output

                do {
                    try process.run()
                    process.waitUntilExit()
                    let message = String(
                        decoding: output.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    )
                    guard process.terminationStatus == 0 else {
                        throw MacSystemPowerPolicyError.commandFailed(
                            message.trimmingCharacters(in: .whitespacesAndNewlines)
                                .nonEmpty
                                ?? "macOS 拒绝了关闭显示器请求。"
                        )
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
public final class MacClosedLidSessionController: ObservableObject {
    private static let logger = Logger(subsystem: "com.tidux.CodexWatchPet.mac", category: "mobility-startup")
    public static let sessionDuration: TimeInterval = 2 * 60 * 60
    /// Zero is an explicit local-only unlimited selection, never a remote policy value.
    public static let durationMinutesChoices = Array(stride(from: 15, through: 240, by: 15)) + [480, 720, 1440, 0]
    public static let maximumLocalDuration: TimeInterval = 24 * 60 * 60
    public var isIndefinite: Bool { selectedDuration == 0 }
    public var caffeine: MacCaffeineController? { caffeineController }
    private let caffeineController: MacCaffeineController?
    private var leaseRenewalTask: Task<Void, Never>?
    private var needsLeaseRenewal: Bool { isIndefinite || selectedDuration > MobilityPolicy.maximumAllowedDurationSeconds }
    private var systemLeaseDuration: TimeInterval { needsLeaseRenewal ? 2 * 60 * 60 : selectedDuration }
    static let durationPreferenceKey = "closedLidSession.durationSeconds.v1"
    @Published public private(set) var selectedDuration: TimeInterval
    @Published public private(set) var isMobileOfficeSession = false
    public var agentDesktop: MacAgentDesktopController? { agentDesktopController }

    public var canEditDuration: Bool {
        (phase == .off || phase == .failed)
            && sessionJournal == nil && !requiresSystemPolicyRecovery
    }

    public var durationLabel: String {
        Self.durationLabel(seconds: selectedDuration)
    }

    public static func durationLabel(seconds: TimeInterval) -> String {
        if seconds == 0 { return "无限（手动结束）" }
        let minutes = Int(normalizedDuration(seconds) / 60)
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    @discardableResult
    public func setDuration(_ seconds: TimeInterval) -> Bool {
        guard canEditDuration, seconds.isFinite else { return false }
        selectedDuration = Self.normalizedDuration(seconds)
        durationPreferences.set(selectedDuration, forKey: Self.durationPreferenceKey)
        return true
    }
    // One monotonic budget covers the initial explicit join and any route
    // recovery after administrator work. The administrator interaction itself
    // is excluded so a slow password prompt cannot consume the network budget.
    // This Mac's iPhone Personal Hotspot needed about 26 seconds to publish
    // DHCP and its default route. Keep one bounded observation window above
    // that measured delay, without restarting the join while DHCP is settling.
    public static let networkRecoveryTimeout: TimeInterval = 40
    public static let maximumForcedNetworkJoinAttempts = 1
    public static let networkRetryDelay: TimeInterval = 0.5

    @Published public private(set) var phase: MacClosedLidSessionPhase = .off {
        didSet {
            if phase == .off || phase == .stopping || phase == .failed {
                agentDesktopController?.endSession()
                caffeineController?.endMobileOffice()
                leaseRenewalTask?.cancel()
                leaseRenewalTask = nil
            }
            if phase == .off || phase == .failed { isMobileOfficeSession = false }
        }
    }
    @Published public private(set) var expiresAt: Date?
    @Published public private(set) var statusMessage = "关闭"
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var baselineClosedLidEnabled: Bool?
    @Published public private(set) var remoteControlReadiness =
        MacCodexRemoteControlReadiness.notChecked
    @Published public private(set) var lastStartupDuration: TimeInterval?

    public var isToggleOn: Bool {
        phase == .preparing || phase == .active
    }

    public var isBusy: Bool {
        phase == .preparing || phase == .stopping
    }

    public var requiresSystemPolicyRecovery: Bool {
        powerPolicyStore.activeClosedLidLease != nil
    }

    public var requiresTemporaryOverrideRecovery: Bool {
        requiresSystemPolicyRecovery
            || (sessionJournal != nil && phase == .failed)
    }

    public var isToggleEnabled: Bool {
        isToggleOn || (!requiresSystemPolicyRecovery && sessionJournal == nil)
    }

    public var isBaselineToggleOn: Bool {
        baselineClosedLidEnabled
            ?? powerPolicyStore.snapshot.sleepDisabled
            ?? false
    }

    public var isBaselineToggleEnabled: Bool {
        sessionJournal == nil
            && phase != .preparing
            && phase != .active
            && phase != .stopping
            && !powerPolicyStore.isBusy
            && !requiresSystemPolicyRecovery
    }

    public var hotspotTargetName: String? {
        hotspotStore.preferredSSIDs.first
    }

    private let agentDesktopController: MacAgentDesktopController?
    private let store: MacMobilityStore
    private let moduleStore: MobilityModuleConfigurationStore
    private let powerPolicyStore: MacSystemPowerPolicyStore
    private let hotspotStore: MacHotspotAutomationStore
    private let remoteControlChecker: any MacCodexRemoteControlChecking
    private let journalPersistence: any MacClosedLidSessionJournalPersisting
    private let durationPreferences: UserDefaults
    private var duration: TimeInterval { selectedDuration }
    private let networkRecoveryTimeout: TimeInterval
    private let maximumForcedNetworkJoinAttempts: Int
    private let networkRetryDelay: TimeInterval
    private let now: @MainActor () -> Date
    private let signalLeaseEnd: @MainActor () -> Void

    private var lease: MacClosedLidContinuityLease?
    private var cleanupTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration: UInt64 = 0
    private var preparationOperationOutstanding = false
    private var sessionJournal: MacClosedLidSessionJournal?
    private var remoteControlRecoveryTask: Task<Void, Never>?
    private var remoteControlRecoveryGeneration: UInt64 = 0
    private var lastHotspotNetworkAvailable = false
    private var cancellables: Set<AnyCancellable> = []

    public init(
        store: MacMobilityStore,
        moduleStore: MobilityModuleConfigurationStore,
        powerPolicyStore: MacSystemPowerPolicyStore,
        hotspotStore: MacHotspotAutomationStore,
        remoteControlChecker: any MacCodexRemoteControlChecking =
            ProcessMacCodexRemoteControlChecker(),
        agentDesktopController: MacAgentDesktopController? = nil,
        caffeineController: MacCaffeineController? = nil,
        leaseEndSignal: (@MainActor () -> Void)? = nil,
        journalDefaults: UserDefaults? = nil,
        duration: TimeInterval? = nil,
        networkRecoveryTimeout: TimeInterval =
            MacClosedLidSessionController.networkRecoveryTimeout,
        maximumForcedNetworkJoinAttempts: Int =
            MacClosedLidSessionController.maximumForcedNetworkJoinAttempts,
        networkRetryDelay: TimeInterval =
            MacClosedLidSessionController.networkRetryDelay,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.agentDesktopController = agentDesktopController
        self.caffeineController = caffeineController
        self.signalLeaseEnd = leaseEndSignal ?? {
            LocalMacSystemPowerPolicyBackend.signalClosedLidLeaseEnd(userID: getuid())
        }
        self.store = store
        self.moduleStore = moduleStore
        self.powerPolicyStore = powerPolicyStore
        self.hotspotStore = hotspotStore
        self.remoteControlChecker = remoteControlChecker
        self.journalPersistence = journalDefaults.map {
            UserDefaultsMacClosedLidSessionJournalPersistence(defaults: $0)
        } ?? UserDefaultsMacClosedLidSessionJournalPersistence()
        let preferences = journalDefaults ?? UserDefaults(
            suiteName: UserDefaultsMacClosedLidSessionJournalPersistence.suiteName
        )!
        self.durationPreferences = preferences
        let savedDuration = preferences.object(forKey: Self.durationPreferenceKey) as? Double
        self.selectedDuration = Self.normalizedDuration(
            duration ?? savedDuration ?? Self.sessionDuration
        )
        self.networkRecoveryTimeout = max(
            networkRecoveryTimeout.isFinite ? networkRecoveryTimeout : Self.networkRecoveryTimeout,
            0.01
        )
        self.maximumForcedNetworkJoinAttempts = max(maximumForcedNetworkJoinAttempts, 1)
        self.networkRetryDelay = max(
            networkRetryDelay.isFinite ? networkRetryDelay : 0,
            0
        )
        self.now = now

        do {
            sessionJournal = try self.journalPersistence.loadJournal()
            if let sessionJournal {
                baselineClosedLidEnabled = sessionJournal.baselineSleepDisabled
                phase = .stopping
                expiresAt = sessionJournal.expiresAt
                statusMessage = "检测到上次临时覆盖，正在等待恢复。"
            }
        } catch {
            phase = .failed
            let message = MacClosedLidSessionError.recoveryJournalFailed(
                Self.errorMessage(error)
            ).localizedDescription
            lastErrorMessage = message
            statusMessage = message
        }

        store.$status
            .sink { [weak self] status in
                self?.handleMobilityStatusChange(status)
            }
            .store(in: &cancellables)

        hotspotStore.$snapshot
            .sink { [weak self] snapshot in
                self?.handleHotspotSnapshot(snapshot)
            }
            .store(in: &cancellables)
    }

    deinit {
        cleanupTask?.cancel()
        preparationTask?.cancel()
        remoteControlRecoveryTask?.cancel()
    }

    public func setEnabled(_ enabled: Bool, mobileOffice: Bool = false) async {
        if enabled {
            guard preparationTask == nil, phase == .off || phase == .failed else { return }
            isMobileOfficeSession = mobileOffice
            preparationGeneration &+= 1
            let generation = preparationGeneration
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.start()
            }
            preparationTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            if generation == preparationGeneration {
                preparationTask = nil
            }
        } else {
            preparationTask?.cancel()
            await stop()
        }
    }

    public func setBaselineClosedLidEnabled(_ enabled: Bool) async {
        guard isBaselineToggleEnabled else { return }
        await powerPolicyStore.refreshNow()
        guard await powerPolicyStore.setClosedLidContinuityEnabled(enabled) else {
            let message = powerPolicyStore.lastErrorMessage
                ?? "无法修改系统级合盖运行配置。"
            lastErrorMessage = message
            statusMessage = message
            return
        }
        baselineClosedLidEnabled = nil
        lastErrorMessage = nil
        statusMessage = enabled ? "基础合盖运行已开启。" : "基础合盖运行已关闭。"
    }

    /// Restores an interrupted temporary override before a new session can be
    /// started. This runs on App launch and is also safe to retry from the UI.
    public func recoverInterruptedSessionIfNeeded() async {
        guard let journal = sessionJournal else { return }
        hotspotStore.setLocalClosedLidSessionAuthorization(false)
        cancelRemoteControlRecovery()
        if store.mode.isEnabled {
            store.stop(reason: "正在恢复上次临时覆盖。")
        }
        phase = .stopping
        statusMessage = "正在恢复上次临时覆盖的系统与模块配置…"

        var restoringJournal = journal
        restoringJournal.phase = .restoring
        try? journalPersistence.saveJournal(restoringJournal)
        sessionJournal = restoringJournal

        let systemRestored = await powerPolicyStore.recoverInterruptedClosedLidSession(
            baselineEnabled: journal.baselineSleepDisabled
        )
        let modulesRestored = moduleStore.restore(journal.baselineModuleConfiguration)
        if systemRestored, modulesRestored, clearJournal() {
            baselineClosedLidEnabled = nil
            expiresAt = nil
            phase = .off
            lastErrorMessage = nil
            statusMessage = "上次临时覆盖已恢复；基础合盖配置保持不变。"
            return
        }

        markJournalRestoreFailed()
        let details = [
            systemRestored ? nil : powerPolicyStore.lastErrorMessage,
            modulesRestored ? nil : moduleStore.persistenceErrorMessage
        ].compactMap { $0 }.joined(separator: "；")
        let error = MacClosedLidSessionError.interruptedSessionRecoveryFailed(
            details.nonEmpty ?? "无法确认恢复结果。"
        )
        phase = .failed
        lastErrorMessage = error.localizedDescription
        statusMessage = error.localizedDescription
    }

    public func start() async {
        guard sessionJournal == nil,
              phase == .off || phase == .failed else {
            if sessionJournal != nil {
                await recoverInterruptedSessionIfNeeded()
            }
            return
        }
        let recoveryClock = ContinuousClock()
        let startupBegan = recoveryClock.now
        lastStartupDuration = nil
        cancelRemoteControlRecovery()
        remoteControlReadiness = .notChecked
        traceStartup("begin", since: startupBegan)
        var networkRecoveryDeadline = recoveryClock.now.advanced(
            by: .seconds(networkRecoveryTimeout)
        )
        hotspotStore.setLocalClosedLidSessionAuthorization(false)
        preparationOperationOutstanding = true
        phase = .preparing
        statusMessage = isMobileOfficeSession
            ? "正在准备合盖续跑与电源保护…"
            : "正在连接并确认指定热点（最长 "
            + Self.durationText(networkRecoveryTimeout)
            + " 秒）…"
        lastErrorMessage = nil
        expiresAt = nil

        do {
            // Honor the saved desktop-protection choice in both session modes.
            // A background-only session still needs no unlocked display. When the
            // user opted in, Mobile Office dims instead of requesting display sleep,
            // preserving the existing system password policy.
            try await agentDesktopController?.beginSession(dimOnLidClose: isMobileOfficeSession)
            try ensurePreparationContinues()
            traceStartup("desktop-checked", since: startupBegan)
            guard isMobileOfficeSession || !hotspotStore.preferredSSIDs.isEmpty else {
                throw MacClosedLidSessionError.hotspotNotConfigured
            }

            await powerPolicyStore.refreshNow()
            try ensurePreparationContinues()
            traceStartup("power-read", since: startupBegan)
            guard let baselineSleepDisabled = powerPolicyStore.snapshot.sleepDisabled else {
                throw MacClosedLidSessionError.systemLeaseFailed(
                    "暂时无法读取系统合盖运行状态，未修改任何配置。"
                )
            }
            let startedAt = now()
            let journal = MacClosedLidSessionJournal(
                baselineSleepDisabled: baselineSleepDisabled,
                baselineModuleConfiguration: moduleStore.configuration,
                startedAt: startedAt,
                expiresAt: isIndefinite ? nil : startedAt.addingTimeInterval(duration)
            )
            do {
                try journalPersistence.saveJournal(journal)
            } catch {
                throw MacClosedLidSessionError.recoveryJournalFailed(
                    Self.errorMessage(error)
                )
            }
            sessionJournal = journal
            baselineClosedLidEnabled = baselineSleepDisabled

            try enableRequiredModules()
            // The bounded network budget begins when network work actually
            // starts. Journal I/O and an initial power-state read must not
            // consume it under a busy system.
            networkRecoveryDeadline = recoveryClock.now.advanced(
                by: .seconds(networkRecoveryTimeout)
            )

            let initiallyConnected: Bool
            let canRecoverNetworkDuringSession: Bool
            if isMobileOfficeSession {
                // A mobile session preserves usable Wi-Fi. Its existing,
                // session-owned recovery controller verifies internet access
                // and joins the saved hotspot only after connectivity fails.
                // Association, DHCP and remote-control checks are not startup
                // gates and must not create a second concurrent join owner.
                initiallyConnected = store.status.network.isConnected
                canRecoverNetworkDuringSession = true
            } else {
                do {
                    // “合盖连热点” is an explicit request to use the configured
                    // phone hotspot, even when an ordinary Wi-Fi route is healthy.
                    // The hotspot store still avoids a disruptive join when the
                    // configured target is already associated, or when macOS hides
                    // its SSID but exposes a metered Personal Hotspot path.
                    initiallyConnected = try await connectPreferredNetwork(
                        until: networkRecoveryDeadline
                    )
                    canRecoverNetworkDuringSession = initiallyConnected
                        || canContinueWithSessionScopedNetworkRecovery
                } catch let error as MacClosedLidSessionError {
                    // A bounded join can time out while Personal Hotspot is still
                    // publishing association/DHCP state. The two-hour lease owns a
                    // session-scoped reconnect controller, so route timeout is a
                    // degraded startup condition rather than a reason to bounce the
                    // user's toggle back off. Identity/configuration failures below
                    // remain hard failures.
                    guard case .hotspotRouteUnavailable = error else { throw error }
                    initiallyConnected = false
                    canRecoverNetworkDuringSession = true
                }
            }
            try ensurePreparationContinues()
            traceStartup("network-deferred-or-checked", since: startupBegan)
            if !initiallyConnected {
                guard canRecoverNetworkDuringSession else {
                    throw currentHotspotConnectionError()
                }
                statusMessage = "网络暂不可用；正在开启续航，会话中将继续重连…"
            }

            let systemPolicyWorkStartedAt = recoveryClock.now
            // Explicit hotspot startup may have spent 40s joining; refresh its
            // baseline. Mobile startup already read it above, and beginLease
            // independently reads/verifies the actual system power policy.
            if !isMobileOfficeSession { await powerPolicyStore.refreshNow() }
            try ensurePreparationContinues()
            statusMessage = "正在启用并确认限时合盖运行…"
            guard let lease = await powerPolicyStore.beginClosedLidContinuityLease(
                duration: systemLeaseDuration,
                now: now()
            ) else {
                throw MacClosedLidSessionError.systemLeaseFailed(
                    powerPolicyStore.lastErrorMessage ?? "管理员验证没有完成。"
                )
            }
            networkRecoveryDeadline = networkRecoveryDeadline.advanced(
                by: systemPolicyWorkStartedAt.duration(to: recoveryClock.now)
            )
            self.lease = lease
            traceStartup("lease-verified", since: startupBegan)
            try updateJournal { journal in
                journal.didEnableSystemPolicy = lease.didEnableSystemPolicy
            }
            store.setTimedClosedLidLeaseActive(true)
            try ensurePreparationContinues()

            if store.mode.isEnabled {
                store.stop(reason: "正在切换到“定时合盖续跑”。")
            }
            if isMobileOfficeSession {
                store.start(profile: .closedLidLabs, maximumDurationSeconds: duration,
                            localSessionDeadline: isIndefinite ? nil : lease.startedAt.addingTimeInterval(duration),
                            localSessionIndefinite: isIndefinite, now: lease.startedAt)
                guard store.mode.phase == .active || store.mode.phase == .degraded else {
                    throw MacClosedLidSessionError.mobilityPreflightFailed(
                        store.mode.detail ?? "本机安全检查未通过。")
                }
            } else {
                try await startMobilityRuntimeAfterNetworkStabilizes(
                    leaseStartedAt: lease.startedAt,
                    networkRecoveryDeadline: networkRecoveryDeadline
                )
            }
            traceStartup("runtime-ready", since: startupBegan)

            // The local administrator action authorizes reconnect only for this
            // successful two-hour session. It is not written to preferences and
            // does not grant BLE, remote-control, status, or file-sync access.
            hotspotStore.setLocalClosedLidSessionAuthorization(true)

            if !isMobileOfficeSession {
                statusMessage = initiallyConnected
                    ? "热点路径已就绪，正在验证 Codex 官方远控…"
                    : "热点尚未就绪，守护将继续重试；正在检查当前网络的远控连接…"
                remoteControlReadiness = await remoteControlChecker.ensureConnected(
                    timeout: ProcessMacCodexRemoteControlChecker.defaultTimeout
                )
                try ensurePreparationContinues()
            }

            expiresAt = isIndefinite ? nil : store.mode.expiresAt ?? lease.expiresAt
            if isMobileOfficeSession, let caffeineController,
               !caffeineController.beginMobileOffice(expiresAt: expiresAt) {
                throw MacClosedLidSessionError.mobilityPreflightFailed(
                    caffeineController.errorMessage ?? "咖啡因启动失败。")
            }
            try updateJournal { journal in
                journal.phase = .active
                journal.expiresAt = self.expiresAt
            }
            phase = .active
            scheduleLeaseRenewal()
            statusMessage = activeStatusMessage(for: lease)
            preparationOperationOutstanding = false
            lastStartupDuration = startupSeconds(since: startupBegan)
            traceStartup("active", since: startupBegan)
            // Starting continuity must leave the open-lid desktop usable.
            // Display sleep and locking remain governed by lid and idle policies.
            scheduleRemoteControlRecovery()
        } catch is CancellationError {
            traceStartup("cancelled", since: startupBegan)
            await cancelPreparation()
        } catch {
            traceStartup("failed", since: startupBegan)
            if phase == .stopping {
                await cancelPreparation()
                return
            }
            await failStart(with: error)
        }
    }

    public func stop() async {
        hotspotStore.setLocalClosedLidSessionAuthorization(false)
        guard phase != .off, phase != .stopping else { return }
        if phase == .preparing {
            preparationTask?.cancel()
            phase = .stopping
            statusMessage = "正在取消开启并恢复系统与模块配置…"
            if preparationOperationOutstanding {
                signalLeaseEnd()
            }
            return
        }
        phase = .stopping
        statusMessage = "正在停止并恢复系统与模块配置…"

        if store.mode.isEnabled {
            store.stop(reason: "已手动关闭“定时合盖续跑”。")
        }
        await finishLeaseAndPublishOff()
    }

    public func retrySystemPolicyRecovery() async {
        hotspotStore.setLocalClosedLidSessionAuthorization(false)
        guard requiresTemporaryOverrideRecovery, phase != .stopping else { return }
        if powerPolicyStore.activeClosedLidLease == nil, sessionJournal != nil {
            await recoverInterruptedSessionIfNeeded()
            return
        }
        phase = .stopping
        statusMessage = "正在重试恢复系统与模块配置…"
        await finishLeaseAndPublishOff()
    }

    public func shutdown() {
        caffeineController?.endMobileOffice()
        leaseRenewalTask?.cancel()
        leaseRenewalTask = nil
        agentDesktopController?.endSession()
        hotspotStore.setLocalClosedLidSessionAuthorization(false)
        cleanupTask?.cancel()
        preparationTask?.cancel()
        cancelRemoteControlRecovery()
        if preparationOperationOutstanding {
            phase = .stopping
            statusMessage = "App 正在退出；系统守护会继续负责到期回滚。"
        }
        if preparationOperationOutstanding
            || lease?.didEnableSystemPolicy == true
            || powerPolicyStore.activeClosedLidLease?.didEnableSystemPolicy == true {
            signalLeaseEnd()
        }
        if let sessionJournal {
            _ = moduleStore.restore(sessionJournal.baselineModuleConfiguration)
        }
        store.setTimedClosedLidLeaseActive(false)
    }

    private func enableRequiredModules() throws {
        moduleStore.setExperimentalModulesEnabled(true)
        for id in [
            MobilityModuleID.travelRuntime,
            .closedLidLabs,
            .hotspotAutomation
        ] {
            guard let descriptor = moduleStore.catalog.descriptor(for: id) else {
                throw MacClosedLidSessionError.moduleConfigurationFailed(
                    "缺少模块 \(id.rawValue)。"
                )
            }
            moduleStore.setModule(descriptor, selected: true)
        }
        if let message = moduleStore.persistenceErrorMessage {
            throw MacClosedLidSessionError.moduleConfigurationFailed(message)
        }
    }

    private func startMobilityRuntimeAfterNetworkStabilizes(
        leaseStartedAt: Date,
        networkRecoveryDeadline: ContinuousClock.Instant
    ) async throws {
        var preferredNetworkWasVerified = true
        var forcedJoinAttempts = 0
        var lastNetworkBlockerDetail = "网络不可用。"

        while true {
            try ensurePreparationContinues()

            if !preferredNetworkWasVerified {
                guard forcedJoinAttempts < maximumForcedNetworkJoinAttempts else {
                    throw MacClosedLidSessionError.mobilityPreflightFailed(
                        lastNetworkBlockerDetail
                    )
                }
                forcedJoinAttempts += 1
                statusMessage =
                    "正在重试连接指定热点（\(forcedJoinAttempts)"
                    + "/\(maximumForcedNetworkJoinAttempts)）…"
                preferredNetworkWasVerified = try await connectPreferredNetwork(
                    until: networkRecoveryDeadline
                )
                try ensurePreparationContinues()
                guard preferredNetworkWasVerified else {
                    if forcedJoinAttempts == maximumForcedNetworkJoinAttempts {
                        throw currentHotspotConnectionError()
                    }
                    let reconnectDetail = hotspotStore.lastConnectionErrorMessage
                        ?? "热点尚未恢复可用网络路径。"
                    statusMessage =
                        "热点重连尚未完成（\(forcedJoinAttempts)"
                        + "/\(maximumForcedNetworkJoinAttempts)）："
                        + reconnectDetail
                    try await waitBeforeNetworkRetry(until: networkRecoveryDeadline)
                    continue
                }
            }

            store.start(
                profile: .closedLidLabs,
                maximumDurationSeconds: duration,
                localSessionDeadline: isIndefinite ? nil : leaseStartedAt.addingTimeInterval(duration),
                localSessionIndefinite: isIndefinite,
                now: leaseStartedAt
            )
            let preflightBlockers = store.consumeLastPreflightBlockers()
            if store.mode.phase == .active || store.mode.phase == .degraded {
                return
            }

            let detail = store.mode.detail ?? "本机安全检查未通过。"
            lastNetworkBlockerDetail = detail
            let isTransientNetworkOnly =
                store.mode.phase == .blocked
                    && preflightBlockers == [.networkUnavailable]
            guard isTransientNetworkOnly else {
                throw MacClosedLidSessionError.mobilityPreflightFailed(detail)
            }

            statusMessage =
                "网络路径中断，准备连接指定热点…"
            preferredNetworkWasVerified = false
        }
    }

    private func connectPreferredNetwork(
        until deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        let clock = ContinuousClock()
        guard clock.now < deadline else {
            throw networkRecoveryTimedOutError()
        }
        let operation = Task<Bool, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.hotspotStore.connectPreferredNetworkNow(
                // This controller is reached only from the explicit local
                // “合盖连热点” action. Prefer the configured hotspot over a
                // healthy ordinary Wi-Fi link; the store itself preserves an
                // already-associated target and a privacy-hidden mobile path.
                forcePreferredNetworkJoin: true,
                networkStatusProvider: self.refreshedNetworkStatus
            )
        }
        let timeoutTask = Task<Void, Never> {
            do {
                try await clock.sleep(until: deadline)
                operation.cancel()
            } catch {
                return
            }
        }

        return try await withTaskCancellationHandler {
            defer { timeoutTask.cancel() }
            do {
                return try await operation.value
            } catch is CancellationError {
                if clock.now >= deadline {
                    throw networkRecoveryTimedOutError()
                }
                throw CancellationError()
            }
        } onCancel: {
            operation.cancel()
            timeoutTask.cancel()
        }
    }

    private func waitBeforeNetworkRetry(
        until deadline: ContinuousClock.Instant
    ) async throws {
        if networkRetryDelay > 0 {
            let clock = ContinuousClock()
            let wakeAt = clock.now.advanced(by: .seconds(networkRetryDelay))
            guard wakeAt < deadline else {
                try await clock.sleep(until: deadline)
                throw networkRecoveryTimedOutError()
            }
            try await clock.sleep(until: wakeAt)
        } else {
            await Task.yield()
        }
    }

    private func networkRecoveryTimedOutError() -> MacClosedLidSessionError {
        .hotspotRouteUnavailable(
            "等待指定热点恢复可用网络路径超过 "
                + Self.durationText(networkRecoveryTimeout)
                + " 秒。"
        )
    }

    private func refreshedNetworkStatus() -> MobilityNetworkStatus {
        // A Personal Hotspot can change association, DHCP address and default
        // route independently. Always re-sample immediately for both the
        // one-shot join and every bounded startup recovery attempt.
        store.refreshNow()
        return store.status.network
    }

    private func currentHotspotConnectionError() -> MacClosedLidSessionError {
        let message = hotspotStore.lastConnectionErrorMessage
            ?? "热点当前不可见或凭据不可用。"
        if let hotspotError = hotspotStore.lastConnectionError
            as? MacHotspotAutomationError,
           case .preferredNetworkRouteUnavailable = hotspotError {
            return .hotspotRouteUnavailable(message)
        }
        return .hotspotConnectionFailed(message)
    }

    private var canContinueWithSessionScopedNetworkRecovery: Bool {
        if let error = hotspotStore.lastConnectionError as? MacBackgroundHotspotError {
            switch error {
            case .associationFailed, .unavailable, .timedOut, .rejected: return true
            case .locationPermissionRequired, .unsupported, .ambiguousTarget: return false
            }
        }
        if let hotspotError = hotspotStore.lastConnectionError
            as? MacHotspotAutomationError,
           case .preferredNetworkRouteUnavailable = hotspotError {
            return true
        }
        if let recoveryError = hotspotStore.lastConnectionError
            as? SavedWiFiNetworkRecoveryError,
           recoveryError == .allCandidatesFailed {
            return true
        }
        return false
    }

    private func scheduleLeaseRenewal() {
        guard needsLeaseRenewal else { return }
        leaseRenewalTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.phase == .active else { return }
                await self.renewLeaseIfNeeded()
            }
        }
    }

    /// Keep the privileged watchdog bounded even for an unlimited logical session.
    /// Failure ends the session and restores the original power policy.
    func renewLeaseIfNeeded(at date: Date? = nil) async {
        let instant = date ?? now()
        guard phase == .active, needsLeaseRenewal, let lease,
              lease.expiresAt.timeIntervalSince(instant) <= 60 * 60 else { return }
        if let expiresAt, instant >= expiresAt { return }
        let deadline = min(expiresAt ?? instant.addingTimeInterval(7200), instant.addingTimeInterval(7200))
        guard let renewed = await powerPolicyStore.renewClosedLidContinuityLease(expiresAt: deadline) else {
            store.stop(reason: "合盖运行保护续期失败，已停止移动办公并恢复配置。")
            return
        }
        self.lease = renewed
    }

    private func activeStatusMessage(for lease: MacClosedLidContinuityLease) -> String {
        if !store.status.network.isConnected || !hotspotStore.snapshot.isNetworkAvailable {
            return isMobileOfficeSession
                ? "合盖续跑已就绪；网络正在后台确认或重连，可用 Wi-Fi 优先。"
                : "后台续跑中；目标热点正在确认，断线守护正在重连。"
        }
        if !remoteControlReadiness.isConnected {
            return "后台续跑中；网络可用，等待官方远控恢复。"
        }
        return lease.didEnableSystemPolicy
            ? "后台续跑中；到期自动恢复系统睡眠策略。"
            : "后台续跑中；会话结束后保留原有系统合盖策略。"
    }

    private func failStart(with error: Error) async {
        hotspotStore.setLocalClosedLidSessionAuthorization(false)
        if store.mode.isEnabled {
            store.stop(reason: "“定时合盖续跑”启动失败。")
        }
        var reportedError = error
        var released = true
        if lease != nil {
            released = await powerPolicyStore.endClosedLidContinuityLease()
            if !released {
                reportedError = MacClosedLidSessionError.startAndSystemLeaseReleaseFailed(
                    start: Self.errorMessage(error),
                    release: powerPolicyStore.lastErrorMessage
                        ?? "无法确认系统策略已经恢复。"
                )
            }
        }
        let configurationRestored = restoreModulesAndFinalizeJournal(
            systemRestored: released
        )
        if !configurationRestored, released {
            reportedError = MacClosedLidSessionError.moduleConfigurationRestoreFailed(
                moduleStore.persistenceErrorMessage ?? "无法写回启动前配置。"
            )
        }
        if powerPolicyStore.activeClosedLidLease == nil {
            lease = nil
        }
        store.setTimedClosedLidLeaseActive(false)
        expiresAt = nil
        phase = .failed
        preparationOperationOutstanding = false
        let message = Self.errorMessage(reportedError)
        lastErrorMessage = message
        statusMessage = message
    }

    private func cancelPreparation() async {
        hotspotStore.setLocalClosedLidSessionAuthorization(false)
        if store.mode.phase != .off {
            store.stop(reason: "已取消开启“定时合盖续跑”。")
        }
        let released = await powerPolicyStore.endClosedLidContinuityLease()
        lease = nil
        let configurationRestored = restoreModulesAndFinalizeJournal(
            systemRestored: released
        )
        store.setTimedClosedLidLeaseActive(false)
        expiresAt = nil
        if released, configurationRestored {
            phase = .off
            lastErrorMessage = nil
            statusMessage = "已取消开启，系统睡眠策略已恢复。"
        } else {
            let error: MacClosedLidSessionError = released
                ? .moduleConfigurationRestoreFailed(
                    moduleStore.persistenceErrorMessage ?? "无法写回启动前配置。"
                )
                : .systemLeaseReleaseFailed(
                    powerPolicyStore.lastErrorMessage ?? "无法确认系统策略已经恢复。"
                )
            phase = .failed
            lastErrorMessage = error.localizedDescription
            statusMessage = error.localizedDescription
        }
        preparationOperationOutstanding = false
    }

    private func ensurePreparationContinues() throws {
        guard phase == .preparing, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func handleMobilityStatusChange(_ status: MobilityDeviceStatus) {
        if phase == .active, status.mode.isEnabled {
            if let lease {
                statusMessage = activeStatusMessage(for: lease)
            }
            return
        }
        guard phase == .active, !status.mode.isEnabled, cleanupTask == nil else {
            return
        }
        hotspotStore.setLocalClosedLidSessionAuthorization(false)
        let reason = status.mode.detail ?? store.lastStopReason ?? "本机安全策略已停止会话。"
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            self.phase = .stopping
            self.statusMessage = "会话已停止，正在恢复系统策略…"
            await self.finishLeaseAndPublishOff(stopReason: reason)
            self.cleanupTask = nil
        }
    }

    private func finishLeaseAndPublishOff(stopReason: String? = nil) async {
        hotspotStore.setLocalClosedLidSessionAuthorization(false)
        cancelRemoteControlRecovery()
        let usedExistingPolicy = sessionJournal?.baselineSleepDisabled
            ?? (lease?.didEnableSystemPolicy == false)
        markJournalRestoring()
        let released = await powerPolicyStore.endClosedLidContinuityLease()
        lease = nil
        let configurationRestored = restoreModulesAndFinalizeJournal(
            systemRestored: released
        )
        store.setTimedClosedLidLeaseActive(false)
        expiresAt = nil
        remoteControlReadiness = .notChecked

        if released, configurationRestored {
            phase = .off
            lastErrorMessage = nil
            if let stopReason {
                statusMessage = stopReason
            } else if usedExistingPolicy {
                statusMessage = "已关闭；原有系统合盖策略保持不变。"
            } else {
                statusMessage = "已关闭，系统睡眠策略已恢复。"
            }
        } else {
            let error: MacClosedLidSessionError = released
                ? .moduleConfigurationRestoreFailed(
                    moduleStore.persistenceErrorMessage ?? "无法写回启动前配置。"
                )
                : .systemLeaseReleaseFailed(
                    powerPolicyStore.lastErrorMessage ?? "无法确认系统策略已经恢复。"
                )
            phase = .failed
            lastErrorMessage = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func updateJournal(
        _ update: (inout MacClosedLidSessionJournal) -> Void
    ) throws {
        guard var journal = sessionJournal else {
            throw MacClosedLidSessionError.recoveryJournalFailed(
                "临时覆盖恢复记录缺失。"
            )
        }
        update(&journal)
        do {
            try journalPersistence.saveJournal(journal)
            sessionJournal = journal
            baselineClosedLidEnabled = journal.baselineSleepDisabled
        } catch {
            throw MacClosedLidSessionError.recoveryJournalFailed(
                Self.errorMessage(error)
            )
        }
    }

    private func markJournalRestoring() {
        guard var journal = sessionJournal else { return }
        journal.phase = .restoring
        try? journalPersistence.saveJournal(journal)
        sessionJournal = journal
    }

    private func markJournalRestoreFailed() {
        guard var journal = sessionJournal else { return }
        journal.phase = .restoreFailed
        try? journalPersistence.saveJournal(journal)
        sessionJournal = journal
    }

    /// Restores module selection only after the system lease has been asked to
    /// end. The journal is cleared exclusively when both layers are confirmed.
    private func restoreModulesAndFinalizeJournal(systemRestored: Bool) -> Bool {
        guard let journal = sessionJournal else { return systemRestored }
        markJournalRestoring()
        let modulesRestored = moduleStore.restore(journal.baselineModuleConfiguration)
        guard systemRestored, modulesRestored else {
            markJournalRestoreFailed()
            return false
        }
        return clearJournal()
    }

    @discardableResult
    private func clearJournal() -> Bool {
        do {
            try journalPersistence.clearJournal()
            sessionJournal = nil
            baselineClosedLidEnabled = nil
            return true
        } catch {
            markJournalRestoreFailed()
            return false
        }
    }

    private func handleHotspotSnapshot(
        _ snapshot: AutomaticNetworkRecoverySnapshot
    ) {
        let becameAvailable = snapshot.isNetworkAvailable
            && !lastHotspotNetworkAvailable
        lastHotspotNetworkAvailable = snapshot.isNetworkAvailable
        guard phase == .active else { return }
        if !snapshot.isNetworkAvailable {
            remoteControlReadiness = .unavailable("网络中断，等待热点恢复。")
            cancelRemoteControlRecovery()
            if let lease {
                statusMessage = activeStatusMessage(for: lease)
            }
        } else if becameAvailable {
            scheduleRemoteControlRecovery()
        }
    }

    private func scheduleRemoteControlRecovery() {
        guard phase == .active, remoteControlRecoveryTask == nil else { return }
        let checker = remoteControlChecker
        remoteControlRecoveryGeneration &+= 1
        let generation = remoteControlRecoveryGeneration
        remoteControlRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.remoteControlRecoveryGeneration {
                    self.remoteControlRecoveryTask = nil
                }
            }
            if self.remoteControlReadiness.isConnected {
                guard self.isMobileOfficeSession else { return }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
            while !Task.isCancelled,
                  self.phase == .active,
                  generation == self.remoteControlRecoveryGeneration {
                if self.store.status.network.isConnected {
                    let readiness = await checker.ensureConnected(
                        timeout: ProcessMacCodexRemoteControlChecker.defaultTimeout
                    )
                    guard !Task.isCancelled, self.phase == .active,
                          generation == self.remoteControlRecoveryGeneration else { return }
                    self.remoteControlReadiness = readiness
                } else {
                    self.remoteControlReadiness = .unavailable("等待热点恢复网络。")
                }
                if let lease = self.lease {
                    self.statusMessage = self.activeStatusMessage(for: lease)
                }
                do {
                    // A connected result is a point-in-time observation. Keep
                    // checking during Mobile Office, including silent remote
                    // session drops that don't generate an NWPath change.
                    if self.remoteControlReadiness.isConnected && !self.isMobileOfficeSession {
                        return
                    }
                    try await Task.sleep(for: .seconds(
                        self.remoteControlReadiness.isConnected ? 30 : 15
                    ))
                } catch {
                    return
                }
            }
        }
    }

    private func cancelRemoteControlRecovery() {
        remoteControlRecoveryGeneration &+= 1
        remoteControlRecoveryTask?.cancel()
        remoteControlRecoveryTask = nil
    }

    private func startupSeconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = start.duration(to: ContinuousClock().now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private func traceStartup(_ stage: String, since start: ContinuousClock.Instant) {
        let milliseconds = Int(startupSeconds(since: start) * 1_000)
        Self.logger.notice("stage=\(stage, privacy: .public) elapsed_ms=\(milliseconds) mobile=\(self.isMobileOfficeSession)")
    }

    private static func normalizedDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return sessionDuration }
        if value == 0 { return 0 }
        return min(
            max(value, MobilityPolicy.minimumAllowedDurationSeconds),
            maximumLocalDuration
        )
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        duration.rounded() == duration
            ? String(Int(duration))
            : String(format: "%.2f", duration)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
