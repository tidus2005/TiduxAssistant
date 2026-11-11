#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFAudio
import Darwin
import CodexMobilityCore
import Foundation
import Observation
import UIKit

enum MobileRecordingPhase: String, Sendable {
    case idle
    case preparing
    case recording
    case stopping
    case finalizationDelayed
    case completed
    case failed

    var title: String {
        switch self {
        case .idle:
            "准备就绪"
        case .preparing:
            "正在准备"
        case .recording:
            "正在倾听"
        case .stopping:
            "正在收尾"
        case .finalizationDelayed:
            "收尾超时"
        case .completed:
            "录音已保存"
        case .failed:
            "录音已中断"
        }
    }

    var isBusy: Bool {
        self == .preparing ||
            self == .stopping ||
            self == .finalizationDelayed
    }
}

enum MobileAudioSessionEventError: LocalizedError, Sendable {
    case interrupted
    case mediaServicesReset
    case routeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .interrupted:
            "录音被电话、Siri 或其他系统音频中断。"
        case .mediaServicesReset:
            "系统音频服务已重置。"
        case let .routeUnavailable(message):
            "麦克风音频路由不可用：\(message)"
        }
    }
}

enum MobileRecordingEnvironmentError: LocalizedError, Sendable {
    case simulatorMicrophoneUnsupported
    case movedToBackgroundDuringPreparation

    var errorDescription: String? {
        switch self {
        case .simulatorMicrophoneUnsupported:
            "iOS 模拟器不能可靠启动麦克风实时转写，请在实体 iPhone 上验收。"
        case .movedToBackgroundDuringPreparation:
            "App 在录音准备期间进入后台，本次录音已取消并保留检查点。"
        }
    }
}

enum MobileRecordingIntegrityError: LocalizedError, Sendable {
    case noCapturedAudio

    var errorDescription: String? {
        switch self {
        case .noCapturedAudio:
            "录音期间没有收到任何麦克风音频帧，本次记录已标记为失败，请检查输入设备后重试。"
        }
    }
}

enum MobileHistoryTransferError:
    LocalizedError,
    Equatable,
    Sendable
{
    case operationAlreadyInProgress
    case recordingLifecycleInProgress

    var errorDescription: String? {
        switch self {
        case .operationAlreadyInProgress:
            "历史迁移正在进行，请等待当前操作完成。"
        case .recordingLifecycleInProgress:
            "正在录音、准备或收尾，暂时不能迁移历史记录。"
        }
    }
}

enum MobileSpeechUpdateTelemetryKind: Equatable, Sendable {
    case unchanged
    case partial
    case final
}

struct MobileSpeechUpdateTelemetry: Sendable {
    private var lastFinalizedText = ""
    private var lastVolatileText = ""

    mutating func reset() {
        lastFinalizedText = ""
        lastVolatileText = ""
    }

    mutating func classify(
        _ update: SpeechTranscriptionUpdate
    ) -> MobileSpeechUpdateTelemetryKind {
        let changed =
            update.finalizedText != lastFinalizedText ||
            update.volatileText != lastVolatileText
        lastFinalizedText = update.finalizedText
        lastVolatileText = update.volatileText

        guard changed, !update.text.isEmpty else {
            return .unchanged
        }
        return update.isFinal ? .final : .partial
    }
}

enum MobileRecordingTextRecovery {
    static func preservedText(
        finalTranscript: String,
        liveTranscript: String
    ) -> String {
        finalTranscript.isEmpty
            ? liveTranscript
            : finalTranscript
    }
}

@MainActor
@Observable
final class MobileAppModel {
    static let minimumRecordingStorageBytes: Int64 =
        256 * 1_024 * 1_024
    static let minimumOngoingStorageBytes: Int64 =
        64 * 1_024 * 1_024

    private enum PreferenceKey {
        static let localeIdentifier =
            "com.tidux.CodexWatchPet.voiceInput.localeIdentifier"
        static let keepAudio =
            "com.tidux.CodexWatchPet.voiceInput.keepAudio"
    }

    private static let supportedLocaleIdentifiers: Set<String> = [
        "zh-CN",
        "zh-TW",
        "en-US",
        "ja-JP",
    ]

    private enum StopReason {
        case user
        case movedToBackground
    }

    var phase: MobileRecordingPhase = .idle
    var statusMessage = "点击下方按钮，开始记录现场内容。"
    var liveTranscript = ""
    var finalTranscript = ""
    var audioLevel = 0.0
    var elapsedSeconds: TimeInterval = 0
    var capability = MobileSpeechCapabilitySnapshot()
    var history: [TranscriptSessionRecord] = []
    var selectedLocaleIdentifier = "zh-CN" {
        didSet {
            preferences.set(
                selectedLocaleIdentifier,
                forKey: PreferenceKey.localeIdentifier
            )
        }
    }
    var keepAudio = true {
        didSet {
            preferences.set(
                keepAudio,
                forKey: PreferenceKey.keepAudio
            )
        }
    }
    var availableStorageBytes: Int64?
    var firstPartialLatencyMilliseconds: Int?
    var partialUpdateCount = 0
    var finalUpdateCount = 0
    var finalizationDurationMilliseconds: Int?
    var recordedAudioFrameCount: Int64?
    var recordedAudioDurationSeconds: TimeInterval?
    var recordingStartAvailableStorageBytes: Int64?
    var recordingEndAvailableStorageBytes: Int64?
    var peakThermalState = "nominal"
    var recordingStartResidentMemoryBytes: UInt64?
    var recordingEndResidentMemoryBytes: UInt64?
    var peakResidentMemoryBytes: UInt64?
    var localeReservationObservedDuringRecording = false
    var localeReservationReleasedAfterRecording = false
    var diagnostics: [String] = []
    var isStartOperationInFlight = false
    var isHistoryTransferInProgress = false

    @ObservationIgnored
    private let speechService = SpeechTranscriptionService()
    @ObservationIgnored
    private let assetManager = MobileSpeechAssetManager()
    @ObservationIgnored
    private let sessionStore: MobileSessionStore
    @ObservationIgnored
    private let preferences: UserDefaults

