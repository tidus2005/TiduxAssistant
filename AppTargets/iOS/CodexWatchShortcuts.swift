import AppIntents
import CodexWatchIntents

struct CodexWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PrepareSMSForwardIntent(), phrases: ["在\(.applicationName)准备短信转发"], shortTitle: "保存并准备短信转发", systemImageName: "message.badge")
        AppShortcut(intent: SaveReceivedMessageIntent(), phrases: ["在\(.applicationName)保存短信"], shortTitle: "保存收到的短信", systemImageName: "message")
        AppShortcut(intent: MarkMessageMailHandedOffIntent(), phrases: ["在\(.applicationName)标记邮件交接"], shortTitle: "标记短信已交给邮件", systemImageName: "envelope")
        AppShortcut(
            intent: ShowActiveTasksIntent(),
            phrases: ["Show \(.applicationName)", "Show Codex tasks in \(.applicationName)"],
            shortTitle: "Show Tasks",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: StartCodexTaskIntent(),
            phrases: ["Start Codex task in \(.applicationName)"],
            shortTitle: "Start Task",
            systemImageName: "plus.bubble"
        )
        AppShortcut(
            intent: ApproveLatestPendingRequestIntent(),
            phrases: ["Approve latest Codex request in \(.applicationName)", "Approve Codex request in \(.applicationName)"],
            shortTitle: "Approve",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: DeclineLatestPendingRequestIntent(),
            phrases: ["Decline latest Codex request in \(.applicationName)", "Decline Codex request in \(.applicationName)"],
            shortTitle: "Decline",
            systemImageName: "xmark.shield"
        )
        AppShortcut(
            intent: ReplyToLatestInputRequestIntent(),
            phrases: ["Reply to latest Codex request in \(.applicationName)", "Reply to Codex request in \(.applicationName)"],
            shortTitle: "Reply",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: ContinueCodexThreadIntent(),
            phrases: ["Continue Codex thread in \(.applicationName)"],
            shortTitle: "Continue Thread",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: ToggleQuietModeIntent(),
            phrases: ["Toggle quiet mode in \(.applicationName)"],
            shortTitle: "Quiet Mode",
            systemImageName: "bell.slash"
        )
    }
}
