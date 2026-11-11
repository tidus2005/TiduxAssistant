import CodexMobilityCore
import Foundation
import Testing

@Suite("Bluetooth file sync core")
struct SyncCoreTests {
    private let transferID = UUID(uuidString: "AD95C81D-5980-4C5E-BB85-DB1A17B727B0")!

    @Test
    func allWireMessagesRoundTripIncludingBinaryChunksAndStoredCompletion() throws {
        let data = Data([0, 1, 2, 127, 128, 255])
        let metadata = makeMetadata(data: data)
        let capabilities = SyncTransportCapabilities(
            maximumFrameSize: 185,
            preferredChunkSize: 640,
            maximumWindowSize: 4
        )
        let parameters = SyncTransferParameters(maximumFrameSize: 185, chunkSize: 512, windowSize: 3)
        let messages: [SyncWireMessage] = [
            .requestOffers(SyncOfferRequest(
                requestID: transferID,
                requestedDirection: .macToPhone,
                knownTransferIDs: [transferID]
            )),
            .offer(SyncOffer(metadata: metadata, capabilities: capabilities)),
            .accept(SyncAcceptance(
                transferID: transferID,
                acceptedRelativePath: "Inbox/photo.jpg",
                resumeOffset: 2,
                parameters: parameters
            )),
            .resume(SyncResume(transferID: transferID, nextOffset: 2)),
            .chunk(SyncChunk(transferID: transferID, offset: 0, data: data, isFinal: true)),
            .ack(SyncAcknowledgement(transferID: transferID, nextExpectedOffset: UInt64(data.count))),
            .complete(SyncCompletion(
                transferID: transferID,
                totalBytes: UInt64(data.count),
                sha256: SyncSHA256.hexDigest(data),
                stage: .receiverStored,
                storedRelativePath: "Inbox/photo.jpg"
            )),
            .cancel(SyncCancellation(transferID: transferID, reason: "User cancelled")),
            .failure(SyncFailure(
                transferID: transferID,
                code: .checksumMismatch,
                message: "Digest mismatch",
                retryable: true
            ))
        ]

        let codec = SyncJSONCodec()
        for message in messages {
            #expect(try codec.decode(codec.encode(message)) == message)
        }

        if case let .chunk(chunk) = try codec.decode(codec.encode(messages[4])) {
            #expect(chunk.data == data)
            #expect(SyncSHA256.matches(chunk.data, expectedHexDigest: chunk.checksumSHA256))
        } else {
            Issue.record("Expected a chunk after round trip")
        }
    }

    @Test
    func metadataValidationCanonicalizesPathAndDigest() throws {
        let data = Data("hello".utf8)
        let metadata = SyncItemMetadata(
            transferID: transferID,
            direction: .phoneToMac,
            mediaType: .file,
            relativePath: "Trips//2026/./note.txt",
            byteSize: UInt64(data.count),
            modifiedAt: Date(timeIntervalSince1970: 1_725_555_555.123),
            sha256: SyncSHA256.hexDigest(data).uppercased()
        )

        let validated = try metadata.validated()
        #expect(validated.relativePath == "Trips/2026/note.txt")
        #expect(validated.sha256 == SyncSHA256.hexDigest(data))
    }

