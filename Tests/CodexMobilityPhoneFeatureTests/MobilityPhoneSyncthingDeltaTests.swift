import CodexMobilityCore
import Foundation
import Testing
@testable import CodexMobilityPhoneFeature

@MainActor
@Suite("Mobility phone Syncthing delta wiring")
struct MobilityPhoneSyncthingDeltaTests {
    @Test("Small phone files publish one delta index, serve blocks, and finish only after ACK")
    func outgoingSmallFileUsesDeltaWithoutLegacyOffer() async throws {
        let fixture = try PhoneDeltaFixture()
        defer { fixture.remove() }
        let payload = Data((0..<180_000).map { UInt8(truncatingIfNeeded: $0 * 19) })
        let source = fixture.root.appendingPathComponent("boarding-pass.pdf")
        try payload.write(to: source)

        let store = fixture.makeStore()
        store.configureSyncthingDeviceID(UUID())
        var peerMessages: [SyncthingPeerMessage] = []
        var legacyMessages: [SyncWireMessage] = []
        store.sendPeerMessage = { message in
            peerMessages.append(message)
            return true
        }
        store.sendMessage = { legacyMessages.append($0) }

        await store.enqueueFiles([source])
        store.peerConnectionDidBecomeReady()
        try await waitUntil { peerMessages.contains(where: { $0.deltaIndex != nil }) }

        let published = try #require(peerMessages.compactMap(\.deltaIndex).last)
        let index = try #require(published.entries.first)
        let transferID = try #require(
            SyncthingTransferFolderID.transferID(from: published.folderID)
        )
        #expect(index.wholeFileSHA256 == SyncSHA256.hexDigest(payload))
        #expect(legacyMessages.compactMap(\.offer).isEmpty)
        #expect(store.outgoingTransfers.first?.id == transferID)

        for blockInfo in index.blocks {
            let block = SyncthingBlockRequest(block: blockInfo)
            let responses = try await store.receivePeerMessage(.blockRequest(
                SyncthingPeerBlockRequest(
                    folderID: published.folderID,
                    relativePath: index.relativePath,
                    block: block
                )
            ))
            let response = try #require(responses.compactMap(\.blockResponse).first)
            let start = Int(block.offset)
            #expect(response.data == payload[start..<(start + block.size)])
        }

        #expect(store.outgoingTransfers.count == 1)
        _ = try await store.receivePeerMessage(.ack(SyncthingPeerAcknowledgement(
            acknowledgedMessageID: published.messageID,
            status: .accepted
        )))
        #expect(store.outgoingTransfers.isEmpty)
        #expect(store.recentResults.first?.id == transferID)
        #expect(store.recentResults.first?.status == .completed)
        let stagedDirectory = fixture.root
            .appendingPathComponent("Outgoing", isDirectory: true)
            .appendingPathComponent(transferID.uuidString.lowercased(), isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
    }

