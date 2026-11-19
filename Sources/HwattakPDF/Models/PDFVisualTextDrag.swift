// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// A normal text drag on a page whose embedded OCR geometry is unusable.
/// Coordinates stay in the source page until recognition maps them to pixels.
struct PDFVisualTextDrag: Sendable {
    let start: CGPoint
    let end: CGPoint

    func recognitionRegion(cropBox: CGRect, rotation: Int) -> CGRect {
        let transform = PDFRegionTextRecognizer.displayTransform(cropBox: cropBox, rotation: rotation)
        let first = start.applying(transform)
        let last = end.applying(transform)
        let displayedCrop = cropBox.applying(transform)
        // Include whole lines so OCR receives uncut words and line context. The
        // recognizer later clips by character positions, never source indices.
        let displayed = CGRect(x: displayedCrop.minX, y: min(first.y, last.y) - 24,
                               width: displayedCrop.width, height: abs(first.y - last.y) + 48)
            .intersection(displayedCrop)
        return displayed.applying(transform.inverted()).intersection(cropBox)
    }

    func fragments(from lines: [PDFVisualTextLine], imageToPage: CGAffineTransform) -> [PDFRegionTextFragment] {
        PDFVisualTextLayout(lines: lines, imageToPage: imageToPage).fragments(for: self)
    }
}

/// Reusable geometry shared by repaired native text and visible-page OCR.
/// All sorting, string indexing, and row-overlap discovery happen once per
/// layout; pointer updates only choose a column and character endpoints.
struct PDFVisualTextLayout: Sendable {
    private static let unbounded = -CGFloat.greatestFiniteMagnitude...CGFloat.greatestFiniteMagnitude

    private struct Line: Sendable {
        let source: PDFVisualTextLine
        let characters: [Character]
        let glyphs: [CGRect]
        let letters: [CGRect]
        let centers: [CGFloat]

        func intersects(_ column: ClosedRange<CGFloat>) -> Bool {
            glyphs.contains { column.contains($0.midX) }
        }
    }

    private struct Row: Sendable {
        var lineIndices: [Int]
        let seedBounds: CGRect
        var bounds: CGRect
        var maximumHeight: CGFloat
    }

    private struct VerticalContextKey: Equatable {
        let bottom: Int
        let top: Int
    }

    private struct GutterContext {
        let lines: [Int]
        let gaps: [ClosedRange<CGFloat>]
        let boundaries: [CGFloat]
    }

    private struct ColumnPositionKey: Equatable {
        let first: Int
        let last: Int
    }

    private struct PreparedColumn {
        let bounds: ClosedRange<CGFloat>
        let rows: [Row]
        let completeFragments: [[PDFRegionTextFragment]]
    }

    private struct CharacterClip: Equatable {
        let first: Int
        let end: Int
    }

    private struct BoundaryKey: Equatable {
        let row: Int
        let clips: [CharacterClip]
    }

    private struct SelectionKey: Equatable {
        let head: BoundaryKey
        let tail: BoundaryKey?
    }

    private struct BoundaryResult {
        let key: BoundaryKey
        let fragments: [PDFRegionTextFragment]
    }

    /// Layout values can be shared with OCR workers. Protect the small memo
    /// cache so that sharing never changes the result of a selection query.
    private final class SelectionCache: @unchecked Sendable {
        let lock = NSLock()
        var verticalKey: VerticalContextKey?
        var context: GutterContext?
        var positionKey: ColumnPositionKey?
        var column: PreparedColumn?
        var columns: [PreparedColumn] = []
        var head: BoundaryResult?
        var tail: BoundaryResult?
        var selectionKey: SelectionKey?
        var fragments: [PDFRegionTextFragment] = []
    }

    private let lines: [Line]
    private let glyphsByX: [(line: Int, bounds: CGRect)]
    private let lineBuckets: [[Int]?]
    private let allRows: [Row]
    private let typicalHeight: CGFloat
    private let imageToPage: CGAffineTransform
    private let pageToImage: CGAffineTransform
    private let minimumYs: [CGFloat]
    private let maximumYs: [CGFloat]
    private let cache = SelectionCache()

