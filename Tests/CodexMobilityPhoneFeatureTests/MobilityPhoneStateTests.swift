import CodexMobilityCore
import Foundation
import Testing
@testable import CodexMobilityPhoneFeature

@Suite("Mobility phone authoritative state")
struct MobilityPhoneStateTests {
    @Test("Sending a mode command does not optimistically flip the switch")
    func modeCommandWaitsForMacAcknowledgement() {
        let original = makeStatus(modePhase: .off)
        var state = MobilityPhoneState(lastKnownStatus: original)
        let id = UUID()

        MobilityPhoneStateReducer.register(
            commandID: id,
            effect: .setMode(enabled: true, profile: .idleGuard),
            sentAt: Date(timeIntervalSince1970: 100),
            state: &state
        )

        #expect(state.lastKnownStatus == original)
        #expect(state.hasPendingModeCommand)

        MobilityPhoneStateReducer.acknowledge(
            commandID: id,
            accepted: true,
            message: nil,
            state: &state
        )

        #expect(state.lastKnownStatus?.mode.phase == .active)
        #expect(!state.hasPendingModeCommand)
    }

    @Test("A rejected command keeps the Mac's last-known mode")
    func rejectionDoesNotMutateStatus() {
        let original = makeStatus(modePhase: .off)
        var state = MobilityPhoneState(lastKnownStatus: original)
        let id = UUID()
        MobilityPhoneStateReducer.register(
            commandID: id,
            effect: .setMode(enabled: true, profile: .idleGuard),
            sentAt: .now,
            state: &state
        )

        MobilityPhoneStateReducer.acknowledge(
            commandID: id,
            accepted: false,
            message: "电量低于安全线",
            state: &state
        )

        #expect(state.lastKnownStatus == original)
        #expect(state.lastErrorMessage == "电量低于安全线")
    }

    @Test("A fresh status is authoritative and clears matching pending work")
    func freshStatusWinsOverPendingCommand() {
        var state = MobilityPhoneState(lastKnownStatus: makeStatus(modePhase: .off))
        let id = UUID()
        MobilityPhoneStateReducer.register(
            commandID: id,
            effect: .setMode(enabled: true, profile: .idleGuard),
            sentAt: .now,
            state: &state
        )
        let receivedAt = Date(timeIntervalSince1970: 200)

        MobilityPhoneStateReducer.receive(
            status: makeStatus(modePhase: .active),
            at: receivedAt,
            state: &state
        )

        #expect(state.lastKnownStatus?.mode.phase == .active)
        #expect(state.lastStatusAt == receivedAt)
        #expect(state.staleSince == nil)
        #expect(state.pendingCommands.isEmpty)
    }

    @Test("Disconnect keeps last-known values and records when they became stale")
    func disconnectPreservesLastKnownStatus() {
        let original = makeStatus(modePhase: .active)
        let disconnectedAt = Date(timeIntervalSince1970: 300)
        var state = MobilityPhoneState(lastKnownStatus: original)

        MobilityPhoneStateReducer.disconnect(at: disconnectedAt, state: &state)

        #expect(state.lastKnownStatus == original)
        #expect(state.staleSince == disconnectedAt)
        #expect(state.isStale)
    }

    private func makeStatus(modePhase: MobilityModePhase) -> MobilityDeviceStatus {
        MobilityDeviceStatus(
            deviceID: UUID(uuidString: "DCA19AE2-BA06-4EB5-B2CE-0C3C611A1D91")!,
            deviceName: "MacBook Pro",
            battery: MobilityBatteryStatus(levelPercent: 76),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true, isExpensive: true, interfaceName: "en0"),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true, activeTaskCount: 1),
            mode: MobilityModeStatus(phase: modePhase, policy: .recommended),
            helperReady: true
        )
    }
}
