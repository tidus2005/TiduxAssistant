import Foundation

/// Replaces facts that a prose model must not rewrite with opaque placeholders.
///
/// `restore(_:from:)` is deliberately strict: every placeholder must survive
/// exactly once and the model may not invent additional placeholders. Callers
/// can therefore treat any thrown error as a signal to use the raw transcript.
struct EntityProtector: Sendable {
    enum EntityKind: String, Codable, CaseIterable, Sendable {
        case url
        case email
        case date
        case filePath
        case money
        case number
        case properNoun
    }

    struct Entity: Equatable, Sendable {
        let placeholder: String
        let value: String
        let kind: EntityKind
    }

    struct ProtectedText: Equatable, Sendable {
        let text: String
        let entities: [Entity]
        fileprivate let markerPrefix: String

        var isEmpty: Bool {
            entities.isEmpty
        }
    }

    enum ProtectionError: Error, Equatable, LocalizedError, Sendable {
        case missingPlaceholder(String)
        case duplicatePlaceholder(String)
        case unexpectedPlaceholder(String)
        case reorderedPlaceholders

        var errorDescription: String? {
            switch self {
            case let .missingPlaceholder(placeholder):
                return "Codex 删除了受保护实体占位符：\(placeholder)"
            case let .duplicatePlaceholder(placeholder):
                return "Codex 重复了受保护实体占位符：\(placeholder)"
            case let .unexpectedPlaceholder(placeholder):
                return "Codex 返回了未知实体占位符：\(placeholder)"
            case .reorderedPlaceholders:
                return "Codex 调换了受保护实体的相对顺序"
            }
        }
    }

    private struct Candidate {
        let range: NSRange
        let kind: EntityKind
    }

    private struct Pattern {
        let expression: String
        let kind: EntityKind
        let trimsURLPunctuation: Bool

        init(
            _ expression: String,
            kind: EntityKind,
            trimsURLPunctuation: Bool = false
        ) {
            self.expression = expression
            self.kind = kind
            self.trimsURLPunctuation = trimsURLPunctuation
        }
    }

    /// Pattern order is also precedence. More structured entities are claimed
    /// before generic numbers so a date or URL is represented by one token.
    private static let patterns: [Pattern] = [
        Pattern(
            #"(?i)(?<![A-Z0-9_])(?:https?://|www\.)[^\s<>"'，。！？；：、]+"#,
            kind: .url,
            trimsURLPunctuation: true
        ),
        Pattern(
            #"(?i)(?<![A-Z0-9._%+\-])[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}(?![A-Z0-9.\-])"#,
            kind: .email
        ),
        Pattern(
            #"(?<!\d)(?:19|20)\d{2}[-/.](?:0?[1-9]|1[0-2])[-/.](?:0?[1-9]|[12]\d|3[01])(?!\d)"#,
            kind: .date
        ),
        Pattern(
            #"(?<!\d)(?:19|20)\d{2}年(?:0?[1-9]|1[0-2])月(?:0?[1-9]|[12]\d|3[01])日?"#,
            kind: .date
        ),
        Pattern(
            #"(?<!\d)(?:0?[1-9]|1[0-2])月(?:0?[1-9]|[12]\d|3[01])日"#,
            kind: .date
        ),
        Pattern(
            #"(?<!\d)(?:19|20)\d{2}[-/.](?:0?[1-9]|1[0-2])(?![-/.\d])"#,
            kind: .date
        ),
        Pattern(
            #"(?<!\d)(?:19|20)\d{2}年(?:0?[1-9]|1[0-2])月"#,
            kind: .date
        ),
        Pattern(
            #"(?<![A-Za-z0-9_])[A-Za-z]:\\(?:[^\\\s<>:"|?*]+\\)*[^\\\s<>:"|?*]*"#,
            kind: .filePath
        ),
        Pattern(
            #"(?<![A-Za-z0-9_/\\])(?:Sources|Tests|docs|src|lib|bin)/(?:[^\s/<>"'，。！？；：、]+/)*[^\s/<>"'，。！？；：、]+"#,
            kind: .filePath
        ),
        Pattern(
            #"(?<![A-Za-z0-9_/\\])(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,16}(?![A-Za-z0-9_])"#,
            kind: .filePath
        ),
        Pattern(
            #"(?:~|\.{1,2})?/(?:[^\s/<>"'，。！？；：、]+/)*[^\s/<>"'，。！？；：、]+"#,
            kind: .filePath
        ),
        Pattern(
            #"(?i)(?:US\$|HK\$|A\$|C\$|RMB\s*|CNY\s*|USD\s*|EUR\s*|GBP\s*|[$€£¥￥])\s*[-+]?\d[\d,]*(?:\.\d+)?(?:\s*(?:万|亿|k|m|b))?"#,
            kind: .money
        ),
        Pattern(
            #"(?i)[-+]?\d[\d,]*(?:\.\d+)?\s*(?:元|块|人民币|美元|美金|港元|欧元|英镑|日元|円|USD|CNY|RMB|EUR|GBP)"#,
            kind: .money
        ),
        Pattern(
            #"[-+]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:%|％)?"#,
            kind: .number
        ),
        Pattern(
            #"[零〇一二两三四五六七八九十百千万亿壹贰叁肆伍陆柒捌玖拾佰仟]+(?:点[零〇一二三四五六七八九]+)?"#,
            kind: .number
        ),
    ]

