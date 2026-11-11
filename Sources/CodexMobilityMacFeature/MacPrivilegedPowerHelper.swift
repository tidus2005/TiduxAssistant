import Darwin
import Foundation

/// Installs one narrowly scoped root LaunchDaemon for the current macOS user.
///
/// The administrator prompt is used only while installing or upgrading the
/// fixed daemon definition. Later requests are written by the owning user to a
/// private control directory. The daemon accepts only narrowly allowlisted power
/// operations and never evaluates request data as shell source.
struct MacPrivilegedPowerHelper: Sendable {
    enum Command: Equatable, Sendable {
        case setSleepDisabled(Bool)
        case beginLease(baselineEnabled: Bool, expiresAt: Date)
        case renewLease(expiresAt: Date)
        case endLease
        case setBatteryDisplaySleep(minutes: Int)
        case setPowerAdapterDisplaySleep(minutes: Int)
        /// `nil` disables the password requirement; a value enables it with that delay.
        case setScreenLockDelay(seconds: Int?)
    }

    static let protocolVersion = "3"
    static let maximumLeaseSeconds: Int64 = 4 * 60 * 60 + 5 * 60
    private static let commandTimeout: TimeInterval = 15
    private static let installationTimeout: TimeInterval = 180
    private static let pollIntervalMicroseconds: useconds_t = 100_000

    let userID: uid_t

    init(userID: uid_t = getuid()) {
        self.userID = userID
    }

    func execute(_ command: Command) throws {
        try ensurePrivateControlDirectory()
        try ensureInstalled()

        let requestID = UUID().uuidString.lowercased()
        let payload = Self.requestPayload(
            requestID: requestID,
            command: command
        )
        try writeRequest(payload)
        try waitForResult(requestID: requestID)
    }

    var hasLeaseState: Bool {
        FileManager.default.fileExists(atPath: Self.leaseStatePath(userID: userID))
    }

    static func requestPayload(requestID: String, command: Command) -> String {
        switch command {
        case .setSleepDisabled(let enabled):
            return "\(protocolVersion)|\(requestID)|set|\(enabled ? 1 : 0)|0\n"
        case .beginLease(let baselineEnabled, let expiresAt):
            let deadline = Int64(expiresAt.timeIntervalSince1970.rounded(.up))
            return "\(protocolVersion)|\(requestID)|lease-start|"
                + "\(baselineEnabled ? 1 : 0)|\(deadline)\n"
        case .renewLease(let expiresAt):
            let deadline = Int64(expiresAt.timeIntervalSince1970.rounded(.up))
            return "\(protocolVersion)|\(requestID)|lease-renew|0|\(deadline)\n"
        case .endLease:
            return "\(protocolVersion)|\(requestID)|lease-stop|0|0\n"
        case .setBatteryDisplaySleep(let minutes):
            return "\(protocolVersion)|\(requestID)|display-b|\(minutes)|0\n"
        case .setPowerAdapterDisplaySleep(let minutes):
            return "\(protocolVersion)|\(requestID)|display-c|\(minutes)|0\n"
        case .setScreenLockDelay(let seconds):
            return "\(protocolVersion)|\(requestID)|screen-lock|\(seconds.map(String.init) ?? "off")|0\n"
        }
    }

    static func launchDaemonLabel(userID: uid_t) -> String {
        "com.tidux.codex-watch-pet.power-helper-\(userID)"
    }

    static func launchDaemonPlistPath(userID: uid_t) -> String {
        "/Library/LaunchDaemons/\(launchDaemonLabel(userID: userID)).plist"
    }

    static func controlDirectoryPath(userID: uid_t) -> String {
        "/private/var/tmp/com.tidux.codex-watch-pet.power-helper-\(userID)"
    }

    static func requestPath(userID: uid_t) -> String {
        "\(controlDirectoryPath(userID: userID))/request"
    }

    static func stateDirectoryPath() -> String {
        "/Library/Application Support/CodexWatchPetPowerHelper"
    }

