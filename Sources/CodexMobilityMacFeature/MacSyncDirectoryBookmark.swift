import AppKit
import Foundation

@MainActor
public protocol MacSyncDirectoryPreferencePersisting: AnyObject {
    func loadBookmark() -> Data?
    func saveBookmark(_ bookmark: Data?)
    func loadIsEnabled() -> Bool
    func saveIsEnabled(_ enabled: Bool)
}

@MainActor
public final class UserDefaultsMacSyncDirectoryPreferences: MacSyncDirectoryPreferencePersisting {
    public static let defaultSuiteName = "com.tidux.codex-mobility.mac-file-sync"

    private enum Key {
        static let bookmark = "syncDirectoryBookmark.v1"
        static let isEnabled = "syncDirectoryEnabled.v1"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = UserDefaults(suiteName: defaultSuiteName)) {
        self.defaults = defaults ?? .standard
    }

    public func loadBookmark() -> Data? {
        defaults.data(forKey: Key.bookmark)
    }

    public func saveBookmark(_ bookmark: Data?) {
        if let bookmark {
            defaults.set(bookmark, forKey: Key.bookmark)
        } else {
            defaults.removeObject(forKey: Key.bookmark)
        }
    }

    public func loadIsEnabled() -> Bool {
        // A restored legacy bookmark is not consent to hash and queue an entire
        // directory on every App launch. Existing explicit choices are kept;
        // otherwise synchronization starts paused until the user enables it.
        guard defaults.object(forKey: Key.isEnabled) != nil else { return false }
        return defaults.bool(forKey: Key.isEnabled)
    }

    public func saveIsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.isEnabled)
    }
}

@MainActor
public protocol MacSyncDirectoryChoosing: AnyObject {
    func chooseDirectory() -> URL?
}

@MainActor
public final class MacSyncOpenPanelDirectoryChooser: MacSyncDirectoryChoosing {
    public init() {}

    public func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择双向同步目录"
        panel.message = "手机收到的文件会写入这里；这里新增或修改的文件会排队发送到手机。"
        panel.prompt = "选择目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum MacSyncDirectoryBookmark {
    static func make(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Unsandboxed development builds do not have a ScopedBookmarksAgent
            // grant. Persist a normal bookmark there; signed sandbox builds still
            // take the security-scoped path above.
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url.standardizedFileURL, stale)
        } catch {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url.standardizedFileURL, stale)
        }
    }
}
