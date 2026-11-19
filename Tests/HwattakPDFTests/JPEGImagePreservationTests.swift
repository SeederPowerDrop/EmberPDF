// SPDX-License-Identifier: MPL-2.0

import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import HwattakPDF

/// Checks the serialized image payload and displayed pixels, so a small file
/// obtained through lossy recompression or an incorrect EXIF transform fails.
final class JPEGImagePreservationTests: XCTestCase {
    @MainActor
    func testWorkspaceJPEGSaveCopyResizeAndCropUndoPreserveOriginalCoefficients() throws {
        try withDirectory { directory in
            let jpeg = try removingPrivateMetadata(from: encodedImage(type: .jpeg))
            let imageURL = directory.appendingPathComponent("photo.jpg")
            let sourceURL = directory.appendingPathComponent("source.pdf")
            let savedURL = directory.appendingPathComponent("saved.pdf")
            try jpeg.write(to: imageURL)
            try blankPDF().write(to: sourceURL)
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: sourceURL))
            workspace.setMode(.editing)
            workspace.insertImage(url: imageURL)
            let imageRequest = try XCTUnwrap(workspace.pendingImageInsertion)
            let preparedImages = try ImageInsertionPreparation.prepare(urls: imageRequest.urls, option: .original)
            XCTAssertTrue(workspace.approveImageInsertion(imageRequest, images: preparedImages))
            let page = try XCTUnwrap(workspace.document?.page(at: 0))
            let annotation = try XCTUnwrap(page.annotations.compactMap { $0 as? ImageStampAnnotation }.first)
            XCTAssertTrue(workspace.saveSynchronously(as: savedURL), workspace.presentedError ?? "Save failed")
            let first = try Data(contentsOf: savedURL)
            try assertOriginalJPEG(jpeg, in: first)
            XCTAssertLessThan(first.count, jpeg.count + 65_536)