    static func leaseStatePath(userID: uid_t) -> String {
        "\(stateDirectoryPath())/lease-\(userID)"
    }

    static func resultPath(userID: uid_t) -> String {
        "\(stateDirectoryPath())/result-\(userID)"
    }

    static func launchDaemonPlist(userID: uid_t) -> String {
        let daemonCommand = xmlEscaped(helperDaemonCommand(userID: userID))
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchDaemonLabel(userID: userID))</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>-c</string>
                <string>\(daemonCommand)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>ThrottleInterval</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
    }

    static func administratorInstallationScript(userID: uid_t) -> String {
        let command = administratorInstallationCommand(userID: userID)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" "
            + "with prompt \"首次安装或升级 Tidux助手的系统组件；授权一次后，后续合盖与自动锁屏设置不再重复询问密码。\" "
            + "with administrator privileges"
    }

    static func administratorInstallationCommand(userID: uid_t) -> String {
        let label = launchDaemonLabel(userID: userID)
        let plistPath = launchDaemonPlistPath(userID: userID)
        let temporaryPlistPath = "\(plistPath).installing"
        let encodedPlist = Data(launchDaemonPlist(userID: userID).utf8)
            .base64EncodedString()
        let stateDirectory = stateDirectoryPath()
        return """
        label='\(label)'; plist='\(plistPath)'; temporary_plist='\(temporaryPlistPath)'; \
        state_dir='\(stateDirectory)'; \
        /bin/launchctl bootout "system/$label" >/dev/null 2>&1 || true; \
        /bin/rm -f "$temporary_plist"; \
        if ! /bin/mkdir -p "$state_dir" \
        || ! /usr/sbin/chown root:wheel "$state_dir" \
        || ! /bin/chmod 0755 "$state_dir"; then exit 1; fi; \
        if ! /usr/bin/printf %s '\(encodedPlist)' \
        | /usr/bin/base64 -D >"$temporary_plist"; then \
        /bin/rm -f "$temporary_plist"; exit 1; fi; \
        if ! /usr/sbin/chown root:wheel "$temporary_plist" \
        || ! /bin/chmod 0644 "$temporary_plist" \
        || ! /bin/mv -f "$temporary_plist" "$plist"; then \
        /bin/rm -f "$temporary_plist"; exit 1; fi; \
        if ! /bin/launchctl bootstrap system "$plist"; then exit 1; fi; \
        /bin/launchctl print "system/$label" >/dev/null 2>&1
        """
    }

    static func helperDaemonCommand(userID: uid_t) -> String {
        let controlDirectory = controlDirectoryPath(userID: userID)
        let request = requestPath(userID: userID)
        let stateDirectory = stateDirectoryPath()
        let leaseState = leaseStatePath(userID: userID)
        let result = resultPath(userID: userID)
        return """
        control_dir='\(controlDirectory)'; request_path='\(request)'; \
        state_dir='\(stateDirectory)'; lease_state='\(leaseState)'; \
        result_path='\(result)'; owner_uid='\(userID)'; protocol='\(protocolVersion)'; \
        max_lease='\(maximumLeaseSeconds)'; \
        write_result() { \
        result_id="$1"; result_status="$2"; result_detail="$3"; \
        result_tmp="$state_dir/.result-\(userID).$$"; \
        /usr/bin/printf '%s|%s|%s\\n' "$result_id" "$result_status" "$result_detail" >"$result_tmp" \
        && /bin/chmod 0644 "$result_tmp" \
        && /bin/mv -f "$result_tmp" "$result_path"; \
        }; \
        restore_corrupt_lease() { \
        /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true; \
        /bin/rm -f "$lease_state"; \
        }; \
        check_lease_deadline() { \
        [ -f "$lease_state" ] || return 0; \
        IFS=' ' read -r saved_baseline saved_deadline <"$lease_state" || { restore_corrupt_lease; return 0; }; \
        case "$saved_baseline" in 0|1) ;; *) restore_corrupt_lease; return 0 ;; esac; \
        case "$saved_deadline" in ''|*[!0-9]*) restore_corrupt_lease; return 0 ;; esac; \
        now="$(/bin/date +%s)"; \
        if [ "$now" -ge "$saved_deadline" ]; then \
        if /usr/bin/pmset -a disablesleep "$saved_baseline" >/dev/null 2>&1; then \
        /bin/rm -f "$lease_state"; fi; fi; \
        }; \
        check_lease_deadline; \
        if [ -f "$lease_state" ]; then \
        /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 || true; fi; \
        while true; do \
        check_lease_deadline; \
        if [ ! -e "$request_path" ]; then /bin/sleep 0.25; continue; fi; \
        if [ -L "$request_path" ] || [ ! -f "$request_path" ]; then \
        /bin/rm -f "$request_path"; /bin/sleep 0.25; continue; fi; \
        request_owner="$(/usr/bin/stat -f %u "$request_path" 2>/dev/null || /usr/bin/printf invalid)"; \
        if [ "$request_owner" != "$owner_uid" ]; then \
        /bin/rm -f "$request_path"; /bin/sleep 0.25; continue; fi; \
        IFS='|' read -r request_protocol request_id request_command request_value request_deadline <"$request_path"; \
        /bin/rm -f "$request_path"; \
        case "$request_id" in ''|*[!0-9A-Fa-f-]*) /bin/sleep 0.25; continue ;; esac; \
        if [ "$request_protocol" != "$protocol" ]; then write_result "$request_id" error protocol; continue; fi; \
        case "$request_command" in \
        set) \
        case "$request_value" in 0|1) ;; *) write_result "$request_id" error invalid-value; continue ;; esac; \
        if [ -f "$lease_state" ]; then write_result "$request_id" error lease-active; continue; fi; \
        if /usr/bin/pmset -a disablesleep "$request_value" >/dev/null 2>&1; then \
        write_result "$request_id" ok set; else write_result "$request_id" error pmset; fi \
        ;; \
        lease-start) \
        case "$request_value" in 0|1) ;; *) write_result "$request_id" error invalid-value; continue ;; esac; \
        case "$request_deadline" in ''|*[!0-9]*) write_result "$request_id" error invalid-deadline; continue ;; esac; \
        now="$(/bin/date +%s)"; latest="$((now + max_lease))"; \
        if [ "$request_deadline" -le "$now" ] || [ "$request_deadline" -gt "$latest" ]; then \
        write_result "$request_id" error invalid-deadline; continue; fi; \
        if [ -f "$lease_state" ]; then write_result "$request_id" error lease-active; continue; fi; \
        lease_tmp="$state_dir/.lease-\(userID).$$"; \
        if /usr/bin/printf '%s %s\\n' "$request_value" "$request_deadline" >"$lease_tmp" \
        && /bin/chmod 0600 "$lease_tmp" \
        && /bin/mv -f "$lease_tmp" "$lease_state" \
        && /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then \
        write_result "$request_id" ok lease-start; \
        else /bin/rm -f "$lease_tmp" "$lease_state"; write_result "$request_id" error lease-start; fi \
        ;; \
        lease-renew) \
        case "$request_deadline" in ''|*[!0-9]*) write_result "$request_id" error invalid-deadline; continue ;; esac; \
        now="$(/bin/date +%s)"; latest="$((now + max_lease))"; \
        if [ "$request_deadline" -le "$now" ] || [ "$request_deadline" -gt "$latest" ]; then \
        write_result "$request_id" error invalid-deadline; continue; fi; \
        if [ ! -f "$lease_state" ]; then write_result "$request_id" error lease-missing; continue; fi; \
        IFS=' ' read -r saved_baseline saved_deadline <"$lease_state" || { write_result "$request_id" error lease-missing; continue; }; \
        case "$saved_baseline" in 0|1) ;; *) write_result "$request_id" error lease-missing; continue ;; esac; \
        lease_tmp="$state_dir/.lease-\(userID).$$"; \
        if /usr/bin/printf '%s %s\\n' "$saved_baseline" "$request_deadline" >"$lease_tmp" \
        && /bin/chmod 0600 "$lease_tmp" \
        && /bin/mv -f "$lease_tmp" "$lease_state"; then \
        write_result "$request_id" ok lease-renew; \
        else /bin/rm -f "$lease_tmp"; write_result "$request_id" error lease-renew; fi \
        ;; \
        lease-stop) \
        if [ -f "$lease_state" ]; then \
        IFS=' ' read -r saved_baseline saved_deadline <"$lease_state" || saved_baseline=0; \
        case "$saved_baseline" in 0|1) ;; *) saved_baseline=0 ;; esac; \
        if /usr/bin/pmset -a disablesleep "$saved_baseline" >/dev/null 2>&1; then \
        /bin/rm -f "$lease_state"; write_result "$request_id" ok lease-stop; \
        else write_result "$request_id" error pmset; fi; \
        else write_result "$request_id" ok lease-stop; fi \
        ;; \
        display-b) \
        case "$request_value" in ''|*[!0-9]*) write_result "$request_id" error invalid-value; continue ;; esac; \
        if [ "$request_value" -gt 300 ]; then write_result "$request_id" error invalid-value; continue; fi; \
        if /usr/bin/pmset -b displaysleep "$request_value" >/dev/null 2>&1; then \
        write_result "$request_id" ok display-b; else write_result "$request_id" error pmset; fi \
        ;; \
        display-c) \
        case "$request_value" in ''|*[!0-9]*) write_result "$request_id" error invalid-value; continue ;; esac; \
        if [ "$request_value" -gt 300 ]; then write_result "$request_id" error invalid-value; continue; fi; \
        if /usr/bin/pmset -c displaysleep "$request_value" >/dev/null 2>&1; then \
        write_result "$request_id" ok display-c; else write_result "$request_id" error pmset; fi \
        ;; \
        screen-lock) \
        case "$request_value" in off|0|5|60|300|900|3600|14400|28800) ;; \
        *) write_result "$request_id" error invalid-value; continue ;; esac; \
        if [ "$request_value" = off ]; then screen_lock_value=off; \
        elif [ "$request_value" = 0 ]; then screen_lock_value=immediate; \
        else screen_lock_value="$request_value"; fi; \
        if /usr/sbin/sysadminctl -screenLock "$screen_lock_value" >/dev/null 2>&1; then \
        write_result "$request_id" ok screen-lock; else write_result "$request_id" error screen-lock; fi \
        ;; \
        *) write_result "$request_id" error command ;; \
        esac; \
        done
        """
    }

    private func ensureInstalled() throws {
        if try isInstalledAndRunning() { return }

        let source = Self.administratorInstallationScript(userID: userID)
        let result: ProcessResult
        do {
            result = try Self.run(
                "/usr/bin/osascript",
                arguments: ["-e", source],
                timeout: Self.installationTimeout
            )
        } catch let error as MacSystemPowerPolicyError {
            throw error
        } catch {
            throw MacSystemPowerPolicyError.authorizationFailed
        }
        guard result.exitCode == 0 else {
            if result.output.localizedCaseInsensitiveContains("User canceled")
                || result.output.contains("(-128)") {
                throw MacSystemPowerPolicyError.authorizationCancelled
            }
            throw MacSystemPowerPolicyError.authorizationFailed
        }
        guard try isInstalledAndRunning() else {
            throw MacSystemPowerPolicyError.commandFailed(
                "系统级合盖助手安装后未能启动。"
            )
        }
    }

    private func isInstalledAndRunning() throws -> Bool {
        let plistPath = Self.launchDaemonPlistPath(userID: userID)
        var status = stat()
        guard lstat(plistPath, &status) == 0 else {
            if errno == ENOENT { return false }
            throw MacSystemPowerPolicyError.commandFailed(
                "无法检查系统级合盖助手。"
            )
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == 0,
              status.st_gid == 0,
              status.st_mode & mode_t(0o022) == 0 else {
            return false
        }
        let installed = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        guard installed == Data(Self.launchDaemonPlist(userID: userID).utf8) else {
            return false
        }
        let launchState = try Self.run(
            "/bin/launchctl",
            arguments: ["print", "system/\(Self.launchDaemonLabel(userID: userID))"],
            timeout: Self.commandTimeout
        )
        return launchState.exitCode == 0
    }

    private func ensurePrivateControlDirectory() throws {
        let path = Self.controlDirectoryPath(userID: userID)
        if mkdir(path, mode_t(0o700)) != 0, errno != EEXIST {
            throw MacSystemPowerPolicyError.unsafeConfiguration(
                "无法创建系统级合盖助手的私有控制目录。"
            )
        }
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == userID,
              status.st_mode & mode_t(0o0777) == mode_t(0o0700) else {
            throw MacSystemPowerPolicyError.unsafeConfiguration(
                "系统级合盖助手控制目录的所有者或权限不安全，已拒绝执行。"
            )
        }
    }

    private func writeRequest(_ payload: String) throws {
        let directory = Self.controlDirectoryPath(userID: userID)
        var template = Array("\(directory)/.request.XXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw MacSystemPowerPolicyError.commandFailed("无法创建系统助手请求。")
        }
        let temporaryPath = Self.stringFromNullTerminatedBytes(template)
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { unlink(temporaryPath) }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw MacSystemPowerPolicyError.commandFailed("无法保护系统助手请求。")
        }
        let data = Data(payload.utf8)
        try Self.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0,
              rename(temporaryPath, Self.requestPath(userID: userID)) == 0 else {
            throw MacSystemPowerPolicyError.commandFailed("无法提交系统助手请求。")
        }
        shouldRemove = false
    }

    private func waitForResult(requestID: String) throws {
        let deadline = Date().addingTimeInterval(Self.commandTimeout)
        let url = URL(fileURLWithPath: Self.resultPath(userID: userID))
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8),
               let result = Self.parseResult(text),
               result.requestID == requestID {
                guard result.status == "ok" else {
                    let message = switch result.detail {
                    case "lease-active": "定时合盖租约仍在运行，不能修改基础策略。"
                    case "invalid-deadline": "系统助手拒绝了不安全的合盖租约期限。"
                    case "invalid-value": "系统助手拒绝了不在允许范围内的锁屏配置。"
                    case "screen-lock": "macOS 拒绝修改锁屏密码等待时间。"
                    default: "系统级合盖助手执行失败（\(result.detail)）。"
                    }
                    throw MacSystemPowerPolicyError.commandFailed(message)
                }
                return
            }
            usleep(Self.pollIntervalMicroseconds)
        }
        throw MacSystemPowerPolicyError.commandTimedOut
    }

    private static func parseResult(
        _ text: String
    ) -> (requestID: String, status: String, detail: String)? {
        let components = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        let requestID = String(components[0])
        let status = String(components[1])
        let detail = String(components[2])
        guard !requestID.isEmpty,
              ["ok", "error"].contains(status),
              !detail.isEmpty,
              detail.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
            return nil
        }
        return (requestID, status, detail)
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw MacSystemPowerPolicyError.commandFailed("无法写入系统助手请求。")
                }
                guard count > 0 else {
                    throw MacSystemPowerPolicyError.commandFailed("系统助手请求写入中断。")
                }
                offset += count
            }
        }
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        var template = Array(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-power-helper.XXXXXX")
                .path
                .utf8CString
        )
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw MacSystemPowerPolicyError.commandFailed("无法创建系统助手输出文件。")
        }
        let outputPath = stringFromNullTerminatedBytes(template)
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            unlink(outputPath)
            throw MacSystemPowerPolicyError.commandFailed("无法保护系统助手输出文件。")
        }
        let outputHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? outputHandle.close()
            unlink(outputPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < terminationDeadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw MacSystemPowerPolicyError.commandTimedOut
        }
        process.waitUntilExit()
        try outputHandle.synchronize()
        try outputHandle.close()
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        return ProcessResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private static func stringFromNullTerminatedBytes(_ bytes: [CChar]) -> String {
        String(
            decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
