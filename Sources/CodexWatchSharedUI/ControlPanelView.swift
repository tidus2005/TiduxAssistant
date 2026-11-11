import CodexWatchCore
import SwiftUI

public struct ControlPanelView: View {
    public var snapshot: TaskSnapshot?
    public var onCommand: (BridgeCommand) -> Void
    @State private var message = ""
    @State private var pendingCommand: BridgeCommand?
    @State private var showsConfirmation = false
    @State private var validationMessage: String?

    public init(snapshot: TaskSnapshot?, onCommand: @escaping (BridgeCommand) -> Void = { _ in }) {
        self.snapshot = snapshot
        self.onCommand = onCommand
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("交代任务", systemImage: "slider.horizontal.3")
                .font(.headline)

            TextField("说说你想做什么…", text: $message, axis: .vertical)
                .codexControlTextFieldStyle()
                .lineLimit(2...4)

            HStack(spacing: 8) {
                commandButton(primaryCommandTitle, systemImage: "paperplane.fill", type: snapshot == nil ? .startThread : .continueThread)
                commandButton("在 Mac 打开", systemImage: "macwindow", type: .openOnMac)
            }

            if let pending = snapshot?.pendingRequest, pending.requiredAction == .reply {
                replyDraftPanel(for: pending)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if let snapshot {
                actionGrid(for: snapshot)
            }
        }
        .confirmationDialog("确认操作", isPresented: $showsConfirmation) {
            if let command = pendingCommand {
                Button("确认发送", role: command.type == .decline || command.type == .cancel ? .destructive : nil) {
                    var confirmed = command
                    confirmed.confirmation = CommandConfirmation(
                        method: "review-tap",
                        displayedSummary: confirmationSummary(for: command),
                        riskAccepted: true
                    )
                    onCommand(confirmed)
                    if command.type == .startThread || command.type == .continueThread {
                        message = ""
                    }
                    validationMessage = nil
                    pendingCommand = nil
                }
            }
        } message: {
            if let command = pendingCommand {
                Text(confirmationSummary(for: command))
            } else {
                Text("检查内容后，再发送给 Mac。")
            }
        }
        .onChange(of: pendingCommand) { _, command in
            showsConfirmation = command != nil
        }
        .onChange(of: showsConfirmation) { _, isPresented in
            if !isPresented {
                pendingCommand = nil
            }
        }
    }

    private var primaryCommandTitle: String {
        snapshot?.status == .waitingForInput ? "回复" : "发送"
    }

