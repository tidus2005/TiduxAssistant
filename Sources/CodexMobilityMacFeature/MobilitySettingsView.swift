import CodexMobilityCore
import SwiftUI

public struct MobilitySettingsView: View {
    @ObservedObject private var store: MacMobilityStore
    @ObservedObject private var moduleStore: MobilityModuleConfigurationStore
    @ObservedObject private var powerPolicyStore: MacSystemPowerPolicyStore
    @ObservedObject private var lidCloseLockController: MacLidCloseLockController
    @ObservedObject private var voiceInputStore: MacVoiceInputStore
    private let fileSyncStore: MacFileSyncStore?
    private let hotspotAutomationStore: MacHotspotAutomationStore?

    public init(
        store: MacMobilityStore,
        fileSyncStore: MacFileSyncStore? = nil,
        moduleStore: MobilityModuleConfigurationStore,
        powerPolicyStore: MacSystemPowerPolicyStore,
        lidCloseLockController: MacLidCloseLockController,
        hotspotAutomationStore: MacHotspotAutomationStore? = nil,
        voiceInputStore: MacVoiceInputStore
    ) {
        self.store = store
        self.fileSyncStore = fileSyncStore
        self.moduleStore = moduleStore
        self.powerPolicyStore = powerPolicyStore
        self.lidCloseLockController = lidCloseLockController
        self.hotspotAutomationStore = hotspotAutomationStore
        self.voiceInputStore = voiceInputStore
    }

