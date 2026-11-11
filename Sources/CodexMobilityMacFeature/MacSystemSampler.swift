import AppKit
import CodexMobilityCore
import Darwin
import Foundation
import IOKit.ps
import Network
import SystemConfiguration

public protocol MacSystemSampling: AnyObject, Sendable {
    func start()
    func stop()
    func sample(mode: MobilityModeStatus, now: Date) -> MobilityDeviceStatus
}

struct CodexProcessRecord: Equatable, Sendable {
    let processIdentifier: pid_t
    let executablePath: String
}

protocol CodexCLIProcessInspecting: Sendable {
    func runningProcesses() -> [CodexProcessRecord]
}

protocol MacPrimaryNetworkProbing: Sendable {
    func currentPrimaryNetwork() -> MobilityNetworkStatus?
}

/// `NWPathMonitor` remains the primary observer. This native
/// SystemConfiguration probe closes the short (and, on some Personal Hotspot
/// transitions, persistent) gap where the default route is already usable but
/// the monitor-backed snapshot has not been published yet.
struct SystemConfigurationMacPrimaryNetworkProbe: MacPrimaryNetworkProbing {
    func currentPrimaryNetwork() -> MobilityNetworkStatus? {
        for addressFamily in ["IPv4", "IPv6"] {
            guard let global = Self.dictionary(
                for: "State:/Network/Global/\(addressFamily)"
            ),
            let interfaceName = global["PrimaryInterface"] as? String,
            !interfaceName.isEmpty,
            let primaryService = global["PrimaryService"] as? String,
            !primaryService.isEmpty else {
                continue
            }

            let interfaceAddresses = Self.dictionary(
                for: "State:/Network/Interface/\(interfaceName)/\(addressFamily)"
            )?["Addresses"] as? [String] ?? []
            let serviceAddresses = Self.dictionary(
                for: "State:/Network/Service/\(primaryService)/\(addressFamily)"
            )?["Addresses"] as? [String] ?? []
            let addresses = Self.preferredAddresses(
                interfaceAddresses: interfaceAddresses,
                serviceAddresses: serviceAddresses
            )

            let link = Self.dictionary(
                for: "State:/Network/Interface/\(interfaceName)/Link"
            )
            guard Self.isUsablePrimaryRoute(
                global: global,
                addresses: addresses,
                link: link
            ) else {
                continue
            }

            return MobilityNetworkStatus(
                kind: Self.networkKind(for: interfaceName),
                isConnected: true,
                isExpensive: Self.boolValue(link?["Expensive"]) ?? false,
                isConstrained: Self.boolValue(link?["Constrained"]) ?? false,
                interfaceName: interfaceName,
                disconnectedSince: nil
            )
        }
        return nil
    }

    static func isUsablePrimaryRoute(
        global: [String: Any],
        addresses: [String],
        link: [String: Any]?
    ) -> Bool {
        guard let primaryService = global["PrimaryService"] as? String,
              !primaryService.isEmpty,
              let router = global["Router"] as? String,
              !router.isEmpty,
              !addresses.isEmpty else {
            return false
        }
        // Some valid VPN and Personal Hotspot transitions omit the Link
        // dictionary. A published primary service, router, and address still
        // establish a usable route; only an explicit inactive link vetoes it.
        if Self.boolValue(link?["Active"]) == false {
            return false
        }
        return true
    }

    static func preferredAddresses(
        interfaceAddresses: [String],
        serviceAddresses: [String]
    ) -> [String] {
        interfaceAddresses.isEmpty ? serviceAddresses : interfaceAddresses
    }

    private static func dictionary(for key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any]
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func networkKind(for interfaceName: String) -> MobilityNetworkKind {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        guard let interface = interfaces.first(where: {
            (SCNetworkInterfaceGetBSDName($0) as String?) == interfaceName
        }),
        let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else {
            return .other
        }

        switch type as CFString {
        case kSCNetworkInterfaceTypeIEEE80211:
            return .wifi
        case kSCNetworkInterfaceTypeEthernet:
            return .ethernet
        case kSCNetworkInterfaceTypeWWAN:
            return .cellular
        default:
            return .other
        }
    }
}

