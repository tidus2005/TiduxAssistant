@testable import CodexMobilityMacFeature
import CodexMobilityCore
import Foundation
import Testing

@Suite("Mac Syncthing-like P2P server")
@MainActor
struct MacSyncthingSyncServerTests {
    private let macDeviceID = UUID(uuidString: "0B19D452-B3DF-490B-95DA-E09AE8F1EE03")!
    private let phoneDeviceID = UUID(uuidString: "AD2697DA-CC07-4C91-A729-E2382299CC1F")!

    @Test("An unpaired hello is rejected before transfer routing")
    func rejectsUnpairedHello() async throws {
        let pairedDeviceID = UUID()
        let credentialStore = FakeMacCredentialStore(credentials: [
            Self.credential(deviceID: pairedDeviceID, tokenByte: 1)
        ])
        let listener = FakeMacSyncthingListener()
        let recorder = TransferRecorder()
        let server = makeServer(
            credentialStore: credentialStore,
            listener: listener,
            recorder: recorder
        )

        await server.start()
        let connection = FakeMacSyncthingConnection()
        await listener.connect(connection)
        await connection.enqueue(
            .hello(
                SyncthingPeerHello(
                    deviceID: UUID(),
                    deviceName: "Unknown iPhone"
                )
            )
        )

        try await waitUntil {
            await connection.closeMessage()?.code == .unauthorized
        }
        #expect(await recorder.received().isEmpty)
        #expect(server.state.authenticatedPeerDeviceIDs.isEmpty)
        await server.stop()
    }

