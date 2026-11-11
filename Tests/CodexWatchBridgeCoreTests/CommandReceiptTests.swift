import CodexWatchBridgeCore
import CodexWatchCore
import Foundation
import Testing

@Suite("Durable command receipts")
struct CommandReceiptTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cwp-receipts-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func command() -> BridgeCommand {
        BridgeCommand(type: .startThread, payload: ["prompt": "receipt test"],
            confirmation: CommandConfirmation(displayedSummary: "test", riskAccepted: true))
    }
    @Test func duplicateAfterRestartReturnsReceiptWithoutSecondLaunch() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let launcher = StubDetachedLauncher()
        let first = BridgeRuntime(codexHome: dir, bridgeHome: dir, launcher: launcher)
        let pairing = try first.ensurePairing(); let command = command()
        let signature = try CommandSigner().sign(command, secret: pairing.secretData)
        let receipt = try first.submit(command: command, bearerToken: pairing.token, signature: signature)
        let restarted = BridgeRuntime(codexHome: dir, bridgeHome: dir, launcher: launcher)
        let repeated = try restarted.submit(command: command, bearerToken: pairing.token, signature: signature)
        #expect(launcher.launches.count == 1)
        #expect(receipt.auditId == repeated.auditId)
        #expect(try restarted.commandReceipt(id: command.id)?.commandId == command.id)
    }
    @Test func changedContentAndUnauthorizedReplayAreRejected() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let launcher = StubDetachedLauncher()
        let runtime = BridgeRuntime(codexHome: dir, bridgeHome: dir, launcher: launcher)
        let pairing = try runtime.ensurePairing(); let original = command()
        let signature = try CommandSigner().sign(original, secret: pairing.secretData)
        _ = try runtime.submit(command: original, bearerToken: pairing.token, signature: signature)
        var changed = original; changed.payload["prompt"] = "different"
        let changedSignature = try CommandSigner().sign(changed, secret: pairing.secretData)
        #expect(throws: (any Error).self) { _ = try runtime.submit(command: changed, bearerToken: pairing.token, signature: changedSignature) }
        #expect(throws: (any Error).self) { _ = try runtime.submit(command: original, bearerToken: "wrong", signature: signature) }
        #expect(throws: (any Error).self) { _ = try runtime.submit(command: original, bearerToken: pairing.token, signature: "wrong") }
        #expect(launcher.launches.count == 1)
    }
    @Test func interruptedReservationCannotBeExecutedAfterRestart() throws {
        struct FailingLauncher: DetachedProcessLaunching {
            func launch(_ executable: String, arguments: [String], logFile: URL) throws -> DetachedProcessLaunch { throw URLError(.networkConnectionLost) }
        }
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = BridgeRuntime(codexHome: dir, bridgeHome: dir, launcher: FailingLauncher())
        let pairing = try first.ensurePairing(); let command = command()
        let signature = try CommandSigner().sign(command, secret: pairing.secretData)
        #expect(throws: (any Error).self) { _ = try first.submit(command: command, bearerToken: pairing.token, signature: signature) }
        let launcher = StubDetachedLauncher()
        let restarted = BridgeRuntime(codexHome: dir, bridgeHome: dir, launcher: launcher)
        #expect(throws: (any Error).self) { _ = try restarted.submit(command: command, bearerToken: pairing.token, signature: signature) }
        #expect(launcher.launches.isEmpty)
    }
}
