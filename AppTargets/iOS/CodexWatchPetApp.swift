import CodexMobilityPhoneFeature
import CodexWatchPhoneFeature
import CodexWatchCore
import SwiftUI
import WristArenaFeature

@main
@MainActor
struct CodexWatchPetApp: App {
    @StateObject private var codexStore: CodexWatchStore
    @ObservedObject private var chatGPTHandoffStore = ChatGPTHandoffStore.shared
    @StateObject private var mobilityRuntime: MobilityPhoneAppRuntime
    @State private var voiceInputRuntime = MobilityVoiceInputRuntime()
    @State private var showsArena = false
    @State private var selectedTab: CodexWatchPetRootTab = .codex
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let runtime = MobilityPhoneAppRuntime()
        let store = CodexWatchStore()
        store.configure(preferredTransports: [BluetoothBridgeTransport(store: runtime.store)])
        if let connection = BridgeConnectionStore().load() {
            store.configure(client: BridgeClient(configuration: BridgeClientConfiguration(
                baseURL: connection.baseURL, bearerToken: connection.bearerToken, sharedSecret: connection.sharedSecret)))
            if let raw = UserDefaults.standard.string(forKey: BridgeConnectionKeys.remoteBridgeURL),
               let remote = URL(string: raw), remote.scheme == "https" {
                store.configure(remoteClient: BridgeClient(configuration: BridgeClientConfiguration(
                    baseURL: remote, bearerToken: connection.bearerToken, sharedSecret: connection.sharedSecret), route: .remoteHTTPS))
            }
        }
        _mobilityRuntime = StateObject(wrappedValue: runtime)
        _codexStore = StateObject(wrappedValue: store)
        runtime.store.start()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                PhoneAppContainerView(store: codexStore, onConnect: { selectedTab = .mobility })
                    .tabItem {
                        Label("协作", systemImage: "sparkles")
                    }
                    .tag(CodexWatchPetRootTab.codex)

                MobilityPhoneContainerView(runtime: mobilityRuntime)
                    .tabItem {
                        Label("设备", systemImage: "laptopcomputer.and.iphone")
                    }
                    .tag(CodexWatchPetRootTab.mobility)

                MobilityVoiceInputContainerView(
                    runtime: voiceInputRuntime
                )
                    .tabItem {
                        Label("听写", systemImage: "waveform.and.mic")
                    }
                    .tag(CodexWatchPetRootTab.voiceInput)

                MobilityPhoneSyncView(store: mobilityRuntime.syncStore)
                    .tabItem { Label("传送", systemImage: "arrow.up.arrow.down") }
                    .tag(CodexWatchPetRootTab.transfer)

                NavigationStack {
                    List {
                        Section("探索") {
                            Button { showsArena = true } label: { Label("表盘大作战", systemImage: "gamecontroller") }
                        }
                        Section("效率工具") {
                        NavigationLink("实时记录 · 今日时间线") { PhoneJournalView() }
                        NavigationLink("短信与验证码") { SMSInboxView() }
                        NavigationLink("ChatGPT 接续") {
                            ChatGPTHandoffPhoneView {
                                Task { await codexStore.syncWatchSettings() }
                            }
                        }
                        NavigationLink("文件同步") { MobilityPhoneSyncView(store: mobilityRuntime.syncStore) }
                        NavigationLink("截图标注") { ScreenshotAnnotationView(store: mobilityRuntime.syncStore) }
                        }
                    }.navigationTitle("工具")
                }
                .tabItem { Label("工具", systemImage: "square.grid.2x2") }
                .tag(CodexWatchPetRootTab.tools)
                .badge(chatGPTHandoffStore.drafts.count)
            }
            .sheet(isPresented: $showsArena) {
                ArenaWebView() { showsArena = false; selectedTab = .codex }
            }
            .onOpenURL { url in
                guard url.scheme == "codexwatchpet" else { return }
                if url.host == "arena" { selectedTab = .tools; showsArena = true }
                if url.host == "assistant" { selectedTab = .codex }
                if url.host == "chatgpt" { selectedTab = .tools }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                PhoneJournalStore.shared.processPending()
                await codexStore.runAutoRefresh()
            }
            .onReceive(mobilityRuntime.store.$state.map(\.connectionPhase).removeDuplicates()) { _ in
                Task { await codexStore.refresh() }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                MobilityVoiceInputRecordingIndicator(
                    runtime: voiceInputRuntime
                ) {
                    selectedTab = .voiceInput
                }
            }
            .task {
                mobilityRuntime.start()
                await voiceInputRuntime.prepare()
            }
            .onChange(of: scenePhase) {
                voiceInputRuntime.handleScenePhase(scenePhase)
                if scenePhase != .active { PhoneJournalStore.shared.pauseProcessing() }
                if scenePhase == .active {
                    mobilityRuntime.start()
                    PhoneJournalStore.shared.processPending()
                    Task { await codexStore.refresh() }
                }
            }
        }
    }
}

private enum CodexWatchPetRootTab: Hashable {
    case codex
    case mobility
    case transfer
    case tools
    case voiceInput
}
