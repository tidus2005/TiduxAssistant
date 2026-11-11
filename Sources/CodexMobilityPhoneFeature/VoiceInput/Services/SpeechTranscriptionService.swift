#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFoundation
import Foundation
import Speech

struct SpeechTranscriptionUpdate: Equatable, Sendable {
    let finalizedText: String
    let volatileText: String
    let text: String
    let isFinal: Bool
    let audioLevel: Double
}

/// Receives read-only microphone buffer copies from the real-time capture path.
///
/// Implementations must return immediately and move any file or network work to
/// their own bounded queue. Returning `false` stops the active transcription
/// instead of silently losing audio.
protocol SpeechAudioBufferSink: Sendable {
    func offer(_ buffer: AVAudioPCMBuffer) -> Bool
    var rejectionErrorDescription: String? { get }
}

extension SpeechAudioBufferSink {
    var rejectionErrorDescription: String? { nil }
}

enum SpeechTranscriptionError: LocalizedError, Sendable {
    case sessionAlreadyActive
    case sessionNotActive
    case microphonePermissionDenied
    case localeNotSupported(String)
    case audioInputUnavailable
    case compatibleAudioFormatUnavailable
    case modelInstallationFailed(String)
    case analyzerFailed(String)
    case audioEngineFailed(String)
    case audioConversionFailed(String)
    case audioBufferOverflow
    case audioSinkFailed(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            return "语音转写已经在运行。"
        case .sessionNotActive:
            return "当前没有正在运行的语音转写。"
        case .microphonePermissionDenied:
            return "Codex Watch Pet 没有麦克风权限。"
        case let .localeNotSupported(identifier):
            return "当前语音模型不支持 \(identifier)。"
        case .audioInputUnavailable:
            return "没有可用的麦克风输入。"
        case .compatibleAudioFormatUnavailable:
            return "无法找到语音模型兼容的音频格式。"
        case let .modelInstallationFailed(message):
            return "本地语音模型准备失败：\(message)"
        case let .analyzerFailed(message):
            return "语音分析器启动失败：\(message)"
        case let .audioEngineFailed(message):
            return "麦克风启动失败：\(message)"
        case let .audioConversionFailed(message):
            return "音频格式转换失败：\(message)"
        case .audioBufferOverflow:
            return "语音处理速度跟不上麦克风输入，听写已自动停止，请重试。"
        case let .audioSinkFailed(message):
            return "原始音频保存失败，听写已安全停止：\(message)"
        case let .recognitionFailed(message):
            return "语音识别失败：\(message)"
        }
    }
}

