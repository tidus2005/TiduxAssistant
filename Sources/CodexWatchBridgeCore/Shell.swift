import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ShellRunning: Sendable {
    func run(_ executable: String, arguments: [String], input: String?) throws -> ShellResult
}

public struct DetachedProcessLaunch: Sendable {
    public var pid: Int32
    public var logFile: URL

    public init(pid: Int32, logFile: URL) {
        self.pid = pid
        self.logFile = logFile
    }
}

public protocol DetachedProcessLaunching: Sendable {
    func launch(_ executable: String, arguments: [String], logFile: URL) throws -> DetachedProcessLaunch
}

public protocol ProcessControlling: Sendable {
    func terminate(pid: Int32) throws
}

private final class PipeDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func collectedData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public struct ProcessShellRunner: ShellRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String], input: String? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdin: Pipe?
        if input != nil {
            stdin = Pipe()
            process.standardInput = stdin
        } else {
            stdin = nil
        }

        try process.run()

        // A child can block once either pipe buffer fills. Drain both pipes while
        // it is running, then wait for the readers after the process exits.
        let stdoutCollector = PipeDataCollector()
        let stderrCollector = PipeDataCollector()
        let readers = DispatchGroup()

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutCollector.append(stdout.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCollector.append(stderr.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        if let input, let stdin {
            if let data = input.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            try stdin.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        readers.wait()
        let stdoutText = String(data: stdoutCollector.collectedData(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderrCollector.collectedData(), encoding: .utf8) ?? ""
        return ShellResult(status: process.terminationStatus, stdout: stdoutText, stderr: stderrText)
    }
}

public enum ProcessControlError: Error, LocalizedError, Equatable {
    case unsupportedPlatform
    case terminateFailed(pid: Int32, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Process control is not supported on this platform."
        case .terminateFailed(let pid, let errno):
            "Failed to terminate process \(pid) with errno \(errno)."
        }
    }
}

public struct DarwinProcessController: ProcessControlling {
    public init() {}

    public func terminate(pid: Int32) throws {
        #if canImport(Darwin)
        let result = kill(pid, SIGTERM)
        guard result == 0 else {
            throw ProcessControlError.terminateFailed(pid: pid, errno: errno)
        }
        #else
        throw ProcessControlError.unsupportedPlatform
        #endif
    }
}

public struct ProcessDetachedLauncher: DetachedProcessLaunching {
    public init() {}

    public func launch(_ executable: String, arguments: [String], logFile: URL) throws -> DetachedProcessLaunch {
        try FileManager.default.createDirectory(
            at: logFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: logFile)
        try handle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        try handle.close()

        return DetachedProcessLaunch(pid: process.processIdentifier, logFile: logFile)
    }
}