    @Test(arguments: [
        "/etc/passwd",
        "\\\\server\\share\\secret",
        "C:\\Users\\person\\secret",
        "C:/Users/person/secret",
        "../secret",
        "safe/../../secret"
    ])
    func unsafePathsAreRejected(path: String) {
        #expect(throws: (any Error).self) {
            try SyncRelativePath.normalize(path)
        }
    }

    @Test
    func nullControlEmptyAndOversizedPathsAreRejected() {
        #expect(throws: SyncPathError.nullByte) {
            try SyncRelativePath.normalize("folder/bad\0name")
        }
        #expect(throws: SyncPathError.controlCharacter) {
            try SyncRelativePath.normalize("folder/bad\nname")
        }
        #expect(throws: SyncPathError.emptyPath) {
            try SyncRelativePath.normalize("././")
        }
        #expect(throws: (any Error).self) {
            try SyncRelativePath.normalize(String(repeating: "a", count: 256))
        }
    }

    @Test
    func conflictPlannerPreservesDirectoryAndExtensionAndIsCaseInsensitiveByDefault() throws {
        let existing = [
            "Trips/Photo.JPG",
            "Trips/photo (2).jpg",
            "Trips/archive.tar.gz",
            "Trips/.gitignore"
        ]

        #expect(try SyncConflictPlanner.availableRelativePath(
            desired: "Trips/photo.jpg",
            existing: existing
        ) == "Trips/photo (3).jpg")
        #expect(try SyncConflictPlanner.availableRelativePath(
            desired: "Trips/archive.tar.gz",
            existing: existing
        ) == "Trips/archive.tar (2).gz")
        #expect(try SyncConflictPlanner.availableRelativePath(
            desired: "Trips/.gitignore",
            existing: existing
        ) == "Trips/.gitignore (2)")
    }

    @Test
    func sha256KnownVectorIncrementalAndFileStreamingAgree() throws {
        let first = Data("abc".utf8)
        #expect(SyncSHA256.hexDigest(first) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SyncSHA256.matches(first, expectedHexDigest: SyncSHA256.hexDigest(first).uppercased()))
        #expect(!SyncSHA256.matches(Data("abd".utf8), expectedHexDigest: SyncSHA256.hexDigest(first)))
        #expect(!SyncSHA256.constantTimeEqual("", String(repeating: "\0", count: 256)))

        var accumulator = SyncSHA256Hasher()
        accumulator.update(Data("a".utf8))
        accumulator.update(Data("bc".utf8))
        #expect(accumulator.finalize() == SyncSHA256.hexDigest(first))

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-mobility-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try first.write(to: temporaryURL, options: .atomic)
        #expect(try SyncSHA256.hexDigest(fileAt: temporaryURL, readChunkSize: 1) == SyncSHA256.hexDigest(first))
    }

    @Test
    func bleParametersAreDerivedFromBothEndpointsNegotiatedLimits() throws {
        let local = try SyncBLETransferTuning.capabilities(
            maximumWriteValueLength: 185,
            maximumUpdateValueLength: 244,
            framesPerChunk: 4,
            maximumWindowSize: 6
        )
        let remote = try SyncBLETransferTuning.capabilities(
            maximumWriteValueLength: 120,
            maximumUpdateValueLength: 160,
            framesPerChunk: 2,
            maximumWindowSize: 3
        )
        let parameters = try SyncBLETransferTuning.negotiate(local: local, remote: remote)

        #expect(local.maximumFrameSize == 185)
        #expect(local.preferredChunkSize == (185 - MobilityFrameHeader.encodedLength) * 4)
        #expect(parameters.maximumFrameSize == 120)
        #expect(parameters.chunkSize == remote.preferredChunkSize)
        #expect(parameters.windowSize == 3)
        #expect(throws: SyncProtocolError.frameSizeTooSmall(20)) {
            try SyncBLETransferTuning.capabilities(
                maximumWriteValueLength: 20,
                maximumUpdateValueLength: 20
            )
        }
    }

    @Test
    func senderWindowReceiverAcksAndVerifiedCompletionFormAFullTransfer() throws {
        let data = Data((0..<70).map { UInt8($0) })
        let metadata = makeMetadata(data: data)
        let parameters = SyncTransferParameters(maximumFrameSize: 185, chunkSize: 32, windowSize: 2)
        var sender = try SyncSendState(metadata: metadata, parameters: parameters)
        var receiver = try SyncReceiveState(metadata: metadata, parameters: parameters)

        let first = try sender.makeChunk(data.subdata(in: 0..<32))
        let second = try sender.makeChunk(data.subdata(in: 32..<64))
        #expect(!sender.isReadyToSend)
        #expect(throws: SyncProtocolError.windowFull) {
            try sender.makeChunk(data.subdata(in: 64..<70))
        }

        let firstProgress = try receiver.receive(first)
        #expect(firstProgress.shouldWrite)
        #expect(firstProgress.acknowledgement.nextExpectedOffset == 32)
        try sender.acknowledge(firstProgress.acknowledgement)

        let duplicate = try receiver.receive(first)
        #expect(duplicate.isDuplicate)
        #expect(!duplicate.shouldWrite)
        #expect(duplicate.acknowledgement.nextExpectedOffset == 32)

        let secondProgress = try receiver.receive(second)
        try sender.acknowledge(secondProgress.acknowledgement)
        let final = try sender.makeChunk(data.subdata(in: 64..<70))
        #expect(final.isFinal)
        let finalProgress = try receiver.receive(final)
        try sender.acknowledge(finalProgress.acknowledgement)

        // A retransmitted final chunk after a lost ACK is idempotently acknowledged.
        let repeatedFinal = try receiver.receive(final)
        #expect(repeatedFinal.isDuplicate)
        #expect(repeatedFinal.acknowledgement.nextExpectedOffset == 70)

        let senderFinished = try sender.senderFinishedMessage()
        #expect(senderFinished.stage == .senderFinished)
        let stored = try receiver.finalize(
            senderFinished,
            calculatedSHA256: SyncSHA256.hexDigest(data),
            storedRelativePath: "Received//payload.bin"
        )
        #expect(stored.isVerifiedAndStored)
        #expect(stored.storedRelativePath == "Received/payload.bin")
        try sender.markReceiverStored(stored)
        #expect(sender.phase == .completed)
        #expect(receiver.phase == .completed)
    }

    @Test
    func resumeStartsAtConfirmedOffsetAndRejectsOutOfOrderOrCorruptChunks() throws {
        let data = Data((0..<64).map { UInt8($0) })
        let metadata = makeMetadata(data: data)
        let parameters = SyncTransferParameters(maximumFrameSize: 185, chunkSize: 32, windowSize: 2)
        var sender = try SyncSendState(metadata: metadata, parameters: parameters, resumeOffset: 32)
        var receiver = try SyncReceiveState(metadata: metadata, parameters: parameters, resumeOffset: 32)

        let final = try sender.makeChunk(data.subdata(in: 32..<64))
        #expect(final.offset == 32)
        #expect(final.isFinal)

        let outOfOrder = SyncChunk(
            transferID: transferID,
            offset: 40,
            data: Data(data[40..<64]),
            isFinal: true
        )
        #expect(throws: SyncProtocolError.unexpectedOffset(expected: 32, actual: 40)) {
            try receiver.receive(outOfOrder)
        }

        var corrupt = final
        corrupt.checksumSHA256 = String(repeating: "0", count: 64)
        #expect(throws: (any Error).self) {
            try receiver.receive(corrupt)
        }

        let progress = try receiver.receive(final)
        #expect(progress.acknowledgement.nextExpectedOffset == 64)
        try sender.acknowledge(progress.acknowledgement)
    }

    @Test
    func wholeFileChecksumMismatchPreventsStoredAcknowledgement() throws {
        let data = Data("correct payload".utf8)
        let metadata = makeMetadata(data: data)
        let parameters = SyncTransferParameters(maximumFrameSize: 185, chunkSize: 64, windowSize: 1)
        var sender = try SyncSendState(metadata: metadata, parameters: parameters)
        var receiver = try SyncReceiveState(metadata: metadata, parameters: parameters)
        _ = try receiver.receive(sender.makeChunk(data))

        #expect(throws: (any Error).self) {
            try receiver.finalize(
                sender.senderFinishedMessage(),
                calculatedSHA256: SyncSHA256.hexDigest(Data("tampered".utf8)),
                storedRelativePath: "payload.bin"
            )
        }
        #expect(receiver.phase == .verifying)
    }

    @Test
    func emptyFileCompletesWithoutADataChunk() throws {
        let data = Data()
        let metadata = makeMetadata(data: data)
        let parameters = SyncTransferParameters(maximumFrameSize: 185, chunkSize: 64, windowSize: 1)
        let sender = try SyncSendState(metadata: metadata, parameters: parameters)
        var receiver = try SyncReceiveState(metadata: metadata, parameters: parameters)

        let stored = try receiver.finalize(
            sender.senderFinishedMessage(),
            calculatedSHA256: SyncSHA256.hexDigest(data),
            storedRelativePath: "empty.txt"
        )
        #expect(stored.isVerifiedAndStored)
    }

    private func makeMetadata(data: Data) -> SyncItemMetadata {
        SyncItemMetadata(
            transferID: transferID,
            direction: .phoneToMac,
            mediaType: .file,
            relativePath: "payload.bin",
            byteSize: UInt64(data.count),
            modifiedAt: Date(timeIntervalSince1970: 1_725_555_555.123),
            sha256: SyncSHA256.hexDigest(data)
        )
    }
}
