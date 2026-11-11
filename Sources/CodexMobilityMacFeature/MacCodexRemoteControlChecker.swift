import Darwin
import Foundation

public enum MacCodexRemoteControlReadiness: Equatable, Sendable {
    case notChecked
    case connected
    // Kept for source compatibility; a competing instance is not online proof.
    case connectedByExistingInstance
    case unavailable(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case .notChecked: "尚未检查 Mac 远控服务"
        case .connected: "Mac 远控服务在线 · 手机任务可用性需单独验证"
        case .connectedByExistingInstance: "检测到远控实例；实际连接尚未确认"
        case .unavailable(let message): "Mac 远控待恢复：\(message)"
        }
    }
}

public protocol MacCodexRemoteControlChecking: Sendable {
    func ensureConnected(timeout: TimeInterval) async -> MacCodexRemoteControlReadiness
}

/// Read-only query of the running official daemon through its local control
/// socket. `proxy` transports WebSocket bytes; it never starts an app-server,
/// enables remote control, enrolls another host, or changes VPN/network policy.
public struct ProcessMacCodexRemoteControlChecker: MacCodexRemoteControlChecking {
    public static let defaultTimeout: TimeInterval = 8
    private let executableCandidates: [String]

    public init(executableCandidates: [String] = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex"
    ]) {
        self.executableCandidates = executableCandidates
    }

    public func ensureConnected(timeout: TimeInterval = Self.defaultTimeout) async -> MacCodexRemoteControlReadiness {
        let candidates = executableCandidates
        let timeout = timeout.isFinite ? max(timeout, 0.1) : Self.defaultTimeout
        let cancellation = MacRemoteProbeCancellation()
        let worker = Task.detached(priority: .utility) {
            Self.run(candidates: candidates, timeout: timeout, cancellation: cancellation)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    private static func run(candidates: [String], timeout: TimeInterval,
                            cancellation: MacRemoteProbeCancellation) -> MacCodexRemoteControlReadiness {
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return .unavailable("未找到官方 Codex CLI。")
        }
        guard !cancellation.isCancelled else { return .unavailable("检查已取消。") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "proxy"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        defer { stop(process, input: input) }

        var buffer = Data()
        var discardedErrors = Data()
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let deadline = Date().addingTimeInterval(timeout)
        var upgraded = false
        var initialized = false
        var fragments = Data()
        do {
            try process.run()
            makeNonblocking(output.fileHandleForReading)
            makeNonblocking(errors.fileHandleForReading)
            try input.fileHandleForWriting.write(contentsOf: MacCodexControlWebSocket.upgradeRequest(key: key))
            while Date() < deadline, !cancellation.isCancelled {
                try drain(output.fileHandleForReading, into: &buffer)
                try drain(errors.fileHandleForReading, into: &discardedErrors)
                // Never parse stderr or a competing-server HTTP 409 as success.
                discardedErrors.removeAll(keepingCapacity: true)
                if !upgraded, let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = Data(buffer[..<end.lowerBound])
                    try MacCodexControlWebSocket.validateUpgrade(header, key: key)
                    buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                    upgraded = true
                    try send([
                        "id": 1, "method": "initialize", "params": [
                            "clientInfo": ["name": "codex-watch-pet-readonly", "version": "1.0"],
                            "capabilities": ["experimentalApi": true]
                        ]
                    ], to: input.fileHandleForWriting)
                }
                if upgraded {
                    while let frame = try MacCodexControlWebSocket.decodeServerFrame(from: &buffer) {
                        switch frame.opcode {
                        case 0x8: return .unavailable("官方本地控制连接已关闭。")
                        case 0x9:
                            try input.fileHandleForWriting.write(contentsOf:
                                MacCodexControlWebSocket.encodeClientFrame(opcode: 0xA, payload: frame.payload))
                            continue
                        case 0xA: continue
                        case 0x1:
                            guard fragments.isEmpty else { throw MacCodexControlWebSocket.Failure.invalidFrame }
                            fragments = frame.payload
                        case 0x0:
                            guard !fragments.isEmpty else { throw MacCodexControlWebSocket.Failure.invalidFrame }
                            fragments.append(frame.payload)
                        default: throw MacCodexControlWebSocket.Failure.invalidFrame
                        }
                        guard fragments.count <= MacCodexControlWebSocket.maximumBytes else {
                            throw MacCodexControlWebSocket.Failure.tooLarge
                        }
                        guard frame.isFinal else { continue }
                        let payload = fragments
                        fragments.removeAll(keepingCapacity: true)
                        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                        let id = object["id"] as? Int
                        if id == 1, !initialized {
                            guard object["result"] != nil else {
                                return .unavailable("现有 Codex 服务不支持本次只读检查。")
                            }
                            initialized = true
                            try send(["method": "initialized"], to: input.fileHandleForWriting)
                            try send(["id": 2, "method": "remoteControl/status/read", "params": NSNull()],
                                     to: input.fileHandleForWriting)
                        } else if id == 2, initialized {
                            guard let result = object["result"] as? [String: Any],
                                  let status = result["status"] as? String else {
                                return .unavailable("现有 Codex 服务未返回可验证的远控状态。")
                            }
                            switch status {
                            case "connected": return .connected
                            case "connecting": return .unavailable("官方服务正在重连；保留现有实例并等待恢复。")
                            case "disabled": return .unavailable("官方服务未开启远控，请在 Codex 中检查设置。")
                            default: return .unavailable("官方服务返回异常状态，手机端还需重新验证任务。")
                            }
                        }
                    }
                }
                if !process.isRunning { break }
                usleep(20_000)
            }
        } catch {
            return .unavailable("无法读取官方本地控制通道；未启动其他远控实例。")
        }
        return .unavailable(cancellation.isCancelled ? "检查已取消。"
            : "现有远控服务不可读取或检查超时；未创建新实例。")
    }

    private static func send(_ value: [String: Any], to handle: FileHandle) throws {
        try handle.write(contentsOf: MacCodexControlWebSocket.encodeClientFrame(
            opcode: 0x1, payload: JSONSerialization.data(withJSONObject: value)))
    }

    private static func makeNonblocking(_ handle: FileHandle) {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private static func drain(_ handle: FileHandle, into buffer: inout Data) throws {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                if buffer.count > MacCodexControlWebSocket.maximumBytes { throw MacCodexControlWebSocket.Failure.tooLarge }
            } else if count < 0, errno == EINTR { continue }
            else { return }
        }
    }

    private static func stop(_ process: Process, input: Pipe) {
        try? input.fileHandleForWriting.close()
        guard process.processIdentifier > 0 else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
}

private final class MacRemoteProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
