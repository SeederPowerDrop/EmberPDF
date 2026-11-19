// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Read text and its rectangle from the same PDFKit selection. PDFKit's
/// characterBounds indices cannot safely be paired with indices in page.string
/// (ligatures and generated separators use different indexing).
@MainActor
enum PDFNativeTextLayout {
    struct CollapsedLayout {
        let lines: [PDFVisualTextLine]
        let excludedBounds: [CGRect]
        let crop: CGRect
        let typicalHeight: CGFloat

        func supports(_ drag: PDFVisualTextDrag) -> Bool {
            guard crop.contains(drag.start), crop.contains(drag.end),
                  lines.contains(where: {
                      $0.bounds.insetBy(dx: -$0.bounds.height * 0.5,
                                       dy: -$0.bounds.height * 0.8).contains(drag.start)
                  }) else { return false }
            let gesture = CGRect(x: min(drag.start.x, drag.end.x), y: min(drag.start.y, drag.end.y),
                                 width: max(0.5, abs(drag.end.x - drag.start.x)),
                                 height: max(0.5, abs(drag.end.y - drag.start.y)))
                .insetBy(dx: -typicalHeight * 0.5, dy: -typicalHeight * 0.8)
            return !excludedBounds.contains(where: { $0.intersects(gesture) })
        }
    }

    static func makeLines(for page: PDFPage) -> [PDFVisualTextLine]? {
        readLines(for: page, collapsedCrop: nil)?.lines
    }

    /// Some OCR fonts have no outlines: characterBounds has zero height, but
    /// a range selection still supplies the native Unicode and its em cell.
    /// Prefer those paired native values to recognizing the printed text a
    /// second time. Never borrow text from a matching phrase elsewhere.
    static func makeCollapsedLayout(for page: PDFPage) -> CollapsedLayout? {
        if let document = page.document,
           document.isLocked || (document.isEncrypted && document.permissionsStatus != .owner
                && !document.allowsCopying) { return nil }
        let count = page.numberOfCharacters
        guard count >= 6, count <= 50_000 else { return nil }
        var measured = 0, collapsed = 0
        for sample in 0..<min(count, 48) {
            let index = sample * (count - 1) / max(1, min(count, 48) - 1)
            guard let selection = page.selection(for: NSRange(location: index, length: 1)),
                  let value = selection.string,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            measured += 1
            if page.characterBounds(at: index).height < 0.1 { collapsed += 1 }
        }
        let crop = page.bounds(for: .cropBox)
        guard measured >= 6, collapsed * 3 >= measured * 2,
              crop.origin.x.isFinite, crop.origin.y.isFinite,
              crop.width.isFinite, crop.height.isFinite, !crop.isEmpty,
              !PDFFormGraphicsStateInspector.hasUnbalancedForm(on: page) else { return nil }
        guard let result = readLines(for: page, collapsedCrop: crop) else { return nil }
        let heights = result.lines.map(\.bounds.height).sorted()
        return CollapsedLayout(lines: result.lines, excludedBounds: result.excludedBounds,
                               crop: crop, typicalHeight: heights[heights.count / 2])
    }

