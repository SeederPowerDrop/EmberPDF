// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText

/// The live TextKit editor and PDF CoreText output share the same source-run
/// preservation. A text-only edit retains surrounding fonts and baselines;
/// an explicit style change intentionally formats the entire draft.
@MainActor
enum PDFBodyTextAttributedLayout {
    static func attributedString(
        text: String,
        style: InlineTextStyle,
        sourceText: String? = nil,
        sourceStyle: InlineTextStyle? = nil,
        sourceRuns: [InlineTextSourceRun] = [],
        lineHeight: CGFloat? = nil,
        firstLineIndent: CGFloat = 0,
        textScale: CGFloat = 1
    ) -> NSAttributedString {
        let scale = textScale.isFinite && textScale > 0 ? textScale : 1
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        if let lineHeight, lineHeight.isFinite {
            // PDF row spacing measures baselines and can be smaller than a
            // fallback face's em size. Keep that source grid in the live editor.
            let height = (lineHeight > 0 ? lineHeight : style.fontSize) * scale
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
        }
        var base = attributes(text: text, style: style, baselineOffset: 0, scale: scale)
        base[.paragraphStyle] = paragraph
        let output = NSMutableAttributedString(string: text, attributes: base)
        guard output.length > 0 else { return output }

        if firstLineIndent.isFinite, firstLineIndent != 0 {
            let firstParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
            firstParagraph.firstLineHeadIndent = firstLineIndent * scale
            output.addAttribute(.paragraphStyle, value: firstParagraph,
                                range: (text as NSString).paragraphRange(for: NSRange(location: 0, length: 0)))
        }
        guard let sourceStyle, hasSameAppearance(sourceStyle, style),
              let sourceText, !sourceRuns.isEmpty else { return output }
        let oldLength = sourceText.utf16.count
        let newLength = output.length
        let runs = sourceRuns.filter {
            $0.range.location != NSNotFound && $0.range.location >= 0 && $0.range.length > 0
                && $0.range.location <= oldLength && $0.range.length <= oldLength - $0.range.location
        }
        let common = commonEnds(sourceText, text)
        let middleSource = NSRange(location: common.prefix,
            length: oldLength - common.prefix - common.suffix)
        let middleDraft = NSRange(location: common.prefix,
            length: newLength - common.prefix - common.suffix)
        // One edit still uses the prefix/suffix path. Separate edits can leave
        // styled runs between them; align that middle only when it reaches
        // more than one source run, and keep a fixed work budget per preview.
        let middle = runs.filter { NSIntersectionRange($0.range, middleSource).length > 0 }.count > 1
            ? unchangedMiddle(sourceText, text, source: middleSource, draft: middleDraft) : nil
        struct Segment {
            let range: NSRange
            let source: InlineTextSourceRun
            let unchanged: Bool
        }
        var segments: [Segment] = []

        func map(_ run: InlineTextSourceRun, sourceRange: NSRange, shift: Int) {
            let intersection = NSIntersectionRange(run.range, sourceRange)
            guard intersection.length > 0 else { return }
            let destination = NSRange(location: intersection.location + shift, length: intersection.length)
            segments.append(Segment(range: destination, source: run, unchanged: true))
        }
        for run in runs {
            map(run, sourceRange: NSRange(location: 0, length: common.prefix), shift: 0)
            map(run, sourceRange: NSRange(location: oldLength - common.suffix, length: common.suffix),
                  shift: newLength - oldLength)
            for island in middle?.unchanged ?? [] {
                map(run, sourceRange: island.source, shift: island.draft.location - island.source.location)
            }
        }
        let changes = middle?.changes ?? [ChangedSpan(sourceLocation: common.prefix, draft: middleDraft)]
        for change in changes where change.draft.length > 0 {
            if let inherited = runs.first(where: { NSLocationInRange(change.sourceLocation, $0.range) })
                ?? runs.last(where: { NSMaxRange($0.range) == change.sourceLocation }) {
                segments.append(Segment(range: change.draft, source: inherited, unchanged: false))
            }
        }
        // Resolve a stable fallback from each original face/size's source
        // text. A new space then keeps its Korean run's fallback, while new
        // Korean typed before Helvetica numbers cannot change those untouched
        // numbers. Only a changed piece needing extra glyphs falls back again.
        struct FontKey: Hashable {
            let name: String
            let size: CGFloat
            let documentFontIdentity: UUID?
            init(_ style: InlineTextStyle) {
                name = style.fontName; size = style.fontSize
                documentFontIdentity = style.sourceFont?.identity
            }
        }
        var contexts: [FontKey: String] = [:]
        for run in runs {
            contexts[FontKey(run.style), default: ""].append((sourceText as NSString).substring(with: run.range))
        }
        var resolvedFonts: [FontKey: NSFont] = [:]
        for segment in segments {
            let source = segment.source
            let key = FontKey(source.style)
            let resolved = resolvedFonts[key] ?? PDFBodyTextEditor.replacementFont(
                for: contexts[key] ?? "", preferred: source.style.font)
            resolvedFonts[key] = resolved
            let fragment = (text as NSString).substring(with: segment.range)
            let correction = widthCorrection(source: source, sourceText: sourceText,
                                             replacementText: fragment, font: resolved)
            let fragmentFont = PDFBodyTextEditor.replacementFont(
                for: fragment, preferred: resolved)
            output.addAttributes(attributes(text: "", style: source.style,
                baselineOffset: source.baselineOffset, scale: scale, resolvedFont: fragmentFont,
                horizontalCorrection: correction), range: segment.range)
            if source.usesSourceUnkernedAdvances,
               PDFBodySourceSpacing.fontMatches(fragmentFont, source.style.font) {
                output.addAttributes([.kern: NSNumber(value: 0),
                    PDFBodySourceSpacing.preservedKerningAttribute: NSNumber(value: true)], range: segment.range)
            }
            // Keep a private drawing receipt only for an unchanged, proven
            // single leading source space. A newly typed or inherited space
            // cannot acquire this receipt through style inheritance.
            let original = sourceText as NSString
            let startsSourceLine = source.range.location == 0
                || [0x0A, 0x0D].contains(Int(original.character(at: source.range.location - 1)))
            if segment.unchanged, segment.range.length == 1, source.range.length == 1,
               fragment == " ", original.substring(with: source.range) == " ", startsSourceLine,
               let advance = source.horizontalAdvance, advance.isFinite, advance > 0,
               advance <= min(256, max(48, source.style.fontSize * 8)) {
                output.addAttribute(PDFBodyLeadingSpaceDrawing.preservedAdvanceAttribute,
                    value: NSNumber(value: Double(advance * scale)), range: segment.range)
            }
        }
        return output
    }

