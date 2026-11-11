import CodexMobilityCore
import CodexMobilityMacFeature
import CodexWatchCore
import Foundation
import Testing

private final class CollaborationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite("Mac authenticated collaboration proxy", .serialized)
struct MacCollaborationServiceTests {
    private func fixture() throws -> (URL, URLSession) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collaboration-proxy-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = ["token": "fixture-token", "sharedSecret": Data("fixture-secret".utf8).base64EncodedString()]
        let file = dir.appendingPathComponent("pairing.json")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CollaborationURLProtocol.self]
        return (file, URLSession(configuration: configuration))
    }
    @Test func snapshotsUseMacCredentialAndReceiptsDoNotExecuteCommands() async throws {
        let (file, session) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        CollaborationURLProtocol.handler = { request in
            #expect(request.url?.host == "127.0.0.1")
            #expect(request.url?.path == "/receipts/fixture-command")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            return Data("null".utf8)
        }
        let service = MacCollaborationService(pairingURL: file, session: session)
        let request = CollaborationRequest(method: .receipt, commandID: "fixture-command")
        let response = await service.handle(request)
        #expect(response.status == 200 && response.requestID == request.id)
        #expect(String(data: response.body, encoding: .utf8) == "null")
    }
    @Test func cannotBeUsedAsArbitraryNetworkProxy() async throws {
        let (file, session) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        CollaborationURLProtocol.handler = { _ in Issue.record("Must not open remote connection"); return Data() }
        let service = MacCollaborationService(baseURL: URL(string: "https://example.com")!, pairingURL: file, session: session)
        #expect(await service.handle(CollaborationRequest(method: .snapshot)).status == 503)
    }
    @Test func commandForwardingSignsTheExactDecodedCommand() async throws {
        let (file, session) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let command = BridgeCommand(type: .startThread, payload: ["prompt": "voice question"],
            confirmation: CommandConfirmation(displayedSummary: "voice question", riskAccepted: true))
        CollaborationURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST" && request.url?.path == "/commands")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            let decoded = try JSONDecoder.codexWatchPet.decode(BridgeCommand.self, from: data)
            #expect(decoded.id == command.id && decoded.payload == command.payload)
            let signature = try #require(request.value(forHTTPHeaderField: "X-CWP-Signature"))
            #expect(try CommandSigner().verify(decoded, signature: signature, secret: Data("fixture-secret".utf8)))
            return try JSONEncoder.codexWatchPet.encode(CodexWatchCore.CommandResult(commandId: command.id, accepted: true, message: "ack"))
        }
        let service = MacCollaborationService(pairingURL: file, session: session)
        let response = await service.handle(CollaborationRequest(method: .command,
            body: try JSONEncoder.codexWatchPetLine.encode(command), commandID: command.id))
        #expect(response.status == 200)
        #expect(try JSONDecoder.codexWatchPet.decode(CodexWatchCore.CommandResult.self, from: response.body).commandId == command.id)
    }
    @Test func oversizedInputIsRejectedBeforeForwarding() async throws {
        let (file, session) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        CollaborationURLProtocol.handler = { _ in Issue.record("Must not forward oversized input"); return Data() }
        let service = MacCollaborationService(pairingURL: file, session: session)
        #expect(await service.handle(CollaborationRequest(method: .command, body: Data(count: 65 * 1024))).status == 503)
    }
    @Test func unavailableBridgeReturnsAnErrorInsteadOfInventingSuccess() async throws {
        let (file, session) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        CollaborationURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let service = MacCollaborationService(pairingURL: file, session: session)
        let response = await service.handle(CollaborationRequest(method: .snapshot))
        #expect(response.status == 503)
        #expect(String(data: response.body, encoding: .utf8)?.contains("暂不可达") == true)
    }
}
