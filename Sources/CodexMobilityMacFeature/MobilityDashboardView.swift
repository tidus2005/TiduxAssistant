import CodexMobilityCore
import SwiftUI
import WristArenaFeature

public struct MobilityDashboardView: View {
    private let store: MacMobilityStore
    @ObservedObject private var moduleStore: MobilityModuleConfigurationStore
    @ObservedObject private var powerPolicyStore: MacSystemPowerPolicyStore
    @ObservedObject private var voiceInputStore: MacVoiceInputStore
    private let fileSyncStore: MacFileSyncStore?
    private let hotspotAutomationStore: MacHotspotAutomationStore?
    private let closedLidSessionController: MacClosedLidSessionController?
    private let caffeineController: MacCaffeineController?
    private static let mobileOfficeSelection = "mobile-office"
    private static let caffeineSelection = "caffeine"
    private let pairingState: MobilityBLEPeripheralState
    private let pairedDevices: [MobilityMacPairedDevice]
    private let pairingManagementErrorMessage: String?
    private let onRegeneratePairingCode: () -> Void
    private let onRevokePairedDevice: (UUID) -> Void

    @State private var showsArena = false
    @State private var selectedModuleRawValue: String?
    @AppStorage("com.tidux.codex-mobility.dashboard.selected-module.v1")
    private var persistedModuleRawValue = MobilityModuleID.deviceStatus.rawValue

