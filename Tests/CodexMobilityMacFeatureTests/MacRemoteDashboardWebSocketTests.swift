@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mac remote dashboard WebSocket")
struct MacRemoteDashboardWebSocketTests {
    @Test("RFC 6455 upgrade uses the expected accept value")
    func upgradeHandshake() throws {
        let request = MacRemoteDashboardHTTPRequest(
            method: "GET",
            path: "/ws",
            headers: [
                "upgrade": "websocket",
                "connection": "keep-alive, Upgrade",
                "sec-websocket-version": "13",
                "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ=="
            ],
            body: Data()
        )

        let response = try MacRemoteDashboardWebSocketCodec.upgradeResponse(
            for: request
        )
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.contains("101 Switching Protocols"))
        #expect(text.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
    }

    @Test("Masked browser text frames decode without leaking mask bytes")
    func maskedClientFrameRoundTrip() throws {
        let payload = Data("{\"type\":\"authenticate\",\"token\":\"test\"}".utf8)
        var buffer = maskedClientFrame(opcode: 0x1, payload: payload)

        let decoded = try MacRemoteDashboardWebSocketCodec.decodeClientFrame(
            from: &buffer
        )
        #expect(decoded == MacRemoteDashboardWebSocketFrame(opcode: 0x1, payload: payload))
        #expect(buffer.isEmpty)

        let serverFrame = MacRemoteDashboardWebSocketCodec.encodeServerFrame(
            opcode: 0x1,
            payload: payload
        )
        #expect(serverFrame[serverFrame.startIndex] == 0x81)
        #expect(serverFrame[serverFrame.index(after: serverFrame.startIndex)] & 0x80 == 0)
    }

    @Test("Unmasked browser frames are rejected")
    func rejectsUnmaskedClientFrame() {
        var buffer = Data([0x81, 0x02, 0x7B, 0x7D])
        #expect(throws: MacRemoteDashboardWebSocketError.unmaskedClientFrame) {
            try MacRemoteDashboardWebSocketCodec.decodeClientFrame(from: &buffer)
        }
    }

    @Test("The H5 page prefers WebSocket and keeps a slow HTTP fallback")
    func pageRealtimeContract() {
        let html = MacRemoteDashboardPage.html
        #expect(html.contains("new WebSocket"))
        #expect(html.contains("WebSocket 实时同步"))
        #expect(html.contains("30000"))
        #expect(!html.contains("setInterval(() => refresh({ quiet: true }), 5000)"))
        #expect(html.contains("type: \"authenticate\", token: state.token"))
        #expect(html.contains("/app/codex-watch-pet"))
        #expect(html.contains("const isHubMode"))
        #expect(html.contains("debugViewport === \"440x860\""))
        #expect(html.contains("embeddedDebugViewport=440x860"))
        #expect(html.contains("endpoint(\"/ws\")"))
        #expect(html.contains("if (!isHubMode)"))
        #expect(html.contains("renderTemperatureHistory(snapshot.thermal"))
        #expect(html.contains("point.time - previousTime > intervalMs * 2.2"))
        #expect(html.contains("温度传感器暂不可用"))
        #expect(html.contains("snapshot.filesVersion"))
        #expect(html.contains("snapshot.screenLock"))
        #expect(html.contains("saveScreenLockSettings"))
        #expect(html.contains("/api/screen-lock"))
        #expect(html.contains("refreshFiles({ quiet: true })"))
        #expect(html.contains("application/octet-stream"))
        #expect(html.contains("class IncrementalSHA256"))
        #expect(html.contains("webkitdirectory"))
        #expect(html.contains("Promise.all(Array.from({ length: Math.min(3"))
        #expect(html.contains("/api/files/preview"))
        #expect(html.contains("data-tab=\"files\""))
    }

    private func maskedClientFrame(opcode: UInt8, payload: Data) -> Data {
        let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        precondition(payload.count < 126)
        var frame = Data([0x80 | opcode, 0x80 | UInt8(payload.count)])
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % mask.count])
        }
        return frame
    }
}
