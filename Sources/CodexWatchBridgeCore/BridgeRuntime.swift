import CodexWatchCore
import Foundation

public final class BridgeRuntime: @unchecked Sendable {
    private let stateReader: CodexStateReader
    private let executor: CodexCommandExecutor
    private let pairingStore: PairingStore
    private let auditLog: AuditLog
    private let eventStore: EventStore
    private let runStore: BridgeRunStore
    private let snoozeStore: SnoozeStore
    private let approvalStore: ApprovalResponseStore
    private let appServerApprovalRouter: AppServerApprovalRouting?
    private let processController: ProcessControlling
    private let runLogParser = CodexRunLogParser()
    private let authorizer: CommandAuthorizer
    private let notificationFactory = NotificationEventFactory()
    private let nonceStore = NonceStore()
    private let commandLock = NSRecursiveLock()
    private let receiptStore: CommandReceiptStore
    private var events: [BridgeEvent] = []
    private var lastKnownUpdates: [String: Date] = [:]
    private var nextSequence: Int64 = 1

    public init(
        codexHome: URL,
        bridgeHome: URL,
        requireSignatures: Bool = true,
        shell: ShellRunning = ProcessShellRunner(),
        launcher: DetachedProcessLaunching = ProcessDetachedLauncher(),
        processController: ProcessControlling = DarwinProcessController(),
        appServerApprovalRouter: AppServerApprovalRouting? = nil
    ) {
        self.stateReader = CodexStateReader(codexHome: codexHome, shell: shell)
        self.executor = CodexCommandExecutor(
            logDirectory: bridgeHome.appendingPathComponent("codex-runs"),
            shell: shell,
            launcher: launcher
        )
        self.pairingStore = PairingStore(directory: bridgeHome)
        self.receiptStore = CommandReceiptStore(fileURL: bridgeHome.appendingPathComponent("command-receipts.json"))
        self.auditLog = AuditLog(fileURL: bridgeHome.appendingPathComponent("audit.jsonl"))
        self.eventStore = EventStore(fileURL: bridgeHome.appendingPathComponent("events.jsonl"))
        self.runStore = BridgeRunStore(fileURL: bridgeHome.appendingPathComponent("runs.json"))
        self.snoozeStore = SnoozeStore(fileURL: bridgeHome.appendingPathComponent("snoozes.json"))
        self.approvalStore = ApprovalResponseStore(fileURL: bridgeHome.appendingPathComponent("approval-responses.jsonl"))
        self.appServerApprovalRouter = appServerApprovalRouter
        self.processController = processController
        self.authorizer = CommandAuthorizer(requireSignature: requireSignatures)
        self.events = (try? eventStore.load()) ?? []
        self.nextSequence = (events.map(\.sequence).max() ?? 0) + 1
        for event in events {
            if let existing = lastKnownUpdates[event.threadId] {
                lastKnownUpdates[event.threadId] = max(existing, event.createdAt)
            } else {
                lastKnownUpdates[event.threadId] = event.createdAt
            }
        }
        self.appServerApprovalRouter?.start()
    }

    public func ensurePairing() throws -> PairingRecord {
        try pairingStore.createOrLoad()
    }

    public func validateReadAccess(bearerToken: String?, isLocalClient: Bool) throws {
        if isLocalClient {
            return
        }
        let pairing = try ensurePairing()
        guard bearerToken == pairing.token else {
            throw BridgeError.unauthorized("remote bridge reads require a valid pairing token")
        }
    }

