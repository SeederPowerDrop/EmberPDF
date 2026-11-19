// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFOutlinedOCRSnapshotTests: XCTestCase {
    func testSourceFontAndOpaqueMetadataSurviveDonorImportWithoutDuplicateText() throws {
        let source = try sourcePage()
        let paths = try drawingPDF()
        let marker = Data("{\"version\":1,\"text\":\"한국\"}".utf8)
        let donor = try PDFBodyTextPageSnapshot.outlinedOCRDonor(paths,
            semanticContent: Data("BT /EmberOCRSource 12 Tf 3 Tr 1 0 0 1 20 50 Tm <D55CAD6D> Tj ET".utf8),
            sourceFontName: "OCR", sourcePage: source.page(at: 0)!, metadata: marker)
        let donorDocument = try XCTUnwrap(PDFDocument(data: donor))
        let donorPage = try XCTUnwrap(donorDocument.page(at: 0))
        XCTAssertEqual(donorPage.string?.filter { !$0.isWhitespace }, "한국")
        XCTAssertFalse(donorPage.string?.contains("DONOR") == true)
        let before = try XCTUnwrap(PDFDocument(data: paths))
        XCTAssertEqual(try pixels(before.page(at: 0)!), try pixels(donorPage),
            "Removing old invisible shows and adding the source-font text must preserve every painted path.")
        let imported = try PDFBodyTextPageSnapshot.data(for: source.page(at: 0)!,
            contentOverride: Data("q /NewText Do Q".utf8), donorPDF: donor, donorName: "NewText", donorOCRFontName: "OCR")
        let reopened = try XCTUnwrap(PDFDocument(data: imported))
        let page = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(PDFBodyTextPageSnapshot.outlinedOCRMetadata(named: "NewText", on: page), marker)
        XCTAssertNil(PDFBodyTextPageSnapshot.outlinedOCRMetadata(named: "Missing", on: page))
        XCTAssertEqual(page.string?.filter { !$0.isWhitespace }, "한국")
        let rootFont = try XCTUnwrap(PDFBodyTextPageSnapshot.scannedOCRFont(named: "OCR", on: page))
        var rootDictionary: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFObjectGetValue(rootFont.object, .dictionary, &rootDictionary))
        var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?, form: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(page.pageRef!.dictionary!, "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(resources!, "XObject", &xobjects))
        XCTAssertTrue(CGPDFDictionaryGetStream(xobjects!, "NewText", &form))
        var donorResources: CGPDFDictionaryRef?, donorFonts: CGPDFDictionaryRef?, donorFont: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(CGPDFStreamGetDictionary(form!)!, "Resources", &donorResources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(donorResources!, "Font", &donorFonts))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(donorFonts!, "EmberOCRSource", &donorFont))
        XCTAssertEqual(pdfReferenceIdentity(rootDictionary!), pdfReferenceIdentity(donorFont!),
            "The imported Form must borrow the original root font object, not an equal duplicate.")
        XCTAssertEqual(donorDocument.pageCount, 1)
        XCTAssertEqual(reopened.pageCount, 1)
    }

    func testAmbiguousWidthsAndOversizedMetadataDoNotEnterOutlinedRoute() throws {
        let source = try sourcePage(widths: "/W [0 [500]]")
        XCTAssertNil(PDFBodyTextPageSnapshot.scannedOCRFont(named: "OCR", on: source.page(at: 0)!))
        let valid = try sourcePage()
        XCTAssertEqual(PDFBodyTextPageSnapshot.scannedOCRFont(named: "OCR", on: valid.page(at: 0)!)?.defaultWidth, 500)
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.outlinedOCRDonor(drawingPDF(),
            semanticContent: Data(), sourceFontName: "OCR", sourcePage: valid.page(at: 0)!,
            metadata: Data(repeating: 65, count: 1_024 * 1_024 + 1)))
    }

    func testVisibleDonorTextCannotBeSilentlyDiscarded() throws {
        let source = try sourcePage()
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.outlinedOCRDonor(drawingPDF(invisible: false),
            semanticContent: Data(), sourceFontName: "OCR", sourcePage: source.page(at: 0)!, metadata: Data("{}".utf8)))
    }

    func testGeneratedActualTextSpanIsRemovedWithItsInvisibleGlyph() throws {
        let source = try sourcePage()
        let original = try drawingPDF()
        let document = try XCTUnwrap(PDFDocument(data: original)), page = try XCTUnwrap(document.page(at: 0))
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let block = try XCTUnwrap(PDFBodyTextContentStream.parse(content).blocks.first)
        func marked(_ opening: String, extraPaint: String = "") throws -> Data {
            var modified = content
            var replacement = Data((opening + "\n").utf8)
            replacement.append(content.subdata(in: block.range))
            replacement.append(Data(("\n" + extraPaint + " EMC\n").utf8))
            modified.replaceSubrange(block.range, with: replacement)
            return try PDFBodyTextPageSnapshot.data(for: page, contentOverride: modified)
        }
        let paths = try marked("/Span << /ActualText <FEFF00E4> >> BDC")
        let donor = try PDFBodyTextPageSnapshot.outlinedOCRDonor(paths,
            semanticContent: Data("BT /EmberOCRSource 12 Tf 3 Tr 1 0 0 1 20 50 Tm <D55CAD6D> Tj ET".utf8),
            sourceFontName: "OCR", sourcePage: source.page(at: 0)!, metadata: Data("{}".utf8))
        let reopened = try XCTUnwrap(PDFDocument(data: donor)), result = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(result.string?.filter { !$0.isWhitespace }, "한국")
        XCTAssertEqual(try pixels(page), try pixels(result))
        let finalContent = try PDFBodyTextPageSnapshot.contentData(for: result)
        XCTAssertNil(finalContent.range(of: Data("ActualText".utf8)))
        for invalid in [try marked("/OC /Hidden BDC"),
                        try marked("/Span << /ActualText <FEFF00E4> >> BDC", extraPaint: "10 10 5 5 re f")] {
            XCTAssertThrowsError(try PDFBodyTextPageSnapshot.outlinedOCRDonor(invalid,
                semanticContent: Data(), sourceFontName: "OCR", sourcePage: source.page(at: 0)!, metadata: Data("{}".utf8)))
        }
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(reopened.pageCount, 1)
    }

    private func drawingPDF(invisible: Bool = true) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 20, y: 10, width: 40, height: 12))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 10, y: 60)
        context.setTextDrawingMode(invisible ? .invisible : .fill)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "DONOR", attributes: [.font: NSFont.systemFont(ofSize: 12)])), context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func pixels(_ page: PDFPage) throws -> Data {
        var data = Data(repeating: 255, count: 100 * 100 * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 100, height: 100,
                bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        return data
    }

    private func sourcePage(widths: String = "") throws -> PDFDocument {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def /CMapName /Identity-UCS def /CMapType 2 def 1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfrange <0000> <FFFF> <0000> endbfrange endcmap CMapName currentdict /CMap defineresource pop end end"
        let bodies = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Font << /OCR 4 0 R >> >> /Contents 7 0 R >>",
            "<< /Type /Font /Subtype /Type0 /BaseFont /HiddenOCR /Encoding /Identity-H /DescendantFonts [5 0 R] /ToUnicode 6 0 R >>",
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ArialMT /FontDescriptor 8 0 R /CIDToGIDMap /Identity /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 500 \(widths) >>",
            "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [0 -250 1000 1000] /Ascent 1000 /Descent -250 /CapHeight 1000 /StemV 80 /ItalicAngle 0 >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, body) in bodies.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer << /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
