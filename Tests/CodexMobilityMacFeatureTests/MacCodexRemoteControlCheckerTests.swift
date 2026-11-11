@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Official read-only remote-control checker")
struct MacCodexRemoteControlCheckerTests {
    @Test func connectedReadUsesOnlyExistingDaemonAndReadOnlyRPCs() async throws {
        let file = try fixture(status: "connected")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let checker = ProcessMacCodexRemoteControlChecker(executableCandidates: [file.path])
        #expect(await checker.ensureConnected(timeout: 2) == .connected)
    }

    @Test(arguments: ["connecting", "disabled", "errored"])
    func doesNotPromoteOtherStatusesOrConnectedNotifications(status: String) async throws {
        let file = try fixture(status: status, sendConnectedNotification: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let checker = ProcessMacCodexRemoteControlChecker(executableCandidates: [file.path])
        #expect(!(await checker.ensureConnected(timeout: 2)).isConnected)
    }

    @Test func instanceConflictIsNeverPhoneOrServiceOnlineProof() async throws {
        let file = try fixture(status: "connected", invalidUpgrade: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let checker = ProcessMacCodexRemoteControlChecker(executableCandidates: [file.path])
        #expect(!(await checker.ensureConnected(timeout: 2)).isConnected)
        #expect(!MacCodexRemoteControlReadiness.connectedByExistingInstance.isConnected)
    }

    @Test func cancellationStopsWaitingProxyPromptly() async throws {
        let file = try fixture(status: "connected", stall: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let checker = ProcessMacCodexRemoteControlChecker(executableCandidates: [file.path])
        let start = ContinuousClock.now
        let task = Task { await checker.ensureConnected(timeout: 20) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(!(await task.value).isConnected)
        #expect(start.duration(to: .now) < .seconds(3))
    }

    @Test func clientMasksFramesAndServerDecoderHandlesPartialInput() throws {
        let data = Data(repeating: 65, count: 500)
        var client = MacCodexControlWebSocket.encodeClientFrame(opcode: 1, payload: data)
        let decoded = try MacRemoteDashboardWebSocketCodec.decodeClientFrame(from: &client)
        #expect(decoded?.payload == data)
        let frame = MacRemoteDashboardWebSocketCodec.encodeServerFrame(opcode: 1, payload: data)
        var partial = Data(frame.prefix(7))
        #expect(try MacCodexControlWebSocket.decodeServerFrame(from: &partial) == nil)
        partial.append(frame.dropFirst(7))
        #expect(try MacCodexControlWebSocket.decodeServerFrame(from: &partial)?.payload == data)
    }

    private func fixture(status: String, sendConnectedNotification: Bool = false,
                         invalidUpgrade: Bool = false, stall: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-readonly-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("codex-fixture")
        // This fixture fails if a new server or any mutating RPC is requested.
        let script = """
        #!/usr/bin/env python3
        import sys, json, hashlib, base64, struct, time
        assert sys.argv[1:] == ['app-server', 'proxy']
        inp, out = sys.stdin.buffer, sys.stdout.buffer
        header = b''
        while b'\\r\\n\\r\\n' not in header:
            chunk = inp.read(1)
            if not chunk: sys.exit(1)
            header += chunk
        if \(stall ? "True" : "False"): time.sleep(20)
        if \(invalidUpgrade ? "True" : "False"):
            out.write(b'HTTP/1.1 409 Conflict\\r\\nContent-Length: 0\\r\\n\\r\\n'); out.flush()
            sys.exit(0)
        key = next(l.split(b': ',1)[1] for l in header.split(b'\\r\\n') if l.lower().startswith(b'sec-websocket-key:'))
        accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
        out.write(b'HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Accept: ' + accept + b'\\r\\n\\r\\n'); out.flush()
        def read():
            a, b = inp.read(2)
            assert b & 128
            n = b & 127
            if n == 126: n = struct.unpack('!H',inp.read(2))[0]
            mask = inp.read(4); payload = inp.read(n)
            return json.loads(bytes(v ^ mask[i%4] for i,v in enumerate(payload)))
        def send(obj):
            data = json.dumps(obj).encode()
            h = bytes([129,len(data)]) if len(data)<126 else bytes([129,126])+struct.pack('!H',len(data))
            out.write(h+data); out.flush()
        assert read()['method'] == 'initialize'
        send({'id':1,'result':{'userAgent':'fixture'}})
        assert read()['method'] == 'initialized'
        request = read()
        assert request['method'] == 'remoteControl/status/read'
        if \(sendConnectedNotification ? "True" : "False"):
            send({'method':'remoteControl/status/changed','params':{'status':'connected'}})
        send({'id':request['id'],'result':{'status':'\(status)','serverName':'Test Mac'}})
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