    init(lines sourceLines: [PDFVisualTextLine], imageToPage: CGAffineTransform) {
        self.imageToPage = imageToPage
        pageToImage = imageToPage.inverted()
        let prepared = sourceLines.sorted { $0.bounds.midY > $1.bounds.midY }.map { source in
            let characters = Array(source.text)
            let glyphs = source.characterBounds.compactMap { $0 }.filter {
                !$0.isNull && !$0.isEmpty && $0.minX.isFinite && $0.maxX.isFinite
            }
            let letters = zip(characters, source.characterBounds).compactMap { pair -> CGRect? in
                let (character, box) = pair
                guard character.isLetter, let box, !box.isNull, !box.isEmpty else { return nil }
                return box
            }
            return Line(source: source, characters: characters, glyphs: glyphs, letters: letters,
                        centers: glyphs.map(\.midX).sorted())
        }
        lines = prepared
        minimumYs = prepared.map(\.source.bounds.minY).filter(\.isFinite).sorted()
        maximumYs = prepared.map(\.source.bounds.maxY).filter(\.isFinite).sorted()
        let heights = prepared.map(\.source.bounds.height).filter { $0.isFinite && $0 > 0 }.sorted()
        let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
        typicalHeight = medianHeight
        glyphsByX = prepared.enumerated().flatMap { index, line in
            line.glyphs.map { (line: index, bounds: $0) }
        }.sorted { $0.bounds.minX < $1.bounds.minX }

        // A row uses its first fragment's baseline. Cache small Y bucket
        // ranges rather than constructing a quadratic matrix of line pairs.
        // Re-selecting seeds after column filtering preserves behavior when a
        // tall observation in the other column spans several body-text rows.
        let buckets = prepared.map { Self.buckets(for: $0.source.bounds, height: max(1, medianHeight)) }
        lineBuckets = buckets
        allRows = Self.makeRows(lines: prepared, buckets: buckets, column: Self.unbounded)
    }

