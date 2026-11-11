import Foundation
import ObjectiveC
import Darwin
import OSLog
import CoreWLAN

/// Wakes and associates to a nearby, account-authorized Personal Hotspot.
/// NWPath must still confirm connectivity before the guard reports recovery.
public protocol MacBackgroundHotspotActivating: Sendable {
    func activate(ssid: String) async throws
}

enum MacBackgroundHotspotError: Error, LocalizedError, Equatable, Sendable {
    case unsupported
    case unavailable
    case ambiguousTarget
    case rejected
    case timedOut
    case locationPermissionRequired
    case associationFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: "当前 macOS 不支持后台个人热点唤醒。"
        case .unavailable: "目标 iPhone 暂不可用，稍后继续尝试唤醒热点。"
        case .ambiguousTarget: "发现多个同名个人热点，无法确定目标 iPhone。"
        case .rejected: "系统未能唤醒目标个人热点，稍后重试。"
        case .locationPermissionRequired: "请先在随行菜单点击“授权后台热点重连”，允许定位权限以连接目标 Wi-Fi。"
        case .associationFailed: "热点已唤醒，但 Wi-Fi 连接失败，稍后重试。"
        case .timedOut: "等待 iPhone 热点响应超时，手机回来后将继续重试。"
        }
    }
}

// Invitation remains in memory only. Never serialize it or expose credentials
// through process arguments, diagnostic descriptions, defaults, or logs.
struct MacHotspotInvitation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let ssid: String
    let password: String
    var description: String { "<redacted hotspot invitation>" }
    var debugDescription: String { description }
}

@MainActor
protocol MacBackgroundHotspotSession: AnyObject {
    func start(
        ssid: String,
        completion: @escaping @MainActor @Sendable (Result<MacHotspotInvitation, MacBackgroundHotspotError>) -> Void
    ) throws
    func stop()
}

@MainActor
final class SharingBackgroundHotspotActivator: MacBackgroundHotspotActivating {
    private static let logger = Logger(subsystem: "com.tidux.CodexWatchPet.mac", category: "hotspot-recovery")
    private let timeout: TimeInterval
    private let associate: @Sendable (MacHotspotInvitation) async throws -> Void
    private let checkAuthorization: @MainActor @Sendable () throws -> Void
    private let makeSession: @MainActor @Sendable () -> any MacBackgroundHotspotSession

    init(
        timeout: TimeInterval = 15,
        checkAuthorization: @escaping @MainActor @Sendable () throws -> Void = {
            guard MacHotspotWiFiAuthorization.shared.isAuthorized else {
                throw MacBackgroundHotspotError.locationPermissionRequired
            }
        },
        associate: @escaping @Sendable (MacHotspotInvitation) async throws -> Void = {
            try await CoreWLANHotspotAssociator.associate($0)
        },
        makeSession: @escaping @MainActor @Sendable () -> any MacBackgroundHotspotSession = {
            DynamicSharingHotspotSession()
        }
    ) {
        self.timeout = timeout.isFinite ? max(0.01, timeout) : 15
        self.makeSession = makeSession
        self.associate = associate
        self.checkAuthorization = checkAuthorization
    }

