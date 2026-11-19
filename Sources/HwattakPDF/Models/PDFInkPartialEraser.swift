// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Widths describe rendered line segments, not pressure samples. A one-point
/// stroke uses one width for its dot; every other stroke has points.count - 1.
struct PDFInkStrokeGeometry: Codable, Equatable {
    var points: [CGPoint]
    var widths: [CGFloat]
    var dash: PDFInkDash? = nil

    var isValid: Bool {
        !points.isEmpty && points.count <= PressureInkAnnotation.maximumPoints
            && widths.count == max(1, points.count - 1)
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }
            && widths.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 256 }
            && validDash
    }

    private var validDash: Bool {
        guard let dash else { return true }
        guard dash.isValid else { return false }
        return dashExpansionCount.isFinite && dashExpansionCount <= 16_384
    }

    var dashExpansionCount: CGFloat {
        guard let dash, points.count > 1 else { return 0 }
        // Bound work before CoreGraphics expands a dashed path. A malformed
        // imported page must not request millions of tiny dash subpaths.
        var length: CGFloat = 0
        for index in 1..<points.count {
            length += hypot(points[index].x - points[index - 1].x,
                            points[index].y - points[index - 1].y)
        }
        return length / dash.period
    }
}

/// Pure annotation replacement planning. Authorization, page identity, undo,
/// and the gesture transaction remain the workspace's responsibility.
enum PDFInkPartialEraser {
    enum Result {
        case unchanged
        case unsupported
        case replaced([PDFAnnotation])
    }

    static func supports(_ annotation: PDFAnnotation) -> Bool {
        if PressureInkAnnotation.geometry(of: annotation) != nil { return true }
        return nativePaths(annotation) != nil
    }

    static func replacements(
        for annotation: PDFAnnotation,
        from start: CGPoint,
        to end: CGPoint,
        radius: CGFloat
    ) -> Result {
        guard finite(start), finite(end), radius.isFinite, radius > 0, radius <= 512 else { return .unsupported }
        if let pressure = PressureInkAnnotation.geometry(of: annotation) {
            var fragments: [PDFInkStrokeGeometry] = []
            var changed = false
            for stroke in pressure.strokes {
                let result = split(stroke, from: start, to: end, radius: radius)
                changed = changed || result.changed
                fragments.append(contentsOf: result.fragments)
            }
            guard changed else { return .unchanged }
            guard !fragments.isEmpty else { return .replaced([]) }
            guard let replacement = PressureInkAnnotation(strokes: fragments, color: pressure.color,
                style: pressure.style, options: pressure.options) else { return .unsupported }
            copyMetadata(from: annotation, to: replacement)
            return .replaced([replacement])
        }
        guard let paths = nativePaths(annotation) else { return .unsupported }
        let width = annotation.border?.lineWidth ?? 1
        var remaining = PressureInkAnnotation.maximumPoints
        var rebuilt: [NSBezierPath] = []
        var survivingGeometry: [PDFInkStrokeGeometry] = []
        var changed = false
        for path in paths {
            guard let strokes = flatten(path, origin: annotation.bounds.origin, width: width, remaining: &remaining) else { return .unsupported }
            var pathChanged = false
            var fragments: [PDFInkStrokeGeometry] = []
            for stroke in strokes {
                let result = split(stroke, from: start, to: end, radius: radius)
                pathChanged = pathChanged || result.changed
                fragments.append(contentsOf: result.fragments)
            }
            survivingGeometry.append(contentsOf: fragments)
            if !pathChanged {
                guard let copy = path.copy() as? NSBezierPath else { return .unsupported }
                rebuilt.append(copy)
                continue
            }
            changed = true
            for fragment in fragments {
                let replacement = NSBezierPath()
                replacement.lineCapStyle = path.lineCapStyle
                replacement.lineJoinStyle = path.lineJoinStyle
                replacement.lineWidth = width
                for (index, point) in fragment.points.enumerated() {
                    let local = CGPoint(x: point.x - annotation.bounds.minX, y: point.y - annotation.bounds.minY)
                    if index == 0 { replacement.move(to: local) } else { replacement.line(to: local) }
                }
                if fragment.points.count == 1 { replacement.line(to: replacement.currentPoint) }
                rebuilt.append(replacement)
            }
        }
        guard changed else { return .unchanged }
        guard !rebuilt.isEmpty else { return .replaced([]) }
        // PDFKit drops native Ink /C alpha while saving. Use an appearance
        // for translucent imported ink too, including every untouched path.
        // Curves retain the same bounded 0.15pt flattening tolerance; widths
        // and one shared opacity layer are preserved across all subpaths.
        if annotation.color.alphaComponent < 1 {
            // A new appearance must not expose parts previously clipped by
            // the imported Ink annotation's rectangle, including end caps.
            guard survivingGeometry.allSatisfy({ stroke in
                let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
                guard let minX = xs.min(), let maxX = xs.max(),
                      let minY = ys.min(), let maxY = ys.max(), let width = stroke.widths.max() else { return false }
                let painted = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    .insetBy(dx: -width / 2, dy: -width / 2)
                return annotation.bounds.contains(painted)
            }) else { return .unsupported }
            guard let replacement = PressureInkAnnotation(strokes: survivingGeometry, color: annotation.color) else { return .unsupported }
            copyMetadata(from: annotation, to: replacement)
            return .replaced([replacement])
        }
        guard rebuilt.count <= 512, let replacement = annotation.copy() as? PDFAnnotation else { return .unsupported }
        replacement.page = nil
        for path in replacement.paths ?? [] { replacement.remove(path) }
        replacement.removeValue(forAnnotationKey: .appearanceDictionary)
        replacement.removeValue(forAnnotationKey: .appearanceState)
        for path in rebuilt { replacement.add(path) }
        replacement.userName = annotation.userName
        return .replaced([replacement])
    }

