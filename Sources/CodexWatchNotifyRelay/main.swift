import CodexWatchBridgeCore
import CodexWatchCore
import Foundation

struct NotifyRelayArguments {
    var bridgeURL = URL(string: ProcessInfo.processInfo.environment["CWP_BRIDGE_URL"] ?? "http://127.0.0.1:8765")!
    var kind = "turn-ended"
    var threadId: String?
    var turnId: String?
    var title: String?
    var summary: String?
    var cwd = ProcessInfo.processInfo.environment["PWD"]
    var rawArgs: [String] = []

    init(arguments: [String]) {
        rawArgs = Array(arguments.dropFirst())
        var iterator = rawArgs.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--bridge-url":
                if let value = iterator.next(), let url = URL(string: value) { bridgeURL = url }
            case "--kind":
                if let value = iterator.next() { kind = value }
            case "--thread-id":
                if let value = iterator.next() { threadId = value }
            case "--turn-id":
                if let value = iterator.next() { turnId = value }
            case "--title":
                if let value = iterator.next() { title = value }
            case "--summary":
                if let value = iterator.next() { summary = value }
            case "--cwd":
                if let value = iterator.next() { cwd = value }
            case "--help", "-h":
                Self.printHelpAndExit()
            default:
                if !argument.hasPrefix("-"), kind == "turn-ended" {
                    kind = argument
                }
            }
        }
    }

    static func printHelpAndExit() -> Never {
        print("""
        CodexWatchNotifyRelay

        Intended for Codex notify hooks. It accepts loose arguments, reads stdin,
        and posts a CodexNotificationPayload to the Mac bridge.

        Options:
          --bridge-url <url>   Default: CWP_BRIDGE_URL or http://127.0.0.1:8765
          --kind <kind>        Default: turn-ended
          --thread-id <id>
          --turn-id <id>
          --title <title>
          --summary <summary>
          --cwd <path>
        """)
        exit(0)
    }
}

let arguments = NotifyRelayArguments(arguments: CommandLine.arguments)
let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let stdinText = String(data: stdinData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
let payload = CodexNotificationPayload(
    kind: arguments.kind,
    threadId: arguments.threadId,
    turnId: arguments.turnId,
    title: arguments.title,
    summary: arguments.summary,
    cwd: arguments.cwd,
    rawArgs: arguments.rawArgs,
    rawStdin: stdinText?.isEmpty == false ? stdinText : nil
)

do {
    var request = URLRequest(url: arguments.bridgeURL.appending(path: "notify"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder.codexWatchPet.encode(payload)

    let semaphore = DispatchSemaphore(value: 0)
    final class ResultBox: @unchecked Sendable {
        var result: Result<Data, Error>?
    }
    let box = ResultBox()
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            box.result = .failure(error)
            return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(http.statusCode)"
            box.result = .failure(BridgeError.invalidRequest(message))
            return
        }
        box.result = .success(data ?? Data())
    }.resume()
    _ = semaphore.wait(timeout: .now() + 3)

    switch box.result {
    case .success:
        exit(0)
    case .failure(let error):
        try spool(payload: payload, error: error)
        exit(1)
    case nil:
        try spool(payload: payload, error: BridgeError.invalidRequest("notify relay timed out"))
        exit(1)
    }
} catch {
    try? spool(payload: payload, error: error)
    fputs("CodexWatchNotifyRelay failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private func spool(payload: CodexNotificationPayload, error: Error) throws {
    let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-watch-pet")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let fileURL = home.appendingPathComponent("notify-spool.jsonl")
    let record: [String: String] = [
        "createdAt": ISO8601DateFormatter().string(from: Date()),
        "error": error.localizedDescription,
        "kind": payload.kind,
        "summary": payload.summary ?? payload.rawStdin ?? ""
    ]
    var line = try JSONEncoder().encode(record)
    line.append(0x0A)
    if FileManager.default.fileExists(atPath: fileURL.path) {
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()
    } else {
        try line.write(to: fileURL, options: .atomic)
    }
}