    func activate(ssid: String) async throws {
        try Task.checkCancellation()
        try checkAuthorization()
        let operation = HotspotActivationOperation(session: makeSession(), timeout: timeout)
        defer { operation.stopSession() }
        Self.logger.notice("headless activation started")
        do {
            let invitation = try await withTaskCancellationHandler {
                try await operation.run(ssid: ssid)
            } onCancel: {
                Task { @MainActor in operation.cancel() }
            }
            guard invitation.ssid == ssid, !invitation.password.isEmpty else {
                throw MacBackgroundHotspotError.rejected
            }
            try Task.checkCancellation()
            Self.logger.notice("headless activation accepted; associating through CoreWLAN")
            try await associate(invitation)
            try Task.checkCancellation()
            Self.logger.notice("headless association succeeded; awaiting network path")
        } catch is CancellationError {
            Self.logger.notice("headless activation cancelled")
            throw CancellationError()
        } catch {
            Self.logger.notice("headless activation failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }
}

@MainActor
private final class HotspotActivationOperation {
    private let session: any MacBackgroundHotspotSession
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<MacHotspotInvitation, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var sessionStopped = false

    init(session: any MacBackgroundHotspotSession, timeout: TimeInterval) {
        self.session = session
        self.timeout = timeout
    }

    func run(ssid: String) async throws -> MacHotspotInvitation {
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self, timeout] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self?.finish(.failure(MacBackgroundHotspotError.timedOut))
            }
            do {
                try session.start(ssid: ssid) { [weak self] result in
                    self?.finish(result.mapError { $0 as any Error })
                }
            } catch {
                finish(.failure(error))
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    func stopSession() {
        guard !sessionStopped else { return }
        sessionStopped = true
        session.stop()
    }

    private func finish(_ result: Result<MacHotspotInvitation, any Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        // Keep the system hotspot session alive until association finishes.
        // Waking the phone does not mean its Wi-Fi beacon is ready yet.
        if case .failure = result { stopSession() }
        let completion = continuation
        continuation = nil
        completion?.resume(with: result)
    }
}

/// Isolates the optional macOS Sharing SPI. No private entitlements are added,
/// credentials stay in memory for association, and system rejection is a failure.
/// This is for the locally installed Mac app, not an App Store API contract.
@MainActor
private final class DynamicSharingHotspotSession: NSObject, MacBackgroundHotspotSession {
    // Keep the image loaded for the lifetime of Objective-C classes/callbacks.
    private static let frameworkAvailable = dlopen(
        "/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW | RTLD_LOCAL
    ) != nil
    private var session: NSObject?
    private var target = ""
    private var requested = false
    private var completion: (@MainActor @Sendable (Result<MacHotspotInvitation, MacBackgroundHotspotError>) -> Void)?

    func start(
        ssid: String,
        completion: @escaping @MainActor @Sendable (Result<MacHotspotInvitation, MacBackgroundHotspotError>) -> Void
    ) throws {
        guard Self.frameworkAvailable,
              let type = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type,
              Self.hasMethod(type, "startBrowsing", arguments: 2),
              Self.hasMethod(type, "stopBrowsing", arguments: 2),
              Self.hasMethod(type, "setDelegate:", arguments: 3),
              Self.hasMethod(type, "enableRemoteHotspotForDevice:withCompletionHandler:", arguments: 4)
        else { throw MacBackgroundHotspotError.unsupported }
        target = ssid
        self.completion = completion
        let instance = type.init()
        session = instance
        instance.perform(NSSelectorFromString("setDelegate:"), with: self)
        instance.perform(NSSelectorFromString("startBrowsing"))
    }

    func stop() {
        completion = nil
        session?.perform(NSSelectorFromString("stopBrowsing"))
        session?.perform(NSSelectorFromString("setDelegate:"), with: nil)
        session = nil
    }

    // The OS invokes this delegate on an XPC queue. Objects are retained only
    // for forwarding to MainActor; all activation/lifecycle work runs there.
    private struct Devices: @unchecked Sendable { let values: [NSObject] }
    @objc(session:updatedFoundDevices:)
    nonisolated func foundDevices(_ sender: NSObject, devices: [NSObject]) {
        let transfer = Devices(values: devices)
        Task { @MainActor [weak self] in self?.activateMatch(in: transfer.values) }
    }

    private func activateMatch(in devices: [NSObject]) {
        guard let session, completion != nil, !requested else { return }
        let nameSelector = NSSelectorFromString("deviceName")
        let matches = devices.filter {
            $0.responds(to: nameSelector)
                && ($0.perform(nameSelector)?.takeUnretainedValue() as? String) == target
        }
        // Zero matches is normal while the phone is away. Keep browsing until
        // it appears or this bounded attempt expires, then let backoff retry.
        guard !matches.isEmpty else { return }
        guard matches.count == 1 else {
            completion?(.failure(.ambiguousTarget))
            return
        }
        requested = true
        let selector = NSSelectorFromString("enableRemoteHotspotForDevice:withCompletionHandler:")
        typealias Reply = @convention(block) (AnyObject?, AnyObject?) -> Void
        typealias Enable = @convention(c) (AnyObject, Selector, AnyObject, Reply) -> Void
        let reply: Reply = { [weak self] info, error in
            // Transfer only the explicitly authorized target's invitation.
            // Do not log the object: its description includes a password.
            let nameSelector = NSSelectorFromString("name")
            let passwordSelector = NSSelectorFromString("password")
            let invitation: MacHotspotInvitation?
            if error == nil, let object = info as? NSObject,
               object.responds(to: nameSelector), object.responds(to: passwordSelector),
               let name = object.perform(nameSelector)?.takeUnretainedValue() as? String,
               let password = object.perform(passwordSelector)?.takeUnretainedValue() as? String {
                invitation = MacHotspotInvitation(ssid: name, password: password)
            } else { invitation = nil }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let invitation, invitation.ssid == self.target, !invitation.password.isEmpty {
                    self.completion?(.success(invitation))
                } else { self.completion?(.failure(.rejected)) }
            }
        }
        let enable = unsafeBitCast(session.method(for: selector), to: Enable.self)
        enable(session, selector, matches[0], reply)
    }

    private static func hasMethod(_ type: AnyClass, _ name: String, arguments: UInt32) -> Bool {
        guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)),
              method_getNumberOfArguments(method) == arguments else { return false }
        let result = method_copyReturnType(method)
        defer { free(result) }
        guard String(cString: result) == "v" else { return false }
        for index in 2..<arguments {
            guard let argument = method_copyArgumentType(method, index) else { return false }
            defer { free(argument) }
            let expected = name.hasPrefix("enableRemote") && index == 3 ? "@?" : "@"
            guard String(cString: argument) == expected else { return false }
        }
        return true
    }
}


