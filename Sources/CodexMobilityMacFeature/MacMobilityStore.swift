import AppKit
import CodexMobilityCore
import Combine
import Foundation

@MainActor
public final class MacMobilityStore: NSObject, ObservableObject {
    public static let defaultPollingInterval: TimeInterval = 5
    public static let idlePollingInterval: TimeInterval = 30
    public static let activePollingInterval: TimeInterval = 5
    public static let thermalSeriousGraceSeconds: TimeInterval = 120

    @Published public private(set) var status: MobilityDeviceStatus
    @Published public private(set) var safetyEvaluation: MobilitySafetyEvaluation
    @Published public private(set) var lastStopReason: String?
    public private(set) var lastPreflightBlockers: [MobilitySafetyBlocker] = []

    public var mode: MobilityModeStatus { status.mode }
    public var policy: MobilityPolicy { status.mode.policy }
    public var isAssertionActive: Bool { assertionController.isActive }

    private let sampler: any MacSystemSampling
    private let assertionController: IdleSleepAssertionController
    private let policyPersistence: any MobilityPolicyPersisting
    private let pollingIntervalOverride: TimeInterval?
    private var pollingTask: Task<Void, Never>?
    private var thermalSeriousSince: Date?
    private var isMonitoring = false
    private var isTimedClosedLidLeaseActive = false

    public init(
        sampler: any MacSystemSampling = MacSystemSampler(),
        assertionController: IdleSleepAssertionController = IdleSleepAssertionController(),
        policy: MobilityPolicy? = nil,
        policyPersistence: any MobilityPolicyPersisting = UserDefaultsMobilityPolicyPersistence(),
        pollingInterval: TimeInterval? = nil
    ) {
        self.sampler = sampler
        self.assertionController = assertionController
        self.policyPersistence = policyPersistence
        self.pollingIntervalOverride = pollingInterval.map { max($0, 1) }

        let initialPolicy = (policy ?? policyPersistence.loadPolicy() ?? .recommended).normalized()
        let initialMode = MobilityModeStatus(policy: initialPolicy)
        let initialStatus = sampler.sample(mode: initialMode, now: Date())
        self.status = initialStatus
        self.safetyEvaluation = MobilitySafetyEvaluation.evaluate(
            status: initialStatus,
            profile: initialMode.profile,
            policy: initialMode.policy
        )
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        startMonitoring()
    }

    deinit {
        pollingTask?.cancel()
        sampler.stop()
        assertionController.release()
        NotificationCenter.default.removeObserver(self)
    }

    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        sampler.start()
        refreshNow()

