import Darwin
import Foundation
import Network
import OSLog

public struct AutomaticNetworkRecoveryPolicy: Equatable, Sendable {
    public var preferredSSIDs: [String]
    public var initialLastGoodSSID: String?
    public var consecutiveFailureThreshold: Int
    public var failureConfirmationInterval: TimeInterval
    public var baseRetryDelay: TimeInterval
    public var maximumRetryDelay: TimeInterval
    public var minimumReconnectInterval: TimeInterval
    public var requiresPreferredSSID: Bool
    /// Only an explicit, temporary hotspot session may replace a healthy LAN.
    public var prefersTargetOverHealthyNetwork: Bool

    public init(
        preferredSSIDs: [String] = [],
        initialLastGoodSSID: String? = nil,
        consecutiveFailureThreshold: Int = 2,
        failureConfirmationInterval: TimeInterval = 5,
        baseRetryDelay: TimeInterval = 15,
        maximumRetryDelay: TimeInterval = 5 * 60,
        minimumReconnectInterval: TimeInterval = 15,
        requiresPreferredSSID: Bool = false,
        prefersTargetOverHealthyNetwork: Bool = false
    ) {
        self.preferredSSIDs = Self.normalizedSSIDs(preferredSSIDs)
        self.initialLastGoodSSID = Self.normalizedSSID(initialLastGoodSSID)
        self.consecutiveFailureThreshold = max(consecutiveFailureThreshold, 1)
        self.failureConfirmationInterval = Self.normalizedInterval(
            failureConfirmationInterval,
            fallback: 5
        )
        self.baseRetryDelay = Self.normalizedInterval(baseRetryDelay, fallback: 15)
        self.maximumRetryDelay = max(
            Self.normalizedInterval(maximumRetryDelay, fallback: 5 * 60),
            self.baseRetryDelay
        )
        self.minimumReconnectInterval = Self.normalizedInterval(
            minimumReconnectInterval,
            fallback: 15
        )
        self.requiresPreferredSSID = requiresPreferredSSID
        self.prefersTargetOverHealthyNetwork = prefersTargetOverHealthyNetwork
    }

    private static func normalizedSSIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            guard let normalized = normalizedSSID(value), seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func normalizedSSID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("\n"), !normalized.contains("\r") else {
            return nil
        }
        return normalized
    }

    private static func normalizedInterval(
        _ value: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        value.isFinite && value >= 0 ? value : fallback
    }
}

public enum AutomaticNetworkRecoveryPhase: String, Equatable, Sendable {
    case stopped
    case monitoring
    case confirmingFailure
    case reconnecting
    case waitingForConnectivity
    case backingOff
}

public struct AutomaticNetworkRecoverySnapshot: Equatable, Sendable {
    public var phase: AutomaticNetworkRecoveryPhase
    public var isNetworkAvailable: Bool
    public var consecutiveFailures: Int
    public var reconnectAttempt: Int
    public var lastGoodSSID: String?
    public var lastAttemptedSSID: String?
    public var nextActionAt: Date?
    public var lastError: String?

    public init(
        phase: AutomaticNetworkRecoveryPhase = .stopped,
        isNetworkAvailable: Bool = false,
        consecutiveFailures: Int = 0,
        reconnectAttempt: Int = 0,
        lastGoodSSID: String? = nil,
        lastAttemptedSSID: String? = nil,
        nextActionAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.phase = phase
        self.isNetworkAvailable = isNetworkAvailable
        self.consecutiveFailures = consecutiveFailures
        self.reconnectAttempt = reconnectAttempt
        self.lastGoodSSID = lastGoodSSID
        self.lastAttemptedSSID = lastAttemptedSSID
        self.nextActionAt = nextActionAt
        self.lastError = lastError
    }
}

public struct AutomaticNetworkPathState: Equatable, Sendable {
    public let isSatisfied: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool

    public init(
        isSatisfied: Bool,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.isSatisfied = isSatisfied
        // Cost/constrained flags are useful only as attributes of a usable
        // path. Normalizing them here prevents an unavailable event from being
        // mistaken for weak hotspot evidence.
        self.isExpensive = isSatisfied && isExpensive
        self.isConstrained = isSatisfied && isConstrained
    }

    public static let satisfied = AutomaticNetworkPathState(isSatisfied: true)
    public static let unavailable = AutomaticNetworkPathState(isSatisfied: false)

    /// Personal Hotspot paths are normally marked expensive and may also be
    /// constrained. This is deliberately only a hint for privacy-hidden SSIDs;
    /// a visible SSID must still match the configured allowlist exactly.
    public var isPotentialMobileHotspot: Bool {
        isSatisfied && (isExpensive || isConstrained)
    }
}

public enum AutomaticNetworkRecoveryTimer: Equatable, Sendable {
    case confirmFailure
    case retry
}

