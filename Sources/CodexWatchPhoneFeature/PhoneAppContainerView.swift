import CodexWatchCore
import SwiftUI

public struct PhoneAppContainerView: View {
    @AppStorage(BridgeConnectionKeys.bridgeURL) private var bridgeURL = "http://127.0.0.1:8765"
    @AppStorage(BridgeConnectionKeys.bridgeToken) private var bridgeToken = ""
    @AppStorage(BridgeConnectionKeys.bridgeSecret) private var bridgeSecret = ""
    @AppStorage(BridgeConnectionKeys.remoteBridgeURL) private var remoteBridgeURL = ""
    @AppStorage(QuietModeStore.key) private var quietModeEnabled = false
    @StateObject private var store: CodexWatchStore
    @State private var showsSettings = false
    private var onConnect: (() -> Void)?

    public init(store: CodexWatchStore = CodexWatchStore(), onConnect: (() -> Void)? = nil) {
        self.onConnect = onConnect
        self._store = StateObject(wrappedValue: store)
    }

    public var body: some View {
        PhoneRootView(store: store, onSettings: { showsSettings = true }, onConnect: onConnect)
        .sheet(isPresented: $showsSettings) {
            BridgeSettingsView(
                bridgeURL: $bridgeURL,
                bridgeToken: $bridgeToken,
                bridgeSecret: $bridgeSecret,
                quietModeEnabled: $quietModeEnabled,
                remoteBridgeURL: $remoteBridgeURL
            ) {
                configureStore()
                Task { await store.refresh() }
            }
        }
        .onOpenURL { url in
            importPairingLink(url.absoluteString)
            Task { await store.refresh() }
        }
        .onAppear {
            configureStore()
        }
        .onChange(of: bridgeURL) { _, _ in configureStore() }
        .onChange(of: bridgeToken) { _, _ in configureStore() }
        .onChange(of: bridgeSecret) { _, _ in configureStore() }
        .onChange(of: remoteBridgeURL) { _, _ in configureStore() }
    }

    private func configureStore() {
        if let remote = URL(string: remoteBridgeURL), remote.scheme == "https", !bridgeToken.isEmpty {
            store.configure(remoteClient: BridgeClient(configuration: BridgeClientConfiguration(
                baseURL: remote, bearerToken: bridgeToken, sharedSecret: Data(base64Encoded: bridgeSecret)), route: .remoteHTTPS))
        } else { store.configure(remoteClient: nil) }
        guard let url = URL(string: bridgeURL), !bridgeToken.isEmpty else {
            store.configure(client: nil)
            return
        }
        let secret = Data(base64Encoded: bridgeSecret)
        store.configure(
            client: BridgeClient(
                configuration: BridgeClientConfiguration(
                    baseURL: url,
                    bearerToken: bridgeToken,
                    sharedSecret: secret
                )
            )
        )
    }

    private func importPairingLink(_ link: String) {
        guard let pairing = try? BridgePairingLink(link: link) else {
            return
        }
        bridgeURL = pairing.bridgeURL.absoluteString
        bridgeToken = pairing.token
        bridgeSecret = pairing.sharedSecret
        configureStore()
    }
}

public struct BridgeSettingsView: View {
    @Binding public var bridgeURL: String
    @Binding public var bridgeToken: String
    @Binding public var bridgeSecret: String
    @Binding public var quietModeEnabled: Bool
    @Binding public var remoteBridgeURL: String
    public var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pairingLink = ""
    @State private var importError: String?

    public init(
        bridgeURL: Binding<String>,
        bridgeToken: Binding<String>,
        bridgeSecret: Binding<String>,
        quietModeEnabled: Binding<Bool>,
        remoteBridgeURL: Binding<String> = .constant(""),
        onSave: @escaping () -> Void
    ) {
        self._bridgeURL = bridgeURL
        self._bridgeToken = bridgeToken
        self._bridgeSecret = bridgeSecret
        self._quietModeEnabled = quietModeEnabled
        self._remoteBridgeURL = remoteBridgeURL
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("蓝牙优先，自动切换", systemImage: "point.3.connected.trianglepath.dotted")
                    Text("在“设备”页添加 Mac。蓝牙暂不可用时，会尝试已配置的网络连接。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("提醒") { Toggle("静音模式", isOn: $quietModeEnabled) }
                Section {
                    DisclosureGroup("高级网络设置") {
                        TextField("粘贴配对链接", text: $pairingLink, axis: .vertical)
                            .autocorrectionDisabled().lineLimit(2...4)
                        Button("导入配对链接") { importPairingLink() }
                        if let importError { Text(importError).font(.caption).foregroundStyle(.orange) }
                        TextField("Mac 局域网地址", text: $bridgeURL).autocorrectionDisabled()
                        SecureField("配对令牌", text: $bridgeToken)
                        SecureField("共享密钥", text: $bridgeSecret)
                        TextField("备用 HTTPS 地址（选填）", text: $remoteBridgeURL).autocorrectionDisabled()
                        Text("网络连接需使用同一台 Mac 的配对信息。不会更改 VPN 或代理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: { Text("通常只需蓝牙配对。离开 Mac 后使用远程连接，需要预先配置可达的 HTTPS 地址。") }

            }
            .navigationTitle("连接与通知")
            .toolbar {
                Button("完成") {
                    onSave()
                    dismiss()
                }
            }
        }
    }

    private func importPairingLink() {
        do {
            let pairing = try BridgePairingLink(link: pairingLink)
            bridgeURL = pairing.bridgeURL.absoluteString
            bridgeToken = pairing.token
            bridgeSecret = pairing.sharedSecret
            importError = nil
            onSave()
        } catch {
            importError = error.localizedDescription
        }
    }
}

#Preview {
    PhoneAppContainerView()
}
