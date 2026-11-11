import CryptoKit
import Foundation

public enum SyncthingPeerAuthenticationError: Error, Equatable, Sendable {
    case malformedPairingToken
    case invalidPairingKeyLength(actual: Int, expected: Int)
    case deviceNameTooLong(actual: Int, maximum: Int)
    case unsupportedProtocolVersion(actual: UInt16, expected: UInt16)
    case unboundSenderDeviceID
    case unboundIntendedPeerDeviceID
    case intendedPeerMismatch(expected: UUID, actual: UUID)
    case missingAuthenticationProof
    case invalidAuthenticationProof
}

/// Binds an application hello to the same 256-bit secret used by the TLS PSK handshake.
///
/// The receiver must look up the pairing token by `hello.deviceID`, pass its own device ID
/// as `expectedLocalDeviceID`, validate the proof, and reject reused nonces. The nonce replay
/// cache is intentionally owned by the session layer because its lifetime is product policy.
public enum SyncthingPeerAuthentication {
    public static let pairingKeyByteCount = 32
    public static let maximumDeviceNameUTF8Bytes = 255
    public static let proofHexCharacterCount = SHA256.byteCount * 2

    public static func makeHello(
        protocolVersion: UInt16 = SyncthingPeerProtocolLimits.currentVersion,
        messageID: UUID = UUID(),
        senderDeviceID: UUID,
        intendedPeerDeviceID: UUID,
        nonce: UUID = UUID(),
        deviceName: String,
        folderIDs: [String] = [],
        pairingToken: String
    ) throws -> SyncthingPeerHello {
        let normalizedName = try normalizedDeviceName(deviceName)
        let proof = try makeProof(
            protocolVersion: protocolVersion,
            senderDeviceID: senderDeviceID,
            intendedPeerDeviceID: intendedPeerDeviceID,
            nonce: nonce,
            deviceName: normalizedName,
            pairingToken: pairingToken
        )
        return SyncthingPeerHello(
            messageID: messageID,
            protocolVersion: protocolVersion,
            deviceID: senderDeviceID,
            intendedPeerDeviceID: intendedPeerDeviceID,
            nonce: nonce,
            deviceName: normalizedName,
            folderIDs: folderIDs,
            authenticationProof: proof
        )
    }

