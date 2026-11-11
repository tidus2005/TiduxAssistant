import CodexMobilityCore
import Foundation
import Testing
@testable import CodexMobilityPhoneFeature

@Suite("AccessorySetupKit state and reconnect planning")
struct MobilityAccessorySetupStateTests {
    private let alphaID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let betaID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test("Activation keeps only authorized Bluetooth accessories")
    func activationFiltersAndNormalizes() {
        var state = MobilityAccessorySetupState()
        let effect = MobilityAccessorySetupReducer.reduce(
            .activated([
                snapshot(alphaID, "  Alpha Mac  ", .authorized),
                snapshot(betaID, "Pending Mac", .awaitingAuthorization),
                snapshot(nil, "No Bluetooth ID", .authorized)
            ]),
            state: &state
        )

        #expect(state.phase == .active)
        #expect(state.authorizedAccessories == [
            MobilitySystemAccessory(id: alphaID, displayName: "Alpha Mac")
        ])
        #expect(effect.accessoriesToRestore == state.authorizedAccessories)
        #expect(effect.preferredConnectionIdentifier == alphaID)
    }

    @Test("Activation de-duplicates identifiers and uses a safe fallback name")
    func activationDeduplicatesAndNames() {
        var state = MobilityAccessorySetupState()
        _ = MobilityAccessorySetupReducer.reduce(
            .activated([
                snapshot(alphaID, "Old Name", .authorized),
                snapshot(alphaID, "   ", .authorized)
            ]),
            state: &state
        )

        #expect(state.authorizedAccessories == [
            MobilitySystemAccessory(id: alphaID, displayName: "Codex 随行 Mac")
        ])
    }

    @Test("An added system accessory is preferred for immediate connection")
    func addedAccessoryBecomesPreferred() {
        var state = MobilityAccessorySetupState(phase: .active)
        let effect = MobilityAccessorySetupReducer.reduce(
            .accessoryAdded(snapshot(betaID, "Travel Mac", .authorized)),
            state: &state
        )

        #expect(state.authorizedAccessories.map(\.id) == [betaID])
        #expect(effect.preferredConnectionIdentifier == betaID)
        #expect(effect.removedIdentifiers.isEmpty)
    }

    @Test("A changed accessory updates its system display name")
    func changedAccessoryUpdatesName() {
        var state = MobilityAccessorySetupState(
            phase: .active,
            authorizedAccessories: [MobilitySystemAccessory(id: alphaID, displayName: "Old")]
        )
        let effect = MobilityAccessorySetupReducer.reduce(
            .accessoryChanged(snapshot(alphaID, "Renamed Mac", .authorized)),
            state: &state
        )

        #expect(state.authorizedAccessories.first?.displayName == "Renamed Mac")
        #expect(effect.preferredConnectionIdentifier == alphaID)
    }

    @Test("Revoked authorization removes the reconnect target")
    func revokedAccessoryIsRemoved() {
        var state = MobilityAccessorySetupState(
            phase: .active,
            authorizedAccessories: [MobilitySystemAccessory(id: alphaID, displayName: "Mac")]
        )
        let effect = MobilityAccessorySetupReducer.reduce(
            .accessoryChanged(snapshot(alphaID, "Mac", .unauthorized)),
            state: &state
        )

        #expect(state.authorizedAccessories.isEmpty)
        #expect(effect.accessoriesToRestore.isEmpty)
        #expect(effect.preferredConnectionIdentifier == nil)
        #expect(effect.removedIdentifiers == [alphaID])
    }

    @Test("Accessory removal is idempotent")
    func accessoryRemovalIsIdempotent() {
        var state = MobilityAccessorySetupState(
            phase: .active,
            authorizedAccessories: [MobilitySystemAccessory(id: alphaID, displayName: "Mac")]
        )
        let first = MobilityAccessorySetupReducer.reduce(.accessoryRemoved(alphaID), state: &state)
        let second = MobilityAccessorySetupReducer.reduce(.accessoryRemoved(alphaID), state: &state)

        #expect(first.removedIdentifiers == [alphaID])
        #expect(second == .none)
        #expect(state.authorizedAccessories.isEmpty)
    }

    @Test("Picker lifecycle exposes one busy state")
    func pickerLifecycle() {
        var state = MobilityAccessorySetupState(phase: .active)
        MobilityAccessorySetupReducer.reduce(.pickerRequested, state: &state)
        #expect(state.isPickerBusy)
        #expect(state.isPickerRequestPending)

        MobilityAccessorySetupReducer.reduce(.pickerPresented, state: &state)
        #expect(state.isPickerBusy)
        #expect(state.isPickerPresented)
        #expect(!state.isPickerRequestPending)

        MobilityAccessorySetupReducer.reduce(.pickerDismissed, state: &state)
        #expect(!state.isPickerBusy)
    }

    @Test("Invalidation cancels pending picker work")
    func invalidationCancelsPicker() {
        var state = MobilityAccessorySetupState(
            phase: .activating,
            isPickerRequestPending: true
        )
        MobilityAccessorySetupReducer.reduce(
            .invalidated("Session ended"),
            state: &state
        )

        #expect(state.phase == .invalidated)
        #expect(!state.isPickerBusy)
        #expect(state.lastErrorMessage == "Session ended")
    }

    @Test("A failed picker preserves authorization and can clear its warning")
    func failureDoesNotDiscardAuthorization() {
        let accessory = MobilitySystemAccessory(id: alphaID, displayName: "Mac")
        var state = MobilityAccessorySetupState(
            phase: .active,
            authorizedAccessories: [accessory]
        )
        MobilityAccessorySetupReducer.reduce(.failed("Picker failed"), state: &state)
        #expect(state.authorizedAccessories == [accessory])
        #expect(state.lastErrorMessage == "Picker failed")

        MobilityAccessorySetupReducer.reduce(.clearError, state: &state)
        #expect(state.lastErrorMessage == nil)
    }

    @Test("Picker configuration matches the Mac advertisement contract")
    func pickerConfigurationMatchesMobilityContract() {
        #expect(MobilityAccessorySetupConfiguration.serviceUUID == MobilityBLEUUIDs.service)
        #expect(MobilityAccessorySetupConfiguration.advertisedName == "Codex 随行")
    }

    private func snapshot(
        _ identifier: UUID?,
        _ name: String,
        _ authorization: MobilityAccessoryAuthorization
    ) -> MobilityAccessorySnapshot {
        MobilityAccessorySnapshot(
            bluetoothIdentifier: identifier,
            displayName: name,
            authorization: authorization
        )
    }
}
