import CryptoKit
import Foundation

enum MacSyncFileUtilities {
    static let stagingDirectoryName = ".codex-sync-staging"
    static let maximumRelativePathLength = 1_024
    static let maximumPathComponentLength = 255

    private static let ignoredSuffixes = [
        ".partial", ".part", ".tmp", ".temp", ".download", ".crdownload", ".swp"
    ]

    static func normalizedRelativePath(_ rawPath: String) throws -> String {
        let normalized = rawPath.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumRelativePathLength,
              !normalized.hasPrefix("/"),
              !normalized.contains("\\"),
              !normalized.contains("\0") else {
            throw MacFileSyncError.unsafeRelativePath(rawPath)
        }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw MacFileSyncError.unsafeRelativePath(rawPath)
        }

        for componentSlice in components {
            let component = String(componentSlice)
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.hasPrefix("."),
                  component.utf8.count <= maximumPathComponentLength else {
                throw MacFileSyncError.unsafeRelativePath(rawPath)
            }
        }

        let result = components.map(String.init).joined(separator: "/")
        guard !shouldIgnore(relativePath: result) else {
            throw MacFileSyncError.unsupportedTemporaryFile(rawPath)
        }
        return result
    }

    static func shouldIgnore(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return true }

        for component in components {
            let lowercased = component.lowercased()
            if component.hasPrefix(".") || component.hasPrefix("~") || component.hasSuffix("~") {
                return true
            }
            if lowercased == stagingDirectoryName || ignoredSuffixes.contains(where: lowercased.hasSuffix) {
                return true
            }
        }
        return false
    }

    static func relativePath(for fileURL: URL, under rootURL: URL) throws -> String {
        let root = rootURL.standardizedFileURL.path
        let file = fileURL.standardizedFileURL.path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard file.hasPrefix(rootPrefix) else {
            throw MacFileSyncError.unsafeRelativePath(file)
        }
        return try normalizedRelativePath(String(file.dropFirst(rootPrefix.count)))
    }

    static func destinationURL(for relativePath: String, under rootURL: URL) throws -> URL {
        let normalized = try normalizedRelativePath(relativePath)
        let candidate = normalized.split(separator: "/").reduce(rootURL.standardizedFileURL) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
        try ensureExistingParentsAreSafe(for: candidate, rootURL: rootURL)
        return candidate
    }

    static func ensureExistingParentsAreSafe(for destinationURL: URL, rootURL: URL) throws {
        let fileManager = FileManager.default
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"

        var current = rootURL.standardizedFileURL
        let relative = try relativePath(for: destinationURL, under: rootURL)
        let parentComponents = relative.split(separator: "/").dropLast()

        for component in parentComponents {
            current.appendPathComponent(String(component), isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true, isDirectory.boolValue else {
                    throw MacFileSyncError.unsafeRelativePath(relative)
                }
            } else {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }

        let resolvedParent = destinationURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(rootPrefix) else {
            throw MacFileSyncError.unsafeRelativePath(relative)
        }
    }

    static func conflictFreeURL(for desiredURL: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: desiredURL.path) else { return desiredURL }

        let parent = desiredURL.deletingLastPathComponent()
        let fileExtension = desiredURL.pathExtension
        let baseName = desiredURL.deletingPathExtension().lastPathComponent

        for suffix in 1...9_999 {
            let filename = fileExtension.isEmpty
                ? "\(baseName) (\(suffix))"
                : "\(baseName) (\(suffix)).\(fileExtension)"
            let candidate = parent.appendingPathComponent(filename, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return parent.appendingPathComponent("\(UUID().uuidString)-\(desiredURL.lastPathComponent)")
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw MacFileSyncError.sourceReadFailed(error.localizedDescription)
        }
        defer { try? handle.close() }

        var digest = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                digest.update(data: data)
            }
        } catch {
            throw MacFileSyncError.sourceReadFailed(error.localizedDescription)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}
