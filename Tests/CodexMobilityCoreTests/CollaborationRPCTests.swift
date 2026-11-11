import CodexMobilityCore
import Foundation
import Testing

@Suite("Collaboration RPC wire format")
struct CollaborationRPCTests {
    @Test func compressedSnapshotRetainsExactContents() throws {
        let original = Data(String(repeating: "{\"task\":\"协作任务\",\"status\":\"active\"}\n", count: 1800).utf8)
        let response = CollaborationResponse(requestID: UUID(), status: 200, body: original).compressedIfUseful()
        #expect(response.compression == "lzfse")
        #expect(response.body.count < original.count / 2)
        let wire = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CollaborationResponse.self, from: wire)
        #expect(try decoded.decodedBody() == original)
    }
    @Test func legacyUncompressedResponseAndMalformedPayload() throws {
        let id = UUID()
        let legacy = Data("{\"requestID\":\"\(id.uuidString)\",\"status\":200,\"body\":\"b2s=\"}".utf8)
        let response = try JSONDecoder().decode(CollaborationResponse.self, from: legacy)
        #expect(try response.decodedBody() == Data("ok".utf8))
        #expect(throws: (any Error).self) {
            try CollaborationResponse(requestID: id, status: 200, body: Data([1, 2, 3]), compression: "lzfse").decodedBody()
        }
        #expect(throws: (any Error).self) {
            try CollaborationResponse(requestID: id, status: 200, body: Data([1]), compression: "unknown").decodedBody()
        }
    }
    @Test func decompressionIsBounded() throws {
        // An otherwise valid compressed payload may not inflate beyond the control-message limit.
        let source = Data(repeating: 42, count: 300 * 1024)
        // compressedIfUseful deliberately refuses to compress over-limit responses.
        #expect(CollaborationResponse(requestID: UUID(), status: 200, body: source).compressedIfUseful().compression == nil)
        #expect(throws: (any Error).self) {
            try CollaborationResponse(requestID: UUID(), status: 200, body: source).decodedBody()
        }
        let compressed = try (source as NSData).compressed(using: .lzfse)
        #expect(throws: (any Error).self) {
            try CollaborationResponse(requestID: UUID(), status: 200, body: compressed as Data, compression: "lzfse").decodedBody()
        }
    }
}