    @Test("Authenticated transfer messages route responses on the same connection")
    func routesTransferOnOriginatingConnection() async throws {
        let phoneCredential = Self.credential(deviceID: phoneDeviceID, tokenByte: 2)
        let credentialStore = FakeMacCredentialStore(credentials: [
            phoneCredential
        ])
        let listener = FakeMacSyncthingListener()
        let recorder = TransferRecorder()
        let expectedResponse = SyncWireMessage.failure(
            SyncFailure(
                code: .unavailable,
                message: "test-response",
                retryable: true
            )
        )
        await recorder.setResponses([expectedResponse])
        let server = makeServer(
            credentialStore: credentialStore,
            listener: listener,
            recorder: recorder
        )

        await server.start()
        let connection = FakeMacSyncthingConnection()
        await listener.connect(connection)
        await connection.enqueue(
            .hello(try signedHello(for: phoneCredential, deviceName: "Travel iPhone"))
        )
        try await waitUntil {
            server.state.authenticatedPeerDeviceIDs == [phoneDeviceID]
        }

        let request = SyncWireMessage.requestOffers(
            SyncOfferRequest(requestedDirection: .macToPhone)
        )
        await connection.enqueue(.transfer(request))

        try await waitUntil {
            await connection.sentMessages().contains(.transfer(expectedResponse))
        }
        let routed = await recorder.received()
        #expect(routed.count == 1)
        #expect(routed.first?.message == request)
        #expect(routed.first?.deviceID == phoneDeviceID)

        let sent = await connection.sentMessages()
        guard case .hello(let serverHello) = sent.first else {
            Issue.record("Expected the Mac hello before transfer responses")
            await server.stop()
            return
        }
        #expect(serverHello.deviceID == macDeviceID)
        #expect(serverHello.deviceName == "MacBook Test")
        #expect(serverHello.intendedPeerDeviceID == phoneDeviceID)
        #expect(try SyncthingPeerAuthentication.verify(
            serverHello,
            expectedLocalDeviceID: phoneDeviceID,
            pairingToken: phoneCredential.token
        ))
        #expect(sent.last == .transfer(expectedResponse))
        await server.stop()
    }

    @Test("Proactive offers reach only authenticated peers that remain paired")
    func proactivePublishRequiresCurrentPairing() async throws {
        let phoneCredential = Self.credential(deviceID: phoneDeviceID, tokenByte: 8)
        let credentialStore = FakeMacCredentialStore(credentials: [
            phoneCredential
        ])
        let listener = FakeMacSyncthingListener()
        let recorder = TransferRecorder()
        let server = makeServer(
            credentialStore: credentialStore,
            listener: listener,
            recorder: recorder
        )
        await server.start()

        let authenticated = FakeMacSyncthingConnection()
        let unauthenticated = FakeMacSyncthingConnection()
        await listener.connect(authenticated)
        await listener.connect(unauthenticated)
        await authenticated.enqueue(
            .hello(try signedHello(for: phoneCredential, deviceName: "Paired iPhone"))
        )
        try await waitUntil {
            server.state.authenticatedPeerDeviceIDs == [phoneDeviceID]
        }

        let firstOffer = SyncWireMessage.requestOffers(
            SyncOfferRequest(requestedDirection: .macToPhone)
        )
        await server.publish([firstOffer])
        #expect(await authenticated.sentMessages().contains(.transfer(firstOffer)))
        #expect(await unauthenticated.sentMessages().isEmpty)

        try credentialStore.revokeCredential(for: phoneDeviceID)
        let postRevocation = SyncWireMessage.failure(
            SyncFailure(code: .unavailable, message: "must-not-send")
        )
        await server.publish([postRevocation])
        let messagesAfterRevocation = await authenticated.sentMessages()
        #expect(!messagesAfterRevocation.contains(.transfer(postRevocation)))
        #expect(await authenticated.wasCancelled())
        await server.stop()
    }

    @Test("Authenticated delta messages route through the peer coordinator and return responses")
    func routesDeltaMessagesOnOriginatingConnection() async throws {
        let phoneCredential = Self.credential(deviceID: phoneDeviceID, tokenByte: 13)
        let credentialStore = FakeMacCredentialStore(credentials: [phoneCredential])
        let listener = FakeMacSyncthingListener()
        let recorder = TransferRecorder()
        let deltaRouter = FakeMacDeltaRouter()
        let payload = Data("from phone".utf8)
        let remoteIndex = try SyncthingPlanner.fileIndex(
            for: payload,
            relativePath: "Inbox/from-phone.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            deviceID: "phone",
            version: SyncthingVersionVector(counters: ["phone": 1]),
            sequence: 1
        )
        let messageID = UUID()
        let inbound = SyncthingPeerMessage.index(SyncthingPeerIndex(
            messageID: messageID,
            folderID: SyncthingTransferFolderID.make(transferID: UUID()),
            sequence: remoteIndex.sequence,
            entries: [remoteIndex]
        ))
        let expectedResponse = SyncthingPeerMessage.ack(SyncthingPeerAcknowledgement(
            acknowledgedMessageID: messageID,
            status: .accepted
        ))
        await deltaRouter.setResponses([expectedResponse])
        let server = MacSyncthingSyncServer(
            localDeviceID: macDeviceID,
            localDeviceName: "MacBook Test",
            credentialStore: credentialStore,
            listener: listener,
            serviceName: "Codex Test",
            deltaRouterFactory: { deltaRouter },
            transferHandler: { message, deviceID in
                await recorder.handle(message: message, deviceID: deviceID)
            }
        )

        await server.start()
        let connection = FakeMacSyncthingConnection()
        await listener.connect(connection)
        await connection.enqueue(.hello(try signedHello(for: phoneCredential)))
        try await waitUntil {
            server.state.authenticatedPeerDeviceIDs == [phoneDeviceID]
        }
        await connection.enqueue(inbound)
        try await waitUntil {
            await connection.sentMessages().contains(expectedResponse)
        }

        #expect(await deltaRouter.receivedMessages() == [inbound])
        #expect(await recorder.received().isEmpty)
        await server.stop()
    }

    @Test("Small files publish one delta index while oversized files stay off P2P")
    func deltaPublicationAndLargeFileFallbackAreDuplicateSafe() async throws {
        let phoneCredential = Self.credential(deviceID: phoneDeviceID, tokenByte: 14)
        let credentialStore = FakeMacCredentialStore(credentials: [phoneCredential])
        let listener = FakeMacSyncthingListener()
        let deltaRouter = FakeMacDeltaRouter()
        let server = MacSyncthingSyncServer(
            localDeviceID: macDeviceID,
            localDeviceName: "MacBook Test",
            credentialStore: credentialStore,
            listener: listener,
            serviceName: "Codex Test",
            deltaRouterFactory: { deltaRouter },
            transferHandler: { _, _ in [] }
        )
        await server.start()
        let connection = FakeMacSyncthingConnection()
        await listener.connect(connection)
        await connection.enqueue(.hello(try signedHello(for: phoneCredential)))
        try await waitUntil {
            server.state.authenticatedPeerDeviceIDs == [phoneDeviceID]
        }

        let smallOffer = makeOffer(
            transferID: UUID(),
            path: "small.bin",
            size: 1_024
        )
        let largeOffer = makeOffer(
            transferID: UUID(),
            path: "large.bin",
            size: SyncthingDeltaSession.maximumInMemoryFileSize + 1
        )
        let messages: [SyncWireMessage] = [.offer(smallOffer), .offer(largeOffer)]
        await server.publish(messages)
        await server.publish(messages)

        let sent = await connection.sentMessages()
        let deltaCount = sent.count { message in
            if case .indexUpdate = message { return true }
            return false
        }
        let smallLegacyCount = sent.count { $0 == .transfer(.offer(smallOffer)) }
        let largeLegacyCount = sent.count { $0 == .transfer(.offer(largeOffer)) }
        #expect(deltaCount == 1)
        #expect(smallLegacyCount == 0)
        #expect(largeLegacyCount == 0)
        #expect(await deltaRouter.publishedOffers().count == 2)
        await server.stop()
    }

    @Test("Handshake immediately publishes files that were already queued")
    func handshakePublishesExistingQueue() async throws {
        let phoneCredential = Self.credential(deviceID: phoneDeviceID, tokenByte: 17)
        let credentialStore = FakeMacCredentialStore(credentials: [phoneCredential])
        let listener = FakeMacSyncthingListener()
        let deltaRouter = FakeMacDeltaRouter()
        let queuedOffer = makeOffer(
            transferID: UUID(),
            path: "already-queued.bin",
            size: 4_096
        )
        let server = MacSyncthingSyncServer(
            localDeviceID: macDeviceID,
            localDeviceName: "MacBook Test",
            credentialStore: credentialStore,
            listener: listener,
            serviceName: "Codex Test",
            deltaRouterFactory: { deltaRouter },
            pendingOffersProvider: { [.offer(queuedOffer)] },
            transferHandler: { _, _ in [] }
        )

        await server.start()
        let connection = FakeMacSyncthingConnection()
        await listener.connect(connection)
        await connection.enqueue(.hello(try signedHello(for: phoneCredential)))
        try await waitUntil {
            await connection.sentMessages().contains { message in
                if case .indexUpdate = message { return true }
                return false
            }
        }
        #expect(await deltaRouter.publishedOffers() == [queuedOffer])
        let sent = await connection.sentMessages()
        guard case .hello = sent.first else {
            Issue.record("The authenticated Mac hello must precede queued indexes")
            return
        }
        await server.stop()
    }

    @Test("A delta network send failure cleans up the connection")
    func deltaSendFailureDisconnectsPeer() async throws {
        let phoneCredential = Self.credential(deviceID: phoneDeviceID, tokenByte: 18)
        let credentialStore = FakeMacCredentialStore(credentials: [phoneCredential])
        let listener = FakeMacSyncthingListener()
        let deltaRouter = FakeMacDeltaRouter()
        let server = MacSyncthingSyncServer(
            localDeviceID: macDeviceID,
            localDeviceName: "MacBook Test",
            credentialStore: credentialStore,
            listener: listener,
            serviceName: "Codex Test",
            deltaRouterFactory: { deltaRouter },
            transferHandler: { _, _ in [] }
        )
        await server.start()
        let connection = FakeMacSyncthingConnection()
        await listener.connect(connection)
        await connection.enqueue(.hello(try signedHello(for: phoneCredential)))
        try await waitUntil {
            server.state.authenticatedPeerDeviceIDs == [phoneDeviceID]
        }
        await connection.failNextSend()
        await server.publish([.offer(makeOffer(
            transferID: UUID(),
            path: "send-fails.bin",
            size: 1_024
        ))])

        #expect(await connection.wasCancelled())
        #expect(server.state.authenticatedPeerDeviceIDs.isEmpty)
        await server.stop()
    }

    @Test("One queued file is proactively consumed by only one authenticated peer")
    func proactivePublicationSelectsOnePeer() async throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let firstCredential = Self.credential(deviceID: firstID, tokenByte: 15)
        let secondCredential = Self.credential(deviceID: secondID, tokenByte: 16)
        let credentialStore = FakeMacCredentialStore(credentials: [
            firstCredential,
            secondCredential
        ])
        let listener = FakeMacSyncthingListener()
        let server = MacSyncthingSyncServer(
            localDeviceID: macDeviceID,
            localDeviceName: "MacBook Test",
            credentialStore: credentialStore,
            listener: listener,
            serviceName: "Codex Test",
            deltaRouterFactory: { FakeMacDeltaRouter() },
            transferHandler: { _, _ in [] }
        )
        await server.start()

        let firstConnection = FakeMacSyncthingConnection()
        let secondConnection = FakeMacSyncthingConnection()
        await listener.connect(firstConnection)
        await listener.connect(secondConnection)
        await firstConnection.enqueue(.hello(try signedHello(for: firstCredential)))
        await secondConnection.enqueue(.hello(try signedHello(for: secondCredential)))
        try await waitUntil {
            server.state.authenticatedPeerDeviceIDs == [firstID, secondID]
        }

        let offer = makeOffer(
            transferID: UUID(),
            path: "single-consumer.bin",
            size: 1_024
        )
        await server.publish([.offer(offer)])
        let firstReceivedIndex = await firstConnection.sentMessages().contains { message in
            if case .indexUpdate = message { return true }
            return false
        }
        let secondReceivedIndex = await secondConnection.sentMessages().contains { message in
            if case .indexUpdate = message { return true }
            return false
        }
        #expect(firstReceivedIndex)
        #expect(!secondReceivedIndex)
        await server.stop()
    }

    @Test("Revocation rebuilds PSK listener and disconnects the revoked peer")
    func revocationRefreshesListenerAndDisconnectsPeer() async throws {
        let retainedDeviceID = UUID()
        let revokedCredential = Self.credential(deviceID: phoneDeviceID, tokenByte: 3)
        let credentialStore = FakeMacCredentialStore(credentials: [
            revokedCredential,
            Self.credential(deviceID: retainedDeviceID, tokenByte: 4)
        ])
        let listener = FakeMacSyncthingListener()
        let recorder = TransferRecorder()
        let server = makeServer(
            credentialStore: credentialStore,
            listener: listener,
            recorder: recorder
        )

        await server.start()
        let connection = FakeMacSyncthingConnection()
        await listener.connect(connection)
        await connection.enqueue(
            .hello(try signedHello(for: revokedCredential, deviceName: "Revoked iPhone"))
        )
        try await waitUntil {
            server.state.authenticatedPeerDeviceIDs == [phoneDeviceID]
        }

        try credentialStore.revokeCredential(for: phoneDeviceID)
        await server.refreshCredentials()

        #expect(await connection.wasCancelled())
        #expect(server.state.authenticatedPeerDeviceIDs.isEmpty)
        #expect(server.state.phase == .advertising)
        #expect(listener.startCount == 2)
        #expect(listener.startedCredentials.map(\.deviceID) == [retainedDeviceID])
        await server.stop()
    }

    @Test("Hello proof is destination-bound and a nonce cannot be replayed")
    func helloProofAndReplayProtection() async throws {
        let phoneCredential = Self.credential(deviceID: phoneDeviceID, tokenByte: 7)
        let credentialStore = FakeMacCredentialStore(credentials: [phoneCredential])
        let listener = FakeMacSyncthingListener()
        let recorder = TransferRecorder()
        let server = makeServer(
            credentialStore: credentialStore,
            listener: listener,
            recorder: recorder
        )
        await server.start()

        var wrongDestination = try signedHello(for: phoneCredential)
        wrongDestination.intendedPeerDeviceID = UUID()
        let invalidConnection = FakeMacSyncthingConnection()
        await listener.connect(invalidConnection)
        await invalidConnection.enqueue(.hello(wrongDestination))
        try await waitUntil {
            await invalidConnection.closeMessage()?.code == .unauthorized
        }

        let nonce = UUID()
        let validHello = try signedHello(for: phoneCredential, nonce: nonce)
        let firstConnection = FakeMacSyncthingConnection()
        await listener.connect(firstConnection)
        await firstConnection.enqueue(.hello(validHello))
        try await waitUntil {
            server.state.authenticatedPeerDeviceIDs == [phoneDeviceID]
        }

        let replayConnection = FakeMacSyncthingConnection()
        await listener.connect(replayConnection)
        await replayConnection.enqueue(.hello(validHello))
        try await waitUntil {
            await replayConnection.closeMessage()?.code == .unauthorized
        }
        #expect(server.state.authenticatedPeerDeviceIDs == [phoneDeviceID])
        await server.stop()
    }

    @Test("LAN profile raises chunks to 64 KiB without changing Bluetooth defaults")
    func localNetworkTransferProfile() {
        #expect(MacFileSyncTransportProfile.bluetooth.preferredChunkSize == 8 * 1_024)
        #expect(
            MacFileSyncTransportProfile.localNetwork.preferredChunkSize
                == SyncProtocolLimits.maximumChunkSize
        )
        #expect(MacFileSyncTransportProfile.bluetooth.windowSize == 1)
        #expect(MacFileSyncTransportProfile.localNetwork.windowSize == 1)
        #expect(
            MacFileSyncTransportProfile.localNetwork.maximumFrameSize
                > MacFileSyncTransportProfile.bluetooth.maximumFrameSize
        )
    }

    @Test("A terminal listener failure is restarted with the current credentials")
    func listenerFailureRestarts() async throws {
        let credential = Self.credential(deviceID: phoneDeviceID, tokenByte: 11)
        let credentialStore = FakeMacCredentialStore(credentials: [credential])
        let listener = FakeMacSyncthingListener()
        let recorder = TransferRecorder()
        let server = MacSyncthingSyncServer(
            localDeviceID: macDeviceID,
            localDeviceName: "MacBook Test",
            credentialStore: credentialStore,
            listener: listener,
            serviceName: "Codex Test",
            listenerRestartDelay: .milliseconds(10),
            transferHandler: { message, deviceID in
                await recorder.handle(message: message, deviceID: deviceID)
            }
        )

        await server.start()
        #expect(listener.startCount == 1)
        listener.emit(.failed("simulated network reset"))

        try await waitUntil {
            listener.startCount == 2 && server.state.phase == .advertising
        }
        #expect(listener.startedCredentials.map(\.deviceID) == [phoneDeviceID])
        await server.stop()
    }

    @Test("An encrypted connection that never sends Hello is cancelled")
    func silentConnectionHelloTimeout() async throws {
        let credential = Self.credential(deviceID: phoneDeviceID, tokenByte: 12)
        let credentialStore = FakeMacCredentialStore(credentials: [credential])
        let listener = FakeMacSyncthingListener()
        let recorder = TransferRecorder()
        let server = MacSyncthingSyncServer(
            localDeviceID: macDeviceID,
            localDeviceName: "MacBook Test",
            credentialStore: credentialStore,
            listener: listener,
            serviceName: "Codex Test",
            helloTimeout: .milliseconds(10),
            transferHandler: { message, deviceID in
                await recorder.handle(message: message, deviceID: deviceID)
            }
        )

        await server.start()
        let connection = FakeMacSyncthingConnection()
        await listener.connect(connection)
        try await waitUntil { await connection.wasCancelled() }
        #expect(server.state.authenticatedPeerDeviceIDs.isEmpty)
        await server.stop()
    }

    @Test("Bonjour instance name stays within the DNS-SD UTF-8 label limit")
    func bonjourNameIsUTF8Bounded() {
        let server = MacSyncthingSyncServer(
            localDeviceID: macDeviceID,
            localDeviceName: String(repeating: "旅行电脑🚄", count: 30),
            credentialStore: FakeMacCredentialStore(credentials: []),
            listener: FakeMacSyncthingListener(),
            transferHandler: { _, _ in [] }
        )
        #expect(server.state.serviceName.utf8.count <= 63)
        #expect(server.state.serviceName.hasPrefix("Tidux助手 - "))
    }

    private func makeServer(
        credentialStore: FakeMacCredentialStore,
        listener: FakeMacSyncthingListener,
        recorder: TransferRecorder
    ) -> MacSyncthingSyncServer {
        MacSyncthingSyncServer(
            localDeviceID: macDeviceID,
            localDeviceName: "MacBook Test",
            credentialStore: credentialStore,
            listener: listener,
            serviceName: "Codex Test",
            transferHandler: { message, deviceID in
                await recorder.handle(message: message, deviceID: deviceID)
            }
        )
    }

    private static func credential(
        deviceID: UUID,
        tokenByte: UInt8
    ) -> MobilityMacPairingCredential {
        MobilityMacPairingCredential(
            deviceID: deviceID,
            deviceName: "Test iPhone",
            token: Data(repeating: tokenByte, count: 32).base64EncodedString()
        )
    }

    private func signedHello(
        for credential: MobilityMacPairingCredential,
        nonce: UUID = UUID(),
        deviceName: String = "Test iPhone"
    ) throws -> SyncthingPeerHello {
        try SyncthingPeerAuthentication.makeHello(
            senderDeviceID: credential.deviceID,
            intendedPeerDeviceID: macDeviceID,
            nonce: nonce,
            deviceName: deviceName,
            pairingToken: credential.token
        )
    }

    private func makeOffer(
        transferID: UUID,
        path: String,
        size: UInt64
    ) -> SyncOffer {
        SyncOffer(
            metadata: SyncItemMetadata(
                transferID: transferID,
                direction: .macToPhone,
                mediaType: .file,
                relativePath: path,
                byteSize: size,
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
                sha256: String(repeating: "a", count: SyncSHA256.hexDigestLength)
            ),
            capabilities: SyncTransportCapabilities(
                maximumFrameSize: 1_024 * 1_024,
                preferredChunkSize: SyncProtocolLimits.maximumChunkSize
            )
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for Mac P2P server state")
    }
}

