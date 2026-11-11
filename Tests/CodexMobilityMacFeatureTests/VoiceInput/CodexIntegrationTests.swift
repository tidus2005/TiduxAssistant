import XCTest
@testable import CodexMobilityMacFeature

final class CodexIntegrationTests: XCTestCase {
    func testAuthenticatedCodexCLIActuallyPolishesText() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEX_WATCH_PET_RUN_CODEX_INTEGRATION"] == "1"
            || environment["FLOWTYPE_RUN_CODEX_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "Set CODEX_WATCH_PET_RUN_CODEX_INTEGRATION=1 to call the authenticated Codex CLI."
            )
        }

        let polisher = CodexPolisher()
        XCTAssertTrue(polisher.isAvailable, "The authenticated Codex CLI must be installed.")

        let rawText = "嗯，7月31日我们开会，然后然后确认方案"
        let startedAt = ContinuousClock.now
        let result = await polisher.polish(
            rawText: rawText,
            locale: "zh-CN",
            timeout: 20
        )
        let elapsed = startedAt.duration(to: .now)

        print("Real Codex CLI elapsed: \(elapsed)")
        XCTAssertFalse(
            result.usedFallback,
            "Expected a real model response, got fallback: \(String(describing: result.reason))"
        )
        XCTAssertTrue(result.text.contains("7月31日"))
        XCTAssertFalse(result.text.contains("然后然后"))
    }
}
