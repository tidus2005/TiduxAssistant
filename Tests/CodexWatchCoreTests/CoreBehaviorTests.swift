import AppKit
import CodexWatchCore
import Foundation
import Testing

@Suite("Core behavior")
struct CoreBehaviorTests {
    @Test
    func reducerCreatesApprovalSnapshot() {
        let event = BridgeEvent(
            sequence: 7,
            threadId: "thread-1",
            type: .approvalRequested,
            title: "Approve command",
            summary: "Codex wants to run a command.",
            urgency: .high,
            petMood: .needsApproval,
            actions: []
        )

        let snapshots = TaskStateReducer().reduce(snapshots: [], event: event)

        #expect(snapshots.count == 1)
        #expect(snapshots[0].status == .waitingForApproval)
        #expect(snapshots[0].pendingRequest?.requiredAction == .approve)
        #expect(snapshots[0].urgency == .high)
    }

    @Test
    func reducerCreatesInputRequestSnapshot() {
        let event = BridgeEvent(
            sequence: 8,
            threadId: "thread-1",
            type: .inputRequested,
            title: "Missing input",
            summary: "Codex needs a scope decision.",
            urgency: .high,
            petMood: .needsInput,
            actions: []
        )

        let snapshots = TaskStateReducer().reduce(snapshots: [], event: event)

        #expect(snapshots.count == 1)
        #expect(snapshots[0].status == .waitingForInput)
        #expect(snapshots[0].pendingRequest?.requiredAction == .reply)
        #expect(snapshots[0].petMood == .needsInput)
    }

    @Test
    func reducerPreservesAppServerPendingRequestId() {
        let event = BridgeEvent(
            id: "appserver-approval-appserver:input-live",
            sequence: 9,
            threadId: "thread-live",
            type: .inputRequested,
            title: "Codex needs input",
            summary: "Choose a release path.",
            urgency: .high,
            petMood: .needsInput,
            actions: []
        )

        let snapshots = TaskStateReducer().reduce(snapshots: [], event: event)

        #expect(snapshots[0].pendingRequest?.id == "appserver:input-live")
    }

    @Test
    func reducerPreservesAppServerPendingRequestIdFromRetryEvent() {
        let event = BridgeEvent(
            id: "appserver-approval-appserver:input-live#retry-command-1",
            sequence: 10,
            threadId: "thread-live",
            type: .inputRequested,
            title: "Reply not sent",
            summary: "Retry from Watch.",
            urgency: .high,
            petMood: .needsInput,
            actions: []
        )

        let snapshots = TaskStateReducer().reduce(snapshots: [], event: event)

        #expect(snapshots[0].pendingRequest?.id == "appserver:input-live")
    }

    @Test
    func bridgeStateSelectsLatestPendingRequestByActionAndAttention() {
        let now = Date()
        let olderApproval = TaskSnapshot(
            id: "approval-old",
            threadId: "approval-old",
            title: "Older approval",
            cwd: "",
            status: .waitingForApproval,
            lastSummary: "Medium priority",
            pendingRequest: PendingRequest(
                id: "request-old",
                title: "Older approval",
                summary: "Run optional command.",
                requiredAction: .approve,
                createdAt: now.addingTimeInterval(-120)
            ),
            updatedAt: now.addingTimeInterval(-120),
            urgency: .medium
        )
        let latestApproval = TaskSnapshot(
            id: "approval-latest",
            threadId: "approval-latest",
            title: "Latest approval",
            cwd: "",
            status: .waitingForApproval,
            lastSummary: "High priority",
            pendingRequest: PendingRequest(
                id: "request-latest",
                title: "Latest approval",
                summary: "Run required command.",
                requiredAction: .approve,
                createdAt: now
            ),
            updatedAt: now,
            urgency: .high
        )
        let input = TaskSnapshot(
            id: "input",
            threadId: "input",
            title: "Needs reply",
            cwd: "",
            status: .waitingForInput,
            lastSummary: "Needs input",
            pendingRequest: PendingRequest(
                id: "request-input",
                title: "Needs reply",
                summary: "Pick a path.",
                requiredAction: .reply,
                createdAt: now.addingTimeInterval(60)
            ),
            updatedAt: now.addingTimeInterval(60),
            urgency: .high
        )
        let state = BridgeState(
            snapshots: [olderApproval, input, latestApproval],
            events: [],
            unreadHighUrgencyCount: 2,
            bridgeOnline: true,
            pairStatus: PairStatus(paired: true)
        )

        #expect(state.latestPendingRequest(requiring: .approve)?.pendingRequest?.id == "request-latest")
        #expect(state.latestPendingRequest(requiring: .reply)?.pendingRequest?.id == "request-input")
    }

