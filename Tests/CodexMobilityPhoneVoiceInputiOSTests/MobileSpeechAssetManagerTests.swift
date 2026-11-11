import Foundation
import XCTest
@testable import CodexMobilityPhoneFeature

final class MobileSpeechAssetManagerTests: XCTestCase {
    func testEquivalentLocaleSeparatorsMatch() {
        XCTAssertTrue(
            MobileSpeechAssetManager.localesAreEquivalent(
                Locale(identifier: "zh_CN"),
                Locale(identifier: "zh-CN")
            )
        )
    }

    func testEquivalentScriptAndRegionVariantMatches() {
        XCTAssertTrue(
            MobileSpeechAssetManager.localesAreEquivalent(
                Locale(identifier: "zh-Hans"),
                Locale(identifier: "zh-CN")
            )
        )
    }

    func testDifferentRegionsDoNotMatch() {
        XCTAssertFalse(
            MobileSpeechAssetManager.localesAreEquivalent(
                Locale(identifier: "en-US"),
                Locale(identifier: "en-GB")
            )
        )
        XCTAssertFalse(
            MobileSpeechAssetManager.localesAreEquivalent(
                Locale(identifier: "zh-CN"),
                Locale(identifier: "zh-TW")
            )
        )
    }
}
