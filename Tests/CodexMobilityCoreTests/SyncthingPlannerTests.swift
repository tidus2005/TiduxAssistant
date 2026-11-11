import CodexMobilityCore
import Foundation
import Testing

@Suite("Syncthing-like index and planner")
struct SyncthingPlannerTests {
    private let minimumBlockSize = SyncthingBlockSizePolicy.minimumBlockSize

    @Test
    func adaptiveBlockSizeUsesSmallestPowerOfTwoBelowTwoThousandBlocks() {
        let largestFileWith1_999MinimumBlocks = UInt64(minimumBlockSize * 1_999)

        #expect(SyncthingBlockSizePolicy.blockSize(forByteSize: 0) == 128 * 1_024)
        #expect(SyncthingBlockSizePolicy.blockSize(
            forByteSize: largestFileWith1_999MinimumBlocks
        ) == 128 * 1_024)
        #expect(SyncthingBlockSizePolicy.blockSize(
            forByteSize: largestFileWith1_999MinimumBlocks + 1
        ) == 256 * 1_024)
        #expect(SyncthingBlockSizePolicy.blockSize(forByteSize: UInt64.max) == 16 * 1_024 * 1_024)
        #expect(SyncthingBlockSizePolicy.isSupported(128 * 1_024))
        #expect(SyncthingBlockSizePolicy.isSupported(16 * 1_024 * 1_024))
        #expect(!SyncthingBlockSizePolicy.isSupported(192 * 1_024))
    }

    @Test
    func fileIndexNormalizesUnicodePathAndBuildsHashedContiguousBlocks() throws {
        let data = Data((0..<(minimumBlockSize * 2 + 17)).map { UInt8($0 % 251) })
        let modifiedAt = Date(timeIntervalSince1970: 1_752_842_096)
        let version = SyncthingVersionVector(counters: ["Mac": 4])
        let index = try SyncthingPlanner.fileIndex(
            for: data,
            relativePath: "Trips//Cafe\u{301}/./photo.raw",
            modifiedAt: modifiedAt,
            deviceID: " Mac ",
            version: version,
            sequence: 42
        )

        #expect(index.relativePath == "Trips/Café/photo.raw")
        #expect(index.size == UInt64(data.count))
        #expect(index.mtime == modifiedAt)
        #expect(index.wholeHash == SyncSHA256.hexDigest(data))
        #expect(index.deviceID == "Mac")
        #expect(index.versionVector == version)
        #expect(index.sequence == 42)
        #expect(!index.deleted)
        #expect(index.blocks.count == 3)
        #expect(index.blocks.map(\.offset) == [0, UInt64(minimumBlockSize), UInt64(minimumBlockSize * 2)])
        #expect(index.blocks.map(\.size) == [minimumBlockSize, minimumBlockSize, 17])
        #expect(index.blocks.allSatisfy { SyncSHA256.isValidHexDigest($0.sha256) })

        let encoded = try JSONEncoder().encode(index)
        #expect(try JSONDecoder().decode(SyncthingFileIndex.self, from: encoded) == index)
        requireSendable(index)
    }

    @Test
    func versionVectorReportsAllFourCausalRelations() {
        let base = SyncthingVersionVector(counters: ["mac": 2, "phone": 1, "ignored": 0])
        let equal = SyncthingVersionVector(counters: ["phone": 1, "mac": 2])
        let newer = SyncthingVersionVector(counters: ["mac": 3, "phone": 1])
        let concurrent = SyncthingVersionVector(counters: ["mac": 1, "phone": 2])

        #expect(base.relation(to: equal) == .equal)
        #expect(newer.relation(to: base) == .dominates)
        #expect(base.relation(to: newer) == .dominated)
        #expect(base.relation(to: concurrent) == .concurrent)
        #expect(base.merged(with: concurrent) == SyncthingVersionVector(
            counters: ["mac": 2, "phone": 2]
        ))
        #expect(base.incremented(deviceID: "mac")["mac"] == 3)
        requireSendable(base)
    }

    @Test
    func deltaPlanRequestsOnlyHashesNotAlreadyAvailableLocally() throws {
        let data = Data((0..<(minimumBlockSize * 2 + 9)).map { UInt8(($0 / minimumBlockSize) + 1) })
        let index = try SyncthingPlanner.fileIndex(
            for: data,
            relativePath: "Sync/archive.bin",
            modifiedAt: Date(timeIntervalSince1970: 100),
            deviceID: "phone",
            version: SyncthingVersionVector(counters: ["phone": 1]),
            sequence: 1
        )
        let localHashes = [index.blocks[0].sha256.uppercased(), index.blocks[2].sha256]
        let plan = SyncthingPlanner.deltaPlan(
            remoteIndex: index,
            locallyAvailableBlockHashes: localHashes
        )

        #expect(plan.relativePath == "Sync/archive.bin")
        #expect(plan.wholeFileSHA256 == index.wholeFileSHA256)
        #expect(plan.requests == [SyncthingBlockRequest(block: index.blocks[1])])
        #expect(!plan.isDeletion)
        #expect(!plan.isContentLocallyAvailable)

        let complete = SyncthingPlanner.deltaPlan(
            remoteIndex: index,
            locallyAvailableBlocks: index.blocks
        )
        #expect(complete.requests.isEmpty)
        #expect(complete.isContentLocallyAvailable)
        requireSendable(plan)
    }

    @Test
    func tombstoneCarriesVersionButNeverRequestsFileBlocks() throws {
        let tombstone = try SyncthingPlanner.tombstone(
            relativePath: "Old//note.txt",
            deletedAt: Date(timeIntervalSince1970: 200),
            deviceID: "mac",
            version: SyncthingVersionVector(counters: ["mac": 7]),
            sequence: 9
        )
        let plan = SyncthingPlanner.deltaPlan(
            remoteIndex: tombstone,
            locallyAvailableBlockHashes: []
        )

        #expect(tombstone.relativePath == "Old/note.txt")
        #expect(tombstone.deleted)
        #expect(tombstone.wholeFileSHA256 == nil)
        #expect(tombstone.blocks.isEmpty)
        #expect(plan.isDeletion)
        #expect(plan.requests.isEmpty)
        #expect(!plan.isContentLocallyAvailable)
    }

    @Test
    func malformedHashesCoverageAndTombstonePayloadAreRejected() throws {
        #expect(throws: SyncthingIndexError.invalidSHA256("bad")) {
            try SyncthingBlockInfo(offset: 0, size: 1, sha256: "bad")
        }

        let block = try SyncthingBlockInfo(
            offset: 1,
            size: 1,
            sha256: SyncSHA256.hexDigest(Data([1]))
        )
        #expect(throws: SyncthingIndexError.unexpectedBlockOffset(expected: 0, actual: 1)) {
            try SyncthingFileIndex(
                relativePath: "bad.bin",
                size: 1,
                modifiedAt: .distantPast,
                wholeFileSHA256: SyncSHA256.hexDigest(Data([1])),
                blocks: [block],
                deviceID: "mac",
                version: SyncthingVersionVector(),
                sequence: 1
            )
        }
        #expect(throws: SyncthingIndexError.tombstoneContainsFileData) {
            try SyncthingFileIndex(
                relativePath: "deleted.bin",
                size: 1,
                modifiedAt: .distantPast,
                wholeFileSHA256: SyncSHA256.hexDigest(Data([1])),
                blocks: [],
                deviceID: "mac",
                version: SyncthingVersionVector(),
                sequence: 2,
                deleted: true
            )
        }
    }

    @Test
    func conflictNamePreservesParentExtensionAndUsesUTCDeviceToken() throws {
        let timestamp = try #require(
            ISO8601DateFormatter().date(from: "2026-07-18T12:34:56Z")
        )
        let conflict = try SyncthingPlanner.conflictRelativePath(
            for: "Trips/Cafe\u{301}.txt",
            modifiedAt: timestamp,
            deviceID: "Phone 15/Pro"
        )

        #expect(conflict == "Trips/Café.sync-conflict-20260718-123456-Phone-15-Pro.txt")
        #expect(try SyncthingPlanner.conflictRelativePath(
            for: "Config/.env",
            modifiedAt: timestamp,
            deviceID: "Mac"
        ) == "Config/.env.sync-conflict-20260718-123456-Mac")
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