    func fragments(for drag: PDFVisualTextDrag) -> [PDFRegionTextFragment] {
        let first = drag.start.applying(pageToImage)
        let last = drag.end.applying(pageToImage)
        cache.lock.lock()
        defer { cache.lock.unlock() }

        // Only crossing a line's vertical edge can change which lines support
        // a gutter. Subpixel pointer movement within that interval needs no
        // page-wide glyph scan or row reconstruction.
        let verticalKey = VerticalContextKey(
            bottom: Self.partition(maximumYs, at: min(first.y, last.y) - typicalHeight * 0.8, inclusive: false),
            top: Self.partition(minimumYs, at: max(first.y, last.y) + typicalHeight * 0.8, inclusive: true))
        if cache.verticalKey != verticalKey {
            cache.verticalKey = verticalKey
            cache.context = gutterContext(first: first, last: last)
            cache.positionKey = nil
        }
        guard let context = cache.context else { return [] }
        let positionKey = ColumnPositionKey(
            first: Self.partition(context.boundaries, at: first.x, inclusive: true),
            last: Self.partition(context.boundaries, at: last.x, inclusive: true))
        if cache.positionKey != positionKey || cache.column == nil {
            cache.positionKey = positionKey
            let bounds = columnBounds(context: context, first: first, last: last)
            if cache.column?.bounds != bounds {
                if let prepared = cache.columns.first(where: { $0.bounds == bounds }) {
                    cache.column = prepared
                } else {
                    let prepared = prepareColumn(bounds)
                    cache.columns.append(prepared)
                    if cache.columns.count > 4 { cache.columns.removeFirst() }
                    cache.column = prepared
                }
                cache.head = nil
                cache.tail = nil
                cache.selectionKey = nil
            }
        }
        guard let prepared = cache.column else { return [] }
        let column = prepared.bounds
        let rows = prepared.rows
        func distance(_ point: CGPoint, _ row: Row) -> CGFloat {
            let box = row.bounds
            return max(0, max(box.minY - point.y, point.y - box.maxY))
        }
        func rowIndex(at point: CGPoint, requiresProximity: Bool) -> Int? {
            guard let index = rows.indices.min(by: { distance(point, rows[$0]) < distance(point, rows[$1]) }) else {
                return nil
            }
            let height = rows[index].maximumHeight
            return !requiresProximity || distance(point, rows[index]) <= max(6, height * 0.8) ? index : nil
        }
        // Once a drag starts on text, releasing just outside a line should
        // extend to the nearest endpoint instead of clearing the selection.
        guard let firstRow = rowIndex(at: first, requiresProximity: true),
              let lastRow = rowIndex(at: last, requiresProximity: false) else {
            cache.selectionKey = nil
            cache.fragments = []
            return []
        }
        let upper = min(firstRow, lastRow), lower = max(firstRow, lastRow)
        let forward = firstRow < lastRow || (firstRow == lastRow && first.x <= last.x)
        let head = forward ? first : last, tail = forward ? last : first
        let headMin = max(column.lowerBound, head.x)
        let headMax = upper == lower ? min(column.upperBound, tail.x) : column.upperBound
        let tailMax = min(column.upperBound, tail.x)
        let headKey = boundaryKey(row: upper, in: prepared, from: headMin, through: headMax)
        let tailKey = upper == lower ? nil
            : boundaryKey(row: lower, in: prepared, from: column.lowerBound, through: tailMax)
        let selectionKey = SelectionKey(head: headKey, tail: tailKey)
        if cache.selectionKey == selectionKey { return cache.fragments }

        func boundary(_ key: BoundaryKey, from minX: CGFloat, through maxX: CGFloat,
                      previous: BoundaryResult?) -> BoundaryResult {
            if let previous, previous.key == key { return previous }
            let fragments: [PDFRegionTextFragment]
            if minX == column.lowerBound && maxX == column.upperBound {
                fragments = prepared.completeFragments[key.row]
            } else {
                fragments = rows[key.row].lineIndices.compactMap { lineIndex in
                    let line = lines[lineIndex]
                    return line.source.fragment(characters: line.characters, from: minX, through: maxX,
                                                imageToPage: imageToPage)
                }
            }
            return BoundaryResult(key: key, fragments: fragments)
        }
        let headResult = boundary(headKey, from: headMin, through: headMax, previous: cache.head)
        cache.head = headResult
        var fragments = headResult.fragments
        if let tailKey {
            for row in (upper + 1)..<lower { fragments.append(contentsOf: prepared.completeFragments[row]) }
            let tailResult = boundary(tailKey, from: column.lowerBound, through: tailMax, previous: cache.tail)
            cache.tail = tailResult
            fragments.append(contentsOf: tailResult.fragments)
        }
        cache.selectionKey = selectionKey
        cache.fragments = fragments
        return fragments
    }

    private func prepareColumn(_ column: ClosedRange<CGFloat>) -> PreparedColumn {
        let rows = column == Self.unbounded ? allRows
            : Self.makeRows(lines: lines, buckets: lineBuckets, column: column)
        let fragments = rows.map { row in
            row.lineIndices.compactMap { index in
                let line = lines[index]
                return line.source.fragment(characters: line.characters, from: column.lowerBound,
                                            through: column.upperBound, imageToPage: imageToPage)
            }
        }
        return PreparedColumn(bounds: column, rows: rows, completeFragments: fragments)
    }

    private func boundaryKey(row: Int, in column: PreparedColumn,
                             from minX: CGFloat, through maxX: CGFloat) -> BoundaryKey {
        BoundaryKey(row: row, clips: column.rows[row].lineIndices.map { index in
            CharacterClip(first: Self.partition(lines[index].centers, at: minX, inclusive: false),
                          end: Self.partition(lines[index].centers, at: maxX, inclusive: true))
        })
    }