    @ObservationIgnored
    private var recorder: RollingAudioRecorder?
    @ObservationIgnored
    private var captureMonitor: MonitoredAudioBufferSink?
    @ObservationIgnored
    private var activeSession: RecordingSession?
    @ObservationIgnored
    private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored
    private var durationTask: Task<Void, Never>?
    @ObservationIgnored
    private var audioRouteValidationTask: Task<Void, Never>?
    @ObservationIgnored
    private var finalizationWatchdogTask: Task<Void, Never>?
    @ObservationIgnored
    private var recordingStartedAt: Date?
    @ObservationIgnored
    private var finalizationStartedAt: Date?
    @ObservationIgnored
    private var lastCheckpointText = ""
    @ObservationIgnored
    private var lastCheckpointAt = Date.distantPast
    @ObservationIgnored
    private var speechUpdateTelemetry =
        MobileSpeechUpdateTelemetry()
    @ObservationIgnored
    private var hasPrepared = false
    @ObservationIgnored
    private var recordingRunCoordinator = RecordingRunCoordinator()
    @ObservationIgnored
    private var pendingAudioSegments: [MobileAudioSegment] = []
    @ObservationIgnored
    private var audioSessionObserverTokens: [NSObjectProtocol] = []
    @ObservationIgnored
    private var backgroundTaskIdentifier:
        UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored
    private var isAppInForeground = true
    @ObservationIgnored
    private var sceneTransitionGeneration: UInt64 = 0

    init(
        sessionStore: MobileSessionStore = MobileSessionStore(),
        preferences: UserDefaults = .standard
    ) {
        self.sessionStore = sessionStore
        self.preferences = preferences

        if
            let storedLocale = preferences.string(
                forKey: PreferenceKey.localeIdentifier
            ),
            Self.supportedLocaleIdentifiers.contains(storedLocale)
        {
            selectedLocaleIdentifier = storedLocale
        }
        if preferences.object(forKey: PreferenceKey.keepAudio) != nil {
            keepAudio = preferences.bool(forKey: PreferenceKey.keepAudio)
        }
    }

    var canToggleRecording: Bool {
        !phase.isBusy &&
            !isStartOperationInFlight &&
            !isHistoryTransferInProgress
    }

    var isRecording: Bool {
        phase == .recording
    }

    var displayedTranscript: String {
        if !liveTranscript.isEmpty {
            return liveTranscript
        }
        if !finalTranscript.isEmpty {
            return finalTranscript
        }
        return "实时文字会显示在这里。"
    }

