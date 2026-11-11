@testable import CodexMobilityMacFeature
import Combine
import CodexMobilityCore
import Foundation
import Testing

@Suite("Configurable closed-lid session")
@MainActor
struct MacClosedLidSessionControllerTests {
    @Test(arguments: [0.0, 28_800.0, 43_200.0, 86_400.0])
    func extendedSessionHasLogicalDeadlineAndRenewsBoundedWatchdog(seconds: Double) async throws {
        let f = try makeFixture(preferredSSIDs: ["Example Hotspot"], activeSSID: "Example Hotspot")
        defer { f.cleanup() }
        #expect(f.controller.setDuration(seconds))
        await f.controller.setEnabled(true, mobileOffice: true)
        #expect(f.controller.phase == .active)
        let deadline: Date? = seconds == 0 ? nil : f.now.addingTimeInterval(seconds)
        #expect(f.controller.expiresAt == deadline)
        #expect(f.store.mode.expiresAt == deadline)
        #expect(f.powerStore.activeClosedLidLease?.expiresAt == f.now.addingTimeInterval(7200))
        f.store.updatePolicy(f.store.mode.policy, now: f.now.addingTimeInterval(300))
        #expect(f.store.mode.expiresAt == deadline)
        await f.controller.renewLeaseIfNeeded(at: f.now.addingTimeInterval(3600))
        #expect(f.powerStore.activeClosedLidLease?.expiresAt == f.now.addingTimeInterval(10800))
        #expect(await f.powerBackend.events() == ["begin", "renew"])
        if seconds > 0 {
            f.store.refreshNow(now: f.now.addingTimeInterval(seconds))
            for _ in 0..<200 where f.controller.phase != .off { await Task.yield() }
            #expect(f.controller.phase == .off)
        } else {
            f.store.refreshNow(now: f.now.addingTimeInterval(100_000))
            #expect(f.store.mode.isEnabled)
            await f.controller.stop()
        }
        #expect(await f.powerBackend.events() == ["begin", "renew", "end"])
    }

    @Test func mobileOfficeStartsCaffeineAndSafetyStopReleasesIt() async throws {
        let name = "mobile-caffeine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let runner = MobileOfficeTestCaffeineRunner()
        let caffeine = MacCaffeineController(runner: runner, defaults: defaults)
        let f = try makeFixture(preferredSSIDs: ["Example Hotspot"], caffeineController: caffeine,
                                activeSSID: "Example Hotspot")
        defer { f.cleanup(); caffeine.stop() }
        _ = f.controller.setDuration(0)
        await f.controller.setEnabled(true, mobileOffice: true)
        #expect(caffeine.isActive && caffeine.isManagedByMobileOffice)
        #expect(runner.timeout == nil)
        f.store.stop(reason: "thermal test")
        for _ in 0..<200 where f.controller.phase != .off { await Task.yield() }
        #expect(!caffeine.isActive && !runner.running)
    }

    @Test func failedRenewalStopsUnlimitedSessionAndRestoresBaseline() async throws {
        let f = try makeFixture(preferredSSIDs: ["Example Hotspot"], activeSSID: "Example Hotspot")
        defer { f.cleanup() }
        _ = f.controller.setDuration(0)
        await f.controller.setEnabled(true, mobileOffice: true)
        await f.powerBackend.setRenewShouldFail()
        await f.controller.renewLeaseIfNeeded(at: f.now.addingTimeInterval(3600))
        for _ in 0..<200 where f.controller.phase != .off { await Task.yield() }
        #expect(f.controller.phase == .off)
        #expect(!f.store.mode.isEnabled)
        #expect(await f.powerBackend.isSleepDisabled() == false)
    }

