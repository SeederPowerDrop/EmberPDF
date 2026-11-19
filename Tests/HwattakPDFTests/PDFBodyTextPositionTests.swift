// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextPositionTests: XCTestCase {
    func testRoundingTextbookFontSizeKeepsOriginalBaseline() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let target = try target(for: "Original text", on: page)
        XCTAssertEqual(target.style.fontSize, 9.9626, accuracy: 0.0001)
        var style = target.style
        style.fontSize = 10

        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Updated text", style: style, bounds: target.bounds)
        let replacement = try self.target(for: "Updated text", on: edited)

        XCTAssertEqual(replacement.bounds.minX, target.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(baseline(of: replacement), baseline(of: target), accuracy: 0.01)
        XCTAssertEqual(replacement.style.fontSize, 10, accuracy: 0.001)
    }

    func testLargerFontAndDifferentFamilyKeepBaselineAfterSaveAndReopen() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try target(for: "Original text", on: page)
        var style = target.style
        style.fontName = "Helvetica"
        style.fontSize = 16
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Updated text", style: style, bounds: target.bounds)
        let output = PDFDocument()
        output.insert(edited, at: 0)
        let reopened = try XCTUnwrap(PDFDocument(data: XCTUnwrap(output.dataRepresentation())))
        let savedPage = try XCTUnwrap(reopened.page(at: 0))
        let replacement = try self.target(for: "Updated text", on: savedPage)

        XCTAssertEqual(replacement.bounds.minX, target.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(baseline(of: replacement), baseline(of: target), accuracy: 0.01)
        XCTAssertEqual(savedPage.bounds(for: .cropBox), page.bounds(for: .cropBox))
        XCTAssertTrue(savedPage.string?.contains("Unrelated text") == true)
        XCTAssertTrue(page.string?.contains("Original text") == true)
    }

    func testRepeatedSizeChangesDoNotAccumulateVerticalDrift() throws {
        let document = try fixture()
        var page = try XCTUnwrap(document.page(at: 0))
        var original = try target(for: "Original text", on: page)
        let expectedBaseline = baseline(of: original)
        let expectedX = original.bounds.minX
        for (index, size) in [10.0, 12.0, 9.9626].enumerated() {
            var style = original.style
            style.fontSize = size
            let phrase = "Updated text \(index)"
            page = try PDFBodyTextEditor.replacementPage(for: page, target: original,
                text: phrase, style: style, bounds: original.bounds)
            original = try target(for: phrase, on: page)
            XCTAssertEqual(original.bounds.minX, expectedX, accuracy: 0.01)
            XCTAssertEqual(baseline(of: original), expectedBaseline, accuracy: 0.01)
        }
    }

    private func baseline(of target: PDFBodyTextTarget) -> CGFloat {
        target.bounds.minY - target.style.font.descender
    }

    private func target(for phrase: String, on page: PDFPage) throws -> PDFBodyTextTarget {
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: range))
        let rect = selection.bounds(for: page)
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page,
            at: CGPoint(x: rect.midX, y: rect.midY)))
    }

    private func fixture() throws -> PDFDocument {
        // Match the fractional Times size and inset CropBox of Ultrafast
        // Optics without keeping any user document content in the test suite.
        let stream = "BT /F1 9.9626 Tf 1 0 0 1 136 689 Tm (Original text) Tj ET\n"
            + "BT /F1 9.9626 Tf 1 0 0 1 136 620 Tm (Unrelated text) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /CropBox [51 45 555 765] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
