#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(UIKit)
import CodexMobilityCore
import UIKit

@MainActor
enum ScreenshotAnnotationRenderer {
    static func render(
        image: UIImage,
        marks: [ScreenshotAnnotationMark]
    ) -> UIImage {
        let sourceImage = normalizedImage(image)
        let sourceWidth = max(sourceImage.cgImage?.width ?? Int(sourceImage.size.width), 1)
        let sourceHeight = max(sourceImage.cgImage?.height ?? Int(sourceImage.size.height), 1)
        let canvasWidth = CGFloat(sourceWidth)
        let canvasHeight = CGFloat(sourceHeight)
        let metrics = notePanelMetrics(width: canvasWidth, marks: marks)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let outputSize = CGSize(width: canvasWidth, height: canvasHeight + metrics.totalHeight)
        let renderer = UIGraphicsImageRenderer(
            size: outputSize,
            format: format
        )
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            sourceImage.draw(in: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
            drawMarks(marks, in: context.cgContext, size: CGSize(width: canvasWidth, height: canvasHeight))
            drawNotes(
                marks,
                metrics: metrics,
                originY: canvasHeight,
                in: context.cgContext,
                width: canvasWidth
            )
        }
    }

    static func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private struct NotePanelMetrics {
        let padding: CGFloat
        let titleFont: UIFont
        let bodyFont: UIFont
        let badgeDiameter: CGFloat
        let rowSpacing: CGFloat
        let headerHeight: CGFloat
        let rowHeights: [CGFloat]
        let totalHeight: CGFloat
    }

