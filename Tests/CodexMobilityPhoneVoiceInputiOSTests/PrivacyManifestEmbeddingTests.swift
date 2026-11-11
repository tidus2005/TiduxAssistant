import Foundation
import XCTest

final class PrivacyManifestEmbeddingTests: XCTestCase {
    func testShippingBundlesContainTheirRequiredReasonManifests()
        throws
    {
        let appURL = Bundle.main.bundleURL
        let watchAppURL = appURL
            .appendingPathComponent("Watch", isDirectory: true)
            .appendingPathComponent(
                "CodexWatchPetWatch.app",
                isDirectory: true
            )
        let widgetURL = watchAppURL
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent(
                "CodexWatchPetWatchWidget.appex",
                isDirectory: true
            )

        XCTAssertEqual(
            try accessedAPIs(in: appURL),
            [
                "NSPrivacyAccessedAPICategoryUserDefaults": [
                    "CA92.1",
                    "1C8F.1",
                ],
                "NSPrivacyAccessedAPICategoryFileTimestamp": [
                    "C617.1",
                    "3B52.1",
                ],
                "NSPrivacyAccessedAPICategoryDiskSpace": [
                    "E174.1",
                    "85F4.1",
                ],
            ]
        )
        let watchReasons: [String: Set<String>] = [
            "NSPrivacyAccessedAPICategoryUserDefaults": [
                "CA92.1",
                "1C8F.1",
            ],
        ]
        XCTAssertEqual(
            try accessedAPIs(in: watchAppURL),
            watchReasons
        )
        XCTAssertEqual(
            try accessedAPIs(in: widgetURL),
            watchReasons
        )
    }

    private func accessedAPIs(
        in bundleURL: URL
    ) throws -> [String: Set<String>] {
        let manifestURL = bundleURL.appendingPathComponent(
            "PrivacyInfo.xcprivacy"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: manifestURL.path
            ),
            "缺少隐私清单：\(manifestURL.path)"
        )
        let propertyList = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: manifestURL),
            format: nil
        )
        let root = try XCTUnwrap(
            propertyList as? [String: Any]
        )
        XCTAssertEqual(root["NSPrivacyTracking"] as? Bool, false)
        XCTAssertTrue(
            (root["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty
                == true
        )
        let entries = try XCTUnwrap(
            root["NSPrivacyAccessedAPITypes"]
                as? [[String: Any]]
        )

        return try entries.reduce(into: [:]) { result, entry in
            let category = try XCTUnwrap(
                entry["NSPrivacyAccessedAPIType"] as? String
            )
            let reasons = try XCTUnwrap(
                entry["NSPrivacyAccessedAPITypeReasons"]
                    as? [String]
            )
            XCTAssertNil(
                result[category],
                "隐私清单重复声明 category：\(category)"
            )
            result[category] = Set(reasons)
        }
    }
}
