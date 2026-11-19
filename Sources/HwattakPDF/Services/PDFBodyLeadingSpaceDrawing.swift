// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText

/// Draw an unchanged positioned source space with its visible run, so PDF
/// text extraction keeps that logical space through a cold save and re-edit.
/// The existing font and placed glyphs are used without font registration.
@MainActor
enum PDFBodyLeadingSpaceDrawing {
    static let preservedAdvanceAttribute = NSAttributedString.Key("EmberPDFPreservedLeadingSpaceAdvance")
    struct Plan {
        let font: CTFont
        let color: CGColor
        let glyphs: [CGGlyph]
        let positions: [CGPoint]

        func draw(in context: CGContext, origin: CGPoint) throws {
            try Task.checkCancellation()
            let absolute = positions.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = .zero
            context.setFillColor(color)
            CTFontDrawGlyphs(font, glyphs, absolute, glyphs.count, context)
            context.restoreGState()
        }
    }

    static func make(line: CTLine, text: NSAttributedString) throws -> Plan? {
        try Task.checkCancellation()
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        // More complex lines retain CoreText's existing complete-line draw.
        guard runs.count == 2 else { return nil }
        let space = runs[0], following = runs[1]
        let left = CTRunGetStringRange(space), right = CTRunGetStringRange(following)
        let lineRange = CTLineGetStringRange(line)
        guard left.location == lineRange.location, left.length == 1,
              right.location == left.location + left.length, right.length > 0, right.length <= 4095,
              left.location >= 0, right.location >= 0,
              right.location <= text.length, right.length <= text.length - right.location else { return nil }
        let prefix = (text.string as NSString).substring(with: NSRange(location: left.location, length: left.length))
        let visible = (text.string as NSString).substring(with: NSRange(location: right.location, length: right.length))
        guard prefix.utf16.allSatisfy({ $0 == 0x20 }),
              visible.unicodeScalars.first.map({ !CharacterSet.whitespacesAndNewlines.contains($0) }) == true,
              !visible.contains("\n"), !visible.contains("\r") else { return nil }
        let a = CTRunGetAttributes(space) as NSDictionary, b = CTRunGetAttributes(following) as NSDictionary
        guard let receipt = a[preservedAdvanceAttribute] as? NSNumber,
              receipt.doubleValue.isFinite, receipt.doubleValue > 0 else { return nil }
        let allowed = Set([NSAttributedString.Key.font.rawValue,
            NSAttributedString.Key.foregroundColor.rawValue,
            NSAttributedString.Key.baselineOffset.rawValue,
            NSAttributedString.Key.paragraphStyle.rawValue,
            NSAttributedString.Key.kern.rawValue,
            PDFBodySourceSpacing.preservedKerningAttribute.rawValue,
            preservedAdvanceAttribute.rawValue])
        // Explicit zero kerning changes only the already-verified positions;
        // nonzero spacing or an unmodeled draw attribute keeps the old route.
        for attributes in [a, b] {
            if let kerning = attributes[NSAttributedString.Key.kern] {
                guard let amount = kerning as? NSNumber, amount.doubleValue == 0,
                      (attributes[PDFBodySourceSpacing.preservedKerningAttribute] as? NSNumber)?.boolValue == true else { return nil }
            }
            guard attributes.allKeys.allSatisfy({ key in
                (key as? String).map(allowed.contains) ?? false
            }) else { return nil }
        }
        guard let af = a[kCTFontAttributeName], let bf = b[kCTFontAttributeName],
              CFGetTypeID(af as CFTypeRef) == CTFontGetTypeID(),
              CFGetTypeID(bf as CFTypeRef) == CTFontGetTypeID(),
              let ac = a[NSAttributedString.Key.foregroundColor] as? NSColor,
              let bc = b[NSAttributedString.Key.foregroundColor] as? NSColor,
              ac.cgColor == bc.cgColor else { return nil }
        let firstFont = af as! CTFont, font = bf as! CTFont
        let firstGraphics = CTFontCopyGraphicsFont(firstFont, nil), graphics = CTFontCopyGraphicsFont(font, nil)
        // Real CGFont object identity; never authorize by PostScript name.
        guard firstGraphics === graphics, CTFontGetSize(firstFont) == CTFontGetSize(font),
              CTFontGetSize(font).isFinite, CTFontGetSize(font) > 0,
              receipt.doubleValue <= Double(min(256, max(48, CTFontGetSize(font) * 8))),
              CTFontGetMatrix(font) == .identity else { return nil }
        let firstMatrix = CTFontGetMatrix(firstFont)
        guard [firstMatrix.a, firstMatrix.b, firstMatrix.c, firstMatrix.d, firstMatrix.tx, firstMatrix.ty].allSatisfy(\.isFinite),
              firstMatrix.a > 0, firstMatrix.d == 1, firstMatrix.b == 0, firstMatrix.c == 0,
              firstMatrix.tx == 0, firstMatrix.ty == 0 else { return nil }
        for attributes in [a, b] {
            if let offset = attributes[NSAttributedString.Key.baselineOffset] as? NSNumber,
               offset.doubleValue != 0 { return nil }
            for key in [NSAttributedString.Key.strokeWidth, .strokeColor, .shadow, .attachment] {
                if attributes[key] != nil { return nil }
            }
        }
        var glyphs: [CGGlyph] = [], positions: [CGPoint] = []
        for (run, expected, expectedMatrix) in [(space, left, firstMatrix), (following, right, CGAffineTransform.identity)] {
            // Initial proof excludes RTL/reordering and requires one UTF-16
            // unit per glyph. Ligatures/combining clusters use existing draw.
            guard CTRunGetStatus(run).rawValue & 3 == 0,
                  CTRunGetTextMatrix(run) == expectedMatrix else { return nil }
            let count = CTRunGetGlyphCount(run)
            guard count == expected.length, count > 0, glyphs.count + count <= 4096 else { return nil }
            var localGlyphs = [CGGlyph](repeating: 0, count: count)
            var localPositions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &localGlyphs)
            CTRunGetPositions(run, CFRange(), &localPositions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            guard localGlyphs.allSatisfy({ $0 != 0 }),
                  indices == Array(expected.location..<(expected.location + expected.length)),
                  localPositions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.y == 0 }) else { return nil }
            // CoreText run positions precede its text matrix. The empty space
            // glyphs use the following font, so preserve their placed origins.
            let placed = localPositions.map { $0.applying(expectedMatrix) }
            guard placed.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.y == 0 }) else { return nil }
            glyphs += localGlyphs; positions += placed
        }
        guard zip(positions, positions.dropFirst()).allSatisfy({ $0.x <= $1.x }),
              positions[left.length].x > positions[0].x,
              abs(positions[left.length].x - positions[0].x - CGFloat(receipt.doubleValue)) <= 0.01 else { return nil }
        var character: UniChar = 0x20, expectedSpace: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &expectedSpace, 1), expectedSpace != 0 else { return nil }
        for glyph in glyphs.prefix(left.length) {
            guard glyph == expectedSpace else { return nil }
            for face in [firstFont, font] {
                var value = glyph, bounds = CGRect.zero
                _ = CTFontGetBoundingRectsForGlyphs(face, .default, &value, &bounds, 1)
                guard bounds.isEmpty else { return nil }
                if let path = CTFontCreatePathForGlyph(face, glyph, nil), !path.isEmpty { return nil }
            }
        }
        return Plan(font: font, color: bc.cgColor, glyphs: glyphs, positions: positions)
    }
}
