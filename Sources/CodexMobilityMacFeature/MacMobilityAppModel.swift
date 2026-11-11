import CodexMobilityCore
import Combine
import Foundation

@MainActor
public final class MacMobilityAppModel: ObservableObject {
    public let caffeineController = MacCaffeineController()
    public var onShowDashboard: (() -> Void)?
    var companionOperationRunning = false
    public let store: MacMobilityStore
    public let peripheral: MobilityBLEPeripheral
    public let fileSyncStore: MacFileSyncStore
    public let fileSyncController: MacFileSyncWireController
    public let syncthingSyncServer: MacSyncthingSyncServer
    public let moduleStore: MobilityModuleConfigurationStore
    public let moduleRuntime: MacMobilityModuleRuntime
    public let hotspotAutomationStore: MacHotspotAutomationStore
    public let powerPolicyStore: MacSystemPowerPolicyStore
    public let closedLidSessionController: MacClosedLidSessionController
    public let lidCloseLockController: MacLidCloseLockController
    public let voiceInputStore: MacVoiceInputStore

    @Published public private(set) var bluetoothState: MobilityBLEPeripheralState
    @Published public private(set) var syncthingState: MacSyncthingSyncServerState
    @Published public private(set) var pairedDevices: [MobilityMacPairedDevice] = []
    @Published public private(set) var pairingManagementErrorMessage: String?

    private var cancellables: Set<AnyCancellable> = []
    private var hasStarted = false
    private var syncthingLifecycleTask: Task<Void, Never>?
    private var offerPublicationTask: Task<Void, Never>?
    private let commandRouter: MacMobilityModuleCommandRouter
    private let voiceInputModuleAdapter: MacVoiceInputModuleAdapter

    public init(
        store: MacMobilityStore = MacMobilityStore(),
        fileSyncStore: MacFileSyncStore = MacFileSyncStore(),
        moduleStore: MobilityModuleConfigurationStore = MobilityModuleConfigurationStore(),
        powerPolicyStore: MacSystemPowerPolicyStore = MacSystemPowerPolicyStore(),
        lidCloseLockController: MacLidCloseLockController = MacLidCloseLockController(),
        credentialVault: any MobilityMacCredentialStoring = MobilityMacCredentialVault()
    ) {
        self.store = store
        self.fileSyncStore = fileSyncStore
        self.moduleStore = moduleStore
        self.powerPolicyStore = powerPolicyStore
        self.lidCloseLockController = lidCloseLockController
        let voiceInputStore = MacVoiceInputStore()
        self.voiceInputStore = voiceInputStore
        let voiceInputModuleAdapter = MacVoiceInputModuleAdapter(
            store: voiceInputStore
        )
        self.voiceInputModuleAdapter = voiceInputModuleAdapter
        let fileSyncController = MacFileSyncWireController(store: fileSyncStore)
        self.fileSyncController = fileSyncController
        let syncthingSyncServer = MacSyncthingSyncServer(
            localDeviceID: store.status.deviceID,
            localDeviceName: store.status.deviceName,
            credentialStore: credentialVault,
            wireController: fileSyncController
        )
        self.syncthingSyncServer = syncthingSyncServer
        let hotspotAutomationStore = MacHotspotAutomationStore()
        self.hotspotAutomationStore = hotspotAutomationStore
        let commandRouter = MacMobilityModuleCommandRouter(
            moduleStore: moduleStore,
            downstream: store
        )
        self.commandRouter = commandRouter
        do {
            self.moduleRuntime = try MacMobilityModuleRuntime(
                configurationStore: moduleStore,
                adapters: [
                    MacTravelRuntimeModuleAdapter(store: store),
                    MacClosedLidLabsModuleAdapter(store: store),
                    MacFileSyncModuleAdapter(
                        store: fileSyncStore,
                        server: syncthingSyncServer
                    ),
                    hotspotAutomationStore,
                    voiceInputModuleAdapter
                ]
            )
        } catch {
            preconditionFailure("Invalid built-in Mac module runtime: \(error)")
        }
        self.closedLidSessionController = MacClosedLidSessionController(
            store: store,
            moduleStore: moduleStore,
            powerPolicyStore: powerPolicyStore,
            hotspotStore: hotspotAutomationStore,
            agentDesktopController: lidCloseLockController.agentDesktopController,
            caffeineController: caffeineController
        )
        closedLidSessionController.$phase
            .sink { [weak closedLidSessionController, weak lidCloseLockController] phase in
                lidCloseLockController?.setMobileOfficePowerSaving(
                    phase == .active && closedLidSessionController?.isMobileOfficeSession == true
                )
            }
            .store(in: &cancellables)
        let peripheral = MobilityBLEPeripheral(
            serverDeviceID: store.status.deviceID,
            serverDeviceName: store.status.deviceName,
            advertisementName: MobilityBLEUUIDs.advertisedLocalName,
            credentialVault: credentialVault
        )
        self.peripheral = peripheral
        self.bluetoothState = peripheral.state
        self.syncthingState = syncthingSyncServer.state

        peripheral.setStatusPublishingEnabled(commandRouter.allowsStatusPublication)
        peripheral.setFileSyncPublishingEnabled(commandRouter.allowsFileSync)
        peripheral.commandDelegate = commandRouter
        let collaborationService = MacCollaborationService()
        peripheral.collaborationHandler = { [weak self] request, _ in
            if request.method == .companion {
                guard let self else { return CollaborationResponse(requestID: request.id, status: 503) }
                return await self.handleCompanionRequest(request)
            }
            return await collaborationService.handle(request)
        }
        peripheral.fileSyncMessageHandler = {
            [weak fileSyncController, weak commandRouter] message, phoneDeviceID in
            guard let fileSyncController, let commandRouter else { return [] }
            return await commandRouter.handleFileSyncMessage(
                message,
                from: phoneDeviceID
            ) { message, phoneDeviceID in
                await fileSyncController.handle(message, from: phoneDeviceID)
            }
        }
        peripheral.stateDidChange = { [weak self] state in
            self?.bluetoothState = state
        }
        peripheral.pairedDevicesDidChange = { [weak self] in
            self?.reloadPairedDevices()
            self?.refreshSyncthingCredentialsIfRunning()
        }
        fileSyncStore.outgoingOffersDidChange = { [weak self] in
            self?.scheduleOfferPublication()
        }

        store.$status
            .sink { [weak peripheral, weak hotspotAutomationStore, weak commandRouter] status in
                if commandRouter?.allowsStatusPublication == true {
                    peripheral?.publishStatus(status)
                }
                hotspotAutomationStore?.setMobilityModeActive(status.mode.isEnabled)
            }
            .store(in: &cancellables)

        syncthingSyncServer.$state
            .sink { [weak self] state in
                self?.syncthingState = state
            }
            .store(in: &cancellables)

        moduleStore.$configuration
            .sink { [weak self] configuration in
                guard let self else { return }
                let statusPublishingEnabled = self.commandRouter
                    .allowsStatusPublication(in: configuration)
                let fileSyncEnabled = self.commandRouter.allowsFileSync(in: configuration)
                self.peripheral.setStatusPublishingEnabled(statusPublishingEnabled)
                self.peripheral.setFileSyncPublishingEnabled(fileSyncEnabled)
                // `MacAppContext.model` is initialized before AppDelegate has
                // resolved a running legacy FlowType instance. Configuration
                // publishers emit their current value immediately, so starting
                // adapters here would briefly give both apps ownership of Fn and
                // the microphone. Runtime activation begins only from `start()`,
                // after the AppDelegate conflict gate has completed.
                if self.hasStarted {
                    self.moduleRuntime.applyConfiguration(configuration)
                }
                if statusPublishingEnabled {
                    self.peripheral.publishStatus(self.store.status)
                }
            }
            .store(in: &cancellables)

        reloadPairedDevices()
    }

