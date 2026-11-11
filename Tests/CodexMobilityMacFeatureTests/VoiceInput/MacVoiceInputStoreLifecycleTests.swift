@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mac voice input store lifecycle")
@MainActor
struct MacVoiceInputStoreLifecycleTests {
    @Test
    func disabledStoreRejectsPermissionRefreshRequestsAndFnToggles() async {
        let harness = makeHarness()

        harness.store.shutdown()
        await harness.store.refreshPermissions()
        await harness.store.requestPermissions()
        await harness.store.toggleDictation()
        await Task.yield()

        #expect(harness.monitor.startCount == 0)
        #expect(harness.permissions.requestCount == 0)
        #expect(await harness.speech.startCount == 0)
        #expect(harness.store.phase == .idle)
    }

    @Test
    func shutdownWhileSpeechStartIsSuspendedCannotRestoreRecording() async {
        let speech = ControllableVoiceSpeechService(suspendStart: true)
        let harness = makeHarness(speech: speech)

        await harness.store.start()
        let beginTask = Task {
            await harness.store.toggleDictation()
        }
        await speech.waitUntilStartWasEntered()

        harness.store.shutdown()
        await speech.resumeStart()
        await beginTask.value
        await speech.waitUntilCancelCount(atLeast: 1)

        #expect(harness.store.phase == .idle)
        #expect(harness.store.statusMessage == "语音输入模块已关闭。")
        #expect(harness.overlay.recordingCount == 0)
        #expect(await speech.cancelCount >= 1)
    }

    @Test
    func shutdownWhileCodexPolishIsSuspendedBlocksEveryDeliverySideEffect() async {
        let speech = ControllableVoiceSpeechService(stoppedText: "原始转写")
        let polishGate = SuspendedPolishGate()
        let harness = makeHarness(
            speech: speech,
            codexPolisher: TestVoiceCodexPolisher(gate: polishGate)
        )
        harness.store.codexEnabled = true

        await harness.store.start()
        await harness.store.toggleDictation()
        #expect(harness.store.phase == .recording)

        let finishTask = Task {
            await harness.store.toggleDictation()
        }
        await polishGate.waitUntilPolishWasEntered()

        harness.store.shutdown()
        await polishGate.resume(text: "整理后的旧结果")
        await finishTask.value

        #expect(harness.store.phase == .idle)
        #expect(harness.store.finalTranscript.isEmpty)
        #expect(harness.insertion.insertCount == 0)
        #expect(harness.pasteboard.writeCount == 0)
        #expect(harness.overlay.resultCount == 0)
    }

    @Test
    func oldGenerationCannotOverwriteARestartedStore() async {
        let speech = ControllableVoiceSpeechService(stoppedText: "旧会话")
        let polishGate = SuspendedPolishGate()
        let harness = makeHarness(
            speech: speech,
            codexPolisher: TestVoiceCodexPolisher(gate: polishGate)
        )
        harness.store.codexEnabled = true

        await harness.store.start()
        await harness.store.toggleDictation()
        let oldFinishTask = Task {
            await harness.store.toggleDictation()
        }
        await polishGate.waitUntilPolishWasEntered()

        harness.store.shutdown()
        await harness.store.start()
        let restartedStatus = harness.store.statusMessage
        #expect(harness.store.phase == .idle)

        await polishGate.resume(text: "不应交付的旧结果")
        await oldFinishTask.value

        #expect(harness.store.phase == .idle)
        #expect(harness.store.statusMessage == restartedStatus)
        #expect(harness.store.finalTranscript.isEmpty)
        #expect(harness.insertion.insertCount == 0)
        #expect(harness.pasteboard.writeCount == 0)
        #expect(harness.overlay.resultCount == 0)
    }

    @Test
    func localCleanupAndDictionaryRunWithoutCodexAndNeverAutoCopy() async {
        let harness = makeHarness(speech: ControllableVoiceSpeechService(stoppedText: "嗯，tidus 就是说，开始"))
        harness.store.saveLexiconEntry(LexiconEntry(term: "Tidux", aliases: ["tidus"], protect: true))
        await harness.store.start()
        await harness.store.toggleDictation()
        await harness.store.toggleDictation()
        #expect(harness.store.finalTranscript == "Tidux 开始")
        #expect(harness.store.deliveryState == .retainedOnly)
        #expect(harness.pasteboard.writeCount == 0)
        harness.store.copyFinalTranscript()
        #expect(harness.store.deliveryState == .copiedByUser)
        #expect(harness.pasteboard.writeCount == 1)
        harness.store.shutdown()
    }

    @Test
    func numericalCorrectionIsRetainedForReview() async {
        let text = "预算100元，不对，改成200元"
        let harness = makeHarness(speech: ControllableVoiceSpeechService(stoppedText: text))
        harness.store.codexEnabled = true
        await harness.store.start()
        await harness.store.toggleDictation()
        await harness.store.toggleDictation()
        #expect(harness.store.correctionNeedsReview)
        #expect(harness.store.finalTranscript == text)
        #expect(harness.store.deliveryState == .retainedOnly)
        #expect(harness.insertion.insertCount == 0)
        #expect(harness.pasteboard.writeCount == 0)
        harness.store.shutdown()
    }

    private func makeHarness(
        speech: ControllableVoiceSpeechService = ControllableVoiceSpeechService(),
        codexPolisher: any VoiceCodexPolishing = CodexPolisher(executableURL: nil)
    ) -> VoiceStoreHarness {
        VoiceStoreHarness(
            speech: speech,
            codexPolisher: codexPolisher
        )
    }
}

