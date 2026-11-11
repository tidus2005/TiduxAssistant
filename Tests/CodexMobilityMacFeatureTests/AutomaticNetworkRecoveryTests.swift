@testable import CodexMobilityMacFeature
import Foundation
import Testing

private actor StubNetworkSetupCommandRunner: NetworkSetupCommandRunning {
    private let hardwarePortsOutput: String
    private let preferredNetworksOutput: String
    private let currentNetworkOutput: String
    private var connectionStatuses: [Int32]
    private var connectionStandardOutputs: [String]
    private var connectionStandardErrors: [String]
    private var recordedArguments: [[String]] = []

    init(
        hardwarePortsOutput: String = """
        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: none

        Hardware Port: Wi-Fi
        Device: en7
        Ethernet Address: 00:00:00:00:00:00
        """,
        preferredNetworksOutput: String = """
        Preferred networks on en7:
                Phone Hotspot
                Office Wi-Fi
        """,
        currentNetworkOutput: String = "Current Wi-Fi Network: Office Wi-Fi",
        connectionStatuses: [Int32] = [0],
        connectionStandardOutputs: [String] = [],
        connectionStandardErrors: [String] = []
    ) {
        self.hardwarePortsOutput = hardwarePortsOutput
        self.preferredNetworksOutput = preferredNetworksOutput
        self.currentNetworkOutput = currentNetworkOutput
        self.connectionStatuses = connectionStatuses
        self.connectionStandardOutputs = connectionStandardOutputs
        self.connectionStandardErrors = connectionStandardErrors
    }

    func run(arguments: [String]) async throws -> NetworkSetupCommandResult {
        recordedArguments.append(arguments)
        switch arguments.first {
        case "-listallhardwareports":
            return NetworkSetupCommandResult(
                terminationStatus: 0,
                standardOutput: hardwarePortsOutput
            )
        case "-listpreferredwirelessnetworks":
            return NetworkSetupCommandResult(
                terminationStatus: 0,
                standardOutput: preferredNetworksOutput
            )
        case "-getairportnetwork":
            return NetworkSetupCommandResult(
                terminationStatus: 0,
                standardOutput: currentNetworkOutput
            )
        case "-setairportpower":
            return NetworkSetupCommandResult(terminationStatus: 0)
        case "-setairportnetwork":
            let status = connectionStatuses.isEmpty ? 1 : connectionStatuses.removeFirst()
            let output = connectionStandardOutputs.isEmpty
                ? ""
                : connectionStandardOutputs.removeFirst()
            let error = connectionStandardErrors.isEmpty
                ? ""
                : connectionStandardErrors.removeFirst()
            return NetworkSetupCommandResult(
                terminationStatus: status,
                standardOutput: output,
                standardError: error
            )
        default:
            return NetworkSetupCommandResult(terminationStatus: 64)
        }
    }

    func argumentsLog() -> [[String]] {
        recordedArguments
    }
}