    private func scheduleOfferPublication() {
        offerPublicationTask?.cancel()
        offerPublicationTask = Task { [weak self] in
            // Watcher callbacks arrive once per file. Coalesce the initial scan and
            // edits, rather than publishing the entire growing queue for every file.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.hasStarted, self.commandRouter.allowsFileSync else { return }
            let offers = await self.fileSyncController.pendingOffers()
            guard !Task.isCancelled, self.commandRouter.allowsFileSync else { return }
            for offer in offers { self.peripheral.publishFileSync(offer) }
            let localOffers = await self.fileSyncController.pendingOffers(transportProfile: .localNetwork)
            guard !Task.isCancelled, self.commandRouter.allowsFileSync else { return }
            await self.syncthingSyncServer.publish(localOffers)
        }
    }

    public var pairingCode: String { bluetoothState.pairingCode }
    public var connectedPhoneCount: Int { bluetoothState.connectedCentralCount }
    public var connectedSyncthingPeerCount: Int { syncthingState.activeConnectionCount }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        store.startMonitoring()
        peripheral.setStatusPublishingEnabled(commandRouter.allowsStatusPublication)
        peripheral.setFileSyncPublishingEnabled(commandRouter.allowsFileSync)
        peripheral.start()
        if commandRouter.allowsStatusPublication {
            peripheral.publishStatus(store.status)
        }
        moduleRuntime.applyConfiguration()
        lidCloseLockController.start()
        Task { [weak closedLidSessionController, weak powerPolicyStore] in
            await closedLidSessionController?.recoverInterruptedSessionIfNeeded()
            powerPolicyStore?.refresh()
        }
    }

    public func regeneratePairingCode() {
        peripheral.regeneratePairingCode()
    }

    public func reloadPairedDevices() {
        do {
            pairedDevices = try peripheral.pairedDevices()
            hotspotAutomationStore.setHasPairedPhone(!pairedDevices.isEmpty)
            pairingManagementErrorMessage = nil
        } catch {
            hotspotAutomationStore.setHasPairedPhone(false)
            pairingManagementErrorMessage = error.localizedDescription
        }
    }

    public func revokePairedDevice(deviceID: UUID) {
        do {
            try peripheral.revokePairedDevice(deviceID: deviceID)
        } catch {
            pairingManagementErrorMessage = error.localizedDescription
        }
    }

    public func shutdown() {
        offerPublicationTask?.cancel()
        closedLidSessionController.shutdown()
        lidCloseLockController.stop()
        peripheral.stop()
        moduleRuntime.stopAll()
        syncthingLifecycleTask?.cancel()
        store.shutdown()
        hasStarted = false
    }

    public func applicationDidBecomeActive() {
        guard hasStarted else { return }
        voiceInputModuleAdapter.applicationDidBecomeActive()
    }

    private func refreshSyncthingCredentialsIfRunning() {
        guard hasStarted, moduleRuntime.isRunning(.fileSync) else { return }
        syncthingLifecycleTask?.cancel()
        syncthingLifecycleTask = Task { [weak syncthingSyncServer] in
            await syncthingSyncServer?.refreshCredentials()
        }
    }
}
