import CodexMobilityCore
import Foundation
import Testing

@Suite("Syncthing peer delta coordinator")
struct SyncthingPeerDeltaCoordinatorTests {
    private let blockSize = SyncthingBlockSizePolicy.minimumBlockSize

    @Test("Two peers exchange block messages, commits, and acknowledgements in both directions")
    func twoPeerRoundTripInBothDirections() async throws {
        let aData = makeData(count: blockSize + 91, seed: 17)
        let bData = makeData(count: blockSize * 2 + 37, seed: 83)
        let aIndex = try makeIndex(
            data: aData,
            path: "From A/report.pdf",
            deviceID: "peer-a"
        )
        let bIndex = try makeIndex(
            data: bData,
            path: "From B/photo.heic",
            deviceID: "peer-b"
        )

        let aAdapter = DeltaTestAdapter(sources: [
            "a-to-b": DeltaTestSource(index: aIndex, data: aData)
        ])
        let bAdapter = DeltaTestAdapter(sources: [
            "b-to-a": DeltaTestSource(index: bIndex, data: bData)
        ])
        let peerA = SyncthingPeerDeltaCoordinator(adapter: aAdapter)
        let peerB = SyncthingPeerDeltaCoordinator(adapter: bAdapter)

        let aMessageID = UUID()
        let aIndexMessage = try await peerA.publish(
            folderID: "a-to-b",
            index: aIndex,
            messageID: aMessageID
        )
        let aAcknowledgement = try await exchange(
            indexMessage: aIndexMessage,
            sender: peerA,
            receiver: peerB
        )
        #expect(aAcknowledgement.acknowledgedMessageID == aMessageID)
        #expect(aAcknowledgement.status == .accepted)
        #expect(await bAdapter.committedFileData(folderID: "a-to-b") == aData)
        #expect(await aAdapter.finishedAcknowledgement(folderID: "a-to-b") == aAcknowledgement)

        let bMessageID = UUID()
        let bIndexMessage = try await peerB.publish(
            folderID: "b-to-a",
            index: bIndex,
            kind: .update,
            messageID: bMessageID
        )
        let bAcknowledgement = try await exchange(
            indexMessage: bIndexMessage,
            sender: peerB,
            receiver: peerA
        )
        #expect(bAcknowledgement.acknowledgedMessageID == bMessageID)
        #expect(bAcknowledgement.status == .accepted)
        #expect(await aAdapter.committedFileData(folderID: "b-to-a") == bData)
        #expect(await bAdapter.finishedAcknowledgement(folderID: "b-to-a") == bAcknowledgement)
    }

