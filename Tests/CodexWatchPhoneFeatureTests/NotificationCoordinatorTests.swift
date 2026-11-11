@testable import CodexWatchPhoneFeature
import Testing
import Foundation

#if canImport(UserNotifications)
@Suite("Notification commands")
struct NotificationCoordinatorTests {
    @Test func defaultNotificationTapCompletesOnMainThread() async {
        let coordinator = await NotificationCoordinator()
        await withCheckedContinuation { continuation in
            Task.detached {
                coordinator.completeResponse(command: nil) {
                    #expect(Thread.isMainThread)
                    continuation.resume()
                }
            }
        }
    }

    @Test
    func approvalActionsCreateConfirmedBridgeCommands() throws {
        let userInfo: [AnyHashable: Any] = [
            "threadId": "thread-live",
            "turnId": "turn-live",
            "requestId": "appserver:42"
        ]

        let approve = try #require(NotificationCoordinator.command(
            actionIdentifier: "CWP_APPROVE",
            userInfo: userInfo
        ))
        let decline = try #require(NotificationCoordinator.command(
            actionIdentifier: "CWP_DECLINE",
            userInfo: userInfo
        ))

        #expect(approve.type == .approve)
        #expect(approve.threadId == "thread-live")
        #expect(approve.turnId == "turn-live")
        #expect(approve.payload["requestId"] == "appserver:42")
        #expect(approve.payload["source"] == "notification-action")
        #expect(approve.confirmation?.method == "notification-action")
        #expect(approve.confirmation?.riskAccepted == true)

        #expect(decline.type == .decline)
        #expect(decline.payload["requestId"] == "appserver:42")
        #expect(decline.confirmation?.riskAccepted == true)
    }

    @Test
    func textReplyCarriesLiveRequestId() throws {
        let command = try #require(NotificationCoordinator.command(
            actionIdentifier: "CWP_REPLY",
            userInfo: [
                "threadId": "thread-input",
                "requestId": "appserver:input-live"
            ],
            userText: "  Use TestFlight.  "
        ))

        #expect(command.type == .continueThread)
        #expect(command.threadId == "thread-input")
        #expect(command.payload["requestId"] == "appserver:input-live")
        #expect(command.payload["prompt"] == "Use TestFlight.")
        #expect(command.confirmation?.riskAccepted == true)
    }

    @Test
    func snoozeActionCreatesLocalSnoozeCommand() throws {
        let command = try #require(NotificationCoordinator.command(
            actionIdentifier: "CWP_SNOOZE",
            userInfo: [
                "threadId": "thread-progress",
                "turnId": "turn-progress"
            ]
        ))

        #expect(command.type == .snooze)
        #expect(command.threadId == "thread-progress")
        #expect(command.turnId == "turn-progress")
        #expect(command.payload["durationSeconds"] == "900")
        #expect(command.payload["source"] == "notification-action")
        #expect(command.confirmation == nil)
    }
}
#endif
