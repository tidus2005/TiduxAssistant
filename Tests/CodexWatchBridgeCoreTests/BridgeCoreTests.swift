import CodexWatchBridgeCore
import CodexWatchCore
import Foundation
import Testing

struct StubShell: ShellRunning {
    var outputs: [String: ShellResult]

    func run(_ executable: String, arguments: [String], input: String?) throws -> ShellResult {
        let key = ([executable] + arguments).joined(separator: " ")
        for (prefix, result) in outputs where key.hasPrefix(prefix) {
            return result
        }
        return ShellResult(status: 1, stdout: "", stderr: "No stub for \(key)")
    }
}

final class RecordingShell: ShellRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        var executable: String
        var arguments: [String]
        var input: String?
    }

    private(set) var invocations: [Invocation] = []
    var result: ShellResult

    init(result: ShellResult) {
        self.result = result
    }

    func run(_ executable: String, arguments: [String], input: String?) throws -> ShellResult {
        invocations.append(Invocation(executable: executable, arguments: arguments, input: input))
        return result
    }
}

final class StubDetachedLauncher: DetachedProcessLaunching, @unchecked Sendable {
    struct Launch: Equatable {
        var executable: String
        var arguments: [String]
        var logFile: URL
    }

    var launches: [Launch] = []
    var nextPID: Int32 = 42

    func launch(_ executable: String, arguments: [String], logFile: URL) throws -> DetachedProcessLaunch {
        launches.append(Launch(executable: executable, arguments: arguments, logFile: logFile))
        return DetachedProcessLaunch(pid: nextPID, logFile: logFile)
    }
}

final class StubProcessController: ProcessControlling, @unchecked Sendable {
    var terminatedPIDs: [Int32] = []

    func terminate(pid: Int32) throws {
        terminatedPIDs.append(pid)
    }
}

final class StubAppServerApprovalRouter: AppServerApprovalRouting, @unchecked Sendable {
    var started = false
    var approvals: [AppServerApprovalRequest]
    var resolved: [(requestId: String, approved: Bool)] = []
    var userInputReplies: [(requestId: String, answer: String)] = []
    var failApprovalDelivery = false
    var failUserInputDelivery = false

    init(approvals: [AppServerApprovalRequest]) {
        self.approvals = approvals
    }

    func start() {
        started = true
    }

    func pendingApprovals() -> [AppServerApprovalRequest] {
        approvals
    }

    func liveControlStatus() -> LiveControlStatus {
        LiveControlStatus(state: .connected, pendingRequestCount: approvals.count)
    }

    func resolveApproval(requestId: String, approved: Bool) throws -> AppServerApprovalResolution {
        resolved.append((requestId: requestId, approved: approved))
        guard let request = approvals.first(where: { $0.id == requestId || $0.rawRequestId.stableString == requestId }) else {
            return AppServerApprovalResolution(delivered: false, message: "missing", request: nil)
        }
        if failApprovalDelivery {
            return AppServerApprovalResolution(
                delivered: false,
                message: "approval delivery failed",
                request: request
            )
        }
        approvals.removeAll { $0.id == request.id }
        return AppServerApprovalResolution(
            delivered: true,
            message: approved ? "stub approval sent" : "stub decline sent",
            request: request
        )
    }

    func resolveUserInput(requestId: String, answer: String) throws -> AppServerApprovalResolution {
        userInputReplies.append((requestId: requestId, answer: answer))
        guard let request = approvals.first(where: { ($0.id == requestId || $0.rawRequestId.stableString == requestId) && $0.kind == .userInput }) else {
            return AppServerApprovalResolution(delivered: false, message: "missing input", request: nil)
        }
        if failUserInputDelivery {
            return AppServerApprovalResolution(
                delivered: false,
                message: "reply delivery failed",
                request: request
            )
        }
        approvals.removeAll { $0.id == request.id }
        return AppServerApprovalResolution(
            delivered: true,
            message: "stub reply sent",
            request: request
        )
    }
}

@Suite("Bridge core")
struct BridgeCoreTests {
    @Test
    func processShellRunnerDrainsLargeStdoutAndStderr() throws {
        let script = """
        (sleep 10; kill -TERM $$) </dev/null >/dev/null 2>&1 &
        watchdog_pid=$!
        trap 'kill "$watchdog_pid" 2>/dev/null || true' EXIT
        i=0
        while [ "$i" -lt 20000 ]; do
          printf 'stdout-line-%05d\\n' "$i"
          printf 'stderr-line-%05d\\n' "$i" >&2
          i=$((i + 1))
        done
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        trap - EXIT
        """

        let result = try ProcessShellRunner().run("/bin/sh", arguments: ["-c", script], input: nil)

        #expect(result.status == 0)
        #expect(result.stdout.utf8.count > 64 * 1024)
        #expect(result.stderr.utf8.count > 64 * 1024)
        #expect(result.stdout.contains("stdout-line-19999"))
        #expect(result.stderr.contains("stderr-line-19999"))
    }

