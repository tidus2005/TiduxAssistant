import CodexMobilityCore
import SwiftUI

struct MobilityFileSyncPanel: View {
    @ObservedObject private var store: MacFileSyncStore
    private let descriptor: MobilityModuleDescriptor
    private let isSelected: Bool
    private let isEnabled: Bool
    private let experimentsEnabled: Bool

    init(
        store: MacFileSyncStore,
        descriptor: MobilityModuleDescriptor,
        isSelected: Bool,
        isEnabled: Bool,
        experimentsEnabled: Bool
    ) {
        self.store = store
        self.descriptor = descriptor
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.experimentsEnabled = experimentsEnabled
    }

    var body: some View {
        MobilityModulePanelScaffold(
            descriptor: descriptor,
            isSelected: isSelected,
            isEnabled: isEnabled,
            experimentsEnabled: experimentsEnabled,
            statusText: syncStatusText,
            statusSymbol: store.isWatching ? "arrow.triangle.2.circlepath.circle.fill" : "pause.circle",
            statusTint: store.isWatching ? .green : .secondary
        ) {
            MobilityPanelCard {
                MacFileSyncDashboardSection(store: store)
                    .disabled(!isEnabled)
            }
        }
    }

    private var syncStatusText: String {
        if !isEnabled { return "模块未运行" }
        if store.isWatching { return "目录监听中" }
        if store.directoryURL == nil { return "等待选择目录" }
        return store.isEnabled ? "正在等待变更" : "同步已暂停"
    }
}