private actor TransferRecorder {
    struct Received: Equatable, Sendable {
        var message: SyncWireMessage
        var deviceID: UUID
    }

    private var messages: [Received] = []
    private var responses: [SyncWireMessage] = []

    func setResponses(_ responses: [SyncWireMessage]) {
        self.responses = responses
    }

    func handle(message: SyncWireMessage, deviceID: UUID) -> [SyncWireMessage] {
        messages.append(Received(message: message, deviceID: deviceID))
        return responses
    }

    func received() -> [Received] { messages }
}

private actor FakeMacDeltaRouter: MacSyncthingDeltaRouting {
    private var received: [SyncthingPeerMessage] = []
    private var responses: [SyncthingPeerMessage] = []
    private var offers: [SyncOffer] = []
    private var activeTransferIDs: Set<UUID> = []

    func setResponses(_ responses: [SyncthingPeerMessage]) {
        self.responses = responses
    }

    func publish(_ offer: SyncOffer) async throws -> SyncthingPeerMessage? {
        offers.append(offer)
        guard activeTransferIDs.insert(offer.metadata.transferID).inserted else {
            return nil
        }
        return .indexUpdate(SyncthingPeerIndexUpdate(
            folderID: SyncthingTransferFolderID.make(
                transferID: offer.metadata.transferID
            ),
            sequence: 1,
            entries: []
        ))
    }

    func receive(_ message: SyncthingPeerMessage) async throws -> [SyncthingPeerMessage] {
        received.append(message)
        return responses
    }

    func receivedMessages() -> [SyncthingPeerMessage] { received }
    func publishedOffers() -> [SyncOffer] { offers }
}