    private static func notePanelMetrics(
        width: CGFloat,
        marks: [ScreenshotAnnotationMark]
    ) -> NotePanelMetrics {
        let padding = max(28, width * 0.035)
        let titleFont = UIFont.systemFont(ofSize: max(30, width * 0.029), weight: .bold)
        let bodyFont = UIFont.systemFont(ofSize: max(24, width * 0.024), weight: .regular)
        let badgeDiameter = max(34, width * 0.035)
        let rowSpacing = max(20, width * 0.022)
        let headerHeight = titleFont.lineHeight + padding * 1.35
        let textWidth = max(width - padding * 2 - badgeDiameter - padding * 0.45, 1)
        let rowHeights = marks.map { mark in
            let textHeight = (mark.note as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: bodyFont],
                context: nil
            ).integral.height
            return max(textHeight, badgeDiameter)
        }
        let rowsHeight = rowHeights.reduce(0, +)
            + rowSpacing * CGFloat(max(rowHeights.count - 1, 0))
        let emptyHeight = marks.isEmpty ? bodyFont.lineHeight : 0
        return NotePanelMetrics(
            padding: padding,
            titleFont: titleFont,
            bodyFont: bodyFont,
            badgeDiameter: badgeDiameter,
            rowSpacing: rowSpacing,
            headerHeight: headerHeight,
            rowHeights: rowHeights,
            totalHeight: headerHeight + padding + rowsHeight + emptyHeight + padding
        )
    }

    private static func drawMarks(
        _ marks: [ScreenshotAnnotationMark],
        in context: CGContext,
        size: CGSize
    ) {
        let coloredWidth = max(5, size.width * 0.006)
        for (offset, mark) in marks.enumerated() {
            let path = path(for: mark.stroke, size: size)
            context.saveGState()
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(coloredWidth + max(4, size.width * 0.003))
            context.addPath(path.cgPath)
            context.strokePath()

            context.setStrokeColor(UIColor(mark.stroke.color).cgColor)
            context.setLineWidth(coloredWidth)
            context.addPath(path.cgPath)
            context.strokePath()
            context.restoreGState()

            drawMarker(
                number: offset + 1,
                color: mark.stroke.color,
                anchor: mark.stroke.markerAnchor,
                size: size,
                in: context
            )
        }
    }

    private static func path(
        for stroke: ScreenshotAnnotationStroke,
        size: CGSize
    ) -> UIBezierPath {
        let path = UIBezierPath()
        switch stroke.tool {
        case .rectangle, .ellipse:
            let bounds = stroke.bounds
            let rect = CGRect(
                x: bounds.x * size.width,
                y: bounds.y * size.height,
                width: bounds.width * size.width,
                height: bounds.height * size.height
            )
            return stroke.tool == .rectangle
                ? UIBezierPath(roundedRect: rect, cornerRadius: max(4, size.width * 0.004))
                : UIBezierPath(ovalIn: rect)
        case .freehand:
            guard let first = stroke.points.first else { return path }
            path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
            for point in stroke.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
            }
            path.close()
            return path
        }
    }

    private static func drawMarker(
        number: Int,
        color: ScreenshotAnnotationColor,
        anchor: ScreenshotAnnotationPoint,
        size: CGSize,
        in context: CGContext
    ) {
        let diameter = max(34, size.width * 0.045)
        let radius = diameter / 2
        let center = CGPoint(
            x: min(max(anchor.x * size.width, radius), size.width - radius),
            y: min(max(anchor.y * size.height, radius), size.height - radius)
        )
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: diameter,
            height: diameter
        )
        context.saveGState()
        context.setFillColor(UIColor(color).cgColor)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(max(3, size.width * 0.0025))
        context.addEllipse(in: rect)
        context.drawPath(using: .fillStroke)
        context.restoreGState()

        let font = UIFont.systemFont(ofSize: diameter * 0.54, weight: .bold)
        let text = "\(number)" as NSString
        let textSize = text.size(withAttributes: [.font: font])
        text.draw(
            at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2),
            withAttributes: [
                .font: font,
                .foregroundColor: color.prefersDarkLabel ? UIColor.black : UIColor.white,
            ]
        )
    }

    private static func drawNotes(
        _ marks: [ScreenshotAnnotationMark],
        metrics: NotePanelMetrics,
        originY: CGFloat,
        in context: CGContext,
        width: CGFloat
    ) {
        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: originY, width: width, height: metrics.totalHeight))
        context.setFillColor(UIColor(white: 0.86, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: originY, width: width, height: max(2, width * 0.002)))
        context.restoreGState()

        let title = "Codex Watch Pet · 截图修改说明" as NSString
        title.draw(
            at: CGPoint(x: metrics.padding, y: originY + metrics.padding * 0.65),
            withAttributes: [
                .font: metrics.titleFont,
                .foregroundColor: UIColor.black,
            ]
        )

        var rowY = originY + metrics.headerHeight
        if marks.isEmpty {
            ("暂无标注" as NSString).draw(
                at: CGPoint(x: metrics.padding, y: rowY + metrics.padding),
                withAttributes: [
                    .font: metrics.bodyFont,
                    .foregroundColor: UIColor.darkGray,
                ]
            )
            return
        }

        let textX = metrics.padding + metrics.badgeDiameter + metrics.padding * 0.45
        let textWidth = width - textX - metrics.padding
        for (offset, mark) in marks.enumerated() {
            let rowHeight = metrics.rowHeights[offset]
            let badgeRect = CGRect(
                x: metrics.padding,
                y: rowY,
                width: metrics.badgeDiameter,
                height: metrics.badgeDiameter
            )
            UIColor(mark.stroke.color).setFill()
            UIBezierPath(ovalIn: badgeRect).fill()

            let badgeFont = UIFont.systemFont(
                ofSize: metrics.badgeDiameter * 0.52,
                weight: .bold
            )
            let badgeText = "\(offset + 1)" as NSString
            let badgeSize = badgeText.size(withAttributes: [.font: badgeFont])
            badgeText.draw(
                at: CGPoint(
                    x: badgeRect.midX - badgeSize.width / 2,
                    y: badgeRect.midY - badgeSize.height / 2
                ),
                withAttributes: [
                    .font: badgeFont,
                    .foregroundColor: mark.stroke.color.prefersDarkLabel
                        ? UIColor.black
                        : UIColor.white,
                ]
            )

            (mark.note as NSString).draw(
                with: CGRect(x: textX, y: rowY, width: textWidth, height: rowHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: metrics.bodyFont,
                    .foregroundColor: UIColor.black,
                ],
                context: nil
            )
            rowY += rowHeight + metrics.rowSpacing
        }
    }
}

private extension UIColor {
    convenience init(_ color: ScreenshotAnnotationColor) {
        let components = color.components
        self.init(
            red: CGFloat(components.red),
            green: CGFloat(components.green),
            blue: CGFloat(components.blue),
            alpha: CGFloat(components.alpha)
        )
    }
}

private extension ScreenshotAnnotationColor {
    var prefersDarkLabel: Bool {
        self == .yellow
    }
}
#endif
