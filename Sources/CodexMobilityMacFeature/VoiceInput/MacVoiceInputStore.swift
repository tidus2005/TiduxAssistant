import AppKit
import Combine
import Foundation

@MainActor
protocol VoicePermissionServicing: AnyObject {
    func snapshot() -> PermissionSnapshot
    func requestAll() async -> PermissionSnapshot
}

extension PermissionService: VoicePermissionServicing {
    func requestAll() async -> PermissionSnapshot {
        await requestAll(promptForAccessibility: true)
    }
}

@MainActor
protocol VoiceFunctionKeyMonitoring: AnyObject {
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

extension FunctionKeyMonitor: VoiceFunctionKeyMonitoring {}

protocol VoiceSpeechTranscribing: Sendable {
    func start(
        locale: Locale
    ) async throws -> AsyncThrowingStream<SpeechTranscriptionUpdate, Error>
    func stop() async throws -> String
    func cancel() async
}

extension SpeechTranscriptionService: VoiceSpeechTranscribing {
    func start(
        locale: Locale
    ) async throws -> AsyncThrowingStream<SpeechTranscriptionUpdate, Error> {
        try await start(locale: locale, audioBufferSink: nil)
    }
}

protocol VoiceCodexPolishing: Sendable {
    var isAvailable: Bool { get }
    func polish(
        rawText: String,
        locale: String?,
        timeout: TimeInterval
    ) async -> CodexPolisher.PolishResult
    func polish(rawText: String, locale: String?, timeout: TimeInterval,
                tone: AppTone, protectedTerms: [String]) async -> CodexPolisher.PolishResult
}

extension VoiceCodexPolishing {
    func polish(rawText: String, locale: String?, timeout: TimeInterval,
                tone: AppTone, protectedTerms: [String]) async -> CodexPolisher.PolishResult {
        await polish(rawText: rawText, locale: locale, timeout: timeout)
    }
}

extension CodexPolisher: VoiceCodexPolishing {
    func polish(rawText: String, locale: String?, timeout: TimeInterval) async -> PolishResult {
        await polish(rawText: rawText, locale: locale, timeout: timeout, tone: .faithful, protectedTerms: [])
    }
}

@MainActor
protocol VoiceTextInserting: AnyObject {
    func captureTarget() throws -> CapturedTextTarget
    func insert(
        _ text: String,
        into target: CapturedTextTarget
    ) async throws -> TextInsertionService.InsertionMethod
}

extension TextInsertionService: VoiceTextInserting {}

@MainActor
protocol VoiceOverlayPresenting: AnyObject {
    func showRecording(text: String, level: Double)
    func showProcessing(text: String)
    func showResult(text: String)
    func showError(text: String)
    func hide()
}

extension OverlayPanelController: VoiceOverlayPresenting {}

@MainActor
protocol VoicePasteboardWriting: AnyObject {
    func write(_ text: String) -> Bool
}

@MainActor
private final class SystemVoicePasteboardWriter: VoicePasteboardWriting {
    func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

@MainActor
public final class MacVoiceInputStore: ObservableObject {
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var statusMessage = "按一下 Fn，或点击麦克风开始听写。"
    @Published private(set) var permissions = PermissionSnapshot()
    @Published private(set) var codexAvailable = false
    @Published private(set) var liveTranscript = ""
    @Published private(set) var finalTranscript = ""
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var usedRawFallback = false

    @Published private(set) var deliveryState: DeliveryState = .retainedOnly
    @Published private(set) var lexicon = LexiconDocument()
    @Published private(set) var appStyles = AppTonesDocument()
    @Published private(set) var history: [TranscriptSession] = []
    @Published private(set) var settingsError: String?
    @Published private(set) var correctionNeedsReview = false
    @Published var historyEnabled: Bool {
        didSet {
            preferences.set(historyEnabled, forKey: PreferenceKey.historyEnabled)
            if historyEnabled { refreshHistory() } else { clearHistory() }
        }
    }

    @Published var codexEnabled: Bool {
        didSet {
            preferences.set(codexEnabled, forKey: PreferenceKey.codexEnabled)
            if !codexEnabled { codexPolishTask?.cancel() }
        }
    }

    @Published var localeIdentifier: String {
        didSet {
            preferences.set(localeIdentifier, forKey: PreferenceKey.localeIdentifier)
        }
    }

