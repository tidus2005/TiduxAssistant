import Foundation
import IOKit.pwr_mgt

public enum IdleSleepAssertionError: Error, LocalizedError, Equatable {
    case creationFailed(IOReturn)

    public var errorDescription: String? {
        switch self {
        case .creationFailed(let code):
            "无法创建防空闲睡眠断言（IOKit 错误 \(code)）。"
        }
    }
}

/// Owns only the public idle-sleep assertion. This deliberately does not
/// prevent lid-close sleep and never changes global `pmset` configuration.
public final class IdleSleepAssertionController: @unchecked Sendable {
    public static let capabilityNotice = "公开 API 只能防止空闲睡眠，不能阻止 Mac 合盖睡眠。"

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?
    private var activityToken: (any NSObjectProtocol)?

    public init() {}

    deinit {
        release()
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }

    /// `PreventUserIdleSystemSleep` protects the machine, while this process
    /// activity keeps App Nap from suspending the local safety timer when every
    /// window is hidden. Neither mechanism overrides lid-close sleep.
    public var isAppNapSuppressed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activityToken != nil
    }

    public func acquire(reason: String = "Codex 移动续跑") throws {
        lock.lock()
        defer { lock.unlock() }
        guard assertionID == nil else { return }

        var createdID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &createdID
        )
        guard result == kIOReturnSuccess else {
            throw IdleSleepAssertionError.creationFailed(result)
        }
        assertionID = createdID
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled],
            reason: reason
        )
    }

    public func release() {
        lock.lock()
        let id = assertionID
        let activity = activityToken
        assertionID = nil
        activityToken = nil
        lock.unlock()

        if let id {
            IOPMAssertionRelease(id)
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
