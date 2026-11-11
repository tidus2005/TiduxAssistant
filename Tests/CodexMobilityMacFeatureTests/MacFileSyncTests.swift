@testable import CodexMobilityMacFeature
import CodexMobilityCore
import Foundation
import Testing

private actor DiscoveredFileCollector {
    private(set) var files: [MacSyncDiscoveredFile] = []

    func append(_ file: MacSyncDiscoveredFile) {
        files.append(file)
    }

    func snapshot() -> [MacSyncDiscoveredFile] {
        files
    }
}

@MainActor
private final class InMemorySyncDirectoryPreferences: MacSyncDirectoryPreferencePersisting {
    var bookmark: Data?
    var enabled: Bool

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    func loadBookmark() -> Data? { bookmark }
    func saveBookmark(_ bookmark: Data?) { self.bookmark = bookmark }
    func loadIsEnabled() -> Bool { enabled }
    func saveIsEnabled(_ enabled: Bool) { self.enabled = enabled }
}

@MainActor
private final class NilSyncDirectoryChooser: MacSyncDirectoryChoosing {
    func chooseDirectory() -> URL? { nil }
}

@Suite("Mac Bluetooth file sync filesystem")
struct MacFileSyncTests {
    @Test @MainActor
    func persistedSyncEnablementDefaultsOffUntilExplicitlyEnabled() throws {
        let suiteName = "MacFileSyncEnablementTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = UserDefaultsMacSyncDirectoryPreferences(defaults: defaults)

        #expect(preferences.loadIsEnabled() == false)
        preferences.saveIsEnabled(true)
        #expect(preferences.loadIsEnabled() == true)
        preferences.saveIsEnabled(false)
        #expect(preferences.loadIsEnabled() == false)
    }