struct DarwinCodexCLIProcessInspector: CodexCLIProcessInspecting {
    func runningProcesses() -> [CodexProcessRecord] {
        let estimatedCount = max(Int(proc_listallpids(nil, 0)), 0)
        guard estimatedCount > 0 else { return [] }

        // Leave room for processes created between the sizing and population calls.
        var processIdentifiers = [pid_t](repeating: 0, count: estimatedCount + 64)
        let populatedCount = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard populatedCount > 0 else { return [] }

        return processIdentifiers.prefix(Int(populatedCount)).compactMap { processIdentifier in
            guard processIdentifier > 0 else { return nil }

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
                proc_pidpath(processIdentifier, buffer.baseAddress, UInt32(buffer.count))
            }
            guard pathLength > 0 else { return nil }

            let executablePath = pathBuffer.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            return CodexProcessRecord(
                processIdentifier: processIdentifier,
                executablePath: executablePath
            )
        }
    }
}

/// Samples only public, user-visible macOS state. Raw IOKit dictionaries are
/// never retained or logged because they may contain hardware identifiers.
public final class MacSystemSampler: MacSystemSampling, @unchecked Sendable {
    private enum PowerSourceKey {
        static let currentCapacity = "Current Capacity"
        static let maxCapacity = "Max Capacity"
        static let isCharging = "Is Charging"
        static let powerSourceState = "Power Source State"
        static let timeToEmpty = "Time to Empty"
        static let timeToFullCharge = "Time to Full Charge"
        static let type = "Type"
        static let internalBattery = "InternalBattery"
        static let acPower = "AC Power"
    }

    static let codexBundleIdentifier = "com.openai.codex"

    private static let deviceIDDefaultsKey = "CodexMobility.macDeviceID"

    public let deviceID: UUID
    public let deviceName: String

    private let pathMonitor: NWPathMonitor
    private let guiCodexIsRunning: () -> Bool
    private let codexCLIProcessInspector: any CodexCLIProcessInspecting
    private let codexCLIProcessIsIgnored: @Sendable (pid_t) -> Bool
    private let closedLidContinuityIsAvailable: () -> Bool
    private let primaryNetworkProbe: any MacPrimaryNetworkProbing
    private let temperatureSensor: any MacTemperatureSampling
    private let pathQueue = DispatchQueue(label: "com.tidux.codex-mobility.network-path")
    private let lock = NSLock()
    private var latestNetwork = MobilityNetworkStatus(
        kind: .unknown,
        isConnected: false,
        disconnectedSince: Date()
    )
    private var isStarted = false

    public convenience init(
        deviceID: UUID? = nil,
        deviceName: String? = nil,
        pathMonitor: NWPathMonitor = NWPathMonitor()
    ) {
        self.init(
            deviceID: deviceID,
            deviceName: deviceName,
            pathMonitor: pathMonitor,
            guiCodexIsRunning: {
                NSRunningApplication.runningApplications(
                    withBundleIdentifier: Self.codexBundleIdentifier
                ).contains { !$0.isTerminated }
            },
            codexCLIProcessInspector: DarwinCodexCLIProcessInspector(),
            codexCLIProcessIsIgnored: {
                VoiceInputCodexProcessRegistry.shared.contains($0)
            },
            closedLidContinuityIsAvailable: {
                MacSystemPowerPolicyProbe.sleepDisabled() == true
            },
            primaryNetworkProbe: SystemConfigurationMacPrimaryNetworkProbe(),
            temperatureSensor: MacTemperatureSensor()
        )
    }