    private static func attributes(text: String, style: InlineTextStyle,
                                   baselineOffset: CGFloat, scale: CGFloat,
                                   resolvedFont: NSFont? = nil,
                                   horizontalCorrection: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let resolved = resolvedFont ?? PDFBodyTextEditor.replacementFont(for: text, preferred: style.font)
        var rendered = style.renderingFont(resolved, size: resolved.pointSize * scale)
        if horizontalCorrection != 1 {
            var matrix = CGAffineTransform(scaleX: style.horizontalScale * horizontalCorrection, y: 1)
            let copy = CTFontCreateCopyWithAttributes(rendered as CTFont, rendered.pointSize, &matrix, nil) as NSFont
            rendered = PDFBodyTextDocumentFonts.retainingBacking(from: rendered, on: copy)
        }
        return [.font: rendered,
                .foregroundColor: style.textColor.nsColor,
                .baselineOffset: (baselineOffset.isFinite ? baselineOffset : 0) * scale]
    }

    /// Calibrate a replacement face against the original run's advance once.
    /// The same ratio applies to inserted text, so longer replacements still
    /// grow naturally instead of being squeezed into the old word's width.
    private static func widthCorrection(source: InlineTextSourceRun, sourceText: String,
                                        replacementText: String, font: NSFont) -> CGFloat {
        guard let advance = source.horizontalAdvance, advance.isFinite, advance > 0 else { return 1 }
        let original = (sourceText as NSString).substring(with: source.range)
        // A generated boundary space can describe a positioned gap rather
        // than a condensed font. Preserve that gap while it remains whitespace,
        // but do not stretch a new word typed in its place to the gap's ratio.
        if original.allSatisfy(\.isWhitespace), replacementText.contains(where: { !$0.isWhitespace }) {
            return 1
        }
        let rendered = source.style.renderingFont(font)
        var attributes: [NSAttributedString.Key: Any] = [.font: rendered]
        if source.usesSourceUnkernedAdvances, PDFBodySourceSpacing.fontMatches(font, source.style.font) {
            attributes[.kern] = NSNumber(value: 0)
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: original, attributes: attributes))
        let measured = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard measured.isFinite, measured > 0 else { return 1 }
        let ratio = advance / measured
        // A proven positioned space can be much wider than a font's ordinary
        // space. Only an unchanged all-ASCII-space run receives this separate
        // bounded advance correction; visible glyph scaling keeps its gate.
        if !original.isEmpty, original.unicodeScalars.allSatisfy({ $0.value == 0x20 }),
           replacementText == original,
           advance <= min(256, max(48, source.style.fontSize * 8)),
           ratio.isFinite, (1.0 / 64...64).contains(ratio) {
            return abs(ratio - 1) >= 0.001 ? ratio : 1
        }
        guard ratio.isFinite, (0.5...2).contains(ratio), abs(ratio - 1) >= 0.001 else { return 1 }
        return ratio
    }

    private static func hasSameAppearance(_ left: InlineTextStyle, _ right: InlineTextStyle) -> Bool {
        left.fontName == right.fontName && left.sourceFont == right.sourceFont
            && abs(left.fontSize - right.fontSize) < 0.0001
            && abs(left.horizontalScale - right.horizontalScale) < 0.0001
            && left.alignment == right.alignment
            && left.textColor.visuallyEquals(right.textColor)
            && left.backgroundColor.visuallyEquals(right.backgroundColor)
    }

    private struct UnchangedSpan {
        let source: NSRange
        let draft: NSRange
    }

    private struct ChangedSpan {
        let sourceLocation: Int
        let draft: NSRange
    }

    private struct MiddleMapping {
        var unchanged: [UnchangedSpan] = []
        var changes: [ChangedSpan] = []
    }

    /// A bounded shortest-edit alignment finds unchanged islands between edits.
    /// Diagonals are capped at 64 inserted/deleted Characters, and comparisons
    /// at 131072; long or heavily rewritten middles retain the old single-edit
    /// behavior. All offsets come from complete Characters, never UTF-16 units.
    private static func unchangedMiddle(_ old: String, _ new: String,
                                        source: NSRange, draft: NSRange) -> MiddleMapping? {
        guard source.length > 0, draft.length > 0,
              source.length <= 32768, draft.length <= 32768 else { return nil }
        let left = Array((old as NSString).substring(with: source))
        let right = Array((new as NSString).substring(with: draft))
        let oldOffsets = left.reduce(into: [0]) { $0.append($0.last! + String($1).utf16.count) }
        let newOffsets = right.reduce(into: [0]) { $0.append($0.last! + String($1).utf16.count) }
        let limit = min(64, left.count + right.count), center = limit + 1
        var diagonals = [Int](repeating: -1, count: 2 * limit + 3)
        diagonals[center + 1] = 0
        var trace: [[Int]] = []
        var work = 0
        var distance: Int?
        search: for step in 0...limit {
            trace.append(diagonals)
            for diagonal in stride(from: -step, through: step, by: 2) {
                work += 1
                guard work <= 131072 else { return nil }
                let at = center + diagonal
                var x = diagonal == -step || (diagonal != step && diagonals[at - 1] < diagonals[at + 1])
                    ? diagonals[at + 1] : diagonals[at - 1] + 1
                var y = x - diagonal
                guard x >= 0, y >= 0, x <= left.count, y <= right.count else {
                    diagonals[at] = -1
                    continue
                }
                while x < left.count, y < right.count {
                    work += 1
                    guard work <= 131072 else { return nil }
                    guard left[x] == right[y], oldOffsets[x + 1] - oldOffsets[x] == newOffsets[y + 1] - newOffsets[y] else { break }
                    x += 1
                    y += 1
                }
                diagonals[at] = x
                if x == left.count, y == right.count {
                    distance = step
                    break search
                }
            }
        }
        guard let distance else { return nil }
        var matches: [(old: Int, new: Int)] = []
        var x = left.count, y = right.count
        for step in stride(from: distance, through: 0, by: -1) {
            let previous = trace[step], diagonal = x - y
            let previousDiagonal = diagonal == -step
                || (diagonal != step && previous[center + diagonal - 1] < previous[center + diagonal + 1])
                ? diagonal + 1 : diagonal - 1
            let oldX = step == 0 ? 0 : previous[center + previousDiagonal]
            let oldY = step == 0 ? 0 : oldX - previousDiagonal
            guard oldX >= 0, oldY >= 0 else { return nil }
            while x > oldX, y > oldY {
                x -= 1
                y -= 1
                matches.append((x, y))
            }
            x = oldX
            y = oldY
        }
        guard !matches.isEmpty else { return nil }
        matches.reverse()
        var result = MiddleMapping(), oldCursor = 0, newCursor = 0, index = 0
        while index < matches.count {
            let start = matches[index]
            var end = index + 1
            while end < matches.count, matches[end].old == matches[end - 1].old + 1,
                  matches[end].new == matches[end - 1].new + 1 { end += 1 }
            if start.new > newCursor {
                result.changes.append(ChangedSpan(sourceLocation: source.location + oldOffsets[oldCursor],
                    draft: NSRange(location: draft.location + newOffsets[newCursor],
                                   length: newOffsets[start.new] - newOffsets[newCursor])))
            }
            oldCursor = matches[end - 1].old + 1
            newCursor = matches[end - 1].new + 1
            result.unchanged.append(UnchangedSpan(
                source: NSRange(location: source.location + oldOffsets[start.old],
                                length: oldOffsets[oldCursor] - oldOffsets[start.old]),
                draft: NSRange(location: draft.location + newOffsets[start.new],
                               length: newOffsets[newCursor] - newOffsets[start.new])))
            index = end
        }
        if newCursor < right.count {
            result.changes.append(ChangedSpan(sourceLocation: source.location + oldOffsets[oldCursor],
                draft: NSRange(location: draft.location + newOffsets[newCursor],
                               length: newOffsets[right.count] - newOffsets[newCursor])))
        }
        return result
    }

    /// Count matching complete Characters, then return UTF-16 offsets for
    /// Foundation ranges. Never split emoji, surrogate pairs, or IME syllables.
    private static func commonEnds(_ old: String, _ new: String) -> (prefix: Int, suffix: Int) {
        let left = Array(old), right = Array(new)
        var head = 0, prefix = 0
        while head < min(left.count, right.count), left[head] == right[head],
              String(left[head]).utf16.count == String(right[head]).utf16.count {
            prefix += String(left[head]).utf16.count
            head += 1
        }
        var tail = 0, suffix = 0
        while tail < min(left.count, right.count) - head {
            let a = left[left.count - 1 - tail], b = right[right.count - 1 - tail]
            guard a == b, String(a).utf16.count == String(b).utf16.count else { break }
            suffix += String(a).utf16.count
            tail += 1
        }
        return (prefix, suffix)
    }
}
