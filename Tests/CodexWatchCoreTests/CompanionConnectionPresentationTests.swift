import XCTest
@testable import CodexWatchCore

final class CompanionConnectionPresentationTests: XCTestCase {
    func testRecentPhoneSyncDoesNotImplyMacIsConnected() {
        let now = Date()
        let view = CompanionConnectionPresentation(bridgeOnline: false, savedAt: now, now: now)
        XCTAssertEqual(view.phase, .offline)
        XCTAssertFalse(view.canSend)
    }
    func testCachedOnlineStatusExpires() {
        let now = Date()
        XCTAssertEqual(CompanionConnectionPresentation(bridgeOnline: true, savedAt: now.addingTimeInterval(-91), now: now).phase, .stale)
        XCTAssertFalse(CompanionConnectionPresentation(bridgeOnline: true, savedAt: nil, now: now).canSend)
        XCTAssertTrue(CompanionConnectionPresentation(bridgeOnline: true, savedAt: now, now: now).canSend)
    }
}
