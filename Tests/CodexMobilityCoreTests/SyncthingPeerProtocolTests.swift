import Foundation
import Testing
@testable import CodexMobilityCore

struct SyncthingPeerProtocolTests {
    @Test
    func messagesRoundTripThroughJSON() throws {
        let deviceID = UUID(uuidString: "B45032C4-F50E-4B2B-BC7A-55CC66B66680")!
        let messageID = UUID(uuidString: "91A2A473-BF5E-489F-9457-C68ACB514C7C")!
        let requestID = UUID(uuidString: "74AE6178-1749-4E44-A57D-AB85EBB756AC")!
        let data = Data("peer block".utf8)
        let block = try SyncthingBlockRequest(
            offset: 1_024,
            size: data.count,
            sha256: SyncSHA256.hexDigest(data)
        )
        let transferID = UUID(uuidString: "C6A46D14-1E3E-426F-8D26-82AD44F7C356")!
        let messages: [SyncthingPeerMessage] = [
            .hello(
                SyncthingPeerHello(
                    messageID: messageID,
                    deviceID: deviceID,
                    intendedPeerDeviceID: UUID(
                        uuidString: "F855375E-9620-4FBB-8D48-2AEB8997AA5E"
                    )!,
                    nonce: UUID(uuidString: "7448D8EB-8D58-4102-9263-0A0F01642529")!,
                    deviceName: "Travel Mac",
                    folderIDs: ["inbox"],
                    authenticationProof: String(repeating: "a", count: 64)
                )
            ),
            .index(
                SyncthingPeerIndex(
                    messageID: messageID,
                    folderID: "inbox",
                    sequence: 7,
                    entries: []
                )
            ),
            .indexUpdate(
                SyncthingPeerIndexUpdate(
                    messageID: messageID,
                    folderID: "inbox",
                    sequence: 8,
                    entries: []
                )
            ),
            .blockRequest(
                SyncthingPeerBlockRequest(
                    requestID: requestID,
                    folderID: "inbox",
                    relativePath: "photos/image.jpg",
                    block: block
                )
            ),
            .blockResponse(
                SyncthingPeerBlockResponse(
                    requestID: requestID,
                    folderID: "inbox",
                    relativePath: "photos/image.jpg",
                    block: block,
                    data: data
                )
            ),
            .ack(SyncthingPeerAcknowledgement(acknowledgedMessageID: messageID)),
            .close(SyncthingPeerClose(code: .shuttingDown, reason: "battery limit")),
            .transfer(
                .ack(
                    SyncAcknowledgement(
                        transferID: transferID,
                        nextExpectedOffset: 32_768,
                        availableWindow: 4
                    )
                )
            )
        ]
        let codec = SyncthingPeerJSONCodec()

        for message in messages {
            #expect(try codec.decode(codec.encode(message)) == message)
        }
    }

    @Test
    func incrementalDecoderHandlesEverySplitPoint() throws {
        let message = SyncthingPeerMessage.hello(
            SyncthingPeerHello(
                deviceID: UUID(uuidString: "560F9BAE-6028-46AF-9CF4-78070A85BCA9")!,
                intendedPeerDeviceID: UUID(
                    uuidString: "68EE3834-2AD0-4F92-BC4D-88C29A71AE3C"
                )!,
                deviceName: "iPhone"
            )
        )
        let codec = SyncthingPeerFrameCodec()
        let frame = try codec.encode(message)
        let expectedPayload = try SyncthingPeerJSONCodec().encode(message)

        for split in 0...frame.count {
            var decoder = SyncthingPeerIncrementalFrameDecoder()
            let first = Data(frame.prefix(split))
            let second = Data(frame.dropFirst(split))
            let firstPayloads = try decoder.append(first)
            let secondPayloads = try decoder.append(second)

            #expect(firstPayloads + secondPayloads == [expectedPayload])
            #expect(decoder.bufferedByteCount == 0)
            try decoder.finish()
        }
    }

