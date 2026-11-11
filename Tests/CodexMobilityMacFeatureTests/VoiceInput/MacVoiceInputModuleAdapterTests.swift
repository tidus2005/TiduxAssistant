@testable import CodexMobilityMacFeature
import Testing

@Suite("Mac voice input module adapter")
@MainActor
struct MacVoiceInputModuleAdapterTests {
    @Test
    func repeatedStartWhileStartupIsPendingStartsOnlyOnce() async {
        let lifecycle = SuspendedVoiceInputLifecycle()
        let adapter = MacVoiceInputModuleAdapter(store: lifecycle)

        adapter.start()
        adapter.start()
        await lifecycle.waitUntilStartWasEntered()

        #expect(lifecycle.startCount == 1)

        lifecycle.finishStart()
        await Task.yield()
        adapter.stop()
        #expect(lifecycle.shutdownCount == 1)
    }

    @Test
    func stopCancelsPendingStartupAndAllowsCleanRestart() async {
        let lifecycle = SuspendedVoiceInputLifecycle()
        let adapter = MacVoiceInputModuleAdapter(store: lifecycle)

        adapter.start()
        adapter.stop()
        await Task.yield()

        #expect(lifecycle.startCount == 0)
        #expect(lifecycle.shutdownCount == 1)

        adapter.start()
        await lifecycle.waitUntilStartWasEntered()
        #expect(lifecycle.startCount == 1)

        lifecycle.finishStart()
        await Task.yield()
        adapter.stop()
        #expect(lifecycle.shutdownCount == 2)
    }

    @Test
    func appActivationRefreshesPermissionsOnlyWhileModuleIsEnabled() async {
        let lifecycle = SuspendedVoiceInputLifecycle()
        let adapter = MacVoiceInputModuleAdapter(store: lifecycle)

        adapter.applicationDidBecomeActive()
        #expect(lifecycle.refreshPermissionsCount == 0)

        adapter.start()
        adapter.applicationDidBecomeActive()
        await lifecycle.waitUntilStartWasEntered()
        #expect(lifecycle.refreshPermissionsCount == 0)

        lifecycle.finishStart()
        await lifecycle.waitUntilRefreshPermissionsWasEntered()
        #expect(lifecycle.refreshPermissionsCount == 1)

        adapter.stop()
        adapter.applicationDidBecomeActive()
        await Task.yield()
        #expect(lifecycle.refreshPermissionsCount == 1)
    }
}

@MainActor
private final class SuspendedVoiceInputLifecycle: MacVoiceInputLifecycle {
    private(set) var startCount = 0
    private(set) var refreshPermissionsCount = 0
    private(set) var shutdownCount = 0

    private var startContinuation: CheckedContinuation<Void, Never>?
    private var waiterContinuations: [CheckedContinuation<Void, Never>] = []
    private var refreshWaiterContinuations: [CheckedContinuation<Void, Never>] = []

    func start() async {
        guard !Task.isCancelled else { return }
        startCount += 1
        let waiters = waiterContinuations
        waiterContinuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func shutdown() {
        shutdownCount += 1
        finishStart()
    }

    func refreshPermissions() async {
        refreshPermissionsCount += 1
        let waiters = refreshWaiterContinuations
        refreshWaiterContinuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStartWasEntered() async {
        guard startCount == 0 else { return }
        await withCheckedContinuation { continuation in
            waiterContinuations.append(continuation)
        }
    }

    func finishStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitUntilRefreshPermissionsWasEntered() async {
        guard refreshPermissionsCount == 0 else { return }
        await withCheckedContinuation { continuation in
            refreshWaiterContinuations.append(continuation)
        }
    }
}
