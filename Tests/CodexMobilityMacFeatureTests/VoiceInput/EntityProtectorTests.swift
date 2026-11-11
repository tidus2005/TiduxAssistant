import XCTest
@testable import CodexMobilityMacFeature

final class EntityProtectorTests: XCTestCase {
    private let protector = EntityProtector()

    func testProtectsEveryHighRiskEntityKindAndRestoresExactly() throws {
        let source = """
            Tidux 请在2026-07-31付￥1,299.50，邮件发给a+b@example.com，访问\
            https://example.com/a?id=42，文件在/Users/example/a.swift，完成率98%。
            """

        let protected = protector.protect(source, protectedTerms: ["Tidux"])

        XCTAssertEqual(
            Set(protected.entities.map(\.kind)),
            Set(EntityProtector.EntityKind.allCases)
        )
        XCTAssertFalse(protected.text.contains("2026-07-31"))
        XCTAssertFalse(protected.text.contains("a+b@example.com"))
        XCTAssertFalse(protected.text.contains("https://example.com/a?id=42"))
        XCTAssertFalse(protected.text.contains("/Users/example/a.swift"))
        XCTAssertEqual(try protector.restore(protected.text, from: protected), source)
    }

    func testURLClaimsItsInternalNumbersAndLeavesSentencePunctuation() throws {
        let source = "打开 https://example.com/v2/item?id=42，然后继续。"

        let protected = protector.protect(source)

        XCTAssertEqual(protected.entities.count, 1)
        XCTAssertEqual(protected.entities[0].kind, .url)
        XCTAssertEqual(protected.entities[0].value, "https://example.com/v2/item?id=42")
        XCTAssertTrue(protected.text.hasSuffix("，然后继续。"))
        XCTAssertEqual(try protector.restore(protected.text, from: protected), source)
    }

    func testURLKeepsBalancedClosingParenthesisButNotSentenceWrapper() {
        let source = "参考 (https://example.com/wiki/Function_(math))。"

        let protected = protector.protect(source)

        XCTAssertEqual(
            protected.entities.first?.value,
            "https://example.com/wiki/Function_(math)"
        )
        XCTAssertTrue(protected.text.hasSuffix(")。"))
    }

    func testRecognizesChineseDatesWindowsAndRelativePaths() throws {
        let source = #"7月31日检查 C:\Users\me\notes.txt 和 Sources/FlowType/App.swift，预算200元。"#

        let protected = protector.protect(source)
        let kinds = protected.entities.map(\.kind)

        XCTAssertEqual(kinds.filter { $0 == .date }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == .filePath }.count, 2)
        XCTAssertEqual(kinds.filter { $0 == .money }.count, 1)
        XCTAssertEqual(try protector.restore(protected.text, from: protected), source)
    }

    func testRepeatedValuesUseDistinctPlaceholders() throws {
        let protected = protector.protect("版本 42 对比版本 42")

        XCTAssertEqual(protected.entities.count, 2)
        XCTAssertNotEqual(
            protected.entities[0].placeholder,
            protected.entities[1].placeholder
        )
        XCTAssertEqual(try protector.restore(protected.text, from: protected), "版本 42 对比版本 42")
    }

    func testMissingPlaceholderIsRejected() {
        let protected = protector.protect("订单 123")
        let candidate = protected.text.replacingOccurrences(
            of: protected.entities[0].placeholder,
            with: ""
        )

        XCTAssertThrowsError(try protector.restore(candidate, from: protected)) { error in
            XCTAssertEqual(
                error as? EntityProtector.ProtectionError,
                .missingPlaceholder(protected.entities[0].placeholder)
            )
        }
    }

    func testDuplicatePlaceholderIsRejected() {
        let protected = protector.protect("订单 123")
        let placeholder = protected.entities[0].placeholder

        XCTAssertThrowsError(
            try protector.restore("\(protected.text) \(placeholder)", from: protected)
        ) { error in
            XCTAssertEqual(
                error as? EntityProtector.ProtectionError,
                .duplicatePlaceholder(placeholder)
            )
        }
    }

    func testReorderedPlaceholdersAreRejected() {
        let protected = protector.protect("订单 123 在 7月31日处理")
        XCTAssertEqual(protected.entities.count, 2)
        let candidate = """
            \(protected.entities[1].placeholder) 在 \
            \(protected.entities[0].placeholder) 处理
            """

        XCTAssertThrowsError(try protector.restore(candidate, from: protected)) { error in
            XCTAssertEqual(
                error as? EntityProtector.ProtectionError,
                .reorderedPlaceholders
            )
        }
    }

    func testInventedPlaceholderIsRejected() {
        let protected = protector.protect("订单 123")
        let candidates = [
            "\(protected.text) ⟦FT_ENTITY_999⟧",
            "\(protected.text) ⟦FT1_ENTITY_999⟧",
        ]

        for candidate in candidates {
            XCTAssertThrowsError(try protector.restore(candidate, from: protected)) { error in
                guard case .unexpectedPlaceholder = error as? EntityProtector.ProtectionError else {
                    return XCTFail("expected an unexpected placeholder error")
                }
            }
        }
    }

    func testMarkerAlreadyPresentInSourceCannotCollide() throws {
        let source = "原文含 ⟦FT_ENTITY_0⟧，订单 123"

        let protected = protector.protect(source)

        XCTAssertTrue(protected.entities.allSatisfy {
            $0.placeholder.hasPrefix("⟦FT1_ENTITY_")
        })
        XCTAssertEqual(try protector.restore(protected.text, from: protected), source)
    }

    func testEmptyTextRoundTripsWithoutEntities() throws {
        let protected = protector.protect("")

        XCTAssertTrue(protected.isEmpty)
        XCTAssertEqual(try protector.restore("", from: protected), "")
    }
}
