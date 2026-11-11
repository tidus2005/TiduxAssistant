@testable import CodexMobilityMacFeature
import CodexMobilityPhoneFeature
import CodexMobilityCore
import Foundation
import Testing

@MainActor
private final class WireTestDirectoryPreferences: MacSyncDirectoryPreferencePersisting {
    private var bookmark: Data?
    private var enabled: Bool

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    func loadBookmark() -> Data? { bookmark }
    func saveBookmark(_ bookmark: Data?) { self.bookmark = bookmark }
    func loadIsEnabled() -> Bool { enabled }
    func saveIsEnabled(_ enabled: Bool) { self.enabled = enabled }
}

@MainActor
private final class WireTestDirectoryChooser: MacSyncDirectoryChoosing {
    func chooseDirectory() -> URL? { nil }
}

@Suite("Mac file sync wire controller")
@MainActor
struct MacFileSyncWireControllerTests {
    private let phoneDeviceID = UUID(uuidString: "A2D9482B-BE4B-4FC1-922A-BD67B86E2402")!
    private let codec = SyncJSONCodec()

    @Test("Phone offer, chunks and senderFinished commit a file and return receiverStored")
    func phoneToMacCompletesAcrossWire() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore()
        try await store.selectDirectory(root)
        let controller = MacFileSyncWireController(store: store)

        let payload = Data("boarding pass sent over bluetooth".utf8)
        let metadata = SyncItemMetadata(
            transferID: UUID(uuidString: "E674152F-B357-470F-A9DB-2AAC1075E6F4")!,
            direction: .phoneToMac,
            mediaType: .file,
            relativePath: "Trips/boarding-pass.txt",
            byteSize: UInt64(payload.count),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sha256: SyncSHA256.hexDigest(payload)
        )
        let offer = SyncWireMessage.offer(
            SyncOffer(
                metadata: metadata,
                capabilities: SyncTransportCapabilities(
                    maximumFrameSize: 60 * 1_024,
                    preferredChunkSize: 8 * 1_024,
                    maximumWindowSize: 1
                )
            )
        )

