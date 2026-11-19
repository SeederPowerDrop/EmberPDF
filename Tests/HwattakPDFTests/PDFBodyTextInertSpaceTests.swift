// SPDX-License-Identifier: MPL-2.0

import AppKit
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextInertSpaceTests: XCTestCase {
    func testOnlyEmptyUnownedUnclippedOpaqueTextHasNoPaint() throws {
        try inspectSpace() { object, text in
            XCTAssertTrue(PDFBodyTextEditor.isInertEmptySpace(object, in: text, hasOwnedCharacters: false))
            XCTAssertFalse(PDFBodyTextEditor.isInertEmptySpace(object, in: text, hasOwnedCharacters: true))
        }
        for modifier in ["0 0 100 100 re W n", "/Fade gs"] {
            try inspectSpace(modifier: modifier, space: modifier.contains("W") ? "X" : " ") { object, text in
                XCTAssertFalse(PDFBodyTextEditor.isInertEmptySpace(object, in: text, hasOwnedCharacters: false), modifier)
            }
        }
        try inspectSpace(space: "X") { object, text in
            XCTAssertFalse(PDFBodyTextEditor.isInertEmptySpace(object, in: text, hasOwnedCharacters: false))
        }
    }

    func testOwnedFormRetainsNativeWordSelectionAcrossEmptySpaceChildren() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("beta", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        XCTAssertEqual(target.text.filter { !$0.isWhitespace }, "alphabeta")
        XCTAssertEqual((target.text as NSString).substring(with: try XCTUnwrap(target.initialSelectedRange)), "beta")
        let replacement = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "beta", with: "zeta"), style: target.style, bounds: target.bounds)
        XCTAssertEqual(replacement.string?.filter { !$0.isWhitespace }, "alphazeta")
    }

    func testSingleRealChildWithTrailingEmptySpaceReplacesTheWholeOwnedForm() throws {
        let document = try fixture(singleWordTrailingSpace: true)
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("beta", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        XCTAssertEqual(target.text, "beta")
        let replacement = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "zeta", style: target.style, bounds: target.bounds)
        XCTAssertEqual(replacement.string?.filter { !$0.isWhitespace }, "zeta")
    }

    func testRepeatedEditPreservesUnequalPositionedSpacesWithoutRescalingWords() throws {
        let document = try fixture(spacedWords: true)
        func revise(_ document: PDFDocument, from old: String, to new: String) throws -> PDFDocument {
            let page = try XCTUnwrap(document.page(at: 0))
            let selection = try XCTUnwrap(document.findString(old, withOptions: []).first)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
            let spaces = target.sourceRuns.filter {
                (target.text as NSString).substring(with: $0.range).allSatisfy(\.isWhitespace)
            }
            XCTAssertEqual(spaces.count, 3)
            for (run, expected) in zip(spaces, [CGFloat(2.5), 4, 3]) {
                XCTAssertEqual(try XCTUnwrap(run.horizontalAdvance), expected, accuracy: 0.01)
            }
            let replacement = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: target.text.replacingOccurrences(of: old, with: new), style: target.style, bounds: target.bounds)
            return try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.originalPageData(for: replacement)))
        }
        let first = try revise(document, from: "beta", to: "zeta")
        let second = try revise(first, from: "zeta", to: "beta")
        for word in ["alpha", "gamma", "delta"] {
            let original = try XCTUnwrap(document.findString(word, withOptions: []).first)
            for result in [first, second] {
                let actual = try XCTUnwrap(result.findString(word, withOptions: []).first)
                XCTAssertEqual(actual.bounds(for: result.page(at: 0)!).minX,
                    original.bounds(for: document.page(at: 0)!).minX, accuracy: 0.02)
            }
        }
    }

    func testForeignAndRepeatedFormsCannotUseTheInertSpaceException() throws {
        for document in [try fixture(owned: false), try fixture(repeated: true)] {
            let page = try XCTUnwrap(document.page(at: 0))
            let selection = try XCTUnwrap(document.findString("beta", withOptions: []).first)
            do {
                let target = try PDFBodyTextEditor.target(on: page, selection: selection)
                XCTAssertNil(target)
            } catch { /* Safe rejection is also an accepted outcome. */ }
        }
    }

    private func inspectSpace(modifier: String = "", space: String = " ",
                              body: (FPDF_PAGEOBJECT, FPDF_TEXTPAGE) throws -> Void) throws {
        let document = try fixture(modifier: modifier, space: space)
        let data = try PDFBodyTextPageSnapshot.originalPageData(for: XCTUnwrap(document.page(at: 0)))
        FPDF_InitLibrary()
        try data.withUnsafeBytes { bytes in
            let native = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(native) }
            let page = try XCTUnwrap(FPDF_LoadPage(native, 0))
            defer { FPDF_ClosePage(page) }
            let text = try XCTUnwrap(FPDFText_LoadPage(page))
            defer { FPDFText_ClosePage(text) }
            let form = try XCTUnwrap(FPDFPage_GetObject(page, 0))
            XCTAssertEqual(FPDFFormObj_CountObjects(form), 3)
            try body(try XCTUnwrap(FPDFFormObj_GetObject(form, 1)), text)
        }
    }

    private func fixture(owned: Bool = true, repeated: Bool = false,
                         modifier: String = "", space: String = " ", singleWordTrailingSpace: Bool = false, spacedWords: Bool = false) throws -> PDFDocument {
        let normal = "BT /F1 12 Tf 1 0 0 1 20 80 Tm (alpha) Tj ET q \(modifier) /Span << /ActualText ( ) >> BDC BT /F1 12 Tf 1 0 0 1 50 80 Tm (\(space)) Tj ET EMC Q BT /F1 12 Tf 1 0 0 1 54 80 Tm (beta) Tj ET"
        let singleContent = singleWordTrailingSpace
            ? "BT /F1 12 Tf 1 0 0 1 20 80 Tm (beta) Tj ET /Span << /ActualText ( ) >> BDC BT /F1 12 Tf 1 0 0 1 50 80 Tm ( ) Tj ET EMC"
            : normal
        let content: String
        if spacedWords {
            let words = [("alpha", CGFloat(20)), ("beta", 40.5), ("gamma", 58.9), ("delta", 79.9)]
            content = words.enumerated().map { index, item in
                let show = "BT /F1 6 Tf 1 0 0 1 \(item.1) 80 Tm (\(item.0)) Tj ET"
                guard index < words.count - 1 else { return show }
                let spaceX = item.1 + CGFloat(item.0.count) * 3.6
                return show + " /Span << /ActualText ( ) >> BDC BT /F1 6 Tf 1 0 0 1 \(spaceX) 80 Tm ( ) Tj ET EMC"
            }.joined(separator: " ")
        } else { content = singleContent }
        let invocation = repeated ? "q /Text Do Q q 1 0 0 1 0 -30 cm /Text Do Q" : "q /Text Do Q"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Text 6 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /\(spacedWords ? "Courier" : "Helvetica") >>",
            "<< /Length \(invocation.utf8.count) >>\nstream\n\(invocation)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 200 200] \(owned ? "/EmberPDFBodyText true" : "") /Resources << /Font << /F1 4 0 R >> /ExtGState << /Fade << /Type /ExtGState /ca 0.5 >> >> >> /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer << /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
