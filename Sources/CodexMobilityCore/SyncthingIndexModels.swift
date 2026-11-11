import Foundation

public enum SyncthingIndexError: Error, Equatable, Sendable {
    case invalidBlockSize(Int)
    case invalidSHA256(String)
    case emptyDeviceID
    case tombstoneContainsFileData
    case unexpectedBlockOffset(expected: UInt64, actual: UInt64)
    case blockRangeOverflow(offset: UInt64, size: Int)
    case blockCoverageMismatch(expected: UInt64, actual: UInt64)
}

/// Syncthing-compatible block sizing: use the smallest power-of-two block size
/// that produces fewer than 2,000 blocks, capped at 16 MiB for very large files.
public enum SyncthingBlockSizePolicy {
    public static let minimumBlockSize = 128 * 1_024
    public static let maximumBlockSize = 16 * 1_024 * 1_024
    public static let targetBlockCount = 2_000

    public static func blockSize(forByteSize byteSize: UInt64) -> Int {
        var candidate = minimumBlockSize
        while candidate < maximumBlockSize {
            if blockCount(forByteSize: byteSize, blockSize: candidate) < UInt64(targetBlockCount) {
                return candidate
            }
            candidate *= 2
        }
        return maximumBlockSize
    }

    public static func blockCount(forByteSize byteSize: UInt64, blockSize: Int) -> UInt64 {
        guard byteSize > 0 else { return 0 }
        let divisor = UInt64(max(blockSize, 1))
        return ((byteSize - 1) / divisor) + 1
    }

    public static func isSupported(_ blockSize: Int) -> Bool {
        blockSize >= minimumBlockSize
            && blockSize <= maximumBlockSize
            && blockSize.isMultiple(of: minimumBlockSize)
            && (blockSize / minimumBlockSize).isPowerOfTwo
    }
}

public struct SyncthingBlockInfo: Codable, Equatable, Hashable, Sendable {
    public let offset: UInt64
    public let size: Int
    public let sha256: String

    public init(offset: UInt64, size: Int, sha256: String) throws {
        guard size > 0, size <= SyncthingBlockSizePolicy.maximumBlockSize else {
            throw SyncthingIndexError.invalidBlockSize(size)
        }
        guard SyncSHA256.isValidHexDigest(sha256) else {
            throw SyncthingIndexError.invalidSHA256(sha256)
        }
        self.offset = offset
        self.size = size
        self.sha256 = sha256.lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case offset
        case size
        case sha256
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            offset: container.decode(UInt64.self, forKey: .offset),
            size: container.decode(Int.self, forKey: .size),
            sha256: container.decode(String.self, forKey: .sha256)
        )
    }

    public var endOffset: UInt64? {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(size))
        return overflow ? nil : end
    }
}

public enum SyncthingVersionRelation: String, Codable, Equatable, Hashable, Sendable {
    case equal
    case dominates
    case dominated
    case concurrent
}

/// A canonical vector clock. Missing and zero-valued counters are equivalent.
public struct SyncthingVersionVector: Codable, Equatable, Sendable, Hashable {
    public private(set) var counters: [String: UInt64]

    public init(counters: [String: UInt64] = [:]) {
        var canonical: [String: UInt64] = [:]
        for (rawDeviceID, value) in counters where value > 0 {
            let deviceID = Self.canonicalDeviceID(rawDeviceID)
            guard !deviceID.isEmpty else { continue }
            canonical[deviceID] = max(canonical[deviceID, default: 0], value)
        }
        self.counters = canonical
    }

    private enum CodingKeys: String, CodingKey {
        case counters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(counters: try container.decode([String: UInt64].self, forKey: .counters))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(counters, forKey: .counters)
    }

    public subscript(deviceID: String) -> UInt64 {
        counters[Self.canonicalDeviceID(deviceID), default: 0]
    }

    public mutating func increment(deviceID: String) {
        let deviceID = Self.canonicalDeviceID(deviceID)
        guard !deviceID.isEmpty else { return }
        let current = counters[deviceID, default: 0]
        counters[deviceID] = current == UInt64.max ? UInt64.max : current + 1
    }

    public func incremented(deviceID: String) -> SyncthingVersionVector {
        var copy = self
        copy.increment(deviceID: deviceID)
        return copy
    }

    public func merged(with other: SyncthingVersionVector) -> SyncthingVersionVector {
        var merged = counters
        for (deviceID, value) in other.counters {
            merged[deviceID] = max(merged[deviceID, default: 0], value)
        }
        return SyncthingVersionVector(counters: merged)
    }

    public func relation(to other: SyncthingVersionVector) -> SyncthingVersionRelation {
        let deviceIDs = Set(counters.keys).union(other.counters.keys)
        var isGreater = false
        var isLess = false

        for deviceID in deviceIDs {
            let local = self[deviceID]
            let remote = other[deviceID]
            if local > remote { isGreater = true }
            if local < remote { isLess = true }
            if isGreater && isLess { return .concurrent }
        }

        if isGreater { return .dominates }
        if isLess { return .dominated }
        return .equal
    }

    public func hash(into hasher: inout Hasher) {
        for deviceID in counters.keys.sorted() {
            hasher.combine(deviceID)
            hasher.combine(counters[deviceID])
        }
    }

