#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(UIKit)
import CodexMobilityCore
import SwiftUI
import UIKit

@MainActor
struct ScreenshotAnnotationCanvasView: View {
    let model: ScreenshotAnnotationEditorModel
    let onFinishedDrawing: (PendingScreenshotAnnotation) -> Void

    var body: some View {
        GeometryReader { proxy in
            if let image = model.sourceImage {
                let imageRect = ScreenshotAnnotationGeometry.aspectFitRect(
                    imageWidth: Double(max(image.size.width, 1)),
                    imageHeight: Double(max(image.size.height, 1)),
                    containerWidth: Double(max(proxy.size.width, 1)),
                    containerHeight: Double(max(proxy.size.height, 1))
                )

                ZStack {
                    Color.black.opacity(0.88)

                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(
                            width: CGFloat(imageRect.width),
                            height: CGFloat(imageRect.height)
                        )
                        .position(
                            x: CGFloat(imageRect.x + imageRect.width / 2),
                            y: CGFloat(imageRect.y + imageRect.height / 2)
                        )

                    Canvas { context, _ in
                        drawCommittedMarks(in: &context, imageRect: imageRect)
                        drawActiveStroke(in: &context, imageRect: imageRect)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
                .gesture(drawingGesture(in: imageRect))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("截图标注画布")
                .accessibilityValue("已有 \(model.marks.count) 条标注")
                .accessibilityHint("使用当前工具在图片范围内拖动，松手后填写修改说明")
                .accessibilityIdentifier("screenshot.annotation.canvas")
            } else {
                ContentUnavailableView(
                    "尚未选择截图",
                    systemImage: "photo.badge.plus",
                    description: Text("从照片中选择一张应用截图后开始标注。")
                )
            }
        }
        .frame(minHeight: 440, idealHeight: 520, maxHeight: 580)
    }

    private func drawingGesture(
        in imageRect: ScreenshotAnnotationRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let shouldClamp = !model.activePoints.isEmpty
                guard let point = ScreenshotAnnotationGeometry.normalizedPoint(
                    x: Double(value.location.x),
                    y: Double(value.location.y),
                    in: imageRect,
                    clamped: shouldClamp
                ) else {
                    return
                }
                model.updateGesture(at: point)
            }
            .onEnded { value in
                guard !model.activePoints.isEmpty else {
                    model.cancelGesture()
                    return
                }
                guard let point = ScreenshotAnnotationGeometry.normalizedPoint(
                    x: Double(value.location.x),
                    y: Double(value.location.y),
                    in: imageRect,
                    clamped: true
                ) else {
                    model.cancelGesture()
                    return
                }
                if let pending = model.finishGesture(at: point) {
                    onFinishedDrawing(pending)
                }
            }
    }

    private func drawCommittedMarks(
        in context: inout GraphicsContext,
        imageRect: ScreenshotAnnotationRect
    ) {
        for (offset, mark) in model.marks.enumerated() {
            draw(
                tool: mark.stroke.tool,
                color: mark.stroke.color,
                points: mark.stroke.points,
                in: &context,
                imageRect: imageRect,
                number: offset + 1
            )
        }
    }

    private func drawActiveStroke(
        in context: inout GraphicsContext,
        imageRect: ScreenshotAnnotationRect
    ) {
        guard !model.activePoints.isEmpty else { return }
        draw(
            tool: model.selectedTool,
            color: model.selectedColor,
            points: model.activePoints,
            in: &context,
            imageRect: imageRect,
            number: nil
        )
    }

    private func draw(
        tool: ScreenshotAnnotationTool,
        color: ScreenshotAnnotationColor,
        points: [ScreenshotAnnotationPoint],
        in context: inout GraphicsContext,
        imageRect: ScreenshotAnnotationRect,
        number: Int?
    ) {
        let path = annotationPath(tool: tool, points: points, imageRect: imageRect)
        guard !path.isEmpty else { return }

        context.stroke(
            path,
            with: .color(.white.opacity(0.92)),
            style: StrokeStyle(
                lineWidth: 7,
                lineCap: .round,
                lineJoin: .round
            )
        )
        context.stroke(
            path,
            with: .color(color.swiftUIColor),
            style: StrokeStyle(
                lineWidth: 4,
                lineCap: .round,
                lineJoin: .round
            )
        )

        guard let number else { return }
        let bounds = normalizedBounds(points)
        let anchor = ScreenshotAnnotationPoint(x: bounds.x, y: bounds.y)
        drawMarker(
            number: number,
            color: color,
            anchor: anchor,
            in: &context,
            imageRect: imageRect
        )
    }

    private func annotationPath(
        tool: ScreenshotAnnotationTool,
        points: [ScreenshotAnnotationPoint],
        imageRect: ScreenshotAnnotationRect
    ) -> Path {
        guard let first = points.first else { return Path() }

        switch tool {
        case .rectangle, .ellipse:
            guard let last = points.last else { return Path() }
            let firstPoint = project(first, in: imageRect)
            let lastPoint = project(last, in: imageRect)
            let rect = CGRect(
                x: min(firstPoint.x, lastPoint.x),
                y: min(firstPoint.y, lastPoint.y),
                width: abs(lastPoint.x - firstPoint.x),
                height: abs(lastPoint.y - firstPoint.y)
            )
            if tool == .rectangle {
                return Path(
                    roundedRect: rect,
                    cornerRadius: max(4, min(rect.width, rect.height) * 0.04)
                )
            }
            return Path(ellipseIn: rect)

        case .freehand:
            var path = Path()
            path.move(to: project(first, in: imageRect))
            for point in points.dropFirst() {
                path.addLine(to: project(point, in: imageRect))
            }
            if points.count >= 3 {
                path.closeSubpath()
            }
            return path
        }
    }

    private func drawMarker(
        number: Int,
        color: ScreenshotAnnotationColor,
        anchor: ScreenshotAnnotationPoint,
        in context: inout GraphicsContext,
        imageRect: ScreenshotAnnotationRect
    ) {
        let diameter: CGFloat = 28
        let radius = diameter / 2
        let projected = project(anchor, in: imageRect)
        let center = CGPoint(
            x: min(
                max(projected.x, CGFloat(imageRect.x) + radius),
                CGFloat(imageRect.x + imageRect.width) - radius
            ),
            y: min(
                max(projected.y, CGFloat(imageRect.y) + radius),
                CGFloat(imageRect.y + imageRect.height) - radius
            )
        )
        let markerRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: diameter,
            height: diameter
        )
        let markerPath = Path(ellipseIn: markerRect)
        context.fill(markerPath, with: .color(color.swiftUIColor))
        context.stroke(markerPath, with: .color(.white), lineWidth: 2)

        let text = Text("\(number)")
            .font(.caption.bold())
            .foregroundStyle(color.prefersDarkText ? Color.black : Color.white)
        context.draw(context.resolve(text), at: center, anchor: .center)
    }

    private func normalizedBounds(
        _ points: [ScreenshotAnnotationPoint]
    ) -> ScreenshotAnnotationRect {
        let minimumX = points.map(\.x).min() ?? 0
        let maximumX = points.map(\.x).max() ?? minimumX
        let minimumY = points.map(\.y).min() ?? 0
        let maximumY = points.map(\.y).max() ?? minimumY
        return ScreenshotAnnotationRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private func project(
        _ point: ScreenshotAnnotationPoint,
        in imageRect: ScreenshotAnnotationRect
    ) -> CGPoint {
        let projected = ScreenshotAnnotationGeometry.projectedPoint(point, in: imageRect)
        return CGPoint(x: projected.x, y: projected.y)
    }
}

extension ScreenshotAnnotationColor {
    var swiftUIColor: Color {
        let components = components
        return Color(
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: components.alpha
        )
    }

    var prefersDarkText: Bool {
        self == .yellow
    }
}

extension ScreenshotAnnotationTool {
    var systemImage: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .freehand: "lasso"
        }
    }
}
#endif