    @Test func mobileOfficeStartsOfflineWithoutWaitingForHotspotVerification() async throws {
        let name = "mobile-office-offline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let desktop = MacAgentDesktopController(checker: TestAgentDesktopChecker(),
            displayKeeper: TestAgentDisplayKeeper(), defaults: defaults)
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"],
            agentDesktopController: desktop, networkConnected: false,
            reconnectRestoresNetwork: false, hotspotVerificationAttempts: 5,
            hotspotVerificationDelay: 0.1)
        defer { fixture.cleanup() }
        let clock = ContinuousClock()
        let started = clock.now
        await fixture.controller.setEnabled(true, mobileOffice: true)
        print("MOBILITY_START offline_mock=\(started.duration(to: clock.now))")
        #expect(fixture.controller.phase == .active)
        #expect(!fixture.controller.isBusy)
        #expect(fixture.store.mode.phase == .degraded)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)
        #expect(await fixture.powerBackend.networkAvailabilityAtBegin() == [false])
        await fixture.controller.stop()
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test func mobileOfficePublishesActiveBeforeRemoteCheckReturnsAndIgnoresLateResult() async throws {
        let name = "mobile-office-remote-delay.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let desktop = MacAgentDesktopController(checker: TestAgentDesktopChecker(),
            displayKeeper: TestAgentDisplayKeeper(), defaults: defaults)
        let checker = PausedStartupRemoteChecker()
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"],
            agentDesktopController: desktop, activeSSID: "Office Wi-Fi",
            remoteControlChecker: checker)
        defer { fixture.cleanup() }
        var completed = false
        let start = Task { @MainActor in
            await fixture.controller.setEnabled(true, mobileOffice: true)
            completed = true
        }
        for _ in 0..<200 where !(await checker.isWaiting) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await checker.isWaiting)
        #expect(completed)
        #expect(fixture.controller.phase == .active)
        #expect(fixture.controller.remoteControlReadiness != .connected)
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)
        await fixture.controller.stop()
        await checker.resume()
        await start.value
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.controller.phase == .off)
        #expect(fixture.controller.remoteControlReadiness == .notChecked)
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
    }

    @Test func cancelledRecoveryCannotOverwriteStoppedSessionWithLateOnlineStatus() async throws {
        let checker = PausedSessionRecoveryChecker()
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"], activeSSID: "Example Hotspot",
            remoteControlChecker: checker)
        defer { fixture.cleanup() }
        await fixture.controller.start()
        for _ in 0..<100 { await Task.yield() }
        fixture.hotspotMonitor.emit(AutomaticNetworkPathState(isSatisfied: true))
        for _ in 0..<200 where !(await checker.isWaiting) { await Task.yield() }
        #expect(await checker.isWaiting)
        await fixture.controller.stop()
        await checker.resume()
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.controller.phase == .off)
        #expect(fixture.controller.remoteControlReadiness == .notChecked)
    }

    @Test func mobileOfficeHonorsSavedDesktopProtectionAndDimsOnLidClose() async throws {
        let name = "mobile-office.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let keeper = TestAgentDisplayKeeper()
        let brightness = TestLidBrightnessController()
        let desktop = MacAgentDesktopController(checker: TestAgentDesktopChecker(reason: "password"),
            displayKeeper: keeper, defaults: defaults, brightness: brightness)
        desktop.setEnabled(true)
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"],
            agentDesktopController: desktop, activeSSID: "Example Hotspot")
        defer { fixture.cleanup() }
        await fixture.controller.setEnabled(true, mobileOffice: true)
        #expect(fixture.controller.phase == .active)
        #expect(fixture.controller.isMobileOfficeSession)
        #expect(desktop.isActive && keeper.held)
        #expect(desktop.isEnabled)
        #expect(defaults.bool(forKey: MacAgentDesktopController.preferenceKey))
        desktop.observeLidState(true)
        #expect(brightness.events == ["restore", "prepare", "dim"])
        await fixture.controller.stop()
        #expect(!desktop.isActive && !keeper.held)
        #expect(!fixture.controller.isMobileOfficeSession)
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
        #expect(brightness.events.last == "restore")
    }

    @Test func mobileOfficeWithDesktopProtectionRejectsLockedSessionBeforePowerChanges() async throws {
        let name = "mobile-office-desktop-locked.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let keeper = TestAgentDisplayKeeper()
        let desktop = MacAgentDesktopController(checker: TestAgentDesktopChecker(reason: "locked"),
            displayKeeper: keeper, defaults: defaults)
        desktop.setEnabled(true)
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"],
            agentDesktopController: desktop, activeSSID: "Example Hotspot")
        defer { fixture.cleanup() }
        await fixture.controller.setEnabled(true, mobileOffice: true)
        #expect(fixture.controller.phase == .failed)
        #expect(fixture.controller.lastErrorMessage?.contains("桌面已锁定") == true)
        #expect(await fixture.powerBackend.events().isEmpty)
        #expect(!desktop.isActive && !keeper.held)
    }

    @Test func mobileOfficeBackgroundWorkDoesNotRequireUnlockedDesktop() async throws {
        let name = "mobile-office-locked.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let keeper = TestAgentDisplayKeeper()
        let desktop = MacAgentDesktopController(checker: TestAgentDesktopChecker(reason: "locked"),
            displayKeeper: keeper, defaults: defaults)
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"],
            agentDesktopController: desktop, activeSSID: "Example Hotspot")
        defer { fixture.cleanup() }
        await fixture.controller.setEnabled(true, mobileOffice: true)
        #expect(fixture.controller.phase == .active)
        #expect(fixture.controller.lastErrorMessage == nil)
        #expect(await fixture.powerBackend.events() == ["begin"])
        #expect(!keeper.held)
        await fixture.controller.stop()
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
    }

    @Test func mobileOfficeCanUseWiFiWithoutConfiguredHotspotOrDesktopController() async throws {
        let fixture = try makeFixture(preferredSSIDs: [], activeSSID: "Office Wi-Fi")
        defer { fixture.cleanup() }
        await fixture.controller.setEnabled(true, mobileOffice: true)
        #expect(fixture.controller.phase == .active)
        #expect(fixture.store.isAssertionActive)
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)
        #expect(fixture.controller.lastStartupDuration != nil)
        await fixture.controller.stop()
        #expect(!fixture.store.isAssertionActive)
    }

    @Test func mobileOfficeStillWaitsForPowerLeaseAndCancelsCleanly() async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"], networkConnected: false)
        defer { fixture.cleanup() }
        await fixture.powerBackend.pauseNextBegin()
        let start = Task { await fixture.controller.setEnabled(true, mobileOffice: true) }
        for _ in 0..<200 where !(await fixture.powerBackend.hasPausedBegin()) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await fixture.powerBackend.hasPausedBegin())
        #expect(fixture.controller.phase == .preparing)
        #expect(!fixture.store.isAssertionActive)
        await fixture.controller.setEnabled(false)
        await fixture.powerBackend.resumeBegin()
        await start.value
        #expect(fixture.controller.phase == .off)
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test func agentDesktopProtectionEndsWithSessionExpiry() async throws {
        let name = "agent-desktop-expiry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let keeper = TestAgentDisplayKeeper()
        let desktop = MacAgentDesktopController(checker: TestAgentDesktopChecker(),
            displayKeeper: keeper, defaults: defaults)
        desktop.setEnabled(true)
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"],
            agentDesktopController: desktop, activeSSID: "Example Hotspot")
        defer { fixture.cleanup() }
        await fixture.controller.start()
        #expect(fixture.controller.phase == .active)
        #expect(keeper.held)
        fixture.store.refreshNow(now: fixture.controller.expiresAt!)
        for _ in 0..<200 where fixture.controller.phase != .off { await Task.yield() }
        #expect(!keeper.held)
        #expect(!desktop.isActive)
    }

    @Test func agentDesktopBlocksBeforeChangingPowerPolicy() async throws {
        let name = "agent-desktop-block.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let keeper = TestAgentDisplayKeeper()
        let desktop = MacAgentDesktopController(checker: TestAgentDesktopChecker(reason: "password"),
            displayKeeper: keeper, defaults: defaults)
        desktop.setEnabled(true)
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"],
            agentDesktopController: desktop, activeSSID: "Example Hotspot")
        defer { fixture.cleanup() }
        await fixture.controller.start()
        #expect(fixture.controller.phase == .failed)
        #expect(fixture.controller.lastErrorMessage?.contains("系统立即要求") == true)
        #expect(await fixture.powerBackend.events().isEmpty)
        #expect(!keeper.held)
    }

    @Test(arguments: [900.0, 3_600.0, 14_400.0])
    func selectedDurationControlsLeaseRuntimeAndExpiry(seconds: TimeInterval) async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"], activeSSID: "Example Hotspot")
        defer { fixture.cleanup() }
        #expect(fixture.controller.selectedDuration == 7_200)
        #expect(fixture.controller.setDuration(seconds))
        #expect(fixture.defaults.double(forKey: MacClosedLidSessionController.durationPreferenceKey) == seconds)

        await fixture.controller.start()

        let deadline = fixture.now.addingTimeInterval(seconds)
        #expect(fixture.controller.phase == .active)
        #expect(fixture.controller.expiresAt == deadline)
        #expect(fixture.store.mode.expiresAt == deadline)
        #expect(fixture.powerStore.activeClosedLidLease?.expiresAt == deadline)
        #expect(!fixture.controller.setDuration(1_800))
        #expect(fixture.controller.selectedDuration == seconds)
        fixture.store.refreshNow(now: deadline.addingTimeInterval(-1))
        #expect(fixture.store.mode.isEnabled)
        fixture.store.refreshNow(now: deadline)
        for _ in 0..<200 where fixture.controller.phase != .off { await Task.yield() }
        #expect(fixture.controller.phase == .off)
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
    }

    @Test func temporaryHotspotAssociationFailureDoesNotTurnOffSession() async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"], networkConnected: false)
        defer { fixture.cleanup() }
        await fixture.hotspotRecoverer.setFailure(.associationFailed)
        await fixture.controller.start()
        #expect(fixture.controller.phase == .active)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(fixture.store.mode.phase == .degraded)
        await fixture.controller.stop()
    }

    @Test func timedSessionKeepsRecoveringBelowNormalBatteryThresholdAndWithoutCodex() async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"], activeSSID: "Example Hotspot")
        defer { fixture.cleanup() }
        fixture.sampler.setBatteryLevel(5)
        fixture.sampler.setCodexRunning(false)
        await fixture.controller.start()
        #expect(fixture.controller.phase == .active)
        fixture.sampler.setNetworkConnected(false)
        fixture.store.refreshNow(now: fixture.now.addingTimeInterval(1900))
        #expect(fixture.store.mode.phase == .degraded)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        fixture.sampler.setBatteryLevel(0)
        fixture.store.refreshNow(now: fixture.now.addingTimeInterval(1901))
        #expect(!fixture.store.mode.isEnabled)
        await fixture.controller.stop()
    }

    @Test
    func durationPersistsAcrossControllerRecreationAndRejectsNonFiniteValues() throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"])
        defer { fixture.cleanup() }
        #expect(fixture.controller.setDuration(10))
        #expect(fixture.controller.selectedDuration == 900)
        #expect(fixture.controller.setDuration(90_000))
        #expect(fixture.controller.selectedDuration == 86_400)
        #expect(fixture.controller.setDuration(5_400))
        #expect(!fixture.controller.setDuration(.infinity))
        #expect(!fixture.controller.setDuration(.nan))
        let reloaded = MacClosedLidSessionController(
            store: fixture.store, moduleStore: fixture.moduleStore,
            powerPolicyStore: fixture.powerStore, hotspotStore: fixture.hotspotStore,
            journalDefaults: fixture.defaults
        )
        #expect(reloaded.selectedDuration == 5_400)
        #expect(reloaded.durationLabel == "1 小时 30 分钟")
        #expect(reloaded.phase == .off)
        reloaded.shutdown()
    }

    @Test
    func oneToggleStartsFromAnAlreadyConnectedHotspotWithoutPhonePairing() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            activeSSID: "Example Hotspot"
        )
        defer { fixture.cleanup() }

        await fixture.controller.start()

        #expect(fixture.controller.phase == .active)
        #expect(fixture.controller.isToggleEnabled)
        #expect(fixture.store.mode.phase == .active)
        #expect(fixture.store.mode.profile == .closedLidLabs)
        #expect(
            fixture.store.mode.expiresAt
                == fixture.now.addingTimeInterval(MacClosedLidSessionController.sessionDuration)
        )
        #expect(fixture.moduleStore.isEnabled(.closedLidLabs))
        #expect(fixture.moduleStore.isEnabled(.hotspotAutomation))
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        for _ in 0..<100 where fixture.hotspotStore.snapshot.phase != .monitoring {
            await Task.yield()
        }
        #expect(fixture.hotspotStore.isOperational)
        #expect(fixture.hotspotMonitor.isStarted)
        #expect(await fixture.powerBackend.events() == ["begin"])

        await fixture.controller.stop()

        #expect(fixture.controller.phase == .off)
        #expect(fixture.store.mode.phase == .off)
        #expect(!fixture.store.isAssertionActive)
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(fixture.hotspotStore.snapshot.phase == .stopped)
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test
    func oneToggleJoinsASavedHotspotWithoutPhonePairing() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            networkConnected: false
        )
        defer { fixture.cleanup() }

        await fixture.controller.start()

        #expect(fixture.controller.phase == .active)
        #expect(await fixture.hotspotRecoverer.requests() == [["Example Hotspot"]])
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        for _ in 0..<100 where fixture.hotspotStore.snapshot.phase != .monitoring {
            await Task.yield()
        }
        #expect(fixture.hotspotStore.isOperational)

        await fixture.controller.stop()
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
    }

    @Test
    func privacyHiddenOrdinaryWiFiSwitchesToTheConfiguredHotspotAtStartup() async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"])
        defer { fixture.cleanup() }

        await fixture.controller.start()

        #expect(fixture.controller.phase == .active)
        #expect(fixture.store.mode.phase == .active)
        #expect(await fixture.hotspotRecoverer.requests() == [["Example Hotspot"]])
        #expect(await fixture.powerBackend.events() == ["begin"])

        await fixture.controller.stop()
    }

    @Test
    func visibleHotspotWithoutRouteWaitsWithoutRejoiningBeforeTheSystemLease() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            activeSSID: "Example Hotspot",
            maximumForcedNetworkJoinAttempts: 2,
            networkRetryDelay: 0
        )
        defer { fixture.cleanup() }
        // The configured SSID is visible before DHCP/default-route publication.
        // A local closed-lid request must preserve that association and wait for
        // its route instead of restarting DHCP with another join command.
        fixture.sampler.setUpcomingNetworkSamples([false, false, true])

        await fixture.controller.setEnabled(true)

        #expect(fixture.controller.phase == .active)
        #expect(fixture.controller.isToggleEnabled)
        #expect(fixture.store.mode.phase == .active)
        #expect(fixture.store.lastPreflightBlockers.isEmpty)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)
        #expect(await fixture.powerBackend.events() == ["begin"])
        #expect(await fixture.powerBackend.networkAvailabilityAtBegin() == [true])

        await fixture.controller.stop()
    }

    @Test
    func visibleHotspotWithoutRouteStartsDegradedAndKeepsTheLease() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            activeSSID: "Example Hotspot",
            networkConnected: false,
            reconnectRestoresNetwork: false,
            hotspotVerificationAttempts: 2,
            hotspotVerificationDelay: 0
        )
        defer { fixture.cleanup() }

        await fixture.controller.setEnabled(true)

        #expect(fixture.controller.phase == .active)
        #expect(fixture.controller.lastErrorMessage == nil)
        #expect(fixture.controller.statusMessage.contains("断线守护正在重连"))
        #expect(fixture.store.mode.phase == .degraded)
        #expect(fixture.store.isAssertionActive)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(fixture.controller.requiresSystemPolicyRecovery)
        #expect(await fixture.powerBackend.events() == ["begin"])
        #expect(await fixture.powerBackend.networkAvailabilityAtBegin() == [false])
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)

        await fixture.controller.stop()
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test
    func sustainedOfflinePreflightStartsDegradedAndKeepsReconnectAuthorization() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            activeSSID: "Example Hotspot",
            reconnectRestoresNetwork: false,
            maximumForcedNetworkJoinAttempts: 2,
            networkRetryDelay: 0
        )
        defer { fixture.cleanup() }
        // Hotspot verification succeeds first; the independent mobility
        // preflight then sees a sustained offline state. The timed lease must
        // stay alive so its reconnect controller can recover the route.
        fixture.sampler.setUpcomingNetworkSamples([true, false])

        await fixture.controller.start()

        #expect(fixture.controller.phase == .active)
        #expect(fixture.store.mode.phase == .degraded)
        #expect(fixture.controller.lastErrorMessage == nil)
        #expect(fixture.controller.statusMessage.contains("断线守护正在重连"))
        #expect(fixture.store.lastPreflightBlockers.isEmpty)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)
        #expect(await fixture.powerBackend.events() == ["begin"])

        fixture.store.refreshNow(
            now: fixture.now.addingTimeInterval(
                MobilityPolicy.recommended.networkDisconnectGraceSeconds + 1
            )
        )
        #expect(fixture.controller.phase == .active)
        #expect(fixture.store.mode.phase == .degraded)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)

        await fixture.controller.stop()
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test
    func startupPathDropAfterTheExplicitJoinHandsRecoveryToTheSessionGuard() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            networkConnected: true,
            hotspotVerificationAttempts: 2,
            hotspotVerificationDelay: 0,
            maximumForcedNetworkJoinAttempts: 2,
            networkRetryDelay: 0
        )
        defer { fixture.cleanup() }
        await fixture.powerBackend.pauseNextBegin()
        // The first hidden ordinary Wi-Fi observation triggers the one explicit
        // configured-hotspot join. A later path drop removes both route and
        // visible identity while the administrator lease is prepared. Once the
        // lease exists, startup must not issue a second join; the session-scoped
        // path monitor takes over while the runtime remains degraded.
        let startTask = Task {
            await fixture.controller.setEnabled(true)
        }
        for _ in 0..<100 {
            if await fixture.powerBackend.hasPausedBegin() {
                break
            }
            await Task.yield()
        }
        #expect(await fixture.powerBackend.hasPausedBegin())

        fixture.sampler.setNetworkConnected(false)
        await fixture.hotspotRecoverer.setActiveSSID(nil)
        await fixture.powerBackend.resumeBegin()
        await startTask.value

        #expect(fixture.controller.phase == .active)
        #expect(fixture.store.mode.phase == .degraded)
        #expect(await fixture.hotspotRecoverer.requests() == [["Example Hotspot"]])
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(fixture.controller.statusMessage.contains("断线守护正在重连"))
        #expect(await fixture.powerBackend.events() == ["begin"])

        await fixture.controller.stop()
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test
    func administratorWaitPathDropStartsTheRuntimeDegradedWithoutASecondJoin() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            activeSSID: "Example Hotspot",
            hotspotVerificationAttempts: 2,
            hotspotVerificationDelay: 0,
            maximumForcedNetworkJoinAttempts: 2,
            networkRetryDelay: 0
        )
        defer { fixture.cleanup() }
        await fixture.powerBackend.pauseNextBegin()
        let startTask = Task {
            await fixture.controller.setEnabled(true)
        }
        for _ in 0..<100 {
            if await fixture.powerBackend.hasPausedBegin() {
                break
            }
            await Task.yield()
        }
        #expect(await fixture.powerBackend.hasPausedBegin())

        fixture.sampler.setNetworkConnected(false)
        await fixture.hotspotRecoverer.setActiveSSID(nil)
        await fixture.powerBackend.resumeBegin()
        await startTask.value

        #expect(fixture.controller.phase == .active)
        #expect(fixture.store.mode.phase == .degraded)
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(fixture.controller.statusMessage.contains("断线守护正在重连"))
        #expect(await fixture.powerBackend.events() == ["begin"])

        await fixture.controller.stop()
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test
    func healthyVisibleNonTargetWiFiSwitchesToTheConfiguredHotspotAtStartup() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            activeSSID: "Office Wi-Fi"
        )
        defer { fixture.cleanup() }

        await fixture.controller.setEnabled(true)

        #expect(fixture.controller.phase == .active)
        #expect(fixture.store.mode.phase == .active)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(await fixture.hotspotRecoverer.requests() == [["Example Hotspot"]])
        #expect(await fixture.powerBackend.events() == ["begin"])

        await fixture.controller.stop()
    }

    @Test
    func directPreflightBlockersAreClearedWhenTheStoreStops() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            networkConnected: false
        )
        defer { fixture.cleanup() }

        fixture.store.start(profile: .closedLidLabs)

        #expect(fixture.store.mode.phase == .blocked)
        #expect(fixture.store.lastPreflightBlockers == [.networkUnavailable])

        fixture.store.stop(reason: "测试停止。")

        #expect(fixture.store.mode.phase == .off)
        #expect(fixture.store.lastPreflightBlockers.isEmpty)
    }

    @Test
    func missingHotspotFailsBeforeRequestingAdministratorAuthorization() async throws {
        let fixture = try makeFixture(preferredSSIDs: [])
        defer { fixture.cleanup() }

        await fixture.controller.start()

        #expect(fixture.controller.phase == .failed)
        #expect(fixture.controller.lastErrorMessage?.contains("热点名称") == true)
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(await fixture.powerBackend.events().isEmpty)
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)
    }

    @Test(arguments: [false, true])
    func localSafetyStopAlsoEndsTheSystemLease(mobileOffice: Bool) async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"])
        defer { fixture.cleanup() }
        await fixture.controller.setEnabled(true, mobileOffice: mobileOffice)
        #expect(fixture.controller.phase == .active)

        fixture.store.stop(reason: "测试安全停止。")
        for _ in 0..<50 where fixture.controller.phase != .off {
            await Task.yield()
        }

        #expect(fixture.controller.phase == .off)
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(fixture.hotspotStore.snapshot.phase == .stopped)
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test
    func failedSystemRollbackCanBeRetriedWithoutStartingANewLease() async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"])
        defer { fixture.cleanup() }
        await fixture.controller.start()
        await fixture.powerBackend.setEndShouldFail(true)

        await fixture.controller.stop()

        #expect(fixture.controller.phase == .failed)
        #expect(fixture.controller.requiresSystemPolicyRecovery)
        #expect(!fixture.controller.isToggleEnabled)
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)

        await fixture.powerBackend.setEndShouldFail(false)
        await fixture.controller.retrySystemPolicyRecovery()

        #expect(fixture.controller.phase == .off)
        #expect(!fixture.controller.requiresSystemPolicyRecovery)
        #expect(fixture.controller.isToggleEnabled)
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(await fixture.powerBackend.events() == ["begin", "end", "end"])
    }

    @Test(arguments: [false, true])
    func failedSafetyPreflightAndFailedRollbackPublishBothErrorsAndRemainRecoverable(mobileOffice: Bool) async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            activeSSID: "Example Hotspot",
            maximumForcedNetworkJoinAttempts: 1,
            networkRetryDelay: 0
        )
        defer { fixture.cleanup() }
        fixture.sampler.setBatteryLevel(0)
        await fixture.powerBackend.setEndShouldFail(true)

        await fixture.controller.setEnabled(true, mobileOffice: mobileOffice)

        #expect(fixture.controller.phase == .failed)
        #expect(fixture.controller.requiresSystemPolicyRecovery)
        #expect(!fixture.controller.isToggleEnabled)
        #expect(fixture.controller.lastErrorMessage?.contains("电量") == true)
        #expect(fixture.controller.lastErrorMessage?.contains("回滚失败") == true)
        #expect(fixture.controller.lastErrorMessage?.contains("测试中的回滚失败") == true)
        #expect(await fixture.powerBackend.events() == ["begin", "end"])

        await fixture.powerBackend.setEndShouldFail(false)
        await fixture.controller.retrySystemPolicyRecovery()

        #expect(fixture.controller.phase == .off)
        #expect(!fixture.controller.requiresSystemPolicyRecovery)
        #expect(fixture.controller.isToggleEnabled)
        #expect(await fixture.powerBackend.events() == ["begin", "end", "end"])
    }

    @Test
    func preparingSessionCanBeCancelledWhileAdministratorWorkIsInFlight() async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"])
        defer { fixture.cleanup() }
        await fixture.powerBackend.pauseNextBegin()
        let startTask = Task {
            await fixture.controller.setEnabled(true)
        }
        for _ in 0..<100 {
            if await fixture.powerBackend.hasPausedBegin() {
                break
            }
            await Task.yield()
        }
        #expect(await fixture.powerBackend.hasPausedBegin())

        await fixture.controller.setEnabled(false)
        #expect(fixture.controller.phase == .stopping)

        await fixture.powerBackend.resumeBegin()
        await startTask.value

        #expect(fixture.controller.phase == .off)
        #expect(fixture.store.mode.phase == .off)
        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test
    func networkRecoveryTimeoutUsesOneBudgetThenStartsDegraded() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            networkConnected: false,
            reconnectRestoresNetwork: false,
            hotspotVerificationAttempts: 100,
            hotspotVerificationDelay: 0.02,
            networkRecoveryTimeout: 0.12,
            maximumForcedNetworkJoinAttempts: 10,
            networkRetryDelay: 0.02
        )
        defer { fixture.cleanup() }
        let clock = ContinuousClock()
        let startedAt = clock.now

        await fixture.controller.setEnabled(true)

        let elapsed = startedAt.duration(to: clock.now)
        #expect(elapsed >= .milliseconds(80))
        // The request-count assertion below proves the timeout budget was not
        // restarted for each forced join. Keep only a generous wall-clock
        // ceiling so a parallel run cannot fail on scheduler contention by a
        // few milliseconds.
        #expect(elapsed < .seconds(2))
        #expect(fixture.controller.phase == .active)
        #expect(fixture.store.mode.phase == .degraded)
        #expect(fixture.controller.lastErrorMessage == nil)
        #expect(fixture.controller.statusMessage.contains("断线守护正在重连"))
        #expect(await fixture.hotspotRecoverer.requests().count == 1)
        #expect(await fixture.powerBackend.events() == ["begin"])
        #expect(fixture.controller.requiresSystemPolicyRecovery)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)

        await fixture.controller.stop()
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
    }

    @Test
    func cancellingDuringInitialJoinPublishesOffWithoutStartingALease() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            networkConnected: false,
            reconnectRestoresNetwork: false,
            hotspotVerificationAttempts: 100,
            hotspotVerificationDelay: 0.2,
            networkRecoveryTimeout: 5
        )
        defer { fixture.cleanup() }
        let startTask = Task {
            await fixture.controller.setEnabled(true)
        }
        for _ in 0..<1_000 {
            if !(await fixture.hotspotRecoverer.requests()).isEmpty {
                break
            }
            await Task.yield()
        }
        #expect(await fixture.hotspotRecoverer.requests().count == 1)

        startTask.cancel()
        await startTask.value

        #expect(fixture.controller.phase == .off)
        #expect(fixture.store.mode.phase == .off)
        #expect(fixture.controller.lastErrorMessage == nil)
        #expect(await fixture.powerBackend.events().isEmpty)
        #expect(!fixture.controller.requiresSystemPolicyRecovery)
    }

    @Test
    func manualStopOfADegradedSessionRollsBackTheLease() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            activeSSID: "Example Hotspot",
            reconnectRestoresNetwork: false
        )
        defer { fixture.cleanup() }
        await fixture.powerBackend.pauseNextBegin()
        let startTask = Task {
            await fixture.controller.setEnabled(true)
        }
        for _ in 0..<1_000 {
            if await fixture.powerBackend.hasPausedBegin() {
                break
            }
            await Task.yield()
        }
        #expect(await fixture.powerBackend.hasPausedBegin())

        fixture.sampler.setNetworkConnected(false)
        await fixture.hotspotRecoverer.setActiveSSID(nil)
        await fixture.powerBackend.resumeBegin()
        await startTask.value

        #expect(fixture.controller.phase == .active)
        #expect(fixture.store.mode.phase == .degraded)
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(await fixture.hotspotRecoverer.requests().isEmpty)

        await fixture.controller.stop()

        #expect(fixture.controller.phase == .off)
        #expect(fixture.store.mode.phase == .off)
        #expect(fixture.controller.lastErrorMessage == nil)
        #expect(await fixture.powerBackend.events() == ["begin", "end"])
        #expect(!fixture.controller.requiresSystemPolicyRecovery)
    }

    @Test
    func shutdownRevokesTheInMemoryReconnectAuthorization() async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"])
        defer { fixture.cleanup() }
        await fixture.controller.start()
        #expect(fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)

        fixture.controller.shutdown()

        #expect(!fixture.hotspotStore.hasLocalClosedLidSessionAuthorization)
        #expect(fixture.hotspotStore.snapshot.phase == .stopped)
    }

    @Test
    func temporaryOverrideRestoresDisabledBaselineAndExactModuleConfiguration() async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"])
        defer { fixture.cleanup() }
        let baselineConfiguration = fixture.moduleStore.configuration

        await fixture.controller.start()

        #expect(fixture.controller.phase == .active)
        #expect(fixture.controller.baselineClosedLidEnabled == false)
        #expect(await fixture.powerBackend.isSleepDisabled() == true)
        #expect(fixture.moduleStore.configuration != baselineConfiguration)

        await fixture.controller.stop()

        #expect(fixture.controller.phase == .off)
        #expect(await fixture.powerBackend.isSleepDisabled() == false)
        #expect(fixture.moduleStore.configuration == baselineConfiguration)
        #expect(fixture.controller.baselineClosedLidEnabled == nil)
    }

    @Test
    func temporaryOverridePreservesAnEnabledBaseline() async throws {
        let fixture = try makeFixture(
            preferredSSIDs: ["Example Hotspot"],
            baselineSleepDisabled: true
        )
        defer { fixture.cleanup() }

        await fixture.controller.start()
        #expect(fixture.controller.baselineClosedLidEnabled == true)

        await fixture.controller.stop()

        #expect(fixture.controller.phase == .off)
        #expect(await fixture.powerBackend.isSleepDisabled() == true)
        #expect(fixture.controller.baselineClosedLidEnabled == nil)
    }

    @Test
    func appRestartRecoveryRestoresTheSavedBaselineBeforeAllowingAnotherSession() async throws {
        let fixture = try makeFixture(preferredSSIDs: ["Example Hotspot"])
        defer { fixture.cleanup() }
        let baselineConfiguration = fixture.moduleStore.configuration
        await fixture.controller.start()
        fixture.controller.shutdown()

        let reloadedPowerStore = MacSystemPowerPolicyStore(
            backend: fixture.powerBackend,
            defaults: fixture.defaults
        )
        let reloadedController = MacClosedLidSessionController(
            store: fixture.store,
            moduleStore: fixture.moduleStore,
            powerPolicyStore: reloadedPowerStore,
            hotspotStore: fixture.hotspotStore,
            remoteControlChecker: SessionRemoteControlChecker(),
            journalDefaults: fixture.defaults,
            now: { fixture.now }
        )

        #expect(reloadedController.baselineClosedLidEnabled == false)
        await reloadedController.recoverInterruptedSessionIfNeeded()

        #expect(reloadedController.phase == .off)
        #expect(await fixture.powerBackend.isSleepDisabled() == false)
        #expect(fixture.moduleStore.configuration == baselineConfiguration)
        #expect(reloadedController.baselineClosedLidEnabled == nil)
        reloadedController.shutdown()
    }
}

