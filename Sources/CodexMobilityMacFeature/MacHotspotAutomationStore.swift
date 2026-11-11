import CodexMobilityCore
import Combine
import Foundation

public protocol MacHotspotAutomationPreferencesPersisting: AnyObject {
    func loadPreferredSSIDs() -> [String]
    func savePreferredSSIDs(_ values: [String])
    func loadLastGoodSSID() -> String?
    func saveLastGoodSSID(_ value: String?)
}

public enum MacHotspotAutomationError: Error, LocalizedError, Equatable, Sendable {
    case connectedOutsideConfiguredTargets(actualSSID: String?)
    case preferredNetworkRouteUnavailable(ssid: String)

    public var errorDescription: String? {
        switch self {
        case .connectedOutsideConfiguredTargets(let actualSSID):
            if let actualSSID {
                return "连接命令已返回，但 Mac 当前连接的是“\(actualSSID)”，不是已配置的手机热点。"
            }
            return "连接命令已返回，但未能确认 Mac 已连接到配置的手机热点。"
        case .preferredNetworkRouteUnavailable(let ssid):
            return "Mac 已连接到“\(ssid)”，但尚未获得可用网络路径。请确认手机蜂窝网络与热点可用后重试。"
        }
    }
}

public final class UserDefaultsMacHotspotAutomationPreferences:
    MacHotspotAutomationPreferencesPersisting {
    public static let suiteName = "com.tidux.codex-mobility.hotspot"

    private enum Key {
        static let preferredSSIDs = "preferredSSIDs.v1"
        static let lastGoodSSID = "lastGoodSSID.v1"
    }

    private let defaults: UserDefaults

    public convenience init() {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else {
            preconditionFailure("Unable to create hotspot automation preferences")
        }
        self.init(defaults: defaults)
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func loadPreferredSSIDs() -> [String] {
        defaults.stringArray(forKey: Key.preferredSSIDs) ?? []
    }

    public func savePreferredSSIDs(_ values: [String]) {
        defaults.set(values, forKey: Key.preferredSSIDs)
    }

    public func loadLastGoodSSID() -> String? {
        defaults.string(forKey: Key.lastGoodSSID)
    }

    public func saveLastGoodSSID(_ value: String?) {
        defaults.set(value, forKey: Key.lastGoodSSID)
    }
}

/// Settings-facing lifecycle for the experimental saved-hotspot reconnect module.
///
/// The module runtime owns `start`/`stop`. Ordinary mobility-mode recovery is
/// authorized by a paired phone. A locally initiated closed-lid session may
/// grant a short-lived, in-memory authorization after its system lease and
/// safety preflight succeed. Pairing remains required for remote control,
/// status delivery, and file sync.
@MainActor
public final class MacHotspotAutomationStore: ObservableObject, MacMobilityModuleAdapter {
    // Personal Hotspot association may precede DHCP/default-route publication
    // by tens of seconds. The closed-lid controller supplies the hard 40-second
    // deadline; this observation window lets that deadline do its job instead
    // of returning early and issuing another disruptive join.
    public static let defaultConnectionVerificationAttempts = 61
    public static let defaultConnectionVerificationDelay: TimeInterval = 0.5
    // When macOS privacy hides SSIDs, switching from ordinary Wi-Fi to the
    // requested hotspot does not necessarily publish an observable path drop.
    // Four stable *metered mobile-path* observations provide a settling window;
    // an unmetered hidden Wi-Fi path is never accepted as hotspot identity.
    static let hiddenStablePathAcceptanceObservations = 4

    public let moduleID: MobilityModuleID = .hotspotAutomation

    @Published public private(set) var preferredSSIDs: [String]
    @Published public private(set) var snapshot: AutomaticNetworkRecoverySnapshot
    @Published public private(set) var isModuleSelected = false
    @Published public private(set) var hasPairedPhone = false
    @Published public private(set) var hasLocalClosedLidSessionAuthorization = false
    @Published public private(set) var isMobilityModeActive = false
    @Published public private(set) var lastConnectionErrorMessage: String?
    public private(set) var lastConnectionError: (any Error)?

    public var preferredSSIDsText: String {
        preferredSSIDs.joined(separator: "\n")
    }

    public var reconnectTargetName: String? {
        preferredSSIDs.first ?? snapshot.lastGoodSSID
    }

    public var hasReconnectTarget: Bool {
        reconnectTargetName != nil
    }

    public var hasReconnectAuthorization: Bool {
        hasPairedPhone || hasLocalClosedLidSessionAuthorization
    }

    public var isOperational: Bool {
        shouldRunController && snapshot.phase != .stopped
    }

    public var statusText: String {
        guard isModuleSelected else { return "实验模块已关闭" }
        guard isMobilityModeActive else { return "等待开启“移动联网运行”" }
        guard hasReconnectAuthorization else {
            return "等待已配对 iPhone 或本机“定时合盖续跑”授权"
        }

        switch snapshot.phase {
        case .stopped:
            return "正在启动 Wi-Fi 事件监听"
        case .monitoring:
            return snapshot.isNetworkAvailable ? "Wi-Fi 路径正常" : "正在等待网络路径"
        case .confirmingFailure:
            return "正在确认 Wi-Fi 断开"
        case .reconnecting:
            return "正在连接已保存的热点"
        case .waitingForConnectivity:
            return "已发起连接，等待网络恢复"
        case .backingOff:
            return snapshot.lastError.map { "重连失败：\($0)" } ?? "等待下一次低频重试"
        }
    }

    private let preferences: any MacHotspotAutomationPreferencesPersisting
    private let recoverer: any SavedWiFiNetworkRecovering
    private let instantHotspotConnector: (any MacInstantHotspotConnecting)?
    private let backgroundHotspotActivator: any MacBackgroundHotspotActivating
    private let pathMonitorFactory: AutomaticNetworkRecoveryController.PathMonitorFactory
    private let connectionVerificationAttempts: Int
    private let connectionVerificationDelay: TimeInterval
    private var controller: AutomaticNetworkRecoveryController?
    private var controllerGeneration: UInt64 = 0
    private var controllerLifecycleTask: Task<Void, Never>?

    public init(
        preferences: any MacHotspotAutomationPreferencesPersisting =
            UserDefaultsMacHotspotAutomationPreferences(),
        recoverer: any SavedWiFiNetworkRecovering = NetworkSetupSavedWiFiRecoverer(),
        instantHotspotConnector: (any MacInstantHotspotConnecting)? = nil,
        backgroundHotspotActivator: (any MacBackgroundHotspotActivating)? = nil,
        connectionVerificationAttempts: Int =
            MacHotspotAutomationStore.defaultConnectionVerificationAttempts,
        connectionVerificationDelay: TimeInterval =
            MacHotspotAutomationStore.defaultConnectionVerificationDelay,
        pathMonitorFactory: @escaping AutomaticNetworkRecoveryController.PathMonitorFactory = {
            NWPathAutomaticNetworkPathMonitor()
        }
    ) {
        self.preferences = preferences
        self.backgroundHotspotActivator = backgroundHotspotActivator ?? SharingBackgroundHotspotActivator()
        self.recoverer = recoverer
        self.instantHotspotConnector = instantHotspotConnector ?? (
            recoverer is NetworkSetupSavedWiFiRecoverer ? SystemSettingsInstantHotspotConnector() : nil
        )
        self.connectionVerificationAttempts = max(connectionVerificationAttempts, 1)
        self.connectionVerificationDelay = max(connectionVerificationDelay, 0)
        self.pathMonitorFactory = pathMonitorFactory
        let preferredSSIDs = Self.normalizedSSIDs(preferences.loadPreferredSSIDs())
        self.preferredSSIDs = preferredSSIDs
        self.snapshot = AutomaticNetworkRecoverySnapshot(
            lastGoodSSID: Self.normalizedSSID(preferences.loadLastGoodSSID())
        )
    }

    public func start() {
        guard !isModuleSelected else { return }
        isModuleSelected = true
        reconcileController()
    }

    public func stop() {
        guard isModuleSelected || controller != nil else { return }
        isModuleSelected = false
        reconcileController()
    }

    public func setHasPairedPhone(_ value: Bool) {
        guard hasPairedPhone != value else { return }
        hasPairedPhone = value
        reconcileController()
    }

    /// Grants continuous reconnect only for the lifetime of a locally initiated
    /// closed-lid session. This state is intentionally never persisted.
    func setLocalClosedLidSessionAuthorization(_ value: Bool) {
        guard hasLocalClosedLidSessionAuthorization != value else { return }
        hasLocalClosedLidSessionAuthorization = value
        if controller != nil, shouldRunController {
            restartController()
        } else {
            reconcileController()
        }
    }

    public func setMobilityModeActive(_ value: Bool) {
        guard isMobilityModeActive != value else { return }
        isMobilityModeActive = value
        reconcileController()
    }

    /// Accepts one SSID per line. Values are data only: no password or shell
    /// command is accepted, and the lower layer still requires a saved macOS network.
    public func updatePreferredSSIDs(text: String) {
        let values = Self.normalizedSSIDs(
            text.components(separatedBy: .newlines)
        )
        guard values != preferredSSIDs else { return }
        preferredSSIDs = values
        preferences.savePreferredSSIDs(values)
        if shouldRunController {
            restartController()
        }
    }

    @discardableResult
    /// Connects a configured, saved hotspot when the Mac has no usable path.
    /// Pass `forcePreferredNetworkJoin` only for an explicit user request to
    /// replace a healthy non-target Wi-Fi connection.
    public func connectPreferredNetworkNow(
        forcePreferredNetworkJoin: Bool = false,
        networkStatusProvider: () -> MobilityNetworkStatus = { MobilityNetworkStatus() }
    ) async throws -> Bool {
        guard hasReconnectTarget else {
            lastConnectionErrorMessage = "请先填写并保存 iPhone 5G 热点名称。"
            lastConnectionError = nil
            return false
        }
        lastConnectionErrorMessage = nil
        lastConnectionError = nil

        do {
            var requiresHiddenPathTransitionAfterJoin = false
            switch try await currentLinkObservation(
                networkStatusProvider: networkStatusProvider
            ) {
            case .visible(let activeSSID, let isNetworkAvailable):
                if preferredSSIDs.contains(activeSSID) {
                    if isNetworkAvailable {
                        snapshot.lastGoodSSID = activeSSID
                        snapshot.lastError = nil
                        preferences.saveLastGoodSSID(activeSSID)
                        return true
                    }
                    // Association and route publication are separate events on
                    // Personal Hotspot. This applies even to an explicit local
                    // closed-lid request: reissuing setairportnetwork while the
                    // target is already associated restarts DHCP and can keep the
                    // default route unavailable indefinitely. `force` chooses the
                    // target only when its identity is hidden, wrong or unavailable.
                    let verifiedSSID = try await verifyActivePreferredNetwork(
                        afterSuccessfulJoinOf: activeSSID,
                        networkStatusProvider: networkStatusProvider
                    )
                    snapshot.lastGoodSSID = verifiedSSID
                    snapshot.lastError = nil
                    preferences.saveLastGoodSSID(verifiedSSID)
                    return true
                }
                if isNetworkAvailable, !forcePreferredNetworkJoin {
                    // A visible office/home network is just as authoritative as
                    // a privacy-hidden one. Hotspot automation is failover-only
                    // unless the caller explicitly asks to replace this link.
                    snapshot.lastError = nil
                    return true
                }
                break
            case .hiddenButUsable(let isLikelyMobileHotspot):
                if isLikelyMobileHotspot {
                    // Personal Hotspot paths are reported by macOS as
                    // expensive or constrained even when SSID access is
                    // privacy-redacted. Preserve that already-usable mobile
                    // path. Reissuing setairportnetwork here can make macOS
                    // fall back to an unrelated auto-join Wi-Fi network.
                    snapshot.lastError = nil
                    return true
                }
                guard forcePreferredNetworkJoin else {
                    // The Wi-Fi-specific path is healthy, but macOS privacy hides
                    // the SSID. Preserve the live link and do not claim that its
                    // identity was verified or issue a disruptive reconnect.
                    snapshot.lastError = nil
                    return true
                }
                // The Wi-Fi-specific path is healthy, but macOS privacy hides
                // its identity. A locally clicked closed-lid session explicitly
                // requests the configured hotspot, so issue the allow-listed,
                // saved-network join instead of accepting an arbitrary Wi-Fi.
                requiresHiddenPathTransitionAfterJoin = true
                break
            case .unavailable:
                break
            }
            let allowedLastGoodSSID = snapshot.lastGoodSSID.flatMap { ssid in
                preferredSSIDs.contains(ssid) ? ssid : nil
            }
            let attemptedSSID: String
            if let systemRecoverer = recoverer as? NetworkSetupSavedWiFiRecoverer {
                let authorizedRecoverer = (forcePreferredNetworkJoin || hasReconnectAuthorization)
                    && MacHotspotWiFiAuthorization.shared.isAuthorized
                    ? systemRecoverer.withBackgroundHotspotActivator(backgroundHotspotActivator)
                    : systemRecoverer
                attemptedSSID = try await authorizedRecoverer.reconnectSavedNetwork(
                    preferredSSIDs: preferredSSIDs,
                    lastGoodSSID: allowedLastGoodSSID,
                    instantHotspotConnector: forcePreferredNetworkJoin ? instantHotspotConnector : nil
                )
            } else {
                attemptedSSID = try await recoverer.reconnectSavedNetwork(
                    preferredSSIDs: preferredSSIDs,
                    lastGoodSSID: allowedLastGoodSSID
                )
            }
            guard preferredSSIDs.contains(attemptedSSID) else {
                throw MacHotspotAutomationError.connectedOutsideConfiguredTargets(
                    actualSSID: attemptedSSID
                )
            }
            let verifiedSSID = try await verifyActivePreferredNetwork(
                afterSuccessfulJoinOf: attemptedSSID,
                requiresHiddenPathTransition: requiresHiddenPathTransitionAfterJoin,
                networkStatusProvider: networkStatusProvider
            )
            snapshot.lastAttemptedSSID = attemptedSSID
            snapshot.lastGoodSSID = verifiedSSID
            snapshot.lastError = nil
            preferences.saveLastGoodSSID(verifiedSSID)
            return true
        } catch is CancellationError {
            lastConnectionError = nil
            lastConnectionErrorMessage = nil
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            snapshot.lastError = message
            lastConnectionError = error
            lastConnectionErrorMessage = message
            return false
        }
    }

    private func reconcileController() {
        if shouldRunController {
            guard controller == nil else { return }
            startController()
        } else {
            stopController()
        }
    }

    private func restartController() {
        stopController()
        guard shouldRunController else { return }
        startController()
    }

    private var shouldRunController: Bool {
        isModuleSelected && isMobilityModeActive && hasReconnectAuthorization
    }

    private func startController() {
        controllerGeneration &+= 1
        let generation = controllerGeneration
        let policy = AutomaticNetworkRecoveryPolicy(
            preferredSSIDs: preferredSSIDs,
            initialLastGoodSSID: snapshot.lastGoodSSID,
            maximumRetryDelay: 30,
            requiresPreferredSSID: !preferredSSIDs.isEmpty,
            // The explicit start still selects the hotspot. During recovery,
            // keep any verified working network instead of oscillating between
            // a healthy Wi-Fi and an absent phone.
            prefersTargetOverHealthyNetwork: false
        )
        let backgroundRecoverer: any SavedWiFiNetworkRecovering
        if let systemRecoverer = recoverer as? NetworkSetupSavedWiFiRecoverer,
           hasReconnectAuthorization, !preferredSSIDs.isEmpty {
            backgroundRecoverer = systemRecoverer.withBackgroundHotspotActivator(backgroundHotspotActivator)
        } else {
            backgroundRecoverer = recoverer
        }
        let controller = AutomaticNetworkRecoveryController(
            policy: policy,
            recoverer: backgroundRecoverer,
            pathMonitorFactory: pathMonitorFactory,
            internetProbe: recoverer is NetworkSetupSavedWiFiRecoverer ? MacInternetReachabilityProbe() : nil
        ) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, generation == self.controllerGeneration else { return }
                self.receive(snapshot)
            }
        }
        self.controller = controller
        let priorLifecycleTask = controllerLifecycleTask
        controllerLifecycleTask = Task { @MainActor [weak self] in
            await priorLifecycleTask?.value
            guard let self,
                  generation == self.controllerGeneration,
                  self.controller === controller else {
                await controller.stop()
                return
            }
            await controller.start()
            guard generation == self.controllerGeneration,
                  self.controller === controller else {
                await controller.stop()
                return
            }
        }
    }

    private func stopController() {
        controllerGeneration &+= 1
        let previous = controller
        controller = nil
        if let previous {
            let priorLifecycleTask = controllerLifecycleTask
            controllerLifecycleTask = Task {
                await priorLifecycleTask?.value
                await previous.stop()
            }
        }
        snapshot.phase = .stopped
        snapshot.isNetworkAvailable = false
        snapshot.consecutiveFailures = 0
        snapshot.reconnectAttempt = 0
        snapshot.nextActionAt = nil
    }

    private func receive(_ next: AutomaticNetworkRecoverySnapshot) {
        if next.lastGoodSSID != snapshot.lastGoodSSID {
            preferences.saveLastGoodSSID(next.lastGoodSSID)
        }
        snapshot = next
    }

    private func verifyActivePreferredNetwork(
        afterSuccessfulJoinOf attemptedSSID: String,
        requiresHiddenPathTransition: Bool = false,
        networkStatusProvider: () -> MobilityNetworkStatus
    ) async throws -> String {
        var lastObservedSSID: String?
        var preferredSSIDWaitingForRoute: String?
        var consecutiveHiddenUsableObservations = 0
        var didObserveTargetTransition = !requiresHiddenPathTransition
        let requiredHiddenUsableObservationsAfterTransition = min(
            connectionVerificationAttempts,
            2
        )
        for attempt in 0..<connectionVerificationAttempts {
            switch try await currentLinkObservation(
                networkStatusProvider: networkStatusProvider
            ) {
            case .visible(let ssid, let isNetworkAvailable):
                lastObservedSSID = ssid
                consecutiveHiddenUsableObservations = 0
                if preferredSSIDs.contains(ssid) {
                    didObserveTargetTransition = true
                    if isNetworkAvailable {
                        return ssid
                    }
                    preferredSSIDWaitingForRoute = ssid
                } else {
                    preferredSSIDWaitingForRoute = nil
                }
            case .hiddenButUsable(let isLikelyMobileHotspot):
                lastObservedSSID = nil
                preferredSSIDWaitingForRoute = nil
                if isLikelyMobileHotspot {
                    consecutiveHiddenUsableObservations += 1
                } else {
                    // A privacy-hidden ordinary Wi-Fi path proves only generic
                    // connectivity. It must never prove that the allow-listed
                    // phone hotspot was joined; otherwise macOS auto-join can
                    // silently switch the session onto an unrelated network.
                    consecutiveHiddenUsableObservations = 0
                }
            case .unavailable:
                lastObservedSSID = nil
                preferredSSIDWaitingForRoute = nil
                consecutiveHiddenUsableObservations = 0
                didObserveTargetTransition = true
            }

            let requiredHiddenUsableObservations = didObserveTargetTransition
                ? requiredHiddenUsableObservationsAfterTransition
                : Self.hiddenStablePathAcceptanceObservations
            if consecutiveHiddenUsableObservations >= requiredHiddenUsableObservations {
                // The command targeted only this allow-listed, already-saved
                // SSID. A real path transition needs two healthy observations;
                // an already-associated, privacy-hidden target needs a longer
                // stable window because joining the same SSID may not flap the
                // route at all. A visible wrong SSID still fails above.
                return attemptedSSID
            }
            if attempt + 1 < connectionVerificationAttempts,
               connectionVerificationDelay > 0 {
                try await Task.sleep(for: .seconds(connectionVerificationDelay))
            }
        }
        if let preferredSSIDWaitingForRoute {
            throw MacHotspotAutomationError.preferredNetworkRouteUnavailable(
                ssid: preferredSSIDWaitingForRoute
            )
        }
        throw MacHotspotAutomationError.connectedOutsideConfiguredTargets(
            actualSSID: lastObservedSSID
        )
    }

    private enum CurrentLinkObservation {
        case visible(String, isNetworkAvailable: Bool)
        case hiddenButUsable(isLikelyMobileHotspot: Bool)
        case unavailable
    }

    private func currentLinkObservation(
        networkStatusProvider: () -> MobilityNetworkStatus
    ) async throws -> CurrentLinkObservation {
        let network = networkStatusProvider()
        do {
            if let ssid = try await recoverer.visibleCurrentNetwork() {
                return .visible(ssid, isNetworkAvailable: network.isConnected)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard Self.isUsableWiFi(network) else { throw error }
            return .hiddenButUsable(
                isLikelyMobileHotspot: Self.isLikelyMobileHotspot(network)
            )
        }
        return Self.isUsableWiFi(network)
            ? .hiddenButUsable(
                isLikelyMobileHotspot: Self.isLikelyMobileHotspot(network)
            )
            : .unavailable
    }

    private static func isUsableWiFi(_ network: MobilityNetworkStatus) -> Bool {
        network.isConnected && network.kind == .wifi
    }

    private static func isLikelyMobileHotspot(
        _ network: MobilityNetworkStatus
    ) -> Bool {
        isUsableWiFi(network) && (network.isExpensive || network.isConstrained)
    }

    private static func normalizedSSIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
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
        guard !normalized.isEmpty,
              !normalized.contains("\n"),
              !normalized.contains("\r") else {
            return nil
        }
        return normalized
    }
}