/// Owns one live, on-device dictation session at a time.
///
/// The audio render callback is deliberately created by a `nonisolated` helper and
/// only copies a buffer into an `AsyncStream`. Conversion and SpeechAnalyzer work
/// happen off the real-time audio thread.
actor SpeechTranscriptionService {
    private enum SessionState {
        case idle
        case starting
        case running
        case stopping
        case failing
    }

    private enum SelectedTranscriber {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case let .speech(transcriber):
                return transcriber
            case let .dictation(transcriber):
                return transcriber
            }
        }
    }

    private var state: SessionState = .idle
    private var audioEngine: AVAudioEngine?
    private var tapInstalled = false
    private var analyzer: SpeechAnalyzer?
    private var transcriptionModule: (any SpeechModule)?

    private var capturedAudioContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var updateContinuation:
        AsyncThrowingStream<SpeechTranscriptionUpdate, Error>.Continuation?

    private var conversionTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var assembly = SpeechTextAssembly()
    private var audioLevel = 0.0
    private var pipelineFailure: SpeechTranscriptionError?

    var isTranscribing: Bool {
        state == .running
    }

    /// Starts microphone capture and returns live partial/final transcription updates.
    ///
    /// Model assets are installed by macOS on first use and remain managed by the
    /// system. Call `PermissionService.requestAll()` before this method.
    func start(
        locale requestedLocale: Locale = .current,
        audioBufferSink: (any SpeechAudioBufferSink)? = nil
    ) async throws -> AsyncThrowingStream<SpeechTranscriptionUpdate, Error> {
        guard state == .idle else {
            throw SpeechTranscriptionError.sessionAlreadyActive
        }

        state = .starting
        assembly = SpeechTextAssembly()
        audioLevel = 0
        pipelineFailure = nil

        do {
            guard AVAudioApplication.shared.recordPermission == .granted else {
                throw SpeechTranscriptionError.microphonePermissionDenied
            }
            let speechLocale: Locale?
            if SpeechTranscriber.isAvailable {
                speechLocale = await SpeechTranscriber.supportedLocale(
                    equivalentTo: requestedLocale
                )
            } else {
                speechLocale = nil
            }
            let dictationLocale: Locale?
            if speechLocale == nil {
                dictationLocale = await DictationTranscriber.supportedLocale(
                    equivalentTo: requestedLocale
                )
            } else {
                dictationLocale = nil
            }
            guard let backend = SpeechBackendSelector.select(
                requestedLocale: requestedLocale,
                speechLocale: speechLocale,
                dictationLocale: dictationLocale
            ) else {
                throw SpeechTranscriptionError.localeNotSupported(
                    requestedLocale.identifier
                )
            }

            let selectedTranscriber: SelectedTranscriber
            switch backend {
            case let .speech(locale):
                selectedTranscriber = .speech(
                    SpeechTranscriber(
                        locale: locale,
                        preset: .progressiveTranscription
                    )
                )
            case let .dictation(locale):
                selectedTranscriber = .dictation(
                    DictationTranscriber(
                        locale: locale,
                        preset: .progressiveLongDictation
                    )
                )
            }
            let module = selectedTranscriber.module
            let modules: [any SpeechModule] = [module]

            do {
                var assetStatus = await AssetInventory.status(
                    forModules: modules
                )
                guard assetStatus != .unsupported else {
                    throw SpeechTranscriptionError.modelInstallationFailed(
                        "当前设备不支持所需的本地语音模型。"
                    )
                }
                if assetStatus != .installed {
                    if let installationRequest = try await AssetInventory
                        .assetInstallationRequest(supporting: modules) {
                        try await installationRequest.downloadAndInstall()
                    }
                    assetStatus = await AssetInventory.status(
                        forModules: modules
                    )
                }
                guard assetStatus == .installed else {
                    throw SpeechTranscriptionError.modelInstallationFailed(
                        "本地语音模型没有完成安装。"
                    )
                }
            } catch {
                if let transcriptionError =
                    error as? SpeechTranscriptionError {
                    throw transcriptionError
                }
                throw SpeechTranscriptionError.modelInstallationFailed(
                    error.localizedDescription
                )
            }

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let naturalFormat = inputNode.outputFormat(forBus: 0)
            guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
                throw SpeechTranscriptionError.audioInputUnavailable
            }

            var compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: naturalFormat
            )
            if compatibleFormat == nil {
                compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: modules
                )
            }
            guard let analyzerFormat = compatibleFormat else {
                throw SpeechTranscriptionError.compatibleAudioFormatUnavailable
            }

            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            do {
                try await analyzer.prepareToAnalyze(in: analyzerFormat)
            } catch {
                throw SpeechTranscriptionError.analyzerFailed(
                    error.localizedDescription
                )
            }

            let (capturedAudio, capturedAudioContinuation) =
                AsyncStream<CapturedAudioBuffer>.makeStream(
                    bufferingPolicy: .bufferingNewest(32)
                )
            let (analyzerInput, analyzerInputContinuation) =
                AsyncStream<AnalyzerInput>.makeStream(
                    bufferingPolicy: .bufferingNewest(32)
                )
            let (updates, updateContinuation) =
                AsyncThrowingStream<SpeechTranscriptionUpdate, Error>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )

            self.audioEngine = engine
            self.analyzer = analyzer
            self.transcriptionModule = module
            self.capturedAudioContinuation = capturedAudioContinuation
            self.analyzerInputContinuation = analyzerInputContinuation
            self.updateContinuation = updateContinuation

            self.resultTask = makeResultTask(for: selectedTranscriber)
            conversionTask = makeConversionTask(
                capturedAudio: capturedAudio,
                analyzerFormat: analyzerFormat,
                analyzerInputContinuation: analyzerInputContinuation
            )

            do {
                try await analyzer.start(inputSequence: analyzerInput)
            } catch {
                throw SpeechTranscriptionError.analyzerFailed(
                    error.localizedDescription
                )
            }
            guard state == .starting else {
                throw pipelineFailure
                    ?? SpeechTranscriptionError.analyzerFailed(
                        "语音分析器在启动期间提前结束。"
                    )
            }

            inputNode.installTap(
                onBus: 0,
                bufferSize: 4_096,
                format: naturalFormat,
                block: Self.makeAudioTap(
                    continuation: capturedAudioContinuation,
                    audioBufferSink: audioBufferSink,
                    failureHandler: { [weak self] failure in
                        Task {
                            await self?.failActiveSession(
                                failure,
                                origin: .capture
                            )
                        }
                    }
                )
            )
            tapInstalled = true

            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw SpeechTranscriptionError.audioEngineFailed(
                    error.localizedDescription
                )
            }

            state = .running
            updateContinuation.yield(assembly.update(audioLevel: 0, isFinal: false))
            return updates
        } catch {
            await tearDownSession(cancelAnalyzer: true)
            if let transcriptionError = error as? SpeechTranscriptionError {
                throw transcriptionError
            }
            throw SpeechTranscriptionError.analyzerFailed(error.localizedDescription)
        }
    }

    /// Stops capture, waits for SpeechAnalyzer to finalize pending audio, and returns
    /// the best complete local transcript.
    func stop() async throws -> String {
        guard state == .running else {
            throw SpeechTranscriptionError.sessionNotActive
        }
        state = .stopping

        stopAudioCapture()
        capturedAudioContinuation?.finish()
        await conversionTask?.value
        analyzerInputContinuation?.finish()

        var finishingFailure: SpeechTranscriptionError?
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                finishingFailure = .recognitionFailed(error.localizedDescription)
            }
        }
        await resultTask?.value

        assembly.commitVolatile()
        let transcript = assembly.text
        updateContinuation?.yield(
            assembly.update(audioLevel: 0, isFinal: true)
        )
        updateContinuation?.finish()

        let failure = pipelineFailure ?? finishingFailure
        clearSessionReferences()

        if let failure {
            throw failure
        }
        return transcript
    }

    /// Immediately abandons the current session without finalizing pending audio.
    func cancel() async {
        guard state != .idle else { return }
        state = .stopping
        await tearDownSession(cancelAnalyzer: true)
    }

    private func makeResultTask(
        for selectedTranscriber: SelectedTranscriber
    ) -> Task<Void, Never> {
        switch selectedTranscriber {
        case let .speech(transcriber):
            return makeResultTask(for: transcriber)
        case let .dictation(transcriber):
            return makeResultTask(for: transcriber)
        }
    }

    private func makeResultTask(
        for transcriber: SpeechTranscriber
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await self?.acceptTranscription(
                        text,
                        isFinal: result.isFinal
                    )
                }
            } catch is CancellationError {
                // Explicit cancellation is part of normal teardown.
            } catch {
                await self?.failActiveSession(
                    .recognitionFailed(error.localizedDescription),
                    origin: .results
                )
            }
        }
    }

    private func makeResultTask(
        for transcriber: DictationTranscriber
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await self?.acceptTranscription(
                        text,
                        isFinal: result.isFinal
                    )
                }
            } catch is CancellationError {
                // Explicit cancellation is part of normal teardown.
            } catch {
                await self?.failActiveSession(
                    .recognitionFailed(error.localizedDescription),
                    origin: .results
                )
            }
        }
    }

    private func makeConversionTask(
        capturedAudio: AsyncStream<CapturedAudioBuffer>,
        analyzerFormat: AVAudioFormat,
        analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) { [weak self] in
            let converter = SpeechAudioBufferConverter()
            do {
                for await captured in capturedAudio {
                    guard !Task.isCancelled else { break }
                    let converted = try converter.convert(
                        captured.buffer,
                        to: analyzerFormat
                    )
                    if converted.frameLength > 0 {
                        let yieldResult = analyzerInputContinuation.yield(
                            AnalyzerInput(buffer: converted)
                        )
                        guard case .enqueued = yieldResult else {
                            if case .dropped = yieldResult {
                                throw SpeechTranscriptionError
                                    .audioBufferOverflow
                            }
                            break
                        }
                    }
                    await self?.acceptAudioLevel(captured.level)
                }

                if !Task.isCancelled {
                    for remainingBuffer in try converter.flush() {
                        let yieldResult = analyzerInputContinuation.yield(
                            AnalyzerInput(buffer: remainingBuffer)
                        )
                        guard case .enqueued = yieldResult else {
                            if case .dropped = yieldResult {
                                throw SpeechTranscriptionError
                                    .audioBufferOverflow
                            }
                            break
                        }
                    }
                }
            } catch is CancellationError {
                // Explicit cancellation is part of normal teardown.
            } catch {
                let failure = error as? SpeechTranscriptionError
                    ?? .audioConversionFailed(error.localizedDescription)
                await self?.failActiveSession(
                    failure,
                    origin: .conversion
                )
            }
            analyzerInputContinuation.finish()
        }
    }

    private func acceptTranscription(_ text: String, isFinal: Bool) {
        guard state == .running || state == .stopping else { return }
        let update = assembly.accept(
            text,
            isFinal: isFinal,
            audioLevel: audioLevel
        )
        updateContinuation?.yield(update)
    }

    private func acceptAudioLevel(_ newLevel: Double) {
        guard state == .running else { return }
        audioLevel = newLevel
        updateContinuation?.yield(
            assembly.update(audioLevel: newLevel, isFinal: false)
        )
    }

    private func failActiveSession(
        _ error: SpeechTranscriptionError,
        origin: SpeechPipelineFailureOrigin
    ) async {
        switch state {
        case .idle, .failing:
            return
        case .stopping:
            if pipelineFailure == nil {
                pipelineFailure = error
            }
            stopAudioCapture()
            capturedAudioContinuation?.finish()
            analyzerInputContinuation?.finish()
            updateContinuation?.finish(throwing: error)
            return
        case .starting, .running:
            state = .failing
            pipelineFailure = error
        }

        stopAudioCapture()
        capturedAudioContinuation?.finish()
        analyzerInputContinuation?.finish()
        updateContinuation?.finish(throwing: error)

        let conversionTask = conversionTask
        let resultTask = resultTask
        let plan = SpeechFailureTeardownPlan.plan(for: origin)
        if plan.cancelConversion {
            conversionTask?.cancel()
        }
        if plan.cancelResults {
            resultTask?.cancel()
        }

        await analyzer?.cancelAndFinishNow()

        if plan.awaitConversion {
            await conversionTask?.value
        }
        if plan.awaitResults {
            await resultTask?.value
        }
        clearSessionReferences()
    }

    private func stopAudioCapture() {
        audioEngine?.stop()
        if tapInstalled, let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func tearDownSession(cancelAnalyzer: Bool) async {
        stopAudioCapture()
        capturedAudioContinuation?.finish()
        analyzerInputContinuation?.finish()
        let conversionTask = conversionTask
        let resultTask = resultTask
        conversionTask?.cancel()
        resultTask?.cancel()
        if cancelAnalyzer {
            await analyzer?.cancelAndFinishNow()
        }
        await conversionTask?.value
        await resultTask?.value
        updateContinuation?.finish()
        clearSessionReferences()
    }

    private func clearSessionReferences() {
        audioEngine = nil
        analyzer = nil
        transcriptionModule = nil
        capturedAudioContinuation = nil
        analyzerInputContinuation = nil
        updateContinuation = nil
        conversionTask = nil
        resultTask = nil
        tapInstalled = false
        audioLevel = 0
        pipelineFailure = nil
        state = .idle
    }

    /// This factory is explicitly nonisolated so the AVAudioEngine real-time callback
    /// cannot inherit the service actor (or an application's MainActor).
    nonisolated private static func makeAudioTap(
        continuation: AsyncStream<CapturedAudioBuffer>.Continuation,
        audioBufferSink: (any SpeechAudioBufferSink)?,
        failureHandler:
            @escaping @Sendable (SpeechTranscriptionError) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let copy = copyAudioBuffer(buffer) else {
                failureHandler(.audioBufferOverflow)
                return
            }
            if let audioBufferSink, !audioBufferSink.offer(copy) {
                if let message =
                    audioBufferSink.rejectionErrorDescription
                {
                    failureHandler(.audioSinkFailed(message))
                } else {
                    failureHandler(.audioBufferOverflow)
                }
                return
            }
            let yieldResult = continuation.yield(
                CapturedAudioBuffer(
                    buffer: copy,
                    level: normalizedAudioLevel(of: buffer)
                )
            )
            if case .dropped = yieldResult {
                failureHandler(.audioBufferOverflow)
            }
        }
    }

    nonisolated private static func copyAudioBuffer(
        _ source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            return nil
        }
        copy.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            copy.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            return nil
        }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            guard
                let sourceData = sourceBuffer.mData,
                let destinationData = destinationBuffers[index].mData
            else {
                continue
            }
            let byteCount = Int(
                min(
                    sourceBuffer.mDataByteSize,
                    destinationBuffers[index].mDataByteSize
                )
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return copy
    }

    nonisolated private static func normalizedAudioLevel(
        of buffer: AVAudioPCMBuffer
    ) -> Double {
        guard
            buffer.frameLength > 0,
            let channels = buffer.floatChannelData
        else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let stride = max(1, frameCount / 512)
        var squareSum = 0.0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channels[channel]
            var frame = 0
            while frame < frameCount {
                let sample = Double(samples[frame])
                squareSum += sample * sample
                sampleCount += 1
                frame += stride
            }
        }

        guard sampleCount > 0, squareSum > 0 else { return 0 }
        let rootMeanSquare = sqrt(squareSum / Double(sampleCount))
        let decibels = 20 * log10(max(rootMeanSquare, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }
}

