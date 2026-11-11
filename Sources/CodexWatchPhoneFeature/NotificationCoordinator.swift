import CodexWatchCore
import Foundation

#if canImport(UserNotifications)
import UserNotifications

private enum NotificationCategoryID {
    static let task = "CODEX_WATCH_TASK"
    static let input = "CODEX_WATCH_INPUT"
    static let approval = "CODEX_WATCH_APPROVAL"
}

private enum NotificationActionID {
    static let reply = "CWP_REPLY"
    static let approve = "CWP_APPROVE"
    static let decline = "CWP_DECLINE"
    static let openMac = "CWP_OPEN_MAC"
    static let review = "CWP_REVIEW"
    static let snooze = "CWP_SNOOZE"
}
#endif

@MainActor
public final class NotificationCoordinator: NSObject {
    public var onCommand: ((BridgeCommand) -> Void)?

    private let planner: NotificationPlanner
    private let quietModeStore: QuietModeStore
    private var plannerState = NotificationPlannerState()

    public init(policy: NotificationPolicy = NotificationPolicy(), quietModeStore: QuietModeStore = QuietModeStore()) {
        self.planner = NotificationPlanner(policy: policy)
        self.quietModeStore = quietModeStore
        super.init()
        #if os(iOS)
        UNUserNotificationCenter.current().delegate = self
        Self.registerCategories(on: UNUserNotificationCenter.current())
        #endif
    }

    public func scheduleNotifications(for state: BridgeState) {
        let snoozedThreadIds = Set(
            state.snapshots
                .filter { $0.isSnoozed && $0.pendingRequest == nil }
                .map(\.threadId)
        )
        scheduleNotifications(for: state.events, snoozedThreadIds: snoozedThreadIds)
    }

    public func scheduleNotifications(for events: [BridgeEvent]) {
        scheduleNotifications(for: events, snoozedThreadIds: [])
    }

    private func scheduleNotifications(for events: [BridgeEvent], snoozedThreadIds: Set<String>) {
        #if canImport(UserNotifications)
        let result = planner.plan(for: events, state: plannerState)
        plannerState = result.state
        let notifications = quietModeStore.isEnabled
            ? result.notifications.filter { $0.event.urgency == .high }
            : result.notifications
        let unsnoozedNotifications = notifications.filter { planned in
            !snoozedThreadIds.contains(planned.event.threadId)
                || planned.event.type == .approvalRequested
                || planned.event.type == .inputRequested
        }
        guard !unsnoozedNotifications.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Self.registerCategories(on: center)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        for planned in unsnoozedNotifications {
            let event = planned.event
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.summary
            content.sound = .default
            content.threadIdentifier = event.threadId
            content.interruptionLevel = event.urgency == .high ? .timeSensitive : .active
            content.categoryIdentifier = Self.categoryIdentifier(for: event)
            content.userInfo = Self.userInfo(for: event)
            let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
            center.add(request)
        }
        #endif
    }

