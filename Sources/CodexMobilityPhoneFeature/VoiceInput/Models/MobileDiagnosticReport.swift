#if os(iOS) && !targetEnvironment(macCatalyst)
import Darwin
import CodexMobilityCore
import Foundation
import UIKit

struct MobileDiagnosticReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
    let appBuild: String
    let sourceRevision: String
    let deviceModel: String
    let hardwareIdentifier: String
    let systemName: String
    let systemVersion: String
    let operatingSystemVersionString: String
    let thermalState: String
    let peakThermalState: String
    let phase: String
    let statusMessage: String
    let requestedLocaleIdentifier: String
    let resolvedLocaleIdentifier: String?
    let microphonePermission: String
    let speechTranscriberAvailable: Bool
    let backend: String?
    let assetState: String
    let localeReserved: Bool
    let localeReservationObservedDuringRecording: Bool
    let localeReservationReleasedAfterRecording: Bool
    let maximumReservedLocales: Int
    let keepAudio: Bool
    let availableStorageBytes: Int64?
    let minimumRecordingStorageBytes: Int64
    let activeSessionID: UUID?
    let activeSessionState: String?
    let elapsedSeconds: TimeInterval
    let firstPartialLatencyMilliseconds: Int?
    let partialUpdateCount: Int
    let finalUpdateCount: Int
    let finalizationDurationMilliseconds: Int?
    let recordedAudioFrameCount: Int64?
    let recordedAudioDurationSeconds: TimeInterval?
    let recordingStartAvailableStorageBytes: Int64?
    let recordingEndAvailableStorageBytes: Int64?
    let recordingStartResidentMemoryBytes: UInt64?
    let recordingEndResidentMemoryBytes: UInt64?
    let peakResidentMemoryBytes: UInt64?
    let diagnostics: [String]

    @MainActor
    init(
        generatedAt: Date = Date(),
        bundle: Bundle = .main,
        device: UIDevice = .current,
        processInfo: ProcessInfo = .processInfo,
        phase: MobileRecordingPhase,
        statusMessage: String,
        selectedLocaleIdentifier: String,
        capability: MobileSpeechCapabilitySnapshot,
        keepAudio: Bool,
        availableStorageBytes: Int64?,
        minimumRecordingStorageBytes: Int64,
        activeSession: RecordingSession?,
        elapsedSeconds: TimeInterval,
        peakThermalState: String,
        firstPartialLatencyMilliseconds: Int?,
        partialUpdateCount: Int,
        finalUpdateCount: Int,
        finalizationDurationMilliseconds: Int?,
        recordedAudioFrameCount: Int64?,
        recordedAudioDurationSeconds: TimeInterval?,
        recordingStartAvailableStorageBytes: Int64?,
        recordingEndAvailableStorageBytes: Int64?,
        recordingStartResidentMemoryBytes: UInt64?,
        recordingEndResidentMemoryBytes: UInt64?,
        peakResidentMemoryBytes: UInt64?,
        localeReservationObservedDuringRecording: Bool,
        localeReservationReleasedAfterRecording: Bool,
        diagnostics: [String]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        appVersion =
            bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown"
        appBuild =
            bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown"
        sourceRevision =
            bundle.object(
                forInfoDictionaryKey: "CodexWatchPetVoiceInputSourceRevision"
            ) as? String ?? "unknown"
        deviceModel = device.model
        hardwareIdentifier = Self.hardwareIdentifier(
            processInfo: processInfo
        )
        systemName = device.systemName
        systemVersion = device.systemVersion
        operatingSystemVersionString =
            processInfo.operatingSystemVersionString
        thermalState = Self.thermalStateTitle(
            processInfo.thermalState
        )
        self.peakThermalState = peakThermalState
        self.phase = phase.rawValue
        self.statusMessage = statusMessage
        requestedLocaleIdentifier = selectedLocaleIdentifier
        resolvedLocaleIdentifier =
            capability.resolvedLocaleIdentifier
        microphonePermission = capability.microphonePermission.rawValue
        speechTranscriberAvailable =
            capability.speechTranscriberAvailable
        backend = capability.backend?.rawValue
        assetState = capability.assetState.rawValue
        localeReserved = capability.localeReserved
        self.localeReservationObservedDuringRecording =
            localeReservationObservedDuringRecording
        self.localeReservationReleasedAfterRecording =
            localeReservationReleasedAfterRecording
        maximumReservedLocales = capability.maximumReservedLocales
        self.keepAudio = keepAudio
        self.availableStorageBytes = availableStorageBytes
        self.minimumRecordingStorageBytes =
            minimumRecordingStorageBytes
        activeSessionID = activeSession?.id
        activeSessionState = activeSession?.state.rawValue
        self.elapsedSeconds = elapsedSeconds
        self.firstPartialLatencyMilliseconds =
            firstPartialLatencyMilliseconds
        self.partialUpdateCount = partialUpdateCount
        self.finalUpdateCount = finalUpdateCount
        self.finalizationDurationMilliseconds =
            finalizationDurationMilliseconds
        self.recordedAudioFrameCount = recordedAudioFrameCount
        self.recordedAudioDurationSeconds =
            recordedAudioDurationSeconds
        self.recordingStartAvailableStorageBytes =
            recordingStartAvailableStorageBytes
        self.recordingEndAvailableStorageBytes =
            recordingEndAvailableStorageBytes
        self.recordingStartResidentMemoryBytes =
            recordingStartResidentMemoryBytes
        self.recordingEndResidentMemoryBytes =
            recordingEndResidentMemoryBytes
        self.peakResidentMemoryBytes =
            peakResidentMemoryBytes
        self.diagnostics = diagnostics
    }

    func formattedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    private static func thermalStateTitle(
        _ state: ProcessInfo.ThermalState
    ) -> String {
        switch state {
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

    private static func hardwareIdentifier(
        processInfo: ProcessInfo
    ) -> String {
        if let simulatorIdentifier =
            processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        {
            return simulatorIdentifier
        }

        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(
                to: CChar.self,
                capacity: 1
            ) {
                String(cString: $0)
            }
        }
    }
}
#endif