enum SpeechPipelineFailureOrigin: Sendable {
    case capture
    case conversion
    case results
}

struct SpeechFailureTeardownPlan: Equatable, Sendable {
    let cancelConversion: Bool
    let cancelResults: Bool
    let awaitConversion: Bool
    let awaitResults: Bool

    static func plan(
        for origin: SpeechPipelineFailureOrigin
    ) -> SpeechFailureTeardownPlan {
        switch origin {
        case .capture:
            return SpeechFailureTeardownPlan(
                cancelConversion: true,
                cancelResults: true,
                awaitConversion: true,
                awaitResults: true
            )
        case .conversion:
            return SpeechFailureTeardownPlan(
                cancelConversion: false,
                cancelResults: true,
                awaitConversion: false,
                awaitResults: true
            )
        case .results:
            return SpeechFailureTeardownPlan(
                cancelConversion: true,
                cancelResults: false,
                awaitConversion: true,
                awaitResults: false
            )
        }
    }
}

enum SpeechBackendSelection: Equatable, Sendable {
    case speech(Locale)
    case dictation(Locale)
}

enum SpeechBackendSelector {
    static func select(
        requestedLocale _: Locale,
        speechLocale: Locale?,
        dictationLocale: Locale?
    ) -> SpeechBackendSelection? {
        // The optional locales come from Apple's
        // `supportedLocale(equivalentTo:)`; a non-nil value is already the
        // framework's authoritative equivalence decision.
        if let speechLocale {
            return .speech(speechLocale)
        }
        if let dictationLocale {
            return .dictation(dictationLocale)
        }
        return nil
    }
}

