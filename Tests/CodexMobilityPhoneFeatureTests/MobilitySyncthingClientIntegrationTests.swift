@testable import CodexMobilityPhoneFeature
import CodexMobilityCore
import Foundation
import Network
import Testing

@Suite("iPhone Syncthing peer handshake")
struct MobilitySyncthingClientIntegrationTests {
    @Test func pairedAddressRequiresExactlyFourPrivateIPv4Octets() {
        for host in ["172.20.10.2", "192.168.31.5", "192.168.1.10"] {
            #expect(MobilitySyncthingClient.isPrivateIPv4(host))
        }
        for host in ["10.bad.1.2.3", "10..1.2.3", "10.1.2.3.4", "127.0.0.1", "8.8.8.8", "192.168.1.999", "172.32.1.2"] {
            #expect(!MobilitySyncthingClient.isPrivateIPv4(host))
        }
    }

    @Test("Real TLS transport completes destination-bound mutual Hello")
    func authenticatedLoopbackHandshake() async throws {
        let fixture = try await LoopbackPeerFixture.start()
        defer { Task { await fixture.stop() } }

        let serverHandshake = Task {
            let server = try await fixture.acceptedPeer()
            guard case .hello(let phoneHello) = try await server.receive() else {
                throw MobilitySyncthingClientError.expectedHello
            }
            try SyncthingPeerAuthentication.requireValid(
                phoneHello,
                expectedLocalDeviceID: fixture.macDeviceID,
                pairingToken: fixture.token
            )
            try await server.send(
                .hello(
                    try SyncthingPeerAuthentication.makeHello(
                        senderDeviceID: fixture.macDeviceID,
                        intendedPeerDeviceID: fixture.phoneDeviceID,
                        deviceName: "Test Mac",
                        folderIDs: ["codex-sync"],
                        pairingToken: fixture.token
                    )
                )
            )
            return phoneHello
        }

        let client = try await MobilitySyncthingClient.connect(
            endpoint: .hostPort(host: "::1", port: fixture.port),
            credential: fixture.phoneCredential,
            localDeviceID: fixture.phoneDeviceID,
            localDeviceName: "Test iPhone",
            includePeerToPeer: false,
            handshakeTimeout: .seconds(1)
        )
        defer { Task { await client.cancel() } }

        let phoneHello = try await serverHandshake.value
        #expect(phoneHello.deviceID == fixture.phoneDeviceID)
        #expect(phoneHello.intendedPeerDeviceID == fixture.macDeviceID)
    }

    @Test("A silent TLS peer times out without leaving the task group stuck")
    func silentPeerTimesOut() async throws {
        let fixture = try await LoopbackPeerFixture.start()
        defer { Task { await fixture.stop() } }

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await MobilitySyncthingClient.connect(
                endpoint: .hostPort(host: "::1", port: fixture.port),
                credential: fixture.phoneCredential,
                localDeviceID: fixture.phoneDeviceID,
                localDeviceName: "Test iPhone",
                includePeerToPeer: false,
                handshakeTimeout: .milliseconds(80)
            )
            Issue.record("A silent peer must not complete the authenticated handshake")
        } catch {
            #expect(error as? MobilitySyncthingClientError == .connectionTimedOut)
        }
        #expect(started.duration(to: clock.now) < .seconds(1))
    }
}

private struct LoopbackPeerFixture: Sendable {
    let macDeviceID: UUID
    let phoneDeviceID: UUID
    let token: String
    let phoneCredential: MobilityPairingCredential
    let listener: SyncthingPeerListener
    let port: NWEndpoint.Port
    private let accepted: LoopbackAcceptedPeerBox

    static func start() async throws -> LoopbackPeerFixture {
        let macDeviceID = UUID()
        let phoneDeviceID = UUID()
        let token = Data((0..<32).map(UInt8.init)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let listener = SyncthingPeerListener(
            serviceName: "Codex Phone Handshake Test",
            credentials: [
                SyncthingPeerCredential(deviceID: phoneDeviceID, pairingToken: token)
            ],
            includePeerToPeer: false
        )
        let accepted = LoopbackAcceptedPeerBox()
        let ready = LoopbackListenerReadyBox()
        try await listener.start(
            onConnection: { peer in await accepted.store(peer) },
            onStateChange: { state in
                guard case .ready = state else { return }
                Task { await ready.markReady() }
            }
        )

        for _ in 0..<200 {
            if await ready.isReady(), let port = await listener.port {
                return LoopbackPeerFixture(
                    macDeviceID: macDeviceID,
                    phoneDeviceID: phoneDeviceID,
                    token: token,
                    phoneCredential: MobilityPairingCredential(
                        peripheralIdentifier: UUID(),
                        computerIdentifier: macDeviceID.uuidString,
                        computerName: "Test Mac",
                        token: token
                    ),
                    listener: listener,
                    port: port,
                    accepted: accepted
                )
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        await listener.stop()
        throw SyncthingPeerTransportError.connectionFailed("listener ready timeout")
    }

    func acceptedPeer() async throws -> SyncthingPeerConnection {
        for _ in 0..<200 {
            if let peer = await accepted.value() { return peer }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SyncthingPeerTransportError.connectionFailed("accept timeout")
    }

    func stop() async {
        if let peer = await accepted.value() { await peer.cancel() }
        await listener.stop()
    }
}

private actor LoopbackListenerReadyBox {
    private var ready = false
    func markReady() { ready = true }
    func isReady() -> Bool { ready }
}

private actor LoopbackAcceptedPeerBox {
    private var peer: SyncthingPeerConnection?
    func store(_ peer: SyncthingPeerConnection) { self.peer = peer }
    func value() -> SyncthingPeerConnection? { peer }
}