    var elapsedLabel: String {
        let totalSeconds = max(0, Int(elapsedSeconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(
                format: "%02d:%02d:%02d",
                hours,
                minutes,
                seconds
            )
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var diagnosticReportText: String {
        makeDiagnosticReportText(includeStorage: true)
    }

    var shareableDiagnosticReportText: String {
        makeDiagnosticReportText(includeStorage: false)
    }

    private func makeDiagnosticReportText(
        includeStorage: Bool
    ) -> String {
        let reportDiagnostics = includeStorage
            ? diagnostics
            : diagnostics.filter {
                !$0.contains("空间") && !$0.contains("磁盘")
            }
        let report = MobileDiagnosticReport(
            phase: phase,
            statusMessage: includeStorage
                ? statusMessage
                : phase.title,
            selectedLocaleIdentifier: selectedLocaleIdentifier,
            capability: capability,
            keepAudio: keepAudio,
            availableStorageBytes: includeStorage
                ? availableStorageBytes
                : nil,
            minimumRecordingStorageBytes:
                Self.minimumRecordingStorageBytes,
            activeSession: activeSession,
            elapsedSeconds: elapsedSeconds,
            peakThermalState: peakThermalState,
            firstPartialLatencyMilliseconds:
                firstPartialLatencyMilliseconds,
            partialUpdateCount: partialUpdateCount,
            finalUpdateCount: finalUpdateCount,
            finalizationDurationMilliseconds:
                finalizationDurationMilliseconds,
            recordedAudioFrameCount: recordedAudioFrameCount,
            recordedAudioDurationSeconds:
                recordedAudioDurationSeconds,
            recordingStartAvailableStorageBytes:
                includeStorage
                    ? recordingStartAvailableStorageBytes
                    : nil,
            recordingEndAvailableStorageBytes:
                includeStorage
                    ? recordingEndAvailableStorageBytes
                    : nil,
            recordingStartResidentMemoryBytes:
                recordingStartResidentMemoryBytes,
            recordingEndResidentMemoryBytes:
                recordingEndResidentMemoryBytes,
            peakResidentMemoryBytes: peakResidentMemoryBytes,
            localeReservationObservedDuringRecording:
                localeReservationObservedDuringRecording,
            localeReservationReleasedAfterRecording:
                localeReservationReleasedAfterRecording,
            diagnostics: reportDiagnostics
        )
        do {
            return try report.formattedJSON()
        } catch {
            return """
            {
              "reportError": "\(error.localizedDescription)"
            }
            """
        }
    }

    func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        diagnostics = [
            "设备：\(UIDevice.current.model)",
            "系统：iOS \(UIDevice.current.systemVersion)",
            "请求语言：\(selectedLocaleIdentifier)",
        ]

        do {
            try await sessionStore.cleanupHistoryBackupStaging()
        } catch {
            diagnostics.append(
                "清理旧历史导出暂存失败：\(error.localizedDescription)"
            )
        }
        do {
            history = try await sessionStore.recoverInterruptedSessions()
        } catch {
            statusMessage = "读取历史记录失败：\(error.localizedDescription)"
            diagnostics.append("历史恢复失败：\(error.localizedDescription)")
        }
        await refreshSessionLoadIssueDiagnostics()
        do {
            let summary = try await sessionStore.recoverAudioManifests(
                for: history
            )
            if summary.recoveredManifestCount > 0 {
                diagnostics.append(
                    "已恢复 \(summary.recoveredManifestCount) 份音频清单，"
                        + "其中 \(summary.recoveredPartialSegmentCount) "
                        + "个临时分段。"
                )
            }
            if
                summary.unreadableFileCount > 0 ||
                summary.structuralIssueCount > 0
            {
                diagnostics.append(
                    "音频恢复发现 "
                        + "\(summary.unreadableFileCount) 个不可读文件、"
                        + "\(summary.structuralIssueCount) 个结构问题。"
                )
            }
        } catch {
            diagnostics.append(
                "音频恢复失败：\(error.localizedDescription)"
            )
        }
        await refreshStorageCapacity()
        await refreshCapabilities()
    }

    func refreshCapabilities() async {
        let snapshot = await assetManager.inspect(
            locale: Locale(identifier: selectedLocaleIdentifier)
        )
        capability = snapshot
        appendCapabilityDiagnostics(snapshot)
    }

    func prepareSpeechAssets() async {
        guard
            !isHistoryTransferInProgress,
            !isStartOperationInFlight,
            phase == .idle || phase == .completed || phase == .failed
        else {
            return
        }
        phase = .preparing
        statusMessage = "正在检查麦克风并准备本地语音模型…"
        do {
            capability = try await assetManager.prepare(
                locale: Locale(identifier: selectedLocaleIdentifier)
            )
            appendCapabilityDiagnostics(capability)
            statusMessage = "本地语音模型已就绪。"
            phase = .idle
        } catch {
            capability.errorMessage = error.localizedDescription
            statusMessage = error.localizedDescription
            diagnostics.append("能力门禁失败：\(error.localizedDescription)")
            phase = .failed
        }
    }

    func toggleRecording() async {
        guard canToggleRecording else { return }
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func reloadHistory() async {
        do {
            history = try await sessionStore.loadAll()
            await refreshSessionLoadIssueDiagnostics()
        } catch {
            statusMessage = "读取历史记录失败：\(error.localizedDescription)"
        }
    }

    func exportHistoryBackup(
        includeAudio: Bool,
        stagingParentDirectory: URL? = nil
    ) async throws -> VoiceHistoryBackupExport {
        try beginHistoryTransfer()
        defer { isHistoryTransferInProgress = false }

        do {
            let export = try await sessionStore.createHistoryBackup(
                stagingParentDirectory: stagingParentDirectory,
                includeAudio: includeAudio,
                sourceAppVersion:
                    Self.bundleInfoValue(
                        "CFBundleShortVersionString"
                    ),
                sourceAppBuild:
                    Self.bundleInfoValue("CFBundleVersion")
            )
            history = try await sessionStore.loadAll()
            await refreshSessionLoadIssueDiagnostics()
            statusMessage =
                "已准备 \(export.manifest.sessions.count) 条历史记录，"
                + "可选择保存或分享。"
            diagnostics.append(
                "历史导出完成："
                    + "\(export.manifest.sessions.count) 条会话，"
                    + "\(export.manifest.totalBytes) 字节。"
            )
            return export
        } catch {
            statusMessage =
                "导出历史记录失败：\(error.localizedDescription)"
            diagnostics.append(
                "历史导出失败：\(error.localizedDescription)"
            )
            throw error
        }
    }

    func importHistoryBackup(
        from packageURL: URL
    ) async throws -> VoiceHistoryBackupImportResult {
        try beginHistoryTransfer()
        defer { isHistoryTransferInProgress = false }

        do {
            let result = try await sessionStore.importHistoryBackup(
                from: packageURL
            )
            history = try await sessionStore.loadAll()
            await refreshSessionLoadIssueDiagnostics()
            statusMessage =
                "历史迁移完成：新增 "
                + "\(result.importedSessionIDs.count) 条，跳过 "
                + "\(result.skippedSessionIDs.count) 条，冲突 "
                + "\(result.conflictingSessionIDs.count) 条。"
            diagnostics.append(statusMessage)
            return result
        } catch {
            statusMessage =
                "导入历史记录失败：\(error.localizedDescription)"
            diagnostics.append(
                "历史导入失败：\(error.localizedDescription)"
            )
            throw error
        }
    }

    func deleteHistorySession(id: UUID) async {
        if isHistoryTransferInProgress {
            statusMessage = "历史迁移进行中，暂时不能删除记录。"
            return
        }
        if
            activeSession?.id == id,
            isStartOperationInFlight ||
            phase == .preparing ||
            phase == .recording ||
            phase == .stopping ||
            phase == .finalizationDelayed
        {
            statusMessage = "正在录音或收尾，暂时不能删除这条记录。"
            return
        }
        do {
            try await sessionStore.deleteSession(sessionID: id)
            history.removeAll { $0.id == id }
            if activeSession?.id == id {
                activeSession = nil
                liveTranscript = ""
                finalTranscript = ""
            }
            statusMessage = "记录及其本机音频、诊断文件已删除。"
        } catch {
            statusMessage = "删除记录失败：\(error.localizedDescription)"
            diagnostics.append(
                "删除会话失败：\(error.localizedDescription)"
            )
        }
    }

    func refreshStorageCapacity() async {
        do {
            availableStorageBytes =
                try await sessionStore
                    .availableCapacityForImportantUsage()
        } catch {
            availableStorageBytes = nil
            diagnostics.append(
                "读取可用空间失败：\(error.localizedDescription)"
            )
        }
    }

    private func beginHistoryTransfer() throws {
        guard !isHistoryTransferInProgress else {
            let error =
                MobileHistoryTransferError.operationAlreadyInProgress
            statusMessage = error.localizedDescription
            throw error
        }
        guard
            !isStartOperationInFlight,
            phase == .idle ||
                phase == .completed ||
                phase == .failed
        else {
            let error =
                MobileHistoryTransferError
                    .recordingLifecycleInProgress
            statusMessage = error.localizedDescription
            throw error
        }
        isHistoryTransferInProgress = true
    }

    private static func bundleInfoValue(_ key: String) -> String {
        Bundle.main.object(
            forInfoDictionaryKey: key
        ) as? String ?? "unknown"
    }

    func handleAppBecameInactive() {
        guard
            phase == .recording ||
            phase == .stopping ||
            phase == .finalizationDelayed
        else {
            return
        }
        beginBackgroundCleanupProtection()
    }

    func handleAppReturnedToForeground() {
        sceneTransitionGeneration &+= 1
        isAppInForeground = true
        guard phase == .recording else { return }
        endBackgroundCleanupProtection()
    }

    func beginBackgroundTransition() -> UInt64 {
        sceneTransitionGeneration &+= 1
        return sceneTransitionGeneration
    }

    func handleAppMovedToBackground(
        eventGeneration: UInt64
    ) async {
        guard eventGeneration == sceneTransitionGeneration else {
            return
        }
        isAppInForeground = false
        if
            phase == .preparing,
            activeSession?.state == .preparing,
            let generation =
                recordingRunCoordinator.activeGeneration,
            recordingRunCoordinator.acceptsUpdate(
                for: generation
            )
        {
            beginBackgroundCleanupProtection()
            await failActiveSession(
                MobileRecordingEnvironmentError
                    .movedToBackgroundDuringPreparation,
                generation: generation
            )
            return
        }
        guard phase == .recording else {
            if
                phase != .stopping &&
                phase != .finalizationDelayed
            {
                endBackgroundCleanupProtection()
            }
            return
        }
        beginBackgroundCleanupProtection()
        await stopRecording(reason: .movedToBackground)
    }

    private func startRecording() async {
        guard isAppInForeground else {
            statusMessage = "请回到 Codex Watch Pet 前台后再开始录音。"
            return
        }
        guard !isStartOperationInFlight else { return }
        isStartOperationInFlight = true
        defer {
            isStartOperationInFlight = false
        }
        phase = .preparing
        statusMessage = "正在准备麦克风和本地语音模型…"
        liveTranscript = ""
        finalTranscript = ""
        audioLevel = 0
        elapsedSeconds = 0
        firstPartialLatencyMilliseconds = nil
        partialUpdateCount = 0
        finalUpdateCount = 0
        finalizationDurationMilliseconds = nil
        recordedAudioFrameCount = nil
        recordedAudioDurationSeconds = nil
        recordingStartAvailableStorageBytes = nil
        recordingEndAvailableStorageBytes = nil
        recordingStartResidentMemoryBytes = nil
        recordingEndResidentMemoryBytes = nil
        peakThermalState = Self.currentThermalStateTitle()
        peakResidentMemoryBytes = nil
        localeReservationObservedDuringRecording = false
        localeReservationReleasedAfterRecording = false
        lastCheckpointText = ""
        lastCheckpointAt = .distantPast
        speechUpdateTelemetry.reset()
        pendingAudioSegments = []
        captureMonitor = nil
        audioRouteValidationTask?.cancel()
        audioRouteValidationTask = nil
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        finalizationStartedAt = nil
        endBackgroundCleanupProtection()
        let generation = recordingRunCoordinator.begin()

        var session = RecordingSession(
            localeIdentifier: selectedLocaleIdentifier
        )
        activeSession = session

        do {
            try await persistCheckpoint(
                text: "",
                isFinal: false,
                session: session
            )
            try ensureRunCanContinue(generation: generation)
            if keepAudio {
                availableStorageBytes =
                    try await sessionStore.ensureRecordingCapacity(
                        minimumBytes:
                            Self.minimumRecordingStorageBytes
                    )
                try ensureRunCanContinue(generation: generation)
            }
            capability = try await assetManager.prepare(
                locale: Locale(identifier: selectedLocaleIdentifier)
            )
            localeReservationObservedDuringRecording =
                capability.localeReserved
            try ensureRunCanContinue(generation: generation)
            if keepAudio {
                availableStorageBytes =
                    try await sessionStore.ensureRecordingCapacity(
                        minimumBytes:
                            Self.minimumRecordingStorageBytes
                    )
                recordingStartAvailableStorageBytes =
                    availableStorageBytes
                try ensureRunCanContinue(generation: generation)
            }
            try Self.requirePhysicalRecordingEnvironment()
            try Self.activateRecordingAudioSession()

            let audioDirectory = try await sessionStore.audioDirectory(
                sessionID: session.id
            )
            try ensureRunCanContinue(generation: generation)
            let recorder = keepAudio
                ? try RollingAudioRecorder(
                    sessionID: session.id,
                    directoryURL: audioDirectory
                )
                : nil
            self.recorder = recorder
            let captureMonitor = MonitoredAudioBufferSink(
                downstream: recorder
            )
            self.captureMonitor = captureMonitor

            let updates = try await speechService.start(
                locale: Locale(identifier: selectedLocaleIdentifier),
                audioBufferSink: captureMonitor
            )
            try ensureRunCanContinue(generation: generation)
            let startedAt = Date()
            try session.transition(to: .recording, at: startedAt)
            activeSession = session
            recordingStartedAt = startedAt
            recordingStartResidentMemoryBytes =
                Self.currentResidentMemoryBytes()
            peakResidentMemoryBytes =
                recordingStartResidentMemoryBytes
            phase = .recording
            statusMessage = keepAudio
                ? "正在设备端实时转写并分段保存音频；"
                    + "请保持 Codex Watch Pet 在前台，离开会自动停止并保存。"
                : "正在设备端实时转写且不保存原始音频；"
                    + "请保持 Codex Watch Pet 在前台，离开会自动停止并保存。"
            startAudioSessionEventMonitoring(generation: generation)

            try await persistCheckpoint(
                text: "",
                isFinal: false,
                session: session
            )
            guard
                recordingRunCoordinator
                    .acceptsUpdate(for: generation),
                isAppInForeground
            else {
                return
            }
            UIApplication.shared.isIdleTimerDisabled = true
            startDurationTask(generation: generation)
            startTranscriptionTask(updates, generation: generation)
        } catch {
            let failedSessionID = session.id
            await failActiveSession(
                error,
                generation: generation
            )
            guard
                recordingRunCoordinator.ownsTerminal(
                    .failure,
                    for: generation
                ),
                capability.localeReserved
            else {
                return
            }

            // A background transition can win failure cleanup while
            // AssetInventory.prepare is still suspended. If prepare later
            // returns with a reservation, the normal terminal path could not
            // have released it, so this start operation owns the late cleanup.
            await assetManager.releaseReservation()
            guard
                recordingRunCoordinator.ownsTerminal(
                    .failure,
                    for: generation
                )
            else {
                return
            }
            let inspectedCapability = await assetManager.inspect(
                locale: Locale(
                    identifier: selectedLocaleIdentifier
                )
            )
            guard
                recordingRunCoordinator.ownsTerminal(
                    .failure,
                    for: generation
                )
            else {
                return
            }
            capability = inspectedCapability
            localeReservationReleasedAfterRecording =
                !inspectedCapability.localeReserved
            await persistDiagnosticReport(
                sessionID: failedSessionID
            )
        }
    }

    private func stopRecording(reason: StopReason = .user) async {
        guard phase == .recording, var session = activeSession else {
            return
        }
        guard
            let generation =
                recordingRunCoordinator.activeGeneration,
            recordingRunCoordinator.claimTerminal(
                .stop,
                for: generation
            ).isAccepted
        else {
            return
        }
        finalizationStartedAt = Date()
        phase = .stopping
        statusMessage = "正在完成最后一段转写并提交音频文件…"
        startFinalizationWatchdog(
            generation: generation,
            terminalPath: .stop
        )
        durationTask?.cancel()
        durationTask = nil

        do {
            let transcript = try await speechService.stop()
            guard
                recordingRunCoordinator.ownsTerminal(
                    .stop,
                    for: generation
                )
            else {
                return
            }
            finalTranscript = transcript
            await transcriptionTask?.value
            transcriptionTask = nil

            let captureSnapshot = captureMonitor?.snapshot()
            if
                let recordingStartedAt,
                Date().timeIntervalSince(recordingStartedAt) >= 1,
                (captureSnapshot?.acceptedFrameCount ?? 0) == 0
            {
                throw MobileRecordingIntegrityError.noCapturedAudio
            }
            let segments = try await recorder?.finish(
                commitCurrentSegment: true
            ) ?? []
            pendingAudioSegments = segments
            recorder = nil
            updateAudioMetrics(
                from: segments,
                captureSnapshot: captureSnapshot
            )
            captureMonitor = nil
            audioRouteValidationTask?.cancel()
            audioRouteValidationTask = nil
            stopAudioSessionEventMonitoring()
            do {
                try Self.deactivateRecordingAudioSession()
            } catch {
                diagnostics.append(
                    "音频会话停用失败：\(error.localizedDescription)"
                )
            }

            try session.transition(to: .stopping, at: Date())
            try session.transition(to: .completed, at: Date())

            let record = try Self.makeRecord(
                session: session,
                text: transcript,
                isFinal: true
            )
            try await sessionStore.save(
                MobileAudioManifest(
                    sessionID: session.id,
                    segments: segments
                )
            )
            try await sessionStore.save(record)

            activeSession = session
            pendingAudioSegments = []
            liveTranscript = ""
            audioLevel = 0

            do {
                history = try await sessionStore.loadAll()
                await refreshSessionLoadIssueDiagnostics()
            } catch {
                diagnostics.append(
                    "刷新历史记录失败：\(error.localizedDescription)"
                )
            }
            await assetManager.releaseReservation()
            capability = await assetManager.inspect(
                locale: Locale(identifier: selectedLocaleIdentifier)
            )
            localeReservationReleasedAfterRecording =
                !capability.localeReserved
            await captureRecordingEndMetrics()

            phase = .completed
            switch reason {
            case .user:
                statusMessage = segments.isEmpty
                    ? "文字已保存。"
                    : "文字与 \(segments.count) 个音频分段已安全保存。"
            case .movedToBackground:
                statusMessage = segments.isEmpty
                    ? "App 进入后台，录音已停止，文字已保存。"
                    : "App 进入后台，录音已停止，文字与音频已安全保存。"
            }
            stopFinalizationWatchdog()
            endBackgroundCleanupProtection()
            UIApplication.shared.isIdleTimerDisabled = false
            await persistDiagnosticReport(sessionID: session.id)
        } catch {
            await finishFailedSession(
                error,
                generation: generation,
                terminalPath: .stop
            )
        }
    }

    private func startTranscriptionTask(
        _ updates: AsyncThrowingStream<SpeechTranscriptionUpdate, Error>,
        generation: UInt64
    ) {
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            do {
                for try await update in updates {
                    guard !Task.isCancelled else { return }
                    guard
                        self?.recordingRunCoordinator
                            .acceptsUpdate(for: generation) == true
                    else {
                        return
                    }
                    await self?.acceptSpeechUpdate(
                        update,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.handleTranscriptionStreamFailure(
                    error,
                    generation: generation
                )
            }
        }
    }

    private func handleTranscriptionStreamFailure(
        _ error: Error,
        generation: UInt64
    ) async {
        guard
            recordingRunCoordinator.activeGeneration == generation
        else {
            return
        }
        if recordingRunCoordinator.ownsTerminal(
            .stop,
            for: generation
        ) {
            diagnostics.append(
                "停止期间语音流结束：\(error.localizedDescription)"
            )
            return
        }
        await failActiveSession(
            error,
            generation: generation
        )
    }

    private func startDurationTask(generation: UInt64) {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            var nextStorageCheck = Date()
                .addingTimeInterval(30)
            var nextResourceSample = Date()
            while !Task.isCancelled {
                guard let self, let recordingStartedAt else { return }
                guard
                    recordingRunCoordinator.acceptsUpdate(
                        for: generation
                    ),
                    phase == .recording
                else {
                    return
                }
                let now = Date()
                elapsedSeconds = now.timeIntervalSince(recordingStartedAt)
                let currentThermalState =
                    Self.currentThermalStateTitle()
                if
                    Self.thermalStateRank(currentThermalState) >
                    Self.thermalStateRank(peakThermalState)
                {
                    peakThermalState = currentThermalState
                }
                if now >= nextResourceSample {
                    if let residentMemory =
                        Self.currentResidentMemoryBytes()
                    {
                        peakResidentMemoryBytes = max(
                            peakResidentMemoryBytes ?? 0,
                            residentMemory
                        )
                    }
                    nextResourceSample =
                        now.addingTimeInterval(5)
                }

                if keepAudio, now >= nextStorageCheck {
                    do {
                        availableStorageBytes =
                            try await sessionStore
                                .ensureRecordingCapacity(
                                    minimumBytes:
                                        Self.minimumOngoingStorageBytes
                                )
                        guard
                            recordingRunCoordinator.acceptsUpdate(
                                for: generation
                            ),
                            phase == .recording
                        else {
                            return
                        }
                    } catch {
                        await failActiveSession(
                            error,
                            generation: generation
                        )
                        return
                    }
                    nextStorageCheck = now.addingTimeInterval(30)
                }

                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    private func acceptSpeechUpdate(
        _ update: SpeechTranscriptionUpdate,
        generation: UInt64
    ) async {
        guard
            recordingRunCoordinator.acceptsUpdate(for: generation),
            phase == .recording
        else {
            return
        }
        switch speechUpdateTelemetry.classify(update) {
        case .partial:
            partialUpdateCount += 1
            if
                firstPartialLatencyMilliseconds == nil,
                !update.volatileText.isEmpty,
                let recordingStartedAt
            {
                firstPartialLatencyMilliseconds = max(
                    0,
                    Int(
                        Date()
                            .timeIntervalSince(recordingStartedAt) *
                            1_000
                    )
                )
            }
        case .final:
            finalUpdateCount += 1
        case .unchanged:
            break
        }
        liveTranscript = update.text
        audioLevel = update.audioLevel

        guard
            let session = activeSession,
            update.text != lastCheckpointText
        else {
            return
        }
        let now = Date()
        guard
            update.isFinal ||
            now.timeIntervalSince(lastCheckpointAt) >= 2
        else {
            return
        }

        do {
            try await persistCheckpoint(
                text: update.text,
                isFinal: update.isFinal,
                session: session
            )
            lastCheckpointText = update.text
            lastCheckpointAt = now
        } catch {
            await failActiveSession(
                error,
                generation: generation
            )
        }
    }

    private func persistCheckpoint(
        text: String,
        isFinal: Bool,
        session: RecordingSession
    ) async throws {
        let record = try Self.makeRecord(
            session: session,
            text: text,
            isFinal: isFinal
        )
        try await sessionStore.save(record)
    }

    private static func makeRecord(
        session: RecordingSession,
        text: String,
        isFinal: Bool
    ) throws -> TranscriptSessionRecord {
        var assembler = TranscriptAssembler(sessionID: session.id)
        if !text.isEmpty {
            _ = try assembler.accept(text, isFinal: isFinal)
        }
        return try assembler.record(for: session)
    }

    private func failActiveSession(
        _ error: Error,
        generation: UInt64
    ) async {
        let claim = recordingRunCoordinator.claimTerminal(
            .failure,
            for: generation
        )
        guard claim.isAccepted else {
            if case .alreadyClaimed(.stop) = claim {
                diagnostics.append(
                    "停止期间收到并发错误：\(error.localizedDescription)"
                )
            }
            return
        }
        await finishFailedSession(
            error,
            generation: generation,
            terminalPath: .failure
        )
    }

    private func finishFailedSession(
        _ error: Error,
        generation: UInt64,
        terminalPath: RecordingTerminalPath
    ) async {
        guard
            recordingRunCoordinator.ownsTerminal(
                terminalPath,
                for: generation
            )
        else {
            return
        }
        if finalizationStartedAt == nil {
            finalizationStartedAt = Date()
        }
        if phase != .finalizationDelayed {
            phase = .stopping
        }
        if finalizationWatchdogTask == nil {
            startFinalizationWatchdog(
                generation: generation,
                terminalPath: terminalPath
            )
        }
        durationTask?.cancel()
        durationTask = nil
        audioRouteValidationTask?.cancel()
        audioRouteValidationTask = nil
        stopAudioSessionEventMonitoring()
        await speechService.cancel()
        transcriptionTask?.cancel()
        transcriptionTask = nil

        var segments = pendingAudioSegments
        if let recorder {
            do {
                let unfinishedSegments = try await recorder.finish(
                    commitCurrentSegment: false
                )
                segments = Self.mergingAudioSegments(
                    segments,
                    unfinishedSegments
                )
            } catch {
                diagnostics.append(
                    "保留未完成音频失败：\(error.localizedDescription)"
                )
            }
        }
        recorder = nil
        pendingAudioSegments = segments
        updateAudioMetrics(
            from: segments,
            captureSnapshot: captureMonitor?.snapshot()
        )
        captureMonitor = nil
        do {
            try Self.deactivateRecordingAudioSession()
        } catch {
            diagnostics.append(
                "音频会话停用失败：\(error.localizedDescription)"
            )
        }
        await assetManager.releaseReservation()
        capability = await assetManager.inspect(
            locale: Locale(identifier: selectedLocaleIdentifier)
        )
        localeReservationReleasedAfterRecording =
            !capability.localeReserved

        if var session = activeSession, !session.state.isTerminal {
            do {
                try session.transition(
                    to: .failed,
                    at: max(Date(), session.updatedAt),
                    failure: RecordingSessionFailure(
                        code: "recording_failed",
                        message: error.localizedDescription
                    )
                )
                activeSession = session
                let preservedText =
                    MobileRecordingTextRecovery.preservedText(
                        finalTranscript: finalTranscript,
                        liveTranscript: liveTranscript
                    )
                let record = try Self.makeRecord(
                    session: session,
                    text: preservedText,
                    isFinal: true
                )

                var manifestWasSaved = false
                if !segments.isEmpty {
                    do {
                        try await sessionStore.save(
                            MobileAudioManifest(
                                sessionID: session.id,
                                segments: segments
                            )
                        )
                        manifestWasSaved = true
                    } catch {
                        diagnostics.append(
                            "保存音频清单失败："
                                + error.localizedDescription
                        )
                    }
                }

                do {
                    try await sessionStore.save(record)
                } catch {
                    diagnostics.append(
                        "保存失败会话文字时出错：\(error.localizedDescription)"
                    )
                }

                if manifestWasSaved {
                    pendingAudioSegments = []
                }

                do {
                    history = try await sessionStore.loadAll()
                    await refreshSessionLoadIssueDiagnostics()
                } catch {
                    diagnostics.append(
                        "刷新失败会话历史时出错：\(error.localizedDescription)"
                    )
                }
            } catch {
                diagnostics.append(
                    "构造失败会话时出错：\(error.localizedDescription)"
                )
            }
        }

        audioLevel = 0
        await captureRecordingEndMetrics()
        phase = .failed
        statusMessage = "录音已停止：\(error.localizedDescription)"
        diagnostics.append("录音失败：\(error.localizedDescription)")
        stopFinalizationWatchdog()
        endBackgroundCleanupProtection()
        UIApplication.shared.isIdleTimerDisabled = false
        if let sessionID = activeSession?.id {
            await persistDiagnosticReport(sessionID: sessionID)
        }
    }

    private func startAudioSessionEventMonitoring(generation: UInt64) {
        stopAudioSessionEventMonitoring()
        let center = NotificationCenter.default

        audioSessionObserverTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard
                    let rawValue = notification.userInfo?[
                        AVAudioSessionInterruptionTypeKey
                    ] as? UInt,
                    AVAudioSession.InterruptionType(rawValue: rawValue)
                        == .began
                else {
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.handleAudioSessionEvent(
                        .interrupted,
                        generation: generation
                    )
                }
            }
        )

        audioSessionObserverTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleAudioSessionEvent(
                        .mediaServicesReset,
                        generation: generation
                    )
                }
            }
        )

        audioSessionObserverTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard
                    let rawValue = notification.userInfo?[
                        AVAudioSessionRouteChangeReasonKey
                    ] as? UInt
                else {
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.handleAudioRouteChange(
                        rawReason: rawValue,
                        generation: generation
                    )
                }
            }
        )
    }

    private func stopAudioSessionEventMonitoring() {
        let center = NotificationCenter.default
        for token in audioSessionObserverTokens {
            center.removeObserver(token)
        }
        audioSessionObserverTokens.removeAll()
    }

    private func handleAudioSessionEvent(
        _ error: MobileAudioSessionEventError,
        generation: UInt64
    ) async {
        guard
            recordingRunCoordinator
                .acceptsUpdate(for: generation),
            phase == .recording
        else {
            return
        }
        await failActiveSession(
            error,
            generation: generation
        )
    }

    private func handleAudioRouteChange(
        rawReason: UInt,
        generation: UInt64
    ) async {
        guard
            recordingRunCoordinator
                .acceptsUpdate(for: generation),
            phase == .recording,
            let reason =
                AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            await failActiveSession(
                MobileAudioSessionEventError.routeUnavailable(
                    "耳机或原麦克风已断开。"
                ),
                generation: generation
            )
        case .noSuitableRouteForCategory:
            await failActiveSession(
                MobileAudioSessionEventError.routeUnavailable(
                    "系统找不到适用于录音的输入设备。"
                ),
                generation: generation
            )
        case .newDeviceAvailable:
            diagnostics.append(
                "检测到新的音频输入设备，正在验证麦克风采集。"
            )
            scheduleAudioRouteValidation(generation: generation)
        case .routeConfigurationChange:
            diagnostics.append(
                "音频路由配置发生变化，正在验证麦克风采集。"
            )
            scheduleAudioRouteValidation(generation: generation)
        case .unknown,
             .categoryChange,
             .override,
             .wakeFromSleep:
            break
        @unknown default:
            diagnostics.append(
                "检测到未知音频路由变化：\(rawReason)。"
            )
        }
    }

    private func scheduleAudioRouteValidation(
        generation: UInt64
    ) {
        let baselineFrameCount =
            captureMonitor?.snapshot().acceptedFrameCount ?? 0
        audioRouteValidationTask?.cancel()
        audioRouteValidationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard
                let self,
                recordingRunCoordinator.acceptsUpdate(
                    for: generation
                ),
                phase == .recording
            else {
                return
            }

            let hasInput =
                !AVAudioSession.sharedInstance()
                    .currentRoute.inputs.isEmpty
            let currentFrameCount =
                captureMonitor?.snapshot().acceptedFrameCount ?? 0
            guard
                hasInput,
                currentFrameCount > baselineFrameCount
            else {
                await failActiveSession(
                    MobileAudioSessionEventError.routeUnavailable(
                        hasInput
                            ? "路由变化后 1 秒内没有收到新的音频帧。"
                            : "路由变化后没有可用的麦克风输入。"
                    ),
                    generation: generation
                )
                return
            }
            diagnostics.append(
                "音频路由变化后采集心跳正常。"
            )
        }
    }

    private func startFinalizationWatchdog(
        generation: UInt64,
        terminalPath: RecordingTerminalPath
    ) {
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard
                let self,
                recordingRunCoordinator.ownsTerminal(
                    terminalPath,
                    for: generation
                ),
                phase == .stopping
            else {
                return
            }

            guard
                !Task.isCancelled,
                recordingRunCoordinator.ownsTerminal(
                    terminalPath,
                    for: generation
                ),
                phase == .stopping
            else {
                return
            }
            phase = .finalizationDelayed
            statusMessage = terminalPath == .stop
                ? "收尾已超过 3 秒；最后检查点和临时音频会用于恢复，"
                    + "Codex Watch Pet 仍在尝试完成，请勿强制退出。"
                : "故障收尾已超过 3 秒；已落盘内容可在下次启动时恢复，"
                    + "Codex Watch Pet 仍在安全清理，请勿强制退出。"
            diagnostics.append(
                terminalPath == .stop
                    ? "收尾超过 3 秒，已进入可恢复状态。"
                    : "故障收尾超过 3 秒，已进入可恢复状态。"
            )
        }
    }

    private func stopFinalizationWatchdog() {
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
    }

    private func beginBackgroundCleanupProtection() {
        guard backgroundTaskIdentifier == .invalid else { return }
        backgroundTaskIdentifier =
            UIApplication.shared.beginBackgroundTask(
                withName: "CodexWatchPet voice input finalization"
            ) { [weak self] in
                self?.expireBackgroundCleanupProtection()
            }
    }

    private func expireBackgroundCleanupProtection() {
        diagnostics.append(
            "后台收尾时间即将耗尽；下次启动将恢复已落盘内容。"
        )
        endBackgroundCleanupProtection()
    }

    private func endBackgroundCleanupProtection() {
        guard backgroundTaskIdentifier != .invalid else { return }
        let identifier = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func updateAudioMetrics(
        from segments: [MobileAudioSegment],
        captureSnapshot: MonitoredAudioCaptureSnapshot?
    ) {
        if let captureSnapshot {
            recordedAudioFrameCount =
                captureSnapshot.acceptedFrameCount
            recordedAudioDurationSeconds =
                captureSnapshot.acceptedDuration
            return
        }
        guard !segments.isEmpty else {
            recordedAudioFrameCount = keepAudio ? 0 : nil
            recordedAudioDurationSeconds = keepAudio ? 0 : nil
            return
        }
        recordedAudioFrameCount = segments.reduce(0) {
            $0 + $1.frameCount
        }
        recordedAudioDurationSeconds = segments.reduce(0) {
            $0 + $1.duration
        }
    }

    private func captureRecordingEndMetrics() async {
        recordingEndResidentMemoryBytes =
            Self.currentResidentMemoryBytes()
        if let recordingEndResidentMemoryBytes {
            peakResidentMemoryBytes = max(
                peakResidentMemoryBytes ?? 0,
                recordingEndResidentMemoryBytes
            )
        }
        if let finalizationStartedAt {
            finalizationDurationMilliseconds = max(
                0,
                Int(
                    Date()
                        .timeIntervalSince(finalizationStartedAt) *
                        1_000
                )
            )
        }
        do {
            let available =
                try await sessionStore
                    .availableCapacityForImportantUsage()
            availableStorageBytes = available
            recordingEndAvailableStorageBytes = available
        } catch {
            diagnostics.append(
                "录音结束时读取可用空间失败：\(error.localizedDescription)"
            )
        }
    }

    private func persistDiagnosticReport(sessionID: UUID) async {
        do {
            try await sessionStore.saveDiagnosticReport(
                diagnosticReportText,
                sessionID: sessionID
            )
        } catch {
            diagnostics.append(
                "保存诊断报告失败：\(error.localizedDescription)"
            )
        }
    }

    private static func currentThermalStateTitle() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
    }

    private static func thermalStateRank(_ state: String) -> Int {
        switch state {
        case "nominal":
            0
        case "fair":
            1
        case "serious":
            2
        case "critical":
            3
        default:
            -1
        }
    }

    private static func currentResidentMemoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size /
                MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    private static func mergingAudioSegments(
        _ first: [MobileAudioSegment],
        _ second: [MobileAudioSegment]
    ) -> [MobileAudioSegment] {
        var bySequence = Dictionary(
            uniqueKeysWithValues: first.map {
                ($0.sequenceNumber, $0)
            }
        )
        for segment in second {
            bySequence[segment.sequenceNumber] = segment
        }
        return bySequence.values.sorted {
            $0.sequenceNumber < $1.sequenceNumber
        }
    }

    private func appendCapabilityDiagnostics(
        _ snapshot: MobileSpeechCapabilitySnapshot
    ) {
        diagnostics.removeAll {
            $0.hasPrefix("请求语言：") ||
                $0.hasPrefix("SpeechTranscriber：") ||
                $0.hasPrefix("解析语言：") ||
                $0.hasPrefix("语音后端：") ||
                $0.hasPrefix("模型状态：") ||
                $0.hasPrefix("模型保留：")
        }
        diagnostics.append(
            "请求语言：\(snapshot.requestedLocaleIdentifier)"
        )
        diagnostics.append(
            "SpeechTranscriber：\(snapshot.speechTranscriberAvailable ? "可用" : "不可用")"
        )
        diagnostics.append(
            "解析语言：\(snapshot.resolvedLocaleIdentifier ?? "不支持")"
        )
        diagnostics.append(
            "语音后端：\(snapshot.backend?.title ?? "未选择")"
        )
        diagnostics.append("模型状态：\(snapshot.assetState.title)")
        diagnostics.append(
            "模型保留：\(snapshot.localeReserved ? "是" : "否")"
        )
        if let errorMessage = snapshot.errorMessage {
            diagnostics.append("能力错误：\(errorMessage)")
        }
    }

    private func refreshSessionLoadIssueDiagnostics() async {
        diagnostics.removeAll {
            $0.hasPrefix("会话文件隔离：")
        }
        let issues = await sessionStore.loadIssues()
        guard !issues.isEmpty else { return }
        let examples = issues.prefix(3).map(\.directoryName)
            .joined(separator: "、")
        diagnostics.append(
            "会话文件隔离：\(issues.count) 个损坏或不可读会话"
                + "未影响其他记录（\(examples)）。"
        )
    }

    private func ensureRunCanContinue(
        generation: UInt64
    ) throws {
        guard
            isAppInForeground,
            recordingRunCoordinator
                .acceptsUpdate(for: generation)
        else {
            throw MobileRecordingEnvironmentError
                .movedToBackgroundDuringPreparation
        }
    }

    private static func activateRecordingAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .record,
            mode: .measurement,
            options: []
        )
        try session.setActive(true)
    }

    private static func requirePhysicalRecordingEnvironment() throws {
#if targetEnvironment(simulator)
        throw MobileRecordingEnvironmentError
            .simulatorMicrophoneUnsupported
#endif
    }

    private static func deactivateRecordingAudioSession() throws {
        try AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
#endif
