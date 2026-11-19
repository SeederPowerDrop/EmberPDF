// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit

/// A value snapshot of one displayed page. Bounds use a lower-left origin,
/// with crop and rotation already applied; no live PDFKit objects are retained.
struct PageTranslationLayout: Equatable, Sendable {
    struct Region: Equatable, Sendable, Identifiable {
        let id: String
        let source: String
        let bounds: CGRect
    }

    static let maximumRasterDimension: CGFloat = 2_400
    static let maximumRasterPixels: CGFloat = 6_000_000
    let pageNumber: Int
    let pageSize: CGSize
    let backgroundPNG: Data
    let regions: [Region]

    var sourceText: String { regions.map(\.source).joined(separator: "\n\n") }
    var blocks: [TranslationBlock] { regions.map { TranslationBlock(id: $0.id, source: $0.source) } }

    @MainActor
    static func capture(page: PDFPage, pageNumber: Int) throws -> Self {
        try Task.checkCancellation()
        guard let source = page.string, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PageTranslationError.emptySource
        }
        guard !EncodedTextLimiter.limit(source, budget: PageTranslationInput.sourceBudget).wasTruncated else {
            throw PageTranslationError.sourceTooLarge
        }
        let crop = page.bounds(for: .cropBox)
        let characterCount = page.numberOfCharacters
        guard pageNumber > 0, valid(crop), crop.width <= 100_000, crop.height <= 100_000,
              page.pageRef != nil, characterCount > 0, characterCount <= 32_000,
              let selection = page.selection(for: NSRange(location: 0, length: characterCount)) else {
            throw PageTranslationLayoutError.unavailableGeometry
        }
        let transform = displayTransform(cropBox: crop, rotation: page.rotation)
        let pageRect = crop.applying(transform)
        guard valid(pageRect) else { throw PageTranslationLayoutError.unavailableGeometry }
        var paragraphs: [(source: String, bounds: CGRect, last: CGRect)] = []
        var extracted: [String] = []
        for line in selection.selectionsByLine() {
            try Task.checkCancellation()
            let text = (line.string ?? "").replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(whereSeparator: \.isNewline).map(String.init).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard text.utf16.count <= PageTranslationInput.maximumBlockUTF16Count else {
                throw PageTranslationError.sourceTooLarge
            }
            let nativeBounds = line.bounds(for: page)
            guard valid(nativeBounds) else { throw PageTranslationLayoutError.unavailableGeometry }
            let bounds = nativeBounds.intersection(crop).applying(transform).intersection(pageRect)
            guard valid(bounds) else { throw PageTranslationLayoutError.unavailableGeometry }
            extracted.append(text)
            // Group using native coordinates, so a /Rotate edit does not change
            // paragraph membership. Only adjacent, aligned, similarly sized lines
            // join; headings, column jumps and paragraph gaps remain separate.
            if let last = paragraphs.last,
               canJoin(previous: last.last, next: nativeBounds),
               (last.source + "\n" + text).utf16.count <= PageTranslationInput.maximumBlockUTF16Count {
                paragraphs[paragraphs.count - 1] = (
                    last.source + "\n" + text, last.bounds.union(bounds), nativeBounds
                )
            } else {
                guard paragraphs.count < PageTranslationInput.maximumBlockCount else {
                    throw PageTranslationError.sourceTooLarge
                }
                paragraphs.append((text, bounds, nativeBounds))
            }
        }
        // Missing text geometry must never produce an apparently complete page.
        // PDFKit may synthesize different whitespace in its line selections.
        guard !paragraphs.isEmpty,
              source.unicodeScalars.filter({ !CharacterSet.whitespacesAndNewlines.contains($0) })
                == extracted.joined().unicodeScalars.filter({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw PageTranslationLayoutError.unavailableGeometry
        }
        let regions = paragraphs.enumerated().map { index, paragraph in
            Region(id: "b\(index + 1)", source: paragraph.source, bounds: paragraph.bounds)
        }
        let joined = regions.map(\.source).joined(separator: "\n\n")
        let blocks = try PageTranslationInput(sourceText: joined, targetLanguageCode: "ko").blocks()
        guard blocks == regions.map({ TranslationBlock(id: $0.id, source: $0.source) }) else {
            throw PageTranslationLayoutError.unavailableGeometry
        }
        let image = try raster(page: page, pageRect: pageRect, transform: transform)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]),
              png.count <= 32 * 1_024 * 1_024 else { throw PageTranslationLayoutError.renderingFailed }
        return Self(pageNumber: pageNumber, pageSize: pageRect.size, backgroundPNG: png, regions: regions)
    }

    private static func canJoin(previous: CGRect, next: CGRect) -> Bool {
        let height = max(previous.height, next.height)
        let gap = previous.minY - next.maxY
        let overlap = min(previous.maxX, next.maxX) - max(previous.minX, next.minX)
        return height > 0 && min(previous.height, next.height) / height >= 0.80
            && abs(previous.minX - next.minX) <= min(10, height * 0.6)
            && gap >= -height * 0.2 && gap <= height * 0.8
            && next.midY < previous.midY
            && overlap >= min(previous.width, next.width) * 0.75
    }

    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && !rect.isNull && rect.width > 0 && rect.height > 0
    }

    private static func displayTransform(cropBox: CGRect, rotation: Int) -> CGAffineTransform {
        switch ((rotation % 360) + 360) % 360 {
        case 0: return CGAffineTransform(translationX: -cropBox.minX, y: -cropBox.minY)
        case 90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -cropBox.minY, ty: cropBox.maxX)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: cropBox.maxX, ty: cropBox.maxY)
        case 270: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: cropBox.maxY, ty: -cropBox.minX)
        default:
            let rotation = CGAffineTransform(rotationAngle: -CGFloat(rotation % 360) * .pi / 180)
            let rect = cropBox.applying(rotation)
            return rotation.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
    }

    @MainActor
    private static func raster(page: PDFPage, pageRect: CGRect, transform: CGAffineTransform) throws -> CGImage {
        let scale = min(2, maximumRasterDimension / max(pageRect.width, pageRect.height),
                        sqrt(maximumRasterPixels / (pageRect.width * pageRect.height)))
        let width = max(1, Int((pageRect.width * scale).rounded(.down)))
        let height = max(1, Int((pageRect.height * scale).rounded(.down)))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PageTranslationLayoutError.renderingFailed
        }
        let pixelRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(pixelRect)
        context.clip(to: pixelRect)
        context.scaleBy(x: CGFloat(width) / pageRect.width, y: CGFloat(height) / pageRect.height)
        context.concatenate(transform)
        // PDFKit applies its own crop/rotation. Cancel that transform because
        // our live page transform already accounts for both (including edits).
        context.concatenate(page.transform(for: .cropBox).inverted())
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw PageTranslationLayoutError.renderingFailed }
        return image
    }
}

enum PageTranslationLayoutError: LocalizedError, Equatable {
    case unavailableGeometry
    case renderingFailed
    case invalidMapping

    var errorDescription: String? {
        switch self {
        case .unavailableGeometry:
            return L10n.string("translation.layout.error.geometry", defaultValue: "This page's text positions could not be read reliably. Try the text translation view instead.")
        case .renderingFailed:
            return L10n.string("translation.layout.error.render", defaultValue: "The complete translated page could not be displayed. No partial page was used.")
        case .invalidMapping:
            return L10n.string("translation.layout.error.mapping", defaultValue: "The translation does not match every text region on this page. Translate the page again.")
        }
    }
}
