@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mac temperature history")
struct MacTemperatureHistoryStoreTests {
    @Test("History keeps one persisted sample per minute")
    func minuteBucketsAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temperature-history-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var store = MacTemperatureHistoryStore(fileURL: fileURL, now: start)
        let recordedFirstMinute = store.record(celsius: 70.04, at: start)
        let recordedDuplicateMinute = store.record(
            celsius: 99,
            at: start.addingTimeInterval(30)
        )
        let recordedSecondMinute = store.record(
            celsius: 71.26,
            at: start.addingTimeInterval(61)
        )
        #expect(recordedFirstMinute)
        #expect(!recordedDuplicateMinute)
        #expect(recordedSecondMinute)

        let reloaded = MacTemperatureHistoryStore(
            fileURL: fileURL,
            now: start.addingTimeInterval(61)
        )
        let samples = reloaded.snapshot(now: start.addingTimeInterval(61))
        #expect(samples.count == 2)
        #expect(samples.map(\.celsius) == [70.0, 71.3])
        #expect(samples[0].recordedAt == MacTemperatureHistoryStore.minuteBucket(for: start))
    }

    @Test("History removes samples outside the twelve hour window")
    func twelveHourRetention() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temperature-retention-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_700_100_000)
        var store = MacTemperatureHistoryStore(
            fileURL: fileURL,
            now: now.addingTimeInterval(-13 * 60 * 60)
        )
        store.record(celsius: 60, at: now.addingTimeInterval(-13 * 60 * 60))
        store.record(celsius: 65, at: now.addingTimeInterval(-11 * 60 * 60))
        store.record(celsius: 70, at: now)

        let samples = store.snapshot(now: now)
        #expect(samples.map(\.celsius) == [65, 70])
    }
}
