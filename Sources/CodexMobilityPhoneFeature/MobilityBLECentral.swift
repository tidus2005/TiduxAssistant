@preconcurrency import CoreBluetooth
import CodexMobilityCore
import Foundation

public struct MobilityDiscoveredComputer: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var signalStrength: Int
    public var lastSeenAt: Date

    public init(id: UUID, name: String, signalStrength: Int, lastSeenAt: Date = Date()) {
        self.id = id
        self.name = name
        self.signalStrength = signalStrength
        self.lastSeenAt = lastSeenAt
    }
}

public enum MobilityBluetoothAvailability: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

public enum MobilityBLEConnectionPhase: Equatable, Sendable {
    case idle
    case scanning
    case connecting(UUID)
    case discovering(UUID)
    case ready(UUID)
    case reconnecting(UUID)

    public var peripheralIdentifier: UUID? {
        switch self {
        case .idle, .scanning:
            nil
        case .connecting(let identifier),
             .discovering(let identifier),
             .ready(let identifier),
             .reconnecting(let identifier):
            identifier
        }
    }
}

public struct MobilityBLEConfiguration: Sendable {
    public let serviceUUID: UUID
    public let pairingCharacteristicUUID: UUID
    public let encryptedControlCharacteristicUUID: UUID
    public let encryptedStatusCharacteristicUUID: UUID
    public let eventCharacteristicUUID: UUID
    public let restorationIdentifier: String

    public init(
        serviceUUID: UUID = MobilityBLEUUIDs.service,
        pairingCharacteristicUUID: UUID = MobilityBLEUUIDs.pairing,
        encryptedControlCharacteristicUUID: UUID = MobilityBLEUUIDs.control,
        encryptedStatusCharacteristicUUID: UUID = MobilityBLEUUIDs.status,
        eventCharacteristicUUID: UUID = MobilityBLEUUIDs.event,
        restorationIdentifier: String = "com.tidux.codex-mobility.phone-central"
    ) {
        self.serviceUUID = serviceUUID
        self.pairingCharacteristicUUID = pairingCharacteristicUUID
        self.encryptedControlCharacteristicUUID = encryptedControlCharacteristicUUID
        self.encryptedStatusCharacteristicUUID = encryptedStatusCharacteristicUUID
        self.eventCharacteristicUUID = eventCharacteristicUUID
        self.restorationIdentifier = restorationIdentifier
    }
}

public enum MobilityBLEWriteChannel: Equatable, Sendable {
    case pairing
    case control
}

public enum MobilityBLEInboundChannel: Equatable, Sendable {
    case status
    case event
}

enum MobilityBLEPeripheralLinkState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting

    init(_ state: CBPeripheralState) {
        self = switch state {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        @unknown default: .disconnected
        }
    }
}

enum MobilityBLERecoveryAction: Equatable {
    case scan
    case connect
    case discover
    case wait
}

enum MobilityBLEDisconnectRecoveryAction: Equatable {
    case ignore
    case awaitSystemReconnect
    case scheduleReconnect
}

enum MobilityBLESetupStage: Equatable {
    case services
    case characteristics
    case subscriptions
}

enum MobilityBLESetupWatchdogAction: Equatable {
    case ignore
    case recover
}

enum MobilityBLERecoveryPlanner {
    static func isPairingFailure(_ error: NSError) -> Bool {
        error.domain == CBErrorDomain &&
            (error.code == CBError.encryptionTimedOut.rawValue || error.code == CBError.peerRemovedPairingInformation.rawValue)
    }
    static func shouldRestartPendingConnection(userRequested: Bool,
        linkState: MobilityBLEPeripheralLinkState, requestPending: Bool) -> Bool {
        // Restored peripherals may already be connecting before this process has
        // registered its own request marker. The framework state is authoritative.
        userRequested && (linkState == .connecting || (linkState == .disconnected && requestPending))
    }

    static func canScan(hasActivePeripheral: Bool, phase: MobilityBLEConnectionPhase,
                        explicitRescan: Bool) -> Bool {
        guard hasActivePeripheral else { return true }
        guard explicitRescan else { return false }
        switch phase {
        case .connecting, .reconnecting: return true
        case .idle, .scanning, .discovering, .ready: return false
        }
    }

