// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

enum PDFEraserMode: String, CaseIterable {
    case stroke, partial
    var alternate: Self { self == .stroke ? .partial : .stroke }
}

/// Keeps the original page order until mouse-up, so a continuous drag takes
/// one Undo. Save/tab-switch settles this transaction through the view hook.
@MainActor
final class PDFEraserGesture {
    private weak var workspace: PDFWorkspaceState?
    let page: PDFPage
    private let document: PDFDocument
    private let original: [PDFAnnotation]
    private var expected: [PDFAnnotation]
    private(set) var isFinished = false

    init?(workspace: PDFWorkspaceState, page: PDFPage) {
        guard workspace.activeTool == .eraser, workspace.allows(.markup),
              let document = workspace.document, document.index(for: page) != NSNotFound else { return nil }
        workspace.prepareForDeactivation()
        guard workspace.pendingInlineTextEdit == nil, workspace.activeTool == .eraser,
              workspace.allows(.markup), workspace.document === document else { return nil }
        self.workspace = workspace
        self.page = page
        self.document = document
        original = page.annotations
        expected = original
    }

    @discardableResult
    func erase(from start: CGPoint, to end: CGPoint, radius: CGFloat, mode: PDFEraserMode) -> Bool {
        guard !isFinished, let workspace, workspace.document === document,
              document.index(for: page) != NSNotFound,
              workspace.activeTool == .eraser, workspace.allows(.markup),
              start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
              radius.isFinite, radius > 0,
              matches(page.annotations, expected) else { return false }
        let radius = min(24, max(1, radius))
        let sweep = CGRect(x: min(start.x, end.x) - radius, y: min(start.y, end.y) - radius,
                           width: abs(start.x - end.x) + 2 * radius, height: abs(start.y - end.y) + 2 * radius)
        var final: [PDFAnnotation] = []
        var changed = false
        for annotation in expected {
            guard annotation.shouldDisplay, annotation.bounds.intersects(sweep) else {
                final.append(annotation); continue
            }
            let result = PDFInkPartialEraser.replacements(for: annotation, from: start, to: end, radius: radius)
            switch result {
            case .replaced(let fragments):
                // The user explicitly erases pen geometry. Standard Ink and
                // validated appearance-backed pen geometry are supported even
                // after reopening; unrelated stamps/images remain excluded.
                guard workspace.mode == .editing || workspace.mode == .study else {
                    final.append(annotation); continue
                }
                if mode == .partial {
                    final.append(contentsOf: fragments)
                }
                changed = true
            case .unchanged:
                final.append(annotation)
            case .unsupported:
                // Whole-object erasing retains the existing stricter policy
                // for notes, marks, images and signatures. Partial never
                // silently falls back to deleting a whole unsupported object.
                if mode == .stroke, workspace.allowsEraserRemoval(of: annotation),
                   segmentIntersects(annotation.bounds.insetBy(dx: -radius, dy: -radius), start, end) {
                    changed = true
                } else { final.append(annotation) }
            }
        }
        guard changed else { return false }
        page.annotations.forEach(page.removeAnnotation)
        final.forEach(page.addAnnotation)
        expected = page.annotations
        return true
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        guard let workspace, workspace.document === document,
              document.index(for: page) != NSNotFound, matches(page.annotations, expected) else { return }
        workspace.registerEraserGesture(on: page, from: original, to: expected)
    }

    private func matches(_ lhs: [PDFAnnotation], _ rhs: [PDFAnnotation]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 === $1 }
    }

    private func segmentIntersects(_ rect: CGRect, _ start: CGPoint, _ end: CGPoint) -> Bool {
        var lower: CGFloat = 0, upper: CGFloat = 1
        for (origin, delta, minimum, maximum) in [
            (start.x, end.x - start.x, rect.minX, rect.maxX),
            (start.y, end.y - start.y, rect.minY, rect.maxY)
        ] {
            if abs(delta) < 0.000_001 {
                if origin < minimum || origin > maximum { return false }
            } else {
                let a = (minimum - origin) / delta, b = (maximum - origin) / delta
                lower = max(lower, min(a, b)); upper = min(upper, max(a, b))
                if lower > upper { return false }
            }
        }
        return true
    }
}
