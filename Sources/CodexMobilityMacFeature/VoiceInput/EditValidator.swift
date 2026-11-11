import Foundation

struct EditValidator {
    enum Rejection: Error, Equatable { case entityConflict, correctionConflict, empty }

    static func hasCorrectionConflict(_ text: String) -> Bool {
        let entities = EntityProtector().protect(text).entities
        let numerical = entities.filter { [.number, .money, .date].contains($0.kind) }
        let cue = text.range(of: #"不对|不是|改成|改为|更正|说错|应该是|(?i:\b(?:sorry|actually|rather|correction)\b)"#,
                             options: .regularExpression) != nil
        return cue && Set(numerical.map(\.value)).count > 1
    }

    static func validate(source: String, candidate: String, protectedTerms: [String] = []) throws {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Rejection.empty }
        // P0 deliberately keeps the entire correction when intent is ambiguous.
        // Preserving both numbers while deleting "不是" would invert meaning.
        if hasCorrectionConflict(source), source != candidate { throw Rejection.correctionConflict }
        let protector = EntityProtector()
        let before = protector.protect(source, protectedTerms: protectedTerms).entities
        let after = protector.protect(candidate, protectedTerms: protectedTerms).entities
        guard before.map(\.value) == after.map(\.value), before.map(\.kind) == after.map(\.kind) else {
            throw Rejection.entityConflict
        }
    }
}

struct LocalTextCleaner {
    static func clean(_ text: String, protectedTerms: [String] = []) -> String {
        guard !EditValidator.hasCorrectionConflict(text) else { return text }
        let protector = EntityProtector()
        let protected = protector.protect(text, protectedTerms: protectedTerms)
        // Only isolated discourse markers, never demonstratives like "那个项目".
        let pattern = #"(^|[，,。！？!?；;\s])(?:嗯+|呃+|那个|就是说)(?:[，,、\s]+|$)"#
        var cleaned = protected.text
        for _ in 0..<3 {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let restored = try? protector.restore(cleaned, from: protected),
              (try? EditValidator.validate(source: text, candidate: restored, protectedTerms: protectedTerms)) != nil else { return text }
        return restored
    }
}
