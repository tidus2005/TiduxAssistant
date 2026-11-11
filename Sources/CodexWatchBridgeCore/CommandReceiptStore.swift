import CodexWatchCore
import CryptoKit
import Foundation

/// Reserve before executing. An interrupted reservation is never treated as permission to execute again.
final class CommandReceiptStore {
    struct Entry: Codable {
        var fingerprint: String
        var result: CommandResult?
    }
    private let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }

    func load() throws -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return try JSONDecoder.codexWatchPet.decode([String: Entry].self, from: Data(contentsOf: fileURL))
    }

    func save(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.codexWatchPet.encode(entries).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func fingerprint(_ command: BridgeCommand) throws -> String {
        SHA256.hash(data: try JSONEncoder.codexWatchPet.encode(command)).map { String(format: "%02x", $0) }.joined()
    }
}
