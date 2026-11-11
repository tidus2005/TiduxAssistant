import Foundation

public extension TaskStatus {
    var collaborationDisplayName: String {
        switch self {
        case .idle: "空闲"
        case .active: "运行中"
        case .runningTool: "执行工具"
        case .waitingForInput: "待回答"
        case .waitingForApproval: "待审批"
        case .completed: "已完成"
        case .failed: "执行失败"
        case .offline: "离线"
        }
    }
}

public enum WatchCollaborationComponent: String, CaseIterable, Identifiable, Sendable {
    case overview, ask, progress, approvals, arena

    public var id: String { rawValue }
    public var widgetKind: String {
        self == .overview ? CodexWatchWidgetConstants.kind : "CodexWatchPet.\(rawValue)"
    }
    public var title: String {
        switch self {
        case .overview: "AI 协作"
        case .ask: "快速提问"
        case .progress: "任务进度"
        case .approvals: "待我审批"
        case .arena: "表盘大作战"
        }
    }
    public var symbolName: String {
        switch self {
        case .overview: "sparkles"
        case .ask: "mic.fill"
        case .progress: "list.bullet.rectangle"
        case .approvals: "checkmark.shield"
        case .arena: "gamecontroller.fill"
        }
    }
    public var detail: String {
        switch self {
        case .overview: "查看运行任务和待处理事项。"
        case .ask: "打开听写，向 Codex 提问或继续任务。"
        case .progress: "查看任务的真实运行状态和最新结果。"
        case .approvals: "打开待审批列表，查看请求后确认。"
        case .arena: "一键进入大作战，等待 AI 工作时玩一局。"
        }
    }
}

/// A widget link only chooses a destination. It never contains an executable command or approval.
public struct WatchCollaborationRoute: Equatable, Identifiable, Sendable {
    public var component: WatchCollaborationComponent
    public var threadID: String?
    public var id: String { url.absoluteString }

    public init(component: WatchCollaborationComponent, threadID: String? = nil) {
        self.component = component
        self.threadID = threadID
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "codexwatchpet"
        parts.host = "watch"
        parts.path = "/\(component.rawValue)"
        if let threadID, !threadID.isEmpty {
            parts.queryItems = [URLQueryItem(name: "thread", value: threadID)]
        }
        return parts.url!
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "codexwatchpet", parts.host == "watch",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let component = WatchCollaborationComponent(rawValue: String(parts.path.dropFirst())),
              (parts.queryItems ?? []).allSatisfy({ $0.name == "thread" }),
              (parts.queryItems ?? []).count <= 1 else { return nil }
        let threadID = parts.queryItems?.first?.value
        guard threadID == nil || (!threadID!.isEmpty && threadID!.count <= 512) else { return nil }
        self.init(component: component, threadID: threadID)
    }
}

public struct WatchQuestionDraft: Identifiable, Sendable {
    public let command: BridgeCommand
    public let reviewedAt: Date
    public var id: String { command.id }
    public var text: String { command.payload["prompt"] ?? "" }

    public init(text: String, now: Date = Date()) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AssistantDraftError.emptyMessage }
        command = BridgeCommand(type: .startThread,
                                payload: ["prompt": text, "source": "watch-quick-ask"], createdAt: now)
        reviewedAt = now
    }

    public func confirmed(now: Date = Date()) throws -> BridgeCommand {
        guard (0...120).contains(now.timeIntervalSince(reviewedAt)) else { throw AssistantDraftError.refreshRequired }
        var command = command
        command.createdAt = now
        command.confirmation = CommandConfirmation(confirmedAt: now, method: "watch-review-tap",
            displayedSummary: "在 Mac 默认目录新建 Codex 提问\n\n\(text)", riskAccepted: true)
        return command
    }
}

public struct WatchCollaborationSummary: Sendable {
    public let snapshots: [TaskSnapshot]
    public let runningTasks: [TaskSnapshot]
    public let approvalTasks: [TaskSnapshot]
    public let inputTasks: [TaskSnapshot]
    public let freshness: SyncFreshness
    public let bridgeOnline: Bool

    public init(snapshots: [TaskSnapshot], bridgeOnline: Bool, savedAt: Date?, now: Date = Date()) {
        self.snapshots = snapshots.sortedByAttention()
        runningTasks = self.snapshots.filter { $0.status == .active || $0.status == .runningTool }
        approvalTasks = self.snapshots.filter { $0.pendingRequest?.requiredAction == .approve }
        inputTasks = self.snapshots.filter { $0.pendingRequest?.requiredAction == .reply }
        freshness = SyncFreshness(savedAt: savedAt, now: now)
        self.bridgeOnline = bridgeOnline
    }

    public var progressTask: TaskSnapshot? { runningTasks.first ?? snapshots.first }
    public var connectionLabel: String {
        if freshness.status == .noData { return "尚未同步" }
        if freshness.isStale { return "待更新 · 上次状态" }
        return bridgeOnline ? "已同步" : "Mac 桥接离线"
    }

    public func route(for component: WatchCollaborationComponent) -> WatchCollaborationRoute {
        let task: TaskSnapshot? = switch component {
        case .approvals: approvalTasks.first
        case .progress: progressTask
        default: nil
        }
        return WatchCollaborationRoute(component: component, threadID: task?.threadId)
    }
}
