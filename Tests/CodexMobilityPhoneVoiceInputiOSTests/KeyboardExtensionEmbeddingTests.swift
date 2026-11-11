import Foundation
import XCTest

final class KeyboardExtensionEmbeddingTests: XCTestCase {
    func testKeyboardExtensionIsEmbeddedWithOfflineConfiguration()
        throws
    {
        let appURL = Bundle.main.bundleURL
        let keyboardURL = appURL
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent(
                "CodexWatchPetKeyboard.appex",
                isDirectory: true
            )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: keyboardURL.path),
            "主 App 必须嵌入 CodexWatchPetKeyboard.appex"
        )

        let appInfo = try propertyList(
            at: appURL.appendingPathComponent("Info.plist")
        )
        let keyboardInfo = try propertyList(
            at: keyboardURL.appendingPathComponent("Info.plist")
        )

        XCTAssertEqual(
            keyboardInfo["CFBundleIdentifier"] as? String,
            "com.tidux.CodexWatchPet.keyboard"
        )
        XCTAssertEqual(
            keyboardInfo["CFBundleShortVersionString"] as? String,
            appInfo["CFBundleShortVersionString"] as? String
        )
        XCTAssertEqual(
            keyboardInfo["CFBundleVersion"] as? String,
            appInfo["CFBundleVersion"] as? String
        )

        let extensionInfo = try XCTUnwrap(
            keyboardInfo["NSExtension"] as? [String: Any]
        )
        XCTAssertEqual(
            extensionInfo["NSExtensionPointIdentifier"] as? String,
            "com.apple.keyboard-service"
        )
        XCTAssertEqual(
            extensionInfo["NSExtensionPrincipalClass"] as? String,
            "CodexWatchPetKeyboard.KeyboardViewController"
        )

        let attributes = try XCTUnwrap(
            extensionInfo["NSExtensionAttributes"]
                as? [String: Any]
        )
        XCTAssertEqual(attributes["RequestsOpenAccess"] as? Bool, false)
        XCTAssertEqual(attributes["IsASCIICapable"] as? Bool, true)
        XCTAssertEqual(
            attributes["PrefersRightToLeft"] as? Bool,
            false
        )
        XCTAssertEqual(attributes["PrimaryLanguage"] as? String, "en-US")
    }

    func testKeyboardPrivacyManifestDeclaresNoCollectionOrAccessedAPIs()
        throws
    {
        let manifestURL = Bundle.main.bundleURL
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent(
                "CodexWatchPetKeyboard.appex",
                isDirectory: true
            )
            .appendingPathComponent("PrivacyInfo.xcprivacy")
        let manifest = try propertyList(at: manifestURL)

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertTrue(
            (manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty
                == true
        )
        XCTAssertTrue(
            (manifest["NSPrivacyAccessedAPITypes"] as? [Any])?.isEmpty
                == true
        )
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "缺少属性列表：\(url.path)"
        )
        let value = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil
        )
        return try XCTUnwrap(value as? [String: Any])
    }
}
