import Foundation
import Testing
@testable import CodexMobilityCore

@Suite("Syncthing transfer folder IDs")
struct SyncthingTransferFolderIDTests {
    @Test("A transfer ID round trips through its canonical folder ID")
    func roundTrip() {
        let transferID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let folderID = SyncthingTransferFolderID.make(transferID: transferID)

        #expect(folderID == "codex-sync-transfer:12345678-1234-1234-1234-1234567890ab")
        #expect(SyncthingTransferFolderID.transferID(from: folderID) == transferID)
    }

    @Test("Malformed or unrelated folder IDs are rejected")
    func rejectsMalformedValues() {
        #expect(SyncthingTransferFolderID.transferID(from: "codex-sync") == nil)
        #expect(SyncthingTransferFolderID.transferID(from: "codex-sync-transfer:") == nil)
        #expect(SyncthingTransferFolderID.transferID(
            from: "other:12345678-1234-1234-1234-1234567890ab"
        ) == nil)
        #expect(SyncthingTransferFolderID.transferID(
            from: "codex-sync-transfer:12345678-1234-1234-1234-1234567890ab-extra"
        ) == nil)
    }
}
