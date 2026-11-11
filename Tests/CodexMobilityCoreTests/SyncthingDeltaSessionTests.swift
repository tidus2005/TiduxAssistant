import CodexMobilityCore
import Foundation
import Testing

@Suite("Syncthing delta session")
struct SyncthingDeltaSessionTests {
    private let blockSize = SyncthingBlockSizePolicy.minimumBlockSize

    @Test
    func requestsOnlyMissingBlocksAndProducesVerifiedAtomicCommit() throws {
        let data = makeData(fullBlocks: 2, tailBytes: 37)
        let index = try makeIndex(
            data: data,
            version: SyncthingVersionVector(counters: ["phone": 1])
        )
        let first = blockData(index.blocks[0], in: data)
        let last = blockData(index.blocks[2], in: data)
        var session = try SyncthingDeltaSession(
            remoteIndex: index,
            locallyAvailableBlocks: [first, last]
        )

        #expect(session.reusedBlockCount == 2)
        #expect(session.assembledBlockCount == 2)
        #expect(session.pendingRequests == [SyncthingBlockRequest(block: index.blocks[1])])
        #expect(!session.isComplete)

        let request = try #require(session.pendingRequests.first)
        let response = SyncthingPeerBlockResponse(
            requestID: UUID(),
            folderID: "default",
            relativePath: index.relativePath,
            block: request,
            data: blockData(index.blocks[1], in: data)
        )
        let commit = try #require(try session.receive(response))

        #expect(commit.relativePath == index.relativePath)
        #expect(commit.data == data)
        #expect(commit.remoteIndex == index)
        #expect(commit.verifiedSHA256 == index.wholeFileSHA256)
        #expect(session.pendingRequests.isEmpty)
        #expect(session.isComplete)
        requireSendable(session)
        requireSendable(commit)
    }

