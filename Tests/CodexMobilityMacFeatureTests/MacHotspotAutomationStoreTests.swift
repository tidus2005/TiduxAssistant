@testable import CodexMobilityMacFeature
import CodexMobilityCore
import Foundation
import Testing

@Suite("Mac hotspot automation settings")
@MainActor
struct MacHotspotAutomationStoreTests {
    @Test
    func unpairedOrdinaryMobilityModeDoesNotStartReconnectController() async {
        let preferences = InMemoryHotspotPreferences(
            preferredSSIDs: ["Tidux iPhone"],
            lastGoodSSID: "Office Wi-Fi"
        )
        let monitor = RecordingAutomaticNetworkPathMonitor()
        let store = MacHotspotAutomationStore(
            preferences: preferences,
            pathMonitorFactory: { monitor }
        )

        store.start()
        store.setMobilityModeActive(true)
        for _ in 0..<20 { await Task.yield() }

        #expect(store.isModuleSelected)
        #expect(!store.hasPairedPhone)
        #expect(store.isMobilityModeActive)
        #expect(!store.hasReconnectAuthorization)
        #expect(!store.isOperational)
        #expect(store.snapshot.phase == .stopped)
        #expect(store.statusText.contains("配对"))
        #expect(!monitor.isStarted)
    }

    @Test
    func pairedModuleStillWaitsForTheOneClickMobilityMode() {
        let store = MacHotspotAutomationStore(preferences: InMemoryHotspotPreferences())

        store.start()
        store.setHasPairedPhone(true)

        #expect(!store.isOperational)
        #expect(store.snapshot.phase == .stopped)
        #expect(store.statusText.contains("移动联网运行"))
    }

    @Test
    func pairedPhoneAuthorizesOrdinaryMobilityReconnectMonitoring() async {
        let monitor = RecordingAutomaticNetworkPathMonitor()
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            pathMonitorFactory: { monitor }
        )

        store.start()
        store.setMobilityModeActive(true)
        store.setHasPairedPhone(true)
        for _ in 0..<100 where store.snapshot.phase != .monitoring {
            await Task.yield()
        }

        #expect(store.isOperational)
        #expect(store.snapshot.phase == .monitoring)
        #expect(monitor.isStarted)

