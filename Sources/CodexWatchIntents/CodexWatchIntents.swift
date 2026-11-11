import AppIntents
import CodexWatchCore
import Foundation

public struct CodexWatchIntentsPackage: AppIntentsPackage {}

public enum CodexTaskMode: String, AppEnum {
    case newThread
    case continueLatest

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Codex task mode")
    public static let caseDisplayRepresentations: [CodexTaskMode: DisplayRepresentation] = [
        .newThread: "New task",
        .continueLatest: "Continue latest"
    ]
}

public struct StartCodexTaskIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Codex Task"
    public static let description = IntentDescription("Create a Codex task through the local bridge.")
    public static let openAppWhenRun = false

    @Parameter(title: "Prompt")
    public var prompt: String

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let client = IntentBridgeClient.makeClient() else {
            return .result(dialog: "Pair Codex Watch Pet on iPhone first.")
        }
        let command = BridgeCommand(
            type: .startThread,
            payload: ["prompt": prompt, "source": "app-intent"],
            confirmation: CommandConfirmation(
                method: "app-intent",
                displayedSummary: "Start Codex task",
                riskAccepted: true
            )
        )
        do {
            let result = try await client.send(command: command)
            if result.accepted {
                return .result(dialog: "Started Codex task.")
            }
            return .result(dialog: "\(result.message)")
        } catch {
            return .result(dialog: "Could not start Codex task: \(error.localizedDescription)")
        }
    }
}

public struct ContinueCodexThreadIntent: AppIntent {
    public static let title: LocalizedStringResource = "Continue Codex Thread"
    public static let description = IntentDescription("Add an instruction to the selected Codex thread.")
    public static let openAppWhenRun = false

    @Parameter(title: "Thread ID")
    public var threadId: String

    @Parameter(title: "Instruction")
    public var instruction: String

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let client = IntentBridgeClient.makeClient() else {
            return .result(dialog: "Pair Codex Watch Pet on iPhone first.")
        }
        let command = BridgeCommand(
            type: .continueThread,
            threadId: threadId,
            payload: ["prompt": instruction, "source": "app-intent"],
            confirmation: CommandConfirmation(
                method: "app-intent",
                displayedSummary: "Continue Codex thread",
                riskAccepted: true
            )
        )
        do {
            let result = try await client.send(command: command)
            if result.accepted {
                return .result(dialog: "Sent instruction to Codex.")
            }
            return .result(dialog: "\(result.message)")
        } catch {
            return .result(dialog: "Could not continue Codex thread: \(error.localizedDescription)")
        }
    }
}

public struct ApprovePendingRequestIntent: AppIntent {
    public static let title: LocalizedStringResource = "Approve Codex Request"
    public static let description = IntentDescription("Approve a pending Codex request through the local bridge.")
    public static let openAppWhenRun = false

    @Parameter(title: "Request ID")
    public var requestId: String

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let client = IntentBridgeClient.makeClient() else {
            return .result(dialog: "Pair Codex Watch Pet on iPhone first.")
        }
        do {
            let state = try await client.fetchSnapshot()
            guard let snapshot = state.snapshots.first(where: { $0.pendingRequest?.id == requestId }) else {
                return .result(dialog: "请求已变化，请刷新后重试。")
            }
            let draft = try AssistantCommandDraft(snapshot: snapshot, type: .approve)
            try await requestConfirmation(dialog: "\(draft.summary)")
            let refreshed = try await client.fetchSnapshot()
            let command = try draft.confirmed(for: refreshed.snapshots.first { $0.threadId == snapshot.threadId })
            let result = try await client.send(command: command)
            if result.accepted {
                return .result(dialog: "授权已发送，等待任务更新。")
            }
            return .result(dialog: "\(result.message)")
        } catch {
            return .result(dialog: "Could not approve request: \(error.localizedDescription)")
        }
    }
}

public struct DeclinePendingRequestIntent: AppIntent {
    public static let title: LocalizedStringResource = "Decline Codex Request"
    public static let description = IntentDescription("Decline a pending Codex request through the local bridge.")
    public static let openAppWhenRun = false