    private static func copyMetadata(from source: PDFAnnotation, to destination: PDFAnnotation) {
        destination.contents = source.contents
        destination.userName = source.userName
        destination.modificationDate = source.modificationDate
        destination.shouldDisplay = source.shouldDisplay
        destination.shouldPrint = source.shouldPrint
        if let name = source.value(forAnnotationKey: .name) { destination.setValue(name, forAnnotationKey: .name) }
    }

    private static func nativePaths(_ annotation: PDFAnnotation) -> [NSBezierPath]? {
        guard annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Ink",
              let paths = annotation.paths, !paths.isEmpty, paths.count <= 512,
              finite(annotation.bounds.origin), annotation.bounds.width.isFinite, annotation.bounds.height.isFinite,
              annotation.bounds.width >= 0, annotation.bounds.height >= 0 else { return nil }
        let width = annotation.border?.lineWidth ?? 1
        guard width.isFinite, width > 0, width <= 256,
              annotation.border?.style != .dashed else { return nil }
        return paths
    }

    /// Intersection of a stroke segment with a swept disk is an interval: the
    /// capsule is convex. Endpoint disks plus its central rectangle yield the
    /// exact interval without missing fast pointer movement between events.
    static func split(_ stroke: PDFInkStrokeGeometry, from start: CGPoint, to end: CGPoint, radius: CGFloat)
        -> (changed: Bool, fragments: [PDFInkStrokeGeometry]) {
        guard stroke.isValid, finite(start), finite(end), radius.isFinite, radius > 0 else { return (false, [stroke]) }
        if stroke.points.count == 1 {
            let erased = distance(stroke.points[0], toSegmentFrom: start, to: end) <= radius + stroke.widths[0] / 2
            return (erased, erased ? [] : [stroke])
        }
        var fragments: [PDFInkStrokeGeometry] = []
        var current = PDFInkStrokeGeometry(points: [], widths: [])
        var changed = false
        func flush() {
            if !current.points.isEmpty { fragments.append(current) }
            current = PDFInkStrokeGeometry(points: [], widths: [])
        }
        func keep(_ first: CGPoint, _ last: CGPoint, width: CGFloat, distance: CGFloat) {
            guard hypot(last.x - first.x, last.y - first.y) > 0.00001 else { return }
            if let previous = current.points.last, hypot(previous.x - first.x, previous.y - first.y) > 0.00001 { flush() }
            if current.points.isEmpty {
                current.points.append(first)
                current.dash = stroke.dash?.advanced(by: distance)
            }
            current.points.append(last)
            current.widths.append(width)
        }
        var travelled: CGFloat = 0
        for index in 1..<stroke.points.count {
            let first = stroke.points[index - 1], last = stroke.points[index]
            let width = stroke.widths[index - 1]
            let length = hypot(last.x - first.x, last.y - first.y)
            defer { travelled += length }
            // The extra fraction avoids antialiasing remnants along the cut.
            if let cut = interval(first, last, start, end, radius + width / 2 + 0.01) {
                changed = true
                if cut.lowerBound > 0 { keep(first, interpolate(first, last, cut.lowerBound), width: width, distance: travelled) }
                flush()
                if cut.upperBound < 1 { keep(interpolate(first, last, cut.upperBound), last, width: width,
                    distance: travelled + length * cut.upperBound) }
            } else {
                keep(first, last, width: width, distance: travelled)
            }
        }
        flush()
        return (changed, changed ? fragments : [stroke])
    }

