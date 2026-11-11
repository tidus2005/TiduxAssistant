import CryptoKit
import Foundation

enum MacRemoteDashboardWebSocketError: Error, Equatable, Sendable {
    case invalidHandshake
    case frameTooLarge
    case fragmentedFrame
    case unsupportedReservedBits
    case unmaskedClientFrame
    case invalidClosePayload
}

struct MacRemoteDashboardWebSocketFrame: Equatable, Sendable {
    var opcode: UInt8
    var payload: Data
}

enum MacRemoteDashboardWebSocketCodec {
    static let path = "/ws"
    static let maximumFrameBytes = 256 * 1024
    private static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func upgradeResponse(
        for request: MacRemoteDashboardHTTPRequest
    ) throws -> Data {
        guard request.method == "GET",
              request.path == path,
              request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["connection"]?
                .split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
                .contains("upgrade") == true,
              request.headers["sec-websocket-version"] == "13",
              let key = request.headers["sec-websocket-key"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw MacRemoteDashboardWebSocketError.invalidHandshake
        }

        let digest = Insecure.SHA1.hash(
            data: Data((key + webSocketGUID).utf8)
        )
        let accept = Data(digest).base64EncodedString()
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "Cache-Control: no-store",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(response.utf8)
    }

    static func encodeServerFrame(opcode: UInt8, payload: Data = Data()) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F))
        appendLength(payload.count, masked: false, to: &frame)
        frame.append(payload)
        return frame
    }

    static func encodeCloseFrame(code: UInt16, reason: String) -> Data {
        var payload = Data([
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ])
        payload.append(Data(reason.utf8.prefix(120)))
        return encodeServerFrame(opcode: 0x8, payload: payload)
    }

    static func decodeClientFrame(
        from buffer: inout Data
    ) throws -> MacRemoteDashboardWebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        let first = buffer[start]
        let second = buffer[buffer.index(after: start)]
        guard first & 0x70 == 0 else {
            throw MacRemoteDashboardWebSocketError.unsupportedReservedBits
        }
        guard first & 0x80 != 0 else {
            throw MacRemoteDashboardWebSocketError.fragmentedFrame
        }
        guard second & 0x80 != 0 else {
            throw MacRemoteDashboardWebSocketError.unmaskedClientFrame
        }

        var offset = 2
        var payloadLength = UInt64(second & 0x7F)
        if payloadLength == 126 {
            guard buffer.count >= 4 else { return nil }
            payloadLength = UInt64(buffer[start + 2]) << 8
                | UInt64(buffer[start + 3])
            offset = 4
        } else if payloadLength == 127 {
            guard buffer.count >= 10 else { return nil }
            payloadLength = 0
            for index in 2..<10 {
                payloadLength = (payloadLength << 8) | UInt64(buffer[start + index])
            }
            offset = 10
        }

        guard payloadLength <= UInt64(maximumFrameBytes),
              payloadLength <= UInt64(Int.max) else {
            throw MacRemoteDashboardWebSocketError.frameTooLarge
        }
        let length = Int(payloadLength)
        guard buffer.count >= offset + 4 + length else { return nil }
        let mask = Array(buffer[(start + offset)..<(start + offset + 4)])
        offset += 4
        var payload = Array(buffer[(start + offset)..<(start + offset + length)])
        for index in payload.indices {
            payload[index] ^= mask[index % 4]
        }
        buffer.removeSubrange(start..<(start + offset + length))
        return MacRemoteDashboardWebSocketFrame(
            opcode: first & 0x0F,
            payload: Data(payload)
        )
    }

    private static func appendLength(
        _ length: Int,
        masked: Bool,
        to frame: inout Data
    ) {
        let maskBit: UInt8 = masked ? 0x80 : 0
        if length < 126 {
            frame.append(maskBit | UInt8(length))
        } else if length <= Int(UInt16.max) {
            frame.append(maskBit | 126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF))
            }
        }
    }
}

struct MacRemoteDashboardWebSocketAuthentication: Codable, Equatable, Sendable {
    var type: String
    var token: String
}

struct MacRemoteDashboardWebSocketSnapshotEnvelope: Encodable, Sendable {
    let type = "snapshot"
    var snapshot: MacRemoteDashboardSnapshot
}

struct MacRemoteDashboardWebSocketStatusEnvelope: Codable, Equatable, Sendable {
    var type: String
    var message: String
}
