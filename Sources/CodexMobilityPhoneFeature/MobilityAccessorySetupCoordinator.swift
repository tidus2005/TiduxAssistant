#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AccessorySetupKit)
@preconcurrency import AccessorySetupKit
import Combine
import CoreBluetooth
import Foundation
import UIKit

/// Owns the AccessorySetupKit session for the iPhone process and translates its
/// Apple-framework events into the platform-neutral setup state.
///
/// AccessorySetupKit grants system access to the selected Mac. The existing six-digit
/// Mobility pairing flow remains the authority for application control credentials.
@MainActor
public final class MobilityAccessorySetupCoordinator: ObservableObject {
    @Published public private(set) var state = MobilityAccessorySetupState()

    private var session: ASAccessorySession
    private var sessionGeneration = UUID()
    private let store: MobilityPhoneStore
    private var hasStarted = false
    @Published public private(set) var isRepairing = false

    public init(
        store: MobilityPhoneStore,
        session: ASAccessorySession = ASAccessorySession()
    ) {
        self.store = store
        self.session = session
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        apply(.activationStarted)

        let generation = sessionGeneration
        session.activate(on: .main) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.handle(event)
            }
        }
    }

    /// Presents Apple's picker. If the session is still activating, the request remains
    /// pending and is presented immediately after the activated event arrives.
    public func showSystemPicker() {
        if state.phase == .invalidated {
            // Invalidation is terminal for a session, not for the entire app process.
            // Ignore late events from the old session after a user-initiated retry.
            sessionGeneration = UUID()
            session.invalidate()
            session = ASAccessorySession()
            hasStarted = false
            state = MobilityAccessorySetupState()
        }
        guard !state.isPickerBusy else { return }

        apply(.pickerRequested)
        start()
        presentPickerIfReady()
    }

    public func clearError() {
        apply(.clearError)
    }

    /// Equivalent reauthorization of one user-selected accessory, never an automatic
    /// response to radio loss. App tokens are retained until new pairing succeeds.
    public func repairAccessory(identifier: UUID) {
        guard !isRepairing, state.isSessionReady, !state.isPickerBusy,
              let accessory = session.accessories.first(where: { $0.bluetoothIdentifier == identifier }) else { return }
        isRepairing = true
        store.beginSystemPairingRepair(identifier: identifier)
        let generation = sessionGeneration
        session.removeAccessory(accessory) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.isRepairing = false
                if let error {
                    self.store.finishSystemPairingRepair(identifier: identifier)
                    self.apply(.failed("无法重建配件关联：\(error.localizedDescription)"))
                } else {
                    self.showSystemPicker()
                }
            }
        }
    }

    /// Local names may be shortened or absent in a Core Bluetooth advertisement.
    /// The app-specific 128-bit service is the discovery constraint; system consent
    /// and the existing six-digit pairing still authorize access afterwards.
    public static func makeDiscoveryDescriptor() -> ASDiscoveryDescriptor {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = CBUUID(nsuuid: MobilityAccessorySetupConfiguration.serviceUUID)
        return descriptor
    }

    private func presentPickerIfReady() {
        guard state.isSessionReady, state.isPickerRequestPending else { return }

        let descriptor = Self.makeDiscoveryDescriptor()

        let productImage = UIImage(systemName: "laptopcomputer.and.iphone") ?? UIImage()
        let displayItem = ASPickerDisplayItem(
            name: MobilityAccessorySetupConfiguration.advertisedName,
            productImage: productImage,
            descriptor: descriptor
        )
        displayItem.setupOptions = [.finishInApp]

        let generation = sessionGeneration
        session.showPicker(for: [displayItem]) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation, let error else { return }
                let nsError = error as NSError
                // ASErrorCodeUserCancelled. Cancellation is a normal user decision, not
                // a setup failure that should leave a persistent warning in the UI.
                if nsError.domain == ASErrorDomain, nsError.code == 700 {
                    self.apply(.pickerDismissed)
                    return
                }
                self.apply(.pickerDismissed)
                self.apply(.failed("无法显示系统配件选择器：\(error.localizedDescription)"))
            }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            apply(.activated(session.accessories.map(snapshot)))
            presentPickerIfReady()

        case .accessoryAdded:
            guard let accessory = event.accessory else { return }
            if let identifier = accessory.bluetoothIdentifier {
                store.finishSystemPairingRepair(identifier: identifier)
            }
            apply(.accessoryAdded(snapshot(accessory)))

        case .accessoryChanged:
            guard let accessory = event.accessory else { return }
            apply(.accessoryChanged(snapshot(accessory)))

        case .accessoryRemoved:
            apply(.accessoryRemoved(event.accessory?.bluetoothIdentifier))

        case .pickerDidPresent:
            apply(.pickerPresented)

        case .pickerDidDismiss:
            apply(.pickerDismissed)

        case .invalidated:
            apply(.invalidated(event.error?.localizedDescription))

        case .pickerSetupFailed:
            apply(.failed(event.error?.localizedDescription ?? "系统没有完成 Mac 配件授权。"))

        case .unknown:
            if let error = event.error {
                apply(.failed(error.localizedDescription))
            }

        case .migrationComplete,
             .accessoryDiscovered,
             .pickerSetupBridging,
             .pickerSetupPairing,
             .pickerSetupRename:
            break

        @unknown default:
            if let error = event.error {
                apply(.failed(error.localizedDescription))
            }
        }
    }

    private func snapshot(_ accessory: ASAccessory) -> MobilityAccessorySnapshot {
        let authorization: MobilityAccessoryAuthorization = switch accessory.state {
        case .unauthorized: .unauthorized
        case .awaitingAuthorization: .awaitingAuthorization
        case .authorized: .authorized
        @unknown default: .unauthorized
        }
        return MobilityAccessorySnapshot(
            bluetoothIdentifier: accessory.bluetoothIdentifier,
            displayName: accessory.displayName,
            authorization: authorization
        )
    }

    private func apply(_ input: MobilityAccessorySetupInput) {
        var next = state
        let effect = MobilityAccessorySetupReducer.reduce(input, state: &next)
        state = next

        for identifier in effect.removedIdentifiers {
            store.removeSystemAuthorizedAccessory(identifier: identifier)
        }
        if !effect.accessoriesToRestore.isEmpty {
            store.restoreSystemAuthorizedAccessories(
                effect.accessoriesToRestore,
                preferredIdentifier: effect.preferredConnectionIdentifier
            )
        }
    }
}

