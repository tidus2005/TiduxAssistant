import CodexWatchBridgeCore
import CodexWatchCore
import Foundation
import Testing

@Suite("Voice approval safety")
struct VoiceApprovalSafetyTests {
    @Test func mismatchedThreadTurnAndRequestKindNeverReachRouter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = AppServerApprovalRequest(rawRequestId: .int(42), threadId: "thread", turnId: "turn", itemId: "item", command: "swift test")
        let router = StubAppServerApprovalRouter(approvals: [request])
        let runtime = BridgeRuntime(codexHome: directory.appendingPathComponent("codex"), bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false, shell: StubShell(outputs: ["/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")]),
            launcher: StubDetachedLauncher(), processController: StubProcessController(), appServerApprovalRouter: router)
        let pairing = try runtime.ensurePairing()
        for (thread, turn, type) in [("other", "turn", BridgeCommandType.approve), ("thread", "old-turn", .decline), ("thread", "turn", .continueThread)] {
            let command = BridgeCommand(type: type, threadId: thread, turnId: turn, payload: ["requestId": request.id, "prompt": "同意"],
                confirmation: CommandConfirmation(displayedSummary: "review", riskAccepted: true))
            let result = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
            #expect(!result.accepted)
        }
        #expect(router.resolved.isEmpty)
        #expect(router.userInputReplies.isEmpty)
        #expect(router.approvals.count == 1)
    }

    @Test func liveApprovalOverridesExistingSQLiteThreadPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = AppServerApprovalRequest(rawRequestId: .int(42), threadId: "thread", turnId: "turn", itemId: "item", command: "swift test")
        let json = #"[{"id":"thread","title":"Existing task","cwd":"/tmp","updated_at":1000,"preview":"old preview","tokens_used":1}]"#
        let runtime = BridgeRuntime(codexHome: directory.appendingPathComponent("codex"), bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false, shell: StubShell(outputs: ["/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: json, stderr: "")]),
            launcher: StubDetachedLauncher(), processController: StubProcessController(), appServerApprovalRouter: StubAppServerApprovalRouter(approvals: [request]))
        let snapshot = try #require(runtime.snapshot().snapshots.first)
        #expect(snapshot.title == "Existing task")
        #expect(snapshot.status == .waitingForApproval)
        #expect(snapshot.pendingRequest?.metadata["turnId"] == "turn")
        #expect(snapshot.pendingRequest?.metadata["command"] == "swift test")
    }
}
