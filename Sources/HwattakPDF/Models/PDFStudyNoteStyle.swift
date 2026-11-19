// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Background alpha lives in the appearance stream: PDFKit drops the alpha of
/// the standard FreeText /C color on serialization. Metadata describes style,
/// and never grants editing permission to an imported annotation.
struct PDFStudyNoteStyle {
    static let metadataKey = PDFAnnotationKey(rawValue: "/EmberStudyNoteStyle")
    var bounds: CGRect
    var background: NSColor
    var foreground: NSColor
    var backgroundOpacity: CGFloat
    var fontSize: CGFloat

    private struct Payload: Codable {
        let version: Int
        let background: [CGFloat]
        let foreground: [CGFloat]
        let opacity: CGFloat
        let fontSize: CGFloat
        /// PDFKit converts fontColor through a calibrated color space when
        /// creating /DA. Keep the original sRGB only while that /DA is intact;
        /// a different editor's explicit text color still takes precedence.
        let foregroundDefaultAppearance: String?
    }

    init(annotation: PDFAnnotation) {
        bounds = annotation.bounds
        background = annotation.color.withAlphaComponent(1)
        foreground = (annotation.fontColor ?? .black).withAlphaComponent(1)
        backgroundOpacity = annotation.color.alphaComponent
        fontSize = annotation.font?.pointSize ?? 15
        if let raw = annotation.value(forAnnotationKey: Self.metadataKey) as? String,
           raw.utf8.count < 4_096, let data = raw.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.version == 1, payload.background.count == 3, payload.foreground.count == 3,
           (payload.background + payload.foreground + [payload.opacity]).allSatisfy({ $0.isFinite && (0...1).contains($0) }),
           payload.fontSize.isFinite, (6...96).contains(payload.fontSize) {
            backgroundOpacity = payload.opacity
            if let recorded = payload.foregroundDefaultAppearance, recorded.utf8.count <= 1_024,
               recorded == annotation.value(forAnnotationKey: .defaultAppearance) as? String {
                foreground = NSColor(srgbRed: payload.foreground[0], green: payload.foreground[1],
                                     blue: payload.foreground[2], alpha: 1)
            }
        }
    }

    init(bounds: CGRect, background: NSColor, foreground: NSColor, backgroundOpacity: CGFloat = 1, fontSize: CGFloat = 15) {
        self.bounds = bounds
        self.background = background
        self.foreground = foreground
        self.backgroundOpacity = backgroundOpacity
        self.fontSize = fontSize
    }

    func constrained(to pageBounds: CGRect) -> Self? {
        guard [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height, backgroundOpacity, fontSize,
               pageBounds.minX, pageBounds.minY, pageBounds.width, pageBounds.height].allSatisfy(\.isFinite),
              pageBounds.width > 0, pageBounds.height > 0,
              let background = background.usingColorSpace(.sRGB),
              let foreground = foreground.usingColorSpace(.sRGB) else { return nil }
        let width = min(pageBounds.width, max(24, bounds.width))
        let height = min(pageBounds.height, max(20, bounds.height))
        return Self(bounds: CGRect(x: min(max(bounds.minX, pageBounds.minX), pageBounds.maxX - width),
                                  y: min(max(bounds.minY, pageBounds.minY), pageBounds.maxY - height),
                                  width: width, height: height),
                    background: background.withAlphaComponent(1), foreground: foreground.withAlphaComponent(1),
                    backgroundOpacity: min(1, max(0, backgroundOpacity)), fontSize: min(96, max(6, fontSize)))
    }

    func apply(to annotation: PDFAnnotation) {
        annotation.bounds = bounds
        annotation.color = background.withAlphaComponent(1)
        annotation.fontColor = foreground.withAlphaComponent(1)
        annotation.font = NSFont(name: annotation.font?.fontName ?? "", size: fontSize) ?? .systemFont(ofSize: fontSize)
        guard let bg = background.usingColorSpace(.sRGB), let fg = foreground.usingColorSpace(.sRGB) else { return }
        let payload = Payload(version: 1, background: [bg.redComponent, bg.greenComponent, bg.blueComponent],
                              foreground: [fg.redComponent, fg.greenComponent, fg.blueComponent],
                              opacity: backgroundOpacity, fontSize: fontSize,
                              foregroundDefaultAppearance: annotation.value(forAnnotationKey: .defaultAppearance) as? String)
        if let data = try? JSONEncoder().encode(payload), let raw = String(data: data, encoding: .utf8) {
            annotation.setValue(raw, forAnnotationKey: Self.metadataKey)
        }
    }

    func matches(_ other: Self) -> Bool {
        bounds == other.bounds && abs(backgroundOpacity - other.backgroundOpacity) < 0.0001
            && abs(fontSize - other.fontSize) < 0.001
            && PDFTextColor(background).visuallyEquals(PDFTextColor(other.background))
            && PDFTextColor(foreground).visuallyEquals(PDFTextColor(other.foreground))
    }
}

/// Keeps the interoperable FreeText subtype and ordinary contents/font data,
/// with a vector appearance for independently transparent note backgrounds.
final class PDFStudyNoteAnnotation: PDFAnnotation {
    init(copying original: PDFAnnotation, style: PDFStudyNoteStyle) {
        var properties = original.annotationKeyValues
        for key in ["/P", "/Parent", "/AP"] { properties.removeValue(forKey: key) }
        super.init(bounds: style.bounds, forType: .freeText, withProperties: properties)
        contents = original.contents
        font = original.font
        fontColor = original.fontColor
        alignment = original.alignment
        userName = original.userName
        shouldDisplay = original.shouldDisplay
        shouldPrint = original.shouldPrint
        modificationDate = original.modificationDate
        style.apply(to: self)
    }

    init(bounds: CGRect, contents: String, font: NSFont, background: NSColor, foreground: NSColor) {
        super.init(bounds: bounds, forType: .freeText, withProperties: nil)
        PDFAnnotationPrivacy.clearImplicitAuthor(on: self)
        self.contents = contents
        self.font = font
        let border = PDFBorder()
        border.lineWidth = 0
        self.border = border
        PDFStudyNoteStyle(bounds: bounds, background: background, foreground: foreground,
                          backgroundOpacity: background.alphaComponent, fontSize: font.pointSize).apply(to: self)
    }

    required init?(coder: NSCoder) { nil }

    override func copy(with zone: NSZone? = nil) -> Any {
        PDFStudyNoteAnnotation(copying: self, style: PDFStudyNoteStyle(annotation: self))
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let style = PDFStudyNoteStyle(annotation: self)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        context.setFillColor(style.background.withAlphaComponent(style.backgroundOpacity).cgColor)
        context.fill(bounds)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let textBounds = bounds.insetBy(dx: 6, dy: 6)
        ((contents ?? "") as NSString).draw(with: textBounds,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font ?? NSFont.systemFont(ofSize: style.fontSize),
                         .foregroundColor: style.foreground, .paragraphStyle: paragraph])
    }
}

/// Explicitly selected object identity is the authority, never PDF metadata.
@MainActor
final class StudyNoteLayoutSelection {
    let documentID: ObjectIdentifier
    weak var annotation: PDFAnnotation?
    var isConsumed = false
    init(document: PDFDocument, annotation: PDFAnnotation) {
        documentID = ObjectIdentifier(document)
        self.annotation = annotation
    }
}