struct SpeechTextAssembly: Equatable, Sendable {
    private(set) var finalizedText = ""
    private(set) var volatileText = ""

    var text: String {
        Self.join(finalizedText, volatileText)
    }

    mutating func accept(
        _ newText: String,
        isFinal: Bool,
        audioLevel: Double = 0
    ) -> SpeechTranscriptionUpdate {
        if isFinal {
            finalizedText = Self.join(finalizedText, newText)
            volatileText = ""
        } else {
            volatileText = newText
        }
        return update(audioLevel: audioLevel, isFinal: isFinal)
    }

    mutating func commitVolatile() {
        finalizedText = Self.join(finalizedText, volatileText)
        volatileText = ""
    }

    func update(
        audioLevel: Double,
        isFinal: Bool
    ) -> SpeechTranscriptionUpdate {
        SpeechTranscriptionUpdate(
            finalizedText: finalizedText,
            volatileText: volatileText,
            text: text,
            isFinal: isFinal,
            audioLevel: min(1, max(0, audioLevel))
        )
    }

    private static func join(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }
        guard
            let left = prefix.last,
            let right = suffix.first,
            !left.isWhitespace,
            !right.isWhitespace,
            needsBoundarySpace(left: left, right: right)
        else {
            return prefix + suffix
        }
        return prefix + " " + suffix
    }

    private static func needsBoundarySpace(
        left: Character,
        right: Character
    ) -> Bool {
        guard left.isASCII, right.isASCII else { return false }

        let punctuationThatClosesWithoutLeadingSpace = CharacterSet(
            charactersIn: ".,;:!?)]}%>'’"
        )
        let punctuationThatOpensWithoutTrailingSpace = CharacterSet(
            charactersIn: "([{<$#@'‘"
        )

        guard
            let leftScalar = left.unicodeScalars.first,
            let rightScalar = right.unicodeScalars.first,
            !punctuationThatOpensWithoutTrailingSpace.contains(leftScalar),
            !punctuationThatClosesWithoutLeadingSpace.contains(rightScalar)
        else {
            return false
        }
        return true
    }
}

