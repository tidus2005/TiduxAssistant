import Foundation
import Testing
@testable import CodexMobilityCore

@Suite("Syncthing peer application identity proof")
struct SyncthingPeerProofTests {
    private let senderID = UUID(uuidString: "8572A42C-4192-441C-A78E-2A30B52430F1")!
    private let receiverID = UUID(uuidString: "5319BAA7-C7B7-4AF4-977B-3274754D0315")!
    private let nonce = UUID(uuidString: "B6EFCFEE-A264-42F2-81A8-E076CD7D0D50")!

    @Test
    func authenticatedHelloRoundTripsAndVerifies() throws {
        let token = pairingToken(bytes: Array(0..<32))
        let hello = try SyncthingPeerAuthentication.makeHello(
            messageID: UUID(uuidString: "A5B52A41-BBC9-4FCD-9603-A0213BE58346")!,
            senderDeviceID: senderID,
            intendedPeerDeviceID: receiverID,
            nonce: nonce,
            deviceName: "Cafe\u{301} Phone",
            folderIDs: ["codex-sync"],
            pairingToken: token
        )

        #expect(hello.deviceName == "Café Phone")
        #expect(hello.authenticationProof?.count == SyncthingPeerAuthentication.proofHexCharacterCount)
        #expect(try SyncthingPeerAuthentication.verify(
            hello,
            expectedLocalDeviceID: receiverID,
            pairingToken: token
        ))
        try SyncthingPeerAuthentication.requireValid(
            hello,
            expectedLocalDeviceID: receiverID,
            pairingToken: token
        )

        let codec = SyncthingPeerJSONCodec()
        let message = SyncthingPeerMessage.hello(hello)
        #expect(try codec.decode(codec.encode(message)) == message)
        requireSendable(hello)
    }

    @Test
    func everyBoundFieldIsAuthenticated() throws {
        let token = pairingToken(bytes: Array(32..<64))
        let hello = try SyncthingPeerAuthentication.makeHello(
            senderDeviceID: senderID,
            intendedPeerDeviceID: receiverID,
            nonce: nonce,
            deviceName: "Travel Mac",
            pairingToken: token
        )

        var changedVersion = hello
        changedVersion.protocolVersion &+= 1
        var changedSender = hello
        changedSender.deviceID = UUID()
        var changedIntendedPeer = hello
        changedIntendedPeer.intendedPeerDeviceID = UUID()
        var changedNonce = hello
        changedNonce.nonce = UUID()
        var changedName = hello
        changedName.deviceName += "!"
        var changedProof = hello
        changedProof.authenticationProof = String(repeating: "0", count: 64)

        for tampered in [
            changedVersion,
            changedSender,
            changedIntendedPeer,
            changedNonce,
            changedName,
            changedProof
        ] {
            #expect(try !SyncthingPeerAuthentication.verify(
                tampered,
                expectedLocalDeviceID: receiverID,
                pairingToken: token
            ))
        }

        let anotherDeviceToken = pairingToken(bytes: Array(64..<96))
        #expect(try !SyncthingPeerAuthentication.verify(
            hello,
            expectedLocalDeviceID: receiverID,
            pairingToken: anotherDeviceToken
        ))
    }

    @Test
    func canonicalPayloadNormalizesNFCAndLengthPrefixesFields() throws {
        let decomposed = try SyncthingPeerAuthentication.canonicalAuthenticationString(
            protocolVersion: 2,
            senderDeviceID: senderID,
            intendedPeerDeviceID: receiverID,
            nonce: nonce,
            deviceName: "Cafe\u{301}:Mac\n"
        )
        let composed = try SyncthingPeerAuthentication.canonicalAuthenticationString(
            protocolVersion: 2,
            senderDeviceID: senderID,
            intendedPeerDeviceID: receiverID,
            nonce: nonce,
            deviceName: "Café:Mac\n"
        )

        #expect(decomposed == composed)
        #expect(decomposed.contains("10:Café:Mac\n"))

        let token = pairingToken(bytes: Array(0..<32))
        let decomposedProof = try SyncthingPeerAuthentication.makeProof(
            protocolVersion: 2,
            senderDeviceID: senderID,
            intendedPeerDeviceID: receiverID,
            nonce: nonce,
            deviceName: "Cafe\u{301}:Mac\n",
            pairingToken: token
        )
        let composedProof = try SyncthingPeerAuthentication.makeProof(
            protocolVersion: 2,
            senderDeviceID: senderID,
            intendedPeerDeviceID: receiverID,
            nonce: nonce,
            deviceName: "Café:Mac\n",
            pairingToken: token
        )
        #expect(decomposedProof == composedProof)
    }

    @Test
    func missingMalformedAndWrongDestinationProofsAreRejected() throws {
        let token = pairingToken(bytes: Array(0..<32))
        let unsigned = SyncthingPeerHello(
            deviceID: senderID,
            intendedPeerDeviceID: receiverID,
            nonce: nonce,
            deviceName: "iPhone"
        )

        #expect(try !SyncthingPeerAuthentication.verify(
            unsigned,
            expectedLocalDeviceID: receiverID,
            pairingToken: token
        ))
        #expect(throws: SyncthingPeerAuthenticationError.missingAuthenticationProof) {
            try SyncthingPeerAuthentication.requireValid(
                unsigned,
                expectedLocalDeviceID: receiverID,
                pairingToken: token
            )
        }

        let signed = try SyncthingPeerAuthentication.makeHello(
            senderDeviceID: senderID,
            intendedPeerDeviceID: receiverID,
            nonce: nonce,
            deviceName: "iPhone",
            pairingToken: token
        )
        let otherReceiver = UUID(uuidString: "3893E687-D3DB-44F3-9993-6CC04002CB9D")!
        #expect(throws: SyncthingPeerAuthenticationError.intendedPeerMismatch(
            expected: otherReceiver,
            actual: receiverID
        )) {
            try SyncthingPeerAuthentication.requireValid(
                signed,
                expectedLocalDeviceID: otherReceiver,
                pairingToken: token
            )
        }

        var malformedProof = signed
        malformedProof.authenticationProof = String(repeating: "z", count: 64)
        #expect(try !SyncthingPeerAuthentication.verify(
            malformedProof,
            expectedLocalDeviceID: receiverID,
            pairingToken: token
        ))
    }

    @Test
    func pairingTokenMustDecodeToExactlyThirtyTwoBytes() {
        let shortToken = pairingToken(bytes: Array(0..<31))
        #expect(throws: SyncthingPeerAuthenticationError.invalidPairingKeyLength(
            actual: 31,
            expected: 32
        )) {
            try SyncthingPeerAuthentication.makeProof(
                protocolVersion: 2,
                senderDeviceID: senderID,
                intendedPeerDeviceID: receiverID,
                nonce: nonce,
                deviceName: "iPhone",
                pairingToken: shortToken
            )
        }
        #expect(throws: SyncthingPeerAuthenticationError.malformedPairingToken) {
            try SyncthingPeerAuthentication.makeProof(
                protocolVersion: 2,
                senderDeviceID: senderID,
                intendedPeerDeviceID: receiverID,
                nonce: nonce,
                deviceName: "iPhone",
                pairingToken: "not-base64!"
            )
        }
    }

    private func pairingToken(bytes: [Int]) -> String {
        Data(bytes.map(UInt8.init)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