    private static func interval(_ p: CGPoint, _ q: CGPoint, _ a: CGPoint, _ b: CGPoint, _ radius: CGFloat) -> ClosedRange<CGFloat>? {
        let vx = q.x - p.x, vy = q.y - p.y
        let lengthSquared = vx * vx + vy * vy
        if lengthSquared < 0.0000000001 {
            return distance(p, toSegmentFrom: a, to: b) <= radius ? 0...1 : nil
        }
        var intervals: [ClosedRange<CGFloat>] = []
        for center in [a, b] {
            let dx = p.x - center.x, dy = p.y - center.y
            let projection = dx * vx + dy * vy
            let discriminant = projection * projection - lengthSquared * (dx * dx + dy * dy - radius * radius)
            if discriminant > 0 {
                let root = sqrt(discriminant)
                let low = max(0, (-projection - root) / lengthSquared)
                let high = min(1, (-projection + root) / lengthSquared)
                if high > low { intervals.append(low...high) }
            }
        }
        let length = hypot(b.x - a.x, b.y - a.y)
        if length > 0.000001 {
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            var low: CGFloat = 0, high: CGFloat = 1
            func clip(_ position: CGFloat, _ velocity: CGFloat, _ minimum: CGFloat, _ maximum: CGFloat) -> Bool {
                if abs(velocity) < 0.000000001 { return position >= minimum && position <= maximum }
                let t0 = (minimum - position) / velocity, t1 = (maximum - position) / velocity
                low = max(low, min(t0, t1)); high = min(high, max(t0, t1))
                return high > low
            }
            let dx = p.x - a.x, dy = p.y - a.y
            if clip(dx * ux + dy * uy, vx * ux + vy * uy, 0, length)
                && clip(-dx * uy + dy * ux, -vx * uy + vy * ux, -radius, radius) {
                intervals.append(low...high)
            }
        }
        guard let low = intervals.map(\.lowerBound).min(), let high = intervals.map(\.upperBound).max() else { return nil }
        return low...high
    }

    private static func flatten(_ path: NSBezierPath, origin: CGPoint, width: CGFloat, remaining: inout Int) -> [PDFInkStrokeGeometry]? {
        guard path.elementCount <= PressureInkAnnotation.maximumPoints else { return nil }
        var strokes: [PDFInkStrokeGeometry] = []
        var points: [CGPoint] = []
        var hasDrawing = false
        var failed = false
        func append(_ point: CGPoint) {
            guard finite(point), remaining > 0 else { failed = true; return }
            if let previous = points.last, previous == point { return }
            points.append(point); remaining -= 1
        }
        func finish() {
            // AppKit may append a move after close(). It positions the next
            // contour and must not become a visible dot in a replacement.
            if !points.isEmpty, hasDrawing || path.elementCount == 1 {
                strokes.append(PDFInkStrokeGeometry(points: points, widths: Array(repeating: width, count: max(1, points.count - 1))))
            }
            points = []
            hasDrawing = false
        }
        func curve(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, depth: Int) {
            guard !failed else { return }
            let flatness = max(distance(p1, toSegmentFrom: p0, to: p3), distance(p2, toSegmentFrom: p0, to: p3))
            if flatness <= 0.15 { append(p3); return }
            guard depth < 16 else { failed = true; return }
            let a = interpolate(p0, p1, 0.5), b = interpolate(p1, p2, 0.5), c = interpolate(p2, p3, 0.5)
            let d = interpolate(a, b, 0.5), e = interpolate(b, c, 0.5), mid = interpolate(d, e, 0.5)
            curve(p0, a, d, mid, depth: depth + 1)
            curve(mid, e, c, p3, depth: depth + 1)
        }
        var associated = [CGPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            let element = path.element(at: index, associatedPoints: &associated)
            let p = associated.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            switch element {
            case .moveTo: finish(); append(p[0])
            case .lineTo: guard !points.isEmpty else { return nil }; hasDrawing = true; append(p[0])
            case .cubicCurveTo:
                guard let first = points.last, p.allSatisfy(finite) else { return nil }
                hasDrawing = true
                curve(first, p[0], p[1], p[2], depth: 0)
            case .quadraticCurveTo:
                guard let first = points.last, p[0...1].allSatisfy(finite) else { return nil }
                hasDrawing = true
                curve(first, interpolate(first, p[0], 2 / 3), interpolate(p[1], p[0], 2 / 3), p[1], depth: 0)
            case .closePath: if let first = points.first { append(first) }; finish()
            @unknown default: return nil
            }
            if failed { return nil }
        }
        finish()
        return strokes
    }

    private static func finite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
    }
    private static func interpolate(_ first: CGPoint, _ last: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: first.x + (last.x - first.x) * t, y: first.y + (last.y - first.y) * t)
    }
    private static func distance(_ point: CGPoint, toSegmentFrom first: CGPoint, to last: CGPoint) -> CGFloat {
        let dx = last.x - first.x, dy = last.y - first.y
        let denominator = dx * dx + dy * dy
        let t = denominator > 0 ? max(0, min(1, ((point.x - first.x) * dx + (point.y - first.y) * dy) / denominator)) : 0
        let closest = interpolate(first, last, t)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}