    public init(
        store: MacMobilityStore,
        moduleStore: MobilityModuleConfigurationStore,
        powerPolicyStore: MacSystemPowerPolicyStore,
        voiceInputStore: MacVoiceInputStore,
        fileSyncStore: MacFileSyncStore? = nil,
        hotspotAutomationStore: MacHotspotAutomationStore? = nil,
        closedLidSessionController: MacClosedLidSessionController? = nil,
        caffeineController: MacCaffeineController? = nil,
        pairingState: MobilityBLEPeripheralState,
        pairedDevices: [MobilityMacPairedDevice],
        pairingManagementErrorMessage: String?,
        onRegeneratePairingCode: @escaping () -> Void,
        onRevokePairedDevice: @escaping (UUID) -> Void
    ) {
        self.store = store
        self.moduleStore = moduleStore
        self.powerPolicyStore = powerPolicyStore
        self.voiceInputStore = voiceInputStore
        self.fileSyncStore = fileSyncStore
        self.hotspotAutomationStore = hotspotAutomationStore
        self.closedLidSessionController = closedLidSessionController
        self.caffeineController = caffeineController
        self.pairingState = pairingState
        self.pairedDevices = pairedDevices
        self.pairingManagementErrorMessage = pairingManagementErrorMessage
        self.onRegeneratePairingCode = onRegeneratePairingCode
        self.onRevokePairedDevice = onRevokePairedDevice
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
        } detail: {
            selectedPanel
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            Button {
                store.refreshNow()
                powerPolicyStore.refresh()
            } label: {
                Label("刷新状态", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")

            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
        }
        .sheet(isPresented: $showsArena) {
            ArenaWebView() { showsArena = false }
                .frame(minWidth: 650, idealWidth: 800, minHeight: 650, idealHeight: 800)
        }
        .onAppear {
            normalizeSelection()
            powerPolicyStore.refresh()
        }
        .onChange(of: selectedModuleRawValue) { _, newValue in
            if let newValue {
                persistedModuleRawValue = newValue
            }
        }
        .onChange(of: descriptorIDs) { _, _ in
            normalizeSelection()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedModuleRawValue) {
                if closedLidSessionController != nil || caffeineController != nil {
                    Section("办公") {
                        if closedLidSessionController != nil {
                            Label("移动办公模式", systemImage: "figure.walk")
                                .tag(Self.mobileOfficeSelection)
                        }
                        if caffeineController != nil {
                            Label("咖啡因", systemImage: "cup.and.saucer.fill")
                                .tag(Self.caffeineSelection)
                        }
                    }
                }
                ForEach(sections) { section in
                    Section(sectionTitle(section.tier)) {
                        ForEach(section.descriptors) { descriptor in
                            sidebarRow(descriptor)
                                .tag(descriptor.id.rawValue)
                        }
                    }
                }
                Section("探索") {
                    Button { showsArena = true } label: { Label("表盘大作战", systemImage: "gamecontroller") }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Tidux助手")

            Divider()
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.status.deviceName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(pairedDevices.isEmpty ? "等待连接 iPhone" : "已配对 \(pairedDevices.count) 台设备")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("打开设置")
            }
            .padding(12)
        }
    }

    private func sidebarRow(_ descriptor: MobilityModuleDescriptor) -> some View {
        let state = MobilityDashboardNavigation.state(
            for: descriptor,
            configuration: moduleStore.configuration,
            platform: moduleStore.platform
        )

        return HStack(spacing: 10) {
            Image(systemName: descriptor.symbolName)
                .foregroundStyle(sidebarIconTint(state, descriptor: descriptor))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.id == .deviceStatus ? "连接与设备" : descriptor.title)
                    .lineLimit(1)
                if descriptor.id == .deviceStatus {
                    Text(pairingState.connectedCentralCount > 0 ? "iPhone 已连接" : "配对与连接诊断")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var selectedPanel: some View {
        if selectedModuleRawValue == Self.caffeineSelection, let caffeineController {
            MobilityCaffeinePanel(controller: caffeineController)
        } else if selectedModuleRawValue == Self.mobileOfficeSelection,
           let session = closedLidSessionController,
           let hotspot = hotspotAutomationStore {
            MobilityMobileOfficePanel(session: session, hotspot: hotspot,
                store: store, power: powerPolicyStore)
        } else if let descriptor = selectedDescriptor {
            panel(for: descriptor)
                .id(descriptor.id)
        } else {
            ContentUnavailableView(
                "没有可显示的模块",
                systemImage: "square.grid.2x2",
                description: Text("请在模块配置中加入至少一个支持 macOS 的模块。")
            )
        }
    }

    @ViewBuilder
    private func panel(for descriptor: MobilityModuleDescriptor) -> some View {
        let isSelected = moduleStore.isSelected(descriptor)
        let isEnabled = moduleStore.isEnabled(descriptor)
        let experimentsEnabled = moduleStore.configuration.experimentalModulesEnabled

        if descriptor.id == .deviceStatus {
            MobilityDeviceStatusPanel(
                store: store,
                descriptor: descriptor,
                isSelected: isSelected,
                isEnabled: isEnabled,
                experimentsEnabled: experimentsEnabled,
                pairingState: pairingState,
                pairedDevices: pairedDevices,
                pairingManagementErrorMessage: pairingManagementErrorMessage,
                onRegeneratePairingCode: onRegeneratePairingCode,
                onRevokePairedDevice: onRevokePairedDevice
            )
        } else if descriptor.id == .travelRuntime {
            MobilityTravelRuntimePanel(
                store: store,
                powerPolicyStore: powerPolicyStore,
                descriptor: descriptor,
                isSelected: isSelected,
                isEnabled: isEnabled,
                experimentsEnabled: experimentsEnabled
            )
        } else if descriptor.id == .fileSync, let fileSyncStore {
            MobilityFileSyncPanel(
                store: fileSyncStore,
                descriptor: descriptor,
                isSelected: isSelected,
                isEnabled: isEnabled,
                experimentsEnabled: experimentsEnabled
            )
        } else if descriptor.id == .voiceInput {
            MobilityVoiceInputPanel(
                store: voiceInputStore,
                descriptor: descriptor,
                isSelected: isSelected,
                isEnabled: isEnabled,
                experimentsEnabled: experimentsEnabled
            )
        } else if descriptor.id == .closedLidLabs {
            MobilityClosedLidLabsPanel(
                mobilityStore: store,
                moduleStore: moduleStore,
                powerPolicyStore: powerPolicyStore,
                descriptor: descriptor
            )
        } else if descriptor.id == .hotspotAutomation, let hotspotAutomationStore {
            MobilityHotspotAutomationPanel(
                store: hotspotAutomationStore,
                descriptor: descriptor,
                isSelected: isSelected,
                isEnabled: isEnabled,
                experimentsEnabled: experimentsEnabled
            )
        } else {
            MobilityGenericModulePanel(
                descriptor: descriptor,
                isSelected: isSelected,
                isEnabled: isEnabled,
                experimentsEnabled: experimentsEnabled
            )
        }
    }

    private var descriptors: [MobilityModuleDescriptor] {
        MobilityDashboardNavigation.descriptors(
            catalog: moduleStore.catalog,
            configuration: moduleStore.configuration,
            platform: moduleStore.platform
        )
    }

    private var sections: [MobilityDashboardNavigation.Section] {
        MobilityDashboardNavigation.sections(descriptors: descriptors)
    }

    private var descriptorIDs: [String] {
        descriptors.map(\.id.rawValue)
    }

    private var selectedDescriptor: MobilityModuleDescriptor? {
        let resolved = MobilityDashboardNavigation.resolvedSelection(
            preferredRawValue: selectedModuleRawValue,
            descriptors: descriptors
        )
        return descriptors.first { $0.id.rawValue == resolved }
    }

    private func normalizeSelection() {
        if caffeineController != nil,
           (selectedModuleRawValue ?? persistedModuleRawValue) == Self.caffeineSelection {
            selectedModuleRawValue = Self.caffeineSelection
            return
        }
        if closedLidSessionController != nil,
           (selectedModuleRawValue ?? persistedModuleRawValue) == Self.mobileOfficeSelection {
            selectedModuleRawValue = Self.mobileOfficeSelection
            return
        }
        let resolved = MobilityDashboardNavigation.resolvedSelection(
            preferredRawValue: selectedModuleRawValue ?? persistedModuleRawValue,
            descriptors: descriptors
        )
        if selectedModuleRawValue != resolved {
            selectedModuleRawValue = resolved
        }
        if let resolved, persistedModuleRawValue != resolved {
            persistedModuleRawValue = resolved
        }
    }

    private func sectionTitle(_ tier: MobilityModuleTier) -> String {
        switch tier {
        case .standard: "随行"
        case .experimental: "进阶"
        }
    }

    private func sidebarDetail(
        _ state: MobilityDashboardNavigation.ModuleState,
        descriptor: MobilityModuleDescriptor
    ) -> String {
        if descriptor.id == .closedLidLabs {
            return powerPolicyStore.snapshot.state(for: .closedLidContinuity).displayName
        }
        return switch state {
        case .enabled: "已开启"
        case .disabled: "已关闭"
        case .experimentalLocked: "需在设置开启 Labs"
        case .unavailable: "暂不可用"
        }
    }

    private func sidebarDetailTint(
        _ state: MobilityDashboardNavigation.ModuleState,
        descriptor: MobilityModuleDescriptor
    ) -> Color {
        if descriptor.id == .closedLidLabs {
            return powerPolicyStore.snapshot.state(for: .closedLidContinuity).mobilityTint
        }
        return switch state {
        case .enabled: .green
        case .unavailable: .orange
        case .disabled, .experimentalLocked: .secondary
        }
    }

    private func sidebarIconTint(
        _ state: MobilityDashboardNavigation.ModuleState,
        descriptor: MobilityModuleDescriptor
    ) -> Color {
        if descriptor.id == .closedLidLabs {
            return powerPolicyStore.snapshot.state(for: .closedLidContinuity).mobilityTint
        }
        return state == .enabled ? .accentColor : .secondary
    }
}
