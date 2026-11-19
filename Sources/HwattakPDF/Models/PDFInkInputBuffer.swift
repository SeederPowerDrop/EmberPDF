// SPDX-License-Identifier: MPL-2.0

import AppKit

/// A gesture keeps its initial tool settings and builds freehand widths one
/// segment at a time. Redrawing never re-filters the entire pointer history.
struct PDFInkInputBuffer {
    let settings: InkSettings
    private(set) var points: [CGPoint] = []
    private(set) var pressures: [CGFloat] = []
    private(set) var geometry: PDFInkStrokeGeometry?
    private(set) var paintedBounds = CGRect.null
    private var segmentBounds: [CGRect] = []
    private var segmentStartDistances: [CGFloat] = []
    private var capturedLength: CGFloat = 0
    /// Work counter used to verify that ordinary append cost stays constant.
    private(set) var widthSampleCount = 0

    init(settings: InkSettings) {
        self.settings = settings
    }

    /// Returns the area whose previous preview must be repainted. Shape tools
    /// replace their outline; freehand extends only the last segment.
    @discardableResult
    mutating func append(_ point: CGPoint, pressure: CGFloat) -> CGRect {
        guard point.x.isFinite, point.y.isFinite, pressure.isFinite else { return .null }
        let pressure = min(1, max(0, pressure))
        if settings.drawingOptions.shape != .freehand {
            let previousBounds = paintedBounds
            if points.isEmpty {
                points = [point]; pressures = [pressure]
            } else if points.count == 1 {
                points.append(point); pressures.append(pressure)
            } else {
                points[1] = point; pressures[1] = pressure
            }
            rebuild()
            return previousBounds.union(paintedBounds)
        }

        var invalidated = CGRect.null
        if points.count >= PressureInkAnnotation.maximumPoints {
            invalidated = paintedBounds
            // Preserve both endpoints when bounded capture compacts a very
            // long stroke; otherwise the last visible segment would vanish.
            var indices = Array(stride(from: 0, to: points.count, by: 2))
            if indices.last != points.count - 1 { indices.append(points.count - 1) }
            points = indices.map { points[$0] }
            pressures = indices.map { pressures[$0] }
            rebuild()
        }

        let tailPoints = points.last.map { [$0, point] } ?? [point]
        let tailPressures = pressures.last.map { [$0, pressure] } ?? [pressure]
        guard let tail = PDFInkStrokeRenderer.stroke(points: tailPoints, pressures: tailPressures,
            width: settings.width, style: settings.style, options: settings.drawingOptions) else { return invalidated }
        let tailLength = points.last.map { hypot(point.x - $0.x, point.y - $0.y) } ?? 0
        if let dash = tail.dash, (capturedLength + tailLength) / dash.period > 16_384 { return invalidated }
        widthSampleCount += tailPoints.count
        let tailBounds = bounds(of: tail)
        // The initial dot can be wider than the first fountain pen segment.
        if points.count == 1 { invalidated = invalidated.union(paintedBounds) }
        if geometry == nil {
            geometry = tail
            segmentBounds = [tailBounds]
            segmentStartDistances = [0]
        } else {
            if points.count == 1 {
                geometry?.widths.removeAll(keepingCapacity: true)
                segmentBounds.removeAll(keepingCapacity: true)
                segmentStartDistances.removeAll(keepingCapacity: true)
            }
            geometry?.points.append(point)
            geometry?.widths.append(tail.widths[0])
            segmentBounds.append(tailBounds)
            segmentStartDistances.append(capturedLength)
        }
        points.append(point)
        pressures.append(pressure)
        capturedLength += tailLength
        paintedBounds = paintedBounds.union(tailBounds)
        return invalidated.union(tailBounds)
    }

    /// Some tablets first identify themselves after mouse-down. Update the
    /// earlier mouse samples once instead of changing the active tool settings.
    @discardableResult
    mutating func promoteToPressure(_ pressure: CGFloat) -> CGRect {
        guard pressure.isFinite else { return .null }
        let previousBounds = paintedBounds
        pressures = Array(repeating: min(1, max(0, pressure)), count: points.count)
        rebuild()
        return previousBounds.union(paintedBounds)
    }

    /// Repaint every crossing inside the invalidated area, but avoid sending
    /// thousands of distant segments through Core Graphics on each movement.
    /// A dashed fragment carries the phase at its original start, so clipping
    /// never makes its dashes slide as the pointer moves.
    func strokes(intersecting dirtyBounds: CGRect) -> [PDFInkStrokeGeometry] {
        guard let geometry, paintedBounds.intersects(dirtyBounds) else { return [] }
        guard settings.drawingOptions.shape == .freehand,
              geometry.points.count > 1,
              !dirtyBounds.contains(paintedBounds) else { return [geometry] }
        var runs: [PDFInkStrokeGeometry] = []
        var start: Int?
        for index in segmentBounds.indices {
            if segmentBounds[index].intersects(dirtyBounds) {
                if start == nil { start = index }
            } else if let first = start {
                runs.append(PDFInkStrokeGeometry(points: Array(geometry.points[first...index]),
                    widths: Array(geometry.widths[first..<index]),
                    dash: geometry.dash?.advanced(by: segmentStartDistances[first])))
                start = nil
            }
        }
        if let first = start {
            runs.append(PDFInkStrokeGeometry(points: Array(geometry.points[first...]),
                widths: Array(geometry.widths[first...]),
                dash: geometry.dash?.advanced(by: segmentStartDistances[first])))
        }
        return runs
    }

    private mutating func rebuild() {
        geometry = PDFInkStrokeRenderer.stroke(points: points, pressures: pressures,
            width: settings.width, style: settings.style, options: settings.drawingOptions)
        widthSampleCount += points.count
        paintedBounds = geometry.map(bounds(of:)) ?? .null
        segmentBounds = []
        segmentStartDistances = []
        capturedLength = 0
        if let geometry {
            if geometry.points.count == 1 {
                segmentBounds = [paintedBounds]
                segmentStartDistances = [0]
            } else {
                segmentBounds = geometry.widths.indices.map { index in
                    segmentStartDistances.append(capturedLength)
                    capturedLength += hypot(geometry.points[index + 1].x - geometry.points[index].x,
                                            geometry.points[index + 1].y - geometry.points[index].y)
                    return bounds(of: PDFInkStrokeGeometry(points: Array(geometry.points[index...index + 1]),
                        widths: [geometry.widths[index]]))
                }
            }
        }
    }

    private func bounds(of stroke: PDFInkStrokeGeometry) -> CGRect {
        let padding = (stroke.widths.max() ?? settings.width) / 2 + 1
        return stroke.points.reduce(CGRect.null) {
            $0.union(CGRect(x: $1.x - padding, y: $1.y - padding,
                           width: padding * 2, height: padding * 2))
        }
    }
}
