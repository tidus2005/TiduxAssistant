import CodexMobilityCore
import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum MobilityPairingUIState: Equatable, Sendable {
    case idle
    case required(peripheralIdentifier: UUID, computerName: String)
    case submitting(peripheralIdentifier: UUID, computerName: String)
    case paired(peripheralIdentifier: UUID, computerName: String)
    case rejected(peripheralIdentifier: UUID, computerName: String, reason: String)

    public var peripheralIdentifier: UUID? {
        switch self {
        case .idle:
            nil
        case .required(let identifier, _),
             .submitting(let identifier, _),
             .paired(let identifier, _),
             .rejected(let identifier, _, _):
            identifier
        }
    }

    public var computerName: String? {
        switch self {
        case .idle:
            nil
        case .required(_, let name),
             .submitting(_, let name),
             .paired(_, let name),
             .rejected(_, let name, _):
            name
        }
    }

    public var requiresCode: Bool {
        switch self {
        case .required, .rejected: true
        case .idle, .submitting, .paired: false
        }
    }
}

public typealias MobilityPhoneFileSyncMessageHandler = @MainActor @Sendable (SyncWireMessage) -> Void
public typealias MobilityPhoneFileSyncConnectionHandler = @MainActor @Sendable () -> Void

@MainActor
public final class MobilityPhoneStore: ObservableObject {
    @Published public internal(set) var dashboard: CompanionDashboardSnapshot?
    @Published public internal(set) var dashboardBusy = false
    @Published public internal(set) var dashboardMessage: String?
    public var dashboardDidRefresh: ((CompanionDashboardSnapshot) -> Void)?
    @Published public private(set) var state: MobilityPhoneState
    @Published public private(set) var pairingState: MobilityPairingUIState = .idle
    private var systemPairingRepairInProgress = false
    private var renewedPairingIdentifiers: Set<UUID> = []

    public func beginSystemPairingRepair(identifier: UUID) {
        systemPairingRepairInProgress = true
        renewedPairingIdentifiers.insert(identifier)
        activeCredential = nil
        central.pauseForAccessoryRepair()
        pairingState = .idle
    }

    public func finishSystemPairingRepair(identifier: UUID) {
        systemPairingRepairInProgress = false
        renewedPairingIdentifiers.insert(identifier)
        attemptedAutomaticConnections.removeAll()
    }

    /// Hooks owned by the process-level phone runtime. File messages share the existing
    /// encrypted, authenticated Mobility BLE transport while keeping their queue/UI state
    /// independent from the remote-control screen.
    public var fileSyncMessageHandler: MobilityPhoneFileSyncMessageHandler?
    public var fileSyncConnectionReadyHandler: MobilityPhoneFileSyncConnectionHandler?
    public var fileSyncConnectionClosedHandler: MobilityPhoneFileSyncConnectionHandler?

    private let central: MobilityBLECentral
    private let credentialVault: any MobilityCredentialVault
    private let jsonCodec = MobilityJSONCodec()
    private let frameCodec = MobilityFrameCodec()
    private var frameReassembler = MobilityFrameReassembler()
    private var activeCredential: MobilityPairingCredential?
    private var protocolReadyAt: Date?
    private var knownCredentials: [UUID: MobilityPairingCredential] = [:]
    private var systemAuthorizedComputers: [UUID: String] = [:]
    private var preferredSystemConnectionIdentifier: UUID?
    private var attemptedAutomaticConnections: Set<UUID> = []
    private var hasStarted = false
    private var freshnessTask: Task<Void, Never>?
    private var lastStatusRecoveryAt: Date?
    private let phoneDeviceID: UUID
    private let phoneDeviceName: String
    private struct PendingCollaboration {
        let peripheralID: UUID
        let continuation: CheckedContinuation<CollaborationResponse, Error>
        let timeout: Task<Void, Never>
    }
    private var pendingCollaboration: [UUID: PendingCollaboration] = [:]

    /// Stable identity reused by the TLS-PSK file channel. The secret itself never leaves
    /// the credential vault; exposing the public device id/name keeps both transports on
    /// the same pairing record.
    public var localDeviceID: UUID { phoneDeviceID }
    public var localDeviceName: String { phoneDeviceName }
    public var isFileSyncControlReady: Bool {
        guard activeCredential != nil else { return false }
        if case .ready = state.connectionPhase { return true }
        return false
    }