    public func snapshot() throws -> BridgeState {
        let now = Date()
        try? snoozeStore.pruneExpired(now: now)
        try syncBridgeRunLogs()
        let activeAppServerRequests = try syncAppServerApprovalRequests()
        let activeAppServerRequestIds = Set(activeAppServerRequests.keys)
        try reconcileClosedAppServerRequests(activeRequestIds: activeAppServerRequestIds)
        var snapshots = try stateReader.makeSnapshots()
        synthesizeEvents(from: snapshots)
        let recentEvents = Array(events.suffix(50)).sorted { $0.sequence > $1.sequence }
        let queuedThreadIdsToSuppress = bridgeRunQueuedThreadIds()
        snapshots.append(contentsOf: bridgeRunSnapshots(excluding: Set(snapshots.map(\.threadId))))
        snapshots.append(
            contentsOf: queuedCommandSnapshots(
                from: recentEvents,
                excluding: Set(snapshots.map(\.threadId)).union(queuedThreadIdsToSuppress),
                activeAppServerRequests: activeAppServerRequests
            )
        )
        // SQLite previews are not live tool requests or final assistant replies.
        for index in snapshots.indices {
            let threadID = snapshots[index].threadId
            if let event = recentEvents.first(where: { $0.threadId == threadID && $0.id.hasPrefix("run-") && $0.createdAt >= snapshots[index].updatedAt }) {
                snapshots[index].lastSummary = event.summary
                snapshots[index].status = event.type == .turnCompleted ? .completed : event.type == .turnFailed ? .failed : .active
                snapshots[index].updatedAt = event.createdAt
                snapshots[index].petMood = event.petMood
            }
            if let request = activeAppServerRequests.values.filter({ $0.threadId == threadID }).max(by: { $0.createdAt < $1.createdAt }) {
                let action: BridgeActionKind = request.kind == .userInput ? .reply : .approve
                snapshots[index].pendingRequest = PendingRequest(id: request.id, title: snapshots[index].title,
                    summary: request.summary, requiredAction: action, createdAt: request.createdAt, metadata: request.pendingMetadata)
                snapshots[index].status = action == .reply ? .waitingForInput : .waitingForApproval
                snapshots[index].lastSummary = request.summary
                snapshots[index].urgency = .high
                snapshots[index].petMood = action == .reply ? .needsInput : .needsApproval
            }
        }
        let activeSnoozes = (try? snoozeStore.active(now: now)) ?? [:]
        snapshots = applySnoozes(to: snapshots, activeSnoozes: activeSnoozes)
        let sortedSnapshots = snapshots.sorted(by: snapshotSort)
        return BridgeState(
            snapshots: sortedSnapshots,
            events: recentEvents,
            unreadHighUrgencyCount: sortedSnapshots.filter { $0.urgency == .high && $0.needsAttention(at: now) }.count,
            bridgeOnline: true,
            pairStatus: pairingStore.status(),
            liveControlStatus: appServerApprovalRouter?.liveControlStatus() ?? .disabled,
            bridgeIdentity: try ensurePairing().deviceId,
            commandReceiptsSupported: true
        )
    }

    public func events(since sequence: Int64?) throws -> [BridgeEvent] {
        _ = try snapshot()
        guard let sequence else {
            return events.sorted { $0.sequence > $1.sequence }
        }
        return events.filter { $0.sequence > sequence }.sorted { $0.sequence > $1.sequence }
    }

    public func submit(command: BridgeCommand, bearerToken: String?, signature: String?) throws -> CommandResult {
        commandLock.lock()
        defer { commandLock.unlock() }
        let pairing = try ensurePairing()
        guard bearerToken == pairing.token else {
            throw BridgeError.unauthorized("invalid bridge token")
        }

        // Authenticate even a receipt replay; never return a prior result for changed content.
        if authorizer.requireSignature {
            guard let signature, try authorizer.signer.verify(command, signature: signature, secret: pairing.secretData) else {
                throw BridgeError.unauthorized("invalid command signature")
            }
        }
        let fingerprint = try CommandReceiptStore.fingerprint(command)
        var receipts = try receiptStore.load()
        if let existing = receipts[command.id] {
            guard existing.fingerprint == fingerprint else {
                throw BridgeError.invalidRequest("Command id already belongs to different content.")
            }
            guard let result = existing.result else {
                throw BridgeError.invalidRequest("Command execution was reserved; outcome is unknown. Reconcile before retrying.")
            }
            return result
        }

        try authorizer.validate(
            command: command,
            signature: signature,
            secret: pairing.secretData,
            nonceStore: nonceStore
        )

        guard receipts.count < 10_000 else { throw BridgeError.invalidRequest("Command receipt store is full.") }
        receipts[command.id] = CommandReceiptStore.Entry(fingerprint: fingerprint, result: nil)
        try receiptStore.save(receipts)

        let execution: CodexCommandExecution
        if command.type == .approve || command.type == .decline {
            execution = try recordApprovalResponse(command)
        } else if command.type == .continueThread, isAppServerRequest(command) {
            execution = try recordUserInputResponse(command)
        } else if command.type == .snooze {
            execution = try recordSnooze(command)
        } else if command.type == .interrupt || command.type == .cancel {
            execution = try interruptBridgeOwnedRun(command)
        } else {
            execution = try executor.execute(command)
        }
        if let run = execution.run {
            try runStore.upsert(run)
        }
        let result = execution.result
        if result.accepted {
            try appendCommandAcceptedEvent(for: command, result: result)
        }
        let audit = AuditLogEntry(
            commandId: command.id,
            commandType: command.type,
            threadId: command.threadId,
            result: result.accepted ? "accepted" : "rejected",
            message: result.message
        )
        try auditLog.append(audit)
        let receipt = CommandResult(commandId: command.id, accepted: result.accepted, message: result.message, auditId: audit.id)
        receipts[command.id] = CommandReceiptStore.Entry(fingerprint: fingerprint, result: receipt)
        try receiptStore.save(receipts)
        return receipt
    }

