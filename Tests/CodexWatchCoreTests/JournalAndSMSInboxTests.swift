import Foundation
import Testing
@testable import CodexWatchCore

struct JournalAndSMSInboxTests {
    @Test func processingPassIncludesArrivalsWithoutRetryingUnavailableModel() throws {
        let now = Date()
        var first = try JournalClip(sessionID: UUID(), startedAt: now, endedAt: now.addingTimeInterval(30))
        first.phase = .waitingForSummary; first.transcript = "人工测试原文"
        var pass = JournalProcessingPass()
        #expect(pass.next(in: [first]) == first.id)
        // Model unavailable: phase remains waiting; a new transfer arrives during the await.
        var second = try JournalClip(sessionID: UUID(), startedAt: now, endedAt: now.addingTimeInterval(30))
        second.phase = .waitingForTranscription
        #expect(pass.next(in: [first, second]) == second.id)
        #expect(pass.next(in: [first, second]) == nil)
        #expect(first.resumePhase == .waitingForSummary)
        #expect(second.resumePhase == .waitingForTranscription)
        var resumed = JournalProcessingPass()
        #expect(resumed.next(in: [first, second]) == first.id)
    }
    @Test func rejectInvalidAudioMetadata() throws {
        let now = Date()
        #expect(throws: JournalError.self) { try JournalClip(sessionID: UUID(), startedAt: now, endedAt: now.addingTimeInterval(-1)) }
        #expect(throws: JournalError.self) { try JournalClip(sessionID: UUID(), startedAt: now, endedAt: now.addingTimeInterval(121)) }
        let clip = try JournalClip(sessionID: UUID(), startedAt: now, endedAt: now.addingTimeInterval(30))
        #expect(clip.audioName == clip.id.uuidString + ".m4a")
        #expect(try JSONDecoder().decode(JournalClip.self, from: JSONEncoder().encode(clip)) == clip)
    }
    @Test func noAutomaticSpeakerFallback() {
        #expect(WristReplyPolicy.shouldPlay(headphones: true, autoHeadphones: true, autoSpeaker: false, recording: false, active: true))
        #expect(!WristReplyPolicy.shouldPlay(headphones: false, autoHeadphones: true, autoSpeaker: false, recording: false, active: true))
        #expect(!WristReplyPolicy.shouldPlay(headphones: true, autoHeadphones: true, autoSpeaker: true, recording: true, active: true))
        #expect(!WristReplyPolicy.shouldPlay(headphones: false, autoHeadphones: false, autoSpeaker: true, recording: false, active: false))
        #expect(WristReplyPolicy.preview(String(repeating: "字", count: 200)).count == 141)
    }
    @Test func codeRequiresContext() {
        #expect(SMSCodeDetector.extract(from: "您的验证码为 123456，五分钟内有效") == "123456")
        #expect(SMSCodeDetector.extract(from: "Your verification code is 765432") == "765432")
        #expect(SMSCodeDetector.extract(from: "订单 123456 已发货") == nil)
        #expect(SMSCodeDetector.extract(from: "验证码服务请联系 13812345678") == nil)
        #expect(SMSCodeDetector.extract(from: "测试 20261111：验证码 123456。") == "123456")
        #expect(SMSCodeDetector.extract(from: "123456 is your verification code.") == "123456")
        #expect(SMSCodeDetector.extract(from: "验证码已发送。订单号 123456") == nil)
    }
    @Test @MainActor func persistDeduplicateAndSeparateMailHandoff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SMSInboxStore(directory: root)
        let first = try store.save(sender: "测试", body: "人工测试验证码 123456", sourceID: "test-1")
        #expect(first.mailHandedOffAt == nil)
        #expect(try store.save(sender: "测试", body: first.body, sourceID: "test-1").id == first.id)
        #expect(throws: SMSInboxError.self) { try store.save(sender: "其他", body: first.body, sourceID: "test-1") }
        #expect(store.messages.count == 1)
        try store.markMailHandedOff(id: first.id)
        let restored = SMSInboxStore(directory: root)
        #expect(restored.messages.first?.mailHandedOffAt != nil)
        #expect(restored.messages.first?.body == first.body)
    }
    @Test @MainActor func reserveBeforeSendingSurvivesRestartAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let store = SMSInboxStore(directory: root)
        let text = try store.prepareSMSForward(sender: "测试", body: "验证码 123456", sourceID: "source-1", now: now)
        #expect(text.hasPrefix("[随行转发]"))
        try store.delete(id: store.messages[0].id)
        let restored = SMSInboxStore(directory: root)
        #expect(try restored.prepareSMSForward(sender: "测试", body: "验证码 123456", sourceID: "source-1", now: now.addingTimeInterval(3600)) == "")
        #expect(try restored.prepareSMSForward(sender: "测试", body: text, now: now) == "")
        #expect(try restored.prepareSMSForward(sender: "测试", body: "验证码 654321", now: now) != "")
        #expect(try restored.prepareSMSForward(sender: "测试", body: "验证码 654321", now: now.addingTimeInterval(60)) == "")
        #expect(try restored.prepareSMSForward(sender: "测试", body: "验证码 654321", now: now.addingTimeInterval(901)) != "")
    }
}
