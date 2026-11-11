import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MacRemoteDashboardFileListResponse: Codable, Equatable, Sendable {
    var isConfigured: Bool
    var isEnabled: Bool
    var directoryName: String?
    var files: [MacRemoteDashboardFileItem]
    var totalCount: Int
    var isTruncated: Bool
    var maximumUploadBytes: UInt64
    var maximumChunkBytes: Int
}

struct MacRemoteDashboardFileItem: Codable, Equatable, Sendable {
    var relativePath: String
    var name: String
    var byteCount: UInt64
    var modifiedAt: Date
    var mediaKind: String
    var contentType: String
}

struct MacRemoteDashboardUploadStartRequest: Codable, Equatable, Sendable {
    var relativePath: String
    var byteCount: UInt64
    var modifiedAt: Date
    var sha256: String
}

struct MacRemoteDashboardUploadStartResponse: Codable, Equatable, Sendable {
    var transferID: UUID
    var offset: UInt64
    var maximumChunkBytes: Int
}

struct MacRemoteDashboardUploadChunkResponse: Codable, Equatable, Sendable {
    var transferID: UUID
    var offset: UInt64
}

struct MacRemoteDashboardUploadCompleteResponse: Codable, Equatable, Sendable {
    var transferID: UUID
    var relativePath: String
    var byteCount: UInt64
    var sha256: String
    var reusedExistingFile: Bool
}

