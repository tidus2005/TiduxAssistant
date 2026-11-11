import Foundation

/// Allow-listed operations shared by the menu bar and the paired phone. No shell,
/// arbitrary URL, credential export, or password-policy mutation is exposed.
public enum CompanionDashboardAction: Codable, Equatable, Sendable {
    case snapshot
    case mobileOffice(enabled: Bool, durationMinutes: Int)
    case baselineClosedLid(Bool)
    case caffeine(enabled: Bool, durationMinutes: Int?)
    case connectHotspot
    case setHotspotName(String)
    case setModule(id: String, enabled: Bool)
    case toggleMacDictation
    case prepareFileReceiver
    case revealInbox
    case showDashboard
}

public struct CompanionModuleState: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var enabled: Bool
    public var canChange: Bool
    public init(id: String, title: String, enabled: Bool, canChange: Bool = true) {
        self.id = id; self.title = title; self.enabled = enabled; self.canChange = canChange
    }
}

public struct CompanionDashboardSnapshot: Codable, Equatable, Sendable {
    public var observedAt = Date()
    public var deviceID: UUID
    public var mobileOfficeOn = false
    public var mobileOfficeBusy = false
    public var durationMinutes = 120
    public var expiresAt: Date?
    public var mobileOfficeStatus = ""
    public var baselineOn = false
    public var baselineCanChange = false
    public var caffeineOn = false
    public var caffeineStatus = ""
    public var hotspotName = ""
    public var hotspotStatus = ""
    public var voiceStatus = ""
    public var voiceRecording = false
    public var inboxPath = ""
    public var modules: [CompanionModuleState] = []
    public var fileHost: String?
    public var filePort: UInt16?
    public init(deviceID: UUID) { self.deviceID = deviceID }
}

public struct CompanionDashboardReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var snapshot: CompanionDashboardSnapshot
    public init(ok: Bool, message: String, snapshot: CompanionDashboardSnapshot) {
        self.ok = ok; self.message = message; self.snapshot = snapshot
    }
}

public enum CompanionFileRoute: String, Codable, Sendable { case bluetooth, localNetwork, waitingForNetwork }
public enum CompanionFileRouting {
    /// A small acknowledgement-driven BLE transfer cannot monopolize the control link.
    public static let bluetoothLimit: UInt64 = 64 * 1_024
    public static func route(byteSize: UInt64, bluetoothReady: Bool, networkReady: Bool) -> CompanionFileRoute {
        if byteSize <= bluetoothLimit && bluetoothReady { return .bluetooth }
        return networkReady ? .localNetwork : .waitingForNetwork
    }
}
