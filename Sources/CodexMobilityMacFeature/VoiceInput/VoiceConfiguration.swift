import Foundation

// Wire keys and enum values mirror typeless-parity/shared-schema 0.1.0.
// These are local Mac stores; Windows match kinds are preserved on round-trip.
enum VoiceStorage {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TiduxVoice", isDirectory: true)

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: value) { return date }
            throw ConfigurationError.invalid("日期格式无效")
        }
        return decoder
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ConfigurationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case let .invalid(message) = self { return message }
        return nil
    }
}

struct LexiconEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var term: String
    var aliases: [String]?
    var locale: String?
    var appScope: [String]?
    var protect: Bool?
    var source: Source?
    var weight: Double?
    enum Source: String, Codable, Sendable { case manual, `import`, learned }

    var isProtected: Bool { protect ?? true }
    func applies(to bundleID: String?) -> Bool {
        guard let appScope, !appScope.isEmpty else { return true }
        return bundleID.map { appScope.contains($0) } ?? false
    }
}

struct LexiconDocument: Codable, Equatable, Sendable {
    var schemaVersion = "0.1.0"
    var updatedAt = Date()
    var localeDefault: String? = "zh-Hans"
    var entries: [LexiconEntry] = []
}

struct LexiconStore {
    let url: URL
    init(directory: URL = VoiceStorage.directory) { url = directory.appendingPathComponent("dictionary.json") }
    func load() throws -> LexiconDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return LexiconDocument() }
        let document = try VoiceStorage.decoder().decode(LexiconDocument.self, from: Data(contentsOf: url))
        try validate(document)
        return document
    }
    func save(_ document: LexiconDocument) throws {
        try validate(document)
        try VoiceStorage.write(VoiceStorage.encoder().encode(document), to: url)
    }
    private func validate(_ document: LexiconDocument) throws {
        guard document.schemaVersion == "0.1.0",
              Set(document.entries.map(\.id)).count == document.entries.count,
              document.entries.allSatisfy({ !$0.id.isEmpty && !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && ($0.weight.map { $0.isFinite && (0...1).contains($0) } ?? true) }) else {
            throw ConfigurationError.invalid("字典格式无效或 schemaVersion 不受支持；原文件未修改。")
        }
    }

    static func protectedTerms(in entries: [LexiconEntry], bundleID: String?) -> [String] {
        entries.filter { $0.applies(to: bundleID) && $0.isProtected }.map(\.term)
    }

    /// Single pass over the original text: longest match wins, canonical words
    /// win ties, ambiguous aliases are left untouched, replacements never cascade.
    static func replacingAliases(in text: String, entries: [LexiconEntry], bundleID: String?) -> String {
        let active = entries.filter { $0.applies(to: bundleID) }
        var mappings: [String: Set<String>] = [:]
        for entry in active {
            for alias in entry.aliases ?? [] where !alias.isEmpty {
                mappings[alias, default: []].insert(entry.term)
            }
        }
        var matches: [(NSRange, String, Bool)] = []
        for entry in active {
            for range in literalRanges(entry.term, in: text) { matches.append((range, entry.term, true)) }
        }
        for (alias, terms) in mappings where terms.count == 1 {
            for range in literalRanges(alias, in: text) { matches.append((range, terms.first!, false)) }
        }
        matches.sort {
            if $0.2 != $1.2 { return $0.2 }
            if $0.0.length != $1.0.length { return $0.0.length > $1.0.length }
            return $0.0.location < $1.0.location
        }
        var accepted: [(NSRange, String, Bool)] = []
        for match in matches where !accepted.contains(where: { NSIntersectionRange($0.0, match.0).length > 0 }) {
            accepted.append(match)
        }
        let result = NSMutableString(string: text)
        for match in accepted.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: match.0, with: match.1)
        }
        return result as String
    }

    static func literalPattern(_ term: String) -> String {
        let asciiWord = #"[A-Za-z0-9_]"#
        let first = String(term.prefix(1)).range(of: asciiWord, options: .regularExpression) != nil
        let last = String(term.suffix(1)).range(of: asciiWord, options: .regularExpression) != nil
        return (first ? "(?<![A-Za-z0-9_])" : "") + NSRegularExpression.escapedPattern(for: term)
            + (last ? "(?![A-Za-z0-9_])" : "")
    }

    static func literalRanges(_ term: String, in text: String) -> [NSRange] {
        guard !term.isEmpty, let regex = try? NSRegularExpression(pattern: literalPattern(term)) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

}

enum AppTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case faithful, concise, formal, casual, bullet
    var id: String { rawValue }
    var title: String {
        switch self {
        case .faithful: "忠实原意"
        case .concise: "简洁"
        case .formal: "正式"
        case .casual: "自然口语"
        case .bullet: "条目"
        }
    }
}

struct AppToneProfile: Codable, Equatable, Identifiable, Sendable {
    struct Match: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case bundleId, exeName, processName }
        var kind: Kind = .bundleId
        var value: String
    }
    var id: String = UUID().uuidString
    var match: Match
    var tone: AppTone
    var polishEnabled: Bool?
    var notes: String?
}

struct AppTonesDocument: Codable, Equatable, Sendable {
    var schemaVersion = "0.1.0"
    var updatedAt = Date()
    var defaultTone: AppTone = .faithful
    var profiles: [AppToneProfile] = []
}

struct AppStylePolicy {
    let url: URL
    init(directory: URL = VoiceStorage.directory) { url = directory.appendingPathComponent("app-tones.json") }
    func load() throws -> AppTonesDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppTonesDocument() }
        let document = try VoiceStorage.decoder().decode(AppTonesDocument.self, from: Data(contentsOf: url))
        try validate(document)
        return document
    }
    func save(_ document: AppTonesDocument) throws {
        try validate(document)
        try VoiceStorage.write(VoiceStorage.encoder().encode(document), to: url)
    }
    private func validate(_ document: AppTonesDocument) throws {
        let macIDs = document.profiles.filter { $0.match.kind == .bundleId }.map(\.match.value)
        guard document.schemaVersion == "0.1.0", Set(document.profiles.map(\.id)).count == document.profiles.count,
              Set(macIDs).count == macIDs.count else {
            throw ConfigurationError.invalid("App 风格版本无效或匹配项重复；原文件未修改。")
        }
    }
    static func resolve(bundleID: String?, document: AppTonesDocument, globalPolishEnabled: Bool) -> (tone: AppTone, polishEnabled: Bool) {
        let profile = document.profiles.first { $0.match.kind == .bundleId && $0.match.value == bundleID }
        return (profile?.tone ?? document.defaultTone, globalPolishEnabled && (profile?.polishEnabled ?? true))
    }
}

struct HotkeySemantics: Codable {
    struct Binding: Codable {
        var id: String
        var action: String
        var keys: [String]
        var platform = "mac"
    }
    struct Defaults: Codable { var mode = "toggle"; var primary = ["Fn"] }
    var schemaVersion = "0.1.0"
    var mode = "toggle"
    var bindings = [Binding(id: "mac-fn-toggle", action: "startStop", keys: ["Fn"]),
                    Binding(id: "mac-panel-toggle", action: "startStop", keys: ["Command", "Shift", "D"])]
    var macDefault = Defaults()

    static func save(to directory: URL) throws {
        // Runtime declaration, not a user-configurable binding file. Cmd-Shift-D
        // is scoped to the visible dictation panel, Fn is global.
        try VoiceStorage.write(VoiceStorage.encoder().encode(Self()),
                               to: directory.appendingPathComponent("hotkey-semantics.json"))
    }
}