    init(
        deviceID: UUID? = nil,
        deviceName: String? = nil,
        pathMonitor: NWPathMonitor = NWPathMonitor(),
        guiCodexIsRunning: @escaping () -> Bool,
        codexCLIProcessInspector: any CodexCLIProcessInspecting,
        codexCLIProcessIsIgnored: @escaping @Sendable (pid_t) -> Bool = {
            VoiceInputCodexProcessRegistry.shared.contains($0)
        },
        closedLidContinuityIsAvailable: @escaping () -> Bool = {
            MacSystemPowerPolicyProbe.sleepDisabled() == true
        },
        primaryNetworkProbe: any MacPrimaryNetworkProbing =
            SystemConfigurationMacPrimaryNetworkProbe(),
        temperatureSensor: any MacTemperatureSampling = MacTemperatureSensor()
    ) {
        self.deviceID = deviceID ?? Self.loadOrCreateDeviceID()
        self.deviceName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Host.current().localizedName?.nonEmpty
            ?? "Mac"
        self.pathMonitor = pathMonitor
        self.guiCodexIsRunning = guiCodexIsRunning
        self.codexCLIProcessInspector = codexCLIProcessInspector
        self.codexCLIProcessIsIgnored = codexCLIProcessIsIgnored
        self.closedLidContinuityIsAvailable = closedLidContinuityIsAvailable
        self.primaryNetworkProbe = primaryNetworkProbe
        self.temperatureSensor = temperatureSensor
    }

    deinit {
        pathMonitor.cancel()
    }

