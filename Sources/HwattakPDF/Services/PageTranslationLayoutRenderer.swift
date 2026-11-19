// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import Foundation
import ImageIO

/// Displays translations on opaque light cards over a bounded page image. This
/// is a separate reading copy, not an edit or reconstruction of the source PDF.
enum PageTranslationLayoutRenderer {
    private static let maximumOutputBytes = 64 * 1_024 * 1_024
    private static let minimumFontSize: CGFloat = 9
    private static let ink = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.14, alpha: 1)
    private static let accent = NSColor(calibratedRed: 0.60, green: 0.23, blue: 0.04, alpha: 1)

    @MainActor
    static func originalPDFData(layout: PageTranslationLayout) throws -> Data {
        try Task.checkCancellation()
        let image = try validatedImage(layout)
        return try makePDF(size: layout.pageSize) { context in
            drawBackground(image, size: layout.pageSize, in: context)
        }
    }

    @MainActor
    static func pdfData(layout: PageTranslationLayout, result: PageTranslationResult) throws -> Data {
        try Task.checkCancellation()
        let image = try validatedImage(layout)
        guard result.blocks.count == layout.regions.count,
              Set(result.blocks.map(\.id)).count == result.blocks.count,
              PageTranslationInput.isValidLanguageCode(result.targetLanguageCode),
              result.sourceLanguageCode.map(PageTranslationInput.isValidLanguageCode) ?? true else {
            throw PageTranslationLayoutError.invalidMapping
        }
        let translated = Dictionary(uniqueKeysWithValues: result.blocks.map { ($0.id, $0) })
        var totalBytes = 0
        for region in layout.regions {
            guard let block = translated[region.id], block.source == region.source,
                  !block.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PageTranslationLayoutError.invalidMapping
            }
            totalBytes += block.translated.utf8.count + block.source.utf8.count
            guard totalBytes <= 2 * 1_024 * 1_024 else { throw PageTranslationLayoutError.renderingFailed }
        }

        struct Placement {
            let bounds: CGRect
            let frame: CTFrame?
            let continuationNumber: Int?
        }
        let pageRect = CGRect(origin: .zero, size: layout.pageSize)
        var placements: [Placement] = []
        var continuations: [(number: Int, text: String)] = []
        for region in layout.regions {
            try Task.checkCancellation()
            let text = translated[region.id]!.translated
            let rect = region.bounds.insetBy(dx: 1, dy: 0.4)
            let sourceLineCount = max(1, region.source.components(separatedBy: .newlines).count)
            let preferredSize = min(16, max(minimumFontSize, region.bounds.height / CGFloat(sourceLineCount) * 0.85))
            var fontSize = preferredSize
            var fittingFrame: CTFrame?
            while fontSize >= minimumFontSize {
                let content = attributed(text, size: fontSize, color: ink)
                if PageTranslationLayout.valid(rect) {
                    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(content as CFAttributedString),
                        CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
                    if CTFrameGetVisibleStringRange(frame).length == content.length {
                        fittingFrame = frame
                        break
                    }
                }
                if fontSize == minimumFontSize { break }
                fontSize = max(minimumFontSize, fontSize - 0.5)
            }
            if let fittingFrame {
                placements.append(Placement(bounds: region.bounds, frame: fittingFrame, continuationNumber: nil))
            } else {
                let number = continuations.count + 1
                continuations.append((number, text))
                placements.append(Placement(bounds: region.bounds, frame: nil, continuationNumber: number))
            }
        }

        // Badges must not obscure another translation, even when a source line
        // is shorter than the readable 16-point badge. Try nearby positions,
        // then fail the page visibly rather than hide a neighbor's content.
        var badges: [(bounds: CGRect, line: CTLine)] = []
        for (index, placement) in placements.enumerated() {
            guard let number = placement.continuationNumber else { continue }
            let label = attributed("[\(number)] →", size: 10, color: accent, weight: .semibold)
            let line = CTLineCreateWithAttributedString(label as CFAttributedString)
            let width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 8
            let preferred = CGRect(x: placement.bounds.minX, y: placement.bounds.midY - 8,
                                   width: width, height: 16)
            let candidates = [preferred,
                CGRect(x: preferred.minX, y: placement.bounds.maxY + 2, width: width, height: 16),
                CGRect(x: preferred.minX, y: placement.bounds.minY - 18, width: width, height: 16),
                CGRect(x: placement.bounds.maxX + 2, y: preferred.minY, width: width, height: 16),
                CGRect(x: placement.bounds.minX - width - 2, y: preferred.minY, width: width, height: 16)]
            guard let badge = candidates.first(where: { candidate in
                pageRect.contains(candidate)
                    && !placements.enumerated().contains(where: { otherIndex, other in
                        otherIndex != index && candidate.intersects(other.bounds.insetBy(dx: -0.8, dy: -0.8))
                    })
                    && !badges.contains(where: { candidate.intersects($0.bounds.insetBy(dx: -1, dy: -1)) })
            }) else { throw PageTranslationLayoutError.renderingFailed }
            badges.append((badge, line))
        }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PageTranslationLayoutError.renderingFailed
        }
        beginPage(pageRect, in: context)
        drawBackground(image, size: layout.pageSize, in: context)
        // Clear every region before drawing translated text, so overlapping
        // source bounds cannot erase a translation drawn earlier in the loop.
        for placement in placements {
            context.setFillColor(CGColor(red: 1, green: 0.995, blue: 0.97, alpha: 1))
            context.fill(placement.bounds.insetBy(dx: -0.8, dy: -0.8).intersection(pageRect))
        }
        for placement in placements {
            if let frame = placement.frame {
                context.saveGState()
                context.clip(to: placement.bounds)
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                context.restoreGState()
            }
        }
        for badge in badges {
            context.setFillColor(CGColor(red: 1, green: 0.93, blue: 0.79, alpha: 1))
            context.fill(badge.bounds)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: badge.bounds.minX + 4, y: badge.bounds.minY + 4)
            CTLineDraw(badge.line, context)
        }
        context.endPDFPage()
        if !continuations.isEmpty {
            try appendContinuations(continuations, in: context, data: data)
        }
        context.closePDF()
        guard data.length <= maximumOutputBytes, let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages >= 1 else {
            throw PageTranslationLayoutError.renderingFailed
        }
        return data as Data
    }

    @MainActor
    private static func appendContinuations(_ blocks: [(number: Int, text: String)], in context: CGContext, data: NSMutableData) throws {
        let content = NSMutableAttributedString(string: "")
        content.append(attributed(L10n.string("translation.layout.continuation", defaultValue: "Full translations continued from numbered regions") + "\n\n", size: 20, color: ink, weight: .semibold))
        content.append(attributed(L10n.string("translation.layout.continuation_note", defaultValue: "The complete translation for each numbered region follows below.") + "\n\n", size: 10, color: ink))
        for block in blocks {
            content.append(attributed("[\(block.number)]\n", size: 12, color: accent, weight: .semibold))
            content.append(attributed(block.text + "\n\n", size: 12, color: ink))
        }
        let pageRect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let textRect = pageRect.insetBy(dx: 48, dy: 48)
        let setter = CTFramesetterCreateWithAttributedString(content as CFAttributedString)
        var offset = 0
        var count = 0
        while offset < content.length {
            try Task.checkCancellation()
            guard count < 128, data.length <= maximumOutputBytes else { throw PageTranslationLayoutError.renderingFailed }
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), CGPath(rect: textRect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.location == offset, visible.length > 0 else { throw PageTranslationLayoutError.renderingFailed }
            beginPage(pageRect, in: context)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(pageRect)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.endPDFPage()
            offset += visible.length
            count += 1
        }
    }

    @MainActor
    private static func attributed(_ string: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.baseWritingDirection = .natural
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }

    private static func validatedImage(_ layout: PageTranslationLayout) throws -> CGImage {
        try Task.checkCancellation()
        let rect = CGRect(origin: .zero, size: layout.pageSize)
        guard layout.pageNumber > 0, PageTranslationLayout.valid(rect),
              layout.pageSize.width <= 150_000, layout.pageSize.height <= 150_000,
              !layout.regions.isEmpty, layout.regions.count <= PageTranslationInput.maximumBlockCount,
              layout.backgroundPNG.count <= 32 * 1_024 * 1_024,
              Set(layout.regions.map(\.id)).count == layout.regions.count else {
            throw PageTranslationLayoutError.renderingFailed
        }
        for region in layout.regions {
            guard PageTranslationLayout.valid(region.bounds), rect.contains(region.bounds),
                  !region.source.isEmpty, region.source.utf16.count <= PageTranslationInput.maximumBlockUTF16Count else {
                throw PageTranslationLayoutError.unavailableGeometry
            }
        }
        for (index, region) in layout.regions.enumerated() {
            for other in layout.regions.dropFirst(index + 1) {
                let intersection = region.bounds.intersection(other.bounds)
                if !intersection.isNull {
                    let smallerArea = min(region.bounds.width * region.bounds.height,
                                          other.bounds.width * other.bounds.height)
                    guard intersection.width * intersection.height <= smallerArea * 0.2 else {
                        throw PageTranslationLayoutError.unavailableGeometry
                    }
                }
            }
        }
        guard try PageTranslationInput(sourceText: layout.sourceText, targetLanguageCode: "ko").blocks() == layout.blocks else {
            throw PageTranslationLayoutError.invalidMapping
        }
        guard let source = CGImageSourceCreateWithData(layout.backgroundPNG as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= Double(PageTranslationLayout.maximumRasterDimension),
              height.doubleValue <= Double(PageTranslationLayout.maximumRasterDimension),
              width.doubleValue * height.doubleValue <= Double(PageTranslationLayout.maximumRasterPixels),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PageTranslationLayoutError.renderingFailed
        }
        return image
    }

    private static func drawBackground(_ image: CGImage, size: CGSize, in context: CGContext) {
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }

    private static func beginPage(_ rect: CGRect, in context: CGContext) {
        var box = rect
        context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
    }

    private static func makePDF(size: CGSize, draw: (CGContext) throws -> Void) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PageTranslationLayoutError.renderingFailed
        }
        beginPage(CGRect(origin: .zero, size: size), in: context)
        try draw(context)
        context.endPDFPage()
        context.closePDF()
        guard data.length <= maximumOutputBytes else { throw PageTranslationLayoutError.renderingFailed }
        return data as Data
    }
}
