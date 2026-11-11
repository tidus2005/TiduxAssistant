import CryptoKit
import Foundation

public enum SyncSHA256 {
    public static let hexDigestLength = 64

    public static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    public static func hexDigest(
        fileAt url: URL,
        readChunkSize: Int = 256 * 1_024
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var accumulator = SyncSHA256Hasher()
        let bufferSize = max(readChunkSize, 1)
        while let data = try handle.read(upToCount: bufferSize), !data.isEmpty {
            accumulator.update(data)
        }
        return accumulator.finalize()
    }

    public static func isValidHexDigest(_ value: String) -> Bool {
        value.utf8.count == hexDigestLength
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            }
    }

    public static func matches(_ data: Data, expectedHexDigest: String) -> Bool {
        guard isValidHexDigest(expectedHexDigest) else { return false }
        return constantTimeEqual(hexDigest(data), expectedHexDigest.lowercased())
    }

    public static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference: UInt8 = left.count == right.count ? 0 : 1
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

public struct SyncSHA256Hasher: Sendable {
    private var hasher: SHA256

    public init() {
        self.hasher = SHA256()
    }

    public mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    public mutating func finalize() -> String {
        hasher.finalize().hexString
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