    @Test("Incoming delta reuses a legacy partial, atomically commits Files, then imports Photos")
    func incomingDeltaReusesPartialAndCommits() async throws {
        let fixture = try PhoneDeltaFixture()
        defer { fixture.remove() }
        let importer = DeltaFailingPhotoImporter()
        let store = fixture.makeStore(photoImporter: importer)
        store.configureSyncthingDeviceID(UUID())
        store.peerConnectionDidBecomeReady()

        let blockSize = SyncthingBlockSizePolicy.minimumBlockSize
        let payload = Data((0..<(blockSize * 2 + 71)).map {
            UInt8(truncatingIfNeeded: $0 * 23 + ($0 / blockSize) * 61)
        })
        let transferID = UUID()
        let folderID = SyncthingTransferFolderID.make(transferID: transferID)
        let index = try SyncthingPlanner.fileIndex(
            for: payload,
            relativePath: "Trips/gate-photo.jpg",
            modifiedAt: Date(timeIntervalSince1970: 1_720_000_000),
            deviceID: "mac",
            version: SyncthingVersionVector(counters: ["mac": 1]),
            sequence: 1
        )
        let firstBlock = index.blocks[0]
        let partialURL = fixture.root
            .appendingPathComponent("Incoming", isDirectory: true)
            .appendingPathComponent(transferID.uuidString.lowercased())
            .appendingPathExtension("partial")
        try payload.prefix(firstBlock.size).write(to: partialURL)
        let messageID = UUID()

        let requests = try await store.receivePeerMessage(.index(SyncthingPeerIndex(
            messageID: messageID,
            folderID: folderID,
            sequence: index.sequence,
            entries: [index]
        )))
        let blockRequests = requests.compactMap(\.blockRequest)
        #expect(blockRequests.count == index.blocks.count - 1)
        #expect(!blockRequests.contains(where: { $0.block.offset == firstBlock.offset }))
        #expect(store.incomingTransfers.first?.confirmedBytes == UInt64(firstBlock.size))

        var terminalAcknowledgement: SyncthingPeerAcknowledgement?
        for request in blockRequests {
            let start = Int(request.block.offset)
            let data = Data(payload[start..<(start + request.block.size)])
            let responses = try await store.receivePeerMessage(.blockResponse(
                SyncthingPeerBlockResponse(
                    requestID: request.requestID,
                    folderID: request.folderID,
                    relativePath: request.relativePath,
                    block: request.block,
                    data: data
                )
            ))
            terminalAcknowledgement = responses.compactMap(\.peerAcknowledgement).last
                ?? terminalAcknowledgement
        }

        #expect(terminalAcknowledgement?.acknowledgedMessageID == messageID)
        #expect(terminalAcknowledgement?.status == .accepted)
        try await waitUntil { store.recentResults.first?.status == .completedWithWarning }
        let result = try #require(store.recentResults.first)
        let storedURL = try #require(result.localURL)
        #expect(try Data(contentsOf: storedURL) == payload)
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(importer.receivedURLs == [storedURL])

        // Re-advertising the identical file must produce an immediate zero-block ACK
        // and must not create a second conflict copy.
        store.peerConnectionDidClose()
        store.peerConnectionDidBecomeReady()
        let repeatMessageID = UUID()
        let repeatResponses = try await store.receivePeerMessage(.index(SyncthingPeerIndex(
            messageID: repeatMessageID,
            folderID: folderID,
            sequence: index.sequence,
            entries: [index]
        )))
        #expect(repeatResponses.compactMap(\.blockRequest).isEmpty)
        #expect(repeatResponses.compactMap(\.peerAcknowledgement).first?.acknowledgedMessageID
            == repeatMessageID)
        let inboxFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.inbox,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        #expect(inboxFiles.count == 1)
    }

    @Test("BLE cannot duplicate a delta claim and takes over after the peer disconnects")
    func legacyHandoffDoesNotDuplicateActiveDelta() async throws {
        let fixture = try PhoneDeltaFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("small.txt")
        try Data("hello delta".utf8).write(to: source)
        let store = fixture.makeStore()
        var peerMessages: [SyncthingPeerMessage] = []
        var legacyMessages: [SyncWireMessage] = []
        store.sendPeerMessage = {
            peerMessages.append($0)
            return true
        }
        store.sendMessage = { legacyMessages.append($0) }

        await store.enqueueFiles([source])
        store.peerConnectionDidBecomeReady()
        try await waitUntil { peerMessages.contains(where: { $0.deltaIndex != nil }) }
        store.connectionDidBecomeReady()
        #expect(legacyMessages.compactMap(\.offer).isEmpty)

        store.peerConnectionDidClose()
        try await waitUntil { !legacyMessages.compactMap(\.offer).isEmpty }
        let legacyOffer = try #require(legacyMessages.compactMap(\.offer).last)
        let deltaIndex = try #require(peerMessages.compactMap(\.deltaIndex).last)
        #expect(SyncthingTransferFolderID.transferID(from: deltaIndex.folderID)
            == legacyOffer.metadata.transferID)
    }

    @Test("Oversized incoming index is rejected so the Mac can use legacy file-backed transfer")
    func oversizedIncomingRequestsLegacyFallback() async throws {
        let fixture = try PhoneDeltaFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.peerConnectionDidBecomeReady()
        let index = try oversizedIndex()
        let messageID = UUID()
        let responses = try await store.receivePeerMessage(.index(SyncthingPeerIndex(
            messageID: messageID,
            folderID: SyncthingTransferFolderID.make(transferID: UUID()),
            sequence: index.sequence,
            entries: [index]
        )))

        let acknowledgement = try #require(responses.compactMap(\.peerAcknowledgement).first)
        #expect(acknowledgement.acknowledgedMessageID == messageID)
        #expect(acknowledgement.status == .rejected)
        #expect(acknowledgement.detail?.contains("legacy") == true)
        #expect(store.transfers.isEmpty)
    }

    private func oversizedIndex() throws -> SyncthingFileIndex {
        let size = SyncthingDeltaSession.maximumInMemoryFileSize + 1
        let hash = String(repeating: "0", count: SyncSHA256.hexDigestLength)
        var blocks: [SyncthingBlockInfo] = []
        var offset: UInt64 = 0
        while offset < size {
            let count = Int(min(
                UInt64(SyncthingBlockSizePolicy.maximumBlockSize),
                size - offset
            ))
            blocks.append(try SyncthingBlockInfo(offset: offset, size: count, sha256: hash))
            offset += UInt64(count)
        }
        return try SyncthingFileIndex(
            relativePath: "large.bin",
            size: size,
            modifiedAt: .now,
            wholeFileSHA256: hash,
            blocks: blocks,
            deviceID: "mac",
            version: SyncthingVersionVector(counters: ["mac": 1]),
            sequence: 1
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Syncthing phone state")
    }
}

@MainActor
private final class DeltaFailingPhotoImporter: MobilityPhonePhotoImporting {
    private(set) var receivedURLs: [URL] = []

    func addToPhotoLibrary(fileURL: URL, mediaType: SyncMediaType) async throws {
        receivedURLs.append(fileURL)
        throw MobilityPhoneSyncError.photoLibraryDenied
    }
}

private struct PhoneDeltaFixture {
    let base: URL
    let root: URL
    let inbox: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneDeltaTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("State", isDirectory: true)
        inbox = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    @MainActor
    func makeStore(
        photoImporter: (any MobilityPhonePhotoImporting)? = nil
    ) -> MobilityPhoneSyncStore {
        MobilityPhoneSyncStore(
            storageRoot: root,
            inboxDirectory: inbox,
            photoImporter: photoImporter
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

private extension SyncthingPeerMessage {
    var deltaIndex: SyncthingPeerIndex? {
        guard case .index(let index) = self else { return nil }
        return index
    }

    var blockRequest: SyncthingPeerBlockRequest? {
        guard case .blockRequest(let request) = self else { return nil }
        return request
    }

    var blockResponse: SyncthingPeerBlockResponse? {
        guard case .blockResponse(let response) = self else { return nil }
        return response
    }

    var peerAcknowledgement: SyncthingPeerAcknowledgement? {
        guard case .ack(let acknowledgement) = self else { return nil }
        return acknowledgement
    }
}

private extension SyncWireMessage {
    var offer: SyncOffer? {
        guard case .offer(let offer) = self else { return nil }
        return offer
    }
}
