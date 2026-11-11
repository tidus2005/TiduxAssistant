@testable import CodexMobilityMacFeature
import CryptoKit
import Foundation
import Testing

@MainActor
private final class DashboardFileSyncPreferences: MacSyncDirectoryPreferencePersisting {
    var bookmark: Data?
    var enabled = true

    func loadBookmark() -> Data? { bookmark }
    func saveBookmark(_ bookmark: Data?) { self.bookmark = bookmark }
    func loadIsEnabled() -> Bool { enabled }
    func saveIsEnabled(_ enabled: Bool) { self.enabled = enabled }
}

@MainActor
private final class DashboardNilDirectoryChooser: MacSyncDirectoryChoosing {
    func chooseDirectory() -> URL? { nil }
}

@Suite("Mac remote dashboard file sync")
struct MacRemoteDashboardFileServiceTests {
    @Test("Unconfigured service reports the Mac selection boundary")
    @MainActor
    func unconfiguredDirectory() async throws {
        let store = makeStore()
        let service = MacRemoteDashboardFileService(store: store)

        let response = await service.response(for: request(method: "GET", path: "/api/files"))
        #expect(response.status == 200)
        let payload = try MacRemoteDashboardJSON.decoder.decode(
            MacRemoteDashboardFileListResponse.self,
            from: response.body
        )
        #expect(payload.isConfigured == false)
        #expect(payload.files.isEmpty)
        #expect(payload.maximumUploadBytes == MacRemoteDashboardFileService.maximumUploadBytes)
    }

    @Test("Listing and download reject hidden files and symbolic-link escapes")
    @MainActor
    func secureListAndDownload() async throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Docs"),
            withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(to: root.appendingPathComponent("Docs/hello.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        try Data("temporary".utf8).write(to: root.appendingPathComponent("~"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Escape"),
            withDestinationURL: outside
        )

        let store = makeStore()
        try await store.selectDirectory(root)
        let service = MacRemoteDashboardFileService(store: store)

        let listResponse = await service.response(for: request(method: "GET", path: "/api/files"))
        let list = try MacRemoteDashboardJSON.decoder.decode(
            MacRemoteDashboardFileListResponse.self,
            from: listResponse.body
        )
        #expect(list.files.map(\.relativePath) == ["Docs/hello.txt"])
        #expect(list.directoryName == root.lastPathComponent)

        let download = await service.response(for: request(
            method: "GET",
            path: "/api/files/download",
            queryItems: ["path": "Docs/hello.txt"]
        ))
        #expect(download.status == 200)
        #expect(download.fileURL == root.appendingPathComponent("Docs/hello.txt"))
        #expect(download.contentLength == 5)
        #expect(download.extraHeaders["Content-Disposition"]?.contains("hello.txt") == true)

        let traversal = await service.response(for: request(
            method: "GET",
            path: "/api/files/download",
            queryItems: ["path": "../secret.txt"]
        ))
        #expect(traversal.status == 400)

