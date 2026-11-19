// SPDX-License-Identifier: MPL-2.0

import AppKit

/// One renderer for the PDF appearance, live stroke, and settings preview.
/// Geometry is bounded by the capture limit; pencil grain is a repeating
/// vector pattern, so a long stroke never allocates a bitmap of the page.
enum PDFInkStrokeRenderer {
    static func stroke(points: [CGPoint], pressures: [CGFloat], width: CGFloat,
                       style: PDFInkStyle, options: PDFInkDrawingOptions = .init()) -> PDFInkStrokeGeometry? {
        guard !points.isEmpty, points.count <= PressureInkAnnotation.maximumPoints,
              points.count == pressures.count, width.isFinite, (0.2...32).contains(width),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }),
              pressures.allSatisfy(\.isFinite) else { return nil }
        let shapePoints = canonicalPoints(points, shape: options.shape)
        let shapePressure = options.shape == .freehand ? pressures
            : options.shape == .line && shapePoints.count == 2 ? [pressures[0], pressures[pressures.count - 1]]
            : Array(repeating: pressures[pressures.count - 1], count: shapePoints.count)
        let points = shapePoints
        let pressure = shapePressure.map { min(1, max(0, $0)) }
        var widths: [CGFloat] = []
        for index in 0..<max(1, points.count - 1) {
            let p = points.count == 1 ? pressure[0] : (pressure[index] + pressure[index + 1]) / 2
            let factor: CGFloat
            switch style {
            case .ink: factor = 0.2 + 0.8 * p
            case .pencil: factor = 0.35 + 0.65 * p
            case .highlighter: factor = 1
            case .fountain:
                let angle = points.count == 1 ? CGFloat.pi / 2
                    : atan2(points[index + 1].y - points[index].y, points[index + 1].x - points[index].x)
                // A broad nib held at 45°: direction affects the width even
                // with a mouse, while tablet pressure remains expressive.
                factor = (0.22 + 0.78 * abs(sin(angle - .pi / 4))) * (0.4 + 0.6 * p)
            }
            widths.append(width * factor)
        }
        let stroke = PDFInkStrokeGeometry(points: points, widths: widths,
            dash: options.pattern == .dashed ? PDFInkDash(length: max(2, width * 3)) : nil)
        return stroke.isValid ? stroke : nil
    }

    static func draw(strokes: [PDFInkStrokeGeometry], color: NSColor,
                     style: PDFInkStyle, options: PDFInkDrawingOptions = .init(), in context: CGContext) {
        guard let rgb = color.usingColorSpace(.deviceRGB), !strokes.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let paintedBounds = strokes.reduce(CGRect.null) { bounds, stroke in
            let padding = (stroke.widths.max() ?? 1) / 2 + 1
            return stroke.points.reduce(bounds) { $0.union(CGRect(x: $1.x - padding, y: $1.y - padding,
                width: padding * 2, height: padding * 2)) }
        }
        guard !paintedBounds.isNull, !paintedBounds.isInfinite else { return }
        context.clip(to: paintedBounds)
        // Paint directly into the page: PDFKit serializes transparency layers
        // with a Generic RGB blending space that changes saturated pen colors.
        // One filled outline/pattern applies opacity once at self-intersections.
        context.setBlendMode(style == .highlighter ? .multiply : .normal)
        context.setAlpha(rgb.alphaComponent)
        let opaque = rgb.withAlphaComponent(1)
        context.setStrokeColor(opaque.cgColor)
        context.setFillColor(opaque.cgColor)
        let cap: CGLineCap = style == .highlighter && options.highlighterTip == .square ? .butt : .round
        context.setLineCap(cap)
        context.setLineJoin(.round)

        if style == .highlighter {
            let outline = CGMutablePath()
            for stroke in strokes {
                if stroke.dash != nil {
                    appendOutline(stroke, to: outline, cap: cap)
                    continue
                }
                let width = stroke.widths[0]
                if stroke.points.count == 1 {
                    let point = stroke.points[0]
                    let dot = CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width)
                    if cap == .butt { outline.addRect(dot) } else { outline.addEllipse(in: dot) }
                } else {
                    let path = CGMutablePath()
                    path.move(to: stroke.points[0])
                    for point in stroke.points.dropFirst() { path.addLine(to: point) }
                    if stroke.points.count > 2, stroke.points.first == stroke.points.last { path.closeSubpath() }
                    outline.addPath(path.copy(strokingWithWidth: width, lineCap: cap,
                                              lineJoin: .round, miterLimit: 10))
                }
            }
            context.addPath(outline)
            context.fillPath()
            return
        }

        if style != .pencil, rgb.alphaComponent < 1 || strokes.contains(where: { $0.dash != nil }) {
            let outline = CGMutablePath()
            for stroke in strokes { appendOutline(stroke, to: outline) }
            context.addPath(outline)
            context.fillPath()
            return
        }

        if style == .pencil, let pattern = makePencilPattern(red: rgb.redComponent,
                green: rgb.greenComponent, blue: rgb.blueComponent),
           let patternSpace = CGColorSpace(patternBaseSpace: nil) {
            let outline = CGMutablePath()
            for stroke in strokes { appendOutline(stroke, to: outline) }
            context.addPath(outline)
            context.clip()
            context.setFillColorSpace(patternSpace)
            var components: [CGFloat] = [1]
            context.setFillPattern(pattern, colorComponents: &components)
            context.fill(paintedBounds)
            return
        }

        for stroke in strokes {
            if stroke.points.count == 1 {
                let point = stroke.points[0], width = stroke.widths[0]
                let dot = CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width)
                context.fillEllipse(in: dot)
            } else {
                for index in 1..<stroke.points.count {
                    context.setLineWidth(stroke.widths[index - 1])
                    context.move(to: stroke.points[index - 1])
                    context.addLine(to: stroke.points[index])
                    context.strokePath()
                }
            }
        }
    }

    private static func appendOutline(_ stroke: PDFInkStrokeGeometry, to outline: CGMutablePath, cap: CGLineCap = .round) {
        if stroke.points.count == 1 {
            if let dash = stroke.dash, dash.phase >= dash.length { return }
            let point = stroke.points[0], width = stroke.widths[0]
            let dot = CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width)
            if cap == .butt { outline.addRect(dot) } else { outline.addEllipse(in: dot) }
            return
        }
        var distance: CGFloat = 0
        for index in 1..<stroke.points.count {
            let line = CGMutablePath()
            line.move(to: stroke.points[index - 1]); line.addLine(to: stroke.points[index])
            let path: CGPath
            if let dash = stroke.dash {
                path = line.copy(dashingWithPhase: dash.advanced(by: distance).phase, lengths: [dash.length, dash.gap])
                distance += hypot(stroke.points[index].x - stroke.points[index - 1].x,
                                  stroke.points[index].y - stroke.points[index - 1].y)
            } else { path = line }
            outline.addPath(path.copy(strokingWithWidth: stroke.widths[index - 1], lineCap: cap,
                lineJoin: .round, miterLimit: 10))
        }
    }

    private static func canonicalPoints(_ points: [CGPoint], shape: PDFInkShape) -> [CGPoint] {
        guard shape != .freehand, let first = points.first, let last = points.last else { return points }
        guard first != last else { return [first] }
        switch shape {
        case .freehand: return points
        case .line: return [first, last]
        case .rectangle:
            return [first, CGPoint(x: last.x, y: first.y), last, CGPoint(x: first.x, y: last.y), first]
        case .ellipse:
            let rx = abs(last.x - first.x) / 2, ry = abs(last.y - first.y) / 2
            guard rx > 0.001, ry > 0.001 else { return [first, last] }
            let center = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
            // A bounded vector polyline gives erasing the same boundary as
            // drawing, with subpixel chords at normal document dimensions.
            let radius = max(rx, ry)
            let estimate = Int(ceil(.pi / acos(max(-1, 1 - 0.1 / radius))))
            let count = min(512, max(32, ((estimate + 3) / 4) * 4))
            var ellipse = (0..<count).map { index in
                let angle = CGFloat(index) * 2 * .pi / CGFloat(count)
                return CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
            }
            ellipse.append(ellipse[0])
            return ellipse
        }
    }

    private final class PencilPatternTint {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        init(red: CGFloat, green: CGFloat, blue: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    private static func makePencilPattern(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGPattern? {
        let tint = Unmanaged.passRetained(PencilPatternTint(red: red, green: green, blue: blue))
        var callbacks = CGPatternCallbacks(version: 0, drawPattern: { info, context in
            guard let info else { return }
            let tint = Unmanaged<PencilPatternTint>.fromOpaque(info).takeUnretainedValue()
            // PDFKit records a color operator inside this cell's appearance.
            // An uncolored pattern loses its external tint when that happens;
            // a colored cell carries the intended RGB through save/reopen.
            context.setFillColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
            context.setAlpha(0.3)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            // Fixed grain anchored in PDF coordinates makes save/reopen and
            // partial erasure deterministic; unaffected ink does not shimmer.
            for row in 0..<12 {
                for column in 0..<12 {
                    let seed = (row * 37 + column * 71 + row * column * 13) % 97
                    let x = CGFloat(column) * 2 / 3 + CGFloat(seed % 5) * 0.035
                    let y = CGFloat(row) * 2 / 3 + CGFloat(seed % 7) * 0.023
                    context.setAlpha(0.3 + CGFloat(seed % 6) * 0.12)
                    let size = 0.22 + CGFloat(seed % 5) * 0.065
                    context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size * 1.4))
                }
            }
        }, releaseInfo: { info in
            guard let info else { return }
            Unmanaged<PencilPatternTint>.fromOpaque(info).release()
        })
        let pattern = CGPattern(info: tint.toOpaque(), bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
            matrix: .identity, xStep: 8, yStep: 8, tiling: .constantSpacing,
            isColored: true, callbacks: &callbacks)
        if pattern == nil { tint.release() }
        return pattern
    }
}
