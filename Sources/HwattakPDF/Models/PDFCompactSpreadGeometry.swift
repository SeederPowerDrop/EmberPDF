// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// A continuous document made of individually fitted two-page rows. No page
/// boxes are changed: an unusually wide page only affects its own row.
struct PDFCompactSpreadGeometry {
    struct Row: Equatable {
        let pageIndex: Int
        let pageCount: Int
        let pageSizes: [CGSize]
        let scale: CGFloat
        let frame: CGRect
    }

    // These match the small, uniform native PDFView margins used by each row.
    static let pageMargin: CGFloat = 0
    static let rowSpacing: CGFloat = 4
    let rows: [Row]
    let contentSize: CGSize

    init(pageSizes: [CGSize], viewport: CGSize, zoom: CGFloat = 1,
         fitMode: PDFPageFitMode? = nil) {
        let viewport = CGSize(width: max(1, viewport.width), height: max(1, viewport.height))
        let safeZoom = zoom.isFinite ? min(20, max(0.05, zoom)) : 1
        var result: [Row] = []
        var y: CGFloat = 0
        var maximumWidth = viewport.width
        for index in stride(from: 0, to: pageSizes.count, by: 2) {
            let sizes = Array(pageSizes[index..<min(index + 2, pageSizes.count)]).map { size in
                CGSize(width: size.width.isFinite && size.width > 0 ? size.width : 612,
                       height: size.height.isFinite && size.height > 0 ? size.height : 792)
            }
            // PDFKit's paged layout includes both outside and inside margins.
            let width = sizes.reduce(0) { $0 + $1.width } + Self.pageMargin * CGFloat(sizes.count + 1) * 2
            let height = (sizes.map(\.height).max() ?? 792) + Self.pageMargin * 4
            let fit = fitMode == .height ? viewport.height / height : viewport.width / width
            let scale = min(20, max(0.05, fit * safeZoom))
            let rowSize = CGSize(width: ceil(width * scale), height: ceil(height * scale))
            result.append(Row(pageIndex: index, pageCount: sizes.count, pageSizes: sizes,
                              scale: scale, frame: CGRect(origin: CGPoint(x: 0, y: y), size: rowSize)))
            maximumWidth = max(maximumWidth, rowSize.width)
            y += rowSize.height + Self.rowSpacing
        }
        rows = result.map { row in
            var frame = row.frame
            frame.origin.x = (maximumWidth - frame.width) / 2
            return Row(pageIndex: row.pageIndex, pageCount: row.pageCount,
                       pageSizes: row.pageSizes, scale: row.scale, frame: frame)
        }
        contentSize = CGSize(width: maximumWidth, height: max(viewport.height, y - (result.isEmpty ? 0 : Self.rowSpacing)))
    }

    func rowIndex(at y: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].frame.maxY + Self.rowSpacing / 2 < y { low = middle + 1 }
            else { high = middle }
        }
        return low
    }

    func materializedRows(in visibleRect: CGRect) -> Range<Int> {
        guard let first = rowIndex(at: visibleRect.minY), let last = rowIndex(at: visibleRect.maxY) else { return 0..<0 }
        return max(0, first - 1)..<min(rows.count, last + 2)
    }
}
