// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFCompressionServiceTests: XCTestCase {
    func testPresetsReducePhotoBytesAndPreserveNativeTextGeometryAnnotationsAndOutline() throws {
        let input = try fixture()
        let source = try XCTUnwrap(PDFDocument(data: input))
        var sizes: [Int] = []
        for quality in PDFCompressionQuality.allCases {
            let result = try PDFCompressionService.compress(data: input, quality: quality)
            XCTAssertTrue(result.didReduce)
            XCTAssertEqual(result.originalBytes, input.count)
            XCTAssertEqual(result.compressedBytes, result.data.count)
            XCTAssertLessThan(result.compressedBytes, input.count / 2)
            let document = try XCTUnwrap(PDFDocument(data: result.data))
            XCTAssertEqual(document.pageCount, 2)
            XCTAssertEqual(document.string, source.string)
            XCTAssertTrue(document.string?.contains("Searchable native text") == true)
            XCTAssertTrue(document.string?.contains("한글") == true)
            for index in 0..<2 {
                let before = try XCTUnwrap(source.page(at: index))
                let after = try XCTUnwrap(document.page(at: index))
                XCTAssertEqual(before.rotation, after.rotation)
                for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                    XCTAssertEqual(before.bounds(for: box), after.bounds(for: box))
                }
                XCTAssertEqual(after.annotations.count, before.annotations.count)
            }
            let page = try XCTUnwrap(document.page(at: 0))
            let field = try XCTUnwrap(page.annotations.first { $0.type == "Widget" })
            XCTAssertEqual(field.fieldName, "customer")
            XCTAssertEqual(field.widgetStringValue, "Editable value")
            XCTAssertEqual(field.widgetFieldType, .text)
            field.widgetStringValue = "Changed after compression"
            let resaved = PDFDocument(data: try XCTUnwrap(document.dataRepresentation()))
            XCTAssertEqual(resaved?.page(at: 0)?.annotations.first { $0.type == "Widget" }?.widgetStringValue,
                "Changed after compression")
            XCTAssertEqual(page.annotations.first { $0.type == "Link" }?.url?.absoluteString, "https://example.com/reference")
            XCTAssertEqual(document.outlineRoot?.child(at: 0)?.label, "Second native page")
            XCTAssertEqual(document.outlineRoot?.child(at: 0)?.destination?.page.map(document.index(for:)), 1)
            // A filtered page still has native text and path operators, not a
            // page-sized bitmap with an OCR layer added afterwards.
            let operations = try scanOperators(try XCTUnwrap(document.page(at: 1)?.pageRef))
            XCTAssertGreaterThan(operations.text, 0)
            XCTAssertGreaterThan(operations.paths, 0)
            sizes.append(result.compressedBytes)
        }
        XCTAssertGreaterThan(sizes[0], sizes[1])
        XCTAssertGreaterThan(sizes[1], sizes[2])
        print("PDF_COMPRESSION_AUDIT source=\(input.count) high=\(sizes[0]) balanced=\(sizes[1]) small=\(sizes[2])")
    }

    func testCompressedCanonicalFormRetainsItsFieldsTreeAndValue() throws {
        let input = try PDFCanonicalFormMaterializer.materialize(fixture())
        let result = try PDFCompressionService.compress(data: input, quality: .balanced)
        XCTAssertTrue(result.didReduce)
        XCTAssertLessThan(result.data.count, input.count)
        let provider = try XCTUnwrap(CGDataProvider(data: result.data as CFData))
        let native = try XCTUnwrap(CGPDFDocument(provider))
        let catalog = try XCTUnwrap(native.catalog)
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?, field: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(form), "Fields", &fields))
        XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(fields)), 1)
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(fields), 0, &field))
        var name: CGPDFStringRef?, value: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(field), "T", &name))
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(field), "V", &value))
        XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(try XCTUnwrap(name))) as String, "customer")
        XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(try XCTUnwrap(value))) as String, "Editable value")
        XCTAssertEqual(try PDFCanonicalFormMaterializer.materialize(input), input)
    }

    func testInsertedPhotoAppearanceShrinksAndKeepsEditableStampAndStackingOrder() throws {
        let document = try XCTUnwrap(PDFDocument(data: tinyPDF()))
        let page = try XCTUnwrap(document.page(at: 0))
        let behind = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .square, withProperties: nil)
        behind.contents = "Behind photo"; page.addAnnotation(behind)
        let raster = try photo(transparent: false)
        let stamp = ImageStampAnnotation(image: NSImage(cgImage: raster, size: CGSize(width: raster.width, height: raster.height)),
            bounds: CGRect(x: 75, y: 150, width: 300, height: 225))
        _ = ImageAnnotationIdentity.assign(to: stamp)
        page.addAnnotation(stamp)
        let front = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 20, height: 20), forType: .circle, withProperties: nil)
        front.contents = "Above photo"; page.addAnnotation(front)
        let input = try XCTUnwrap(document.dataRepresentation())
        let result = try PDFCompressionService.compress(data: input, quality: .balanced)
        XCTAssertTrue(result.didReduce)
        XCTAssertLessThan(result.compressedBytes, input.count / 3)
        let reopened = try XCTUnwrap(PDFDocument(data: result.data))
        let after = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(after.annotations.map(\.type), ["Square", "Stamp", "Circle"])
        XCTAssertEqual(after.annotations.first?.contents, "Behind photo")
        XCTAssertEqual(after.annotations.last?.contents, "Above photo")
        XCTAssertTrue(ImageAnnotationIdentity.isEditableImage(after.annotations[1]))
        XCTAssertEqual(after.annotations[1].bounds, stamp.bounds)
        let beforePixels = try renderAnnotation(stamp)
        let afterPixels = try renderAnnotation(after.annotations[1])
        XCTAssertGreaterThan(beforePixels.filter { $0 < 240 }.count, beforePixels.count / 4)
        XCTAssertGreaterThan(afterPixels.filter { $0 < 240 }.count, afterPixels.count / 4)
        let averageError = zip(beforePixels, afterPixels).map { abs(Int($0) - Int($1)) }.reduce(0, +) / beforePixels.count
        XCTAssertLessThan(averageError, 8, "Compression must preserve the appearance's position, color and orientation.")
        after.annotations[1].bounds.origin.x += 20
        let edited = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(reopened.dataRepresentation())))
        XCTAssertEqual(edited.page(at: 0)?.annotations[1].bounds.minX, stamp.bounds.minX + 20)
        print("PDF_COMPRESSION_STAMP_AUDIT source=\(input.count) balanced=\(result.compressedBytes) meanPixelError=\(averageError)")
    }

    func testTransparentInsertedStampRetainsAlphaAndVisiblePixels() throws {
        let document = try XCTUnwrap(PDFDocument(data: tinyPDF()))
        let page = try XCTUnwrap(document.page(at: 0))
        let image = try photo(transparent: true)
        let stamp = ImageStampAnnotation(image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)),
            bounds: CGRect(x: 50, y: 100, width: 400, height: 300))
        _ = ImageAnnotationIdentity.assign(to: stamp)
        stamp.setValue("Keep custom metadata", forAnnotationKey: PDFAnnotationKey(rawValue: "/EmberTestProperty"))
        page.addAnnotation(stamp)
        let input = try XCTUnwrap(document.dataRepresentation())
        let before = try renderAnnotation(stamp)
        XCTAssertGreaterThan(before.filter { $0 < 240 }.count, before.count / 8)
        let result = try PDFCompressionService.compress(data: input, quality: .small)
        let reopened = try XCTUnwrap(PDFDocument(data: result.data))
        let annotation = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertTrue(ImageAnnotationIdentity.isEditableImage(annotation))
        XCTAssertEqual(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/EmberTestProperty")) as? String,
            "Keep custom metadata")
        let after = try renderAnnotation(annotation)
        XCTAssertGreaterThan(after.filter { $0 < 240 }.count, after.count / 8)
        for x in [10, 40, 80] {
            let offset = (150 * 400 + x) * 4
            XCTAssertEqual(Array(after[offset..<(offset + 3)]), [255, 255, 255])
        }
        let meanError = zip(before, after).map { abs(Int($0) - Int($1)) }.reduce(0, +) / before.count
        XCTAssertLessThan(meanError, 8)
    }

    private func renderAnnotation(_ annotation: PDFAnnotation) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300,
            bitsPerComponent: 8, bytesPerRow: 400 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.scaleBy(x: 400 / annotation.bounds.width, y: 300 / annotation.bounds.height)
        context.translateBy(x: -annotation.bounds.minX, y: -annotation.bounds.minY)
        annotation.draw(with: .mediaBox, in: context)
        return Array(try XCTUnwrap(context.makeImage()?.dataProvider?.data) as Data)
    }

    func testTransparentImagesKeepTheirMaskAndDoNotCoverUnderlyingVectors() throws {
        let input = try fixture(transparent: true, includeMetadata: false)
        let source = try XCTUnwrap(PDFDocument(data: input))
        let before = try render(try XCTUnwrap(source.page(at: 0)?.pageRef))
        for quality in PDFCompressionQuality.allCases {
            let result = try PDFCompressionService.compress(data: input, quality: quality)
            XCTAssertLessThanOrEqual(result.compressedBytes, input.count)
            if quality != .highQuality { XCTAssertTrue(result.didReduce) }
            let document = try XCTUnwrap(PDFDocument(data: result.data))
            let page = try XCTUnwrap(document.page(at: 0)?.pageRef)
            let after = try render(page)
            // The left part of the image is entirely transparent; the green
            // vector underneath must stay visible after JPEG compression.
            for x in [65, 85, 100] {
                let offset = ((792 - 1 - 200) * 612 + x) * 4
                XCTAssertEqual(Array(before[offset..<(offset + 3)]), Array(after[offset..<(offset + 3)]))
                XCTAssertGreaterThan(after[offset + 1], after[offset])
            }
            // Semi-transparent photo pixels should keep the original opacity.
            for channel in 0..<3 {
                let offset = ((792 - 1 - 200) * 612 + 260) * 4 + channel
                XCTAssertLessThanOrEqual(abs(Int(before[offset]) - Int(after[offset])), 15)
            }
            XCTAssertTrue(try hasSoftMask(page), "Image alpha must stay represented as a PDF soft mask.")
        }
    }

    func testAlreadySmallDocumentReturnsOriginalBytesInsteadOfLargerPDF() throws {
        let input = tinyPDF()
        let result = try PDFCompressionService.compress(data: input, quality: .highQuality)
        XCTAssertFalse(result.didReduce)
        XCTAssertEqual(result.data, input)
        XCTAssertEqual(result.originalBytes, input.count)
        XCTAssertEqual(result.compressedBytes, input.count)
    }

    func testEncryptedDocumentIsRejectedEvenAfterOwnerUnlock() throws {
        let document = try XCTUnwrap(PDFDocument(data: tinyPDF()))
        let data = try XCTUnwrap(document.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "owner", PDFDocumentWriteOption.userPasswordOption: "reader"
        ]))
        XCTAssertThrowsError(try PDFCompressionService.compress(data: data, quality: .balanced))
        let opened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(opened.unlock(withPassword: "owner"))
        XCTAssertThrowsError(try PDFCompressionService.validateSource(opened))
    }

    func testSignatureAndAccessibilityStructuresFailClosed() throws {
        for extra in ["/AcroForm << /Fields [5 0 R] >>", "/StructTreeRoot << /Type /StructTreeRoot /K [] >>",
                      "/OCProperties << /OCGs [] >>", "/Names << /EmbeddedFiles << /Names [] >> >>"] {
            let data = tinyPDF(catalogExtra: extra,
                extraObjects: ["<< /FT /Sig /Type /Annot /Subtype /Widget /T (signature) /Rect [0 0 10 10] >>"])
            XCTAssertThrowsError(try PDFCompressionService.compress(data: data, quality: .balanced), extra)
        }
    }

    func testMalformedDataFailsWithoutProducingOutput() throws {
        XCTAssertThrowsError(try PDFCompressionService.compress(data: Data("not a PDF".utf8), quality: .small))
    }

    func testCancelledWorkerDoesNotReturnACompressedCopy() async throws {
        let data = tinyPDF()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PDFCompressionService.compress(data: data, quality: .balanced)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled compression must not offer an output copy.")
        } catch is CancellationError { }
    }

    private func fixture(transparent: Bool = false, includeMetadata: Bool = true) throws -> Data {
        let bytes = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        let image = try photo(transparent: transparent)
        for index in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.08, green: 0.8, blue: 0.16, alpha: 1))
            context.fill(CGRect(x: 50, y: 100, width: 500, height: 375))
            context.draw(image, in: CGRect(x: 50, y: 100, width: 500, height: 375))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.textPosition = CGPoint(x: 40, y: 700)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Searchable native text \(index) — 한글", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            CTLineDraw(line, context)
            context.setStrokeColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
            context.setLineWidth(3)
            context.stroke(CGRect(x: 30, y: 50, width: 530, height: 550))
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: bytes as Data))
        if includeMetadata {
            let page = try XCTUnwrap(document.page(at: 0))
            page.rotation = 90
            for (box, bounds) in [(PDFDisplayBox.cropBox, CGRect(x: 10, y: 15, width: 580, height: 750)),
                (.bleedBox, CGRect(x: 5, y: 10, width: 590, height: 765)),
                (.trimBox, CGRect(x: 15, y: 20, width: 570, height: 740)),
                (.artBox, CGRect(x: 20, y: 25, width: 560, height: 730))] {
                page.setBounds(bounds, for: box)
            }
            let note = PDFAnnotation(bounds: CGRect(x: 40, y: 600, width: 200, height: 35), forType: .freeText, withProperties: nil)
            note.contents = "Editable comment"; note.font = NSFont.systemFont(ofSize: 12)
            note.fontColor = .blue; note.color = .clear
            page.addAnnotation(note)
            let widget = PDFAnnotation(bounds: CGRect(x: 40, y: 550, width: 200, height: 35), forType: .widget, withProperties: nil)
            widget.widgetFieldType = .text; widget.fieldName = "customer"; widget.widgetStringValue = "Editable value"
            page.addAnnotation(widget)
            let link = PDFAnnotation(bounds: CGRect(x: 300, y: 550, width: 100, height: 30), forType: .link, withProperties: nil)
            link.url = URL(string: "https://example.com/reference"); page.addAnnotation(link)
            let highlight = PDFAnnotation(bounds: CGRect(x: 40, y: 695, width: 260, height: 25), forType: .highlight, withProperties: nil)
            highlight.color = .yellow.withAlphaComponent(0.4); page.addAnnotation(highlight)
            let root = PDFOutline()
            let child = PDFOutline(); child.label = "Second native page"
            child.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 1)), at: CGPoint(x: 40, y: 700))
            root.insertChild(child, at: 0); document.outlineRoot = root
            document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Compression preservation", PDFDocumentAttribute.authorAttribute: "EmberPDF Tests",
                PDFDocumentAttribute.subjectAttribute: "Native content", PDFDocumentAttribute.keywordsAttribute: ["photo", "text"]]
        }
        return try XCTUnwrap(document.dataRepresentation())
    }

    private func photo(transparent: Bool) throws -> CGImage {
        let width = 1_536, height = 1_152
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt32 = 19
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = Int((state >> 24) & 31)
                let alpha = !transparent || x > width * 3 / 4 ? 255 : (x < width / 4 ? 0 : 128)
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(((x / 10 + noise) % 256) * alpha / 255)
                pixels[offset + 1] = UInt8(((y / 8 + noise) % 256) * alpha / 255)
                pixels[offset + 2] = UInt8(((x / 20 + y / 13 + noise) % 256) * alpha / 255)
                pixels[offset + 3] = UInt8(alpha)
            }
        }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    private func render(_ page: CGPDFPage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 612, height: 792,
            bitsPerComponent: 8, bytesPerRow: 612 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        context.drawPDFPage(page)
        return Array(try XCTUnwrap(context.makeImage()?.dataProvider?.data) as Data)
    }

    private final class Operations { var text = 0; var paths = 0; var mask = false }

    private func scanOperators(_ page: CGPDFPage) throws -> Operations {
        let result = Operations()
        let table = try XCTUnwrap(CGPDFOperatorTableCreate())
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let info else { return }; Unmanaged<Operations>.fromOpaque(info).takeUnretainedValue().text += 1
        }
        CGPDFOperatorTableSetCallback(table, "S") { _, info in
            guard let info else { return }; Unmanaged<Operations>.fromOpaque(info).takeUnretainedValue().paths += 1
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(result).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        XCTAssertTrue(CGPDFScannerScan(scanner))
        return result
    }

    private func hasSoftMask(_ page: CGPDFPage) throws -> Bool {
        let pageDictionary = try XCTUnwrap(page.dictionary)
        var resources: CGPDFDictionaryRef?, images: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &images), let images else { return false }
        let state = Operations()
        CGPDFDictionaryApplyBlock(images, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream {
                var mask: CGPDFObjectRef?
                if let dictionary = CGPDFStreamGetDictionary(stream), CGPDFDictionaryGetObject(dictionary, "SMask", &mask) { state.mask = true }
            }
            return true
        }, nil)
        return state.mask
    }

    private func tinyPDF(catalogExtra: String = "", extraObjects: [String] = []) -> Data {
        let objects = ["<< /Type /Catalog /Pages 2 0 R \(catalogExtra) >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>", "<< /Length 0 >>\nstream\n\nendstream"] + extraObjects
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
