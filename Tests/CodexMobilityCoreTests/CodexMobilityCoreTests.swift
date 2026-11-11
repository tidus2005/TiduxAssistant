import CodexMobilityCore
import Foundation
import Testing

@Suite("Codex mobility core")
struct CodexMobilityCoreTests {
    @Test
    func policyNormalizationUsesSafeBoundsAndRecommendedFallbacks() {
        let invalid = MobilityPolicy(
            lowBatteryThresholdPercent: 5,
            maximumDurationSeconds: .infinity,
            networkDisconnectGraceSeconds: -30,
            requiresCodexRunning: false
        ).normalized()

        #expect(invalid.lowBatteryThresholdPercent == MobilityPolicy.minimumAllowedBatteryPercent)
        #expect(invalid.maximumDurationSeconds == MobilityPolicy.recommended.maximumDurationSeconds)
        #expect(invalid.networkDisconnectGraceSeconds == 0)
        #expect(invalid.requiresCodexRunning == false)

        let excessive = MobilityPolicy(
            lowBatteryThresholdPercent: 99,
            maximumDurationSeconds: 48 * 60 * 60,
            networkDisconnectGraceSeconds: 2 * 60 * 60
        ).normalized()

        #expect(excessive.lowBatteryThresholdPercent == MobilityPolicy.maximumAllowedBatteryPercent)
        #expect(excessive.maximumDurationSeconds == MobilityPolicy.maximumAllowedDurationSeconds)
        #expect(excessive.networkDisconnectGraceSeconds == MobilityPolicy.maximumAllowedNetworkGraceSeconds)
    }

    @Test
    func safetyBlocksLabsWithoutHelperAndSeriousThermalState() {
        var status = makeSafeStatus()
        status.helperReady = false

        let labs = MobilitySafetyEvaluation.evaluate(
            status: status,
            profile: .closedLidLabs
        )

        #expect(!labs.isAllowed)
        #expect(labs.blockers == [.helperUnavailable])

        status.helperReady = true
        status.thermalState = .serious
        let hot = MobilitySafetyEvaluation.evaluate(status: status, profile: .idleGuard)

        #expect(!hot.isAllowed)
        #expect(hot.blockers.contains(.thermalSerious))
    }

    @Test
    func safetyAllowsNominalIdleGuardWhenPreflightIsHealthy() {
        let evaluation = MobilitySafetyEvaluation.evaluate(
            status: makeSafeStatus(),
            profile: .idleGuard
        )

        #expect(evaluation.isAllowed)
        #expect(evaluation.blockers.isEmpty)
    }

    @Test
    func clientAndServerWireMessagesRoundTripWithMillisecondDates() throws {
        let codec = MobilityJSONCodec()
        let sentAt = Date(timeIntervalSince1970: 1_725_555_555.123)
        let command = AuthenticatedCommand(
            token: "paired-device-token",
            nonce: UUID(uuidString: "72C3A230-A2B2-46D5-A6EC-0F8E02200D6A")!,
            sentAt: sentAt,
            action: .setMode(enabled: true, profile: .closedLidLabs)
        )
        let client = ClientEnvelope(
            messageID: UUID(uuidString: "F37B9C81-35FA-4990-8867-C0E489C721DC")!,
            sentAt: sentAt,
            message: .command(command)
        )

        let clientData = try codec.encode(client)
        #expect(try codec.decodeClient(clientData) == client)

        let status = makeSafeStatus(observedAt: sentAt)
        let server = ServerEnvelope(
            messageID: client.messageID,
            sentAt: sentAt,
            message: .result(
                CommandResult(
                    nonce: command.nonce,
                    accepted: true,
                    message: "Mode enabled",
                    status: status
                )
            )
        )

        let serverData = try codec.encode(server)
        #expect(try codec.decodeServer(serverData) == server)
    }

    @Test
    func framesLargerThanMTUReassembleOutOfOrder() throws {
        let payload = Data((0..<2_048).map { UInt8($0 % 251) })
        let messageID = UUID(uuidString: "D7E44F27-D7A5-49A5-88F8-55A78F928854")!
        let frames = try MobilityFrameCodec.fragment(
            payload,
            messageID: messageID,
            maximumFrameSize: 64
        )

        #expect(frames.count > 1)
        #expect(frames.allSatisfy { $0.count <= 64 })

        var reassembler = MobilityFrameReassembler(maximumMessageSize: 4_096)
        var completed: MobilityReassembledMessage?
        for frame in frames.reversed() {
            if let message = try reassembler.ingest(frame) {
                completed = message
            }
        }

        #expect(completed?.messageID == messageID)
        #expect(completed?.payload == payload)
    }

    @Test
    func badFrameHeaderIsRejected() throws {
        let valid = try #require(
            MobilityFrameCodec.fragment(Data("hello".utf8), maximumFrameSize: 64).first
        )
        var corrupted = valid
        corrupted[corrupted.startIndex] = 0

        #expect(throws: MobilityFrameError.invalidMagic(0x004D4F42)) {
            try MobilityFrameCodec.decode(corrupted)
        }
        #expect(throws: MobilityFrameError.frameTooShort(
            actual: 3,
            minimum: MobilityFrameHeader.encodedLength
        )) {
            try MobilityFrameCodec.decode(Data([0x43, 0x4D, 0x4F]))
        }
    }

    private func makeSafeStatus(observedAt: Date = Date(timeIntervalSince1970: 1_725_555_555.123)) -> MobilityDeviceStatus {
        MobilityDeviceStatus(
            deviceID: UUID(uuidString: "2B495205-D800-4010-9074-4515C6E12925")!,
            deviceName: "Travel Mac",
            battery: MobilityBatteryStatus(levelPercent: 75),
            network: MobilityNetworkStatus(kind: .wifi, isConnected: true, isExpensive: true),
            thermalState: .nominal,
            codex: MobilityCodexStatus(isRunning: true, activeTaskCount: 1),
            mode: MobilityModeStatus(
                phase: .off,
                profile: .idleGuard,
                policy: .recommended,
                lastTransitionAt: observedAt
            ),
            helperReady: true,
            observedAt: observedAt
        )
    }
}
