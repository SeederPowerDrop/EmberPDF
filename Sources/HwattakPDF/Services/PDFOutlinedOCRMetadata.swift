// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

enum PDFOCRTextEncoding: String, Codable {
    case utf16BE, ascii
}

/// Versioned editor state for our isolated scan outlines. This is a bounded
/// wire format, not proof of ownership: the target resolver independently
/// checks the Form, its unique invocation and its native text/geometry.
struct PDFOutlinedOCRMetadata: Equatable {
    static let maximumBytes = 1_024 * 1_024
    let id: UUID
    let text: String
    let style: InlineTextStyle
    let bounds: CGRect
    let baseline: CGPoint
    let lineHeight: CGFloat?
    let firstLineIndent: CGFloat
    let sourceRuns: [InlineTextSourceRun]
    let erasedRects: [CGRect]
    let paperColor: PDFTextColor
    let semanticFontName: String
    let semanticEncoding: PDFOCRTextEncoding
    let semanticDefaultWidth: CGFloat
    let semanticLineMatrices: [CGAffineTransform]
    let semanticLineFontSizes: [CGFloat]
    let semanticLineWidths: [CGFloat]

    enum Failure: Error { case invalid, tooLarge }

    init(id: UUID = UUID(), text: String, style: InlineTextStyle, bounds: CGRect,
         baseline: CGPoint, lineHeight: CGFloat?, firstLineIndent: CGFloat,
         sourceRuns: [InlineTextSourceRun], erasedRects: [CGRect], paperColor: PDFTextColor,
         semanticFontName: String, semanticEncoding: PDFOCRTextEncoding,
         semanticDefaultWidth: CGFloat, semanticLineMatrices: [CGAffineTransform],
         semanticLineFontSizes: [CGFloat], semanticLineWidths: [CGFloat]) throws {
        self.id = id; self.text = text; self.style = style; self.bounds = bounds
        self.baseline = baseline; self.lineHeight = lineHeight; self.firstLineIndent = firstLineIndent
        self.sourceRuns = sourceRuns; self.erasedRects = erasedRects; self.paperColor = paperColor
        self.semanticFontName = semanticFontName; self.semanticEncoding = semanticEncoding
        self.semanticDefaultWidth = semanticDefaultWidth
        self.semanticLineMatrices = semanticLineMatrices; self.semanticLineFontSizes = semanticLineFontSizes
        self.semanticLineWidths = semanticLineWidths
        try validate()
    }

