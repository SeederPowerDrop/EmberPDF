// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextRepeatedLineTests: XCTestCase {
    func testEachGeneratedLineCanBeEditedIndividuallyBeforeAndAfterSaving() throws {
        for reopened in [false, true] {
            var document = try generatedLines()
            if reopened { document = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation()))) }
            let originalText = try XCTUnwrap(document.string)
            for (before, after) in [("First changed line", "First revised line"),
                                    ("Second changed line", "Second revised line"),
                                    ("Third changed line", "Third revised line")] {
                let page = try XCTUnwrap(document.page(at: 0))
                let selection = try XCTUnwrap(document.findString(before, withOptions: []).first)
                let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
                let rect = selection.bounds(for: page)
                XCTAssertNotNil(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: rect.midX, y: rect.midY)))
                let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                    text: (target.text as NSString).replacingCharacters(in: XCTUnwrap(target.initialSelectedRange), with: after),
                    style: target.style, bounds: target.bounds)
                let next = PDFDocument()
                next.insert(result, at: 0)
                let revised = try XCTUnwrap(next.findString(after, withOptions: []).first)
                XCTAssertEqual(revised.bounds(for: result).minX, rect.minX, accuracy: 0.1)
                XCTAssertEqual(revised.bounds(for: result).minY, rect.minY, accuracy: 0.1)
                XCTAssertTrue(next.findString(before, withOptions: []).isEmpty)
                XCTAssertTrue((next.string ?? "").contains("Unaffected caption"))
                XCTAssertTrue((page.string ?? "").contains(before), "The service must not mutate its source page.")
                document = next
            }
            XCTAssertTrue(originalText.contains("First changed line"))
            XCTAssertTrue((document.string ?? "").contains("First revised line"))
            XCTAssertTrue((document.string ?? "").contains("Second revised line"))
            XCTAssertTrue((document.string ?? "").contains("Third revised line"))
        }
    }

    func testGeneratedLinesRemainEditableAsOneSelection() throws {
        for background in [PDFTextColor.clear] {
            let document = try generatedLines(background: background)
            let page = try XCTUnwrap(document.page(at: 0))
            let selection = try regionSelection(["First changed line", "Second changed line"], in: document)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
            let range = try XCTUnwrap(target.initialSelectedRange)
            XCTAssertEqual((target.text as NSString).substring(with: range), "First changed line\nSecond changed line")
            let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: (target.text as NSString).replacingCharacters(in: range, with: "First grouped edit\nSecond grouped edit"),
                style: target.style, bounds: target.bounds)
            let next = PDFDocument()
            next.insert(result, at: 0)
            XCTAssertEqual(next.findString("Third changed line", withOptions: []).count, 1)
            let first = try XCTUnwrap(next.findString("First grouped edit", withOptions: []).first)
            XCTAssertNotNil(try PDFBodyTextEditor.target(on: result, selection: first))
            let combined = try regionSelection(["First grouped edit", "Second grouped edit"], in: next)
            XCTAssertNotNil(try PDFBodyTextEditor.target(on: result, selection: combined))
        }
    }

    func testGeneratedParagraphSharesEmbeddedFontBetweenLines() throws {
        let one = try generatedLines(text: "First changed line")
        let many = try generatedLines(text: (0..<12).map { "Changed line \($0)" }.joined(separator: "\n"))
        // One paragraph Form shares its embedded font between all lines.
        // This generous bound catches one complete font copy per output line.
        let oneSize = try XCTUnwrap(one.dataRepresentation()).count
        let manySize = try XCTUnwrap(many.dataRepresentation()).count
        XCTAssertLessThan(manySize, oneSize * 4)
    }

    func testGroupingDoesNotMoveTextAcrossAnotherFormsBackground() throws {
        let source = try formFixture()
        let selection = try regionSelection(["First line", "Second line"], in: source)
        XCTAssertNil(try PDFBodyTextEditor.target(on: XCTUnwrap(source.page(at: 0)), selection: selection))
        XCTAssertTrue((source.string ?? "").contains("First line"))
        XCTAssertTrue((source.string ?? "").contains("Second line"))
    }

    func testOpaqueParagraphBackgroundIsRefusedWithoutMutatingThePage() throws {
        let document = try generatedLines(background: PDFTextColor(red: 1, green: 1, blue: 0, alpha: 1))
        let page = try XCTUnwrap(document.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let selection = try XCTUnwrap(document.findString("Second changed line", withOptions: []).first)
        XCTAssertNil(try PDFBodyTextEditor.target(on: page, selection: selection))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testNestedAncestorWithOtherPaintIsRefusedWithoutMutatingThePage() throws {
        let document = try nestedFixture(hasSibling: true)
        let page = try XCTUnwrap(document.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let selection = try XCTUnwrap(document.findString("Nested line", withOptions: []).first)
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, selection: selection))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testNestedSingleChildChainCanBeEditedRepeatedly() throws {
        let document = try nestedFixture(hasSibling: false)
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("Nested line", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Revised line", style: target.style, bounds: target.bounds)
        let next = PDFDocument()
        next.insert(result, at: 0)
        let revised = try XCTUnwrap(next.findString("Revised line", withOptions: []).first)
        XCTAssertNotNil(try PDFBodyTextEditor.target(on: result, selection: revised))
        XCTAssertTrue(next.findString("Nested line", withOptions: []).isEmpty)
    }

    func testMarkedDonorAlsoInvokedThroughInheritedNestedResourcesIsNotDropped() throws {
        let text = "BT /F1 20 Tf 1 0 0 1 40 400 Tm (Shared donor line) Tj ET"
        let nested = "q 1 0 0 1 0 -100 cm /Donor Do Q"
        let content = "/Donor Do /Nested Do"
        let source = try document(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /XObject << /Donor 5 0 R /Nested 6 0 R >> >> /Contents 7 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /XObject /Subtype /Form /EmberPDFBodyText true /BBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> >> /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream",
            // No Resources: this invocation inherits the page's donor entry.
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 500] /Length \(nested.utf8.count) >>\nstream\n\(nested)\nendstream",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ])
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        XCTAssertEqual(source.findString("Shared donor line", withOptions: []).count, 2)
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 45, y: 405)))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
        XCTAssertEqual(source.findString("Shared donor line", withOptions: []).count, 2)
    }

    private func generatedLines(text: String = "First changed line\nSecond changed line\nThird changed line",
                                background: PDFTextColor = .clear) throws -> PDFDocument {
        let bytes = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        for (text, y) in [("Original line", CGFloat(540)), ("Unaffected caption", CGFloat(60))] {
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.font: NSFont(name: "Helvetica", size: 20)!])), context)
        }
        context.endPDFPage()
        context.closePDF()
        let original = try XCTUnwrap(PDFDocument(data: bytes as Data))
        let page = try XCTUnwrap(original.page(at: 0))
        let selection = try XCTUnwrap(original.findString("Original line", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        var style = target.style
        style.backgroundColor = background
        let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: text, style: style, bounds: target.bounds)
        let document = PDFDocument()
        document.insert(result, at: 0)
        return document
    }

    private func regionSelection(_ terms: [String], in document: PDFDocument) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: 0))
        let fragments = try terms.map { term in
            let selection = try XCTUnwrap(document.findString(term, withOptions: []).first)
            return PDFRegionTextFragment(text: term, bounds: selection.bounds(for: page))
        }
        return PDFRegionTextSelection(document: document, page: page, fragments: fragments)
    }

    private func formFixture() throws -> PDFDocument {
        let first = "BT /F1 20 Tf 1 0 0 1 40 400 Tm (First line) Tj ET"
        let second = "q 1 1 1 rg 30 350 200 40 re f Q BT /F1 20 Tf 1 0 0 1 40 376 Tm (Second line) Tj ET"
        let page = "/A Do /B Do"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /XObject << /A 5 0 R /B 6 0 R >> >> /Contents 7 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> >> /Length \(first.utf8.count) >>\nstream\n\(first)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> >> /Length \(second.utf8.count) >>\nstream\n\(second)\nendstream",
            "<< /Length \(page.utf8.count) >>\nstream\n\(page)\nendstream"
        ]
        return try document(objects: objects)
    }

    private func nestedFixture(hasSibling: Bool) throws -> PDFDocument {
        let inner = "BT /F1 20 Tf 1 0 0 1 40 400 Tm (Nested line) Tj ET"
        let outer = (hasSibling ? "q 1 0 0 rg 20 20 30 30 re f Q " : "") + "/Inner Do"
        let page = "/Outer Do"
        return try document(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /XObject << /Outer 5 0 R >> >> /Contents 7 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 500] /Resources << /XObject << /Inner 6 0 R >> >> /Length \(outer.utf8.count) >>\nstream\n\(outer)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> >> /Length \(inner.utf8.count) >>\nstream\n\(inner)\nendstream",
            "<< /Length \(page.utf8.count) >>\nstream\n\(page)\nendstream"
        ])
    }

    private func document(objects: [String]) throws -> PDFDocument {
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
}
