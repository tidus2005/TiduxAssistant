import Foundation

enum DeliveryState: String, Codable, Sendable {
    case inserted, copiedByUser, unconfirmed, retainedOnly, cancelled, failed
    var title: String {
        switch self {
        case .inserted: "已写入原输入框"
        case .copiedByUser: "已手动复制，尚未确认粘贴"
        case .unconfirmed: "自动写入未确认，请先检查原输入框"
        case .retainedOnly: "仅保留在本 App，可手动复制"
        case .cancelled: "已取消"
        case .failed: "交付失败"
        }
    }
}

@MainActor
struct DeliveryCoordinator {
    let insertion: any VoiceTextInserting
    let pasteboard: any VoicePasteboardWriting

    func deliver(_ text: String, target: CapturedTextTarget?) async -> DeliveryState {
        guard !Task.isCancelled else { return .cancelled }
        guard let target else { return .retainedOnly }
        do {
            _ = try await insertion.insert(text, into: target)
            return .inserted
        } catch TextInsertionService.InsertionError.pasteboardDeliveryUnconfirmed {
            return .unconfirmed
        } catch TextInsertionService.InsertionError.pasteboardRestoreFailed {
            return .unconfirmed
        } catch {
            // Target mismatch, permission denial and every other failure must
            // leave the user's clipboard alone. Only the explicit button copies.
            return Task.isCancelled ? .cancelled : .retainedOnly
        }
    }

    func copyByUser(_ text: String) -> DeliveryState {
        guard !text.isEmpty, pasteboard.write(text) else { return .retainedOnly }
        return .copiedByUser
    }
}
