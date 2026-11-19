// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextReadOrderSourceRowsTests: XCTestCase {
    func testSmallNativeBaselineDifferencesDoNotForceRewritingUntouchedRows() throws {
        let document = try fixture(), page = try XCTUnwrap(document.page(at: 0))
        let before = try XCTUnwrap(page.string), native = before as NSString
        let first = native.range(of: "FIRST original"), last = native.range(of: "KeepLast")
        XCTAssertNotEqual(first.location, NSNotFound)
        XCTAssertNotEqual(last.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: first.location,
            length: NSMaxRange(last) - first.location)))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let revised = target.text.replacingOccurrences(of: "original", with: "revised")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: revised, style: target.style, bounds: target.bounds)
        let output = try PDFBodyTextPageSnapshot.originalPageData(for: edited)
        let reopened = try XCTUnwrap(PDFDocument(data: output)), result = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(result.string?.filter { !$0.isWhitespace },
            before.replacingOccurrences(of: "original", with: "revised").filter { !$0.isWhitespace })
        let content = try PDFBodyTextPageSnapshot.contentData(for: result)
        for row in ["KeepSecond", "KeepThird", "KeepLast"] {
            XCTAssertNotNil(content.range(of: Data("(\(row)) Tj".utf8)),
                "An unchanged native show must keep its original bytes.")
            let old = try XCTUnwrap(document.findString(row, withOptions: []).first)
            let new = try XCTUnwrap(reopened.findString(row, withOptions: []).first)
            XCTAssertEqual(old.bounds(for: page), new.bounds(for: result))
        }
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(reopened.pageCount, 1)
    }

    private func fixture() throws -> PDFDocument {
        let commands = "BT /F1 12 Tf 1 0 0 1 40 180 Tm (KeepTop) Tj ET\n"
            // A rectangular reselect expanded by two points reaches this
            // unrelated tiny header. The exact paragraph range must exclude it.
            + "BT /F1 2 Tf 1 0 0 1 39 149.5 Tm (1) Tj ET\n"
            + "BT /F1 12 Tf 1 0 0 1 40 140 Tm (FIRST original) Tj ET\n"
            + "BT /F1 12 Tf 1 0 0 1 40 122 Tm (KeepSecond) Tj ET\n"
            + "BT /F1 12 Tf 1 0 0 1 40 103.85 Tm (KeepThird) Tj ET\n"
            + "BT /F1 12 Tf 1 0 0 1 40 86 Tm (KeepLast) Tj ET\n"
        let bodies = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 220] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream"
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
