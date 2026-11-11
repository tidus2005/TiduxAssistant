@testable import CodexWatchPhoneFeature
import CodexWatchCore
import Foundation
import Testing

@Suite("Watch sync service")
@MainActor
struct WatchSyncServiceTests {
    @Test
    func syncMessageIncludesBridgeConnectionWhenPaired() throws {
        let suiteName = "CodexWatchPetWatchSyncTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let connectionStore = BridgeConnectionStore(defaults: defaults)
        connectionStore.save(
            BridgeConnectionConfiguration(
                baseURL: URL(string: "http://172.20.12.65:8766")!,
                bearerToken: "token",
                sharedSecretBase64: Data("secret".utf8).base64EncodedString()
            )
        )
        let service = WatchSyncService(bridgeConnectionStore: connectionStore)
        let message = try service.makeSyncMessage(
            state: BridgeState(
                snapshots: [.sampleApproval],
                events: [],
                unreadHighUrgencyCount: 1,
                bridgeOnline: true,
                pairStatus: PairStatus(paired: true)
            )
        )

        let stateData = try #require(message[WatchConnectivityMessageKey.bridgeState] as? Data)
        let connectionData = try #require(message[WatchConnectivityMessageKey.bridgeConnection] as? Data)
        let decodedState = try JSONDecoder.codexWatchPet.decode(BridgeState.self, from: stateData)
        let decodedConnection = try JSONDecoder.codexWatchPet.decode(BridgeConnectionConfiguration.self, from: connectionData)

        #expect(decodedState.snapshots.first?.threadId == "thread-approval")
        #expect(decodedConnection.baseURL.absoluteString == "http://172.20.12.65:8766")
        #expect(decodedConnection.bearerToken == "token")
        #expect(decodedConnection.sharedSecret == Data("secret".utf8))
    }
}