    public func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.record(path: path, observedAt: Date())
        }
        pathMonitor.start(queue: pathQueue)
    }

    public func stop() {
        lock.lock()
        let shouldCancel = isStarted
        isStarted = false
        lock.unlock()
        if shouldCancel {
            pathMonitor.cancel()
        }
    }

    public func sample(mode: MobilityModeStatus, now: Date = Date()) -> MobilityDeviceStatus {
        let temperature = temperatureSensor.currentReading(now: now)
        return MobilityDeviceStatus(
            deviceID: deviceID,
            deviceName: deviceName,
            battery: sampleBattery(),
            network: networkSnapshot(),
            thermalState: sampleThermalState(),
            temperatureCelsius: temperature?.celsius,
            temperatureSource: temperature?.source,
            codex: sampleCodexStatus(),
            mode: mode,
            helperReady: closedLidContinuityIsAvailable(),
            observedAt: now
        )
    }

    private func sampleBattery() -> MobilityBatteryStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return MobilityBatteryStatus()
        }

        let descriptions = sourceList.compactMap { source -> [String: Any]? in
            guard let rawDescription = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
            else { return nil }
            return rawDescription as? [String: Any]
        }
        return Self.batteryStatus(from: descriptions)
    }

    /// Accepts decoded IOKit descriptions so the InternalBattery-only boundary
    /// can be tested without substituting private power-source APIs.
    static func batteryStatus(from descriptions: [[String: Any]]) -> MobilityBatteryStatus {
        for description in descriptions {
            // UPS devices also expose capacity fields. Type must match exactly so
            // an external UPS can never be mistaken for this Mac's battery.
            guard description[PowerSourceKey.type] as? String == PowerSourceKey.internalBattery
            else { continue }

            let currentCapacity = number(description[PowerSourceKey.currentCapacity])
            let maxCapacity = number(description[PowerSourceKey.maxCapacity])
            let levelPercent: Int?
            if let currentCapacity, let maxCapacity, maxCapacity > 0 {
                levelPercent = Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
            } else {
                levelPercent = currentCapacity
            }

            let isCharging = (description[PowerSourceKey.isCharging] as? Bool) ?? false
            let isOnExternalPower = (description[PowerSourceKey.powerSourceState] as? String)
                == PowerSourceKey.acPower
            let estimateKey = isCharging
                ? PowerSourceKey.timeToFullCharge
                : PowerSourceKey.timeToEmpty
            let estimatedMinutes = number(description[estimateKey]).flatMap { $0 >= 0 ? $0 : nil }

            return MobilityBatteryStatus(
                levelPercent: levelPercent,
                isCharging: isCharging,
                isOnExternalPower: isOnExternalPower,
                estimatedMinutesRemaining: estimatedMinutes
            )
        }

        return MobilityBatteryStatus()
    }

    private func sampleThermalState() -> MobilityThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }

    private func sampleCodexStatus() -> MobilityCodexStatus {
        let isGUIRunning = guiCodexIsRunning()
        let currentProcessIdentifier = getpid()
        let isCLIRunning = codexCLIProcessInspector.runningProcesses().contains { process in
            process.processIdentifier != currentProcessIdentifier
                && !codexCLIProcessIsIgnored(process.processIdentifier)
                && Self.isCodexCLIExecutablePath(process.executablePath)
        }
        let detail: String
        switch (isGUIRunning, isCLIRunning) {
        case (true, true):
            detail = "Codex 图形客户端与 CLI 正在运行"
        case (true, false):
            detail = "Codex 图形客户端正在运行"
        case (false, true):
            detail = "Codex CLI 正在运行"
        case (false, false):
            detail = "未检测到 Codex 图形客户端或 CLI"
        }
        return MobilityCodexStatus(
            isRunning: isGUIRunning || isCLIRunning,
            activeTaskCount: 0,
            detail: detail
        )
    }

    static func isCodexCLIExecutablePath(_ executablePath: String) -> Bool {
        URL(fileURLWithPath: executablePath).lastPathComponent
            .caseInsensitiveCompare("codex") == .orderedSame
    }

    private func record(path: NWPath, observedAt: Date) {
        let isConnected = path.status == .satisfied
        let kind: MobilityNetworkKind
        if !isConnected {
            kind = .offline
        } else if path.usesInterfaceType(.wifi) {
            kind = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = .ethernet
        } else if path.usesInterfaceType(.cellular) {
            kind = .cellular
        } else if path.availableInterfaces.isEmpty {
            kind = .unknown
        } else {
            kind = .other
        }

        let usedInterface = path.availableInterfaces.first { path.usesInterfaceType($0.type) }

        lock.lock()
        let disconnectedSince = isConnected
            ? nil
            : (latestNetwork.disconnectedSince ?? observedAt)
        latestNetwork = MobilityNetworkStatus(
            kind: kind,
            isConnected: isConnected,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            interfaceName: usedInterface?.name,
            disconnectedSince: disconnectedSince
        )
        lock.unlock()
    }

    private func networkSnapshot() -> MobilityNetworkStatus {
        lock.lock()
        let monitoredNetwork = latestNetwork
        lock.unlock()

        guard !monitoredNetwork.isConnected else {
            return monitoredNetwork
        }

        let primaryRoute = primaryNetworkProbe.currentPrimaryNetwork()

        // The NWPath callback may land while the synchronous fallback is being
        // read. Re-read after the probe so a newly satisfied path wins in this
        // very sample instead of waiting for the next polling cycle.
        lock.lock()
        let latestMonitoredNetwork = latestNetwork
        lock.unlock()

        return Self.resolvedNetworkStatus(
            monitored: latestMonitoredNetwork,
            primaryRoute: primaryRoute
        )
    }

    static func resolvedNetworkStatus(
        monitored: MobilityNetworkStatus,
        primaryRoute: MobilityNetworkStatus?
    ) -> MobilityNetworkStatus {
        guard !monitored.isConnected,
              let primaryRoute,
              primaryRoute.isConnected else {
            return monitored
        }
        return primaryRoute
    }

    private static func number(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }

    private static func loadOrCreateDeviceID(defaults: UserDefaults = .standard) -> UUID {
        if let stored = defaults.string(forKey: deviceIDDefaultsKey),
           let identifier = UUID(uuidString: stored) {
            return identifier
        }
        let identifier = UUID()
        defaults.set(identifier.uuidString, forKey: deviceIDDefaultsKey)
        return identifier
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