            let copy = try XCTUnwrap(annotation.copy() as? ImageStampAnnotation)
            annotation.bounds = annotation.bounds.insetBy(dx: 5, dy: 3)
            for _ in 0..<3 {
                XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
                try assertOriginalJPEG(jpeg, in: Data(contentsOf: savedURL))
            }
            let originalCrop = annotation.normalizedCropRect
            let originalBounds = annotation.bounds
            let originalDate = annotation.modificationDate
            annotation.updateCropRect(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
            workspace.registerAnnotationGeometryChange(annotation, on: page, from: originalBounds,
                originalCropRect: originalCrop, originalModificationDate: originalDate, message: "Crop image")
            XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
            let cropped = try Data(contentsOf: savedURL)
            let croppedImages = try imageStreams(in: cropped)
            XCTAssertTrue(croppedImages.contains { $0.width == 96 && $0.height == 64 })
            XCTAssertFalse(croppedImages.contains { $0.width == 192 && $0.height == 128 })
            XCTAssertNil(cropped.range(of: jpeg), "A crop must not serialize recoverable hidden source pixels.")
            try assertOriginalJPEG(jpeg, in: pdf(containing: copy))

            workspace.undo()
            XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
            try assertOriginalJPEG(jpeg, in: Data(contentsOf: savedURL))
            workspace.redo()
            XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
            let redone = try Data(contentsOf: savedURL)
            XCTAssertNil(redone.range(of: jpeg))
            XCTAssertEqual(try imageStreams(in: redone).map(\.data), croppedImages.map(\.data),
                "Crop undo/redo must derive the same pixels without cumulative JPEG loss.")
            XCTAssertEqual(try Data(contentsOf: imageURL), jpeg, "Insertion must never rewrite the user's photo.")
        }
    }

    @MainActor
    func testAllEightEXIFOrientationsMatchImageIOAndRemovePrivateMetadata() throws {
        try withDirectory { directory in
            for orientation in 1...8 {
                let sentinel = "PRIVATE-PHOTO-GPS-XMP-\(orientation)"
                var jpeg = try encodedImage(type: .jpeg, orientation: orientation)
                jpeg.insert(contentsOf: jpegSegment(marker: 0xE1,
                    payload: Data(("http://ns.adobe.com/xap/1.0/\0" + sentinel).utf8)), at: 2)
                jpeg.insert(contentsOf: jpegSegment(marker: 0xFE, payload: Data(sentinel.utf8)), at: 2)
                let url = directory.appendingPathComponent("orientation-\(orientation).jpg")
                try jpeg.write(to: url)
                let loaded = try BoundedImageLoader(efficientRenderingEnabled: true).loadForInsertion(at: url)
                XCTAssertNotNil(loaded.originalJPEG, "EXIF orientation \(orientation) should preserve compression.")
                let reference = try transformedReference(jpeg)
                XCTAssertEqual(Int(loaded.image.size.width), reference.width)
                XCTAssertEqual(Int(loaded.image.size.height), reference.height)
                let annotation = ImageStampAnnotation(image: loaded.image,
                    bounds: CGRect(x: 40, y: 50, width: CGFloat(reference.width), height: CGFloat(reference.height)),
                    originalJPEG: loaded.originalJPEG)
                let saved = try pdf(containing: annotation)
                XCTAssertNil(saved.range(of: Data(sentinel.utf8)))
                let jpegStreams = try imageStreams(in: saved).filter { $0.filter == "DCTDecode" }
                XCTAssertEqual(jpegStreams.count, 1)
                XCTAssertEqual(jpegStreams.first?.data, try removingPrivateMetadata(from: jpeg),
                    "Only metadata may change; JPEG coefficients must survive orientation \(orientation).")
                try assertVisualMatch(saved, image: reference, bounds: annotation.bounds,
                    message: "EXIF orientation \(orientation)")
            }
        }
    }

    @MainActor
    func testGrayscaleAndDisplayP3JPEGKeepColorAndCompressedPixels() throws {
        try withDirectory { directory in
            let variants: [(String, CGColorSpace)] = [
                ("gray", CGColorSpaceCreateDeviceGray()),
                ("display-p3", try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)))
            ]
            for (name, colorSpace) in variants {
                let jpeg = try removingPrivateMetadata(from: encodedImage(type: .jpeg, colorSpace: colorSpace))
                let url = directory.appendingPathComponent("\(name).jpg")
                try jpeg.write(to: url)
                let loaded = try BoundedImageLoader(efficientRenderingEnabled: true).loadForInsertion(at: url)
                XCTAssertNotNil(loaded.originalJPEG)
                let annotation = ImageStampAnnotation(image: loaded.image,
                    bounds: CGRect(x: 40, y: 50, width: 192, height: 128), originalJPEG: loaded.originalJPEG)
                let saved = try pdf(containing: annotation)
                try assertOriginalJPEG(jpeg, in: saved)
                try assertVisualMatch(saved, image: transformedReference(jpeg), bounds: annotation.bounds,
                    message: name)
            }
        }
    }

    @MainActor
    func testTransparentPNGUsesLosslessFallbackAndKeepsTransparency() throws {
        try withDirectory { directory in
            let png = try encodedImage(type: .png, alpha: true)
            let url = directory.appendingPathComponent("transparent.png")
            try png.write(to: url)
            let loaded = try BoundedImageLoader(efficientRenderingEnabled: true).loadForInsertion(at: url)
            XCTAssertNil(loaded.originalJPEG)
            let annotation = ImageStampAnnotation(image: loaded.image,
                bounds: CGRect(x: 40, y: 50, width: 192, height: 128), originalJPEG: loaded.originalJPEG)
            let saved = try pdf(containing: annotation)
            XCTAssertFalse(try imageStreams(in: saved).contains { $0.filter == "DCTDecode" },
                "Transparency must not be flattened or discarded to produce JPEG.")
            try assertVisualMatch(saved, image: transformedReference(png), bounds: annotation.bounds,
                message: "transparent PNG")
        }
    }

    @MainActor
    func testJPEGAbovePixelBudgetStillUsesBoundedDecode() throws {
        try withDirectory { directory in
            let jpeg = try encodedImage(type: .jpeg, width: 3_600, height: 1_900)
            let url = directory.appendingPathComponent("large.jpg")
            try jpeg.write(to: url)
            let loaded = try BoundedImageLoader(efficientRenderingEnabled: true).loadForInsertion(at: url)
            XCTAssertNil(loaded.originalJPEG, "Compression preservation must not bypass the decode memory budget.")
            let image = try XCTUnwrap(loaded.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertLessThanOrEqual(max(image.width, image.height), 3_200)
            XCTAssertLessThanOrEqual(image.width * image.height, 6_000_000)
            XCTAssertGreaterThan(image.width, 1_900, "Bounded loading must retain useful image detail.")
        }
    }

    private func assertOriginalJPEG(_ expected: Data, in pdf: Data, file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        let jpegStreams = try imageStreams(in: pdf).filter { $0.filter == "DCTDecode" }
        XCTAssertEqual(jpegStreams.count, 1, file: file, line: line)
        XCTAssertEqual(jpegStreams.first?.data, expected,
            "Saved DCT bytes must be identical; repeated encoding would lose photo detail.", file: file, line: line)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-JPEG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func blankPDF() throws -> Data {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func pdf(containing annotation: PDFAnnotation) throws -> Data {
        let document = try XCTUnwrap(PDFDocument(data: blankPDF()))
        let page = try XCTUnwrap(document.page(at: 0))
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        page.addAnnotation(annotation)
        return try XCTUnwrap(document.dataRepresentation())
    }

    private func encodedImage(type: UTType, orientation: Int = 1, width: Int = 192, height: Int = 128,
                              colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB(), alpha: Bool = false) throws -> Data {
        let gray = colorSpace.model == .monochrome
        let bitmapInfo = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo))
        let colors: [[CGFloat]] = gray
            ? [[0.15], [0.45], [0.7], [0.95]]
            : [[0.85, 0.1, 0.15], [0.1, 0.75, 0.2], [0.1, 0.2, 0.9], [0.9, 0.8, 0.15]]
        for quadrant in 0..<4 {
            let components = colors[quadrant] + [alpha && quadrant == 0 ? 0 : (alpha && quadrant == 1 ? 0.45 : 1)]
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace, components: components)))
            context.fill(CGRect(x: quadrant % 2 * width / 2, y: quadrant / 2 * height / 2,
                width: width / 2, height: height / 2))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.73,
            kCGImagePropertyOrientation: orientation
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func transformedReference(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096
        ] as CFDictionary))
    }

    private func assertVisualMatch(_ data: Data, image: CGImage, bounds: CGRect, message: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        func canvas() throws -> CGContext {
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8,
                bytesPerRow: 1_600, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            return context
        }
        let actual = try canvas()
        page.draw(with: .mediaBox, to: actual)
        let expected = try canvas()
        expected.draw(image, in: bounds)
        let actualBytes = try XCTUnwrap(actual.data).assumingMemoryBound(to: UInt8.self)
        let expectedBytes = try XCTUnwrap(expected.data).assumingMemoryBound(to: UInt8.self)
        // A grid comfortably inside each quadrant catches mirrored/rotated
        // photos, color-space loss and flattened PNG alpha without edge noise.
        for fractionY in [0.2, 0.35, 0.65, 0.8] {
            for fractionX in [0.2, 0.35, 0.65, 0.8] {
                let x = Int(bounds.minX + bounds.width * fractionX)
                let y = Int(bounds.minY + bounds.height * fractionY)
                let offset = y * 1_600 + x * 4
                for channel in 0..<3 {
                    XCTAssertLessThanOrEqual(abs(Int(actualBytes[offset + channel]) - Int(expectedBytes[offset + channel])),
                        8, "\(message), sample \(x),\(y) channel \(channel)", file: file, line: line)
                }
            }
        }
    }

    private func jpegSegment(marker: UInt8, payload: Data) -> Data {
        let length = payload.count + 2
        return Data([0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload
    }

    /// Remove metadata fixture segments before an exact-byte assertion. JPEG
    /// tables, scan data, color profile and Adobe color interpretation remain.
    private func removingPrivateMetadata(from data: Data) throws -> Data {
        let bytes = Array(data)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8])
        var result = Data(bytes.prefix(2))
        var offset = 2
        while offset + 4 <= bytes.count {
            let marker = bytes[offset + 1]
            if marker == 0xDA || marker == 0xD9 {
                result.append(contentsOf: bytes[offset...])
                return result
            }
            let count = 2 + (Int(bytes[offset + 2]) << 8) + Int(bytes[offset + 3])
            guard offset + count <= bytes.count else { throw NSError(domain: "JPEGFixture", code: 1) }
            if marker != 0xE1 && marker != 0xED && marker != 0xFE {
                result.append(contentsOf: bytes[offset..<(offset + count)])
            }
            offset += count
        }
        throw NSError(domain: "JPEGFixture", code: 2)
    }

    private struct ImageStream {
        let width: Int
        let height: Int
        let filter: String
        let data: Data
    }

    private final class ImageCollector {
        var images: [ImageStream] = []
        var visited = Set<UInt>()

        func visitDictionary(_ dictionary: CGPDFDictionaryRef) {
            guard visited.insert(pdfReferenceIdentity(dictionary)).inserted else { return }
            CGPDFDictionaryApplyFunction(dictionary, { key, object, opaque in
                guard let opaque, strcmp(key, "Parent") != 0 else { return }
                Unmanaged<ImageCollector>.fromOpaque(opaque).takeUnretainedValue().visitObject(object)
            }, Unmanaged.passUnretained(self).toOpaque())
        }

        func visitObject(_ object: CGPDFObjectRef) {
            switch CGPDFObjectGetType(object) {
            case .dictionary:
                var value: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &value), let value { visitDictionary(value) }
            case .array:
                var value: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &value), let value,
                      visited.insert(pdfReferenceIdentity(value)).inserted else { return }
                for index in 0..<CGPDFArrayGetCount(value) {
                    var element: CGPDFObjectRef?
                    if CGPDFArrayGetObject(value, index, &element), let element { visitObject(element) }
                }
            case .stream:
                var value: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &value), let value,
                      visited.insert(pdfReferenceIdentity(value)).inserted,
                      let dictionary = CGPDFStreamGetDictionary(value) else { return }
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, strcmp(subtype, "Image") == 0 {
                    var width = 0, height = 0
                    var filter: UnsafePointer<CChar>?
                    _ = CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                    _ = CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                    _ = CGPDFDictionaryGetName(dictionary, "Filter", &filter)
                    var format = CGPDFDataFormat.raw
                    if let data = CGPDFStreamCopyData(value, &format) {
                        images.append(ImageStream(width: width, height: height,
                            filter: filter.map { String(cString: $0) } ?? "none", data: data as Data))
                    }
                }
                visitDictionary(dictionary)
            default: break
            }
        }
    }

    private func imageStreams(in data: Data) throws -> [ImageStream] {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let dictionary = try XCTUnwrap(page.dictionary)
        let collector = ImageCollector()
        collector.visitDictionary(dictionary)
        return collector.images
    }
}
