// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

/// Separate compatibility proposal. Not part of the sealed isolated35 package.
@MainActor
final class PDFBodyTextExtentCompatibilityTests: XCTestCase {
    func testFontSizeIncreaseFrom18To24UsesVerifiedBlankVerticalClearance() throws {
        let source = try fixture(font: "Helvetica", text: "iii")
        let page = try XCTUnwrap(source.page(at: 0))
        let selected = try target(on: page, text: "iii")
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let declaredBeforeEdit = selected.paintBounds
        var larger = selected.style
        larger.fontSize = 24
        let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(
            NSAttributedString(string: "iii", attributes: [.font: larger.renderingFont(larger.font)])), .useGlyphPathBounds)
            .offsetBy(dx: selected.baseline.x, dy: selected.baseline.y)
        XCTAssertGreaterThan(ink.maxY, selected.bounds.maxY,
            "The fixture must need blank space above the source's old metrics.")
        XCTAssertTrue(declaredBeforeEdit.contains(ink),
            "Source-derived clearance must be declared before the larger output exists.")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "iii", style: larger, bounds: selected.bounds)
        let actual = try target(on: edited, text: "iii")
        XCTAssertEqual(actual.style.fontSize, 24, accuracy: 0.05)
        XCTAssertEqual(actual.baseline.x, selected.baseline.x, accuracy: 0.05)
        XCTAssertEqual(actual.baseline.y, selected.baseline.y, accuracy: 0.05)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testNewNegativeFirstBearingUsesVerifiedBlankLeftClearanceWithoutMovingOrigin() throws {
        let source = try fixture(font: "Times-Italic", text: "iii")
        let page = try XCTUnwrap(source.page(at: 0))
        let selected = try target(on: page, text: "iii")
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let declaredBeforeEdit = selected.paintBounds
        let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(
            NSAttributedString(string: "jazz", attributes: [.font: selected.style.renderingFont(selected.style.font)])), .useGlyphPathBounds)
            .offsetBy(dx: selected.baseline.x, dy: selected.baseline.y)
        XCTAssertLessThan(ink.minX, selected.bounds.minX,
            "The replacement must exercise a real negative first bearing absent from the source.")
        XCTAssertTrue(declaredBeforeEdit.contains(ink),
            "Blank-left clearance must come from the source, never an output-driven mask.")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "jazz", style: selected.style, bounds: selected.bounds)
        let actual = try target(on: edited, text: "jazz")
        XCTAssertEqual(actual.baseline.x, selected.baseline.x, accuracy: 0.05)
        XCTAssertEqual(actual.baseline.y, selected.baseline.y, accuracy: 0.05)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    private func target(on page: PDFPage, text: String) throws -> PDFBodyTextTarget {
        let range = (try XCTUnwrap(page.string) as NSString).range(of: text)
        guard range.location != NSNotFound else { throw NSError(domain: "BodyCompatibilityPhrase", code: 1) }
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: XCTUnwrap(page.selection(for: range))))
    }

    private func fixture(font: String, text: String) throws -> PDFDocument {
        let content = "BT /F1 18 Tf 1 0 0 1 100 180 Tm (\(text)) Tj ET"
        return try XCTUnwrap(PDFDocument(data: PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /\(font) >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ])))
    }
}
