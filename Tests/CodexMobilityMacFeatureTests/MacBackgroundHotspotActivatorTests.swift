@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Headless hotspot activation")
@MainActor
struct MacBackgroundHotspotActivatorTests {
    @Test func activationFinishesAndStopsDiscovery() async throws {
        let session = FakeBackgroundHotspotSession()
        session.immediateResult = .success(MacHotspotInvitation(ssid: "Phone", password: "test-password"))
        let activator = SharingBackgroundHotspotActivator(checkAuthorization: {}, associate: { _ in }, makeSession: { session })
        try await activator.activate(ssid: "Phone")
        #expect(session.target == "Phone")
        #expect(session.stopCount == 1)
        session.completion?(.failure(.rejected)) // Late callback must not resume twice.
        #expect(session.stopCount == 1)
    }

    @Test func discoverySessionSurvivesUntilAssociationFinishes() async throws {
        let session = FakeBackgroundHotspotSession()
        session.immediateResult = .success(MacHotspotInvitation(ssid: "Phone", password: "test-password"))
        let activator = SharingBackgroundHotspotActivator(checkAuthorization: {}, associate: { _ in
            await MainActor.run { #expect(session.stopCount == 0) }
            try await Task.sleep(for: .milliseconds(5))
        }, makeSession: { session })
        try await activator.activate(ssid: "Phone")
        #expect(session.stopCount == 1)
    }

    @Test func timeoutReleasesDiscoveryAndAllowsNextAttempt() async throws {
        let session = FakeBackgroundHotspotSession()
        let activator = SharingBackgroundHotspotActivator(timeout: 0.02, checkAuthorization: {}, associate: { _ in }, makeSession: { session })
        do { try await activator.activate(ssid: "Phone"); Issue.record("Expected timeout") }
        catch { #expect(error as? MacBackgroundHotspotError == .timedOut) }
        #expect(session.stopCount == 1)
        session.immediateResult = .success(MacHotspotInvitation(ssid: "Phone", password: "test-password"))
        try await activator.activate(ssid: "Phone")
        #expect(session.stopCount == 2)
    }

    @Test func cancellationStopsDiscoveryWithoutWaitingForTimeout() async throws {
        let session = FakeBackgroundHotspotSession()
        let activator = SharingBackgroundHotspotActivator(timeout: 100, checkAuthorization: {}, associate: { _ in }, makeSession: { session })
        let task = Task { try await activator.activate(ssid: "Phone") }
        for _ in 0..<100 where session.target == nil { await Task.yield() }
        #expect(session.target == "Phone")
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(session.stopCount == 1)
    }

    @Test func systemRejectionIsNotReportedAsActivationSuccess() async {
        let session = FakeBackgroundHotspotSession()
        session.immediateResult = .failure(.rejected)
        let activator = SharingBackgroundHotspotActivator(checkAuthorization: {}, associate: { _ in }, makeSession: { session })
        do { try await activator.activate(ssid: "Phone"); Issue.record("Expected rejection") }
        catch { #expect(error as? MacBackgroundHotspotError == .rejected) }
        #expect(session.stopCount == 1)
    }
    @Test func activationReplyMustAssociateBeforeReportingSuccess() async throws {
        let session = FakeBackgroundHotspotSession()
        session.immediateResult = .success(MacHotspotInvitation(ssid: "Phone", password: "test-password"))
        let activator = SharingBackgroundHotspotActivator(checkAuthorization: {}, associate: { invitation in
            #expect(invitation.ssid == "Phone")
            throw MacBackgroundHotspotError.associationFailed
        }, makeSession: { session })
        do { try await activator.activate(ssid: "Phone"); Issue.record("Must propagate association failure") }
        catch { #expect(error as? MacBackgroundHotspotError == .associationFailed) }
    }

    @Test func mismatchedInvitationNeverAssociates() async {
        let session = FakeBackgroundHotspotSession()
        session.immediateResult = .success(MacHotspotInvitation(ssid: "Other Phone", password: "test-password"))
        let activator = SharingBackgroundHotspotActivator(checkAuthorization: {}, associate: { _ in
            Issue.record("Must not associate to an unconfigured phone")
        }, makeSession: { session })
        do { try await activator.activate(ssid: "Phone"); Issue.record("Expected rejection") }
        catch { #expect(error as? MacBackgroundHotspotError == .rejected) }
    }

    @Test func missingAuthorizationDoesNotStartDiscovery() async {
        let session = FakeBackgroundHotspotSession()
        let activator = SharingBackgroundHotspotActivator(checkAuthorization: {
            throw MacBackgroundHotspotError.locationPermissionRequired
        }, associate: { _ in Issue.record("Must not associate") }, makeSession: { session })
        do { try await activator.activate(ssid: "Phone"); Issue.record("Expected permission error") }
        catch { #expect(error as? MacBackgroundHotspotError == .locationPermissionRequired) }
        #expect(session.target == nil)
    }

    @Test func cancellationDuringAssociationDoesNotReportSuccess() async throws {
        let session = FakeBackgroundHotspotSession()
        session.immediateResult = .success(MacHotspotInvitation(ssid: "Phone", password: "test-password"))
        let activator = SharingBackgroundHotspotActivator(checkAuthorization: {}, associate: { _ in
            try await Task.sleep(for: .seconds(100))
        }, makeSession: { session })
        let task = Task { try await activator.activate(ssid: "Phone") }
        for _ in 0..<100 where session.target == nil { await Task.yield() }
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

}

@MainActor
private final class FakeBackgroundHotspotSession: MacBackgroundHotspotSession {
    var target: String?
    var stopCount = 0
    var immediateResult: Result<MacHotspotInvitation, MacBackgroundHotspotError>?
    var completion: (@MainActor @Sendable (Result<MacHotspotInvitation, MacBackgroundHotspotError>) -> Void)?
    func start(ssid: String, completion: @escaping @MainActor @Sendable (Result<MacHotspotInvitation, MacBackgroundHotspotError>) -> Void) throws {
        target = ssid
        self.completion = completion
        if let immediateResult { completion(immediateResult) }
    }
    func stop() { stopCount += 1 }
}