public enum AutomaticNetworkRecoveryAction: Equatable, Sendable {
    case cancelScheduledWork
    case cancelReconnect
    case schedule(timer: AutomaticNetworkRecoveryTimer, after: TimeInterval)
    case reconnect
}

/// A deterministic state machine for the experimental automatic-network module.
/// It is independent from `NWPathMonitor`, wall-clock sleeping, and
/// `networksetup`, so policy behavior can be tested without changing Wi-Fi.
public struct AutomaticNetworkRecoveryStateMachine: Sendable {
    public let policy: AutomaticNetworkRecoveryPolicy
    public private(set) var snapshot: AutomaticNetworkRecoverySnapshot

    private var isRunning = false
    private var isDisconnected = false
    private var lastReconnectAttemptAt: Date?

    public init(policy: AutomaticNetworkRecoveryPolicy) {
        self.policy = policy
        snapshot = AutomaticNetworkRecoverySnapshot(
            lastGoodSSID: policy.initialLastGoodSSID
        )
    }

    @discardableResult
    public mutating func start() -> [AutomaticNetworkRecoveryAction] {
        guard !isRunning else { return [] }
        isRunning = true
        isDisconnected = false
        snapshot.phase = .monitoring
        snapshot.isNetworkAvailable = false
        snapshot.consecutiveFailures = 0
        snapshot.reconnectAttempt = 0
        snapshot.nextActionAt = nil
        snapshot.lastError = nil
        return [.cancelScheduledWork, .cancelReconnect]
    }

    @discardableResult
    public mutating func stop() -> [AutomaticNetworkRecoveryAction] {
        isRunning = false
        isDisconnected = false
        snapshot.phase = .stopped
        snapshot.isNetworkAvailable = false
        snapshot.consecutiveFailures = 0
        snapshot.reconnectAttempt = 0
        snapshot.nextActionAt = nil
        return [.cancelScheduledWork, .cancelReconnect]
    }

    @discardableResult
    public mutating func observePath(
        _ state: AutomaticNetworkPathState,
        now: Date
    ) -> [AutomaticNetworkRecoveryAction] {
        guard isRunning else { return [] }

        if state.isSatisfied {
            isDisconnected = false
            snapshot.phase = .monitoring
            snapshot.isNetworkAvailable = true
            snapshot.consecutiveFailures = 0
            snapshot.reconnectAttempt = 0
            snapshot.nextActionAt = nil
            snapshot.lastError = nil
            return [.cancelScheduledWork, .cancelReconnect]
        }

        snapshot.isNetworkAvailable = false
        guard !isDisconnected else { return [] }

        isDisconnected = true
        snapshot.consecutiveFailures = 1
        snapshot.reconnectAttempt = 0
        snapshot.lastError = nil

        if policy.consecutiveFailureThreshold == 1 {
            return beginReconnectOrCooldown(now: now)
        }

        snapshot.phase = .confirmingFailure
        snapshot.nextActionAt = now.addingTimeInterval(policy.failureConfirmationInterval)
        return [
            .cancelScheduledWork,
            .schedule(
                timer: .confirmFailure,
                after: policy.failureConfirmationInterval
            )
        ]
    }

    @discardableResult
    public mutating func timerFired(
        _ timer: AutomaticNetworkRecoveryTimer,
        now: Date
    ) -> [AutomaticNetworkRecoveryAction] {
        guard isRunning, isDisconnected else { return [] }

        switch timer {
        case .confirmFailure:
            guard snapshot.phase == .confirmingFailure else { return [] }
            snapshot.consecutiveFailures += 1
            if snapshot.consecutiveFailures >= policy.consecutiveFailureThreshold {
                return beginReconnectOrCooldown(now: now)
            }

            snapshot.nextActionAt = now.addingTimeInterval(policy.failureConfirmationInterval)
            return [
                .schedule(
                    timer: .confirmFailure,
                    after: policy.failureConfirmationInterval
                )
            ]

        case .retry:
            guard snapshot.phase == .backingOff
                    || snapshot.phase == .waitingForConnectivity else {
                return []
            }
            return beginReconnectOrCooldown(now: now)
        }
    }

    @discardableResult
    public mutating func reconnectCompleted(
        attemptedSSID: String?,
        errorDescription: String?,
        now: Date
    ) -> [AutomaticNetworkRecoveryAction] {
        guard isRunning, isDisconnected, snapshot.phase == .reconnecting else {
            return []
        }

        snapshot.lastAttemptedSSID = attemptedSSID
        snapshot.lastError = errorDescription
        let delay = retryDelay(afterAttempt: snapshot.reconnectAttempt, now: now)
        snapshot.nextActionAt = now.addingTimeInterval(delay)
        snapshot.phase = errorDescription == nil ? .waitingForConnectivity : .backingOff
        return [.schedule(timer: .retry, after: delay)]
    }