    static func action(
        hasReconnectTarget: Bool,
        recoveredPeripheralState: MobilityBLEPeripheralLinkState?,
        connectionRequestPending: Bool,
        systemReconnectPending: Bool = false
    ) -> MobilityBLERecoveryAction {
        guard hasReconnectTarget, let recoveredPeripheralState else {
            return .scan
        }

        return switch recoveredPeripheralState {
        case .disconnected:
            connectionRequestPending || systemReconnectPending ? .wait : .connect
        case .connecting, .disconnecting:
            .wait
        case .connected:
            .discover
        }
    }

    static func disconnectAction(
        isActivePeripheral: Bool,
        hasReconnectTarget: Bool,
        isSystemReconnecting: Bool
    ) -> MobilityBLEDisconnectRecoveryAction {
        guard isActivePeripheral, hasReconnectTarget else {
            return .ignore
        }
        return isSystemReconnecting ? .awaitSystemReconnect : .scheduleReconnect
    }

    static func watchdogAction(
        watchedStage: MobilityBLESetupStage,
        currentStage: MobilityBLESetupStage?,
        isDiscoveringActivePeripheral: Bool
    ) -> MobilityBLESetupWatchdogAction {
        guard isDiscoveringActivePeripheral, currentStage == watchedStage else {
            return .ignore
        }
        return .recover
    }
}

@MainActor
public protocol MobilityBLECentralDelegate: AnyObject {
    func mobilityCentral(_ central: MobilityBLECentral, didChange availability: MobilityBluetoothAvailability)
    func mobilityCentral(_ central: MobilityBLECentral, didDiscover computers: [MobilityDiscoveredComputer])
    func mobilityCentral(_ central: MobilityBLECentral, didChange phase: MobilityBLEConnectionPhase)
    func mobilityCentral(
        _ central: MobilityBLECentral,
        didReceive frame: Data,
        on channel: MobilityBLEInboundChannel,
        from peripheralIdentifier: UUID
    )
    func mobilityCentral(_ central: MobilityBLECentral, didFail error: MobilityBLECentralError)
}

public enum MobilityBLECentralError: LocalizedError, Equatable, Sendable {
    case bluetoothUnavailable
    case computerNotFound
    case connectionFailed(String)
    case mobilityServiceMissing
    case mobilityCharacteristicsMissing
    case notificationSubscriptionFailed(String)
    case notReady
    case frameTooLarge(maximumBytes: Int)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            "蓝牙当前不可用。"
        case .computerNotFound:
            "没有找到这台 Mac，请让 Mac 端保持随行配对页面开启。"
        case .connectionFailed(let detail):
            "连接 Mac 失败：\(detail)"
        case .mobilityServiceMissing:
            "这台设备没有提供 Codex Mobility 服务。"
        case .mobilityCharacteristicsMissing:
            "Mac 端的加密控制或状态通道不完整。"
        case .notificationSubscriptionFailed(let detail):
            "订阅 Mac 状态失败：\(detail)"
        case .notReady:
            "Mac 控制通道尚未就绪。"
        case .frameTooLarge(let maximumBytes):
            "控制消息超过当前蓝牙连接上限（\(maximumBytes) 字节）。"
        case .writeFailed(let detail):
            "向 Mac 写入控制消息失败：\(detail)"
        }
    }
}

/// Core Bluetooth central used by the phone feature.
///
/// The central intentionally runs on the main queue. Every control frame is serialized and
/// written with `.withResponse`; the next frame is not sent until Core Bluetooth acknowledges
/// the previous write. State preservation uses a stable restoration identifier, while actual
/// background execution remains subject to iOS scheduling.
@MainActor
public final class MobilityBLECentral: NSObject {
    public weak var delegate: MobilityBLECentralDelegate?

    public private(set) var computers: [MobilityDiscoveredComputer] = []
    public private(set) var phase: MobilityBLEConnectionPhase = .idle

    private let configuration: MobilityBLEConfiguration
    private var centralManager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var pairingCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var eventCharacteristic: CBCharacteristic?
    private struct QueuedWrite {
        var data: Data
        var characteristic: CBCharacteristic
    }
    private var queuedWrites: [QueuedWrite] = []
    private var writeInFlight = false
    private var statusSubscribed = false
    private var eventSubscriptionRequired = false
    private var eventSubscribed = false
    private var shouldScan = false
    private var reconnectAttempt = 0
    private var reconnectTargetIdentifier: UUID?
    private var connectionRequestIdentifier: UUID?
    private var systemReconnectIdentifier: UUID?
    private var reconnectTask: Task<Void, Never>?
    private var setupWatchdogTask: Task<Void, Never>?
    private var setupStage: MobilityBLESetupStage?
    private var writeWatchdogTask: Task<Void, Never>?
    private var writeGeneration = UUID()

