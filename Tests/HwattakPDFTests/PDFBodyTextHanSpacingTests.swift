// SPDX-License-Identifier: MPL-2.0

import AppKit
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextHanSpacingTests: XCTestCase {
    func testTwoHanObjectsDoNotInventSpaceFromSideBearings() throws {
        for layout in [Layout.separate, .wholeBlock] {
            let source = try fixture(left: "孔", right: "子", layout: layout)
            let page = try XCTUnwrap(source.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.contentData(for: page)
            let native = try audit(page)
            // These are two actual text objects with independently mapped Han
            // semantics. The narrow Latin outlines deliberately create a side
            // bearing gap without an encoded or PDFium-generated word space.
            XCTAssertEqual(native.rootTextObjects, 2)
            XCTAssertEqual(native.scalars, Array("孔子".unicodeScalars.map(\.value)))
            XCTAssertEqual(native.generatedSpaces, 0)
            XCTAssertGreaterThan(native.inkGap, 1.5)
            let target = try target(source, native: native, text: "孔子")
            XCTAssertEqual(target.text, "孔子")
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), before)
        }
    }

    func testSourceOwnedLiteralAndGeneratedSpacesSurvive() throws {
        for (left, right) in [("孔", "子"), ("i", "l")] {
            for layout in [Layout.literalSpace, .generatedSpace] {
                let source = try fixture(left: left, right: right, layout: layout)
                let page = try XCTUnwrap(source.page(at: 0))
                let before = try PDFBodyTextPageSnapshot.contentData(for: page)
                let native = try audit(page)
                let expected = left + " " + right
                XCTAssertEqual(native.scalars, Array(expected.unicodeScalars.map(\.value)))
                if layout == .generatedSpace {
                    XCTAssertGreaterThan(native.generatedSpaces, 0,
                        "The generated-space control must prove actual PDFium ownership.")
                } else {
                    XCTAssertEqual(native.generatedSpaces, 0)
                }
                XCTAssertEqual(try target(source, native: native, text: expected).text, expected)
                XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), before)
            }
        }
    }

    func testLatinAndHangulMeaningfulWordSpacesRemain() throws {
        for (left, right) in [("i", "l"), ("가", "나")] {
            let source = try fixture(left: left, right: right, layout: .literalSpace)
            let page = try XCTUnwrap(source.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.contentData(for: page)
            let native = try audit(page)
            let expected = left + " " + right
            XCTAssertEqual(native.scalars, Array(expected.unicodeScalars.map(\.value)))
            XCTAssertEqual(try target(source, native: native, text: expected).text, expected)
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), before)
        }
    }

    private enum Layout { case separate, wholeBlock, literalSpace, generatedSpace }
    private struct Native {
        let scalars: [UInt32]
        let generatedSpaces: Int
        let rootTextObjects: Int
        let bounds: CGRect
        let inkGap: CGFloat
    }

    private func target(_ document: PDFDocument, native: Native, text: String) throws -> PDFBodyTextTarget {
        let page = try XCTUnwrap(document.page(at: 0))
        let selected = PDFRegionTextSelection(document: document, page: page,
            fragments: [.init(text: text, bounds: native.bounds)])
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
    }

    private func audit(_ page: PDFPage) throws -> Native {
        // Bootstrap the product's process-wide PDFium owner once via its public
        // point entry. The lower-left point contains no text in this fixture.
        _ = try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 5, y: 5))
        let data = try PDFBodyTextPageSnapshot.data(for: page)
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let nativePage = try XCTUnwrap(FPDF_LoadPage(document, 0))
            defer { FPDF_ClosePage(nativePage) }
            let textPage = try XCTUnwrap(FPDFText_LoadPage(nativePage))
            defer { FPDFText_ClosePage(textPage) }
            var scalars: [UInt32] = [], generated = 0, ink: [CGRect] = []
            for index in 0..<FPDFText_CountChars(textPage) {
                guard FPDFText_GetTextObject(textPage, index) != nil,
                      let scalar = UnicodeScalar(FPDFText_GetUnicode(textPage, index)),
                      !CharacterSet.newlines.contains(scalar) else { continue }
                scalars.append(scalar.value)
                if scalar.value == 32, FPDFText_IsGenerated(textPage, index) != 0 { generated += 1 }
                if !CharacterSet.whitespaces.contains(scalar) {
                    var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
                    XCTAssertNotEqual(FPDFText_GetCharBox(textPage, index, &left, &right, &bottom, &top), 0)
                    ink.append(CGRect(x: left, y: bottom, width: right - left, height: top - bottom))
                }
            }
            XCTAssertEqual(ink.count, 2)
            let first = try XCTUnwrap(ink.first), last = try XCTUnwrap(ink.last)
            let rootCount = Int(FPDFPage_CountObjects(nativePage))
            let textCount = (0..<rootCount).filter {
                FPDFPage_GetObject(nativePage, Int32($0)).map { FPDFPageObj_GetType($0) == FPDF_PAGEOBJ_TEXT } ?? false
            }.count
            return Native(scalars: scalars, generatedSpaces: generated,
                rootTextObjects: textCount, bounds: first.union(last), inkGap: last.minX - first.maxX)
        }
    }

    private func fixture(left: String, right: String, layout: Layout) throws -> PDFDocument {
        func hex(_ value: String) -> String { value.utf16.map { String(format: "%04X", $0) }.joined() }
        let cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
            + "/CIDSystemInfo << /Registry (Owned) /Ordering (Spacing) /Supplement 0 >> def\n"
            + "/CMapName /OwnedSpacing def\n/CMapType 2 def\n"
            + "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
            + "3 beginbfchar\n<20> <0020>\n<69> <\(hex(left))>\n<6C> <\(hex(right))>\nendbfchar\n"
            + "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend"
        let prefix = "BT /F1 10 Tf 1 0 0 1 40 80 Tm "
        let stream: String
        switch layout {
        case .separate:
            stream = prefix + "(i) Tj ET\nBT /F1 10 Tf 1 0 0 1 42.57 80 Tm (l) Tj ET\n"
        case .wholeBlock:
            stream = prefix + "(i) Tj 1 0 0 1 42.57 80 Tm (l) Tj ET\n"
        case .literalSpace:
            stream = prefix + "(i ) Tj ET\nBT /F1 10 Tf 1 0 0 1 45 80 Tm (l) Tj ET\n"
        case .generatedSpace:
            stream = prefix + "[(i) -278 (l)] TJ ET\n"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 120] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
            "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
