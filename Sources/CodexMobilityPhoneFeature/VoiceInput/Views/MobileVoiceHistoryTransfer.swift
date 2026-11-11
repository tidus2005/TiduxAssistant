#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreTransferable
import CodexMobilityCore
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let flowTypeVoiceHistoryBackup = UTType(
        exportedAs:
            VoiceHistoryBackupFormat.contentTypeIdentifier,
        conformingTo: .package
    )
}

struct MobileVoiceHistoryBackupTransfer: Transferable {
    let packageURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            exportedContentType: .flowTypeVoiceHistoryBackup
        ) { item in
            SentTransferredFile(
                item.packageURL,
                allowAccessingOriginalFile: true
            )
        }
    }
}
#endif