@Suite("Automatic network recovery")
struct AutomaticNetworkRecoveryTests {
    @Test func healthyInternetProbesDoNotRepeatSSIDLookupUntilPathChanges() async throws {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: "Office Wi-Fi")
        let probe = MutableInternetProbe(true)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(preferredSSIDs: ["Phone Hotspot"],
                requiresPreferredSSID: true),
            recoverer: recoverer, pathMonitorFactory: { monitor },
            internetProbe: probe, healthCheckInterval: 0.01)
        await controller.start()
        monitor.emit(AutomaticNetworkPathState(isSatisfied: true))
        for _ in 0..<100 where await probe.calls < 4 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.calls >= 4)
        #expect(await recoverer.lookupCount == 1)
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await controller.snapshot.lastGoodSSID == nil)
        #expect(await recoverer.reconnectCount() == 0)
        monitor.emit(AutomaticNetworkPathState(isSatisfied: true, isExpensive: true))
        for _ in 0..<100 where await recoverer.lookupCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recoverer.lookupCount == 2)
        await controller.stop()
    }
    @Test func hiddenMobileWiFiWaitsForVPNWithoutRejoiningOrClaimingInternet() async throws {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: nil)
        let probe = MutableInternetProbe(false)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(preferredSSIDs: ["Phone Hotspot"],
                consecutiveFailureThreshold: 1, baseRetryDelay: 0.02,
                maximumRetryDelay: 0.02, minimumReconnectInterval: 0, requiresPreferredSSID: true),
            recoverer: recoverer, pathMonitorFactory: { monitor },
            internetProbe: probe, healthCheckInterval: 0.01)
        await controller.start()
        monitor.emit(AutomaticNetworkPathState(isSatisfied: true, isExpensive: true))
        for _ in 0..<100 where await controller.snapshot.reconnectAttempt == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await controller.snapshot.reconnectAttempt > 0)
        #expect(!(await controller.snapshot.isNetworkAvailable))
        #expect(await controller.snapshot.lastGoodSSID == nil)
        #expect(await recoverer.reconnectCount() == 0)
        await probe.set(true)
        for _ in 0..<100 where !(await controller.snapshot.isNetworkAvailable) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await recoverer.reconnectCount() == 0)
        await controller.stop()
    }

    @Test func hiddenSSIDDeferralExpiresAndRealDisconnectClearsIt() {
        var guardPolicy = AssociatedWiFiRepairGuard()
        let start = Date(timeIntervalSince1970: 1000)
        func check(_ associated: Bool, at seconds: TimeInterval) -> Bool {
            guardPolicy.shouldWait(isAssociated: associated, ssid: nil,
                preferredSSIDs: ["Phone Hotspot"], hasMobileHint: true,
                now: start.addingTimeInterval(seconds))
        }
        #expect(check(true, at: 0))
        #expect(check(true, at: 119))
        #expect(!check(true, at: 120))
        #expect(check(true, at: 121))
        #expect(!check(false, at: 122))
        #expect(check(true, at: 250))
    }

    @Test func unknownOrdinaryWiFiOrVisibleWrongSSIDDoesNotAcquireHotspotProtection() {
        var guardPolicy = AssociatedWiFiRepairGuard()
        let now = Date(timeIntervalSince1970: 1000)
        let unknownOrdinary = guardPolicy.shouldWait(isAssociated: true, ssid: nil,
            preferredSSIDs: ["Phone Hotspot"], hasMobileHint: false, now: now)
        let wrongSSID = guardPolicy.shouldWait(isAssociated: true, ssid: "Office Wi-Fi",
            preferredSSIDs: ["Phone Hotspot"], hasMobileHint: true, now: now)
        let unconfigured = guardPolicy.shouldWait(isAssociated: true, ssid: nil,
            preferredSSIDs: [], hasMobileHint: true, now: now)
        let knownTarget = guardPolicy.shouldWait(isAssociated: true, ssid: "Phone Hotspot",
            preferredSSIDs: ["Phone Hotspot"], hasMobileHint: false, now: now)
        #expect(!unknownOrdinary)
        #expect(!wrongSSID)
        #expect(!unconfigured)
        #expect(knownTarget)
    }

    @Test(arguments: [
        ["-setdnsservers", "Wi-Fi", "1.1.1.1"],
        ["-setwebproxy", "Wi-Fi", "localhost", "9999"],
        ["-setsecurewebproxystate", "Wi-Fi", "off"],
        ["-setsocksfirewallproxystate", "Wi-Fi", "off"],
        ["-setnetworkserviceenabled", "VPN", "off"],
        ["-setairportpower", "en0", "off"]
    ]) func recoveryRunnerRejectsVPNProxyDNSAndRadioDisable(arguments: [String]) async {
        do {
            _ = try await ProcessNetworkSetupCommandRunner().run(arguments: arguments)
            Issue.record("Policy mutation must be rejected before launching networksetup")
        } catch { #expect(error as? NetworkSetupCommandRunnerError == .unsupportedOperation) }
    }

    @Test func lateHealthReplyCannotRestartStoppedGuard() async throws {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let probe = SuspendedInternetProbe()
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(preferredSSIDs: ["Phone Hotspot"]),
            recoverer: RecordingVisibleNetworkRecoverer(visibleSSID: "Phone Hotspot"),
            pathMonitorFactory: { monitor }, internetProbe: probe, healthCheckInterval: 100)
        await controller.start(); monitor.emit(.satisfied)
        for _ in 0..<100 where !(await probe.started) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.started)
        await controller.stop()
        await probe.finish()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await controller.snapshot.phase == .stopped)
        #expect(!(await controller.snapshot.isNetworkAvailable))
    }

    @Test func linkedButUnusableWiFiTriggersHotspotRecoveryAndHealthRecovery() async throws {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: "Office Wi-Fi")
        let probe = MutableInternetProbe(false)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(preferredSSIDs: ["Phone Hotspot"], consecutiveFailureThreshold: 1),
            recoverer: recoverer, pathMonitorFactory: { monitor }, internetProbe: probe, healthCheckInterval: 0.02)
        await controller.start()
        monitor.emit(.satisfied)
        for _ in 0..<100 where await recoverer.reconnectCount() == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await recoverer.reconnectCount() == 1)
        #expect(await controller.snapshot.isNetworkAvailable == false)
        await probe.set(true)
        for _ in 0..<100 where await controller.snapshot.isNetworkAvailable == false { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await controller.snapshot.phase == .monitoring)
        await controller.stop()
    }

    @Test func healthyWiFiDoesNotSwitchNetworksAndStopEndsProbing() async throws {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: "Office Wi-Fi")
        let probe = MutableInternetProbe(true)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(preferredSSIDs: ["Phone Hotspot"]),
            recoverer: recoverer, pathMonitorFactory: { monitor }, internetProbe: probe, healthCheckInterval: 0.02)
        await controller.start(); monitor.emit(.satisfied)
        for _ in 0..<100 where await controller.snapshot.isNetworkAvailable == false { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await recoverer.reconnectCount() == 0)
        await controller.stop()
        let calls = await probe.calls
        try await Task.sleep(for: .milliseconds(70))
        #expect(await probe.calls == calls)
        #expect(await controller.snapshot.phase == .stopped)
    }

    @Test func targetAlreadyAssociatedWaitsForVPNWithoutRepeatedRadioJoins() async throws {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: "Phone Hotspot")
        let probe = MutableInternetProbe(false)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(preferredSSIDs: ["Phone Hotspot"], consecutiveFailureThreshold: 1,
                baseRetryDelay: 0.02, maximumRetryDelay: 0.02, minimumReconnectInterval: 0),
            recoverer: recoverer, pathMonitorFactory: { monitor }, internetProbe: probe, healthCheckInterval: 0.01)
        await controller.start(); monitor.emit(.satisfied)
        for _ in 0..<100 where await controller.snapshot.reconnectAttempt < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await controller.snapshot.reconnectAttempt >= 2)
        #expect(await recoverer.reconnectCount() == 0)
        await probe.set(true)
        for _ in 0..<100 where await controller.snapshot.isNetworkAvailable == false { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await controller.snapshot.isNetworkAvailable)
        await controller.stop()
    }

    @Test func captivePortalOrServerErrorsAreNotInternetSuccess() {
        #expect(!MacInternetReachabilityProbe.accepts(status: 200, body: Data("Login here".utf8), appleProbe: true))
        #expect(!MacInternetReachabilityProbe.accepts(status: 302, body: Data(), appleProbe: false))
        #expect(!MacInternetReachabilityProbe.accepts(status: 500, body: Data(), appleProbe: false))
        #expect(MacInternetReachabilityProbe.accepts(status: 204, body: Data(), appleProbe: false))
    }

    @Test
    func backgroundFailureAssociatesWithoutReissuingNetworksetup() async throws {
        let runner = StubNetworkSetupCommandRunner(
            connectionStatuses: [0, 0],
            connectionStandardOutputs: ["Could not find network Phone Hotspot.", ""]
        )
        let activator = RecordingBackgroundActivator()
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: runner, backgroundHotspotActivator: activator)
        #expect(try await recoverer.reconnectSavedNetwork(
            preferredSSIDs: ["Unsaved Phone", "Phone Hotspot"], lastGoodSSID: nil
        ) == "Phone Hotspot")
        #expect(await activator.targets == ["Phone Hotspot"])
        #expect(await runner.argumentsLog().filter { $0.first == "-setairportnetwork" }.count == 1)
    }

    @Test
    func explicitStartFallsBackAfterHeadlessHotspotFailure() async throws {
        let connector = RecordingInstantHotspotConnector()
        let activator = RecordingBackgroundActivator(failures: 1)
        let recoverer = NetworkSetupSavedWiFiRecoverer(
            commandRunner: StubNetworkSetupCommandRunner(connectionStatuses: [1]),
            backgroundHotspotActivator: activator)
        let result = try await recoverer.reconnectSavedNetwork(
            preferredSSIDs: ["Phone Hotspot"], lastGoodSSID: nil,
            instantHotspotConnector: connector)
        #expect(result == "Phone Hotspot")
        #expect(await activator.targets == ["Phone Hotspot"])
        #expect(await connector.targets == ["Phone Hotspot"])
    }

    @Test
    func backgroundActivationNeverRunsForUnsavedOrUnconfiguredTargets() async {
        let activator = RecordingBackgroundActivator()
        let recoverer = NetworkSetupSavedWiFiRecoverer(
            commandRunner: StubNetworkSetupCommandRunner(connectionStatuses: [1]),
            backgroundHotspotActivator: activator
        )
        _ = try? await recoverer.reconnectSavedNetwork(preferredSSIDs: ["Unsaved"], lastGoodSSID: nil)
        _ = try? await recoverer.reconnectSavedNetwork(preferredSSIDs: [], lastGoodSSID: "Phone Hotspot")
        #expect(await activator.targets.isEmpty)
    }

    @Test
    func unavailablePhoneCanReturnOnALaterBackgroundAttempt() async throws {
        let runner = StubNetworkSetupCommandRunner(connectionStatuses: [1, 1, 0])
        let activator = RecordingBackgroundActivator(failures: 1)
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: runner, backgroundHotspotActivator: activator)
        do {
            _ = try await recoverer.reconnectSavedNetwork(preferredSSIDs: ["Phone Hotspot"], lastGoodSSID: nil)
            Issue.record("Phone absence must remain a failed attempt")
        } catch { #expect(error as? MacBackgroundHotspotError == .unavailable) }
        #expect(try await recoverer.reconnectSavedNetwork(preferredSSIDs: ["Phone Hotspot"], lastGoodSSID: nil) == "Phone Hotspot")
        #expect(await activator.targets.count == 2)
    }

    @Test(arguments: [false, true])
    func recoveryOrStopCancelsWaitingBackgroundActivation(stop: Bool) async throws {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let activator = SuspendedBackgroundActivator()
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(preferredSSIDs: ["Phone Hotspot"], consecutiveFailureThreshold: 1),
            recoverer: NetworkSetupSavedWiFiRecoverer(
                commandRunner: StubNetworkSetupCommandRunner(connectionStatuses: [1]),
                backgroundHotspotActivator: activator
            ), pathMonitorFactory: { monitor }
        )
        await controller.start()
        monitor.emit(.unavailable)
        for _ in 0..<100 where !(await activator.started) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await activator.started)
        if stop { await controller.stop() } else { monitor.emit(.satisfied) }
        for _ in 0..<100 where !(await activator.cancelled) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await activator.cancelled)
        #expect(await controller.snapshot.phase == (stop ? .stopped : .monitoring))
        await controller.stop()
    }

    @Test
    func explicitSystemHotspotFallbackOnlyReceivesSavedAllowlistedTarget() async throws {
        let runner = StubNetworkSetupCommandRunner(
            connectionStandardOutputs: ["Could not find network Phone Hotspot."]
        )
        let connector = RecordingInstantHotspotConnector()
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: runner)
        let result = try await recoverer.reconnectSavedNetwork(
            preferredSSIDs: ["Unsaved Phone", "Phone Hotspot"], lastGoodSSID: nil,
            instantHotspotConnector: connector
        )
        #expect(result == "Phone Hotspot")
        #expect(await connector.targets == ["Phone Hotspot"])
    }

    @Test
    func successfulWiFiJoinDoesNotOpenSystemSettings() async throws {
        let connector = RecordingInstantHotspotConnector()
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: StubNetworkSetupCommandRunner())
        _ = try await recoverer.reconnectSavedNetwork(
            preferredSSIDs: ["Phone Hotspot"], lastGoodSSID: nil,
            instantHotspotConnector: connector
        )
        #expect(await connector.targets.isEmpty)
    }

    @Test
    func unsavedTargetNeverInvokesSystemHotspotFallback() async {
        let connector = RecordingInstantHotspotConnector()
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: StubNetworkSetupCommandRunner())
        do {
            _ = try await recoverer.reconnectSavedNetwork(
                preferredSSIDs: ["Unsaved Phone"], lastGoodSSID: nil,
                instantHotspotConnector: connector
            )
            Issue.record("Unsaved hotspot should fail")
        } catch {
            #expect(error as? SavedWiFiNetworkRecoveryError == .noAllowedSavedNetwork)
        }
        #expect(await connector.targets.isEmpty)
    }

    @Test
    func stateMachineConfirmsFailuresBeforeFirstReconnect() {
        let policy = AutomaticNetworkRecoveryPolicy(
            consecutiveFailureThreshold: 3,
            failureConfirmationInterval: 5,
            baseRetryDelay: 10,
            maximumRetryDelay: 40,
            minimumReconnectInterval: 0
        )
        var machine = AutomaticNetworkRecoveryStateMachine(policy: policy)
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(machine.start() == [.cancelScheduledWork, .cancelReconnect])
        #expect(machine.observePath(.unavailable, now: start) == [
            .cancelScheduledWork,
            .schedule(timer: .confirmFailure, after: 5)
        ])
        #expect(machine.snapshot.phase == .confirmingFailure)
        #expect(machine.snapshot.consecutiveFailures == 1)

        #expect(machine.timerFired(.confirmFailure, now: start.addingTimeInterval(5)) == [
            .schedule(timer: .confirmFailure, after: 5)
        ])
        #expect(machine.snapshot.consecutiveFailures == 2)

        #expect(machine.timerFired(.confirmFailure, now: start.addingTimeInterval(10)) == [
            .cancelScheduledWork,
            .reconnect
        ])
        #expect(machine.snapshot.phase == .reconnecting)
        #expect(machine.snapshot.reconnectAttempt == 1)
    }

    @Test
    func failedReconnectsUseExponentialBackoffAndMaximumDelay() {
        let policy = AutomaticNetworkRecoveryPolicy(
            consecutiveFailureThreshold: 1,
            failureConfirmationInterval: 0,
            baseRetryDelay: 10,
            maximumRetryDelay: 25,
            minimumReconnectInterval: 0
        )
        var machine = AutomaticNetworkRecoveryStateMachine(policy: policy)
        let start = Date(timeIntervalSince1970: 2_000)
        _ = machine.start()

        #expect(machine.observePath(.unavailable, now: start) == [
            .cancelScheduledWork,
            .reconnect
        ])
        #expect(machine.reconnectCompleted(
            attemptedSSID: nil,
            errorDescription: "offline",
            now: start
        ) == [.schedule(timer: .retry, after: 10)])

        #expect(machine.timerFired(.retry, now: start.addingTimeInterval(10)) == [
            .cancelScheduledWork,
            .reconnect
        ])
        #expect(machine.reconnectCompleted(
            attemptedSSID: nil,
            errorDescription: "offline",
            now: start.addingTimeInterval(10)
        ) == [.schedule(timer: .retry, after: 20)])

        #expect(machine.timerFired(.retry, now: start.addingTimeInterval(30)) == [
            .cancelScheduledWork,
            .reconnect
        ])
        #expect(machine.reconnectCompleted(
            attemptedSSID: nil,
            errorDescription: "offline",
            now: start.addingTimeInterval(30)
        ) == [.schedule(timer: .retry, after: 25)])
        #expect(machine.snapshot.reconnectAttempt == 3)
        #expect(machine.snapshot.phase == .backingOff)
    }

    @Test
    func reconnectCooldownSurvivesAPathFlap() {
        let policy = AutomaticNetworkRecoveryPolicy(
            consecutiveFailureThreshold: 1,
            failureConfirmationInterval: 0,
            baseRetryDelay: 5,
            maximumRetryDelay: 60,
            minimumReconnectInterval: 30
        )
        var machine = AutomaticNetworkRecoveryStateMachine(policy: policy)
        let start = Date(timeIntervalSince1970: 3_000)
        _ = machine.start()

        _ = machine.observePath(.unavailable, now: start)
        _ = machine.reconnectCompleted(
            attemptedSSID: "Phone Hotspot",
            errorDescription: nil,
            now: start
        )
        #expect(machine.observePath(.satisfied, now: start.addingTimeInterval(1)) == [
            .cancelScheduledWork,
            .cancelReconnect
        ])

        #expect(machine.observePath(.unavailable, now: start.addingTimeInterval(2)) == [
            .schedule(timer: .retry, after: 28)
        ])
        #expect(machine.snapshot.phase == .backingOff)
        #expect(machine.snapshot.reconnectAttempt == 0)
    }

    @Test
    func duplicateUnavailableEventsDoNotDefeatDebounce() {
        let policy = AutomaticNetworkRecoveryPolicy(
            consecutiveFailureThreshold: 2,
            failureConfirmationInterval: 7
        )
        var machine = AutomaticNetworkRecoveryStateMachine(policy: policy)
        let start = Date(timeIntervalSince1970: 4_000)
        _ = machine.start()

        _ = machine.observePath(.unavailable, now: start)
        #expect(machine.observePath(.unavailable, now: start.addingTimeInterval(1)).isEmpty)
        #expect(machine.snapshot.consecutiveFailures == 1)
        #expect(machine.snapshot.nextActionAt == start.addingTimeInterval(7))
    }

    @Test
    func satisfiedPathResetsFailuresAndLearnsLastGoodOnlyWhileConnected() {
        var machine = AutomaticNetworkRecoveryStateMachine(policy: .init(
            initialLastGoodSSID: "Initial Wi-Fi",
            consecutiveFailureThreshold: 1
        ))
        let start = Date(timeIntervalSince1970: 5_000)
        _ = machine.start()
        _ = machine.observePath(.unavailable, now: start)

        machine.recordLastGoodSSID("Must Not Replace")
        #expect(machine.snapshot.lastGoodSSID == "Initial Wi-Fi")

        _ = machine.observePath(.satisfied, now: start.addingTimeInterval(1))
        machine.recordLastGoodSSID("Office Wi-Fi")
        #expect(machine.snapshot.lastGoodSSID == "Office Wi-Fi")
        #expect(machine.snapshot.consecutiveFailures == 0)
        #expect(machine.snapshot.reconnectAttempt == 0)
        #expect(machine.snapshot.lastError == nil)
    }

    @Test
    func parserFindsDynamicWiFiInterface() {
        let output = """
        Hardware Port: Ethernet
        Device: en0

        Hardware Port: Wi-Fi
        Device: en9
        """

        #expect(NetworkSetupSavedWiFiRecoverer.parseWiFiInterface(output) == "en9")
    }

    @Test
    func reconnectUsesOnlySavedAllowlistedSSIDAndNeverPassesAPassword() async throws {
        let runner = StubNetworkSetupCommandRunner()
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: runner)

        let connectedSSID = try await recoverer.reconnectSavedNetwork(
            preferredSSIDs: ["Unknown Network", "Phone Hotspot"],
            lastGoodSSID: "Office Wi-Fi"
        )

        #expect(connectedSSID == "Phone Hotspot")
        let calls = await runner.argumentsLog()
        #expect(calls == [
            ["-listallhardwareports"],
            ["-listpreferredwirelessnetworks", "en7"],
            ["-setairportpower", "en7", "on"],
            ["-setairportnetwork", "en7", "Phone Hotspot"]
        ])
        #expect(calls.last?.count == 3)
    }

    @Test
    func lastGoodCandidateIsUsedOnlyWhenItIsSaved() async throws {
        let runner = StubNetworkSetupCommandRunner()
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: runner)

        let connectedSSID = try await recoverer.reconnectSavedNetwork(
            preferredSSIDs: [],
            lastGoodSSID: "Office Wi-Fi"
        )

        #expect(connectedSSID == "Office Wi-Fi")
        let calls = await runner.argumentsLog()
        #expect(calls.last == ["-setairportnetwork", "en7", "Office Wi-Fi"])
    }

    @Test
    func zeroExitWithCouldNotFindDiagnosticIsAConnectionFailure() async {
        let runner = StubNetworkSetupCommandRunner(
            connectionStatuses: [0],
            connectionStandardOutputs: ["Could not find network Phone Hotspot.\n"]
        )
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: runner)
        var capturedError: SavedWiFiNetworkRecoveryError?

        do {
            _ = try await recoverer.reconnectSavedNetwork(
                preferredSSIDs: ["Phone Hotspot"],
                lastGoodSSID: nil
            )
        } catch let error as SavedWiFiNetworkRecoveryError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(capturedError == .allCandidatesFailed)
    }

    @Test
    func zeroExitFailureDiagnosticFallsThroughToTheNextSavedCandidate() async throws {
        let runner = StubNetworkSetupCommandRunner(
            connectionStatuses: [0, 0],
            connectionStandardOutputs: [
                "Could not find network Phone Hotspot.",
                ""
            ]
        )
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: runner)

        let connectedSSID = try await recoverer.reconnectSavedNetwork(
            preferredSSIDs: ["Phone Hotspot"],
            lastGoodSSID: "Office Wi-Fi"
        )

        #expect(connectedSSID == "Office Wi-Fi")
        let calls = await runner.argumentsLog()
        #expect(Array(calls.suffix(2)) == [
            ["-setairportnetwork", "en7", "Phone Hotspot"],
            ["-setairportnetwork", "en7", "Office Wi-Fi"]
        ])
    }

    @Test
    func unknownUnsavedCandidateNeverRunsSetAirportNetwork() async {
        let runner = StubNetworkSetupCommandRunner()
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: runner)
        var capturedError: SavedWiFiNetworkRecoveryError?

        do {
            _ = try await recoverer.reconnectSavedNetwork(
                preferredSSIDs: ["Unsaved Network"],
                lastGoodSSID: nil
            )
        } catch let error as SavedWiFiNetworkRecoveryError {
            capturedError = error
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(capturedError == .noAllowedSavedNetwork)
        let calls = await runner.argumentsLog()
        #expect(!calls.contains { $0.first == "-setairportnetwork" })
    }

    @Test
    func visibleCurrentNetworkIsReportedEvenWhenItIsNotSaved() async throws {
        let runner = StubNetworkSetupCommandRunner(
            currentNetworkOutput: "Current Wi-Fi Network: Cafe Wi-Fi"
        )
        let recoverer = NetworkSetupSavedWiFiRecoverer(commandRunner: runner)

        #expect(try await recoverer.visibleCurrentNetwork() == "Cafe Wi-Fi")
    }

    @Test
    func hiddenSSIDOnExpensiveWiFiIsAcceptedAsPotentialMobileHotspot() async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: nil)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"],
                consecutiveFailureThreshold: 1,
                failureConfirmationInterval: 0,
                minimumReconnectInterval: 0,
                requiresPreferredSSID: true
            ),
            recoverer: recoverer,
            pathMonitorFactory: { monitor }
        )
        await controller.start()

        monitor.emit(AutomaticNetworkPathState(
            isSatisfied: true,
            isExpensive: true
        ))
        for _ in 0..<100 where !(await controller.snapshot.isNetworkAvailable) {
            await Task.yield()
        }

        #expect(await controller.snapshot.phase == .monitoring)
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await recoverer.reconnectCount() == 0)
        await controller.stop()
    }

    @Test
    func hiddenSSIDOnConstrainedWiFiIsAcceptedAsPotentialMobileHotspot() async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: nil)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"],
                consecutiveFailureThreshold: 1,
                failureConfirmationInterval: 0,
                minimumReconnectInterval: 0,
                requiresPreferredSSID: true
            ),
            recoverer: recoverer,
            pathMonitorFactory: { monitor }
        )
        await controller.start()

        monitor.emit(AutomaticNetworkPathState(
            isSatisfied: true,
            isConstrained: true
        ))
        for _ in 0..<100 where !(await controller.snapshot.isNetworkAvailable) {
            await Task.yield()
        }

        #expect(await controller.snapshot.phase == .monitoring)
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await recoverer.reconnectCount() == 0)
        await controller.stop()
    }

    @Test
    func hiddenSSIDOnOrdinaryWiFiRemainsHealthyUnderStrictTargetPolicy() async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: nil)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"],
                consecutiveFailureThreshold: 1,
                failureConfirmationInterval: 0,
                minimumReconnectInterval: 0,
                requiresPreferredSSID: true
            ),
            recoverer: recoverer,
            pathMonitorFactory: { monitor }
        )
        await controller.start()

        monitor.emit(.satisfied)
        for _ in 0..<100 where !(await controller.snapshot.isNetworkAvailable) {
            await Task.yield()
        }

        #expect(await controller.snapshot.phase == .monitoring)
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await recoverer.reconnectCount() == 0)
        await controller.stop()
    }

    @Test(arguments: [Optional<String>.none, Optional("Office Wi-Fi")])
    func explicitHotspotSessionRetriesEvenWhenOtherWiFiIsHealthy(ssid: String?) async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: ssid)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"], consecutiveFailureThreshold: 1,
                minimumReconnectInterval: 0, requiresPreferredSSID: true,
                prefersTargetOverHealthyNetwork: true
            ),
            recoverer: recoverer, pathMonitorFactory: { monitor }
        )
        await controller.start()
        monitor.emit(.satisfied)
        for _ in 0..<200 where await recoverer.reconnectCount() == 0 { await Task.yield() }
        #expect(await recoverer.reconnectCount() == 1)
        #expect(!(await controller.snapshot.isNetworkAvailable))
        #expect(await controller.snapshot.lastGoodSSID == nil)
        await controller.stop()
    }

    @Test
    func explicitHotspotSessionPreservesHiddenMobilePathWithoutRejoining() async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: nil)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"], consecutiveFailureThreshold: 1,
                requiresPreferredSSID: true, prefersTargetOverHealthyNetwork: true
            ),
            recoverer: recoverer, pathMonitorFactory: { monitor }
        )
        await controller.start()
        monitor.emit(.init(isSatisfied: true, isExpensive: true))
        for _ in 0..<200 where !(await controller.snapshot.isNetworkAvailable) { await Task.yield() }
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await recoverer.reconnectCount() == 0)
        await controller.stop()
    }

    @Test
    func hiddenSSIDOnOrdinaryWiFiRemainsHealthyWithoutStrictTargetPolicy() async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: nil)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"],
                consecutiveFailureThreshold: 1,
                failureConfirmationInterval: 0,
                minimumReconnectInterval: 0,
                requiresPreferredSSID: false
            ),
            recoverer: recoverer,
            pathMonitorFactory: { monitor }
        )
        await controller.start()

        monitor.emit(.satisfied)
        for _ in 0..<100 where !(await controller.snapshot.isNetworkAvailable) {
            await Task.yield()
        }

        #expect(await controller.snapshot.phase == .monitoring)
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await recoverer.reconnectCount() == 0)
        await controller.stop()
    }

    @Test
    func visiblePreferredSSIDIsAcceptedWithoutMobileHotspotHint() async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(
            visibleSSID: "Phone Hotspot"
        )
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"],
                consecutiveFailureThreshold: 1,
                failureConfirmationInterval: 0,
                minimumReconnectInterval: 0,
                requiresPreferredSSID: true
            ),
            recoverer: recoverer,
            pathMonitorFactory: { monitor }
        )
        await controller.start()

        monitor.emit(.satisfied)
        for _ in 0..<100 where !(await controller.snapshot.isNetworkAvailable) {
            await Task.yield()
        }

        #expect(await controller.snapshot.phase == .monitoring)
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await controller.snapshot.lastGoodSSID == "Phone Hotspot")
        #expect(await recoverer.reconnectCount() == 0)
        await controller.stop()
    }

    @Test
    func visibleNonTargetRemainsHealthyEvenWithMobileHotspotHint() async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: "Office Wi-Fi")
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"],
                consecutiveFailureThreshold: 1,
                failureConfirmationInterval: 0,
                minimumReconnectInterval: 0,
                requiresPreferredSSID: true
            ),
            recoverer: recoverer,
            pathMonitorFactory: { monitor }
        )
        await controller.start()

        monitor.emit(AutomaticNetworkPathState(
            isSatisfied: true,
            isExpensive: true
        ))
        for _ in 0..<100 where !(await controller.snapshot.isNetworkAvailable) {
            await Task.yield()
        }

        #expect(await controller.snapshot.phase == .monitoring)
        #expect(await controller.snapshot.isNetworkAvailable)
        #expect(await controller.snapshot.lastGoodSSID == nil)
        #expect(await recoverer.reconnectCount() == 0)
        await controller.stop()
    }

    @Test
    func unavailableWiFiPathReconnectsAllowlistedTarget() async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = RecordingVisibleNetworkRecoverer(visibleSSID: nil)
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"],
                consecutiveFailureThreshold: 1,
                failureConfirmationInterval: 0,
                minimumReconnectInterval: 0,
                requiresPreferredSSID: true
            ),
            recoverer: recoverer,
            pathMonitorFactory: { monitor }
        )
        await controller.start()

        monitor.emit(.unavailable)
        for _ in 0..<100 where await recoverer.reconnectCount() == 0 {
            await Task.yield()
        }

        #expect(await controller.snapshot.isNetworkAvailable == false)
        #expect(await recoverer.reconnectCount() == 1)
        await controller.stop()
    }

    @Test
    func staleSatisfiedSSIDLookupCannotOverrideANewerDisconnect() async {
        let monitor = ControllableAutomaticNetworkPathMonitor()
        let recoverer = SuspendedActiveNetworkRecoverer()
        let controller = AutomaticNetworkRecoveryController(
            policy: AutomaticNetworkRecoveryPolicy(
                preferredSSIDs: ["Phone Hotspot"],
                consecutiveFailureThreshold: 2,
                failureConfirmationInterval: 3_600,
                requiresPreferredSSID: true
            ),
            recoverer: recoverer,
            pathMonitorFactory: { monitor }
        )
        await controller.start()

        monitor.emit(.satisfied)
        for _ in 0..<100 {
            if await recoverer.hasPendingActiveLookup() {
                break
            }
            await Task.yield()
        }
        #expect(await recoverer.hasPendingActiveLookup())

        monitor.emit(.unavailable)
        for _ in 0..<100 {
            if await controller.snapshot.phase == .confirmingFailure {
                break
            }
            await Task.yield()
        }
        #expect(await controller.snapshot.phase == .confirmingFailure)

        await recoverer.resumeActiveLookup(with: "Phone Hotspot")
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(await controller.snapshot.phase == .confirmingFailure)
        await controller.stop()
    }
}

