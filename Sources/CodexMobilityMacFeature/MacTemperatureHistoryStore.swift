import Foundation

struct MacTemperatureHistoryStore: Sendable {
    static let historyWindowSeconds: TimeInterval = 12 * 60 * 60
    static let sampleIntervalSeconds: TimeInterval = 60
    static let maximumSampleCount = 12 * 60

    private struct Archive: Codable {
        var schemaVersion: Int
        var samples: [MacRemoteDashboardTemperaturePoint]
    }

    private let fileURL: URL
    private(set) var samples: [MacRemoteDashboardTemperaturePoint]

    init(fileURL: URL = Self.defaultFileURL(), now: Date = Date()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let archive = try? JSONDecoder().decode(Archive.self, from: data),
           archive.schemaVersion == 1 {
            samples = Self.normalized(archive.samples, now: now)
        } else {
            samples = []
        }
    }

    @discardableResult
    mutating func record(celsius: Double, at date: Date) -> Bool {
        guard celsius.isFinite, (-20 ... 150).contains(celsius) else { return false }
        let bucket = Self.minuteBucket(for: date)
        samples = Self.normalized(samples, now: date)
        guard !samples.contains(where: { $0.recordedAt == bucket }) else {
            return false
        }

        samples.append(
            MacRemoteDashboardTemperaturePoint(
                recordedAt: bucket,
                celsius: (celsius * 10).rounded() / 10
            )
        )
        samples = Self.normalized(samples, now: date)
        persist()
        return true
    }

    func snapshot(now: Date) -> [MacRemoteDashboardTemperaturePoint] {
        Self.normalized(samples, now: now)
    }

    static func minuteBucket(for date: Date) -> Date {
        let seconds = floor(date.timeIntervalSince1970 / sampleIntervalSeconds)
            * sampleIntervalSeconds
        return Date(timeIntervalSince1970: seconds)
    }

    private static func normalized(
        _ samples: [MacRemoteDashboardTemperaturePoint],
        now: Date
    ) -> [MacRemoteDashboardTemperaturePoint] {
        let cutoff = now.addingTimeInterval(-historyWindowSeconds)
        let valid = samples.filter {
            $0.recordedAt >= cutoff
                && $0.recordedAt <= now.addingTimeInterval(sampleIntervalSeconds)
                && $0.celsius.isFinite
                && (-20 ... 150).contains($0.celsius)
        }
        let deduplicated = Dictionary(grouping: valid, by: \.recordedAt)
            .compactMap { _, values in values.last }
            .sorted { $0.recordedAt < $1.recordedAt }
        return Array(deduplicated.suffix(maximumSampleCount))
    }

    private func persist() {
        let archive = Archive(schemaVersion: 1, samples: samples)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A missing history file must never take the live dashboard down.
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("CodexWatchPet", isDirectory: true)
            .appendingPathComponent("temperature-history-v1.json")
    }
}
