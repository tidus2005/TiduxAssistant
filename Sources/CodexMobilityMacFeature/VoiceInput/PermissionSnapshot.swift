import Foundation

struct PermissionSnapshot: Equatable, Sendable {
    var microphoneGranted = false
    var accessibilityGranted = false

    var allGranted: Bool {
        microphoneGranted && accessibilityGranted
    }
}