    public static func makeProof(
        protocolVersion: UInt16,
        senderDeviceID: UUID,
        intendedPeerDeviceID: UUID,
        nonce: UUID,
        deviceName: String,
        pairingToken: String
    ) throws -> String {
        guard senderDeviceID != SyncthingPeerHello.unboundPeerDeviceID else {
            throw SyncthingPeerAuthenticationError.unboundSenderDeviceID
        }
        guard intendedPeerDeviceID != SyncthingPeerHello.unboundPeerDeviceID else {
            throw SyncthingPeerAuthenticationError.unboundIntendedPeerDeviceID
        }
        let keyData = try pairingKeyData(from: pairingToken)
        let canonicalData = try canonicalAuthenticationData(
            protocolVersion: protocolVersion,
            senderDeviceID: senderDeviceID,
            intendedPeerDeviceID: intendedPeerDeviceID,
            nonce: nonce,
            deviceName: deviceName
        )
        let code = HMAC<SHA256>.authenticationCode(
            for: canonicalData,
            using: SymmetricKey(data: keyData)
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies version, destination binding and HMAC. Missing or malformed proofs return false.
    public static func verify(
        _ hello: SyncthingPeerHello,
        expectedLocalDeviceID: UUID,
        pairingToken: String,
        expectedProtocolVersion: UInt16 = SyncthingPeerProtocolLimits.currentVersion
    ) throws -> Bool {
        guard hello.protocolVersion == expectedProtocolVersion,
              hello.deviceID != SyncthingPeerHello.unboundPeerDeviceID,
              hello.intendedPeerDeviceID != SyncthingPeerHello.unboundPeerDeviceID,
              expectedLocalDeviceID != SyncthingPeerHello.unboundPeerDeviceID,
              hello.intendedPeerDeviceID == expectedLocalDeviceID,
              let suppliedProof = hello.authenticationProof else {
            return false
        }

        let expectedProof = try makeProof(
            protocolVersion: hello.protocolVersion,
            senderDeviceID: hello.deviceID,
            intendedPeerDeviceID: hello.intendedPeerDeviceID,
            nonce: hello.nonce,
            deviceName: hello.deviceName,
            pairingToken: pairingToken
        )
        return constantTimeProofEqual(expectedProof, suppliedProof)
    }

    /// The production handshake entry point: structural and proof failures are explicit errors.
    public static func requireValid(
        _ hello: SyncthingPeerHello,
        expectedLocalDeviceID: UUID,
        pairingToken: String,
        expectedProtocolVersion: UInt16 = SyncthingPeerProtocolLimits.currentVersion
    ) throws {
        guard hello.protocolVersion == expectedProtocolVersion else {
            throw SyncthingPeerAuthenticationError.unsupportedProtocolVersion(
                actual: hello.protocolVersion,
                expected: expectedProtocolVersion
            )
        }
        guard hello.deviceID != SyncthingPeerHello.unboundPeerDeviceID else {
            throw SyncthingPeerAuthenticationError.unboundSenderDeviceID
        }
        guard hello.intendedPeerDeviceID != SyncthingPeerHello.unboundPeerDeviceID,
              expectedLocalDeviceID != SyncthingPeerHello.unboundPeerDeviceID else {
            throw SyncthingPeerAuthenticationError.unboundIntendedPeerDeviceID
        }
        guard hello.intendedPeerDeviceID == expectedLocalDeviceID else {
            throw SyncthingPeerAuthenticationError.intendedPeerMismatch(
                expected: expectedLocalDeviceID,
                actual: hello.intendedPeerDeviceID
            )
        }
        guard hello.authenticationProof != nil else {
            throw SyncthingPeerAuthenticationError.missingAuthenticationProof
        }
        guard try verify(
            hello,
            expectedLocalDeviceID: expectedLocalDeviceID,
            pairingToken: pairingToken,
            expectedProtocolVersion: expectedProtocolVersion
        ) else {
            throw SyncthingPeerAuthenticationError.invalidAuthenticationProof
        }
    }

    /// A printable, deterministic representation useful for protocol fixtures and diagnostics.
    /// Every field is UTF-8 byte-length-prefixed, so separators inside a device name are safe.
    public static func canonicalAuthenticationString(
        protocolVersion: UInt16,
        senderDeviceID: UUID,
        intendedPeerDeviceID: UUID,
        nonce: UUID,
        deviceName: String
    ) throws -> String {
        let fields = [
            "codexsync-peer-proof-v1",
            String(protocolVersion),
            senderDeviceID.uuidString.lowercased(),
            intendedPeerDeviceID.uuidString.lowercased(),
            nonce.uuidString.lowercased(),
            try normalizedDeviceName(deviceName)
        ]
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func pairingKeyData(from pairingToken: String) throws -> Data {
        guard !pairingToken.isEmpty, pairingToken.utf8.count % 4 != 1 else {
            throw SyncthingPeerAuthenticationError.malformedPairingToken
        }
        let paddingCount = (4 - pairingToken.utf8.count % 4) % 4
        let base64 = pairingToken
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: paddingCount)
        guard let decoded = Data(base64Encoded: base64) else {
            throw SyncthingPeerAuthenticationError.malformedPairingToken
        }
        guard decoded.count == pairingKeyByteCount else {
            throw SyncthingPeerAuthenticationError.invalidPairingKeyLength(
                actual: decoded.count,
                expected: pairingKeyByteCount
            )
        }
        return decoded
    }

    private static func canonicalAuthenticationData(
        protocolVersion: UInt16,
        senderDeviceID: UUID,
        intendedPeerDeviceID: UUID,
        nonce: UUID,
        deviceName: String
    ) throws -> Data {
        Data(try canonicalAuthenticationString(
            protocolVersion: protocolVersion,
            senderDeviceID: senderDeviceID,
            intendedPeerDeviceID: intendedPeerDeviceID,
            nonce: nonce,
            deviceName: deviceName
        ).utf8)
    }

    private static func normalizedDeviceName(_ deviceName: String) throws -> String {
        let normalized = deviceName.precomposedStringWithCanonicalMapping
        guard normalized.utf8.count <= maximumDeviceNameUTF8Bytes else {
            throw SyncthingPeerAuthenticationError.deviceNameTooLong(
                actual: normalized.utf8.count,
                maximum: maximumDeviceNameUTF8Bytes
            )
        }
        return normalized
    }

    private static func constantTimeProofEqual(_ expectedHex: String, _ suppliedHex: String) -> Bool {
        let expected = decodeHex(expectedHex) ?? []
        let supplied = decodeHex(suppliedHex) ?? []
        let count = max(max(expected.count, supplied.count), SHA256.byteCount)
        var difference = expected.count ^ supplied.count
        for index in 0..<count {
            let lhs = index < expected.count ? expected[index] : 0
            let rhs = index < supplied.count ? supplied[index] : 0
            difference |= Int(lhs ^ rhs)
        }
        return difference == 0
    }

    private static func decodeHex(_ value: String) -> [UInt8]? {
        guard value.utf8.count == proofHexCharacterCount else { return nil }
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(SHA256.byteCount)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexValue(bytes[index]), let low = hexValue(bytes[index + 1]) else {
                return nil
            }
            result.append(high << 4 | low)
        }
        return result
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