    public var isCollaborationReady: Bool { isFileSyncControlReady }

    public func requestCollaboration(
        _ request: CollaborationRequest, timeout: Duration = .seconds(12)
    ) async throws -> CollaborationResponse {
        guard isCollaborationReady, let credential = activeCredential,
              pendingCollaboration.count < 8, pendingCollaboration[request.id] == nil,
              (request.body?.count ?? 0) <= 64 * 1_024 else {
            throw CollaborationTransportError.unavailable
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.completeCollaboration(request.id, result: .failure(CollaborationTransportError.timedOut))
                }
                pendingCollaboration[request.id] = PendingCollaboration(
                    peripheralID: credential.peripheralIdentifier, continuation: continuation, timeout: timer
                )
                do {
                    let envelope = try MobilityPhoneMessageFactory.authenticatedEnvelope(
                        action: .collaboration(request), token: credential.token, nonce: UUID(), sentAt: Date()
                    )
                    try send(envelope, on: .control)
                } catch { completeCollaboration(request.id, result: .failure(error)) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.completeCollaboration(request.id, result: .failure(CancellationError()))
            }
        }
    }

    private func completeCollaboration(_ id: UUID, result: Result<CollaborationResponse, Error>) {
        guard let pending = pendingCollaboration.removeValue(forKey: id) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(with: result)
    }

    public init(
        initialState: MobilityPhoneState = MobilityPhoneState(),
        central: MobilityBLECentral? = nil,
        credentialVault: any MobilityCredentialVault = KeychainMobilityCredentialVault(),
        phoneDeviceID: UUID? = nil,
        phoneDeviceName: String? = nil
    ) {
        self.state = initialState
        self.central = central ?? MobilityBLECentral(configuration: MobilityBLEConfiguration())
        self.credentialVault = credentialVault
        self.phoneDeviceID = phoneDeviceID ?? Self.defaultPhoneDeviceID
        self.phoneDeviceName = phoneDeviceName ?? Self.defaultPhoneDeviceName
        self.central.delegate = self
    }

    public func start() {
        guard !systemPairingRepairInProgress else { return }
        guard !hasStarted else {
            central.start()
            checkStatusFreshness()
            if isCollaborationReady { refreshStatus() }
            return
        }
        hasStarted = true
        freshnessTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                self.checkStatusFreshness()
            }
        }
        do {
            let credentials = try credentialVault.allCredentials()
            knownCredentials = Dictionary(uniqueKeysWithValues: credentials.map { ($0.peripheralIdentifier, $0) })
            central.restoreKnownPeripherals(with: credentials.map(\.peripheralIdentifier))
            mutateState { next in
                next.computers = mergeCredentialPlaceholders(into: next.computers)
            }
        } catch {
            record(error: error)
        }
        central.start()
        if let knownComputer = central.computers.first(where: { knownCredentials[$0.id] != nil }) {
            attemptedAutomaticConnections.insert(knownComputer.id)
            central.connect(to: knownComputer.id)
        }
    }

    deinit { freshnessTask?.cancel() }

    private func checkStatusFreshness(now: Date = Date()) {
        mutateState { next in
            MobilityPhoneStateReducer.expireStatus(at: now, state: &next)
        }
        if isCollaborationReady,
           MobilityPhoneStateReducer.shouldRecoverConnectedLink(readyAt: protocolReadyAt,
               lastStatusAt: state.lastStatusAt, now: now) {
            lastStatusRecoveryAt = now
            central.recoverUnresponsiveLink()
            return
        }
        guard state.isStale, isCollaborationReady,
              lastStatusRecoveryAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true,
              !state.pendingCommands.values.contains(where: { $0.effect == .refreshOnly }) else { return }
        lastStatusRecoveryAt = now
        refreshStatus()
    }

    public func rescan() {
        attemptedAutomaticConnections.removeAll()
        central.rescan()
    }

    /// Restores the Core Bluetooth peripherals selected through AccessorySetupKit and
    /// connects to the preferred one. If restoration has not surfaced the peripheral yet,
    /// a service-filtered scan remains active and connects when the authorized Mac appears.
    public func restoreSystemAuthorizedAccessories(
        _ accessories: [MobilitySystemAccessory],
        preferredIdentifier: UUID?
    ) {
        guard !systemPairingRepairInProgress, !accessories.isEmpty else { return }
        start()

        for accessory in accessories {
            systemAuthorizedComputers[accessory.id] = accessory.displayName
        }
        let identifiers = accessories.map(\.id)
        if let preferredIdentifier {
            preferredSystemConnectionIdentifier = preferredIdentifier
            attemptedAutomaticConnections.remove(preferredIdentifier)
        }

        central.restoreKnownPeripherals(with: identifiers)
        mutateState { next in
            next.computers = mergeCredentialPlaceholders(into: central.computers)
        }

        let targetIdentifier = preferredIdentifier ?? accessories.first?.id
        guard let targetIdentifier else { return }
        if state.connectionPhase.peripheralIdentifier == targetIdentifier
            || attemptedAutomaticConnections.contains(targetIdentifier) {
            preferredSystemConnectionIdentifier = nil
            return
        }
        if central.computers.contains(where: { $0.id == targetIdentifier }) {
            attemptedAutomaticConnections.insert(targetIdentifier)
            preferredSystemConnectionIdentifier = nil
            connect(to: targetIdentifier, restartPendingConnection: false)
        } else {
            central.rescan()
        }
    }

    public func removeSystemAuthorizedAccessory(identifier: UUID) {
        systemAuthorizedComputers[identifier] = nil
        attemptedAutomaticConnections.remove(identifier)
        if preferredSystemConnectionIdentifier == identifier {
            preferredSystemConnectionIdentifier = nil
        }
        mutateState { next in
            next.computers = mergeCredentialPlaceholders(
                into: next.computers.filter { computer in
                    computer.id != identifier || knownCredentials[identifier] != nil
                }
            )
        }
    }

    public func connect(to peripheralIdentifier: UUID, restartPendingConnection: Bool = true) {
        if state.lastKnownStatus != nil {
            mutateState { next in
                MobilityPhoneStateReducer.disconnect(at: Date(), state: &next)
            }
        }
        central.connect(to: peripheralIdentifier, restartPendingConnection: restartPendingConnection)
    }

    public func submitPairingCode(_ code: String) {
        guard
            let identifier = state.connectionPhase.peripheralIdentifier,
            case .ready = state.connectionPhase
        else {
            record(error: MobilityPhoneMessageError.noConnectedComputer)
            return
        }
        let computerName = computerName(for: identifier)

        do {
            let envelope = try MobilityPhoneMessageFactory.pairingEnvelope(
                code: code,
                phoneDeviceID: phoneDeviceID,
                phoneDeviceName: phoneDeviceName
            )
            try send(envelope, on: .pairing)
            pairingState = .submitting(peripheralIdentifier: identifier, computerName: computerName)
            schedulePairingTimeout(peripheralIdentifier: identifier, computerName: computerName)
        } catch {
            pairingState = .required(peripheralIdentifier: identifier, computerName: computerName)
            record(error: error)
        }
    }

    public func refreshStatus() {
        sendAuthenticated(action: .requestStatus, effect: .refreshOnly)
    }

    public func setModeEnabled(_ enabled: Bool) {
        sendAuthenticated(
            action: .setMode(enabled: enabled, profile: .idleGuard),
            effect: .setMode(enabled: enabled, profile: .idleGuard)
        )
    }

    public func updatePolicy(_ policy: MobilityPolicy) {
        let normalized = policy.normalized()
        sendAuthenticated(
            action: .updatePolicy(normalized),
            effect: .updatePolicy(normalized)
        )
    }

    @discardableResult
    public func sendFileSyncMessage(_ message: SyncWireMessage) -> Bool {
        guard let activeCredential else {
            record(error: MobilityPhoneMessageError.notPaired)
            return false
        }

        do {
            let envelope = try MobilityPhoneMessageFactory.authenticatedEnvelope(
                action: .fileSync(message),
                token: activeCredential.token,
                nonce: UUID(),
                sentAt: Date()
            )
            try send(envelope, on: .control)
            return true
        } catch {
            record(error: error)
            return false
        }
    }

    /// Uses the live encrypted-control write limit for a conservative bidirectional MTU.
    /// Notification capacity can be larger, but choosing the smaller value keeps either
    /// direction resumable with the same negotiated parameters.
    public func currentFileSyncTransportCapabilities() -> SyncTransportCapabilities? {
        guard let frameSize = try? central.maximumFrameSize(for: .control) else { return nil }
        return try? SyncBLETransferTuning.capabilities(
            maximumWriteValueLength: frameSize,
            maximumUpdateValueLength: frameSize,
            framesPerChunk: 4,
            maximumWindowSize: 1
        )
    }

    public func clearError() {
        mutateState { $0.lastErrorMessage = nil }
    }

    private func sendAuthenticated(action: Action, effect: MobilityPendingEffect) {
        guard let activeCredential else {
            record(error: MobilityPhoneMessageError.notPaired)
            return
        }

        let nonce = UUID()
        let now = Date()
        do {
            let envelope = try MobilityPhoneMessageFactory.authenticatedEnvelope(
                action: action,
                token: activeCredential.token,
                nonce: nonce,
                sentAt: now
            )
            try send(envelope, on: .control)
            mutateState { next in
                MobilityPhoneStateReducer.register(
                    commandID: nonce,
                    effect: effect,
                    sentAt: now,
                    state: &next
                )
            }
            scheduleCommandTimeout(commandID: nonce)
        } catch {
            record(error: error)
        }
    }

    private func schedulePairingTimeout(peripheralIdentifier: UUID, computerName: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self,
                  case .submitting(let pendingIdentifier, _) = self.pairingState,
                  pendingIdentifier == peripheralIdentifier else {
                return
            }
            self.pairingState = .required(
                peripheralIdentifier: peripheralIdentifier,
                computerName: computerName
            )
            self.record(error: "Mac 未在 15 秒内确认配对，请检查配对码后重试。")
        }
    }

    private func scheduleCommandTimeout(commandID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.state.pendingCommands[commandID] != nil else { return }
            self.mutateState { next in
                next.pendingCommands[commandID] = nil
                next.lastErrorMessage = "Mac 未在 15 秒内确认操作，界面仍保留上次已知状态。"
            }
        }
    }

    private func send(_ envelope: ClientEnvelope, on channel: MobilityBLEWriteChannel) throws {
        let payload = try jsonCodec.encode(envelope)
        let maximumFrameSize = try central.maximumFrameSize(for: channel)
        let frames = try frameCodec.encode(
            payload,
            messageID: envelope.messageID,
            maximumFrameSize: maximumFrameSize
        )
        try central.enqueue(frames: frames, on: channel)
    }

    private func handleReady(peripheralIdentifier: UUID) {
        frameReassembler.reset()
        do {
            if !renewedPairingIdentifiers.contains(peripheralIdentifier),
               let credential = try credentialVault.credential(for: peripheralIdentifier) {
                activeCredential = credential
                pairingState = .paired(
                    peripheralIdentifier: peripheralIdentifier,
                    computerName: credential.computerName
                )
                refreshStatus()
                fileSyncConnectionReadyHandler?()
            } else {
                activeCredential = nil
                pairingState = .required(
                    peripheralIdentifier: peripheralIdentifier,
                    computerName: computerName(for: peripheralIdentifier)
                )
            }
        } catch {
            activeCredential = nil
            pairingState = .required(
                peripheralIdentifier: peripheralIdentifier,
                computerName: computerName(for: peripheralIdentifier)
            )
            record(error: error)
        }
    }

    private func handle(_ envelope: ServerEnvelope, from peripheralIdentifier: UUID) {
        guard state.connectionPhase.peripheralIdentifier == peripheralIdentifier else { return }
        guard envelope.version == ServerEnvelope.currentVersion else {
            record(error: MobilityPhoneMessageError.invalidServerVersion(envelope.version))
            return
        }

        switch envelope.message {
        case .pairAccepted(let acceptance):
            guard case .submitting(let expectedIdentifier, _) = pairingState,
                  expectedIdentifier == peripheralIdentifier else { return }
            guard !acceptance.token.isEmpty else {
                pairingState = .required(
                    peripheralIdentifier: peripheralIdentifier,
                    computerName: computerName(for: peripheralIdentifier)
                )
                record(error: MobilityPhoneMessageError.missingPairingToken)
                return
            }
            let credential = MobilityPairingCredential(
                peripheralIdentifier: peripheralIdentifier,
                computerIdentifier: acceptance.serverDeviceID.uuidString,
                computerName: acceptance.serverDeviceName,
                token: acceptance.token
            )
            do {
                try credentialVault.store(credential)
                renewedPairingIdentifiers.remove(peripheralIdentifier)
                knownCredentials[peripheralIdentifier] = credential
                activeCredential = credential
                pairingState = .paired(
                    peripheralIdentifier: peripheralIdentifier,
                    computerName: acceptance.serverDeviceName
                )
                refreshStatus()
                fileSyncConnectionReadyHandler?()
            } catch {
                record(error: error)
            }

        case .pairRejected(let rejection):
            activeCredential = nil
            pairingState = .rejected(
                peripheralIdentifier: peripheralIdentifier,
                computerName: computerName(for: peripheralIdentifier),
                reason: rejection.reason
            )
            record(error: rejection.reason)

        case .status(let status):
            guard activeCredential?.peripheralIdentifier == peripheralIdentifier,
                  activeCredential?.computerIdentifier.lowercased() == status.deviceID.uuidString.lowercased() else { return }
            mutateState { next in
                MobilityPhoneStateReducer.receive(status: status, at: Date(), state: &next)
            }
            #if canImport(UIKit)
            if UIApplication.shared.applicationState == .background {
                // Bounded diagnostic: one timestamp, no payload or credentials.
                UserDefaults.standard.set(Date(), forKey: "mobility.backgroundStatusReceivedAt")
            }
            #endif

        case .result(let result):
            guard activeCredential?.peripheralIdentifier == peripheralIdentifier else { return }
            if let status = result.status {
                guard activeCredential?.computerIdentifier.lowercased() == status.deviceID.uuidString.lowercased() else { return }
                mutateState { next in
                    MobilityPhoneStateReducer.receive(status: status, at: Date(), state: &next)
                }
            }
            mutateState { next in
                MobilityPhoneStateReducer.acknowledge(
                    commandID: result.nonce,
                    accepted: result.accepted,
                    message: result.message,
                    state: &next
                )
            }

        case .fileSync(let message):
            guard activeCredential?.peripheralIdentifier == peripheralIdentifier else { return }
            fileSyncMessageHandler?(message)
        case .collaboration(let response):
            guard let pending = pendingCollaboration[response.requestID],
                  pending.peripheralID == peripheralIdentifier,
                  activeCredential?.peripheralIdentifier == peripheralIdentifier else { return }
            completeCollaboration(response.requestID, result: .success(response))
        }
    }

    private func attemptAutomaticConnection(to computers: [MobilityDiscoveredComputer]) {
        guard !systemPairingRepairInProgress else { return }
        guard case .scanning = state.connectionPhase else { return }
        if let preferredSystemConnectionIdentifier {
            guard
                let preferred = computers.first(where: { $0.id == preferredSystemConnectionIdentifier }),
                !attemptedAutomaticConnections.contains(preferred.id)
            else {
                return
            }
            attemptedAutomaticConnections.insert(preferred.id)
            self.preferredSystemConnectionIdentifier = nil
            central.connect(to: preferred.id)
            return
        }
        for computer in computers where !attemptedAutomaticConnections.contains(computer.id) {
            attemptedAutomaticConnections.insert(computer.id)
            if systemAuthorizedComputers[computer.id] != nil {
                central.connect(to: computer.id)
                return
            }
            do {
                if try credentialVault.credential(for: computer.id) != nil {
                    central.connect(to: computer.id)
                    return
                }
            } catch {
                record(error: error)
            }
        }
    }

    private func computerName(for identifier: UUID) -> String {
        state.computers.first(where: { $0.id == identifier })?.name
            ?? knownCredentials[identifier]?.computerName
            ?? "Mac"
    }

    private func mergeCredentialPlaceholders(
        into computers: [MobilityDiscoveredComputer]
    ) -> [MobilityDiscoveredComputer] {
        var merged = computers
        for credential in knownCredentials.values where !merged.contains(where: { $0.id == credential.peripheralIdentifier }) {
            merged.append(
                MobilityDiscoveredComputer(
                    id: credential.peripheralIdentifier,
                    name: credential.computerName,
                    signalStrength: 0,
                    lastSeenAt: .distantPast
                )
            )
        }
        for (identifier, name) in systemAuthorizedComputers where !merged.contains(where: { $0.id == identifier }) {
            merged.append(
                MobilityDiscoveredComputer(
                    id: identifier,
                    name: name,
                    signalStrength: 0,
                    lastSeenAt: .distantPast
                )
            )
        }
        return merged.sorted { lhs, rhs in
            let lhsIsNearby = lhs.lastSeenAt != .distantPast
            let rhsIsNearby = rhs.lastSeenAt != .distantPast
            if lhsIsNearby != rhsIsNearby { return lhsIsNearby }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func record(error: Error) {
        record(error: error.localizedDescription)
    }

    private func record(error message: String) {
        mutateState { next in
            MobilityPhoneStateReducer.fail(message: message, state: &next)
        }
    }

    private func mutateState(_ mutation: (inout MobilityPhoneState) -> Void) {
        var next = state
        mutation(&next)
        state = next
    }

    private static var defaultPhoneDeviceID: UUID {
        #if canImport(UIKit)
        UIDevice.current.identifierForVendor ?? UUID()
        #else
        UUID()
        #endif
    }

    private static var defaultPhoneDeviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "iPhone"
        #endif
    }
}

