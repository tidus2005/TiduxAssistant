import Foundation
import Security

public struct MobilityMacPairingCredential: Codable, Equatable, Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var token: String
    public var pairedAt: Date

    public init(deviceID: UUID, deviceName: String, token: String, pairedAt: Date = Date()) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.token = token
        self.pairedAt = pairedAt
    }
}

/// Token-free metadata that is safe to expose to the Mac management UI.
public struct MobilityMacPairedDevice: Equatable, Identifiable, Sendable {
    public var id: UUID { deviceID }
    public var deviceID: UUID
    public var deviceName: String
    public var pairedAt: Date

    public init(deviceID: UUID, deviceName: String, pairedAt: Date) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pairedAt = pairedAt
    }
}

public protocol MobilityMacCredentialStoring: Sendable {
    func issueCredential(deviceID: UUID, deviceName: String, pairedAt: Date) throws -> MobilityMacPairingCredential
    func pairedDevices() throws -> [MobilityMacPairedDevice]
    func credential(for deviceID: UUID) throws -> MobilityMacPairingCredential?
    func credential(matchingToken token: String) throws -> MobilityMacPairingCredential?
    func revokeCredential(for deviceID: UUID) throws
}

public enum MobilityMacCredentialVaultError: LocalizedError, Equatable, Sendable {
    case randomGenerationFailed(OSStatus)
    case malformedCredential
    case unexpectedStatus(operation: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            "无法生成安全配对令牌（\(status)）。"
        case .malformedCredential:
            "Mac 随行配对凭据已损坏，请撤销后重新配对。"
        case .unexpectedStatus(let operation, let status):
            "Mac 随行钥匙串操作失败（\(operation)，\(status)）。"
        }
    }
}

/// Mac-only Keychain vault for Mobility BLE tokens.
///
/// Its service name is intentionally unrelated to the legacy Bridge pairing record and
/// UserDefaults keys. Re-pairing a device rotates that device's token atomically.
public struct MobilityMacCredentialVault: MobilityMacCredentialStoring {
    public static let defaultService = "com.tidux.codex-mobility.mac-pairing-token"

    public let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func issueCredential(
        deviceID: UUID,
        deviceName: String,
        pairedAt: Date = Date()
    ) throws -> MobilityMacPairingCredential {
        let credential = MobilityMacPairingCredential(
            deviceID: deviceID,
            deviceName: Self.normalizedDeviceName(deviceName),
            token: try Self.makeRandomToken(),
            pairedAt: pairedAt
        )
        try store(credential)
        return credential
    }

    public func pairedDevices() throws -> [MobilityMacPairedDevice] {
        try allCredentials()
            .map {
                MobilityMacPairedDevice(
                    deviceID: $0.deviceID,
                    deviceName: $0.deviceName,
                    pairedAt: $0.pairedAt
                )
            }
            .sorted {
                if $0.pairedAt != $1.pairedAt {
                    return $0.pairedAt > $1.pairedAt
                }
                return $0.deviceID.uuidString < $1.deviceID.uuidString
            }
    }

    public func credential(for deviceID: UUID) throws -> MobilityMacPairingCredential? {
        var query = baseQuery(for: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MobilityMacCredentialVaultError.unexpectedStatus(operation: "读取", status: status)
        }
        guard
            let data = result as? Data,
            let credential = try? JSONDecoder().decode(MobilityMacPairingCredential.self, from: data),
            credential.deviceID == deviceID
        else {
            throw MobilityMacCredentialVaultError.malformedCredential
        }
        return credential
    }

    public func credential(matchingToken token: String) throws -> MobilityMacPairingCredential? {
        guard !token.isEmpty else { return nil }
        for credential in try allCredentials() where Self.constantTimeEqual(credential.token, token) {
            return credential
        }
        return nil
    }

    public func revokeCredential(for deviceID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobilityMacCredentialVaultError.unexpectedStatus(operation: "撤销", status: status)
        }
    }

    private func store(_ credential: MobilityMacPairingCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(for: credential.deviceID)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MobilityMacCredentialVaultError.unexpectedStatus(operation: "更新", status: updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MobilityMacCredentialVaultError.unexpectedStatus(operation: "新增", status: addStatus)
        }
    }

    private func allCredentials() throws -> [MobilityMacPairingCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // macOS login keychains can reject bulk extraction of generic-password
            // secret data. Enumerate non-secret account attributes first, then
            // read each credential through the single-item path.
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw MobilityMacCredentialVaultError.unexpectedStatus(operation: "列出", status: status)
        }

        let attributes: [[String: Any]]
        if let dictionary = result as? [String: Any] {
            attributes = [dictionary]
        } else if let dictionaries = result as? [[String: Any]] {
            attributes = dictionaries
        } else {
            throw MobilityMacCredentialVaultError.malformedCredential
        }

        return try attributes.map { attributes in
            guard
                let account = attributes[kSecAttrAccount as String] as? String,
                let deviceID = UUID(uuidString: account),
                let credential = try credential(for: deviceID)
            else {
                throw MobilityMacCredentialVaultError.malformedCredential
            }
            return credential
        }
    }

    private func baseQuery(for deviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.uuidString.lowercased()
        ]
    }

    private static func makeRandomToken(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw MobilityMacCredentialVaultError.randomGenerationFailed(status)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<count {
            difference |= Int(index < left.count ? left[index] : 0)
                ^ Int(index < right.count ? right[index] : 0)
        }
        return difference == 0
    }

    private static func normalizedDeviceName(_ deviceName: String) -> String {
        let sanitized = deviceName.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(80)
        let normalized = String(String.UnicodeScalarView(sanitized))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "iPhone" : normalized
    }
}