private extension MacClosedLidSessionControllerTests {
    struct Fixture {
        let controller: MacClosedLidSessionController
        let store: MacMobilityStore
        let sampler: SessionSystemSampler
        let moduleStore: MobilityModuleConfigurationStore
        let powerStore: MacSystemPowerPolicyStore
        let powerBackend: SessionPowerBackend
        let hotspotRecoverer: SessionHotspotRecoverer
        let hotspotStore: MacHotspotAutomationStore
        let hotspotMonitor: SessionAutomaticNetworkPathMonitor
        let moduleRuntime: MacMobilityModuleRuntime
        let moduleConfigurationCancellable: AnyCancellable
        let mobilityStatusCancellable: AnyCancellable
        let defaults: UserDefaults
        let suiteName: String
        let now: Date

        @MainActor
        func cleanup() {
            controller.shutdown()
            moduleRuntime.stopAll()
            moduleConfigurationCancellable.cancel()
            mobilityStatusCancellable.cancel()
            store.shutdown()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func makeFixture(
        preferredSSIDs: [String],
        agentDesktopController: MacAgentDesktopController? = nil,
        caffeineController: MacCaffeineController? = nil,
        activeSSID: String? = nil,
        networkConnected: Bool = true,
        reconnectRestoresNetwork: Bool = true,
        baselineSleepDisabled: Bool = false,
        visibleSSIDAfterReconnect: @escaping @Sendable (String) -> String? = { $0 },
        hotspotVerificationAttempts: Int = 12,
        hotspotVerificationDelay: TimeInterval = 0,
        networkRecoveryTimeout: TimeInterval =
            MacClosedLidSessionController.networkRecoveryTimeout,
        maximumForcedNetworkJoinAttempts: Int =
            MacClosedLidSessionController.maximumForcedNetworkJoinAttempts,
        networkRetryDelay: TimeInterval =
            MacClosedLidSessionController.networkRetryDelay,
        remoteControlChecker: (any MacCodexRemoteControlChecking)? = nil
    ) throws -> Fixture {
        let now = Date(timeIntervalSince1970: 10_000)
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Test Mac",
            battery: MobilityBatteryStatus(levelPercent: 90),
            network: MobilityNetworkStatus(
                kind: networkConnected ? .wifi : .offline,
                isConnected: networkConnected
            ),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            helperReady: true
        )
        let sampler = SessionSystemSampler(status: status)
        let store = MacMobilityStore(
            sampler: sampler,
            policyPersistence: SessionPolicyPersistence(),
            pollingInterval: 60
        )
        let modulePersistence = SessionModulePersistence()
        let moduleStore = MobilityModuleConfigurationStore(
            persistence: modulePersistence
        )
        let suiteName = "MacClosedLidSessionControllerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let powerBackend = SessionPowerBackend(
            baselineSleepDisabled: baselineSleepDisabled,
            networkStatusProvider: { [weak sampler] in
                sampler?.isNetworkConnected() ?? false
            }
        )
        let powerStore = MacSystemPowerPolicyStore(
            backend: powerBackend,
            defaults: defaults
        )
        let hotspotRecoverer = SessionHotspotRecoverer(
            activeSSID: activeSSID,
            visibleSSIDAfterReconnect: visibleSSIDAfterReconnect,
            onReconnect: { [weak sampler] in
                if reconnectRestoresNetwork {
                    sampler?.setNetworkConnected(true)
                }
            }
        )
        let hotspotMonitor = SessionAutomaticNetworkPathMonitor()
        let hotspotStore = MacHotspotAutomationStore(
            preferences: SessionHotspotPreferences(preferredSSIDs: preferredSSIDs),
            recoverer: hotspotRecoverer,
            connectionVerificationAttempts: hotspotVerificationAttempts,
            connectionVerificationDelay: hotspotVerificationDelay,
            pathMonitorFactory: { hotspotMonitor }
        )
        let moduleRuntime = try MacMobilityModuleRuntime(
            configurationStore: moduleStore,
            adapters: [hotspotStore]
        )
        let moduleConfigurationCancellable = moduleStore.$configuration
            .sink { [weak moduleRuntime] configuration in
                moduleRuntime?.applyConfiguration(configuration)
            }
        let mobilityStatusCancellable = store.$status
            .sink { [weak hotspotStore] status in
                hotspotStore?.setMobilityModeActive(status.mode.isEnabled)
            }
        let controller = MacClosedLidSessionController(
            store: store,
            moduleStore: moduleStore,
            powerPolicyStore: powerStore,
            hotspotStore: hotspotStore,
            remoteControlChecker: remoteControlChecker ?? SessionRemoteControlChecker(),
            agentDesktopController: agentDesktopController,
            caffeineController: caffeineController,
            leaseEndSignal: {},
            journalDefaults: defaults,
            networkRecoveryTimeout: networkRecoveryTimeout,
            maximumForcedNetworkJoinAttempts: maximumForcedNetworkJoinAttempts,
            networkRetryDelay: networkRetryDelay,
            now: { now }
        )
        return Fixture(
            controller: controller,
            store: store,
            sampler: sampler,
            moduleStore: moduleStore,
            powerStore: powerStore,
            powerBackend: powerBackend,
            hotspotRecoverer: hotspotRecoverer,
            hotspotStore: hotspotStore,
            hotspotMonitor: hotspotMonitor,
            moduleRuntime: moduleRuntime,
            moduleConfigurationCancellable: moduleConfigurationCancellable,
            mobilityStatusCancellable: mobilityStatusCancellable,
            defaults: defaults,
            suiteName: suiteName,
            now: now
        )
    }
}

