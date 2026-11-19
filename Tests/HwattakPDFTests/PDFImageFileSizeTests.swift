// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import PDFKit
import XCTest
@testable import HwattakPDF

/// Exercises production insertion and save paths with compressible photographic
/// texture, rather than a flat-color bitmap that conceals compression changes.
final class PDFImageFileSizeTests: XCTestCase {
    @MainActor
    func testPhotoInsertionRepeatedSaveResizeCropAndDeleteHaveBoundedFileGrowth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EmberPDF-ImageSize-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        let editedURL = directory.appendingPathComponent("edited.pdf")
        let resizeURL = directory.appendingPathComponent("resize.pdf")
        let jpegURL = directory.appendingPathComponent("photographic-texture.jpg")
        try blankPDF().write(to: sourceURL)
        let jpeg = try photographicJPEG()
        try jpeg.write(to: jpegURL)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: sourceURL))
        workspace.setMode(.editing)
        workspace.insertImage(url: jpegURL)
        let imageRequest = try XCTUnwrap(workspace.pendingImageInsertion)
        let preparedImages = try ImageInsertionPreparation.prepare(urls: imageRequest.urls, option: .original)
        XCTAssertTrue(workspace.approveImageInsertion(imageRequest, images: preparedImages))
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let inserted = try XCTUnwrap(page.annotations.compactMap { $0 as? ImageStampAnnotation }.first)
        XCTAssertTrue(workspace.saveSynchronously(as: editedURL), workspace.presentedError ?? "Save failed")
        let first = try snapshot(editedURL)
        try retainArtifact(editedURL, named: "image-first-save.pdf")
        try retainArtifact(jpegURL, named: "image-source.jpg")

        var unchangedSaves: [SizeSnapshot] = []
        for _ in 0..<10 {
            XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
            unchangedSaves.append(try snapshot(editedURL))
        }

        // Reopen a distinct copy on every iteration, just as successive app
        // sessions would. The serialized appearance is now a plain PDFAnnotation.
        try FileManager.default.copyItem(at: editedURL, to: resizeURL)
        var reopenedResizes: [SizeSnapshot] = []
        for iteration in 0..<10 {
            try autoreleasepool {
                let reopened = PDFWorkspaceState()
                XCTAssertTrue(reopened.open(url: resizeURL))
                reopened.setMode(.editing)
                let reopenedPage = try XCTUnwrap(reopened.document?.page(at: 0))
                let annotation = try XCTUnwrap(reopenedPage.annotations.first(where: ImageAnnotationIdentity.isEditableImage))
                let previousBounds = annotation.bounds
                let previousDate = annotation.modificationDate
                annotation.bounds = CGRect(x: 100 + iteration, y: 130, width: 190 + iteration, height: 140 + iteration)
                annotation.modificationDate = Date()
                reopened.registerAnnotationGeometryChange(annotation, on: reopenedPage,
                    from: previousBounds, originalModificationDate: previousDate, message: "Resize image")
                XCTAssertTrue(reopened.saveSynchronously(), reopened.presentedError ?? "Save failed")
                reopenedResizes.append(try snapshot(resizeURL))
            }
        }

        let oldCrop = inserted.normalizedCropRect
        let oldBounds = inserted.bounds
        let oldDate = inserted.modificationDate
        inserted.updateCropRect(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        workspace.registerAnnotationGeometryChange(inserted, on: page, from: oldBounds,
            originalCropRect: oldCrop, originalModificationDate: oldDate, message: "Crop image")
        XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
        let cropped = try snapshot(editedURL)
        try retainArtifact(editedURL, named: "image-cropped.pdf")
        for _ in 0..<3 {
            XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
            let savedCrop = try snapshot(editedURL)
            XCTAssertEqual(savedCrop.images, cropped.images)
            XCTAssertLessThanOrEqual(savedCrop.bytes, cropped.bytes + 16_384)
        }
        XCTAssertTrue(workspace.deleteImageAnnotation(inserted, on: page))
        XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
        let deleted = try snapshot(editedURL)
        try retainArtifact(editedURL, named: "image-deleted.pdf")
        let baseline = try snapshot(sourceURL)
        let report = SizeReport(jpegBytes: jpeg.count, baseline: baseline, firstSave: first,
            unchangedSaves: unchangedSaves, reopenedResizes: reopenedResizes,
            cropped: cropped, deleted: deleted)
        try writeReport(report)

        XCTAssertEqual(first.annotationCount, 1)
        XCTAssertTrue(first.images.contains { $0.width == 1_024 && $0.height == 768 })
        XCTAssertLessThanOrEqual(first.bytes, jpeg.count + 65_536,
            "An unchanged JPEG must retain its source compression rather than expand into raw pixels.")
        XCTAssertTrue(first.images.contains { $0.filter == "DCTDecode" && $0.storedBytes <= jpeg.count && $0.storedBytes >= jpeg.count - 1_024 },
            "The first appearance must embed JPEG without recompression; metadata may be removed.")
        for saved in unchangedSaves + reopenedResizes {
            XCTAssertEqual(saved.annotationCount, 1)
            XCTAssertEqual(saved.images, first.images, "Save/resize must not duplicate or resample image XObjects.")
            XCTAssertLessThanOrEqual(saved.bytes, first.bytes + 16_384,
                "Metadata/geometry changes must not accumulate prior image appearances.")
        }
        XCTAssertTrue(cropped.images.contains { $0.width == 512 && $0.height == 384 })
        XCTAssertFalse(cropped.images.contains { $0.width == 1_024 && $0.height == 768 },
            "The saved crop must not retain hidden source pixels.")
        // A detached lossless crop can exceed the source JPEG; it must contain
        // only visible pixels and remain stable when saved again.
        XCTAssertEqual(deleted.annotationCount, 0)
        XCTAssertTrue(deleted.images.isEmpty, "Deleted image resources must not remain reachable in the PDF.")
        XCTAssertLessThan(deleted.bytes, baseline.bytes + 16_384,
            "Deleting the only photo should remove its serialized image payload.")
    }

    private struct ImageResource: Codable, Equatable {
        let width: Int
        let height: Int
        let storedBytes: Int
        let filter: String
    }

    private struct SizeSnapshot: Codable {
        let bytes: Int
        let annotationCount: Int
        let images: [ImageResource]
    }

    private struct SizeReport: Codable {
        let jpegBytes: Int
        let baseline: SizeSnapshot
        let firstSave: SizeSnapshot
        let unchangedSaves: [SizeSnapshot]
        let reopenedResizes: [SizeSnapshot]
        let cropped: SizeSnapshot
        let deleted: SizeSnapshot
    }

    private func snapshot(_ url: URL) throws -> SizeSnapshot {
        let data = try Data(contentsOf: url)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let dictionary = try XCTUnwrap(page.dictionary)
        let collector = ResourceCollector()
        collector.visitDictionary(dictionary)
        var annotations: CGPDFArrayRef?
        _ = CGPDFDictionaryGetArray(dictionary, "Annots", &annotations)
        return SizeSnapshot(bytes: data.count,
            annotationCount: annotations.map(CGPDFArrayGetCount) ?? 0,
            images: collector.images.sorted {
                if $0.width != $1.width { return $0.width < $1.width }
                if $0.height != $1.height { return $0.height < $1.height }
                if $0.storedBytes != $1.storedBytes { return $0.storedBytes < $1.storedBytes }
                return $0.filter < $1.filter
            })
    }

    private final class ResourceCollector {
        var images: [ImageResource] = []
        var visited = Set<UInt>()

        func visitDictionary(_ dictionary: CGPDFDictionaryRef) {
            guard visited.insert(pdfReferenceIdentity(dictionary)).inserted,
                  visited.count < 10_000 else { return }
            CGPDFDictionaryApplyFunction(dictionary, { key, object, context in
                guard let context, strcmp(key, "Parent") != 0 else { return }
                Unmanaged<ResourceCollector>.fromOpaque(context).takeUnretainedValue().visitObject(object)
            }, Unmanaged.passUnretained(self).toOpaque())
        }

        private func visitObject(_ object: CGPDFObjectRef) {
            switch CGPDFObjectGetType(object) {
            case .dictionary:
                var dictionary: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary { visitDictionary(dictionary) }
            case .array:
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &array), let array,
                      visited.insert(pdfReferenceIdentity(array)).inserted else { return }
                for index in 0..<min(10_000, CGPDFArrayGetCount(array)) {
                    var element: CGPDFObjectRef?
                    if CGPDFArrayGetObject(array, index, &element), let element { visitObject(element) }
                }
            case .stream:
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      visited.insert(pdfReferenceIdentity(stream)).inserted,
                      let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                   strcmp(subtype, "Image") == 0 {
                    var width = 0, height = 0, length = 0
                    var filter: UnsafePointer<CChar>?
                    _ = CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                    _ = CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                    _ = CGPDFDictionaryGetInteger(dictionary, "Length", &length)
                    _ = CGPDFDictionaryGetName(dictionary, "Filter", &filter)
                    images.append(ImageResource(width: width, height: height, storedBytes: length,
                        filter: filter.map { String(cString: $0) } ?? "none-or-array"))
                }
                visitDictionary(dictionary)
            default: break
            }
        }
    }

    private func blankPDF() throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func photographicJPEG() throws -> Data {
        let width = 1_024, height = 768
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        var random: UInt64 = 0x1234_5678_9abc_def0
        for y in 0..<height {
            for x in 0..<width {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                let noise = Int((random >> 32) & 63) - 31
                let ripple = Int(28 * sin(Double(x + y) / 23) + 19 * cos(Double(x - y) / 51))
                let values = [40 + x * 130 / width + ripple + noise,
                    60 + y * 130 / height + ripple + noise,
                    85 + (x + y) * 100 / (width + height) - ripple + noise]
                let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
                for channel in 0..<3 { pixels[offset + channel] = UInt8(clamping: values[channel]) }
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.55]))
    }

    private func auditDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["EMBER_SIZE_AUDIT_DIRECTORY"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func retainArtifact(_ source: URL, named name: String) throws {
        guard let directory = try auditDirectory() else { return }
        try Data(contentsOf: source).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func writeReport(_ report: SizeReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if let directory = try auditDirectory() {
            try data.write(to: directory.appendingPathComponent("image-file-size.json"), options: .atomic)
        }
        print("IMAGE_FILE_SIZE jpeg=\(report.jpegBytes) first=\(report.firstSave.bytes) repeated=\(report.unchangedSaves.map(\.bytes)) resized=\(report.reopenedResizes.map(\.bytes)) cropped=\(report.cropped.bytes) deleted=\(report.deleted.bytes)")
    }
}