        let symlink = await service.response(for: request(
            method: "GET",
            path: "/api/files/download",
            queryItems: ["path": "Escape/secret.txt"]
        ))
        #expect(symlink.status == 400)
        await store.clearDirectory()
    }

    @Test("Chunk upload verifies SHA-256 and preserves a conflicting file")
    @MainActor
    func verifiedConflictUpload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("original".utf8)
        let incoming = Data("new mobile photo".utf8)
        try original.write(to: root.appendingPathComponent("photo.jpg"))

        let store = makeStore()
        try await store.selectDirectory(root)
        let service = MacRemoteDashboardFileService(store: store)
        let started = try await startUpload(
            service: service,
            relativePath: "photo.jpg",
            data: incoming
        )

        let first = incoming.prefix(5)
        let firstResponse = await service.response(for: request(
            method: "POST",
            path: "/api/files/upload/chunk",
            queryItems: [
                "transferID": started.transferID.uuidString,
                "offset": "0"
            ],
            body: Data(first)
        ))
        #expect(firstResponse.status == 200)

        let secondResponse = await service.response(for: request(
            method: "POST",
            path: "/api/files/upload/chunk",
            queryItems: [
                "transferID": started.transferID.uuidString,
                "offset": String(first.count)
            ],
            body: Data(incoming.dropFirst(first.count))
        ))
        #expect(secondResponse.status == 200)

        let completedResponse = await service.response(for: request(
            method: "POST",
            path: "/api/files/upload/complete",
            queryItems: ["transferID": started.transferID.uuidString]
        ))
        #expect(completedResponse.status == 200)
        let completed = try MacRemoteDashboardJSON.decoder.decode(
            MacRemoteDashboardUploadCompleteResponse.self,
            from: completedResponse.body
        )
        #expect(completed.relativePath == "photo (1).jpg")
        #expect(try Data(contentsOf: root.appendingPathComponent("photo.jpg")) == original)
        #expect(try Data(contentsOf: root.appendingPathComponent("photo (1).jpg")) == incoming)
        await store.clearDirectory()
    }

    @Test("Wrong offsets and wrong whole-file digests never commit a final file")
    @MainActor
    func uploadIntegrityFailures() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = Data("integrity".utf8)
        let store = makeStore()
        try await store.selectDirectory(root)
        let service = MacRemoteDashboardFileService(store: store)

        let started = try await startUpload(
            service: service,
            relativePath: "bad.bin",
            data: incoming,
            sha256: String(repeating: "0", count: 64)
        )
        let wrongOffset = await service.response(for: request(
            method: "POST",
            path: "/api/files/upload/chunk",
            queryItems: [
                "transferID": started.transferID.uuidString,
                "offset": "1"
            ],
            body: incoming
        ))
        #expect(wrongOffset.status == 409)

        let write = await service.response(for: request(
            method: "POST",
            path: "/api/files/upload/chunk",
            queryItems: [
                "transferID": started.transferID.uuidString,
                "offset": "0"
            ],
            body: incoming
        ))
        #expect(write.status == 200)

        let complete = await service.response(for: request(
            method: "POST",
            path: "/api/files/upload/complete",
            queryItems: ["transferID": started.transferID.uuidString]
        ))
        #expect(complete.status == 409)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad.bin").path))
        await store.clearDirectory()
    }

    @Test("Image preview returns a reduced JPEG and rejects non-images and traversal")
    @MainActor
    func lowBandwidthImagePreview() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z7ZsAAAAASUVORK5CYII="
        ))
        try png.write(to: root.appendingPathComponent("photo.png"))
        try Data("plain text".utf8).write(to: root.appendingPathComponent("note.txt"))

        let store = makeStore()
        try await store.selectDirectory(root)
        let service = MacRemoteDashboardFileService(store: store)

        let preview = await service.response(for: request(
            method: "GET",
            path: "/api/files/preview",
            queryItems: ["path": "photo.png", "maxPixel": "480"]
        ))
        #expect(preview.status == 200)
        #expect(preview.contentType == "image/jpeg")
        #expect(!preview.body.isEmpty)
        #expect(preview.extraHeaders["X-Codex-Preview"] == "low-bandwidth")

        let text = await service.response(for: request(
            method: "GET",
            path: "/api/files/preview",
            queryItems: ["path": "note.txt"]
        ))
        #expect(text.status == 400)

        let traversal = await service.response(for: request(
            method: "GET",
            path: "/api/files/preview",
            queryItems: ["path": "../photo.png"]
        ))
        #expect(traversal.status == 400)
        await store.clearDirectory()
    }

    @Test("Dashboard upload chunk limit is one MiB")
    func exposesEfficientChunkLimit() {
        #expect(MacRemoteDashboardFileService.maximumChunkBytes == 1_024 * 1_024)
        #expect(MacRemoteDashboardHTTPRequest.maximumBytes > MacRemoteDashboardFileService.maximumChunkBytes)
    }

    @Test("HTTP parsing preserves decoded file query parameters")
    func queryParsing() throws {
        let data = Data(
            "GET /api/files/download?path=Trips%2F%E7%85%A7%E7%89%87.jpg HTTP/1.1\r\n\r\n".utf8
        )
        guard case .complete(let parsed) = MacRemoteDashboardHTTPRequest.parse(data) else {
            Issue.record("Expected complete request")
            return
        }
        #expect(parsed.path == "/api/files/download")
        #expect(parsed.queryItems["path"] == "Trips/照片.jpg")
    }

    @MainActor
    private func makeStore() -> MacFileSyncStore {
        MacFileSyncStore(
            preferences: DashboardFileSyncPreferences(),
            directoryChooser: DashboardNilDirectoryChooser(),
            watcherPollingInterval: 3_600,
            watcherStableInterval: 3_600
        )
    }

    private func request(
        method: String,
        path: String,
        queryItems: [String: String] = [:],
        body: Data = Data()
    ) -> MacRemoteDashboardHTTPRequest {
        MacRemoteDashboardHTTPRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            headers: [:],
            body: body
        )
    }

    private func startUpload(
        service: MacRemoteDashboardFileService,
        relativePath: String,
        data: Data,
        sha256: String? = nil
    ) async throws -> MacRemoteDashboardUploadStartResponse {
        let requestBody = try MacRemoteDashboardJSON.encoder.encode(
            MacRemoteDashboardUploadStartRequest(
                relativePath: relativePath,
                byteCount: UInt64(data.count),
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
                sha256: sha256 ?? digest(data)
            )
        )
        let response = await service.response(for: request(
            method: "POST",
            path: "/api/files/upload/start",
            body: requestBody
        ))
        #expect(response.status == 200)
        return try MacRemoteDashboardJSON.decoder.decode(
            MacRemoteDashboardUploadStartResponse.self,
            from: response.body
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteDashboardFileServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