    private static let setupWatchdogDuration: Duration = .seconds(12)

    private var serviceUUID: CBUUID { CBUUID(nsuuid: configuration.serviceUUID) }
    private var pairingUUID: CBUUID { CBUUID(nsuuid: configuration.pairingCharacteristicUUID) }
    private var controlUUID: CBUUID { CBUUID(nsuuid: configuration.encryptedControlCharacteristicUUID) }
    private var statusUUID: CBUUID { CBUUID(nsuuid: configuration.encryptedStatusCharacteristicUUID) }
    private var eventUUID: CBUUID { CBUUID(nsuuid: configuration.eventCharacteristicUUID) }

    public init(configuration: MobilityBLEConfiguration) {
        self.configuration = configuration
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: configuration.restorationIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    public func start() {
        centralManagerDidUpdateState(centralManager)
        shouldScan = true
        guard centralManager.state == .poweredOn else {
            return
        }
        startScanningIfNeeded()
    }

    public func rescan() {
        centralManagerDidUpdateState(centralManager)
        shouldScan = true
        computers = []
        peripherals = activePeripheral.map { [$0.identifier: $0] } ?? [:]
        delegate?.mobilityCentral(self, didDiscover: computers)
        // A pending connect can wait forever when a saved peripheral is no longer
        // reachable. Explicit discovery must still find the current advertisement,
        // without cancelling the system's background reconnect or deleting trust.
        startScanningIfNeeded(explicitRescan: true)
    }

    /// Called only by the user's explicit system-accessory repair action.
    public func pauseForAccessoryRepair() {
        let previous = activePeripheral
        shouldScan = false
        centralManager.stopScan()
        suspendConnection()
        reconnectTargetIdentifier = nil
        if let previous { centralManager.cancelPeripheralConnection(previous) }
    }

    public func restoreKnownPeripherals(with identifiers: [UUID]) {
        guard !identifiers.isEmpty else { return }
        let restored = centralManager.retrievePeripherals(withIdentifiers: identifiers)
        for peripheral in restored {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            let computer = MobilityDiscoveredComputer(
                id: peripheral.identifier,
                name: peripheral.name ?? "已配对的 Mac",
                signalStrength: 0,
                lastSeenAt: .distantPast
            )
            if let index = computers.firstIndex(where: { $0.id == peripheral.identifier }) {
                computers[index] = computer
            } else {
                computers.append(computer)
            }
        }
        if !restored.isEmpty {
            delegate?.mobilityCentral(self, didDiscover: computers)
            if activePeripheral == nil, let paired = restored.first {
                // A saved, trusted peripheral need not be rediscovered in an advert.
                // Register the connection even when launched directly into background.
                resume(paired, connectingPhase: .reconnecting(paired.identifier))
            }
        }
    }

    public func connect(to peripheralIdentifier: UUID, restartPendingConnection: Bool = false) {
        guard let peripheral = peripherals[peripheralIdentifier] else {
            delegate?.mobilityCentral(self, didFail: .computerNotFound)
            return
        }

        reconnectTargetIdentifier = peripheralIdentifier
        guard centralManager.state == .poweredOn else {
            suspendConnection(preserving: peripheralIdentifier)
            return
        }

        if centralManager.state == .poweredOn {
            centralManager.stopScan()
        }
        if let activePeripheral, activePeripheral.identifier != peripheralIdentifier {
            connectionRequestIdentifier = nil
            systemReconnectIdentifier = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            cancelSetupWatchdog()
            centralManager.cancelPeripheralConnection(activePeripheral)
        }

        if activePeripheral?.identifier == peripheralIdentifier {
            recordConnectionDiagnostic("selected state=\(peripheral.state.rawValue) retry=\(restartPendingConnection)")
            if MobilityBLERecoveryPlanner.shouldRestartPendingConnection(
                userRequested: restartPendingConnection,
                linkState: MobilityBLEPeripheralLinkState(peripheral.state),
                requestPending: connectionRequestIdentifier == peripheralIdentifier
                    || systemReconnectIdentifier == peripheralIdentifier) {
                recordConnectionDiagnostic("userRetry state=\(peripheral.state.rawValue)")
                recoverFromSetupFailure(peripheral, failure: nil)
                return
            }
            resume(peripheral, connectingPhase: .connecting(peripheralIdentifier))
            return
        }

        resetConnectionChannels(clearQueuedWrites: true)
        activePeripheral = peripheral
        peripheral.delegate = self
        reconnectAttempt = 0
        resume(peripheral, connectingPhase: .connecting(peripheralIdentifier))
    }

    public func maximumFrameSize(for channel: MobilityBLEWriteChannel) throws -> Int {
        guard
            case .ready = phase,
            let peripheral = activePeripheral,
            characteristic(for: channel) != nil
        else {
            throw MobilityBLECentralError.notReady
        }
        return peripheral.maximumWriteValueLength(for: .withResponse)
    }

    public func enqueue(frames: [Data], on channel: MobilityBLEWriteChannel) throws {
        guard
            case .ready = phase,
            let peripheral = activePeripheral,
            let characteristic = characteristic(for: channel)
        else {
            throw MobilityBLECentralError.notReady
        }
        let maximum = peripheral.maximumWriteValueLength(for: .withResponse)
        if let oversized = frames.first(where: { $0.count > maximum }) {
            _ = oversized
            throw MobilityBLECentralError.frameTooLarge(maximumBytes: maximum)
        }
        queuedWrites.append(contentsOf: frames.map { QueuedWrite(data: $0, characteristic: characteristic) })
        flushNextWriteIfPossible()
    }

    private func startScanningIfNeeded(explicitRescan: Bool = false) {
        guard shouldScan, centralManager.state == .poweredOn,
              MobilityBLERecoveryPlanner.canScan(hasActivePeripheral: activePeripheral != nil,
                  phase: phase, explicitRescan: explicitRescan) else {
            return
        }
        if activePeripheral == nil { updatePhase(.scanning) }
        recordConnectionDiagnostic("scan explicit=\(explicitRescan) pending=\(activePeripheral != nil)")
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func updatePhase(_ next: MobilityBLEConnectionPhase) {
        guard phase != next else { return }
        phase = next
        recordConnectionDiagnostic("phase=\(next)")
        delegate?.mobilityCentral(self, didChange: next)
    }

    /// Bounded local transport evidence only; never record tokens, frames or user data.
    private func recordConnectionDiagnostic(_ event: String) {
        let key = "mobility.bleConnectionDiagnostics"
        var entries = UserDefaults.standard.stringArray(forKey: key) ?? []
        entries.append("\(Date().timeIntervalSince1970) \(event)")
        UserDefaults.standard.set(Array(entries.suffix(60)), forKey: key)
    }

    private func resetConnectionChannels(clearQueuedWrites: Bool) {
        writeWatchdogTask?.cancel()
        writeWatchdogTask = nil
        writeGeneration = UUID()
        pairingCharacteristic = nil
        controlCharacteristic = nil
        statusCharacteristic = nil
        eventCharacteristic = nil
        writeInFlight = false
        statusSubscribed = false
        eventSubscriptionRequired = false
        eventSubscribed = false
        if clearQueuedWrites {
            queuedWrites.removeAll()
        }
    }

    private func cancelSetupWatchdog() {
        setupWatchdogTask?.cancel()
        setupWatchdogTask = nil
        setupStage = nil
    }

    private func scheduleSetupWatchdog(
        for stage: MobilityBLESetupStage,
        peripheral: CBPeripheral
    ) {
        setupWatchdogTask?.cancel()
        setupStage = stage
        let peripheralIdentifier = peripheral.identifier
        setupWatchdogTask = Task { @MainActor [weak self, weak peripheral] in
            do {
                try await Task.sleep(for: Self.setupWatchdogDuration)
            } catch {
                return
            }
            guard let self, let peripheral else { return }
            let isDiscoveringActivePeripheral = self.activePeripheral?.identifier == peripheralIdentifier
                && self.phase == .discovering(peripheralIdentifier)
            guard MobilityBLERecoveryPlanner.watchdogAction(
                watchedStage: stage,
                currentStage: self.setupStage,
                isDiscoveringActivePeripheral: isDiscoveringActivePeripheral
            ) == .recover else {
                return
            }

            let failure: MobilityBLECentralError = switch stage {
            case .services:
                .connectionFailed("发现 Mobility 服务超时")
            case .characteristics:
                .connectionFailed("发现 Mobility 通道超时")
            case .subscriptions:
                .notificationSubscriptionFailed("等待 Mac 确认通知订阅超时")
            }
            self.recoverFromSetupFailure(peripheral, failure: failure)
        }
    }

    private func beginServiceDiscovery(_ peripheral: CBPeripheral) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionRequestIdentifier = nil
        systemReconnectIdentifier = nil
        resetConnectionChannels(clearQueuedWrites: true)
        updatePhase(.discovering(peripheral.identifier))
        scheduleSetupWatchdog(for: .services, peripheral: peripheral)
        peripheral.discoverServices([serviceUUID])
    }

    private func recoverFromSetupFailure(
        _ peripheral: CBPeripheral,
        failure: MobilityBLECentralError?
    ) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        cancelSetupWatchdog()
        connectionRequestIdentifier = nil
        systemReconnectIdentifier = nil
        resetConnectionChannels(clearQueuedWrites: true)
        updatePhase(.reconnecting(peripheral.identifier))
        if let failure { delegate?.mobilityCentral(self, didFail: failure) }

        if peripheral.state == .disconnected {
            scheduleReconnect(peripheral)
        } else {
            centralManager.cancelPeripheralConnection(peripheral)
            // The disconnect callback normally drives recovery. Keep a backoff task as a
            // fallback so a delayed callback cannot leave the state machine stranded.
            scheduleReconnect(peripheral)
        }
    }