    #if canImport(UserNotifications)
    private static func registerCategories(on center: UNUserNotificationCenter) {
        let reply = UNTextInputNotificationAction(
            identifier: NotificationActionID.reply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply to Codex"
        )
        let approve = UNNotificationAction(
            identifier: NotificationActionID.approve,
            title: "Approve",
            options: [.authenticationRequired]
        )
        let decline = UNNotificationAction(
            identifier: NotificationActionID.decline,
            title: "Decline",
            options: [.authenticationRequired, .destructive]
        )
        let openMac = UNNotificationAction(identifier: NotificationActionID.openMac, title: "Open Mac", options: [])
        let review = UNNotificationAction(identifier: NotificationActionID.review, title: "Review", options: [.foreground])
        let snooze = UNNotificationAction(identifier: NotificationActionID.snooze, title: "Snooze", options: [])

        let input = UNNotificationCategory(
            identifier: NotificationCategoryID.input,
            actions: [reply, review, openMac],
            intentIdentifiers: [],
            options: []
        )
        let approval = UNNotificationCategory(
            identifier: NotificationCategoryID.approval,
            actions: [approve, decline, review, openMac],
            intentIdentifiers: [],
            options: []
        )
        let task = UNNotificationCategory(
            identifier: NotificationCategoryID.task,
            actions: [snooze, openMac],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([input, approval, task])
    }

    private static func categoryIdentifier(for event: BridgeEvent) -> String {
        switch event.type {
        case .approvalRequested:
            NotificationCategoryID.approval
        case .inputRequested:
            NotificationCategoryID.input
        default:
            NotificationCategoryID.task
        }
    }

    private static func userInfo(for event: BridgeEvent) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "threadId": event.threadId,
            "eventType": event.type.rawValue,
            "title": event.title
        ]
        if let turnId = event.turnId {
            info["turnId"] = turnId
        }
        if let requestId = Self.requestId(from: event) {
            info["requestId"] = requestId
        }
        return info
    }

    private static func requestId(from event: BridgeEvent) -> String? {
        let prefix = "appserver-approval-"
        guard event.id.hasPrefix(prefix) else { return nil }
        return String(event.id.dropFirst(prefix.count)).split(separator: "#", maxSplits: 1).first.map(String.init)
    }
    #endif
}

#if canImport(UserNotifications)
private final class NotificationCompletion: @unchecked Sendable {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    @MainActor func finish() { completion() }
}

extension NotificationCoordinator: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completeResponse(command: Self.command(from: response), completionHandler: completionHandler)
    }

    nonisolated func completeResponse(command: BridgeCommand?, completionHandler: @escaping () -> Void) {
        let completion = NotificationCompletion(completionHandler)
        Task { @MainActor in
            if let command { self.onCommand?(command) }
            // UIKit's notification response completion performs scene restoration.
            // Complete on main even for default taps, which have no command.
            completion.finish()
        }
    }

    private nonisolated static func command(from response: UNNotificationResponse) -> BridgeCommand? {
        let userInfo = response.notification.request.content.userInfo
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        return command(actionIdentifier: response.actionIdentifier, userInfo: userInfo, userText: userText)
    }

    nonisolated static func command(actionIdentifier: String, userInfo: [AnyHashable: Any], userText: String? = nil) -> BridgeCommand? {
        guard let threadId = userInfo["threadId"] as? String else { return nil }
        let turnId = userInfo["turnId"] as? String

        switch actionIdentifier {
        case NotificationActionID.reply:
            let reply = userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reply.isEmpty else { return nil }
            var payload = ["prompt": reply, "source": "notification-reply"]
            if let requestId = userInfo["requestId"] as? String {
                payload["requestId"] = requestId
            }
            return BridgeCommand(
                type: .continueThread,
                threadId: threadId,
                turnId: turnId,
                payload: payload,
                confirmation: CommandConfirmation(
                    displayedSummary: "Reply from notification",
                    riskAccepted: true
                )
            )
        case NotificationActionID.approve, NotificationActionID.decline:
            guard let requestId = userInfo["requestId"] as? String else { return nil }
            let approved = actionIdentifier == NotificationActionID.approve
            return BridgeCommand(
                type: approved ? .approve : .decline,
                threadId: threadId,
                turnId: turnId,
                payload: ["requestId": requestId, "source": "notification-action"],
                confirmation: CommandConfirmation(
                    method: "notification-action",
                    displayedSummary: approved ? "Approve Codex request" : "Decline Codex request",
                    riskAccepted: true
                )
            )
        case NotificationActionID.openMac:
            return BridgeCommand(
                type: .openOnMac,
                threadId: threadId,
                turnId: turnId,
                payload: ["source": "notification-action"]
            )
        case NotificationActionID.snooze:
            return BridgeCommand(
                type: .snooze,
                threadId: threadId,
                turnId: turnId,
                payload: ["source": "notification-action", "durationSeconds": "900"]
            )
        default:
            return nil
        }
    }
}
#endif