    @Test("Receiver reuses matching local blocks and asks for only the missing block")
    func requestsOnlyMissingBlock() async throws {
        let data = makeData(count: blockSize * 2 + 53, seed: 29)
        let index = try makeIndex(
            data: data,
            path: "Archive/video.mov",
            deviceID: "mac"
        )
        let first = blockData(index.blocks[0], in: data)
        let last = blockData(index.blocks[2], in: data)
        let senderAdapter = DeltaTestAdapter(sources: [
            "shared": DeltaTestSource(index: index, data: data)
        ])
        let receiverAdapter = DeltaTestAdapter(
            reusableBlocks: ["shared": [first, last]]
        )
        let sender = SyncthingPeerDeltaCoordinator(adapter: senderAdapter)
        let receiver = SyncthingPeerDeltaCoordinator(adapter: receiverAdapter)
        let messageID = UUID()
        let indexMessage = try await sender.publish(
            folderID: "shared",
            index: index,
            messageID: messageID
        )

        let requests = try await receiver.receive(indexMessage)
        #expect(requests.count == 1)
        let request = try blockRequest(from: requests[0])
        #expect(request.block == SyncthingBlockRequest(block: index.blocks[1]))

        let responses = try await sender.receive(.blockRequest(request))
        let response = try #require(responses.first)
        let acknowledgementMessages = try await receiver.receive(response)
        let acknowledgement = try acknowledgement(from: try #require(acknowledgementMessages.first))
        #expect(acknowledgement.acknowledgedMessageID == messageID)
        #expect(await receiverAdapter.committedFileData(folderID: "shared") == data)
    }

    @Test("Wrong request IDs and paths are rejected without consuming the valid request")
    func rejectsWrongRequestIDAndPath() async throws {
        let data = makeData(count: 1_023, seed: 41)
        let index = try makeIndex(
            data: data,
            path: "Inbox/note.txt",
            deviceID: "phone"
        )
        let adapter = DeltaTestAdapter()
        let receiver = SyncthingPeerDeltaCoordinator(adapter: adapter)
        let sourceMessageID = UUID()
        let requests = try await receiver.receive(.index(SyncthingPeerIndex(
            messageID: sourceMessageID,
            folderID: "inbox",
            sequence: index.sequence,
            entries: [index]
        )))
        let request = try blockRequest(from: try #require(requests.first))

        let wrongRequestID = UUID()
        let wrongIDResponse = SyncthingPeerBlockResponse(
            requestID: wrongRequestID,
            folderID: request.folderID,
            relativePath: request.relativePath,
            block: request.block,
            data: data
        )
        do {
            _ = try await receiver.receive(.blockResponse(wrongIDResponse))
            Issue.record("A response with an unknown request ID must be rejected")
        } catch let error as SyncthingPeerDeltaCoordinatorError {
            #expect(error == .unexpectedResponseRequestID(wrongRequestID))
        }

        let wrongPathResponse = SyncthingPeerBlockResponse(
            requestID: request.requestID,
            folderID: request.folderID,
            relativePath: "Inbox/other.txt",
            block: request.block,
            data: data
        )
        do {
            _ = try await receiver.receive(.blockResponse(wrongPathResponse))
            Issue.record("A response for a different path must be rejected")
        } catch let error as SyncthingPeerDeltaCoordinatorError {
            #expect(error == .responsePathMismatch(
                expected: index.relativePath,
                actual: "Inbox/other.txt"
            ))
        }

        let validResponse = SyncthingPeerBlockResponse(
            requestID: request.requestID,
            folderID: request.folderID,
            relativePath: request.relativePath,
            block: request.block,
            data: data
        )
        let acknowledgementMessages = try await receiver.receive(.blockResponse(validResponse))
        let acknowledgement = try acknowledgement(from: try #require(acknowledgementMessages.first))
        #expect(acknowledgement.acknowledgedMessageID == sourceMessageID)
        #expect(await adapter.committedFileData(folderID: "inbox") == data)
    }

    @Test("Sender serves only blocks and paths from its published index")
    func senderValidatesPublishedIndex() async throws {
        let data = makeData(count: blockSize + 7, seed: 61)
        let index = try makeIndex(
            data: data,
            path: "Published/file.bin",
            deviceID: "mac"
        )
        let adapter = DeltaTestAdapter(sources: [
            "published": DeltaTestSource(index: index, data: data)
        ])
        let sender = SyncthingPeerDeltaCoordinator(adapter: adapter)
        _ = try await sender.publish(folderID: "published", index: index)
        let block = SyncthingBlockRequest(block: index.blocks[0])

        let wrongPath = SyncthingPeerBlockRequest(
            folderID: "published",
            relativePath: "Published/other.bin",
            block: block
        )
        do {
            _ = try await sender.receive(.blockRequest(wrongPath))
            Issue.record("A block request for an unpublished path must be rejected")
        } catch let error as SyncthingPeerDeltaCoordinatorError {
            #expect(error == .requestPathMismatch(
                expected: index.relativePath,
                actual: "Published/other.bin"
            ))
        }

