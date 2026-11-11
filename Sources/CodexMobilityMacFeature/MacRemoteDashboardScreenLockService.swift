import Darwin
import Foundation

struct MacScreenLockConfiguration: Equatable, Sendable {
    var batteryDisplaySleepMinutes: Int
    var powerAdapterDisplaySleepMinutes: Int
    var requiresPassword: Bool
    var passwordDelaySeconds: Int?
}

protocol MacScreenLockSettingsBackend: Sendable {
    func loadConfiguration() async throws -> MacScreenLockConfiguration
    func setDisplaySleep(batteryMinutes: Int, powerAdapterMinutes: Int) async throws
    func setScreenLockDelay(seconds: Int?) async throws
}

actor MacRemoteDashboardScreenLockService {
    static let allowedDisplaySleepMinutes: Set<Int> = [
        0, 1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 150, 180
    ]
    static let allowedPasswordDelaySeconds: Set<Int> = [
        0, 5, 60, 300, 900, 3_600, 14_400, 28_800
    ]

    private let backend: any MacScreenLockSettingsBackend
    private let lidCloseLockController: MacLidCloseLockController?

    init(
        backend: any MacScreenLockSettingsBackend = LocalMacScreenLockSettingsBackend(),
        lidCloseLockController: MacLidCloseLockController? = nil
    ) {
        self.backend = backend
        self.lidCloseLockController = lidCloseLockController
    }

    func load() async -> MacRemoteDashboardScreenLockSnapshot {
        let lidCloseLock = await lidCloseLockController?.snapshot()
        do {
            return Self.snapshot(from: try await backend.loadConfiguration())
                .merging(lidCloseLock: lidCloseLock)
        } catch {
            return MacRemoteDashboardScreenLockSnapshot
                .unavailable(error.localizedDescription)
                .merging(lidCloseLock: lidCloseLock)
        }
    }

    func apply(
        _ request: MacRemoteDashboardScreenLockUpdateRequest
    ) async -> MacRemoteDashboardScreenLockResponse {
        guard Self.allowedDisplaySleepMinutes.contains(
            request.batteryDisplaySleepMinutes
        ), Self.allowedDisplaySleepMinutes.contains(
            request.powerAdapterDisplaySleepMinutes
        ), request.passwordDelaySeconds.map(Self.allowedPasswordDelaySeconds.contains) != false else {
            return failure(
                "锁屏时间不在允许的安全范围内。",
                fallback: await load()
            )
        }
        if let seconds = request.lidCloseLockDelaySeconds,
           !MacLidCloseLockController.allowedDelaySeconds.contains(seconds) {
            return failure(
                "合盖锁屏时间不在允许的安全范围内。",
                fallback: await load()
            )
        }

        let original: MacScreenLockConfiguration
        do {
            original = try await backend.loadConfiguration()
        } catch {
            return failure(error.localizedDescription, fallback: await load())
        }

        let requestedPasswordConfiguration = MacScreenLockConfiguration(
            batteryDisplaySleepMinutes: original.batteryDisplaySleepMinutes,
            powerAdapterDisplaySleepMinutes: original.powerAdapterDisplaySleepMinutes,
            requiresPassword: request.passwordDelaySeconds != nil,
            passwordDelaySeconds: request.passwordDelaySeconds
        )
        guard Self.hasSamePasswordPolicy(
            requestedPasswordConfiguration,
            as: original
        ) else {
            return failure(
                "“关闭屏幕后需要密码”只能在这台 Mac 的“系统设置 → 锁定屏幕”中修改；显示器与合盖设置尚未更改。",
                fallback: Self.snapshot(from: original).merging(
                    lidCloseLock: await lidCloseLockController?.snapshot()
                )
            )
        }

        let target = MacScreenLockConfiguration(
            batteryDisplaySleepMinutes: request.batteryDisplaySleepMinutes,
            powerAdapterDisplaySleepMinutes: request.powerAdapterDisplaySleepMinutes,
            requiresPassword: original.requiresPassword,
            passwordDelaySeconds: original.passwordDelaySeconds
        )
        let displaySleepChanged =
            target.batteryDisplaySleepMinutes != original.batteryDisplaySleepMinutes
            || target.powerAdapterDisplaySleepMinutes != original.powerAdapterDisplaySleepMinutes

        do {
            if displaySleepChanged {
                try await backend.setDisplaySleep(
                    batteryMinutes: target.batteryDisplaySleepMinutes,
                    powerAdapterMinutes: target.powerAdapterDisplaySleepMinutes
                )
            }
            let verified = try await backend.loadConfiguration()
            guard verified == target else {
                throw MacScreenLockSettingsError.verificationFailed
            }
            try await lidCloseLockController?.updateDelaySeconds(
                request.lidCloseLockDelaySeconds
            )
            let lidCloseLock = await lidCloseLockController?.snapshot()
            let snapshot = Self.snapshot(from: verified)
                .merging(lidCloseLock: lidCloseLock)
            return MacRemoteDashboardScreenLockResponse(
                ok: true,
                message: "显示器休眠时间与合盖锁屏已更新；锁屏密码策略保持不变。",
                settings: snapshot
            )
        } catch {
            let originalError = error
            guard displaySleepChanged else {
                return failure(originalError.localizedDescription, fallback: await load())
            }
            do {
                try await backend.setDisplaySleep(
                    batteryMinutes: original.batteryDisplaySleepMinutes,
                    powerAdapterMinutes: original.powerAdapterDisplaySleepMinutes
                )
                let restored = try await backend.loadConfiguration()
                guard restored == original else {
                    throw MacScreenLockSettingsError.verificationFailed
                }
            } catch {
                let latest = await load()
                return failure(
                    "设置失败：\(originalError.localizedDescription)；原配置回滚失败：\(error.localizedDescription)",
                    fallback: latest
                )
            }
            let lidCloseLock = await lidCloseLockController?.snapshot()
            return failure(
                originalError.localizedDescription,
                fallback: Self.snapshot(from: original).merging(
                    lidCloseLock: lidCloseLock
                )
            )
        }
    }

    private static func hasSamePasswordPolicy(
        _ lhs: MacScreenLockConfiguration,
        as rhs: MacScreenLockConfiguration
    ) -> Bool {
        lhs.requiresPassword == rhs.requiresPassword
            && lhs.passwordDelaySeconds == rhs.passwordDelaySeconds
    }

    private func failure(
        _ message: String,
        fallback: MacRemoteDashboardScreenLockSnapshot
    ) -> MacRemoteDashboardScreenLockResponse {
        MacRemoteDashboardScreenLockResponse(
            ok: false,
            message: message,
            settings: fallback
        )
    }

    static func snapshot(
        from configuration: MacScreenLockConfiguration
    ) -> MacRemoteDashboardScreenLockSnapshot {
        let battery = displaySleepDescription(configuration.batteryDisplaySleepMinutes)
        let power = displaySleepDescription(configuration.powerAdapterDisplaySleepMinutes)
        let password: String
        if !configuration.requiresPassword {
            password = "当前未要求密码"
        } else if let delay = configuration.passwordDelaySeconds {
            password = passwordDelayDescription(delay)
        } else {
            password = "密码等待时间未知"
        }
        return MacRemoteDashboardScreenLockSnapshot(
            batteryDisplaySleepMinutes: configuration.batteryDisplaySleepMinutes,
            powerAdapterDisplaySleepMinutes: configuration.powerAdapterDisplaySleepMinutes,
            requiresPassword: configuration.requiresPassword,
            passwordDelaySeconds: configuration.passwordDelaySeconds,
            isConfigurable: true,
            status: "电池 \(battery) · 电源 \(power) · \(password)"
        )
    }

    private static func displaySleepDescription(_ minutes: Int) -> String {
        minutes == 0 ? "永不" : "\(minutes) 分钟"
    }

    private static func passwordDelayDescription(_ seconds: Int) -> String {
        switch seconds {
        case 0: "立即需要密码"
        case 5: "5 秒后需要密码"
        case 60: "1 分钟后需要密码"
        case 300: "5 分钟后需要密码"
        case 900: "15 分钟后需要密码"
        case 3_600: "1 小时后需要密码"
        case 14_400: "4 小时后需要密码"
        case 28_800: "8 小时后需要密码"
        default: "\(seconds) 秒后需要密码"
        }
    }
}