    private func flushNextWriteIfPossible() {
        guard
            !writeInFlight,
            let queuedWrite = queuedWrites.first,
            let peripheral = activePeripheral,
            case .ready = phase
        else {
            return
        }
        writeInFlight = true
        let generation = UUID()
        writeGeneration = generation
        writeWatchdogTask?.cancel()
        writeWatchdogTask = Task { @MainActor [weak self, weak peripheral] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, let peripheral, self.writeInFlight,
                  self.writeGeneration == generation,
                  self.activePeripheral?.identifier == peripheral.identifier else { return }
            self.recoverFromSetupFailure(peripheral,
                failure: .writeFailed("蓝牙写入确认超时，正在重新连接；未确认操作不会自动重发。"))
        }
        peripheral.writeValue(queuedWrite.data, for: queuedWrite.characteristic, type: .withResponse)
    }

    /// A connected radio is not proof that the application protocol is responsive.
    /// Leave an out-of-range system connection pending; only reset an unhealthy ready link.
    public func recoverUnresponsiveLink() {
        guard let peripheral = activePeripheral, case .ready = phase else { return }
        recoverFromSetupFailure(peripheral,
            failure: .connectionFailed("Mac 状态持续未更新，正在恢复蓝牙连接。"))
    }

    private func characteristic(for channel: MobilityBLEWriteChannel) -> CBCharacteristic? {
        switch channel {
        case .pairing: pairingCharacteristic
        case .control: controlCharacteristic
        }
    }

