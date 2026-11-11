#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFAudio
import Foundation
import Speech

enum MobileSpeechAssetError: LocalizedError, Sendable {
    case microphoneDenied
    case localeUnsupported(String)
    case speechAssetsUnsupported
    case speechAssetsNotInstalled
    case localeReservationFailed(String)
    case localeReleaseFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "没有麦克风权限。"
        case let .localeUnsupported(identifier):
            "当前设备不支持 \(identifier) 语音转写。"
        case .speechAssetsUnsupported:
            "当前设备不支持所需的本地语音模型。"
        case .speechAssetsNotInstalled:
            "本地语音模型没有完成安装。"
        case let .localeReservationFailed(identifier):
            "无法为 \(identifier) 保留本地语音模型。"
        case let .localeReleaseFailed(identifier):
            "无法释放 \(identifier) 的本地语音模型保留槽位。"
        }
    }
}

actor MobileSpeechAssetManager {
    private enum Backend {
        case speech(locale: Locale, module: SpeechTranscriber)
        case dictation(locale: Locale, module: DictationTranscriber)

        var locale: Locale {
            switch self {
            case let .speech(locale, _), let .dictation(locale, _):
                locale
            }
        }

        var kind: MobileSpeechBackend {
            switch self {
            case .speech:
                .speechTranscriber
            case .dictation:
                .dictationTranscriber
            }
        }

        var modules: [any SpeechModule] {
            switch self {
            case let .speech(_, module):
                [module]
            case let .dictation(_, module):
                [module]
            }
        }
    }

    private var reservedLocale: Locale?

    func inspect(locale requestedLocale: Locale) async
        -> MobileSpeechCapabilitySnapshot
    {
        var snapshot = baseSnapshot(for: requestedLocale)
        do {
            let backend = try await selectBackend(for: requestedLocale)
            snapshot.resolvedLocaleIdentifier = backend.locale.identifier
            snapshot.backend = backend.kind
            snapshot.assetState = Self.map(
                await AssetInventory.status(forModules: backend.modules)
            )
            let reserved = await AssetInventory.reservedLocales
            snapshot.localeReserved = reserved.contains {
                Self.localesAreEquivalent($0, backend.locale)
            }
        } catch {
            snapshot.errorMessage = error.localizedDescription
            snapshot.assetState = .failed
        }
        return snapshot
    }

    func prepare(locale requestedLocale: Locale) async throws
        -> MobileSpeechCapabilitySnapshot
    {
        let microphonePermission = await requestMicrophonePermission()
        guard microphonePermission == .granted else {
            throw MobileSpeechAssetError.microphoneDenied
        }

        let backend = try await selectBackend(for: requestedLocale)
        var assetStatus = await AssetInventory.status(
            forModules: backend.modules
        )
        guard assetStatus != .unsupported else {
            throw MobileSpeechAssetError.speechAssetsUnsupported
        }

        if assetStatus != .installed {
            if let request = try await AssetInventory
                .assetInstallationRequest(supporting: backend.modules) {
                try await request.downloadAndInstall()
            }
            assetStatus = await AssetInventory.status(
                forModules: backend.modules
            )
        }
        guard assetStatus == .installed else {
            throw MobileSpeechAssetError.speechAssetsNotInstalled
        }

        if let reservedLocale,
           !Self.localesAreEquivalent(
               reservedLocale,
               backend.locale
           ) {
            let released = await release(
                localeEquivalentTo: reservedLocale
            )
            guard released else {
                throw MobileSpeechAssetError.localeReleaseFailed(
                    reservedLocale.identifier
                )
            }
            self.reservedLocale = nil
        }

        var reservedLocales = await AssetInventory.reservedLocales
        var actualReservedLocale = reservedLocales.first {
            Self.localesAreEquivalent($0, backend.locale)
        }
        if actualReservedLocale == nil {
            let didReserve = try await AssetInventory.reserve(
                locale: backend.locale
            )
            guard didReserve else {
                throw MobileSpeechAssetError.localeReservationFailed(
                    backend.locale.identifier
                )
            }
            reservedLocales = await AssetInventory.reservedLocales
            actualReservedLocale = reservedLocales.first {
                Self.localesAreEquivalent($0, backend.locale)
            }
        }

        guard let actualReservedLocale else {
            throw MobileSpeechAssetError.localeReservationFailed(
                backend.locale.identifier
            )
        }
        reservedLocale = actualReservedLocale

        return MobileSpeechCapabilitySnapshot(
            microphonePermission: microphonePermission,
            speechTranscriberAvailable: SpeechTranscriber.isAvailable,
            requestedLocaleIdentifier: requestedLocale.identifier,
            resolvedLocaleIdentifier: backend.locale.identifier,
            backend: backend.kind,
            assetState: .installed,
            localeReserved: true,
            maximumReservedLocales: AssetInventory.maximumReservedLocales,
            errorMessage: nil
        )
    }

    func releaseReservation() async {
        if let reservedLocale {
            let released = await release(
                localeEquivalentTo: reservedLocale
            )
            if released {
                self.reservedLocale = nil
            }
        }
        await SpeechModels.endRetention()
    }

    private func release(localeEquivalentTo target: Locale) async -> Bool {
        let reservedLocales = await AssetInventory.reservedLocales
        var candidates = reservedLocales.filter {
            Self.localesAreEquivalent($0, target)
        }
        if !candidates.contains(where: {
            $0.identifier == target.identifier
        }) {
            candidates.insert(target, at: 0)
        }

        for candidate in candidates {
            if await AssetInventory.release(reservedLocale: candidate) {
                return true
            }
        }
        return false
    }

    func requestMicrophonePermission() async -> MobileMicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .granted : .denied
        @unknown default:
            return .unknown
        }
    }

    private func baseSnapshot(
        for requestedLocale: Locale
    ) -> MobileSpeechCapabilitySnapshot {
        MobileSpeechCapabilitySnapshot(
            microphonePermission: Self.currentMicrophonePermission(),
            speechTranscriberAvailable: SpeechTranscriber.isAvailable,
            requestedLocaleIdentifier: requestedLocale.identifier,
            maximumReservedLocales: AssetInventory.maximumReservedLocales
        )
    }

    private func selectBackend(for requestedLocale: Locale) async throws
        -> Backend
    {
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(
               equivalentTo: requestedLocale
           ) {
            return .speech(
                locale: locale,
                module: SpeechTranscriber(
                    locale: locale,
                    preset: .progressiveTranscription
                )
            )
        }

        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw MobileSpeechAssetError.localeUnsupported(
                requestedLocale.identifier
            )
        }
        return .dictation(
            locale: locale,
            module: DictationTranscriber(
                locale: locale,
                preset: .progressiveLongDictation
            )
        )
    }

    private static func currentMicrophonePermission()
        -> MobileMicrophonePermission
    {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            .granted
        case .denied:
            .denied
        case .undetermined:
            .undetermined
        @unknown default:
            .unknown
        }
    }

    private static func map(
        _ status: AssetInventory.Status
    ) -> MobileSpeechAssetState {
        switch status {
        case .unsupported:
            .unsupported
        case .supported:
            .supported
        case .downloading:
            .downloading
        case .installed:
            .installed
        @unknown default:
            .failed
        }
    }

    static func localesAreEquivalent(
        _ lhs: Locale,
        _ rhs: Locale
    ) -> Bool {
        if lhs.language == rhs.language {
            return true
        }

        guard
            lhs.language.languageCode == rhs.language.languageCode
        else {
            return false
        }
        let lhsRegion = lhs.language.region
        let rhsRegion = rhs.language.region
        return lhsRegion == nil || rhsRegion == nil || lhsRegion == rhsRegion
    }
}
#endif