    private static func canonicalDeviceID(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SyncthingFileIndex: Codable, Equatable, Hashable, Sendable {
    public let relativePath: String
    public let size: UInt64
    public let modifiedAt: Date
    public let wholeFileSHA256: String?
    public let blocks: [SyncthingBlockInfo]
    public let deviceID: String
    public let version: SyncthingVersionVector
    public let sequence: UInt64
    public let deleted: Bool

    public init(
        relativePath: String,
        size: UInt64,
        modifiedAt: Date,
        wholeFileSHA256: String?,
        blocks: [SyncthingBlockInfo],
        deviceID: String,
        version: SyncthingVersionVector,
        sequence: UInt64,
        deleted: Bool = false
    ) throws {
        let relativePath = try SyncRelativePath.normalize(relativePath)
        let deviceID = deviceID.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty else { throw SyncthingIndexError.emptyDeviceID }

        if deleted {
            guard size == 0, wholeFileSHA256 == nil, blocks.isEmpty else {
                throw SyncthingIndexError.tombstoneContainsFileData
            }
        } else {
            guard let wholeFileSHA256, SyncSHA256.isValidHexDigest(wholeFileSHA256) else {
                throw SyncthingIndexError.invalidSHA256(wholeFileSHA256 ?? "")
            }
            try Self.validateCoverage(blocks, expectedSize: size)
        }

        self.relativePath = relativePath
        self.size = size
        self.modifiedAt = modifiedAt
        self.wholeFileSHA256 = wholeFileSHA256?.lowercased()
        self.blocks = blocks
        self.deviceID = deviceID
        self.version = version
        self.sequence = sequence
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath
        case size
        case modifiedAt
        case wholeFileSHA256
        case blocks
        case deviceID
        case version
        case sequence
        case deleted
    }

    /// Network decoding must take the same validated path as local construction.
    /// Synthesized `Decodable` would otherwise populate stored properties directly.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relativePath: container.decode(String.self, forKey: .relativePath),
            size: container.decode(UInt64.self, forKey: .size),
            modifiedAt: container.decode(Date.self, forKey: .modifiedAt),
            wholeFileSHA256: container.decodeIfPresent(String.self, forKey: .wholeFileSHA256),
            blocks: container.decode([SyncthingBlockInfo].self, forKey: .blocks),
            deviceID: container.decode(String.self, forKey: .deviceID),
            version: container.decode(SyncthingVersionVector.self, forKey: .version),
            sequence: container.decode(UInt64.self, forKey: .sequence),
            deleted: container.decode(Bool.self, forKey: .deleted)
        )
    }

    public var mtime: Date { modifiedAt }
    public var wholeHash: String? { wholeFileSHA256 }
    public var versionVector: SyncthingVersionVector { version }

    private static func validateCoverage(
        _ blocks: [SyncthingBlockInfo],
        expectedSize: UInt64
    ) throws {
        if blocks.count > 1 {
            let nominalBlockSize = blocks[0].size
            guard SyncthingBlockSizePolicy.isSupported(nominalBlockSize) else {
                throw SyncthingIndexError.invalidBlockSize(nominalBlockSize)
            }
            for block in blocks.dropLast() where block.size != nominalBlockSize {
                throw SyncthingIndexError.invalidBlockSize(block.size)
            }
            if let finalBlock = blocks.last, finalBlock.size > nominalBlockSize {
                throw SyncthingIndexError.invalidBlockSize(finalBlock.size)
            }
        }

        var expectedOffset: UInt64 = 0
        for block in blocks {
            guard block.offset == expectedOffset else {
                throw SyncthingIndexError.unexpectedBlockOffset(
                    expected: expectedOffset,
                    actual: block.offset
                )
            }
            guard let endOffset = block.endOffset else {
                throw SyncthingIndexError.blockRangeOverflow(offset: block.offset, size: block.size)
            }
            expectedOffset = endOffset
        }
        guard expectedOffset == expectedSize else {
            throw SyncthingIndexError.blockCoverageMismatch(
                expected: expectedSize,
                actual: expectedOffset
            )
        }
    }
}

public struct SyncthingBlockRequest: Codable, Equatable, Hashable, Sendable {
    public let offset: UInt64
    public let size: Int
    public let sha256: String

    public init(offset: UInt64, size: Int, sha256: String) throws {
        let block = try SyncthingBlockInfo(offset: offset, size: size, sha256: sha256)
        self.init(block: block)
    }

    public init(block: SyncthingBlockInfo) {
        self.offset = block.offset
        self.size = block.size
        self.sha256 = block.sha256
    }

    private enum CodingKeys: String, CodingKey {
        case offset
        case size
        case sha256
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            offset: container.decode(UInt64.self, forKey: .offset),
            size: container.decode(Int.self, forKey: .size),
            sha256: container.decode(String.self, forKey: .sha256)
        )
    }
}

public struct SyncthingDeltaPlan: Codable, Equatable, Hashable, Sendable {
    public let relativePath: String
    public let wholeFileSHA256: String?
    public let requests: [SyncthingBlockRequest]
    public let isDeletion: Bool

    public init(
        relativePath: String,
        wholeFileSHA256: String?,
        requests: [SyncthingBlockRequest],
        isDeletion: Bool
    ) {
        self.relativePath = relativePath
        self.wholeFileSHA256 = wholeFileSHA256
        self.requests = requests
        self.isDeletion = isDeletion
    }

    public var requestedBlocks: [SyncthingBlockRequest] { requests }
    public var isContentLocallyAvailable: Bool { !isDeletion && requests.isEmpty }
}

private extension Int {
    var isPowerOfTwo: Bool {
        self > 0 && (self & (self - 1)) == 0
    }
}
