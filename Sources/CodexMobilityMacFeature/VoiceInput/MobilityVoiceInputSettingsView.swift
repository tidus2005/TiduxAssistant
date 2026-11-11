import SwiftUI

struct MobilityVoiceInputSettingsView: View {
    @ObservedObject var store: MacVoiceInputStore
    let isModuleEnabled: Bool
    @State private var editingEntry: LexiconEntry?
    @State private var editingProfile: AppToneProfile?

    var body: some View {
        Form {
            if !isModuleEnabled {
                Section {
                    Label(
                        "语音输入模块已关闭。请先在“模块”中开启，权限操作和听写设置才会生效。",
                        systemImage: "mic.slash"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Section("听写") {
                Picker("识别语言", selection: $store.localeIdentifier) {
                    Text("中文（简体）").tag("zh-CN")
                    Text("English (US)").tag("en-US")
                }

                Toggle("使用 Codex CLI 智能整理", isOn: $store.codexEnabled)
            }

            Section("Codex") {
                LabeledContent("状态", value: store.codexAvailable ? "已发现" : "未发现")
                LabeledContent("超时", value: "\(Int(store.codexTimeoutSeconds)) 秒")
                Slider(value: $store.codexTimeoutSeconds, in: 5...20, step: 1)
            }

            Section("个人字典") {
                Text("别名会替换为标准词；开启保护后，专名不会被本地规则或 Codex 改写。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.lexicon.entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.term)
                            Text((entry.aliases ?? []).joined(separator: "、"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.isProtected { Image(systemName: "lock.shield") }
                        Button("编辑") { editingEntry = entry }
                        Button("删除", role: .destructive) { store.deleteLexiconEntry(id: entry.id) }
                    }
                }
                Button("添加词条") { editingEntry = LexiconEntry(term: "", protect: true, source: .manual) }
            }

            Section("App 风格") {
                Text("未匹配 App：\(store.appStyles.defaultTone.title)；风格在 Codex 开启后生效。App 开关不能越过总开关。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.appStyles.profiles.filter { $0.match.kind == .bundleId }) { profile in
                    HStack {
                        Text(profile.match.value)
                        Spacer()
                        Text(profile.tone.title).foregroundStyle(.secondary)
                        Text((profile.polishEnabled ?? true) ? "允许整理" : "仅本地")
                            .font(.caption)
                        Button("编辑") { editingProfile = profile }
                        Button("删除", role: .destructive) { store.deleteAppProfile(id: profile.id) }
                    }
                }
                Button("添加 App") {
                    editingProfile = AppToneProfile(match: .init(value: ""), tone: .faithful, polishEnabled: true)
                }
            }

            Section("加密历史") {
                Toggle("保留本机文字历史（7 天，最多 200 条）", isOn: $store.historyEnabled)
                Text("默认关闭。开启后用 Keychain 本机密钥加密；关闭会清除已保存历史。音频不会保存在历史中。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("刷新历史") { store.refreshHistory() }
                    Button("清空历史", role: .destructive) { store.clearHistory() }
                    Text("\(store.history.count) 条").foregroundStyle(.secondary)
                }
                ForEach(store.history.prefix(10)) { session in
                    DisclosureGroup("\(session.createdAt.formatted()) · \(session.delivery.title)") {
                        Text(session.polishedText ?? session.rawText).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let error = store.settingsError {
                Section("需要处理") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }

            Section("热键") {
                Text("单独按下并松开 Fn 开始，再按一次结束（toggle，不需按住）。⌘⇧D 仅在听写面板内开始/结束。")
                Text("如 Fn 打开表情或系统听写：系统设置 → 键盘 → 按下 🌐 键时 → 不执行任何操作。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("系统权限") {
                LabeledContent(
                    "麦克风",
                    value: store.permissions.microphoneGranted ? "已允许" : "需要允许"
                )
                LabeledContent(
                    "辅助功能",
                    value: store.permissions.accessibilityGranted ? "已允许" : "需要允许"
                )
                HStack {
                    Button("重新检查") {
                        Task { await store.refreshPermissions() }
                    }
                    if !store.permissions.allGranted {
                        Button("完成所需权限") {
                            Task { await store.requestPermissions() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section("隐私与迁移") {
                Text("Apple 本地转写为主路径，音频仅在内存中处理，不上传、不落盘；无厂商周字数墙。关闭 Codex 仍会运行本地字典和规则整理。")
                    .foregroundStyle(.secondary)
                Text("Codex 默认关闭。开启后，转写文字（含可能的个人或业务信息）会交给本机 Codex CLI，并可能发送至其配置的模型服务，遵循该服务的数据与计费政策。占位符只保护部分实体，不是匿名化。")
                    .foregroundStyle(.secondary)
                Text("字典与 App 风格 JSON 是本机明文。交付失败或目标变化时只保留在 App；点击复制会主动覆盖剪贴板。粘贴兼容模式会短暂使用系统剪贴板，剪贴板管理器可能读取。")
                    .foregroundStyle(.secondary)
                Text("首次合并启动只迁移旧 FlowType 中实际保存过的语言、Codex 选择和超时；之后只使用 Tidux助手的设置域。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!isModuleEnabled)
        .formStyle(.grouped)
        .sheet(item: $editingEntry) { entry in
            LexiconEntryEditor(entry: entry) { store.saveLexiconEntry($0) }
        }
        .sheet(item: $editingProfile) { profile in
            AppToneEditor(profile: profile) { store.saveAppProfile($0) }
        }
    }
}

private struct LexiconEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: LexiconEntry
    let save: (LexiconEntry) -> Void
    @State private var term: String
    @State private var aliases: String
    @State private var scope: String
    @State private var protect: Bool

    init(entry: LexiconEntry, save: @escaping (LexiconEntry) -> Void) {
        self.entry = entry
        self.save = save
        _term = State(initialValue: entry.term)
        _aliases = State(initialValue: (entry.aliases ?? []).joined(separator: ", "))
        _scope = State(initialValue: (entry.appScope ?? []).joined(separator: ", "))
        _protect = State(initialValue: entry.isProtected)
    }

    var body: some View {
        Form {
            Text("字典词条").font(.headline)
            TextField("标准词", text: $term)
            TextField("别名（逗号分隔）", text: $aliases)
            TextField("App bundle ID（留空为全局）", text: $scope)
            Toggle("保护专名，不改写", isOn: $protect)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    var updated = entry
                    updated.term = term.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.aliases = parts(aliases)
                    updated.appScope = parts(scope)
                    updated.protect = protect
                    save(updated)
                    dismiss()
                }.disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480)
    }

    private func parts(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

private struct AppToneEditor: View {
    @Environment(\.dismiss) private var dismiss
    let profile: AppToneProfile
    let save: (AppToneProfile) -> Void
    @State private var bundleID: String
    @State private var tone: AppTone
    @State private var polishEnabled: Bool

    init(profile: AppToneProfile, save: @escaping (AppToneProfile) -> Void) {
        self.profile = profile
        self.save = save
        _bundleID = State(initialValue: profile.match.value)
        _tone = State(initialValue: profile.tone)
        _polishEnabled = State(initialValue: profile.polishEnabled ?? true)
    }
    var body: some View {
        Form {
            Text("App 风格").font(.headline)
            TextField("App bundle ID（如 com.apple.mail）", text: $bundleID)
            Picker("风格", selection: $tone) {
                ForEach(AppTone.allCases) { Text($0.title).tag($0) }
            }
            Toggle("允许此 App 使用 Codex（还需开启总开关）", isOn: $polishEnabled)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    var updated = profile
                    updated.match = .init(value: bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
                    updated.tone = tone
                    updated.polishEnabled = polishEnabled
                    save(updated)
                    dismiss()
                }.disabled(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480)
    }
}
