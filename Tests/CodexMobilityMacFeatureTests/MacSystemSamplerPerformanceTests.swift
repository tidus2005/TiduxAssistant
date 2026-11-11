@testable import CodexMobilityMacFeature
import CodexMobilityCore
import Foundation
import XCTest

/// Opt-in microbenchmark for the real public-system sampler. It intentionally has
/// no machine-speed assertion: the printed result is evidence for choosing an
/// idle polling cadence, not a flaky CI pass/fail threshold.
final class MacSystemSamplerPerformanceTests: XCTestCase {
    func testRealSamplerLatencyWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["RUN_MOBILITY_PERF_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RUN_MOBILITY_PERF_BENCHMARK=1 to run the real sampler benchmark.")
        }

        let iterations = 30
        let sampler = MacSystemSampler(deviceID: UUID(), deviceName: "Performance Mac")
        let mode = MobilityModeStatus()

        var latestStatus = sampler.sample(mode: mode, now: Date())
        for _ in 0..<2 {
            latestStatus = sampler.sample(mode: mode, now: Date())
        }

        let clock = ContinuousClock()
        var milliseconds: [Double] = []
        milliseconds.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = clock.now
            latestStatus = sampler.sample(mode: mode, now: Date())
            let elapsed = start.duration(to: clock.now)
            let components = elapsed.components
            let seconds = Double(components.seconds)
            let attoseconds = Double(components.attoseconds)
            milliseconds.append((seconds * 1_000) + (attoseconds / 1e15))
        }

        let sorted = milliseconds.sorted()
        let mean = milliseconds.reduce(0, +) / Double(milliseconds.count)
        let median = sorted[(sorted.count - 1) / 2]
        let p95Index = min(Int(ceil(Double(sorted.count) * 0.95)) - 1, sorted.count - 1)
        let p95 = sorted[p95Index]
        let processCount = DarwinCodexCLIProcessInspector().runningProcesses().count

        print(
            String(
                format: "PERF MacSystemSampler iterations=%d visible_processes=%d mean_ms=%.3f median_ms=%.3f p95_ms=%.3f max_ms=%.3f",
                iterations,
                processCount,
                mean,
                median,
                p95,
                sorted.last ?? 0
            )
        )
        print(
            "LIVE MacSystemSampler connected=\(latestStatus.network.isConnected) "
                + "kind=\(latestStatus.network.kind.rawValue) "
                + "interface=\(latestStatus.network.interfaceName ?? "none")"
        )
    }
}