    @Parameter(title: "Request ID")
    public var requestId: String

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let client = IntentBridgeClient.makeClient() else {
            return .result(dialog: "Pair Codex Watch Pet on iPhone first.")
        }
        do {
            let state = try await client.fetchSnapshot()
            guard let snapshot = state.snapshots.first(where: { $0.pendingRequest?.id == requestId }) else {
                return .result(dialog: "请求已变化，请刷新后重试。")
            }
            let draft = try AssistantCommandDraft(snapshot: snapshot, type: .decline)
            try await requestConfirmation(dialog: "\(draft.summary)")
            let refreshed = try await client.fetchSnapshot()
            let command = try draft.confirmed(for: refreshed.snapshots.first { $0.threadId == snapshot.threadId })
            let result = try await client.send(command: command)
            if result.accepted {
                return .result(dialog: "Declined Codex request.")
            }
            return .result(dialog: "\(result.message)")
        } catch {
            return .result(dialog: "Could not decline request: \(error.localizedDescription)")
        }
    }
}

public struct ReplyToPendingRequestIntent: AppIntent {
    public static let title: LocalizedStringResource = "Reply to Codex Request"
    public static let description = IntentDescription("Send text input to a pending Codex request through the local bridge.")
    public static let openAppWhenRun = false

    @Parameter(title: "Request ID")
    public var requestId: String

    @Parameter(title: "Reply")
    public var reply: String

    public init() {}

    public func perform() async throws -> some IntentResult {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else {
            return .result(dialog: "Add a reply before sending it to Codex.")
        }
        guard let client = IntentBridgeClient.makeClient() else {
            return .result(dialog: "Pair Codex Watch Pet on iPhone first.")
        }
        do {
            let state = try await client.fetchSnapshot()
            guard let snapshot = state.snapshots.first(where: { $0.pendingRequest?.id == requestId }) else {
                return .result(dialog: "请求已变化，请刷新后重试。")
            }
            let draft = try AssistantCommandDraft(snapshot: snapshot, type: .continueThread, text: trimmedReply)
            try await requestConfirmation(dialog: "\(draft.summary)")
            let refreshed = try await client.fetchSnapshot()
            let command = try draft.confirmed(for: refreshed.snapshots.first { $0.threadId == snapshot.threadId })
            let result = try await client.send(command: command)
            if result.accepted {
                return .result(dialog: "Sent reply to Codex.")
            }
            return .result(dialog: "\(result.message)")
        } catch {
            return .result(dialog: "Could not send reply: \(error.localizedDescription)")
        }
    }
}

public struct ApproveLatestPendingRequestIntent: AppIntent {
    public static let title: LocalizedStringResource = "Approve Latest Codex Request"
    public static let description = IntentDescription("Approve the highest-priority pending Codex approval request.")
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let client = IntentBridgeClient.makeClient() else {
            return .result(dialog: "Pair Codex Watch Pet on iPhone first.")
        }

        do {
            let target = try await IntentPendingRequestResolver.latestTarget(requiring: .approve, client: client)
            let draft = try AssistantCommandDraft(snapshot: target.snapshot, type: .approve)
            try await requestConfirmation(dialog: "\(draft.summary)")
            let refreshed = try await client.fetchSnapshot()
            let command = try draft.confirmed(for: refreshed.snapshots.first { $0.threadId == target.snapshot.threadId })
            let result = try await client.send(command: command)
            if result.accepted {
                return .result(dialog: "授权已发送，等待任务更新。")
            }
            return .result(dialog: "\(result.message)")
        } catch IntentPendingRequestError.notFound {
            return .result(dialog: "No pending Codex approval request was found.")
        } catch {
            return .result(dialog: "Could not approve latest request: \(error.localizedDescription)")
        }
    }
}

public struct DeclineLatestPendingRequestIntent: AppIntent {
    public static let title: LocalizedStringResource = "Decline Latest Codex Request"
    public static let description = IntentDescription("Decline the highest-priority pending Codex approval request.")
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let client = IntentBridgeClient.makeClient() else {
            return .result(dialog: "Pair Codex Watch Pet on iPhone first.")
        }

