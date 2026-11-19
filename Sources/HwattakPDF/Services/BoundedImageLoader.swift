// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import ImageIO

enum BoundedImageLoadingError: LocalizedError {
    case unreadable
    case unsafeFile
    case sourceTooLarge
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable, .decodeFailed:
            L10n.string("error.image_open")
        case .unsafeFile:
            L10n.string(
                "error.image_unsafe_file",
                defaultValue: "일반 이미지 파일만 추가할 수 있습니다."
            )
        case .sourceTooLarge:
            L10n.string(
                "error.image_too_large",
                defaultValue: "이미지가 안전한 파일·픽셀 크기 제한을 초과했습니다. 더 작은 사본을 사용하세요."
            )
        }
    }
}

/// Reads image metadata without decoding, then creates one bounded first-frame
/// raster through ImageIO. This prevents compressed image bombs from asking
/// `NSImage(contentsOf:)` to materialize an arbitrary pixel buffer on the main
/// actor before the app can inspect it.
struct BoundedImageLoader {
    struct InsertionImage {
        let image: NSImage
        let originalJPEG: PDFOriginalJPEG?
        let sourcePixelSize: CGSize
        let sourceFileBytes: Int
    }

    static let maximumFileBytes = 64 * 1_024 * 1_024
    static let maximumSourcePixelCount: UInt64 = 120_000_000

    let efficientRenderingEnabled: Bool

    init(
        efficientRenderingEnabled: Bool = AppPerformanceSettings.isEfficientRenderingEnabled
    ) {
        self.efficientRenderingEnabled = efficientRenderingEnabled
    }

    func load(at url: URL) throws -> NSImage {
        try load(at: url, preservingJPEG: false).image
    }

    func loadForInsertion(at url: URL, rasterBudget: PDFRasterBudget? = nil) throws -> InsertionImage {
        try load(at: url, preservingJPEG: true, rasterBudget: rasterBudget)
    }

    private func load(at url: URL, preservingJPEG: Bool, rasterBudget: PDFRasterBudget? = nil) throws -> InsertionImage {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            throw BoundedImageLoadingError.unreadable
        }
        guard
            values.isRegularFile == true,
            values.isDirectory != true,
            values.isSymbolicLink != true
        else {
            throw BoundedImageLoadingError.unsafeFile
        }
        guard let fileSize = values.fileSize, (1...Self.maximumFileBytes).contains(fileSize) else {
            throw BoundedImageLoadingError.sourceTooLarge
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let sourceData: Data?
        let sourceReference: CGImageSource?
        if preservingJPEG {
            // Both the preview and original compression must describe the same
            // immutable file version. Bound this read even if the file grows
            // between the metadata check and opening it.
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard !data.isEmpty, data.count <= Self.maximumFileBytes else {
                throw BoundedImageLoadingError.sourceTooLarge
            }
            sourceData = data
            sourceReference = CGImageSourceCreateWithData(data as CFData, sourceOptions)
        } else {
            sourceData = nil
            sourceReference = CGImageSourceCreateWithURL(url as CFURL, sourceOptions)
        }
        guard
            let source = sourceReference,
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw BoundedImageLoadingError.unreadable
        }

        let sourceWidth = widthNumber.uint64Value
        let sourceHeight = heightNumber.uint64Value
        let (sourcePixels, overflow) = sourceWidth.multipliedReportingOverflow(by: sourceHeight)
        guard
            !overflow,
            sourceWidth > 0,
            sourceHeight > 0,
            sourcePixels <= Self.maximumSourcePixelCount
        else {
            throw BoundedImageLoadingError.sourceTooLarge
        }

        let defaultBudget = efficientRenderingEnabled
            ? PDFRasterBudget(maximumDimension: 3_200, maximumPixelCount: 6_000_000)
            : PDFRasterBudget(maximumDimension: 4_096, maximumPixelCount: 12_000_000)
        let budget = rasterBudget ?? defaultBudget
        let target = budget.boundedPixelSize(
            logicalSize: CGSize(width: CGFloat(sourceWidth), height: CGFloat(sourceHeight)),
            scale: 1
        )
        let maximumPixelSize = max(1, Int(max(target.width, target.height).rounded(.down)))
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw BoundedImageLoadingError.decodeFailed
        }
        let preview = NSImage(
            cgImage: image,
            size: CGSize(width: image.width, height: image.height)
        )
        var originalJPEG: PDFOriginalJPEG?
        if let sourceData, CGImageSourceGetType(source) as String? == "public.jpeg",
           CGFloat(sourceWidth) <= target.width, CGFloat(sourceHeight) <= target.height {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if let jpeg = PDFOriginalJPEG(data: sourceData, orientation: orientation),
               jpeg.image.width == Int(sourceWidth), jpeg.image.height == Int(sourceHeight),
               let reference = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions),
               let referenceSpace = reference.colorSpace, let storedSpace = jpeg.image.colorSpace,
               CFEqual(referenceSpace, storedSpace) {
                // Some files describe color through EXIF rather than ICC.
                // If removing private metadata changes that interpretation,
                // use the already color-managed preview instead.
                originalJPEG = jpeg
            }
        }
        return InsertionImage(image: preview, originalJPEG: originalJPEG,
            sourcePixelSize: CGSize(width: CGFloat(sourceWidth), height: CGFloat(sourceHeight)),
            sourceFileBytes: sourceData?.count ?? fileSize)
    }
}
