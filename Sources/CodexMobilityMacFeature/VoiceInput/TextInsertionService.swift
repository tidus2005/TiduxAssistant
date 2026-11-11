import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import OSLog

public struct TextSelectionRangeSnapshot: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    fileprivate init(_ range: CFRange) {
        self.init(location: range.location, length: range.length)
    }
}

/// An opaque snapshot of the text destination that was focused when recording
/// began. The underlying AX element is intentionally not exposed to callers.
public struct CapturedTextTarget {
    fileprivate let element: AXUIElement

    public let processIdentifier: pid_t
    public let applicationBundleIdentifier: String?
    public let role: String
    public let subrole: String?
    public let selectedTextRangeAtCapture: TextSelectionRangeSnapshot?

    init(
        element: AXUIElement,
        processIdentifier: pid_t,
        applicationBundleIdentifier: String?,
        role: String,
        subrole: String?,
        selectedTextRangeAtCapture: TextSelectionRangeSnapshot?
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.role = role
        self.subrole = subrole
        self.selectedTextRangeAtCapture = selectedTextRangeAtCapture
    }
}

public typealias TextInsertionTarget = CapturedTextTarget

/// A one-shot signal set only after the lazy `.string` representation has
/// actually been requested from the pasteboard item.
final class PasteboardReadReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var isArmed = false
    private var isDelivered = false

    init() {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func arm() {
        lock.withLock {
            isArmed = true
        }
    }

    func markStringRead() {
        let shouldSignal = lock.withLock {
            guard isArmed, !isDelivered else {
                return false
            }
            isDelivered = true
            return true
        }

        if shouldSignal {
            continuation.yield(())
            continuation.finish()
        }
    }

    func waitForStringRead(timeout: Duration) async -> Bool {
        if lock.withLock({ isDelivered }) {
            return true
        }

        return await withTaskGroup(of: Bool.self) { group in
            let stream = self.stream
            group.addTask {
                for await _ in stream {
                    return true
                }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

struct PasteboardDeliveryPolicy: Equatable, Sendable {
    let confirmationTimeout: Duration
    let postReadSettleDelay: Duration

    static let standard = PasteboardDeliveryPolicy(
        confirmationTimeout: .milliseconds(1_500),
        postReadSettleDelay: .milliseconds(80)
    )
}

struct PasteboardDeliveryEvidence: Equatable, Sendable {
    let targetStillFocused: Bool
    let capturedRange: TextSelectionRangeSnapshot?
    let deliveredRange: TextSelectionRangeSnapshot?
    let insertedUTF16Count: Int

    var confirmsTargetDelivery: Bool {
        guard targetStillFocused,
              let capturedRange,
              let deliveredRange
        else {
            return false
        }
        return insertedUTF16Count > 0
            && deliveredRange.location == capturedRange.location + insertedUTF16Count
            && deliveredRange.length == 0
    }
}

private final class ReceiptStringDataProvider:
    NSObject,
    NSPasteboardItemDataProvider
{
    private let text: String
    private let receipt: PasteboardReadReceipt

    init(text: String, receipt: PasteboardReadReceipt) {
        self.text = text
        self.receipt = receipt
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .string, item.setString(text, forType: type) else {
            return
        }
        receipt.markStringRead()
    }
}

/// Captures and writes to a focused macOS text element without ever retargeting
/// to whichever app happens to be active at completion time.
@MainActor
public final class TextInsertionService {
    public enum InsertionMethod: Equatable, Sendable {
        case accessibilitySelectedText
        case pasteboard
    }

    public enum InsertionError: Error, Equatable, LocalizedError, Sendable {
        case accessibilityPermissionDenied
        case noFocusedElement
        case noFrontmostApplication
        case focusedApplicationMismatch(expected: pid_t, actual: pid_t)
        case secureTextField
        case notEditableText
        case targetApplicationChanged(expected: pid_t, actual: pid_t?)
        case focusChanged
        case accessibilityWriteFailed(code: Int32)
        case pasteboardWriteFailed
        case pasteboardRestoreFailed
        case pasteboardDeliveryUnconfirmed(resultCopied: Bool)
        case keyboardEventUnavailable

        public var errorDescription: String? {
            switch self {
            case .accessibilityPermissionDenied:
                return "Tidux助手尚未获得辅助功能权限。"
            case .noFocusedElement:
                return "没有找到当前聚焦的输入框。"
            case .noFrontmostApplication:
                return "无法确定当前前台应用。"
            case let .focusedApplicationMismatch(expected, actual):
                return "聚焦输入框不属于当前前台应用（焦点 PID \(expected)，前台 PID \(actual)）。"
            case .secureTextField:
                return "出于安全原因，Tidux助手不会读取或写入密码输入框。"
            case .notEditableText:
                return "当前焦点不是可编辑文本区域。"
            case let .targetApplicationChanged(expected, actual):
                if let actual {
                    return "录音期间前台应用发生变化（原 PID \(expected)，现 PID \(actual)）。"
                }
                return "录音期间前台应用已不可用。"
            case .focusChanged:
                return "录音期间输入焦点发生变化，已取消自动写入。"
            case let .accessibilityWriteFailed(code):
                return "通过辅助功能写入失败（错误码 \(code)）。"
            case .pasteboardWriteFailed:
                return "无法创建安全的临时粘贴板事务。"
            case .pasteboardRestoreFailed:
                return "文字已发送，但无法恢复原粘贴板内容。"
            case let .pasteboardDeliveryUnconfirmed(resultCopied):
                if resultCopied {
                    return "目标应用未确认读取文字，结果已保留在剪贴板，请手动粘贴。"
                }
                return "自动写入未确认；已恢复原剪贴板或保留较新的内容，结果保留在本 App。"
            case .keyboardEventUnavailable:
                return "无法创建系统粘贴按键事件。"
            }
        }
    }

    private struct PasteboardSnapshot {
        let items: [NSPasteboardItem]
    }

    private static let protectedContentAttribute = "AXProtectedContent" as CFString
    private static let editableAttribute = "AXEditable" as CFString
    private static let transactionPasteboardType = NSPasteboard.PasteboardType(
        "com.tidux.codex-watch-pet.private-paste-transaction"
    )
    private static let vKeyCode = CGKeyCode(9)
    private let pasteboardDeliveryPolicy: PasteboardDeliveryPolicy

    public init() {
        pasteboardDeliveryPolicy = .standard
    }

    init(pasteboardDeliveryPolicy: PasteboardDeliveryPolicy) {
        self.pasteboardDeliveryPolicy = pasteboardDeliveryPolicy
    }

    /// Captures the exact AX element focused at recording start.
    ///
    /// Secure and non-editable elements are rejected before selection metadata
    /// is read. Existing text content is never copied into application state.
    public func captureTarget() throws -> CapturedTextTarget {
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityPermissionDenied
        }
        guard !IsSecureEventInputEnabled() else {
            throw InsertionError.secureTextField
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = Self.elementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: systemWideElement
        ) else {
            throw InsertionError.noFocusedElement
        }

        var focusedPID: pid_t = 0
        let pidError = AXUIElementGetPid(focusedElement, &focusedPID)
        guard pidError == .success else {
            throw InsertionError.accessibilityWriteFailed(code: pidError.rawValue)
        }

        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw InsertionError.noFrontmostApplication
        }
        guard focusedPID == frontmostPID else {
            throw InsertionError.focusedApplicationMismatch(
                expected: focusedPID,
                actual: frontmostPID
            )
        }

        let role = Self.stringAttribute(kAXRoleAttribute as CFString, from: focusedElement) ?? ""
        let subrole = Self.stringAttribute(kAXSubroleAttribute as CFString, from: focusedElement)

        guard !Self.isSecureTextElement(focusedElement, role: role, subrole: subrole) else {
            throw InsertionError.secureTextField
        }
        guard Self.isEditableTextElement(focusedElement, role: role) else {
            throw InsertionError.notEditableText
        }

        let runningApplication = NSRunningApplication(processIdentifier: focusedPID)
        return CapturedTextTarget(
            element: focusedElement,
            processIdentifier: focusedPID,
            applicationBundleIdentifier: runningApplication?.bundleIdentifier,
            role: role,
            subrole: subrole,
            selectedTextRangeAtCapture: Self.selectedTextRange(from: focusedElement)
        )
    }

    public func captureFocusedTarget() throws -> CapturedTextTarget {
        try captureTarget()
    }

    /// Inserts into the target captured at recording start.
    ///
    /// `AXSelectedText` is attempted first because it preserves the selected
    /// range without touching global state. Applications that do not expose
    /// that setter fall back to a short, ownership-checked pasteboard
    /// transaction whose previous contents are restored after Cmd-V.
    @discardableResult
    public func insert(
        _ text: String,
        into target: CapturedTextTarget
    ) async throws -> InsertionMethod {
        guard !text.isEmpty else {
            return .accessibilitySelectedText
        }

        let currentElement = try validateAndReturnCurrentElement(for: target)
        if Self.setSelectedText(text, on: currentElement) {
            guard hasConfirmedPasteDelivery(for: target, text: text) else {
                throw InsertionError.pasteboardDeliveryUnconfirmed(resultCopied: false)
            }
            AppLog.insertion.debug(
                "Inserted using AXSelectedText for pid \(target.processIdentifier, privacy: .public)"
            )
            return .accessibilitySelectedText
        }

        try await paste(text, into: target)
        AppLog.insertion.debug(
            "Inserted using a pasteboard transaction for pid \(target.processIdentifier, privacy: .public)"
        )
        return .pasteboard
    }

    @discardableResult
    public func insert(
        _ text: String,
        target: CapturedTextTarget
    ) async throws -> InsertionMethod {
        try await insert(text, into: target)
    }

    private func validateAndReturnCurrentElement(
        for target: CapturedTextTarget
    ) throws -> AXUIElement {
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityPermissionDenied
        }
        guard !IsSecureEventInputEnabled() else {
            throw InsertionError.secureTextField
        }

        let currentFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard currentFrontmostPID == target.processIdentifier else {
            throw InsertionError.targetApplicationChanged(
                expected: target.processIdentifier,
                actual: currentFrontmostPID
            )
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        guard let currentElement = Self.elementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: systemWideElement
        ) else {
            throw InsertionError.noFocusedElement
        }

        var currentPID: pid_t = 0
        guard AXUIElementGetPid(currentElement, &currentPID) == .success,
              currentPID == target.processIdentifier,
              CFEqual(currentElement, target.element)
        else {
            throw InsertionError.focusChanged
        }

        let role = Self.stringAttribute(kAXRoleAttribute as CFString, from: currentElement) ?? ""
        let subrole = Self.stringAttribute(kAXSubroleAttribute as CFString, from: currentElement)
        guard !Self.isSecureTextElement(currentElement, role: role, subrole: subrole) else {
            throw InsertionError.secureTextField
        }
        guard Self.isEditableTextElement(currentElement, role: role) else {
            throw InsertionError.notEditableText
        }
        if let capturedRange = target.selectedTextRangeAtCapture {
            guard Self.selectedTextRange(from: currentElement) == capturedRange else {
                throw InsertionError.focusChanged
            }
        }

        return currentElement
    }

    private func paste(_ text: String, into target: CapturedTextTarget) async throws {
        // Build the key events before changing the pasteboard so an allocation
        // failure cannot leave the user's clipboard replaced.
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: Self.vKeyCode,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: Self.vKeyCode,
            keyDown: false
        ) else {
            throw InsertionError.keyboardEventUnavailable
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Revalidate immediately before posting. There is no suspension between
        // this check and the event post.
        _ = try validateAndReturnCurrentElement(for: target)

        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(pasteboard)
        let transactionToken = UUID().uuidString
        let deliveryReceipt = PasteboardReadReceipt()
        let stringProvider = ReceiptStringDataProvider(
            text: text,
            receipt: deliveryReceipt
        )
        defer {
            withExtendedLifetime(stringProvider) {}
        }
        let temporaryItem = NSPasteboardItem()
        guard temporaryItem.setString(
            transactionToken,
            forType: Self.transactionPasteboardType
        ) else {
            throw InsertionError.pasteboardWriteFailed
        }
        temporaryItem.setDataProvider(stringProvider, forTypes: [.string])

        pasteboard.clearContents()
        guard pasteboard.writeObjects([temporaryItem]) else {
            _ = Self.restore(snapshot, to: pasteboard)
            throw InsertionError.pasteboardWriteFailed
        }
        let transactionChangeCount = pasteboard.changeCount

        // Ignore any eager provider request caused by declaring the pasteboard
        // item itself. Only reads after the paste event is armed count as a
        // delivery receipt.
        deliveryReceipt.arm()
        keyDown.postToPid(target.processIdentifier)
        keyUp.postToPid(target.processIdentifier)

        let deliveryConfirmed = await deliveryReceipt.waitForStringRead(
            timeout: pasteboardDeliveryPolicy.confirmationTimeout
        )
        guard deliveryConfirmed else {
            throw Self.deliveryUnconfirmedError(
                restoring: snapshot,
                on: pasteboard,
                token: transactionToken,
                changeCount: transactionChangeCount
            )
        }

        do {
            try await Task.sleep(
                for: pasteboardDeliveryPolicy.postReadSettleDelay
            )
        } catch {
            throw Self.deliveryUnconfirmedError(
                restoring: snapshot,
                on: pasteboard,
                token: transactionToken,
                changeCount: transactionChangeCount
            )
        }

        guard hasConfirmedPasteDelivery(for: target, text: text) else {
            throw Self.deliveryUnconfirmedError(
                restoring: snapshot,
                on: pasteboard,
                token: transactionToken,
                changeCount: transactionChangeCount
            )
        }

        // Never overwrite a copy operation performed by the user or target app
        // during the settle window. If our marker still owns the board, restore
        // all original item types and their ordering.
        guard Self.ownsPasteboardTransaction(
            pasteboard,
            token: transactionToken,
            changeCount: transactionChangeCount
        ) else {
            AppLog.insertion.notice(
                "Pasteboard ownership changed before restoration; preserving the newer contents"
            )
            return
        }

        guard Self.restore(snapshot, to: pasteboard) else {
            throw InsertionError.pasteboardRestoreFailed
        }
    }

    /// A provider read is insufficient evidence because a clipboard manager can
    /// trigger it. Delivery is confirmed only when the original focused AX
    /// element also exposes an observably changed selection range.
    private func hasConfirmedPasteDelivery(
        for target: CapturedTextTarget, text: String
    ) -> Bool {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            return false
        }

        let currentFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard currentFrontmostPID == target.processIdentifier else {
            return false
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        guard let currentElement = Self.elementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: systemWideElement
        ) else {
            return false
        }

        var currentPID: pid_t = 0
        guard AXUIElementGetPid(currentElement, &currentPID) == .success,
              currentPID == target.processIdentifier,
              CFEqual(currentElement, target.element)
        else {
            return false
        }

        let role = Self.stringAttribute(kAXRoleAttribute as CFString, from: currentElement) ?? ""
        let subrole = Self.stringAttribute(kAXSubroleAttribute as CFString, from: currentElement)
        guard !Self.isSecureTextElement(currentElement, role: role, subrole: subrole) else {
            return false
        }

        return PasteboardDeliveryEvidence(
            targetStillFocused: true,
            capturedRange: target.selectedTextRangeAtCapture,
            deliveredRange: Self.selectedTextRange(from: currentElement),
            insertedUTF16Count: text.utf16.count
        ).confirmsTargetDelivery
    }

    private static func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    private static func isEditableTextElement(_ element: AXUIElement, role: String) -> Bool {
        if boolAttribute(kAXEnabledAttribute as CFString, from: element) == false {
            return false
        }

        let knownEditableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        if knownEditableRoles.contains(role) {
            return true
        }

        if boolAttribute(editableAttribute, from: element) == true {
            return true
        }

        return isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
            || isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element)
    }

    private static func isSecureTextElement(
        _ element: AXUIElement,
        role: String,
        subrole: String?
    ) -> Bool {
        if role == kAXSecureTextFieldSubrole as String
            || subrole == kAXSecureTextFieldSubrole as String
        {
            return true
        }
        return boolAttribute(protectedContentAttribute, from: element) == true
    }

    private static func isAttributeSettable(
        _ attribute: CFString,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    private static func elementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func selectedTextRange(
        from element: AXUIElement
    ) -> TextSelectionRangeSnapshot? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return TextSelectionRangeSnapshot(range)
    }

    private static func boolAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        if let value = value as? Bool {
            return value
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let copiedItems = (pasteboard.pasteboardItems ?? []).map { sourceItem in
            let copiedItem = NSPasteboardItem()
            for type in sourceItem.types {
                if let data = sourceItem.data(forType: type) {
                    copiedItem.setData(data, forType: type)
                }
            }
            return copiedItem
        }
        return PasteboardSnapshot(items: copiedItems)
    }

    private static func ownsPasteboardTransaction(
        _ pasteboard: NSPasteboard,
        token: String,
        changeCount: Int
    ) -> Bool {
        pasteboard.changeCount == changeCount
            && pasteboard.string(forType: transactionPasteboardType) == token
    }

    private static func deliveryUnconfirmedError(
        restoring snapshot: PasteboardSnapshot,
        on pasteboard: NSPasteboard,
        token: String,
        changeCount: Int
    ) -> InsertionError {
        let stillOwnsTransaction = ownsPasteboardTransaction(
            pasteboard,
            token: token,
            changeCount: changeCount
        )
        guard stillOwnsTransaction else {
            return .pasteboardDeliveryUnconfirmed(resultCopied: false)
        }

        guard restore(snapshot, to: pasteboard) else { return .pasteboardRestoreFailed }
        return .pasteboardDeliveryUnconfirmed(resultCopied: false)
    }

    @discardableResult
    private static func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard
    ) -> Bool {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else {
            return true
        }
        return pasteboard.writeObjects(snapshot.items)
    }
}