        let unpublishedBlock = try SyncthingBlockRequest(
            offset: block.offset,
            size: block.size,
            sha256: String(repeating: "f", count: SyncSHA256.hexDigestLength)
        )
        let wrongBlock = SyncthingPeerBlockRequest(
            folderID: "published",
            relativePath: index.relativePath,
            block: unpublishedBlock
        )
        do {
            _ = try await sender.receive(.blockRequest(wrongBlock))
            Issue.record("A block not present in the published index must be rejected")
        } catch let error as SyncthingPeerDeltaCoordinatorError {
            #expect(error == .requestedBlockWasNotPublished(unpublishedBlock))
        }
    }

    @Test("Oversized incoming files require an explicit file-backed fallback")
    func oversizedFileRequiresFallback() async throws {
        let index = try makeOversizedIndex()
        let coordinator = SyncthingPeerDeltaCoordinator(adapter: DeltaTestAdapter())
        let message = SyncthingPeerMessage.index(SyncthingPeerIndex(
            folderID: "large",
            sequence: index.sequence,
            entries: [index]
        ))

        do {
            _ = try await coordinator.receive(message)
            Issue.record("The in-memory coordinator must reject oversized files")
        } catch let error as SyncthingPeerDeltaCoordinatorError {
            #expect(error == .requiresFileBackedFallback(
                size: index.size,
                maximumInMemorySize: SyncthingDeltaSession.maximumInMemoryFileSize
            ))
        }
    }

    private func exchange<SenderAdapter, ReceiverAdapter>(
        indexMessage: SyncthingPeerMessage,
        sender: SyncthingPeerDeltaCoordinator<SenderAdapter>,
        receiver: SyncthingPeerDeltaCoordinator<ReceiverAdapter>
    ) async throws -> SyncthingPeerAcknowledgement
    where SenderAdapter: SyncthingPeerDeltaAdapter,
          ReceiverAdapter: SyncthingPeerDeltaAdapter {
        let requests = try await receiver.receive(indexMessage)
        var acknowledgement: SyncthingPeerAcknowledgement?
        for requestMessage in requests {
            let responses = try await sender.receive(requestMessage)
            #expect(responses.count == 1)
            for response in responses {
                let results = try await receiver.receive(response)
                for result in results {
                    acknowledgement = try self.acknowledgement(from: result)
                    _ = try await sender.receive(result)
                }
            }
        }
        return try #require(acknowledgement)
    }

    private func makeIndex(
        data: Data,
        path: String,
        deviceID: String
    ) throws -> SyncthingFileIndex {
        try SyncthingPlanner.fileIndex(
            for: data,
            relativePath: path,
            modifiedAt: Date(timeIntervalSince1970: 1_710_000_000),
            deviceID: deviceID,
            version: SyncthingVersionVector(counters: [deviceID: 1]),
            sequence: 1
        )
    }

    private func makeOversizedIndex() throws -> SyncthingFileIndex {
        let size = SyncthingDeltaSession.maximumInMemoryFileSize + 1
        let chunkSize = SyncthingBlockSizePolicy.maximumBlockSize
        let digest = String(repeating: "0", count: SyncSHA256.hexDigestLength)
        var blocks: [SyncthingBlockInfo] = []
        var offset: UInt64 = 0
        while offset < size {
            let remaining = size - offset
            let blockByteCount = Int(min(UInt64(chunkSize), remaining))
            blocks.append(try SyncthingBlockInfo(
                offset: offset,
                size: blockByteCount,
                sha256: digest
            ))
            offset += UInt64(blockByteCount)
        }
        return try SyncthingFileIndex(
            relativePath: "Large/archive.bin",
            size: size,
            modifiedAt: Date(timeIntervalSince1970: 1_710_000_000),
            wholeFileSHA256: digest,
            blocks: blocks,
            deviceID: "mac",
            version: SyncthingVersionVector(counters: ["mac": 1]),
            sequence: 1
        )
    }

    private func makeData(count: Int, seed: Int) -> Data {
        Data((0..<count).map { index in
            UInt8(truncatingIfNeeded: seed + index * 31 + (index / max(blockSize, 1)) * 47)
        })
    }

    private func blockData(_ block: SyncthingBlockInfo, in data: Data) -> Data {
        let start = Int(block.offset)
        return data.subdata(in: start..<(start + block.size))
    }

    private func blockRequest(
        from message: SyncthingPeerMessage
    ) throws -> SyncthingPeerBlockRequest {
        guard case let .blockRequest(request) = message else {
            throw DeltaTestError.unexpectedMessage
        }
        return request
    }

    private func acknowledgement(
        from message: SyncthingPeerMessage
    ) throws -> SyncthingPeerAcknowledgement {
        guard case let .ack(acknowledgement) = message else {
            throw DeltaTestError.unexpectedMessage
        }
        return acknowledgement
    }
}