    public func commandReceipt(id: String) throws -> CommandResult? {
        commandLock.lock()
        defer { commandLock.unlock() }
        return try receiptStore.load()[id]?.result
    }

    public func ingest(notification: CodexNotificationPayload) throws -> BridgeEvent {
        let snapshots = (try? stateReader.makeSnapshots(limit: 20)) ?? []
        let fallback = notification.threadId.flatMap { threadId in
            snapshots.first { $0.threadId == threadId }
        } ?? snapshots.first
        let event = notificationFactory.event(from: notification, fallbackSnapshot: fallback, sequence: nextSequence)
        nextSequence += 1
        events.append(event)
        try eventStore.append(event)
        if event.urgency == .high || event.type == .turnCompleted || event.type == .turnFailed {
            lastKnownUpdates[event.threadId] = event.createdAt
        }
        trimEvents()
        return event
    }

    private func synthesizeEvents(from snapshots: [TaskSnapshot]) {
        for snapshot in snapshots {
            guard lastKnownUpdates[snapshot.threadId] != snapshot.updatedAt else { continue }
            lastKnownUpdates[snapshot.threadId] = snapshot.updatedAt
            let event = BridgeEvent(
                    sequence: nextSequence,
                    threadId: snapshot.threadId,
                    type: eventType(for: snapshot.status),
                    title: snapshot.title,
                    summary: snapshot.lastSummary,
                    urgency: snapshot.urgency,
                    petMood: snapshot.petMood,
                    actions: actions(for: snapshot),
                    createdAt: snapshot.updatedAt
            )
            events.append(event)
            try? eventStore.append(event)
            nextSequence += 1
        }
        trimEvents()
    }

    private func syncBridgeRunLogs() throws {
        var knownEventIds = Set(events.map(\.id))
        var runs = (try? runStore.load()) ?? []
        var changedRuns: [BridgeRunRecord] = []

        for index in runs.indices {
            guard runs[index].status == .running else { continue }
            let result = runLogParser.parse(run: runs[index], startingAtLine: runs[index].lastLogLineCount)
            guard result.consumedLineCount != runs[index].lastLogLineCount || !result.events.isEmpty || result.status != nil else {
                continue
            }

            for parsedEvent in result.events where !knownEventIds.contains(parsedEvent.id) {
                var event = parsedEvent
                event.sequence = nextSequence
                try appendEvent(event)
                knownEventIds.insert(event.id)
            }

            runs[index].lastLogLineCount = result.consumedLineCount
            if let threadId = result.threadId {
                runs[index].threadId = threadId
            }
            if let status = result.status {
                runs[index].status = status
            }
            if let lastEventDate = result.events.last?.createdAt {
                runs[index].updatedAt = lastEventDate
            }
            changedRuns.append(runs[index])
        }

        for run in changedRuns {
            try runStore.upsert(run)
        }
    }

    private func bridgeRunSnapshots(excluding existingThreadIds: Set<String>) -> [TaskSnapshot] {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        let records = (try? runStore.load()) ?? []
        return records.compactMap { run in
            guard run.updatedAt >= cutoff else { return nil }
            guard !existingThreadIds.contains(run.threadId) else { return nil }

            let status: TaskStatus = switch run.status {
            case .running:
                .active
            case .interrupted:
                .failed
            case .completed:
                .completed
            case .failed:
                .failed
            }
            let summary: String = switch run.status {
            case .running:
                "Bridge-owned Codex run is active on the Mac. Log: \(run.logFile)"
            case .interrupted:
                "Bridge-owned Codex run was interrupted from Watch/iPhone."
            case .completed:
                "Bridge-owned Codex run completed on the Mac."
            case .failed:
                "Bridge-owned Codex run failed on the Mac. Log: \(run.logFile)"
            }

            return TaskSnapshot(
                id: run.threadId,
                threadId: run.threadId,
                title: run.title,
                cwd: run.cwd,
                status: status,
                lastSummary: summary,
                lastSyncedAt: Date(),
                updatedAt: run.updatedAt,
                petMood: status.petMood,
                urgency: run.status == .failed ? .high : (run.status == .running ? .medium : .low)
            )
        }
    }

