import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Security
import Testing
@testable import CodexMobilityMacFeature

@Suite("Voice MVP P0 contracts")
struct VoiceMVPP0Tests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-p0-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func dictionaryRoundTripReplacementScopeAndBoundaries() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LexiconStore(directory: dir)
        let entries = [LexiconEntry(term: "Tidux", aliases: ["tidus", "铁克斯"], protect: true),
                       LexiconEntry(term: "大象", aliases: ["DX"], appScope: ["com.apple.mail"])]
        try store.save(LexiconDocument(entries: entries))
        #expect(try store.load().entries == entries)
        #expect(LexiconStore.replacingAliases(in: "tidus 铁克斯 DX Xtidus", entries: entries,
                                              bundleID: "com.apple.mail") == "Tidux Tidux 大象 Xtidus")
        #expect(LexiconStore.replacingAliases(in: "DX", entries: entries, bundleID: nil) == "DX")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func dictionaryDoesNotCascadeOrGuessAmbiguousAlias() {
        let entries = [LexiconEntry(term: "A", aliases: ["B", "X"]), LexiconEntry(term: "B", aliases: ["C", "X"])]
        #expect(LexiconStore.replacingAliases(in: "A B C X", entries: entries, bundleID: nil) == "A B B X")
        let protected = [LexiconEntry(term: "Tidux", protect: true), LexiconEntry(term: "别的", aliases: ["Tidux助手"])]
        #expect(LexiconStore.replacingAliases(in: "Tidux助手", entries: protected, bundleID: nil) == "Tidux助手")
    }

    @Test func invalidConfigurationIsNotOverwritten() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LexiconStore(directory: dir)
        let bad = Data(#"{"schemaVersion":"9","updatedAt":"2026-11-05T00:00:00Z","entries":[]}"#.utf8)
        try bad.write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == bad)
        #expect(throws: (any Error).self) { try store.save(LexiconDocument(entries: [LexiconEntry(term: "")])) }
        #expect(try Data(contentsOf: store.url) == bad)
    }

    @Test func appStylesMatchExactBundleAndRespectGlobalOptOut() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = AppStylePolicy(directory: dir)
        let document = AppTonesDocument(profiles: [
            AppToneProfile(match: .init(value: "com.apple.mail"), tone: .formal),
            AppToneProfile(match: .init(kind: .exeName, value: "mail.exe"), tone: .casual),
            AppToneProfile(match: .init(value: "com.example.private"), tone: .faithful, polishEnabled: false)])
        try policy.save(document)
        #expect(try policy.load().profiles == document.profiles)
        #expect(AppStylePolicy.resolve(bundleID: "com.apple.mail", document: document, globalPolishEnabled: true).tone == .formal)
        #expect(!AppStylePolicy.resolve(bundleID: "com.apple.mail", document: document, globalPolishEnabled: false).polishEnabled)
        #expect(!AppStylePolicy.resolve(bundleID: "com.example.private", document: document, globalPolishEnabled: true).polishEnabled)
        #expect(AppStylePolicy.resolve(bundleID: "mail.exe", document: document, globalPolishEnabled: true).tone == .faithful)
        #expect(AppStylePolicy.resolve(bundleID: nil, document: document, globalPolishEnabled: true).tone == .faithful)
    }

    @Test func protectsProperNounsAndRejectsInventedFacts() throws {
        let text = "Tidux 给 Keeta 支付100元"
        let terms = ["Tidux", "Keeta"]
        let protected = EntityProtector().protect(text, protectedTerms: terms)
        #expect(protected.entities.filter { $0.kind == .properNoun }.map(\.value) == terms)
        #expect(!protected.text.contains("Keeta"))
        #expect(try EntityProtector().restore(protected.text, from: protected) == text)
        #expect(throws: EditValidator.Rejection.entityConflict) {
            try EditValidator.validate(source: text, candidate: "Tidux 给 Keta 支付100元", protectedTerms: terms)
        }
        #expect(throws: EditValidator.Rejection.entityConflict) {
            try EditValidator.validate(source: text, candidate: text + "，明天增加200元", protectedTerms: terms)
        }
    }

    @Test(arguments: ["预算100元，不对，改成200元", "不是十五，是五十", "pay 15, sorry 50"])
    func numericCorrectionsCannotDropEarlierValueOrNegation(_ source: String) throws {
        #expect(EditValidator.hasCorrectionConflict(source))
        #expect(throws: EditValidator.Rejection.correctionConflict) {
            try EditValidator.validate(source: source, candidate: source.replacingOccurrences(of: "不是", with: "是") + "。")
        }
        #expect(LocalTextCleaner.clean(source) == source)
        try EditValidator.validate(source: source, candidate: source)
    }

    @Test func cleanerPreservesDemonstrativesAndProtectedFillers() {
        #expect(LocalTextCleaner.clean("嗯，那个，就是说，开始处理") == "开始处理")
        #expect(LocalTextCleaner.clean("打开那个项目") == "打开那个项目")
        #expect(LocalTextCleaner.clean("那个，开始", protectedTerms: ["那个"]) == "那个，开始")
        #expect(LocalTextCleaner.clean("嗯，订单100元") == "订单100元")
    }

    @Test func historyEncryptionRoundTripTamperAndWrongKey() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let repository = HistoryRepository(directory: dir, keyProvider: key)
        let record = TranscriptSession(createdAt: Date(timeIntervalSince1970: 1_800_000_000), locale: "zh-CN",
                                       rawText: "私密内容100元", polishedText: "私密内容100元", delivery: .unconfirmed)
        try repository.record(record, enabled: true, now: record.createdAt)
        #expect(try repository.load(now: record.createdAt) == [record])
        let sealed = try Data(contentsOf: repository.url)
        #expect(sealed.range(of: Data(record.rawText.utf8)) == nil)
        #expect(throws: (any Error).self) {
            try HistoryRepository(directory: dir, keyProvider: TestHistoryKey()).load(now: record.createdAt)
        }
        var changed = sealed
        changed[changed.count - 1] ^= 1
        try changed.write(to: repository.url)
        #expect(throws: (any Error).self) { try repository.load(now: record.createdAt) }
        #expect(try Data(contentsOf: repository.url) == changed)
    }

    @Test func historyDisabledNeverRequestsKeyOrCreatesFileAndRetentionPrunes() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let disabled = HistoryRepository(directory: dir, keyProvider: RejectHistoryKey())
        try disabled.record(TranscriptSession(locale: "zh-CN", rawText: "不保存"), enabled: false)
        #expect(!FileManager.default.fileExists(atPath: disabled.url.path))
        let repository = HistoryRepository(directory: dir, keyProvider: TestHistoryKey())
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let record = TranscriptSession(createdAt: created, locale: "zh-CN", rawText: "过期")
        try repository.record(record, enabled: true, now: created)
        #expect(try repository.load(now: created.addingTimeInterval(8 * 86400)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repository.url.path))
    }

    @Test func historyUpsertsDeliveryWithoutDuplicatingOrIncludingAudio() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir, keyProvider: TestHistoryKey())
        var record = TranscriptSession(locale: "zh-CN", rawText: "结果")
        try repository.record(record, enabled: true)
        record.delivery = .copiedByUser
        try repository.record(record, enabled: true)
        #expect(try repository.load().count == 1)
        #expect(try repository.load().first?.delivery == .copiedByUser)
        record.audioIncluded = true
        #expect(throws: HistoryError.self) { try repository.record(record, enabled: true) }
        try repository.clear()
        #expect(try repository.load().isEmpty)
    }

    @Test func keychainKeyPersistsAcrossProviders() throws {
        let service = "com.tidux.voice-p0-tests.\(UUID().uuidString)"
        let provider = KeychainHistoryKeyProvider(service: service)
        defer {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        }
        let first = try provider.key().withUnsafeBytes { Data($0) }
        let second = try KeychainHistoryKeyProvider(service: service).key().withUnsafeBytes { Data($0) }
        #expect(first.count == 32)
        #expect(first == second)
    }

    @Test func dictionaryNameInsideURLKeepsWholeURLProtected() throws {
        let source = "打开 https://Tidux.example/v2，Project2026 准备"
        let protected = EntityProtector().protect(source, protectedTerms: ["Tidux", "Project2026"])
        #expect(protected.entities.map(\.kind) == [.url, .properNoun])
        #expect(throws: EditValidator.Rejection.entityConflict) {
            try EditValidator.validate(source: source,
                candidate: source.replacingOccurrences(of: "example", with: "invalid"),
                protectedTerms: ["Tidux", "Project2026"])
        }
    }

    @Test func frozenExamplesRoundTripAndExportSchemaEvidence() throws {
        // Exact examples frozen by Tidux on 2026-11-05, not a parallel schema.
        let dictionaryJSON = #"""
        {
          "schemaVersion": "0.1.0",
          "updatedAt": "2026-11-05T04:10:00+08:00",
          "localeDefault": "zh-Hans",
          "entries": [
            {
              "id": "tidux",
              "term": "Tidux",
              "aliases": ["tidus", "铁克斯"],
              "protect": true,
              "source": "manual",
              "weight": 1
            },
            {
              "id": "meituan-daxiang",
              "term": "大象",
              "aliases": ["DX"],
              "appScope": ["com.apple.mail", "OUTLOOK.EXE"],
              "protect": true,
              "source": "manual"
            }
          ]
        }
        """#
        let stylesJSON = #"""
        {
          "schemaVersion": "0.1.0",
          "updatedAt": "2026-11-05T04:10:00+08:00",
          "defaultTone": "faithful",
          "profiles": [
            {
              "id": "mail-formal",
              "match": { "kind": "bundleId", "value": "com.apple.mail" },
              "tone": "formal",
              "polishEnabled": true
            },
            {
              "id": "wechat-casual",
              "match": { "kind": "bundleId", "value": "com.tencent.xinWeChat" },
              "tone": "casual",
              "polishEnabled": true
            },
            {
              "id": "win-notepad-faithful",
              "match": { "kind": "exeName", "value": "notepad.exe" },
              "tone": "faithful",
              "polishEnabled": false
            }
          ]
        }
        """#
        let dictionary = try VoiceStorage.decoder().decode(LexiconDocument.self, from: Data(dictionaryJSON.utf8))
        let styles = try VoiceStorage.decoder().decode(AppTonesDocument.self, from: Data(stylesJSON.utf8))
        #expect(dictionary.entries.first?.term == "Tidux")
        #expect(styles.profiles.last?.match.kind == .exeName)
        #expect(try VoiceStorage.decoder().decode(LexiconDocument.self, from: VoiceStorage.encoder().encode(dictionary)) == dictionary)
        #expect(try VoiceStorage.decoder().decode(AppTonesDocument.self, from: VoiceStorage.encoder().encode(styles)) == styles)
        let keys = HotkeySemantics()
        #expect(keys.mode == "toggle")
        #expect(keys.bindings.first?.keys == ["Fn"])
        let session = TranscriptSession(createdAt: Date(timeIntervalSince1970: 1_800_000_000), locale: "zh-CN", rawText: "合成验收文本", delivery: .retainedOnly)
        if let path = ProcessInfo.processInfo.environment["VOICE_MVP_SCHEMA_OUTPUT"] {
            let directory = URL(fileURLWithPath: path)
            try VoiceStorage.write(VoiceStorage.encoder().encode(dictionary), to: directory.appendingPathComponent("dictionary.json"))
            try VoiceStorage.write(VoiceStorage.encoder().encode(styles), to: directory.appendingPathComponent("app-tones.json"))
            try HotkeySemantics.save(to: directory)
            try VoiceStorage.write(VoiceStorage.encoder().encode(session), to: directory.appendingPathComponent("transcript-session.json"))
        }
    }

    @Test func pasteEvidenceRejectsArbitraryCursorMovement() {
        let captured = TextSelectionRangeSnapshot(location: 4, length: 3)
        #expect(!PasteboardDeliveryEvidence(targetStillFocused: true, capturedRange: captured,
            deliveredRange: .init(location: 15, length: 0), insertedUTF16Count: 5).confirmsTargetDelivery)
        #expect(PasteboardDeliveryEvidence(targetStillFocused: true, capturedRange: captured,
            deliveredRange: .init(location: 9, length: 0), insertedUTF16Count: 5).confirmsTargetDelivery)
    }

    @Test @MainActor func deliveryStatesNeverAutoCopyOnAnyFailure() async {
        let insertion = MVPInsertion()
        let pasteboard = MVPClipboard()
        let coordinator = DeliveryCoordinator(insertion: insertion, pasteboard: pasteboard)
        let target = CapturedTextTarget(element: AXUIElementCreateApplication(1), processIdentifier: 1,
            applicationBundleIdentifier: "test", role: "AXTextField", subrole: nil, selectedTextRangeAtCapture: nil)
        #expect(await coordinator.deliver("结果", target: nil) == .retainedOnly)
        #expect(await coordinator.deliver("结果", target: target) == .inserted)
        let failures: [TextInsertionService.InsertionError] = [.focusChanged, .targetApplicationChanged(expected: 1, actual: 2),
            .secureTextField, .accessibilityPermissionDenied, .pasteboardWriteFailed]
        for error in failures {
            insertion.error = error
            #expect(await coordinator.deliver("结果", target: target) == .retainedOnly)
        }
        insertion.error = .pasteboardDeliveryUnconfirmed(resultCopied: false)
        #expect(await coordinator.deliver("结果", target: target) == .unconfirmed)
        #expect(pasteboard.contents == "用户原剪贴板")
        #expect(pasteboard.writes == 0)
        #expect(coordinator.copyByUser("结果") == .copiedByUser)
        #expect(pasteboard.contents == "结果")
        pasteboard.succeeds = false
        #expect(coordinator.copyByUser("另一个结果") == .retainedOnly)
    }
}

private struct TestHistoryKey: HistoryKeyProviding {
    let value = SymmetricKey(size: .bits256)
    func key() throws -> SymmetricKey { value }
}
private struct RejectHistoryKey: HistoryKeyProviding {
    func key() throws -> SymmetricKey { throw HistoryError.invalidRecord }
}
@MainActor private final class MVPInsertion: VoiceTextInserting {
    var error: TextInsertionService.InsertionError?
    func captureTarget() throws -> CapturedTextTarget { throw TextInsertionService.InsertionError.noFocusedElement }
    func insert(_ text: String, into target: CapturedTextTarget) async throws -> TextInsertionService.InsertionMethod {
        if let error { throw error }
        return .accessibilitySelectedText
    }
}
@MainActor private final class MVPClipboard: VoicePasteboardWriting {
    var writes = 0
    var contents = "用户原剪贴板"
    var succeeds = true
    func write(_ text: String) -> Bool {
        writes += 1
        if succeeds { contents = text }
        return succeeds
    }
}
