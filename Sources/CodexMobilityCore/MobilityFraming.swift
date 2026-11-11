import Foundation

public struct MobilityFrameHeader: Codable, Equatable, Hashable, Sendable {
    public static let expectedMagic: UInt32 = 0x434D4F42
    public static let currentVersion: UInt8 = 1
    public static let encodedLength = 25

    public var magic: UInt32
    public var version: UInt8
    public var messageID: UUID
    public var fragmentIndex: UInt16
    public var fragmentCount: UInt16

    public init(
        magic: UInt32 = Self.expectedMagic,
        version: UInt8 = Self.currentVersion,
        messageID: UUID,
        fragmentIndex: UInt16,
        fragmentCount: UInt16
    ) {
        self.magic = magic
        self.version = version
        self.messageID = messageID
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
    }
}

public struct MobilityFrame: Codable, Equatable, Hashable, Sendable {
    public var header: MobilityFrameHeader
    public var payload: Data

    public init(header: MobilityFrameHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

public enum MobilityFrameError: Error, Codable, Equatable, Hashable, Sendable {
    case frameTooShort(actual: Int, minimum: Int)
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt8)
    case invalidFragmentCount(UInt16)
    case invalidFragmentIndex(index: UInt16, count: UInt16)
    case frameSizeTooSmall(Int)
    case tooManyFragments(Int)
    case inconsistentFragmentCount
    case conflictingDuplicate(UInt16)
    case messageTooLarge(Int)
}

public struct MobilityFrameCodec: Codable, Equatable, Hashable, Sendable {
    public init() {}

    public func encode(
        _ payload: Data,
        messageID: UUID = UUID(),
        maximumFrameSize: Int
    ) throws -> [Data] {
        try Self.fragment(payload, messageID: messageID, maximumFrameSize: maximumFrameSize)
    }

    public func decode(_ data: Data) throws -> MobilityFrame {
        try Self.decode(data)
    }

    public static func fragment(
        _ payload: Data,
        messageID: UUID = UUID(),
        maximumFrameSize: Int
    ) throws -> [Data] {
        let payloadCapacity = maximumFrameSize - MobilityFrameHeader.encodedLength
        guard payloadCapacity > 0 else {
            throw MobilityFrameError.frameSizeTooSmall(maximumFrameSize)
        }

        let fragmentCount = max(1, (payload.count + payloadCapacity - 1) / payloadCapacity)
        guard fragmentCount <= Int(UInt16.max) else {
            throw MobilityFrameError.tooManyFragments(fragmentCount)
        }

        return (0..<fragmentCount).map { index in
            let lowerBound = index * payloadCapacity
            let upperBound = min(lowerBound + payloadCapacity, payload.count)
            let fragmentPayload = payload.subdata(in: lowerBound..<upperBound)
            let header = MobilityFrameHeader(
                messageID: messageID,
                fragmentIndex: UInt16(index),
                fragmentCount: UInt16(fragmentCount)
            )
            return encode(header: header, payload: fragmentPayload)
        }
    }

    public static func decode(_ data: Data) throws -> MobilityFrame {
        guard data.count >= MobilityFrameHeader.encodedLength else {
            throw MobilityFrameError.frameTooShort(
                actual: data.count,
                minimum: MobilityFrameHeader.encodedLength
            )
        }

        let bytes = [UInt8](data.prefix(MobilityFrameHeader.encodedLength))
        let magic = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        guard magic == MobilityFrameHeader.expectedMagic else {
            throw MobilityFrameError.invalidMagic(magic)
        }

        let version = bytes[4]
        guard version == MobilityFrameHeader.currentVersion else {
            throw MobilityFrameError.unsupportedVersion(version)
        }

        let uuid = UUID(uuid: (
            bytes[5], bytes[6], bytes[7], bytes[8],
            bytes[9], bytes[10], bytes[11], bytes[12],
            bytes[13], bytes[14], bytes[15], bytes[16],
            bytes[17], bytes[18], bytes[19], bytes[20]
        ))
        let fragmentIndex = UInt16(bytes[21]) << 8 | UInt16(bytes[22])
        let fragmentCount = UInt16(bytes[23]) << 8 | UInt16(bytes[24])
        guard fragmentCount > 0 else {
            throw MobilityFrameError.invalidFragmentCount(fragmentCount)
        }
        guard fragmentIndex < fragmentCount else {
            throw MobilityFrameError.invalidFragmentIndex(index: fragmentIndex, count: fragmentCount)
        }

        return MobilityFrame(
            header: MobilityFrameHeader(
                magic: magic,
                version: version,
                messageID: uuid,
                fragmentIndex: fragmentIndex,
                fragmentCount: fragmentCount
            ),
            payload: Data(data.dropFirst(MobilityFrameHeader.encodedLength))
        )
    }