    public mutating func recordLastGoodSSID(_ ssid: String) {
        guard isRunning, !isDisconnected,
              let normalized = AutomaticNetworkRecoveryPolicy(
                initialLastGoodSSID: ssid
              ).initialLastGoodSSID else {
            return
        }
        snapshot.lastGoodSSID = normalized
    }

    private mutating func beginReconnectOrCooldown(
        now: Date
    ) -> [AutomaticNetworkRecoveryAction] {
        if let lastReconnectAttemptAt {
            let elapsed = now.timeIntervalSince(lastReconnectAttemptAt)
            let remainingCooldown = policy.minimumReconnectInterval - elapsed
            if remainingCooldown > 0 {
                snapshot.phase = .backingOff
                snapshot.nextActionAt = now.addingTimeInterval(remainingCooldown)
                return [.schedule(timer: .retry, after: remainingCooldown)]
            }
        }

        snapshot.phase = .reconnecting
        snapshot.reconnectAttempt += 1
        snapshot.nextActionAt = nil
        lastReconnectAttemptAt = now
        return [.cancelScheduledWork, .reconnect]
    }

    private func retryDelay(afterAttempt attempt: Int, now: Date) -> TimeInterval {
        let exponent = max(min(attempt - 1, 20), 0)
        let exponentialDelay = min(
            policy.baseRetryDelay * pow(2, Double(exponent)),
            policy.maximumRetryDelay
        )
        let remainingCooldown = lastReconnectAttemptAt.map {
            max(policy.minimumReconnectInterval - now.timeIntervalSince($0), 0)
        } ?? 0
        return max(exponentialDelay, remainingCooldown)
    }
}

public struct NetworkSetupCommandResult: Equatable, Sendable {
    public var terminationStatus: Int32
    public var standardOutput: String
    public var standardError: String

    public init(
        terminationStatus: Int32,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol NetworkSetupCommandRunning: Sendable {
    func run(arguments: [String]) async throws -> NetworkSetupCommandResult
}

public enum NetworkSetupCommandRunnerError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case unsupportedOperation
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperation:
            "网络守护只允许读取 Wi-Fi 状态、打开 Wi-Fi 和加入目标网络，不允许改写 VPN、代理或 DNS 策略。"
        case .launchFailed(let description):
            "无法启动 macOS 网络配置工具：\(description)"
        case .timedOut:
            "macOS 网络配置工具等待超时，已终止本次连接。"
        }
    }
}

private final class NetworkSetupProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func finish() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

/// Runs only `/usr/sbin/networksetup`, passing every value as a separate argv
/// element. It never evaluates a shell command or reads a shell configuration.
public struct ProcessNetworkSetupCommandRunner: NetworkSetupCommandRunning {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = max(timeout.isFinite ? timeout : 15, 0.1)
    }

    static func isAllowed(_ arguments: [String]) -> Bool {
        switch arguments.first {
        case "-listallhardwareports": return arguments.count == 1
        case "-listpreferredwirelessnetworks", "-getairportnetwork": return arguments.count == 2
        case "-setairportpower": return arguments.count == 3 && arguments[2] == "on"
        case "-setairportnetwork": return arguments.count == 3 && !arguments[2].isEmpty
        default: return false
        }
    }

    public func run(arguments: [String]) async throws -> NetworkSetupCommandResult {
        guard Self.isAllowed(arguments) else { throw NetworkSetupCommandRunnerError.unsupportedOperation }
        let processState = NetworkSetupProcessState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    process.arguments = arguments

                    let standardOutput = Pipe()
                    let standardError = Pipe()
                    process.standardOutput = standardOutput
                    process.standardError = standardError

                    guard processState.install(process) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    defer { processState.finish() }

                    do {
                        try process.run()
                        let deadline = Date().addingTimeInterval(timeout)
                        var terminationStartedAt: Date?
                        var timedOut = false

                        while process.isRunning {
                            let cancelled = processState.isCancelled
                            if cancelled || Date() >= deadline {
                                timedOut = timedOut || !cancelled
                                if terminationStartedAt == nil {
                                    terminationStartedAt = Date()
                                    process.terminate()
                                } else if let terminationStartedAt,
                                          Date().timeIntervalSince(terminationStartedAt) >= 0.5 {
                                    kill(process.processIdentifier, SIGKILL)
                                }
                            }
                            usleep(50_000)
                        }
                        process.waitUntilExit()

                        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
                        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                        if processState.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if timedOut {
                            continuation.resume(
                                throwing: NetworkSetupCommandRunnerError.timedOut
                            )
                        } else {
                            continuation.resume(returning: NetworkSetupCommandResult(
                                terminationStatus: process.terminationStatus,
                                standardOutput: String(decoding: outputData, as: UTF8.self),
                                standardError: String(decoding: errorData, as: UTF8.self)
                            ))
                        }
                    } catch {
                        if processState.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(
                                throwing: NetworkSetupCommandRunnerError.launchFailed(
                                    error.localizedDescription
                                )
                            )
                        }
                    }
                }
            }
        } onCancel: {
            processState.cancel()
        }
    }
}

