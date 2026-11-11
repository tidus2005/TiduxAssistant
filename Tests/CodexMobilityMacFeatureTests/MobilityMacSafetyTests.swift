@testable import CodexMobilityMacFeature
import CodexMobilityCore
import Darwin
import Foundation
import Testing

private struct StubCodexProcessInspector: CodexCLIProcessInspecting {
    var processes: [CodexProcessRecord]

    func runningProcesses() -> [CodexProcessRecord] {
        processes
    }
}

private struct StubPrimaryNetworkProbe: MacPrimaryNetworkProbing {
    var status: MobilityNetworkStatus?

    func currentPrimaryNetwork() -> MobilityNetworkStatus? {
        status
    }
}

private final class InMemoryPolicyPersistence: MobilityPolicyPersisting {
    var storedPolicy: MobilityPolicy?
    private(set) var savedPolicies: [MobilityPolicy] = []

    init(storedPolicy: MobilityPolicy? = nil) {
        self.storedPolicy = storedPolicy
    }

    func loadPolicy() -> MobilityPolicy? {
        storedPolicy
    }

    func savePolicy(_ policy: MobilityPolicy) {
        storedPolicy = policy
        savedPolicies.append(policy)
    }
}

private final class StubMacSystemSampler: MacSystemSampling, @unchecked Sendable {
    var sampledStatus: MobilityDeviceStatus
    private(set) var isStarted = false

    init(status: MobilityDeviceStatus) {
        self.sampledStatus = status
    }

    func start() {
        isStarted = true
    }

    func stop() {
        isStarted = false
    }

    func sample(mode: MobilityModeStatus, now: Date) -> MobilityDeviceStatus {
        var result = sampledStatus
        result.mode = mode
        result.observedAt = now
        return result
    }
}

@Suite("Mobility Mac safety boundary")
struct MobilityMacSafetyTests {
    @Test
    func batterySamplingIgnoresUPSAndSelectsInternalBattery() {
        let status = MacSystemSampler.batteryStatus(from: [
            [
                "Type": "UPS",
                "Current Capacity": 98,
                "Max Capacity": 100,
                "Power Source State": "AC Power"
            ],
            [
                "Type": "InternalBattery",
                "Current Capacity": 40,
                "Max Capacity": 80,
                "Is Charging": false,
                "Power Source State": "Battery Power",
                "Time to Empty": 125
            ]
        ])

        #expect(status.levelPercent == 50)
        #expect(status.isCharging == false)
        #expect(status.isOnExternalPower == false)
        #expect(status.estimatedMinutesRemaining == 125)
    }

    @Test
    func upsAloneNeverBecomesMacBattery() {
        let status = MacSystemSampler.batteryStatus(from: [[
            "Type": "UPS",
            "Current Capacity": 73,
            "Max Capacity": 100
        ]])

        #expect(status.levelPercent == nil)
    }

    @Test
    func codexCLIPathMatchingIsExact() {
        #expect(MacSystemSampler.isCodexCLIExecutablePath("/usr/local/bin/codex"))
        #expect(MacSystemSampler.isCodexCLIExecutablePath("/Applications/ChatGPT.app/Contents/Resources/Codex"))
        #expect(!MacSystemSampler.isCodexCLIExecutablePath("/usr/bin/grep"))
        #expect(!MacSystemSampler.isCodexCLIExecutablePath("/tmp/codex-helper"))
        #expect(!MacSystemSampler.isCodexCLIExecutablePath("/usr/bin/node"))
    }

    @Test
    func primaryRouteClosesPersonalHotspotPathPublicationGap() {
        let monitored = MobilityNetworkStatus(
            kind: .offline,
            isConnected: false,
            disconnectedSince: Date(timeIntervalSince1970: 100)
        )
        let primaryRoute = MobilityNetworkStatus(
            kind: .wifi,
            isConnected: true,
            isExpensive: true,
            isConstrained: true,
            interfaceName: "en0"
        )

        let resolved = MacSystemSampler.resolvedNetworkStatus(
            monitored: monitored,
            primaryRoute: primaryRoute
        )

        #expect(resolved == primaryRoute)
    }

