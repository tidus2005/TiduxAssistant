@preconcurrency import CoreBluetooth
import CodexMobilityCore
import Foundation
import OSLog

public struct MobilityMacCommandOutcome: Equatable, Sendable {
    public var accepted: Bool
    public var message: String
    public var status: MobilityDeviceStatus?

    public init(accepted: Bool, message: String, status: MobilityDeviceStatus? = nil) {
        self.accepted = accepted
        self.message = message
        self.status = status
    }
}

@MainActor
public protocol MobilityMacCommandHandling: AnyObject {
    func handleMobilityAction(_ action: Action) async throws -> MobilityMacCommandOutcome
}

public typealias MobilityMacCommandHandler = @MainActor @Sendable (Action) async throws -> MobilityMacCommandOutcome
public typealias MobilityPairingCodeProvider = @MainActor @Sendable () -> String
public typealias MobilityFileSyncMessageHandler = @MainActor @Sendable (
    _ message: SyncWireMessage,
    _ phoneDeviceID: UUID
) async throws -> [SyncWireMessage]

public enum MobilityBLEPeripheralAvailability: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

public enum MobilityPairingAttemptResult: Equatable, Sendable {
    case accepted
    case windowClosed
    case codeExpired
    case invalidCode(remainingAttempts: Int)
    case locked(until: Date)
}

public struct MobilityPairingGateSnapshot: Equatable, Sendable {
    public var isOpen: Bool
    public var expiresAt: Date?
    public var lockedUntil: Date?
    public var failedAttemptCount: Int

    public init(
        isOpen: Bool,
        expiresAt: Date?,
        lockedUntil: Date?,
        failedAttemptCount: Int
    ) {
        self.isOpen = isOpen
        self.expiresAt = expiresAt
        self.lockedUntil = lockedUntil
        self.failedAttemptCount = failedAttemptCount
    }
}

/// Pure pairing-window state machine, kept independent from Core Bluetooth so its
/// expiry, one-time-code, and brute-force protections can be tested deterministically.
public struct MobilityPairingGate: Equatable, Sendable {
    public static let defaultWindowDuration: TimeInterval = 5 * 60
    public static let defaultCodeTTL: TimeInterval = 5 * 60
    public static let defaultMaximumFailedAttempts = 3
    public static let defaultInitialLockoutDuration: TimeInterval = 30
    public static let defaultMaximumLockoutDuration: TimeInterval = 5 * 60

    public let windowDuration: TimeInterval
    public let codeTTL: TimeInterval
    public let maximumFailedAttempts: Int
    public let initialLockoutDuration: TimeInterval
    public let maximumLockoutDuration: TimeInterval

    public private(set) var windowExpiresAt: Date?
    public private(set) var codeExpiresAt: Date?
    public private(set) var lockedUntil: Date?
    public private(set) var failedAttemptCount = 0

    private var lockoutLevel = 0

    public init(
        windowDuration: TimeInterval = MobilityPairingGate.defaultWindowDuration,
        codeTTL: TimeInterval = MobilityPairingGate.defaultCodeTTL,
        maximumFailedAttempts: Int = MobilityPairingGate.defaultMaximumFailedAttempts,
        initialLockoutDuration: TimeInterval = MobilityPairingGate.defaultInitialLockoutDuration,
        maximumLockoutDuration: TimeInterval = MobilityPairingGate.defaultMaximumLockoutDuration
    ) {
        self.windowDuration = max(windowDuration, 1)
        self.codeTTL = max(codeTTL, 1)
        self.maximumFailedAttempts = max(maximumFailedAttempts, 1)
        self.initialLockoutDuration = max(initialLockoutDuration, 1)
        self.maximumLockoutDuration = max(maximumLockoutDuration, self.initialLockoutDuration)
    }

    /// Opens a fresh window for a code that was rotated at `now`.
    public mutating func open(at now: Date) {
        windowExpiresAt = now.addingTimeInterval(windowDuration)
        codeExpiresAt = now.addingTimeInterval(codeTTL)
        lockedUntil = nil
        failedAttemptCount = 0
        lockoutLevel = 0
    }

    public mutating func close() {
        windowExpiresAt = nil
        codeExpiresAt = nil
        lockedUntil = nil
        failedAttemptCount = 0
        lockoutLevel = 0
    }

    /// A matching code is consumed immediately: the gate closes before credential
    /// persistence or any response is attempted, so the same code cannot be replayed.
    public mutating func attempt(
        providedCode: String,
        expectedCode: String,
        at now: Date
    ) -> MobilityPairingAttemptResult {
        guard let windowExpiresAt, windowExpiresAt > now else {
            return .windowClosed
        }
        guard let codeExpiresAt, codeExpiresAt > now else {
            return .codeExpired
        }
        if let lockedUntil, lockedUntil > now {
            return .locked(until: lockedUntil)
        }
        if lockedUntil != nil {
            self.lockedUntil = nil
        }

        if Self.constantTimeMatches(providedCode, expectedCode) {
            close()
            return .accepted
        }

        failedAttemptCount += 1
        let remainingAttempts = maximumFailedAttempts - failedAttemptCount
        guard remainingAttempts <= 0 else {
            return .invalidCode(remainingAttempts: remainingAttempts)
        }

        failedAttemptCount = 0
        let multiplier = pow(2, Double(min(lockoutLevel, 20)))
        let duration = min(initialLockoutDuration * multiplier, maximumLockoutDuration)
        let deadline = now.addingTimeInterval(duration)
        lockedUntil = deadline
        lockoutLevel = min(lockoutLevel + 1, 20)
        return .locked(until: deadline)
    }