        let acceptance = try #require(
            try await sendAcrossWire(offer, to: controller).onlyAcceptance
        )
        #expect(acceptance.transferID == metadata.transferID)
        #expect(acceptance.resumeOffset == 0)
        #expect(acceptance.acceptedRelativePath == metadata.relativePath)

        let splitIndex = 11
        let firstChunk = SyncChunk(
            transferID: metadata.transferID,
            offset: 0,
            data: payload.prefix(splitIndex),
            isFinal: false
        )
        let firstAck = try #require(
            try await sendAcrossWire(.chunk(firstChunk), to: controller).onlyAcknowledgement
        )
        #expect(firstAck.nextExpectedOffset == UInt64(splitIndex))

        let secondChunk = SyncChunk(
            transferID: metadata.transferID,
            offset: UInt64(splitIndex),
            data: payload.dropFirst(splitIndex),
            isFinal: true
        )
        let finalAck = try #require(
            try await sendAcrossWire(.chunk(secondChunk), to: controller).onlyAcknowledgement
        )
        #expect(finalAck.nextExpectedOffset == UInt64(payload.count))

        let completion = SyncCompletion(
            transferID: metadata.transferID,
            totalBytes: UInt64(payload.count),
            sha256: metadata.sha256,
            stage: .senderFinished
        )
        let stored = try #require(
            try await sendAcrossWire(.complete(completion), to: controller).onlyCompletion
        )
        #expect(stored.stage == .receiverStored)
        #expect(stored.transferID == metadata.transferID)
        #expect(stored.totalBytes == UInt64(payload.count))
        #expect(stored.sha256 == metadata.sha256)
        #expect(stored.storedRelativePath == metadata.relativePath)

        let finalURL = root.appendingPathComponent(metadata.relativePath)
        #expect(try Data(contentsOf: finalURL) == payload)
        #expect(store.queue.allSatisfy { $0.transferID != metadata.transferID })
        #expect(store.recentResults.first?.relativePath == metadata.relativePath)
        #expect(store.recentResults.first?.succeeded == true)

        await store.clearDirectory()
        store.shutdown()
    }

    @Test("requestOffers reoffers known transfers first so a receiver can resume")
    func requestOffersReoffersKnownTransfer() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("alpha".utf8).write(to: root.appendingPathComponent("a-first.txt"))
        try Data("omega".utf8).write(to: root.appendingPathComponent("z-resume.txt"))

        let store = makeStore(watcherPollingInterval: 0.2, watcherStableInterval: 0)
        try await store.selectDirectory(root)
        let controller = MacFileSyncWireController(store: store)
        let initialOffers = try await waitForOffers(count: 2, from: controller)

        let knownOffer = try #require(initialOffers.compactMap(\.offer).first {
            $0.metadata.relativePath == "z-resume.txt"
        })
        let knownTransferID = knownOffer.metadata.transferID
        let request = SyncOfferRequest(
            requestID: UUID(uuidString: "685D07D3-67CB-4252-949E-6FC7E6A8E2EC")!,
            requestedDirection: .macToPhone,
            knownTransferIDs: [knownTransferID]
        )

        let responses = try await sendAcrossWire(.requestOffers(request), to: controller)
        let repeatedOffers = responses.compactMap(\.offer)

        #expect(repeatedOffers.count == initialOffers.count)
        #expect(repeatedOffers.first?.metadata.transferID == knownTransferID)
        #expect(repeatedOffers.contains { $0.metadata.transferID == knownTransferID })
        #expect(repeatedOffers.first?.metadata.relativePath == "z-resume.txt")

        await store.clearDirectory()
        store.shutdown()
    }

    @Test("Directory bursts use bounded BLE windows, preserve pending files and prioritize resume")
    func boundedOfferWindow() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<12 {
            try Data("test \(index)".utf8).write(to: root.appendingPathComponent(String(format: "%02d.txt", index)))
        }
        let store = makeStore(watcherPollingInterval: 0.2, watcherStableInterval: 0)
        try await store.selectDirectory(root)
        defer { store.shutdown() }
        let controller = MacFileSyncWireController(store: store)
        for _ in 0..<40 {
            if await store.outgoingDescriptors().count == 12 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await store.outgoingDescriptors().count == 12)
        let first = await controller.pendingOffers().compactMap(\.offer)
        #expect(first.count == MacFileSyncWireController.bluetoothOfferWindow)
        let lan = await controller.pendingOffers(transportProfile: .localNetwork).compactMap(\.offer)
        #expect(lan.count == 12)
        let resumeID = try #require(lan.last?.metadata.transferID)
        let resumed = await controller.pendingOffers(knownTransferIDs: [resumeID]).compactMap(\.offer)
        #expect(resumed.count == 4)
        #expect(resumed.first?.metadata.transferID == resumeID)
        for offer in first { try await store.markOutgoingCompleted(transferID: offer.metadata.transferID) }
        let next = await controller.pendingOffers().compactMap(\.offer)
        #expect(next.count == 4)
        #expect(Set(first.map(\.metadata.transferID)).isDisjoint(with: next.map(\.metadata.transferID)))
        #expect(await store.outgoingDescriptors().count == 8)
        await store.clearDirectory()
    }

    @Test("LAN negotiation cannot raise a Bluetooth transfer above 8 KiB")
    func transportProfilesKeepIndependentChunkLimits() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x5A, count: 64 * 1_024)
        try payload.write(to: root.appendingPathComponent("large-transfer.bin"))

        let store = makeStore(watcherPollingInterval: 0.2, watcherStableInterval: 0)
        try await store.selectDirectory(root)
        let controller = MacFileSyncWireController(store: store)
        let offer = try #require(
            try await waitForOffers(count: 1, from: controller).first?.offer
        )
        let acceptance = SyncAcceptance(
            transferID: offer.metadata.transferID,
            acceptedRelativePath: offer.metadata.relativePath,
            parameters: SyncTransferParameters(
                maximumFrameSize: MacFileSyncTransportProfile.localNetwork.maximumFrameSize,
                chunkSize: SyncProtocolLimits.maximumChunkSize,
                windowSize: 1
            )
        )

        let localNetworkChunk = try #require(
            try await sendAcrossWire(
                .accept(acceptance),
                to: controller,
                transportProfile: .localNetwork
            ).onlyChunk
        )
        #expect(localNetworkChunk.data.count == SyncProtocolLimits.maximumChunkSize)

        let bluetoothChunk = try #require(
            try await sendAcrossWire(
                .resume(SyncResume(transferID: offer.metadata.transferID, nextOffset: 0)),
                to: controller,
                transportProfile: .bluetooth
            ).onlyChunk
        )
        #expect(bluetoothChunk.data.count == MacFileSyncWireController.bluetoothChunkSize)

        await store.clearDirectory()
        store.shutdown()
    }

    @Test("Phone media streams to Mac disk, resumes after a lost ACK and verifies bytes")
    func mediaEndToEndResumesAfterLostAcknowledgement() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("MacInbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let mac = makeStore()
        try await mac.selectDirectory(inbox)
        let controller = MacFileSyncWireController(store: mac)
        let phone = MobilityPhoneSyncStore(storageRoot: root.appendingPathComponent("phone"))
        phone.usesDualChannelRouting = true
        var droppedAcknowledgement = false
        var resumedOffset: UInt64 = 0
        var blePayloadCount = 0
        let phoneID = phoneDeviceID
        let codec = codec
        phone.sendMessage = { message in
            if case .chunk = message { blePayloadCount += 1 }
        }
        phone.sendNetworkMessage = { message in
            Task {
                let responses = await controller.handle(try codec.decode(codec.encode(message)),
                    from: phoneID, transportProfile: .localNetwork)
                if case .chunk = message, !droppedAcknowledgement {
                    droppedAcknowledgement = true
                    phone.peerConnectionDidClose()
                    try await Task.sleep(for: .milliseconds(20))
                    phone.peerConnectionDidBecomeReady()
                    return // Mac has the bytes, phone never saw this ACK.
                }
                for response in responses {
                    if case .accept(let acceptance) = response { resumedOffset = max(resumedOffset, acceptance.resumeOffset) }
                    phone.receive(try codec.decode(codec.encode(response)), viaNetwork: true)
                }
            }
            return true
        }
        phone.connectionDidBecomeReady()
        phone.peerConnectionDidBecomeReady()
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("media-fixture.mp4")
        try data.write(to: source)
        await phone.enqueueFiles([source])
        for _ in 0..<500 {
            if !phone.recentResults.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(phone.recentResults.first?.status == .completed)
        #expect(resumedOffset == 65_536)
        #expect(blePayloadCount == 0)
        let stored = try Data(contentsOf: inbox.appendingPathComponent("media-fixture.mp4"))
        #expect(stored == data)
        #expect(SyncSHA256.hexDigest(stored) == SyncSHA256.hexDigest(data))
        await mac.clearDirectory()
    }

    private func makeStore(
        watcherPollingInterval: TimeInterval = 60,
        watcherStableInterval: TimeInterval = 60
    ) -> MacFileSyncStore {
        MacFileSyncStore(
            preferences: WireTestDirectoryPreferences(),
            directoryChooser: WireTestDirectoryChooser(),
            watcherPollingInterval: watcherPollingInterval,
            watcherStableInterval: watcherStableInterval
        )
    }

    private func sendAcrossWire(
        _ message: SyncWireMessage,
        to controller: MacFileSyncWireController,
        transportProfile: MacFileSyncTransportProfile = .bluetooth
    ) async throws -> [SyncWireMessage] {
        let decodedRequest = try codec.decode(codec.encode(message))
        let responses = await controller.handle(
            decodedRequest,
            from: phoneDeviceID,
            transportProfile: transportProfile
        )
        return try responses.map { try codec.decode(codec.encode($0)) }
    }

    private func waitForOffers(
        count: Int,
        from controller: MacFileSyncWireController
    ) async throws -> [SyncWireMessage] {
        for _ in 0..<30 {
            let offers = await controller.pendingOffers()
            if offers.count == count {
                return offers
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Timed out waiting for \(count) outgoing file offers")
        return await controller.pendingOffers()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexWatchPet-WireControllerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension Array where Element == SyncWireMessage {
    var onlyAcceptance: SyncAcceptance? {
        guard count == 1, case .accept(let value) = first else { return nil }
        return value
    }

    var onlyAcknowledgement: SyncAcknowledgement? {
        guard count == 1, case .ack(let value) = first else { return nil }
        return value
    }

    var onlyCompletion: SyncCompletion? {
        guard count == 1, case .complete(let value) = first else { return nil }
        return value
    }

    var onlyChunk: SyncChunk? {
        guard count == 1, case .chunk(let value) = first else { return nil }
        return value
    }
}

private extension SyncWireMessage {
    var offer: SyncOffer? {
        guard case .offer(let value) = self else { return nil }
        return value
    }
}