    @ViewBuilder
    private func actionGrid(for snapshot: TaskSnapshot) -> some View {
        let actions = availableActions(for: snapshot)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(actions) { action in
                Button {
                    stage(action: action, snapshot: snapshot)
                } label: {
                    Label(action.title, systemImage: symbol(for: action.kind))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(action.destructive ? .red : .blue)
                .disabled(action.requiresReplyDraft && trimmedMessage.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func replyDraftPanel(for pending: PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(pending.summary, systemImage: "questionmark.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(Self.quickReplies, id: \.self) { reply in
                    Button(reply) {
                        message = reply
                        validationMessage = nil
                    }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.bordered)
                    .lineLimit(2)
                }
            }
        }
    }

    private func commandButton(_ title: String, systemImage: String, type: BridgeCommandType) -> some View {
        Button {
            var payload: [String: String] = [:]
            if !trimmedMessage.isEmpty {
                payload["prompt"] = trimmedMessage
            }
            payload["cwd"] = snapshot?.cwd
            if type == .continueThread, snapshot?.pendingRequest?.requiredAction == .reply {
                payload["requestId"] = snapshot?.pendingRequest?.id
            }
            let command = BridgeCommand(type: type, threadId: snapshot?.threadId, turnId: snapshot?.pendingRequest?.metadata["turnId"], payload: payload)
            if command.requiresHighImpactConfirmation {
                pendingCommand = command
            } else {
                onCommand(command)
            }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(((type == .startThread || type == .continueThread) && trimmedMessage.isEmpty) || (type == .openOnMac && snapshot == nil))
    }

    private func stage(action: BridgeAction, snapshot: TaskSnapshot) {
        if action.requiresReplyDraft && trimmedMessage.isEmpty {
            validationMessage = "请先输入回复内容。"
            return
        }

        let commandType: BridgeCommandType = switch action.kind {
        case .approve: .approve
        case .decline: .decline
        case .cancel: .cancel
        case .interrupt: .interrupt
        case .openOnMac: .openOnMac
        case .snooze: .snooze
        case .reply, .continueThread: .continueThread
        case .startThread: .startThread
        }
        var payload: [String: String] = ["action": action.kind.rawValue]
        if !trimmedMessage.isEmpty {
            payload["prompt"] = trimmedMessage
        }
        payload["cwd"] = snapshot.cwd
        if let pending = snapshot.pendingRequest {
            payload["requestId"] = pending.id
        }
        var command = BridgeCommand(type: commandType, threadId: snapshot.threadId, turnId: snapshot.pendingRequest?.metadata["turnId"], payload: payload)
        if action.requiresHoldConfirmation {
            command.confirmation = CommandConfirmation(displayedSummary: action.summary, riskAccepted: false)
            pendingCommand = command
        } else {
            onCommand(command)
        }
        validationMessage = nil
    }

    private func availableActions(for snapshot: TaskSnapshot) -> [BridgeAction] {
        let isRetry = snapshot.title.localizedCaseInsensitiveContains("not sent")
        return switch snapshot.status {
        case .waitingForApproval:
            [
                BridgeAction(kind: .approve, title: isRetry ? "重新检查授权" : "检查授权", summary: "Approve the pending Codex request.", requiresHoldConfirmation: true),
                BridgeAction(kind: .decline, title: isRetry ? "改为拒绝" : "拒绝", summary: "Decline the pending Codex request.", requiresHoldConfirmation: true, destructive: true)
            ]
        case .waitingForInput:
            [
                BridgeAction(kind: .reply, title: isRetry ? "重试" : "回复", summary: "Send your reply to Codex.", requiresHoldConfirmation: true)
            ]
        case .active, .runningTool:
            [
                BridgeAction(kind: .continueThread, title: "补充说明", summary: "Append instructions to this Codex thread.", requiresHoldConfirmation: true),
                BridgeAction(kind: .interrupt, title: "停止任务", summary: "Interrupt the current bridge-owned turn.", requiresHoldConfirmation: true, destructive: true),
                BridgeAction(kind: .snooze, title: "稍后提醒", summary: "Hide this update from attention for 15 minutes.")
            ]
        default:
            [
                BridgeAction(kind: .openOnMac, title: "在 Mac 打开", summary: "Open Codex on Mac."),
                BridgeAction(kind: .snooze, title: "稍后提醒", summary: "Hide this update from attention for 15 minutes.")
            ]
        }
    }

    private func symbol(for kind: BridgeActionKind) -> String {
        switch kind {
        case .reply: "text.bubble"
        case .continueThread: "arrowshape.turn.up.right"
        case .approve: "checkmark.shield"
        case .decline: "xmark.shield"
        case .cancel: "xmark.circle"
        case .interrupt: "stop.circle"
        case .openOnMac: "macwindow"
        case .snooze: "bell.slash"
        case .startThread: "plus.bubble"
        }
    }

    private func confirmationSummary(for command: BridgeCommand) -> String {
        let action = switch command.type {
        case .startThread:
            "在 Mac 上新建 Codex 任务。"
        case .continueThread:
            "将以下内容发送到当前任务。"
        case .approve:
            "授权当前待处理请求。"
        case .decline:
            "拒绝当前待处理请求。"
        case .cancel:
            "取消所选任务。"
        case .interrupt:
            "停止由随行助手启动的当前任务。"
        case .openOnMac:
            "在 Mac 上打开 Codex。"
        case .snooze:
            "稍后再提醒。"
        }
        return [action, command.payload["prompt"], snapshot?.pendingRequest?.summary, snapshot?.pendingRequest?.metadata["command"], snapshot?.pendingRequest?.metadata["grantRoot"], snapshot?.cwd].compactMap { $0 }.joined(separator: "\n\n")
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let quickReplies = [
        "按你的判断继续。",
        "基于当前上下文继续。",
        "暂停，等我在 Mac 上回复。"
    ]
}

private extension BridgeAction {
    var requiresReplyDraft: Bool {
        kind == .reply
    }
}

private extension View {
    @ViewBuilder
    func codexControlTextFieldStyle() -> some View {
        #if os(watchOS)
        textFieldStyle(.plain)
        #else
        textFieldStyle(.roundedBorder)
        #endif
    }
}

#Preview {
    ControlPanelView(snapshot: .sampleInput)
        .padding()
}