private final class SessionSystemSampler: MacSystemSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var status: MobilityDeviceStatus
    private var upcomingNetworkSamples: [Bool] = []

    init(status: MobilityDeviceStatus) {
        self.status = status
    }

    func start() {}
    func stop() {}

    func sample(mode: MobilityModeStatus, now: Date) -> MobilityDeviceStatus {
        lock.lock()
        defer { lock.unlock() }
        if !upcomingNetworkSamples.isEmpty {
            setNetworkConnectedLocked(upcomingNetworkSamples.removeFirst())
        }
        var result = status
        result.mode = mode
        result.observedAt = now
        return result
    }

    func setNetworkConnected(_ isConnected: Bool) {
        lock.lock()
        setNetworkConnectedLocked(isConnected)
        lock.unlock()
    }

    func setCodexRunning(_ running: Bool) {
        lock.lock()
        status.codex = MobilityCodexStatus(isRunning: running)
        lock.unlock()
    }

    func setBatteryLevel(_ levelPercent: Int?) {
        lock.lock()
        status.battery = MobilityBatteryStatus(levelPercent: levelPercent)
        lock.unlock()
    }

    func setUpcomingNetworkSamples(_ values: [Bool]) {
        lock.lock()
        upcomingNetworkSamples = values
        lock.unlock()
    }

    func isNetworkConnected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return status.network.isConnected
    }

    private func setNetworkConnectedLocked(_ isConnected: Bool) {
        status.network = MobilityNetworkStatus(
            kind: isConnected ? .wifi : .offline,
            isConnected: isConnected
        )
    }
}