        do {
            let target = try await IntentPendingRequestResolver.latestTarget(requiring: .approve, client: client)
            let draft = try AssistantCommandDraft(snapshot: target.snapshot, type: .decline)
            try await requestConfirmation(dialog: "\(draft.summary)")
            let refreshed = try await client.fetchSnapshot()
            let command = try draft.confirmed(for: refreshed.snapshots.first { $0.threadId == target.snapshot.threadId })
            let result = try await client.send(command: command)
            if result.accepted {
                return .result(dialog: "Declined latest Codex request.")
            }
            return .result(dialog: "\(result.message)")
        } catch IntentPendingRequestError.notFound {
            return .result(dialog: "No pending Codex approval request was found.")
        } catch {
            return .result(dialog: "Could not decline latest request: \(error.localizedDescription)")
        }
    }
}

public struct ReplyToLatestInputRequestIntent: AppIntent {
    public static let title: LocalizedStringResource = "Reply to Latest Codex Request"
    public static let description = IntentDescription("Send text input to the highest-priority pending Codex input request.")
    public static let openAppWhenRun = false

    @Parameter(title: "Reply")
    public var reply: String

    public init() {}

    public func perform() async throws -> some IntentResult {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else {
            return .result(dialog: "Add a reply before sending it to Codex.")
        }
        guard let client = IntentBridgeClient.makeClient() else {
            return .result(dialog: "Pair Codex Watch Pet on iPhone first.")
        }

        do {
            let target = try await IntentPendingRequestResolver.latestTarget(requiring: .reply, client: client)
            let draft = try AssistantCommandDraft(snapshot: target.snapshot, type: .continueThread, text: trimmedReply)
            try await requestConfirmation(dialog: "\(draft.summary)")
            let refreshed = try await client.fetchSnapshot()
            let command = try draft.confirmed(for: refreshed.snapshots.first { $0.threadId == target.snapshot.threadId })
            let result = try await client.send(command: command)
            if result.accepted {
                return .result(dialog: "Sent reply to latest Codex request.")
            }
            return .result(dialog: "\(result.message)")
        } catch IntentPendingRequestError.notFound {
            return .result(dialog: "No pending Codex input request was found.")
        } catch {
            return .result(dialog: "Could not reply to latest request: \(error.localizedDescription)")
        }
    }
}

public struct ShowActiveTasksIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Codex Tasks"
    public static let description = IntentDescription("Summarize active Codex tasks through the local bridge.")
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard let client = IntentBridgeClient.makeClient() else {
            return .result(dialog: "Pair Codex Watch Pet on iPhone first.")
        }
        do {
            let state = try await client.fetchSnapshot()
            let topTask = state.widgetSnapshot?.title ?? "no active task"
            if state.unreadHighUrgencyCount > 0 {
                return .result(dialog: "\(state.unreadHighUrgencyCount) Codex task needs attention. Top task: \(topTask).")
            }
            return .result(dialog: "\(state.snapshots.count) Codex tasks found. Top task: \(topTask).")
        } catch {
            return .result(dialog: "Could not read Codex tasks: \(error.localizedDescription)")
        }
    }
}

public struct ToggleQuietModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Toggle Codex Quiet Mode"
    public static let description = IntentDescription("Toggle quiet mode for Codex Watch notifications.")
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        let enabled = QuietModeStore().toggle()
        return .result(dialog: enabled ? "Codex quiet mode is on." : "Codex quiet mode is off.")
    }
}

private enum IntentBridgeClient {
    static func makeClient() -> BridgeHTTPClient? {
        guard let configuration = BridgeConnectionStore().load() else {
            return nil
        }
        return BridgeHTTPClient(configuration: configuration)
    }

}

private enum IntentPendingRequestError: Error {
    case notFound
}

private struct IntentPendingRequestTarget {
    var snapshot: TaskSnapshot
    var request: PendingRequest
}

private enum IntentPendingRequestResolver {
    static func latestTarget(requiring action: BridgeActionKind, client: BridgeHTTPClient) async throws -> IntentPendingRequestTarget {
        let state = try await client.fetchSnapshot()
        guard let snapshot = state.latestPendingRequest(requiring: action),
              let request = snapshot.pendingRequest else {
            throw IntentPendingRequestError.notFound
        }
        return IntentPendingRequestTarget(snapshot: snapshot, request: request)
    }
}
