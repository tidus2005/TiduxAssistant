@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("AI desktop session protection")
@MainActor
struct MacAgentDesktopControllerTests {
    @Test func mobileOfficeDimsOnLidCloseAndRestoresWithoutChangingAuthentication() async throws {
        let name = "mobile-office-brightness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let brightness = TestLidBrightnessController()
        let keeper = TestAgentDisplayKeeper()
        let controller = MacAgentDesktopController(
            checker: TestAgentDesktopChecker(reason: "password"),
            displayKeeper: keeper, defaults: defaults, brightness: brightness)
        try await controller.beginSession(required: true, dimOnLidClose: true)
        #expect(controller.isActive)
        #expect(!controller.isEnabled)
        #expect(controller.needsAttention)
        controller.observeLidState(false)
        #expect(brightness.events == ["prepare"])
        controller.observeLidState(true)
        controller.observeLidState(true)
        #expect(brightness.events == ["prepare", "dim"])
        await controller.checkReadiness()
        #expect(controller.isActive && keeper.held)
        controller.observeLidState(false)
        #expect(brightness.events == ["prepare", "dim", "restore", "prepare"])
        controller.observeLidState(true)
        controller.endSession()
        #expect(brightness.events.suffix(2) == ["dim", "restore"])
        #expect(!keeper.held)
        #expect(!defaults.bool(forKey: MacAgentDesktopController.preferenceKey))
    }

    @Test func defaultOffNeverAcquiresAssertion() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try await fixture.controller.beginSession()
        #expect(!fixture.controller.isActive)
        #expect(fixture.keeper.begins == 0)
    }

    @Test(arguments: ["password", "locked", "display", "unknown", "external"])
    func blocksUnreadyDesktop(reason: String) async {
        let fixture = makeFixture(reason: reason)
        defer { fixture.cleanup() }
        fixture.controller.setEnabled(true)
        do {
            try await fixture.controller.beginSession()
            Issue.record("Unsafe desktop should block startup")
        } catch {}
        #expect(!fixture.controller.isActive)
        #expect(fixture.controller.needsAttention)
        #expect(fixture.keeper.begins == 0)
    }

    @Test func endsProtectionWithoutChangingPreference() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.controller.setEnabled(true)
        try await fixture.controller.beginSession()
        #expect(fixture.controller.isActive)
        #expect(fixture.keeper.held)
        fixture.controller.endSession()
        #expect(!fixture.controller.isActive)
        #expect(!fixture.keeper.held)
        #expect(fixture.controller.isEnabled)
        #expect(fixture.defaults.bool(forKey: MacAgentDesktopController.preferenceKey))
    }

    @Test func lateReadCannotReenableEndedSession() async {
        let fixture = makeFixture(delay: .milliseconds(60))
        defer { fixture.cleanup() }
        fixture.controller.setEnabled(true)
        let pending = Task { try await fixture.controller.beginSession() }
        await Task.yield()
        fixture.controller.endSession()
        _ = try? await pending.value
        #expect(!fixture.controller.isActive)
        #expect(!fixture.keeper.held)
    }

    @Test func failedAssertionIsNotReportedActive() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.keeper.fail = true
        fixture.controller.setEnabled(true)
        _ = try? await fixture.controller.beginSession()
        #expect(!fixture.controller.isActive)
        #expect(fixture.controller.needsAttention)
    }

    @Test func oneHourPasswordPolicyAllowsProtectionButReportsLimit() async throws {
        let fixture = makeFixture(reason: "oneHour")
        defer { fixture.cleanup() }
        fixture.controller.setEnabled(true)
        try await fixture.controller.beginSession()
        #expect(fixture.controller.isActive)
        #expect(fixture.controller.needsAttention)
        #expect(fixture.controller.status.contains("1 小时"))
        #expect(fixture.controller.status.contains("到时仍可能锁屏"))
        await fixture.controller.checkReadiness()
        #expect(fixture.controller.needsAttention)
    }

    private func makeFixture(reason: String = "", delay: Duration = .zero) -> Fixture {
        let name = "agent-desktop-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let keeper = TestAgentDisplayKeeper()
        let controller = MacAgentDesktopController(
            checker: TestAgentDesktopChecker(reason: reason, delay: delay),
            displayKeeper: keeper, defaults: defaults
        )
        return Fixture(controller: controller, keeper: keeper, defaults: defaults, name: name)
    }

    @MainActor private struct Fixture {
        let controller: MacAgentDesktopController
        let keeper: TestAgentDisplayKeeper
        let defaults: UserDefaults
        let name: String
        func cleanup() {
            controller.endSession()
            defaults.removePersistentDomain(forName: name)
        }
    }
}

@MainActor
final class TestLidBrightnessController: MacLidBrightnessControlling {
    var events: [String] = []
    func prepare() throws { events.append("prepare") }
    func dim() throws { events.append("dim") }
    func restore() throws { events.append("restore") }
}

struct TestAgentDesktopChecker: MacAgentDesktopChecking {
    var reason = ""
    var delay: Duration = .zero
    func read() async throws -> MacAgentDesktopReadiness {
        if delay > .zero { try await Task.sleep(for: delay) }
        if reason == "unknown" { throw MacAgentDesktopError.unavailable }
        return MacAgentDesktopReadiness(requiresPassword: reason == "password" || reason == "oneHour",
                                        isLocked: reason == "locked", hasDisplay: reason != "display",
                                        hasConflictingLidPolicy: reason == "external",
                                        passwordDelaySeconds: reason == "oneHour" ? 3600 : nil)
    }
}

@MainActor
final class TestAgentDisplayKeeper: MacAgentDisplayKeeping {
    var begins = 0
    var held = false
    var fail = false
    func begin() throws {
        if fail { throw MacAgentDesktopError.assertionFailed }
        begins += 1
        held = true
    }
    func end() { held = false }
}
