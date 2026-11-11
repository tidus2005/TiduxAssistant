import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

struct MacAgentDesktopReadiness: Sendable {
    var requiresPassword: Bool
    var isLocked: Bool
    var hasDisplay: Bool
    var hasConflictingLidPolicy = false
    var passwordDelaySeconds: Int? = nil
}

protocol MacAgentDesktopChecking: Sendable {
    func read() async throws -> MacAgentDesktopReadiness
}

struct SystemMacAgentDesktopChecker: MacAgentDesktopChecking {
    func read() async throws -> MacAgentDesktopReadiness {
        let configuration = try await LocalMacScreenLockSettingsBackend().loadConfiguration()
        let power = await LocalMacSystemPowerPolicyBackend().loadFacts()
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionLoginDoneKey as String] as? Bool == true else {
            throw MacAgentDesktopError.unavailable
        }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            throw MacAgentDesktopError.unavailable
        }
        return MacAgentDesktopReadiness(
            requiresPassword: configuration.requiresPassword,
            isLocked: session["CGSSessionScreenIsLocked"] as? Bool ?? false,
            hasDisplay: count > 0,
            hasConflictingLidPolicy: power.lidGuardRunning && power.displaySleepOnLidClose != false,
            passwordDelaySeconds: configuration.passwordDelaySeconds
        )
    }
}

@MainActor
protocol MacAgentDisplayKeeping: AnyObject {
    func begin() throws
    func end()
}

@MainActor
final class SystemMacAgentDisplayKeeper: MacAgentDisplayKeeping {
    private var assertion = IOPMAssertionID(0)

    func begin() throws {
        guard assertion == 0 else { return }
        guard IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Tidux助手 AI 桌面操作" as CFString,
            &assertion
        ) == kIOReturnSuccess else {
            assertion = 0
            throw MacAgentDesktopError.assertionFailed
        }
    }

    func end() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }
}

enum MacAgentDesktopError: LocalizedError {
    case passwordRequired, locked, noDisplay, unavailable, assertionFailed, cancelled, conflictingLidPolicy

    var errorDescription: String? {
        switch self {
        case .passwordRequired:
            "系统立即要求熄屏密码，或无法确认等待时间。请在本机“系统设置 → 锁定屏幕”中选择适合你的等待时间，完成系统认证后重新检查。保留等待时间时，系统到时仍可能锁屏；此模式不会延长该时间。若选项因 iPhone 镜像自动认证而不可修改，先将镜像设为每次询问认证。"
        case .locked: "桌面已锁定，请手动解锁后再启动；AI 桌面操作模式不会自动解锁。"
        case .noDisplay: "没有可用的显示会话，无法确认桌面截图与点击能力；请接入显示器后复查。"
        case .unavailable: "无法确认系统锁屏或显示会话状态，尚不能启用 AI 桌面操作保护。"
        case .assertionFailed: "macOS 拒绝了显示会话保活请求。"
        case .cancelled: "AI 桌面操作模式已取消，请重新启动随行。"
        case .conflictingLidPolicy: "外部合盖服务仍可能强制关闭显示器。请先关闭本页“合盖且无外接屏时熄屏”，再重新检查。"
        }
    }
}

/// Protects an already unlocked desktop. Never changes authentication settings
/// or attempts to unlock a session. The user must configure the OS locally.
@MainActor
public final class MacAgentDesktopController: ObservableObject {
    static let preferenceKey = "com.tidux.codex-mobility.agent-desktop-mode.v1"
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isActive = false
    @Published public private(set) var status = "未检查；此模式仅用于定时随行会话。"
    @Published public private(set) var needsAttention = false
    @Published public private(set) var brightnessStatus = "合盖时将内屏亮度调至最低；开盖恢复。"
    private let checker: any MacAgentDesktopChecking
    private let displayKeeper: any MacAgentDisplayKeeping
    private let defaults: UserDefaults
    private let brightness: (any MacLidBrightnessControlling)?
    private var dimsOnLidClose = false
    private var didAttemptLidDim = false
    private var brightnessIssue: String?
    private var generation = 0
    private var monitor: Task<Void, Never>?

    public convenience init() {
        self.init(checker: SystemMacAgentDesktopChecker(),
                  displayKeeper: SystemMacAgentDisplayKeeper(), defaults: .standard,
                  brightness: SystemMacLidBrightnessController())
    }

    init(checker: any MacAgentDesktopChecking, displayKeeper: any MacAgentDisplayKeeping,
         defaults: UserDefaults, brightness: (any MacLidBrightnessControlling)? = nil) {
        self.checker = checker
        self.displayKeeper = displayKeeper
        self.defaults = defaults
        self.brightness = brightness
        isEnabled = defaults.bool(forKey: Self.preferenceKey)
    }