        store.stop()
    }

    @Test
    func localClosedLidAuthorizationSurvivesPairingRevocationAndStopsAtSessionEnd() async {
        let monitor = RecordingAutomaticNetworkPathMonitor()
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            pathMonitorFactory: { monitor }
        )

        store.start()
        store.setMobilityModeActive(true)
        store.setHasPairedPhone(true)
        store.setLocalClosedLidSessionAuthorization(true)
        for _ in 0..<100 where store.snapshot.phase != .monitoring {
            await Task.yield()
        }

        store.setHasPairedPhone(false)
        for _ in 0..<20 { await Task.yield() }
        #expect(store.hasLocalClosedLidSessionAuthorization)
        #expect(store.isOperational)
        #expect(monitor.startCount == 1)

        store.setLocalClosedLidSessionAuthorization(false)
        for _ in 0..<100 where monitor.cancelCount == 0 {
            await Task.yield()
        }
        #expect(!store.hasReconnectAuthorization)
        #expect(!store.isOperational)
        #expect(store.snapshot.phase == .stopped)
        #expect(monitor.cancelCount == 1)
    }

    @Test
    func preferredSSIDInputIsNormalizedAndPersistedWithoutPasswords() {
        let preferences = InMemoryHotspotPreferences()
        let store = MacHotspotAutomationStore(preferences: preferences)

        store.updatePreferredSSIDs(text: "  Tidux iPhone  \nOffice Wi-Fi\nTidux iPhone\n\n")

        #expect(store.preferredSSIDs == ["Tidux iPhone", "Office Wi-Fi"])
        #expect(preferences.preferredSSIDs == ["Tidux iPhone", "Office Wi-Fi"])
        #expect(store.preferredSSIDsText == "Tidux iPhone\nOffice Wi-Fi")
    }

    @Test
    func quickSessionConnectsTheConfiguredSavedHotspotImmediately() async throws {
        let preferences = InMemoryHotspotPreferences(
            preferredSSIDs: ["Example Hotspot"]
        )
        let recoverer = RecordingSavedWiFiRecoverer(connectedSSID: "Example Hotspot")
        let store = MacHotspotAutomationStore(
            preferences: preferences,
            recoverer: recoverer
        )
        let offline = MobilityNetworkStatus(kind: .offline, isConnected: false)
        let connected = MobilityNetworkStatus(kind: .wifi, isConnected: true)
        var statuses = [offline, connected]

        #expect(try await store.connectPreferredNetworkNow(networkStatusProvider: {
            let status = statuses.first ?? connected
            if statuses.count > 1 {
                statuses.removeFirst()
            }
            return status
        }))
        #expect(store.snapshot.lastGoodSSID == "Example Hotspot")
        #expect(store.snapshot.lastAttemptedSSID == "Example Hotspot")
        #expect(store.lastConnectionErrorMessage == nil)
        #expect(await recoverer.requests() == [["Example Hotspot"]])
        #expect(await recoverer.lastGoodRequests() == [nil])
    }

    @Test
    func slowDHCPWaitsForTheRouteWithoutRepeatingTheJoinCommand() async throws {
        let recoverer = RecordingSavedWiFiRecoverer(connectedSSID: "Example Hotspot")
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(
                preferredSSIDs: ["Example Hotspot"]
            ),
            recoverer: recoverer,
            connectionVerificationDelay: 0
        )
        let offline = MobilityNetworkStatus(kind: .offline, isConnected: false)
        let connected = MobilityNetworkStatus(kind: .wifi, isConnected: true)
        var statuses = Array(repeating: offline, count: 53) + [connected]

        #expect(try await store.connectPreferredNetworkNow(networkStatusProvider: {
            let status = statuses.first ?? connected
            if statuses.count > 1 {
                statuses.removeFirst()
            }
            return status
        }))
        #expect(await recoverer.requests() == [["Example Hotspot"]])
        #expect(store.snapshot.lastGoodSSID == "Example Hotspot")
    }

    @Test
    func alreadyConnectedPreferredHotspotSkipsAReconnectCommand() async throws {
        let preferences = InMemoryHotspotPreferences(
            preferredSSIDs: ["Example Hotspot"]
        )
        let recoverer = RecordingSavedWiFiRecoverer(
            connectedSSID: "Example Hotspot",
            activeSSID: "Example Hotspot"
        )
        let store = MacHotspotAutomationStore(
            preferences: preferences,
            recoverer: recoverer
        )
        let connected = MobilityNetworkStatus(kind: .wifi, isConnected: true)

        #expect(try await store.connectPreferredNetworkNow(
            forcePreferredNetworkJoin: true,
            networkStatusProvider: { connected }
        ))
        #expect(store.snapshot.lastGoodSSID == "Example Hotspot")
        #expect(store.snapshot.lastAttemptedSSID == nil)
        #expect(await recoverer.requests().isEmpty)
        #expect(preferences.lastGoodSSID == "Example Hotspot")
    }

    @Test
    func forcedJoinWaitsForAnAssociatedPreferredHotspotRouteWithoutReconnecting() async throws {
        let preferences = InMemoryHotspotPreferences(
            preferredSSIDs: ["Example Hotspot"]
        )
        let recoverer = RecordingSavedWiFiRecoverer(
            connectedSSID: "Example Hotspot",
            activeSSID: "Example Hotspot"
        )
        let store = MacHotspotAutomationStore(
            preferences: preferences,
            recoverer: recoverer,
            connectionVerificationAttempts: 4,
            connectionVerificationDelay: 0
        )
        let offline = MobilityNetworkStatus(kind: .offline, isConnected: false)
        let connected = MobilityNetworkStatus(kind: .wifi, isConnected: true)
        var statuses = [offline, offline, connected]

        #expect(try await store.connectPreferredNetworkNow(
            forcePreferredNetworkJoin: true,
            networkStatusProvider: {
                let status = statuses.first ?? connected
                if statuses.count > 1 {
                    statuses.removeFirst()
                }
                return status
            }
        ))
        #expect(store.snapshot.lastGoodSSID == "Example Hotspot")
        #expect(store.snapshot.lastAttemptedSSID == nil)
        #expect(await recoverer.requests().isEmpty)
        #expect(preferences.lastGoodSSID == "Example Hotspot")
    }

    @Test
    func forcedJoinTimesOutOnAnAssociatedHotspotWithoutRepeatingTheJoin() async throws {
        let recoverer = RecordingSavedWiFiRecoverer(
            connectedSSID: "Example Hotspot",
            activeSSID: "Example Hotspot"
        )
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            recoverer: recoverer,
            connectionVerificationAttempts: 3,
            connectionVerificationDelay: 0
        )
        let offline = MobilityNetworkStatus(kind: .offline, isConnected: false)

        #expect(try await store.connectPreferredNetworkNow(
            forcePreferredNetworkJoin: true,
            networkStatusProvider: { offline }
        ) == false)
        #expect(store.lastConnectionErrorMessage?.contains("尚未获得可用网络路径") == true)
        #expect(store.snapshot.lastAttemptedSSID == nil)
        #expect(await recoverer.requests().isEmpty)
    }

    @Test
    func disconnectedTargetDoesNotLeaveAStaleAssociatedRouteError() async throws {
        let recoverer = SequencedVisibleNetworkRecoverer(
            activeSSIDResponses: ["Example Hotspot", nil, nil]
        )
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            recoverer: recoverer,
            connectionVerificationAttempts: 2,
            connectionVerificationDelay: 0
        )
        let offline = MobilityNetworkStatus(kind: .offline, isConnected: false)

        #expect(try await store.connectPreferredNetworkNow(
            networkStatusProvider: { offline }
        ) == false)
        #expect(
            store.lastConnectionErrorMessage
                == "连接命令已返回，但未能确认 Mac 已连接到配置的手机热点。"
        )
        #expect(
            store.lastConnectionError
                as? MacHotspotAutomationError
                == .connectedOutsideConfiguredTargets(actualSSID: nil)
        )
        #expect(await recoverer.requests().isEmpty)
    }

    @Test
    func privacyHiddenUsableWiFiIsPreservedWithoutAReconnectCommand() async throws {
        let preferences = InMemoryHotspotPreferences(
            preferredSSIDs: ["Example Hotspot"]
        )
        let recoverer = PrivacyHiddenSavedWiFiRecoverer()
        let store = MacHotspotAutomationStore(
            preferences: preferences,
            recoverer: recoverer
        )
        let network = MobilityNetworkStatus(
            kind: .wifi,
            isConnected: true,
            isExpensive: true,
            isConstrained: true
        )

        #expect(try await store.connectPreferredNetworkNow(networkStatusProvider: { network }))
        #expect(store.snapshot.lastGoodSSID == nil)
        #expect(store.snapshot.lastAttemptedSSID == nil)
        #expect(await recoverer.requests().isEmpty)
    }

    @Test
    func visibleNonTargetUsableWiFiIsPreservedWithoutAReconnectCommand() async throws {
        let recoverer = RecordingSavedWiFiRecoverer(
            connectedSSID: "Example Hotspot",
            activeSSID: "Office Wi-Fi"
        )
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            recoverer: recoverer
        )
        let connected = MobilityNetworkStatus(kind: .wifi, isConnected: true)

        #expect(try await store.connectPreferredNetworkNow(
            networkStatusProvider: { connected }
        ))
        #expect(store.snapshot.lastGoodSSID == nil)
        #expect(store.snapshot.lastAttemptedSSID == nil)
        #expect(await recoverer.requests().isEmpty)
    }

    @Test
    func explicitClosedLidJoinDoesNotImmediatelyAcceptPrivacyHiddenWiFi() async throws {
        let recoverer = PrivacyHiddenSavedWiFiRecoverer()
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            recoverer: recoverer,
            connectionVerificationAttempts: 2,
            connectionVerificationDelay: 0
        )
        let connected = MobilityNetworkStatus(kind: .wifi, isConnected: true)

        #expect(try await store.connectPreferredNetworkNow(
            forcePreferredNetworkJoin: true,
            networkStatusProvider: { connected }
        ) == false)
        #expect(store.snapshot.lastGoodSSID == nil)
        #expect(store.snapshot.lastAttemptedSSID == nil)
        #expect(await recoverer.requests() == [["Example Hotspot"]])
    }

    @Test
    func explicitClosedLidStartPreservesAlreadyConnectedPrivacyHiddenMobileHotspot() async throws {
        let recoverer = PrivacyHiddenSavedWiFiRecoverer()
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            recoverer: recoverer,
            connectionVerificationAttempts:
                MacHotspotAutomationStore.hiddenStablePathAcceptanceObservations,
            connectionVerificationDelay: 0
        )
        let connected = MobilityNetworkStatus(
            kind: .wifi,
            isConnected: true,
            isExpensive: true
        )

        #expect(try await store.connectPreferredNetworkNow(
            forcePreferredNetworkJoin: true,
            networkStatusProvider: { connected }
        ))
        #expect(store.snapshot.lastGoodSSID == nil)
        #expect(store.snapshot.lastAttemptedSSID == nil)
        #expect(await recoverer.requests().isEmpty)
    }

    @Test
    func explicitPrivacyHiddenJoinAcceptsTheTargetAfterAPathTransition() async throws {
        let recoverer = PrivacyHiddenSavedWiFiRecoverer()
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            recoverer: recoverer,
            connectionVerificationAttempts: 4,
            connectionVerificationDelay: 0
        )
        let offline = MobilityNetworkStatus(kind: .offline, isConnected: false)
        let ordinaryWiFi = MobilityNetworkStatus(kind: .wifi, isConnected: true)
        let mobileHotspot = MobilityNetworkStatus(
            kind: .wifi,
            isConnected: true,
            isConstrained: true
        )
        var statuses = [ordinaryWiFi, offline, mobileHotspot, mobileHotspot]

        #expect(try await store.connectPreferredNetworkNow(
            forcePreferredNetworkJoin: true,
            networkStatusProvider: {
                let status = statuses.first ?? mobileHotspot
                if statuses.count > 1 {
                    statuses.removeFirst()
                }
                return status
            }
        ))
        #expect(store.snapshot.lastGoodSSID == "Example Hotspot")
        #expect(store.snapshot.lastAttemptedSSID == "Example Hotspot")
        #expect(await recoverer.requests() == [["Example Hotspot"]])
    }

    @Test
    func explicitClosedLidJoinRejectsAVisibleWrongNetworkAfterTheCommand() async throws {
        let recoverer = SequencedVisibleNetworkRecoverer(
            activeSSIDResponses: [nil, "Office Wi-Fi"]
        )
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            recoverer: recoverer,
            connectionVerificationAttempts: 1,
            connectionVerificationDelay: 0
        )
        let connected = MobilityNetworkStatus(kind: .wifi, isConnected: true)

        #expect(try await store.connectPreferredNetworkNow(
            forcePreferredNetworkJoin: true,
            networkStatusProvider: { connected }
        ) == false)
        #expect(store.snapshot.lastGoodSSID == nil)
        #expect(store.lastConnectionErrorMessage?.contains("Office Wi-Fi") == true)
        #expect(
            store.lastConnectionError as? MacHotspotAutomationError
                == .connectedOutsideConfiguredTargets(actualSSID: "Office Wi-Fi")
        )
        #expect(await recoverer.requests() == [["Example Hotspot"]])
    }

    @Test
    func privacyHiddenButDisconnectedWiFiStillReconnectsSavedTarget() async throws {
        let recoverer = PrivacyHiddenSavedWiFiRecoverer()
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(preferredSSIDs: ["Example Hotspot"]),
            recoverer: recoverer,
            connectionVerificationAttempts: 3,
            connectionVerificationDelay: 0
        )
        let offline = MobilityNetworkStatus(kind: .offline, isConnected: false)
        let connected = MobilityNetworkStatus(
            kind: .wifi,
            isConnected: true,
            isExpensive: true
        )
        var statuses = [offline, connected, connected]

        #expect(try await store.connectPreferredNetworkNow(networkStatusProvider: {
            let status = statuses.first ?? connected
            if statuses.count > 1 {
                statuses.removeFirst()
            }
            return status
        }))
        #expect(store.snapshot.lastGoodSSID == "Example Hotspot")
        #expect(store.snapshot.lastAttemptedSSID == "Example Hotspot")
        #expect(await recoverer.requests() == [["Example Hotspot"]])
    }

    @Test
    func quickSessionNeverFallsBackToAStaleNonTargetNetwork() async throws {
        let preferences = InMemoryHotspotPreferences(
            preferredSSIDs: ["Example Hotspot"],
            lastGoodSSID: "Office Wi-Fi"
        )
        let recoverer = RecordingSavedWiFiRecoverer(connectedSSID: "Example Hotspot")
        let store = MacHotspotAutomationStore(
            preferences: preferences,
            recoverer: recoverer
        )
        let offline = MobilityNetworkStatus(kind: .offline, isConnected: false)
        let connected = MobilityNetworkStatus(kind: .wifi, isConnected: true)
        var statuses = [offline, connected]

        #expect(try await store.connectPreferredNetworkNow(networkStatusProvider: {
            let status = statuses.first ?? connected
            if statuses.count > 1 {
                statuses.removeFirst()
            }
            return status
        }))
        #expect(await recoverer.requests() == [["Example Hotspot"]])
        #expect(await recoverer.lastGoodRequests() == [nil])
    }

    @Test
    func quickSessionRejectsACommandThatDidNotActuallyJoinTheTarget() async throws {
        let recoverer = RecordingSavedWiFiRecoverer(
            connectedSSID: "Example Hotspot",
            activeSSID: "Office Wi-Fi"
        )
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(
                preferredSSIDs: ["Example Hotspot"]
            ),
            recoverer: recoverer,
            connectionVerificationAttempts: 1,
            connectionVerificationDelay: 0
        )

        #expect(try await store.connectPreferredNetworkNow() == false)
        #expect(store.snapshot.lastGoodSSID == nil)
        #expect(store.lastConnectionErrorMessage?.contains("Office Wi-Fi") == true)
    }

    @Test
    func quickSessionRefusesToGuessAnUnconfiguredHotspot() async throws {
        let recoverer = RecordingSavedWiFiRecoverer(connectedSSID: "Office Wi-Fi")
        let store = MacHotspotAutomationStore(
            preferences: InMemoryHotspotPreferences(),
            recoverer: recoverer
        )

        let connected = try await store.connectPreferredNetworkNow()
        #expect(!connected)
        #expect(store.lastConnectionErrorMessage?.contains("填写") == true)
        #expect(await recoverer.requests().isEmpty)
    }
}

