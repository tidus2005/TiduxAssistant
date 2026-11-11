import CodexMobilityCore
import Foundation

@MainActor
public protocol MobilityPhonePhotoImporting {
    func addToPhotoLibrary(fileURL: URL, mediaType: SyncMediaType) async throws
}

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(Photos)
import Photos

public struct SystemMobilityPhonePhotoImporter: MobilityPhonePhotoImporting {
    public init() {}

    public func addToPhotoLibrary(fileURL: URL, mediaType: SyncMediaType) async throws {
        guard mediaType == .image || mediaType == .video else { return }

        var authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard authorization == .authorized || authorization == .limited else {
            throw MobilityPhoneSyncError.photoLibraryDenied
        }

        try await Self.writeAsset(fileURL: fileURL, mediaType: mediaType)
    }

    // Photos executes change blocks on its own queue, not the caller's MainActor.
    nonisolated private static func writeAsset(fileURL: URL, mediaType: SyncMediaType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges { @Sendable in
                switch mediaType {
                case .image:
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                case .video:
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                case .file:
                    break
                }
            } completionHandler: { @Sendable didSucceed, error in
                if didSucceed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error
                            ?? MobilityPhoneSyncError.photoImportFailed("照片图库未接受该文件")
                    )
                }
            }
        }
    }
}
#else
/// SwiftPM's macOS tests exercise the durable Files path without mutating a photo library.
public struct SystemMobilityPhonePhotoImporter: MobilityPhonePhotoImporting {
    public init() {}

    public func addToPhotoLibrary(fileURL: URL, mediaType: SyncMediaType) async throws {}
}
#endif