    private func handleDisconnect(
        _ peripheral: CBPeripheral,
        isSystemReconnecting: Bool,
        error: Error?
    ) {
        let failure = error as NSError?
        recordConnectionDiagnostic("disconnected state=\(peripheral.state.rawValue) systemRetry=\(isSystemReconnecting) domain=\(failure?.domain ?? "none") code=\(failure?.code ?? 0)")
        let action = MobilityBLERecoveryPlanner.disconnectAction(
            isActivePeripheral: activePeripheral?.identifier == peripheral.identifier,
            hasReconnectTarget: reconnectTargetIdentifier == peripheral.identifier,
            isSystemReconnecting: isSystemReconnecting
        )
        guard action != .ignore else { return }

        cancelSetupWatchdog()
        connectionRequestIdentifier = nil
        resetConnectionChannels(clearQueuedWrites: true)
        updatePhase(.reconnecting(peripheral.identifier))
        if let error {
            let detail = MobilityBLERecoveryPlanner.isPairingFailure(error as NSError)
                ? "蓝牙加密握手失败。请在设备页选择“重新配对此 Mac”，恢复系统配件关联。"
                : error.localizedDescription
            delegate?.mobilityCentral(self, didFail: .connectionFailed(detail))
        }

        switch action {
        case .ignore:
            break
        case .awaitSystemReconnect:
            systemReconnectIdentifier = peripheral.identifier
            reconnectTask?.cancel()
            reconnectTask = nil
        case .scheduleReconnect:
            systemReconnectIdentifier = nil
            // Arm Core Bluetooth while this background delegate callback has execution
            // time. The pending connect survives suspension and has no range timeout.
            if peripheral.state == .disconnected { requestConnectionIfNeeded(to: peripheral) }
            else { scheduleReconnect(peripheral) }
        }
    }

