import CodexMobilityCore
import Foundation
import Testing
@testable import CodexMobilityPhoneFeature

@Suite("Remote Mac telemetry freshness and sensor identity")
struct MobilityTelemetryTests {
    @Test func returningAfterHoursAwayGetsFreshConnectionGracePeriod() {
        let ready = Date(timeIntervalSince1970: 100_000)
        let stale = ready.addingTimeInterval(-7_200)
        #expect(!MobilityPhoneStateReducer.shouldRecoverConnectedLink(readyAt: ready, lastStatusAt: stale, now: ready))
        #expect(!MobilityPhoneStateReducer.shouldRecoverConnectedLink(readyAt: ready, lastStatusAt: nil, now: ready.addingTimeInterval(89)))
        #expect(MobilityPhoneStateReducer.shouldRecoverConnectedLink(readyAt: ready, lastStatusAt: nil, now: ready.addingTimeInterval(91)))
        #expect(!MobilityPhoneStateReducer.shouldRecoverConnectedLink(readyAt: nil, lastStatusAt: stale, now: ready))
        #expect(!MobilityPhoneStateReducer.shouldRecoverConnectedLink(readyAt: ready, lastStatusAt: ready.addingTimeInterval(80), now: ready.addingTimeInterval(91)))
    }

    private func status(at date: Date = Date(timeIntervalSince1970: 100)) -> MobilityDeviceStatus {
        MobilityDeviceStatus(deviceID: UUID(uuidString: "C0DE0000-7A11-4A3B-9A7E-5A7A11C0DE01")!,
            deviceName: "Test Mac", battery: MobilityBatteryStatus(levelPercent: 70),
            network: MobilityNetworkStatus(), thermalState: .nominal,
            temperatureCelsius: 42.5, temperatureSource: .chipMaximum,
            codex: MobilityCodexStatus(), observedAt: date)
    }

    @Test func batteryFallbackIsNotPresentedAsChipTemperature() {
        var sample = status()
        #expect(MobilityTelemetryPresentation.temperatureValue(sample) == "42.5°C")
        #expect(MobilityTelemetryPresentation.temperatureSource(sample) == "芯片最高温")
        sample.temperatureSource = .battery
        #expect(MobilityTelemetryPresentation.temperatureSource(sample) == "电池温度")
        sample.temperatureCelsius = .nan
        #expect(MobilityTelemetryPresentation.temperatureValue(sample) == "暂无读数")
        sample.temperatureCelsius = nil
        #expect(MobilityTelemetryPresentation.temperatureSource(sample) == "未取得传感器温度")
    }

    @Test func connectedButSilentStreamExpiresAndFreshSampleRecovers() {
        let start = Date(timeIntervalSince1970: 100)
        var state = MobilityPhoneState(connectionPhase: .ready(UUID()))
        MobilityPhoneStateReducer.receive(status: status(), at: start, state: &state)
        MobilityPhoneStateReducer.expireStatus(at: start.addingTimeInterval(89), state: &state)
        #expect(!state.isStale)
        MobilityPhoneStateReducer.expireStatus(at: start.addingTimeInterval(90), state: &state)
        #expect(state.isStale)
        #expect(state.lastKnownStatus?.battery.levelPercent == 70)
        MobilityPhoneStateReducer.receive(status: status(at: start.addingTimeInterval(91)),
            at: start.addingTimeInterval(92), state: &state)
        #expect(!state.isStale)
    }

    @Test func duplicateOrLateSampleDoesNotRenewLease() {
        let start = Date(timeIntervalSince1970: 100)
        var state = MobilityPhoneState()
        MobilityPhoneStateReducer.receive(status: status(), at: start, state: &state)
        MobilityPhoneStateReducer.receive(status: status(), at: start.addingTimeInterval(80), state: &state)
        MobilityPhoneStateReducer.receive(status: status(at: start.addingTimeInterval(-1)),
            at: start.addingTimeInterval(85), state: &state)
        #expect(state.lastStatusAt == start)
        MobilityPhoneStateReducer.expireStatus(at: start.addingTimeInterval(90), state: &state)
        #expect(state.isStale)
    }
}