@MainActor
private struct VoiceStoreHarness {
    let store: MacVoiceInputStore
    let permissions: StubVoicePermissionService
    let monitor: SpyFunctionKeyMonitor
    let speech: ControllableVoiceSpeechService
    let insertion: SpyVoiceTextInsertionService
    let overlay: SpyVoiceOverlayPresenter
    let pasteboard: SpyVoicePasteboardWriter

    init(
        speech: ControllableVoiceSpeechService,
        codexPolisher: any VoiceCodexPolishing
    ) {
        let preferences = UserDefaults(
            suiteName: "MacVoiceInputStoreLifecycleTests.\(UUID().uuidString)"
        )!
        let permissions = StubVoicePermissionService()
        let monitor = SpyFunctionKeyMonitor()
        let insertion = SpyVoiceTextInsertionService()
        let overlay = SpyVoiceOverlayPresenter()
        let pasteboard = SpyVoicePasteboardWriter()

        self.permissions = permissions
        self.monitor = monitor
        self.speech = speech
        self.insertion = insertion
        self.overlay = overlay
        self.pasteboard = pasteboard
        store = MacVoiceInputStore(
            preferences: preferences,
            legacyPreferences: nil,
            codexPolisher: codexPolisher,
            permissionService: permissions,
            speechService: speech,
            insertionService: insertion,
            overlayController: overlay,
            functionKeyMonitor: monitor,
            pasteboardWriter: pasteboard,
            configurationDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }
}

@MainActor
private final class StubVoicePermissionService: VoicePermissionServicing {
    private(set) var requestCount = 0
    var current = PermissionSnapshot(
        microphoneGranted: true,
        accessibilityGranted: true
    )

    func snapshot() -> PermissionSnapshot {
        current
    }

    func requestAll() async -> PermissionSnapshot {
        requestCount += 1
        return current
    }
}

@MainActor
private final class SpyFunctionKeyMonitor: VoiceFunctionKeyMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    func start() throws {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

private actor ControllableVoiceSpeechService: VoiceSpeechTranscribing {
    private let suspendStart: Bool
    private let stoppedText: String
    private var startContinuation:
        CheckedContinuation<
            AsyncThrowingStream<SpeechTranscriptionUpdate, Error>,
            Error
        >?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [
        (minimumCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    init(
        suspendStart: Bool = false,
        stoppedText: String = "测试转写"
    ) {
        self.suspendStart = suspendStart
        self.stoppedText = stoppedText
    }

    func start(
        locale _: Locale
    ) async throws -> AsyncThrowingStream<SpeechTranscriptionUpdate, Error> {
        startCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard suspendStart else {
            return Self.finishedUpdates()
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
    }

    func stop() async throws -> String {
        stopCount += 1
        return stoppedText
    }

    func cancel() async {
        cancelCount += 1
        let readyWaiters = cancelWaiters.filter {
            cancelCount >= $0.minimumCount
        }
        cancelWaiters.removeAll {
            cancelCount >= $0.minimumCount
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    func waitUntilStartWasEntered() async {
        guard startCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeStart() {
        startContinuation?.resume(returning: Self.finishedUpdates())
        startContinuation = nil
    }

    func waitUntilCancelCount(atLeast minimumCount: Int) async {
        guard cancelCount < minimumCount else { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append((minimumCount, continuation))
        }
    }

    private nonisolated static func finishedUpdates()
        -> AsyncThrowingStream<SpeechTranscriptionUpdate, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct TestVoiceCodexPolisher: VoiceCodexPolishing {
    let gate: SuspendedPolishGate
    let isAvailable = true

    func polish(
        rawText: String,
        locale _: String?,
        timeout _: TimeInterval
    ) async -> CodexPolisher.PolishResult {
        await gate.polish(rawText: rawText)
    }
}

private actor SuspendedPolishGate {
    private var continuation:
        CheckedContinuation<CodexPolisher.PolishResult, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var polishCount = 0

    func polish(rawText _: String) async -> CodexPolisher.PolishResult {
        polishCount += 1
        let readyWaiters = waiters
        waiters.removeAll()
        for waiter in readyWaiters {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilPolishWasEntered() async {
        guard polishCount == 0 else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resume(text: String) {
        continuation?.resume(
            returning: CodexPolisher.PolishResult(
                text: text,
                usedFallback: false,
                reason: nil
            )
        )
        continuation = nil
    }
}

@MainActor
private final class SpyVoiceTextInsertionService: VoiceTextInserting {
    private(set) var captureCount = 0
    private(set) var insertCount = 0

    func captureTarget() throws -> CapturedTextTarget {
        captureCount += 1
        throw TextInsertionService.InsertionError.noFocusedElement
    }

    func insert(
        _: String,
        into _: CapturedTextTarget
    ) async throws -> TextInsertionService.InsertionMethod {
        insertCount += 1
        return .accessibilitySelectedText
    }
}

@MainActor
private final class SpyVoiceOverlayPresenter: VoiceOverlayPresenting {
    private(set) var recordingCount = 0
    private(set) var processingCount = 0
    private(set) var resultCount = 0
    private(set) var errorCount = 0
    private(set) var hideCount = 0

    func showRecording(text _: String, level _: Double) {
        recordingCount += 1
    }

    func showProcessing(text _: String) {
        processingCount += 1
    }

    func showResult(text _: String) {
        resultCount += 1
    }

    func showError(text _: String) {
        errorCount += 1
    }

    func hide() {
        hideCount += 1
    }
}

@MainActor
private final class SpyVoicePasteboardWriter: VoicePasteboardWriting {
    private(set) var writeCount = 0

    func write(_: String) -> Bool {
        writeCount += 1
        return true
    }
}
