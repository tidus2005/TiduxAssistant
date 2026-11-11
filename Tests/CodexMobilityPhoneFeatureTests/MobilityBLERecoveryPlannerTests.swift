import Testing
import Foundation
import CoreBluetooth
@testable import CodexMobilityPhoneFeature

@Suite("Mobility Bluetooth recovery planning")
struct MobilityBLERecoveryPlannerTests {
    @Test("Only Bluetooth encryption and lost bond errors recommend pairing repair")
    func pairingFailureClassification() {
        for code in [CBError.encryptionTimedOut, .peerRemovedPairingInformation] {
            #expect(MobilityBLERecoveryPlanner.isPairingFailure(NSError(domain: CBErrorDomain, code: code.rawValue)))
        }
        #expect(!MobilityBLERecoveryPlanner.isPairingFailure(NSError(domain: CBErrorDomain, code: CBError.connectionTimeout.rawValue)))
        #expect(!MobilityBLERecoveryPlanner.isPairingFailure(NSError(domain: NSURLErrorDomain, code: 15)))
    }

    @Test("User retry replaces a stuck connect but background events preserve it")
    func explicitConnectionRetryPreservesHealthyAndBackgroundLinks() {
        for state in [MobilityBLEPeripheralLinkState.connecting, .disconnected] {
            #expect(MobilityBLERecoveryPlanner.shouldRestartPendingConnection(
                userRequested: true, linkState: state, requestPending: true))
            #expect(!MobilityBLERecoveryPlanner.shouldRestartPendingConnection(
                userRequested: false, linkState: state, requestPending: true))
            #expect(MobilityBLERecoveryPlanner.shouldRestartPendingConnection(
                userRequested: true, linkState: state, requestPending: false) == (state == .connecting))
        }
        for state in [MobilityBLEPeripheralLinkState.connected, .disconnecting] {
            #expect(!MobilityBLERecoveryPlanner.shouldRestartPendingConnection(
                userRequested: true, linkState: state, requestPending: true))
        }
    }

    @Test("Explicit rediscovery is not blocked by a pending background connection")
    func explicitScanCanFindChangedPeripheralWhileReconnectWaits() {
        let id = UUID()
        for phase in [MobilityBLEConnectionPhase.connecting(id), .reconnecting(id)] {
            #expect(MobilityBLERecoveryPlanner.canScan(hasActivePeripheral: true,
                phase: phase, explicitRescan: true))
            #expect(!MobilityBLERecoveryPlanner.canScan(hasActivePeripheral: true,
                phase: phase, explicitRescan: false))
        }
        for phase in [MobilityBLEConnectionPhase.ready(id), .discovering(id)] {
            #expect(!MobilityBLERecoveryPlanner.canScan(hasActivePeripheral: true,
                phase: phase, explicitRescan: true))
        }
        #expect(MobilityBLERecoveryPlanner.canScan(hasActivePeripheral: false,
            phase: .idle, explicitRescan: false))
    }

    @Test("A missing restored peripheral falls back to scanning")
    func missingRestoredPeripheralScans() {
        #expect(
            MobilityBLERecoveryPlanner.action(
                hasReconnectTarget: true,
                recoveredPeripheralState: nil,
                connectionRequestPending: false
            ) == .scan
        )
    }

    @Test("A recovered disconnected peripheral reconnects once")
    func recoveredPeripheralReconnectsWithoutDuplicates() {
        #expect(
            MobilityBLERecoveryPlanner.action(
                hasReconnectTarget: true,
                recoveredPeripheralState: .disconnected,
                connectionRequestPending: false
            ) == .connect
        )
        #expect(
            MobilityBLERecoveryPlanner.action(
                hasReconnectTarget: true,
                recoveredPeripheralState: .disconnected,
                connectionRequestPending: true
            ) == .wait
        )
        #expect(
            MobilityBLERecoveryPlanner.action(
                hasReconnectTarget: true,
                recoveredPeripheralState: .disconnected,
                connectionRequestPending: false,
                systemReconnectPending: true
            ) == .wait
        )
    }

    @Test("Core Bluetooth owned transitions are not duplicated")
    func inFlightTransitionsWait() {
        #expect(
            MobilityBLERecoveryPlanner.action(
                hasReconnectTarget: true,
                recoveredPeripheralState: .connecting,
                connectionRequestPending: false
            ) == .wait
        )
        #expect(
            MobilityBLERecoveryPlanner.action(
                hasReconnectTarget: true,
                recoveredPeripheralState: .disconnecting,
                connectionRequestPending: false
            ) == .wait
        )
    }

    @Test("A recovered live link resumes service discovery")
    func connectedPeripheralDiscoversServices() {
        #expect(
            MobilityBLERecoveryPlanner.action(
                hasReconnectTarget: true,
                recoveredPeripheralState: .connected,
                connectionRequestPending: false
            ) == .discover
        )
    }

    @Test("A system-owned reconnect suppresses application reconnects")
    func systemReconnectOwnershipIsRespected() {
        #expect(
            MobilityBLERecoveryPlanner.disconnectAction(
                isActivePeripheral: true,
                hasReconnectTarget: true,
                isSystemReconnecting: true
            ) == .awaitSystemReconnect
        )
        #expect(
            MobilityBLERecoveryPlanner.disconnectAction(
                isActivePeripheral: true,
                hasReconnectTarget: true,
                isSystemReconnecting: false
            ) == .scheduleReconnect
        )
    }

    @Test("Stale or unrelated disconnect callbacks are ignored")
    func staleDisconnectIsIgnored() {
        #expect(
            MobilityBLERecoveryPlanner.disconnectAction(
                isActivePeripheral: false,
                hasReconnectTarget: true,
                isSystemReconnecting: true
            ) == .ignore
        )
        #expect(
            MobilityBLERecoveryPlanner.disconnectAction(
                isActivePeripheral: true,
                hasReconnectTarget: false,
                isSystemReconnecting: false
            ) == .ignore
        )
    }

    @Test("Only the current discovery stage can trip its watchdog")
    func setupWatchdogRejectsStaleTimers() {
        #expect(
            MobilityBLERecoveryPlanner.watchdogAction(
                watchedStage: .services,
                currentStage: .services,
                isDiscoveringActivePeripheral: true
            ) == .recover
        )
        #expect(
            MobilityBLERecoveryPlanner.watchdogAction(
                watchedStage: .services,
                currentStage: .characteristics,
                isDiscoveringActivePeripheral: true
            ) == .ignore
        )
        #expect(
            MobilityBLERecoveryPlanner.watchdogAction(
                watchedStage: .subscriptions,
                currentStage: .subscriptions,
                isDiscoveringActivePeripheral: false
            ) == .ignore
        )
        #expect(
            MobilityBLERecoveryPlanner.watchdogAction(
                watchedStage: .subscriptions,
                currentStage: nil,
                isDiscoveringActivePeripheral: true
            ) == .ignore
        )
    }
}