    private static func readLines(for page: PDFPage, collapsedCrop: CGRect?)
        -> (lines: [PDFVisualTextLine], excludedBounds: [CGRect])? {
        let count = page.numberOfCharacters
        guard count > 0, count <= 50_000,
              let whole = page.selection(for: NSRange(location: 0, length: count)) else { return nil }
        var lines: [PDFVisualTextLine] = []
        var consumed = Set<NSRange>()
        var nativeCells: [CGRect] = []
        var excludedBounds: [CGRect] = []
        for line in whole.selectionsByLine() {
            var text = ""
            var boxes: [CGRect?] = []
            var bounds = CGRect.null
            var cells: [CGRect] = []
            var rejectedBounds = CGRect.null
            for part in 0..<line.numberOfTextRanges(on: page) {
                let range = line.range(at: part, on: page)
                guard range.location != NSNotFound, range.location >= 0,
                      range.length <= count, range.location <= count - range.length else { return nil }
                var index = range.location
                while index < NSMaxRange(range) {
                    defer { index += 1 }
                    guard let glyph = page.selection(for: NSRange(location: index, length: 1)),
                          glyph.numberOfTextRanges(on: page) == 1,
                          let value = glyph.string else { continue }
                    let actual = glyph.range(at: 0, on: page)
                    guard actual.location != NSNotFound, actual.length > 0,
                          actual.location >= range.location, actual.location <= count,
                          actual.length <= count - actual.location,
                          NSMaxRange(actual) <= NSMaxRange(range),
                          consumed.insert(actual).inserted else { continue }
                    // A single fi ligature selects both UTF-16 positions. Read
                    // the expanded selection once, retaining the original text.
                    index = max(index, NSMaxRange(actual) - 1)
                    let box = glyph.bounds(for: page)
                    let usableBox = !box.isNull && !box.isEmpty && box.origin.x.isFinite
                        && box.origin.y.isFinite && box.width.isFinite && box.height.isFinite
                    if let crop = collapsedCrop,
                       value.contains(where: { !$0.isWhitespace && !$0.isNewline }) {
                        guard box.origin.x.isFinite, box.origin.y.isFinite,
                              box.width.isFinite, box.height.isFinite else { return nil }
                        if !usableBox || !crop.insetBy(dx: -1, dy: -1).contains(box)
                            || box.height > 256 || box.width > max(256, box.height * 8)
                            || value.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline) {
                            rejectedBounds = rejectedBounds.union(box)
                        }
                        // Record once per independently selected source range;
                        // an expanded ligature may legitimately share one cell.
                        cells.append(box)
                    }
                    for character in value where !character.isNewline {
                        // PDFKit may synthesize zero-width spaces between font
                        // runs. Preserve those word boundaries even though they
                        // provide no selectable ink rectangle.
                        guard character.isWhitespace || usableBox else { continue }
                        text.append(character)
                        boxes.append(character.isWhitespace ? nil : box)
                    }
                    if usableBox { bounds = bounds.union(box) }
                }
            }
            if collapsedCrop != nil {
                // An unavailable glyph/range must not turn a native line into
                // a plausible partial phrase. Spaces may be synthesized by
                // PDFKit, but every other source scalar must survive exactly.
                let key: (String) -> [UnicodeScalar] = { value in
                    value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
                }
                if line.string.map({ key($0) == key(text) }) != true {
                    let sourceBounds = line.bounds(for: page)
                    guard sourceBounds.origin.x.isFinite, sourceBounds.origin.y.isFinite,
                          sourceBounds.width.isFinite, sourceBounds.height.isFinite,
                          !sourceBounds.isNull, !sourceBounds.isEmpty else { return nil }
                    rejectedBounds = rejectedBounds.union(sourceBounds)
                }
            }
            if collapsedCrop != nil, !rejectedBounds.isNull {
                let lineBounds = line.bounds(for: page)
                guard lineBounds.origin.x.isFinite, lineBounds.origin.y.isFinite,
                      lineBounds.width.isFinite, lineBounds.height.isFinite else { return nil }
                excludedBounds.append(rejectedBounds.union(lineBounds))
                continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !bounds.isNull else { continue }
            lines.append(PDFVisualTextLine(text: text, bounds: bounds, characterBounds: boxes))
            nativeCells.append(contentsOf: cells)
        }
        if collapsedCrop != nil, hasAmbiguousCells(nativeCells) { return nil }
        return lines.isEmpty ? nil : (lines, excludedBounds)
    }

    private static func hasAmbiguousCells(_ cells: [CGRect]) -> Bool {
        var active: [CGRect] = []
        var comparisons = 0
        for cell in cells.sorted(by: { $0.minX < $1.minX }) {
            active.removeAll { $0.maxX <= cell.minX }
            for other in active {
                comparisons += 1
                guard comparisons <= 500_000 else { return true }
                let overlap = other.intersection(cell)
                if !overlap.isNull,
                   overlap.width > min(other.width, cell.width) * 0.45,
                   overlap.height > min(other.height, cell.height) * 0.65 { return true }
            }
            active.append(cell)
        }
        return false
    }
}
