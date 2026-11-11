import Combine
import Foundation

public enum MacCaffeineDurationMode: String, CaseIterable, Sendable {
    case indefinite
    case timed
}

@MainActor
protocol MacCaffeineRunning: AnyObject {
    func start(timeoutSeconds: Int?, onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws
    func stop()
}

/// The OS timeout and parent-PID watch also release assertions if the UI stalls
/// or the assistant is force-quit. This process never manages network settings.
@MainActor
final class SystemMacCaffeineRunner: MacCaffeineRunning {
    private var process: Process?

    func start(timeoutSeconds: Int?, onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws {
        stop()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        var arguments = ["-d", "-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if let timeoutSeconds { arguments += ["-t", String(timeoutSeconds)] }
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in onExit(status) }
        }
        try child.run()
        process = child
    }

    func stop() {
        guard let child = process else { return }
        process = nil
        child.terminationHandler = nil
        if child.isRunning { child.terminate() }
    }
}

/// Independent, opt-in idle display/system protection. Persist only the choice
/// of duration; launching the assistant never silently starts a new session.
@MainActor
public final class MacCaffeineController: ObservableObject {
    static let modeKey = "com.tidux.codex-mobility.caffeine.mode.v1"
    static let minutesKey = "com.tidux.codex-mobility.caffeine.minutes.v1"
    public static let durationChoices = [15, 30, 60, 120, 240, 480, 720, 1440]

    @Published public private(set) var mode: MacCaffeineDurationMode
    @Published public private(set) var durationMinutes: Int
    @Published public private(set) var isActive = false
    @Published public private(set) var expiresAt: Date?
    @Published public private(set) var status = "已关闭"
    @Published public private(set) var errorMessage: String?

    private let runner: any MacCaffeineRunning
    private let defaults: UserDefaults
    private let now: () -> Date
    @Published public private(set) var isManagedByMobileOffice = false
    private var previousManualSession: (active: Bool, deadline: Date?)?

    /// Borrow caffeine without overwriting the user's independent duration preference.
    @discardableResult
    public func beginMobileOffice(expiresAt deadline: Date?) -> Bool {
        guard !isManagedByMobileOffice else { return isActive }
        previousManualSession = (isActive, expiresAt)
        let effectiveDeadline: Date?
        if isActive, expiresAt == nil { effectiveDeadline = nil }
        else if let deadline { effectiveDeadline = max(deadline, expiresAt ?? deadline) }
        else { effectiveDeadline = nil }
        endSession(status: "正在开启")
        isManagedByMobileOffice = true
        start(deadline: effectiveDeadline)
        if isActive { status = "已开启 · 跟随移动办公" }
        return isActive
    }

    public func endMobileOffice() {
        guard isManagedByMobileOffice else { return }
        let previous = previousManualSession
        previousManualSession = nil
        isManagedByMobileOffice = false
        endSession(status: "已关闭")
        if let previous, previous.active,
           previous.deadline.map({ $0 > now() }) ?? true {
            start(deadline: previous.deadline)
        }
    }

    private var sessionID: UUID?
    private var expirationMonitor: Task<Void, Never>?

    public convenience init() {
        self.init(runner: SystemMacCaffeineRunner(), defaults: .standard)
    }

    init(runner: any MacCaffeineRunning, defaults: UserDefaults,
         now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.defaults = defaults
        self.now = now
        mode = defaults.string(forKey: Self.modeKey)
            .flatMap(MacCaffeineDurationMode.init(rawValue:)) ?? .timed
        let savedMinutes = defaults.integer(forKey: Self.minutesKey)
        durationMinutes = Self.durationChoices.contains(savedMinutes) ? savedMinutes : 240
    }

    public func setMode(_ value: MacCaffeineDurationMode) {
        guard !isActive else { return }
        mode = value
        defaults.set(value.rawValue, forKey: Self.modeKey)
    }

    public func setDurationMinutes(_ value: Int) {
        guard !isActive, Self.durationChoices.contains(value) else { return }
        durationMinutes = value
        defaults.set(value, forKey: Self.minutesKey)
    }

    public func setEnabled(_ enabled: Bool) {
        guard !isManagedByMobileOffice else { return }
        if enabled { start() } else { stop() }
    }

    public func stop() {
        isManagedByMobileOffice = false
        previousManualSession = nil
        endSession(status: "已关闭")
    }

    private func start() {
        guard !isActive else { return }
        let deadline = mode == .timed ? now().addingTimeInterval(Double(durationMinutes * 60)) : nil
        start(deadline: deadline)
    }

    private func start(deadline: Date?) {
        errorMessage = nil
        let id = UUID()
        sessionID = id
        let seconds = deadline.map { max(1, Int(ceil($0.timeIntervalSince(now())))) }
        do {
            try runner.start(timeoutSeconds: seconds) { [weak self] exitStatus in
                self?.processExited(session: id, exitStatus: exitStatus)
            }
            expiresAt = deadline
            isActive = true
            status = deadline == nil ? "已开启 · 持续保持唤醒" : "已开启 · 到期自动关闭"
            if deadline != nil {
                expirationMonitor = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        self?.checkExpiration()
                    }
                }
            }
        } catch {
            endSession(status: "开启失败")
            errorMessage = "无法启动咖啡因：" + error.localizedDescription
        }
    }

    func checkExpiration() {
        guard isActive, let expiresAt, now() >= expiresAt else { return }
        endSession(status: "已到期 · 已关闭")
    }

    private func processExited(session: UUID, exitStatus: Int32) {
        guard sessionID == session else { return }
        // caffeinate's own timeout may win the race with the UI's one-second tick.
        let expired = expiresAt.map { now() >= $0.addingTimeInterval(-1) } ?? false
        endSession(status: expired && exitStatus == 0 ? "已到期 · 已关闭" : "已停止")
        if !expired || exitStatus != 0 {
            errorMessage = "咖啡因进程已结束，请重新开启。"
        }
    }

    private func endSession(status: String) {
        sessionID = nil
        expirationMonitor?.cancel()
        expirationMonitor = nil
        runner.stop()
        isActive = false
        expiresAt = nil
        errorMessage = nil
        self.status = status
    }
}
