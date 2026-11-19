// SPDX-License-Identifier: MPL-2.0

import AppKit

/// A gallery owns only bounded pixels, never a PDFDocument/PDFPage graph.
struct PDFDocumentGalleryPreview {
    let image: NSImage
    let pageIndex: Int
    let pageCount: Int
    let revision: UUID
    let pixelSize: CGSize
}

enum PDFDocumentGalleryRenderingPolicy {
    static let maximumDimension: CGFloat = 1_200
    static let maximumPixelCount: CGFloat = 1_000_000
    static let maximumCachedPreviews = 32
    static let maximumCacheBytes = 24 * 1_024 * 1_024

    static func targetSize(pageBounds: CGRect, rotation: Int, width: CGFloat) -> CGSize {
        let proposed = PDFThumbnailRenderingPolicy(efficientRenderingEnabled: true)
            .targetSize(pageBounds: pageBounds, rotation: rotation, requestedWidth: width)
        return PDFRasterBudget(maximumDimension: maximumDimension,
                               maximumPixelCount: maximumPixelCount)
            .boundedPixelSize(logicalSize: proposed, scale: 1)
    }

    static func widthBucket(_ width: CGFloat) -> Int {
        let finite = width.isFinite ? width : 480
        return Int((min(maximumDimension, max(80, finite)) / 32).rounded(.up)) * 32
    }
}