    @Published var codexTimeoutSeconds: Double {
        didSet {
            preferences.set(codexTimeoutSeconds, forKey: PreferenceKey.codexTimeoutSeconds)
        }
    }

    var localeDisplayName: String {
        switch localeIdentifier {
        case "zh-CN":
            return "中文（简体）"
        case "en-US":
            return "English (US)"
        default:
            return Locale.current.localizedString(forIdentifier: localeIdentifier)
                ?? localeIdentifier
        }
    }

    private enum PreferenceKey {
        static let historyEnabled = "com.tidux.codex-watch-pet.voice-input.history-enabled.v1"
        static let codexEnabled =
            "com.tidux.codex-watch-pet.voice-input.codex-enabled.v1"
        static let localeIdentifier =
            "com.tidux.codex-watch-pet.voice-input.locale-identifier.v1"
        static let codexTimeoutSeconds =
            "com.tidux.codex-watch-pet.voice-input.codex-timeout-seconds.v1"
        static let legacyMigrationCompleted =
            "com.tidux.codex-watch-pet.voice-input.flowtype-migration-completed.v1"
    }

    private enum LegacyPreferenceKey {
        static let codexEnabled = "codexEnabled"
        static let localeIdentifier = "localeIdentifier"
        static let codexTimeoutSeconds = "codexTimeoutSeconds"
    }

    private let configurationDirectory: URL
    private let lexiconStore: LexiconStore
    private let stylePolicy: AppStylePolicy
    private let historyRepository: HistoryRepository
    private var currentSession: TranscriptSession?
    private var sessionBundleID: String?
    private let preferences: UserDefaults
    private let permissionService: any VoicePermissionServicing
    private let speechService: any VoiceSpeechTranscribing
    private let codexPolisher: any VoiceCodexPolishing
    private let insertionService: any VoiceTextInserting
    private let overlayController: any VoiceOverlayPresenting
    private let injectedFunctionKeyMonitor: (any VoiceFunctionKeyMonitoring)?
    private let pasteboardWriter: any VoicePasteboardWriting

    private lazy var functionKeyMonitor: any VoiceFunctionKeyMonitoring = {
        if let injectedFunctionKeyMonitor {
            return injectedFunctionKeyMonitor
        }
        return FunctionKeyMonitor { [weak self] in
            guard let self else { return }
            await self.toggleDictation()
        }
    }()

    private var isEnabled = false
    private var capturedTarget: CapturedTextTarget?
    private var transcriptionTask: Task<Void, Never>?
    private var codexPolishTask:
        Task<CodexPolisher.PolishResult, Never>?
    private var completionResetTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0

    private func isActive(generation: UInt64) -> Bool {
        isEnabled
            && generation == sessionGeneration
            && !Task.isCancelled
    }

    public convenience init() {
        self.init(
            preferences: .standard,
            legacyPreferences: UserDefaults(suiteName: "com.tidux.flowtype"),
            codexPolisher: CodexPolisher()
        )
    }

    init(
        preferences: UserDefaults = .standard,
        legacyPreferences: UserDefaults? = UserDefaults(suiteName: "com.tidux.flowtype"),
        codexPolisher: any VoiceCodexPolishing = CodexPolisher(),
        permissionService: any VoicePermissionServicing = PermissionService(),
        speechService: any VoiceSpeechTranscribing = SpeechTranscriptionService(),
        insertionService: any VoiceTextInserting = TextInsertionService(),
        overlayController: any VoiceOverlayPresenting = OverlayPanelController(),
        functionKeyMonitor: (any VoiceFunctionKeyMonitoring)? = nil,
        pasteboardWriter: any VoicePasteboardWriting = SystemVoicePasteboardWriter(),
        configurationDirectory: URL = VoiceStorage.directory,
        historyKeyProvider: any HistoryKeyProviding = KeychainHistoryKeyProvider()
    ) {
        self.configurationDirectory = configurationDirectory
        lexiconStore = LexiconStore(directory: configurationDirectory)
        stylePolicy = AppStylePolicy(directory: configurationDirectory)
        historyRepository = HistoryRepository(directory: configurationDirectory, keyProvider: historyKeyProvider)
        historyEnabled = preferences.bool(forKey: PreferenceKey.historyEnabled)
        self.preferences = preferences
        self.codexPolisher = codexPolisher
        self.permissionService = permissionService
        self.speechService = speechService
        self.insertionService = insertionService
        self.overlayController = overlayController
        injectedFunctionKeyMonitor = functionKeyMonitor
        self.pasteboardWriter = pasteboardWriter
        Self.migrateLegacyPreferencesIfNeeded(
            from: legacyPreferences,
            to: preferences
        )

        if preferences.object(forKey: PreferenceKey.codexEnabled) == nil {
            codexEnabled = false
        } else {
            codexEnabled = preferences.bool(forKey: PreferenceKey.codexEnabled)
        }

        localeIdentifier = preferences.string(forKey: PreferenceKey.localeIdentifier)
            ?? "zh-CN"

        let storedTimeout = preferences.double(forKey: PreferenceKey.codexTimeoutSeconds)
        codexTimeoutSeconds = storedTimeout > 0 ? min(max(storedTimeout, 5), 20) : 12
        do {
            lexicon = try lexiconStore.load()
            appStyles = try stylePolicy.load()
        } catch { settingsError = error.localizedDescription }
    }