    /// Count values below the coordinate, or below/equal for an upper edge.
    /// Duplicate centers keep expanded ligatures on the same character edge.
    private static func partition(_ values: [CGFloat], at coordinate: CGFloat, inclusive: Bool) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = low + (high - low) / 2
            if values[middle] < coordinate || (inclusive && values[middle] == coordinate) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func buckets(for bounds: CGRect, height: CGFloat) -> [Int]? {
        let first = (bounds.minY / height).rounded(.down)
        let last = (bounds.maxY / height).rounded(.down)
        guard first.isFinite, last.isFinite, abs(first) < CGFloat(Int.max / 4),
              abs(last) < CGFloat(Int.max / 4), first <= last, last - first <= 64 else { return nil }
        return Array(Int(first)...Int(last))
    }

    private static func makeRows(lines: [Line], buckets: [[Int]?],
                                 column: ClosedRange<CGFloat>) -> [Row] {
        var rows: [Row] = []
        var rowsByBucket: [Int: [Int]] = [:]
        var wideRows: [Int] = []
        for index in lines.indices where lines[index].intersects(column) {
            let bounds = lines[index].source.bounds
            let matchingRow: Int?
            if let lineBuckets = buckets[index] {
                var earliest: Int?
                func consider(_ candidates: [Int]) {
                    for candidate in candidates {
                        if let earliest, candidate >= earliest { break }
                        if sharesRow(rows[candidate].seedBounds, bounds) {
                            earliest = candidate
                            break
                        }
                    }
                }
                consider(wideRows)
                for bucket in lineBuckets { consider(rowsByBucket[bucket] ?? []) }
                matchingRow = earliest
            } else {
                // Extremely tall/malformed observations use bounded row
                // lookup without allocating thousands of spatial buckets.
                matchingRow = rows.firstIndex { sharesRow($0.seedBounds, bounds) }
            }
            if let row = matchingRow {
                rows[row].lineIndices.append(index)
                rows[row].bounds = rows[row].bounds.union(bounds)
                rows[row].maximumHeight = max(rows[row].maximumHeight, bounds.height)
            } else {
                let row = rows.count
                rows.append(Row(lineIndices: [index], seedBounds: bounds, bounds: bounds, maximumHeight: bounds.height))
                if let lineBuckets = buckets[index] {
                    for bucket in lineBuckets { rowsByBucket[bucket, default: []].append(row) }
                } else {
                    wideRows.append(row)
                }
            }
        }
        for index in rows.indices {
            rows[index].lineIndices.sort { lines[$0].source.bounds.minX < lines[$1].source.bounds.minX }
        }
        return rows
    }

    private static func sharesRow(_ first: CGRect, _ second: CGRect) -> Bool {
        min(first.maxY, second.maxY) - max(first.minY, second.minY)
            > min(first.height, second.height) * 0.35
    }

    /// A persistent vertical gap separates reading columns. Work from glyph
    /// boxes because Vision can combine two columns into one observation, or
    /// split a TOC entry into its section number, title, and page number.
    private func gutterContext(first: CGPoint, last: CGPoint) -> GutterContext {
        guard typicalHeight > 0 else { return GutterContext(lines: [], gaps: [], boundaries: []) }
        // A cached OCR result may cover the whole page. A full-width running
        // header or figure elsewhere must not bridge this passage's gutter.
        let bottom = min(first.y, last.y) - typicalHeight * 0.8
        let top = max(first.y, last.y) + typicalHeight * 0.8
        let context = lines.indices.filter {
            lines[$0].source.bounds.maxY >= bottom && lines[$0].source.bounds.minY <= top
        }
        var includesLine = [Bool](repeating: false, count: lines.count)
        for index in context { includesLine[index] = true }
        guard let firstBox = glyphsByX.first(where: { includesLine[$0.line] })?.bounds else {
            return GutterContext(lines: context, gaps: [], boundaries: [])
        }
        // Book gutters are often only one or two text heights wide, even
        // across a broad page. A percentage of page/content width incorrectly
        // erases those gutters when long TOC titles approach the next column.
        let minimumGap = typicalHeight * 1.25
        var gaps: [ClosedRange<CGFloat>] = []
        var right = firstBox.maxX
        for glyph in glyphsByX where includesLine[glyph.line] {
            let box = glyph.bounds
            if box.minX - right >= minimumGap { gaps.append(right...box.minX) }
            right = max(right, box.maxX)
        }
        return GutterContext(lines: context,
            gaps: gaps.sorted { $0.upperBound - $0.lowerBound > $1.upperBound - $1.lowerBound },
            boundaries: gaps.map { ($0.lowerBound + $0.upperBound) / 2 }.sorted())
    }

