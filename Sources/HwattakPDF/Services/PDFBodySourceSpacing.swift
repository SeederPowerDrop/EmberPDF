// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText

/// A native PDF show can use nominal glyph advances without CoreText's
/// automatic kerning. Retain that spacing only when every original glyph
/// origin proves it, and CoreText's default spacing is materially different.
@MainActor
enum PDFBodySourceSpacing {
    static let preservedKerningAttribute = NSAttributedString.Key("EmberPDFSourceUnkernedAdvances")
    static let maximumGlyphs = 4096
    static let originTolerance: CGFloat = 0.01
    struct Sample {
        let scalar: UInt32
        let origin: CGPoint
        let matrix: CGAffineTransform
        let generated: Bool
    }
    struct Evidence {
        let unkernedMaximumError: CGFloat
        let defaultMaximumError: CGFloat
    }

    static func evidence(text: String, samples: [Sample], availableFont: NSFont?) -> Evidence? {
        guard let availableFont, samples.count >= 2, samples.count <= maximumGlyphs,
              text.utf16.count == samples.count, text.unicodeScalars.count == samples.count,
              text.unicodeScalars.map(\.value) == samples.map(\.scalar),
              samples.allSatisfy({ !$0.generated && $0.scalar >= 0x20 && $0.scalar != 0x7F }),
              let first = samples.first else { return nil }
        let sourceMatrix = first.matrix
        guard horizontal(sourceMatrix), first.origin.x.isFinite, first.origin.y.isFinite,
              samples.allSatisfy({ $0.matrix == sourceMatrix && $0.origin.x.isFinite && $0.origin.y.isFinite }),
              zip(samples, samples.dropFirst()).allSatisfy({ $0.origin.x <= $1.origin.x }) else { return nil }
        let expected = samples.map { CGPoint(x: $0.origin.x - first.origin.x, y: $0.origin.y - first.origin.y) }
        guard expected.allSatisfy({ abs($0.y) <= originTolerance }),
              let natural = origins(text: text, font: availableFont as CTFont, zeroKerning: false),
              natural.count == expected.count else { return nil }
        func error(_ actual: [CGPoint]) -> CGFloat {
            zip(actual, expected).reduce(0) { max($0, max(abs($1.0.x - $1.1.x), abs($1.0.y - $1.1.y))) }
        }
        let defaultError = error(natural)
        guard defaultError > 0.05,
              let zero = origins(text: text, font: availableFont as CTFont, zeroKerning: true),
              zero.count == expected.count else { return nil }
        let zeroError = error(zero)
        guard zeroError <= originTolerance, defaultError - zeroError > 0.04 else { return nil }
        return Evidence(unkernedMaximumError: zeroError, defaultMaximumError: defaultError)
    }

    static func fontMatches(_ actual: NSFont, _ source: NSFont) -> Bool {
        CTFontCopyGraphicsFont(actual as CTFont, nil) === CTFontCopyGraphicsFont(source as CTFont, nil)
            && actual.pointSize == source.pointSize
            && CTFontGetMatrix(actual as CTFont) == CTFontGetMatrix(source as CTFont)
    }

    private static func horizontal(_ matrix: CGAffineTransform) -> Bool {
        [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].allSatisfy(\.isFinite)
            && matrix.a > 0 && matrix.d > 0 && matrix.b == 0 && matrix.c == 0
            && matrix.tx == 0 && matrix.ty == 0
    }

    private static func origins(text: String, font: CTFont, zeroKerning: Bool) -> [CGPoint]? {
        let units = Array(text.utf16)
        guard units.count <= maximumGlyphs, CTFontGetSize(font).isFinite, CTFontGetSize(font) > 0,
              horizontal(CTFontGetMatrix(font)) else { return nil }
        var mapped = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &mapped, units.count), mapped.allSatisfy({ $0 != 0 }) else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if zeroKerning { attributes[.kern] = NSNumber(value: 0) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        guard runs.count == 1, let run = runs.first,
              CTRunGetStatus(run).rawValue & 3 == 0,
              CTRunGetGlyphCount(run) == units.count else { return nil }
        let range = CTRunGetStringRange(run), matrix = CTRunGetTextMatrix(run)
        let raw = CTRunGetAttributes(run) as NSDictionary
        guard range.location == 0, range.length == units.count,
              matrix == CTFontGetMatrix(font), horizontal(matrix),
              let value = raw[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { return nil }
        let runFont = value as! CTFont
        guard CTFontCopyGraphicsFont(runFont, nil) === CTFontCopyGraphicsFont(font, nil),
              CTFontGetSize(runFont) == CTFontGetSize(font), CTFontGetMatrix(runFont) == CTFontGetMatrix(font) else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        var indices = [CFIndex](repeating: 0, count: units.count)
        var positions = [CGPoint](repeating: .zero, count: units.count)
        CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetStringIndices(run, CFRange(), &indices)
        CTRunGetPositions(run, CFRange(), &positions)
        guard glyphs == mapped, indices == Array(0..<units.count) else { return nil }
        let placed = positions.map { $0.applying(matrix) }
        guard placed.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.y) <= originTolerance }),
              zip(placed, placed.dropFirst()).allSatisfy({ $0.x <= $1.x }) else { return nil }
        return placed
    }
}
