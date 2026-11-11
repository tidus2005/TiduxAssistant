@testable import CodexMobilityMacFeature
import Foundation
import Testing

private actor WatcherEventFileCollector {
    private var files: [MacSyncDiscoveredFile] = []

    func append(_ file: MacSyncDiscoveredFile) {
        files.append(file)
    }

    func paths() -> [String] {
        files.map(\.relativePath)
    }

    func clear() {
        files.removeAll()
    }
}

private final class TestDirectoryEventSource: MacSyncDirectoryEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private let startsSuccessfully: Bool
    private var handler: (@Sendable ([MacSyncDirectoryEvent]) -> Void)?
    private var running = false
    private var stopCallsStorage = 0

    init(startsSuccessfully: Bool = true) {
        self.startsSuccessfully = startsSuccessfully
    }

    func start(handler: @escaping @Sendable ([MacSyncDirectoryEvent]) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard startsSuccessfully else { return false }
        self.handler = handler
        running = true
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        running = false
        handler = nil
        stopCallsStorage += 1
    }

    func emit(_ events: [MacSyncDirectoryEvent]) {
        lock.lock()
        let currentHandler = running ? handler : nil
        lock.unlock()
        currentHandler?(events)
    }

    var stopCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCallsStorage
    }
}

@Suite("Mac sync directory event scheduling")
struct MacSyncDirectoryWatcherEventTests {
    @Test("A recursive filesystem event is debounced before scanning a nested file")
    func eventDebouncesNestedScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = TestDirectoryEventSource()
        let collector = WatcherEventFileCollector()
        let watcher = MacSyncDirectoryWatcher(
            rootURL: root,
            fallbackScanInterval: 60,
            stableInterval: 0,
            eventDebounceInterval: 0.08,
            eventSource: source
        ) { file in
            await collector.append(file)
        }

        await watcher.start()
        try await Task.sleep(for: .milliseconds(30))
        let nested = root.appendingPathComponent("nested/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let eventURL = nested.appendingPathComponent("event.txt")
        try Data("event".utf8).write(to: eventURL)
        source.emit([
            MacSyncDirectoryEvent(
                path: eventURL.path,
                flags: [.itemCreated, .itemIsFile]
            )
        ])

        try await Task.sleep(for: .milliseconds(25))
        #expect(await collector.paths().isEmpty)
        #expect(try await waitUntil { await collector.paths() == ["nested/deeper/event.txt"] })
        #expect(await watcher.isUsingEventStream())

        await watcher.stop()
        #expect(source.stopCalls == 1)
    }

    @Test("Multiple nested paths coalesce without enumerating an unrelated directory")
    func coalescesTargetedPathsWithoutUnrelatedEnumeration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelatedDirectory = root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelatedDirectory,
            withIntermediateDirectories: true
        )
        let unrelatedFile = unrelatedDirectory.appendingPathComponent("baseline.txt")
        try Data("baseline".utf8).write(to: unrelatedFile)

        let source = TestDirectoryEventSource()
        let collector = WatcherEventFileCollector()
        let watcher = MacSyncDirectoryWatcher(
            rootURL: root,
            fallbackScanInterval: 60,
            stableInterval: 0,
            eventDebounceInterval: 0.08,
            eventSource: source
        ) { file in
            await collector.append(file)
        }

        await watcher.start()
        #expect(try await waitUntil {
            await collector.paths() == ["unrelated/baseline.txt"]
        })
        await collector.clear()

        // This mutation has no event. A full-tree event scan would incorrectly
        // discover it, while path-targeted scanning must leave it untouched.
        try Data("unrelated mutation with a different size".utf8).write(to: unrelatedFile)

        let firstDirectory = root.appendingPathComponent("one/deep", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("two/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstFile = firstDirectory.appendingPathComponent("first.txt")
        let secondFile = secondDirectory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstFile)
        try Data("second".utf8).write(to: secondFile)

        source.emit([
            MacSyncDirectoryEvent(path: firstFile.path, flags: [.itemCreated, .itemIsFile])
        ])
        source.emit([
            MacSyncDirectoryEvent(path: secondFile.path, flags: [.itemCreated, .itemIsFile])
        ])

        #expect(try await waitUntil {
            Set(await collector.paths()) == ["one/deep/first.txt", "two/deeper/second.txt"]
        })
        try await Task.sleep(for: .milliseconds(120))
        let finalPaths = await collector.paths()
        #expect(!finalPaths.contains("unrelated/baseline.txt"))
        await watcher.stop()
    }

    @Test("Dropped-event flags force a full-tree safety scan")
    func droppedEventsForceFullScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unreportedFile = root.appendingPathComponent("unreported.txt")
        try Data("initial".utf8).write(to: unreportedFile)
        let source = TestDirectoryEventSource()
        let collector = WatcherEventFileCollector()
        let watcher = MacSyncDirectoryWatcher(
            rootURL: root,
            fallbackScanInterval: 60,
            stableInterval: 0,
            eventDebounceInterval: 0.02,
            eventSource: source
        ) { file in
            await collector.append(file)
        }

        await watcher.start()
        #expect(try await waitUntil { await collector.paths() == ["unreported.txt"] })
        await collector.clear()
        try Data("changed after an event was dropped".utf8).write(to: unreportedFile)

        source.emit([
            MacSyncDirectoryEvent(
                path: root.appendingPathComponent("incomplete-event-path").path,
                flags: [.mustScanSubdirectories, .userDropped]
            )
        ])

        #expect(try await waitUntil { await collector.paths() == ["unreported.txt"] })
        await watcher.stop()
    }

    @Test("When FSEvents cannot start the short safety fallback still discovers changes")
    func failedStreamUsesSafetyFallback() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = TestDirectoryEventSource(startsSuccessfully: false)
        let collector = WatcherEventFileCollector()
        let watcher = MacSyncDirectoryWatcher(
            rootURL: root,
            fallbackScanInterval: 60,
            failedEventStreamScanInterval: 0.05,
            stableInterval: 0,
            eventDebounceInterval: 0.01,
            eventSource: source
        ) { file in
            await collector.append(file)
        }

        await watcher.start()
        try await Task.sleep(for: .milliseconds(20))
        try Data("fallback".utf8).write(to: root.appendingPathComponent("fallback.txt"))

        #expect(try await waitUntil { await collector.paths() == ["fallback.txt"] })
        #expect(await watcher.isUsingEventStream() == false)
        await watcher.stop()
    }

    @Test("Stopping closes the event source and later events do not scan")
    func stopClosesEventSource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = TestDirectoryEventSource()
        let collector = WatcherEventFileCollector()
        let watcher = MacSyncDirectoryWatcher(
            rootURL: root,
            fallbackScanInterval: 60,
            stableInterval: 0,
            eventDebounceInterval: 0.02,
            eventSource: source
        ) { file in
            await collector.append(file)
        }

        await watcher.start()
        try await Task.sleep(for: .milliseconds(20))
        try Data("stopped".utf8).write(to: root.appendingPathComponent("stopped.txt"))
        source.emit([
            MacSyncDirectoryEvent(
                path: root.appendingPathComponent("stopped.txt").path,
                flags: [.itemCreated, .itemIsFile]
            )
        ])
        await watcher.stop()
        try await Task.sleep(for: .milliseconds(80))

        #expect(await collector.paths().isEmpty)
        #expect(source.stopCalls == 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWatchPet-FSEvents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}
