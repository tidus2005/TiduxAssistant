import ApplicationServices
import AVFoundation
import Foundation

@MainActor
final class PermissionService {
    init() {}

    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphoneGranted: AVAudioApplication.shared.recordPermission == .granted,
            accessibilityGranted: AXIsProcessTrusted()
        )
    }

    @discardableResult
    func requestAll(
        promptForAccessibility: Bool = true
    ) async -> PermissionSnapshot {
        _ = await requestMicrophone()
        _ = requestAccessibility(prompt: promptForAccessibility)
        return snapshot()
    }

    @discardableResult
    func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    @discardableResult
    func requestAccessibility(prompt: Bool = true) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