    @Test
    func samplerUsesPrimaryRouteBeforeNWPathPublishesItsFirstUpdate() {
        let primaryRoute = MobilityNetworkStatus(
            kind: .wifi,
            isConnected: true,
            isExpensive: true,
            isConstrained: true,
            interfaceName: "en0"
        )
        let sampler = MacSystemSampler(
            deviceID: UUID(),
            deviceName: "Test Mac",
            guiCodexIsRunning: { false },
            codexCLIProcessInspector: StubCodexProcessInspector(processes: []),
            primaryNetworkProbe: StubPrimaryNetworkProbe(status: primaryRoute)
        )

        let sampled = sampler.sample(mode: MobilityModeStatus()).network

        #expect(sampled == primaryRoute)
    }

    @Test
    func primaryRouteFallbackRequiresServiceRouterAddressAndNoExplicitInactiveLink() {
        let global: [String: Any] = [
            "PrimaryInterface": "en0",
            "PrimaryService": "service-id",
            "Router": "172.20.10.1"
        ]
        let activeLink: [String: Any] = ["Active": true, "Expensive": true]

        #expect(SystemConfigurationMacPrimaryNetworkProbe.isUsablePrimaryRoute(
            global: global,
            addresses: ["172.20.10.2"],
            link: activeLink
        ))

        var noRouter = global
        noRouter["Router"] = nil
        #expect(!SystemConfigurationMacPrimaryNetworkProbe.isUsablePrimaryRoute(
            global: noRouter,
            addresses: ["172.20.10.2"],
            link: activeLink
        ))
        #expect(!SystemConfigurationMacPrimaryNetworkProbe.isUsablePrimaryRoute(
            global: global,
            addresses: [],
            link: activeLink
        ))
        #expect(!SystemConfigurationMacPrimaryNetworkProbe.isUsablePrimaryRoute(
            global: global,
            addresses: ["172.20.10.2"],
            link: ["Active": false]
        ))
        #expect(SystemConfigurationMacPrimaryNetworkProbe.isUsablePrimaryRoute(
            global: global,
            addresses: ["172.20.10.2"],
            link: nil
        ))
    }

    @Test
    func primaryRouteFallsBackToServiceAddressesOnlyWhenInterfaceAddressesAreMissing() {
        #expect(SystemConfigurationMacPrimaryNetworkProbe.preferredAddresses(
            interfaceAddresses: [],
            serviceAddresses: ["172.20.10.2"]
        ) == ["172.20.10.2"])
        #expect(SystemConfigurationMacPrimaryNetworkProbe.preferredAddresses(
            interfaceAddresses: ["192.168.31.78"],
            serviceAddresses: ["172.20.10.2"]
        ) == ["192.168.31.78"])
    }

    @Test
    func satisfiedNWPathRemainsAuthoritativeOverPrimaryRouteFallback() {
        let monitored = MobilityNetworkStatus(
            kind: .wifi,
            isConnected: true,
            isExpensive: true,
            isConstrained: true,
            interfaceName: "en0"
        )
        let primaryRoute = MobilityNetworkStatus(
            kind: .ethernet,
            isConnected: true,
            interfaceName: "en4"
        )

        let resolved = MacSystemSampler.resolvedNetworkStatus(
            monitored: monitored,
            primaryRoute: primaryRoute
        )

        #expect(resolved == monitored)
    }

    @Test
    func missingPrimaryRouteDoesNotInventConnectivity() {
        let monitored = MobilityNetworkStatus(
            kind: .offline,
            isConnected: false,
            disconnectedSince: Date(timeIntervalSince1970: 100)
        )

        let resolved = MacSystemSampler.resolvedNetworkStatus(
            monitored: monitored,
            primaryRoute: nil
        )

        #expect(resolved == monitored)
    }

    @Test
    func codexDetectionCoversCLIWithoutMatchingSelfOrGrep() {
        let samplerWithFalsePositives = MacSystemSampler(
            deviceID: UUID(),
            deviceName: "Test Mac",
            guiCodexIsRunning: { false },
            codexCLIProcessInspector: StubCodexProcessInspector(processes: [
                CodexProcessRecord(processIdentifier: getpid(), executablePath: "/usr/local/bin/codex"),
                CodexProcessRecord(processIdentifier: getpid() + 1, executablePath: "/usr/bin/grep")
            ])
        )

        let notRunning = samplerWithFalsePositives.sample(mode: MobilityModeStatus()).codex
        #expect(notRunning.isRunning == false)

        let samplerWithCLI = MacSystemSampler(
            deviceID: UUID(),
            deviceName: "Test Mac",
            guiCodexIsRunning: { false },
            codexCLIProcessInspector: StubCodexProcessInspector(processes: [
                CodexProcessRecord(
                    processIdentifier: getpid() + 2,
                    executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex"
                )
            ])
        )

        let running = samplerWithCLI.sample(mode: MobilityModeStatus()).codex
        #expect(running.isRunning)
        #expect(running.detail == "Codex CLI 正在运行")
    }

    @Test
    func codexDetectionCoversGUIBundleResult() {
        let sampler = MacSystemSampler(
            deviceID: UUID(),
            deviceName: "Test Mac",
            guiCodexIsRunning: { true },
            codexCLIProcessInspector: StubCodexProcessInspector(processes: [])
        )

        let status = sampler.sample(mode: MobilityModeStatus()).codex
        #expect(status.isRunning)
        #expect(status.detail == "Codex 图形客户端正在运行")
    }

    @Test
    func voicePolisherSubprocessDoesNotSatisfyCodexRunningPolicy() {
        let polisherPID = getpid() + 100
        let userTaskPID = polisherPID + 1
        let samplerWithOnlyPolisher = MacSystemSampler(
            deviceID: UUID(),
            deviceName: "Test Mac",
            guiCodexIsRunning: { false },
            codexCLIProcessInspector: StubCodexProcessInspector(processes: [
                CodexProcessRecord(
                    processIdentifier: polisherPID,
                    executablePath: "/usr/local/bin/codex"
                )
            ]),
            codexCLIProcessIsIgnored: { $0 == polisherPID }
        )
        #expect(
            samplerWithOnlyPolisher
                .sample(mode: MobilityModeStatus())
                .codex
                .isRunning == false
        )

        let samplerWithUserTask = MacSystemSampler(
            deviceID: UUID(),
            deviceName: "Test Mac",
            guiCodexIsRunning: { false },
            codexCLIProcessInspector: StubCodexProcessInspector(processes: [
                CodexProcessRecord(
                    processIdentifier: polisherPID,
                    executablePath: "/usr/local/bin/codex"
                ),
                CodexProcessRecord(
                    processIdentifier: userTaskPID,
                    executablePath: "/usr/local/bin/codex"
                )
            ]),
            codexCLIProcessIsIgnored: { $0 == polisherPID }
        )
        #expect(
            samplerWithUserTask
                .sample(mode: MobilityModeStatus())
                .codex
                .isRunning
        )
    }

    @Test
    func policyPersistenceUsesInjectedDefaultsSuiteAndNormalizes() throws {
        let suiteName = "CodexMobilityPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = UserDefaultsMobilityPolicyPersistence(defaults: defaults)
        let unnormalized = MobilityPolicy(
            lowBatteryThresholdPercent: 1,
            maximumDurationSeconds: 1,
            networkDisconnectGraceSeconds: .infinity,
            requiresCodexRunning: false
        )

        persistence.savePolicy(unnormalized)

        #expect(persistence.loadPolicy() == unnormalized.normalized())
        #expect(defaults.data(forKey: UserDefaultsMobilityPolicyPersistence.policyKey) != nil)
        #expect(defaults.object(forKey: "CodexMobility.macDeviceID") == nil)
    }

    @Test @MainActor
    func storeLoadsAndSavesThroughInjectedPolicyPersistence() {
        let persisted = MobilityPolicy(
            lowBatteryThresholdPercent: 45,
            maximumDurationSeconds: 90 * 60,
            networkDisconnectGraceSeconds: 5 * 60,
            requiresCodexRunning: false
        )
        let persistence = InMemoryPolicyPersistence(storedPolicy: persisted)
        let store = MacMobilityStore(
            policyPersistence: persistence,
            pollingInterval: 60
        )
        defer { store.shutdown() }

        #expect(store.policy == persisted.normalized())

        let updated = MobilityPolicy(
            lowBatteryThresholdPercent: 50,
            maximumDurationSeconds: 3 * 60 * 60,
            networkDisconnectGraceSeconds: 2 * 60,
            requiresCodexRunning: true
        )
        store.updatePolicy(updated)

        #expect(persistence.savedPolicies == [updated.normalized()])
        #expect(store.policy == updated.normalized())
    }

    @Test
    func publicIdleSleepAssertionAcquiresAndReleases() throws {
        let controller = IdleSleepAssertionController()

        #expect(controller.isActive == false)
        #expect(controller.isAppNapSuppressed == false)
        try controller.acquire(reason: "CodexWatchPet test assertion")
        #expect(controller.isActive)
        #expect(controller.isAppNapSuppressed)

        controller.release()
        #expect(controller.isActive == false)
        #expect(controller.isAppNapSuppressed == false)
    }

    @Test @MainActor
    func pollingSlowsWhileIdleAndReturnsToFiveSecondsInMobilityMode() {
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Adaptive polling Mac",
            battery: MobilityBatteryStatus(levelPercent: 80),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true)
        )
        let store = MacMobilityStore(
            sampler: StubMacSystemSampler(status: status),
            policyPersistence: InMemoryPolicyPersistence()
        )
        defer { store.shutdown() }

        #expect(store.effectivePollingInterval == 30)
        store.start()
        #expect(store.mode.phase == .active)
        #expect(store.effectivePollingInterval == 5)
        store.stop()
        #expect(store.effectivePollingInterval == 30)
    }

    @Test @MainActor
    func closedLidLabsStaysBlockedWithoutSystemPolicy() {
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Test Mac",
            battery: MobilityBatteryStatus(levelPercent: 80),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            helperReady: false
        )
        let store = MacMobilityStore(
            sampler: StubMacSystemSampler(status: status),
            policyPersistence: InMemoryPolicyPersistence(),
            pollingInterval: 60
        )
        defer { store.shutdown() }

        store.start(profile: .closedLidLabs)

        #expect(store.mode.phase == .blocked)
        #expect(store.mode.profile == .closedLidLabs)
        #expect(store.isAssertionActive == false)
        #expect(store.lastStopReason?.contains("系统级合盖续跑策略尚未开启") == true)
    }

    @Test @MainActor
    func closedLidLabsRunsWhenSystemPolicyIsDetected() {
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Test Mac",
            battery: MobilityBatteryStatus(levelPercent: 80),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            helperReady: true
        )
        let store = MacMobilityStore(
            sampler: StubMacSystemSampler(status: status),
            policyPersistence: InMemoryPolicyPersistence(),
            pollingInterval: 60
        )
        defer { store.shutdown() }

        store.start(profile: .closedLidLabs)

        #expect(store.mode.phase == .active)
        #expect(store.mode.profile == .closedLidLabs)
        #expect(store.isAssertionActive)
        #expect(store.lastStopReason == nil)
    }

    @Test @MainActor
    func timedClosedLidLeaseStartsDegradedOfflineAndOutlivesNetworkGrace() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let policy = MobilityPolicy(
            lowBatteryThresholdPercent: 35,
            maximumDurationSeconds: 2 * 60 * 60,
            networkDisconnectGraceSeconds: 60,
            requiresCodexRunning: true
        )
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Offline closed-lid Mac",
            battery: MobilityBatteryStatus(levelPercent: 80),
            network: MobilityNetworkStatus(
                kind: .offline,
                isConnected: false,
                disconnectedSince: startedAt
            ),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            mode: MobilityModeStatus(policy: policy),
            helperReady: true,
            observedAt: startedAt
        )
        let sampler = StubMacSystemSampler(status: status)
        let store = MacMobilityStore(
            sampler: sampler,
            policy: policy,
            policyPersistence: InMemoryPolicyPersistence(),
            pollingInterval: 60
        )
        defer { store.shutdown() }

        store.setTimedClosedLidLeaseActive(true)
        store.start(
            profile: .closedLidLabs,
            maximumDurationSeconds: 2 * 60 * 60,
            now: startedAt
        )

        #expect(store.mode.phase == .degraded)
        #expect(store.isAssertionActive)
        #expect(store.lastPreflightBlockers.isEmpty)
        #expect(store.mode.detail?.contains("热点守护正在重连") == true)

        store.refreshNow(now: startedAt.addingTimeInterval(61))

        #expect(store.mode.phase == .degraded)
        #expect(store.isAssertionActive)
        #expect(store.lastStopReason == nil)

        sampler.sampledStatus.network = MobilityNetworkStatus(
            kind: .wifi,
            isConnected: true
        )
        store.refreshNow(now: startedAt.addingTimeInterval(62))

        #expect(store.mode.phase == .active)
        #expect(store.isAssertionActive)
    }

    @Test @MainActor
    func untimedClosedLidModeStillBlocksWhenOffline() {
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Untimed closed-lid Mac",
            battery: MobilityBatteryStatus(levelPercent: 80),
            network: MobilityNetworkStatus(kind: .offline, isConnected: false),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            helperReady: true
        )
        let store = MacMobilityStore(
            sampler: StubMacSystemSampler(status: status),
            policyPersistence: InMemoryPolicyPersistence(),
            pollingInterval: 60
        )
        defer { store.shutdown() }

        store.start(profile: .closedLidLabs)

        #expect(store.mode.phase == .blocked)
        #expect(!store.isAssertionActive)
        #expect(store.lastPreflightBlockers == [.networkUnavailable])
    }

    @Test @MainActor
    func disablingClosedLidExperimentReleasesOnlyItsAppIdleGuard() {
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Test Mac",
            battery: MobilityBatteryStatus(levelPercent: 80),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            helperReady: true
        )
        let store = MacMobilityStore(
            sampler: StubMacSystemSampler(status: status),
            policyPersistence: InMemoryPolicyPersistence(),
            pollingInterval: 60
        )
        defer { store.shutdown() }
        let adapter = MacClosedLidLabsModuleAdapter(store: store)

        store.start(profile: .closedLidLabs)
        #expect(store.isAssertionActive)

        adapter.stop()

        #expect(store.mode.phase == .off)
        #expect(!store.isAssertionActive)
        #expect(store.lastStopReason?.contains("实验模块已在设置中关闭") == true)
        #expect(store.lastStopReason?.contains("系统级合盖策略仍保持") == true)
        #expect(store.lastStopReason?.contains("手动关闭") == true)
    }

    @Test @MainActor
    func disablingClosedLidExperimentDoesNotStopOrdinaryIdleGuard() {
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Test Mac",
            battery: MobilityBatteryStatus(levelPercent: 80),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            helperReady: true
        )
        let store = MacMobilityStore(
            sampler: StubMacSystemSampler(status: status),
            policyPersistence: InMemoryPolicyPersistence(),
            pollingInterval: 60
        )
        defer { store.shutdown() }
        let adapter = MacClosedLidLabsModuleAdapter(store: store)

        store.start(profile: .idleGuard)
        adapter.stop()

        #expect(store.mode.phase == .active)
        #expect(store.mode.profile == .idleGuard)
        #expect(store.isAssertionActive)
    }

    @Test @MainActor
    func stoppingClosedLidMonitoringDoesNotClaimGlobalPolicyWasReverted() {
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Test Mac",
            battery: MobilityBatteryStatus(levelPercent: 80),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            helperReady: true
        )
        let store = MacMobilityStore(
            sampler: StubMacSystemSampler(status: status),
            policyPersistence: InMemoryPolicyPersistence(),
            pollingInterval: 60
        )
        defer { store.shutdown() }

        store.start(profile: .closedLidLabs)
        store.stop(reason: "已达到低电量停止阈值。")

        #expect(store.mode.phase == .off)
        #expect(!store.isAssertionActive)
        #expect(store.lastStopReason?.contains("系统级合盖策略仍保持") == true)
        #expect(store.lastStopReason?.contains("手动关闭") == true)
    }

    @Test @MainActor
    func lowBatteryStopsLocallyAndReleasesAssertion() {
        let fixture = makeActiveFixture()
        defer { fixture.store.shutdown() }

        fixture.sampler.sampledStatus.battery = MobilityBatteryStatus(levelPercent: 35)
        fixture.store.refreshNow(now: fixture.startedAt.addingTimeInterval(1))

        #expect(fixture.store.mode.phase == .off)
        #expect(fixture.store.isAssertionActive == false)
        #expect(fixture.store.lastStopReason?.contains("电量") == true)
    }

    @Test @MainActor
    func externalPowerDoesNotTriggerLowBatteryCutoff() {
        let fixture = makeActiveFixture()
        defer { fixture.store.shutdown() }

        fixture.sampler.sampledStatus.battery = MobilityBatteryStatus(
            levelPercent: 5,
            isCharging: true,
            isOnExternalPower: true
        )
        fixture.store.refreshNow(now: fixture.startedAt.addingTimeInterval(1))

        #expect(fixture.store.mode.phase == .active)
        #expect(fixture.store.isAssertionActive)
    }

    @Test @MainActor
    func criticalThermalStateStopsImmediately() {
        let fixture = makeActiveFixture()
        defer { fixture.store.shutdown() }

        fixture.sampler.sampledStatus.thermalState = .critical
        fixture.store.refreshNow(now: fixture.startedAt.addingTimeInterval(1))

        #expect(fixture.store.mode.phase == .off)
        #expect(fixture.store.isAssertionActive == false)
        #expect(fixture.store.lastStopReason?.contains("临界") == true)
    }

    @Test @MainActor
    func sustainedSeriousThermalStateStopsAfterGrace() {
        let fixture = makeActiveFixture()
        defer { fixture.store.shutdown() }

        fixture.sampler.sampledStatus.thermalState = .serious
        fixture.store.refreshNow(now: fixture.startedAt.addingTimeInterval(1))
        #expect(fixture.store.mode.phase == .degraded)

        fixture.store.refreshNow(
            now: fixture.startedAt.addingTimeInterval(
                1 + MacMobilityStore.thermalSeriousGraceSeconds
            )
        )

        #expect(fixture.store.mode.phase == .off)
        #expect(fixture.store.isAssertionActive == false)
        #expect(fixture.store.lastStopReason?.contains("严重热状态") == true)
    }

    @Test @MainActor
    func networkGraceExpiresLocally() {
        let fixture = makeActiveFixture(
            policy: MobilityPolicy(
                lowBatteryThresholdPercent: 35,
                maximumDurationSeconds: 2 * 60 * 60,
                networkDisconnectGraceSeconds: 60,
                requiresCodexRunning: true
            )
        )
        defer { fixture.store.shutdown() }

        fixture.sampler.sampledStatus.network = MobilityNetworkStatus(
            kind: .offline,
            isConnected: false,
            disconnectedSince: fixture.startedAt
        )
        fixture.store.refreshNow(now: fixture.startedAt.addingTimeInterval(30))
        #expect(fixture.store.mode.phase == .degraded)

        fixture.store.refreshNow(now: fixture.startedAt.addingTimeInterval(60))
        #expect(fixture.store.mode.phase == .off)
        #expect(fixture.store.isAssertionActive == false)
        #expect(fixture.store.lastStopReason?.contains("网络断开") == true)
    }

    @Test @MainActor
    func maximumDurationStopsLocally() {
        let fixture = makeActiveFixture(
            policy: MobilityPolicy(
                lowBatteryThresholdPercent: 35,
                maximumDurationSeconds: MobilityPolicy.minimumAllowedDurationSeconds,
                networkDisconnectGraceSeconds: 60,
                requiresCodexRunning: true
            )
        )
        defer { fixture.store.shutdown() }

        fixture.store.refreshNow(
            now: fixture.startedAt.addingTimeInterval(MobilityPolicy.minimumAllowedDurationSeconds)
        )

        #expect(fixture.store.mode.phase == .off)
        #expect(fixture.store.isAssertionActive == false)
        #expect(fixture.store.lastStopReason?.contains("最长运行时长") == true)
    }

    @Test @MainActor
    func codexExitStopsLocally() {
        let fixture = makeActiveFixture()
        defer { fixture.store.shutdown() }

        fixture.sampler.sampledStatus.codex = MobilityCodexStatus(isRunning: false)
        fixture.store.refreshNow(now: fixture.startedAt.addingTimeInterval(1))

        #expect(fixture.store.mode.phase == .off)
        #expect(fixture.store.isAssertionActive == false)
        #expect(fixture.store.lastStopReason?.contains("Codex 已退出") == true)
    }

    @MainActor
    private func makeActiveFixture(
        policy: MobilityPolicy = .recommended
    ) -> (store: MacMobilityStore, sampler: StubMacSystemSampler, startedAt: Date) {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let status = MobilityDeviceStatus(
            deviceID: UUID(),
            deviceName: "Test Mac",
            battery: MobilityBatteryStatus(levelPercent: 80),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true),
            mode: MobilityModeStatus(policy: policy),
            observedAt: startedAt
        )
        let sampler = StubMacSystemSampler(status: status)
        let store = MacMobilityStore(
            sampler: sampler,
            policy: policy,
            policyPersistence: InMemoryPolicyPersistence(),
            pollingInterval: 60
        )
        store.start(now: startedAt)
        #expect(store.mode.phase == .active)
        #expect(store.isAssertionActive)
        return (store, sampler, startedAt)
    }
}