    private func bridgeRunQueuedThreadIds() -> Set<String> {
        let records = (try? runStore.load()) ?? []
        return Set(records.map { "command-\($0.commandId)" })
    }

    private func queuedCommandSnapshots(
        from events: [BridgeEvent],
        excluding existingThreadIds: Set<String>,
        activeAppServerRequests: [String: AppServerApprovalRequest]
    ) -> [TaskSnapshot] {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        var seen: Set<String> = []
        var snapshots: [TaskSnapshot] = []

        for event in events {
            guard event.createdAt >= cutoff else { continue }
            guard !existingThreadIds.contains(event.threadId), !seen.contains(event.threadId) else { continue }
            let requestId = appServerRequestId(from: event.id)
            let activeRequest = requestId.flatMap { activeAppServerRequests[$0] }
            if requestId != nil, activeRequest == nil {
                continue
            }
            guard event.type == .threadStarted
                || event.type == .turnProgress
                || event.type == .approvalRequested
                || event.type == .inputRequested
                || (event.type == .turnCompleted && closedAppServerRequestId(from: event.id) != nil) else { continue }

            let status: TaskStatus = switch event.type {
            case .approvalRequested:
                .waitingForApproval
            case .inputRequested:
                .waitingForInput
            case .turnCompleted:
                .completed
            default:
                .active
            }
            let pendingRequest: PendingRequest? = switch event.type {
            case .approvalRequested:
                PendingRequest(
                    id: pendingRequestId(from: event),
                    title: "Approve Codex request",
                    summary: event.summary,
                    requiredAction: .approve,
                    createdAt: event.createdAt,
                    metadata: activeRequest?.pendingMetadata ?? [:]
                )
            case .inputRequested:
                PendingRequest(
                    id: pendingRequestId(from: event),
                    title: "Reply to Codex",
                    summary: event.summary,
                    requiredAction: .reply,
                    createdAt: event.createdAt,
                    metadata: activeRequest?.pendingMetadata ?? [:]
                )
            default:
                nil
            }

            seen.insert(event.threadId)
            snapshots.append(
                TaskSnapshot(
                    id: event.threadId,
                    threadId: event.threadId,
                    title: event.title,
                    cwd: "",
                    status: status,
                    lastSummary: event.summary,
                    pendingRequest: pendingRequest,
                    lastSyncedAt: Date(),
                    updatedAt: event.createdAt,
                    petMood: status.petMood,
                    urgency: event.urgency
                )
            )
        }

        return snapshots
    }

