import AppKit
import ApplicationServices
import Foundation

public protocol MacInstantHotspotConnecting: Sendable {
    func connect(ssid: String) async throws
}

enum MacInstantHotspotError: Error, LocalizedError {
    case accessibilityRequired
    case unavailable
    case actionFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            "普通 Wi-Fi 连接未找到热点。请在系统设置的辅助功能权限中允许 Tidux助手，才能自动操作系统个人热点入口。"
        case .unavailable:
            "系统 Wi-Fi 页面暂未发现指定个人热点；请确保 iPhone 在附近、Wi-Fi 与蓝牙已开启后重试。"
        case .actionFailed:
            "macOS 未接受个人热点连接请求，请在系统 Wi-Fi 中检查热点状态。"
        }
    }
}

/// Instant Hotspot can be visible to macOS Continuity without broadcasting an
/// SSID that networksetup can join. Use the system's exact Personal Hotspot row
/// once for an explicit user start. Never automate credentials or permission
/// dialogs, and never use this foreground fallback for background retries.
struct SystemSettingsInstantHotspotConnector: MacInstantHotspotConnecting {
    @MainActor
    func connect(ssid: String) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw MacInstantHotspotError.accessibilityRequired }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension"),
              NSWorkspace.shared.open(url) else {
            throw MacInstantHotspotError.unavailable
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.systempreferences"
            ).first {
                let root = AXUIElementCreateApplication(application.processIdentifier)
                if let row = hotspotRow(in: root, ssid: ssid),
                   let action = connectAction(on: row) {
                    try Task.checkCancellation()
                    guard AXUIElementPerformAction(row, action as CFString) == .success else {
                        throw MacInstantHotspotError.actionFailed
                    }
                    // Request accepted is not proof of association. The caller
                    // still waits for SSID/usable mobile-path verification.
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw MacInstantHotspotError.unavailable
    }

    private func hotspotRow(in root: AXUIElement, ssid: String) -> AXUIElement? {
        var stack = [root]
        var visited = 0
        while let element = stack.popLast(), visited < 2_000 {
            visited += 1
            let children = children(of: element)
            // Require the OS's Personal Hotspot icon identifier in the same
            // container; an unrelated network with a similar label is ignored.
            let hotspotID = "wifi-network-\(ssid)-hotspot"
            if children.contains(where: { string($0, kAXIdentifierAttribute) == hotspotID }),
               let row = children.first(where: {
                   string($0, kAXValueAttribute) == ssid
                       || string($0, kAXTitleAttribute) == ssid
               }) {
                return row
            }
            stack.append(contentsOf: children)
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func connectAction(on element: AXUIElement) -> String? {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let actions = value as? [String] else { return nil }
        for action in actions {
            var description: CFString?
            if AXUIElementCopyActionDescription(element, action as CFString, &description) == .success,
               let description = description as String?,
               ["连接", "Connect", "connect"].contains(description) {
                return action
            }
        }
        return actions.contains(kAXPressAction) ? kAXPressAction : nil
    }
}