private final class SessionPolicyPersistence: MobilityPolicyPersisting {
    func loadPolicy() -> MobilityPolicy? { .recommended }
    func savePolicy(_ policy: MobilityPolicy) {}
}

private final class SessionModulePersistence: MobilityModuleConfigurationPersisting {
    private var configuration: MobilityModuleConfiguration?

    func loadConfiguration() throws -> MobilityModuleConfiguration? {
        configuration
    }

    func saveConfiguration(_ configuration: MobilityModuleConfiguration) throws {
        self.configuration = configuration
    }
}

private actor SessionPowerBackend: MacSystemPowerPolicyBackend {
    private var facts = MacSystemPowerPolicyFacts(
        sleepDisabled: false,
        displaySleepOnLidClose: true,
        requirePasswordAfterDisplaySleep: true,
        keepExternalDisplayActive: false,
        legacyConfigurationAvailable: true,
        lidGuardRunning: true
    )
    private var recordedEvents: [String] = []
    private var endShouldFail = false
    private var renewShouldFail = false
    private var shouldPauseBegin = false
    private var beginContinuation: CheckedContinuation<Void, Never>?
    private let networkStatusProvider: @Sendable () -> Bool
    private var recordedNetworkAvailabilityAtBegin: [Bool] = []

    init(
        baselineSleepDisabled: Bool = false,
        networkStatusProvider: @escaping @Sendable () -> Bool = { true }
    ) {
        self.networkStatusProvider = networkStatusProvider
        facts.sleepDisabled = baselineSleepDisabled
    }

    func loadFacts() async -> MacSystemPowerPolicyFacts {
        facts
    }

    func setClosedLidContinuity(enabled: Bool) async throws {
        facts.sleepDisabled = enabled
    }

    func beginClosedLidContinuityLease(
        duration: TimeInterval,
        now: Date
    ) async throws -> MacClosedLidContinuityLease {
        recordedEvents.append("begin")
        recordedNetworkAvailabilityAtBegin.append(networkStatusProvider())
        if shouldPauseBegin {
            await withCheckedContinuation { continuation in
                beginContinuation = continuation
            }
            shouldPauseBegin = false
        }
        let didEnableSystemPolicy = facts.sleepDisabled != true
        facts.sleepDisabled = true
        return MacClosedLidContinuityLease(
            startedAt: now,
            expiresAt: now.addingTimeInterval(duration),
            didEnableSystemPolicy: didEnableSystemPolicy
        )
    }

    func setRenewShouldFail() { renewShouldFail = true }
    func renewClosedLidContinuityLease(_ lease: MacClosedLidContinuityLease, expiresAt: Date) async throws -> MacClosedLidContinuityLease {
        if renewShouldFail { throw MacSystemPowerPolicyError.verificationFailed }
        recordedEvents.append("renew")
        return MacClosedLidContinuityLease(startedAt: lease.startedAt, expiresAt: expiresAt,
                                          didEnableSystemPolicy: lease.didEnableSystemPolicy)
    }

    func endClosedLidContinuityLease(_ lease: MacClosedLidContinuityLease) async throws {
        recordedEvents.append("end")
        if endShouldFail {
            throw MacSystemPowerPolicyError.commandFailed("测试中的回滚失败。")
        }
        if lease.didEnableSystemPolicy {
            facts.sleepDisabled = false
        }
    }

    func setLegacyControl(
        _ control: MacSystemPolicyControl,
        enabled: Bool
    ) async throws {}

    func events() -> [String] {
        recordedEvents
    }

    func isSleepDisabled() -> Bool? {
        facts.sleepDisabled
    }

    func networkAvailabilityAtBegin() -> [Bool] {
        recordedNetworkAvailabilityAtBegin
    }

    func setEndShouldFail(_ value: Bool) {
        endShouldFail = value
    }

    func pauseNextBegin() {
        shouldPauseBegin = true
    }

    func hasPausedBegin() -> Bool {
        beginContinuation != nil
    }

    func resumeBegin() {
        beginContinuation?.resume()
        beginContinuation = nil
    }
}

