// SPDX-License-Identifier: MPL-2.0

import AppKit

enum PDFInkShape: String, Codable, CaseIterable, Identifiable {
    case freehand, line, rectangle, ellipse
    var id: String { rawValue }
    var title: String { L10n.string("pen.shape.\(rawValue)") }
    var symbol: String {
        switch self {
        case .freehand: "pencil.tip"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        }
    }
}

enum PDFInkPattern: String, Codable, CaseIterable, Identifiable {
    case solid, dashed
    var id: String { rawValue }
    var title: String { L10n.string("pen.pattern.\(rawValue)") }
}

enum PDFHighlighterTip: String, Codable, CaseIterable, Identifiable {
    case square, round
    var id: String { rawValue }
    var title: String { L10n.string("pen.tip.\(rawValue)") }
}

/// Shape is resolved once into page-space points. It is never reapplied to
/// saved or erased fragments, so an erased rectangle cannot close itself.
struct PDFInkDrawingOptions: Codable, Equatable {
    var shape: PDFInkShape = .freehand
    var pattern: PDFInkPattern = .solid
    var highlighterTip: PDFHighlighterTip = .square

    var requiresCustomAppearance: Bool { self != PDFInkDrawingOptions() }
}

/// Dash dimensions and phase belong to the original stroke, not its surviving
/// fragments. Keeping them in page units prevents erasing from moving dashes.
struct PDFInkDash: Codable, Equatable {
    var length: CGFloat
    var phase: CGFloat = 0
    var gap: CGFloat { length * 0.65 }
    var period: CGFloat { length + gap }
    var isValid: Bool {
        length.isFinite && length > 0 && length <= 4_096
            && phase.isFinite && phase >= 0 && phase < period
    }

    func advanced(by distance: CGFloat) -> PDFInkDash {
        PDFInkDash(length: length, phase: (phase + distance).truncatingRemainder(dividingBy: period))
    }

    func scaled(by scale: CGFloat) -> PDFInkDash {
        PDFInkDash(length: length * scale, phase: phase * scale)
    }
}