    func protect(_ source: String, protectedTerms: [String] = []) -> ProtectedText {
        guard !source.isEmpty else {
            return ProtectedText(text: source, entities: [], markerPrefix: markerPrefix(for: source))
        }

        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var claimedRanges: [NSRange] = []
        var candidates: [Candidate] = []

        // Structured facts own their entire range; then dictionary names take
        // precedence over bare numbers (e.g. Project2026).
        let nounPatterns = protectedTerms.sorted(by: { $0.utf16.count > $1.utf16.count })
            .filter { !$0.isEmpty }
            .map { Pattern(LexiconStore.literalPattern($0), kind: .properNoun) }
        let patterns = Self.patterns.filter { $0.kind != .number }
            + nounPatterns + Self.patterns.filter { $0.kind == .number }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.expression) else {
                continue
            }

            for match in regex.matches(in: source, range: fullRange) {
                var range = match.range
                if pattern.trimsURLPunctuation {
                    range = trimURLPunctuation(from: range, in: source)
                }
                guard range.length > 0, !claimedRanges.contains(where: { overlaps($0, range) }) else {
                    continue
                }

                claimedRanges.append(range)
                candidates.append(Candidate(range: range, kind: pattern.kind))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length > rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }

        let prefix = markerPrefix(for: source)
        var entities: [Entity] = []
        entities.reserveCapacity(candidates.count)

        for (index, candidate) in candidates.enumerated() {
            guard let swiftRange = Range(candidate.range, in: source) else {
                continue
            }
            entities.append(
                Entity(
                    placeholder: "\(prefix)\(index)⟧",
                    value: String(source[swiftRange]),
                    kind: candidate.kind
                )
            )
        }

        var protected = source
        for (candidate, entity) in zip(candidates, entities).reversed() {
            guard let swiftRange = Range(candidate.range, in: protected) else {
                continue
            }
            protected.replaceSubrange(swiftRange, with: entity.placeholder)
        }

        return ProtectedText(text: protected, entities: entities, markerPrefix: prefix)
    }

    func restore(_ candidate: String, from protected: ProtectedText) throws -> String {
        for entity in protected.entities {
            switch occurrenceCount(of: entity.placeholder, in: candidate) {
            case 0:
                throw ProtectionError.missingPlaceholder(entity.placeholder)
            case 1:
                break
            default:
                throw ProtectionError.duplicatePlaceholder(entity.placeholder)
            }
        }

        let expected = Set(protected.entities.map(\.placeholder))
        for placeholder in placeholders(in: candidate)
            where !expected.contains(placeholder)
        {
            throw ProtectionError.unexpectedPlaceholder(placeholder)
        }

        let placeholderOffsets = protected.entities.compactMap { entity in
            candidate.range(of: entity.placeholder)?.lowerBound
        }
        guard placeholderOffsets == placeholderOffsets.sorted() else {
            throw ProtectionError.reorderedPlaceholders
        }

        return protected.entities.reduce(candidate) { partial, entity in
            partial.replacingOccurrences(of: entity.placeholder, with: entity.value)
        }
    }

    private func markerPrefix(for source: String) -> String {
        var sequence = 0
        while true {
            let prefix = sequence == 0 ? "⟦FT_ENTITY_" : "⟦FT\(sequence)_ENTITY_"
            if !source.contains(prefix) {
                return prefix
            }
            sequence += 1
        }
    }

    private func trimURLPunctuation(from range: NSRange, in source: String) -> NSRange {
        guard let swiftRange = Range(range, in: source) else {
            return range
        }

        var value = String(source[swiftRange])
        let punctuation: Set<Character> = [
            ".", ",", "!", "?", ";", ":",
            "，", "。", "！", "？", "；", "：", "、",
        ]
        while let last = value.last {
            if punctuation.contains(last) {
                value.removeLast()
                continue
            }
            let opener: Character?
            switch last {
            case ")":
                opener = "("
            case "]":
                opener = "["
            case "}":
                opener = "{"
            default:
                opener = nil
            }
            guard
                let opener,
                value.filter({ $0 == last }).count > value.filter({ $0 == opener }).count
            else {
                break
            }
            value.removeLast()
        }
        return NSRange(location: range.location, length: (value as NSString).length)
    }

    private func overlaps(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        lhs.location < NSMaxRange(rhs) && rhs.location < NSMaxRange(lhs)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else {
            return 0
        }
        return haystack.components(separatedBy: needle).count - 1
    }

    private func placeholders(in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"⟦FT(?:\d+)?_ENTITY_\d+⟧"#
        ) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: source) else {
                return nil
            }
            return String(source[swiftRange])
        }
    }
}