private final class SessionHotspotPreferences:
    MacHotspotAutomationPreferencesPersisting {
    private var preferredSSIDs: [String]
    private var lastGoodSSID: String?

    init(preferredSSIDs: [String]) {
        self.preferredSSIDs = preferredSSIDs
    }

    func loadPreferredSSIDs() -> [String] { preferredSSIDs }
    func savePreferredSSIDs(_ values: [String]) { preferredSSIDs = values }
    func loadLastGoodSSID() -> String? { lastGoodSSID }
    func saveLastGoodSSID(_ value: String?) { lastGoodSSID = value }
}

private actor SessionHotspotRecoverer: SavedWiFiNetworkRecovering {
    private var failure: MacBackgroundHotspotError?
    func setFailure(_ error: MacBackgroundHotspotError) { failure = error }

    private var preferredSSIDRequests: [[String]] = []
    private var activeSSID: String?
    private let visibleSSIDAfterReconnect: @Sendable (String) -> String?
    private let onReconnect: @Sendable () -> Void

    init(
        activeSSID: String?,
        visibleSSIDAfterReconnect: @escaping @Sendable (String) -> String? = { $0 },
        onReconnect: @escaping @Sendable () -> Void
    ) {
        self.activeSSID = activeSSID
        self.visibleSSIDAfterReconnect = visibleSSIDAfterReconnect
        self.onReconnect = onReconnect
    }

    func visibleCurrentNetwork() async throws -> String? {
        activeSSID
    }

    func reconnectSavedNetwork(
        preferredSSIDs: [String],
        lastGoodSSID: String?
    ) async throws -> String {
        preferredSSIDRequests.append(preferredSSIDs)
        if let failure { throw failure }
        activeSSID = visibleSSIDAfterReconnect(preferredSSIDs[0])
        onReconnect()
        return preferredSSIDs[0]
    }

    func setActiveSSID(_ value: String?) {
        activeSSID = value
    }

    func requests() -> [[String]] {
        preferredSSIDRequests
    }
}