public protocol SavedWiFiNetworkRecovering: Sendable {
    /// Returns the currently visible SSID, if macOS exposes it. A `nil`
    /// result does not by itself mean that Wi-Fi is disconnected: recent
    /// macOS releases can hide the SSID while the Wi-Fi path remains usable.
    func visibleCurrentNetwork() async throws -> String?

    /// Reconnects a candidate only when the SSID is present in macOS's saved
    /// preferred-network list. No password is accepted by this API.
    func reconnectSavedNetwork(
        preferredSSIDs: [String],
        lastGoodSSID: String?
    ) async throws -> String
}

public enum SavedWiFiNetworkRecoveryError: Error, LocalizedError, Equatable {
    case noWiFiInterface
    case unableToReadSavedNetworks
    case noAllowedSavedNetwork
    case unableToEnableWiFi
    case allCandidatesFailed

    public var errorDescription: String? {
        switch self {
        case .noWiFiInterface:
            "没有检测到可用的 Wi-Fi 网卡。"
        case .unableToReadSavedNetworks:
            "无法读取 macOS 已保存的 Wi-Fi 网络。"
        case .noAllowedSavedNetwork:
            "首选网络和 last-good 网络都没有已保存凭据。"
        case .unableToEnableWiFi:
            "无法打开 Mac 的 Wi-Fi。"
        case .allCandidatesFailed:
            "已保存的候选网络均连接失败。"
        }
    }
}

public struct NetworkSetupSavedWiFiRecoverer: SavedWiFiNetworkRecovering {
    private let commandRunner: any NetworkSetupCommandRunning
    private let backgroundHotspotActivator: (any MacBackgroundHotspotActivating)?

    public init(
        commandRunner: any NetworkSetupCommandRunning = ProcessNetworkSetupCommandRunner(),
        backgroundHotspotActivator: (any MacBackgroundHotspotActivating)? = nil
    ) {
        self.commandRunner = commandRunner
        self.backgroundHotspotActivator = backgroundHotspotActivator
    }

    func withBackgroundHotspotActivator(_ activator: any MacBackgroundHotspotActivating) -> Self {
        Self(commandRunner: commandRunner, backgroundHotspotActivator: activator)
    }

    public func visibleCurrentNetwork() async throws -> String? {
        try Task.checkCancellation()
        guard let interface = try await discoverWiFiInterface() else {
            throw SavedWiFiNetworkRecoveryError.noWiFiInterface
        }
        try Task.checkCancellation()
        return try await currentNetwork(interface: interface)
    }

    public func reconnectSavedNetwork(
        preferredSSIDs: [String],
        lastGoodSSID: String?
    ) async throws -> String {
        try await reconnectSavedNetwork(
            preferredSSIDs: preferredSSIDs, lastGoodSSID: lastGoodSSID,
            instantHotspotConnector: nil
        )
    }

    func reconnectSavedNetwork(
        preferredSSIDs: [String],
        lastGoodSSID: String?,
        instantHotspotConnector: (any MacInstantHotspotConnecting)?
    ) async throws -> String {
        try Task.checkCancellation()
        guard let interface = try await discoverWiFiInterface() else {
            throw SavedWiFiNetworkRecoveryError.noWiFiInterface
        }

        try Task.checkCancellation()
        let savedNetworks = try await savedPreferredNetworks(interface: interface)
        let savedNetworkSet = Set(savedNetworks)
        var seen: Set<String> = []
        let requested = preferredSSIDs + [lastGoodSSID].compactMap { $0 }
        let candidates = requested.compactMap { rawSSID -> String? in
            let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssid.isEmpty,
                  !ssid.contains("\n"),
                  !ssid.contains("\r"),
                  savedNetworkSet.contains(ssid),
                  seen.insert(ssid).inserted else {
                return nil
            }
            return ssid
        }

        guard !candidates.isEmpty else {
            throw SavedWiFiNetworkRecoveryError.noAllowedSavedNetwork
        }

        try Task.checkCancellation()
        let powerResult = try await commandRunner.run(arguments: [
            "-setairportpower",
            interface,
            "on"
        ])
        guard powerResult.terminationStatus == 0 else {
            throw SavedWiFiNetworkRecoveryError.unableToEnableWiFi
        }

        for ssid in candidates {
            try Task.checkCancellation()
            let result = try await commandRunner.run(arguments: [
                "-setairportnetwork",
                interface,
                ssid
            ])
            if Self.didSetAirportNetworkSucceed(result) {
                return ssid
            }
        }

        // A saved SSID alone cannot wake an idle Instant Hotspot. Only the
        // session-owned recoverer receives this headless activation capability.
        if let backgroundHotspotActivator,
           let target = candidates.first(where: { preferredSSIDs.contains($0) }) {
            try Task.checkCancellation()
            do {
                try await backgroundHotspotActivator.activate(ssid: target)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let failure = error as? MacBackgroundHotspotError,
                   failure == .locationPermissionRequired || failure == .ambiguousTarget || failure == .unsupported {
                    throw error
                }
                // The foreground fallback belongs only to an explicit local
                // start. Background recovery never receives this capability.
                guard let instantHotspotConnector else { throw error }
                try Task.checkCancellation()
                try await instantHotspotConnector.connect(ssid: target)
            }
            // The activator associates in-process using the system invitation.
            // Reissuing networksetup would undo that connection (and its CLI
            // process does not inherit this app's Location authorization).
            try Task.checkCancellation()
            return target
        }

        if let instantHotspotConnector, let target = candidates.first {
            try Task.checkCancellation()
            try await instantHotspotConnector.connect(ssid: target)
            return target
        }
        throw SavedWiFiNetworkRecoveryError.allCandidatesFailed
    }