    @Test
    func stateReaderUsesBoundedReadOnlySQLiteQuery() throws {
        let shell = RecordingShell(result: ShellResult(status: 0, stdout: "[]", stderr: ""))
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-watch-bounded-query-\(UUID().uuidString)", isDirectory: true)
        let reader = CodexStateReader(codexHome: codexHome, shell: shell)

        _ = try reader.readRecentThreads()

        #expect(shell.invocations.count == 1)
        let invocation = try #require(shell.invocations.first)
        #expect(invocation.executable == "/usr/bin/sqlite3")
        #expect(invocation.arguments.prefix(2) == ["-json", "-readonly"])
        let query = try #require(invocation.arguments.last)
        #expect(query.contains("substr(title, 1, 256) as title"))
        #expect(query.contains("substr(cwd, 1, 512) as cwd"))
        #expect(query.contains("substr(preview, 1, 512) as preview"))
    }

    @Test
    func stateReaderUsesReadOnlySQLiteForGoalsDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-watch-goals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("goals_1.sqlite").path,
            contents: Data()
        )

        let shell = RecordingShell(result: ShellResult(status: 0, stdout: "[]", stderr: ""))
        let reader = CodexStateReader(codexHome: directory, shell: shell)

        _ = try reader.readRecentThreads()

        #expect(shell.invocations.count == 2)
        let goalsInvocation = try #require(shell.invocations.last)
        #expect(goalsInvocation.executable == "/usr/bin/sqlite3")
        #expect(goalsInvocation.arguments.prefix(2) == ["-json", "-readonly"])
        #expect(goalsInvocation.arguments[2].hasSuffix("/goals_1.sqlite"))
    }

    @Test
    func stateReaderMapsRecentActiveThread() throws {
        let json = """
        [{"id":"thread-1","title":"Active","cwd":"/tmp","updated_at":4102444800,"preview":"Working\\nNow","tokens_used":120}]
        """
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: json, stderr: "")
        ])
        let reader = CodexStateReader(codexHome: URL(fileURLWithPath: "/tmp/codex-home"), shell: shell)

        let snapshots = try reader.makeSnapshots(now: Date(timeIntervalSince1970: 4102444820))

        #expect(snapshots.count == 1)
        #expect(snapshots[0].status == .active)
        #expect(snapshots[0].lastSummary == "Working Now")
    }

    @Test
    func executorRejectsStartWithoutPrompt() throws {
        let executor = CodexCommandExecutor(shell: StubShell(outputs: [:]))
        let command = BridgeCommand(
            type: .startThread,
            confirmation: CommandConfirmation(displayedSummary: "start", riskAccepted: true)
        )

        #expect(throws: BridgeError.invalidRequest("startThread requires payload.prompt")) {
            _ = try executor.execute(command)
        }
    }

    @Test
    func executorStartsCodexTaskInBackground() throws {
        let launcher = StubDetachedLauncher()
        let executor = CodexCommandExecutor(
            codexCLIPath: "/usr/local/bin/codex",
            logDirectory: URL(fileURLWithPath: "/tmp/codex-watch-tests"),
            shell: StubShell(outputs: [:]),
            launcher: launcher
        )
        let command = BridgeCommand(
            id: "command-1",
            type: .startThread,
            payload: ["prompt": "Summarize the current project", "cwd": "/tmp/project"],
            confirmation: CommandConfirmation(displayedSummary: "start", riskAccepted: true)
        )

        let execution = try executor.execute(command)
        let result = execution.result

        #expect(result.accepted == true)
        #expect(result.message.contains("pid 42"))
        #expect(execution.run?.threadId == "command-command-1")
        #expect(execution.run?.status == .running)
        #expect(launcher.launches.count == 1)
        #expect(launcher.launches[0].executable == "/usr/local/bin/codex")
        #expect(launcher.launches[0].arguments == [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "-C",
            "/tmp/project",
            "Summarize the current project"
        ])
        #expect(launcher.launches[0].logFile.path.hasSuffix("/command-1.jsonl"))
    }

    @Test
    func runLogParserMapsJsonlProgressAndCompletion() {
        let run = BridgeRunRecord(
            id: "run-1",
            commandId: "run-1",
            threadId: "command-run-1",
            commandType: .startThread,
            title: "Build watch bridge",
            prompt: "Build watch bridge",
            cwd: "/tmp",
            pid: 42,
            logFile: "/tmp/run-1.jsonl"
        )
        let lines = [
            #"{"type":"agent_message","message":"Reading project files"}"#,
            #"{"type":"tool_call","name":"shell","message":"Running tests"}"#,
            #"{"type":"turn.completed","summary":"All requested work is complete"}"#
        ]

        let result = CodexRunLogParser().parse(lines: lines, run: run)

        #expect(result.consumedLineCount == 3)
        #expect(result.status == .completed)
        #expect(result.events.map(\.type) == [.turnProgress, .turnProgress, .turnCompleted])
        #expect(result.events[1].petMood == .tooling)
        #expect(result.events[2].summary == "All requested work is complete")
    }

    @Test
    func runLogParserMapsRealCodexExecJsonlShape() {
        let run = BridgeRunRecord(
            id: "probe",
            commandId: "probe",
            threadId: "command-probe",
            commandType: .startThread,
            title: "Probe",
            prompt: "Probe",
            cwd: "/tmp",
            pid: 42,
            logFile: "/tmp/probe.jsonl"
        )
        let lines = [
            #"{"type":"thread.started","thread_id":"019e8388-9f98-7621-bc8f-14ee1bcd869e"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"LOG_PROBE_DONE"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":23227,"cached_input_tokens":4992,"output_tokens":31,"reasoning_output_tokens":21}}"#
        ]

        let result = CodexRunLogParser().parse(lines: lines, run: run)

        #expect(result.threadId == "019e8388-9f98-7621-bc8f-14ee1bcd869e")
        #expect(result.status == .completed)
        #expect(result.events.map(\.type) == [.threadStarted, .turnProgress, .turnProgress, .turnCompleted])
        #expect(result.events[0].threadId == "019e8388-9f98-7621-bc8f-14ee1bcd869e")
        #expect(result.events[2].summary == "LOG_PROBE_DONE")
        #expect(result.events[3].summary == "LOG_PROBE_DONE")
        let incremental = CodexRunLogParser().parse(lines: lines, run: run, startingAtLine: 3)
        #expect(incremental.events.first?.summary == "LOG_PROBE_DONE")
    }

    @Test
    func pairingCreatesStableRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetTests")
            .appendingPathComponent(UUID().uuidString)
        let store = PairingStore(directory: directory)

        let first = try store.createOrLoad(deviceName: "Watch", deviceId: "device")
        let second = try store.createOrLoad(deviceName: "Other", deviceId: "other")

        #expect(first.token == second.token)
        #expect(store.status().paired == true)
    }

    @Test
    func notificationFactoryMapsTurnEndedToCompletedEvent() {
        let payload = CodexNotificationPayload(
            kind: "turn-ended",
            threadId: "thread-1",
            title: "Build app",
            summary: "Codex finished the requested work."
        )
        let event = NotificationEventFactory().event(from: payload, fallbackSnapshot: nil, sequence: 42)

        #expect(event.sequence == 42)
        #expect(event.threadId == "thread-1")
        #expect(event.type == .turnCompleted)
        #expect(event.petMood == .done)
        #expect(event.urgency == .medium)
    }

    @Test
    func eventStorePersistsEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetEventTests")
            .appendingPathComponent(UUID().uuidString)
        let store = EventStore(fileURL: directory.appendingPathComponent("events.jsonl"))
        let event = BridgeEvent(
            sequence: 1,
            threadId: "thread-1",
            type: .inputRequested,
            title: "Need input",
            summary: "Please provide missing info.",
            urgency: .high,
            petMood: .needsInput,
            actions: []
        )

        try store.append(event)
        let loaded = try store.load()

        #expect(loaded.count == 1)
        #expect(loaded.first?.threadId == "thread-1")
        #expect(loaded.first?.type == .inputRequested)
    }

    @Test
    func approvalResponseStorePersistsResponses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetApprovalStoreTests")
            .appendingPathComponent(UUID().uuidString)
        let store = ApprovalResponseStore(fileURL: directory.appendingPathComponent("approval-responses.jsonl"))
        let record = ApprovalResponseRecord(
            commandId: "approve-1",
            threadId: "thread-1",
            requestId: "request-1",
            approved: true,
            summary: "Approved from Watch."
        )

        try store.append(record)
        let loaded = try store.load()

        #expect(loaded.count == 1)
        #expect(loaded.first?.commandId == "approve-1")
        #expect(loaded.first?.approved == true)
    }

    @Test
    func appServerApprovalStorePersistsPendingRequests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerApprovalStoreTests")
            .appendingPathComponent(UUID().uuidString)
        let store = AppServerApprovalStore(fileURL: directory.appendingPathComponent("appserver-approvals.json"))
        let request = AppServerApprovalRequest(
            rawRequestId: .string("rpc-1"),
            threadId: "thread-live",
            turnId: "turn-live",
            itemId: "item-live",
            command: "swift test",
            cwd: "/tmp/project",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        try store.upsert(request)
        let loaded = try store.load()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == "appserver:rpc-1")
        #expect(loaded.first?.summary == "Approve command: swift test")
    }

    @Test
    func appServerApprovalStorePrunesExpiredRequests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerApprovalPruneTests")
            .appendingPathComponent(UUID().uuidString)
        let store = AppServerApprovalStore(fileURL: directory.appendingPathComponent("appserver-approvals.json"))
        let expired = AppServerApprovalRequest(
            rawRequestId: .string("expired"),
            threadId: "thread-expired",
            turnId: "turn-expired",
            itemId: "item-expired",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let fresh = AppServerApprovalRequest(
            rawRequestId: .string("fresh"),
            threadId: "thread-fresh",
            turnId: "turn-fresh",
            itemId: "item-fresh",
            createdAt: Date(timeIntervalSince1970: 500)
        )

        try store.upsert(expired)
        try store.upsert(fresh)
        let pruned = try store.prune(olderThan: Date(timeIntervalSince1970: 200))
        let loaded = try store.load()

        #expect(pruned.map(\.id) == ["appserver:expired"])
        #expect(loaded.map(\.id) == ["appserver:fresh"])
    }

    @Test
    func appServerRouterHidesExpiredPendingRequests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerRouterPruneTests")
            .appendingPathComponent(UUID().uuidString)
        let store = AppServerApprovalStore(fileURL: directory.appendingPathComponent("appserver-approvals.json"))
        let expired = AppServerApprovalRequest(
            rawRequestId: .string("expired"),
            threadId: "thread-expired",
            turnId: "turn-expired",
            itemId: "item-expired",
            createdAt: Date().addingTimeInterval(-120)
        )
        let fresh = AppServerApprovalRequest(
            rawRequestId: .string("fresh"),
            threadId: "thread-fresh",
            turnId: "turn-fresh",
            itemId: "item-fresh",
            createdAt: Date()
        )
        try store.upsert(expired)
        try store.upsert(fresh)
        let router = CodexAppServerApprovalRouter(
            store: store,
            transport: CodexAppServerWebSocketTransport(socketPath: "/tmp/missing-codex.sock"),
            maxRequestAgeSeconds: 60
        )

        let pending = router.pendingApprovals()
        let loaded = try store.load()

        #expect(pending.map(\.id) == ["appserver:fresh"])
        #expect(loaded.map(\.id) == ["appserver:fresh"])
    }

    @Test
    func appServerRouterKeepsRequestWhenDeliveryFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerDeliveryFailureTests")
            .appendingPathComponent(UUID().uuidString)
        let store = AppServerApprovalStore(fileURL: directory.appendingPathComponent("appserver-approvals.json"))
        let request = AppServerApprovalRequest(
            rawRequestId: .string("live"),
            threadId: "thread-live",
            turnId: "turn-live",
            itemId: "item-live"
        )
        try store.upsert(request)
        let router = CodexAppServerApprovalRouter(
            store: store,
            transport: CodexAppServerWebSocketTransport(socketPath: "/tmp/missing-codex.sock")
        )

        let result = try router.resolveApproval(requestId: "appserver:live", approved: true)
        let loaded = try store.load()

        #expect(result.delivered == false)
        #expect(result.message.contains("Could not deliver"))
        #expect(loaded.map(\.id) == ["appserver:live"])
    }

    @Test
    func remoteReadsRequirePairingToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge")
        )
        let pairing = try runtime.ensurePairing()

        try runtime.validateReadAccess(bearerToken: nil, isLocalClient: true)
        #expect(throws: BridgeError.unauthorized("remote bridge reads require a valid pairing token")) {
            try runtime.validateReadAccess(bearerToken: nil, isLocalClient: false)
        }
        try runtime.validateReadAccess(bearerToken: pairing.token, isLocalClient: false)
    }

    @Test
    func runtimeCreatesImmediateEventForQueuedStartCommand() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetQueuedCommandTests")
            .appendingPathComponent(UUID().uuidString)
        let launcher = StubDetachedLauncher()
        let processController = StubProcessController()
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: launcher,
            processController: processController
        )
        let pairing = try runtime.ensurePairing()
        let command = BridgeCommand(
            id: "queued-start",
            type: .startThread,
            payload: ["prompt": "Write a release checklist for the watch app"],
            confirmation: CommandConfirmation(displayedSummary: "start", riskAccepted: true)
        )

        let result = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
        let events = try runtime.events(since: nil)
        let snapshot = try runtime.snapshot()

        #expect(result.accepted == true)
        #expect(launcher.launches.count == 1)
        #expect(events.first?.type == .threadStarted)
        #expect(events.first?.threadId == "command-queued-start")
        #expect(events.first?.petMood == .thinking)
        #expect(events.first?.summary.contains("Queued Codex task on Mac") == true)
        #expect(snapshot.snapshots.first?.threadId == "command-queued-start")
        #expect(snapshot.snapshots.first?.status == .active)
    }

    @Test
    func runtimeSnoozesThreadSnapshotThroughBridgeCommand() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetSnoozeRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let bridgeHome = directory.appendingPathComponent("bridge")
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: bridgeHome,
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController()
        )
        let pairing = try runtime.ensurePairing()
        let start = BridgeCommand(
            id: "snoozed-start",
            type: .startThread,
            payload: ["prompt": "Watch a noisy progress update"],
            confirmation: CommandConfirmation(displayedSummary: "start", riskAccepted: true)
        )
        _ = try runtime.submit(command: start, bearerToken: pairing.token, signature: nil)

        let snooze = BridgeCommand(
            id: "snooze-command",
            type: .snooze,
            threadId: "command-snoozed-start",
            payload: ["durationSeconds": "1200"]
        )
        let result = try runtime.submit(command: snooze, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()
        let records = try SnoozeStore(fileURL: bridgeHome.appendingPathComponent("snoozes.json")).load()

        #expect(result.accepted == true)
        #expect(result.message.contains("20 minutes"))
        #expect(records.first?.threadId == "command-snoozed-start")
        #expect(snapshot.snapshots.first?.threadId == "command-snoozed-start")
        #expect(snapshot.snapshots.first?.snoozedUntil != nil)
    }

    @Test
    func runtimeInterruptsBridgeOwnedRunByThreadId() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetInterruptTests")
            .appendingPathComponent(UUID().uuidString)
        let launcher = StubDetachedLauncher()
        launcher.nextPID = 1234
        let processController = StubProcessController()
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: launcher,
            processController: processController
        )
        let pairing = try runtime.ensurePairing()
        let start = BridgeCommand(
            id: "run-to-stop",
            type: .startThread,
            payload: ["prompt": "Run a long Codex task"],
            confirmation: CommandConfirmation(displayedSummary: "start", riskAccepted: true)
        )
        _ = try runtime.submit(command: start, bearerToken: pairing.token, signature: nil)

        let stop = BridgeCommand(
            type: .interrupt,
            threadId: "command-run-to-stop",
            confirmation: CommandConfirmation(displayedSummary: "stop", riskAccepted: true)
        )
        let result = try runtime.submit(command: stop, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()

        #expect(result.accepted == true)
        #expect(processController.terminatedPIDs == [1234])
        #expect(snapshot.snapshots.first?.threadId == "command-run-to-stop")
        #expect(snapshot.snapshots.first?.status == .failed)
        #expect(snapshot.events.first?.type == .turnFailed)
    }

    @Test
    func runtimeRecordsApprovalResponseAndEmitsEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetApprovalRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController()
        )
        let pairing = try runtime.ensurePairing()
        let command = BridgeCommand(
            id: "approval-command",
            type: .approve,
            threadId: "thread-approval",
            payload: ["requestId": "request-approval"],
            confirmation: CommandConfirmation(displayedSummary: "approve", riskAccepted: true)
        )

        let result = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()
        let approvalStore = ApprovalResponseStore(fileURL: directory.appendingPathComponent("bridge/approval-responses.jsonl"))
        let records = try approvalStore.load()

        #expect(result.accepted == false)
        #expect(records.isEmpty)
        #expect(snapshot.events.isEmpty)
    }

    @Test
    func runtimeSurfacesAppServerApprovalAsPendingSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerApprovalRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            rawRequestId: .string("rpc-live"),
            threadId: "thread-live",
            turnId: "turn-live",
            itemId: "item-live",
            command: "scripts/build-real-device.sh",
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )

        let snapshot = try runtime.snapshot()

        #expect(router.started == true)
        #expect(snapshot.events.first?.type == .approvalRequested)
        #expect(snapshot.events.first?.title == "Codex needs approval")
        #expect(snapshot.snapshots.first?.threadId == "thread-live")
        #expect(snapshot.snapshots.first?.status == .waitingForApproval)
        #expect(snapshot.snapshots.first?.pendingRequest?.id == "appserver:rpc-live")
    }

    @Test
    func runtimeSurfacesAppServerFileChangeApprovalAsPendingSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerFileApprovalRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            kind: .fileChangeApproval,
            rawRequestId: .string("file-live"),
            threadId: "thread-file-live",
            turnId: "turn-file-live",
            itemId: "item-file-live",
            command: "apply_patch",
            cwd: "/tmp/project",
            grantRoot: "/tmp/project",
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )

        let snapshot = try runtime.snapshot()

        #expect(snapshot.events.first?.type == .approvalRequested)
        #expect(snapshot.events.first?.title == "Codex needs file approval")
        #expect(snapshot.events.first?.summary.contains("/tmp/project") == true)
        #expect(snapshot.snapshots.first?.status == .waitingForApproval)
        #expect(snapshot.snapshots.first?.pendingRequest?.id == "appserver:file-live")
        #expect(snapshot.snapshots.first?.pendingRequest?.metadata["requestKind"] == "fileChangeApproval")
        #expect(snapshot.snapshots.first?.pendingRequest?.metadata["grantRoot"] == "/tmp/project")
        #expect(snapshot.snapshots.first?.pendingRequest?.metadata["command"] == "apply_patch")
        #expect(snapshot.snapshots.first?.pendingRequest?.metadata["cwd"] == "/tmp/project")
    }

    @Test
    func runtimeSurfacesAppServerUserInputAsPendingSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerInputRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            kind: .userInput,
            rawRequestId: .string("input-live"),
            threadId: "thread-input-live",
            turnId: "turn-input-live",
            itemId: "item-input-live",
            command: "Choose a release path. Options: Simulator / TestFlight",
            questionIds: ["release_path"],
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )

        let snapshot = try runtime.snapshot()

        #expect(snapshot.events.first?.type == .inputRequested)
        #expect(snapshot.events.first?.title == "Codex needs input")
        #expect(snapshot.snapshots.first?.threadId == "thread-input-live")
        #expect(snapshot.snapshots.first?.status == .waitingForInput)
        #expect(snapshot.snapshots.first?.pendingRequest?.id == "appserver:input-live")
        #expect(snapshot.snapshots.first?.pendingRequest?.requiredAction == .reply)
    }

    @Test
    func runtimeRemovesLivePendingSnapshotWhenRequestClosesElsewhere() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerExternalCloseRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            rawRequestId: .string("rpc-live"),
            threadId: "thread-live",
            turnId: "turn-live",
            itemId: "item-live",
            command: "swift test",
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )

        let pendingSnapshot = try runtime.snapshot()
        router.approvals.removeAll()
        let closedSnapshot = try runtime.snapshot()

        #expect(pendingSnapshot.snapshots.first?.pendingRequest?.id == "appserver:rpc-live")
        #expect(closedSnapshot.snapshots.first?.threadId == "thread-live")
        #expect(closedSnapshot.snapshots.first?.status == .active)
        #expect(closedSnapshot.snapshots.first?.pendingRequest == nil)
        #expect(closedSnapshot.events.first?.id == "appserver-closed-appserver:rpc-live")
        #expect(closedSnapshot.events.first?.title == "Live request closed")
        #expect(closedSnapshot.events.first?.urgency == .low)
        #expect(closedSnapshot.liveControlStatus.pendingRequestCount == 0)
    }

    @Test
    func runtimeDoesNotCloseRetryableLiveRequestStillCached() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerStillCachedRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            kind: .userInput,
            rawRequestId: .string("input-live"),
            threadId: "thread-input-live",
            turnId: "turn-input-live",
            itemId: "item-input-live",
            command: "Choose one.",
            questionIds: ["choice"],
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        router.failUserInputDelivery = true
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )
        let pairing = try runtime.ensurePairing()
        let command = BridgeCommand(
            id: "input-retry-command",
            type: .continueThread,
            threadId: "thread-input-live",
            turnId: "turn-input-live",
            payload: ["requestId": "appserver:input-live", "prompt": "Use TestFlight."],
            confirmation: CommandConfirmation(displayedSummary: "reply", riskAccepted: true)
        )

        _ = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()

        #expect(snapshot.events.first?.id != "appserver-closed-appserver:input-live")
        #expect(snapshot.snapshots.first?.pendingRequest?.id == "appserver:input-live")
        #expect(snapshot.snapshots.first?.status == .waitingForInput)
    }

    @Test
    func runtimeIncludesLiveControlStatusInSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetLiveControlStatusRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            rawRequestId: .string("rpc-live"),
            threadId: "thread-live",
            turnId: "turn-live",
            itemId: "item-live",
            command: "swift test",
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )

        let snapshot = try runtime.snapshot()

        #expect(snapshot.liveControlStatus.state == .connected)
        #expect(snapshot.liveControlStatus.pendingRequestCount == 1)
    }

    @Test
    func runtimeReportsLiveControlDisabledWithoutRouter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetLiveControlDisabledRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController()
        )

        let snapshot = try runtime.snapshot()

        #expect(snapshot.liveControlStatus.state == .disabled)
        #expect(snapshot.liveControlStatus.pendingRequestCount == 0)
    }

    @Test
    func runtimeDeliversApprovalResponseToAppServerRouter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerApprovalDeliveryTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            rawRequestId: .int(42),
            threadId: "thread-live",
            turnId: "turn-live",
            itemId: "item-live",
            command: "swift test",
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )
        let pairing = try runtime.ensurePairing()
        let command = BridgeCommand(
            id: "approval-command",
            type: .approve,
            threadId: "thread-live",
            turnId: "turn-live",
            payload: ["requestId": "appserver:42"],
            confirmation: CommandConfirmation(displayedSummary: "approve", riskAccepted: true)
        )

        let result = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()

        #expect(result.accepted == true)
        #expect(result.message == "stub approval sent")
        #expect(router.resolved.count == 1)
        #expect(router.resolved.first?.requestId == "appserver:42")
        #expect(router.resolved.first?.approved == true)
        #expect(snapshot.events.first?.id == "appserver-closed-appserver:42")
        #expect(snapshot.events.first?.type == .turnProgress)
        #expect(snapshot.events.first?.title == "Approval sent")
        #expect(snapshot.snapshots.first?.threadId == "thread-live")
        #expect(snapshot.snapshots.first?.status == .active)
        #expect(snapshot.snapshots.first?.pendingRequest == nil)
        #expect(snapshot.liveControlStatus.pendingRequestCount == 0)
    }

    @Test
    func runtimeDeliversDeclineResponseAsClosedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerDeclineDeliveryTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            rawRequestId: .int(42),
            threadId: "thread-live",
            turnId: "turn-live",
            itemId: "item-live",
            command: "swift test",
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )
        let pairing = try runtime.ensurePairing()
        let command = BridgeCommand(
            id: "decline-command",
            type: .decline,
            threadId: "thread-live",
            turnId: "turn-live",
            payload: ["requestId": "appserver:42"],
            confirmation: CommandConfirmation(displayedSummary: "decline", riskAccepted: true)
        )

        let result = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()

        #expect(result.accepted == true)
        #expect(result.message == "stub decline sent")
        #expect(router.resolved.first?.approved == false)
        #expect(snapshot.events.first?.id == "appserver-closed-appserver:42")
        #expect(snapshot.events.first?.type == .turnProgress)
        #expect(snapshot.events.first?.title == "Decline sent")
        #expect(snapshot.snapshots.first?.status == .active)
        #expect(snapshot.snapshots.first?.pendingRequest == nil)
    }

    @Test
    func runtimeKeepsLiveApprovalActionableWhenDeliveryFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerApprovalRetryRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            rawRequestId: .int(42),
            threadId: "thread-live",
            turnId: "turn-live",
            itemId: "item-live",
            command: "swift test",
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        router.failApprovalDelivery = true
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )
        let pairing = try runtime.ensurePairing()
        let command = BridgeCommand(
            id: "approval-retry-command",
            type: .approve,
            threadId: "thread-live",
            turnId: "turn-live",
            payload: ["requestId": "appserver:42"],
            confirmation: CommandConfirmation(displayedSummary: "approve", riskAccepted: true)
        )

        let result = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()

        #expect(result.accepted == false)
        #expect(result.message == "approval delivery failed")
        #expect(router.approvals.map(\.id) == ["appserver:42"])
        #expect(snapshot.events.first?.type == .approvalRequested)
        #expect(snapshot.events.first?.title == "Approval not sent")
        #expect(snapshot.snapshots.first?.status == .waitingForApproval)
        #expect(snapshot.snapshots.first?.pendingRequest?.id == "appserver:42")
        #expect(snapshot.snapshots.first?.pendingRequest?.requiredAction == .approve)
    }

    @Test
    func runtimeDeliversUserInputResponseToAppServerRouter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerInputDeliveryTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            kind: .userInput,
            rawRequestId: .string("input-live"),
            threadId: "thread-input-live",
            turnId: "turn-input-live",
            itemId: "item-input-live",
            command: "Choose one.",
            questionIds: ["choice"],
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )
        let pairing = try runtime.ensurePairing()
        let command = BridgeCommand(
            id: "input-command",
            type: .continueThread,
            threadId: "thread-input-live",
            turnId: "turn-input-live",
            payload: ["requestId": "appserver:input-live", "prompt": "Use TestFlight."],
            confirmation: CommandConfirmation(displayedSummary: "reply", riskAccepted: true)
        )

        let result = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()

        #expect(result.accepted == true)
        #expect(result.message == "stub reply sent")
        #expect(router.userInputReplies.count == 1)
        #expect(router.userInputReplies.first?.requestId == "appserver:input-live")
        #expect(router.userInputReplies.first?.answer == "Use TestFlight.")
        #expect(snapshot.events.first?.title == "Reply sent")
    }

    @Test
    func runtimeKeepsLiveInputActionableWhenDeliveryFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerInputRetryRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let request = AppServerApprovalRequest(
            kind: .userInput,
            rawRequestId: .string("input-live"),
            threadId: "thread-input-live",
            turnId: "turn-input-live",
            itemId: "item-input-live",
            command: "Choose one.",
            questionIds: ["choice"],
            createdAt: Date()
        )
        let router = StubAppServerApprovalRouter(approvals: [request])
        router.failUserInputDelivery = true
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )
        let pairing = try runtime.ensurePairing()
        let command = BridgeCommand(
            id: "input-retry-command",
            type: .continueThread,
            threadId: "thread-input-live",
            turnId: "turn-input-live",
            payload: ["requestId": "appserver:input-live", "prompt": "Use TestFlight."],
            confirmation: CommandConfirmation(displayedSummary: "reply", riskAccepted: true)
        )

        let result = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()

        #expect(result.accepted == false)
        #expect(result.message == "reply delivery failed")
        #expect(router.approvals.map(\.id) == ["appserver:input-live"])
        #expect(snapshot.events.first?.type == .inputRequested)
        #expect(snapshot.events.first?.title == "Reply not sent")
        #expect(snapshot.snapshots.first?.status == .waitingForInput)
        #expect(snapshot.snapshots.first?.pendingRequest?.id == "appserver:input-live")
        #expect(snapshot.snapshots.first?.pendingRequest?.requiredAction == .reply)
    }

    @Test
    func runtimeEmitsFailureEventWhenLiveInputReplyCannotBeDelivered() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetAppServerInputFailureRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let router = StubAppServerApprovalRouter(approvals: [])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: StubDetachedLauncher(),
            processController: StubProcessController(),
            appServerApprovalRouter: router
        )
        let pairing = try runtime.ensurePairing()
        let command = BridgeCommand(
            id: "input-command",
            type: .continueThread,
            threadId: "thread-input-live",
            turnId: "turn-input-live",
            payload: ["requestId": "appserver:missing", "prompt": "Use TestFlight."],
            confirmation: CommandConfirmation(displayedSummary: "reply", riskAccepted: true)
        )

        let result = try runtime.submit(command: command, bearerToken: pairing.token, signature: nil)
        let snapshot = try runtime.snapshot()

        #expect(result.accepted == false)
        #expect(result.message.contains("重新确认"))
        #expect(snapshot.events.isEmpty)
        #expect(router.userInputReplies.isEmpty)
    }

    @Test
    func runtimePromotesBridgeRunLogCompletionIntoSnapshotAndEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetRunLogTests")
            .appendingPathComponent(UUID().uuidString)
        let launcher = StubDetachedLauncher()
        let processController = StubProcessController()
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: launcher,
            processController: processController
        )
        let pairing = try runtime.ensurePairing()
        let start = BridgeCommand(
            id: "run-log-complete",
            type: .startThread,
            payload: ["prompt": "Complete from log"],
            confirmation: CommandConfirmation(displayedSummary: "start", riskAccepted: true)
        )
        _ = try runtime.submit(command: start, bearerToken: pairing.token, signature: nil)
        let logFile = try #require(launcher.launches.first?.logFile)
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"type":"agent_message","message":"Working on it"}
        {"type":"turn.completed","summary":"Finished from Codex JSONL"}
        """.write(to: logFile, atomically: true, encoding: .utf8)

        let snapshot = try runtime.snapshot()

        #expect(snapshot.snapshots.first?.threadId == "command-run-log-complete")
        #expect(snapshot.snapshots.first?.status == .completed)
        #expect(snapshot.events.first?.type == .turnCompleted)
        #expect(snapshot.events.first?.summary == "Finished from Codex JSONL")
    }

    @Test
    func runtimeRebindsQueuedRunToRealCodexThreadIdFromLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPetThreadRebindTests")
            .appendingPathComponent(UUID().uuidString)
        let launcher = StubDetachedLauncher()
        let processController = StubProcessController()
        let shell = StubShell(outputs: [
            "/usr/bin/sqlite3 -json": ShellResult(status: 0, stdout: "[]", stderr: "")
        ])
        let runtime = BridgeRuntime(
            codexHome: directory.appendingPathComponent("codex"),
            bridgeHome: directory.appendingPathComponent("bridge"),
            requireSignatures: false,
            shell: shell,
            launcher: launcher,
            processController: processController
        )
        let pairing = try runtime.ensurePairing()
        let start = BridgeCommand(
            id: "thread-rebind",
            type: .startThread,
            payload: ["prompt": "Probe thread id"],
            confirmation: CommandConfirmation(displayedSummary: "start", riskAccepted: true)
        )
        _ = try runtime.submit(command: start, bearerToken: pairing.token, signature: nil)
        let logFile = try #require(launcher.launches.first?.logFile)
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"type":"thread.started","thread_id":"real-thread-1"}
        {"type":"item.completed","item":{"type":"agent_message","text":"Still running"}}
        """.write(to: logFile, atomically: true, encoding: .utf8)

        let snapshot = try runtime.snapshot()

        #expect(snapshot.snapshots.first?.threadId == "real-thread-1")
        #expect(snapshot.snapshots.first?.status == .active)
        #expect(snapshot.events.first?.threadId == "real-thread-1")
    }
}
