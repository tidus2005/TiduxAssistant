import Combine
import Darwin
import Foundation
import IOKit

public enum MacLidCloseLockError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedDelay(Int)
    case lidStateUnavailable
    case lockServiceUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedDelay:
            "合盖锁屏时间不在允许的安全范围内。"
        case .lidStateUnavailable:
            "无法读取这台 Mac 的合盖状态。"
        case .lockServiceUnavailable:
            "macOS 锁屏服务当前不可用。"
        }
    }
}

public struct MacLidCloseLockSnapshot: Equatable, Sendable {
    public var delaySeconds: Int?
    public var isLidClosed: Bool?
    public var pendingLockAt: Date?
    public var agentDesktopEnabled: Bool
    public var agentDesktopActive: Bool
    public var agentDesktopStatus: String
    public var status: String
}

protocol MacLidStateReading: Sendable {
    func isLidClosed() throws -> Bool
}

struct IOKitMacLidStateReader: MacLidStateReading {
    func isLidClosed() throws -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { throw MacLidCloseLockError.lidStateUnavailable }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw MacLidCloseLockError.lidStateUnavailable
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }
}

public protocol MacScreenLockRequesting: Sendable {
    func requestScreenLock() async throws
}

public struct SystemMacScreenLockRequester: MacScreenLockRequesting {
    private typealias LockFunction = @convention(c) () -> Void

    public init() {}

    public func requestScreenLock() async throws {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/login",
            RTLD_LAZY | RTLD_LOCAL
        ) else {
            throw MacLidCloseLockError.lockServiceUnavailable
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            throw MacLidCloseLockError.lockServiceUnavailable
        }
        unsafeBitCast(symbol, to: LockFunction.self)()
    }
}

protocol MacLidCloseLockSettingsPersisting: AnyObject {
    func loadDelaySeconds() -> Int?
    func saveDelaySeconds(_ seconds: Int?)
}

final class UserDefaultsMacLidCloseLockSettingsPersistence:
    MacLidCloseLockSettingsPersisting {
    static let delayKey = "com.tidux.codex-mobility.lid-close-lock-delay-seconds.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadDelaySeconds() -> Int? {
        guard defaults.object(forKey: Self.delayKey) != nil else { return nil }
        return defaults.integer(forKey: Self.delayKey)
    }

    func saveDelaySeconds(_ seconds: Int?) {
        if let seconds {
            defaults.set(seconds, forKey: Self.delayKey)
        } else {
            defaults.removeObject(forKey: Self.delayKey)
        }
    }
}

@MainActor
public final class MacLidCloseLockController: ObservableObject {
    nonisolated public static let allowedDelaySeconds: Set<Int> = [0, 15, 30, 60, 300, 900]
    nonisolated public static let monitorInterval: TimeInterval = 1

    @Published public private(set) var delaySeconds: Int?
    @Published public private(set) var isLidClosed: Bool?
    @Published public private(set) var pendingLockAt: Date?
    @Published public private(set) var lastErrorMessage: String?

    public let agentDesktopController = MacAgentDesktopController()
    private var agentDesktopSubscription: AnyCancellable?
    private var agentDesktopSuppressed = false
    private var mobileOfficePowerSaving = false

    private let lidStateReader: any MacLidStateReading
    private let displaySleepRequester: any MacDisplaySleepRequesting
    private let screenLockRequester: any MacScreenLockRequesting
    private let persistence: any MacLidCloseLockSettingsPersisting
    private let monitorInterval: TimeInterval
    private var monitorTask: Task<Void, Never>?
    private var displaySleepTask: Task<Void, Never>?
    private var pendingLockTask: Task<Void, Never>?
    private var lidClosedAt: Date?
    private var lastEventMessage: String?

