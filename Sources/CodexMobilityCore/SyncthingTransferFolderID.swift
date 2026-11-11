import Foundation

/// A stable, opaque folder identifier for one file transfer.
///
/// The first app release has a queue of individual files rather than a persisted
/// whole-folder database. Giving every queued transfer its own folder ID lets the
/// block coordinator resume that file without exposing local paths on the wire.
public enum SyncthingTransferFolderID {
    public static let prefix = "codex-sync-transfer:"

    public static func make(transferID: UUID) -> String {
        prefix + transferID.uuidString.lowercased()
    }

    public static func transferID(from folderID: String) -> UUID? {
        guard folderID.hasPrefix(prefix) else { return nil }
        let rawID = String(folderID.dropFirst(prefix.count))
        guard rawID.count == 36,
              !rawID.contains(where: \Character.isWhitespace),
              let transferID = UUID(uuidString: rawID),
              make(transferID: transferID) == folderID.lowercased() else {
            return nil
        }
        return transferID
    }
}
