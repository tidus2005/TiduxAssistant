@testable import CodexMobilityMacFeature
import Foundation
import XCTest

private actor PerformanceDiscoveredFileCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }

    func snapshot() -> Int {
        count
    }
}

/// Opt-in directory watcher benchmark. The fixture is deliberately fixed so
/// repeated runs can compare a first hash/index pass with steady enumeration.
final class MacSyncWatcherPerformanceTests: XCTestCase {
    func testWatcherHashAndSteadyScanWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["RUN_MOBILITY_PERF_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RUN_MOBILITY_PERF_BENCHMARK=1 to run the watcher benchmark.")
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CodexWatchPet-WatcherPerf-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fileCount = 1_000
        let payload = Data(repeating: 0x5A, count: 4_096)
        for index in 0..<fileCount {
            let bucket = root.appendingPathComponent(String(format: "%02d", index / 100), isDirectory: true)
            try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)
            try payload.write(to: bucket.appendingPathComponent(String(format: "file-%04d.bin", index)))
        }

        let counter = PerformanceDiscoveredFileCounter()
        let watcher = MacSyncDirectoryWatcher(
            rootURL: root,
            pollingInterval: 60,
            stableInterval: 0
        ) { _ in
            await counter.increment()
        }

        let clock = ContinuousClock()
        let firstStart = clock.now
        await watcher.scanNow()
        let firstMilliseconds = milliseconds(firstStart.duration(to: clock.now))
        let discoveredFileCount = await counter.snapshot()
        XCTAssertEqual(discoveredFileCount, fileCount)

        var steadyMilliseconds: [Double] = []
        for _ in 0..<10 {
            let start = clock.now
            await watcher.scanNow()
            steadyMilliseconds.append(milliseconds(start.duration(to: clock.now)))
        }

        let sorted = steadyMilliseconds.sorted()
        let mean = steadyMilliseconds.reduce(0, +) / Double(steadyMilliseconds.count)
        let median = sorted[(sorted.count - 1) / 2]
        let p95Index = min(Int(ceil(Double(sorted.count) * 0.95)) - 1, sorted.count - 1)

        print(
            String(
                format: "PERF MacSyncDirectoryWatcher files=%d bytes=%d first_hash_ms=%.3f steady_mean_ms=%.3f steady_median_ms=%.3f steady_p95_ms=%.3f steady_max_ms=%.3f",
                fileCount,
                fileCount * payload.count,
                firstMilliseconds,
                mean,
                median,
                sorted[p95Index],
                sorted.last ?? 0
            )
        )
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000) + (Double(components.attoseconds) / 1e15)
    }
}