    public convenience init() {
        self.init(
            lidStateReader: IOKitMacLidStateReader(),
            displaySleepRequester: ProcessMacDisplaySleepRequester(),
            screenLockRequester: SystemMacScreenLockRequester(),
            persistence: UserDefaultsMacLidCloseLockSettingsPersistence(),
            monitorInterval: Self.monitorInterval
        )
    }

    init(
        lidStateReader: any MacLidStateReading,
        displaySleepRequester: any MacDisplaySleepRequesting,
        screenLockRequester: any MacScreenLockRequesting,
        persistence: any MacLidCloseLockSettingsPersisting,
        monitorInterval: TimeInterval
    ) {
        self.lidStateReader = lidStateReader
        self.displaySleepRequester = displaySleepRequester
        self.screenLockRequester = screenLockRequester
        self.persistence = persistence
        self.monitorInterval = monitorInterval
        let savedDelay = persistence.loadDelaySeconds()
        self.delaySeconds = savedDelay.flatMap {
            Self.allowedDelaySeconds.contains($0) ? $0 : nil
        }
        agentDesktopSubscription = agentDesktopController.$isActive.sink { [weak self] active in
            self?.setAgentDesktopSuppressed(active)
        }
    }

    public func start() {
        guard monitorTask == nil else { return }
        let reader = lidStateReader
        let interval = monitorInterval
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let isClosed = try reader.isLidClosed()
                    self?.observeLidState(isClosed)
                } catch {
                    self?.lastErrorMessage = Self.errorMessage(error)
                }
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        mobileOfficePowerSaving = false
        agentDesktopController.endSession()
        monitorTask?.cancel()
        monitorTask = nil
        displaySleepTask?.cancel()
        displaySleepTask = nil
        cancelPendingLock()
    }

    public func updateDelaySeconds(_ seconds: Int?) throws {
        if let seconds, !Self.allowedDelaySeconds.contains(seconds) {
            throw MacLidCloseLockError.unsupportedDelay(seconds)
        }
        persistence.saveDelaySeconds(seconds)
        delaySeconds = seconds
        lastErrorMessage = nil
        lastEventMessage = seconds == nil ? "助手合盖锁屏已关闭；系统锁屏策略仍生效" : "合盖锁屏时间已更新"
        guard !agentDesktopSuppressed else { return }

        guard isLidClosed == true, let lidClosedAt, let seconds else {
            if seconds == nil { cancelPendingLock() }
            return
        }
        scheduleLock(closedAt: lidClosedAt, delaySeconds: seconds)
    }

    public func snapshot(now: Date = Date()) -> MacLidCloseLockSnapshot {
        MacLidCloseLockSnapshot(
            delaySeconds: delaySeconds,
            isLidClosed: isLidClosed,
            pendingLockAt: pendingLockAt,
            agentDesktopEnabled: agentDesktopController.isEnabled,
            agentDesktopActive: agentDesktopController.isActive,
            agentDesktopStatus: agentDesktopController.status,
            status: statusDescription(now: now)
        )
    }

    func observeLidState(_ closed: Bool, now: Date = Date()) {
        agentDesktopController.observeLidState(closed)
        guard let previous = isLidClosed else {
            isLidClosed = closed
            return
        }
        guard previous != closed else { return }
        isLidClosed = closed
        lastErrorMessage = nil

        if closed {
            lidClosedAt = now
            guard !agentDesktopSuppressed else { return }
            if mobileOfficePowerSaving { requestImmediateDisplaySleep() }
            guard let delaySeconds else {
                lastEventMessage = "检测到合盖；助手未主动锁屏，系统锁屏策略仍生效"
                return
            }
            if !mobileOfficePowerSaving { requestImmediateDisplaySleep() }
            scheduleLock(closedAt: now, delaySeconds: delaySeconds)
        } else {
            lidClosedAt = nil
            let didCancel = pendingLockAt != nil
            cancelPendingLock()
            lastEventMessage = didCancel
                ? "已开盖，取消本次尚未执行的锁屏"
                : "已开盖"
        }
    }

    func setMobileOfficePowerSaving(_ active: Bool) {
        guard mobileOfficePowerSaving != active else { return }
        mobileOfficePowerSaving = active
        if active, isLidClosed == true, !agentDesktopSuppressed {
            requestImmediateDisplaySleep()
        } else if !active, delaySeconds == nil {
            displaySleepTask?.cancel()
            displaySleepTask = nil
        }
    }

    func setAgentDesktopSuppressed(_ active: Bool) {
        guard agentDesktopSuppressed != active else { return }
        agentDesktopSuppressed = active
        if active {
            displaySleepTask?.cancel()
            displaySleepTask = nil
            cancelPendingLock()
        } else if isLidClosed == true, let delaySeconds {
            // Resume from now, rather than firing a stale timer from before the session.
            lidClosedAt = Date()
            scheduleLock(closedAt: lidClosedAt!, delaySeconds: delaySeconds)
        }
    }

    private func requestImmediateDisplaySleep() {
        displaySleepTask?.cancel()
        let requester = displaySleepRequester
        displaySleepTask = Task { @MainActor [weak self] in
            do {
                guard !Task.isCancelled, self?.agentDesktopSuppressed == false,
                      self?.isLidClosed == true else { return }
                try await requester.requestDisplaySleep()
                guard let self, self.isLidClosed == true,
                      !self.agentDesktopSuppressed,
                      self.pendingLockAt != nil else { return }
                self.lastEventMessage = "已合盖并请求立即关闭显示器"
            } catch is CancellationError {
                return
            } catch {
                self?.lastErrorMessage = "立即关闭显示器失败：\(Self.errorMessage(error))"
            }
        }
    }

    private func scheduleLock(closedAt: Date, delaySeconds: Int) {
        cancelPendingLock()
        let target = closedAt.addingTimeInterval(TimeInterval(delaySeconds))
        pendingLockAt = target
        let requester = screenLockRequester
        pendingLockTask = Task { @MainActor [weak self] in
            let remaining = max(target.timeIntervalSinceNow, 0)
            do {
                if remaining > 0 {
                    try await Task.sleep(for: .seconds(remaining))
                }
                guard !Task.isCancelled,
                      let self,
                      !self.agentDesktopSuppressed,
                      self.isLidClosed == true,
                      self.pendingLockAt == target else { return }
                try await requester.requestScreenLock()
                guard self.isLidClosed == true else { return }
                self.pendingLockAt = nil
                self.pendingLockTask = nil
                self.lastEventMessage = "本次合盖已锁定屏幕"
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.pendingLockAt = nil
                self.pendingLockTask = nil
                self.lastErrorMessage = "合盖锁屏失败：\(Self.errorMessage(error))"
            }
        }
    }

    private func cancelPendingLock() {
        pendingLockTask?.cancel()
        pendingLockTask = nil
        pendingLockAt = nil
    }

    private func statusDescription(now: Date) -> String {
        if agentDesktopSuppressed { return "AI 桌面操作模式：助手合盖熄屏与锁屏已暂停" }
        guard let delaySeconds else {
            return lastEventMessage ?? "关闭；合盖仍按 macOS 原有策略处理"
        }
        if let lastErrorMessage { return lastErrorMessage }
        if let pendingLockAt {
            let remaining = max(Int(ceil(pendingLockAt.timeIntervalSince(now))), 0)
            return "显示器已请求立即关闭 · \(Self.delayDescription(remaining))后锁定"
        }
        let rule = "合盖立即熄屏 · \(Self.delayDescription(delaySeconds))后锁定"
        return lastEventMessage.map { "\(rule) · \($0)" } ?? rule
    }

    public static func delayDescription(_ seconds: Int) -> String {
        switch seconds {
        case 0: "立即"
        case 15: "15 秒"
        case 30: "30 秒"
        case 60: "1 分钟"
        case 300: "5 分钟"
        case 900: "15 分钟"
        default: "\(seconds) 秒"
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
