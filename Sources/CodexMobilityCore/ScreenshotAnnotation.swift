import Foundation

public enum ScreenshotAnnotationTool: String, CaseIterable, Codable, Hashable, Sendable {
    case rectangle
    case ellipse
    case freehand

    public var displayName: String {
        switch self {
        case .rectangle: "矩形"
        case .ellipse: "圆形"
        case .freehand: "手绘圈选"
        }
    }
}

public enum ScreenshotAnnotationColor: String, CaseIterable, Codable, Hashable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple

    public var displayName: String {
        switch self {
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .purple: "紫色"
        }
    }

    public var components: ScreenshotAnnotationColorComponents {
        switch self {
        case .red:
            ScreenshotAnnotationColorComponents(red: 0.94, green: 0.19, blue: 0.19)
        case .orange:
            ScreenshotAnnotationColorComponents(red: 1.0, green: 0.49, blue: 0.08)
        case .yellow:
            ScreenshotAnnotationColorComponents(red: 1.0, green: 0.80, blue: 0.08)
        case .green:
            ScreenshotAnnotationColorComponents(red: 0.12, green: 0.72, blue: 0.33)
        case .blue:
            ScreenshotAnnotationColorComponents(red: 0.10, green: 0.47, blue: 0.95)
        case .purple:
            ScreenshotAnnotationColorComponents(red: 0.62, green: 0.30, blue: 0.91)
        }
    }
}

public struct ScreenshotAnnotationColorComponents: Codable, Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}

public struct ScreenshotAnnotationPoint: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    public func distance(to other: ScreenshotAnnotationPoint) -> Double {
        hypot(other.x - x, other.y - y)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}

public struct ScreenshotAnnotationRect: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(width, 0)
        self.height = max(height, 0)
    }
}

public struct ScreenshotAnnotationStroke: Codable, Equatable, Hashable, Sendable {
    public let tool: ScreenshotAnnotationTool
    public let color: ScreenshotAnnotationColor
    public let points: [ScreenshotAnnotationPoint]

    public init?(
        tool: ScreenshotAnnotationTool,
        color: ScreenshotAnnotationColor,
        points: [ScreenshotAnnotationPoint]
    ) {
        let normalizedPoints = Self.normalizedPoints(for: tool, points: points)
        guard Self.isMeaningful(tool: tool, points: normalizedPoints) else {
            return nil
        }
        self.tool = tool
        self.color = color
        self.points = normalizedPoints
    }

    public var bounds: ScreenshotAnnotationRect {
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

    public var markerAnchor: ScreenshotAnnotationPoint {
        ScreenshotAnnotationPoint(x: bounds.x, y: bounds.y)
    }

    private static func normalizedPoints(
        for tool: ScreenshotAnnotationTool,
        points: [ScreenshotAnnotationPoint]
    ) -> [ScreenshotAnnotationPoint] {
        switch tool {
        case .rectangle, .ellipse:
            guard let first = points.first, let last = points.last else { return [] }
            return [first, last]
        case .freehand:
            return points
        }
    }

    private static func isMeaningful(
        tool: ScreenshotAnnotationTool,
        points: [ScreenshotAnnotationPoint]
    ) -> Bool {
        switch tool {
        case .rectangle, .ellipse:
            guard points.count == 2 else { return false }
            return abs(points[1].x - points[0].x) >= 0.008
                && abs(points[1].y - points[0].y) >= 0.008
        case .freehand:
            guard points.count >= 3 else { return false }
            let travelled = zip(points, points.dropFirst()).reduce(0.0) { partial, pair in
                partial + pair.0.distance(to: pair.1)
            }
            return travelled >= 0.02
        }
    }
}

public struct ScreenshotAnnotationMark: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var stroke: ScreenshotAnnotationStroke
    public var note: String
    public let createdAt: Date

    public init?(
        id: UUID = UUID(),
        stroke: ScreenshotAnnotationStroke,
        note: String,
        createdAt: Date = Date()
    ) {
        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedNote.isEmpty else { return nil }
        self.id = id
        self.stroke = stroke
        self.note = normalizedNote
        self.createdAt = createdAt
    }
}

public struct ScreenshotAnnotationDocument: Codable, Equatable, Sendable {
    public var sourcePixelWidth: Int
    public var sourcePixelHeight: Int
    public var marks: [ScreenshotAnnotationMark]

    public init(
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        marks: [ScreenshotAnnotationMark] = []
    ) {
        self.sourcePixelWidth = max(sourcePixelWidth, 1)
        self.sourcePixelHeight = max(sourcePixelHeight, 1)
        self.marks = marks
    }
}

public enum ScreenshotAnnotationGeometry {
    public static func aspectFitRect(
        imageWidth: Double,
        imageHeight: Double,
        containerWidth: Double,
        containerHeight: Double
    ) -> ScreenshotAnnotationRect {
        guard imageWidth.isFinite,
              imageHeight.isFinite,
              containerWidth.isFinite,
              containerHeight.isFinite,
              imageWidth > 0,
              imageHeight > 0,
              containerWidth > 0,
              containerHeight > 0 else {
            return ScreenshotAnnotationRect(x: 0, y: 0, width: 0, height: 0)
        }
        let scale = min(containerWidth / imageWidth, containerHeight / imageHeight)
        let width = imageWidth * scale
        let height = imageHeight * scale
        return ScreenshotAnnotationRect(
            x: (containerWidth - width) / 2,
            y: (containerHeight - height) / 2,
            width: width,
            height: height
        )
    }

    public static func normalizedPoint(
        x: Double,
        y: Double,
        in rect: ScreenshotAnnotationRect,
        clamped: Bool = false
    ) -> ScreenshotAnnotationPoint? {
        guard rect.width > 0, rect.height > 0, x.isFinite, y.isFinite else { return nil }
        let normalizedX = (x - rect.x) / rect.width
        let normalizedY = (y - rect.y) / rect.height
        if !clamped
            && (!(0...1).contains(normalizedX) || !(0...1).contains(normalizedY)) {
            return nil
        }
        return ScreenshotAnnotationPoint(x: normalizedX, y: normalizedY)
    }

    public static func projectedPoint(
        _ point: ScreenshotAnnotationPoint,
        in rect: ScreenshotAnnotationRect
    ) -> (x: Double, y: Double) {
        (
            x: rect.x + point.x * rect.width,
            y: rect.y + point.y * rect.height
        )
    }
}
