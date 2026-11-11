import Foundation

/// Immutable review context: changing tasks or requests invalidates the review.
public struct AssistantCommandDraft: Identifiable, Sendable {
    public let id = UUID()
    public let command: BridgeCommand
    public let summary: String
    public let request: PendingRequest?
    public let reviewedAt: Date

    public init(snapshot: TaskSnapshot, type: BridgeCommandType, text: String = "", now: Date = Date()) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = ["source": "watch-voice-review", "cwd": snapshot.cwd]
        let pending = snapshot.pendingRequest
        if type == .continueThread {
            guard !text.isEmpty else { throw AssistantDraftError.emptyMessage }
            guard snapshot.status != .active && snapshot.status != .runningTool else { throw AssistantDraftError.alreadyRunning }
            guard pending == nil || pending?.requiredAction == .reply else { throw AssistantDraftError.reviewApprovalFirst }
            payload["prompt"] = text
        }
        if type == .approve || type == .decline || pending?.requiredAction == .reply {
            guard let pending, pending.id.hasPrefix("appserver:"),
                  let turn = pending.metadata["turnId"], !turn.isEmpty else { throw AssistantDraftError.refreshRequired }
            if type == .approve || type == .decline {
                guard pending.requiredAction == .approve else { throw AssistantDraftError.refreshRequired }
            }
            if (pending.metadata["questionIds"]?.split(separator: ",").count ?? 0) > 1 { throw AssistantDraftError.multipleQuestions }
            payload["requestId"] = pending.id
        }
        guard [.continueThread, .approve, .decline, .interrupt].contains(type) else { throw AssistantDraftError.refreshRequired }
        command = BridgeCommand(type: type, threadId: snapshot.threadId,
            turnId: pending?.metadata["turnId"], payload: payload, createdAt: now)
        request = pending
        reviewedAt = now
        let action = type == .approve ? "同意本次操作" : type == .decline ? "拒绝本次操作" : type == .interrupt ? "停止由 Bridge 启动的任务" : "发送给 Codex"
        var details = [action, snapshot.title, "任务：\(snapshot.threadId)", "目录：\(snapshot.cwd)"]
        if let pending {
            details.append(pending.summary)
            for key in ["command", "grantRoot", "reason"] {
                if let value = pending.metadata[key], !value.isEmpty { details.append("\(key)：\(value)") }
            }
        }
        if !text.isEmpty { details.append(text) }
        summary = details.joined(separator: "\n\n")
    }

    public func confirmed(for snapshot: TaskSnapshot?, now: Date = Date()) throws -> BridgeCommand {
        guard let snapshot, snapshot.threadId == command.threadId, snapshot.pendingRequest == request,
              now.timeIntervalSince(reviewedAt) >= 0, now.timeIntervalSince(reviewedAt) <= 120 else { throw AssistantDraftError.refreshRequired }
        if command.type == .continueThread && (snapshot.status == .active || snapshot.status == .runningTool) { throw AssistantDraftError.alreadyRunning }
        var confirmed = command
        confirmed.createdAt = now
        confirmed.confirmation = CommandConfirmation(confirmedAt: now, method: "watch-review-tap", displayedSummary: summary, riskAccepted: true)
        return confirmed
    }
}

public enum AssistantDraftError: LocalizedError {
    case emptyMessage, refreshRequired, multipleQuestions, reviewApprovalFirst, alreadyRunning
    public var errorDescription: String? {
        switch self {
        case .emptyMessage: "请先说话或输入内容。"
        case .refreshRequired: "任务或授权已变化，请刷新后重新检查。"
        case .multipleQuestions: "这个请求包含多个问题，请到 Mac 逐题回答。"
        case .reviewApprovalFirst: "请先处理当前待授权操作。"
        case .alreadyRunning: "任务正在运行，请等待回复，避免同时启动另一轮任务。"
        }
    }
}