private extension SpeechTranscriber.Preset {
    /// The macOS 26 SDK currently exposes this live progressive preset as
    /// `progressiveTranscription`. Keep the product-facing name explicit while
    /// compiling against both Xcode 26.2 and the macOS 26.5 command-line SDK.
    static var progressiveLiveTranscription: Self {
        .progressiveTranscription
    }
}

private struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let level: Double
}

private final class SpeechAudioBufferConverter {
    enum ConversionError: LocalizedError {
        case couldNotCreateConverter
        case couldNotCreateOutputBuffer
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateConverter:
                return "无法创建 AVAudioConverter。"
            case .couldNotCreateOutputBuffer:
                return "无法分配音频转换缓冲区。"
            case let .conversionFailed(message):
                return "AVAudioConverter 失败：\(message)"
            }
        }
    }

    private var converter: AVAudioConverter?

    func convert(
        _ buffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != outputFormat else { return buffer }

        if converter?.inputFormat != inputFormat ||
            converter?.outputFormat != outputFormat {
            converter = AVAudioConverter(
                from: inputFormat,
                to: outputFormat
            )
            converter?.primeMethod = .none
        }
        guard let converter else {
            throw ConversionError.couldNotCreateConverter
        }

        let ratio = converter.outputFormat.sampleRate /
            converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up)
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: max(capacity, 1)
        ) else {
            throw ConversionError.couldNotCreateOutputBuffer
        }

        var conversionError: NSError?
        let inputBox = ConverterInputBox(buffer: buffer)
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            inputBox.take(inputStatus: inputStatus)
        }

        guard status != .error else {
            throw ConversionError.conversionFailed(
                conversionError?.localizedDescription ?? "未知错误"
            )
        }
        return output
    }

    func flush() throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }

        var remainingBuffers: [AVAudioPCMBuffer] = []
        while true {
            let capacity = AVAudioFrameCount(
                max(1, converter.outputFormat.sampleRate / 10)
            )
            guard let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: capacity
            ) else {
                throw ConversionError.couldNotCreateOutputBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            switch status {
            case .haveData:
                if output.frameLength > 0 {
                    remainingBuffers.append(output)
                }
            case .inputRanDry, .endOfStream:
                return remainingBuffers
            case .error:
                throw ConversionError.conversionFailed(
                    conversionError?.localizedDescription ?? "未知错误"
                )
            @unknown default:
                return remainingBuffers
            }
        }
    }
}

private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take(
        inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard let buffer else {
            inputStatus.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        inputStatus.pointee = .haveData
        return buffer
    }
}
#endif