/// Process-level dependency graph for Mobility on iPhone. The app root owns one instance,
/// which keeps both Core Bluetooth restoration and ASAccessorySession alive together.
@MainActor
public final class MobilityPhoneAppRuntime: ObservableObject {
    public let store: MobilityPhoneStore
    public let accessorySetupCoordinator: MobilityAccessorySetupCoordinator
    public let syncStore: MobilityPhoneSyncStore
    public let peerClient: MobilitySyncthingClient
    private var highSpeedTask: Task<Void, Never>?
    private var transferWatchdog: Task<Void, Never>?
    private var lastHotspotAttempt: Date?


    public init(
        store: MobilityPhoneStore = MobilityPhoneStore(),
        syncStore: MobilityPhoneSyncStore = MobilityPhoneSyncStore(requiresIncomingApproval: true)
    ) {
        self.store = store
        self.syncStore = syncStore
        self.accessorySetupCoordinator = MobilityAccessorySetupCoordinator(store: store)
        let peerClient = MobilitySyncthingClient(
            localDeviceID: store.localDeviceID,
            localDeviceName: store.localDeviceName
        )
        self.peerClient = peerClient
        syncStore.configureSyncthingDeviceID(store.localDeviceID)
        syncStore.usesDualChannelRouting = true
        syncStore.prepareReceiver = { [weak store] in
            guard let store else { return false }
            // Multiple selected assets share the dashboard RPC with discovery. Wait for
            // its short read rather than showing a false “inbox unavailable” error.
            for _ in 0..<100 {
                guard !Task.isCancelled else { return false }
                if !store.dashboardBusy { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            }
            return await store.performDashboard(.prepareFileReceiver)
        }
        syncStore.sendNetworkMessage = { [weak peerClient] message in peerClient?.send(message) == true }
        store.dashboardDidRefresh = { [weak peerClient] snapshot in peerClient?.updatePairedEndpoint(snapshot) }
        peerClient.onTransferMessage = { [weak syncStore] message in syncStore?.receive(message, viaNetwork: true) }
        syncStore.requestHighSpeedConnection = { [weak self] in self?.prepareHighSpeedTransfer() }


        syncStore.sendMessage = { [weak store] message in
            _ = store?.sendFileSyncMessage(message)
        }
        syncStore.sendPeerMessage = { [weak peerClient] message in
            peerClient?.send(message) == true
        }
        store.fileSyncMessageHandler = { [weak syncStore] message in
            syncStore?.receive(message)
        }
        peerClient.onPeerMessage = { [weak syncStore] message in
            guard let syncStore else {
                throw MobilityPhoneSyncthingDeltaError.storeReleased
            }
            return try await syncStore.receivePeerMessage(message)
        }
        peerClient.onConnectionReady = { [weak syncStore] in
            guard let syncStore else { return }
            if !syncStore.usesDualChannelRouting { syncStore.updateTransportCapabilities(MobilitySyncthingClient.lanCapabilities) }
            syncStore.highSpeedStatus = "加密 Wi-Fi 通道已连接"
            syncStore.peerConnectionDidBecomeReady()
        }
        peerClient.onConnectionClosed = { [weak store, weak syncStore] in
            guard let syncStore else { return }
            syncStore.highSpeedStatus = "网络通道中断，等待恢复后续传"
            syncStore.peerConnectionDidClose()
            if let capabilities = store?.currentFileSyncTransportCapabilities(),
               store?.isFileSyncControlReady == true {
                syncStore.updateTransportCapabilities(capabilities)
            }
        }
        store.fileSyncConnectionReadyHandler = { [weak store, weak syncStore, weak peerClient] in
            guard let syncStore else { return }
            peerClient?.refreshCredentials()
            if peerClient?.isReady == true {
                if !syncStore.usesDualChannelRouting { syncStore.updateTransportCapabilities(MobilitySyncthingClient.lanCapabilities) }
            } else if let capabilities = store?.currentFileSyncTransportCapabilities() {
                syncStore.updateTransportCapabilities(capabilities)
            }
            syncStore.connectionDidBecomeReady()
            Task { await store?.performDashboard(.snapshot) }
        }
        store.fileSyncConnectionClosedHandler = { [weak syncStore] in
            syncStore?.connectionDidClose()
        }
    }

    private func prepareHighSpeedTransfer() {
        guard highSpeedTask == nil else { return }
        highSpeedTask = Task { [weak self] in
            guard let self else { return }
            defer { self.highSpeedTask = nil }
            self.syncStore.highSpeedStatus = "正在寻找 Mac 高速通道"
            await self.store.performDashboard(.snapshot)
            self.peerClient.refreshCredentials()
            for attempt in 0..<24 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard self.syncStore.hasWaitingLargeFiles else { return }
                if self.peerClient.isReady { self.syncStore.retryWaitingTransfers(); return }
                if attempt == 2, self.lastHotspotAttempt.map({ Date().timeIntervalSince($0) > 90 }) ?? true {
                    self.lastHotspotAttempt = Date()
                    self.syncStore.highSpeedStatus = "正在请求 Mac 连接已保存的手机热点"
                    let ok = await self.store.performDashboard(.connectHotspot)
                    if !ok { self.syncStore.highSpeedStatus = self.store.dashboardMessage ?? "请开启手机个人热点" }
                }
                await self.store.performDashboard(.snapshot)
            }
            self.syncStore.highSpeedStatus = "高速通道未连通。请打开个人热点，确认 VPN 允许局域网后点重试连接。文件仍在队列中。"
        }
    }

    public func start() {
        store.start()
        accessorySetupCoordinator.start()
        peerClient.start()
        if transferWatchdog == nil {
            transferWatchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self else { return }
                    self.syncStore.recoverStalledTransfers()
                }
            }
        }
    }
}
#endif
