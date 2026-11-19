// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

enum PDFSearchScrollAxis: Equatable {
    case vertical
    case horizontal
}

/// Geometry only: the view converts PDF hits into its document coordinates
/// before calling this policy, including page rotation and magnification.
enum PDFSearchScrollPolicy {
    static let maxSnapDistance: CGFloat = 18
    static let minSnapDistance: CGFloat = 0.75
    static let readingAnchorFraction: CGFloat = 0.28
    static let settleDelay: TimeInterval = 0.18
    static let fastScrollSpeed: CGFloat = 700
    private static let markerBinLength: CGFloat = 2

    /// Physical progress along the track, independent of the document origin.
    /// Vertical tracks run from top to bottom; horizontal tracks left to right.
    static func markerProgress(
        point: CGPoint,
        documentBounds: CGRect,
        axis: PDFSearchScrollAxis,
        isFlipped: Bool
    ) -> CGFloat? {
        guard point.x.isFinite, point.y.isFinite,
              documentBounds.origin.x.isFinite, documentBounds.origin.y.isFinite,
              documentBounds.size.width.isFinite, documentBounds.size.height.isFinite,
              documentBounds.size.width > 0, documentBounds.size.height > 0,
              documentBounds.maxX.isFinite, documentBounds.maxY.isFinite else { return nil }

        let coordinate: CGFloat
        let origin: CGFloat
        let length: CGFloat
        switch axis {
        case .vertical:
            coordinate = point.y
            origin = documentBounds.origin.y
            length = documentBounds.height
        case .horizontal:
            coordinate = point.x
            origin = documentBounds.origin.x
            length = documentBounds.width
        }
        let relative = (coordinate - origin) / length
        guard relative.isFinite else { return nil }
        let progress = axis == .vertical && !isFlipped ? 1 - relative : relative
        guard progress.isFinite else { return nil }
        return min(1, max(0, progress))
    }

    /// Signed delta to add to the viewport origin. `screenScale` is the number
    /// of screen points per document-coordinate unit, not the backing scale.
    /// Distant hits are never pulled into view and tiny offsets do not jitter.
    static func snapOffset(
        hitCoordinate: CGFloat,
        viewportOrigin: CGFloat,
        viewportLength: CGFloat,
        axis: PDFSearchScrollAxis,
        isFlipped: Bool,
        screenScale: CGFloat = 1
    ) -> CGFloat? {
        guard hitCoordinate.isFinite, viewportOrigin.isFinite,
              viewportLength.isFinite, viewportLength > 0,
              screenScale.isFinite, screenScale > 0 else { return nil }

        let fraction = axis == .vertical && !isFlipped
            ? 1 - readingAnchorFraction : readingAnchorFraction
        let anchor = viewportOrigin + viewportLength * fraction
        let offset = hitCoordinate - anchor
        let screenDistance = abs(offset) * screenScale
        guard anchor.isFinite, offset.isFinite, screenDistance.isFinite,
              screenDistance >= minSnapDistance,
              screenDistance <= maxSnapDistance else { return nil }
        return offset
    }

    /// Keep one real hit position per two track units so dense documents do
    /// not require drawing every search result. Invalid values are ignored.
    static func mergeMarkerProgresses(_ values: [CGFloat], trackLength: CGFloat) -> [CGFloat] {
        guard trackLength.isFinite, trackLength > 0 else { return [] }
        let progresses = values.filter(\.isFinite).map { min(1, max(0, $0)) }.sorted()
        var previousBin: CGFloat?
        var result: [CGFloat] = []
        for progress in progresses {
            // Keep the bin as a floating-point value: no overflowing Int
            // conversion even if a caller provides an extreme finite length.
            let bin = floor(progress * trackLength / markerBinLength)
            guard bin != previousBin else { continue }
            result.append(progress)
            previousBin = bin
        }
        return result
    }
}