@Suite("Mobility BLE pairing security")
struct MobilityPairingGateTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Pairing window and code TTL expire independently")
    func windowAndCodeExpiration() {
        var gate = MobilityPairingGate(windowDuration: 300, codeTTL: 60)

        #expect(gate.snapshot(at: start).isOpen == false)
        gate.open(at: start)
        #expect(gate.snapshot(at: start.addingTimeInterval(59)).isOpen)
        #expect(gate.snapshot(at: start).expiresAt == start.addingTimeInterval(60))
        #expect(
            gate.attempt(
                providedCode: "123456",
                expectedCode: "123456",
                at: start.addingTimeInterval(60)
            ) == .codeExpired
        )
    }

    @Test("A correct code is consumed and closes pairing immediately")
    func successfulCodeIsOneTime() {
        var gate = MobilityPairingGate()
        gate.open(at: start)
        #expect(gate.snapshot(at: start).expiresAt == start.addingTimeInterval(5 * 60))

        #expect(
            gate.attempt(
                providedCode: "042731",
                expectedCode: "042731",
                at: start.addingTimeInterval(1)
            ) == .accepted
        )
        #expect(gate.snapshot(at: start.addingTimeInterval(1)).isOpen == false)
        #expect(
            gate.attempt(
                providedCode: "042731",
                expectedCode: "042731",
                at: start.addingTimeInterval(2)
            ) == .windowClosed
        )
    }

    @Test("Repeated failures lock pairing with bounded exponential backoff")
    func failuresTriggerBackoff() {
        var gate = MobilityPairingGate(
            windowDuration: 300,
            codeTTL: 300,
            maximumFailedAttempts: 3,
            initialLockoutDuration: 30,
            maximumLockoutDuration: 120
        )
        gate.open(at: start)

        #expect(attemptWrongCode(&gate, offset: 0) == .invalidCode(remainingAttempts: 2))
        #expect(attemptWrongCode(&gate, offset: 1) == .invalidCode(remainingAttempts: 1))
        let firstLockDeadline = start.addingTimeInterval(32)
        #expect(attemptWrongCode(&gate, offset: 2) == .locked(until: firstLockDeadline))
        #expect(
            gate.attempt(
                providedCode: "123456",
                expectedCode: "123456",
                at: start.addingTimeInterval(3)
            ) == .locked(until: firstLockDeadline)
        )

        #expect(attemptWrongCode(&gate, offset: 33) == .invalidCode(remainingAttempts: 2))
        #expect(attemptWrongCode(&gate, offset: 34) == .invalidCode(remainingAttempts: 1))
        let secondLockDeadline = start.addingTimeInterval(95)
        #expect(attemptWrongCode(&gate, offset: 35) == .locked(until: secondLockDeadline))
    }

    @Test("Opening a fresh window resets failures and lockout")
    func reopeningResetsSecurityState() {
        var gate = MobilityPairingGate(maximumFailedAttempts: 3)
        gate.open(at: start)
        _ = attemptWrongCode(&gate, offset: 0)
        _ = attemptWrongCode(&gate, offset: 1)

        let reopenedAt = start.addingTimeInterval(5)
        gate.open(at: reopenedAt)

        let snapshot = gate.snapshot(at: reopenedAt)
        #expect(snapshot.isOpen)
        #expect(snapshot.failedAttemptCount == 0)
        #expect(snapshot.lockedUntil == nil)
        #expect(attemptWrongCode(&gate, offset: 6) == .invalidCode(remainingAttempts: 2))
    }

    private func attemptWrongCode(
        _ gate: inout MobilityPairingGate,
        offset: TimeInterval
    ) -> MobilityPairingAttemptResult {
        gate.attempt(
            providedCode: "000000",
            expectedCode: "123456",
            at: start.addingTimeInterval(offset)
        )
    }
}
