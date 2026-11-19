// SPDX-License-Identifier: MPL-2.0
import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextCIDFontSafetyTests: XCTestCase {
    func testNativeRewriteRefusesDistinctCIDFontsWithSameGeneratorKey() throws {
        let document = try fixture(nonzeroOrigin: true, shareFont: false)
        let page = try XCTUnwrap(document.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 75, y: 505)))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testNativeRewriteAllowsTwoResourceAliasesOfOneCIDFont() throws {
        let document = try fixture(nonzeroOrigin: true, shareFont: true)
        XCTAssertNotNil(try PDFBodyTextEditor.target(on: XCTUnwrap(document.page(at: 0)), at: CGPoint(x: 75, y: 505)))
    }

    func testLosslessRewriteStillAllowsDistinctCIDFonts() throws {
        let document = try fixture(nonzeroOrigin: false, shareFont: false)
        let page = try XCTUnwrap(document.page(at: 0))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, at: CGPoint(x: 75, y: 505)))
        let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Revised", style: target.style, bounds: target.bounds)
        let content = String(decoding: try PDFBodyTextPageSnapshot.contentData(for: result), as: UTF8.self)
        XCTAssertTrue(content.contains("/C1 20 Tf 40 300 Td <0001> Tj"))
        XCTAssertTrue(content.contains("/C2 20 Tf 40 250 Td <0002> Tj"))
        XCTAssertTrue((result.string ?? "").contains("Revised"))
    }

    private func fixture(nonzeroOrigin: Bool, shareFont: Bool) throws -> PDFDocument {
        let content = "BT /F1 20 Tf 40 500 Td (Original) Tj ET\nBT /C1 20 Tf 40 300 Td <0001> Tj ET\nBT /C2 20 Tf 40 250 Td <0002> Tj ET"
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def /CMapName /Test def /CMapType 2 def 1 begincodespacerange <0000> <FFFF> endcodespacerange 2 beginbfchar <0001> <0041> <0002> <0042> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end"
        let font = "<< /Type /Font /Subtype /Type0 /BaseFont /TestCID /Encoding /Identity-H /DescendantFonts [7 0 R] /ToUnicode 8 0 R >>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(nonzeroOrigin ? "10 20 410 620" : "0 0 400 600")] /Resources << /Font << /F1 4 0 R /C1 5 0 R /C2 \(shareFont ? 5 : 6) 0 R >> >> /Contents 10 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", font, font,
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCID /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 1000 /FontDescriptor 9 0 R /CIDToGIDMap /Identity >>",
            "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream",
            "<< /Type /FontDescriptor /FontName /TestCID /Flags 4 /FontBBox [0 -200 1000 800] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
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
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