    func start() async {
        guard !Task.isCancelled, !isEnabled else { return }
        isEnabled = true
        sessionGeneration &+= 1
        let activeGeneration = sessionGeneration

        do {
            try reloadConfiguration()
            if !FileManager.default.fileExists(atPath: lexiconStore.url.path) { try lexiconStore.save(lexicon) }
            if !FileManager.default.fileExists(atPath: stylePolicy.url.path) { try stylePolicy.save(appStyles) }
            try HotkeySemantics.save(to: configurationDirectory)
        } catch { settingsError = error.localizedDescription }
        refreshHistory()
        codexAvailable = codexPolisher.isAvailable
        await refreshPermissions(generation: activeGeneration)
        guard isActive(generation: activeGeneration) else { return }

        if permissions.allGranted, functionKeyMonitor.isRunning {
            statusMessage = codexEnabled && codexAvailable
                ? "已就绪：Fn 听写，本地转写，Codex 整理已开启。"
                : "已就绪：Fn 听写，本地转写与规则整理。"
        } else if permissions.allGranted {
            statusMessage = "系统权限已就绪，但 Fn 监听器启动失败；仍可点击麦克风听写。"
        } else {
            statusMessage = "请完成麦克风和辅助功能权限。"
        }
    }

    func refreshPermissions() async {
        guard isEnabled, !Task.isCancelled else { return }
        await refreshPermissions(generation: sessionGeneration)
    }