private actor RecordingInstantHotspotConnector: MacInstantHotspotConnecting {
    private(set) var targets: [String] = []
    func connect(ssid: String) async throws { targets.append(ssid) }
}

private final class ControllableAutomaticNetworkPathMonitor:
    AutomaticNetworkPathMonitoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var updateHandler: (@Sendable (AutomaticNetworkPathState) -> Void)?

    func start(
        queue: DispatchQueue,
        updateHandler: @escaping @Sendable (AutomaticNetworkPathState) -> Void
    ) {
        lock.lock()
        self.updateHandler = updateHandler
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        updateHandler = nil
        lock.unlock()
    }

    func emit(_ state: AutomaticNetworkPathState) {
        lock.lock()
        let handler = updateHandler
        lock.unlock()
        handler?(state)
    }
}

private actor SuspendedActiveNetworkRecoverer: SavedWiFiNetworkRecovering {
    private var activeLookupContinuation: CheckedContinuation<String?, Never>?

    func visibleCurrentNetwork() async throws -> String? {
        await withCheckedContinuation { continuation in
            activeLookupContinuation = continuation
        }
    }

    func reconnectSavedNetwork(
        preferredSSIDs: [String],
        lastGoodSSID: String?
    ) async throws -> String {
        preferredSSIDs[0]
    }

    func hasPendingActiveLookup() -> Bool {
        activeLookupContinuation != nil
    }

    func resumeActiveLookup(with ssid: String?) {
        activeLookupContinuation?.resume(returning: ssid)
        activeLookupContinuation = nil
    }
}

