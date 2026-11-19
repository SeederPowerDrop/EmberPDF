// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextLosslessTests: XCTestCase {
    func testRichGraphicsRemainByteForByteAndPixelIdenticalAfterTextEdit() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try unrelatedPixels(page)
        let target = try target("Original line", in: source)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Revised line", style: target.style, bounds: target.bounds)
        let result = document(edited)

        XCTAssertTrue(result.findString("Original line", withOptions: []).isEmpty)
        XCTAssertEqual(result.findString("Revised line", withOptions: []).count, 1)
        XCTAssertEqual(result.findString("Unaffected line", withOptions: []).count, 1)
        XCTAssertEqual(try unrelatedPixels(edited), before)
        XCTAssertTrue(try decodedContents(edited).contains(Self.graphics),
            "CMYK, spot-color, shading and miter commands must survive without stream regeneration.")
        try assertRichResources(edited)
        XCTAssertEqual(source.findString("Original line", withOptions: []).count, 1,
            "Editing the detached page must not change the original document.")
    }

    func testRichPageCanBeSavedReopenedAndEditedAgainWithoutOldSearchText() throws {
        var source = try fixture()
        var control = try fixture()
        for (before, after) in [("Original line", "Revised line"), ("Revised line", "Final line")] {
            let page = try XCTUnwrap(source.page(at: 0))
            let selected = try target(before, in: source)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: after, style: selected.style, bounds: selected.bounds)
            let saved = try XCTUnwrap(document(edited).dataRepresentation())
            source = try XCTUnwrap(PDFDocument(data: saved))
            // PDFKit itself can normalize spot colors/resource names during
            // serialization. Compare against the same untouched save cycle;
            // the unsaved edit has a stricter exact-pixel/byte assertion above.
            let controlPage = try XCTUnwrap(XCTUnwrap(control.page(at: 0)).copy() as? PDFPage)
            control = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document(controlPage).dataRepresentation())))
            let reopened = try XCTUnwrap(source.page(at: 0))
            XCTAssertTrue(source.findString(before, withOptions: []).isEmpty)
            XCTAssertEqual(source.findString(after, withOptions: []).count, 1)
            XCTAssertEqual(try unrelatedPixels(reopened), try unrelatedPixels(XCTUnwrap(control.page(at: 0))))
        }
        XCTAssertTrue(source.findString("Original line", withOptions: []).isEmpty)
    }

    func testPartialSelectionPreservesOtherWordsAndInheritedTextState() throws {
        let source = try fixture(firstText: "Keep original words")
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try unrelatedPixels(page)
        let selected = try target("original", in: source)
        let range = try XCTUnwrap(selected.initialSelectedRange)
        XCTAssertEqual((selected.text as NSString).substring(with: range), "original")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: (selected.text as NSString).replacingCharacters(in: range, with: "revised"),
            style: selected.style, bounds: selected.bounds)
        let result = document(edited)
        XCTAssertEqual(result.findString("Keep revised words", withOptions: []).count, 1)
        XCTAssertTrue(result.findString("original", withOptions: []).isEmpty)
        XCTAssertEqual(try unrelatedPixels(edited), before,
            "Removing a show operation must retain font, character and word spacing inherited by later text blocks.")
    }

    func testDeleteTextRetainsRichGraphicsAndFollowingText() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try unrelatedPixels(page)
        let selected = try target("Original line", in: source)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "", style: selected.style, bounds: selected.bounds)
        let result = document(edited)
        XCTAssertTrue(result.findString("Original line", withOptions: []).isEmpty)
        XCTAssertEqual(result.findString("Unaffected line", withOptions: []).count, 1)
        XCTAssertEqual(try unrelatedPixels(edited), before)
        XCTAssertTrue(try decodedContents(edited).contains(Self.graphics))
    }

    func testNonspaceActualTextTargetRefusesRawReplacementWithoutMutatingSource() throws {
        let source = try fixture(marked: true)
        try assertUnsupportedTargetUnchanged(source)
    }

    func testMultipleTextShowsCanReplaceOneWordWithoutMovingFollowingContent() throws {
        let source = try fixture(firstText: "Keep original words", multipleShows: true)
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try unrelatedPixels(page)
        let selected = try target("original", in: source)
        let range = try XCTUnwrap(selected.initialSelectedRange)
        XCTAssertEqual((selected.text as NSString).substring(with: range), "original")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: (selected.text as NSString).replacingCharacters(in: range, with: "revised"),
            style: selected.style, bounds: selected.bounds)
        let result = document(edited)
        XCTAssertEqual(result.findString("Keep revised words trailing", withOptions: []).count, 1)
        XCTAssertTrue(result.findString("original", withOptions: []).isEmpty)
        XCTAssertEqual(result.findString("Unaffected line", withOptions: []).count, 1)
        XCTAssertEqual(try unrelatedPixels(edited), before)
        XCTAssertEqual(source.findString("Keep original words trailing", withOptions: []).count, 1)
    }

    func testReplacementKeepsPaintOrderBelowLaterVectorCover() throws {
        let source = try fixture(cover: true)
        let page = try XCTUnwrap(source.page(at: 0))
        let selected = try target("Original line", in: source)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "Revised long text", style: selected.style, bounds: selected.bounds)
        XCTAssertEqual(try pixels(edited, region: CGRect(x: 72, y: 263, width: 44, height: 17)),
                       try pixels(page, region: CGRect(x: 72, y: 263, width: 44, height: 17)),
            "Replacement must stay at the source paint position instead of covering later vectors.")
    }

    func testPageTransformIsNotAppliedTwiceToReplacement() throws {
        let source = try fixture(transformed: true)
        let page = try XCTUnwrap(source.page(at: 0))
        let selected = try target("Original line", in: source)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "Revised line", style: selected.style, bounds: selected.bounds)
        let result = document(edited)
        let revised = try target("Revised line", in: result)
        XCTAssertEqual(revised.baseline.x, selected.baseline.x, accuracy: 0.01)
        XCTAssertEqual(revised.baseline.y, selected.baseline.y, accuracy: 0.01)
        XCTAssertEqual(try pixels(edited, region: CGRect(x: 0, y: 0, width: 400, height: 200)),
                       try pixels(page, region: CGRect(x: 0, y: 0, width: 400, height: 200)))
    }

    private func assertUnsupportedTargetUnchanged(_ source: PDFDocument) throws {
        let page = try XCTUnwrap(source.page(at: 0))
        let bytes = try PDFBodyTextPageSnapshot.data(for: page)
        let original = page.string
        let selection = try XCTUnwrap(source.findString("Original line", withOptions: []).first)
        do {
            let selected = try PDFBodyTextEditor.target(on: page, selection: selection)
            XCTAssertNil(selected, "Unsafe mapping must be rejected rather than altering the wrong text show.")
        } catch {
            // The service may reject unsupported structures before returning a target.
        }
        XCTAssertEqual(page.string, original)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), bytes)
    }

    private func target(_ phrase: String, in source: PDFDocument) throws -> PDFBodyTextTarget {
        let page = try XCTUnwrap(source.page(at: 0))
        let selection = try XCTUnwrap(source.findString(phrase, withOptions: []).first)
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
    }

    private func document(_ page: PDFPage) -> PDFDocument {
        let result = PDFDocument()
        result.insert(page, at: 0)
        return result
    }

    private static let graphics = """
    % original graphics: preserve exact operator bytes
    q 0.8 0.1 0 0.15 k 22 25 88 65 re f Q
    q /Spot cs 0.65 scn 128 25 88 65 re f Q
    q 242 25 130 65 re W n /Sh1 sh Q
    q 3.864 M 0 j 6 w 0.1 0.6 0 0 K 30 125 m 78 188 l 126 125 l S Q
    % end original graphics
    """

    private func fixture(firstText: String = "Original line", marked: Bool = false,
                         multipleShows: Bool = false, cover: Bool = false,
                         transformed: Bool = false) throws -> PDFDocument {
        let text = "BT /F1 16 Tf 0.2 Tc 0.5 Tw 1 0 0 1 40 265 Tm (\(firstText)) Tj"
            + (multipleShows ? " ( trailing) Tj" : "") + " ET\n"
        let first = marked ? "/Span << /ActualText (\(firstText)) >> BDC\n\(text)EMC\n" : text
        // This line deliberately inherits the source block's font and spacing.
        let content = (transformed ? "q 0.9 0 0 0.9 12 8 cm\n" : "")
            + first + "BT 1 0 0 1 40 228 Tm (Unaffected line) Tj ET\n"
            + (transformed ? "Q\n" : "") + Self.graphics
            + (cover ? "\nq 0.2 0.7 0.3 rg 70 261 48 21 re f Q\n" : "")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> /ColorSpace << /Spot [/Separation /TestInk /DeviceRGB 6 0 R] >> /Shading << /Sh1 7 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0.1 0.3 0.8] /N 1 >>",
            "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [242 25 372 90] /Function 8 0 R /Extend [true true] >>",
            "<< /FunctionType 2 /Domain [0 1] /C0 [0.9 0.1 0.2] /C1 [0.1 0.7 0.4] /N 1 >>"
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func decodedContents(_ page: PDFPage) throws -> String {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var contents: CGPDFObjectRef?
        XCTAssertTrue(CGPDFDictionaryGetObject(dictionary, "Contents", &contents))
        let object = try XCTUnwrap(contents)
        var streams: [CGPDFStreamRef] = []
        if CGPDFObjectGetType(object) == .stream {
            var stream: CGPDFStreamRef?
            XCTAssertTrue(CGPDFObjectGetValue(object, .stream, &stream))
            streams.append(try XCTUnwrap(stream))
        } else {
            var array: CGPDFArrayRef?
            XCTAssertTrue(CGPDFObjectGetValue(object, .array, &array))
            let values = try XCTUnwrap(array)
            for index in 0..<CGPDFArrayGetCount(values) {
                var stream: CGPDFStreamRef?
                XCTAssertTrue(CGPDFArrayGetStream(values, index, &stream))
                streams.append(try XCTUnwrap(stream))
            }
        }
        return try streams.map { stream in
            var format = CGPDFDataFormat.raw
            return String(decoding: try XCTUnwrap(CGPDFStreamCopyData(stream, &format) as Data?), as: UTF8.self)
        }.joined(separator: "\n")
    }

    private func assertRichResources(_ page: PDFPage) throws {
        let pageDictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var resources: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources))
        let dictionary = try XCTUnwrap(resources)
        var colorSpaces: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "ColorSpace", &colorSpaces))
        var spot: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(colorSpaces), "Spot", &spot))
        var kind: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFArrayGetName(try XCTUnwrap(spot), 0, &kind))
        XCTAssertEqual(String(cString: try XCTUnwrap(kind)), "Separation")
        var shadings: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "Shading", &shadings))
        var shading: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(shadings), "Sh1", &shading))
        var type: CGPDFInteger = 0
        XCTAssertTrue(CGPDFDictionaryGetInteger(try XCTUnwrap(shading), "ShadingType", &type))
        XCTAssertEqual(type, 2)
    }

    private func unrelatedPixels(_ page: PDFPage) throws -> Data {
        // Everything below 246pt includes the second line and every illustration.
        try pixels(page, region: CGRect(x: 0, y: 0, width: 400, height: 246))
    }

    private func pixels(_ page: PDFPage, region: CGRect) throws -> Data {
        let width = 800, height = 600
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: 2, y: 2)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        let xRange = Int(region.minX * 2)..<Int(region.maxX * 2)
        let yRange = Int(region.minY * 2)..<Int(region.maxY * 2)
        var sampled = Data()
        for y in yRange {
            sampled.append(contentsOf: bytes[((height - 1 - y) * width + xRange.lowerBound) * 4..<((height - 1 - y) * width + xRange.upperBound) * 4])
        }
        XCTAssertTrue(sampled.contains { $0 != 255 })
        return sampled
    }
}
