import AppKit
import Combine
import CoreLocation
import CoreWLAN
import SwiftUI

/// macOS privacy-gates Wi-Fi identities behind Location authorization.
/// Request only from the explicit button, never from a background retry.
/// No location updates are requested or collected.
@MainActor
final class MacHotspotWiFiAuthorization: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = MacHotspotWiFiAuthorization()
    private let manager = CLLocationManager()
    @Published private(set) var isAuthorized = false

    override private init() {
        super.init()
        manager.delegate = self
        refresh()
    }

    static func currentSSID(interface: String) async -> String? {
        guard shared.isAuthorized else { return nil }
        return await Task.detached(priority: .utility) {
            CWWiFiClient.shared().interface(withName: interface)?.ssid()
        }.value
    }

    func request() {
        refresh()
        guard !isAuthorized else { return }
        if manager.authorizationStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private func refresh() {
        isAuthorized = manager.authorizationStatus == .authorizedAlways
            && CLLocationManager.locationServicesEnabled()
    }
}

struct HotspotWiFiPermissionButton: View {
    @ObservedObject private var authorization = MacHotspotWiFiAuthorization.shared

    var body: some View {
        if authorization.isAuthorized {
            Label("后台热点重连已授权", systemImage: "checkmark.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Button("授权后台热点重连…") { authorization.request() }
                .font(.caption)
                .help("macOS 需要定位权限才能识别并连接 Wi-Fi；随行助手不会收集地理位置。")
        }
    }
}