    public var body: some View {
        TabView {
            MobilityPowerAndLidSettingsView(
                mobilityStore: store,
                moduleStore: moduleStore,
                powerPolicyStore: powerPolicyStore,
                lidCloseLockController: lidCloseLockController
            )
            .tabItem { Label("电源", systemImage: "power") }

            Form {
                Section("自动停止") {
                    LabeledContent("截止电量", value: "\(store.policy.lowBatteryThresholdPercent)%")
                    Slider(
                        value: Binding(
                            get: { Double(store.policy.lowBatteryThresholdPercent) },
                            set: { updatePolicy(lowBattery: Int($0.rounded())) }
                        ),
                        in: 20...80,
                        step: 5
                    )

                    LabeledContent("最长运行", value: durationText)
                    Slider(
                        value: Binding(
                            get: { store.policy.maximumDurationSeconds / 60 },
                            set: { updatePolicy(maximumMinutes: $0) }
                        ),
                        in: 15...240,
                        step: 15
                    )

                    LabeledContent("断网宽限", value: graceText)
                    Slider(
                        value: Binding(
                            get: { store.policy.networkDisconnectGraceSeconds / 60 },
                            set: { updatePolicy(networkGraceMinutes: $0) }
                        ),
                        in: 0...30,
                        step: 1
                    )

                    Toggle(
                        "Codex 退出时自动停止",
                        isOn: Binding(
                            get: { store.policy.requiresCodexRunning },
                            set: { updatePolicy(requiresCodex: $0) }
                        )
                    )
                }

                Section("说明") {
                    Text("启动时电量必须至少高于截止值 10%。严重热状态、临界热状态和最长时长由 Mac 本地保护，不依赖手机连接。")
                        .foregroundStyle(.secondary)
                    Text("这些自动停止条件只释放 App 的 Idle Guard。若“电源”中的系统级 SleepDisabled 已开启，它不会被自动关闭，需要在这台 Mac 上通过本 App 的“设置 > 电源”手动关闭。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("安全", systemImage: "shield") }

            if let fileSyncStore, moduleStore.isEnabled(.fileSync) {
                Form {
                    Section("同步目录") {
                        LabeledContent("当前位置") {
                            Text(fileSyncStore.directoryDisplayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Toggle(
                            "启用双向同步",
                            isOn: Binding(
                                get: { fileSyncStore.isEnabled },
                                set: { enabled in fileSyncStore.setEnabled(enabled) }
                            )
                        )
                        HStack {
                            Button(fileSyncStore.directoryURL == nil ? "选择目录…" : "更换目录…") {
                                fileSyncStore.chooseDirectory()
                            }
                            if fileSyncStore.directoryURL != nil {
                                Button("在 Finder 中打开") {
                                    fileSyncStore.revealDirectory()
                                }
                                Button("移除目录", role: .destructive) {
                                    Task { await fileSyncStore.clearDirectory() }
                                }
                            }
                        }
                    }

                    Section("传输规则") {
                        Text("同步默认保持关闭，避免 App 启动时自动扫描旧目录；明确选择新目录会同时开启同步，之后可随时用上方开关暂停。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("只同步普通文件；隐藏文件、符号链接、下载临时文件和 .partial 文件不会入队。P2P 并发修改保留为 .sync-conflict 副本；蓝牙 fallback 遇到普通重名时保留为“名称 (1).扩展名”。")
                            .foregroundStyle(.secondary)
                        Text("单文件上限 2 GB。不超过 256 MiB 时使用 Syncthing 式 P2P delta；更大的文件使用 file-backed 蓝牙 fallback。delta 进行中的块不会跨 App 重启保留。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("文件", systemImage: "arrow.triangle.2.circlepath") }
            }

            MobilityVoiceInputSettingsView(
                store: voiceInputStore,
                isModuleEnabled: moduleStore.isEnabled(.voiceInput)
            )
                .tabItem { Label("语音", systemImage: "waveform.badge.mic") }

            moduleSettings
        }
        .frame(width: 640, height: 560)
        .scenePadding()
    }

    private var moduleSettings: some View {
        Form {
            Section("常规模块") {
                ForEach(moduleStore.descriptors(tier: .standard)) { descriptor in
                    moduleRow(descriptor)
                }
            }

            Section("实验模块") {
                Toggle(
                    "允许实验模块",
                    isOn: Binding(
                        get: { moduleStore.configuration.experimentalModulesEnabled },
                        set: { moduleStore.setExperimentalModulesEnabled($0) }
                    )
                )
                Text("实验功能需要先打开总开关，再逐项明确开启。关闭总开关会立即让全部实验模块失效，但保留逐项选择。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(moduleStore.descriptors(tier: .experimental)) { descriptor in
                    VStack(alignment: .leading, spacing: 8) {
                        moduleRow(descriptor)
                        if descriptor.id == .hotspotAutomation,
                           moduleStore.isEnabled(descriptor),
                           let hotspotAutomationStore {
                            HotspotAutomationSettingsSection(store: hotspotAutomationStore)
                                .padding(.leading, 32)
                        }
                    }
                }
            }

            Section("扩展方式") {
                Text("模块由稳定 ID、平台和能力描述符驱动。可通过 JSON 配置追加模块；配置只声明能力，不会加载或执行外部代码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = moduleStore.persistenceErrorMessage {
                Section("配置未保存") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .tabItem { Label("模块", systemImage: "puzzlepiece.extension") }
    }

    private func moduleRow(_ descriptor: MobilityModuleDescriptor) -> some View {
        Toggle(
            isOn: Binding(
                get: { moduleStore.isSelected(descriptor) },
                set: { moduleStore.setModule(descriptor, selected: $0) }
            )
        ) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: descriptor.symbolName)
                    .foregroundStyle(descriptor.isAvailable ? Color.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                    Text(descriptor.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let reason = descriptor.unavailableReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .disabled(
            !descriptor.isAvailable
                || (descriptor.tier == .experimental
                    && !moduleStore.configuration.experimentalModulesEnabled)
        )
        .accessibilityHint(moduleAccessibilityHint(descriptor))
    }

    private func moduleAccessibilityHint(_ descriptor: MobilityModuleDescriptor) -> String {
        if let reason = descriptor.unavailableReason { return reason }
        if descriptor.tier == .experimental,
           !moduleStore.configuration.experimentalModulesEnabled {
            return "请先允许实验模块"
        }
        return descriptor.summary
    }

    private var durationText: String {
        let minutes = Int(store.policy.maximumDurationSeconds / 60)
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
    }

    private var graceText: String {
        let minutes = Int(store.policy.networkDisconnectGraceSeconds / 60)
        return minutes == 0 ? "立即停止" : "\(minutes) 分钟"
    }

    private func updatePolicy(
        lowBattery: Int? = nil,
        maximumMinutes: Double? = nil,
        networkGraceMinutes: Double? = nil,
        requiresCodex: Bool? = nil
    ) {
        var policy = store.policy
        if let lowBattery { policy.lowBatteryThresholdPercent = lowBattery }
        if let maximumMinutes { policy.maximumDurationSeconds = maximumMinutes * 60 }
        if let networkGraceMinutes { policy.networkDisconnectGraceSeconds = networkGraceMinutes * 60 }
        if let requiresCodex { policy.requiresCodexRunning = requiresCodex }
        store.updatePolicy(policy)
    }
}