private final class SessionAutomaticNetworkPathMonitor:
    AutomaticNetworkPathMonitoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var handler: (@Sendable (AutomaticNetworkPathState) -> Void)?

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func start(
        queue: DispatchQueue,
        updateHandler: @escaping @Sendable (AutomaticNetworkPathState) -> Void
    ) {
        lock.lock()
        started = true
        handler = updateHandler
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        started = false
        handler = nil
        lock.unlock()
    }

    func emit(_ state: AutomaticNetworkPathState) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(state)
    }
}

private struct SessionRemoteControlChecker: MacCodexRemoteControlChecking {
    func ensureConnected(timeout: TimeInterval) async -> MacCodexRemoteControlReadiness {
        .connected
    }
}

private actor PausedSessionRecoveryChecker: MacCodexRemoteControlChecking {
    private var calls = 0
    private var continuation: CheckedContinuation<MacCodexRemoteControlReadiness, Never>?
    var isWaiting: Bool { continuation != nil }
    func ensureConnected(timeout: TimeInterval) async -> MacCodexRemoteControlReadiness {
        calls += 1
        if calls == 1 { return .unavailable("测试首次未连接") }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume(returning: .connected)
        continuation = nil
    }
}

private actor PausedStartupRemoteChecker: MacCodexRemoteControlChecking {
    private var continuation: CheckedContinuation<MacCodexRemoteControlReadiness, Never>?
    var isWaiting: Bool { continuation != nil }
    func ensureConnected(timeout: TimeInterval) async -> MacCodexRemoteControlReadiness {
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume(returning: .connected)
        continuation = nil
    }
}

@MainActor private final class MobileOfficeTestCaffeineRunner: MacCaffeineRunning {
    var running = false
    var timeout: Int?
    func start(timeoutSeconds: Int?, onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws {
        running = true
        timeout = timeoutSeconds
    }
    func stop() { running = false }
}