    public func setEnabled(_ enabled: Bool) {
        endSession()
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        needsAttention = enabled
        status = enabled ? "已选择；请检查系统设置，再重新启动定时随行。" : "关闭；使用原有合盖锁屏规则。"
    }

    public func checkReadiness(preservingImmediateLockPolicy: Bool = false) async {
        let expected = generation
        do {
            let readiness = try await checker.read()
            try validate(readiness, preservingImmediateLockPolicy: dimsOnLidClose || preservingImmediateLockPolicy)
            guard generation == expected else { return }
            publishReadiness(readiness)
        } catch {
            guard generation == expected else { return }
            needsAttention = true
            status = error.localizedDescription
        }
    }

    func beginSession(required: Bool = false, dimOnLidClose: Bool = false) async throws {
        // Mobile Office owns this protection for its session only; do not
        // silently rewrite the user's standalone desktop-mode preference.
        guard isEnabled || required else { return }
        let expected = generation
        do {
            let readiness = try await checker.read()
            try validate(readiness, preservingImmediateLockPolicy: dimOnLidClose)
            guard generation == expected, isEnabled || required, !Task.isCancelled else {
                throw MacAgentDesktopError.cancelled
            }
            if dimOnLidClose { try brightness?.prepare() }
            try displayKeeper.begin()
            dimsOnLidClose = dimOnLidClose
            didAttemptLidDim = false
            isActive = true
            publishReadiness(readiness)
            monitor?.cancel()
            monitor = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.checkReadiness()
                }
            }
        } catch {
            if generation == expected {
                needsAttention = true
                status = error.localizedDescription
            }
            throw error
        }
    }

    func endSession() {
        generation += 1
        monitor?.cancel()
        monitor = nil
        displayKeeper.end()
        do { try brightness?.restore(); brightnessIssue = nil }
        catch {
            brightnessIssue = error.localizedDescription
            brightnessStatus = "恢复内屏亮度失败，请手动调整：" + error.localizedDescription
        }
        dimsOnLidClose = false
        didAttemptLidDim = false
        let wasActive = isActive
        isActive = false
        if wasActive {
            status = "桌面保活已结束，助手合盖规则已恢复；系统密码策略保持你的设置。"
        }
    }

    public func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!)
    }

    func observeLidState(_ closed: Bool) {
        guard isActive, dimsOnLidClose else { return }
        if closed {
            guard !didAttemptLidDim else { return }
            didAttemptLidDim = true
            do {
                try brightness?.dim()
                brightnessIssue = nil
                brightnessStatus = "合盖内屏已调至最低亮度；未请求熄屏或锁屏。"
            } catch {
                needsAttention = true
                brightnessIssue = error.localizedDescription
                brightnessStatus = error.localizedDescription
            }
        } else if didAttemptLidDim {
            do {
                try brightness?.restore()
                try brightness?.prepare()
                brightnessIssue = nil
                brightnessStatus = "已开盖，内屏原亮度已恢复。"
                didAttemptLidDim = false
            } catch {
                needsAttention = true
                brightnessIssue = error.localizedDescription
                brightnessStatus = "恢复内屏亮度失败，请手动调整：" + error.localizedDescription
            }
        }
    }

    private func validate(_ readiness: MacAgentDesktopReadiness,
                          preservingImmediateLockPolicy: Bool = false) throws {
        if readiness.isLocked { throw MacAgentDesktopError.locked }
        if !preservingImmediateLockPolicy, readiness.requiresPassword, (readiness.passwordDelaySeconds ?? 0) <= 0 {
            throw MacAgentDesktopError.passwordRequired
        }
        if readiness.hasConflictingLidPolicy { throw MacAgentDesktopError.conflictingLidPolicy }
        if !readiness.hasDisplay { throw MacAgentDesktopError.noDisplay }
    }

    private func publishReadiness(_ readiness: MacAgentDesktopReadiness) {
        needsAttention = readiness.requiresPassword || brightnessIssue != nil
        let prefix = isActive
            ? "显示会话保活中；助手不主动熄屏或锁屏。"
            : "可以启动定时随行的桌面保活。"
        if readiness.requiresPassword, (readiness.passwordDelaySeconds ?? 0) == 0 {
            status = prefix + "系统保留立即锁屏；本模式仅调暗内屏，不主动熄屏，系统合盖锁定仍需实测。"
        } else if readiness.requiresPassword, let delay = readiness.passwordDelaySeconds {
            let duration = delay % 3600 == 0 ? "\(delay / 3600) 小时" : "\(delay) 秒"
            status = prefix + "保留系统熄屏后 \(duration) 要求密码；到时仍可能锁屏，无法保证长期 Computer Use。"
        } else {
            status = prefix + "合盖截图与点击仍需实测。"
        }
    }
}
