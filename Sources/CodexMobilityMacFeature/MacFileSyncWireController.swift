import CodexMobilityCore
import Foundation

/// Negotiation limits for the link carrying the synchronization state machine.
///
/// Bluetooth keeps the original conservative 8 KiB, single-flight behavior. The
/// TLS local-network transport can carry the protocol maximum 64 KiB chunk while
/// retaining a one-chunk acknowledgement window until pipelining is implemented.
public enum MacFileSyncTransportProfile: Equatable, Hashable, Sendable {
    case bluetooth
    case localNetwork

    public var maximumFrameSize: Int {
        switch self {
        case .bluetooth:
            MacFileSyncWireController.logicalMessageLimit
        case .localNetwork:
            MacFileSyncWireController.localNetworkLogicalMessageLimit
        }
    }

    public var preferredChunkSize: Int {
        switch self {
        case .bluetooth:
            MacFileSyncWireController.bluetoothChunkSize
        case .localNetwork:
            SyncProtocolLimits.maximumChunkSize
        }
    }

    public var windowSize: Int { 1 }

    fileprivate var capabilities: SyncTransportCapabilities {
        SyncTransportCapabilities(
            maximumFrameSize: maximumFrameSize,
            preferredChunkSize: preferredChunkSize,
            maximumWindowSize: windowSize
        )
    }

    fileprivate var defaultParameters: SyncTransferParameters {
        SyncTransferParameters(
            maximumFrameSize: maximumFrameSize,
            chunkSize: preferredChunkSize,
            windowSize: windowSize
        )
    }
}

/// Bridges the platform-neutral synchronization protocol to the selected Mac folder.
///
/// Transfers deliberately use one acknowledged chunk at a time. Bluetooth throughput is
/// lower than Wi-Fi, but this keeps memory bounded, naturally resumes after disconnects, and
/// makes every persisted offset the single source of truth.
@MainActor
public final class MacFileSyncWireController {
    nonisolated public static let bluetoothOfferWindow = 4
    nonisolated public static let bluetoothChunkSize = 8 * 1_024
    nonisolated public static let logicalMessageLimit = 60 * 1_024
    nonisolated public static let localNetworkLogicalMessageLimit = 1 * 1_024 * 1_024

    public let store: MacFileSyncStore

    private struct OutgoingTransferKey: Hashable {
        var transferID: UUID
        var transportProfile: MacFileSyncTransportProfile
    }

    private var incomingMetadata: [UUID: SyncItemMetadata] = [:]
    private var outgoingParameters: [OutgoingTransferKey: SyncTransferParameters] = [:]

    public init(store: MacFileSyncStore) {
        self.store = store
    }

