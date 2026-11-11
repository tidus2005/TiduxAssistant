import CodexMobilityCore
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class MobilityPhoneSyncStore: ObservableObject {
    @Published public private(set) var transfers: [MobilityPhoneSyncTransfer] = []
    @Published public private(set) var availableMacFiles: [SyncOffer] = []
    @Published public private(set) var pausedLegacyIncomingCount = 0
    private let requiresIncomingApproval: Bool
    private var requestedIncomingIDs: Set<UUID> = []
    private var availableMacRoutes: [UUID: Bool] = [:]
    @Published public private(set) var recentResults: [MobilityPhoneSyncResult] = []
    @Published public private(set) var isConnectionReady = false
    @Published public private(set) var isPeerConnectionReady = false
    @Published public private(set) var isImporting = false
    @Published public private(set) var lastErrorMessage: String?

    /// The app runtime owns BLE framing/encryption and installs this closure after pairing.
    public var sendMessage: ((SyncWireMessage) -> Void)?
    public var sendNetworkMessage: ((SyncWireMessage) -> Bool)?
    public var requestHighSpeedConnection: (() -> Void)?
    public var prepareReceiver: (() async -> Bool)?
    public var usesDualChannelRouting = false
    @Published public private(set) var transferRoutes: [UUID: CompanionFileRoute] = [:]
    @Published public var highSpeedStatus = "等待局域网或手机热点"
    public var hasWaitingLargeFiles: Bool {
        outgoingTransfers.contains { $0.metadata.byteSize > CompanionFileRouting.bluetoothLimit && $0.status == .waitingForConnection }
    }
    public func recoverStalledTransfers(now: Date = Date()) {
        guard usesDualChannelRouting else { return }
        for item in outgoingTransfers where [.negotiating, .transferring, .verifying].contains(item.status) {
            let deadline: TimeInterval = item.status == .verifying ? 120 : 30
            guard now.timeIntervalSince(item.updatedAt) > deadline else { continue }
            sendStates[item.id] = nil
            updateTransfer(item.id) { $0.status = .waitingForConnection }
        }
        retryWaitingTransfers()
    }
    public func retryWaitingTransfers() {
        for transfer in outgoingTransfers where transfer.status == .waitingForConnection || transfer.status == .queued {
            routeOutgoingTransfer(transfer.id)
        }
    }

    /// The Syncthing client installs this closure for authenticated peer messages.
    public var sendPeerMessage: ((SyncthingPeerMessage) -> Bool)?

    public let maximumFileSize: UInt64
    public private(set) var localCapabilities: SyncTransportCapabilities

    public var outgoingTransfers: [MobilityPhoneSyncTransfer] {
        transfers.filter { $0.metadata.direction == .phoneToMac }
    }

    public var incomingTransfers: [MobilityPhoneSyncTransfer] {
        transfers.filter { $0.metadata.direction == .macToPhone }
    }

    public var inboxURL: URL { storage.inboxDirectory }

    private struct PersistedState: Codable {
        var transfers: [MobilityPhoneSyncTransfer]
        var recentResults: [MobilityPhoneSyncResult]
        var requestedIncomingIDs: [UUID]?
    }

    private let storage: MobilityPhoneSyncStorage
    private let photoImporter: any MobilityPhonePhotoImporting
    private var sendStates: [UUID: SyncSendState] = [:]
    private var receiveStates: [UUID: SyncReceiveState] = [:]
    private var finalizingIncoming: Set<UUID> = []
    private var isLegacyConnectionReady = false
    private var syncthingDeviceID = "iphone"
    private var syncthingConnectionGeneration: UInt64 = 0
    private var syncthingCoordinator:
        SyncthingPeerDeltaCoordinator<MobilityPhoneSyncthingAdapter>?
    private var syncthingClaimedOutgoing: Set<UUID> = []
    private var syncthingLegacyFallbacks: Set<UUID> = []
    private var syncthingIncomingTransfers: Set<UUID> = []
    private var syncthingReceivedRequestIDs: Set<UUID> = []
    private var syncthingRemoteIndexes: [String: SyncthingFileIndex] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    public init(
        storageRoot: URL? = nil,
        requiresIncomingApproval: Bool = false,
        inboxDirectory: URL? = nil,
        maximumFileSize: UInt64 = SyncProtocolLimits.maximumItemSize,
        localCapabilities: SyncTransportCapabilities = SyncTransportCapabilities(
            maximumFrameSize: 512,
            preferredChunkSize: 1_024,
            maximumWindowSize: 1
        ),
        photoImporter: (any MobilityPhonePhotoImporting)? = nil
    ) {
        self.requiresIncomingApproval = requiresIncomingApproval
        var startupError: String?
        do {
            if let storageRoot {
                self.storage = try MobilityPhoneSyncStorage(
                    rootDirectory: storageRoot,
                    inboxDirectory: inboxDirectory
                        ?? storageRoot.appendingPathComponent("Codex Sync Inbox", isDirectory: true)
                )
            } else if let inboxDirectory {
                let support = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
                self.storage = try MobilityPhoneSyncStorage(
                    rootDirectory: support
                        .appendingPathComponent("CodexWatchPet", isDirectory: true)
                        .appendingPathComponent("FileSync", isDirectory: true),
                    inboxDirectory: inboxDirectory
                )
            } else {
                self.storage = try .live()
            }
        } catch {
            startupError = error.localizedDescription
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexWatchPet-FileSync-Fallback", isDirectory: true)
            self.storage = try! MobilityPhoneSyncStorage(
                rootDirectory: fallback,
                inboxDirectory: fallback.appendingPathComponent("Codex Sync Inbox", isDirectory: true)
            )
        }
        self.maximumFileSize = min(maximumFileSize, SyncProtocolLimits.maximumItemSize)
        self.localCapabilities = localCapabilities
        self.photoImporter = photoImporter ?? SystemMobilityPhonePhotoImporter()
        restorePersistedState()
        if let startupError {
            lastErrorMessage = MobilityPhoneSyncError.storage(startupError).localizedDescription
        }
    }

    /// Allows the active transport to replace conservative defaults with its live limits.
    public func updateTransportCapabilities(_ capabilities: SyncTransportCapabilities) {
        localCapabilities = capabilities
    }

    public func configureSyncthingDeviceID(_ deviceID: UUID) {
        syncthingDeviceID = deviceID.uuidString.lowercased()
    }

    public func enqueueFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        // Staging remains available offline. The paired Mac prepares its inbox once reachable.
        if isConnectionReady, let prepareReceiver, !(await prepareReceiver()) {
            lastErrorMessage = "Mac 接收目录尚未就绪，请在 Mac 控制台检查文件同步。"
        }

        for url in urls {
            do {
                let transfer = try await prepareOutgoingTransfer(from: url)
                transfers.removeAll { $0.id == transfer.id }
                transfers.insert(transfer, at: 0)
                persist()
                routeOutgoingTransfer(transfer.id)
            } catch {
                record(error)
            }
        }
    }

    /// Called only after either the paired BLE fallback or TLS peer channel is writable.
    public func connectionDidBecomeReady() {
        isLegacyConnectionReady = true
        isConnectionReady = true
        if usesDualChannelRouting { requestMacOffers(); retryWaitingTransfers(); return }
        guard !isPeerConnectionReady else {
            requestMacOffers()
            for transfer in outgoingTransfers
            where (transfer.metadata.byteSize > maximumSyncthingFileSize
                || syncthingLegacyFallbacks.contains(transfer.id))
                && (transfer.status == .queued || transfer.status == .waitingForConnection) {
                offerOutgoing(transfer.id)
            }
            persist()
            return
        }
        sendStates.removeAll(keepingCapacity: true)
        receiveStates.removeAll(keepingCapacity: true)

        for index in transfers.indices where transfers[index].status.isActive {
            transfers[index].status = .waitingForConnection
            transfers[index].updatedAt = .now
        }
        requestMacOffers()
        for transfer in outgoingTransfers where transfer.status != .failed {
            offerOutgoing(transfer.id)
        }
        persist()
    }

    public func connectionDidClose() {
        isLegacyConnectionReady = false
        isConnectionReady = isPeerConnectionReady
        if usesDualChannelRouting {
            for (id, route) in transferRoutes where route == .bluetooth {
                sendStates[id] = nil; receiveStates[id] = nil
                updateTransfer(id) { $0.status = .waitingForConnection }
                transferRoutes[id] = nil
            }
            retryWaitingTransfers(); persist(); return
        }
        guard !isPeerConnectionReady else {
            persist()
            return
        }
        sendStates.removeAll(keepingCapacity: true)
        receiveStates.removeAll(keepingCapacity: true)
        for index in transfers.indices where transfers[index].status.isActive {
            transfers[index].status = .waitingForConnection
            transfers[index].updatedAt = .now
        }
        persist()
    }

    /// Starts a fresh, generation-bound delta coordinator for the authenticated
    /// Syncthing transport. Small queued files are claimed here and are therefore
    /// not offered through the legacy state machine at the same time.
    public func peerConnectionDidBecomeReady() {
        syncthingConnectionGeneration &+= 1
        let generation = syncthingConnectionGeneration
        let adapter = MobilityPhoneSyncthingAdapter(store: self, generation: generation)
        syncthingCoordinator = SyncthingPeerDeltaCoordinator(adapter: adapter)
        syncthingClaimedOutgoing.removeAll(keepingCapacity: true)
        syncthingIncomingTransfers.removeAll(keepingCapacity: true)
        syncthingReceivedRequestIDs.removeAll(keepingCapacity: true)
        syncthingRemoteIndexes.removeAll(keepingCapacity: true)
        isPeerConnectionReady = true
        isConnectionReady = true

        for transfer in outgoingTransfers where transfer.status != .failed {
            routeOutgoingTransfer(transfer.id)
        }
        persist()
    }

    public func peerConnectionDidClose() {
        guard isPeerConnectionReady || syncthingCoordinator != nil else { return }
        syncthingConnectionGeneration &+= 1
        isPeerConnectionReady = false
        syncthingCoordinator = nil
        if usesDualChannelRouting {
            for (id, route) in transferRoutes where route == .localNetwork {
                sendStates[id] = nil; receiveStates[id] = nil
                updateTransfer(id) { $0.status = .waitingForConnection }
                transferRoutes[id] = .waitingForNetwork
            }
        }
        let previouslyClaimed = syncthingClaimedOutgoing
        let previouslyIncoming = syncthingIncomingTransfers
        syncthingClaimedOutgoing.removeAll(keepingCapacity: true)
        syncthingIncomingTransfers.removeAll(keepingCapacity: true)
        syncthingReceivedRequestIDs.removeAll(keepingCapacity: true)
        syncthingRemoteIndexes.removeAll(keepingCapacity: true)
        isConnectionReady = isLegacyConnectionReady

        for transferID in previouslyClaimed {
            updateTransfer(transferID) { transfer in
                if transfer.status.isActive {
                    transfer.status = .waitingForConnection
                }
            }
        }
        for transferID in previouslyIncoming {
            updateTransfer(transferID) { transfer in
                if transfer.status.isActive {
                    transfer.status = .waitingForConnection
                }
            }
        }
        if usesDualChannelRouting { retryWaitingTransfers(); persist(); return }
        if isLegacyConnectionReady {
            sendStates.removeAll(keepingCapacity: true)
            receiveStates.removeAll(keepingCapacity: true)
            requestMacOffers()
            for transfer in outgoingTransfers where transfer.status != .failed {
                offerOutgoing(transfer.id)
            }
        }
        persist()
    }

    /// Handles one authenticated index/block message. Responses are returned to
    /// `MobilitySyncthingClient`, which sends them only on the same connection generation.
    public func receivePeerMessage(
        _ message: SyncthingPeerMessage
    ) async throws -> [SyncthingPeerMessage] {
        guard isPeerConnectionReady, let coordinator = syncthingCoordinator else {
            throw MobilityPhoneSyncthingDeltaError.inactivePeerConnection
        }
        let generation = syncthingConnectionGeneration

        // Older peers can still publish a delta index instead of selectable offers.
        // Do not let that compatibility path bypass explicit incoming-file consent.
        if requiresIncomingApproval {
            let unsolicitedIndexID: UUID?
            switch message {
            case .index(let index): unsolicitedIndexID = index.messageID
            case .indexUpdate(let update): unsolicitedIndexID = update.messageID
            default: unsolicitedIndexID = nil
            }
            if let id = unsolicitedIndexID {
                return [.ack(SyncthingPeerAcknowledgement(
                    acknowledgedMessageID: id,
                    status: .rejected,
                    detail: "requires selected file-backed transfer"
                ))]
            }
        }

        if let oversized = oversizedIncomingIndex(in: message) {
            return [.ack(SyncthingPeerAcknowledgement(
                acknowledgedMessageID: oversized.messageID,
                status: .rejected,
                detail: "requires legacy file-backed transfer"
            ))]
        }

        switch message {
        case .index(let index) where index.entries.count == 1:
            syncthingRemoteIndexes[index.folderID] = index.entries[0]
        case .indexUpdate(let update) where update.entries.count == 1:
            syncthingRemoteIndexes[update.folderID] = update.entries[0]
        default:
            break
        }

        do {
            let responses = try await coordinator.receive(message)
            try requireSyncthingGeneration(generation)
            if case let .blockResponse(response) = message,
               !responses.contains(where: Self.isPeerAcknowledgement) {
                recordSyncthingBlockProgress(response)
            }
            if responses.contains(where: Self.isPeerAcknowledgement) {
                switch message {
                case .index(let index):
                    syncthingRemoteIndexes.removeValue(forKey: index.folderID)
                case .indexUpdate(let update):
                    syncthingRemoteIndexes.removeValue(forKey: update.folderID)
                case .blockResponse(let response):
                    syncthingRemoteIndexes.removeValue(forKey: response.folderID)
                default:
                    break
                }
            }
            return responses
        } catch {
            record(error)
            throw error
        }
    }

    /// Entry point for decoded messages delivered by the paired BLE runtime.
    public func receive(_ message: SyncWireMessage, viaNetwork: Bool = false) {
        if requiresIncomingApproval, case .offer(let offer) = message,
           !requestedIncomingIDs.contains(offer.metadata.transferID) {
            guard (try? offer.metadata.validated()) != nil else { return }
            // Advertisements are choices, not consent to mirror the entire Mac folder.
            if !availableMacFiles.contains(where: { $0.metadata.transferID == offer.metadata.transferID }),
               availableMacFiles.count < 32 {
                availableMacFiles.append(offer)
            }
            if availableMacFiles.contains(where: { $0.metadata.transferID == offer.metadata.transferID }) {
                availableMacRoutes[offer.metadata.transferID] = viaNetwork
            }
            return
        }
        if usesDualChannelRouting, let id = Self.legacyTransferID(in: message) {
            if case .offer(let offer) = message {
                if !viaNetwork && offer.metadata.byteSize > CompanionFileRouting.bluetoothLimit { return }
                transferRoutes[id] = viaNetwork ? .localNetwork : .bluetooth
            } else if let route = transferRoutes[id],
                      (route == .localNetwork && !viaNetwork) || (route == .bluetooth && viaNetwork) {
                return // late acknowledgements from a previous channel cannot advance a new one
            }
        }
        if let transferID = Self.legacyTransferID(in: message),
           syncthingClaimedOutgoing.contains(transferID)
            || syncthingIncomingTransfers.contains(transferID) {
            return
        }
        switch message {
        case .requestOffers(let request):
            receiveOfferRequest(request)
        case .offer(let offer):
            receiveOffer(offer)
        case .accept(let acceptance):
            receiveAcceptance(acceptance)
        case .resume(let resume):
            receiveResume(resume)
        case .chunk(let chunk):
            receiveChunk(chunk)
        case .ack(let acknowledgement):
            receiveAcknowledgement(acknowledgement)
        case .complete(let completion):
            receiveCompletion(completion)
        case .cancel(let cancellation):
            cancelLocally(cancellation.transferID, detail: cancellation.reason, notifyPeer: false)
        case .failure(let failure):
            receiveFailure(failure)
        }
    }

    public func receiveMacFile(_ offer: SyncOffer) {
        let id = offer.metadata.transferID
        guard incomingTransfers.count < 2 else {
            lastErrorMessage = "请等待当前接收完成后再选择文件。"
            return
        }
        requestedIncomingIDs.insert(id)
        let network = availableMacRoutes[id] == true
        availableMacFiles.removeAll { $0.metadata.transferID == id }
        receive(.offer(offer), viaNetwork: network)
        persist()
    }

    public func retry(_ transferID: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        sendStates[transferID] = nil
        receiveStates[transferID] = nil
        transferRoutes[transferID] = nil
        transfers[index].status = .queued
        transfers[index].errorMessage = nil
        transfers[index].updatedAt = .now
        persist()
        guard isConnectionReady else { return }
        if transfers[index].metadata.direction == .phoneToMac {
            routeOutgoingTransfer(transferID)
        } else {
            if !isPeerConnectionReady { requestMacOffers() }
        }
    }

    public func cancel(_ transferID: UUID) {
        cancelLocally(transferID, detail: "已取消", notifyPeer: true)
    }

    public func clearError() {
        lastErrorMessage = nil
    }

    public func reportImportError(_ error: Error) {
        record(error)
    }

    public func clearRecentResults() {
        recentResults.removeAll()
        persist()
    }

    private func prepareOutgoingTransfer(from sourceURL: URL) async throws -> MobilityPhoneSyncTransfer {
        let storage = storage
        let maximumFileSize = maximumFileSize
        return try await Task.detached(priority: .userInitiated) {
            let sourceName = sourceURL.lastPathComponent
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let sourceSize = UInt64(max(try MobilityPhoneSyncStorage.fileSize(at: sourceURL), 0))
            guard sourceSize <= maximumFileSize else {
                throw MobilityPhoneSyncError.fileTooLarge(
                    name: sourceName,
                    size: sourceSize,
                    maximum: maximumFileSize
                )
            }

            let safeName = try MobilityPhoneSyncStorage.safeFileName(sourceName)
            let transferID = UUID()
            let stagedURL = try storage.stage(
                sourceURL: sourceURL,
                transferID: transferID,
                fileName: safeName
            )
            do {
                let size = UInt64(max(try MobilityPhoneSyncStorage.fileSize(at: stagedURL), 0))
                guard size <= maximumFileSize else {
                    throw MobilityPhoneSyncError.fileTooLarge(
                        name: safeName,
                        size: size,
                        maximum: maximumFileSize
                    )
                }
                let digest = try MobilityPhoneSyncStorage.sha256Hex(at: stagedURL)
                let values = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey])
                let metadata = try SyncItemMetadata(
                    transferID: transferID,
                    direction: .phoneToMac,
                    mediaType: Self.mediaType(forFileName: safeName),
                    relativePath: safeName,
                    byteSize: size,
                    modifiedAt: values?.contentModificationDate ?? .now,
                    sha256: digest
                ).validated()
                return MobilityPhoneSyncTransfer(metadata: metadata)
            } catch {
                try? storage.removeStagedFile(at: stagedURL)
                throw error
            }
        }.value
    }

    private nonisolated static func mediaType(forFileName fileName: String) -> SyncMediaType {
        guard
            let pathExtension = fileName.split(separator: ".").last.map(String.init),
            let type = UTType(filenameExtension: pathExtension)
        else {
            return .file
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return .file
    }

    private nonisolated static func isPeerAcknowledgement(
        _ message: SyncthingPeerMessage
    ) -> Bool {
        if case .ack = message { return true }
        return false
    }

    private nonisolated static func legacyTransferID(
        in message: SyncWireMessage
    ) -> UUID? {
        switch message {
        case .requestOffers:
            nil
        case .offer(let offer):
            offer.metadata.transferID
        case .accept(let acceptance):
            acceptance.transferID
        case .resume(let resume):
            resume.transferID
        case .chunk(let chunk):
            chunk.transferID
        case .ack(let acknowledgement):
            acknowledgement.transferID
        case .complete(let completion):
            completion.transferID
        case .cancel(let cancellation):
            cancellation.transferID
        case .failure(let failure):
            failure.transferID
        }
    }

    private var maximumSyncthingFileSize: UInt64 {
        min(maximumFileSize, SyncthingDeltaSession.maximumInMemoryFileSize)
    }

    private func routeOutgoingTransfer(_ transferID: UUID) {
        if usesDualChannelRouting {
            guard let item = transfers.first(where: { $0.id == transferID }),
                  item.status == .queued || item.status == .waitingForConnection else { return }
            let route = CompanionFileRouting.route(byteSize: item.metadata.byteSize,
                bluetoothReady: isLegacyConnectionReady, networkReady: isPeerConnectionReady)
            transferRoutes[transferID] = route
            if route == .waitingForNetwork {
                updateTransfer(transferID) { $0.status = .waitingForConnection }
                if item.metadata.byteSize > CompanionFileRouting.bluetoothLimit { requestHighSpeedConnection?() }
            } else {
                // One file in flight per channel; telemetry and controls retain their own priority.
                guard !outgoingTransfers.contains(where: {
                    $0.id != transferID && transferRoutes[$0.id] == route &&
                    [.negotiating, .transferring, .verifying].contains($0.status)
                }) else { return }
                offerOutgoing(transferID)
            }
            persist()
            return
        }
        guard isConnectionReady,
              let transfer = transfers.first(where: {
                  $0.id == transferID && $0.metadata.direction == .phoneToMac
              }),
              transfer.status != .failed else {
            return
        }
        if isPeerConnectionReady,
           !syncthingLegacyFallbacks.contains(transferID),
           transfer.metadata.byteSize <= maximumSyncthingFileSize,
           transfer.status == .queued || transfer.status == .waitingForConnection {
            publishOutgoingWithSyncthing(transferID)
        } else if isLegacyConnectionReady {
            offerOutgoing(transferID)
        }
    }

    private func publishOutgoingWithSyncthing(_ transferID: UUID) {
        guard isPeerConnectionReady,
              let coordinator = syncthingCoordinator,
              let transfer = transfers.first(where: {
                  $0.id == transferID && $0.metadata.direction == .phoneToMac
              }),
              transfer.metadata.byteSize <= maximumSyncthingFileSize,
              !syncthingLegacyFallbacks.contains(transferID),
              syncthingClaimedOutgoing.insert(transferID).inserted else {
            return
        }

        let generation = syncthingConnectionGeneration
        let metadata = transfer.metadata
        let storage = storage
        let deviceID = syncthingDeviceID
        updateTransfer(transferID) { transfer in
            transfer.status = .negotiating
            transfer.errorMessage = nil
        }
        persist()

        Task { [weak self] in
            guard let self else { return }
            do {
                let index = try await Task.detached(priority: .userInitiated) {
                    try storage.makeOutgoingSyncthingIndex(
                        metadata: metadata,
                        deviceID: deviceID
                    )
                }.value
                try self.requireSyncthingGeneration(generation)
                let message = try await coordinator.publish(
                    folderID: SyncthingTransferFolderID.make(transferID: transferID),
                    index: index
                )
                try self.requireSyncthingGeneration(generation)
                guard self.sendPeerMessage?(message) == true else {
                    throw MobilityPhoneSyncthingDeltaError.peerMessageSendFailed
                }
                self.updateTransfer(transferID) { transfer in
                    transfer.status = .transferring
                    transfer.negotiatedChunkSize = SyncthingBlockSizePolicy.blockSize(
                        forByteSize: transfer.metadata.byteSize
                    )
                }
                self.persist()
            } catch {
                self.handleSyncthingPublicationFailure(
                    transferID: transferID,
                    generation: generation,
                    error: error
                )
            }
        }
    }

    private func handleSyncthingPublicationFailure(
        transferID: UUID,
        generation: UInt64,
        error: Error
    ) {
        guard generation == syncthingConnectionGeneration else { return }
        syncthingClaimedOutgoing.remove(transferID)
        if error as? MobilityPhoneSyncthingDeltaError == .peerMessageSendFailed
            || error as? MobilityPhoneSyncthingDeltaError == .staleConnectionGeneration {
            updateTransfer(transferID) { transfer in
                transfer.status = .waitingForConnection
                transfer.errorMessage = error.localizedDescription
            }
            persist()
            return
        }
        failTransfer(transferID, error: error, notifyPeer: false)
    }

    private func oversizedIncomingIndex(
        in message: SyncthingPeerMessage
    ) -> (messageID: UUID, size: UInt64)? {
        let messageID: UUID
        let entries: [SyncthingFileIndex]
        switch message {
        case .index(let index):
            messageID = index.messageID
            entries = index.entries
        case .indexUpdate(let update):
            messageID = update.messageID
            entries = update.entries
        default:
            return nil
        }
        guard let size = entries.map(\.size).max(), size > maximumSyncthingFileSize else {
            return nil
        }
        return (messageID, size)
    }

    private func requireSyncthingGeneration(_ generation: UInt64) throws {
        guard isPeerConnectionReady else {
            throw MobilityPhoneSyncthingDeltaError.inactivePeerConnection
        }
        guard generation == syncthingConnectionGeneration else {
            throw MobilityPhoneSyncthingDeltaError.staleConnectionGeneration
        }
    }

    private func transferID(from folderID: String) throws -> UUID {
        guard let transferID = SyncthingTransferFolderID.transferID(from: folderID) else {
            throw MobilityPhoneSyncthingDeltaError.invalidTransferFolderID(folderID)
        }
        return transferID
    }

    private func recordSyncthingBlockProgress(_ response: SyncthingPeerBlockResponse) {
        guard let transferID = SyncthingTransferFolderID.transferID(from: response.folderID),
              syncthingReceivedRequestIDs.insert(response.requestID).inserted else {
            return
        }
        updateTransfer(transferID) { transfer in
            transfer.confirmedBytes = min(
                transfer.metadata.byteSize,
                transfer.confirmedBytes + UInt64(response.data.count)
            )
            transfer.status = .transferring
        }
        persist()
    }

    private func requestMacOffers() {
        guard isLegacyConnectionReady else { return }
        let knownTransferIDs = incomingTransfers.map(\.id)
        emit(.requestOffers(SyncOfferRequest(
            requestedDirection: .macToPhone,
            knownTransferIDs: knownTransferIDs
        )))
    }

    private func receiveOfferRequest(_ request: SyncOfferRequest) {
        guard request.requestedDirection == .phoneToMac else { return }
        for transfer in outgoingTransfers where transfer.status != .failed {
            offerOutgoing(transfer.id)
        }
    }

    private func offerOutgoing(_ transferID: UUID) {
        guard
            (isLegacyConnectionReady || (usesDualChannelRouting && isPeerConnectionReady)),
            !syncthingClaimedOutgoing.contains(transferID),
            let index = transfers.firstIndex(where: {
                $0.id == transferID && $0.metadata.direction == .phoneToMac
            })
        else { return }

        if usesDualChannelRouting, sendStates[transferID] != nil { return }
        if usesDualChannelRouting, transferRoutes[transferID] == nil || transferRoutes[transferID] == .waitingForNetwork {
            routeOutgoingTransfer(transferID)
            return
        }
        do {
            let fileURL = try storage.stagedURL(
                transferID: transferID,
                fileName: transfers[index].fileName
            )
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw MobilityPhoneSyncError.fileUnavailable(name: transfers[index].fileName)
            }
            transfers[index].status = .negotiating
            transfers[index].errorMessage = nil
            transfers[index].updatedAt = .now
            emit(.offer(SyncOffer(
                metadata: transfers[index].metadata,
                capabilities: usesDualChannelRouting && transferRoutes[transferID] == .localNetwork
                    ? SyncTransportCapabilities(maximumFrameSize: 1_048_576, preferredChunkSize: 65_536, maximumWindowSize: 1)
                    : localCapabilities
            )))
            persist()
        } catch {
            failTransfer(transferID, error: error, notifyPeer: false)
        }
    }

    private func receiveOffer(_ offer: SyncOffer) {
        do {
            let metadata = try offer.metadata.validated()
            if usesDualChannelRouting, receiveStates[metadata.transferID] != nil { return }
            if !usesDualChannelRouting, isPeerConnectionReady, metadata.byteSize <= maximumSyncthingFileSize {
                return
            }
            guard !syncthingIncomingTransfers.contains(metadata.transferID) else {
                throw MobilityPhoneSyncthingDeltaError.transferNotClaimed(metadata.transferID)
            }
            guard metadata.direction == .macToPhone else {
                throw MobilityPhoneSyncError.invalidDirection
            }
            guard metadata.byteSize <= maximumFileSize else {
                throw MobilityPhoneSyncError.fileTooLarge(
                    name: SyncRelativePath.fileName(in: metadata.relativePath),
                    size: metadata.byteSize,
                    maximum: maximumFileSize
                )
            }

            let parameters = try SyncBLETransferTuning.negotiate(
                local: usesDualChannelRouting && transferRoutes[metadata.transferID] == .localNetwork
                    ? SyncTransportCapabilities(maximumFrameSize: 1_048_576, preferredChunkSize: 65_536, maximumWindowSize: 1)
                    : localCapabilities,
                remote: offer.capabilities
            )
            let index: Int
            if let existing = transfers.firstIndex(where: { $0.id == metadata.transferID }) {
                if transfers[existing].metadata.sha256 != metadata.sha256
                    || transfers[existing].metadata.byteSize != metadata.byteSize {
                    try? storage.removeIncomingPartial(transferID: metadata.transferID)
                    transfers[existing] = MobilityPhoneSyncTransfer(metadata: metadata)
                } else {
                    transfers[existing].metadata = metadata
                }
                index = existing
            } else {
                transfers.insert(MobilityPhoneSyncTransfer(metadata: metadata), at: 0)
                index = 0
            }

            try storage.prepareIncomingPartial(transferID: metadata.transferID)
            var resumeOffset = UInt64(max(try storage.partialSize(for: metadata.transferID), 0))
            if resumeOffset > metadata.byteSize {
                try storage.removeIncomingPartial(transferID: metadata.transferID)
                try storage.prepareIncomingPartial(transferID: metadata.transferID)
                resumeOffset = 0
            }
            let state = try SyncReceiveState(
                metadata: metadata,
                parameters: parameters,
                resumeOffset: resumeOffset
            )
            receiveStates[metadata.transferID] = state
            transfers[index].confirmedBytes = resumeOffset
            transfers[index].negotiatedChunkSize = parameters.chunkSize
            transfers[index].status = resumeOffset == metadata.byteSize ? .verifying : .transferring
            transfers[index].errorMessage = nil
            transfers[index].updatedAt = .now
            persist()
            emit(.accept(SyncAcceptance(
                transferID: metadata.transferID,
                acceptedRelativePath: SyncRelativePath.fileName(in: metadata.relativePath),
                resumeOffset: resumeOffset,
                parameters: parameters
            )))
        } catch {
            let transferID = offer.metadata.transferID
            record(error)
            emit(.failure(SyncFailure(
                transferID: transferID,
                code: failureCode(for: error),
                message: error.localizedDescription,
                retryable: false
            )))
        }
    }

    private func receiveAcceptance(_ acceptance: SyncAcceptance) {
        guard !syncthingClaimedOutgoing.contains(acceptance.transferID) else { return }
        guard
            let index = transfers.firstIndex(where: {
                $0.id == acceptance.transferID && $0.metadata.direction == .phoneToMac
            })
        else {
            emitUnknownTransfer(acceptance.transferID)
            return
        }
        do {
            let state = try SyncSendState(
                metadata: transfers[index].metadata,
                parameters: acceptance.parameters,
                resumeOffset: acceptance.resumeOffset
            )
            sendStates[acceptance.transferID] = state
            transfers[index].confirmedBytes = acceptance.resumeOffset
            transfers[index].negotiatedChunkSize = acceptance.parameters.chunkSize
            transfers[index].status = acceptance.resumeOffset == transfers[index].metadata.byteSize
                ? .verifying
                : .transferring
            transfers[index].errorMessage = nil
            transfers[index].updatedAt = .now
            persist()
            pumpOutgoing(acceptance.transferID)
        } catch {
            failTransfer(acceptance.transferID, error: error, notifyPeer: true)
        }
    }

    private func receiveResume(_ resume: SyncResume) {
        var state: SyncSendState
        if let existingState = sendStates[resume.transferID] {
            state = existingState
        } else {
            guard
                let transfer = transfers.first(where: {
                    $0.id == resume.transferID && $0.metadata.direction == .phoneToMac
                })
            else {
                emitUnknownTransfer(resume.transferID)
                return
            }
            let parameters = SyncTransferParameters(
                maximumFrameSize: localCapabilities.maximumFrameSize,
                chunkSize: localCapabilities.preferredChunkSize,
                windowSize: 1
            )
            do {
                state = try SyncSendState(
                    metadata: transfer.metadata,
                    parameters: parameters,
                    resumeOffset: resume.nextOffset
                )
            } catch {
                failTransfer(resume.transferID, error: error, notifyPeer: true)
                return
            }
        }

        do {
            try state.resume(at: resume.nextOffset)
            sendStates[resume.transferID] = state
            updateTransfer(resume.transferID) { transfer in
                transfer.confirmedBytes = resume.nextOffset
                transfer.status = resume.nextOffset == transfer.metadata.byteSize
                    ? .verifying
                    : .transferring
            }
            persist()
            pumpOutgoing(resume.transferID)
        } catch {
            failTransfer(resume.transferID, error: error, notifyPeer: true)
        }
    }

    private func pumpOutgoing(_ transferID: UUID) {
        guard var state = sendStates[transferID] else { return }
        do {
            if state.metadata.byteSize == 0 || state.acknowledgedOffset == state.metadata.byteSize {
                emit(.complete(try state.senderFinishedMessage()))
                updateTransfer(transferID) { $0.status = .verifying }
                return
            }

            while state.isReadyToSend {
                let data = try storage.readOutgoingChunk(
                    transferID: transferID,
                    fileName: SyncRelativePath.fileName(in: state.metadata.relativePath),
                    offset: state.nextOffset,
                    maximumLength: state.parameters.chunkSize
                )
                let chunk = try state.makeChunk(data)
                guard emit(.chunk(chunk)) else { return }
            }
            sendStates[transferID] = state
            updateTransfer(transferID) { transfer in
                transfer.status = state.phase == .verifying ? .verifying : .transferring
                transfer.updatedAt = .now
            }
        } catch {
            failTransfer(transferID, error: error, notifyPeer: true)
        }
    }

    private func receiveAcknowledgement(_ acknowledgement: SyncAcknowledgement) {
        guard var state = sendStates[acknowledgement.transferID] else {
            emitUnknownTransfer(acknowledgement.transferID)
            return
        }
        do {
            try state.acknowledge(acknowledgement)
            sendStates[acknowledgement.transferID] = state
            updateTransfer(acknowledgement.transferID) { transfer in
                transfer.confirmedBytes = acknowledgement.nextExpectedOffset
                transfer.status = acknowledgement.nextExpectedOffset == transfer.metadata.byteSize
                    ? .verifying
                    : .transferring
            }
            persist()
            pumpOutgoing(acknowledgement.transferID)
        } catch {
            failTransfer(acknowledgement.transferID, error: error, notifyPeer: true)
        }
    }

    private func receiveChunk(_ chunk: SyncChunk) {
        guard var state = receiveStates[chunk.transferID] else {
            emitUnknownTransfer(chunk.transferID)
            return
        }
        do {
            let progress = try state.receive(chunk)
            if progress.shouldWrite {
                _ = try storage.writeIncomingChunk(
                    chunk.data,
                    transferID: chunk.transferID,
                    offset: Int64(chunk.offset)
                )
            } else if progress.isDuplicate {
                guard try storage.incomingChunkMatches(
                    chunk.data,
                    transferID: chunk.transferID,
                    offset: chunk.offset
                ) else {
                    throw SyncProtocolError.checksumMismatch(
                        expected: chunk.checksumSHA256,
                        actual: "stored bytes differ"
                    )
                }
            }
            receiveStates[chunk.transferID] = state
            updateTransfer(chunk.transferID) { transfer in
                transfer.confirmedBytes = progress.acknowledgement.nextExpectedOffset
                transfer.status = state.phase == .verifying ? .verifying : .transferring
            }
            persist()
            emit(.ack(progress.acknowledgement))
        } catch {
            failTransfer(chunk.transferID, error: error, notifyPeer: true)
        }
    }

    private func receiveCompletion(_ completion: SyncCompletion) {
        guard let transfer = transfers.first(where: { $0.id == completion.transferID }) else {
            emitUnknownTransfer(completion.transferID)
            return
        }
        switch (transfer.metadata.direction, completion.stage) {
        case (.macToPhone, .senderFinished):
            guard finalizingIncoming.insert(completion.transferID).inserted else { return }
            updateTransfer(completion.transferID) { $0.status = .verifying }
            persist()
            Task { [weak self] in
                await self?.verifyAndCommitIncoming(completion)
            }
        case (.phoneToMac, .receiverStored):
            finishOutgoing(completion)
        default:
            failTransfer(
                completion.transferID,
                error: SyncProtocolError.invalidCompletionStage(completion.stage),
                notifyPeer: true
            )
        }
    }

    private func verifyAndCommitIncoming(_ completion: SyncCompletion) async {
        defer { finalizingIncoming.remove(completion.transferID) }
        guard
            var state = receiveStates[completion.transferID],
            let transfer = transfers.first(where: { $0.id == completion.transferID })
        else { return }

        do {
            let partialURL = storage.partialURL(for: completion.transferID)
            let digest = try await Task.detached(priority: .userInitiated) {
                try MobilityPhoneSyncStorage.sha256Hex(at: partialURL)
            }.value
            // Pick the conflict-free destination first, validate every sender declaration and
            // both hashes while the bytes are still a private partial, then expose the file.
            let finalURL = try storage.finalizedInboxURL(fileName: transfer.fileName)
            let stored = try state.finalize(
                completion,
                calculatedSHA256: digest,
                storedRelativePath: finalURL.lastPathComponent
            )
            try storage.commitIncoming(transferID: completion.transferID, to: finalURL)
            receiveStates[completion.transferID] = state
            emit(.complete(stored))
            transfers.removeAll { $0.id == completion.transferID }
            sendStates[completion.transferID] = nil
            transferRoutes[completion.transferID] = nil
            if usesDualChannelRouting { Task { self.retryWaitingTransfers() } }
            addResult(MobilityPhoneSyncResult(
                id: completion.transferID,
                direction: .macToPhone,
                fileName: finalURL.lastPathComponent,
                byteSize: transfer.metadata.byteSize,
                status: .completed,
                detail: transfer.metadata.mediaType == .file
                    ? "已保存到“文件”App / Codex Sync Inbox"
                    : "已保存到“文件”App，正在添加到照片",
                localURL: finalURL
            ))
            persist()

            if transfer.metadata.mediaType == .image || transfer.metadata.mediaType == .video {
                await addIncomingMediaToPhotoLibrary(
                    transferID: completion.transferID,
                    fileURL: finalURL,
                    mediaType: transfer.metadata.mediaType
                )
            }
        } catch {
            try? storage.removeIncomingPartial(transferID: completion.transferID)
            receiveStates[completion.transferID]?.fail()
            failTransfer(completion.transferID, error: error, notifyPeer: true)
        }
    }

    private func addIncomingMediaToPhotoLibrary(
        transferID: UUID,
        fileURL: URL,
        mediaType: SyncMediaType
    ) async {
        do {
            try await photoImporter.addToPhotoLibrary(fileURL: fileURL, mediaType: mediaType)
            updateResult(transferID) { result in
                result.status = .completed
                result.detail = "已保存到“文件”App，并添加到照片"
            }
        } catch {
            updateResult(transferID) { result in
                result.status = .completedWithWarning
                result.detail = error.localizedDescription
            }
        }
        persist()
    }

    private func finishOutgoing(_ completion: SyncCompletion) {
        guard
            var state = sendStates[completion.transferID],
            let transfer = transfers.first(where: { $0.id == completion.transferID })
        else {
            emitUnknownTransfer(completion.transferID)
            return
        }
        do {
            try state.markReceiverStored(completion)
            sendStates[completion.transferID] = state
            if let stagedURL = try? storage.stagedURL(
                transferID: completion.transferID,
                fileName: transfer.fileName
            ) {
                try? storage.removeStagedFile(at: stagedURL)
            }
            transfers.removeAll { $0.id == completion.transferID }
            sendStates[completion.transferID] = nil
            transferRoutes[completion.transferID] = nil
            if usesDualChannelRouting { Task { self.retryWaitingTransfers() } }
            addResult(MobilityPhoneSyncResult(
                id: completion.transferID,
                direction: .phoneToMac,
                fileName: transfer.fileName,
                byteSize: transfer.metadata.byteSize,
                status: .completed,
                detail: completion.storedRelativePath.map { "Mac 已保存到 \($0)" } ?? "Mac 已校验并保存"
            ))
            persist()
        } catch {
            failTransfer(completion.transferID, error: error, notifyPeer: true)
        }
    }

    private func receiveFailure(_ failure: SyncFailure) {
        let message = failure.message.isEmpty ? "对端报告同步失败" : failure.message
        lastErrorMessage = message
        guard let transferID = failure.transferID else { return }
        updateTransfer(transferID) { transfer in
            transfer.status = failure.retryable ? .waitingForConnection : .failed
            transfer.errorMessage = message
        }
        persist()
    }

    func syncthingLocalIndex(
        folderID: String,
        relativePath: String,
        generation: UInt64
    ) async throws -> SyncthingFileIndex? {
        try requireSyncthingGeneration(generation)
        _ = try transferID(from: folderID)
        let storage = storage
        let deviceID = syncthingDeviceID
        let index = try await Task.detached(priority: .utility) {
            try storage.localSyncthingIndex(
                relativePath: relativePath,
                deviceID: deviceID
            )
        }.value
        try requireSyncthingGeneration(generation)
        if let index,
           let remoteIndex = syncthingRemoteIndexes[folderID],
           let localHash = index.wholeFileSHA256,
           let remoteHash = remoteIndex.wholeFileSHA256,
           SyncSHA256.constantTimeEqual(localHash, remoteHash) {
            // Returning the exact remote vector makes reconnect idempotent: the
            // coordinator emits an immediate ACK and creates no conflict copy.
            return remoteIndex
        }
        return index
    }

    func syncthingReusableBlockData(
        folderID: String,
        remoteIndex: SyncthingFileIndex,
        generation: UInt64
    ) async throws -> [Data] {
        try requireSyncthingGeneration(generation)
        let transferID = try transferID(from: folderID)
        guard remoteIndex.size <= maximumSyncthingFileSize else {
            throw MobilityPhoneSyncError.fileTooLarge(
                name: SyncRelativePath.fileName(in: remoteIndex.relativePath),
                size: remoteIndex.size,
                maximum: maximumSyncthingFileSize
            )
        }

        let metadata = try SyncItemMetadata(
            transferID: transferID,
            direction: .macToPhone,
            mediaType: Self.mediaType(forFileName: remoteIndex.relativePath),
            relativePath: remoteIndex.relativePath,
            byteSize: remoteIndex.size,
            modifiedAt: remoteIndex.modifiedAt,
            sha256: remoteIndex.wholeFileSHA256 ?? SyncSHA256.hexDigest(Data())
        ).validated()
        if let existing = transfers.firstIndex(where: { $0.id == transferID }) {
            guard transfers[existing].metadata.direction == .macToPhone else {
                throw MobilityPhoneSyncError.invalidDirection
            }
            transfers[existing].metadata = metadata
            transfers[existing].status = .transferring
            transfers[existing].errorMessage = nil
            transfers[existing].updatedAt = .now
        } else {
            transfers.insert(MobilityPhoneSyncTransfer(
                metadata: metadata,
                status: .transferring
            ), at: 0)
        }
        syncthingIncomingTransfers.insert(transferID)

        let storage = storage
        let reusable = try await Task.detached(priority: .utility) {
            try storage.reusableSyncthingBlockData(
                transferID: transferID,
                remoteIndex: remoteIndex
            )
        }.value
        try requireSyncthingGeneration(generation)

        let availableHashes = Set(reusable.map(SyncSHA256.hexDigest))
        let reusedByteCount = remoteIndex.blocks.reduce(into: UInt64(0)) { count, block in
            if availableHashes.contains(block.sha256) {
                count += UInt64(block.size)
            }
        }
        updateTransfer(transferID) { transfer in
            transfer.confirmedBytes = min(reusedByteCount, transfer.metadata.byteSize)
        }
        persist()
        return reusable
    }

    func syncthingReadBlock(
        folderID: String,
        index: SyncthingFileIndex,
        block: SyncthingBlockRequest,
        generation: UInt64
    ) async throws -> Data {
        try requireSyncthingGeneration(generation)
        let transferID = try transferID(from: folderID)
        guard syncthingClaimedOutgoing.contains(transferID) else {
            throw MobilityPhoneSyncthingDeltaError.transferNotClaimed(transferID)
        }
        guard let transfer = transfers.first(where: {
            $0.id == transferID && $0.metadata.direction == .phoneToMac
        }) else {
            throw MobilityPhoneSyncthingDeltaError.unknownTransfer(transferID)
        }
        guard index.relativePath == transfer.metadata.relativePath,
              index.size == transfer.metadata.byteSize,
              index.wholeFileSHA256.map({
                  SyncSHA256.constantTimeEqual($0, transfer.metadata.sha256)
              }) == true else {
            throw MobilityPhoneSyncError.checksumMismatch(name: transfer.fileName)
        }

        let storage = storage
        let fileName = transfer.fileName
        let data = try await Task.detached(priority: .userInitiated) {
            try storage.readOutgoingSyncthingBlock(
                transferID: transferID,
                fileName: fileName,
                block: block
            )
        }.value
        try requireSyncthingGeneration(generation)
        return data
    }

    func syncthingCommit(
        _ commit: SyncthingPeerDeltaCommit,
        folderID: String,
        generation: UInt64
    ) async throws {
        try requireSyncthingGeneration(generation)
        let transferID = try transferID(from: folderID)

        switch commit {
        case .deletion(let deletion):
            try storage.commitSyncthingDeletion(deletion)
            try? storage.removeIncomingPartial(transferID: transferID)
            syncthingIncomingTransfers.remove(transferID)
            syncthingRemoteIndexes.removeValue(forKey: folderID)
            transfers.removeAll { $0.id == transferID && $0.metadata.direction == .macToPhone }
            persist()

        case .file(let fileCommit):
            updateTransfer(transferID) { transfer in
                transfer.status = .verifying
                transfer.confirmedBytes = transfer.metadata.byteSize
            }
            persist()

            // The image has already passed block and whole-file verification. Expose it in
            // Files before ACK; Photos remains a best-effort follow-up and never delays ACK.
            let finalURL = try storage.commitSyncthingFile(fileCommit)
            try? storage.removeIncomingPartial(transferID: transferID)
            let mediaType = Self.mediaType(forFileName: finalURL.lastPathComponent)
            let byteSize = fileCommit.remoteIndex.size
            transfers.removeAll { $0.id == transferID }
        transferRoutes[transferID] = nil
        if usesDualChannelRouting { Task { self.retryWaitingTransfers() } }
            syncthingIncomingTransfers.remove(transferID)
            syncthingRemoteIndexes.removeValue(forKey: folderID)
            addResult(MobilityPhoneSyncResult(
                id: transferID,
                direction: .macToPhone,
                fileName: finalURL.lastPathComponent,
                byteSize: byteSize,
                status: .completed,
                detail: mediaType == .file
                    ? "已保存到“文件”App / Codex Sync Inbox"
                    : "已保存到“文件”App，正在添加到照片",
                localURL: finalURL
            ))
            persist()

            if mediaType == .image || mediaType == .video {
                Task { [weak self] in
                    await self?.addIncomingMediaToPhotoLibrary(
                        transferID: transferID,
                        fileURL: finalURL,
                        mediaType: mediaType
                    )
                }
            }
        }
    }

    func syncthingOutgoingTransferDidFinish(
        folderID: String,
        index: SyncthingFileIndex,
        acknowledgement: SyncthingPeerAcknowledgement,
        generation: UInt64
    ) async throws {
        try requireSyncthingGeneration(generation)
        let transferID = try transferID(from: folderID)
        guard syncthingClaimedOutgoing.contains(transferID) else {
            throw MobilityPhoneSyncthingDeltaError.transferNotClaimed(transferID)
        }
        guard let transfer = transfers.first(where: {
            $0.id == transferID && $0.metadata.direction == .phoneToMac
        }) else {
            throw MobilityPhoneSyncthingDeltaError.unknownTransfer(transferID)
        }
        guard index.wholeFileSHA256.map({
            SyncSHA256.constantTimeEqual($0, transfer.metadata.sha256)
        }) == true else {
            throw MobilityPhoneSyncError.checksumMismatch(name: transfer.fileName)
        }

        syncthingClaimedOutgoing.remove(transferID)
        if acknowledgement.status == .rejected {
            syncthingLegacyFallbacks.insert(transferID)
            updateTransfer(transferID) { transfer in
                transfer.status = .waitingForConnection
                transfer.errorMessage = acknowledgement.detail
            }
            persist()
            if isConnectionReady { offerOutgoing(transferID) }
            return
        }

        syncthingLegacyFallbacks.remove(transferID)

        if let stagedURL = try? storage.stagedURL(
            transferID: transferID,
            fileName: transfer.fileName
        ) {
            try? storage.removeStagedFile(at: stagedURL)
        }
        transfers.removeAll { $0.id == transferID }
        transferRoutes[transferID] = nil
        if usesDualChannelRouting { Task { self.retryWaitingTransfers() } }
        addResult(MobilityPhoneSyncResult(
            id: transferID,
            direction: .phoneToMac,
            fileName: transfer.fileName,
            byteSize: transfer.metadata.byteSize,
            status: .completed,
            detail: "Mac 已校验并保存（Syncthing 增量同步）"
        ))
        persist()
    }

    private func cancelLocally(_ transferID: UUID, detail: String, notifyPeer: Bool) {
        guard let transfer = transfers.first(where: { $0.id == transferID }) else { return }
        if transfer.metadata.direction == .phoneToMac,
           let stagedURL = try? storage.stagedURL(
               transferID: transferID,
               fileName: transfer.fileName
           ) {
            try? storage.removeStagedFile(at: stagedURL)
        } else {
            try? storage.removeIncomingPartial(transferID: transferID)
        }
        sendStates[transferID]?.cancel()
        receiveStates[transferID]?.cancel()
        sendStates[transferID] = nil
        receiveStates[transferID] = nil
        syncthingClaimedOutgoing.remove(transferID)
        syncthingLegacyFallbacks.remove(transferID)
        syncthingIncomingTransfers.remove(transferID)
        transfers.removeAll { $0.id == transferID }
        if usesDualChannelRouting { Task { self.retryWaitingTransfers() } }
        addResult(MobilityPhoneSyncResult(
            id: transferID,
            direction: transfer.metadata.direction,
            fileName: transfer.fileName,
            byteSize: transfer.metadata.byteSize,
            status: .cancelled,
            detail: detail
        ))
        if notifyPeer, isConnectionReady {
            emit(.cancel(SyncCancellation(transferID: transferID, reason: detail)))
        }
        transferRoutes[transferID] = nil
        persist()
    }

    private func failTransfer(_ transferID: UUID, error: Error, notifyPeer: Bool) {
        let message = error.localizedDescription
        sendStates[transferID]?.fail()
        receiveStates[transferID]?.fail()
        updateTransfer(transferID) { transfer in
            transfer.status = .failed
            transfer.errorMessage = message
        }
        lastErrorMessage = message
        if notifyPeer, isConnectionReady {
            emit(.failure(SyncFailure(
                transferID: transferID,
                code: failureCode(for: error),
                message: message,
                retryable: true
            )))
        }
        persist()
        if usesDualChannelRouting { Task { self.retryWaitingTransfers() } }
    }

    private func emitUnknownTransfer(_ transferID: UUID) {
        let error = MobilityPhoneSyncError.unknownTransfer(transferID)
        record(error)
        emit(.failure(SyncFailure(
            transferID: transferID,
            code: .protocolViolation,
            message: error.localizedDescription,
            retryable: true
        )))
    }

    private func failureCode(for error: Error) -> SyncFailureCode {
        if let error = error as? MobilityPhoneSyncError {
            switch error {
            case .fileTooLarge: .itemTooLarge
            case .photoLibraryDenied: .permissionDenied
            case .invalidDirection, .invalidOffset, .unknownTransfer: .protocolViolation
            case .checksumMismatch: .checksumMismatch
            case .fileUnavailable, .photoImportFailed, .storage: .io
            }
        } else if let error = error as? SyncPathError {
            switch error {
            case .noAvailableConflictName: .conflict
            default: .invalidPath
            }
        } else if let error = error as? SyncProtocolError {
            switch error {
            case .itemTooLarge: .itemTooLarge
            case .checksumMismatch, .invalidSHA256: .checksumMismatch
            default: .protocolViolation
            }
        } else {
            .io
        }
    }

    @discardableResult
    private func emit(_ message: SyncWireMessage) -> Bool {
        if usesDualChannelRouting, let id = Self.legacyTransferID(in: message), transferRoutes[id] == .localNetwork {
            if sendNetworkMessage?(message) != true {
                sendStates[id] = nil; receiveStates[id] = nil
                updateTransfer(id) { $0.status = .waitingForConnection }
                transferRoutes[id] = .waitingForNetwork
                requestHighSpeedConnection?()
                return false
            }
        } else {
            guard let sendMessage else { return false }
            sendMessage(message)
        }
        return true
    }

    private func updateTransfer(
        _ transferID: UUID,
        mutation: (inout MobilityPhoneSyncTransfer) -> Void
    ) {
        guard let index = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        mutation(&transfers[index])
        transfers[index].updatedAt = .now
    }

    private func addResult(_ result: MobilityPhoneSyncResult) {
        recentResults.removeAll { $0.id == result.id }
        recentResults.insert(result, at: 0)
        if recentResults.count > 30 {
            recentResults.removeLast(recentResults.count - 30)
        }
    }

    private func updateResult(
        _ transferID: UUID,
        mutation: (inout MobilityPhoneSyncResult) -> Void
    ) {
        guard let index = recentResults.firstIndex(where: { $0.id == transferID }) else { return }
        mutation(&recentResults[index])
    }

    private func record(_ error: Error) {
        lastErrorMessage = error.localizedDescription
    }

    private func persist() {
        do {
            let data = try encoder.encode(PersistedState(
                transfers: transfers,
                recentResults: recentResults,
                requestedIncomingIDs: Array(requestedIncomingIDs)
            ))
            try data.write(to: storage.stateURL, options: .atomic)
        } catch {
            lastErrorMessage = MobilityPhoneSyncError.storage(error.localizedDescription).localizedDescription
        }
    }

    private func restorePersistedState() {
        guard let data = try? Data(contentsOf: storage.stateURL) else { return }
        do {
            let persisted = try decoder.decode(PersistedState.self, from: data)
            requestedIncomingIDs = Set(persisted.requestedIncomingIDs ?? [])
            if requiresIncomingApproval {
                pausedLegacyIncomingCount = persisted.transfers.filter {
                    $0.metadata.direction == .macToPhone && !requestedIncomingIDs.contains($0.id)
                }.count
                if pausedLegacyIncomingCount > 0 {
                    let archive = storage.rootDirectory.appendingPathComponent("legacy-auto-receive-\(UUID().uuidString).json")
                    try data.write(to: archive, options: .atomic)
                }
            }
            transfers = persisted.transfers.compactMap { transfer in
                if requiresIncomingApproval, transfer.metadata.direction == .macToPhone,
                   !requestedIncomingIDs.contains(transfer.id) { return nil }
                var transfer = transfer
                transfer.status = transfer.status == .failed ? .failed : .waitingForConnection
                transfer.updatedAt = .now
                if transfer.metadata.direction == .macToPhone {
                    let actual = UInt64(max(
                        (try? storage.partialSize(for: transfer.id)) ?? 0,
                        0
                    ))
                    if actual > transfer.metadata.byteSize {
                        try? storage.removeIncomingPartial(transferID: transfer.id)
                        transfer.confirmedBytes = 0
                    } else {
                        transfer.confirmedBytes = actual
                    }
                    return transfer
                }
                guard
                    let stagedURL = try? storage.stagedURL(
                        transferID: transfer.id,
                        fileName: transfer.fileName
                    ),
                    FileManager.default.fileExists(atPath: stagedURL.path)
                else {
                    return nil
                }
                return transfer
            }
            recentResults = Array(persisted.recentResults.prefix(30))
            if pausedLegacyIncomingCount > 0 { persist() }
        } catch {
            lastErrorMessage = MobilityPhoneSyncError.storage(
                "无法恢复同步队列：\(error.localizedDescription)"
            ).localizedDescription
        }
    }
}
