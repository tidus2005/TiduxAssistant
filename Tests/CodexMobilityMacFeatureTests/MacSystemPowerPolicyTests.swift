@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mac system power policy")
struct MacSystemPowerPolicyTests {
    @Test
    func pmsetParserReadsEnabledAndDisabledValues() {
        let enabled = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         sleep                0 (sleep prevented by powerd)
        """
        let disabled = """
        System-wide power settings:
         sleepdisabled 0
        """

        #expect(LocalMacSystemPowerPolicyBackend.parseSleepDisabled(enabled) == true)
        #expect(LocalMacSystemPowerPolicyBackend.parseSleepDisabled(disabled) == false)
    }

    @Test
    func pmsetParserRejectsMissingOrMalformedValues() {
        #expect(LocalMacSystemPowerPolicyBackend.parseSleepDisabled("sleep 0") == nil)
        #expect(LocalMacSystemPowerPolicyBackend.parseSleepDisabled("SleepDisabled yes") == nil)
        #expect(LocalMacSystemPowerPolicyBackend.parseSleepDisabled("SleepDisabled") == nil)
        #expect(LocalMacSystemPowerPolicyBackend.parseSleepDisabled("") == nil)
    }

    @Test
    func privilegedHelperRequestsAreVersionedAndAllowlisted() {
        let expiresAt = Date(timeIntervalSince1970: 17_000_000_000)

        #expect(
            MacPrivilegedPowerHelper.requestPayload(
                requestID: "request-a",
                command: .setSleepDisabled(true)
            ) == "3|request-a|set|1|0\n"
        )
        #expect(
            MacPrivilegedPowerHelper.requestPayload(
                requestID: "request-b",
                command: .setSleepDisabled(false)
            ) == "3|request-b|set|0|0\n"
        )
        #expect(
            MacPrivilegedPowerHelper.requestPayload(
                requestID: "request-c",
                command: .beginLease(baselineEnabled: false, expiresAt: expiresAt)
            ) == "3|request-c|lease-start|0|17000000000\n"
        )
        #expect(
            MacPrivilegedPowerHelper.requestPayload(
                requestID: "request-d",
                command: .endLease
            ) == "3|request-d|lease-stop|0|0\n"
        )
        #expect(
            MacPrivilegedPowerHelper.requestPayload(
                requestID: "request-e",
                command: .setBatteryDisplaySleep(minutes: 30)
            ) == "3|request-e|display-b|30|0\n"
        )
        #expect(
            MacPrivilegedPowerHelper.requestPayload(
                requestID: "request-f",
                command: .setPowerAdapterDisplaySleep(minutes: 150)
            ) == "3|request-f|display-c|150|0\n"
        )
        #expect(
            MacPrivilegedPowerHelper.requestPayload(
                requestID: "request-g",
                command: .setScreenLockDelay(seconds: 300)
            ) == "3|request-g|screen-lock|300|0\n"
        )
        #expect(
            MacPrivilegedPowerHelper.requestPayload(
                requestID: "request-h",
                command: .setScreenLockDelay(seconds: nil)
            ) == "3|request-h|screen-lock|off|0\n"
        )
    }

    @Test
    func privilegedHelperDaemonUsesFixedCommandsAndRestoresLeaseDeadline() throws {
        let plistText = MacPrivilegedPowerHelper.launchDaemonPlist(userID: 501)
        let propertyList = try PropertyListSerialization.propertyList(
            from: Data(plistText.utf8),
            options: [],
            format: nil
        )
        let dictionary = try #require(propertyList as? [String: Any])
        let arguments = try #require(dictionary["ProgramArguments"] as? [String])
        let daemonCommand = try #require(arguments.last)

        #expect(
            dictionary["Label"] as? String
                == "com.tidux.codex-watch-pet.power-helper-501"
        )
        #expect(dictionary["RunAtLoad"] as? Bool == true)
        #expect(dictionary["KeepAlive"] as? Bool == true)
        #expect(arguments.prefix(2) == ["/bin/sh", "-c"])
        #expect(daemonCommand.contains("case \"$request_command\" in"))
        #expect(daemonCommand.contains("set)"))
        #expect(daemonCommand.contains("lease-start)"))
        #expect(daemonCommand.contains("lease-stop)"))
        #expect(daemonCommand.contains("lease-renew)"))
        #expect(daemonCommand.contains("$saved_baseline"))
        #expect(MacPrivilegedPowerHelper.requestPayload(requestID: "renew",
            command: .renewLease(expiresAt: Date(timeIntervalSince1970: 1800000000)))
            == "3|renew|lease-renew|0|1800000000\n")
        #expect(daemonCommand.contains("display-b)"))
        #expect(daemonCommand.contains("display-c)"))
        #expect(daemonCommand.contains("screen-lock)"))
        #expect(daemonCommand.contains("request_owner"))
        #expect(daemonCommand.contains("[ -L \"$request_path\" ]"))
        #expect(daemonCommand.contains("max_lease='14700'"))
        #expect(daemonCommand.contains("/usr/bin/pmset -a disablesleep \"$request_value\""))
        #expect(daemonCommand.contains("/usr/bin/pmset -a disablesleep \"$saved_baseline\""))
        #expect(daemonCommand.contains("/usr/bin/pmset -b displaysleep \"$request_value\""))
        #expect(daemonCommand.contains("/usr/bin/pmset -c displaysleep \"$request_value\""))
        #expect(daemonCommand.contains("/usr/sbin/sysadminctl -screenLock \"$screen_lock_value\""))
        #expect(daemonCommand.contains("screen_lock_value=off"))
        #expect(
            daemonCommand.contains(
                "/Library/Application Support/CodexWatchPetPowerHelper/lease-501"
            )
        )
        #expect(!daemonCommand.contains("eval"))
        #expect(!daemonCommand.contains("sudo"))

        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntaxCheck.arguments = ["-n", "-c", daemonCommand]
        try syntaxCheck.run()
        syntaxCheck.waitUntilExit()
        #expect(syntaxCheck.terminationStatus == 0)
    }

    @Test
    func privilegedHelperInstallationPromptsOnceWithoutChangingPowerState() throws {
        let script = MacPrivilegedPowerHelper.administratorInstallationScript(userID: 501)
        let command = MacPrivilegedPowerHelper.administratorInstallationCommand(userID: 501)

        #expect(script.contains("授权一次后"))
        #expect(script.contains("with administrator privileges"))
        #expect(
            command.contains(
                "/Library/LaunchDaemons/"
                    + "com.tidux.codex-watch-pet.power-helper-501.plist"
            )
        )
        #expect(command.contains("/usr/sbin/chown root:wheel"))
        #expect(command.contains("/bin/chmod 0644"))
        #expect(command.contains("/bin/launchctl bootout"))
        #expect(command.contains("/bin/launchctl bootstrap system"))
        #expect(command.contains("/bin/launchctl print"))
        #expect(!command.contains("pmset"))
        #expect(!command.contains("sudo"))

        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntaxCheck.arguments = ["-n", "-c", command]
        try syntaxCheck.run()
        syntaxCheck.waitUntilExit()
        #expect(syntaxCheck.terminationStatus == 0)
    }

    @Test
    func lidConfigurationReadsAllThreeCanonicalControls() {
        let configuration = ContinuityLidPolicyConfiguration(text: """
        # Existing comments must remain data, not configuration.
        export LID_GUARD_ENABLE_DISPLAY_SLEEP=0
        LID_GUARD_ENABLE_LOCK='yes'
        LID_GUARD_KEEP_EXTERNAL_ACTIVE="on"
        UNKNOWN_SETTING=unchanged
        """)

        #expect(configuration.displaySleepOnLidClose == false)
        #expect(configuration.requirePasswordAfterDisplaySleep == true)
        #expect(configuration.keepExternalDisplayActive == true)
    }

    @Test
    func keepExternalControlUsesCompatibilityKeysOnlyAsFallbacks() {
        let preserved = ContinuityLidPolicyConfiguration(text: """
        LID_GUARD_PRESERVE_EXTERNAL_DISPLAY=0
        LID_GUARD_SKIP_ON_AC_EXTERNAL=1
        """)
        let legacy = ContinuityLidPolicyConfiguration(text: """
        LID_GUARD_SKIP_ON_AC_EXTERNAL=0
        """)
        let canonicalWins = ContinuityLidPolicyConfiguration(text: """
        LID_GUARD_KEEP_EXTERNAL_ACTIVE=0
        LID_GUARD_PRESERVE_EXTERNAL_DISPLAY=1
        LID_GUARD_SKIP_ON_AC_EXTERNAL=1
        """)

        #expect(preserved.keepExternalDisplayActive == false)
        #expect(legacy.keepExternalDisplayActive == false)
        #expect(canonicalWins.keepExternalDisplayActive == false)
    }

    @Test
    func lidConfigurationTreatsInvalidAndDuplicateBooleanValuesAsUnknown() {
        let invalid = ContinuityLidPolicyConfiguration(text: """
        LID_GUARD_ENABLE_DISPLAY_SLEEP=sometimes
        LID_GUARD_ENABLE_LOCK=2
        LID_GUARD_KEEP_EXTERNAL_ACTIVE=
        """)
        let duplicate = ContinuityLidPolicyConfiguration(text: """
        LID_GUARD_ENABLE_DISPLAY_SLEEP=1
        LID_GUARD_ENABLE_DISPLAY_SLEEP=0
        LID_GUARD_ENABLE_LOCK=yes
        LID_GUARD_ENABLE_LOCK=yes
        """)

        #expect(invalid.displaySleepOnLidClose == nil)
        #expect(invalid.requirePasswordAfterDisplaySleep == nil)
        #expect(invalid.keepExternalDisplayActive == nil)
        #expect(duplicate.displaySleepOnLidClose == nil)
        #expect(duplicate.requirePasswordAfterDisplaySleep == nil)
    }

    @Test
    func lidConfigurationUpdatesOnlyTheSelectedKeyAndPreservesUnknownContent() {
        let original = """
        # User comment
        UNKNOWN_SETTING=value with spaces
        export LID_GUARD_ENABLE_DISPLAY_SLEEP=1
        LID_GUARD_SKIP_ON_AC_EXTERNAL=0

        """
        let configuration = ContinuityLidPolicyConfiguration(text: original)

        let displayUpdated = configuration.updating(
            control: .displaySleepOnLidClose,
            enabled: false
        )
        #expect(displayUpdated.contains("# User comment"))
        #expect(displayUpdated.contains("UNKNOWN_SETTING=value with spaces"))
        #expect(displayUpdated.contains("LID_GUARD_SKIP_ON_AC_EXTERNAL=0"))
        #expect(displayUpdated.contains("LID_GUARD_ENABLE_DISPLAY_SLEEP=0"))
        #expect(!displayUpdated.contains("LID_GUARD_ENABLE_DISPLAY_SLEEP=1"))

        let canonicalAppended = configuration.updating(
            control: .keepExternalDisplayActive,
            enabled: true
        )
        #expect(canonicalAppended.contains("UNKNOWN_SETTING=value with spaces"))
        #expect(canonicalAppended.contains("LID_GUARD_SKIP_ON_AC_EXTERNAL=0"))
        #expect(canonicalAppended.contains("LID_GUARD_KEEP_EXTERNAL_ACTIVE=1"))

        #expect(
            configuration.updating(control: .closedLidContinuity, enabled: false)
                == original
        )
    }

    @Test
    func lidConfigurationNormalizesDuplicateSelectedKeysToOneCanonicalValue() {
        let configuration = ContinuityLidPolicyConfiguration(text: """
        export LID_GUARD_ENABLE_LOCK=0
        UNKNOWN_SETTING=unchanged
        LID_GUARD_ENABLE_LOCK=1
        LID_GUARD_ENABLE_LOCK=no
        """)

        let updated = configuration.updating(
            control: .requirePasswordAfterDisplaySleep,
            enabled: true
        )
        let selectedLines = updated.split(whereSeparator: \.isNewline).filter {
            $0.contains("LID_GUARD_ENABLE_LOCK")
        }

        #expect(selectedLines == ["LID_GUARD_ENABLE_LOCK=1"])
        #expect(updated.contains("UNKNOWN_SETTING=unchanged"))
        #expect(
            ContinuityLidPolicyConfiguration(text: updated)
                .requirePasswordAfterDisplaySleep == true
        )
    }

    @Test
    func snapshotDistinguishesDisabledExternalAndAppManagedPower() {
        var snapshot = MacSystemPowerPolicySnapshot(sleepDisabled: false)
        #expect(snapshot.state(for: .closedLidContinuity) == .disabled)

        snapshot.sleepDisabled = true
        #expect(snapshot.state(for: .closedLidContinuity) == .externallyEnabled)

        snapshot.managedControls = [.closedLidContinuity]
        #expect(snapshot.state(for: .closedLidContinuity) == .appManaged)

        snapshot.sleepDisabled = nil
        #expect(
            snapshot.state(for: .closedLidContinuity)
                == .unknown("暂时无法读取当前系统状态。")
        )
    }

    @Test
    func snapshotRequiresBothLegacyConfigurationAndRunningAgent() {
        let missingConfiguration = MacSystemPowerPolicySnapshot(
            displaySleepOnLidClose: true,
            legacyConfigurationAvailable: false,
            lidGuardRunning: true
        )
        #expect(
            missingConfiguration.state(for: .displaySleepOnLidClose)
                == .unsupported("没有检测到本机 Continuity 合盖策略配置。")
        )

        let stoppedAgent = MacSystemPowerPolicySnapshot(
            requirePasswordAfterDisplaySleep: true,
            legacyConfigurationAvailable: true,
            lidGuardRunning: false
        )
        #expect(
            stoppedAgent.state(for: .requirePasswordAfterDisplaySleep)
                == .unknown("配置存在，但合盖策略服务当前没有运行。")
        )

        let runningAgent = MacSystemPowerPolicySnapshot(
            keepExternalDisplayActive: true,
            legacyConfigurationAvailable: true,
            lidGuardRunning: true,
            managedControls: [.keepExternalDisplayActive]
        )
        #expect(runningAgent.state(for: .keepExternalDisplayActive) == .appManaged)
    }

    @Test @MainActor
    func storeRejectsARepeatedBeginUntilTheActiveLeaseEnds() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(sleepDisabled: false))
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 10_000)

        let first = await fixture.store.beginClosedLidContinuityLease(now: now)
        let repeated = await fixture.store.beginClosedLidContinuityLease(now: now)

        #expect(first?.didEnableSystemPolicy == true)
        #expect(repeated == nil)
        #expect(fixture.store.activeClosedLidLease == first)
        #expect(await fixture.backend.recordedClosedLidChanges() == [true])

        #expect(await fixture.store.endClosedLidContinuityLease())
        let afterEnd = await fixture.store.beginClosedLidContinuityLease(now: now)
        #expect(afterEnd?.didEnableSystemPolicy == true)
        #expect(await fixture.backend.recordedClosedLidChanges() == [true, false, true])
    }

    @Test @MainActor
    func cancelledAuthorizationLeavesNoActiveLeaseAndAllowsRetry() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(sleepDisabled: false))
        defer { fixture.cleanup() }
        await fixture.backend.configureClosedLidFailure(
            .authorizationCancelled,
            factsAfterAttempt: Self.facts(sleepDisabled: false)
        )

        let cancelled = await fixture.store.beginClosedLidContinuityLease()

        #expect(cancelled == nil)
        #expect(fixture.store.activeClosedLidLease == nil)
        #expect(
            fixture.store.lastErrorMessage
                == MacSystemPowerPolicyError.authorizationCancelled.errorDescription
        )

        await fixture.backend.configureClosedLidUpdateFacts()
        let retried = await fixture.store.beginClosedLidContinuityLease()
        #expect(retried?.didEnableSystemPolicy == true)
        #expect(fixture.store.activeClosedLidLease == retried)
    }

    @Test @MainActor
    func postBeginVerificationFailureEndsTheAcquiredLeaseBeforeReportingFailure() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(sleepDisabled: false))
        defer { fixture.cleanup() }
        await fixture.backend.configureClosedLidSuccessWithoutChangingFacts()

        let lease = await fixture.store.beginClosedLidContinuityLease()

        #expect(lease == nil)
        #expect(fixture.store.activeClosedLidLease == nil)
        #expect(
            !fixture.store.snapshot.managedControls.contains(.closedLidContinuity)
        )
        #expect(await fixture.backend.recordedClosedLidChanges() == [true, false])
        #expect(
            fixture.store.lastErrorMessage
                == MacSystemPowerPolicyError.verificationFailed.errorDescription
        )
    }

    @Test @MainActor
    func failedPostBeginRollbackRetainsLeaseAndOwnershipForRetry() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(sleepDisabled: false))
        defer { fixture.cleanup() }
        await fixture.backend.configureClosedLidSuccessWithoutChangingFacts()
        await fixture.backend.configureLeaseEndFailure(
            .commandFailed("测试回滚失败。")
        )

        let lease = await fixture.store.beginClosedLidContinuityLease()

        #expect(lease == nil)
        #expect(fixture.store.activeClosedLidLease?.didEnableSystemPolicy == true)
        #expect(
            fixture.store.snapshot.managedControls.contains(.closedLidContinuity)
        )
        #expect(fixture.store.lastErrorMessage?.contains("系统策略回滚失败") == true)

        await fixture.backend.configureLeaseEndFailure(nil)
        #expect(await fixture.store.endClosedLidContinuityLease())
        #expect(fixture.store.activeClosedLidLease == nil)
        #expect(
            !fixture.store.snapshot.managedControls.contains(.closedLidContinuity)
        )
    }

    @Test @MainActor
    func endReadbackMismatchRetainsLeaseAndOwnershipForRetry() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(sleepDisabled: false))
        defer { fixture.cleanup() }
        let lease = await fixture.store.beginClosedLidContinuityLease()
        #expect(lease?.didEnableSystemPolicy == true)
        await fixture.backend.configureClosedLidSuccessWithoutChangingFacts()

        #expect(!(await fixture.store.endClosedLidContinuityLease()))
        #expect(fixture.store.activeClosedLidLease == lease)
        #expect(
            fixture.store.snapshot.managedControls.contains(.closedLidContinuity)
        )

        await fixture.backend.configureClosedLidUpdateFacts()
        #expect(await fixture.store.endClosedLidContinuityLease())
        #expect(fixture.store.activeClosedLidLease == nil)
        #expect(
            !fixture.store.snapshot.managedControls.contains(.closedLidContinuity)
        )
    }

    @Test @MainActor
    func storeReportsAnExistingEnabledPolicyAsExternal() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(sleepDisabled: true))
        defer { fixture.cleanup() }

        await fixture.store.refreshNow()

        #expect(
            fixture.store.snapshot.state(for: MacSystemPolicyControl.closedLidContinuity)
                == MacPolicyControlState.externallyEnabled
        )
        #expect(fixture.store.lastErrorMessage == nil)
        #expect(await fixture.backend.recordedClosedLidChanges() == [])
    }

    @Test @MainActor
    func successfulStoreMutationBecomesAppManagedAndPersistsOwnership() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(sleepDisabled: false))
        defer { fixture.cleanup() }

        let succeeded = await fixture.store.setClosedLidContinuityEnabled(true)

        #expect(succeeded)
        #expect(fixture.store.snapshot.sleepDisabled == true)
        #expect(
            fixture.store.snapshot.state(for: MacSystemPolicyControl.closedLidContinuity)
                == MacPolicyControlState.appManaged
        )
        #expect(fixture.store.lastActionMessage == "设置已开启。")
        #expect(await fixture.backend.recordedClosedLidChanges() == [true])

        let reloadedStore = MacSystemPowerPolicyStore(
            backend: fixture.backend,
            defaults: fixture.defaults
        )
        await reloadedStore.refreshNow()
        #expect(
            reloadedStore.snapshot.state(for: MacSystemPolicyControl.closedLidContinuity)
                == MacPolicyControlState.appManaged
        )
    }

    @Test @MainActor
    func legacyStoreMutationUsesFakeBackendAndTracksAppOwnership() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(
            displaySleepOnLidClose: false,
            legacyConfigurationAvailable: true,
            lidGuardRunning: true
        ))
        defer { fixture.cleanup() }

        let succeeded = await fixture.store.setLegacyControl(
            MacSystemPolicyControl.displaySleepOnLidClose,
            enabled: true
        )

        #expect(succeeded)
        #expect(
            fixture.store.snapshot.state(for: MacSystemPolicyControl.displaySleepOnLidClose)
                == MacPolicyControlState.appManaged
        )
        #expect(
            await fixture.backend.recordedLegacyChanges()
                == [FakeMacSystemPowerPolicyBackend.LegacyChange(
                    control: .displaySleepOnLidClose,
                    enabled: true
                )]
        )
    }

    @Test @MainActor
    func failedMutationReadsBackActualFactsAndDoesNotClaimOwnership() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(sleepDisabled: false))
        defer { fixture.cleanup() }
        await fixture.backend.configureClosedLidFailure(
            MacSystemPowerPolicyError.commandFailed("测试中的管理员命令失败。"),
            factsAfterAttempt: Self.facts(sleepDisabled: true)
        )

        let succeeded = await fixture.store.setClosedLidContinuityEnabled(true)

        #expect(!succeeded)
        #expect(fixture.store.snapshot.sleepDisabled == true)
        #expect(
            fixture.store.snapshot.state(for: MacSystemPolicyControl.closedLidContinuity)
                == MacPolicyControlState.externallyEnabled
        )
        #expect(fixture.store.lastErrorMessage == "测试中的管理员命令失败。")
        #expect(fixture.store.lastActionMessage == nil)
    }

    @Test @MainActor
    func verificationFailureReReadsStateAndClearsTentativeOwnership() async throws {
        let fixture = try Self.makeStoreFixture(facts: Self.facts(sleepDisabled: false))
        defer { fixture.cleanup() }
        await fixture.backend.configureClosedLidSuccessWithoutChangingFacts()

        let succeeded = await fixture.store.setClosedLidContinuityEnabled(true)

        #expect(!succeeded)
        #expect(fixture.store.snapshot.sleepDisabled == false)
        #expect(
            fixture.store.snapshot.state(for: MacSystemPolicyControl.closedLidContinuity)
                == MacPolicyControlState.disabled
        )
        #expect(
            fixture.store.lastErrorMessage
                == MacSystemPowerPolicyError.verificationFailed.errorDescription
        )
    }
}

private extension MacSystemPowerPolicyTests {
    struct StoreFixture {
        let store: MacSystemPowerPolicyStore
        let backend: FakeMacSystemPowerPolicyBackend
        let defaults: UserDefaults
        let suiteName: String

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    static func facts(
        sleepDisabled: Bool? = nil,
        displaySleepOnLidClose: Bool? = nil,
        requirePasswordAfterDisplaySleep: Bool? = nil,
        keepExternalDisplayActive: Bool? = nil,
        legacyConfigurationAvailable: Bool = false,
        lidGuardRunning: Bool = false
    ) -> MacSystemPowerPolicyFacts {
        MacSystemPowerPolicyFacts(
            sleepDisabled: sleepDisabled,
            displaySleepOnLidClose: displaySleepOnLidClose,
            requirePasswordAfterDisplaySleep: requirePasswordAfterDisplaySleep,
            keepExternalDisplayActive: keepExternalDisplayActive,
            legacyConfigurationAvailable: legacyConfigurationAvailable,
            lidGuardRunning: lidGuardRunning
        )
    }

    @MainActor
    static func makeStoreFixture(
        facts: MacSystemPowerPolicyFacts
    ) throws -> StoreFixture {
        let suiteName = "MacSystemPowerPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let backend = FakeMacSystemPowerPolicyBackend(facts: facts)
        return StoreFixture(
            store: MacSystemPowerPolicyStore(backend: backend, defaults: defaults),
            backend: backend,
            defaults: defaults,
            suiteName: suiteName
        )
    }
}

private actor FakeMacSystemPowerPolicyBackend: MacSystemPowerPolicyBackend {
    struct LegacyChange: Equatable, Sendable {
        let control: MacSystemPolicyControl
        let enabled: Bool
    }

    private enum ClosedLidBehavior: Sendable {
        case updateFacts
        case succeedWithoutChangingFacts
        case fail(MacSystemPowerPolicyError, factsAfterAttempt: MacSystemPowerPolicyFacts?)
    }

    private var facts: MacSystemPowerPolicyFacts
    private var closedLidBehavior: ClosedLidBehavior = .updateFacts
    private var leaseEndFailure: MacSystemPowerPolicyError?
    private var closedLidChanges: [Bool] = []
    private var legacyChanges: [LegacyChange] = []

    init(facts: MacSystemPowerPolicyFacts) {
        self.facts = facts
    }

    func loadFacts() async -> MacSystemPowerPolicyFacts {
        facts
    }

    func setClosedLidContinuity(enabled: Bool) async throws {
        closedLidChanges.append(enabled)
        switch closedLidBehavior {
        case .updateFacts:
            facts.sleepDisabled = enabled
        case .succeedWithoutChangingFacts:
            break
        case .fail(let error, let factsAfterAttempt):
            if let factsAfterAttempt {
                facts = factsAfterAttempt
            }
            throw error
        }
    }

    func beginClosedLidContinuityLease(
        duration: TimeInterval,
        now: Date
    ) async throws -> MacClosedLidContinuityLease {
        let wasEnabled = facts.sleepDisabled == true
        if !wasEnabled {
            try await setClosedLidContinuity(enabled: true)
        }
        return MacClosedLidContinuityLease(
            startedAt: now,
            expiresAt: now.addingTimeInterval(duration),
            didEnableSystemPolicy: !wasEnabled
        )
    }

    func endClosedLidContinuityLease(_ lease: MacClosedLidContinuityLease) async throws {
        if let leaseEndFailure {
            throw leaseEndFailure
        }
        if lease.didEnableSystemPolicy {
            try await setClosedLidContinuity(enabled: false)
        }
    }

    func setLegacyControl(
        _ control: MacSystemPolicyControl,
        enabled: Bool
    ) async throws {
        legacyChanges.append(LegacyChange(control: control, enabled: enabled))
        switch control {
        case .closedLidContinuity:
            Issue.record("Closed-lid continuity must use the dedicated backend method")
        case .displaySleepOnLidClose:
            facts.displaySleepOnLidClose = enabled
        case .requirePasswordAfterDisplaySleep:
            facts.requirePasswordAfterDisplaySleep = enabled
        case .keepExternalDisplayActive:
            facts.keepExternalDisplayActive = enabled
        }
    }

    func configureClosedLidFailure(
        _ error: MacSystemPowerPolicyError,
        factsAfterAttempt: MacSystemPowerPolicyFacts?
    ) {
        closedLidBehavior = .fail(error, factsAfterAttempt: factsAfterAttempt)
    }

    func configureClosedLidSuccessWithoutChangingFacts() {
        closedLidBehavior = .succeedWithoutChangingFacts
    }

    func configureClosedLidUpdateFacts() {
        closedLidBehavior = .updateFacts
    }

    func configureLeaseEndFailure(_ error: MacSystemPowerPolicyError?) {
        leaseEndFailure = error
    }

    func recordedClosedLidChanges() -> [Bool] {
        closedLidChanges
    }

    func recordedLegacyChanges() -> [LegacyChange] {
        legacyChanges
    }
}