extension MobilityPhoneStore: MobilityBLECentralDelegate {
    public func mobilityCentral(
        _ central: MobilityBLECentral,
        didChange availability: MobilityBluetoothAvailability
    ) {
        mutateState { $0.bluetoothAvailability = availability }
    }

    public func mobilityCentral(
        _ central: MobilityBLECentral,
        didDiscover computers: [MobilityDiscoveredComputer]
    ) {
        mutateState { $0.computers = mergeCredentialPlaceholders(into: computers) }
        attemptAutomaticConnection(to: computers)
    }

    public func mobilityCentral(
        _ central: MobilityBLECentral,
        didChange phase: MobilityBLEConnectionPhase
    ) {
        let previous = state.connectionPhase
        #if canImport(UIKit)
        if UIApplication.shared.applicationState == .background {
            UserDefaults.standard.set(String(describing: phase), forKey: "mobility.backgroundConnectionPhase")
            UserDefaults.standard.set(Date(), forKey: "mobility.backgroundConnectionChangedAt")
        }
        #endif
        mutateState { $0.connectionPhase = phase }

        switch phase {
        case .ready(let identifier):
            protocolReadyAt = Date()
            handleReady(peripheralIdentifier: identifier)
        case .reconnecting, .idle:
            protocolReadyAt = nil
            for id in Array(pendingCollaboration.keys) {
                completeCollaboration(id, result: .failure(CollaborationTransportError.disconnected))
            }
            frameReassembler.reset()
            mutateState { next in
                MobilityPhoneStateReducer.disconnect(at: Date(), state: &next)
                if !next.pendingCommands.isEmpty {
                    next.pendingCommands.removeAll()
                    next.lastErrorMessage = "蓝牙连接中断，未确认的操作已取消。"
                }
            }
            fileSyncConnectionClosedHandler?()
        case .scanning, .connecting, .discovering:
            if previous.peripheralIdentifier != phase.peripheralIdentifier,
               state.lastKnownStatus != nil {
                mutateState { next in
                    MobilityPhoneStateReducer.disconnect(at: Date(), state: &next)
                }
            }
        }
    }

    public func mobilityCentral(
        _ central: MobilityBLECentral,
        didReceive frame: Data,
        on channel: MobilityBLEInboundChannel,
        from peripheralIdentifier: UUID
    ) {
        do {
            guard let message = try frameReassembler.ingest(frame) else { return }
            let envelope = try jsonCodec.decodeServer(message.payload)
            guard envelope.messageID == message.messageID else {
                throw MobilityPhoneMessageError.messageIdentifierMismatch
            }
            handle(envelope, from: peripheralIdentifier)
        } catch {
            record(error: "无法读取 Mac 状态：\(error)")
        }
    }

    public func mobilityCentral(_ central: MobilityBLECentral, didFail error: MobilityBLECentralError) {
        if case .writeFailed = error,
           case .submitting(let identifier, let name) = pairingState {
            pairingState = .required(peripheralIdentifier: identifier, computerName: name)
        }
        mutateState { next in
            if case .writeFailed = error {
                next.pendingCommands.removeAll()
            }
            MobilityPhoneStateReducer.fail(message: error.localizedDescription, state: &next)
        }
    }
}