    public func snapshot(at now: Date) -> MobilityPairingGateSnapshot {
        let effectiveExpiry = [windowExpiresAt, codeExpiresAt].compactMap { $0 }.min()
        let hasNotExpired = effectiveExpiry.map { $0 > now } == true
        let activeLock = hasNotExpired ? lockedUntil.flatMap { $0 > now ? $0 : nil } : nil
        let isOpen = hasNotExpired && activeLock == nil
        return MobilityPairingGateSnapshot(
            isOpen: isOpen,
            expiresAt: effectiveExpiry,
            lockedUntil: activeLock,
            failedAttemptCount: failedAttemptCount
        )
    }

    public func nextTransitionDate(after now: Date) -> Date? {
        let snapshot = snapshot(at: now)
        return [snapshot.lockedUntil, snapshot.expiresAt]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
    }

    private static func constantTimeMatches(_ candidate: String, _ expected: String) -> Bool {
        let candidateBytes = Array(candidate.utf8)
        let expectedBytes = Array(expected.utf8)
        guard candidateBytes.count == expectedBytes.count else { return false }

        var difference: UInt8 = 0
        for index in candidateBytes.indices {
            difference |= candidateBytes[index] ^ expectedBytes[index]
        }
        return difference == 0
    }
}

public struct MobilityBLEPeripheralState: Equatable, Sendable {
    public var availability: MobilityBLEPeripheralAvailability
    public var isAdvertising: Bool
    public var pairingCode: String
    public var connectedCentralCount: Int
    public var lastErrorMessage: String?
    public var isPairingWindowOpen: Bool
    public var pairingWindowExpiresAt: Date?
    public var pairingLockedUntil: Date?

    public init(
        availability: MobilityBLEPeripheralAvailability,
        isAdvertising: Bool,
        pairingCode: String,
        connectedCentralCount: Int,
        lastErrorMessage: String?,
        isPairingWindowOpen: Bool = false,
        pairingWindowExpiresAt: Date? = nil,
        pairingLockedUntil: Date? = nil
    ) {
        self.availability = availability
        self.isAdvertising = isAdvertising
        self.pairingCode = pairingCode
        self.connectedCentralCount = connectedCentralCount
        self.lastErrorMessage = lastErrorMessage
        self.isPairingWindowOpen = isPairingWindowOpen
        self.pairingWindowExpiresAt = pairingWindowExpiresAt
        self.pairingLockedUntil = pairingLockedUntil
    }
}

public enum MobilityBLEPeripheralError: LocalizedError, Equatable, Sendable {
    case bluetoothUnavailable
    case serviceRegistrationFailed(String)
    case invalidProtocolVersion(UInt16)
    case invalidMessageChannel
    case commandExpired
    case invalidToken
    case replayedNonce
    case commandHandlerUnavailable
    case wireEncodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            "蓝牙当前不可用。"
        case .serviceRegistrationFailed(let message):
            "无法注册 Mac 随行蓝牙服务：\(message)"
        case .invalidProtocolVersion(let version):
            "不兼容的随行协议版本（\(version)）。"
        case .invalidMessageChannel:
            "消息发送到了错误的蓝牙通道。"
        case .commandExpired:
            "命令已过期，请刷新后重试。"
        case .invalidToken:
            "配对令牌无效，请重新配对。"
        case .replayedNonce:
            "检测到重复命令，已拒绝执行。"
        case .commandHandlerUnavailable:
            "Mac 随行控制器尚未就绪。"
        case .wireEncodingFailed(let message):
            "无法编码蓝牙消息：\(message)"
        }
    }
}

/// Encrypted Core Bluetooth peripheral for Mac Mobility control.
///
/// Pairing and control writes require an encrypted BLE link. Status/event notifications
/// also require link encryption, while application-level commands additionally require a
/// Keychain-backed token, a fresh timestamp, and a nonce that has not been observed before.
@MainActor
public final class MobilityBLEPeripheral: NSObject {
    public var collaborationHandler: (@MainActor @Sendable (CollaborationRequest, UUID) async -> CollaborationResponse)?
    public weak var commandDelegate: (any MobilityMacCommandHandling)?
    public var commandHandler: MobilityMacCommandHandler?
    public var fileSyncMessageHandler: MobilityFileSyncMessageHandler?
    public var stateDidChange: (@MainActor @Sendable (MobilityBLEPeripheralState) -> Void)?
    public var pairedDevicesDidChange: (@MainActor @Sendable () -> Void)?

    public private(set) var pairingCode: String
    public private(set) var connectedCentralCount = 0
    public private(set) var isAdvertising = false
    public private(set) var availability: MobilityBLEPeripheralAvailability = .unknown
    public private(set) var lastErrorMessage: String?

    public var state: MobilityBLEPeripheralState {
        let pairingSnapshot = pairingGate.snapshot(at: Date())
        return MobilityBLEPeripheralState(
            availability: availability,
            isAdvertising: isAdvertising,
            pairingCode: pairingCode,
            connectedCentralCount: connectedCentralCount,
            lastErrorMessage: lastErrorMessage,
            isPairingWindowOpen: pairingSnapshot.isOpen,
            pairingWindowExpiresAt: pairingSnapshot.expiresAt,
            pairingLockedUntil: pairingSnapshot.lockedUntil
        )
    }

