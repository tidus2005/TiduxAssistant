@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mac remote dashboard screen lock")
struct MacRemoteDashboardScreenLockServiceTests {
    @Test("pmset custom output keeps battery and power-adapter timers distinct")
    func parsesDisplaySleepByPowerSource() throws {
        let parsed = try #require(LocalMacScreenLockSettingsBackend.parseDisplaySleep("""
        Battery Power:
         displaysleep         30
         sleep                0
        AC Power:
         displaysleep         150
         sleep                0
        """))

        #expect(parsed.battery == 30)
        #expect(parsed.powerAdapter == 150)
        #expect(LocalMacScreenLockSettingsBackend.parseDisplaySleep("sleep 0") == nil)
    }

    @Test("sysadminctl status recognizes immediate, delayed and disabled password policies")
    func parsesScreenLockStatus() {
        #expect(
            LocalMacScreenLockSettingsBackend.parseScreenLockStatus(
                "screenLock delay is immediate"
            )?.delaySeconds == 0
        )
        #expect(
            LocalMacScreenLockSettingsBackend.parseScreenLockStatus(
                "screenLock delay is 300 seconds"
            )?.delaySeconds == 300
        )
        #expect(
            LocalMacScreenLockSettingsBackend.parseScreenLockStatus(
                "screenLock is off"
            )?.requiresPassword == false
        )
        #expect(
            LocalMacScreenLockSettingsBackend.parseScreenLockStatus("unknown") == nil
        )
    }

    @Test("unchanged password policy lets both display timers update without password mutation")
    func appliesDisplaySleepAndPreservesPasswordPolicy() async {
        let backend = FakeScreenLockSettingsBackend(configuration: currentConfiguration)
        let service = MacRemoteDashboardScreenLockService(backend: backend)
        let request = MacRemoteDashboardScreenLockUpdateRequest(
            batteryDisplaySleepMinutes: 10,
            powerAdapterDisplaySleepMinutes: 60,
            passwordDelaySeconds: 0
        )

        let response = await service.apply(request)

        #expect(response.ok)
        #expect(response.settings.batteryDisplaySleepMinutes == 10)
        #expect(response.settings.powerAdapterDisplaySleepMinutes == 60)
        #expect(response.settings.passwordDelaySeconds == 0)
        #expect(await backend.configuration == MacScreenLockConfiguration(
            batteryDisplaySleepMinutes: 10,
            powerAdapterDisplaySleepMinutes: 60,
            requiresPassword: true,
            passwordDelaySeconds: 0
        ))
        #expect(await backend.displaySleepMutationCount == 1)
        #expect(await backend.passwordMutationCount == 0)
    }

    @Test("a password policy change is rejected before any system mutation")
    func rejectsPasswordPolicyChangeBeforeMutation() async {
        let backend = FakeScreenLockSettingsBackend(configuration: currentConfiguration)
        let service = MacRemoteDashboardScreenLockService(backend: backend)

        let response = await service.apply(.init(
            batteryDisplaySleepMinutes: 5,
            powerAdapterDisplaySleepMinutes: 30,
            passwordDelaySeconds: 900
        ))

        #expect(!response.ok)
        #expect(await backend.configuration == currentConfiguration)
        #expect(response.settings.batteryDisplaySleepMinutes == 30)
        #expect(response.settings.powerAdapterDisplaySleepMinutes == 150)
        #expect(response.settings.passwordDelaySeconds == 0)
        #expect(response.message.contains("系统设置 → 锁定屏幕"))
        #expect(await backend.mutationCount == 0)
    }

    @Test("display timers remain configurable when password requirement is disabled")
    func updatesDisplaySleepWhenPasswordRequirementIsDisabled() async {
        let disabledConfiguration = MacScreenLockConfiguration(
            batteryDisplaySleepMinutes: 30,
            powerAdapterDisplaySleepMinutes: 150,
            requiresPassword: false,
            passwordDelaySeconds: nil
        )
        let backend = FakeScreenLockSettingsBackend(configuration: disabledConfiguration)
        let service = MacRemoteDashboardScreenLockService(backend: backend)

        let response = await service.apply(.init(
            batteryDisplaySleepMinutes: 10,
            powerAdapterDisplaySleepMinutes: 60,
            passwordDelaySeconds: nil
        ))
        #expect(response.ok)
        #expect(response.settings.requiresPassword == false)
        #expect(response.settings.passwordDelaySeconds == nil)
        #expect(await backend.displaySleepMutationCount == 1)
        #expect(await backend.passwordMutationCount == 0)
    }

    @Test("forged values are rejected before reaching the privileged backend")
    func rejectsValuesOutsideTheAllowlist() async {
        let backend = FakeScreenLockSettingsBackend(configuration: currentConfiguration)
        let service = MacRemoteDashboardScreenLockService(backend: backend)

        let response = await service.apply(.init(
            batteryDisplaySleepMinutes: 999,
            powerAdapterDisplaySleepMinutes: 30,
            passwordDelaySeconds: 0
        ))

        #expect(!response.ok)
        #expect(await backend.configuration == currentConfiguration)
        #expect(await backend.mutationCount == 0)
    }

    @Test("forged lid-close delays are rejected before any system mutation")
    func rejectsUnsupportedLidCloseDelay() async {
        let backend = FakeScreenLockSettingsBackend(configuration: currentConfiguration)
        let service = MacRemoteDashboardScreenLockService(backend: backend)

        let response = await service.apply(.init(
            batteryDisplaySleepMinutes: 30,
            powerAdapterDisplaySleepMinutes: 150,
            passwordDelaySeconds: 0,
            lidCloseLockDelaySeconds: 999
        ))

        #expect(!response.ok)
        #expect(await backend.mutationCount == 0)
    }

    private var currentConfiguration: MacScreenLockConfiguration {
        MacScreenLockConfiguration(
            batteryDisplaySleepMinutes: 30,
            powerAdapterDisplaySleepMinutes: 150,
            requiresPassword: true,
            passwordDelaySeconds: 0
        )
    }
}

private actor FakeScreenLockSettingsBackend: MacScreenLockSettingsBackend {
    private(set) var configuration: MacScreenLockConfiguration
    private(set) var mutationCount = 0
    private(set) var displaySleepMutationCount = 0
    private(set) var passwordMutationCount = 0
    private var passwordFailuresRemaining = 0

    init(configuration: MacScreenLockConfiguration) {
        self.configuration = configuration
    }

    func loadConfiguration() async throws -> MacScreenLockConfiguration {
        configuration
    }

    func setDisplaySleep(
        batteryMinutes: Int,
        powerAdapterMinutes: Int
    ) async throws {
        mutationCount += 1
        displaySleepMutationCount += 1
        configuration.batteryDisplaySleepMinutes = batteryMinutes
        configuration.powerAdapterDisplaySleepMinutes = powerAdapterMinutes
    }

    func setScreenLockDelay(seconds: Int?) async throws {
        mutationCount += 1
        passwordMutationCount += 1
        if passwordFailuresRemaining > 0 {
            passwordFailuresRemaining -= 1
            throw MacSystemPowerPolicyError.commandFailed("模拟密码策略失败")
        }
        configuration.requiresPassword = seconds != nil
        configuration.passwordDelaySeconds = seconds
    }

    func failNextPasswordUpdate() {
        passwordFailuresRemaining = 1
    }
}
