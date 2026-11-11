import CodexMobilityCore
import Foundation
import Testing
@testable import CodexMobilityPhoneFeature

@MainActor
@Suite("Mobility phone file sync")
struct MobilityPhoneSyncStoreTests {
    @Test("Outgoing queue survives restart and resumes from the Mac offset")
    func outgoingQueuePersistsAndResumes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data((0..<160).map { UInt8($0) })
        let source = fixture.root.appendingPathComponent("trip-notes.bin")
        try payload.write(to: source)

        var firstMessages: [SyncWireMessage] = []
        let firstStore = fixture.makeStore()
        firstStore.sendMessage = { firstMessages.append($0) }
        await firstStore.enqueueFiles([source])
        firstStore.connectionDidBecomeReady()

        let offer = try #require(firstMessages.compactMap(\.offer).last)
        let parameters = SyncTransferParameters(
            maximumFrameSize: 185,
            chunkSize: 64,
            windowSize: 1
        )
        firstStore.receive(.accept(SyncAcceptance(
            transferID: offer.metadata.transferID,
            acceptedRelativePath: offer.metadata.relativePath,
            resumeOffset: 0,
            parameters: parameters
        )))
        let firstChunk = try #require(firstMessages.compactMap(\.chunk).last)
        #expect(firstChunk.offset == 0)
        #expect(firstChunk.data == payload.prefix(64))
        firstStore.receive(.ack(SyncAcknowledgement(
            transferID: offer.metadata.transferID,
            nextExpectedOffset: 64,
            availableWindow: 1
        )))
        #expect(firstStore.outgoingTransfers.first?.confirmedBytes == 64)

        var resumedMessages: [SyncWireMessage] = []
        let resumedStore = fixture.makeStore()
        resumedStore.sendMessage = { resumedMessages.append($0) }
        #expect(resumedStore.outgoingTransfers.first?.confirmedBytes == 64)
        resumedStore.connectionDidBecomeReady()
        resumedStore.receive(.accept(SyncAcceptance(
            transferID: offer.metadata.transferID,
            acceptedRelativePath: offer.metadata.relativePath,
            resumeOffset: 64,
            parameters: parameters
        )))

