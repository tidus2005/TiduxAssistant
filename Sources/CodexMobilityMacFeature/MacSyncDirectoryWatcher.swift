import CoreServices
import Foundation

struct MacSyncDirectoryEventFlags: OptionSet, Sendable {
    let rawValue: UInt32

    static let mustScanSubdirectories = Self(
        rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs)
    )
    static let userDropped = Self(rawValue: UInt32(kFSEventStreamEventFlagUserDropped))
    static let kernelDropped = Self(rawValue: UInt32(kFSEventStreamEventFlagKernelDropped))
    static let eventIDsWrapped = Self(rawValue: UInt32(kFSEventStreamEventFlagEventIdsWrapped))
    static let rootChanged = Self(rawValue: UInt32(kFSEventStreamEventFlagRootChanged))
    static let itemCreated = Self(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
    static let itemRemoved = Self(rawValue: UInt32(kFSEventStreamEventFlagItemRemoved))
    static let itemRenamed = Self(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
    static let itemModified = Self(rawValue: UInt32(kFSEventStreamEventFlagItemModified))
    static let itemIsFile = Self(rawValue: UInt32(kFSEventStreamEventFlagItemIsFile))
    static let itemIsDirectory = Self(rawValue: UInt32(kFSEventStreamEventFlagItemIsDir))
    static let itemIsSymbolicLink = Self(rawValue: UInt32(kFSEventStreamEventFlagItemIsSymlink))

    var requiresFullScan: Bool {
        !intersection([
            .mustScanSubdirectories,
            .userDropped,
            .kernelDropped,
            .eventIDsWrapped,
            .rootChanged
        ]).isEmpty
    }
}

struct MacSyncDirectoryEvent: Sendable {
    var path: String?
    var flags: MacSyncDirectoryEventFlags

    init(path: String?, flags: MacSyncDirectoryEventFlags = []) {
        self.path = path
        self.flags = flags
    }
}

protocol MacSyncDirectoryEventSource: AnyObject, Sendable {
    @discardableResult
    func start(handler: @escaping @Sendable ([MacSyncDirectoryEvent]) -> Void) -> Bool
    func stop()
}

/// Recursive, event-driven directory watcher backed by the public FSEvents API.
///
/// FSEvents is recursive for every watched root, so adding or changing a file in
/// a nested directory wakes the watcher without repeatedly enumerating the whole
/// tree. The stream owns a private serial queue and forwards the public FSEvents
/// path/flag payload; all watcher state remains isolated by
/// ``MacSyncDirectoryWatcher``.
private final class MacSyncDirectoryFSEventSource: MacSyncDirectoryEventSource, @unchecked Sendable {
    fileprivate final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable ([MacSyncDirectoryEvent]) -> Void

        init(handler: @escaping @Sendable ([MacSyncDirectoryEvent]) -> Void) {
            self.handler = handler
        }
    }

    private let rootURL: URL
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "app.codexwatchpet.sync-directory.fsevents")
    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    init(rootURL: URL, latency: TimeInterval) {
        self.rootURL = rootURL
        self.latency = latency
    }

    @discardableResult
    func start(handler: @escaping @Sendable ([MacSyncDirectoryEvent]) -> Void) -> Bool {
        guard stream == nil else { return true }

        let box = CallbackBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [rootURL.path as CFString] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let newStream = FSEventStreamCreate(
            nil,
            macSyncDirectoryFSEventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return false
        }

        callbackBox = box
        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        guard let stream else {
            callbackBox = nil
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackBox = nil
    }

    deinit {
        stop()
    }
}

private let macSyncDirectoryFSEventCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, eventCount, eventPaths, eventFlags, _ in
    guard eventCount > 0, let clientCallBackInfo else { return }
    let box = Unmanaged<MacSyncDirectoryFSEventSource.CallbackBox>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()

    let pathPointers = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    var events: [MacSyncDirectoryEvent] = []
    events.reserveCapacity(eventCount)
    for index in 0..<eventCount {
        events.append(
            MacSyncDirectoryEvent(
                path: pathPointers[index].map(String.init(cString:)),
                flags: MacSyncDirectoryEventFlags(rawValue: UInt32(eventFlags[index]))
            )
        )
    }
    box.handler(events)
}