    private func refreshPermissions(generation: UInt64) async {
        guard isActive(generation: generation) else { return }
        let refreshedPermissions = permissionService.snapshot()
        let refreshedCodexAvailability = codexPolisher.isAvailable
        guard isActive(generation: generation) else { return }
        permissions = refreshedPermissions
        codexAvailable = refreshedCodexAvailability

        if permissions.accessibilityGranted {
            guard isActive(generation: generation) else { return }
            do {
                try functionKeyMonitor.start()
            } catch {
                guard isActive(generation: generation) else { return }
                statusMessage = error.localizedDescription
                AppLog.lifecycle.error(
                    "Fn monitor failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        } else {
            functionKeyMonitor.stop()
        }
    }

    func requestPermissions() async {
        guard isEnabled, !Task.isCancelled else { return }
        let activeGeneration = sessionGeneration
        statusMessage = "正在请求系统权限…"
        let requestedPermissions = await permissionService.requestAll()
        guard isActive(generation: activeGeneration) else { return }
        permissions = requestedPermissions
        await refreshPermissions(generation: activeGeneration)
        guard isActive(generation: activeGeneration) else { return }

        if permissions.allGranted {
            statusMessage = "权限已就绪，可以开始听写。"
        } else {
            statusMessage = "部分权限尚未启用；在系统设置中完成后点“重新检查”。"
        }
    }

    func toggleDictation() async {
        guard isEnabled, !Task.isCancelled else { return }
        switch phase {
        case .recording:
            await finishDictation()
        case .idle, .completed, .failed:
            await beginDictation()
        case .preparing, .processing, .inserting:
            return
        }
    }

    func shutdown() {
        isEnabled = false
        sessionGeneration &+= 1
        completionResetTask?.cancel()
        completionResetTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        codexPolishTask?.cancel()
        codexPolishTask = nil
        functionKeyMonitor.stop()
        capturedTarget = nil
        audioLevel = 0
        liveTranscript = ""
        finalTranscript = ""
        currentSession = nil
        sessionBundleID = nil
        deliveryState = .cancelled
        usedRawFallback = false
        overlayController.hide()
        phase = .idle
        statusMessage = "语音输入模块已关闭。"

        let speechService = speechService
        Task {
            await speechService.cancel()
        }
    }

    private func beginDictation() async {
        guard isEnabled, !Task.isCancelled else { return }
        completionResetTask?.cancel()
        completionResetTask = nil
        phase = .preparing
        statusMessage = "正在检查权限…"
        sessionGeneration &+= 1
        let activeGeneration = sessionGeneration

        await refreshPermissions(generation: activeGeneration)
        guard isActive(generation: activeGeneration) else { return }
        guard permissions.microphoneGranted else {
            fail("需要先允许麦克风权限。", generation: activeGeneration)
            return
        }
        do { try reloadConfiguration() } catch {
            fail("语音配置读取失败：\(error.localizedDescription)", generation: activeGeneration)
            return
        }
        capturedTarget = nil
        sessionBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            capturedTarget = try insertionService.captureTarget()
        } catch TextInsertionService.InsertionError.secureTextField {
            fail("密码输入框中禁止启动听写。", generation: activeGeneration)
            return
        } catch {
            AppLog.insertion.notice(
                "No insertion target captured: \(error.localizedDescription, privacy: .public)"
            )
        }

        statusMessage = "正在准备本地语音模型…"
        liveTranscript = ""
        finalTranscript = ""
        currentSession = nil
        deliveryState = .retainedOnly
        correctionNeedsReview = false
        audioLevel = 0
        usedRawFallback = false
        overlayController.showProcessing(text: "正在准备本地语音模型")

        do {
            let updates = try await speechService.start(
                locale: Locale(identifier: localeIdentifier)
            )
            guard isActive(generation: activeGeneration) else {
                await speechService.cancel()
                return
            }
            phase = .recording
            statusMessage = capturedTarget == nil
                ? "正在听写；未捕获输入框，完成后在本 App 保留，请手动复制。"
                : "正在听写，再按一下 Fn 结束。"
            overlayController.showRecording(text: "", level: 0)

            transcriptionTask?.cancel()
            transcriptionTask = Task { [weak self] in
                do {
                    for try await update in updates {
                        guard !Task.isCancelled else { break }
                        guard let self,
                              self.isActive(generation: activeGeneration) else {
                            return
                        }
                        self.acceptSpeechUpdate(
                            update,
                            generation: activeGeneration
                        )
                    }
                } catch {
                    guard let self,
                          self.isActive(generation: activeGeneration) else {
                        return
                    }
                    await self.handleSpeechStreamFailure(
                        error,
                        generation: activeGeneration
                    )
                }
            }
        } catch {
            guard isActive(generation: activeGeneration) else { return }
            fail(error.localizedDescription, generation: activeGeneration)
        }
    }

    private func finishDictation() async {
        guard isEnabled, !Task.isCancelled, phase == .recording else { return }
        let activeGeneration = sessionGeneration
        let activeTranscriptionTask = transcriptionTask

        phase = .processing
        statusMessage = "正在完成本地转写…"
        audioLevel = 0
        overlayController.showProcessing(text: "正在完成本地转写")

        let rawText: String
        do {
            rawText = try await speechService.stop()
            guard isActive(generation: activeGeneration) else { return }
            await activeTranscriptionTask?.value
            guard isActive(generation: activeGeneration) else { return }
            transcriptionTask = nil
        } catch {
            guard isActive(generation: activeGeneration) else { return }
            activeTranscriptionTask?.cancel()
            transcriptionTask = nil
            fail(error.localizedDescription, generation: activeGeneration)
            return
        }

        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawText.isEmpty else {
            fail("没有识别到可写入的语音。", generation: activeGeneration)
            return
        }

        liveTranscript = ""
        let entries = lexicon.entries
        let bundleID = capturedTarget?.applicationBundleIdentifier ?? sessionBundleID
        let dictionaryText = LexiconStore.replacingAliases(in: trimmedRawText, entries: entries, bundleID: bundleID)
        let protectedTerms = LexiconStore.protectedTerms(in: entries, bundleID: bundleID)
        let localText = LocalTextCleaner.clean(dictionaryText, protectedTerms: protectedTerms)
        correctionNeedsReview = EditValidator.hasCorrectionConflict(dictionaryText)
        let style = AppStylePolicy.resolve(bundleID: bundleID, document: appStyles, globalPolishEnabled: codexEnabled)
        finalTranscript = localText
        var outputText = localText

        if style.polishEnabled && !correctionNeedsReview {
            statusMessage = "Codex 正在按 App 风格整理文字…"
            overlayController.showProcessing(text: statusMessage)
            let codexPolisher = codexPolisher
            let locale = localeIdentifier
            let timeout = codexTimeoutSeconds
            let polishTask = Task {
                await codexPolisher.polish(rawText: localText, locale: locale, timeout: timeout,
                                          tone: style.tone, protectedTerms: protectedTerms)
            }
            codexPolishTask = polishTask
            let result = await polishTask.value
            guard isActive(generation: activeGeneration) else { return }
            codexPolishTask = nil
            if codexEnabled,
               (try? EditValidator.validate(source: localText, candidate: result.text, protectedTerms: protectedTerms)) != nil {
                outputText = result.text
                usedRawFallback = result.usedFallback
            } else {
                usedRawFallback = true
            }
        } else {
            usedRawFallback = false
        }

        guard isActive(generation: activeGeneration) else { return }
        finalTranscript = outputText
        phase = .inserting
        statusMessage = "正在写回原输入框…"
        let coordinator = DeliveryCoordinator(insertion: insertionService, pasteboard: pasteboardWriter)
        // Conflicting corrections require review rather than automatic delivery.
        let delivery = correctionNeedsReview ? DeliveryState.retainedOnly
            : await coordinator.deliver(outputText, target: capturedTarget)
        guard isActive(generation: activeGeneration) else { return }
        deliveryState = delivery
        currentSession = TranscriptSession(locale: localeIdentifier, targetApp: bundleID,
            rawText: trimmedRawText, polishedText: outputText,
            deliveredText: delivery == .inserted ? outputText : nil,
            tone: style.tone.rawValue,
            dictionaryVersion: ISO8601DateFormatter().string(from: lexicon.updatedAt), delivery: delivery)
        persistCurrentSession()
        let review = correctionNeedsReview ? "检测到数字改口，已保留原文，请检查后手动复制。" : delivery.title
        complete(message: review + (usedRawFallback ? " Codex 未通过校验，已回退本地整理。" : ""),
                 overlayMessage: review, generation: activeGeneration)
        capturedTarget = nil
    }

    func copyFinalTranscript() {
        guard !phase.isBusy, !finalTranscript.isEmpty else { return }
        deliveryState = DeliveryCoordinator(insertion: insertionService, pasteboard: pasteboardWriter)
            .copyByUser(finalTranscript)
        currentSession?.delivery = deliveryState
        currentSession?.deliveredText = deliveryState == .copiedByUser ? finalTranscript : nil
        persistCurrentSession()
        statusMessage = deliveryState.title
    }

    private func reloadConfiguration() throws {
        lexicon = try lexiconStore.load()
        appStyles = try stylePolicy.load()
    }

    func saveLexiconEntry(_ entry: LexiconEntry) {
        do {
            var document = try lexiconStore.load()
            document.entries.removeAll { $0.id == entry.id }
            document.entries.append(entry)
            document.updatedAt = Date()
            try lexiconStore.save(document)
            lexicon = document
            settingsError = nil
        } catch { settingsError = error.localizedDescription }
    }

    func deleteLexiconEntry(id: String) {
        do {
            var document = try lexiconStore.load()
            document.entries.removeAll { $0.id == id }
            document.updatedAt = Date()
            try lexiconStore.save(document)
            lexicon = document
            settingsError = nil
        } catch { settingsError = error.localizedDescription }
    }

    func saveAppProfile(_ profile: AppToneProfile) {
        do {
            var document = try stylePolicy.load()
            document.profiles.removeAll { $0.id == profile.id }
            document.profiles.append(profile)
            document.updatedAt = Date()
            try stylePolicy.save(document)
            appStyles = document
            settingsError = nil
        } catch { settingsError = error.localizedDescription }
    }

    func deleteAppProfile(id: String) {
        do {
            var document = try stylePolicy.load()
            document.profiles.removeAll { $0.id == id }
            document.updatedAt = Date()
            try stylePolicy.save(document)
            appStyles = document
            settingsError = nil
        } catch { settingsError = error.localizedDescription }
    }

    func refreshHistory() {
        guard historyEnabled else { history = []; return }
        do { history = try historyRepository.load() }
        catch { settingsError = error.localizedDescription }
    }

    func clearHistory() {
        do {
            try historyRepository.clear()
            history = []
            currentSession = nil
        } catch { settingsError = error.localizedDescription }
    }

    private func persistCurrentSession() {
        guard let currentSession, historyEnabled else { return }
        do {
            try historyRepository.record(currentSession, enabled: historyEnabled)
            history = try historyRepository.load()
        } catch { settingsError = error.localizedDescription }
    }

    private func acceptSpeechUpdate(
        _ update: SpeechTranscriptionUpdate,
        generation: UInt64
    ) {
        guard isActive(generation: generation),
              phase == .recording || phase == .processing else {
            return
        }
        liveTranscript = update.text
        audioLevel = update.audioLevel

        if phase == .recording {
            overlayController.showRecording(
                text: update.text,
                level: update.audioLevel
            )
        }
    }

    private func handleSpeechStreamFailure(
        _ error: Error,
        generation: UInt64
    ) async {
        guard isActive(generation: generation), phase == .recording else { return }
        await speechService.cancel()
        guard isActive(generation: generation), phase == .recording else { return }
        transcriptionTask = nil
        fail(
            "语音转写已中断：\(error.localizedDescription)",
            generation: generation
        )
    }

    private func complete(
        message: String,
        overlayMessage: String,
        generation: UInt64
    ) {
        guard isActive(generation: generation) else { return }
        phase = .completed
        statusMessage = message
        audioLevel = 0
        if deliveryState == .inserted || deliveryState == .copiedByUser {
            overlayController.showResult(text: overlayMessage)
        } else {
            overlayController.showError(text: overlayMessage)
        }

        completionResetTask?.cancel()
        completionResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2.5))
            } catch {
                return
            }
            guard let self,
                  self.isActive(generation: generation),
                  self.phase == .completed else {
                return
            }
            self.phase = .idle
            self.statusMessage = self.deliveryState.title + "。按 Fn 开始下一次听写。"
        }
    }

    private func fail(_ message: String, generation: UInt64) {
        guard isActive(generation: generation) else { return }
        phase = .failed(message)
        statusMessage = message
        audioLevel = 0
        capturedTarget = nil
        overlayController.showError(text: message)
        AppLog.lifecycle.error("Flow failed: \(message, privacy: .public)")
    }

    private static func migrateLegacyPreferencesIfNeeded(
        from legacy: UserDefaults?,
        to preferences: UserDefaults
    ) {
        guard preferences.object(
            forKey: PreferenceKey.legacyMigrationCompleted
        ) == nil else {
            return
        }

        defer {
            preferences.set(
                true,
                forKey: PreferenceKey.legacyMigrationCompleted
            )
        }
        guard let legacy else { return }

        if preferences.object(forKey: PreferenceKey.codexEnabled) == nil,
           let enabled = legacy.object(
               forKey: LegacyPreferenceKey.codexEnabled
           ) as? Bool {
            preferences.set(
                enabled,
                forKey: PreferenceKey.codexEnabled
            )
        }

        if preferences.object(forKey: PreferenceKey.localeIdentifier) == nil,
           let locale = legacy.string(
               forKey: LegacyPreferenceKey.localeIdentifier
           ),
           !locale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preferences.set(
                locale,
                forKey: PreferenceKey.localeIdentifier
            )
        }

        if preferences.object(forKey: PreferenceKey.codexTimeoutSeconds) == nil,
           let number = legacy.object(
               forKey: LegacyPreferenceKey.codexTimeoutSeconds
           ) as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           case let timeout = number.doubleValue,
           timeout.isFinite,
           timeout > 0 {
            preferences.set(
                min(max(timeout, 5), 20),
                forKey: PreferenceKey.codexTimeoutSeconds
            )
        }
    }
}