    private static func encode(header: MobilityFrameHeader, payload: Data) -> Data {
        var data = Data(capacity: MobilityFrameHeader.encodedLength + payload.count)
        data.append(UInt8((header.magic >> 24) & 0xFF))
        data.append(UInt8((header.magic >> 16) & 0xFF))
        data.append(UInt8((header.magic >> 8) & 0xFF))
        data.append(UInt8(header.magic & 0xFF))
        data.append(header.version)
        var rawUUID = header.messageID.uuid
        withUnsafeBytes(of: &rawUUID) { data.append(contentsOf: $0) }
        data.append(UInt8((header.fragmentIndex >> 8) & 0xFF))
        data.append(UInt8(header.fragmentIndex & 0xFF))
        data.append(UInt8((header.fragmentCount >> 8) & 0xFF))
        data.append(UInt8(header.fragmentCount & 0xFF))
        data.append(payload)
        return data
    }
}

public struct MobilityReassembledMessage: Codable, Equatable, Hashable, Sendable {
    public var messageID: UUID
    public var payload: Data

    public init(messageID: UUID, payload: Data) {
        self.messageID = messageID
        self.payload = payload
    }
}

public struct MobilityFrameReassembler: Codable, Equatable, Sendable {
    private struct Assembly: Codable, Equatable, Sendable {
        var fragmentCount: UInt16
        var fragments: [UInt16: Data]
        var byteCount: Int
        var updatedAt: Date
    }

    public var timeout: TimeInterval
    public var maximumMessageSize: Int
    private var assemblies: [UUID: Assembly]

    public init(timeout: TimeInterval = 5, maximumMessageSize: Int = 64 * 1024) {
        self.timeout = max(timeout, 0)
        self.maximumMessageSize = max(maximumMessageSize, 1)
        self.assemblies = [:]
    }

    public mutating func ingest(
        _ encodedFrame: Data,
        now: Date = Date()
    ) throws -> MobilityReassembledMessage? {
        pruneExpired(now: now)
        let frame = try MobilityFrameCodec.decode(encodedFrame)
        let id = frame.header.messageID

        var assembly = assemblies[id] ?? Assembly(
            fragmentCount: frame.header.fragmentCount,
            fragments: [:],
            byteCount: 0,
            updatedAt: now
        )
        guard assembly.fragmentCount == frame.header.fragmentCount else {
            assemblies[id] = nil
            throw MobilityFrameError.inconsistentFragmentCount
        }

        if let existing = assembly.fragments[frame.header.fragmentIndex] {
            guard existing == frame.payload else {
                assemblies[id] = nil
                throw MobilityFrameError.conflictingDuplicate(frame.header.fragmentIndex)
            }
        } else {
            assembly.fragments[frame.header.fragmentIndex] = frame.payload
            assembly.byteCount += frame.payload.count
            guard assembly.byteCount <= maximumMessageSize else {
                assemblies[id] = nil
                throw MobilityFrameError.messageTooLarge(assembly.byteCount)
            }
        }
        assembly.updatedAt = now

        guard assembly.fragments.count == Int(assembly.fragmentCount) else {
            assemblies[id] = assembly
            return nil
        }

        var payload = Data(capacity: assembly.byteCount)
        for index in 0..<assembly.fragmentCount {
            guard let fragment = assembly.fragments[index] else {
                assemblies[id] = assembly
                return nil
            }
            payload.append(fragment)
        }
        assemblies[id] = nil
        return MobilityReassembledMessage(messageID: id, payload: payload)
    }

    public mutating func pruneExpired(now: Date = Date()) {
        assemblies = assemblies.filter { now.timeIntervalSince($0.value.updatedAt) <= timeout }
    }

    public mutating func reset() {
        assemblies.removeAll(keepingCapacity: false)
    }
}