    @Test
    func rejectsOutOfBoundsUnexpectedAndMismatchedBlocks() throws {
        let data = makeData(fullBlocks: 2)
        let index = try makeIndex(data: data)
        var session = try SyncthingDeltaSession(remoteIndex: index)
        let validHash = SyncSHA256.hexDigest(Data([0]))

        let outOfBounds = try SyncthingBlockRequest(
            offset: index.size,
            size: 1,
            sha256: validHash
        )
        #expect(throws: SyncthingDeltaSessionError.blockOutOfBounds(
            offset: index.size,
            size: 1,
            fileSize: index.size
        )) {
            try session.receive(block: outOfBounds, data: Data([0]))
        }

        let unexpected = try SyncthingBlockRequest(
            offset: 1,
            size: 1,
            sha256: validHash
        )
        #expect(throws: SyncthingDeltaSessionError.unexpectedBlock(offset: 1)) {
            try session.receive(block: unexpected, data: Data([0]))
        }

        let expected = SyncthingBlockRequest(block: index.blocks[0])
        let mismatched = try SyncthingBlockRequest(
            offset: expected.offset,
            size: expected.size - 1,
            sha256: expected.sha256
        )
        #expect(throws: SyncthingDeltaSessionError.blockMetadataMismatch(
            expected: expected,
            actual: mismatched
        )) {
            try session.receive(block: mismatched, data: Data())
        }

        #expect(throws: SyncthingDeltaSessionError.blockSizeMismatch(
            offset: expected.offset,
            expected: expected.size,
            actual: expected.size - 1
        )) {
            try session.receive(
                block: expected,
                data: blockData(index.blocks[0], in: data).dropLast()
            )
        }
    }

    @Test
    func rejectsWrongHashDuplicateAndWrongResponsePath() throws {
        let data = makeData(fullBlocks: 2)
        let index = try makeIndex(data: data)
        let firstRequest = SyncthingBlockRequest(block: index.blocks[0])
        let firstData = blockData(index.blocks[0], in: data)

        var corrupted = firstData
        corrupted[corrupted.startIndex] ^= 0xff
        var hashSession = try SyncthingDeltaSession(remoteIndex: index)
        let corruptHash = SyncSHA256.hexDigest(corrupted)
        #expect(throws: SyncthingDeltaSessionError.blockHashMismatch(
            offset: firstRequest.offset,
            expected: firstRequest.sha256,
            actual: corruptHash
        )) {
            try hashSession.receive(block: firstRequest, data: corrupted)
        }

        var duplicateSession = try SyncthingDeltaSession(remoteIndex: index)
        #expect(try duplicateSession.receive(block: firstRequest, data: firstData) == nil)
        #expect(throws: SyncthingDeltaSessionError.duplicateBlock(offset: firstRequest.offset)) {
            try duplicateSession.receive(block: firstRequest, data: firstData)
        }

        var pathSession = try SyncthingDeltaSession(remoteIndex: index)
        let wrongPath = SyncthingPeerBlockResponse(
            requestID: UUID(),
            folderID: "default",
            relativePath: "other.bin",
            block: firstRequest,
            data: firstData
        )
        #expect(throws: SyncthingDeltaSessionError.unexpectedRelativePath(
            expected: index.relativePath,
            actual: "other.bin"
        )) {
            try pathSession.receive(wrongPath)
        }
    }

    @Test
    func verifiesWholeFileHashBeforeExposingCommit() throws {
        let data = makeData(fullBlocks: 1, tailBytes: 11)
        let validIndex = try makeIndex(data: data)
        let impossibleWholeHash = String(repeating: "0", count: SyncSHA256.hexDigestLength)
        let inconsistentIndex = try SyncthingFileIndex(
            relativePath: validIndex.relativePath,
            size: validIndex.size,
            modifiedAt: validIndex.modifiedAt,
            wholeFileSHA256: impossibleWholeHash,
            blocks: validIndex.blocks,
            deviceID: validIndex.deviceID,
            version: validIndex.version,
            sequence: validIndex.sequence
        )
        var session = try SyncthingDeltaSession(remoteIndex: inconsistentIndex)

        for block in inconsistentIndex.blocks.dropLast() {
            #expect(try session.receive(
                block: SyncthingBlockRequest(block: block),
                data: blockData(block, in: data)
            ) == nil)
        }
        let finalBlock = try #require(inconsistentIndex.blocks.last)
        #expect(throws: SyncthingDeltaSessionError.wholeFileHashMismatch(
            expected: impossibleWholeHash,
            actual: SyncSHA256.hexDigest(data)
        )) {
            try session.receive(
                block: SyncthingBlockRequest(block: finalBlock),
                data: blockData(finalBlock, in: data)
            )
        }
        #expect(session.commit == nil)
    }

    @Test
    func emptyFileIsVerifiedWithoutBlockRequests() throws {
        let index = try makeIndex(data: Data())
        let session = try SyncthingDeltaSession(remoteIndex: index)

        #expect(session.pendingRequests.isEmpty)
        #expect(session.isComplete)
        #expect(session.commit?.data == Data())
        #expect(session.commit?.verifiedSHA256 == SyncSHA256.hexDigest(Data()))
    }

    @Test
    func identicalContentNeedsNoTransferWhenVectorHistoryWasLost() throws {
        let data = Data("same bytes after an app restart".utf8)
        let local = try makeIndex(
            data: data,
            deviceID: "mac",
            version: SyncthingVersionVector(counters: ["mac": 7])
        )
        let remote = try makeIndex(
            data: data,
            deviceID: "phone",
            version: SyncthingVersionVector(counters: ["phone": 11])
        )

        let decision = try SyncthingDeltaReconciler.decide(
            remoteIndex: remote,
            localIndex: local
        )

        #expect(decision.action == .keepLocal)
        #expect(decision.reason == .identicalContent)
        #expect(decision.relation == .concurrent)
    }

    @Test
    func equalVersionWithDifferentBytesPreservesTheRemoteAsAConflict() throws {
        let timestamp = Date(timeIntervalSince1970: 1_768_000_000)
        let version = SyncthingVersionVector(counters: ["shared-device": 9])
        let local = try makeIndex(
            data: Data("local bytes".utf8),
            modifiedAt: timestamp,
            deviceID: "shared-device",
            version: version
        )
        let remote = try makeIndex(
            data: Data("remote bytes".utf8),
            modifiedAt: timestamp,
            deviceID: "shared-device",
            version: version
        )

        let decision = try SyncthingDeltaReconciler.decide(
            remoteIndex: remote,
            localIndex: local
        )
        let expectedPath = try SyncthingPlanner.conflictRelativePath(
            for: remote.relativePath,
            modifiedAt: timestamp,
            deviceID: remote.deviceID
        )

        #expect(decision.action == .applyRemote(relativePath: expectedPath))
        #expect(decision.reason == .equalVersionContentMismatch)
        #expect(decision.relation == .equal)
    }

    @Test
    func inMemorySessionRejectsFilesThatRequireFileBackedStaging() throws {
        let oversized = SyncthingDeltaSession.maximumInMemoryFileSize + 1
        var blocks: [SyncthingBlockInfo] = []
        var offset: UInt64 = 0
        while offset < oversized {
            let remaining = oversized - offset
            let blockSize = Int(min(
                remaining,
                UInt64(SyncthingBlockSizePolicy.maximumBlockSize)
            ))
            blocks.append(try SyncthingBlockInfo(
                offset: offset,
                size: blockSize,
                sha256: String(repeating: "0", count: SyncSHA256.hexDigestLength)
            ))
            offset += UInt64(blockSize)
        }
        let index = try SyncthingFileIndex(
            relativePath: "oversized.bin",
            size: oversized,
            modifiedAt: .now,
            wholeFileSHA256: String(repeating: "0", count: SyncSHA256.hexDigestLength),
            blocks: blocks,
            deviceID: "phone",
            version: SyncthingVersionVector(counters: ["phone": 1]),
            sequence: 1
        )

        #expect(throws: SyncthingDeltaSessionError.fileTooLargeForMemory(oversized)) {
            try SyncthingDeltaSession(remoteIndex: index)
        }
    }

    @Test
    func tombstonesAndConcurrentVersionsUseDataPreservingDecisions() throws {
        let timestamp = Date(timeIntervalSince1970: 1_768_000_000)
        let localLive = try makeIndex(
            data: Data("local".utf8),
            modifiedAt: timestamp,
            deviceID: "mac",
            version: SyncthingVersionVector(counters: ["mac": 1])
        )
        let dominantTombstone = try SyncthingPlanner.tombstone(
            relativePath: localLive.relativePath,
            deletedAt: timestamp.addingTimeInterval(1),
            deviceID: "mac",
            version: SyncthingVersionVector(counters: ["mac": 2]),
            sequence: 2
        )
        let deletion = try SyncthingDeltaSession.prepare(
            remoteIndex: dominantTombstone,
            localIndex: localLive
        )
        if case let .deletion(commit, decision) = deletion {
            #expect(commit.relativePath == localLive.relativePath)
            #expect(commit.tombstone == dominantTombstone)
            #expect(decision.reason == .remoteVersionDominates)
        } else {
            #expect(Bool(false), "A dominating tombstone must prepare an atomic deletion")
        }

        let concurrentRemote = try makeIndex(
            data: Data("remote".utf8),
            modifiedAt: timestamp,
            deviceID: "phone",
            version: SyncthingVersionVector(counters: ["phone": 1])
        )
        let conflict = try SyncthingDeltaReconciler.decide(
            remoteIndex: concurrentRemote,
            localIndex: localLive
        )
        let expectedConflictPath = try SyncthingPlanner.conflictRelativePath(
            for: concurrentRemote.relativePath,
            modifiedAt: concurrentRemote.modifiedAt,
            deviceID: concurrentRemote.deviceID
        )
        #expect(conflict.action == .applyRemote(relativePath: expectedConflictPath))
        #expect(conflict.reason == .concurrentContent)
        #expect(conflict.relation == .concurrent)

        let concurrentRemoteDeletion = try SyncthingPlanner.tombstone(
            relativePath: localLive.relativePath,
            deletedAt: timestamp,
            deviceID: "phone",
            version: SyncthingVersionVector(counters: ["phone": 1]),
            sequence: 3
        )
        let keepLive = try SyncthingDeltaReconciler.decide(
            remoteIndex: concurrentRemoteDeletion,
            localIndex: localLive
        )
        #expect(keepLive.action == .keepLocal)
        #expect(keepLive.reason == .concurrentRemoteDeletion)

        let localDeletion = try SyncthingPlanner.tombstone(
            relativePath: localLive.relativePath,
            deletedAt: timestamp,
            deviceID: "mac",
            version: SyncthingVersionVector(counters: ["mac": 1]),
            sequence: 4
        )
        let resurrect = try SyncthingDeltaReconciler.decide(
            remoteIndex: concurrentRemote,
            localIndex: localDeletion
        )
        #expect(resurrect.action == .applyRemote(relativePath: concurrentRemote.relativePath))
        #expect(resurrect.reason == .concurrentLocalDeletion)
    }

    private func makeData(fullBlocks: Int, tailBytes: Int = 0) -> Data {
        let count = blockSize * fullBlocks + tailBytes
        return Data((0..<count).map { index in
            UInt8(truncatingIfNeeded: (index / blockSize) * 71 + index * 17)
        })
    }

    private func makeIndex(
        data: Data,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        deviceID: String = "phone",
        version: SyncthingVersionVector = SyncthingVersionVector(counters: ["phone": 1])
    ) throws -> SyncthingFileIndex {
        try SyncthingPlanner.fileIndex(
            for: data,
            relativePath: "Sync/archive.bin",
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            version: version,
            sequence: 1
        )
    }

    private func blockData(_ block: SyncthingBlockInfo, in data: Data) -> Data {
        let start = Int(block.offset)
        return data.subdata(in: start..<(start + block.size))
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