    func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Wire(self))
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.tooLarge }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.version == 1, wire.sourceRuns.count <= 2_048,
              wire.erasedRects.count <= 64, wire.semanticLineMatrices.count <= 64,
              wire.semanticLineFontSizes.count <= 64, wire.semanticLineWidths.count <= 64 else { throw Failure.invalid }
        return try Self(id: wire.id, text: wire.text, style: wire.style.value(), bounds: wire.bounds.value,
            baseline: CGPoint(x: wire.baselineX, y: wire.baselineY), lineHeight: wire.lineHeight.map { CGFloat($0) },
            firstLineIndent: CGFloat(wire.firstLineIndent), sourceRuns: wire.sourceRuns.map { try $0.value() },
            erasedRects: wire.erasedRects.map(\.value), paperColor: color(wire.paperColor, alpha: 1),
            semanticFontName: wire.semanticFontName, semanticEncoding: wire.semanticEncoding,
            semanticDefaultWidth: CGFloat(wire.semanticDefaultWidth),
            semanticLineMatrices: wire.semanticLineMatrices.map(\.value),
            semanticLineFontSizes: wire.semanticLineFontSizes.map { CGFloat($0) },
            semanticLineWidths: wire.semanticLineWidths.map { CGFloat($0) })
    }

    private func validate() throws {
        guard !text.isEmpty, !InlineTextDraftLimiter.limit(text).wasTruncated,
              text.utf8.count <= Self.maximumBytes, Self.valid(bounds),
              baseline.x.isFinite, baseline.y.isFinite,
              abs(baseline.x) <= 1_000_000, abs(baseline.y) <= 1_000_000,
              lineHeight.map({ $0.isFinite && $0 > 0 && $0 <= 1_000_000 }) ?? true,
              firstLineIndent.isFinite, abs(firstLineIndent) <= 1_000_000,
              !erasedRects.isEmpty, erasedRects.count <= 64, erasedRects.allSatisfy(Self.valid),
              sourceRuns.count <= 2_048, !semanticFontName.isEmpty, semanticFontName.utf8.count <= 128,
              semanticFontName.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "_.+-".unicodeScalars.contains($0)
              }), semanticDefaultWidth.isFinite, semanticDefaultWidth > 0,
              semanticDefaultWidth <= 100_000,
              !semanticLineMatrices.isEmpty, semanticLineMatrices.count <= 64,
              semanticLineMatrices.count == semanticLineFontSizes.count,
              semanticLineMatrices.count == semanticLineWidths.count,
              semanticLineWidths.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1_000_000 }) else { throw Failure.invalid }
        for (matrix, size) in zip(semanticLineMatrices, semanticLineFontSizes) {
            guard [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty, size].allSatisfy({
                $0.isFinite && abs($0) <= 1_000_000
            }), matrix.a > 0, matrix.d > 0, abs(matrix.b) < 0.001, abs(matrix.c) < 0.001,
            size > 0, (InlineTextStyle.minimumFontSize...InlineTextStyle.maximumFontSize).contains(size * matrix.d)
            else { throw Failure.invalid }
        }
        if semanticEncoding == .ascii, !text.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            throw Failure.invalid
        }
        _ = try Style(style).value()
        _ = try Self.color(Self.components(paperColor), alpha: 1)
        let units = Array(text.utf16)
        func boundary(_ offset: Int) -> Bool {
            offset == 0 || offset == units.count
                || !((0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset]))
        }
        var end = 0
        for run in sourceRuns {
            let range = run.range
            guard range.location >= end, range.location <= units.count, range.length > 0,
                  range.length <= units.count - range.location,
                  boundary(range.location), boundary(NSMaxRange(range)),
                  run.baselineOffset.isFinite, abs(run.baselineOffset) <= 1_000_000,
                  run.horizontalAdvance.map({ $0.isFinite && $0 > 0 && $0 <= 1_000_000 }) ?? true,
                  units[end..<range.location].allSatisfy({
                      UnicodeScalar($0).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
                  }) else { throw Failure.invalid }
            _ = try Style(run.style).value()
            end = NSMaxRange(range)
        }
        if !sourceRuns.isEmpty, !units[end...].allSatisfy({
            UnicodeScalar($0).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }) { throw Failure.invalid }
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy {
            $0.isFinite && abs($0) <= 1_000_000
        }
    }

    private static func components(_ color: PDFTextColor) -> [Double] {
        [color.red, color.green, color.blue, color.alpha].map(Double.init)
    }

    private static func color(_ values: [Double], alpha: Double) throws -> PDFTextColor {
        guard values.count == 4, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(values[3] - alpha) < 0.000001 else { throw Failure.invalid }
        return PDFTextColor(red: CGFloat(values[0]), green: CGFloat(values[1]), blue: CGFloat(values[2]), alpha: CGFloat(values[3]))
    }

    private struct Rectangle: Codable {
        let x: Double, y: Double, width: Double, height: Double
        init(_ rect: CGRect) { x = Double(rect.minX); y = Double(rect.minY); width = Double(rect.width); height = Double(rect.height) }
        var value: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    private struct Matrix: Codable {
        let a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
        init(_ value: CGAffineTransform) {
            a = Double(value.a); b = Double(value.b); c = Double(value.c); d = Double(value.d)
            tx = Double(value.tx); ty = Double(value.ty)
        }
        var value: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
    }

    private struct Style: Codable {
        let fontName: String, fontSize: Double, textColor: [Double], backgroundColor: [Double]
        let alignment: Int, horizontalScale: Double
        init(_ style: InlineTextStyle) {
            fontName = style.fontName; fontSize = Double(style.fontSize)
            textColor = components(style.textColor); backgroundColor = components(style.backgroundColor)
            alignment = style.alignment.rawValue; horizontalScale = Double(style.horizontalScale)
        }
        func value() throws -> InlineTextStyle {
            guard !fontName.isEmpty, fontName.utf8.count <= 256,
                  !fontName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  fontSize.isFinite, (Double(InlineTextStyle.minimumFontSize)...Double(InlineTextStyle.maximumFontSize)).contains(fontSize),
                  horizontalScale.isFinite, (0.1...10).contains(horizontalScale),
                  let resolved = NSTextAlignment(rawValue: alignment), [.left, .center, .right].contains(resolved) else { throw Failure.invalid }
            return try InlineTextStyle(fontName: fontName, fontSize: CGFloat(fontSize), textColor: color(textColor, alpha: 1),
                backgroundColor: color(backgroundColor, alpha: 0), alignment: resolved, horizontalScale: CGFloat(horizontalScale))
        }
    }

    private struct Run: Codable {
        let location: Int, length: Int, style: Style, baselineOffset: Double, horizontalAdvance: Double?
        init(_ run: InlineTextSourceRun) {
            location = run.range.location; length = run.range.length; style = Style(run.style)
            baselineOffset = Double(run.baselineOffset); horizontalAdvance = run.horizontalAdvance.map(Double.init)
        }
        func value() throws -> InlineTextSourceRun {
            try InlineTextSourceRun(range: NSRange(location: location, length: length), style: style.value(),
                baselineOffset: CGFloat(baselineOffset), horizontalAdvance: horizontalAdvance.map { CGFloat($0) })
        }
    }

    private struct Wire: Codable {
        let version: Int, id: UUID, text: String, style: Style, bounds: Rectangle
        let baselineX: Double, baselineY: Double, lineHeight: Double?, firstLineIndent: Double
        let sourceRuns: [Run], erasedRects: [Rectangle], paperColor: [Double]
        let semanticFontName: String, semanticEncoding: PDFOCRTextEncoding, semanticDefaultWidth: Double
        let semanticLineMatrices: [Matrix], semanticLineFontSizes: [Double], semanticLineWidths: [Double]
        init(_ source: PDFOutlinedOCRMetadata) {
            version = 1; id = source.id; text = source.text; style = Style(source.style); bounds = Rectangle(source.bounds)
            baselineX = Double(source.baseline.x); baselineY = Double(source.baseline.y)
            lineHeight = source.lineHeight.map(Double.init); firstLineIndent = Double(source.firstLineIndent)
            sourceRuns = source.sourceRuns.map(Run.init); erasedRects = source.erasedRects.map(Rectangle.init)
            paperColor = components(source.paperColor); semanticFontName = source.semanticFontName
            semanticEncoding = source.semanticEncoding; semanticDefaultWidth = Double(source.semanticDefaultWidth)
            semanticLineMatrices = source.semanticLineMatrices.map(Matrix.init)
            semanticLineFontSizes = source.semanticLineFontSizes.map(Double.init)
            semanticLineWidths = source.semanticLineWidths.map(Double.init)
        }
    }
}

/// A whole owned Form transaction. Replacement verifies the same immutable
/// page snapshot before removing its sole invocation and painting new text.
struct PDFOutlinedOCRSource {
    let snapshot: Data
    let metadata: PDFOutlinedOCRMetadata
    let resourceName: String
    let formRootIndex: Int
    let showRange: Range<Int>
    let insertionOffset: Int
    let transform: CGAffineTransform
}
