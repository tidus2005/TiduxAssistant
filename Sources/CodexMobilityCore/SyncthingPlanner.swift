import Foundation

public enum SyncthingPlanner {
    public static func blocks(for data: Data) throws -> [SyncthingBlockInfo] {
        guard !data.isEmpty else { return [] }
        let blockSize = SyncthingBlockSizePolicy.blockSize(forByteSize: UInt64(data.count))
        var blocks: [SyncthingBlockInfo] = []
        blocks.reserveCapacity(Int(
            SyncthingBlockSizePolicy.blockCount(
                forByteSize: UInt64(data.count),
                blockSize: blockSize
            )
        ))

        var offset = 0
        while offset < data.count {
            let end = min(offset + blockSize, data.count)
            let blockData = data.subdata(in: offset..<end)
            blocks.append(try SyncthingBlockInfo(
                offset: UInt64(offset),
                size: blockData.count,
                sha256: SyncSHA256.hexDigest(blockData)
            ))
            offset = end
        }
        return blocks
    }

    public static func fileIndex(
        for data: Data,
        relativePath: String,
        modifiedAt: Date,
        deviceID: String,
        version: SyncthingVersionVector,
        sequence: UInt64
    ) throws -> SyncthingFileIndex {
        try SyncthingFileIndex(
            relativePath: relativePath,
            size: UInt64(data.count),
            modifiedAt: modifiedAt,
            wholeFileSHA256: SyncSHA256.hexDigest(data),
            blocks: blocks(for: data),
            deviceID: deviceID,
            version: version,
            sequence: sequence
        )
    }

    public static func tombstone(
        relativePath: String,
        deletedAt: Date,
        deviceID: String,
        version: SyncthingVersionVector,
        sequence: UInt64
    ) throws -> SyncthingFileIndex {
        try SyncthingFileIndex(
            relativePath: relativePath,
            size: 0,
            modifiedAt: deletedAt,
            wholeFileSHA256: nil,
            blocks: [],
            deviceID: deviceID,
            version: version,
            sequence: sequence,
            deleted: true
        )
    }

    /// Produces requests only for remote blocks whose content hash is not locally available.
    public static func deltaPlan(
        remoteIndex: SyncthingFileIndex,
        locallyAvailableBlockHashes: some Sequence<String>
    ) -> SyncthingDeltaPlan {
        let localHashes = Set(locallyAvailableBlockHashes.compactMap { hash -> String? in
            guard SyncSHA256.isValidHexDigest(hash) else { return nil }
            return hash.lowercased()
        })
        let requests = remoteIndex.deleted ? [] : remoteIndex.blocks.compactMap { block in
            localHashes.contains(block.sha256) ? nil : SyncthingBlockRequest(block: block)
        }
        return SyncthingDeltaPlan(
            relativePath: remoteIndex.relativePath,
            wholeFileSHA256: remoteIndex.wholeFileSHA256,
            requests: requests,
            isDeletion: remoteIndex.deleted
        )
    }

    public static func deltaPlan(
        remoteIndex: SyncthingFileIndex,
        locallyAvailableBlocks: some Sequence<SyncthingBlockInfo>
    ) -> SyncthingDeltaPlan {
        deltaPlan(
            remoteIndex: remoteIndex,
            locallyAvailableBlockHashes: locallyAvailableBlocks.map(\.sha256)
        )
    }

    /// Creates `<stem>.sync-conflict-YYYYMMDD-HHmmss-<device>.<ext>` in UTC.
    public static func conflictRelativePath(
        for relativePath: String,
        modifiedAt: Date,
        deviceID: String
    ) throws -> String {
        let relativePath = try SyncRelativePath.normalize(relativePath)
        let parent = SyncRelativePath.parent(in: relativePath)
        let fileName = SyncRelativePath.fileName(in: relativePath)
        let parts = splitExtension(fileName)
        let timestamp = utcTimestamp(modifiedAt)
        let deviceToken = safeDeviceToken(deviceID)
        let suffix = ".sync-conflict-\(timestamp.date)-\(timestamp.time)-\(deviceToken)"
        let extensionSuffix = parts.extension.map { ".\($0)" } ?? ""
        let availableStemBytes = SyncProtocolLimits.maximumPathComponentUTF8Bytes
            - suffix.utf8.count
            - extensionSuffix.utf8.count
        guard availableStemBytes > 0 else {
            throw SyncPathError.componentTooLong(fileName)
        }
        let stem = truncate(parts.stem, maximumUTF8Bytes: availableStemBytes)
        let conflictName = stem + suffix + extensionSuffix
        return try SyncRelativePath.normalize(
            parent.map { "\($0)/\(conflictName)" } ?? conflictName
        )
    }

    private static func utcTimestamp(_ date: Date) -> (date: String, time: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return (
            String(
                format: "%04d%02d%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            ),
            String(
                format: "%02d%02d%02d",
                components.hour ?? 0,
                components.minute ?? 0,
                components.second ?? 0
            )
        )
    }

    private static func safeDeviceToken(_ deviceID: String) -> String {
        var result = ""
        var previousWasSeparator = false
        for scalar in deviceID.precomposedStringWithCanonicalMapping.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "_"
            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator && !result.isEmpty {
                result.append("-")
                previousWasSeparator = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if result.isEmpty { result = "unknown-device" }
        return truncate(result, maximumUTF8Bytes: 48)
    }

    private static func splitExtension(_ fileName: String) -> (stem: String, extension: String?) {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return (fileName, nil)
        }
        let afterDot = fileName.index(after: dot)
        guard afterDot < fileName.endIndex else { return (fileName, nil) }
        return (String(fileName[..<dot]), String(fileName[afterDot...]))
    }

    private static func truncate(_ value: String, maximumUTF8Bytes: Int) -> String {
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumUTF8Bytes else { break }
            result = candidate
        }
        return result.isEmpty ? "file" : result
    }
}
