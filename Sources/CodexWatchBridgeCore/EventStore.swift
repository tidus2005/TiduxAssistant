import CodexWatchCore
import Foundation

public struct EventStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load(limit: Int = 500) throws -> [BridgeEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder.codexWatchPet
        let events = text.split(separator: "\n").compactMap { line -> BridgeEvent? in
            try? decoder.decode(BridgeEvent.self, from: Data(line.utf8))
        }
        return Array(events.suffix(limit))
    }

    public func append(_ event: BridgeEvent) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.codexWatchPetLine.encode(event)
        var line = data
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
}