    private func syncAppServerApprovalRequests() throws -> [String: AppServerApprovalRequest] {
        guard let appServerApprovalRouter else { return [:] }
        let pendingRequests = appServerApprovalRouter.pendingApprovals()
        let activeRequests = Dictionary(pendingRequests.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.createdAt >= rhs.createdAt ? lhs : rhs
        })
        let knownEventIds = Set(events.map(\.id))
        let knownAppServerRequestIds = Set(events.compactMap { appServerRequestId(from: $0.id) })
        for request in pendingRequests {
            let eventId = appServerApprovalEventId(for: request)
            guard !knownEventIds.contains(eventId), !knownAppServerRequestIds.contains(request.id) else { continue }
            let eventType: BridgeEventType = request.kind == .userInput ? .inputRequested : .approvalRequested
            let title = switch request.kind {
            case .commandApproval:
                "Codex needs approval"
            case .fileChangeApproval:
                "Codex needs file approval"
            case .userInput:
                "Codex needs input"
            }
            let actions: [BridgeAction] = switch request.kind {
            case .commandApproval, .fileChangeApproval:
                [
                    BridgeAction(kind: .approve, title: "Approve", summary: "Approve the pending Codex request.", requiresHoldConfirmation: true),
                    BridgeAction(kind: .decline, title: "Decline", summary: "Decline the pending Codex request.", requiresHoldConfirmation: true, destructive: true)
                ]
            case .userInput:
                [
                    BridgeAction(kind: .reply, title: "Reply", summary: "Send your reply to Codex.", requiresHoldConfirmation: true)
                ]
            }
            try appendEvent(
                BridgeEvent(
                    id: eventId,
                    sequence: nextSequence,
                    threadId: request.threadId,
                    turnId: request.turnId,
                    type: eventType,
                    title: title,
                    summary: request.summary,
                    urgency: .high,
                    petMood: eventType == .inputRequested ? .needsInput : .needsApproval,
                    actions: actions,
                    createdAt: request.createdAt
                )
            )
        }
        return activeRequests
    }

    private func reconcileClosedAppServerRequests(activeRequestIds: Set<String>) throws {
        guard appServerApprovalRouter != nil else { return }
        let knownEventIds = Set(events.map(\.id))
        var latestPendingEventByRequestId: [String: BridgeEvent] = [:]

        for event in events {
            guard event.type == .approvalRequested || event.type == .inputRequested else { continue }
            guard let requestId = appServerRequestId(from: event.id), !activeRequestIds.contains(requestId) else { continue }
            guard !knownEventIds.contains(closedAppServerEventId(for: requestId)) else { continue }

            if let existing = latestPendingEventByRequestId[requestId], existing.sequence > event.sequence {
                continue
            }
            latestPendingEventByRequestId[requestId] = event
        }

        for (requestId, event) in latestPendingEventByRequestId {
            try appendEvent(
                BridgeEvent(
                    id: closedAppServerEventId(for: requestId),
                    sequence: nextSequence,
                    threadId: event.threadId,
                    turnId: event.turnId,
                    type: .turnProgress,
                    title: "Live request closed",
                    summary: "This live Codex request is no longer pending on the Mac bridge.",
                    urgency: .low,
                    petMood: .done,
                    actions: [
                        BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac.")
                    ]
                )
            )
        }
    }

    private func appendCommandAcceptedEvent(for command: BridgeCommand, result: CommandResult) throws {
        guard let event = commandAcceptedEvent(for: command, result: result) else {
            return
        }
        events.append(event)
        try eventStore.append(event)
        lastKnownUpdates[event.threadId] = event.createdAt
        nextSequence += 1
        trimEvents()
    }

    private func interruptBridgeOwnedRun(_ command: BridgeCommand) throws -> CodexCommandExecution {
        guard let threadId = command.threadId, !threadId.isEmpty else {
            throw BridgeError.invalidRequest("\(command.type.rawValue) requires threadId")
        }
        guard var run = try runStore.find(threadId: threadId) else {
            return CodexCommandExecution(
                result: CommandResult(
                    commandId: command.id,
                    accepted: false,
                    message: "No bridge-owned running Codex task found for \(threadId)."
                )
            )
        }

        try processController.terminate(pid: run.pid)
        let now = Date()
        run.status = .interrupted
        run.updatedAt = now
        try runStore.upsert(run)
        try appendEvent(
            BridgeEvent(
                sequence: nextSequence,
                threadId: run.threadId,
                type: .turnFailed,
                title: run.title,
                summary: "Interrupted bridge-owned Codex run \(run.pid).",
                urgency: .medium,
                petMood: .failed,
                actions: [
                    BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac.")
                ],
                createdAt: now
            )
        )

        return CodexCommandExecution(
            result: CommandResult(
                commandId: command.id,
                accepted: true,
                message: "Interrupted bridge-owned Codex run \(run.pid)."
            )
        )
    }

    private func matchingLiveRequest(_ command: BridgeCommand, isInput: Bool) -> AppServerApprovalRequest? {
        guard let requestId = command.payload["requestId"],
              let request = appServerApprovalRouter?.pendingApprovals().first(where: { $0.id == requestId }),
              request.threadId == command.threadId,
              request.turnId == command.turnId,
              (request.kind == .userInput) == isInput,
              !isInput || request.questionIds.count <= 1 else { return nil }
        return request
    }

    private func rejectedLiveRequest(_ command: BridgeCommand) -> CodexCommandExecution {
        CodexCommandExecution(result: CommandResult(commandId: command.id, accepted: false,
            message: "任务、轮次或请求已变化，或需要逐题回答。请刷新后重新确认；复杂授权请回 Mac 处理。"))
    }

    private func recordApprovalResponse(_ command: BridgeCommand) throws -> CodexCommandExecution {
        guard matchingLiveRequest(command, isInput: false) != nil else {
            return rejectedLiveRequest(command)
        }
        let requestId = command.payload["requestId"]
        let threadId = command.threadId ?? requestId ?? "approval-\(command.id)"
        let approved = command.type == .approve
        let appServerResolution = requestId.flatMap { requestId in
            try? appServerApprovalRouter?.resolveApproval(requestId: requestId, approved: approved)
        }
        let deliveredToAppServer = appServerResolution?.delivered == true
        let summary: String
        if let appServerResolution {
            summary = appServerResolution.message
        } else {
            summary = "未能发送授权回执，请刷新任务并在 Mac 核实。"
        }
        let retryableLiveRequest = appServerResolution?.delivered == false ? appServerResolution?.request : nil
        let handledLiveRequest = deliveredToAppServer ? appServerResolution?.request : nil
        let now = Date()
        let record = ApprovalResponseRecord(
            commandId: command.id,
            threadId: threadId,
            requestId: requestId,
            approved: approved,
            summary: summary,
            createdAt: now
        )
        try approvalStore.append(record)
        try appendEvent(
            BridgeEvent(
                id: approvalResponseEventId(
                    retryableLiveRequest: retryableLiveRequest,
                    handledLiveRequest: handledLiveRequest,
                    commandId: command.id
                ),
                sequence: nextSequence,
                threadId: retryableLiveRequest?.threadId ?? handledLiveRequest?.threadId ?? threadId,
                turnId: command.turnId ?? handledLiveRequest?.turnId,
                type: approvalResponseEventType(
                    approved: approved,
                    deliveredToAppServer: deliveredToAppServer,
                    retryableLiveRequest: retryableLiveRequest
                ),
                title: appServerResolution == nil
                    ? (approved ? "Approval recorded" : "Request declined")
                    : approvalResultTitle(approved: approved, deliveredToAppServer: deliveredToAppServer),
                summary: summary,
                urgency: retryableLiveRequest == nil ? .medium : .high,
                petMood: approvalResponsePetMood(
                    approved: approved,
                    deliveredToAppServer: deliveredToAppServer,
                    retryableLiveRequest: retryableLiveRequest
                ),
                actions: retryableLiveRequest == nil ? [
                    BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac to reconcile the live request.")
                ] : [
                    BridgeAction(kind: .approve, title: "Retry Approve", summary: "Retry approving the live Codex request.", requiresHoldConfirmation: true),
                    BridgeAction(kind: .decline, title: "Decline", summary: "Decline the live Codex request.", requiresHoldConfirmation: true, destructive: true),
                    BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac to reconcile the live request.")
                ],
                createdAt: now
            )
        )

        return CodexCommandExecution(
            result: CommandResult(
                commandId: command.id,
                accepted: deliveredToAppServer,
                message: summary
            )
        )
    }

    private func recordUserInputResponse(_ command: BridgeCommand) throws -> CodexCommandExecution {
        guard matchingLiveRequest(command, isInput: true) != nil else {
            return rejectedLiveRequest(command)
        }
        let requestId = command.payload["requestId"]
        let prompt = command.payload["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let threadId = command.threadId ?? requestId ?? "input-\(command.id)"
        guard let requestId, !prompt.isEmpty else {
            return CodexCommandExecution(
                result: CommandResult(
                    commandId: command.id,
                    accepted: false,
                    message: "Live Codex input replies require requestId and payload.prompt."
                )
            )
        }

        let resolution = try? appServerApprovalRouter?.resolveUserInput(requestId: requestId, answer: prompt)
        guard let resolution, resolution.delivered else {
            let message = resolution?.message ?? "No matching live Codex input request was available for \(requestId)."
            let retryableLiveRequest = resolution?.request
            try appendEvent(
                BridgeEvent(
                    id: retryableLiveRequest.map { retryableAppServerEventId(for: $0, commandId: command.id) } ?? UUID().uuidString,
                    sequence: nextSequence,
                    threadId: retryableLiveRequest?.threadId ?? threadId,
                    turnId: command.turnId,
                    type: retryableLiveRequest == nil ? .turnFailed : .inputRequested,
                    title: "Reply not sent",
                    summary: message,
                    urgency: retryableLiveRequest == nil ? .medium : .high,
                    petMood: retryableLiveRequest == nil ? .failed : .needsInput,
                    actions: retryableLiveRequest == nil ? [
                        BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac to reconcile the live request.")
                    ] : [
                        BridgeAction(kind: .reply, title: "Retry", summary: "Retry sending your reply to Codex.", requiresHoldConfirmation: true),
                        BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac to reconcile the live request.")
                    ]
                )
            )
            return CodexCommandExecution(
                result: CommandResult(
                    commandId: command.id,
                    accepted: false,
                    message: message
                )
            )
        }

        let now = Date()
        try appendEvent(
            BridgeEvent(
                sequence: nextSequence,
                threadId: threadId,
                turnId: command.turnId,
                type: .turnProgress,
                title: "Reply sent",
                summary: resolution.message,
                urgency: .medium,
                petMood: .thinking,
                actions: [
                    BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac.")
                ],
                createdAt: now
            )
        )

        return CodexCommandExecution(
            result: CommandResult(
                commandId: command.id,
                accepted: true,
                message: resolution.message
            )
        )
    }

    private func recordSnooze(_ command: BridgeCommand) throws -> CodexCommandExecution {
        guard let threadId = command.threadId?.nonBlank ?? command.payload["threadId"]?.nonBlank else {
            return CodexCommandExecution(
                result: CommandResult(
                    commandId: command.id,
                    accepted: false,
                    message: "Snooze requires a thread id."
                )
            )
        }

        let now = Date()
        let duration = snoozeDuration(from: command.payload["durationSeconds"])
        let snoozedUntil = now.addingTimeInterval(duration)
        try snoozeStore.upsert(
            SnoozeRecord(
                threadId: threadId,
                commandId: command.id,
                createdAt: now,
                snoozedUntil: snoozedUntil
            )
        )
        return CodexCommandExecution(
            result: CommandResult(
                commandId: command.id,
                accepted: true,
                message: "Snoozed \(threadId) for \(Int(duration / 60)) minutes."
            )
        )
    }

    private func approvalResultTitle(approved: Bool, deliveredToAppServer: Bool) -> String {
        if deliveredToAppServer {
            return approved ? "Approval sent" : "Decline sent"
        }
        return approved ? "Approval not sent" : "Decline not sent"
    }

    private func approvalResponseEventId(
        retryableLiveRequest: AppServerApprovalRequest?,
        handledLiveRequest: AppServerApprovalRequest?,
        commandId: String
    ) -> String {
        if let retryableLiveRequest {
            return retryableAppServerEventId(for: retryableLiveRequest, commandId: commandId)
        }
        if let handledLiveRequest {
            return closedAppServerEventId(for: handledLiveRequest.id)
        }
        return UUID().uuidString
    }

    private func approvalResponseEventType(
        approved: Bool,
        deliveredToAppServer: Bool,
        retryableLiveRequest: AppServerApprovalRequest?
    ) -> BridgeEventType {
        if retryableLiveRequest != nil {
            return .approvalRequested
        }
        if deliveredToAppServer {
            return .turnProgress
        }
        return approved ? .turnProgress : .turnFailed
    }

    private func approvalResponsePetMood(
        approved: Bool,
        deliveredToAppServer: Bool,
        retryableLiveRequest: AppServerApprovalRequest?
    ) -> PetMood {
        if retryableLiveRequest != nil {
            return .needsApproval
        }
        if deliveredToAppServer {
            return .thinking
        }
        return approved ? .thinking : .failed
    }

    private func commandAcceptedEvent(for command: BridgeCommand, result: CommandResult) -> BridgeEvent? {
        let now = Date()
        switch command.type {
        case .startThread:
            let prompt = command.payload["prompt"] ?? "Codex task"
            return BridgeEvent(
                sequence: nextSequence,
                threadId: command.threadId ?? "command-\(command.id)",
                turnId: command.turnId,
                type: .threadStarted,
                title: prompt.shortTitle(defaultValue: "Codex task"),
                summary: result.message,
                urgency: .medium,
                petMood: .thinking,
                actions: [
                    BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac."),
                    BridgeAction(kind: .snooze, title: "Snooze", summary: "Snooze this update locally.")
                ],
                createdAt: now
            )
        case .continueThread:
            guard !isAppServerRequest(command) else {
                return nil
            }
            let prompt = command.payload["prompt"] ?? "New instruction"
            return BridgeEvent(
                sequence: nextSequence,
                threadId: command.threadId ?? "command-\(command.id)",
                turnId: command.turnId,
                type: .turnProgress,
                title: "Continuing Codex thread",
                summary: prompt.shortTitle(defaultValue: result.message),
                urgency: .medium,
                petMood: .thinking,
                actions: [
                    BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac.")
                ],
                createdAt: now
            )
        default:
            return nil
        }
    }

    private func trimEvents() {
        if events.count > 500 {
            events.removeFirst(events.count - 500)
        }
    }

    private func appendEvent(_ event: BridgeEvent) throws {
        events.append(event)
        try eventStore.append(event)
        lastKnownUpdates[event.threadId] = event.createdAt
        nextSequence += 1
        trimEvents()
    }

    private func snapshotSort(_ lhs: TaskSnapshot, _ rhs: TaskSnapshot) -> Bool {
        if lhs.urgency != rhs.urgency {
            return lhs.urgency > rhs.urgency
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private func applySnoozes(to snapshots: [TaskSnapshot], activeSnoozes: [String: SnoozeRecord]) -> [TaskSnapshot] {
        snapshots.map { snapshot in
            var snapshot = snapshot
            snapshot.snoozedUntil = activeSnoozes[snapshot.threadId]?.snoozedUntil
            return snapshot
        }
    }

    private func snoozeDuration(from value: String?) -> TimeInterval {
        guard let value, let seconds = TimeInterval(value), seconds > 0 else {
            return 15 * 60
        }
        return min(seconds, 4 * 60 * 60)
    }

    private func eventType(for status: TaskStatus) -> BridgeEventType {
        switch status {
        case .waitingForApproval:
            .approvalRequested
        case .waitingForInput:
            .inputRequested
        case .completed:
            .turnCompleted
        case .failed:
            .turnFailed
        case .offline:
            .bridgeOffline
        case .idle, .active, .runningTool:
            .turnProgress
        }
    }

    private func actions(for snapshot: TaskSnapshot) -> [BridgeAction] {
        switch snapshot.status {
        case .waitingForApproval:
            return [
                BridgeAction(kind: .approve, title: "Approve", summary: "Approve the pending Codex request.", requiresHoldConfirmation: true),
                BridgeAction(kind: .decline, title: "Decline", summary: "Decline the pending Codex request.", requiresHoldConfirmation: true, destructive: true)
            ]
        case .waitingForInput:
            return [
                BridgeAction(kind: .reply, title: "Reply", summary: "Send voice or text input back to Codex.", requiresHoldConfirmation: true)
            ]
        case .active, .runningTool:
            return [
                BridgeAction(kind: .interrupt, title: "Interrupt", summary: "Stop the current bridge-owned turn.", requiresHoldConfirmation: true, destructive: true),
                BridgeAction(kind: .continueThread, title: "Add note", summary: "Append more instructions to this thread.", requiresHoldConfirmation: true)
            ]
        default:
            return [
                BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac.")
            ]
        }
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func shortTitle(defaultValue: String, maxLength: Int = 72) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultValue }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "..."
    }
}

private func isAppServerRequest(_ command: BridgeCommand) -> Bool {
    command.payload["requestId"]?.hasPrefix("appserver:") == true
}

private func appServerApprovalEventId(for request: AppServerApprovalRequest) -> String {
    "appserver-approval-\(request.id)"
}

private func retryableAppServerEventId(for request: AppServerApprovalRequest, commandId: String) -> String {
    "\(appServerApprovalEventId(for: request))#retry-\(commandId)"
}

private func closedAppServerEventId(for requestId: String) -> String {
    "appserver-closed-\(requestId)"
}

private func closedAppServerRequestId(from eventId: String) -> String? {
    let prefix = "appserver-closed-"
    guard eventId.hasPrefix(prefix) else { return nil }
    return String(eventId.dropFirst(prefix.count))
}

private func pendingRequestId(from event: BridgeEvent) -> String {
    appServerRequestId(from: event.id) ?? event.id
}

private func appServerRequestId(from eventId: String) -> String? {
    let prefix = "appserver-approval-"
    if eventId.hasPrefix(prefix) {
        return String(eventId.dropFirst(prefix.count)).split(separator: "#", maxSplits: 1).first.map(String.init)
    }
    return nil
}

private extension AppServerApprovalRequest {
    var pendingMetadata: [String: String] {
        var metadata: [String: String] = [
            "requestKind": kind.rawValue,
            "turnId": turnId,
            "itemId": itemId
        ]
        if let approvalId = approvalId?.nonBlank {
            metadata["approvalId"] = approvalId
        }
        if let command = command?.nonBlank {
            metadata["command"] = command
        }
        if let cwd = cwd?.nonBlank {
            metadata["cwd"] = cwd
        }
        if let reason = reason?.nonBlank {
            metadata["reason"] = reason
        }
        if let grantRoot = grantRoot?.nonBlank {
            metadata["grantRoot"] = grantRoot
        }
        if !questionIds.isEmpty {
            metadata["questionIds"] = questionIds.joined(separator: ", ")
        }
        return metadata
    }
}