    public func pendingOffers(
        knownTransferIDs: Set<UUID> = [],
        transportProfile: MacFileSyncTransportProfile = .bluetooth
    ) async -> [SyncWireMessage] {
        // A known id means the phone may hold a resumable partial file, not that the item is
        // complete. Re-offer every queued item and put known ids first so the receiver can
        // answer with its durable resume offset after either process reconnects.
        let descriptors = await store.outgoingDescriptors().sorted { lhs, rhs in
            let lhsIsKnown = knownTransferIDs.contains(lhs.transferID)
            let rhsIsKnown = knownTransferIDs.contains(rhs.transferID)
            if lhsIsKnown != rhsIsKnown { return lhsIsKnown }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        // Completion schedules the next window. A directory enumeration must never
        // flood the BLE link that also carries status and control acknowledgements.
        let offeredDescriptors = transportProfile == .bluetooth
            ? Array(descriptors.filter { $0.byteCount <= CompanionFileRouting.bluetoothLimit }.prefix(Self.bluetoothOfferWindow)) : descriptors
        return offeredDescriptors.map { descriptor in
            return .offer(
                SyncOffer(
                    metadata: metadata(from: descriptor),
                    capabilities: transportProfile.capabilities
                )
            )
        }
    }

    public func handle(
        _ message: SyncWireMessage,
        from phoneDeviceID: UUID,
        transportProfile: MacFileSyncTransportProfile = .bluetooth
    ) async -> [SyncWireMessage] {
        do {
            return try await handleValidated(
                message,
                from: phoneDeviceID,
                transportProfile: transportProfile
            )
        } catch {
            return [
                .failure(
                    SyncFailure(
                        transferID: message.transferID,
                        code: failureCode(for: error),
                        message: error.localizedDescription,
                        retryable: isRetryable(error)
                    )
                )
            ]
        }
    }

    private func handleValidated(
        _ message: SyncWireMessage,
        from phoneDeviceID: UUID,
        transportProfile: MacFileSyncTransportProfile
    ) async throws -> [SyncWireMessage] {
        // The phone id is intentionally part of this boundary even though the first release
        // serializes transfers. The BLE peripheral uses it to target every response only to
        // the authenticated central that sent the message.
        _ = phoneDeviceID

        switch message {
        case .requestOffers(let request):
            guard request.requestedDirection == .macToPhone else { return [] }
            return await pendingOffers(
                knownTransferIDs: Set(request.knownTransferIDs),
                transportProfile: transportProfile
            )

        case .offer(let offer):
            let metadata = try offer.metadata.validated()
            guard metadata.direction == .phoneToMac else {
                throw MacFileSyncWireError.invalidDirection
            }
            if transportProfile == .bluetooth && metadata.byteSize > CompanionFileRouting.bluetoothLimit {
                return [.failure(SyncFailure(transferID: metadata.transferID, code: .unavailable,
                    message: "大文件需要 Wi-Fi 高速通道，请更新手机端并开启局域网或个人热点。", retryable: true))]
            }
            let resumeOffset = try await store.prepareIncoming(metadata)
            guard resumeOffset <= metadata.byteSize else {
                throw SyncProtocolError.invalidResumeOffset(resumeOffset)
            }
            incomingMetadata[metadata.transferID] = metadata
            let parameters = negotiatedParameters(
                with: offer.capabilities,
                transportProfile: transportProfile
            )
            return [
                .accept(
                    SyncAcceptance(
                        transferID: metadata.transferID,
                        acceptedRelativePath: metadata.relativePath,
                        resumeOffset: resumeOffset,
                        parameters: parameters
                    )
                )
            ]

        case .accept(let acceptance):
            let descriptor = try await outgoingDescriptor(for: acceptance.transferID)
            guard acceptance.resumeOffset <= descriptor.byteCount else {
                throw SyncProtocolError.invalidResumeOffset(acceptance.resumeOffset)
            }
            outgoingParameters[
                OutgoingTransferKey(
                    transferID: acceptance.transferID,
                    transportProfile: transportProfile
                )
            ] = constrained(
                acceptance.parameters,
                transportProfile: transportProfile
            )
            return [
                try await nextOutgoingMessage(
                    descriptor: descriptor,
                    offset: acceptance.resumeOffset,
                    transportProfile: transportProfile
                )
            ]

        case .resume(let resume):
            let descriptor = try await outgoingDescriptor(for: resume.transferID)
            guard resume.nextOffset <= descriptor.byteCount else {
                throw SyncProtocolError.invalidResumeOffset(resume.nextOffset)
            }
            return [
                try await nextOutgoingMessage(
                    descriptor: descriptor,
                    offset: resume.nextOffset,
                    transportProfile: transportProfile
                )
            ]

        case .chunk(let chunk):
            guard incomingMetadata[chunk.transferID] != nil else {
                throw MacFileSyncWireError.offerRequired
            }
            let nextOffset = try await store.writeIncoming(chunk)
            return [
                .ack(
                    SyncAcknowledgement(
                        transferID: chunk.transferID,
                        nextExpectedOffset: nextOffset,
                        availableWindow: 1
                    )
                )
            ]

        case .ack(let acknowledgement):
            let descriptor = try await outgoingDescriptor(for: acknowledgement.transferID)
            guard acknowledgement.nextExpectedOffset <= descriptor.byteCount else {
                throw SyncProtocolError.acknowledgementOutOfRange(
                    acknowledgement.nextExpectedOffset
                )
            }
            return [
                try await nextOutgoingMessage(
                    descriptor: descriptor,
                    offset: acknowledgement.nextExpectedOffset,
                    transportProfile: transportProfile
                )
            ]

        case .complete(let completion):
            switch completion.stage {
            case .senderFinished:
                guard incomingMetadata[completion.transferID] != nil else {
                    throw MacFileSyncWireError.offerRequired
                }
                let stored = try await store.completeIncoming(completion)
                incomingMetadata[completion.transferID] = nil
                return [.complete(stored)]

            case .receiverStored:
                let descriptor = try await outgoingDescriptor(for: completion.transferID)
                guard completion.totalBytes == descriptor.byteCount,
                      SyncSHA256.constantTimeEqual(completion.sha256, descriptor.sha256) else {
                    throw SyncProtocolError.checksumMismatch(
                        expected: descriptor.sha256,
                        actual: completion.sha256
                    )
                }
                try await store.markOutgoingCompleted(transferID: completion.transferID)
                removeOutgoingParameters(transferID: completion.transferID)
                return []
            }

        case .cancel(let cancellation):
            if incomingMetadata.removeValue(forKey: cancellation.transferID) != nil {
                await store.cancelIncoming(
                    transferID: cancellation.transferID,
                    reason: cancellation.reason
                )
            } else {
                removeOutgoingParameters(transferID: cancellation.transferID)
                await store.markOutgoingFailed(
                    transferID: cancellation.transferID,
                    reason: cancellation.reason
                )
            }
            return []

        case .failure(let failure):
            guard let transferID = failure.transferID else { return [] }
            if incomingMetadata.removeValue(forKey: transferID) != nil {
                await store.cancelIncoming(transferID: transferID, reason: failure.message)
            } else {
                removeOutgoingParameters(transferID: transferID)
                await store.markOutgoingFailed(transferID: transferID, reason: failure.message)
            }
            return []
        }
    }

    private func outgoingDescriptor(for transferID: UUID) async throws -> MacSyncFileDescriptor {
        guard let descriptor = await store.outgoingDescriptors().first(where: {
            $0.transferID == transferID
        }) else {
            throw MacFileSyncError.transferNotFound(transferID)
        }
        return descriptor
    }

    private func nextOutgoingMessage(
        descriptor: MacSyncFileDescriptor,
        offset: UInt64,
        transportProfile: MacFileSyncTransportProfile
    ) async throws -> SyncWireMessage {
        if offset == descriptor.byteCount {
            return .complete(
                SyncCompletion(
                    transferID: descriptor.transferID,
                    totalBytes: descriptor.byteCount,
                    sha256: descriptor.sha256,
                    stage: .senderFinished
                )
            )
        }

        let parameters = outgoingParameters[
            OutgoingTransferKey(
                transferID: descriptor.transferID,
                transportProfile: transportProfile
            )
        ]
            ?? transportProfile.defaultParameters
        let data = try await store.nextOutgoingChunk(
            transferID: descriptor.transferID,
            offset: offset,
            maximumBytes: parameters.chunkSize
        )
        guard !data.isEmpty else {
            throw SyncProtocolError.incompleteTransfer(
                expected: descriptor.byteCount,
                actual: offset
            )
        }
        let nextOffset = offset + UInt64(data.count)
        return .chunk(
            SyncChunk(
                transferID: descriptor.transferID,
                offset: offset,
                data: data,
                isFinal: nextOffset == descriptor.byteCount
            )
        )
    }

    private func metadata(from descriptor: MacSyncFileDescriptor) -> SyncItemMetadata {
        SyncItemMetadata(
            transferID: descriptor.transferID,
            direction: .macToPhone,
            mediaType: Self.mediaType(for: descriptor.relativePath),
            relativePath: descriptor.relativePath,
            byteSize: descriptor.byteCount,
            modifiedAt: descriptor.modifiedAt,
            sha256: descriptor.sha256
        )
    }

    private func negotiatedParameters(
        with remote: SyncTransportCapabilities,
        transportProfile: MacFileSyncTransportProfile
    ) -> SyncTransferParameters {
        SyncTransferParameters(
            maximumFrameSize: min(remote.maximumFrameSize, transportProfile.maximumFrameSize),
            chunkSize: min(remote.preferredChunkSize, transportProfile.preferredChunkSize),
            windowSize: transportProfile.windowSize
        )
    }

    private func constrained(
        _ parameters: SyncTransferParameters,
        transportProfile: MacFileSyncTransportProfile
    ) -> SyncTransferParameters {
        SyncTransferParameters(
            maximumFrameSize: min(parameters.maximumFrameSize, transportProfile.maximumFrameSize),
            chunkSize: min(parameters.chunkSize, transportProfile.preferredChunkSize),
            windowSize: transportProfile.windowSize
        )
    }

    private func removeOutgoingParameters(transferID: UUID) {
        outgoingParameters = outgoingParameters.filter { key, _ in
            key.transferID != transferID
        }
    }

    private func failureCode(for error: Error) -> SyncFailureCode {
        switch error {
        case is SyncPathError:
            .invalidPath
        case SyncProtocolError.itemTooLarge:
            .itemTooLarge
        case SyncProtocolError.checksumMismatch,
             MacFileSyncError.checksumMismatch:
            .checksumMismatch
        case MacFileSyncError.syncDisabled,
             MacFileSyncError.directoryUnavailable:
            .unavailable
        default:
            .io
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        switch error {
        case MacFileSyncError.directoryUnavailable,
             MacFileSyncError.sourceChanged:
            true
        default:
            false
        }
    }

    private static func mediaType(for path: String) -> SyncMediaType {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "dng"].contains(ext) {
            return .image
        }
        if ["mov", "mp4", "m4v", "avi", "hevc"].contains(ext) {
            return .video
        }
        return .file
    }

}

public enum MacFileSyncWireError: LocalizedError, Equatable, Sendable {
    case invalidDirection
    case offerRequired

    public var errorDescription: String? {
        switch self {
        case .invalidDirection:
            "文件同步方向与当前设备不匹配。"
        case .offerRequired:
            "未找到文件传输提议，请重新连接后重试。"
        }
    }
}

extension SyncWireMessage {
    var transferID: UUID? {
        switch self {
        case .requestOffers:
            nil
        case .offer(let value):
            value.metadata.transferID
        case .accept(let value):
            value.transferID
        case .resume(let value):
            value.transferID
        case .chunk(let value):
            value.transferID
        case .ack(let value):
            value.transferID
        case .complete(let value):
            value.transferID
        case .cancel(let value):
            value.transferID
        case .failure(let value):
            value.transferID
        }
    }
}
