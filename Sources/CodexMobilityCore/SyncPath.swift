import Foundation

public enum SyncPathError: Error, Equatable, Sendable {
    case emptyPath
    case absolutePath
    case parentTraversal
    case nullByte
    case controlCharacter
    case componentTooLong(String)
    case pathTooLong
    case noAvailableConflictName
}

public enum SyncRelativePath {
    /// Converts slash and backslash separators to a canonical `/` representation.
    /// Empty and `.` components are removed; absolute and parent-traversing paths are rejected.
    public static func normalize(_ input: String) throws -> String {
        guard !input.isEmpty else { throw SyncPathError.emptyPath }
        guard !input.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw SyncPathError.nullByte
        }
        guard !input.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw SyncPathError.controlCharacter
        }

        let separatorsNormalized = input.replacingOccurrences(of: "\\", with: "/")
        guard !separatorsNormalized.hasPrefix("/") else { throw SyncPathError.absolutePath }

        let rawComponents = separatorsNormalized.split(separator: "/", omittingEmptySubsequences: false)
        if let first = rawComponents.first, isWindowsDrivePath(String(first)) {
            throw SyncPathError.absolutePath
        }

        var components: [String] = []
        for rawComponent in rawComponents {
            let component = String(rawComponent).precomposedStringWithCanonicalMapping
            if component.isEmpty || component == "." { continue }
            guard component != ".." else { throw SyncPathError.parentTraversal }
            guard component.utf8.count <= SyncProtocolLimits.maximumPathComponentUTF8Bytes else {
                throw SyncPathError.componentTooLong(component)
            }
            components.append(component)
        }

        guard !components.isEmpty else { throw SyncPathError.emptyPath }
        let normalized = components.joined(separator: "/")
        guard normalized.utf8.count <= SyncProtocolLimits.maximumRelativePathUTF8Bytes else {
            throw SyncPathError.pathTooLong
        }
        return normalized
    }

    public static func fileName(in normalizedRelativePath: String) -> String {
        normalizedRelativePath.split(separator: "/").last.map(String.init) ?? normalizedRelativePath
    }

    public static func parent(in normalizedRelativePath: String) -> String? {
        let components = normalizedRelativePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    private static func isWindowsDrivePath(_ firstComponent: String) -> Bool {
        let scalars = Array(firstComponent.unicodeScalars)
        guard scalars.count >= 2, scalars[1] == ":" else { return false }
        let value = scalars[0].value
        return (65...90).contains(value) || (97...122).contains(value)
    }
}

public enum SyncConflictPlanner {
    /// Returns `name.ext`, or the first free `name (N).ext` starting at N=2.
    public static func availableRelativePath(
        desired: String,
        existing: some Sequence<String>,
        caseSensitive: Bool = false,
        maximumAttempts: Int = 10_000
    ) throws -> String {
        let desired = try SyncRelativePath.normalize(desired)
        let occupied: Set<String> = Set(try existing.map {
            let normalized = try SyncRelativePath.normalize($0)
            return comparisonKey(normalized, caseSensitive: caseSensitive)
        })
        if !occupied.contains(comparisonKey(desired, caseSensitive: caseSensitive)) {
            return desired
        }

        let parent = SyncRelativePath.parent(in: desired)
        let fileName = SyncRelativePath.fileName(in: desired)
        let parts = splitExtension(fileName)
        for number in 2...max(maximumAttempts, 1) + 1 {
            let suffix = " (\(number))"
            let extensionSuffix = parts.extension.map { ".\($0)" } ?? ""
            let availableStemBytes = SyncProtocolLimits.maximumPathComponentUTF8Bytes
                - suffix.utf8.count
                - extensionSuffix.utf8.count
            guard availableStemBytes > 0 else { throw SyncPathError.componentTooLong(fileName) }
            let stem = truncate(parts.stem, maximumUTF8Bytes: availableStemBytes)
            let candidateName = stem + suffix + extensionSuffix
            let candidate = parent.map { "\($0)/\(candidateName)" } ?? candidateName
            let normalized = try SyncRelativePath.normalize(candidate)
            if !occupied.contains(comparisonKey(normalized, caseSensitive: caseSensitive)) {
                return normalized
            }
        }
        throw SyncPathError.noAvailableConflictName
    }

    private static func comparisonKey(_ value: String, caseSensitive: Bool) -> String {
        caseSensitive ? value : value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func splitExtension(_ fileName: String) -> (stem: String, extension: String?) {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return (fileName, nil)
        }
        let afterDot = fileName.index(after: dot)
        guard afterDot < fileName.endIndex else { return (fileName, nil) }
        return (String(fileName[..<dot]), String(fileName[afterDot...]))
    }

    private static func truncate(_ value: String, maximumUTF8Bytes: Int) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, maximumUTF8Bytes))
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumUTF8Bytes else { break }
            result = candidate
        }
        return result.isEmpty ? "file" : result
    }
}
