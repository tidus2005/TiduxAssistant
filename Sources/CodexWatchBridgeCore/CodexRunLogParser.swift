import CodexWatchCore
import Foundation

public struct CodexRunLogParseResult: Sendable {
    public var events: [BridgeEvent]
    public var status: BridgeRunStatus?
    public var threadId: String?
    public var consumedLineCount: Int

    public init(events: [BridgeEvent], status: BridgeRunStatus?, threadId: String? = nil, consumedLineCount: Int) {
        self.events = events
        self.status = status
        self.threadId = threadId
        self.consumedLineCount = consumedLineCount
    }
}

public struct CodexRunLogParser: Sendable {
    public init() {}

    public func parse(run: BridgeRunRecord, startingAtLine startLine: Int = 0) -> CodexRunLogParseResult {
        guard let text = try? String(contentsOfFile: run.logFile, encoding: .utf8) else {
            return CodexRunLogParseResult(events: [], status: nil, consumedLineCount: startLine)
        }
        return parse(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), run: run, startingAtLine: startLine)
    }

    public func parse(lines: [String], run: BridgeRunRecord, startingAtLine startLine: Int = 0) -> CodexRunLogParseResult {
        let clampedStart = min(max(0, startLine), lines.count)
        var events: [BridgeEvent] = []
        var finalStatus: BridgeRunStatus?
        var discoveredThreadId: String?
        var activeThreadId: String?
        var lastAssistantReply = lines.prefix(clampedStart).compactMap(Self.assistantReply).last

        for index in clampedStart..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let reply = Self.assistantReply(line) { lastAssistantReply = reply }
            guard let parsed = event(from: line, run: run, lineNumber: index + 1) else { continue }
            if let threadId = parsed.threadId {
                discoveredThreadId = threadId
                activeThreadId = threadId
            }
            var event = parsed.event
            if event.type == .turnCompleted, let lastAssistantReply {
                event.summary = String(lastAssistantReply.prefix(3000))
            }
            if parsed.threadId == nil, let activeThreadId, event.threadId == run.threadId {
                event.threadId = activeThreadId
            }
            events.append(event)

            switch event.type {
            case .turnCompleted:
                finalStatus = .completed
            case .turnFailed:
                finalStatus = .failed
            default:
                break
            }
        }

        return CodexRunLogParseResult(
            events: events,
            status: finalStatus,
            threadId: discoveredThreadId,
            consumedLineCount: lines.count
        )
    }

    private static func assistantReply(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "item.completed",
              let item = object["item"] as? [String: Any],
              item["type"] as? String == "agent_message",
              let text = item["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    private func event(from line: String, run: BridgeRunRecord, lineNumber: Int) -> ParsedRunEvent? {
        if let data = line.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return event(from: object, run: run, lineNumber: lineNumber, fallbackSummary: line)
        }

        return ParsedRunEvent(
            event: BridgeEvent(
                id: "run-\(run.id)-line-\(lineNumber)",
                sequence: 0,
                threadId: run.threadId,
                type: .turnProgress,
                title: run.title,
                summary: line.trimmed(maxLength: 300),
                urgency: .medium,
                petMood: .thinking,
                actions: runningActions(),
                createdAt: Date()
            ),
            threadId: nil
        )
    }

    private func event(from object: Any, run: BridgeRunRecord, lineNumber: Int, fallbackSummary: String) -> ParsedRunEvent? {
        let strings = flattenStrings(object)
        let classifierText = strings.joined(separator: " ").lowercased()
        let type = eventType(for: classifierText, object: object)
        guard type != nil || !strings.isEmpty else { return nil }

        let resolvedType = type ?? .turnProgress
        let resolvedThreadId = preferredThreadId(from: object)
        let summary = preferredSummary(from: object)
            ?? defaultSummary(for: resolvedType, object: object)
            ?? fallbackSummary

        return ParsedRunEvent(
            event: BridgeEvent(
                id: "run-\(run.id)-line-\(lineNumber)-\(resolvedType.rawValue)",
                sequence: 0,
                threadId: resolvedThreadId ?? run.threadId,
                type: resolvedType,
                title: run.title,
                summary: summary.trimmed(maxLength: 300),
                urgency: urgency(for: resolvedType),
                petMood: mood(for: resolvedType, classifierText: classifierText),
                actions: actions(for: resolvedType),
                createdAt: Date()
            ),
            threadId: resolvedThreadId
        )
    }

    private func eventType(for text: String, object: Any) -> BridgeEventType? {
        switch topLevelString(forKey: "type", in: object)?.lowercased() {
        case "thread.started", "session.started":
            return .threadStarted
        case "turn.started", "item.started", "item.completed", "agent_message", "assistant_message":
            return .turnProgress
        case "turn.completed":
            return .turnCompleted
        case "turn.failed", "error":
            return .turnFailed
        case .some(let value) where value.contains("approval") || value.contains("permission"):
            return .approvalRequested
        case .some(let value) where value.contains("input") || value.contains("blocked") || value.contains("question"):
            return .inputRequested
        default:
            break
        }

        if text.contains("turn.failed") || text.contains("failed") || text.contains("failure") || text.contains("error") {
            return .turnFailed
        }
        if text.contains("turn.completed") || text.contains("complete") || text.contains("done") || text.contains("success") {
            return .turnCompleted
        }
        if text.contains("approval") || text.contains("permission") {
            return .approvalRequested
        }
        if text.contains("input") || text.contains("blocked") || text.contains("question") {
            return .inputRequested
        }
        if text.contains("thread.started") || text.contains("session.started") {
            return .threadStarted
        }
        if text.contains("turn.started") {
            return .turnProgress
        }
        if text.contains("message") || text.contains("delta") || text.contains("assistant") || text.contains("tool") || text.contains("command") || text.contains("progress") {
            return .turnProgress
        }
        return nil
    }

    private func urgency(for type: BridgeEventType) -> Urgency {
        switch type {
        case .approvalRequested, .inputRequested, .turnFailed:
            .high
        case .threadStarted, .turnProgress, .turnCompleted:
            .medium
        case .bridgeOffline:
            .high
        }
    }

    private func mood(for type: BridgeEventType, classifierText: String) -> PetMood {
        switch type {
        case .approvalRequested:
            .needsApproval
        case .inputRequested:
            .needsInput
        case .turnCompleted:
            .done
        case .turnFailed:
            .failed
        case .bridgeOffline:
            .offline
        case .threadStarted, .turnProgress:
            classifierText.contains("tool") || classifierText.contains("command") ? .tooling : .thinking
        }
    }

    private func actions(for type: BridgeEventType) -> [BridgeAction] {
        switch type {
        case .approvalRequested:
            [
                BridgeAction(kind: .approve, title: "Approve", summary: "Approve the pending Codex request.", requiresHoldConfirmation: true),
                BridgeAction(kind: .decline, title: "Decline", summary: "Decline the pending Codex request.", requiresHoldConfirmation: true, destructive: true)
            ]
        case .inputRequested:
            [
                BridgeAction(kind: .reply, title: "Reply", summary: "Send the missing information back to Codex.", requiresHoldConfirmation: true)
            ]
        case .turnCompleted, .turnFailed, .bridgeOffline:
            [
                BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac.")
            ]
        case .threadStarted, .turnProgress:
            runningActions()
        }
    }

    private func runningActions() -> [BridgeAction] {
        [
            BridgeAction(kind: .interrupt, title: "Stop", summary: "Interrupt this bridge-owned Codex run.", requiresHoldConfirmation: true, destructive: true),
            BridgeAction(kind: .openOnMac, title: "Open", summary: "Open Codex on Mac.")
        ]
    }

    private func preferredSummary(from object: Any) -> String? {
        for key in ["summary", "message", "text", "content", "delta", "output", "error", "title"] {
            if let value = findString(forKey: key, in: object)?.nonBlank {
                return value
            }
        }
        return nil
    }

    private func preferredThreadId(from object: Any) -> String? {
        for key in ["thread_id", "threadId", "session_id", "sessionId", "conversation_id", "conversationId"] {
            if let value = findString(forKey: key, in: object)?.nonBlank {
                return value
            }
        }
        return nil
    }

    private func defaultSummary(for type: BridgeEventType, object: Any) -> String? {
        switch type {
        case .threadStarted:
            if let threadId = preferredThreadId(from: object) {
                return "Codex thread started: \(threadId)"
            }
            return "Codex thread started."
        case .turnProgress:
            return "Codex turn is running."
        case .turnCompleted:
            if let usage = usageSummary(from: object) {
                return "Codex run completed. \(usage)"
            }
            return "Codex run completed."
        case .turnFailed:
            return "Codex run failed."
        case .approvalRequested:
            return "Codex needs approval."
        case .inputRequested:
            return "Codex needs input."
        case .bridgeOffline:
            return "Codex bridge is offline."
        }
    }

    private func usageSummary(from object: Any) -> String? {
        guard let usage = findDictionary(forKey: "usage", in: object) else {
            return nil
        }
        let input = numericValue(for: "input_tokens", in: usage)
        let output = numericValue(for: "output_tokens", in: usage)
        var parts: [String] = []
        if let input {
            parts.append("input \(input)")
        }
        if let output {
            parts.append("output \(output)")
        }
        return parts.isEmpty ? nil : "Tokens: \(parts.joined(separator: ", "))."
    }

    private func findString(forKey key: String, in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for (candidateKey, value) in dictionary {
                if candidateKey.lowercased() == key.lowercased(), let string = value as? String {
                    return string
                }
                if let nested = findString(forKey: key, in: value) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = findString(forKey: key, in: value) {
                    return nested
                }
            }
        }
        return nil
    }

    private func topLevelString(forKey key: String, in object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        for (candidateKey, value) in dictionary {
            if candidateKey.lowercased() == key.lowercased(), let string = value as? String {
                return string
            }
        }
        return nil
    }

    private func findDictionary(forKey key: String, in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            for (candidateKey, value) in dictionary {
                if candidateKey.lowercased() == key.lowercased(), let nested = value as? [String: Any] {
                    return nested
                }
                if let nested = findDictionary(forKey: key, in: value) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = findDictionary(forKey: key, in: value) {
                    return nested
                }
            }
        }
        return nil
    }

    private func numericValue(for key: String, in dictionary: [String: Any]) -> Int? {
        guard let value = dictionary[key] else { return nil }
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func flattenStrings(_ object: Any) -> [String] {
        if let string = object as? String {
            return [string]
        }
        if let number = object as? NSNumber {
            return [number.stringValue]
        }
        if let array = object as? [Any] {
            return array.flatMap(flattenStrings)
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.flatMap { key, value in
                [key] + flattenStrings(value)
            }
        }
        return []
    }
}

private struct ParsedRunEvent {
    var event: BridgeEvent
    var threadId: String?
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func trimmed(maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength - 1)) + "..."
    }
}