actor MacRemoteDashboardFileService {
    static let maximumUploadBytes: UInt64 = 256 * 1_024 * 1_024
    static let maximumChunkBytes = 1_024 * 1_024
    static let maximumListedFiles = 2_000
    static let defaultPreviewMaximumPixel = 960
    static let maximumPreviewPixel = 1_600

    private struct DirectorySnapshot: Sendable {
        var url: URL?
        var isEnabled: Bool
        var isOperational: Bool
    }

    private let store: MacFileSyncStore
    private var uploadDescriptors: [UUID: MacSyncFileDescriptor] = [:]

    init(store: MacFileSyncStore) {
        self.store = store
    }

    func response(
        for request: MacRemoteDashboardHTTPRequest
    ) async -> MacRemoteDashboardHTTPResponse {
        do {
            switch (request.method, request.path) {
            case ("GET", "/api/files"):
                return .jsonEncodable(try await fileList())

            case ("GET", "/api/files/download"):
                guard let relativePath = request.queryItems["path"] else {
                    return .jsonError("缺少要下载的文件路径。", status: 400)
                }
                return try await downloadResponse(relativePath: relativePath)

            case ("GET", "/api/files/preview"):
                guard let relativePath = request.queryItems["path"] else {
                    return .jsonError("缺少要预览的图片路径。", status: 400)
                }
                let requestedPixel = request.queryItems["maxPixel"].flatMap(Int.init)
                return try await previewResponse(
                    relativePath: relativePath,
                    maximumPixel: requestedPixel
                )

            case ("POST", "/api/files/upload/start"):
                let payload = try MacRemoteDashboardJSON.decoder.decode(
                    MacRemoteDashboardUploadStartRequest.self,
                    from: request.body
                )
                return .jsonEncodable(try await startUpload(payload))

            case ("POST", "/api/files/upload/chunk"):
                guard let transferID = request.queryItems["transferID"].flatMap(UUID.init(uuidString:)),
                      let offset = request.queryItems["offset"].flatMap(UInt64.init) else {
                    return .jsonError("分片传输参数无效。", status: 400)
                }
                return .jsonEncodable(
                    try await writeUploadChunk(
                        transferID: transferID,
                        offset: offset,
                        data: request.body
                    )
                )

            case ("POST", "/api/files/upload/complete"):
                guard let transferID = request.queryItems["transferID"].flatMap(UUID.init(uuidString:)) else {
                    return .jsonError("上传任务编号无效。", status: 400)
                }
                return .jsonEncodable(try await completeUpload(transferID: transferID))

            case ("POST", "/api/files/upload/cancel"):
                guard let transferID = request.queryItems["transferID"].flatMap(UUID.init(uuidString:)) else {
                    return .jsonError("上传任务编号无效。", status: 400)
                }
                await cancelUpload(transferID: transferID)
                return .jsonObject(["status": "cancelled"])

            default:
                return .jsonError("没有对应的文件同步路径。", status: 404)
            }
        } catch let error as DecodingError {
            return .jsonError("文件传输请求格式无效：\(error.localizedDescription)", status: 400)
        } catch let error as MacFileSyncError {
            return Self.errorResponse(error)
        } catch let error as MacRemoteDashboardFileServiceError {
            return .jsonError(error.localizedDescription, status: 400)
        } catch {
            return .jsonError("文件传输失败：\(error.localizedDescription)", status: 500)
        }
    }

    private func fileList() async throws -> MacRemoteDashboardFileListResponse {
        let directory = await directorySnapshot()
        guard let rootURL = directory.url else {
            return MacRemoteDashboardFileListResponse(
                isConfigured: false,
                isEnabled: directory.isEnabled,
                directoryName: nil,
                files: [],
                totalCount: 0,
                isTruncated: false,
                maximumUploadBytes: Self.maximumUploadBytes,
                maximumChunkBytes: Self.maximumChunkBytes
            )
        }

        let scanned = try Self.scanFiles(rootURL: rootURL)
        return MacRemoteDashboardFileListResponse(
            isConfigured: true,
            isEnabled: directory.isEnabled,
            directoryName: rootURL.lastPathComponent,
            files: Array(scanned.prefix(Self.maximumListedFiles)),
            totalCount: scanned.count,
            isTruncated: scanned.count > Self.maximumListedFiles,
            maximumUploadBytes: Self.maximumUploadBytes,
            maximumChunkBytes: Self.maximumChunkBytes
        )
    }

    private func downloadResponse(relativePath: String) async throws -> MacRemoteDashboardHTTPResponse {
        let rootURL = try await operationalRootURL()
        let fileURL = try Self.safeExistingFile(relativePath: relativePath, rootURL: rootURL)
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = UInt64(max(values.fileSize ?? 0, 0))
        return .file(
            fileURL,
            byteCount: byteCount,
            contentType: Self.contentType(for: fileURL),
            downloadName: fileURL.lastPathComponent
        )
    }

    private func previewResponse(
        relativePath: String,
        maximumPixel: Int?
    ) async throws -> MacRemoteDashboardHTTPResponse {
        let rootURL = try await operationalRootURL()
        let fileURL = try Self.safeExistingFile(relativePath: relativePath, rootURL: rootURL)
        guard UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .image) == true else {
            throw MacRemoteDashboardFileServiceError.previewRequiresImage
        }
        let pixel = min(max(maximumPixel ?? Self.defaultPreviewMaximumPixel, 240), Self.maximumPreviewPixel)
        let data = try Self.jpegThumbnail(fileURL: fileURL, maximumPixel: pixel)
        return .binary(
            data,
            contentType: "image/jpeg",
            extraHeaders: [
                "Content-Disposition": "inline",
                "X-Codex-Preview": "low-bandwidth"
            ]
        )
    }

    private func startUpload(
        _ request: MacRemoteDashboardUploadStartRequest
    ) async throws -> MacRemoteDashboardUploadStartResponse {
        _ = try await operationalRootURL()
        let relativePath = try MacSyncFileUtilities.normalizedRelativePath(request.relativePath)
        guard request.byteCount <= Self.maximumUploadBytes else {
            throw MacFileSyncError.fileTooLarge(maximumBytes: Self.maximumUploadBytes)
        }
        guard MacSyncFileUtilities.isValidSHA256(request.sha256) else {
            throw MacFileSyncError.invalidDigest
        }

        let descriptor = MacSyncFileDescriptor(
            relativePath: relativePath,
            byteCount: request.byteCount,
            modifiedAt: request.modifiedAt,
            sha256: request.sha256
        )
        let offset = try await store.prepareIncoming(descriptor)
        uploadDescriptors[descriptor.transferID] = descriptor
        return MacRemoteDashboardUploadStartResponse(
            transferID: descriptor.transferID,
            offset: offset,
            maximumChunkBytes: Self.maximumChunkBytes
        )
    }

    private func writeUploadChunk(
        transferID: UUID,
        offset: UInt64,
        data: Data
    ) async throws -> MacRemoteDashboardUploadChunkResponse {
        guard uploadDescriptors[transferID] != nil else {
            throw MacFileSyncError.transferNotFound(transferID)
        }
        guard !data.isEmpty, data.count <= Self.maximumChunkBytes else {
            throw MacRemoteDashboardFileServiceError.invalidChunkSize(data.count)
        }
        let nextOffset = try await store.writeIncoming(
            transferID: transferID,
            offset: offset,
            data: data
        )
        return MacRemoteDashboardUploadChunkResponse(
            transferID: transferID,
            offset: nextOffset
        )
    }

    private func completeUpload(
        transferID: UUID
    ) async throws -> MacRemoteDashboardUploadCompleteResponse {
        guard uploadDescriptors[transferID] != nil else {
            throw MacFileSyncError.transferNotFound(transferID)
        }
        do {
            let completed = try await store.completeIncoming(transferID: transferID)
            uploadDescriptors.removeValue(forKey: transferID)
            return MacRemoteDashboardUploadCompleteResponse(
                transferID: completed.transferID,
                relativePath: completed.relativePath,
                byteCount: completed.byteCount,
                sha256: completed.sha256,
                reusedExistingFile: completed.reusedExistingFile
            )
        } catch {
            if case MacFileSyncError.checksumMismatch = error {
                uploadDescriptors.removeValue(forKey: transferID)
            }
            throw error
        }
    }

    private func cancelUpload(transferID: UUID) async {
        guard uploadDescriptors.removeValue(forKey: transferID) != nil else { return }
        await store.cancelIncoming(transferID: transferID, reason: "手机端取消上传")
    }

    private func directorySnapshot() async -> DirectorySnapshot {
        await MainActor.run {
            DirectorySnapshot(
                url: store.directoryURL,
                isEnabled: store.isEnabled,
                isOperational: store.isOperational
            )
        }
    }

    private func operationalRootURL() async throws -> URL {
        let directory = await directorySnapshot()
        guard directory.isOperational else {
            if directory.url == nil {
                throw MacFileSyncError.directoryUnavailable
            }
            throw MacFileSyncError.syncDisabled
        }
        return try directory.url.orThrow(MacFileSyncError.directoryUnavailable)
    }

    private static func scanFiles(rootURL: URL) throws -> [MacRemoteDashboardFileItem] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw MacFileSyncError.directoryUnavailable
        }

        var items: [MacRemoteDashboardFileItem] = []
        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let filePath = fileURL.standardizedFileURL.path
            if filePath.hasPrefix(rootPrefix) {
                let rawRelativePath = String(filePath.dropFirst(rootPrefix.count))
                if MacSyncFileUtilities.shouldIgnore(relativePath: rawRelativePath) {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
            }
            guard values.isRegularFile == true else { continue }
            guard let relativePath = try? MacSyncFileUtilities.relativePath(
                for: fileURL,
                under: rootURL
            ) else {
                continue
            }
            let byteCount = UInt64(max(values.fileSize ?? 0, 0))
            items.append(MacRemoteDashboardFileItem(
                relativePath: relativePath,
                name: fileURL.lastPathComponent,
                byteCount: byteCount,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                mediaKind: mediaKind(for: fileURL),
                contentType: contentType(for: fileURL)
            ))
        }
        return items.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private static func safeExistingFile(relativePath: String, rootURL: URL) throws -> URL {
        let normalized = try MacSyncFileUtilities.normalizedRelativePath(relativePath)
        let components = normalized.split(separator: "/").map(String.init)
        var current = rootURL.standardizedFileURL

        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: index < components.count - 1)
            let values = try current.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else {
                throw MacFileSyncError.unsafeRelativePath(relativePath)
            }
            if index < components.count - 1 {
                guard values.isDirectory == true else {
                    throw MacFileSyncError.unsafeRelativePath(relativePath)
                }
            } else {
                guard values.isRegularFile == true else {
                    throw MacFileSyncError.sourceReadFailed("目标不是普通文件。")
                }
            }
        }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedFile = current.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedFile.hasPrefix(prefix) else {
            throw MacFileSyncError.unsafeRelativePath(relativePath)
        }
        return current
    }

    private static func contentType(for fileURL: URL) -> String {
        UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private static func mediaKind(for fileURL: URL) -> String {
        guard let type = UTType(filenameExtension: fileURL.pathExtension) else { return "other" }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) { return "video" }
        if type.conforms(to: .audio) { return "audio" }
        if type.conforms(to: .pdf) || type.conforms(to: .text) { return "document" }
        if type.conforms(to: .archive) { return "archive" }
        return "other"
    }

    private static func jpegThumbnail(fileURL: URL, maximumPixel: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixel
                ] as CFDictionary
              ) else {
            throw MacRemoteDashboardFileServiceError.previewGenerationFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw MacRemoteDashboardFileServiceError.previewGenerationFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.68] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw MacRemoteDashboardFileServiceError.previewGenerationFailed
        }
        return output as Data
    }

    private static func errorResponse(_ error: MacFileSyncError) -> MacRemoteDashboardHTTPResponse {
        let status: Int
        switch error {
        case .fileTooLarge:
            status = 413
        case .transferNotFound:
            status = 404
        case .syncDisabled, .directoryUnavailable, .unexpectedOffset, .incompleteTransfer,
             .checksumMismatch, .sourceChanged:
            status = 409
        case .unsafeRelativePath, .unsupportedTemporaryFile, .invalidDigest,
             .invalidDirection, .chunkExceedsDeclaredSize:
            status = 400
        case .insufficientStorage, .sourceReadFailed, .destinationWriteFailed:
            status = 500
        }
        return .jsonError(error.localizedDescription, status: status)
    }
}

private enum MacRemoteDashboardFileServiceError: LocalizedError {
    case invalidChunkSize(Int)
    case previewRequiresImage
    case previewGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidChunkSize(let byteCount):
            "上传分片大小无效（\(byteCount) 字节）。"
        case .previewRequiresImage:
            "只有图片文件支持低流量预览。"
        case .previewGenerationFailed:
            "这张图片暂时无法生成低流量预览。"
        }
    }
}

private extension Optional {
    func orThrow(_ error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