private enum CoreWLANHotspotAssociator {
    private static let logger = Logger(subsystem: "com.tidux.CodexWatchPet.mac", category: "hotspot-recovery")
    static func associate(_ invitation: MacHotspotInvitation) async throws {
        // CoreWLAN scan/association are blocking. Keep them off MainActor and
        // propagate cancellation so no association starts after a cancelled scan.
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let interface = CWWiFiClient.shared().interface() else {
                throw MacBackgroundHotspotError.associationFailed
            }
            for attempt in 0..<6 {
                try Task.checkCancellation()
                do {
                    var networks = try interface.scanForNetworks(withName: invitation.ssid, includeHidden: true)
                    // An awakened Instant Hotspot may be absent from a directed
                    // probe while present in the system's normal scan. Broaden
                    // discovery, but still associate only the exact target.
                    if networks.isEmpty {
                        try Task.checkCancellation()
                        networks = try interface.scanForNetworks(withName: nil, includeHidden: true)
                    }
                    logger.notice("directed scan attempt=\(attempt) count=\(networks.count) matching=\(networks.filter { $0.ssid == invitation.ssid }.count)")
                    if !networks.isEmpty, networks.allSatisfy({ $0.ssid == nil }) {
                        throw MacBackgroundHotspotError.locationPermissionRequired
                    }
                    if let network = networks.filter({ $0.ssid == invitation.ssid })
                        .max(by: { $0.rssiValue < $1.rssiValue }) {
                        try Task.checkCancellation()
                        try interface.associate(to: network, password: invitation.password)
                        try Task.checkCancellation()
                        return
                    }
                } catch is CancellationError { throw CancellationError() }
                catch MacBackgroundHotspotError.locationPermissionRequired {
                    throw MacBackgroundHotspotError.locationPermissionRequired
                } catch {
                    logger.notice("CoreWLAN association/scan failed code=\((error as NSError).code)")
                    // Raw system errors may contain network metadata. Only
                    // publish the safe failure below, never the invitation.
                }
                if attempt < 5 { try await Task.sleep(for: .seconds(2)) }
            }
            throw MacBackgroundHotspotError.associationFailed
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}
