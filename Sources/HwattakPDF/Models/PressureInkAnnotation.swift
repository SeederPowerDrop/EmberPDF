// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Vector appearance preserves variable width and opacity in ordinary PDF
/// readers. It is a Stamp appearance, not a native constant-width Ink path.
final class PressureInkAnnotation: PDFAnnotation {
    static let stampName = "HwattakPDFPressureInk"
    static let maximumPoints = 8_192
    private static let geometryKey = PDFAnnotationKey(rawValue: "/HwattakPDFInkGeometry")
    private static let maximumMetadataBytes = 1_048_576
    private let strokes: [PDFInkStrokeGeometry]
    private let sourceBounds: CGRect
    private let inkColor: NSColor
    private let inkStyle: PDFInkStyle
    private let drawingOptions: PDFInkDrawingOptions

    struct Geometry {
        let strokes: [PDFInkStrokeGeometry]
        let color: NSColor
        let style: PDFInkStyle
        let options: PDFInkDrawingOptions
    }

    private struct Payload: Codable {
        let version: Int
        let bounds: CGRect
        let strokes: [PDFInkStrokeGeometry]
        let rgba: [CGFloat]
        let style: PDFInkStyle?
        let options: PDFInkDrawingOptions?
    }

    convenience init?(points: [CGPoint], pressures: [CGFloat], width: CGFloat, color: NSColor,
                      style: PDFInkStyle = .ink, options: PDFInkDrawingOptions = .init()) {
        guard let stroke = PDFInkStrokeRenderer.stroke(points: points, pressures: pressures,
            width: width, style: style, options: options) else { return nil }
        self.init(strokes: [stroke], color: color, style: style, options: options)
    }

    init?(strokes: [PDFInkStrokeGeometry], color: NSColor, style: PDFInkStyle = .ink,
          options: PDFInkDrawingOptions = .init()) {
        guard Self.valid(strokes, options: options), let rgb = color.usingColorSpace(.deviceRGB),
              [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].allSatisfy(\.isFinite) else { return nil }
        self.strokes = strokes
        inkColor = rgb
        inkStyle = style
        drawingOptions = options
        let points = strokes.flatMap(\.points)
        let padding = (strokes.flatMap(\.widths).max() ?? 1) + 1
        let x = points.map(\.x), y = points.map(\.y)
        let bounds = CGRect(x: x.min()! - padding, y: y.min()! - padding,
            width: x.max()! - x.min()! + 2 * padding, height: y.max()! - y.min()! + 2 * padding)
        sourceBounds = bounds
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        PDFAnnotationPrivacy.clearImplicitAuthor(on: self)
        // Alpha belongs to the appearance, otherwise some readers apply it
        // twice while others discard it when serializing the /C entry.
        self.color = rgb.withAlphaComponent(1)
        shouldDisplay = true
        shouldPrint = true
        setValue(Self.stampName, forAnnotationKey: .iconName)
        let payload = Payload(version: 3, bounds: bounds, strokes: strokes,
            rgba: [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent], style: style, options: options)
        if let data = try? JSONEncoder().encode(payload), data.count <= Self.maximumMetadataBytes,
           let string = String(data: data, encoding: .utf8) {
            setValue(string, forAnnotationKey: Self.geometryKey)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Bounded shape metadata is only a geometry description. The workspace
    /// must independently authorize every erase, especially after reopening.
    static func geometry(of annotation: PDFAnnotation) -> Geometry? {
        if let live = annotation as? PressureInkAnnotation {
            return transformed(live.strokes, from: live.sourceBounds, to: annotation.bounds,
                color: live.inkColor, style: live.inkStyle, options: live.drawingOptions)
        }
        guard annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Stamp",
              (annotation.value(forAnnotationKey: .iconName) as? String)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) == stampName,
              let string = annotation.value(forAnnotationKey: geometryKey) as? String,
              string.utf8.count <= maximumMetadataBytes,
              let data = string.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (1...3).contains(payload.version), valid(payload.strokes, options: payload.options ?? .init()), payload.rgba.count == 4,
              payload.rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        let rgba = payload.rgba
        return transformed(payload.strokes, from: payload.bounds, to: annotation.bounds,
            color: NSColor(deviceRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]),
            style: payload.style ?? .ink, options: payload.options ?? .init())
    }

    private static func valid(_ strokes: [PDFInkStrokeGeometry], options: PDFInkDrawingOptions) -> Bool {
        !strokes.isEmpty && strokes.count <= 512
            && strokes.reduce(0, { $0 + $1.points.count }) <= maximumPoints
            && strokes.allSatisfy(\.isValid)
            && strokes.allSatisfy { (options.pattern == .dashed) == ($0.dash != nil) }
            && strokes.reduce(0, { $0 + $1.dashExpansionCount }) <= 16_384
    }

    private static func transformed(_ strokes: [PDFInkStrokeGeometry], from source: CGRect, to target: CGRect,
                                    color: NSColor, style: PDFInkStyle, options: PDFInkDrawingOptions) -> Geometry? {
        guard [source.minX, source.minY, source.width, source.height,
               target.minX, target.minY, target.width, target.height].allSatisfy(\.isFinite),
              source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return nil }
        let sx = target.width / source.width, sy = target.height / source.height
        // Nonuniformly stretched stamps have elliptical stroke widths, which
        // cannot be represented faithfully by this circular-stroke model.
        guard abs(sx - sy) <= max(sx, sy) * 0.0001 else { return nil }
        let moved = strokes.map { stroke in
            PDFInkStrokeGeometry(points: stroke.points.map {
                CGPoint(x: target.minX + ($0.x - source.minX) * sx,
                        y: target.minY + ($0.y - source.minY) * sy)
            }, widths: stroke.widths.map { $0 * sx }, dash: stroke.dash?.scaled(by: sx))
        }
        guard valid(moved, options: options) else { return nil }
        return Geometry(strokes: moved, color: color, style: style, options: options)
    }

    /// PDFAnnotation's Objective-C copy does not initialize subclass Swift
    /// storage, so copy every stroke and its opacity explicitly.
    override func copy(with zone: NSZone? = nil) -> Any {
        PressureInkAnnotation(copying: self)
    }

    private init(copying source: PressureInkAnnotation) {
        strokes = source.strokes
        sourceBounds = source.sourceBounds
        inkColor = source.inkColor
        inkStyle = source.inkStyle
        drawingOptions = source.drawingOptions
        var properties = source.annotationKeyValues
        properties.removeValue(forKey: PDFAnnotationKey.page.rawValue)
        properties.removeValue(forKey: PDFAnnotationKey.parent.rawValue)
        super.init(bounds: source.bounds, forType: .stamp, withProperties: properties)
        userName = source.userName
        page = nil
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let geometry = Self.geometry(of: self) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // PDFAnnotation receives a display-box context, while captured stroke
        // points remain in the page's unrotated coordinates. PDFKit applies
        // this transform for native Ink; custom appearances must apply it
        // themselves or releasing the pointer shifts/rotates the stroke.
        if let page { context.concatenate(page.transform(for: box)) }
        PDFInkStrokeRenderer.draw(strokes: geometry.strokes, color: geometry.color,
                                  style: geometry.style, options: geometry.options, in: context)
    }
}
