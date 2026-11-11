import CodexWatchCore
import CryptoKit
import Foundation
import Security

public struct PairingRecord: Codable, Hashable, Sendable {
    public var deviceName: String
    public var deviceId: String
    public var token: String
    public var sharedSecret: String
    public var pairedAt: Date

    public init(deviceName: String, deviceId: String, token: String, sharedSecret: String, pairedAt: Date = Date()) {
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.token = token
        self.sharedSecret = sharedSecret
        self.pairedAt = pairedAt
    }

    public var secretData: Data {
        Data(base64Encoded: sharedSecret) ?? Data(sharedSecret.utf8)
    }
}

public final class PairingStore: @unchecked Sendable {
    public let directory: URL
    private let fileURL: URL
    private let encoder = JSONEncoder.codexWatchPet
    private let decoder = JSONDecoder.codexWatchPet

    public init(directory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-watch-pet")) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("pairing.json")
    }

    public func load() throws -> PairingRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(PairingRecord.self, from: data)
    }

    @discardableResult
    public func createOrLoad(deviceName: String = "Codex Watch", deviceId: String = UUID().uuidString) throws -> PairingRecord {
        if let existing = try load() {
            return existing
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = PairingRecord(
            deviceName: deviceName,
            deviceId: deviceId,
            token: Self.randomBase64URL(byteCount: 32),
            sharedSecret: Self.randomBase64(byteCount: 32)
        )
        try encoder.encode(record).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return record
    }

    public func status() -> PairStatus {
        guard let record = try? load() else {
            return PairStatus(paired: false)
        }
        return PairStatus(
            paired: true,
            deviceName: record.deviceName,
            tokenPreview: String(record.token.prefix(8)) + "...",
            pairedAt: record.pairedAt
        )
    }

    public static func randomBase64(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    public static func randomBase64URL(byteCount: Int) -> String {
        randomBase64(byteCount: byteCount)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
