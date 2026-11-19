// SPDX-License-Identifier: MPL-2.0

import CoreGraphics

/// Quartz subsets can append an unpainted move after a glyph's final closed
/// contour. Compare the actual filled outline without changing any coordinate,
/// curve, contour order, or advance. Font permission is checked by the caller.
enum PDFGlyphOutlineIdentity {
    static let maximumCanonicalElements = 4096

    static func matches(_ left: CGPath, _ right: CGPath) -> Bool {
        if left == right { return true }
        guard let a = closedOutline(left), let b = closedOutline(right) else { return false }
        return a == b
    }

    /// Source geometry uses the same bounded, filled-outline canonical view;
    /// unpainted trailing moves cannot expand an original ink declaration.
    static func closedPaintBounds(_ path: CGPath) -> CGRect? {
        guard let elements = closedOutline(path) else { return nil }
        let painted = CGMutablePath()
        var contourOpen = false
        for element in elements {
            switch element.kind {
            case CGPathElementType.moveToPoint.rawValue:
                guard !contourOpen else { return nil }; contourOpen = true
                painted.move(to: element.points[0])
            case CGPathElementType.addLineToPoint.rawValue: painted.addLine(to: element.points[0])
            case CGPathElementType.addQuadCurveToPoint.rawValue:
                painted.addQuadCurve(to: element.points[1], control: element.points[0])
            case CGPathElementType.addCurveToPoint.rawValue:
                painted.addCurve(to: element.points[2], control1: element.points[0], control2: element.points[1])
            case CGPathElementType.closeSubpath.rawValue:
                guard contourOpen else { return nil }; contourOpen = false; painted.closeSubpath()
            default: return nil
            }
        }
        let bounds = painted.boundingBoxOfPath
        guard !bounds.isNull, [bounds.minX,bounds.minY,bounds.maxX,bounds.maxY].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    private struct Element: Equatable {
        let kind: Int32
        let points: [CGPoint]
    }

    private static func closedOutline(_ path: CGPath) -> [Element]? {
        var elements: [Element] = []
        var valid = true
        path.applyWithBlock { pointer in
            guard valid, elements.count < maximumCanonicalElements else { valid = false; return }
            let element = pointer.pointee
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: valid = false; return
            }
            let points = (0..<count).map { element.points[$0] }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { valid = false; return }
            elements.append(Element(kind: element.type.rawValue, points: points))
        }
        guard valid else { return nil }
        while elements.last?.kind == CGPathElementType.moveToPoint.rawValue { elements.removeLast() }
        guard elements.last?.kind == CGPathElementType.closeSubpath.rawValue,
              elements.contains(where: {
                  $0.kind == CGPathElementType.addLineToPoint.rawValue
                      || $0.kind == CGPathElementType.addQuadCurveToPoint.rawValue
                      || $0.kind == CGPathElementType.addCurveToPoint.rawValue
              }) else { return nil }
        return elements
    }
}