    private enum WriteChannel {
        case pairing
        case control
    }

    private struct QueuedUpdate {
        var data: Data
        var characteristic: CBMutableCharacteristic
        var centrals: [CBCentral]?
        var isCoalescibleStatusBroadcast = false
        var isStatusPayload = false
        var isFileSyncPayload = false
        var offerID: UUID?
    }

    private let serverDeviceID: UUID
    private let serverDeviceName: String
    private let advertisementName: String
    private let credentialVault: any MobilityMacCredentialStoring
    private let pairingCodeProvider: MobilityPairingCodeProvider
    private let commandValidityWindow: TimeInterval
    private let nonceRetentionWindow: TimeInterval
    private let jsonCodec = MobilityJSONCodec()
    private let transportLog = Logger(subsystem: "com.tidux.CodexWatchPet.mac", category: "MobilityBLE")
    private let frameCodec = MobilityFrameCodec()

    private var peripheralManager: CBPeripheralManager!
    private var mobilityService: CBMutableService?
    private var pairingCharacteristic: CBMutableCharacteristic?
    private var controlCharacteristic: CBMutableCharacteristic?
    private var statusCharacteristic: CBMutableCharacteristic?
    private var eventCharacteristic: CBMutableCharacteristic?
    private var wantsAdvertising = false
    private var serviceWasAdded = false
    private var reassemblers: [UUID: MobilityFrameReassembler] = [:]
    private var knownCentrals: [UUID: CBCentral] = [:]
    private var centralAuthorizations = MobilityCentralAuthorizationRegistry()
    private var seenNonces: [UUID: Date] = [:]
    private var pendingUpdates: [QueuedUpdate] = []
    private var lastQueueWarningAt: Date = .distantPast
    private var lastPublishedOffers: [UUID: Date] = [:]
    private var latestStatus: MobilityDeviceStatus?
    private var deferredBroadcastStatus: MobilityDeviceStatus?
    private var isStatusPublishingEnabled = true
    private var isFileSyncPublishingEnabled = true
    private var pairingGate: MobilityPairingGate
    private var pairingTransitionTask: Task<Void, Never>?

