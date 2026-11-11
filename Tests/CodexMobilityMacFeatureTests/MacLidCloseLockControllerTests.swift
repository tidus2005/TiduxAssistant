@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mac lid-close delayed lock")
@MainActor
struct MacLidCloseLockControllerTests {
    @Test func stoppingMobileOfficeBeforeQueuedSleepPreventsLateDisplayAction() async throws {
        let display = FakeDisplaySleepRequester()
        let controller = makeController(display: display)
        defer { controller.stop() }
        controller.observeLidState(true)
        controller.setMobileOfficePowerSaving(true)
        controller.setMobileOfficePowerSaving(false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await display.requestCount == 0)
    }

    @Test func mobileOfficeSleepsDisplayWithoutEnablingOrChangingLockRule() async throws {
        let display = FakeDisplaySleepRequester()
        let lock = FakeScreenLockRequester()
        let controller = makeController(display: display, lock: lock)
        defer { controller.stop() }
        controller.observeLidState(false)
        controller.setMobileOfficePowerSaving(true)
        #expect(await display.requestCount == 0)
        controller.observeLidState(true)
        controller.observeLidState(true)
        try await waitUntil { await display.requestCount == 1 }
        #expect(controller.delaySeconds == nil)
        #expect(await lock.requestCount == 0)
        controller.setMobileOfficePowerSaving(false)
        controller.observeLidState(false)
        controller.observeLidState(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await display.requestCount == 1)
    }

    @Test func mobileOfficePreservesConfiguredLockAndAvoidsDuplicateDisplaySleep() async throws {
        let display = FakeDisplaySleepRequester()
        let lock = FakeScreenLockRequester()
        let controller = makeController(display: display, lock: lock)
        defer { controller.stop() }
        try controller.updateDelaySeconds(0)
        controller.observeLidState(false)
        controller.setMobileOfficePowerSaving(true)
        controller.observeLidState(true)
        try await waitUntil { await lock.requestCount == 1 }
        #expect(await display.requestCount == 1)
        #expect(controller.delaySeconds == 0)
    }

    @Test("startup only establishes the current lid baseline")
    func initialClosedStateDoesNotTriggerActions() async throws {
        let display = FakeDisplaySleepRequester()
        let lock = FakeScreenLockRequester()
        let controller = makeController(display: display, lock: lock)
        try controller.updateDelaySeconds(0)

        controller.observeLidState(true)
        try await Task.sleep(for: .milliseconds(30))

        #expect(await display.requestCount == 0)
        #expect(await lock.requestCount == 0)
    }

    @Test("an open-to-closed transition sleeps the display and locks")
    func closeTransitionTriggersConfiguredActions() async throws {
        let display = FakeDisplaySleepRequester()
        let lock = FakeScreenLockRequester()
        let controller = makeController(display: display, lock: lock)
        try controller.updateDelaySeconds(0)
        controller.observeLidState(false)

        controller.observeLidState(true)
        try await waitUntil {
            let displayCount = await display.requestCount
            let lockCount = await lock.requestCount
            return displayCount == 1 && lockCount == 1
                && controller.snapshot().status.contains("已锁定屏幕")
        }

        #expect(controller.pendingLockAt == nil)
        #expect(controller.snapshot().status.contains("已锁定屏幕"))
    }

    @Test("opening the lid cancels a pending delayed lock")
    func openingCancelsPendingLock() async throws {
        let display = FakeDisplaySleepRequester()
        let lock = FakeScreenLockRequester()
        let controller = makeController(display: display, lock: lock)
        try controller.updateDelaySeconds(15)
        controller.observeLidState(false)

        controller.observeLidState(true)
        #expect(controller.pendingLockAt != nil)
        controller.observeLidState(false)
        try await Task.sleep(for: .milliseconds(30))

        #expect(controller.pendingLockAt == nil)
        #expect(await lock.requestCount == 0)
        #expect(controller.snapshot().status.contains("取消"))
    }

    @Test("disabled and unsupported values are persisted safely")
    func persistsSettingsAndRejectsForgedValues() throws {
        let persistence = FakeLidCloseLockPersistence()
        let controller = makeController(persistence: persistence)

        try controller.updateDelaySeconds(300)
        #expect(persistence.delaySeconds == 300)
        try controller.updateDelaySeconds(nil)
        #expect(persistence.delaySeconds == nil)
        #expect(throws: MacLidCloseLockError.unsupportedDelay(999)) {
            try controller.updateDelaySeconds(999)
        }
    }

    @Test("AI desktop mode cancels pending locks and suppresses later lid actions")
    func agentDesktopSuspendsAndRestoresLockRule() async throws {
        let display = FakeDisplaySleepRequester()
        let lock = FakeScreenLockRequester()
        let controller = makeController(display: display, lock: lock)
        try controller.updateDelaySeconds(15)
        controller.observeLidState(false)
        controller.observeLidState(true)
        #expect(controller.pendingLockAt != nil)
        controller.setAgentDesktopSuppressed(true)
        #expect(controller.pendingLockAt == nil)
        controller.observeLidState(false)
        controller.observeLidState(true)
        try controller.updateDelaySeconds(30)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await lock.requestCount == 0)
        #expect(await display.requestCount == 0)
        #expect(controller.pendingLockAt == nil)
        controller.setAgentDesktopSuppressed(false)
        #expect(controller.pendingLockAt != nil)
        #expect(controller.delaySeconds == 30)
        controller.stop()
    }

    private func makeController(
        display: FakeDisplaySleepRequester = FakeDisplaySleepRequester(),
        lock: FakeScreenLockRequester = FakeScreenLockRequester(),
        persistence: FakeLidCloseLockPersistence = FakeLidCloseLockPersistence()
    ) -> MacLidCloseLockController {
        MacLidCloseLockController(
            lidStateReader: FixedLidStateReader(isClosed: false),
            displaySleepRequester: display,
            screenLockRequester: lock,
            persistence: persistence,
            monitorInterval: 60
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("等待合盖动作执行超时")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct FixedLidStateReader: MacLidStateReading {
    let isClosed: Bool

    func isLidClosed() throws -> Bool { isClosed }
}

private actor FakeDisplaySleepRequester: MacDisplaySleepRequesting {
    private(set) var requestCount = 0

    func requestDisplaySleep() async throws {
        requestCount += 1
    }
}

private actor FakeScreenLockRequester: MacScreenLockRequesting {
    private(set) var requestCount = 0

    func requestScreenLock() async throws {
        requestCount += 1
    }
}

private final class FakeLidCloseLockPersistence: MacLidCloseLockSettingsPersisting {
    var delaySeconds: Int?

    func loadDelaySeconds() -> Int? { delaySeconds }

    func saveDelaySeconds(_ seconds: Int?) {
        delaySeconds = seconds
    }
}
