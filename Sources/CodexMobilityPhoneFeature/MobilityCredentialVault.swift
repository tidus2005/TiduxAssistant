import Foundation
import Security

/// The phone-side credential issued by a Mac after a six-digit pairing code is accepted.
///
/// Credentials are deliberately keyed by the Core Bluetooth peripheral identifier and
/// stored in their own Keychain service. They do not share the existing Bridge settings
/// or its UserDefaults keys.
public struct MobilityPairingCredential: Codable, Equatable, Sendable {
    public var peripheralIdentifier: UUID
    public var computerIdentifier: String
    public var computerName: String
    public var token: String

    public init(
        peripheralIdentifier: UUID,
        computerIdentifier: String,
        computerName: String,
        token: String
    ) {
        self.peripheralIdentifier = peripheralIdentifier
        self.computerIdentifier = computerIdentifier
        self.computerName = computerName
        self.token = token
    }
}

public protocol MobilityCredentialVault: Sendable {
    func credential(for peripheralIdentifier: UUID) throws -> MobilityPairingCredential?
    func allCredentials() throws -> [MobilityPairingCredential]
    func store(_ credential: MobilityPairingCredential) throws
    func removeCredential(for peripheralIdentifier: UUID) throws
}

public enum MobilityCredentialVaultError: LocalizedError, Equatable {
    case malformedCredential
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .malformedCredential:
            "配对凭据已损坏，请删除后重新配对。"
        case .unexpectedStatus(let status):
            "钥匙串操作失败（\(status)）。"
        }
    }
}

public struct KeychainMobilityCredentialVault: MobilityCredentialVault {
    public static let service = "com.tidux.codex-mobility.phone-pairing-token"

    private let service: String

    public init(service: String = Self.service) {
        self.service = service
    }

    public func credential(for peripheralIdentifier: UUID) throws -> MobilityPairingCredential? {
        var query = baseQuery(for: peripheralIdentifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MobilityCredentialVaultError.unexpectedStatus(status)
        }
        guard
            let data = result as? Data,
            let credential = try? JSONDecoder().decode(MobilityPairingCredential.self, from: data),
            credential.peripheralIdentifier == peripheralIdentifier
        else {
            throw MobilityCredentialVaultError.malformedCredential
        }
        return credential
    }

    public func allCredentials() throws -> [MobilityPairingCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw MobilityCredentialVaultError.unexpectedStatus(status)
        }

        let encodedCredentials: [Data]
        if let data = result as? Data {
            encodedCredentials = [data]
        } else if let data = result as? [Data] {
            encodedCredentials = data
        } else {
            throw MobilityCredentialVaultError.malformedCredential
        }

        return try encodedCredentials.map { data in
            guard let credential = try? JSONDecoder().decode(MobilityPairingCredential.self, from: data) else {
                throw MobilityCredentialVaultError.malformedCredential
            }
            return credential
        }
        .sorted { $0.computerName.localizedStandardCompare($1.computerName) == .orderedAscending }
    }

    public func store(_ credential: MobilityPairingCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(for: credential.peripheralIdentifier)
        let updates = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MobilityCredentialVaultError.unexpectedStatus(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MobilityCredentialVaultError.unexpectedStatus(addStatus)
        }
    }

    public func removeCredential(for peripheralIdentifier: UUID) throws {
        let status = SecItemDelete(baseQuery(for: peripheralIdentifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobilityCredentialVaultError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for peripheralIdentifier: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peripheralIdentifier.uuidString.lowercased()
        ]
    }
}
