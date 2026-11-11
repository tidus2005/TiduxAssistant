import CodexMobilityCore
import Foundation

public enum MobilityPhoneMessageFactory {
    public static func pairingEnvelope(
        code: String,
        phoneDeviceID: UUID,
        phoneDeviceName: String,
        messageID: UUID = UUID(),
        sentAt: Date = Date()
    ) throws -> ClientEnvelope {
        guard isValidPairingCode(code) else {
            throw MobilityPhoneMessageError.invalidPairingCode
        }
        return ClientEnvelope(
            messageID: messageID,
            sentAt: sentAt,
            message: .pair(
                PairRequest(
                    deviceID: phoneDeviceID,
                    deviceName: phoneDeviceName,
                    pairingCode: code
                )
            )
        )
    }

    public static func authenticatedEnvelope(
        action: Action,
        token: String,
        nonce: UUID = UUID(),
        messageID: UUID = UUID(),
        sentAt: Date = Date()
    ) throws -> ClientEnvelope {
        guard !token.isEmpty else {
            throw MobilityPhoneMessageError.missingPairingToken
        }
        return ClientEnvelope(
            messageID: messageID,
            sentAt: sentAt,
            message: .command(
                AuthenticatedCommand(
                    token: token,
                    nonce: nonce,
                    sentAt: sentAt,
                    action: action
                )
            )
        )
    }

    public static func isValidPairingCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

public enum MobilityPhoneMessageError: LocalizedError, Equatable, Sendable {
    case invalidPairingCode
    case missingPairingToken
    case noConnectedComputer
    case notPaired
    case invalidServerVersion(UInt16)
    case messageIdentifierMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidPairingCode:
            "请输入 Mac 上显示的 6 位数字配对码。"
        case .missingPairingToken, .notPaired:
            "这台 Mac 尚未完成配对。"
        case .noConnectedComputer:
            "尚未连接 Mac。"
        case .invalidServerVersion(let version):
            "Mac 使用了不兼容的协议版本（\(version)）。"
        case .messageIdentifierMismatch:
            "蓝牙分片与消息标识不一致，已丢弃这条状态。"
        }
    }
}
