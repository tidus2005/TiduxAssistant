import CodexMobilityCore
import Foundation
import Testing
@testable import CodexMobilityPhoneFeature

@MainActor @Suite("Companion dual channel media")
struct CompanionMediaRoutingTests {
    @Test func legacyDeltaIndexesCannotBypassExplicitSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobilityPhoneSyncStore(storageRoot: root, requiresIncomingApproval: true)
        store.usesDualChannelRouting = true
        store.peerConnectionDidBecomeReady()
        let id = UUID()
        let messages: [SyncthingPeerMessage] = [
            .index(.init(messageID: id, folderID: "test", sequence: 1, entries: [])),
            .indexUpdate(.init(messageID: id, folderID: "test", sequence: 2, entries: []))
        ]
        for message in messages {
            let responses = try await store.receivePeerMessage(message)
            #expect(responses.count == 1)
            guard case .ack(let ack) = responses.first else {
                Issue.record("Expected rejection without requesting any file blocks")
                continue
            }
            #expect(ack.acknowledgedMessageID == id)
            #expect(ack.status == .rejected)
        }
        #expect(store.incomingTransfers.isEmpty)
    }

    @Test func unsolicitedMacDirectoryIsBoundedAndRequiresSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobilityPhoneSyncStore(storageRoot: root, requiresIncomingApproval: true)
        store.usesDualChannelRouting = true
        var responses: [SyncWireMessage] = []
        store.sendMessage = { responses.append($0) }
        for index in 0..<100 {
            let metadata = SyncItemMetadata(direction: .macToPhone, mediaType: .file,
                relativePath: "file-\(index).txt", byteSize: 10, modifiedAt: Date(), sha256: SyncSHA256.hexDigest(Data(repeating: 0, count: 10)))
            store.receive(.offer(SyncOffer(metadata: metadata, capabilities: store.localCapabilities)))
        }
        #expect(store.availableMacFiles.count == 32)
        #expect(store.incomingTransfers.isEmpty)
        #expect(responses.isEmpty)
        store.receiveMacFile(try #require(store.availableMacFiles.first))
        #expect(store.incomingTransfers.count == 1)
        #expect(responses.contains { if case .accept = $0 { true } else { false } })
    }

    @Test func legacyAutomaticQueueIsArchivedWithoutDeletingPartials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = MobilityPhoneSyncStore(storageRoot: root)
        let metadata = SyncItemMetadata(direction: .macToPhone, mediaType: .file,
            relativePath: "old.txt", byteSize: 10, modifiedAt: Date(), sha256: SyncSHA256.hexDigest(Data(repeating: 0, count: 10)))
        legacy.receive(.offer(SyncOffer(metadata: metadata, capabilities: legacy.localCapabilities)))
        let updated = MobilityPhoneSyncStore(storageRoot: root, requiresIncomingApproval: true)
        #expect(updated.incomingTransfers.isEmpty)
        #expect(updated.pausedLegacyIncomingCount == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(files.contains { $0.hasPrefix("legacy-auto-receive-") })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Incoming").path))
        let reopened = MobilityPhoneSyncStore(storageRoot: root, requiresIncomingApproval: true)
        #expect(reopened.pausedLegacyIncomingCount == 0)
    }

    @Test func boundaries() {
        #expect(CompanionFileRouting.route(byteSize: 65_536, bluetoothReady: true, networkReady: true) == .bluetooth)
        #expect(CompanionFileRouting.route(byteSize: 65_537, bluetoothReady: true, networkReady: false) == .waitingForNetwork)
        #expect(CompanionFileRouting.route(byteSize: 2_000_000_000, bluetoothReady: true, networkReady: true) == .localNetwork)
        #expect(CompanionFileRouting.route(byteSize: 1, bluetoothReady: false, networkReady: true) == .localNetwork)
    }

    @Test func largeFileWaitsForNetworkAndResumesOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("test-video.mov")
        let bytes = Data(repeating: 42, count: 150_000)
        try bytes.write(to: source)
        let store = MobilityPhoneSyncStore(storageRoot: root.appendingPathComponent("state"))
        store.usesDualChannelRouting = true
        var ble: [SyncWireMessage] = []
        var lan: [SyncWireMessage] = []
        var requests = 0
        store.sendMessage = { ble.append($0) }
        store.sendNetworkMessage = { lan.append($0); return true }
        store.requestHighSpeedConnection = { requests += 1 }
        store.connectionDidBecomeReady()
        await store.enqueueFiles([source])
        #expect(requests == 1)
        #expect(store.outgoingTransfers.first?.status == .waitingForConnection)
        #expect(!ble.contains { if case .offer = $0 { true } else { false } })
        store.peerConnectionDidBecomeReady()
        let offer = try #require(lan.compactMap { if case .offer(let o) = $0 { o } else { nil } }.last)
        let parameters = SyncTransferParameters(maximumFrameSize: 1_048_576, chunkSize: 65_536, windowSize: 1)
        store.receive(.accept(SyncAcceptance(transferID: offer.metadata.transferID,
            acceptedRelativePath: offer.metadata.relativePath, resumeOffset: 65_536, parameters: parameters)), viaNetwork: true)
        let chunk = try #require(lan.compactMap { if case .chunk(let c) = $0 { c } else { nil } }.last)
        #expect(chunk.offset == 65_536)
        #expect(chunk.data == bytes[65_536..<131_072])
        store.peerConnectionDidClose()
        #expect(store.outgoingTransfers.first?.status == .waitingForConnection)
        #expect(!ble.contains { if case .chunk = $0 { true } else { false } })
        store.peerConnectionDidBecomeReady()
        store.receive(.accept(SyncAcceptance(transferID: offer.metadata.transferID,
            acceptedRelativePath: offer.metadata.relativePath, resumeOffset: 131_072, parameters: parameters)), viaNetwork: true)
        let resumed = try #require(lan.compactMap { if case .chunk(let c) = $0 { c } else { nil } }.last)
        #expect(resumed.offset == 131_072)
        #expect(resumed.data == bytes.suffix(18_928))
        // Stale BLE receipts cannot advance the Wi-Fi sender.
        store.receive(.ack(SyncAcknowledgement(transferID: offer.metadata.transferID,
            nextExpectedOffset: 150_000, availableWindow: 1)))
        #expect(store.outgoingTransfers.first?.confirmedBytes == 131_072)
    }

    @Test func networkCancellationAndStalledOfferStayOnCorrectChannel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("video.mov")
        try Data(repeating: 7, count: 70_000).write(to: source)
        let store = MobilityPhoneSyncStore(storageRoot: root.appendingPathComponent("state"))
        store.usesDualChannelRouting = true
        var ble: [SyncWireMessage] = []
        var lan: [SyncWireMessage] = []
        store.sendMessage = { ble.append($0) }
        store.sendNetworkMessage = { lan.append($0); return true }
        store.connectionDidBecomeReady()
        store.peerConnectionDidBecomeReady()
        await store.enqueueFiles([source])
        let id = try #require(store.outgoingTransfers.first?.id)
        #expect(lan.count == 1)
        store.recoverStalledTransfers(now: Date().addingTimeInterval(31))
        #expect(lan.count == 2)
        store.cancel(id)
        #expect(lan.contains { if case .cancel(let c) = $0 { c.transferID == id } else { false } })
        #expect(!ble.contains { if case .cancel = $0 { true } else { false } })
        #expect(store.outgoingTransfers.isEmpty)
    }

    @Test func smallFileUsesBLEEvenWhenWiFiAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("small.txt")
        try Data("hello".utf8).write(to: source)
        let store = MobilityPhoneSyncStore(storageRoot: root.appendingPathComponent("state"))
        store.usesDualChannelRouting = true
        var ble: [SyncWireMessage] = []
        var lan: [SyncWireMessage] = []
        store.sendMessage = { ble.append($0) }
        store.sendNetworkMessage = { lan.append($0); return true }
        store.connectionDidBecomeReady()
        store.peerConnectionDidBecomeReady()
        await store.enqueueFiles([source])
        #expect(ble.contains { if case .offer = $0 { true } else { false } })
        #expect(lan.isEmpty)
    }
}
