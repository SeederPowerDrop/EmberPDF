// SPDX-License-Identifier: MPL-2.0

import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageInsertionPreparation {
    // Prepared previews remain alive until confirmation, so bound the whole
    // batch as well as each individual decoder allocation.
    static let maximumPreparedPixelCount = 48_000_000

    static func prepare(urls: [URL], option: ImageInsertionQuality) throws -> [PreparedImageInsertion] {
        var prepared: [PreparedImageInsertion] = []
        var pixels = 0
        for url in urls {
            try Task.checkCancellation()
            let result = try autoreleasepool { () throws -> PreparedImageInsertion in
                let access = SecurityScopedAccess(url: url)
                return try withExtendedLifetime(access) { try prepare(url: url, option: option) }
            }
            pixels += Int(result.pixelSize.width * result.pixelSize.height)
            guard pixels <= maximumPreparedPixelCount else {
                throw PreparationError.batchTooLarge
            }
            prepared.append(result)
        }
        try Task.checkCancellation()
        return prepared
    }

    private static func prepare(url: URL, option: ImageInsertionQuality) throws -> PreparedImageInsertion {
        let loaded = try BoundedImageLoader().loadForInsertion(at: url, rasterBudget: option.rasterBudget)
        var proposed = loaded
        let reference = try cgImage(loaded.image)
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(reference.alphaInfo)
        var recompressed = false
        let originalEstimate = try estimatedAppearanceBytes(for: loaded)
        var estimate = originalEstimate

        // JPEG cannot encode transparency. Keep transparent pixels lossless,
        // even when the user chooses a smaller raster size.
        if let quality = option.jpegQuality, !hasAlpha {
            try Task.checkCancellation()
            if let jpeg = recompressedJPEG(reference, quality: quality) {
                let candidate = BoundedImageLoader.InsertionImage(
                    image: NSImage(cgImage: jpeg.image, size: CGSize(width: jpeg.image.width, height: jpeg.image.height)),
                    originalJPEG: jpeg, sourcePixelSize: loaded.sourcePixelSize, sourceFileBytes: loaded.sourceFileBytes)
                let candidateEstimate = try estimatedAppearanceBytes(for: candidate)
                // Re-encoding an already compact JPEG at a higher quality can
                // enlarge it. Keep the current pixels/encoding when that happens.
                if candidateEstimate < originalEstimate {
                    proposed = candidate
                    estimate = candidateEstimate
                    recompressed = true
                }
            }
        }
        let size = proposed.image.size
        let sourceSize = loaded.sourcePixelSize
        // EXIF rotation exchanges dimensions but does not count as resizing.
        let resized = Int(min(size.width, size.height)) < Int(min(sourceSize.width, sourceSize.height))
            || Int(max(size.width, size.height)) < Int(max(sourceSize.width, sourceSize.height))
        return PreparedImageInsertion(sourceURL: url, image: proposed.image, originalJPEG: proposed.originalJPEG,
            sourceBytes: loaded.sourceFileBytes, estimatedAddedBytes: estimate,
            sourcePixelSize: sourceSize, pixelSize: size, isResized: resized,
            preservesTransparency: hasAlpha, isRecompressed: recompressed, option: option)
    }

    /// Unsupported color spaces/encodings keep the valid, resized lossless
    /// image. A compression preference must not make an otherwise usable
    /// photograph impossible to insert.
    private static func recompressedJPEG(_ reference: CGImage, quality: CGFloat) -> PDFOriginalJPEG? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, reference,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PDFOriginalJPEG(data: encoded as Data, orientation: 1)
    }

    /// Quartz uses the same stamp drawing path as the real save. The small
    /// standalone page overhead makes this an estimate, not a promised size.
    private static func estimatedAppearanceBytes(for insertion: BoundedImageLoader.InsertionImage) throws -> Int {
        let data = NSMutableData()
        var bounds = CGRect(origin: .zero, size: insertion.image.size)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw BoundedImageLoadingError.decodeFailed
        }
        context.beginPDFPage(nil)
        let stamp = ImageStampAnnotation(image: insertion.image, bounds: bounds, originalJPEG: insertion.originalJPEG)
        stamp.draw(with: .mediaBox, in: context)
        context.endPDFPage()
        context.closePDF()
        return data.length
    }

    private static func cgImage(_ image: NSImage) throws -> CGImage {
        var bounds = CGRect(origin: .zero, size: image.size)
        guard let raster = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else {
            throw BoundedImageLoadingError.decodeFailed
        }
        return raster
    }

    private enum PreparationError: LocalizedError {
        case batchTooLarge

        var errorDescription: String? {
            L10n.string("image.insert.batch_too_large", defaultValue: "한 번에 준비할 수 있는 이미지 크기를 초과했습니다. 작은 용량을 선택하거나 이미지를 나누어 추가하세요.")
        }
    }
}