    private func scheduleReconnect(_ peripheral: CBPeripheral) {
        guard systemReconnectIdentifier != peripheral.identifier else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 20.0)
        reconnectTask = Task { @MainActor [weak self, weak peripheral] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard
                let self,
                let peripheral,
                self.centralManager.state == .poweredOn,
                self.activePeripheral?.identifier == peripheral.identifier,
                case .reconnecting = self.phase
            else {
                return
            }

            let linkState = MobilityBLEPeripheralLinkState(peripheral.state)
            let action = MobilityBLERecoveryPlanner.action(
                hasReconnectTarget: self.reconnectTargetIdentifier == peripheral.identifier,
                recoveredPeripheralState: linkState,
                connectionRequestPending: self.connectionRequestIdentifier == peripheral.identifier,
                systemReconnectPending: self.systemReconnectIdentifier == peripheral.identifier
            )
            switch action {
            case .connect:
                self.requestConnectionIfNeeded(to: peripheral)
            case .discover:
                self.beginServiceDiscovery(peripheral)
            case .wait:
                if linkState == .disconnecting {
                    self.scheduleReconnect(peripheral)
                }
            case .scan:
                self.activePeripheral = nil
                self.startScanningIfNeeded()
            }
        }
    }

    private func requestConnectionIfNeeded(to peripheral: CBPeripheral) {
        guard centralManager.state == .poweredOn else { return }
        guard systemReconnectIdentifier != peripheral.identifier else { return }
        guard peripheral.state == .disconnected else {
            if peripheral.state == .connecting {
                connectionRequestIdentifier = peripheral.identifier
            }
            return
        }
        guard connectionRequestIdentifier != peripheral.identifier else { return }
        connectionRequestIdentifier = peripheral.identifier
        recordConnectionDiagnostic("connectRequested=\(peripheral.identifier)")
        // Standard pending connects already survive suspension. Optional reconnect /
        // start-delay options were rejected by the physical iPhone with invalidParameters.
        centralManager.connect(peripheral, options: nil)
    }

    private func resume(
        _ peripheral: CBPeripheral,
        connectingPhase: MobilityBLEConnectionPhase
    ) {
        activePeripheral = peripheral
        peripherals[peripheral.identifier] = peripheral
        reconnectTargetIdentifier = peripheral.identifier
        peripheral.delegate = self
        if centralManager.state == .poweredOn {
            centralManager.stopScan()
        }

        let action = MobilityBLERecoveryPlanner.action(
            hasReconnectTarget: true,
            recoveredPeripheralState: MobilityBLEPeripheralLinkState(peripheral.state),
            connectionRequestPending: connectionRequestIdentifier == peripheral.identifier,
            systemReconnectPending: systemReconnectIdentifier == peripheral.identifier
        )
        switch action {
        case .scan:
            activePeripheral = nil
            startScanningIfNeeded()
        case .connect:
            updatePhase(connectingPhase)
            requestConnectionIfNeeded(to: peripheral)
        case .discover:
            beginServiceDiscovery(peripheral)
        case .wait:
            if systemReconnectIdentifier == peripheral.identifier {
                updatePhase(.reconnecting(peripheral.identifier))
            } else {
                updatePhase(connectingPhase)
            }
        }
    }

    private func suspendConnection(preserving identifier: UUID? = nil) {
        reconnectTargetIdentifier = identifier
            ?? activePeripheral?.identifier
            ?? reconnectTargetIdentifier
        connectionRequestIdentifier = nil
        systemReconnectIdentifier = nil
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelSetupWatchdog()
        resetConnectionChannels(clearQueuedWrites: true)
        activePeripheral = nil
        updatePhase(.idle)
    }

    private func resumeAfterBluetoothPoweredOn() {
        guard let reconnectTargetIdentifier else {
            startScanningIfNeeded()
            return
        }

        if let activePeripheral,
           activePeripheral.identifier == reconnectTargetIdentifier {
            if activePeripheral.state == .connected {
                switch phase {
                case .discovering, .ready:
                    return
                case .idle, .scanning, .connecting, .reconnecting:
                    break
                }
            }
            resume(activePeripheral, connectingPhase: .reconnecting(activePeripheral.identifier))
            return
        }

        let restored = centralManager.retrievePeripherals(withIdentifiers: [reconnectTargetIdentifier])
        guard let peripheral = restored.first else {
            activePeripheral = nil
            connectionRequestIdentifier = nil
            startScanningIfNeeded()
            return
        }

        resetConnectionChannels(clearQueuedWrites: true)
        activePeripheral = peripheral
        resume(peripheral, connectingPhase: .reconnecting(peripheral.identifier))
    }

    private func registerRestoredPeripheral(_ peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        reconnectTargetIdentifier = peripheral.identifier
        activePeripheral = peripheral
        peripheral.delegate = self

        let computer = MobilityDiscoveredComputer(
            id: peripheral.identifier,
            name: peripheral.name ?? "已配对的 Mac",
            signalStrength: 0
        )
        computers = [computer]
        delegate?.mobilityCentral(self, didDiscover: computers)

        if centralManager.state == .poweredOn {
            resume(peripheral, connectingPhase: .reconnecting(peripheral.identifier))
        }
    }
}