        let resumedChunk = try #require(resumedMessages.compactMap(\.chunk).last)
        #expect(resumedChunk.offset == 64)
        #expect(resumedChunk.data == payload[64..<128])
    }

    @Test("Incoming media is verified, committed to Files, and retained when Photos rejects it")
    func incomingMediaKeepsFilesCopyWhenPhotosFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let photoImporter = FailingPhotoImporter()
        let store = fixture.makeStore(photoImporter: photoImporter)
        var messages: [SyncWireMessage] = []
        store.sendMessage = { messages.append($0) }
        store.connectionDidBecomeReady()

        let payload = Data("verified image bytes".utf8)
        let metadata = try SyncItemMetadata(
            direction: .macToPhone,
            mediaType: .image,
            relativePath: "boarding-pass.jpg",
            byteSize: UInt64(payload.count),
            modifiedAt: .now,
            sha256: SyncSHA256.hexDigest(payload)
        ).validated()
        store.receive(.offer(SyncOffer(
            metadata: metadata,
            capabilities: SyncTransportCapabilities(
                maximumFrameSize: 185,
                preferredChunkSize: 64,
                maximumWindowSize: 1
            )
        )))

        let acceptance = try #require(messages.compactMap(\.accept).last)
        #expect(acceptance.resumeOffset == 0)
        store.receive(.chunk(SyncChunk(
            transferID: metadata.transferID,
            offset: 0,
            data: payload,
            isFinal: true
        )))
        #expect(messages.compactMap(\.ack).last?.nextExpectedOffset == UInt64(payload.count))

        store.receive(.complete(SyncCompletion(
            transferID: metadata.transferID,
            totalBytes: UInt64(payload.count),
            sha256: metadata.sha256,
            stage: .senderFinished
        )))
        try await waitUntil { !store.recentResults.isEmpty }
        try await waitUntil { store.recentResults.first?.status == .completedWithWarning }

        let result = try #require(store.recentResults.first)
        #expect(result.status == .completedWithWarning)
        let storedURL = try #require(result.localURL)
        #expect(try Data(contentsOf: storedURL) == payload)
        #expect(photoImporter.receivedURLs == [storedURL])
        let storedCompletion = try #require(messages.compactMap(\.complete).last)
        #expect(storedCompletion.stage == .receiverStored)
        #expect(storedCompletion.storedRelativePath == storedURL.lastPathComponent)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root
                .appendingPathComponent("Incoming")
                .appendingPathComponent(metadata.transferID.uuidString.lowercased())
                .appendingPathExtension("partial")
                .path
        ))
    }

    @Test("Invalid sender completion never exposes a file in Documents")
    func invalidCompletionDoesNotCommitPartial() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        var messages: [SyncWireMessage] = []
        store.sendMessage = { messages.append($0) }
        store.connectionDidBecomeReady()

        let payload = Data("private partial".utf8)
        let metadata = SyncItemMetadata(
            direction: .macToPhone,
            mediaType: .file,
            relativePath: "sensitive.txt",
            byteSize: UInt64(payload.count),
            modifiedAt: .now,
            sha256: SyncSHA256.hexDigest(payload)
        )
        store.receive(.offer(SyncOffer(
            metadata: metadata,
            capabilities: SyncTransportCapabilities(
                maximumFrameSize: 185,
                preferredChunkSize: 64,
                maximumWindowSize: 1
            )
        )))
        store.receive(.chunk(SyncChunk(
            transferID: metadata.transferID,
            offset: 0,
            data: payload,
            isFinal: true
        )))
        store.receive(.complete(SyncCompletion(
            transferID: metadata.transferID,
            totalBytes: UInt64(payload.count),
            sha256: String(repeating: "0", count: 64),
            stage: .senderFinished
        )))

        try await waitUntil { store.transfers.first?.status == .failed }
        let inboxContents = try FileManager.default.contentsOfDirectory(
            at: fixture.inbox,
            includingPropertiesForKeys: nil
        )
        #expect(inboxContents.isEmpty)
        #expect(messages.compactMap(\.failure).last?.code == .checksumMismatch)
    }

    @Test("Oversized files are rejected before entering the durable queue")
    func oversizedFileIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("too-large.dat")
        try Data(repeating: 7, count: 9).write(to: source)
        let store = fixture.makeStore(maximumFileSize: 8)

        await store.enqueueFiles([source])

        #expect(store.transfers.isEmpty)
        #expect(store.lastErrorMessage?.contains("超过单文件上限") == true)
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous file finalization")
    }
}

@MainActor
private final class FailingPhotoImporter: MobilityPhonePhotoImporting {
    private(set) var receivedURLs: [URL] = []

    func addToPhotoLibrary(fileURL: URL, mediaType: SyncMediaType) async throws {
        receivedURLs.append(fileURL)
        throw MobilityPhoneSyncError.photoLibraryDenied
    }
}

private struct Fixture {
    let root: URL
    let inbox: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobilityPhoneSyncTests-\(UUID().uuidString)", isDirectory: true)
        self.root = base.appendingPathComponent("State", isDirectory: true)
        self.inbox = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    @MainActor
    func makeStore(
        maximumFileSize: UInt64 = SyncProtocolLimits.maximumItemSize,
        photoImporter: (any MobilityPhonePhotoImporting)? = nil
    ) -> MobilityPhoneSyncStore {
        MobilityPhoneSyncStore(
            storageRoot: root,
            inboxDirectory: inbox,
            maximumFileSize: maximumFileSize,
            photoImporter: photoImporter
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

private extension SyncWireMessage {
    var offer: SyncOffer? {
        guard case .offer(let value) = self else { return nil }
        return value
    }

    var accept: SyncAcceptance? {
        guard case .accept(let value) = self else { return nil }
        return value
    }

    var chunk: SyncChunk? {
        guard case .chunk(let value) = self else { return nil }
        return value
    }

    var ack: SyncAcknowledgement? {
        guard case .ack(let value) = self else { return nil }
        return value
    }

    var complete: SyncCompletion? {
        guard case .complete(let value) = self else { return nil }
        return value
    }

    var failure: SyncFailure? {
        guard case .failure(let value) = self else { return nil }
        return value
    }
}