actor LocalMacScreenLockSettingsBackend: MacScreenLockSettingsBackend {
    private static let commandTimeout: TimeInterval = 15
    private let helper: MacPrivilegedPowerHelper

    init(userID: uid_t = getuid()) {
        self.helper = MacPrivilegedPowerHelper(userID: userID)
    }

    func loadConfiguration() async throws -> MacScreenLockConfiguration {
        let pmset = try Self.run(
            "/usr/bin/pmset",
            arguments: ["-g", "custom"]
        )
        guard pmset.exitCode == 0,
              let displaySleep = Self.parseDisplaySleep(pmset.output),
              let battery = displaySleep.battery,
              let powerAdapter = displaySleep.powerAdapter else {
            throw MacScreenLockSettingsError.unreadableDisplaySleep
        }

        let screenLock = try Self.run(
            "/usr/sbin/sysadminctl",
            arguments: ["-screenLock", "status"]
        )
        guard screenLock.exitCode == 0,
              let password = Self.parseScreenLockStatus(screenLock.output) else {
            throw MacScreenLockSettingsError.unreadablePasswordDelay
        }

        return MacScreenLockConfiguration(
            batteryDisplaySleepMinutes: battery,
            powerAdapterDisplaySleepMinutes: powerAdapter,
            requiresPassword: password.requiresPassword,
            passwordDelaySeconds: password.delaySeconds
        )
    }

    func setDisplaySleep(
        batteryMinutes: Int,
        powerAdapterMinutes: Int
    ) async throws {
        try helper.execute(.setBatteryDisplaySleep(minutes: batteryMinutes))
        try helper.execute(.setPowerAdapterDisplaySleep(minutes: powerAdapterMinutes))
    }

    func setScreenLockDelay(seconds: Int?) async throws {
        try helper.execute(.setScreenLockDelay(seconds: seconds))
    }

    static func parseDisplaySleep(
        _ output: String
    ) -> (battery: Int?, powerAdapter: Int?)? {
        enum Section {
            case battery
            case powerAdapter
        }
        var section: Section?
        var battery: Int?
        var powerAdapter: Int?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.caseInsensitiveCompare("Battery Power:") == .orderedSame {
                section = .battery
                continue
            }
            if line.caseInsensitiveCompare("AC Power:") == .orderedSame {
                section = .powerAdapter
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  fields[0].caseInsensitiveCompare("displaysleep") == .orderedSame,
                  let value = Int(fields[1]),
                  (0...300).contains(value) else {
                continue
            }
            switch section {
            case .battery: battery = value
            case .powerAdapter: powerAdapter = value
            case nil: break
            }
        }
        guard battery != nil || powerAdapter != nil else { return nil }
        return (battery, powerAdapter)
    }

    static func parseScreenLockStatus(
        _ output: String
    ) -> (requiresPassword: Bool, delaySeconds: Int?)? {
        let normalized = output.lowercased()
        if normalized.contains("screenlock is off") {
            return (false, nil)
        }
        if normalized.contains("screenlock delay is immediate") {
            return (true, 0)
        }
        guard let start = normalized.range(of: "screenlock delay is "),
              let end = normalized.range(
                of: " seconds",
                range: start.upperBound..<normalized.endIndex
              ),
              let seconds = Int(normalized[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...28_800).contains(seconds) else {
            return nil
        }
        return (true, seconds)
    }

    private static func run(
        _ executable: String,
        arguments: [String]
    ) throws -> ProcessResult {
        var template = Array(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-screen-lock.XXXXXX")
                .path
                .utf8CString
        )
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw MacScreenLockSettingsError.commandFailed
        }
        let outputPath = String(
            decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            unlink(outputPath)
            throw MacScreenLockSettingsError.commandFailed
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlink(outputPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            throw MacScreenLockSettingsError.commandFailed
        }

        let deadline = Date().addingTimeInterval(commandTimeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw MacScreenLockSettingsError.commandTimedOut
        }
        process.waitUntilExit()
        try handle.synchronize()
        try handle.close()
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        return ProcessResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}

private enum MacScreenLockSettingsError: LocalizedError {
    case unreadableDisplaySleep
    case unreadablePasswordDelay
    case verificationFailed
    case commandFailed
    case commandTimedOut

    var errorDescription: String? {
        switch self {
        case .unreadableDisplaySleep:
            "无法读取 macOS 的电池与电源自动锁屏时间。"
        case .unreadablePasswordDelay:
            "无法读取 macOS 的锁屏密码等待时间。"
        case .verificationFailed:
            "macOS 回读值与目标显示器配置不一致，原配置已恢复。"
        case .commandFailed:
            "macOS 锁屏配置命令执行失败。"
        case .commandTimedOut:
            "macOS 锁屏配置命令执行超时。"
        }
    }
}