/// A recursive FSEvents watcher with a low-frequency full-tree safety scan.
/// A file must keep the same size and modification date for `stableInterval`
/// before it is offered to the phone, avoiding half-copied files.
public actor MacSyncDirectoryWatcher {
    public typealias Handler = @Sendable (MacSyncDiscoveredFile) async -> Void

    public static let defaultFallbackScanInterval: TimeInterval = 60 * 60
    public static let defaultEventDebounceInterval: TimeInterval = 0.75

    private struct Fingerprint: Equatable, Sendable {
        var byteCount: UInt64
        var modifiedAt: Date
    }

    private struct Candidate: Sendable {
        var fingerprint: Fingerprint
        var stableSince: Date
    }

    private struct ScanTarget: Hashable, Sendable {
        var path: String
        var isDirectory: Bool?
    }

    private enum ScanPlan: Sendable {
        case full
        case targets([ScanTarget])
    }

    private let rootURL: URL
    private let fallbackScanInterval: TimeInterval
    private let failedEventStreamScanInterval: TimeInterval
    private let eventDebounceInterval: TimeInterval
    private let stableInterval: TimeInterval
    private let handler: Handler
    private let eventSource: any MacSyncDirectoryEventSource
    private var candidates: [String: Candidate] = [:]
    private var emitted: [String: Fingerprint] = [:]
    private var fallbackTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var stabilityTask: Task<Void, Never>?
    private var pendingEventPlan: ScanPlan?
    private var pendingStabilityPlan: ScanPlan?
    private var eventStreamActive = false

    public init(
        rootURL: URL,
        pollingInterval: TimeInterval = MacSyncDirectoryWatcher.defaultFallbackScanInterval,
        stableInterval: TimeInterval = 1.2,
        eventDebounceInterval: TimeInterval = MacSyncDirectoryWatcher.defaultEventDebounceInterval,
        handler: @escaping Handler
    ) {
        let normalizedURL = rootURL.standardizedFileURL
        let debounceInterval = min(max(eventDebounceInterval, 0.5), 2)
        self.rootURL = normalizedURL
        self.fallbackScanInterval = max(pollingInterval, 1)
        self.failedEventStreamScanInterval = min(max(pollingInterval, 1), 30)
        self.eventDebounceInterval = debounceInterval
        self.stableInterval = max(stableInterval, 0)
        self.handler = handler
        self.eventSource = MacSyncDirectoryFSEventSource(
            rootURL: normalizedURL,
            latency: min(debounceInterval, 1)
        )
    }

    init(
        rootURL: URL,
        fallbackScanInterval: TimeInterval,
        failedEventStreamScanInterval: TimeInterval = 30,
        stableInterval: TimeInterval,
        eventDebounceInterval: TimeInterval,
        eventSource: any MacSyncDirectoryEventSource,
        handler: @escaping Handler
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fallbackScanInterval = max(fallbackScanInterval, 0.01)
        self.failedEventStreamScanInterval = max(failedEventStreamScanInterval, 0.01)
        self.eventDebounceInterval = max(eventDebounceInterval, 0)
        self.stableInterval = max(stableInterval, 0)
        self.eventSource = eventSource
        self.handler = handler
    }

    deinit {
        fallbackTask?.cancel()
        debounceTask?.cancel()
        stabilityTask?.cancel()
        eventSource.stop()
    }

    public func start() {
        guard fallbackTask == nil else { return }

        eventStreamActive = eventSource.start { [weak self] events in
            Task {
                await self?.recordFileSystemEvents(events)
            }
        }
        let interval = eventStreamActive
            ? fallbackScanInterval
            : failedEventStreamScanInterval

        fallbackTask = Task { [weak self] in
            guard let self else { return }
            await self.scanTriggeredByMonitor(plan: .full)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                await self.scanTriggeredByMonitor(plan: .full)
            }
        }
    }

    public func stop() {
        fallbackTask?.cancel()
        fallbackTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        stabilityTask?.cancel()
        stabilityTask = nil
        pendingEventPlan = nil
        pendingStabilityPlan = nil
        eventSource.stop()
        eventStreamActive = false
        candidates.removeAll()
        emitted.removeAll()
    }

    public func scanNow(now: Date = Date()) async {
        await scan(plan: .full, now: now)
    }

    func isUsingEventStream() -> Bool {
        eventStreamActive
    }

    private func recordFileSystemEvents(_ events: [MacSyncDirectoryEvent]) {
        guard fallbackTask != nil else { return }
        pendingEventPlan = merge(pendingEventPlan, eventPlan(for: events))
        debounceTask?.cancel()
        let interval = eventDebounceInterval
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.consumeDebouncedEvents()
        }
    }

    private func consumeDebouncedEvents() async {
        guard fallbackTask != nil, let plan = pendingEventPlan else { return }
        pendingEventPlan = nil
        debounceTask = nil
        await scanTriggeredByMonitor(plan: plan)
    }

    private func scanTriggeredByMonitor(plan: ScanPlan) async {
        await scan(plan: plan, now: Date())
        scheduleStabilityConfirmationIfNeeded(for: plan)
    }

    private func scheduleStabilityConfirmationIfNeeded(for plan: ScanPlan) {
        guard stableInterval > 0 else { return }
        pendingStabilityPlan = merge(pendingStabilityPlan, plan)
        stabilityTask?.cancel()
        let interval = stableInterval
        stabilityTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.confirmStability()
        }
    }

    private func confirmStability() async {
        guard fallbackTask != nil, let plan = pendingStabilityPlan else { return }
        pendingStabilityPlan = nil
        stabilityTask = nil
        await scan(plan: plan, now: Date())
    }

    private func eventPlan(for events: [MacSyncDirectoryEvent]) -> ScanPlan {
        guard !events.isEmpty else { return .full }

        var targets: [ScanTarget] = []
        let rootPath = rootURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for event in events {
            guard !event.flags.requiresFullScan, let rawPath = event.path else {
                return .full
            }

            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard path != rootPath, path.hasPrefix(rootPrefix) else {
                return .full
            }

            let directoryHint: Bool?
            if event.flags.contains(.itemIsDirectory) {
                directoryHint = true
            } else if event.flags.contains(.itemIsFile)
                        || event.flags.contains(.itemIsSymbolicLink) {
                directoryHint = false
            } else {
                directoryHint = nil
            }
            targets.append(ScanTarget(path: path, isDirectory: directoryHint))
        }

        return .targets(minimized(targets))
    }

    private func merge(_ existing: ScanPlan?, _ incoming: ScanPlan) -> ScanPlan {
        guard let existing else { return incoming }
        switch (existing, incoming) {
        case (.full, _), (_, .full):
            return .full
        case let (.targets(lhs), .targets(rhs)):
            return .targets(minimized(lhs + rhs))
        }
    }

    private func minimized(_ targets: [ScanTarget]) -> [ScanTarget] {
        var byPath: [String: ScanTarget] = [:]
        for target in targets {
            if let existing = byPath[target.path] {
                let hint: Bool?
                if existing.isDirectory == true || target.isDirectory == true {
                    hint = true
                } else if existing.isDirectory == false && target.isDirectory == false {
                    hint = false
                } else {
                    hint = nil
                }
                byPath[target.path] = ScanTarget(path: target.path, isDirectory: hint)
            } else {
                byPath[target.path] = target
            }
        }

        let ordered = byPath.values.sorted {
            let lhsDepth = $0.path.split(separator: "/").count
            let rhsDepth = $1.path.split(separator: "/").count
            return lhsDepth == rhsDepth ? $0.path < $1.path : lhsDepth < rhsDepth
        }
        var result: [ScanTarget] = []
        for target in ordered {
            let isCovered = result.contains { existing in
                existing.isDirectory == true && isDescendant(target.path, of: existing.path)
            }
            if !isCovered {
                result.append(target)
            }
        }
        return result
    }

    private func isDescendant(_ path: String, of ancestor: String) -> Bool {
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    private func scan(plan: ScanPlan, now: Date) async {
        switch plan {
        case .full:
            await scanFullDirectory(now: now)
        case let .targets(targets):
            await scanTargets(targets, now: now)
        }
    }

    private func scanFullDirectory(now: Date) async {
        guard let visiblePaths = await scanDirectoryTree(at: rootURL, now: now) else {
            return
        }
        candidates = candidates.filter { visiblePaths.contains($0.key) }
        emitted = emitted.filter { visiblePaths.contains($0.key) }
    }

    private func scanTargets(_ targets: [ScanTarget], now: Date) async {
        for target in targets {
            await scanTarget(target, now: now)
        }
    }

    private func scanTarget(_ target: ScanTarget, now: Date) async {
        let fileURL = URL(fileURLWithPath: target.path).standardizedFileURL
        guard let relativePath = lexicalRelativePath(for: fileURL) else {
            await scanFullDirectory(now: now)
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            pruneTracking(
                relativePath: relativePath,
                includeDescendants: target.isDirectory != false
            )
            return
        }

        let values = try? fileURL.resourceValues(
            forKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        )
        guard values?.isHidden != true, values?.isSymbolicLink != true,
              !MacSyncFileUtilities.shouldIgnore(relativePath: relativePath) else {
            pruneTracking(relativePath: relativePath, includeDescendants: true)
            return
        }

        if values?.isDirectory == true || isDirectory.boolValue {
            guard let visiblePaths = await scanDirectoryTree(at: fileURL, now: now) else {
                return
            }
            pruneTracking(
                relativePath: relativePath,
                includeDescendants: true,
                keeping: visiblePaths
            )
        } else if let visiblePath = await inspectRegularFile(at: fileURL, now: now) {
            pruneTracking(
                relativePath: relativePath,
                includeDescendants: false,
                keeping: [visiblePath]
            )
        } else {
            pruneTracking(relativePath: relativePath, includeDescendants: false)
        }
    }

    private func lexicalRelativePath(for fileURL: URL) -> String? {
        let rootPath = rootURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(rootPrefix) else { return nil }
        return String(path.dropFirst(rootPrefix.count))
    }

    private func pruneTracking(
        relativePath: String,
        includeDescendants: Bool,
        keeping visiblePaths: Set<String> = []
    ) {
        let prefix = relativePath.hasSuffix("/") ? relativePath : relativePath + "/"
        func isInScope(_ path: String) -> Bool {
            path == relativePath || (includeDescendants && path.hasPrefix(prefix))
        }
        candidates = candidates.filter {
            !isInScope($0.key) || visiblePaths.contains($0.key)
        }
        emitted = emitted.filter {
            !isInScope($0.key) || visiblePaths.contains($0.key)
        }
    }

    private func scanDirectoryTree(at directoryURL: URL, now: Date) async -> Set<String>? {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }

        var visiblePaths = Set<String>()
        while let fileURL = enumerator.nextObject() as? URL {
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: keys)
            } catch {
                continue
            }

            let relativePath: String
            do {
                relativePath = try MacSyncFileUtilities.relativePath(for: fileURL, under: rootURL)
            } catch {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values.isHidden == true || values.isSymbolicLink == true
                || MacSyncFileUtilities.shouldIgnore(relativePath: relativePath) {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if let visiblePath = await inspectRegularFile(
                at: fileURL,
                now: now,
                values: values
            ) {
                visiblePaths.insert(visiblePath)
            }
        }
        return visiblePaths
    }

    private func inspectRegularFile(
        at fileURL: URL,
        now: Date,
        values prefetchedValues: URLResourceValues? = nil
    ) async -> String? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let values = prefetchedValues ?? (try? fileURL.resourceValues(forKeys: keys)),
              values.isRegularFile == true,
              values.isHidden != true,
              values.isSymbolicLink != true,
              let relativePath = try? MacSyncFileUtilities.relativePath(
                  for: fileURL,
                  under: rootURL
              ),
              !MacSyncFileUtilities.shouldIgnore(relativePath: relativePath) else {
            return nil
        }

        let fingerprint = Fingerprint(
            byteCount: UInt64(max(values.fileSize ?? 0, 0)),
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
        if let candidate = candidates[relativePath], candidate.fingerprint == fingerprint {
            if now.timeIntervalSince(candidate.stableSince) >= stableInterval,
               emitted[relativePath] != fingerprint {
                await emitIfStillStable(
                    fileURL: fileURL,
                    relativePath: relativePath,
                    fingerprint: fingerprint
                )
            }
        } else {
            candidates[relativePath] = Candidate(fingerprint: fingerprint, stableSince: now)
            if stableInterval == 0 {
                await emitIfStillStable(
                    fileURL: fileURL,
                    relativePath: relativePath,
                    fingerprint: fingerprint
                )
            }
        }
        return relativePath
    }

    private func emitIfStillStable(
        fileURL: URL,
        relativePath: String,
        fingerprint: Fingerprint
    ) async {
        guard let digest = try? MacSyncFileUtilities.sha256(of: fileURL) else { return }

        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let afterHash = Fingerprint(
            byteCount: UInt64(max(values?.fileSize ?? -1, 0)),
            modifiedAt: values?.contentModificationDate ?? .distantPast
        )
        guard afterHash == fingerprint else {
            candidates[relativePath] = Candidate(fingerprint: afterHash, stableSince: Date())
            return
        }

        emitted[relativePath] = fingerprint
        await handler(
            MacSyncDiscoveredFile(
                relativePath: relativePath,
                fileURL: fileURL,
                byteCount: fingerprint.byteCount,
                modifiedAt: fingerprint.modifiedAt,
                sha256: digest
            )
        )
    }
}