private struct DeltaTestSource: Sendable {
    let index: SyncthingFileIndex
    let data: Data
}

private enum DeltaTestError: Error {
    case missingSource
    case sourceIndexMismatch
    case invalidBlockRange
    case unexpectedMessage
}

private actor DeltaTestAdapter: SyncthingPeerDeltaAdapter {
    private struct FinishedTransfer: Sendable {
        let folderID: String
        let acknowledgement: SyncthingPeerAcknowledgement
    }

    private let sources: [String: DeltaTestSource]
    private let localIndexes: [String: SyncthingFileIndex]
    private let reusableBlocks: [String: [Data]]
    private var commits: [(folderID: String, commit: SyncthingPeerDeltaCommit)] = []
    private var finishedTransfers: [FinishedTransfer] = []

    init(
        sources: [String: DeltaTestSource] = [:],
        localIndexes: [String: SyncthingFileIndex] = [:],
        reusableBlocks: [String: [Data]] = [:]
    ) {
        self.sources = sources
        self.localIndexes = localIndexes
        self.reusableBlocks = reusableBlocks
    }

    func localIndex(
        folderID: String,
        relativePath: String
    ) async throws -> SyncthingFileIndex? {
        localIndexes[folderID]
    }

    func reusableBlockData(
        folderID: String,
        remoteIndex: SyncthingFileIndex
    ) async throws -> [Data] {
        reusableBlocks[folderID, default: []]
    }

    func readBlock(
        folderID: String,
        index: SyncthingFileIndex,
        block: SyncthingBlockRequest
    ) async throws -> Data {
        guard let source = sources[folderID] else {
            throw DeltaTestError.missingSource
        }
        guard source.index == index else {
            throw DeltaTestError.sourceIndexMismatch
        }
        guard block.offset <= UInt64(Int.max) else {
            throw DeltaTestError.invalidBlockRange
        }
        let start = Int(block.offset)
        let (end, overflow) = start.addingReportingOverflow(block.size)
        guard !overflow, start >= 0, end <= source.data.count else {
            throw DeltaTestError.invalidBlockRange
        }
        return source.data.subdata(in: start..<end)
    }

    func commit(
        _ commit: SyncthingPeerDeltaCommit,
        folderID: String
    ) async throws {
        commits.append((folderID, commit))
    }

    func outgoingTransferDidFinish(
        folderID: String,
        index: SyncthingFileIndex,
        acknowledgement: SyncthingPeerAcknowledgement
    ) async throws {
        finishedTransfers.append(FinishedTransfer(
            folderID: folderID,
            acknowledgement: acknowledgement
        ))
    }

    func committedFileData(folderID: String) -> Data? {
        for item in commits.reversed() where item.folderID == folderID {
            if case let .file(commit) = item.commit {
                return commit.data
            }
        }
        return nil
    }

    func finishedAcknowledgement(
        folderID: String
    ) -> SyncthingPeerAcknowledgement? {
        finishedTransfers.last(where: { $0.folderID == folderID })?.acknowledgement
    }
}