    public init(
        serverDeviceID: UUID,
        serverDeviceName: String,
        advertisementName: String? = nil,
        pairingCode: String? = nil,
        pairingCodeProvider: MobilityPairingCodeProvider? = nil,
        credentialVault: any MobilityMacCredentialStoring = MobilityMacCredentialVault(),
        commandHandler: MobilityMacCommandHandler? = nil,
        commandValidityWindow: TimeInterval = 60,
        nonceRetentionWindow: TimeInterval = 10 * 60,
        pairingWindowDuration: TimeInterval = MobilityPairingGate.defaultWindowDuration,
        pairingCodeTTL: TimeInterval = MobilityPairingGate.defaultCodeTTL,
        maximumFailedPairingAttempts: Int = MobilityPairingGate.defaultMaximumFailedAttempts,
        initialPairingLockoutDuration: TimeInterval = MobilityPairingGate.defaultInitialLockoutDuration,
        maximumPairingLockoutDuration: TimeInterval = MobilityPairingGate.defaultMaximumLockoutDuration
    ) {
        self.serverDeviceID = serverDeviceID
        self.serverDeviceName = serverDeviceName
        self.advertisementName = advertisementName ?? serverDeviceName
        self.credentialVault = credentialVault
        self.commandHandler = commandHandler
        self.commandValidityWindow = max(commandValidityWindow, 1)
        self.nonceRetentionWindow = max(nonceRetentionWindow, commandValidityWindow, 1)
        self.pairingGate = MobilityPairingGate(
            windowDuration: pairingWindowDuration,
            codeTTL: pairingCodeTTL,
            maximumFailedAttempts: maximumFailedPairingAttempts,
            initialLockoutDuration: initialPairingLockoutDuration,
            maximumLockoutDuration: maximumPairingLockoutDuration
        )

        let provider: MobilityPairingCodeProvider
        if let pairingCodeProvider {
            provider = pairingCodeProvider
        } else if let pairingCode, Self.isValidPairingCode(pairingCode) {
            provider = { pairingCode }
        } else {
            provider = { Self.generatePairingCode() }
        }
        self.pairingCodeProvider = provider
        let initialCode = provider()
        self.pairingCode = Self.isValidPairingCode(initialCode) ? initialCode : Self.generatePairingCode()

        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    public func start() {
        if !wantsAdvertising {
            pairingGate.open(at: Date())
            schedulePairingTransition()
            emitState()
        }
        wantsAdvertising = true
        guard peripheralManager.state == .poweredOn else {
            if peripheralManager.state != .unknown && peripheralManager.state != .resetting {
                report(error: MobilityBLEPeripheralError.bluetoothUnavailable)
            }
            return
        }
        registerServiceIfNeeded()
        startAdvertisingIfReady()
    }

    public func stop() {
        wantsAdvertising = false
        pairingGate.close()
        rotatePairingCode()
        schedulePairingTransition()
        peripheralManager.stopAdvertising()
        isAdvertising = false
        pendingUpdates.removeAll()
        lastPublishedOffers.removeAll()
        deferredBroadcastStatus = nil
        emitState()
    }

    /// Rotates the six-digit code and opens a fresh, time-limited pairing window.
    public func regeneratePairingCode() {
        rotatePairingCodeAndOpenWindow(at: Date())
    }

    /// Explicitly reopens pairing. Reopening always rotates the code to avoid
    /// reviving a value that may already have been observed.
    public func openPairingWindow() {
        rotatePairingCodeAndOpenWindow(at: Date())
    }

    public func closePairingWindow() {
        pairingGate.close()
        rotatePairingCode()
        schedulePairingTransition()
        emitState()
    }

    public func pairedDevices() throws -> [MobilityMacPairedDevice] {
        try credentialVault.pairedDevices()
    }

    /// Revokes one Keychain credential and immediately removes every live central
    /// that authenticated as that device from status/event delivery.
    public func revokePairedDevice(deviceID: UUID) throws {
        try credentialVault.revokeCredential(for: deviceID)
        deauthorizeCentrals(for: deviceID)
        pairedDevicesDidChange?()
    }

    private func rotatePairingCodeAndOpenWindow(at now: Date) {
        rotatePairingCode()
        pairingGate.open(at: now)
        schedulePairingTransition()
        emitState()
    }

    private func rotatePairingCode() {
        let next = pairingCodeProvider()
        let candidate = Self.isValidPairingCode(next) ? next : Self.generatePairingCode()
        if candidate == pairingCode {
            repeat {
                pairingCode = Self.generatePairingCode()
            } while pairingCode == candidate
        } else {
            pairingCode = candidate
        }
    }

    private var lastStatusBroadcastAt: Date?

    public func publishStatus(_ status: MobilityDeviceStatus) {
        guard isStatusPublishingEnabled else { return }
        let modeChanged = latestStatus?.mode != status.mode
        latestStatus = status
        let now = Date()
        // A low-rate peripheral notification wakes the suspended phone through Core
        // Bluetooth. No iOS polling timer or unrelated background mode is required.
        guard modeChanged || lastStatusBroadcastAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        guard let statusCharacteristic else { return }
        let recipients = authorizedSubscribers(of: statusCharacteristic)
        guard !recipients.isEmpty else { return }

        let alreadyQueued = pendingUpdates.contains {
            $0.isCoalescibleStatusBroadcast
        }
        if alreadyQueued {
            deferredBroadcastStatus = status
            return
        }
        lastStatusBroadcastAt = now
        enqueue(message: .status(status), on: statusCharacteristic, centrals: recipients, isBroadcast: true)
    }

    func setStatusPublishingEnabled(_ enabled: Bool) {
        guard isStatusPublishingEnabled != enabled else { return }
        isStatusPublishingEnabled = enabled
        guard !enabled else { return }

        latestStatus = nil
        deferredBroadcastStatus = nil
        pendingUpdates.removeAll { $0.isStatusPayload }
    }

    func setFileSyncPublishingEnabled(_ enabled: Bool) {
        guard isFileSyncPublishingEnabled != enabled else { return }
        isFileSyncPublishingEnabled = enabled
        guard !enabled else { return }

        // Core Bluetooth updates already handed to the OS cannot be recalled,
        // but no queued transfer payload may leave after the module is disabled.
        pendingUpdates.removeAll { $0.isFileSyncPayload }
    }

    public func publishEvent(_ message: ServerMessage) {
        let isFileSyncPayload: Bool
        if case .fileSync = message {
            guard isFileSyncPublishingEnabled else { return }
            isFileSyncPayload = true
        } else {
            isFileSyncPayload = false
        }
        guard let eventCharacteristic else { return }
        let recipients = authorizedSubscribers(of: eventCharacteristic)
        guard !recipients.isEmpty else { return }
        enqueue(
            message: message,
            on: eventCharacteristic,
            centrals: recipients,
            isFileSyncPayload: isFileSyncPayload
        )
    }

    /// Sends a synchronization message only to authenticated, currently subscribed phones.
    /// When `phoneDeviceID` is nil the message is offered to every authorized phone; transfer
    /// responses are always targeted back to the phone that initiated the exchange.
    public func publishFileSync(
        _ message: SyncWireMessage,
        to phoneDeviceID: UUID? = nil
    ) {
        guard isFileSyncPublishingEnabled else { return }
        guard let eventCharacteristic else { return }
        let recipients = authorizedSubscribers(of: eventCharacteristic).filter { central in
            guard let phoneDeviceID else { return true }
            return centralAuthorizations.deviceID(for: central.identifier) == phoneDeviceID
        }
        guard !recipients.isEmpty else { return }
        if case .offer(let offer) = message {
            let now = Date()
            lastPublishedOffers = lastPublishedOffers.filter { now.timeIntervalSince($0.value) < 10 }
            guard lastPublishedOffers[offer.metadata.transferID] == nil else { return }
            lastPublishedOffers[offer.metadata.transferID] = now
        }
        enqueue(
            message: .fileSync(message),
            on: eventCharacteristic,
            centrals: recipients,
            isFileSyncPayload: true
        )
    }

    public static func isValidPairingCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    public static func generatePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private func registerServiceIfNeeded() {
        guard !serviceWasAdded, mobilityService == nil, peripheralManager.state == .poweredOn else { return }

        let pairing = CBMutableCharacteristic(
            type: CBUUID(nsuuid: MobilityBLEUUIDs.pairing),
            properties: [.write, .notify, .notifyEncryptionRequired],
            value: nil,
            permissions: [.writeEncryptionRequired]
        )
        let control = CBMutableCharacteristic(
            type: CBUUID(nsuuid: MobilityBLEUUIDs.control),
            properties: [.write, .notify, .notifyEncryptionRequired],
            value: nil,
            permissions: [.writeEncryptionRequired]
        )
        let status = CBMutableCharacteristic(
            type: CBUUID(nsuuid: MobilityBLEUUIDs.status),
            properties: [.read, .notify, .notifyEncryptionRequired],
            value: nil,
            permissions: [.readEncryptionRequired]
        )
        let event = CBMutableCharacteristic(
            type: CBUUID(nsuuid: MobilityBLEUUIDs.event),
            properties: [.notify, .notifyEncryptionRequired],
            value: nil,
            permissions: []
        )
        let service = CBMutableService(type: CBUUID(nsuuid: MobilityBLEUUIDs.service), primary: true)
        service.characteristics = [pairing, control, status, event]

        pairingCharacteristic = pairing
        controlCharacteristic = control
        statusCharacteristic = status
        eventCharacteristic = event
        mobilityService = service
        peripheralManager.add(service)
    }

    private func startAdvertisingIfReady() {
        guard
            wantsAdvertising,
            serviceWasAdded,
            peripheralManager.state == .poweredOn,
            !peripheralManager.isAdvertising
        else {
            return
        }
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: MobilityBLEUUIDs.service)],
            CBAdvertisementDataLocalNameKey: advertisementName
        ])
    }

    private func process(_ envelope: ClientEnvelope, channel: WriteChannel, central: CBCentral) {
        guard envelope.version == ClientEnvelope.currentVersion else {
            let error = MobilityBLEPeripheralError.invalidProtocolVersion(envelope.version)
            reject(envelope.message, reason: error.localizedDescription, central: central)
            report(error: error)
            return
        }

        switch (channel, envelope.message) {
        case (.pairing, .pair(let request)):
            handlePair(request, central: central)
        case (.control, .command(let command)):
            Task { [weak self] in
                await self?.handle(command, central: central)
            }
        case (.pairing, .command), (.control, .pair):
            let error = MobilityBLEPeripheralError.invalidMessageChannel
            reject(envelope.message, reason: error.localizedDescription, central: central)
            report(error: error)
        }
    }

    private func reject(_ message: ClientMessage, reason: String, central: CBCentral) {
        let response: ServerMessage = switch message {
        case .pair:
            .pairRejected(PairRejection(reason: reason))
        case .command(let command):
            .result(
                CommandResult(
                    nonce: command.nonce,
                    accepted: false,
                    message: reason,
                    status: isStatusPublishingEnabled
                        && centralAuthorizations.isAuthorized(centralID: central.identifier)
                        ? latestStatus
                        : nil
                )
            )
        }
        enqueue(message: response, on: statusCharacteristic, centrals: [central])
    }

    private func handlePair(_ request: PairRequest, central: CBCentral) {
        let now = Date()
        let result = pairingGate.attempt(
            providedCode: request.pairingCode,
            expectedCode: pairingCode,
            at: now
        )
        schedulePairingTransition()

        switch result {
        case .windowClosed:
            emitState()
            sendPairRejection("配对窗口已关闭，请在 Mac 上重新开启。", to: central)
            return
        case .codeExpired:
            emitState()
            sendPairRejection("配对码已过期，请在 Mac 上生成新码。", to: central)
            return
        case .invalidCode(let remainingAttempts):
            emitState()
            sendPairRejection("配对码不正确，还可尝试 \(remainingAttempts) 次。", to: central)
            return
        case .locked(let deadline):
            emitState()
            let wait = max(Int(ceil(deadline.timeIntervalSince(now))), 1)
            sendPairRejection("配对尝试过多，请等待 \(wait) 秒后重试。", to: central)
            return
        case .accepted:
            // The gate consumed the code before any fallible credential operation.
            // Rotate it now as an additional replay barrier while leaving pairing closed.
            rotatePairingCode()
            emitState()
        }

        do {
            let credential = try credentialVault.issueCredential(
                deviceID: request.deviceID,
                deviceName: request.deviceName,
                pairedAt: now
            )
            // Issuing again for the same device rotates its token. Any earlier
            // connection for that device must stop receiving updates immediately.
            deauthorizeCentrals(for: credential.deviceID)
            centralAuthorizations.authorize(
                centralID: central.identifier,
                deviceID: credential.deviceID
            )
            enqueue(
                message: .pairAccepted(
                    PairAcceptance(
                        token: credential.token,
                        serverDeviceID: serverDeviceID,
                        serverDeviceName: serverDeviceName
                    )
                ),
                on: statusCharacteristic,
                centrals: [central]
            )
            pairedDevicesDidChange?()
        } catch {
            sendPairRejection("无法保存配对凭据；配对码已作废，请在 Mac 上重试。", to: central)
            report(error: error)
        }
    }

    private func schedulePairingTransition() {
        pairingTransitionTask?.cancel()
        pairingTransitionTask = nil

        let now = Date()
        guard let deadline = pairingGate.nextTransitionDate(after: now) else {
            return
        }
        let delay = max(deadline.timeIntervalSince(now), 0)
        pairingTransitionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.emitState()
            self.schedulePairingTransition()
        }
    }

    private func sendPairRejection(_ reason: String, to central: CBCentral) {
        enqueue(
            message: .pairRejected(PairRejection(reason: reason)),
            on: statusCharacteristic,
            centrals: [central]
        )
    }

    private func handle(_ command: AuthenticatedCommand, central: CBCentral) async {
        let now = Date()
        transportLog.notice("Control received: age=\(now.timeIntervalSince(command.sentAt))s queuedFrames=\(self.pendingUpdates.count)")
        do {
            let credential = try authenticate(command, now: now)
            centralAuthorizations.authorize(
                centralID: central.identifier,
                deviceID: credential.deviceID
            )

            if case .collaboration(let request) = command.action {
                guard let collaborationHandler else {
                    throw MobilityBLEPeripheralError.commandHandlerUnavailable
                }
                let response = await collaborationHandler(request, credential.deviceID)
                guard isAuthorizationCurrent(centralID: central.identifier,
                    deviceID: credential.deviceID, token: command.token) else { return }
                enqueue(message: .collaboration(response), on: eventCharacteristic, centrals: [central])
                return
            }

            if case .fileSync(let message) = command.action {
                guard isFileSyncPublishingEnabled else {
                    enqueue(
                        message: .fileSync(Self.fileSyncDisabledFailure(for: message)),
                        on: eventCharacteristic,
                        centrals: [central]
                    )
                    return
                }
                guard let fileSyncMessageHandler else {
                    throw MobilityBLEPeripheralError.commandHandlerUnavailable
                }
                let responses = try await fileSyncMessageHandler(message, credential.deviceID)

                // File IO may suspend for a noticeable time. A revoked phone must not receive
                // a queued chunk or completion after local revocation finishes.
                guard isAuthorizationCurrent(
                    centralID: central.identifier,
                    deviceID: credential.deviceID,
                    token: command.token
                ) else {
                    return
                }
                guard isFileSyncPublishingEnabled else {
                    enqueue(
                        message: .fileSync(Self.fileSyncDisabledFailure(for: message)),
                        on: eventCharacteristic,
                        centrals: [central]
                    )
                    return
                }
                for response in responses {
                    enqueue(
                        message: .fileSync(response),
                        on: eventCharacteristic,
                        centrals: [central],
                        isFileSyncPayload: true
                    )
                }
                return
            }

            let outcome: MobilityMacCommandOutcome
            if let commandDelegate {
                outcome = try await commandDelegate.handleMobilityAction(command.action)
            } else if let commandHandler {
                outcome = try await commandHandler(command.action)
            } else if isStatusPublishingEnabled,
                      case .requestStatus = command.action,
                      let latestStatus {
                outcome = MobilityMacCommandOutcome(accepted: true, message: "状态已刷新。", status: latestStatus)
            } else {
                throw MobilityBLEPeripheralError.commandHandlerUnavailable
            }

            // The command handler may suspend. Recheck after it returns so a local
            // revocation that happened meanwhile cannot leak a result or status.
            guard isAuthorizationCurrent(
                centralID: central.identifier,
                deviceID: credential.deviceID,
                token: command.token
            ) else {
                return
            }

            let responseStatus = isStatusPublishingEnabled ? outcome.status : nil
            if let status = responseStatus {
                latestStatus = status
            }
            enqueue(
                message: .result(
                    CommandResult(
                        nonce: command.nonce,
                        accepted: outcome.accepted,
                        message: outcome.message,
                        status: responseStatus
                    )
                ),
                on: statusCharacteristic,
                centrals: [central]
            )
        } catch {
            enqueue(
                message: .result(
                    CommandResult(
                        nonce: command.nonce,
                        accepted: false,
                        message: error.localizedDescription,
                        status: isStatusPublishingEnabled
                            && centralAuthorizations.isAuthorized(centralID: central.identifier)
                            ? latestStatus
                            : nil
                    )
                ),
                on: statusCharacteristic,
                centrals: [central]
            )
            report(error: error)
        }
    }

    private func authenticate(
        _ command: AuthenticatedCommand,
        now: Date
    ) throws -> MobilityMacPairingCredential {
        guard abs(now.timeIntervalSince(command.sentAt)) <= commandValidityWindow else {
            throw MobilityBLEPeripheralError.commandExpired
        }
        guard let credential = try credentialVault.credential(matchingToken: command.token) else {
            throw MobilityBLEPeripheralError.invalidToken
        }

        seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) <= nonceRetentionWindow }
        guard seenNonces[command.nonce] == nil else {
            throw MobilityBLEPeripheralError.replayedNonce
        }
        seenNonces[command.nonce] = now
        return credential
    }

    private func enqueue(
        message: ServerMessage,
        on characteristic: CBMutableCharacteristic?,
        centrals: [CBCentral]?,
        isBroadcast: Bool = false,
        isFileSyncPayload: Bool = false
    ) {
        guard let characteristic else { return }
        do {
            let isFilePayload: Bool
            let offerID: UUID?
            if case .fileSync(let syncMessage) = message {
                isFilePayload = true
                if case .offer(let offer) = syncMessage { offerID = offer.metadata.transferID }
                else { offerID = nil }
            } else {
                isFilePayload = isFileSyncPayload
                offerID = nil
            }
            if let offerID, pendingUpdates.contains(where: {
                $0.offerID == offerID
                    && Set(($0.centrals ?? []).map(\.identifier)) == Set((centrals ?? []).map(\.identifier))
            }) { return }
            let envelope = ServerEnvelope(message: message)
            let payload = try jsonCodec.encode(envelope)
            let maximumFrameSize = maximumFrameSize(for: characteristic, targetedCentrals: centrals)
            let frames = try frameCodec.encode(
                payload,
                messageID: envelope.messageID,
                maximumFrameSize: maximumFrameSize
            )
            // File chunks remain resumable in the file store. Never let bulk data
            // consume unlimited memory or hold telemetry/control behind a directory scan.
            if isFilePayload && (pendingUpdates.filter(\.isFileSyncPayload).count + frames.count > 256) {
                reportQueuePressure()
                return
            }
            if pendingUpdates.count + frames.count > 512 {
                pendingUpdates.removeAll { $0.isFileSyncPayload || $0.isCoalescibleStatusBroadcast }
            }
            guard pendingUpdates.count + frames.count <= 512 else {
                reportQueuePressure()
                return
            }
            if !isBroadcast && !isFilePayload {
                transportLog.notice("Control response: bytes=\(payload.count) frames=\(frames.count) mtu=\(maximumFrameSize)")
            }
            let updates = frames.map {
                QueuedUpdate(
                    data: $0,
                    characteristic: characteristic,
                    centrals: centrals,
                    isCoalescibleStatusBroadcast: isBroadcast,
                    isStatusPayload: Self.containsStatusPayload(message),
                    isFileSyncPayload: isFilePayload,
                    offerID: offerID
                )
            }
            let insertionIndex = isFilePayload ? pendingUpdates.endIndex
                : (pendingUpdates.firstIndex(where: \.isFileSyncPayload) ?? pendingUpdates.endIndex)
            pendingUpdates.insert(contentsOf: updates, at: insertionIndex)
            flushPendingUpdates()
        } catch {
            report(error: MobilityBLEPeripheralError.wireEncodingFailed(error.localizedDescription))
        }
    }

    private func reportQueuePressure() {
        let now = Date()
        guard now.timeIntervalSince(lastQueueWarningAt) >= 10 else { return }
        lastQueueWarningAt = now
        transportLog.warning("BLE queue bounded; bulk transfer will retry. queuedFrames=\(self.pendingUpdates.count)")
    }

    private static func fileSyncDisabledFailure(for message: SyncWireMessage) -> SyncWireMessage {
        .failure(
            SyncFailure(
                transferID: message.transferID,
                code: .unavailable,
                message: "Mac 设置中的“双向文件同步”模块已关闭。",
                retryable: false
            )
        )
    }

    private static func containsStatusPayload(_ message: ServerMessage) -> Bool {
        switch message {
        case .status:
            true
        case .result(let result):
            result.status != nil
        case .pairAccepted, .pairRejected, .fileSync, .collaboration:
            false
        }
    }

    private func maximumFrameSize(
        for characteristic: CBMutableCharacteristic,
        targetedCentrals: [CBCentral]?
    ) -> Int {
        let subscribed = targetedCentrals ?? characteristic.subscribedCentrals ?? []
        return subscribed.map(\.maximumUpdateValueLength).min() ?? 185
    }

    private func flushPendingUpdates() {
        while let next = pendingUpdates.first {
            let sent = peripheralManager.updateValue(
                next.data,
                for: next.characteristic,
                onSubscribedCentrals: next.centrals
            )
            guard sent else { return }
            pendingUpdates.removeFirst()
        }

        if let deferredBroadcastStatus {
            self.deferredBroadcastStatus = nil
            publishStatus(deferredBroadcastStatus)
        }
    }

    private func authorizedSubscribers(of characteristic: CBMutableCharacteristic) -> [CBCentral] {
        (characteristic.subscribedCentrals ?? []).filter {
            centralAuthorizations.isAuthorized(centralID: $0.identifier)
        }
    }

    private func isAuthorizationCurrent(centralID: UUID, deviceID: UUID, token: String) -> Bool {
        guard centralAuthorizations.deviceID(for: centralID) == deviceID else {
            return false
        }
        return (try? credentialVault.credential(matchingToken: token))?.deviceID == deviceID
    }

    private func deauthorizeCentrals(for deviceID: UUID) {
        let revokedCentralIDs = centralAuthorizations.revoke(deviceID: deviceID)
        guard !revokedCentralIDs.isEmpty else { return }

        // Core Bluetooth updates already handed to the OS cannot be recalled, but
        // no queued or future application update may target a revoked connection.
        pendingUpdates = pendingUpdates.compactMap { update in
            guard let targetedCentrals = update.centrals else {
                return nil
            }
            let remaining = targetedCentrals.filter {
                !revokedCentralIDs.contains($0.identifier)
            }
            guard !remaining.isEmpty else { return nil }
            var retained = update
            retained.centrals = remaining
            return retained
        }
        deferredBroadcastStatus = nil
    }

    private func respondToStatusRead(_ request: CBATTRequest) {
        let message: ServerMessage
        if !isStatusPublishingEnabled {
            message = .result(
                CommandResult(
                    nonce: UUID(),
                    accepted: false,
                    message: "Mac 设置中的“设备状态”模块已关闭。"
                )
            )
        } else if centralAuthorizations.isAuthorized(centralID: request.central.identifier),
                  let latestStatus {
            message = .status(latestStatus)
        } else {
            message = .result(
                CommandResult(
                    nonce: UUID(),
                    accepted: false,
                    message: "请先使用配对令牌请求状态。"
                )
            )
        }

        do {
            let envelope = ServerEnvelope(message: message)
            let payload = try jsonCodec.encode(envelope)
            let frames = try frameCodec.encode(
                payload,
                messageID: envelope.messageID,
                maximumFrameSize: request.central.maximumUpdateValueLength
            )
            guard let first = frames.first else {
                peripheralManager.respond(to: request, withResult: .unlikelyError)
                return
            }
            request.value = first
            peripheralManager.respond(to: request, withResult: .success)
            if let statusCharacteristic, frames.count > 1 {
                pendingUpdates.append(contentsOf: frames.dropFirst().map {
                    QueuedUpdate(
                        data: $0,
                        characteristic: statusCharacteristic,
                        centrals: [request.central],
                        isStatusPayload: Self.containsStatusPayload(message)
                    )
                })
                flushPendingUpdates()
            }
        } catch {
            peripheralManager.respond(to: request, withResult: .unlikelyError)
            report(error: error)
        }
    }

    private func updateConnectedCentralCount() {
        let characteristics = [pairingCharacteristic, controlCharacteristic, statusCharacteristic, eventCharacteristic]
        let identifiers = characteristics
            .compactMap { $0?.subscribedCentrals }
            .flatMap { $0 }
            .map(\.identifier)
        connectedCentralCount = Set(identifiers).count
        emitState()
    }

    private func report(error: Error) {
        lastErrorMessage = error.localizedDescription
        emitState()
    }

    private func emitState() {
        stateDidChange?(state)
    }
}

