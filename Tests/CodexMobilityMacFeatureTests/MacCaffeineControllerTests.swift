@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Independent caffeine sessions")
@MainActor
struct MacCaffeineControllerTests {
    @Test func durationIsRememberedButSessionDoesNotRestart() {
        let f = Fixture()
        defer { f.cleanup() }
        f.controller.setMode(.indefinite)
        f.controller.setEnabled(true)
        #expect(f.runner.starts == 1 && f.runner.timeout == nil)
        let reopened = MacCaffeineController(runner: TestCaffeineRunner(), defaults: f.defaults)
        #expect(reopened.mode == .indefinite)
        #expect(!reopened.isActive)
        #expect(reopened.expiresAt == nil)
    }

    @Test func timedSessionExpiresAndReleasesOnlyItsRunner() {
        let f = Fixture()
        defer { f.cleanup() }
        f.controller.setDurationMinutes(15)
        f.controller.setEnabled(true)
        #expect(f.runner.timeout == 900)
        #expect(f.controller.expiresAt == f.clock.date.addingTimeInterval(900))
        f.clock.date.addTimeInterval(899)
        f.controller.checkExpiration()
        #expect(f.controller.isActive)
        f.clock.date.addTimeInterval(1)
        f.controller.checkExpiration()
        #expect(!f.controller.isActive && !f.runner.running)
        #expect(f.controller.status.contains("已到期"))
    }

    @Test func duplicateEnableAndDelayedOldExitCannotEndNewSession() {
        let f = Fixture()
        defer { f.cleanup() }
        f.controller.setEnabled(true)
        f.controller.setEnabled(true)
        #expect(f.runner.starts == 1)
        let oldCompletion = f.runner.onExit
        f.controller.stop()
        f.controller.setMode(.indefinite)
        f.controller.setEnabled(true)
        oldCompletion?(15)
        #expect(f.controller.isActive && f.runner.running)
        f.controller.setDurationMinutes(15)
        f.controller.setMode(.timed)
        #expect(f.controller.mode == .indefinite)
        #expect(f.controller.durationMinutes == 240)
        f.controller.stop()
        #expect(!f.controller.isActive && !f.runner.running)
    }

    @Test func launchFailureAndUnexpectedExitAreVisible() {
        let f = Fixture()
        defer { f.cleanup() }
        f.runner.fail = true
        f.controller.setEnabled(true)
        #expect(!f.controller.isActive)
        #expect(f.controller.errorMessage != nil)
        f.runner.fail = false
        f.controller.setEnabled(true)
        #expect(f.controller.errorMessage == nil)
        f.runner.onExit?(9)
        #expect(!f.controller.isActive)
        #expect(f.controller.errorMessage != nil)
    }

    @Test func nativeTimeoutExitAndUIExpiryHaveSameResult() {
        let f = Fixture()
        defer { f.cleanup() }
        f.controller.setDurationMinutes(15)
        f.controller.setEnabled(true)
        f.clock.date.addTimeInterval(900)
        f.runner.onExit?(0)
        #expect(!f.controller.isActive)
        #expect(f.controller.errorMessage == nil)
        #expect(f.controller.status.contains("已到期"))
    }

    @Test func invalidSavedDurationFallsBackToFourHours() {
        let f = Fixture()
        defer { f.cleanup() }
        f.defaults.set(-1, forKey: MacCaffeineController.minutesKey)
        let controller = MacCaffeineController(runner: TestCaffeineRunner(), defaults: f.defaults)
        #expect(controller.durationMinutes == 240)
        controller.setDurationMinutes(0)
        #expect(controller.durationMinutes == 240)
    }

    @Test func mobileOfficeBorrowsAndRestoresManualRemainingTime() {
        let f = Fixture()
        defer { f.cleanup() }
        f.controller.setDurationMinutes(120)
        f.controller.setEnabled(true)
        let originalDeadline = f.controller.expiresAt
        #expect(f.controller.beginMobileOffice(expiresAt: nil))
        #expect(f.controller.isManagedByMobileOffice && f.runner.timeout == nil)
        f.controller.setEnabled(false)
        #expect(f.controller.isActive)
        f.clock.date.addTimeInterval(600)
        f.controller.endMobileOffice()
        #expect(f.controller.isActive && !f.controller.isManagedByMobileOffice)
        #expect(f.controller.expiresAt == originalDeadline)
        #expect(f.runner.timeout == 6600)
    }

    @Test func mobileOfficeReleasesOnlyItsOwnCaffeineAndDoesNotReviveExpiredManualSession() {
        let f = Fixture()
        defer { f.cleanup() }
        #expect(f.controller.beginMobileOffice(expiresAt: nil))
        f.controller.endMobileOffice()
        #expect(!f.controller.isActive)
        f.controller.setDurationMinutes(15)
        f.controller.setEnabled(true)
        #expect(f.controller.beginMobileOffice(expiresAt: nil))
        f.clock.date.addTimeInterval(1000)
        f.controller.endMobileOffice()
        #expect(!f.controller.isActive)
    }

    @MainActor private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @MainActor private struct Fixture {
        let suite = "caffeine-tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let runner = TestCaffeineRunner()
        let clock = Clock()
        let controller: MacCaffeineController
        init() {
            defaults = UserDefaults(suiteName: suite)!
            let clock = self.clock
            controller = MacCaffeineController(runner: runner, defaults: defaults, now: { clock.date })
        }
        func cleanup() {
            controller.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
private final class TestCaffeineRunner: MacCaffeineRunning {
    var starts = 0
    var timeout: Int?
    var running = false
    var fail = false
    var onExit: (@MainActor @Sendable (Int32) -> Void)?
    func start(timeoutSeconds: Int?, onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws {
        if fail { throw CocoaError(.executableNotLoadable) }
        starts += 1
        timeout = timeoutSeconds
        running = true
        self.onExit = onExit
    }
    func stop() { running = false }
}
