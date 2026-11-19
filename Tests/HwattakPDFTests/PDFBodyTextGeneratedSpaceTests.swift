// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextGeneratedSpaceTests: XCTestCase {
    func testOriginalPositionedWordsRemainSelectableWithoutLosingSpaces() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        for phrase in ["first consider", "Original textbook heading", "textbook"] {
            let selected = try selection(phrase, on: page)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
            let range = try XCTUnwrap(target.initialSelectedRange)
            XCTAssertEqual((target.text as NSString).substring(with: range), phrase)
            XCTAssertTrue(target.text.contains(" "))
        }
        XCTAssertTrue(page.string?.contains("We first consider propagation") == true)
    }

    func testPositionedWordPhraseCanBeEditedSavedAndEditedAgain() throws {
        let document = try fixture()
        let originalPage = try XCTUnwrap(document.page(at: 0))
        let originalTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: originalPage,
            selection: selection("first consider", on: originalPage)))
        let range = try XCTUnwrap(originalTarget.initialSelectedRange)
        let edited = try PDFBodyTextEditor.replacementPage(for: originalPage, target: originalTarget,
            text: (originalTarget.text as NSString).replacingCharacters(in: range, with: "begin modeling"),
            style: originalTarget.style, bounds: originalTarget.bounds)
        let output = PDFDocument()
        output.insert(edited, at: 0)
        let reopened = try XCTUnwrap(PDFDocument(data: XCTUnwrap(output.dataRepresentation())))
        let savedPage = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertTrue(savedPage.string?.contains("We begin modeling propagation") == true)
        let nextTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: savedPage,
            selection: selection("begin modeling", on: savedPage)))
        let nextRange = try XCTUnwrap(nextTarget.initialSelectedRange)
        let revised = try PDFBodyTextEditor.replacementPage(for: savedPage, target: nextTarget,
            text: (nextTarget.text as NSString).replacingCharacters(in: nextRange, with: "study"),
            style: nextTarget.style, bounds: nextTarget.bounds)
        XCTAssertTrue(revised.string?.contains("We study propagation") == true)
        XCTAssertTrue(revised.string?.contains("Original textbook heading") == true)
        XCTAssertTrue(originalPage.string?.contains("We first consider propagation") == true)
    }

    func testPositionedSpacesDoNotPermitDifferentSelectedWords() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let original = try selection("first consider", on: page)
        let mismatch = PDFRegionTextSelection(document: document, page: page,
            fragments: [.init(text: "different words", bounds: original.bounds(for: page))])
        XCTAssertNil(try PDFBodyTextEditor.target(on: page, selection: mismatch))
    }

    private func selection(_ phrase: String, on page: PDFPage) throws -> PDFSelection {
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound)
        return try XCTUnwrap(page.selection(for: range))
    }

    private func fixture() throws -> PDFDocument {
        // No literal spaces appear inside any text string. PDFium reconstructs
        // the word spaces from TJ positioning and reports them as generated.
        let stream = "BT /F1 9.9626 Tf 1 0 0 1 90 240 Tm [(We) -250 (first) -250 (consider) -250 (propagation)] TJ ET\n"
            + "BT /F1 9.9626 Tf 1 0 0 1 90 200 Tm [(Original) -250 (textbook) -250 (heading)] TJ ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 320] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
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
