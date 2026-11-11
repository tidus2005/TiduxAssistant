import CodexWatchCore
import Testing
@testable import CodexWatchPhoneFeature

@MainActor
struct OfflineStoreTests {
    @Test func disconnectedRefreshDoesNotInventDemoTasks() async {
        let store = CodexWatchStore()
        await store.refresh()
        #expect(store.state.snapshots.isEmpty)
        #expect(!store.state.bridgeOnline)
    }
}
