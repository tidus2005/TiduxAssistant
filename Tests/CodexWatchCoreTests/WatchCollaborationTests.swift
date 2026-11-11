import CodexWatchCore
import Foundation
import Testing

@Suite("AI collaboration complications")
struct WatchCollaborationTests {
    @Test func routesRoundTripWithOpaqueThreadIDs() {
        for component in WatchCollaborationComponent.allCases {
            let route = WatchCollaborationRoute(component: component, threadID: "task/a?b=&中文")
            #expect(WatchCollaborationRoute(url: route.url) == route)
        }
        #expect(Set(CodexWatchWidgetConstants.kinds).count == 5)
        #expect(WatchCollaborationComponent.overview.widgetKind == "CodexWatchPetWidget")
    }

    @Test(arguments: ["https://watch/ask", "codexwatchpet://other/ask", "codexwatchpet://watch/approve",
                      "codexwatchpet://watch/approvals?command=approve", "codexwatchpet://watch/ask?thread=",
                      "codexwatchpet://watch/progress?thread=a&thread=b", "codexwatchpet://user@watch/arena"])
    func ignoresUnknownOrExecutableLinks(_ link: String) throws {
        #expect(WatchCollaborationRoute(url: try #require(URL(string: link))) == nil)
    }

    @Test func approvalsDoNotCountFailuresOrInputRequests() {
        var approval = TaskSnapshot.sampleApproval
        approval.threadId = "approval"
        var failure = approval
        failure.threadId = "failed"
        failure.status = .failed
        failure.pendingRequest = nil
        var input = approval
        input.threadId = "input"
        input.status = .waitingForInput
        input.pendingRequest?.requiredAction = .reply
        var active = TaskSnapshot.sampleActive
        active.threadId = "running"
        let summary = WatchCollaborationSummary(snapshots: [failure, input, approval, active],
                                               bridgeOnline: true, savedAt: Date())
        #expect(summary.approvalTasks.map(\.threadId) == ["approval"])
        #expect(summary.inputTasks.map(\.threadId) == ["input"])
        #expect(summary.runningTasks.map(\.threadId) == ["running"])
        #expect(summary.route(for: .approvals).threadID == "approval")
        #expect(summary.route(for: .progress).threadID == "running")
        #expect(summary.route(for: .ask).threadID == nil)
    }

    @Test func oldCachedStatesAreNotPresentedAsLive() {
        let now = Date()
        let summary = WatchCollaborationSummary(snapshots: [.sampleActive], bridgeOnline: true,
                                               savedAt: now.addingTimeInterval(-601), now: now)
        #expect(summary.freshness.isStale)
        #expect(summary.connectionLabel == "待更新 · 上次状态")
        let offline = WatchCollaborationSummary(snapshots: [], bridgeOnline: false, savedAt: now, now: now)
        #expect(offline.connectionLabel == "Mac 桥接离线")
        let missing = WatchCollaborationSummary(snapshots: [], bridgeOnline: false, savedAt: nil, now: now)
        #expect(missing.connectionLabel == "尚未同步")
    }

    @Test func newQuestionNeedsFreshExplicitReview() throws {
        let now = Date()
        #expect(throws: AssistantDraftError.self) { try WatchQuestionDraft(text: " \n ") }
        let draft = try WatchQuestionDraft(text: "  解释这个方案  ", now: now)
        #expect(draft.command.confirmation == nil)
        let command = try draft.confirmed(now: now.addingTimeInterval(10))
        #expect(command.type == .startThread)
        #expect(command.threadId == nil)
        #expect(command.payload["prompt"] == "解释这个方案")
        #expect(command.confirmation?.riskAccepted == true)
        #expect(throws: AssistantDraftError.self) { try draft.confirmed(now: now.addingTimeInterval(121)) }
        #expect(throws: AssistantDraftError.self) { try draft.confirmed(now: now.addingTimeInterval(-1)) }
    }
}
