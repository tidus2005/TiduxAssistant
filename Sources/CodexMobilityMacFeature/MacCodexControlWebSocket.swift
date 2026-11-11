import CryptoKit
import Foundation

/// Minimal RFC 6455 client framing for the official local Unix control socket.
/// All messages are read-only status RPCs, with bounded input and no credentials.
enum MacCodexControlWebSocket {
    static let maximumBytes = 256 * 1024
    enum Failure: Error { case invalidHandshake, invalidFrame, tooLarge }
    struct Frame { let opcode: UInt8; let isFinal: Bool; let payload: Data }

    static func upgradeRequest(key: String) -> Data {
        Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
    }

    static func validateUpgrade(_ data: Data, key: String) throws {
        guard let header = String(data: data, encoding: .utf8) else { throw Failure.invalidHandshake }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first?.split(separator: " ").dropFirst().first == "101" else { throw Failure.invalidHandshake }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        guard fields["upgrade"]?.lowercased() == "websocket",
              fields["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              fields["sec-websocket-accept"] == Data(digest).base64EncodedString() else { throw Failure.invalidHandshake }
    }

    static func encodeClientFrame(opcode: UInt8, payload: Data) -> Data {
        var bytes = Data([0x80 | opcode])
        let length = payload.count
        if length < 126 { bytes.append(0x80 | UInt8(length)) }
        else if length <= Int(UInt16.max) {
            bytes.append(contentsOf: [0xFE, UInt8(length >> 8), UInt8(length & 255)])
        } else {
            bytes.append(0xFF)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((UInt64(length) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        bytes.append(contentsOf: mask)
        bytes.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return bytes
    }

    static func decodeServerFrame(from buffer: inout Data) throws -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        let first = buffer[start], second = buffer[start + 1]
        guard first & 0x70 == 0, second & 0x80 == 0 else { throw Failure.invalidFrame }
        var offset = 2, length = UInt64(second & 0x7F)
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = UInt64(buffer[start + 2]) << 8 | UInt64(buffer[start + 3]); offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = (length << 8) | UInt64(buffer[start + i]) }
            offset = 10
        }
        guard length <= UInt64(maximumBytes) else { throw Failure.tooLarge }
        let opcode = first & 0x0F
        if opcode >= 8, (length > 125 || first & 0x80 == 0) { throw Failure.invalidFrame }
        guard buffer.count >= offset + Int(length) else { return nil }
        let payload = Data(buffer[(start + offset)..<(start + offset + Int(length))])
        buffer.removeSubrange(start..<(start + offset + Int(length)))
        return Frame(opcode: opcode, isFinal: first & 0x80 != 0, payload: payload)
    }
}
