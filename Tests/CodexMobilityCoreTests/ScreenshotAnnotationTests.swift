@testable import CodexMobilityCore
import Foundation
import Testing

@Suite("Screenshot annotation core")
struct ScreenshotAnnotationTests {
    @Test
    func aspectFitGeometryCentersPortraitImage() {
        let rect = ScreenshotAnnotationGeometry.aspectFitRect(
            imageWidth: 1_290,
            imageHeight: 2_796,
            containerWidth: 390,
            containerHeight: 500
        )

        #expect(abs(rect.height - 500) < 0.001)
        #expect(abs(rect.width - 230.687) < 0.01)
        #expect(abs(rect.x - 79.656) < 0.01)
        #expect(rect.y == 0)
    }

    @Test
    func pointsNormalizeAndProjectWithoutDependingOnViewSize() throws {
        let rect = ScreenshotAnnotationRect(x: 40, y: 20, width: 200, height: 400)
        let point = try #require(
            ScreenshotAnnotationGeometry.normalizedPoint(x: 140, y: 220, in: rect)
        )
        #expect(point == ScreenshotAnnotationPoint(x: 0.5, y: 0.5))

        let projected = ScreenshotAnnotationGeometry.projectedPoint(point, in: rect)
        #expect(projected.x == 140)
        #expect(projected.y == 220)
        #expect(ScreenshotAnnotationGeometry.normalizedPoint(x: 20, y: 220, in: rect) == nil)
        #expect(
            ScreenshotAnnotationGeometry.normalizedPoint(
                x: 20,
                y: 900,
                in: rect,
                clamped: true
            ) == ScreenshotAnnotationPoint(x: 0, y: 1)
        )
    }

    @Test
    func shapeStrokesRejectAccidentalTapsAndExposeStableBounds() throws {
        #expect(
            ScreenshotAnnotationStroke(
                tool: .rectangle,
                color: .red,
                points: [
                    ScreenshotAnnotationPoint(x: 0.2, y: 0.2),
                    ScreenshotAnnotationPoint(x: 0.205, y: 0.7),
                ]
            ) == nil
        )

        let stroke = try #require(ScreenshotAnnotationStroke(
            tool: .ellipse,
            color: .blue,
            points: [
                ScreenshotAnnotationPoint(x: 0.8, y: 0.7),
                ScreenshotAnnotationPoint(x: 0.2, y: 0.1),
            ]
        ))
        #expect(stroke.points.count == 2)
        #expect(abs(stroke.bounds.x - 0.2) < 0.000_001)
        #expect(abs(stroke.bounds.y - 0.1) < 0.000_001)
        #expect(abs(stroke.bounds.width - 0.6) < 0.000_001)
        #expect(abs(stroke.bounds.height - 0.6) < 0.000_001)
        #expect(stroke.markerAnchor == ScreenshotAnnotationPoint(x: 0.2, y: 0.1))
    }

    @Test
    func freehandStrokeRequiresARealPathAndNotesAreTrimmed() throws {
        let points = [
            ScreenshotAnnotationPoint(x: 0.1, y: 0.1),
            ScreenshotAnnotationPoint(x: 0.4, y: 0.1),
            ScreenshotAnnotationPoint(x: 0.4, y: 0.4),
            ScreenshotAnnotationPoint(x: 0.1, y: 0.4),
        ]
        let stroke = try #require(ScreenshotAnnotationStroke(
            tool: .freehand,
            color: .purple,
            points: points
        ))
        let mark = try #require(ScreenshotAnnotationMark(
            stroke: stroke,
            note: "  调整这里的按钮间距。\n"
        ))
        #expect(mark.note == "调整这里的按钮间距。")
        #expect(
            ScreenshotAnnotationMark(stroke: stroke, note: " \n ") == nil
        )
    }

    @Test
    func colorComponentsClampInvalidValues() {
        let components = ScreenshotAnnotationColorComponents(
            red: -1,
            green: 2,
            blue: .infinity,
            alpha: 0.5
        )
        #expect(components.red == 0)
        #expect(components.green == 1)
        #expect(components.blue == 0)
        #expect(components.alpha == 0.5)
    }
}