extension MobilityBLEPeripheral: @preconcurrency CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        availability = switch peripheral.state {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .unauthorized
        case .poweredOff: .poweredOff
        case .poweredOn: .poweredOn
        @unknown default: .unknown
        }

        if peripheral.state == .poweredOn {
            lastErrorMessage = nil
            registerServiceIfNeeded()
            startAdvertisingIfReady()
        } else if peripheral.state != .unknown && peripheral.state != .resetting {
            isAdvertising = false
            if wantsAdvertising {
                lastErrorMessage = MobilityBLEPeripheralError.bluetoothUnavailable.localizedDescription
            }
        }
        emitState()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard service.uuid == CBUUID(nsuuid: MobilityBLEUUIDs.service) else { return }
        if let error {
            serviceWasAdded = false
            report(error: MobilityBLEPeripheralError.serviceRegistrationFailed(error.localizedDescription))
            return
        }
        serviceWasAdded = true
        startAdvertisingIfReady()
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            isAdvertising = false
            report(error: error)
        } else {
            isAdvertising = true
            lastErrorMessage = nil
            emitState()
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushPendingUpdates()
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        knownCentrals[central.identifier] = central
        updateConnectedCentralCount()
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        updateConnectedCentralCount()
        // A queued frame targets a specific subscription. Remove that recipient
        // immediately so a reconnect cannot be blocked behind an obsolete central.
        pendingUpdates = pendingUpdates.compactMap { update in
            guard update.characteristic.uuid == characteristic.uuid else { return update }
            guard let targets = update.centrals else { return nil }
            let remaining = targets.filter { $0.identifier != central.identifier }
            guard !remaining.isEmpty else { return nil }
            var retained = update
            retained.centrals = remaining
            return retained
        }
        lastPublishedOffers.removeAll()
        let remainsSubscribed = [pairingCharacteristic, controlCharacteristic, statusCharacteristic, eventCharacteristic]
            .compactMap { $0?.subscribedCentrals }
            .flatMap { $0 }
            .contains { $0.identifier == central.identifier }
        if !remainsSubscribed {
            centralAuthorizations.remove(centralID: central.identifier)
            reassemblers[central.identifier] = nil
            knownCentrals[central.identifier] = nil
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard
            request.characteristic.uuid == CBUUID(nsuuid: MobilityBLEUUIDs.status),
            request.offset == 0
        else {
            peripheral.respond(to: request, withResult: request.offset == 0 ? .readNotPermitted : .invalidOffset)
            return
        }
        knownCentrals[request.central.identifier] = request.central
        respondToStatusRead(request)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.offset == 0, let value = request.value else {
                peripheral.respond(
                    to: request,
                    withResult: request.offset == 0 ? .invalidAttributeValueLength : .invalidOffset
                )
                continue
            }

            let channel: WriteChannel
            if request.characteristic.uuid == CBUUID(nsuuid: MobilityBLEUUIDs.pairing) {
                channel = .pairing
            } else if request.characteristic.uuid == CBUUID(nsuuid: MobilityBLEUUIDs.control) {
                channel = .control
            } else {
                peripheral.respond(to: request, withResult: .writeNotPermitted)
                continue
            }

            knownCentrals[request.central.identifier] = request.central
            do {
                var reassembler = reassemblers[request.central.identifier] ?? MobilityFrameReassembler()
                let completed = try reassembler.ingest(value)
                reassemblers[request.central.identifier] = reassembler
                let envelope = try completed.map { try jsonCodec.decodeClient($0.payload) }
                peripheral.respond(to: request, withResult: .success)
                if let envelope {
                    process(envelope, channel: channel, central: request.central)
                }
            } catch {
                reassemblers[request.central.identifier] = nil
                peripheral.respond(to: request, withResult: .invalidPdu)
                report(error: error)
            }
        }
    }
}
