import CodexMobilityCore
import Foundation

public actor MacSyncFileTransferEngine {
    public static let defaultMaximumFileSize: UInt64 = 2 * 1_024 * 1_024 * 1_024

    private struct OutgoingState: Sendable {
        var descriptor: MacSyncFileDescriptor
        var fileURL: URL
    }

    private struct IncomingState: Sendable {
        var descriptor: MacSyncFileDescriptor
        var partialURL: URL
        var sidecarURL: URL
        var expectedOffset: UInt64
    }

    private let rootURL: URL
    private let stagingURL: URL
    private let loopSuppressor: MacSyncLoopSuppressor
    private let maximumFileSize: UInt64
    private var outgoingByID: [UUID: OutgoingState] = [:]
    private var outgoingOrder: [UUID] = []
    private var incomingByID: [UUID: IncomingState] = [:]

    public init(
        rootURL: URL,
        loopSuppressor: MacSyncLoopSuppressor = MacSyncLoopSuppressor(),
        maximumFileSize: UInt64 = MacSyncFileTransferEngine.defaultMaximumFileSize
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MacFileSyncError.directoryUnavailable
        }

        self.rootURL = rootURL.standardizedFileURL
        self.stagingURL = rootURL.standardizedFileURL
            .appendingPathComponent(MacSyncFileUtilities.stagingDirectoryName, isDirectory: true)
        self.loopSuppressor = loopSuppressor
        self.maximumFileSize = max(maximumFileSize, 1)
    }

    @discardableResult
    public func enqueueDiscoveredFile(
        _ file: MacSyncDiscoveredFile,
        now: Date = Date()
    ) async throws -> MacSyncFileDescriptor? {
        let relativePath = try MacSyncFileUtilities.normalizedRelativePath(file.relativePath)
        guard file.byteCount <= maximumFileSize else {
            throw MacFileSyncError.fileTooLarge(maximumBytes: maximumFileSize)
        }
        let shouldSuppress = await loopSuppressor.shouldSuppress(
            relativePath: relativePath,
            sha256: file.sha256,
            now: now
        )
        guard !shouldSuppress else {
            return nil
        }

        if let duplicate = outgoingByID.values.first(where: {
            $0.descriptor.relativePath == relativePath && $0.descriptor.sha256 == file.sha256
        }) {
            return duplicate.descriptor
        }

        let supersededIDs = outgoingByID.values
            .filter { $0.descriptor.relativePath == relativePath }
            .map(\.descriptor.transferID)
        for transferID in supersededIDs {
            outgoingByID.removeValue(forKey: transferID)
            outgoingOrder.removeAll { $0 == transferID }
        }

        let descriptor = MacSyncFileDescriptor(
            relativePath: relativePath,
            byteCount: file.byteCount,
            modifiedAt: file.modifiedAt,
            sha256: file.sha256
        )
        outgoingByID[descriptor.transferID] = OutgoingState(
            descriptor: descriptor,
            fileURL: file.fileURL.standardizedFileURL
        )
        outgoingOrder.append(descriptor.transferID)
        return descriptor
    }

    public func outgoingDescriptors() -> [MacSyncFileDescriptor] {
        outgoingOrder.compactMap { outgoingByID[$0]?.descriptor }
    }

    public func nextOutgoingChunk(
        transferID: UUID,
        offset: UInt64,
        maximumBytes: Int
    ) throws -> Data {
        guard let state = outgoingByID[transferID] else {
            throw MacFileSyncError.transferNotFound(transferID)
        }
        guard maximumBytes > 0 else { return Data() }
        guard offset <= state.descriptor.byteCount else {
            throw MacFileSyncError.unexpectedOffset(
                expected: state.descriptor.byteCount,
                received: offset
            )
        }

        let values = try? state.fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let attributes = try? FileManager.default.attributesOfItem(atPath: state.fileURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.uint64Value
        let currentModifiedAt = attributes?[.modificationDate] as? Date
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              currentSize == state.descriptor.byteCount,
              currentModifiedAt == state.descriptor.modifiedAt else {
            throw MacFileSyncError.sourceChanged(state.descriptor.relativePath)
        }

        let remaining = state.descriptor.byteCount - offset
        let requested = Int(min(UInt64(maximumBytes), remaining))
        guard requested > 0 else { return Data() }

        do {
            let handle = try FileHandle(forReadingFrom: state.fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: requested) ?? Data()
        } catch let error as MacFileSyncError {
            throw error
        } catch {
            throw MacFileSyncError.sourceReadFailed(error.localizedDescription)
        }
    }

    public func markOutgoingCompleted(transferID: UUID) throws -> MacSyncFileDescriptor {
        guard let state = outgoingByID.removeValue(forKey: transferID) else {
            throw MacFileSyncError.transferNotFound(transferID)
        }
        outgoingOrder.removeAll { $0 == transferID }
        return state.descriptor
    }

    public func markOutgoingFailed(transferID: UUID) throws -> MacSyncFileDescriptor {
        try markOutgoingCompleted(transferID: transferID)
    }

    /// Removes stale offers for a path after a remote delta has replaced or deleted it.
    public func discardOutgoing(relativePath: String) throws -> [UUID] {
        let relativePath = try MacSyncFileUtilities.normalizedRelativePath(relativePath)
        let transferIDs = outgoingByID.values.compactMap { state in
            state.descriptor.relativePath == relativePath ? state.descriptor.transferID : nil
        }
        for transferID in transferIDs {
            outgoingByID.removeValue(forKey: transferID)
            outgoingOrder.removeAll { $0 == transferID }
        }
        return transferIDs
    }

    /// Prepares a resumable `.partial` file and returns the next required byte offset.
    public func prepareIncoming(_ descriptor: MacSyncFileDescriptor) throws -> UInt64 {
        let normalizedPath = try MacSyncFileUtilities.normalizedRelativePath(descriptor.relativePath)
        guard MacSyncFileUtilities.isValidSHA256(descriptor.sha256) else {
            throw MacFileSyncError.invalidDigest
        }
        guard descriptor.byteCount <= maximumFileSize else {
            throw MacFileSyncError.fileTooLarge(maximumBytes: maximumFileSize)
        }

        if let existing = incomingByID[descriptor.transferID] {
            guard existing.descriptor == descriptor else {
                discardFiles(for: existing)
                incomingByID.removeValue(forKey: descriptor.transferID)
                return try createIncoming(descriptor: descriptor, normalizedPath: normalizedPath)
            }
            return existing.expectedOffset
        }

        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try createIncoming(descriptor: descriptor, normalizedPath: normalizedPath)
    }

    public func writeIncoming(
        transferID: UUID,
        offset: UInt64,
        data: Data
    ) throws -> UInt64 {
        guard var state = incomingByID[transferID] else {
            throw MacFileSyncError.transferNotFound(transferID)
        }
        guard offset == state.expectedOffset else {
            throw MacFileSyncError.unexpectedOffset(expected: state.expectedOffset, received: offset)
        }
        guard UInt64(data.count) <= state.descriptor.byteCount - state.expectedOffset else {
            throw MacFileSyncError.chunkExceedsDeclaredSize
        }
        guard !data.isEmpty else { return state.expectedOffset }

        do {
            let handle = try FileHandle(forWritingTo: state.partialURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
        } catch {
            throw MacFileSyncError.destinationWriteFailed(error.localizedDescription)
        }

        state.expectedOffset += UInt64(data.count)
        incomingByID[transferID] = state
        return state.expectedOffset
    }

    public func completeIncoming(
        transferID: UUID,
        now: Date = Date()
    ) async throws -> MacSyncCompletedTransfer {
        guard let state = incomingByID[transferID] else {
            throw MacFileSyncError.transferNotFound(transferID)
        }
        guard state.expectedOffset == state.descriptor.byteCount else {
            throw MacFileSyncError.incompleteTransfer(
                expected: state.descriptor.byteCount,
                actual: state.expectedOffset
            )
        }

        do {
            let handle = try FileHandle(forWritingTo: state.partialURL)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch {
            throw MacFileSyncError.destinationWriteFailed(error.localizedDescription)
        }

        let actualDigest = try MacSyncFileUtilities.sha256(of: state.partialURL)
        guard actualDigest.caseInsensitiveCompare(state.descriptor.sha256) == .orderedSame else {
            discardFiles(for: state)
            incomingByID.removeValue(forKey: transferID)
            throw MacFileSyncError.checksumMismatch(
                expected: state.descriptor.sha256,
                actual: actualDigest
            )
        }

        let desiredURL = try MacSyncFileUtilities.destinationURL(
            for: state.descriptor.relativePath,
            under: rootURL
        )

        if FileManager.default.fileExists(atPath: desiredURL.path),
           (try? MacSyncFileUtilities.sha256(of: desiredURL)) == actualDigest {
            discardFiles(for: state)
            incomingByID.removeValue(forKey: transferID)
            await loopSuppressor.record(
                relativePath: state.descriptor.relativePath,
                sha256: actualDigest,
                now: now
            )
            return MacSyncCompletedTransfer(
                transferID: transferID,
                relativePath: state.descriptor.relativePath,
                fileURL: desiredURL,
                byteCount: state.descriptor.byteCount,
                sha256: actualDigest,
                completedAt: now,
                reusedExistingFile: true
            )
        }

        let finalURL = MacSyncFileUtilities.conflictFreeURL(for: desiredURL)
        try MacSyncFileUtilities.ensureExistingParentsAreSafe(for: finalURL, rootURL: rootURL)
        do {
            try FileManager.default.moveItem(at: state.partialURL, to: finalURL)
            try? FileManager.default.setAttributes(
                [.modificationDate: state.descriptor.modifiedAt],
                ofItemAtPath: finalURL.path
            )
            try? FileManager.default.removeItem(at: state.sidecarURL)
        } catch {
            throw MacFileSyncError.destinationWriteFailed(error.localizedDescription)
        }
        incomingByID.removeValue(forKey: transferID)

        let finalRelativePath = try MacSyncFileUtilities.relativePath(for: finalURL, under: rootURL)
        await loopSuppressor.record(relativePath: finalRelativePath, sha256: actualDigest, now: now)
        return MacSyncCompletedTransfer(
            transferID: transferID,
            relativePath: finalRelativePath,
            fileURL: finalURL,
            byteCount: state.descriptor.byteCount,
            sha256: actualDigest,
            completedAt: now
        )
    }

    public func cancelIncoming(transferID: UUID) {
        guard let state = incomingByID.removeValue(forKey: transferID) else { return }
        discardFiles(for: state)
    }

    public func incomingOffset(transferID: UUID) -> UInt64? {
        incomingByID[transferID]?.expectedOffset
    }

    /// Atomically replaces one destination with content that the delta coordinator
    /// has already verified block-by-block and as a whole file.
    public func commitVerifiedIncoming(
        transferID: UUID,
        relativePath: String,
        data: Data,
        modifiedAt: Date,
        sha256: String,
        now: Date = Date()
    ) async throws -> MacSyncCompletedTransfer {
        let normalizedPath = try MacSyncFileUtilities.normalizedRelativePath(relativePath)
        guard MacSyncFileUtilities.isValidSHA256(sha256) else {
            throw MacFileSyncError.invalidDigest
        }
        guard UInt64(data.count) <= maximumFileSize else {
            throw MacFileSyncError.fileTooLarge(maximumBytes: maximumFileSize)
        }
        let actualDigest = SyncSHA256.hexDigest(data)
        guard SyncSHA256.constantTimeEqual(actualDigest, sha256) else {
            throw MacFileSyncError.checksumMismatch(expected: sha256, actual: actualDigest)
        }

        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = stagingURL.appendingPathComponent(
            "\(transferID.uuidString).delta-\(UUID().uuidString).partial",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch {
            throw MacFileSyncError.destinationWriteFailed(error.localizedDescription)
        }

        let destinationURL = try MacSyncFileUtilities.destinationURL(
            for: normalizedPath,
            under: rootURL
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let values = try destinationURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw MacFileSyncError.unsafeRelativePath(normalizedPath)
            }
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            try? FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            throw MacFileSyncError.destinationWriteFailed(error.localizedDescription)
        }

        await loopSuppressor.record(
            relativePath: normalizedPath,
            sha256: actualDigest,
            now: now
        )
        return MacSyncCompletedTransfer(
            transferID: transferID,
            relativePath: normalizedPath,
            fileURL: destinationURL,
            byteCount: UInt64(data.count),
            sha256: actualDigest,
            completedAt: now
        )
    }

    /// Applies a remote tombstone after validating that the final path is not a symlink.
    public func commitIncomingDeletion(
        transferID: UUID,
        relativePath: String,
        now: Date = Date()
    ) throws -> String {
        _ = transferID
        _ = now
        let normalizedPath = try MacSyncFileUtilities.normalizedRelativePath(relativePath)
        let destinationURL = try MacSyncFileUtilities.destinationURL(
            for: normalizedPath,
            under: rootURL
        )
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            return normalizedPath
        }
        let values = try destinationURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MacFileSyncError.unsafeRelativePath(normalizedPath)
        }
        do {
            try FileManager.default.removeItem(at: destinationURL)
            return normalizedPath
        } catch {
            throw MacFileSyncError.destinationWriteFailed(error.localizedDescription)
        }
    }

    private func createIncoming(
        descriptor originalDescriptor: MacSyncFileDescriptor,
        normalizedPath: String
    ) throws -> UInt64 {
        var descriptor = originalDescriptor
        descriptor.relativePath = normalizedPath
        descriptor.sha256 = descriptor.sha256.lowercased()

        let partialURL = stagingURL.appendingPathComponent(
            "\(descriptor.transferID.uuidString).partial",
            isDirectory: false
        )
        let sidecarURL = stagingURL.appendingPathComponent(
            "\(descriptor.transferID.uuidString).json",
            isDirectory: false
        )

        var resumableOffset: UInt64 = 0
        if let savedData = try? Data(contentsOf: sidecarURL),
           let savedDescriptor = try? JSONDecoder().decode(MacSyncFileDescriptor.self, from: savedData),
           savedDescriptor == descriptor,
           let attributes = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
           let fileSize = attributes[.size] as? NSNumber,
           fileSize.uint64Value <= descriptor.byteCount {
            resumableOffset = fileSize.uint64Value
        } else {
            try? FileManager.default.removeItem(at: partialURL)
            try? FileManager.default.removeItem(at: sidecarURL)
            guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
                throw MacFileSyncError.destinationWriteFailed("无法创建临时文件")
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: partialURL.path
            )
            let sidecarData = try JSONEncoder().encode(descriptor)
            try sidecarData.write(to: sidecarURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: sidecarURL.path
            )
        }

        if let available = try? rootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           available > 0,
           UInt64(available) < descriptor.byteCount - resumableOffset {
            throw MacFileSyncError.insufficientStorage
        }

        incomingByID[descriptor.transferID] = IncomingState(
            descriptor: descriptor,
            partialURL: partialURL,
            sidecarURL: sidecarURL,
            expectedOffset: resumableOffset
        )
        return resumableOffset
    }

    private func discardFiles(for state: IncomingState) {
        try? FileManager.default.removeItem(at: state.partialURL)
        try? FileManager.default.removeItem(at: state.sidecarURL)
    }
}
