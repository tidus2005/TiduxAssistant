import CodexWatchCore
import Foundation
import Testing

@Suite("Watch assistant review")
struct AssistantCommandDraftTests {
    private func approval() -> TaskSnapshot {
        var snapshot = TaskSnapshot.sampleApproval
        snapshot.pendingRequest = PendingRequest(id: "appserver:42", title: "Approve", summary: "运行测试",
            requiredAction: .approve, metadata: ["turnId": "turn-1", "command": "swift test", "cwd": "/tmp/project"])
        return snapshot
    }

    @Test func approvalCarriesScopeAndDisplayedOperation() throws {
        let snapshot = approval()
        let draft = try AssistantCommandDraft(snapshot: snapshot, type: .approve)
        let command = try draft.confirmed(for: snapshot)
        #expect(command.threadId == snapshot.threadId)
        #expect(command.turnId == "turn-1")
        #expect(command.payload["requestId"] == "appserver:42")
        #expect(command.confirmation?.displayedSummary.contains("swift test") == true)
        #expect(command.confirmation?.riskAccepted == true)
    }

    @Test func changedRequestAndExpiredReviewCannotBeConfirmed() throws {
        let now = Date()
        var snapshot = approval()
        let draft = try AssistantCommandDraft(snapshot: snapshot, type: .approve, now: now)
        #expect(throws: AssistantDraftError.self) { try draft.confirmed(for: snapshot, now: now.addingTimeInterval(121)) }
        snapshot.pendingRequest?.metadata["command"] = "delete files"
        #expect(throws: AssistantDraftError.self) { try draft.confirmed(for: snapshot) }
    }

    @Test func speechCannotApproveAnOutstandingRequest() {
        #expect(throws: AssistantDraftError.self) { try AssistantCommandDraft(snapshot: approval(), type: .continueThread, text: "全部同意") }
    }

    @Test func replyRequiresOneCurrentQuestionAndNonemptyTranscript() throws {
        var snapshot = approval()
        snapshot.status = .waitingForInput
        snapshot.pendingRequest?.requiredAction = .reply
        snapshot.pendingRequest?.metadata["questionIds"] = "q1, q2"
        #expect(throws: AssistantDraftError.self) { try AssistantCommandDraft(snapshot: snapshot, type: .continueThread, text: "继续") }
        snapshot.pendingRequest?.metadata["questionIds"] = "q1"
        #expect(throws: AssistantDraftError.self) { try AssistantCommandDraft(snapshot: snapshot, type: .continueThread, text: "  ") }
        let draft = try AssistantCommandDraft(snapshot: snapshot, type: .continueThread, text: "  使用当前方案  ")
        #expect(draft.command.payload["prompt"] == "使用当前方案")
        #expect(draft.command.payload["requestId"] == "appserver:42")
    }

    @Test func runningTaskCannotLaunchConcurrentVoiceTurn() {
        #expect(throws: AssistantDraftError.self) { try AssistantCommandDraft(snapshot: .sampleActive, type: .continueThread, text: "继续") }
    }

    @Test func oldOrFutureAuthorizationCannotBeRenewedByFreshEnvelope() {
        let now = Date()
        for offset in [-121.0, 10.0] {
            let command = BridgeCommand(type: .approve,
                confirmation: CommandConfirmation(confirmedAt: now.addingTimeInterval(offset), displayedSummary: "approve", riskAccepted: true), createdAt: now)
            #expect(throws: CommandSecurityError.staleConfirmation) {
                try CommandAuthorizer(requireSignature: false).validate(command: command, signature: nil, secret: Data(), nonceStore: NonceStore(), now: now)
            }
        }
    }
}