    @Test("Relative paths reject traversal, absolute, hidden and temporary files")
    func safeRelativePaths() throws {
        #expect(try MacSyncFileUtilities.normalizedRelativePath("Trips/boarding-pass.pdf") == "Trips/boarding-pass.pdf")

        for path in [
            "../secret.txt",
            "/etc/passwd",
            "Trips/../../secret.txt",
            ".hidden",
            "Trips/.hidden/photo.jpg",
            "photo.partial",
            "photo.crdownload",
            "Trips\\photo.jpg"
        ] {
            #expect(throws: (any Error).self) {
                try MacSyncFileUtilities.normalizedRelativePath(path)
            }
        }
    }

    @Test("Existing symlink parents cannot escape the selected directory")
    func symlinkParentIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Escape"),
            withDestinationURL: outside
        )

        #expect(throws: MacFileSyncError.self) {
            try MacSyncFileUtilities.destinationURL(
                for: "Escape/stolen.txt",
                under: root
            )
        }
    }

    @Test("Receiver writes partial chunks, verifies SHA-256 and atomically commits")
    func incomingCommit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("hello from iPhone".utf8)
        let digest = try digest(for: payload, in: root)
        let descriptor = MacSyncFileDescriptor(
            relativePath: "Inbox/greeting.txt",
            byteCount: UInt64(payload.count),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sha256: digest
        )
        let engine = try MacSyncFileTransferEngine(rootURL: root)

        #expect(try await engine.prepareIncoming(descriptor) == 0)
        let split = 5
        #expect(
            try await engine.writeIncoming(
                transferID: descriptor.transferID,
                offset: 0,
                data: payload.prefix(split)
            ) == UInt64(split)
        )
        #expect(
            try await engine.writeIncoming(
                transferID: descriptor.transferID,
                offset: UInt64(split),
                data: payload.dropFirst(split)
            ) == UInt64(payload.count)
        )

        let completed = try await engine.completeIncoming(transferID: descriptor.transferID)
        #expect(completed.relativePath == "Inbox/greeting.txt")
        #expect(completed.reusedExistingFile == false)
        #expect(try Data(contentsOf: completed.fileURL) == payload)

        let staging = root.appendingPathComponent(MacSyncFileUtilities.stagingDirectoryName)
        let stagedFiles = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(stagedFiles.isEmpty)
    }

    @Test("Receiver resumes a matching partial file after engine recreation")
    func incomingResume() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0xA5, count: 64)
        let descriptor = MacSyncFileDescriptor(
            relativePath: "resume.bin",
            byteCount: UInt64(payload.count),
            modifiedAt: Date(),
            sha256: try digest(for: payload, in: root)
        )

        let firstEngine = try MacSyncFileTransferEngine(rootURL: root)
        _ = try await firstEngine.prepareIncoming(descriptor)
        _ = try await firstEngine.writeIncoming(
            transferID: descriptor.transferID,
            offset: 0,
            data: payload.prefix(24)
        )

        let resumedEngine = try MacSyncFileTransferEngine(rootURL: root)
        #expect(try await resumedEngine.prepareIncoming(descriptor) == 24)
        _ = try await resumedEngine.writeIncoming(
            transferID: descriptor.transferID,
            offset: 24,
            data: payload.dropFirst(24)
        )
        let completed = try await resumedEngine.completeIncoming(transferID: descriptor.transferID)
        #expect(try Data(contentsOf: completed.fileURL) == payload)
    }

    @Test("Checksum failure never exposes a final file")
    func checksumFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("corrupt me".utf8)
        let descriptor = MacSyncFileDescriptor(
            relativePath: "bad.txt",
            byteCount: UInt64(payload.count),
            modifiedAt: Date(),
            sha256: String(repeating: "0", count: 64)
        )
        let engine = try MacSyncFileTransferEngine(rootURL: root)
        _ = try await engine.prepareIncoming(descriptor)
        _ = try await engine.writeIncoming(
            transferID: descriptor.transferID,
            offset: 0,
            data: payload
        )

        await #expect(throws: MacFileSyncError.self) {
            try await engine.completeIncoming(transferID: descriptor.transferID)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad.txt").path))
    }

    @Test("Different conflict is renamed while identical destination is reused")
    func conflictPlanning() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: root.appendingPathComponent("photo.jpg"))

        let payload = Data("new".utf8)
        let descriptor = MacSyncFileDescriptor(
            relativePath: "photo.jpg",
            byteCount: UInt64(payload.count),
            modifiedAt: Date(),
            sha256: try digest(for: payload, in: root)
        )
        let engine = try MacSyncFileTransferEngine(rootURL: root)
        _ = try await engine.prepareIncoming(descriptor)
        _ = try await engine.writeIncoming(transferID: descriptor.transferID, offset: 0, data: payload)
        let renamed = try await engine.completeIncoming(transferID: descriptor.transferID)

        #expect(renamed.relativePath == "photo (1).jpg")
        #expect(try Data(contentsOf: renamed.fileURL) == payload)

        let duplicate = MacSyncFileDescriptor(
            relativePath: "photo (1).jpg",
            byteCount: UInt64(payload.count),
            modifiedAt: Date(),
            sha256: descriptor.sha256
        )
        _ = try await engine.prepareIncoming(duplicate)
        _ = try await engine.writeIncoming(transferID: duplicate.transferID, offset: 0, data: payload)
        let reused = try await engine.completeIncoming(transferID: duplicate.transferID)
        #expect(reused.reusedExistingFile)
        #expect(reused.relativePath == "photo (1).jpg")
    }

    @Test("Recently received files are suppressed from the outgoing queue once")
    func loopSuppression() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suppressor = MacSyncLoopSuppressor(lifetime: 60)
        let engine = try MacSyncFileTransferEngine(rootURL: root, loopSuppressor: suppressor)
        let payload = Data("round trip".utf8)
        let descriptor = MacSyncFileDescriptor(
            relativePath: "round-trip.txt",
            byteCount: UInt64(payload.count),
            modifiedAt: Date(),
            sha256: try digest(for: payload, in: root)
        )
        _ = try await engine.prepareIncoming(descriptor)
        _ = try await engine.writeIncoming(transferID: descriptor.transferID, offset: 0, data: payload)
        let completed = try await engine.completeIncoming(transferID: descriptor.transferID)

        let discovered = MacSyncDiscoveredFile(
            relativePath: completed.relativePath,
            fileURL: completed.fileURL,
            byteCount: completed.byteCount,
            modifiedAt: descriptor.modifiedAt,
            sha256: completed.sha256
        )
        #expect(try await engine.enqueueDiscoveredFile(discovered) == nil)
        #expect(await engine.outgoingDescriptors().isEmpty)
    }

    @Test("Watcher waits for stability and ignores partial files")
    func watcherDebounceAndIgnoreRules() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = DiscoveredFileCollector()
        let watcher = MacSyncDirectoryWatcher(
            rootURL: root,
            pollingInterval: 60,
            stableInterval: 1
        ) { file in
            await collector.append(file)
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try Data("ready".utf8).write(to: root.appendingPathComponent("ready.txt"))
        try Data("partial".utf8).write(to: root.appendingPathComponent("upload.partial"))
        await watcher.scanNow(now: start)
        #expect(await collector.snapshot().isEmpty)

        await watcher.scanNow(now: start.addingTimeInterval(0.5))
        #expect(await collector.snapshot().isEmpty)

        await watcher.scanNow(now: start.addingTimeInterval(1.1))
        let files = await collector.snapshot()
        #expect(files.map(\.relativePath) == ["ready.txt"])
    }

    @Test("Outgoing reads are bounded and reject a source changed after offering")
    func outgoingChunkAndMutationGuard() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("document.txt")
        let payload = Data("0123456789".utf8)
        try payload.write(to: sourceURL)
        let modifiedAt = try #require(
            sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let engine = try MacSyncFileTransferEngine(rootURL: root)
        let offered = try #require(
            try await engine.enqueueDiscoveredFile(
                MacSyncDiscoveredFile(
                    relativePath: "document.txt",
                    fileURL: sourceURL,
                    byteCount: UInt64(payload.count),
                    modifiedAt: modifiedAt,
                    sha256: MacSyncFileUtilities.sha256(of: sourceURL)
                )
            )
        )

        #expect(try await engine.nextOutgoingChunk(
            transferID: offered.transferID,
            offset: 3,
            maximumBytes: 4
        ) == Data("3456".utf8))

        try Data("changed-size".utf8).write(to: sourceURL)
        await #expect(throws: MacFileSyncError.self) {
            try await engine.nextOutgoingChunk(
                transferID: offered.transferID,
                offset: 0,
                maximumBytes: 4
            )
        }
    }

    @Test("Directory bookmark persists and restores the selected folder") @MainActor
    func directoryBookmarkPersistence() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = InMemorySyncDirectoryPreferences()
        let store = MacFileSyncStore(
            preferences: preferences,
            directoryChooser: NilSyncDirectoryChooser(),
            watcherPollingInterval: 60,
            watcherStableInterval: 60
        )

        try await store.selectDirectory(root)
        #expect(store.directoryURL == root.standardizedFileURL)
        let bookmark = try #require(preferences.bookmark)
        #expect(try MacSyncDirectoryBookmark.resolve(bookmark).url == root.standardizedFileURL)

        store.setEnabled(false)
        #expect(preferences.enabled == false)
        await store.clearDirectory()
        #expect(preferences.bookmark == nil)
        store.shutdown()
    }

    @Test("Module shutdown preserves directory and explicit sync preference for restart") @MainActor
    func moduleShutdownPreservesUserSyncConfiguration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = InMemorySyncDirectoryPreferences(enabled: true)
        let store = MacFileSyncStore(
            preferences: preferences,
            directoryChooser: NilSyncDirectoryChooser(),
            watcherPollingInterval: 60,
            watcherStableInterval: 60
        )

        try await store.selectDirectory(root)
        let bookmark = try #require(preferences.bookmark)
        store.shutdown()

        #expect(store.isEnabled)
        #expect(store.directoryURL == root.standardizedFileURL)
        #expect(preferences.enabled)
        #expect(preferences.bookmark == bookmark)

        store.start()
        await Task.yield()
        #expect(store.isEnabled)
        #expect(preferences.enabled)
        #expect(preferences.bookmark != nil)
        store.shutdown()
    }

    @Test("Core chunks are verified before write, duplicate-safe, and finish with receiverStored") @MainActor
    func coreProtocolStoreBoundary() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacFileSyncStore(
            preferences: InMemorySyncDirectoryPreferences(),
            directoryChooser: NilSyncDirectoryChooser(),
            watcherPollingInterval: 60,
            watcherStableInterval: 60
        )
        try await store.selectDirectory(root)

        let payload = Data("hello over bluetooth".utf8)
        let metadata = SyncItemMetadata(
            direction: .phoneToMac,
            mediaType: .file,
            relativePath: "Inbox/hello.txt",
            byteSize: UInt64(payload.count),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sha256: SyncSHA256.hexDigest(payload)
        )
        #expect(try await store.prepareIncoming(metadata) == 0)

        let firstData = payload.prefix(5)
        let invalidChunk = SyncChunk(
            transferID: metadata.transferID,
            offset: 0,
            data: firstData,
            checksumSHA256: String(repeating: "0", count: 64),
            isFinal: false
        )
        await #expect(throws: SyncProtocolError.self) {
            try await store.writeIncoming(invalidChunk)
        }

        let firstChunk = SyncChunk(
            transferID: metadata.transferID,
            offset: 0,
            data: firstData,
            isFinal: false
        )
        #expect(try await store.writeIncoming(firstChunk) == 5)
        #expect(try await store.writeIncoming(firstChunk) == 5)

        let finalChunk = SyncChunk(
            transferID: metadata.transferID,
            offset: 5,
            data: payload.dropFirst(5),
            isFinal: true
        )
        #expect(try await store.writeIncoming(finalChunk) == UInt64(payload.count))

        let response = try await store.completeIncoming(
            SyncCompletion(
                transferID: metadata.transferID,
                totalBytes: UInt64(payload.count),
                sha256: metadata.sha256,
                stage: .senderFinished
            )
        )
        #expect(response.stage == .receiverStored)
        #expect(response.storedRelativePath == "Inbox/hello.txt")
        #expect(try Data(contentsOf: root.appendingPathComponent("Inbox/hello.txt")) == payload)

        await store.clearDirectory()
        store.shutdown()
    }

    @Test("Mac delta router publishes a stable index, serves blocks, and suppresses duplicates") @MainActor
    func syncthingDeltaOutgoingPublication() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacFileSyncStore(
            preferences: InMemorySyncDirectoryPreferences(),
            directoryChooser: NilSyncDirectoryChooser(),
            watcherPollingInterval: 60,
            watcherStableInterval: 60
        )
        try await store.selectDirectory(root)

        let payload = Data((0..<(SyncthingBlockSizePolicy.minimumBlockSize + 29)).map {
            UInt8(truncatingIfNeeded: $0 * 19)
        })
        let sourceURL = root.appendingPathComponent("Outgoing.bin")
        try payload.write(to: sourceURL)
        let modifiedAt = try #require(
            sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let descriptor = try #require(try await store.enqueueOutgoingDiscoveredFile(
            MacSyncDiscoveredFile(
                relativePath: "Outgoing.bin",
                fileURL: sourceURL,
                byteCount: UInt64(payload.count),
                modifiedAt: modifiedAt,
                sha256: SyncSHA256.hexDigest(payload)
            )
        ))
        let adapter = MacSyncthingDeltaAdapter(store: store, localDeviceID: UUID())
        let router = MacSyncthingDeltaRouter(adapter: adapter)
        let offer = SyncOffer(
            metadata: descriptor.syncMetadata(direction: .macToPhone),
            capabilities: SyncTransportCapabilities(
                maximumFrameSize: 1_024 * 1_024,
                preferredChunkSize: SyncProtocolLimits.maximumChunkSize
            )
        )

        let publication = try #require(try await router.publish(offer))
        guard case let .indexUpdate(update) = publication,
              let index = update.entries.first else {
            Issue.record("Expected a delta index update")
            return
        }
        #expect(update.folderID == SyncthingTransferFolderID.make(
            transferID: descriptor.transferID
        ))
        #expect(index.relativePath == descriptor.relativePath)
        #expect(index.wholeFileSHA256 == descriptor.sha256)
        #expect(index.blocks.count == 2)
        #expect(try await router.publish(offer) == nil)

        let firstBlock = SyncthingBlockRequest(block: index.blocks[0])
        let request = SyncthingPeerBlockRequest(
            folderID: update.folderID,
            relativePath: index.relativePath,
            block: firstBlock
        )
        let responses = try await router.receive(.blockRequest(request))
        guard case let .blockResponse(response) = responses.first else {
            Issue.record("Expected an exact block response")
            return
        }
        #expect(response.data == payload.prefix(firstBlock.size))
        #expect(response.block == firstBlock)

        _ = try await router.receive(.ack(SyncthingPeerAcknowledgement(
            acknowledgedMessageID: update.messageID,
            status: .rejected,
            detail: "temporary peer rejection"
        )))
        #expect(await store.outgoingDescriptors().count == 1)
        #expect(store.queue.first?.phase == .failed)

        let retryPublication = try #require(try await router.publish(offer))
        guard case let .indexUpdate(retryUpdate) = retryPublication else {
            Issue.record("Expected a fresh publication after an explicit retry")
            return
        }
        _ = try await router.receive(.ack(SyncthingPeerAcknowledgement(
            acknowledgedMessageID: retryUpdate.messageID,
            status: .accepted
        )))
        #expect(await store.outgoingDescriptors().isEmpty)
        #expect(store.recentResults.first?.direction == .toPhone)
        #expect(store.recentResults.first?.succeeded == true)
        await store.clearDirectory()
        store.shutdown()
    }

    @Test("Mac delta receiver reuses the matching local block and atomically replaces the file") @MainActor
    func syncthingDeltaIncomingReuseAndCommit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacFileSyncStore(
            preferences: InMemorySyncDirectoryPreferences(),
            directoryChooser: NilSyncDirectoryChooser(),
            watcherPollingInterval: 60,
            watcherStableInterval: 60
        )
        try await store.selectDirectory(root)

        let blockSize = SyncthingBlockSizePolicy.minimumBlockSize
        let remoteData = Data((0..<(blockSize * 2 + 31)).map { index in
            UInt8(truncatingIfNeeded: index < blockSize ? index * 7 : index * 23 + 5)
        })
        let localData = Data((0..<remoteData.count).map { index in
            index < blockSize ? remoteData[index] : UInt8(truncatingIfNeeded: index * 3 + 91)
        })
        let destinationURL = root.appendingPathComponent("Shared.bin")
        try localData.write(to: destinationURL)
        let localModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: localModifiedAt],
            ofItemAtPath: destinationURL.path
        )
        let actualLocalModifiedAt = try #require(
            destinationURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        )

        let macDeviceID = UUID(uuidString: "0B19D452-B3DF-490B-95DA-E09AE8F1EE03")!
        let macIndexDeviceID = macDeviceID.uuidString.lowercased()
        let localCounter = UInt64(actualLocalModifiedAt.timeIntervalSince1970 * 1_000)
        let remoteIndex = try SyncthingPlanner.fileIndex(
            for: remoteData,
            relativePath: "Shared.bin",
            modifiedAt: actualLocalModifiedAt.addingTimeInterval(10),
            deviceID: "phone",
            version: SyncthingVersionVector(counters: [
                macIndexDeviceID: localCounter + 1,
                "phone": 1
            ]),
            sequence: localCounter + 1
        )
        let folderID = SyncthingTransferFolderID.make(transferID: UUID())
        let sourceMessageID = UUID()
        let adapter = MacSyncthingDeltaAdapter(store: store, localDeviceID: macDeviceID)
        let router = MacSyncthingDeltaRouter(adapter: adapter)

        let requests = try await router.receive(.indexUpdate(SyncthingPeerIndexUpdate(
            messageID: sourceMessageID,
            folderID: folderID,
            sequence: remoteIndex.sequence,
            entries: [remoteIndex]
        )))
        let blockRequests = requests.compactMap { message -> SyncthingPeerBlockRequest? in
            guard case let .blockRequest(request) = message else { return nil }
            return request
        }
        #expect(blockRequests.count == 2)
        #expect(!blockRequests.contains { $0.block.offset == 0 })

        var terminalMessages: [SyncthingPeerMessage] = []
        for request in blockRequests {
            let start = Int(request.block.offset)
            let data = remoteData.subdata(in: start..<(start + request.block.size))
            terminalMessages = try await router.receive(.blockResponse(
                SyncthingPeerBlockResponse(
                    requestID: request.requestID,
                    folderID: request.folderID,
                    relativePath: request.relativePath,
                    block: request.block,
                    data: data
                )
            ))
        }

        guard case let .ack(acknowledgement) = terminalMessages.first else {
            Issue.record("Expected an acknowledgement after the atomic commit")
            return
        }
        #expect(acknowledgement.acknowledgedMessageID == sourceMessageID)
        #expect(try Data(contentsOf: destinationURL) == remoteData)
        #expect(store.queue.isEmpty)
        #expect(store.recentResults.first?.direction == .toMac)
        #expect(store.recentResults.first?.succeeded == true)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Shared (1).bin").path
        ))

        // Simulate a process restart with both a fresh coordinator and adapter.
        // Identical whole-file content must ACK immediately even after version
        // history is lost, without another block or conflict copy.
        let reconnectAdapter = MacSyncthingDeltaAdapter(
            store: store,
            localDeviceID: macDeviceID
        )
        let reconnectRouter = MacSyncthingDeltaRouter(adapter: reconnectAdapter)
        let reconnectMessageID = UUID()
        let reconnectResponses = try await reconnectRouter.receive(.index(
            SyncthingPeerIndex(
                messageID: reconnectMessageID,
                folderID: folderID,
                sequence: remoteIndex.sequence,
                entries: [remoteIndex]
            )
        ))
        #expect(reconnectResponses.count == 1)
        guard case let .ack(reconnectAcknowledgement) = reconnectResponses.first else {
            Issue.record("Identical content must produce a zero-block acknowledgement")
            return
        }
        #expect(reconnectAcknowledgement.acknowledgedMessageID == reconnectMessageID)
        #expect(store.recentResults.count == 1)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Shared (1).bin").path
        ))
        await store.clearDirectory()
        store.shutdown()
    }

    @Test("A dominating delta tombstone removes the Mac file and updates recent results") @MainActor
    func syncthingDeltaIncomingDeletion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacFileSyncStore(
            preferences: InMemorySyncDirectoryPreferences(),
            directoryChooser: NilSyncDirectoryChooser(),
            watcherPollingInterval: 60,
            watcherStableInterval: 60
        )
        try await store.selectDirectory(root)

        let path = "Delete-me.txt"
        let destinationURL = root.appendingPathComponent(path)
        try Data("obsolete".utf8).write(to: destinationURL)
        let modifiedAt = try #require(
            destinationURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        )
        let macDeviceID = UUID()
        let macIndexDeviceID = macDeviceID.uuidString.lowercased()
        let localCounter = UInt64(modifiedAt.timeIntervalSince1970 * 1_000)
        let tombstone = try SyncthingPlanner.tombstone(
            relativePath: path,
            deletedAt: modifiedAt.addingTimeInterval(1),
            deviceID: "phone",
            version: SyncthingVersionVector(counters: [
                macIndexDeviceID: localCounter + 1,
                "phone": 1
            ]),
            sequence: localCounter + 1
        )
        let messageID = UUID()
        let folderID = SyncthingTransferFolderID.make(transferID: UUID())
        let router = MacSyncthingDeltaRouter(adapter: MacSyncthingDeltaAdapter(
            store: store,
            localDeviceID: macDeviceID
        ))
        let responses = try await router.receive(.indexUpdate(SyncthingPeerIndexUpdate(
            messageID: messageID,
            folderID: folderID,
            sequence: tombstone.sequence,
            entries: [tombstone]
        )))

        guard case let .ack(acknowledgement) = responses.first else {
            Issue.record("A committed tombstone must be acknowledged")
            return
        }
        #expect(acknowledgement.acknowledgedMessageID == messageID)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
        #expect(store.queue.isEmpty)
        #expect(store.recentResults.first?.direction == .toMac)
        #expect(store.recentResults.first?.succeeded == true)
        let repeatedMessageID = UUID()
        let repeated = try await router.receive(.index(SyncthingPeerIndex(
            messageID: repeatedMessageID,
            folderID: folderID,
            sequence: tombstone.sequence,
            entries: [tombstone]
        )))
        #expect(repeated.count == 1)
        #expect(store.recentResults.count == 1)
        await store.clearDirectory()
        store.shutdown()
    }

    @Test("Core metadata adapter preserves identity and classifies media")
    func coreMetadataAdapter() throws {
        let descriptor = MacSyncFileDescriptor(
            relativePath: "Trips/IMG_0001.HEIC",
            byteCount: 42,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sha256: String(repeating: "a", count: 64)
        )
        let metadata = descriptor.syncMetadata(direction: .macToPhone)

        #expect(metadata.transferID == descriptor.transferID)
        #expect(metadata.mediaType == .image)
        #expect(metadata.direction == .macToPhone)
        #expect(try MacSyncFileDescriptor(metadata: metadata) == descriptor)
        #expect(MacSyncMediaClassifier.mediaType(for: "movie.mov") == .video)
        #expect(MacSyncMediaClassifier.mediaType(for: "notes.pdf") == .file)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPet-MacSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func digest(for data: Data, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("digest-\(UUID().uuidString).tmp")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try MacSyncFileUtilities.sha256(of: url)
    }
}