    func discoverWiFiInterface() async throws -> String? {
        let result = try await commandRunner.run(arguments: ["-listallhardwareports"])
        guard result.terminationStatus == 0 else { return nil }
        return Self.parseWiFiInterface(result.standardOutput)
    }

    func savedPreferredNetworks(interface: String) async throws -> [String] {
        let result = try await commandRunner.run(arguments: [
            "-listpreferredwirelessnetworks",
            interface
        ])
        guard result.terminationStatus == 0 else {
            throw SavedWiFiNetworkRecoveryError.unableToReadSavedNetworks
        }
        return Self.parsePreferredNetworks(result.standardOutput)
    }

    func currentNetwork(interface: String) async throws -> String? {
        // The CLI does not inherit the app's Location permission. Read the
        // associated SSID in-process when authorized; never infer the target
        // merely from a generic healthy Wi-Fi path.
        if commandRunner is ProcessNetworkSetupCommandRunner,
           let ssid = await MacHotspotWiFiAuthorization.currentSSID(interface: interface) {
            return ssid
        }
        let result = try await commandRunner.run(arguments: [
            "-getairportnetwork",
            interface
        ])
        guard result.terminationStatus == 0 else { return nil }
        return Self.parseCurrentNetwork(result.standardOutput)
    }

    static func parseWiFiInterface(_ output: String) -> String? {
        var currentHardwarePort: String?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Hardware Port:") {
                currentHardwarePort = String(line.dropFirst("Hardware Port:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if line.hasPrefix("Device:"), let currentHardwarePort {
                let normalizedPort = currentHardwarePort
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: " ", with: "")
                guard normalizedPort.contains("wifi") || normalizedPort.contains("airport") else {
                    continue
                }
                let device = String(line.dropFirst("Device:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return device.isEmpty ? nil : device
            }
        }
        return nil
    }

    static func parsePreferredNetworks(_ output: String) -> [String] {
        var seen: Set<String> = []
        return output.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.lowercased().hasPrefix("preferred networks on"),
                  seen.insert(line).inserted else {
                return nil
            }
            return line
        }
    }

    static func parseCurrentNetwork(_ output: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              !line.localizedCaseInsensitiveContains("not associated"),
              let separator = line.firstIndex(of: ":") else {
            return nil
        }
        let ssid = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ssid.isEmpty ? nil : ssid
    }

    /// `networksetup -setairportnetwork` can exit with status 0 while printing
    /// an operational failure such as "Could not find network ...". Treat
    /// those diagnostics as failures so a command return alone can never be
    /// promoted into false hotspot identity evidence.
    static func didSetAirportNetworkSucceed(
        _ result: NetworkSetupCommandResult
    ) -> Bool {
        guard result.terminationStatus == 0 else { return false }
        let diagnostic = (result.standardOutput + "\n" + result.standardError)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !diagnostic.isEmpty else { return true }

        let failureMarkers = [
            "could not find network",
            "failed to join network",
            "could not be joined",
            "unable to join",
            "error:"
        ]
        return !failureMarkers.contains { diagnostic.contains($0) }
    }
}

public protocol AutomaticNetworkPathMonitoring: AnyObject, Sendable {
    func start(
        queue: DispatchQueue,
        updateHandler: @escaping @Sendable (AutomaticNetworkPathState) -> Void
    )
    func cancel()
}

private final class AutomaticNetworkPathEventSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