extension MobilityBLECentral: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        recordConnectionDiagnostic("bluetooth=\(central.state.rawValue)")
        let availability: MobilityBluetoothAvailability = switch central.state {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .unauthorized
        case .poweredOff: .poweredOff
        case .poweredOn: .poweredOn
        @unknown default: .unknown
        }
        delegate?.mobilityCentral(self, didChange: availability)

        switch central.state {
        case .poweredOn:
            resumeAfterBluetoothPoweredOn()
        case .poweredOff, .resetting, .unsupported, .unauthorized:
            suspendConnection()
        case .unknown:
            break
        @unknown default:
            suspendConnection()
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard
            let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
            let peripheral = restored.first
        else {
            return
        }
        shouldScan = true
        registerRestoredPeripheral(peripheral)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        recordConnectionDiagnostic("discovered=\(peripheral.identifier) rssi=\(RSSI.intValue)")
        peripherals[peripheral.identifier] = peripheral
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let computer = MobilityDiscoveredComputer(
            id: peripheral.identifier,
            name: advertisedName ?? peripheral.name ?? "附近的 Mac",
            signalStrength: RSSI.intValue
        )
        if let index = computers.firstIndex(where: { $0.id == peripheral.identifier }) {
            computers[index] = computer
        } else {
            computers.append(computer)
        }
        computers.sort { lhs, rhs in
            if lhs.signalStrength == rhs.signalStrength {
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            } else {
                lhs.signalStrength > rhs.signalStrength
            }
        }

        if reconnectTargetIdentifier == peripheral.identifier, activePeripheral == nil {
            central.stopScan()
            resetConnectionChannels(clearQueuedWrites: true)
            activePeripheral = peripheral
            resume(peripheral, connectingPhase: .reconnecting(peripheral.identifier))
        }
        delegate?.mobilityCentral(self, didDiscover: computers)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        recordConnectionDiagnostic("connected=\(peripheral.identifier)")
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        central.stopScan()
        connectionRequestIdentifier = nil
        systemReconnectIdentifier = nil
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        peripheral.delegate = self
        beginServiceDiscovery(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let failure = error as NSError?
        recordConnectionDiagnostic("connectFailed domain=\(failure?.domain ?? "none") code=\(failure?.code ?? 0)")
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        connectionRequestIdentifier = nil
        systemReconnectIdentifier = nil
        updatePhase(.reconnecting(peripheral.identifier))
        if let error {
            let detail = MobilityBLERecoveryPlanner.isPairingFailure(error as NSError)
                ? "蓝牙加密握手失败。请在设备页选择“重新配对此 Mac”，恢复系统配件关联。"
                : error.localizedDescription
            delegate?.mobilityCentral(self, didFail: .connectionFailed(detail))
        }
        scheduleReconnect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnect(peripheral, isSystemReconnecting: false, error: error)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        _ = timestamp
        handleDisconnect(peripheral, isSystemReconnecting: isReconnecting, error: error)
    }
}