private final class FakeMacCredentialStore: MobilityMacCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentialsByDeviceID: [UUID: MobilityMacPairingCredential]

    init(credentials: [MobilityMacPairingCredential]) {
        self.credentialsByDeviceID = Dictionary(
            credentials.map { ($0.deviceID, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    func issueCredential(
        deviceID: UUID,
        deviceName: String,
        pairedAt: Date
    ) throws -> MobilityMacPairingCredential {
        lock.lock()
        defer { lock.unlock() }
        let credential = MobilityMacPairingCredential(
            deviceID: deviceID,
            deviceName: deviceName,
            token: Data(repeating: 9, count: 32).base64EncodedString(),
            pairedAt: pairedAt
        )
        credentialsByDeviceID[deviceID] = credential
        return credential
    }

    func pairedDevices() throws -> [MobilityMacPairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return credentialsByDeviceID.values.map {
            MobilityMacPairedDevice(
                deviceID: $0.deviceID,
                deviceName: $0.deviceName,
                pairedAt: $0.pairedAt
            )
        }.sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
    }

    func credential(for deviceID: UUID) throws -> MobilityMacPairingCredential? {
        lock.lock()
        defer { lock.unlock() }
        return credentialsByDeviceID[deviceID]
    }

    func credential(matchingToken token: String) throws -> MobilityMacPairingCredential? {
        lock.lock()
        defer { lock.unlock() }
        return credentialsByDeviceID.values.first { $0.token == token }
    }

    func revokeCredential(for deviceID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        credentialsByDeviceID[deviceID] = nil
    }
}

@MainActor
private final class FakeMacSyncthingListener: MacSyncthingPeerListening {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var startedCredentials: [SyncthingPeerCredential] = []
    private var onConnection: (@Sendable (any MacSyncthingPeerConnectionProtocol) async -> Void)?
    private var onStateChange: (@Sendable (MacSyncthingPeerListenerState) -> Void)?

    func start(
        serviceName: String,
        credentials: [SyncthingPeerCredential],
        onConnection: @escaping @Sendable (any MacSyncthingPeerConnectionProtocol) async -> Void,
        onStateChange: @escaping @Sendable (MacSyncthingPeerListenerState) -> Void,
        onConnectionError: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = serviceName
        _ = onConnectionError
        startCount += 1
        startedCredentials = credentials.sorted {
            $0.deviceID.uuidString < $1.deviceID.uuidString
        }
        self.onConnection = onConnection
        self.onStateChange = onStateChange
        onStateChange(.ready)
        await Task.yield()
    }

    func stop() async {
        stopCount += 1
        onConnection = nil
        onStateChange = nil
    }

    func connect(_ connection: any MacSyncthingPeerConnectionProtocol) async {
        await onConnection?(connection)
    }

    func emit(_ state: MacSyncthingPeerListenerState) {
        onStateChange?(state)
    }
}

private actor FakeMacSyncthingConnection: MacSyncthingPeerConnectionProtocol {
    private var inbound: [SyncthingPeerMessage] = []
    private var receiveContinuation: CheckedContinuation<SyncthingPeerMessage?, Never>?
    private var sent: [SyncthingPeerMessage] = []
    private var closedWith: SyncthingPeerClose?
    private var cancelled = false
    private var shouldFailNextSend = false

    func enqueue(_ message: SyncthingPeerMessage) {
        if let receiveContinuation {
            self.receiveContinuation = nil
            receiveContinuation.resume(returning: message)
        } else {
            inbound.append(message)
        }
    }

    func receive() async throws -> SyncthingPeerMessage? {
        if !inbound.isEmpty {
            return inbound.removeFirst()
        }
        if cancelled || closedWith != nil {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func send(_ message: SyncthingPeerMessage) async throws {
        if shouldFailNextSend {
            shouldFailNextSend = false
            throw FakeMacSyncthingConnectionError.sendFailed
        }
        sent.append(message)
    }

    func close(_ close: SyncthingPeerClose) async throws {
        closedWith = close
        finishReceive()
    }

    func cancel() async {
        cancelled = true
        finishReceive()
    }

    func sentMessages() -> [SyncthingPeerMessage] { sent }
    func closeMessage() -> SyncthingPeerClose? { closedWith }
    func wasCancelled() -> Bool { cancelled }
    func failNextSend() { shouldFailNextSend = true }

    private func finishReceive() {
        guard let receiveContinuation else { return }
        self.receiveContinuation = nil
        receiveContinuation.resume(returning: nil)
    }
}

private enum FakeMacSyncthingConnectionError: Error {
    case sendFailed
}