private actor RecordingVisibleNetworkRecoverer: SavedWiFiNetworkRecovering {
    private let visibleSSID: String?
    private var recordedReconnectCount = 0
    private(set) var lookupCount = 0

    init(visibleSSID: String?) {
        self.visibleSSID = visibleSSID
    }

    func visibleCurrentNetwork() async throws -> String? {
        lookupCount += 1
        return visibleSSID
    }

    func reconnectSavedNetwork(
        preferredSSIDs: [String],
        lastGoodSSID: String?
    ) async throws -> String {
        recordedReconnectCount += 1
        return preferredSSIDs[0]
    }

    func reconnectCount() -> Int {
        recordedReconnectCount
    }
}

private actor RecordingBackgroundActivator: MacBackgroundHotspotActivating {
    private(set) var targets: [String] = []
    var failures: Int
    init(failures: Int = 0) { self.failures = failures }
    func activate(ssid: String) async throws {
        targets.append(ssid)
        if failures > 0 { failures -= 1; throw MacBackgroundHotspotError.unavailable }
    }
}

private actor SuspendedBackgroundActivator: MacBackgroundHotspotActivating {
    private(set) var started = false
    private(set) var cancelled = false
    func activate(ssid: String) async throws {
        started = true
        do { try await Task.sleep(for: .seconds(100)) }
        catch { cancelled = true; throw error }
    }
}

private actor MutableInternetProbe: MacInternetReachabilityProbing {
    var success: Bool
    private(set) var calls = 0
    init(_ success: Bool) { self.success = success }
    func set(_ success: Bool) { self.success = success }
    func isInternetReachable() async -> Bool { calls += 1; return success }
}

private actor SuspendedInternetProbe: MacInternetReachabilityProbing {
    private var reply: CheckedContinuation<Bool, Never>?
    private(set) var started = false
    func isInternetReachable() async -> Bool {
        started = true
        return await withCheckedContinuation { reply = $0 }
    }
    func finish() { reply?.resume(returning: true); reply = nil }
}