private final class InMemoryHotspotPreferences:
    MacHotspotAutomationPreferencesPersisting {
    var preferredSSIDs: [String]
    var lastGoodSSID: String?

    init(preferredSSIDs: [String] = [], lastGoodSSID: String? = nil) {
        self.preferredSSIDs = preferredSSIDs
        self.lastGoodSSID = lastGoodSSID
    }

    func loadPreferredSSIDs() -> [String] {
        preferredSSIDs
    }

    func savePreferredSSIDs(_ values: [String]) {
        preferredSSIDs = values
    }

    func loadLastGoodSSID() -> String? {
        lastGoodSSID
    }

    func saveLastGoodSSID(_ value: String?) {
        lastGoodSSID = value
    }
}

private actor RecordingSavedWiFiRecoverer: SavedWiFiNetworkRecovering {
    private let connectedSSID: String
    private var activeSSIDResponses: [String?]
    private var preferredSSIDRequests: [[String]] = []
    private var recordedLastGoodSSIDs: [String?] = []

    init(connectedSSID: String, activeSSID: String? = nil) {
        self.connectedSSID = connectedSSID
        if let activeSSID {
            self.activeSSIDResponses = [activeSSID, activeSSID]
        } else {
            self.activeSSIDResponses = [nil, connectedSSID]
        }
    }

    func visibleCurrentNetwork() async throws -> String? {
        guard let first = activeSSIDResponses.first else { return nil }
        if activeSSIDResponses.count > 1 {
            activeSSIDResponses.removeFirst()
        }
        return first
    }

    func reconnectSavedNetwork(
        preferredSSIDs: [String],
        lastGoodSSID: String?
    ) async throws -> String {
        preferredSSIDRequests.append(preferredSSIDs)
        recordedLastGoodSSIDs.append(lastGoodSSID)
        return connectedSSID
    }

    func requests() -> [[String]] {
        preferredSSIDRequests
    }

    func lastGoodRequests() -> [String?] {
        recordedLastGoodSSIDs
    }
}

