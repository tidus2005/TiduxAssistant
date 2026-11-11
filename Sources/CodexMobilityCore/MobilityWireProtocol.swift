import Foundation

public struct PairRequest: Codable, Equatable, Hashable, Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var pairingCode: String

    public init(deviceID: UUID, deviceName: String, pairingCode: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pairingCode = pairingCode
    }
}

public enum Action: Codable, Equatable, Hashable, Sendable {
    case requestStatus
    case setMode(enabled: Bool, profile: MobilityModeProfile)
    case updatePolicy(MobilityPolicy)
    case fileSync(SyncWireMessage)
    case collaboration(CollaborationRequest)
}

public struct AuthenticatedCommand: Codable, Equatable, Hashable, Sendable {
    public var token: String
    public var nonce: UUID
    public var sentAt: Date
    public var action: Action

    public init(token: String, nonce: UUID = UUID(), sentAt: Date = Date(), action: Action) {
        self.token = token
        self.nonce = nonce
        self.sentAt = sentAt
        self.action = action
    }
}

public enum ClientMessage: Codable, Equatable, Hashable, Sendable {
    case pair(PairRequest)
    case command(AuthenticatedCommand)
}

public struct PairAcceptance: Codable, Equatable, Hashable, Sendable {
    public var token: String
    public var serverDeviceID: UUID
    public var serverDeviceName: String
    public var pairedAt: Date

    public init(
        token: String,
        serverDeviceID: UUID,
        serverDeviceName: String,
        pairedAt: Date = Date()
    ) {
        self.token = token
        self.serverDeviceID = serverDeviceID
        self.serverDeviceName = serverDeviceName
        self.pairedAt = pairedAt
    }
}

public struct PairRejection: Codable, Equatable, Hashable, Sendable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public struct CommandResult: Codable, Equatable, Hashable, Sendable {
    public var nonce: UUID
    public var accepted: Bool
    public var message: String
    public var status: MobilityDeviceStatus?

    public init(
        nonce: UUID,
        accepted: Bool,
        message: String,
        status: MobilityDeviceStatus? = nil
    ) {
        self.nonce = nonce
        self.accepted = accepted
        self.message = message
        self.status = status
    }
}

public enum ServerMessage: Codable, Equatable, Hashable, Sendable {
    case pairAccepted(PairAcceptance)
    case pairRejected(PairRejection)
    case status(MobilityDeviceStatus)
    case result(CommandResult)
    case fileSync(SyncWireMessage)
    case collaboration(CollaborationResponse)
}

public struct ClientEnvelope: Codable, Equatable, Hashable, Sendable {
    public static let currentVersion: UInt16 = 1

    public var version: UInt16
    public var messageID: UUID
    public var sentAt: Date
    public var message: ClientMessage

    public init(
        version: UInt16 = Self.currentVersion,
        messageID: UUID = UUID(),
        sentAt: Date = Date(),
        message: ClientMessage
    ) {
        self.version = version
        self.messageID = messageID
        self.sentAt = sentAt
        self.message = message
    }
}

public struct ServerEnvelope: Codable, Equatable, Hashable, Sendable {
    public static let currentVersion: UInt16 = 1

    public var version: UInt16
    public var messageID: UUID
    public var sentAt: Date
    public var message: ServerMessage

    public init(
        version: UInt16 = Self.currentVersion,
        messageID: UUID = UUID(),
        sentAt: Date = Date(),
        message: ServerMessage
    ) {
        self.version = version
        self.messageID = messageID
        self.sentAt = sentAt
        self.message = message
    }
}

public struct MobilityJSONCodec: Codable, Equatable, Hashable, Sendable {
    public init() {}

    public func encode(_ envelope: ClientEnvelope) throws -> Data {
        try Self.makeEncoder().encode(envelope)
    }

    public func encode(_ envelope: ServerEnvelope) throws -> Data {
        try Self.makeEncoder().encode(envelope)
    }

    public func decodeClient(_ data: Data) throws -> ClientEnvelope {
        try Self.makeDecoder().decode(ClientEnvelope.self, from: data)
    }

    public func decodeServer(_ data: Data) throws -> ServerEnvelope {
        try Self.makeDecoder().decode(ServerEnvelope.self, from: data)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public struct MobilityBLEUUIDs: Codable, Equatable, Hashable, Sendable {
    /// Fits beside one 128-bit service UUID in the primary advertisement.
    public static let advertisedLocalName = "Codex"
    public static let service = UUID(uuidString: "C0DE0001-7A11-4A3B-9A7E-5A7A11C0DE01")!
    public static let pairing = UUID(uuidString: "C0DE0002-7A11-4A3B-9A7E-5A7A11C0DE01")!
    public static let control = UUID(uuidString: "C0DE0003-7A11-4A3B-9A7E-5A7A11C0DE01")!
    public static let status = UUID(uuidString: "C0DE0004-7A11-4A3B-9A7E-5A7A11C0DE01")!
    public static let event = UUID(uuidString: "C0DE0005-7A11-4A3B-9A7E-5A7A11C0DE01")!

    public init() {}
}