public final class NWPathAutomaticNetworkPathMonitor: AutomaticNetworkPathMonitoring,
    @unchecked Sendable {
    private let monitor: NWPathMonitor

    public init(monitor: NWPathMonitor? = nil) {
        self.monitor = monitor ?? NWPathMonitor(requiredInterfaceType: .wifi)
    }

    public func start(
        queue: DispatchQueue,
        updateHandler: @escaping @Sendable (AutomaticNetworkPathState) -> Void
    ) {
        monitor.pathUpdateHandler = { path in
            updateHandler(AutomaticNetworkPathState(
                isSatisfied: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            ))
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }
}

/// A link may be usable by Wi-Fi while its VPN is still reconnecting. Hidden
/// SSIDs on expensive/constrained Wi-Fi are only a reason to defer disruption,
/// never proof of hotspot identity or internet connectivity.
struct AssociatedWiFiRepairGuard {
    private var waitingSince: Date?

    mutating func reset() { waitingSince = nil }

    mutating func shouldWait(isAssociated: Bool, ssid: String?, preferredSSIDs: [String],
                             hasMobileHint: Bool, now: Date) -> Bool {
        guard isAssociated, !preferredSSIDs.isEmpty else { reset(); return false }
        let shouldPreserve = ssid.map { preferredSSIDs.contains($0) } ?? hasMobileHint
        guard shouldPreserve else { reset(); return false }
        if let waitingSince, now.timeIntervalSince(waitingSince) >= 120 {
            self.waitingSince = now
            return false
        }
        if waitingSince == nil { waitingSince = now }
        return true
    }
}

/// Ordinary recovery preserves healthy networks. Explicit hotspot sessions can
/// additionally require their target before cancelling reconnect backoff.
public actor AutomaticNetworkRecoveryController {
    public typealias PathMonitorFactory = @Sendable () -> any AutomaticNetworkPathMonitoring
    public typealias SnapshotHandler = @Sendable (AutomaticNetworkRecoverySnapshot) -> Void

    private let recoverer: any SavedWiFiNetworkRecovering
    private let pathMonitorFactory: PathMonitorFactory
    private let pathQueue = DispatchQueue(
        label: "com.tidux.codex-watch-pet.automatic-network-recovery",
        qos: .utility
    )
    private let snapshotHandler: SnapshotHandler?
    private var stateMachine: AutomaticNetworkRecoveryStateMachine
    private var pathMonitor: (any AutomaticNetworkPathMonitoring)?
    private var scheduledTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var scheduleGeneration: UInt64 = 0
    private var pathMonitorGeneration: UInt64 = 0
    private var latestPathSourceEvent: UInt64 = 0
    private var lastSSIDLookupSourceEvent: UInt64?
    private let internetProbe: (any MacInternetReachabilityProbing)?
    private let healthCheckInterval: TimeInterval
    private var healthTask: Task<Void, Never>?
    private var lastPathState = AutomaticNetworkPathState.unavailable
    private var healthCheckGeneration: UInt64 = 0
    private var healthFailures = 0
    private var associatedWiFiRepairGuard = AssociatedWiFiRepairGuard()
    private var reconnectGeneration: UInt64 = 0

    private static let logger = Logger(subsystem: "com.tidux.CodexWatchPet.mac", category: "hotspot-recovery")
    private var lastLoggedPhase: AutomaticNetworkRecoveryPhase?
    private var lastLoggedAttempt = -1

    public init(
        policy: AutomaticNetworkRecoveryPolicy,
        recoverer: any SavedWiFiNetworkRecovering = NetworkSetupSavedWiFiRecoverer(),
        pathMonitorFactory: @escaping PathMonitorFactory = {
            NWPathAutomaticNetworkPathMonitor()
        },
        internetProbe: (any MacInternetReachabilityProbing)? = nil,
        healthCheckInterval: TimeInterval = 20,
        snapshotHandler: SnapshotHandler? = nil
    ) {
        self.internetProbe = internetProbe
        self.healthCheckInterval = healthCheckInterval.isFinite ? max(0.01, healthCheckInterval) : 20
        self.recoverer = recoverer
        self.pathMonitorFactory = pathMonitorFactory
        self.snapshotHandler = snapshotHandler
        stateMachine = AutomaticNetworkRecoveryStateMachine(policy: policy)
    }

    public var snapshot: AutomaticNetworkRecoverySnapshot {
        stateMachine.snapshot
    }

    public func start() {
        guard pathMonitor == nil else { return }
        pathMonitorGeneration &+= 1
        let monitorGeneration = pathMonitorGeneration
        latestPathSourceEvent = 0
        lastSSIDLookupSourceEvent = nil
        lastPathState = .unavailable
        healthFailures = 0
        associatedWiFiRepairGuard.reset()
        if internetProbe != nil {
            healthTask = Task { [weak self, healthCheckInterval] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(healthCheckInterval)) } catch { return }
                    guard let self else { return }
                    await self.checkInternet(monitorGeneration: monitorGeneration)
                }
            }
        }
        let eventSequencer = AutomaticNetworkPathEventSequencer()
        let monitor = pathMonitorFactory()
        pathMonitor = monitor
        apply(stateMachine.start())
        publishSnapshot()

        monitor.start(queue: pathQueue) { [weak self] state in
            let sourceEvent = eventSequencer.next()
            Task {
                await self?.pathDidChange(
                    state,
                    monitorGeneration: monitorGeneration,
                    sourceEvent: sourceEvent
                )
            }
        }
    }

    public func stop() {
        associatedWiFiRepairGuard.reset()
        pathMonitorGeneration &+= 1
        latestPathSourceEvent = 0
        healthCheckGeneration &+= 1
        healthTask?.cancel()
        healthTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        scheduledTask?.cancel()
        scheduledTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        scheduleGeneration &+= 1
        apply(stateMachine.stop())
        publishSnapshot()
    }

    private func pathDidChange(
        _ state: AutomaticNetworkPathState,
        monitorGeneration: UInt64,
        sourceEvent: UInt64
    ) async {
        guard monitorGeneration == pathMonitorGeneration, pathMonitor != nil else {
            return
        }
        guard sourceEvent > latestPathSourceEvent else { return }
        latestPathSourceEvent = sourceEvent
        lastPathState = state
        if !state.isSatisfied { associatedWiFiRepairGuard.reset() }
        healthCheckGeneration &+= 1
        if internetProbe != nil, state.isSatisfied {
            await checkInternet(monitorGeneration: monitorGeneration)
            return
        }
        if !state.isSatisfied { healthFailures = 0 }
        await acceptPath(state, monitorGeneration: monitorGeneration, sourceEvent: sourceEvent)
    }

    private func checkInternet(monitorGeneration: UInt64) async {
        guard let internetProbe, pathMonitor != nil,
              monitorGeneration == pathMonitorGeneration, lastPathState.isSatisfied else { return }
        healthCheckGeneration &+= 1
        let checkGeneration = healthCheckGeneration
        let sourceEvent = latestPathSourceEvent
        let state = lastPathState
        let success = await internetProbe.isInternetReachable()
        guard !Task.isCancelled, pathMonitor != nil,
              monitorGeneration == pathMonitorGeneration,
              checkGeneration == healthCheckGeneration,
              sourceEvent == latestPathSourceEvent else { return }
        if success {
            healthFailures = 0
            associatedWiFiRepairGuard.reset()
            await acceptPath(state, monitorGeneration: monitorGeneration, sourceEvent: sourceEvent)
        } else {
            healthFailures += 1
            // Give a switching VPN/DHCP route one full probe cycle to settle.
            // A link-only event must not clear a failed internet check.
            if healthFailures >= 2 {
                apply(stateMachine.observePath(.unavailable, now: Date()))
                publishSnapshot()
            }
        }
    }

    private func acceptPath(_ state: AutomaticNetworkPathState,
                            monitorGeneration: UInt64, sourceEvent: UInt64) async {
        guard state.isSatisfied else {
            apply(stateMachine.observePath(state, now: Date()))
            publishSnapshot()
            return
        }

        if stateMachine.policy.prefersTargetOverHealthyNetwork {
            let ssid: String?
            do {
                ssid = try await recoverer.visibleCurrentNetwork()
            } catch {
                ssid = nil
            }
            guard monitorGeneration == pathMonitorGeneration,
                  sourceEvent == latestPathSourceEvent,
                  pathMonitor != nil else { return }
            let isTarget = ssid.map { stateMachine.policy.preferredSSIDs.contains($0) }
                ?? state.isPotentialMobileHotspot
            apply(stateMachine.observePath(isTarget ? state : .unavailable, now: Date()))
            if isTarget, let ssid { stateMachine.recordLastGoodSSID(ssid) }
            publishSnapshot()
            return
        }

        // A satisfied Wi-Fi-specific NWPath is authoritative connectivity
        // evidence. Recent macOS releases can hide the SSID, and a healthy
        // office/home network can legitimately differ from the configured
        // failover hotspot. Neither case authorizes a disruptive
        // `networksetup -setairportnetwork` call. The preferred SSID is used
        // only after NWPath reports a real failure.
        apply(stateMachine.observePath(.satisfied, now: Date()))
        publishSnapshot()

        // Internet probes repeat every 20s, but SSID is metadata. Resolve it
        // once per path event rather than launching networksetup on every
        // healthy probe. A changed Wi-Fi path always gets a fresh lookup.
        guard lastSSIDLookupSourceEvent != sourceEvent else { return }
        lastSSIDLookupSourceEvent = sourceEvent
        do {
            let ssid = try await recoverer.visibleCurrentNetwork()
            guard monitorGeneration == pathMonitorGeneration,
                  sourceEvent == latestPathSourceEvent,
                  pathMonitor != nil else {
                return
            }
            guard let ssid else { return }
            if stateMachine.policy.requiresPreferredSSID,
               !stateMachine.policy.preferredSSIDs.contains(ssid) {
                // Preserve a healthy non-target network without promoting it
                // into target-hotspot identity or a future reconnect candidate.
                return
            }
            stateMachine.recordLastGoodSSID(ssid)
            publishSnapshot()
        } catch {
            // SSID lookup is metadata-only. A privacy or command failure cannot
            // override the satisfied NWPath observed above.
            return
        }
    }

    private func timerDidFire(
        _ timer: AutomaticNetworkRecoveryTimer,
        generation: UInt64
    ) {
        guard generation == scheduleGeneration else { return }
        scheduledTask = nil
        apply(stateMachine.timerFired(timer, now: Date()))
        publishSnapshot()
    }

    private func reconnectDidComplete(
        attemptedSSID: String?,
        errorDescription: String?,
        generation: UInt64
    ) {
        guard generation == reconnectGeneration, pathMonitor != nil else { return }
        reconnectTask = nil
        apply(stateMachine.reconnectCompleted(
            attemptedSSID: attemptedSSID,
            errorDescription: errorDescription,
            now: Date()
        ))
        publishSnapshot()
    }

    private func apply(_ actions: [AutomaticNetworkRecoveryAction]) {
        for action in actions {
            switch action {
            case .cancelScheduledWork:
                scheduledTask?.cancel()
                scheduledTask = nil
                scheduleGeneration &+= 1

            case .cancelReconnect:
                reconnectGeneration &+= 1
                reconnectTask?.cancel()
                reconnectTask = nil

            case .schedule(let timer, let delay):
                scheduledTask?.cancel()
                scheduleGeneration &+= 1
                let generation = scheduleGeneration
                let nanoseconds = Self.nanoseconds(for: delay)
                scheduledTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self?.timerDidFire(timer, generation: generation)
                }

            case .reconnect:
                reconnectGeneration &+= 1
                let generation = reconnectGeneration
                reconnectTask?.cancel()
                let preferredSSIDs = stateMachine.policy.preferredSSIDs
                let lastGoodSSID: String?
                if stateMachine.policy.requiresPreferredSSID {
                    lastGoodSSID = stateMachine.snapshot.lastGoodSSID.flatMap { ssid in
                        preferredSSIDs.contains(ssid) ? ssid : nil
                    }
                } else {
                    lastGoodSSID = stateMachine.snapshot.lastGoodSSID
                }
                let recoverer = self.recoverer
                reconnectTask = Task { [weak self] in
                    do {
                        if let self, await self.shouldWaitForTargetRoute(generation: generation) {
                            await self.reconnectDidComplete(attemptedSSID: nil,
                                errorDescription: "Wi-Fi 仍已关联，等待互联网或 VPN 恢复；保留现有 VPN、代理和 DNS 策略。",
                                generation: generation)
                            return
                        }
                        try Task.checkCancellation()
                        let ssid = try await recoverer.reconnectSavedNetwork(
                            preferredSSIDs: preferredSSIDs,
                            lastGoodSSID: lastGoodSSID
                        )
                        guard !Task.isCancelled else { return }
                        await self?.reconnectDidComplete(
                            attemptedSSID: ssid,
                            errorDescription: nil, generation: generation
                        )
                    } catch {
                        guard !Task.isCancelled else { return }
                        await self?.reconnectDidComplete(
                            attemptedSSID: nil,
                            errorDescription: error.localizedDescription, generation: generation
                        )
                    }
                }
            }
        }
    }

    private func shouldWaitForTargetRoute(generation: UInt64) async -> Bool {
        guard internetProbe != nil, healthFailures >= 2, lastPathState.isSatisfied else { return false }
        let ssid = try? await recoverer.visibleCurrentNetwork()
        guard generation == reconnectGeneration, !Task.isCancelled else { return false }
        return associatedWiFiRepairGuard.shouldWait(
            isAssociated: lastPathState.isSatisfied, ssid: ssid,
            preferredSSIDs: stateMachine.policy.preferredSSIDs,
            hasMobileHint: lastPathState.isPotentialMobileHotspot, now: Date())
    }

    private func publishSnapshot() {
        let snapshot = stateMachine.snapshot
        if snapshot.phase != lastLoggedPhase || snapshot.reconnectAttempt != lastLoggedAttempt {
            Self.logger.notice("phase=\(snapshot.phase.rawValue, privacy: .public) attempt=\(snapshot.reconnectAttempt) error=\(snapshot.lastError ?? "none", privacy: .private)")
            lastLoggedPhase = snapshot.phase
            lastLoggedAttempt = snapshot.reconnectAttempt
        }
        snapshotHandler?(snapshot)
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        let safeSeconds = max(interval.isFinite ? interval : 0, 0)
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64(min(safeSeconds, maximumSeconds) * 1_000_000_000)
    }
}
