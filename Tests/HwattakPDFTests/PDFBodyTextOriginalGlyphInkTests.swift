// SPDX-License-Identifier: MPL-2.0
// Owned generated fixtures only; no corpus filenames, pages or text conditions.
import AppKit
import CoreText
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextOriginalGlyphInkTests: XCTestCase {
    func testMappedSourceGlyphInkIncludesBearingRoundedOutOfNativeCharBox() throws {
        try withOwnedSource { snapshot, content, range, object, textPage, _ in
            let ink = try XCTUnwrap(PDFBodyTextOriginalGlyphInk.envelope(snapshot: snapshot,
                sourceContent: content, showRange: range, sourceFormName: nil,
                expectedText: "both", nativeObject: object, nativeTextPage: textPage))
            var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
            XCTAssertNotEqual(FPDFText_GetCharBox(textPage, 0, &left, &right, &bottom, &top), 0)
            let font = try XCTUnwrap(NSFont(name: "Georgia", size: 15))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "both", attributes: [
                .font: font, .foregroundColor: NSColor.black, .ligature: 0]))
            let actualSourceInk = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                .offsetBy(dx: 80.125, dy: 190.375)
            // This independent source path has a negative bearing omitted by
            // the native quantized CharBox. No fit tolerance is introduced.
            XCTAssertEqual(ink.minX, actualSourceInk.minX)
            XCTAssertLessThan(ink.minX, left)
        }
    }

    func testSourceInkRefusesEncodingPresenceAndMisboundNativeCode() throws {
        try withOwnedSource { snapshot, content, range, object, textPage, program in
            XCTAssertNotNil(try PDFBodyTextOriginalGlyphInk.envelope(snapshot: snapshot,
                sourceContent: content, showRange: range, sourceFormName: nil,
                expectedText: "both", nativeObject: object, nativeTextPage: textPage),
                "Negative cases must start from a non-vacuous accepted owner.")
            for encoding in ["/WinAnsiEncoding", "<< /BaseEncoding /MacRomanEncoding /Differences [98 /h] >>"] {
                let foreign = pdf(program: program, content: content, encoding: encoding)
                XCTAssertNil(try PDFBodyTextOriginalGlyphInk.envelope(snapshot: foreign,
                    sourceContent: content, showRange: range, sourceFormName: nil,
                    expectedText: "both", nativeObject: object, nativeTextPage: textPage))
            }
            let nullMap = pdf(program: program, content: content, encoding: "/MacRomanEncoding", extra: "/ToUnicode null")
            XCTAssertNil(try PDFBodyTextOriginalGlyphInk.envelope(snapshot: nullMap,
                sourceContent: content, showRange: range, sourceFormName: nil,
                expectedText: "both", nativeObject: object, nativeTextPage: textPage))
            // Same valid font/program and independently mapped existing glyphs,
            // but a raw show whose bytes do not belong to the native object.
            let raw = try XCTUnwrap(String(data: content, encoding: .utf8))
            XCTAssertEqual(raw.components(separatedBy: "(both)").count, 2)
            let changed = Data(raw.replacingOccurrences(of: "(both)", with: "(hoth)").utf8)
            let parsed = try PDFBodyTextContentStream.parse(changed)
            let changedRange = try XCTUnwrap(parsed.records.first).showRange
            let misbound = pdf(program: program, content: changed, encoding: "/MacRomanEncoding")
            XCTAssertNil(try PDFBodyTextOriginalGlyphInk.envelope(snapshot: misbound,
                sourceContent: changed, showRange: changedRange, sourceFormName: nil,
                expectedText: "hoth", nativeObject: object, nativeTextPage: textPage))
            var multiple = content
            multiple.replaceSubrange(range, with: Data("(b) Tj (oth) Tj".utf8))
            XCTAssertNotEqual(multiple, content)
            XCTAssertNil(try PDFBodyTextOriginalGlyphInk.envelope(
                snapshot: pdf(program: program, content: multiple, encoding: "/MacRomanEncoding"),
                sourceContent: multiple, showRange: range, sourceFormName: nil,
                expectedText: "both", nativeObject: object, nativeTextPage: textPage))
            var differentProgram = program
            differentProgram[differentProgram.count - 1] ^= 1
            let foreignProgram = pdf(program: differentProgram, content: content, encoding: "/MacRomanEncoding")
            XCTAssertNil(try PDFBodyTextOriginalGlyphInk.envelope(snapshot: foreignProgram,
                sourceContent: content, showRange: range, sourceFormName: nil,
                expectedText: "both", nativeObject: object, nativeTextPage: textPage))
        }
    }

    private func withOwnedSource(_ body: (Data, Data, Range<Int>, FPDF_PAGEOBJECT, FPDF_TEXTPAGE, Data) throws -> Void) throws {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 360, height: 280)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = try XCTUnwrap(NSFont(name: "Georgia", size: 15))
        context.beginPDFPage(nil); context.textMatrix = .identity
        context.textPosition = CGPoint(x: 80.125, y: 190.375)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "both", attributes: [
            .font: font, .foregroundColor: NSColor.black, .ligature: 0]))
        CTLineDraw(line, context); context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes as Data))
        let page = try XCTUnwrap(document.page(at: 0)), string = try XCTUnwrap(page.string) as NSString
        let selection = try XCTUnwrap(page.selection(for: string.range(of: "both")))
        // Initializes the ordinary product native owner before direct handles.
        XCTAssertNotNil(try PDFBodyTextEditor.target(on: page, selection: selection))
        let snapshot = try PDFBodyTextPageSnapshot.data(for: page)
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let parsed = try PDFBodyTextContentStream.parse(content)
        XCTAssertEqual(parsed.records.count, 1)
        let range = try XCTUnwrap(parsed.records.first).showRange
        try snapshot.withUnsafeBytes { raw in
            let owner = try XCTUnwrap(FPDF_LoadMemDocument64(raw.baseAddress, snapshot.count, nil))
            defer { FPDF_CloseDocument(owner) }
            let native = try XCTUnwrap(FPDF_LoadPage(owner, 0)); defer { FPDF_ClosePage(native) }
            let textPage = try XCTUnwrap(FPDFText_LoadPage(native)); defer { FPDFText_ClosePage(textPage) }
            let count = FPDFPage_CountObjects(native)
            let objects = (0..<count).compactMap { FPDFPage_GetObject(native, $0) }
                .filter { FPDFPageObj_GetType($0) == FPDF_PAGEOBJ_TEXT }
            XCTAssertEqual(objects.count, 1)
            let object = try XCTUnwrap(objects.first), nativeFont = try XCTUnwrap(FPDFTextObj_GetFont(object))
            var length = 0
            XCTAssertNotEqual(FPDFFont_GetFontData(nativeFont, nil, 0, &length), 0)
            guard length > 0, length <= 1_024 * 1_024 else { throw NSError(domain: "OwnedProgramCap", code: 1) }
            var program = Data(count: length), copied = length
            let success = program.withUnsafeMutableBytes {
                FPDFFont_GetFontData(nativeFont, $0.bindMemory(to: UInt8.self).baseAddress, length, &copied)
            }
            XCTAssertNotEqual(success, 0); XCTAssertEqual(copied, length)
            try body(snapshot, content, range, object, textPage, program)
        }
    }

    // Tiny intentionally varied raw metadata. A negative result never grants
    // these synthetic bytes the original owner's production prefix proof.
    private func pdf(program: Data, content: Data, encoding: String, extra: String = "") -> Data {
        func stream(_ data: Data) -> Data {
            Data("<< /Length \(data.count) >>\nstream\n".utf8) + data + Data("\nendstream".utf8)
        }
        let widths = Array(repeating: "500", count: 256).joined(separator: " ")
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 360 280] /Resources << /Font << /TT1 5 0 R >> >> /Contents 4 0 R >>".utf8),
            stream(content),
            Data("<< /Type /Font /Subtype /TrueType /BaseFont /OwnedGeorgia /Encoding \(encoding) \(extra) /FirstChar 0 /LastChar 255 /Widths [\(widths)] /FontDescriptor 6 0 R >>".utf8),
            Data("<< /Type /FontDescriptor /FontName /OwnedGeorgia /Flags 32 /FontBBox [-1000 -1000 2000 2000] /ItalicAngle 0 /Ascent 1000 /Descent -1000 /CapHeight 700 /StemV 80 /FontFile2 7 0 R >>".utf8),
            stream(program)]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index+1) 0 obj\n".utf8)); data.append(object); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
