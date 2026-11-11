import CodexMobilityCore
import Foundation

public extension MacSyncFileDescriptor {
    init(metadata: SyncItemMetadata) throws {
        let metadata = try metadata.validated()
        self.init(
            transferID: metadata.transferID,
            relativePath: metadata.relativePath,
            byteCount: metadata.byteSize,
            modifiedAt: metadata.modifiedAt,
            sha256: metadata.sha256
        )
    }

    func syncMetadata(direction: SyncDirection) -> SyncItemMetadata {
        SyncItemMetadata(
            transferID: transferID,
            direction: direction,
            mediaType: MacSyncMediaClassifier.mediaType(for: relativePath),
            relativePath: relativePath,
            byteSize: byteCount,
            modifiedAt: modifiedAt,
            sha256: sha256
        )
    }
}

public enum MacSyncMediaClassifier {
    private static let imageExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "bmp"
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mpeg", "mpg"
    ]

    public static func mediaType(for relativePath: String) -> SyncMediaType {
        let pathExtension = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        if imageExtensions.contains(pathExtension) { return .image }
        if videoExtensions.contains(pathExtension) { return .video }
        return .file
    }
}