extension MobilityBLECentral: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard activePeripheral?.identifier == peripheral.identifier,
              invalidatedServices.contains(where: { $0.uuid == serviceUUID }) else { return }
        cancelSetupWatchdog()
        resetConnectionChannels(clearQueuedWrites: true)
        updatePhase(.reconnecting(peripheral.identifier))
        if peripheral.state == .connected { beginServiceDiscovery(peripheral) }
        else { requestConnectionIfNeeded(to: peripheral) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard
            activePeripheral?.identifier == peripheral.identifier,
            phase == .discovering(peripheral.identifier)
        else {
            return
        }
        if let error {
            recoverFromSetupFailure(peripheral, failure: .connectionFailed(error.localizedDescription))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            recoverFromSetupFailure(peripheral, failure: .mobilityServiceMissing)
            return
        }
        scheduleSetupWatchdog(for: .characteristics, peripheral: peripheral)
        peripheral.discoverCharacteristics([pairingUUID, controlUUID, statusUUID, eventUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard
            activePeripheral?.identifier == peripheral.identifier,
            phase == .discovering(peripheral.identifier)
        else {
            return
        }
        if let error {
            recoverFromSetupFailure(peripheral, failure: .connectionFailed(error.localizedDescription))
            return
        }
        pairingCharacteristic = service.characteristics?.first { $0.uuid == pairingUUID }
        controlCharacteristic = service.characteristics?.first { $0.uuid == controlUUID }
        statusCharacteristic = service.characteristics?.first { $0.uuid == statusUUID }
        eventCharacteristic = service.characteristics?.first { $0.uuid == eventUUID }
        guard let pairingCharacteristic, let controlCharacteristic, let statusCharacteristic else {
            recoverFromSetupFailure(peripheral, failure: .mobilityCharacteristicsMissing)
            return
        }
        guard
            pairingCharacteristic.properties.contains(.write),
            controlCharacteristic.properties.contains(.write),
            statusCharacteristic.properties.contains(.notify) || statusCharacteristic.properties.contains(.indicate)
        else {
            recoverFromSetupFailure(peripheral, failure: .mobilityCharacteristicsMissing)
            return
        }
        scheduleSetupWatchdog(for: .subscriptions, peripheral: peripheral)
        peripheral.setNotifyValue(true, for: statusCharacteristic)
        if let eventCharacteristic,
           eventCharacteristic.properties.contains(.notify) || eventCharacteristic.properties.contains(.indicate) {
            eventSubscriptionRequired = true
            peripheral.setNotifyValue(true, for: eventCharacteristic)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard
            activePeripheral?.identifier == peripheral.identifier,
            phase == .discovering(peripheral.identifier),
            characteristic === statusCharacteristic || characteristic === eventCharacteristic
        else {
            return
        }
        if let error {
            recoverFromSetupFailure(
                peripheral,
                failure: .notificationSubscriptionFailed(error.localizedDescription)
            )
            return
        }
        guard characteristic.isNotifying else {
            recoverFromSetupFailure(
                peripheral,
                failure: .notificationSubscriptionFailed("Mac 未启用通知")
            )
            return
        }
        if characteristic.uuid == statusUUID {
            statusSubscribed = true
        } else if characteristic.uuid == eventUUID {
            eventSubscribed = true
        }
        if statusSubscribed && (!eventSubscriptionRequired || eventSubscribed) {
            cancelSetupWatchdog()
            updatePhase(.ready(peripheral.identifier))
        }
        if characteristic.uuid == statusUUID, characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard
            activePeripheral?.identifier == peripheral.identifier,
            characteristic === statusCharacteristic || characteristic === eventCharacteristic
        else {
            return
        }
        if let error {
            delegate?.mobilityCentral(self, didFail: .connectionFailed(error.localizedDescription))
            return
        }
        guard let value = characteristic.value else { return }
        let channel: MobilityBLEInboundChannel = characteristic.uuid == statusUUID ? .status : .event
        delegate?.mobilityCentral(self, didReceive: value, on: channel, from: peripheral.identifier)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard
            activePeripheral?.identifier == peripheral.identifier,
            queuedWrites.first?.characteristic === characteristic,
            writeInFlight
        else {
            return
        }
        writeInFlight = false
        writeWatchdogTask?.cancel()
        writeWatchdogTask = nil
        if !queuedWrites.isEmpty {
            queuedWrites.removeFirst()
        }
        if let error {
            queuedWrites.removeAll()
            delegate?.mobilityCentral(self, didFail: .writeFailed(error.localizedDescription))
            return
        }
        flushNextWriteIfPossible()
    }
}