    private func columnBounds(context: GutterContext, first: CGPoint, last: CGPoint) -> ClosedRange<CGFloat> {
        // Section labels and page numbers are part of their title's column.
        // Require letter-bearing content on both sides so their sometimes
        // wide spacing cannot split a TOC entry apart. The opposite column
        // may contain only one row within a short multiline gesture.
        func textRows(toLeftOf boundary: CGFloat, onLeft: Bool,
                      within horizontalRange: ClosedRange<CGFloat>) -> [CGRect] {
            var rows: [CGRect] = []
            for index in context.lines {
                let letters = lines[index].letters.filter { box in
                    horizontalRange.contains(box.midX) && (box.midX < boundary) == onLeft
                }
                guard letters.count >= 3 else { continue }
                let bounds = letters.reduce(CGRect.null) { $0.union($1) }
                if !rows.contains(where: { Self.sharesRow($0, bounds) }) {
                    rows.append(bounds)
                    if rows.count >= 2 { return rows }
                }
            }
            return rows
        }

        var lower = Self.unbounded.lowerBound
        var upper = Self.unbounded.upperBound
        // Resolve the broadest gutter first, then inspect only its chosen
        // column. Otherwise letters in the other column could make a smaller
        // title-to-page-number gap look like a second reading column.
        for gap in context.gaps {
            let boundary = (gap.lowerBound + gap.upperBound) / 2
            let startsOnLeft = first.x < boundary
            guard boundary > lower, boundary < upper,
                  startsOnLeft == (last.x < boundary) else { continue }
            let leftRows = textRows(toLeftOf: boundary, onLeft: true, within: lower...upper)
            let rightRows = textRows(toLeftOf: boundary, onLeft: false, within: lower...upper)
            guard let left = leftRows.first, let right = rightRows.first else { continue }
            // Even one row per column needs separation when their baselines
            // are staggered: a slightly diagonal drag must not snap its end
            // to the other column's closer row. One shared row already uses
            // the horizontal endpoints and needs no column inference.
            let sharedRow = Self.sharesRow(left, right)
            guard leftRows.count >= 2 || rightRows.count >= 2 || !sharedRow else { continue }
            if startsOnLeft { upper = min(upper, boundary) }
            else { lower = max(lower, boundary) }
        }
        return lower...upper
    }
}

/// OCR coordinates use lower-left-origin image pixels, independent of PDF
/// rotation and the reading order of the document's existing hidden text.
struct PDFVisualTextLine: Sendable {
    let text: String
    let bounds: CGRect
    let characterBounds: [CGRect?]

    func fragment(from minX: CGFloat, through maxX: CGFloat,
                  imageToPage: CGAffineTransform) -> PDFRegionTextFragment? {
        fragment(characters: Array(text), from: minX, through: maxX, imageToPage: imageToPage)
    }

    fileprivate func fragment(characters: [Character], from minX: CGFloat, through maxX: CGFloat,
                              imageToPage: CGAffineTransform) -> PDFRegionTextFragment? {
        guard characters.count == characterBounds.count else { return nil }
        let chosen = characterBounds.indices.filter { index in
            guard let rect = characterBounds[index], !rect.isEmpty, !rect.isNull else { return false }
            return rect.midX >= minX && rect.midX <= maxX
        }
        guard let first = chosen.first, let last = chosen.last else { return nil }
        let selectedText = String(characters[first...last]).trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedBounds = chosen.compactMap { characterBounds[$0] }.reduce(CGRect.null) { $0.union($1) }
        guard !selectedText.isEmpty, !selectedBounds.isNull else { return nil }
        return PDFRegionTextFragment(text: selectedText, bounds: selectedBounds.applying(imageToPage))
    }
}
