#if os(iOS) && !targetEnvironment(macCatalyst)
import CodexMobilityCore
import SwiftUI

enum MobileAccessibilityIdentifier {
    static let rootTabView = "mobile.root.tabView"
    static let recordingTab = "mobile.tab.recording"
    static let historyTab = "mobile.tab.history"
    static let settingsTab = "mobile.tab.settings"
    static let globalRecordingIndicator =
        "mobile.recording.globalIndicator"

    static let recordingScreen = "mobile.recording.screen"
    static let recordingPhase = "mobile.recording.phase"
    static let recordingElapsed = "mobile.recording.elapsed"
    static let recordingAudioLevel = "mobile.recording.audioLevel"
    static let recordingStatus = "mobile.recording.status"
    static let recordingTranscript = "mobile.recording.transcript"
    static let recordingToggle = "mobile.recording.toggle"
    static let prepareSpeechAssets = "mobile.recording.prepareSpeechAssets"

    static let historyScreen = "mobile.history.screen"
    static let historyList = "mobile.history.list"
    static let historyEmpty = "mobile.history.empty"
    static let historyReload = "mobile.history.reload"

    static let detailScreen = "mobile.detail.screen"
    static let detailOverview = "mobile.detail.overview"
    static let detailTranscript = "mobile.detail.transcript"
    static let detailFailure = "mobile.detail.failure"
    static let detailSegments = "mobile.detail.segments"
    static let detailSessionID = "mobile.detail.sessionID"
    static let detailShare = "mobile.detail.share"

    static let settingsScreen = "mobile.settings.screen"
    static let settingsLocale = "mobile.settings.locale"
    static let settingsKeepAudio = "mobile.settings.keepAudio"
    static let settingsCapabilityError =
        "mobile.settings.capabilityError"
    static let settingsRefreshCapabilities =
        "mobile.settings.refreshCapabilities"
    static let settingsPrepareAssets = "mobile.settings.prepareAssets"
    static let settingsRefreshStorage =
        "mobile.settings.refreshStorage"
    static let settingsShareDiagnostics =
        "mobile.settings.shareDiagnostics"
    static let settingsExportHistory =
        "mobile.settings.exportHistory"
    static let settingsImportHistory =
        "mobile.settings.importHistory"
    static let settingsDiagnostics = "mobile.settings.diagnostics"
    static let settingsPrivacyPolicy =
        "mobile.settings.privacyPolicy"

    static func historyRow(_ id: UUID) -> String {
        "mobile.history.row.\(id.uuidString.lowercased())"
    }

    static func detailSegment(_ id: UUID) -> String {
        "mobile.detail.segment.\(id.uuidString.lowercased())"
    }
}

struct MobileSectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            ))
    }
}

struct MobileSessionStateBadge: View {
    let state: RecordingSessionState

    var body: some View {
        Label(state.mobileTitle, systemImage: state.mobileSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.mobileTint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(state.mobileTint.opacity(0.12), in: Capsule())
    }
}

extension RecordingSessionState {
    var mobileTitle: String {
        switch self {
        case .preparing:
            "准备中"
        case .recording:
            "录音中"
        case .paused:
            "已暂停"
        case .stopping:
            "收尾中"
        case .completed:
            "已完成"
        case .cancelled:
            "已取消"
        case .failed:
            "已中断"
        }
    }

    fileprivate var mobileSymbol: String {
        switch self {
        case .preparing:
            "hourglass"
        case .recording:
            "waveform.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .stopping:
            "ellipsis.circle"
        case .completed:
            "checkmark.circle.fill"
        case .cancelled:
            "xmark.circle"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    fileprivate var mobileTint: Color {
        switch self {
        case .recording:
            .red
        case .paused, .failed:
            .orange
        case .completed:
            .green
        case .preparing, .stopping:
            .blue
        case .cancelled:
            .secondary
        }
    }
}

enum MobileViewFormat {
    static func byteCount(_ bytes: Int64?) -> String {
        guard let bytes else { return "未知" }
        return byteCount(bytes)
    }

    static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func duration(from start: Date?, to end: Date?) -> String {
        guard let start, let end else { return "未开始" }
        let totalSeconds = max(
            0,
            Int(end.timeIntervalSince(start).rounded(.down))
        )
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
}
#endif
