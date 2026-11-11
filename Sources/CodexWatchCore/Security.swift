import CryptoKit
import Foundation

public enum CommandSecurityError: Error, Equatable {
    case missingConfirmation
    case confirmationNotAccepted
    case missingSignature
    case invalidSignature
    case replayedNonce
    case staleCommand
    case staleConfirmation
}

public struct CommandSigner: Sendable {
    public init() {}

    public func sign(_ command: BridgeCommand, secret: Data) throws -> String {
        let data = try canonicalData(for: command)
        let key = SymmetricKey(data: secret)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(signature).base64EncodedString()
    }

    public func verify(_ command: BridgeCommand, signature: String, secret: Data) throws -> Bool {
        let expected = try sign(command, secret: secret)
        return secureCompare(expected, signature)
    }

    private func canonicalData(for command: BridgeCommand) throws -> Data {
        let encoder = JSONEncoder.codexWatchPet
        encoder.outputFormatting.insert(.sortedKeys)
        return try encoder.encode(command)
    }

    private func secureCompare(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for (left, right) in zip(lhsBytes, rhsBytes) {
            diff |= left ^ right
        }
        return diff == 0
    }
}

public final class NonceStore: @unchecked Sendable {
    private var accepted: [String: Date] = [:]
    private let maxAge: TimeInterval

    public init(maxAge: TimeInterval = 300) {
        self.maxAge = maxAge
    }

    public func accept(_ nonce: String, createdAt: Date, now: Date = Date()) throws {
        prune(now: now)
        guard abs(now.timeIntervalSince(createdAt)) <= maxAge else {
            throw CommandSecurityError.staleCommand
        }
        guard accepted[nonce] == nil else {
            throw CommandSecurityError.replayedNonce
        }
        accepted[nonce] = now
    }

    private func prune(now: Date) {
        accepted = accepted.filter { now.timeIntervalSince($0.value) <= maxAge }
    }
}

public struct CommandAuthorizer: Sendable {
    public var signer: CommandSigner
    public var requireSignature: Bool

    public init(signer: CommandSigner = CommandSigner(), requireSignature: Bool = true) {
        self.signer = signer
        self.requireSignature = requireSignature
    }

    public func validate(
        command: BridgeCommand,
        signature: String?,
        secret: Data,
        nonceStore: NonceStore,
        now: Date = Date()
    ) throws {
        if command.requiresHighImpactConfirmation {
            guard let confirmation = command.confirmation else {
                throw CommandSecurityError.missingConfirmation
            }
            guard confirmation.riskAccepted else {
                throw CommandSecurityError.confirmationNotAccepted
            }
            guard now.timeIntervalSince(confirmation.confirmedAt) <= 120,
                  confirmation.confirmedAt.timeIntervalSince(now) <= 5 else {
                throw CommandSecurityError.staleConfirmation
            }
        }

        try nonceStore.accept(command.clientNonce, createdAt: command.createdAt, now: now)

        guard requireSignature else { return }
        guard let signature else {
            throw CommandSecurityError.missingSignature
        }
        guard try signer.verify(command, signature: signature, secret: secret) else {
            throw CommandSecurityError.invalidSignature
        }
    }
}

public extension BridgeCommand {
    var requiresHighImpactConfirmation: Bool {
        switch type {
        case .startThread, .continueThread, .approve, .decline, .cancel, .interrupt:
            true
        case .openOnMac, .snooze:
            false
        }
    }
}

public extension JSONEncoder {
    static var codexWatchPet: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var codexWatchPetLine: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var codexWatchPet: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
