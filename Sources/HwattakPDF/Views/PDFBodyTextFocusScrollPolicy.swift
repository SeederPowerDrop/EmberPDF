// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Focus an explicitly requested text edit without changing its reading zoom.
/// Inputs use the native clip view's coordinates, which also handles PDFKit's
/// scaled document view and rotated PDF pages after conversion.
enum PDFBodyTextFocusScrollPolicy {
    static let firstLineFractionFromTop: CGFloat = 0.38

    static func proposedBounds(
        focusing lineRects: [CGRect],
        viewport: CGRect,
        isFlipped: Bool
    ) -> CGRect? {
        guard isValid(viewport), viewport.width > 0, viewport.height > 0 else { return nil }
        let lines = lineRects.filter { isValid($0) && !$0.isEmpty }
        guard let first = lines.min(by: { left, right in
            if abs(left.midY - right.midY) < 0.01 { return left.minX < right.minX }
            return isFlipped ? left.midY < right.midY : left.midY > right.midY
        }) else { return nil }
        // Center the first selected line horizontally. Native NSClipView
        // constraining decides the valid range at either document edge.
        let yFraction = isFlipped ? firstLineFractionFromTop : 1 - firstLineFractionFromTop
        return CGRect(x: first.midX - viewport.width / 2,
                      y: first.midY - viewport.height * yFraction,
                      width: viewport.width, height: viewport.height)
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}
