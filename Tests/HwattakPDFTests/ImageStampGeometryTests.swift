// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// The oracle is ordinary PDF page content, independent of custom annotation
/// drawing and PDFPage.transform. Four differently colored corners reveal
/// clipped images, translations, rotations and vertical mirroring.
@MainActor
final class ImageStampGeometryTests: XCTestCase {
    private let originalBounds = CGRect(x: 75, y: 100, width: 150, height: 120)
    private let crop = CGRect(x: 0.125, y: 0.25, width: 0.625, height: 0.5)
    private let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let colors: [[CGFloat]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0]]

    func testFullImageKeepsEveryCornerInsideItsBoundsLiveAndAfterSave() throws {
        try checkImage(crop: whole)
    }

    func testCroppedImageKeepsVisibleCornersInsideItsBoundsLiveAndAfterSave() throws {
        try checkImage(crop: crop)
    }

    func testMovingAndResizingAttachedImageKeepsItsWholeAppearance() throws {
        let image = try rasterImage()
        for rotation in [0, 90, 180, 270] {
            for visibleCrop in [whole, crop] {
                let document = try source(rotation: rotation, offset: true)
                let page = try XCTUnwrap(document.page(at: 0))
                let stamp = ImageStampAnnotation(image: image, bounds: originalBounds, normalizedCropRect: visibleCrop)
                _ = ImageAnnotationIdentity.assign(to: stamp)
                page.addAnnotation(stamp)
                for bounds in [CGRect(x: 90, y: 125, width: 130, height: 95),
                               CGRect(x: 60, y: 90, width: 170, height: 140)] {
                    stamp.bounds = bounds
                    try check(document, bounds: bounds, crop: visibleCrop, rotation: rotation, offset: true,
                              name: "moved-\(rotation)-\(bounds.width)-\(visibleCrop == whole ? "full" : "crop")")
                }
            }
        }
    }

    func testCompressingInsertedImagePreservesPositionCropCornersAndLaterResize() throws {
        // A noisy large raster guarantees this exercises replacement appearance
        // generation rather than the 'already small, return input' fast path.
        let image = try rasterImage(width: 1000, height: 750, noise: true)
        for rotation in [0, 90, 180, 270] {
            for visibleCrop in [whole, crop] {
                let document = try source(rotation: rotation, offset: true)
                let page = try XCTUnwrap(document.page(at: 0))
                let stamp = ImageStampAnnotation(image: image, bounds: originalBounds, normalizedCropRect: visibleCrop)
                _ = ImageAnnotationIdentity.assign(to: stamp)
                page.addAnnotation(stamp)
                let input = try XCTUnwrap(document.dataRepresentation())
                let result = try PDFCompressionService.compress(data: input, quality: .balanced)
                XCTAssertTrue(result.didReduce, "The fixture must exercise compressed appearances")
                let compressed = try XCTUnwrap(PDFDocument(data: result.data))
                let compressedPage = try XCTUnwrap(compressed.page(at: 0))
                let annotation = try XCTUnwrap(compressedPage.annotations.first)
                XCTAssertTrue(ImageAnnotationIdentity.isEditableImage(annotation))
                XCTAssertEqual(compressedPage.annotations.count, 1)
                let name = "compressed-\(rotation)-\(visibleCrop == whole ? "full" : "crop")"
                try assertAppearance(page: compressedPage, referenceBounds: originalBounds, crop: visibleCrop,
                                     rotation: rotation, offset: true, name: name)
                // PDFKit may normalize a nonzero MediaBox origin while saving.
                // Resize the saved annotation in that normalized coordinate space
                // and compare to the corresponding original page-content oracle.
                let media = compressedPage.bounds(for: .mediaBox)
                let shift = CGPoint(x: media.minX - 13, y: media.minY - 29)
                let moved = CGRect(x: 95, y: 115, width: 125, height: 100)
                annotation.bounds = moved.offsetBy(dx: shift.x, dy: shift.y)
                try assertAppearance(page: compressedPage, referenceBounds: moved, crop: visibleCrop,
                                     rotation: rotation, offset: true, name: name + "-resized")
                let saved = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(compressed.dataRepresentation())))
                try assertAppearance(page: XCTUnwrap(saved.page(at: 0)), referenceBounds: moved, crop: visibleCrop,
                                     rotation: rotation, offset: true, name: name + "-resized-saved")
            }
        }
    }

    private func checkImage(crop: CGRect) throws {
        let image = try rasterImage()
        for offset in [false, true] {
            for rotation in [0, 90, 180, 270] {
                let document = try source(rotation: rotation, offset: offset)
                let page = try XCTUnwrap(document.page(at: 0))
                let stamp = ImageStampAnnotation(image: image, bounds: originalBounds, normalizedCropRect: crop)
                _ = ImageAnnotationIdentity.assign(to: stamp)
                page.addAnnotation(stamp)
                try check(document, bounds: originalBounds, crop: crop, rotation: rotation, offset: offset,
                          name: "\(crop == whole ? "full" : "crop")-\(rotation)-\(offset ? "offset" : "zero")")
            }
        }
    }

    private func check(_ document: PDFDocument, bounds: CGRect, crop: CGRect, rotation: Int,
                       offset: Bool, name: String) throws {
        try assertAppearance(page: XCTUnwrap(document.page(at: 0)), referenceBounds: bounds,
                             crop: crop, rotation: rotation, offset: offset, name: name + "-live")
        let data = try XCTUnwrap(document.dataRepresentation())
        try dump(data, named: name + ".pdf")
        let saved = try XCTUnwrap(PDFDocument(data: data))
        let savedPage = try XCTUnwrap(saved.page(at: 0))
        XCTAssertEqual(savedPage.annotations.count, 1)
        XCTAssertEqual(savedPage.rotation, rotation)
        try assertAppearance(page: savedPage, referenceBounds: bounds, crop: crop,
                             rotation: rotation, offset: offset, name: name + "-saved")
    }

    private func assertAppearance(page: PDFPage, referenceBounds: CGRect, crop: CGRect,
                                  rotation: Int, offset: Bool, name: String) throws {
        let reference = try source(rotation: rotation, offset: offset, imageBounds: referenceBounds, crop: crop)
        let referencePage = try XCTUnwrap(reference.page(at: 0))
        for box in [PDFDisplayBox.mediaBox, .cropBox] {
            let expected = try bitmap(referencePage, box: box)
            let actual = try bitmap(page, box: box)
            try dump(actual.representation(using: .png, properties: [:]), named: "\(name)-\(box.rawValue).png")
            var samples = [Int](repeating: 0, count: 4)
            var failures = 0
            var firstFailure = ""
            // Exclude color boundaries so interpolation and JPEG edge pixels
            // do not masquerade as a geometry regression.
            for y in stride(from: 4, to: expected.pixelsHigh - 4, by: 4) {
                for x in stride(from: 4, to: expected.pixelsWide - 4, by: 4) {
                    guard let index = colorIndex(expected, x: x, y: y),
                          colorIndex(expected, x: x - 3, y: y) == index,
                          colorIndex(expected, x: x + 3, y: y) == index,
                          colorIndex(expected, x: x, y: y - 3) == index,
                          colorIndex(expected, x: x, y: y + 3) == index else { continue }
                    samples[index] += 1
                    if colorIndex(actual, x: x, y: y) != index {
                        failures += 1
                        if firstFailure.isEmpty { firstFailure = "pixel \(x),\(y), corner \(index)" }
                    }
                }
            }
            for count in samples { XCTAssertGreaterThan(count, 30, "Each of the four image corners must be visible in the independent oracle") }
            XCTAssertEqual(failures, 0, "\(name), display box \(box): clipped, shifted or mirrored image at \(firstFailure)")
        }
    }

    private func colorIndex(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Int? {
        guard let rgb = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return colors.firstIndex { target in zip(values, target).allSatisfy { abs($0 - $1) < 0.24 } }
    }

    private func bitmap(_ page: PDFPage, box: PDFDisplayBox) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 420, pixelsHigh: 420,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 420, height: 420))
        page.draw(with: box, to: graphics.cgContext)
        graphics.flushGraphics()
        return bitmap
    }

    private func rasterImage(width: Int = 256, height: Int = 192, noise: Bool = false) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, components) in colors.enumerated() {
            context.setFillColor(red: components[0], green: components[1], blue: components[2], alpha: 1)
            context.fill(CGRect(x: index % 2 * width / 2, y: index / 2 * height / 2, width: width / 2, height: height / 2))
        }
        if noise {
            let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
            var seed: UInt32 = 0xCAFE1234
            for y in 0..<height { for x in 0..<width {
                for channel in 0..<3 {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let jitter = UInt8((seed >> 24) % 32)
                    let index = y * context.bytesPerRow + x * 4 + channel
                    bytes[index] = bytes[index] > 127 ? 255 - jitter : jitter
                }
            } }
        }
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: width, height: height))
    }

    private func source(rotation: Int, offset: Bool, imageBounds: CGRect? = nil,
                        crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> PDFDocument {
        let media = offset ? CGRect(x: 13, y: 29, width: 310, height: 360) : CGRect(x: 0, y: 0, width: 310, height: 360)
        let pageCrop = offset ? CGRect(x: 43, y: 71, width: 240, height: 260) : CGRect(x: 0, y: 0, width: 240, height: 260)
        var content = "1 1 1 rg \(media.minX) \(media.minY) \(media.width) \(media.height) re f\n"
        if let bounds = imageBounds {
            for (index, color) in colors.enumerated() {
                let quadrant = CGRect(x: CGFloat(index % 2) * 0.5, y: CGFloat(index / 2) * 0.5, width: 0.5, height: 0.5)
                let visible = quadrant.intersection(crop)
                guard !visible.isEmpty else { continue }
                let rect = CGRect(x: bounds.minX + (visible.minX - crop.minX) / crop.width * bounds.width,
                                  y: bounds.minY + (visible.minY - crop.minY) / crop.height * bounds.height,
                                  width: visible.width / crop.width * bounds.width,
                                  height: visible.height / crop.height * bounds.height)
                content += "\(color[0]) \(color[1]) \(color[2]) rg \(rect.minX) \(rect.minY) \(rect.width) \(rect.height) re f\n"
            }
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(media.minX) \(media.minY) \(media.maxX) \(media.maxY)] /CropBox [\(pageCrop.minX) \(pageCrop.minY) \(pageCrop.maxX) \(pageCrop.maxY)] /Rotate \(rotation) /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
        ]
        var data = "%PDF-1.7\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.utf8.count)
            data += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = data.utf8.count
        data += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for position in offsets.dropFirst() { data += String(format: "%010d 00000 n \n", position) }
        data += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return try XCTUnwrap(PDFDocument(data: Data(data.utf8)))
    }

    private func dump(_ data: Data?, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["EMBER_IMAGE_GEOMETRY_QA_DIRECTORY"], let data else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try data.write(to: url.appendingPathComponent(name))
    }
}
