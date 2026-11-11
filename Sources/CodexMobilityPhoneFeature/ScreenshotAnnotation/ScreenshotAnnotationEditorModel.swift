#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(PhotosUI) && canImport(UIKit)
import CodexMobilityCore
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

struct PendingScreenshotAnnotation: Identifiable, Equatable {
    let id = UUID()
    let stroke: ScreenshotAnnotationStroke
}

struct ExportedScreenshotAnnotation: Identifiable {
    let id = UUID()
    let image: UIImage
    let fileURL: URL
}

enum ScreenshotAnnotationEditorError: Error, LocalizedError {
    case unreadableImage
    case pngEncodingFailed
    case noAnnotations

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "无法读取所选图片，请换一张图片重试。"
        case .pngEncodingFailed:
            "无法生成标注图片的 PNG 数据。"
        case .noAnnotations:
            "请先在截图上添加至少一条标注。"
        }
    }
}

@MainActor
@Observable
final class ScreenshotAnnotationEditorModel {
    var selectedTool: ScreenshotAnnotationTool = .rectangle
    var selectedColor: ScreenshotAnnotationColor = .red
    private(set) var sourceImage: UIImage?
    private(set) var sourceName = "应用截图"
    private(set) var marks: [ScreenshotAnnotationMark] = []
    private(set) var activePoints: [ScreenshotAnnotationPoint] = []
    private(set) var composedPreview: UIImage?
    private(set) var exportedAsset: ExportedScreenshotAnnotation?
    private(set) var isImporting = false
    private(set) var isExporting = false
    var statusMessage: String?
    var errorMessage: String?

    var hasSourceImage: Bool { sourceImage != nil }
    var canExport: Bool { sourceImage != nil && !marks.isEmpty && !isExporting }

    func importPhoto(_ item: PhotosPickerItem) async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw ScreenshotAnnotationEditorError.unreadableImage
            }
            setSourceImage(image, name: "应用截图")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSourceImage(_ image: UIImage, name: String) {
        sourceImage = ScreenshotAnnotationRenderer.normalizedImage(image)
        sourceName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "应用截图"
            : name
        marks = []
        activePoints = []
        composedPreview = nil
        exportedAsset = nil
        statusMessage = "图片已载入，请选择工具后在图上圈选。"
        errorMessage = nil
    }

    func updateGesture(at point: ScreenshotAnnotationPoint) {
        switch selectedTool {
        case .rectangle, .ellipse:
            if activePoints.isEmpty {
                activePoints = [point, point]
            } else {
                activePoints[activePoints.count - 1] = point
            }
        case .freehand:
            if let last = activePoints.last, last.distance(to: point) < 0.0025 {
                return
            }
            activePoints.append(point)
        }
    }

    func finishGesture(at point: ScreenshotAnnotationPoint) -> PendingScreenshotAnnotation? {
        updateGesture(at: point)
        defer { activePoints = [] }
        guard let stroke = ScreenshotAnnotationStroke(
            tool: selectedTool,
            color: selectedColor,
            points: activePoints
        ) else {
            statusMessage = "圈选范围太小，请重新绘制。"
            return nil
        }
        return PendingScreenshotAnnotation(stroke: stroke)
    }

    func cancelGesture() {
        activePoints = []
    }

    func commit(_ pending: PendingScreenshotAnnotation, note: String) -> Bool {
        guard let mark = ScreenshotAnnotationMark(stroke: pending.stroke, note: note) else {
            return false
        }
        marks.append(mark)
        rebuildComposedPreview()
        statusMessage = "已添加标注 \(marks.count)，拼接预览已更新。"
        return true
    }

    func updateMark(id: UUID, note: String, color: ScreenshotAnnotationColor) -> Bool {
        guard let index = marks.firstIndex(where: { $0.id == id }),
              let stroke = ScreenshotAnnotationStroke(
                tool: marks[index].stroke.tool,
                color: color,
                points: marks[index].stroke.points
              ),
              let replacement = ScreenshotAnnotationMark(
                id: marks[index].id,
                stroke: stroke,
                note: note,
                createdAt: marks[index].createdAt
              ) else {
            return false
        }
        marks[index] = replacement
        rebuildComposedPreview()
        statusMessage = "标注 \(index + 1) 已更新。"
        return true
    }

    func mark(id: UUID) -> ScreenshotAnnotationMark? {
        marks.first { $0.id == id }
    }

    func removeMark(id: UUID) {
        marks.removeAll { $0.id == id }
        rebuildComposedPreview()
        statusMessage = marks.isEmpty ? "全部标注已移除。" : "标注已移除，编号已重新排列。"
    }

    func undoLastMark() {
        guard !marks.isEmpty else { return }
        marks.removeLast()
        rebuildComposedPreview()
        statusMessage = marks.isEmpty ? "已撤销最后一条标注。" : "已撤销，拼接预览已更新。"
    }

    func clearAllMarks() {
        marks = []
        activePoints = []
        composedPreview = nil
        exportedAsset = nil
        statusMessage = "标注已清空，原图仍保留。"
    }

    func exportToFiles() {
        guard let sourceImage else {
            errorMessage = ScreenshotAnnotationEditorError.unreadableImage.localizedDescription
            return
        }
        guard !marks.isEmpty else {
            errorMessage = ScreenshotAnnotationEditorError.noAnnotations.localizedDescription
            return
        }
        isExporting = true
        defer { isExporting = false }
        do {
            let image = ScreenshotAnnotationRenderer.render(image: sourceImage, marks: marks)
            guard let data = image.pngData() else {
                throw ScreenshotAnnotationEditorError.pngEncodingFailed
            }
            let directory = try exportDirectory()
            let fileURL = directory.appendingPathComponent(exportFileName(), isDirectory: false)
            try data.write(to: fileURL, options: .atomic)
            exportedAsset = ExportedScreenshotAnnotation(image: image, fileURL: fileURL)
            composedPreview = image
            statusMessage = "已生成“原图 + 标记 + 下方注释”的 PNG。"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reportSentToMac() {
        statusMessage = "已加入发送到 Mac 的同步队列。"
    }

    func reportSyncFailure(_ message: String) {
        errorMessage = message
    }

    private func rebuildComposedPreview() {
        exportedAsset = nil
        guard let sourceImage, !marks.isEmpty else {
            composedPreview = nil
            return
        }
        composedPreview = ScreenshotAnnotationRenderer.render(image: sourceImage, marks: marks)
    }

    private func exportDirectory() throws -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = documents.appendingPathComponent("Screenshot Annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func exportFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let safeName = sourceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let uniqueSuffix = UUID().uuidString.prefix(6).lowercased()
        return "\(safeName)-标注-\(formatter.string(from: Date()))-\(uniqueSuffix).png"
    }
}
#endif