private actor PrivacyHiddenSavedWiFiRecoverer: SavedWiFiNetworkRecovering {
    private var preferredSSIDRequests: [[String]] = []

    func visibleCurrentNetwork() async throws -> String? {
        nil
    }

    func reconnectSavedNetwork(
        preferredSSIDs: [String],
        lastGoodSSID: String?
    ) async throws -> String {
        preferredSSIDRequests.append(preferredSSIDs)
        return preferredSSIDs[0]
    }

    func requests() -> [[String]] {
        preferredSSIDRequests
    }
}

private actor SequencedVisibleNetworkRecoverer: SavedWiFiNetworkRecovering {
    private var activeSSIDResponses: [String?]
    private var preferredSSIDRequests: [[String]] = []

    init(activeSSIDResponses: [String?]) {
        self.activeSSIDResponses = activeSSIDResponses
    }

    func visibleCurrentNetwork() async throws -> String? {
        guard !activeSSIDResponses.isEmpty else { return nil }
        return activeSSIDResponses.removeFirst()
    }

    func reconnectSavedNetwork(
        preferredSSIDs: [String],
        lastGoodSSID: String?
    ) async throws -> String {
        preferredSSIDRequests.append(preferredSSIDs)
        return preferredSSIDs[0]
    }

    func requests() -> [[String]] {
        preferredSSIDRequests
    }
}

private final class RecordingAutomaticNetworkPathMonitor:
    AutomaticNetworkPathMonitoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStartCount = 0
    private var recordedCancelCount = 0

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedStartCount > recordedCancelCount
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedStartCount
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCancelCount
    }

    func start(
        queue: DispatchQueue,
        updateHandler: @escaping @Sendable (AutomaticNetworkPathState) -> Void
    ) {
        lock.lock()
        recordedStartCount += 1
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        recordedCancelCount += 1
        lock.unlock()
    }
}