        schedulePollingLoop()
    }

    public var effectivePollingInterval: TimeInterval {
        if let pollingIntervalOverride { return pollingIntervalOverride }
        return status.mode.isEnabled
            ? Self.activePollingInterval
            : Self.idlePollingInterval
    }

    private func schedulePollingLoop() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let nanoseconds = UInt64(
                    self.effectivePollingInterval * 1_000_000_000
                )
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self.refreshNow()
            }
        }
    }

    public func stopMonitoring() {
        if status.mode.phase != .off {
            stop(reason: "本机安全监控已停止，移动续跑同步关闭。")
        } else {
            assertionController.release()
        }
        isMonitoring = false
        pollingTask?.cancel()
        pollingTask = nil
        sampler.stop()
    }

    public func refreshNow(now: Date = Date()) {
        status = sampler.sample(mode: status.mode, now: now)
        safetyEvaluation = MobilitySafetyEvaluation.evaluate(
            status: status,
            profile: status.mode.profile,
            policy: status.mode.policy
        )
        enforceLocalPolicy(now: now)
    }

    public func setMode(enabled: Bool, profile: MobilityModeProfile) {
        enabled ? start(profile: profile) : stop(reason: "已手动停止移动续跑。")
    }

    public func start(
        profile: MobilityModeProfile = .idleGuard,
        maximumDurationSeconds: TimeInterval? = nil,
        localSessionDeadline: Date? = nil,
        localSessionIndefinite: Bool = false,
        now: Date = Date()
    ) {
        lastPreflightBlockers = []
        refreshNow(now: now)

        transition(to: .preflighting, profile: profile, detail: "正在执行本机安全检查…", now: now)
        status = sampler.sample(mode: status.mode, now: now)
        safetyEvaluation = MobilitySafetyEvaluation.evaluate(
            status: status,
            profile: profile,
            policy: status.mode.policy
        )
        let blockingPreflightReasons = safetyEvaluation.blockers.filter { blocker in
            if profile == .closedLidLabs, isTimedClosedLidLeaseActive {
                if blocker == .networkUnavailable || blocker == .codexNotRunning { return false }
                if blocker == .insufficientBatteryReserve,
                   let level = status.battery.levelPercent, level > 0 { return false }
            }
            return true
        }
        guard blockingPreflightReasons.isEmpty else {
            assertionController.release()
            lastPreflightBlockers = blockingPreflightReasons
            let reason = blockingPreflightReasons.map(\.chineseDescription).joined(separator: "；")
            transition(
                to: .blocked,
                profile: profile,
                detail: reason,
                startedAt: nil,
                expiresAt: nil,
                now: now
            )
            lastStopReason = reason
            return
        }

        do {
            try assertionController.acquire()
        } catch {
            transition(
                to: .faulted,
                profile: profile,
                detail: error.localizedDescription,
                startedAt: nil,
                expiresAt: nil,
                now: now
            )
            lastStopReason = error.localizedDescription
            return
        }

        let duration = maximumDurationSeconds.map {
            min(
                max($0, MobilityPolicy.minimumAllowedDurationSeconds),
                MobilityPolicy.maximumAllowedDurationSeconds
            )
        } ?? status.mode.policy.maximumDurationSeconds
        let ownsLocalLease = profile == .closedLidLabs && isTimedClosedLidLeaseActive
        let expiresAt: Date? = ownsLocalLease && localSessionIndefinite ? nil
            : (ownsLocalLease ? localSessionDeadline : nil) ?? now.addingTimeInterval(duration)
        transition(
            to: .armed,
            profile: profile,
            detail: profile == .closedLidLabs
                ? "系统级合盖策略已验证；App 本地监控与 Idle Guard 已就绪。"
                : "防空闲睡眠已就绪。",
            startedAt: now,
            expiresAt: expiresAt,
            now: now
        )
        transition(
            to: .active,
            profile: profile,
            detail: profile == .closedLidLabs
                ? "App 监控已开启；系统级合盖策略独立持久，需在“电源”设置中手动关闭。"
                : "移动续跑已开启；请保持屏幕盖打开并确保通风。",
            startedAt: now,
            expiresAt: expiresAt,
            now: now
        )
        lastStopReason = nil
        thermalSeriousSince = nil
        // A timed closed-lid session owns an allow-listed hotspot recovery
        // controller. Network loss is therefore a recoverable runtime state,
        // not a reason to discard the two-hour lease immediately after a
        // successful local safety preflight.
        enforceLocalPolicy(now: now)
        if isMonitoring {
            schedulePollingLoop()
        }
    }

    public func stop(reason: String = "移动续跑已停止。", now: Date = Date()) {
        let effectiveReason: String
        if status.mode.profile == .closedLidLabs, status.helperReady {
            if isTimedClosedLidLeaseActive {
                effectiveReason = reason
                    + " 已释放 App Idle Guard；定时租约正在自动恢复系统合盖策略。"
            } else {
                effectiveReason = reason
                    + " 已释放 App Idle Guard；系统级合盖策略仍保持，需在 Mac“电源”设置中手动关闭。"
            }
        } else {
            effectiveReason = reason
        }
        if status.mode.phase != .off {
            transition(to: .stopping, detail: "正在释放防睡眠断言…", now: now)
        }
        assertionController.release()
        thermalSeriousSince = nil
        transition(
            to: .off,
            detail: effectiveReason,
            startedAt: nil,
            expiresAt: nil,
            now: now
        )
        lastStopReason = effectiveReason
        if isMonitoring {
            schedulePollingLoop()
        }
    }

    public func setTimedClosedLidLeaseActive(_ active: Bool) {
        isTimedClosedLidLeaseActive = active
    }

    /// Returns the blockers captured by the immediately preceding preflight.
    /// The closed-lid controller consumes this synchronously after `start` so a
    /// recovered sampler frame cannot erase the reason that triggered a retry.
    func consumeLastPreflightBlockers() -> [MobilitySafetyBlocker] {
        defer { lastPreflightBlockers = [] }
        return lastPreflightBlockers
    }

    public func updatePolicy(_ policy: MobilityPolicy, now: Date = Date()) {
        var mode = status.mode
        mode.policy = policy.normalized()
        policyPersistence.savePolicy(mode.policy)
        if let startedAt = mode.startedAt, mode.isEnabled, !isTimedClosedLidLeaseActive {
            mode.expiresAt = startedAt.addingTimeInterval(mode.policy.maximumDurationSeconds)
        }
        mode.revision = nextRevision(after: mode.revision)
        mode.lastTransitionAt = now
        status = sampler.sample(mode: mode, now: now)
        safetyEvaluation = MobilitySafetyEvaluation.evaluate(
            status: status,
            profile: mode.profile,
            policy: mode.policy
        )
        enforceLocalPolicy(now: now)
    }

    public func shutdown(now: Date = Date()) {
        stop(reason: "应用退出，已释放防睡眠断言。", now: now)
        stopMonitoring()
    }

    @objc private func applicationWillTerminate() {
        shutdown()
    }

    private func enforceLocalPolicy(now: Date) {
        guard status.mode.phase == .armed
                || status.mode.phase == .active
                || status.mode.phase == .degraded else {
            return
        }

        if status.mode.profile == .closedLidLabs, !status.helperReady {
            blockClosedLidMode(now: now)
            return
        }
        guard assertionController.isActive else {
            assertionController.release()
            transition(
                to: .faulted,
                detail: "防空闲睡眠断言意外失效，模式已停止。",
                startedAt: nil,
                expiresAt: nil,
                now: now
            )
            lastStopReason = status.mode.detail
            return
        }

        if status.thermalState == .critical {
            stop(reason: "系统热状态达到临界级，已自动停止。", now: now)
            return
        }

        if let level = status.battery.levelPercent {
            if !status.battery.isOnExternalPower,
               level <= (isTimedClosedLidLeaseActive ? 0 : status.mode.policy.lowBatteryThresholdPercent) {
                stop(reason: "电量已达到停止阈值（\(level)%），已自动停止。", now: now)
                return
            }
        } else {
            stop(reason: "无法读取电池状态，已安全停止。", now: now)
            return
        }

        if let expiresAt = status.mode.expiresAt, now >= expiresAt {
            stop(reason: "已达到最长运行时长，已自动停止。", now: now)
            return
        }

        if !isTimedClosedLidLeaseActive,
           status.mode.policy.requiresCodexRunning && !status.codex.isRunning {
            stop(reason: "Codex 已退出，已自动停止移动续跑。", now: now)
            return
        }

        var degradationReasons: [String] = []
        if status.thermalState == .serious {
            thermalSeriousSince = thermalSeriousSince ?? now
            let elapsed = now.timeIntervalSince(thermalSeriousSince ?? now)
            if elapsed >= Self.thermalSeriousGraceSeconds {
                stop(reason: "严重热状态持续 2 分钟，已自动停止。", now: now)
                return
            }
            degradationReasons.append("热状态严重，正在等待降温")
        } else {
            thermalSeriousSince = nil
        }

        if !status.network.isConnected {
            if status.mode.profile == .closedLidLabs, isTimedClosedLidLeaseActive {
                degradationReasons.append("网络已断开，热点守护正在重连")
            } else {
                let disconnectedSince = status.network.disconnectedSince ?? now
                let elapsed = max(now.timeIntervalSince(disconnectedSince), 0)
                let grace = status.mode.policy.networkDisconnectGraceSeconds
                if elapsed >= grace {
                    stop(reason: "网络断开超过宽限时间，已自动停止。", now: now)
                    return
                }
                let remainingMinutes = max(Int(ceil((grace - elapsed) / 60)), 1)
                degradationReasons.append("网络已断开，约 \(remainingMinutes) 分钟后停止")
            }
        }

        if degradationReasons.isEmpty {
            if status.mode.phase == .degraded {
                transition(to: .active, detail: "安全条件已恢复，移动续跑继续运行。", now: now)
            }
        } else {
            transition(to: .degraded, detail: degradationReasons.joined(separator: "；"), now: now)
        }
    }

    private func blockClosedLidMode(now: Date) {
        assertionController.release()
        transition(
            to: .blocked,
            profile: .closedLidLabs,
            detail: IdleSleepAssertionController.capabilityNotice,
            startedAt: nil,
            expiresAt: nil,
            now: now
        )
        lastStopReason = IdleSleepAssertionController.capabilityNotice
    }

    private func transition(
        to phase: MobilityModePhase,
        profile: MobilityModeProfile? = nil,
        detail: String?,
        startedAt: Date? = nil,
        expiresAt: Date? = nil,
        now: Date
    ) {
        var mode = status.mode
        mode.phase = phase
        if let profile {
            mode.profile = profile
        }
        mode.revision = nextRevision(after: mode.revision)
        mode.lastTransitionAt = now
        mode.detail = detail

        if phase == .off || phase == .blocked || phase == .faulted {
            mode.startedAt = startedAt
            mode.expiresAt = expiresAt
        } else {
            mode.startedAt = startedAt ?? mode.startedAt
            mode.expiresAt = expiresAt ?? mode.expiresAt
        }

        status = sampler.sample(mode: mode, now: now)
        safetyEvaluation = MobilitySafetyEvaluation.evaluate(
            status: status,
            profile: mode.profile,
            policy: mode.policy
        )
        if phase == .off || phase == .faulted || phase == .active {
            lastPreflightBlockers = []
        }
    }

    private func nextRevision(after revision: UInt64) -> UInt64 {
        revision == .max ? 0 : revision + 1
    }
}

private extension MobilitySafetyBlocker {
    var chineseDescription: String {
        switch self {
        case .batteryUnavailable: "无法读取电池状态"
        case .insufficientBatteryReserve: "电量未高于停止阈值至少 10%"
        case .networkUnavailable: "网络不可用"
        case .codexNotRunning: "Codex 未运行"
        case .thermalSerious: "系统热状态严重"
        case .thermalCritical: "系统热状态临界"
        case .thermalUnknown: "无法读取热状态"
        case .helperUnavailable: "系统级合盖续跑策略尚未开启"
        }
    }
}
