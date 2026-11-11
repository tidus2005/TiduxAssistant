import XCTest
import CodexMobilityCore

final class AdvertisementBudgetTests: XCTestCase {
    func testNameAnd128BitServiceFitPrimaryAdvertisingBudget() {
        // Apple documents 28 bytes, excluding per-field headers. Keeping both
        // fields in that budget avoids requiring a complete scan-response name.
        XCTAssertLessThanOrEqual(16 + MobilityBLEUUIDs.advertisedLocalName.utf8.count, 28)
    }
}
