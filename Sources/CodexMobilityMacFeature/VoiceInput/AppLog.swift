import OSLog

enum AppLog {
    static let subsystem = "com.tidux.CodexWatchPet.mac.voice-input"
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let codex = Logger(subsystem: subsystem, category: "codex")
    static let insertion = Logger(subsystem: subsystem, category: "insertion")
}