    @Test
    func focusDigestHighlightsPendingApprovalContext() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = TaskSnapshot(
            id: "approval",
            threadId: "approval",
            title: "Ship local bridge",
            cwd: "/Users/example/myapps/CodexWatchPet",
            status: .waitingForApproval,
            lastSummary: "Fallback summary",
            pendingRequest: PendingRequest(
                id: "appserver:approval-request-42",
                title: "Approve command",
                summary: "Run bridge integration test.",
                requiredAction: .approve,
                createdAt: now.addingTimeInterval(-120)
            ),
            elapsedSeconds: 3_900,
            tokensUsed: 15_320,
            updatedAt: now,
            urgency: .high
        )

        let digest = snapshot.focusDigest(now: now)

        #expect(digest.headline == "Approve command")
        #expect(digest.detail == "Run bridge integration test.")
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Status", value: "Approval")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Needs", value: "Approve")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Request", value: "appserver:approval-reques...")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Waiting", value: "2m")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Runtime", value: "1h 5m")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Tokens", value: "15k")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Folder", value: "CodexWatchPet")))
    }

    @Test
    func focusDigestShowsSnoozeRemainingForStatusOnlyTask() {
        let now = Date(timeIntervalSince1970: 2_000)
        let snapshot = TaskSnapshot(
            id: "active",
            threadId: "active",
            title: "Implement Watch detail",
            cwd: "",
            status: .active,
            lastSummary: "Codex is editing the watch UI.",
            updatedAt: now,
            urgency: .medium,
            snoozedUntil: now.addingTimeInterval(900)
        )

        let digest = snapshot.focusDigest(now: now)

        #expect(digest.headline == "Active")
        #expect(digest.detail == "Codex is editing the watch UI.")
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Snoozed", value: "15m")))
    }

    @Test
    func focusDigestShowsFileChangeApprovalRiskContext() {
        let now = Date(timeIntervalSince1970: 3_000)
        let snapshot = TaskSnapshot(
            id: "file-approval",
            threadId: "file-approval",
            title: "Codex needs file approval",
            cwd: "/tmp/project",
            status: .waitingForApproval,
            lastSummary: "Approve file changes under /tmp/project.",
            pendingRequest: PendingRequest(
                id: "appserver:file-live",
                title: "Approve Codex request",
                summary: "Approve file changes under /tmp/project.",
                requiredAction: .approve,
                createdAt: now.addingTimeInterval(-30),
                metadata: [
                    "requestKind": "fileChangeApproval",
                    "grantRoot": "/tmp/project",
                    "command": "apply_patch",
                    "cwd": "/tmp/project"
                ]
            ),
            updatedAt: now,
            urgency: .high
        )

        let digest = snapshot.focusDigest(now: now)

        #expect(digest.items.contains(TaskFocusDigestItem(label: "Type", value: "File change")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Risk", value: "File changes")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Scope", value: "tmp/project")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "Command", value: "apply_patch")))
        #expect(digest.items.contains(TaskFocusDigestItem(label: "CWD", value: "tmp/project")))
    }

    @Test
    func pendingRequestDecodesLegacyPayloadWithoutMetadata() throws {
        let json = """
        {
          "id": "request-legacy",
          "title": "Legacy request",
          "summary": "Old bridge state.",
          "requiredAction": "approve",
          "createdAt": "2026-06-01T00:00:00Z"
        }
        """

        let request = try JSONDecoder.codexWatchPet.decode(PendingRequest.self, from: Data(json.utf8))

        #expect(request.metadata.isEmpty)
    }

    @Test
    func bridgeStateDecodesMissingLiveControlStatusAsDisabled() throws {
        let json = """
        {
          "snapshots" : [],
          "events" : [],
          "unreadHighUrgencyCount" : 0,
          "bridgeOnline" : true,
          "pairStatus" : {
            "paired" : false
          },
          "generatedAt" : "2026-06-01T00:00:00Z"
        }
        """

        let state = try JSONDecoder.codexWatchPet.decode(BridgeState.self, from: Data(json.utf8))

        #expect(state.liveControlStatus.state == .disabled)
        #expect(state.liveControlStatus.displayName == "Live control off")
    }

    @Test
    func liveControlStatusMarksDisconnectedAsDegraded() {
        let status = LiveControlStatus(
            state: .disconnected,
            pendingRequestCount: 2,
            lastError: "socket unavailable"
        )

        #expect(status.isDegraded == true)
        #expect(status.displayName == "Live control disconnected")
        #expect(status.symbolName == "wifi.exclamationmark")
    }

    @Test
    func everyLiveControlStatusUsesAnAvailableSystemSymbol() {
        for state in LiveControlConnectionState.allCases {
            let symbolName = LiveControlStatus(state: state).symbolName
            #expect(
                NSImage(
                    systemSymbolName: symbolName,
                    accessibilityDescription: nil
                ) != nil,
                "Missing SF Symbol: \(symbolName)"
            )
        }
    }

    @Test
    func attentionQueuePrioritizesHumanActionBeforeStatusOnlyUpdates() {
        let now = Date()
        let completed = TaskSnapshot(
            id: "completed",
            threadId: "completed",
            title: "Completed",
            cwd: "",
            status: .completed,
            lastSummary: "Done",
            updatedAt: now,
            urgency: .high
        )
        let failed = TaskSnapshot(
            id: "failed",
            threadId: "failed",
            title: "Failed",
            cwd: "",
            status: .failed,
            lastSummary: "Needs review",
            updatedAt: now.addingTimeInterval(-10),
            urgency: .high
        )
        let approval = TaskSnapshot(
            id: "approval",
            threadId: "approval",
            title: "Approval",
            cwd: "",
            status: .waitingForApproval,
            lastSummary: "Needs approval",
            updatedAt: now.addingTimeInterval(-20),
            urgency: .medium
        )
        let input = TaskSnapshot(
            id: "input",
            threadId: "input",
            title: "Input",
            cwd: "",
            status: .waitingForInput,
            lastSummary: "Needs input",
            updatedAt: now.addingTimeInterval(-30),
            urgency: .low
        )

        let queue = [completed, failed, approval, input].attentionQueue(limit: 3)

        #expect(queue.map(\.threadId) == ["input", "approval", "failed"])
    }

    @Test
    func attentionQueueFiltersIdleTasksAndHonorsLimit() {
        let now = Date()
        let activeHigh = TaskSnapshot(
            id: "active",
            threadId: "active",
            title: "Active",
            cwd: "",
            status: .active,
            lastSummary: "Important progress",
            updatedAt: now,
            urgency: .high
        )
        let idle = TaskSnapshot(
            id: "idle",
            threadId: "idle",
            title: "Idle",
            cwd: "",
            status: .idle,
            lastSummary: "Idle",
            updatedAt: now.addingTimeInterval(10),
            urgency: .low
        )
        let approval = TaskSnapshot(
            id: "approval",
            threadId: "approval",
            title: "Approval",
            cwd: "",
            status: .waitingForApproval,
            lastSummary: "Needs approval",
            updatedAt: now.addingTimeInterval(-10),
            urgency: .medium
        )

        let queue = [idle, activeHigh, approval].attentionQueue(limit: 1)

        #expect(queue.map(\.threadId) == ["approval"])
        #expect(idle.needsAttention == false)
    }

    @Test
    func snoozedStatusOnlyTasksLeaveAttentionQueue() {
        let now = Date()
        let snoozedFailure = TaskSnapshot(
            id: "failed",
            threadId: "failed",
            title: "Failed",
            cwd: "",
            status: .failed,
            lastSummary: "Review later",
            updatedAt: now,
            urgency: .high,
            snoozedUntil: now.addingTimeInterval(900)
        )
        let pendingInput = TaskSnapshot(
            id: "input",
            threadId: "input",
            title: "Input",
            cwd: "",
            status: .waitingForInput,
            lastSummary: "Needs input",
            pendingRequest: PendingRequest(title: "Input", summary: "Pick one.", requiredAction: .reply),
            updatedAt: now,
            urgency: .high,
            snoozedUntil: now.addingTimeInterval(900)
        )

        let queue = [snoozedFailure, pendingInput].attentionQueue(limit: 5)

        #expect(snoozedFailure.needsAttention(at: now) == false)
        #expect(pendingInput.needsAttention(at: now) == true)
        #expect(queue.map(\.threadId) == ["input"])
    }

    @Test
    func progressNotificationsAreThrottled() {
        let now = Date()
        let previous = BridgeEvent(
            sequence: 1,
            threadId: "thread-1",
            type: .turnProgress,
            title: "Progress",
            summary: "Older event",
            urgency: .medium,
            petMood: .thinking,
            actions: [],
            createdAt: now.addingTimeInterval(-60)
        )
        let next = BridgeEvent(
            sequence: 2,
            threadId: "thread-1",
            type: .turnProgress,
            title: "Progress",
            summary: "New event",
            urgency: .medium,
            petMood: .thinking,
            actions: [],
            createdAt: now
        )

        let decision = NotificationPolicy(progressCooldown: 180).decision(
            for: next,
            previousEventForThread: previous,
            now: now
        )

        #expect(decision.shouldNotify == false)
        #expect(decision.reason == "progress throttled")
    }

    @Test
    func highUrgencyBypassesThrottle() {
        let now = Date()
        let previous = BridgeEvent(
            sequence: 1,
            threadId: "thread-1",
            type: .turnProgress,
            title: "Progress",
            summary: "Older event",
            urgency: .medium,
            petMood: .thinking,
            actions: [],
            createdAt: now
        )
        let next = BridgeEvent(
            sequence: 2,
            threadId: "thread-1",
            type: .approvalRequested,
            title: "Approval",
            summary: "Needs approval",
            urgency: .high,
            petMood: .needsApproval,
            actions: [],
            createdAt: now
        )

        let decision = NotificationPolicy().decision(for: next, previousEventForThread: previous, now: now)

        #expect(decision.shouldNotify == true)
        #expect(decision.reason == "high urgency")
    }

    @Test
    func notificationPlannerDeduplicatesAlreadySeenEvents() {
        let event = BridgeEvent(
            id: "approval-1",
            sequence: 1,
            threadId: "thread-1",
            type: .approvalRequested,
            title: "Approval",
            summary: "Needs approval",
            urgency: .high,
            petMood: .needsApproval,
            actions: []
        )
        let planner = NotificationPlanner()

        let first = planner.plan(for: [event], state: NotificationPlannerState())
        let second = planner.plan(for: [event], state: first.state)

        #expect(first.notifications.map(\.event.id) == ["approval-1"])
        #expect(second.notifications.isEmpty)
    }

    @Test
    func attentionHapticPlannerSignalsOnlyNewHighSignalEvents() {
        let progress = BridgeEvent(
            id: "progress-1",
            sequence: 1,
            threadId: "thread-1",
            type: .turnProgress,
            title: "Progress",
            summary: "Low priority progress",
            urgency: .medium,
            petMood: .thinking,
            actions: []
        )
        let input = BridgeEvent(
            id: "input-1",
            sequence: 2,
            threadId: "thread-1",
            type: .inputRequested,
            title: "Input",
            summary: "Needs user input",
            urgency: .high,
            petMood: .needsInput,
            actions: []
        )
        let planner = AttentionHapticPlanner()

        let first = planner.plan(for: [progress, input], state: AttentionHapticPlannerState())
        let second = planner.plan(for: [progress, input], state: first.state)

        #expect(first.haptic == .notification)
        #expect(second.haptic == nil)
    }

    @Test
    func attentionHapticPlannerPrioritizesFailureOverCompletion() {
        let completed = BridgeEvent(
            id: "done-1",
            sequence: 1,
            threadId: "thread-1",
            type: .turnCompleted,
            title: "Done",
            summary: "Codex finished",
            urgency: .medium,
            petMood: .done,
            actions: []
        )
        let failed = BridgeEvent(
            id: "failed-1",
            sequence: 2,
            threadId: "thread-2",
            type: .turnFailed,
            title: "Failed",
            summary: "Codex failed",
            urgency: .high,
            petMood: .failed,
            actions: []
        )

        let result = AttentionHapticPlanner().plan(for: [completed, failed], state: AttentionHapticPlannerState())

        #expect(result.haptic == .failure)
    }

    @Test
    func attentionHapticPlannerSuppressesSnoozedNonHumanActionThreads() {
        let failed = BridgeEvent(
            id: "failed-1",
            sequence: 1,
            threadId: "thread-snoozed",
            type: .turnFailed,
            title: "Failed",
            summary: "Review later",
            urgency: .high,
            petMood: .failed,
            actions: []
        )
        let input = BridgeEvent(
            id: "input-1",
            sequence: 2,
            threadId: "thread-snoozed",
            type: .inputRequested,
            title: "Input",
            summary: "Needs user input",
            urgency: .high,
            petMood: .needsInput,
            actions: []
        )

        let result = AttentionHapticPlanner().plan(
            for: [failed, input],
            state: AttentionHapticPlannerState(),
            suppressingThreadIds: ["thread-snoozed"]
        )

        #expect(result.haptic == .notification)
        #expect(result.state.seenEventIds == Set(["failed-1", "input-1"]))
    }

    @Test
    func notificationPlannerDoesNotEmitLateStaleProgress() {
        let now = Date()
        let firstProgress = BridgeEvent(
            id: "progress-1",
            sequence: 1,
            threadId: "thread-1",
            type: .turnProgress,
            title: "Progress",
            summary: "Initial progress",
            urgency: .medium,
            petMood: .thinking,
            actions: [],
            createdAt: now.addingTimeInterval(-120)
        )
        let throttledProgress = BridgeEvent(
            id: "progress-2",
            sequence: 2,
            threadId: "thread-1",
            type: .turnProgress,
            title: "Progress",
            summary: "Too soon",
            urgency: .medium,
            petMood: .thinking,
            actions: [],
            createdAt: now.addingTimeInterval(-60)
        )
        let planner = NotificationPlanner(policy: NotificationPolicy(progressCooldown: 180))

        let first = planner.plan(for: [firstProgress], state: NotificationPlannerState(), now: now)
        let second = planner.plan(for: [throttledProgress], state: first.state, now: now)
        let lateReplay = planner.plan(
            for: [throttledProgress],
            state: second.state,
            now: now.addingTimeInterval(240)
        )

        #expect(first.notifications.map(\.event.id) == ["progress-1"])
        #expect(second.notifications.isEmpty)
        #expect(lateReplay.notifications.isEmpty)
    }

    @Test
    func notificationPlannerEmitsFreshProgressAfterCooldown() {
        let now = Date()
        let firstProgress = BridgeEvent(
            id: "progress-1",
            sequence: 1,
            threadId: "thread-1",
            type: .turnProgress,
            title: "Progress",
            summary: "Initial progress",
            urgency: .medium,
            petMood: .thinking,
            actions: [],
            createdAt: now
        )
        let laterProgress = BridgeEvent(
            id: "progress-2",
            sequence: 2,
            threadId: "thread-1",
            type: .turnProgress,
            title: "Progress",
            summary: "Later progress",
            urgency: .medium,
            petMood: .thinking,
            actions: [],
            createdAt: now.addingTimeInterval(240)
        )
        let planner = NotificationPlanner(policy: NotificationPolicy(progressCooldown: 180))

        let first = planner.plan(for: [firstProgress], state: NotificationPlannerState(), now: now)
        let second = planner.plan(
            for: [laterProgress],
            state: first.state,
            now: now.addingTimeInterval(240)
        )

        #expect(first.notifications.map(\.event.id) == ["progress-1"])
        #expect(second.notifications.map(\.event.id) == ["progress-2"])
    }

    @Test
    func widgetStateStoreRoundTripsLatestBridgeState() throws {
        let suiteName = "CodexWatchPetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = WidgetStateStore(defaults: defaults)
        let state = BridgeState(
            snapshots: [.sampleActive],
            events: [],
            unreadHighUrgencyCount: 0,
            bridgeOnline: true,
            pairStatus: PairStatus(paired: true, deviceName: "Test Watch")
        )

        try store.save(state)
        let loaded = try #require(store.load())

        #expect(loaded.snapshots.first?.threadId == "thread-active")
        #expect(loaded.bridgeOnline == true)
        #expect(store.savedAt() != nil)
    }

    @Test
    func widgetSnapshotPrefersAttentionOverNewestIdleItem() {
        let now = Date()
        let idle = TaskSnapshot(
            id: "idle",
            threadId: "idle",
            title: "Idle newest",
            cwd: "",
            status: .idle,
            lastSummary: "Idle",
            updatedAt: now,
            urgency: .medium
        )
        let approval = TaskSnapshot(
            id: "approval",
            threadId: "approval",
            title: "Approval older",
            cwd: "",
            status: .waitingForApproval,
            lastSummary: "Needs approval",
            updatedAt: now.addingTimeInterval(-300),
            urgency: .medium
        )
        let state = BridgeState(
            snapshots: [idle, approval],
            events: [],
            unreadHighUrgencyCount: 0,
            bridgeOnline: true,
            pairStatus: PairStatus(paired: true)
        )

        #expect(state.widgetSnapshot?.threadId == "approval")
    }

    @Test
    func widgetSnapshotPrefersInputOverCompletedWithSameUrgency() {
        let now = Date()
        let completed = TaskSnapshot(
            id: "completed",
            threadId: "completed",
            title: "Completed newest",
            cwd: "",
            status: .completed,
            lastSummary: "Done",
            updatedAt: now,
            urgency: .high
        )
        let input = TaskSnapshot(
            id: "input",
            threadId: "input",
            title: "Needs answer",
            cwd: "",
            status: .waitingForInput,
            lastSummary: "Needs input",
            updatedAt: now.addingTimeInterval(-120),
            urgency: .high
        )
        let state = BridgeState(
            snapshots: [completed, input],
            events: [],
            unreadHighUrgencyCount: 1,
            bridgeOnline: true,
            pairStatus: PairStatus(paired: true)
        )

        #expect(state.widgetSnapshot?.threadId == "input")
    }

    @Test
    func widgetSnapshotSkipsSnoozedNoiseWhenOtherTaskExists() {
        let now = Date()
        let snoozedActive = TaskSnapshot(
            id: "active",
            threadId: "active",
            title: "Noisy progress",
            cwd: "",
            status: .active,
            lastSummary: "Status-only progress.",
            updatedAt: now,
            urgency: .high,
            snoozedUntil: now.addingTimeInterval(900)
        )
        let idle = TaskSnapshot(
            id: "idle",
            threadId: "idle",
            title: "Quiet idle",
            cwd: "",
            status: .idle,
            lastSummary: "No action.",
            updatedAt: now.addingTimeInterval(-60),
            urgency: .low
        )
        let state = BridgeState(
            snapshots: [snoozedActive, idle],
            events: [],
            unreadHighUrgencyCount: 0,
            bridgeOnline: true,
            pairStatus: PairStatus(paired: true)
        )

        #expect(state.widgetSnapshot?.threadId == "idle")
    }

    @Test
    func widgetSnapshotKeepsSnoozedTaskWhenItIsTheOnlyTask() {
        let now = Date()
        let snoozedActive = TaskSnapshot(
            id: "active",
            threadId: "active",
            title: "Noisy progress",
            cwd: "",
            status: .active,
            lastSummary: "Status-only progress.",
            updatedAt: now,
            urgency: .high,
            snoozedUntil: now.addingTimeInterval(900)
        )
        let state = BridgeState(
            snapshots: [snoozedActive],
            events: [],
            unreadHighUrgencyCount: 0,
            bridgeOnline: true,
            pairStatus: PairStatus(paired: true)
        )

        #expect(state.widgetSnapshot?.threadId == "active")
    }

    @Test
    func widgetPresentationMarksSnoozedTask() {
        let now = Date()
        let snapshot = TaskSnapshot(
            id: "active",
            threadId: "active",
            title: "Noisy progress",
            cwd: "",
            status: .active,
            lastSummary: "Status-only progress.",
            updatedAt: now,
            urgency: .medium,
            snoozedUntil: now.addingTimeInterval(900)
        )

        let presentation = snapshot.widgetPresentation(savedAt: now, now: now)

        #expect(presentation.symbolName == "bell.slash")
        #expect(presentation.status == "Snoozed")
        #expect(presentation.shortStatus == "Soon")
        #expect(presentation.detail == "Snoozed 15m - Status-only progress.")
        #expect(presentation.isSnoozed == true)
    }

    @Test
    func widgetPresentationUsesPendingRequestSummaryAndStaleStatus() {
        let now = Date()
        let snapshot = TaskSnapshot(
            id: "approval",
            threadId: "approval",
            title: "File approval",
            cwd: "",
            status: .waitingForApproval,
            lastSummary: "Fallback summary",
            pendingRequest: PendingRequest(
                id: "appserver:file",
                title: "Approve request",
                summary: "Approve changes under Sources.",
                requiredAction: .approve,
                createdAt: now.addingTimeInterval(-120)
            ),
            updatedAt: now,
            urgency: .high
        )

        let presentation = snapshot.widgetPresentation(savedAt: now.addingTimeInterval(-900), now: now)

        #expect(presentation.status == "Approval - Old")
        #expect(presentation.shortStatus == "Old")
        #expect(presentation.detail == "Stale 15m ago - Approve changes under Sources.")
    }

    @Test
    func widgetPresentationMarksCompletedStaleClosure() {
        let now = Date()
        let snapshot = TaskSnapshot(
            id: "done",
            threadId: "done",
            title: "Approval handled",
            cwd: "",
            status: .completed,
            lastSummary: "Approval sent.",
            updatedAt: now,
            urgency: .medium
        )

        let presentation = snapshot.widgetPresentation(savedAt: now.addingTimeInterval(-900), now: now)

        #expect(presentation.status == "Done - Old")
        #expect(presentation.shortStatus == "Old")
        #expect(presentation.detail == "Stale 15m ago - Approval sent.")
        #expect(presentation.isSnoozed == false)
    }

    @Test
    func syncFreshnessMarksMissingAndStaleData() {
        let now = Date()
        let missing = SyncFreshness(savedAt: nil, now: now)
        let fresh = SyncFreshness(savedAt: now.addingTimeInterval(-120), now: now)
        let stale = SyncFreshness(savedAt: now.addingTimeInterval(-900), now: now)

        #expect(missing.status == .noData)
        #expect(missing.displayName == "No sync yet")
        #expect(fresh.status == .fresh)
        #expect(fresh.displayName == "Synced 2m ago")
        #expect(stale.status == .stale)
        #expect(stale.shortDisplayName == "Old")
    }

    @Test
    func watchConnectivityMessageKeysAreStable() {
        #expect(WatchConnectivityMessageKey.bridgeState == "bridgeState")
        #expect(WatchConnectivityMessageKey.bridgeConnection == "bridgeConnection")
        #expect(WatchConnectivityMessageKey.bridgeCommand == "bridgeCommand")
        #expect(WatchConnectivityMessageKey.bridgeRefreshRequest == "bridgeRefreshRequest")
    }

    @Test
    func bridgeConnectionStoreRoundTripsPairingConfiguration() throws {
        let suiteName = "CodexWatchPetBridgeConnectionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = BridgeConnectionStore(defaults: defaults)
        let configuration = BridgeConnectionConfiguration(
            baseURL: URL(string: "http://172.20.12.65:8766")!,
            bearerToken: "token",
            sharedSecretBase64: Data("secret".utf8).base64EncodedString()
        )

        store.save(configuration)
        let loaded = try #require(store.load())

        #expect(loaded.baseURL.absoluteString == "http://172.20.12.65:8766")
        #expect(loaded.bearerToken == "token")
        #expect(loaded.sharedSecret == Data("secret".utf8))
    }

    @Test
    func quietModeStoreTogglesPersistedState() throws {
        let suiteName = "CodexWatchPetQuietModeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = QuietModeStore(defaults: defaults)

        #expect(store.isEnabled == false)
        #expect(store.toggle() == true)
        #expect(QuietModeStore(defaults: defaults).isEnabled == true)
        #expect(store.toggle() == false)
    }

    @Test
    func signerRoundTripsAndNonceRejectsReplay() throws {
        let secret = Data("local-secret".utf8)
        let command = BridgeCommand(
            type: .continueThread,
            threadId: "thread-1",
            payload: ["prompt": "continue"],
            confirmation: CommandConfirmation(displayedSummary: "continue", riskAccepted: true)
        )
        let signer = CommandSigner()
        let signature = try signer.sign(command, secret: secret)
        let nonceStore = NonceStore()
        let authorizer = CommandAuthorizer(requireSignature: true)

        try authorizer.validate(
            command: command,
            signature: signature,
            secret: secret,
            nonceStore: nonceStore
        )

        #expect(throws: CommandSecurityError.replayedNonce) {
            try authorizer.validate(
                command: command,
                signature: signature,
                secret: secret,
                nonceStore: nonceStore
            )
        }
    }

    @Test
    func pairingLinkRoundTrips() throws {
        let link = BridgePairingLink(
            bridgeURL: URL(string: "http://172.20.12.65:8766")!,
            token: "token-with-safe-chars",
            sharedSecret: Data("shared-secret".utf8).base64EncodedString()
        )

        let parsed = try BridgePairingLink(link: link.link)

        #expect(parsed.bridgeURL.absoluteString == "http://172.20.12.65:8766")
        #expect(parsed.token == "token-with-safe-chars")
        #expect(Data(base64Encoded: parsed.sharedSecret) == Data("shared-secret".utf8))
    }

    @Test
    func pairingLinkRejectsInvalidSecret() {
        #expect(throws: BridgePairingLinkError.invalidSecret) {
            _ = try BridgePairingLink(link: "codexwatchpet://pair?bridge=http%3A%2F%2F127.0.0.1%3A8766&token=t&secret=not-base64")
        }
    }
}