    @Test
    func incrementalDecoderHandlesStickyFrames() throws {
        let first = SyncthingPeerMessage.ack(
            SyncthingPeerAcknowledgement(
                acknowledgedMessageID: UUID(uuidString: "BF976944-3C41-4546-B1F0-7FF3E80C1075")!
            )
        )
        let second = SyncthingPeerMessage.close(SyncthingPeerClose())
        let frameCodec = SyncthingPeerFrameCodec()
        var combined = try frameCodec.encode(first)
        combined.append(try frameCodec.encode(second))

        var decoder = SyncthingPeerIncrementalFrameDecoder()
        let payloads = try decoder.append(combined)
        let messageCodec = SyncthingPeerJSONCodec()

        #expect(try payloads.map(messageCodec.decode) == [first, second])
        #expect(!decoder.hasIncompleteFrame)
    }

    @Test
    func decoderRejectsOversizedLengthBeforePayloadArrives() {
        let oversized = SyncthingPeerProtocolLimits.maximumMessageSize + 1
        let length = UInt32(oversized)
        let header = Data([
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length)
        ])
        var decoder = SyncthingPeerIncrementalFrameDecoder()

        #expect(throws: SyncthingPeerFramingError.messageTooLarge(
            actual: oversized,
            maximum: SyncthingPeerProtocolLimits.maximumMessageSize
        )) {
            try decoder.append(header)
        }
    }

    @Test
    func encoderRejectsOversizedPayload() {
        let oversized = SyncthingPeerProtocolLimits.maximumMessageSize + 1
        let payload = Data(repeating: 0x61, count: oversized)

        #expect(throws: SyncthingPeerFramingError.messageTooLarge(
            actual: oversized,
            maximum: SyncthingPeerProtocolLimits.maximumMessageSize
        )) {
            try SyncthingPeerFrameCodec().encode(payload: payload)
        }
    }

    @Test
    func maximumAdaptiveBlockFitsTheBoundedJSONFrame() throws {
        let data = Data(repeating: 0xa5, count: SyncthingBlockSizePolicy.maximumBlockSize)
        let block = try SyncthingBlockRequest(
            offset: 0,
            size: data.count,
            sha256: SyncSHA256.hexDigest(data)
        )
        let message = SyncthingPeerMessage.blockResponse(
            SyncthingPeerBlockResponse(
                requestID: UUID(),
                folderID: "codex-sync",
                relativePath: "large.bin",
                block: block,
                data: data
            )
        )

        let frame = try SyncthingPeerFrameCodec().encode(message)
        #expect(frame.count > data.count)
        #expect(
            frame.count
                <= SyncthingPeerProtocolLimits.maximumMessageSize
                    + SyncthingPeerProtocolLimits.frameHeaderSize
        )
    }

    @Test
    func networkDecodingRevalidatesPathsHashesAndBlockBounds() throws {
        let index = try SyncthingPlanner.fileIndex(
            for: Data("validated".utf8),
            relativePath: "safe.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_710_000_000),
            deviceID: "peer",
            version: SyncthingVersionVector(counters: ["peer": 1]),
            sequence: 1
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let validIndexJSON = try #require(String(data: encoder.encode(index), encoding: .utf8))
        let unsafePathJSON = validIndexJSON.replacingOccurrences(
            of: "\"safe.txt\"",
            with: "\"../escape.txt\""
        )
        do {
            _ = try decoder.decode(SyncthingFileIndex.self, from: Data(unsafePathJSON.utf8))
            Issue.record("A decoded peer index must not bypass relative-path validation")
        } catch {
            // Expected.
        }

        let request = try SyncthingBlockRequest(
            offset: 0,
            size: 9,
            sha256: SyncSHA256.hexDigest(Data("validated".utf8))
        )
        let validRequestJSON = try #require(String(data: encoder.encode(request), encoding: .utf8))
        let oversizedRequestJSON = validRequestJSON.replacingOccurrences(
            of: "\"size\":9",
            with: "\"size\":16777217"
        )
        do {
            _ = try decoder.decode(
                SyncthingBlockRequest.self,
                from: Data(oversizedRequestJSON.utf8)
            )
            Issue.record("A decoded peer block must respect the adaptive block-size cap")
        } catch {
            // Expected.
        }
    }
}
