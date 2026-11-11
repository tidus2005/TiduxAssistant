@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mobility Mac credential revocation")
struct MobilityCredentialRevocationTests {
    @Test("Vault lists token-free metadata and revokes only the selected device")
    func vaultMetadataAndSingleDeviceRevocation() throws {
        let vault = MobilityMacCredentialVault(
            service: "com.tidux.codex-mobility.tests.\(UUID().uuidString)"
        )
        let firstDeviceID = UUID()
        let secondDeviceID = UUID()
        let firstPairedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let secondPairedAt = firstPairedAt.addingTimeInterval(60)
        defer {
            try? vault.revokeCredential(for: firstDeviceID)
            try? vault.revokeCredential(for: secondDeviceID)
        }

        let firstCredential = try vault.issueCredential(
            deviceID: firstDeviceID,
            deviceName: "  Alice\u{0000}'s iPhone  ",
            pairedAt: firstPairedAt
        )
        let secondCredential = try vault.issueCredential(
            deviceID: secondDeviceID,
            deviceName: "Travel iPhone",
            pairedAt: secondPairedAt
        )

        let metadata = try vault.pairedDevices()
        #expect(metadata.map(\.deviceID) == [secondDeviceID, firstDeviceID])
        #expect(metadata[1].deviceName == "Alice's iPhone")
        #expect(metadata[1].pairedAt == firstPairedAt)
        #expect(Mirror(reflecting: metadata[1]).children.allSatisfy { $0.label != "token" })
        #expect(try vault.credential(matchingToken: firstCredential.token)?.deviceID == firstDeviceID)
        #expect(try vault.credential(matchingToken: secondCredential.token)?.deviceID == secondDeviceID)

        try vault.revokeCredential(for: firstDeviceID)

        #expect(try vault.credential(for: firstDeviceID) == nil)
        #expect(try vault.credential(matchingToken: firstCredential.token) == nil)
        #expect(try vault.credential(matchingToken: secondCredential.token)?.deviceID == secondDeviceID)
        #expect(try vault.pairedDevices().map(\.deviceID) == [secondDeviceID])
    }

    @Test("Revoking a device immediately excludes all of its centrals from delivery")
    func centralAuthorizationRevocation() {
        let revokedDeviceID = UUID()
        let retainedDeviceID = UUID()
        let firstRevokedCentralID = UUID()
        let secondRevokedCentralID = UUID()
        let retainedCentralID = UUID()
        var registry = MobilityCentralAuthorizationRegistry()

        registry.authorize(centralID: firstRevokedCentralID, deviceID: revokedDeviceID)
        registry.authorize(centralID: secondRevokedCentralID, deviceID: revokedDeviceID)
        registry.authorize(centralID: retainedCentralID, deviceID: retainedDeviceID)

        let revoked = registry.revoke(deviceID: revokedDeviceID)

        #expect(revoked == [firstRevokedCentralID, secondRevokedCentralID])
        #expect(!registry.isAuthorized(centralID: firstRevokedCentralID))
        #expect(!registry.isAuthorized(centralID: secondRevokedCentralID))
        #expect(registry.isAuthorized(centralID: retainedCentralID))
        #expect(
            registry.authorizedCentralIDs(
                among: [firstRevokedCentralID, retainedCentralID, secondRevokedCentralID]
            ) == [retainedCentralID]
        )
    }
}
