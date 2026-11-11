import CodexMobilityCore
@testable import CodexMobilityPhoneFeature
import UIKit
import XCTest

@MainActor
final class ScreenshotAnnotationRendererTests: XCTestCase {
    func testRenderedPNGContainsImageAndAnnotationPanel() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 240, height: 120),
            format: format
        ).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        }

        let stroke = try XCTUnwrap(
            ScreenshotAnnotationStroke(
                tool: .rectangle,
                color: .red,
                points: [
                    ScreenshotAnnotationPoint(x: 0.1, y: 0.2),
                    ScreenshotAnnotationPoint(x: 0.8, y: 0.75),
                ]
            )
        )
        let mark = try XCTUnwrap(
            ScreenshotAnnotationMark(
                stroke: stroke,
                note: "将这里的按钮改成主要操作，并提高文字对比度。"
            )
        )

        let rendered = ScreenshotAnnotationRenderer.render(
            image: source,
            marks: [mark]
        )
        let pngData = try XCTUnwrap(rendered.pngData())
        let decoded = try XCTUnwrap(UIImage(data: pngData))

        XCTAssertEqual(decoded.cgImage?.width, 240)
        XCTAssertGreaterThan(decoded.cgImage?.height ?? 0, 120)
        XCTAssertTrue(pngData.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
}
