import CodexMobilityCore
import Foundation
import Network
import Testing

@Suite("Syncthing peer TLS transport")
struct SyncthingPeerTransportIntegrationTests {
    @Test("TLS PSK loopback carries framed peer messages")
    func tlsPSKLoopback() async throws {
        let phoneID = UUID(uuidString: "A73C0C7D-76A8-40A6-84A0-7834B7BFDA06")!
        let token = Data((0..<32).map(UInt8.init)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let credential = SyncthingPeerCredential(deviceID: phoneID, pairingToken: token)
        let listener = SyncthingPeerListener(
            serviceName: "Codex Sync Test",
            credentials: [credential],
            includePeerToPeer: false
        )
        let accepted = AcceptedPeerBox()
        let listenerReady = ListenerReadyBox()

        try await listener.start(
            onConnection: { peer in
                await accepted.store(peer)
            },
            onStateChange: { state in
                guard case .ready = state else { return }
                Task { await listenerReady.markReady() }
            }
        )
        defer { Task { await listener.stop() } }

        try await waitForListenerReady(listenerReady)
        let port = try await waitForPort(listener)
        let client = try await SyncthingPeerConnection.connect(
            to: .hostPort(host: "::1", port: port),
            credential: credential,
            includePeerToPeer: false
        )
        let server = try await waitForAcceptedPeer(accepted)
        defer {
            Task {
                await client.cancel()
                await server.cancel()
            }
        }

        let hello = SyncthingPeerMessage.hello(
            SyncthingPeerHello(deviceID: phoneID, deviceName: "Test iPhone")
        )
        try await client.send(hello)
        #expect(try await server.receive() == hello)

        let acknowledgement = SyncthingPeerMessage.ack(
            SyncthingPeerAcknowledgement(
                acknowledgedMessageID: UUID(uuidString: "D07F8BC9-9AE8-4075-9ED7-8400A69794CE")!
            )
        )
        try await server.send(acknowledgement)
        #expect(try await client.receive() == acknowledgement)
    }

    private func waitForPort(_ listener: SyncthingPeerListener) async throws -> NWEndpoint.Port {
        for _ in 0..<200 {
            if let port = await listener.port { return port }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SyncthingPeerTransportError.connectionFailed("listener port timeout")
    }

    private func waitForListenerReady(_ box: ListenerReadyBox) async throws {
        for _ in 0..<200 {
            if await box.isReady() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SyncthingPeerTransportError.connectionFailed("listener ready timeout")
    }

    private func waitForAcceptedPeer(_ box: AcceptedPeerBox) async throws -> SyncthingPeerConnection {
        for _ in 0..<200 {
            if let peer = await box.value() { return peer }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SyncthingPeerTransportError.connectionFailed("accept timeout")
    }
}

private actor ListenerReadyBox {
    private var ready = false

    func markReady() { ready = true }
    func isReady() -> Bool { ready }
}

private actor AcceptedPeerBox {
    private var peer: SyncthingPeerConnection?

    func store(_ peer: SyncthingPeerConnection) {
        self.peer = peer
    }

    func value() -> SyncthingPeerConnection? { peer }
}
