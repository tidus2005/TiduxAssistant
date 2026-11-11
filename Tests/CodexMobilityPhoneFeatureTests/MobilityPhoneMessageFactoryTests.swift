import CodexMobilityCore
import Foundation
import Testing
@testable import CodexMobilityPhoneFeature

@Suite("Mobility phone command construction")
struct MobilityPhoneMessageFactoryTests {
    @Test("Pairing accepts exactly six ASCII digits")
    func pairingCodeValidation() throws {
        #expect(MobilityPhoneMessageFactory.isValidPairingCode("042731"))
        #expect(!MobilityPhoneMessageFactory.isValidPairingCode("42731"))
        #expect(!MobilityPhoneMessageFactory.isValidPairingCode("１２３４５６"))
        #expect(!MobilityPhoneMessageFactory.isValidPairingCode("12A456"))

        #expect(throws: MobilityPhoneMessageError.invalidPairingCode) {
            _ = try MobilityPhoneMessageFactory.pairingEnvelope(
                code: "12345",
                phoneDeviceID: UUID(),
                phoneDeviceName: "iPhone"
            )
        }
    }

    @Test("Authenticated commands carry the supplied random nonce and current timestamp")
    func authenticatedCommandCarriesAntiReplayFields() throws {
        let nonce = UUID(uuidString: "95E6FD82-35DE-46B7-B56A-276143D748D6")!
        let messageID = UUID(uuidString: "273DD363-D984-4C2D-A730-FA5123BC58D0")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let envelope = try MobilityPhoneMessageFactory.authenticatedEnvelope(
            action: .setMode(enabled: true, profile: .idleGuard),
            token: "paired-token",
            nonce: nonce,
            messageID: messageID,
            sentAt: now
        )

        #expect(envelope.messageID == messageID)
        #expect(envelope.sentAt == now)
        guard case .command(let command) = envelope.message else {
            Issue.record("Expected authenticated command")
            return
        }
        #expect(command.token == "paired-token")
        #expect(command.nonce == nonce)
        #expect(command.sentAt == now)
        #expect(command.action == .setMode(enabled: true, profile: .idleGuard))
    }
}
