// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFNativeSelectionProxyTests: XCTestCase {
    @MainActor
    func testUnclosedFormSavesRecoverExactTextAndGeometryWithoutChangingSource() throws {
        for rotation in [0, 90, 180, 270] {
            let document = try XCTUnwrap(PDFDocument(data: formFixtureData(content: "q", rotation: rotation)))
            let source = try XCTUnwrap(document.page(at: 0))
            let originalText = source.string
            let originalBounds = source.characterBounds(at: 0)
            let proxy = try XCTUnwrap(PDFNativeSelectionProxy.makePage(for: source))
            let referenceDocument = try XCTUnwrap(PDFDocument(data: formFixtureData(content: "q Q", rotation: rotation)))
            let reference = try XCTUnwrap(referenceDocument.page(at: 0))

            XCTAssertEqual(proxy.page.string, reference.string)
            XCTAssertTrue(proxy.page.string?.contains("Recovered bottom line.") ?? false)
            XCTAssertFalse(PDFTextSelectionGeometry.needsRegionSelection(on: proxy.page))
            let start = CGPoint(x: 90, y: 404)
            let end = CGPoint(x: 185, y: 374)
            let expected = try XCTUnwrap(reference.selection(from: start, to: end))
            for (anchor, extent) in [(start, end), (end, start)] {
                let selection = try XCTUnwrap(proxy.page.selection(from: anchor, to: extent))
                XCTAssertEqual(selection.string, expected.string)
                assertEqual(selection.bounds(for: proxy.page), expected.bounds(for: reference))
            }
            XCTAssertEqual(source.string, originalText)
            XCTAssertEqual(source.characterBounds(at: 0), originalBounds)
            XCTAssertEqual(document.pageCount, 1)
            XCTAssertTrue(document.page(at: 0) === source)
        }
    }

    @MainActor
    func testFormRepairTerminatesTrailingCommentsAndDoesNotCountQuotedOperators() throws {
        let data = formFixtureData(content: "q BT /F1 8 Tf (q q Q) Tj ET % q q")
        let document = try XCTUnwrap(PDFDocument(data: data))
        let source = try XCTUnwrap(document.page(at: 0))
        let proxy = try XCTUnwrap(PDFNativeSelectionProxy.makePage(for: source))

        XCTAssertFalse(PDFFormGraphicsStateInspector.hasUnbalancedForm(on: proxy.page))
        XCTAssertTrue(proxy.page.string?.contains("Alpha bravo charlie.") ?? false)
    }

    @MainActor
    func testUnmatchedFormRestoreRetainsOCRFallbackInsteadOfInventingGraphicsState() throws {
        let document = try XCTUnwrap(PDFDocument(data: formFixtureData(content: "Q")))
        let source = try XCTUnwrap(document.page(at: 0))

        XCTAssertTrue(PDFTextSelectionGeometry.needsRegionSelection(on: source))
        XCTAssertNil(PDFNativeSelectionProxy.makePage(for: source))
    }

    @MainActor
    func testOptionalReportedTextbookFormRepairPreservesExactWordsInBothColumns() throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_SELECTION_PDF_FIXTURE"] else {
            throw XCTSkip("Set EMBER_SELECTION_PDF_FIXTURE to run the local textbook regression.")
        }
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        let source = try XCTUnwrap(document.page(at: 11))
        let originalText = source.string
        let originalBounds = source.characterBounds(at: 0)
        let proxy = try XCTUnwrap(PDFNativeSelectionProxy.makePage(for: source))
        let right = try XCTUnwrap(proxy.page.selection(
            from: CGPoint(x: 295, y: 658), to: CGPoint(x: 387, y: 600)
        ))
        let left = try XCTUnwrap(proxy.page.selection(
            from: CGPoint(x: 72, y: 627), to: CGPoint(x: 178, y: 426)
        ))

        for phrase in ["Real Gases: The Van der Waals Equation", "Equations of State 597",
                       "20-7 Phase Changes 599", "20-8 Evaporation 601"] {
            XCTAssertTrue(right.string?.contains(phrase) ?? false, phrase)
        }
        XCTAssertFalse(right.string?.contains("Doppler") ?? true)
        XCTAssertTrue(left.string?.contains("17-9 The Doppler Shift 507") ?? false)
        XCTAssertTrue(left.string?.contains("18-4 Standing Waves 531") ?? false)
        XCTAssertFalse(left.string?.contains("Real Gases") ?? true)
        for line in right.selectionsByLine() {
            XCTAssertGreaterThan(line.bounds(for: proxy.page).minX, 290)
        }
        for line in left.selectionsByLine() {
            XCTAssertLessThan(line.bounds(for: proxy.page).maxX, 290)
        }
        XCTAssertFalse(PDFTextSelectionGeometry.needsRegionSelection(on: proxy.page))
        XCTAssertEqual(source.string, originalText)
        XCTAssertEqual(source.characterBounds(at: 0), originalBounds)
    }

    @MainActor
    func testMalformedMetricsRecoverTextAndGeometryWithoutChangingSourceAtEveryRotation() throws {
        for rotation in [0, 90, 180, 270] {
            let document = try makeDocument(ascent: 67_306_242, rotation: rotation)
            let source = try XCTUnwrap(document.page(at: 0))
            let originalText = source.string
            let originalBounds = source.characterBounds(at: 0)
            let proxy = try XCTUnwrap(PDFNativeSelectionProxy.makePage(for: source))
            let reference = try makeDocument(rotation: rotation)
            let referencePage = try XCTUnwrap(reference.page(at: 0))

            XCTAssertEqual(proxy.page.string, referencePage.string)
            XCTAssertEqual(normalizeWhitespace(proxy.page.string), normalizeWhitespace(originalText))
            XCTAssertEqual(proxy.page.numberOfCharacters, referencePage.numberOfCharacters)
            XCTAssertEqual(proxy.page.rotation, rotation)
            XCTAssertEqual(proxy.page.bounds(for: .cropBox), source.bounds(for: .cropBox))
            XCTAssertEqual(proxy.page.bounds(for: .mediaBox), source.bounds(for: .mediaBox))
            XCTAssertTrue(proxy.page.document === proxy.document)
            XCTAssertFalse(proxy.page === source)
            XCTAssertFalse(PDFTextSelectionGeometry.needsRegionSelection(on: proxy.page))

            for index in 0..<proxy.page.numberOfCharacters {
                let bounds = proxy.page.characterBounds(at: index)
                XCTAssertTrue(bounds.width.isFinite && bounds.height.isFinite)
                XCTAssertLessThan(max(bounds.width, bounds.height), 40)
            }
            XCTAssertEqual(source.string, originalText)
            XCTAssertEqual(source.characterBounds(at: 0), originalBounds)
            XCTAssertGreaterThan(originalBounds.height, 1_000_000)
            XCTAssertEqual(document.pageCount, 1)
            XCTAssertTrue(document.page(at: 0) === source)
        }
    }

    @MainActor
    func testForwardAndReverseDragFollowTextAcrossPartialLinesAtEveryRotation() throws {
        for rotation in [0, 90, 180, 270] {
            let sourceDocument = try makeDocument(ascent: 67_306_242, rotation: rotation)
            let source = try XCTUnwrap(sourceDocument.page(at: 0))
            let proxy = try XCTUnwrap(PDFNativeSelectionProxy.makePage(for: source))
            let referenceDocument = try makeDocument(rotation: rotation)
            let reference = try XCTUnwrap(referenceDocument.page(at: 0))
            let anchor = try point(in: reference, word: "bravo", edge: .leading)
            let endpoint = try point(in: reference, word: "golf", edge: .trailing)
            let expected = try XCTUnwrap(reference.selection(from: anchor, to: endpoint))
            let forward = try XCTUnwrap(proxy.page.selection(from: anchor, to: endpoint))
            let reverse = try XCTUnwrap(proxy.page.selection(from: endpoint, to: anchor))

            XCTAssertEqual(forward.string, expected.string)
            XCTAssertEqual(reverse.string, expected.string)
            XCTAssertEqual(forward.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           "bravo charlie delta.\nEcho foxtrot golf")
            XCTAssertFalse(forward.string?.contains("Alpha") ?? true)
            XCTAssertFalse(forward.string?.contains("hotel") ?? true)
            XCTAssertFalse(forward.string?.contains("India") ?? true)

            let lines = forward.selectionsByLine()
            XCTAssertEqual(lines.count, 2)
            let first = try XCTUnwrap(lines.first)
            let second = try XCTUnwrap(lines.last)
            XCTAssertGreaterThan(first.bounds(for: proxy.page).minX, second.bounds(for: proxy.page).minX)
            XCTAssertGreaterThan(first.bounds(for: proxy.page).maxX, second.bounds(for: proxy.page).maxX)
            for (line, normalLine) in zip(lines, expected.selectionsByLine()) {
                assertEqual(line.bounds(for: proxy.page), normalLine.bounds(for: reference))
                XCTAssertLessThan(line.bounds(for: proxy.page).height, 30)
            }
        }
    }

    @MainActor
    func testNativeWordAndLineSelectionUseRepairedCharacterHitTesting() throws {
        let sourceDocument = try makeDocument(ascent: 67_306_242, rotation: 270)
        let source = try XCTUnwrap(sourceDocument.page(at: 0))
        let proxy = try XCTUnwrap(PDFNativeSelectionProxy.makePage(for: source))
        let text = try XCTUnwrap(proxy.page.string) as NSString
        let index = text.range(of: "foxtrot").location
        let bounds = proxy.page.characterBounds(at: index)
        let location = CGPoint(x: bounds.midX, y: bounds.midY)

        XCTAssertEqual(proxy.page.characterIndex(at: location), index)
        XCTAssertEqual(proxy.page.selectionForWord(at: location)?.string, "foxtrot")
        XCTAssertEqual(proxy.page.selectionForLine(at: location)?.string, "Echo foxtrot golf hotel.")
        XCTAssertEqual(proxy.page.characterIndex(at: CGPoint(x: 31, y: 70)), NSNotFound)
    }

    @MainActor
    func testProxyHonorsRotationAndCropEditedInMemory() throws {
        let document = try makeDocument(ascent: 67_306_242)
        let source = try XCTUnwrap(document.page(at: 0))
        source.rotation = 270
        let crop = CGRect(x: 35, y: 310, width: 260, height: 120)
        source.setBounds(crop, for: .cropBox)

        let proxy = try XCTUnwrap(PDFNativeSelectionProxy.makePage(for: source))

        XCTAssertEqual(proxy.page.rotation, 270)
        XCTAssertEqual(proxy.page.bounds(for: .cropBox), crop)
        XCTAssertEqual(source.rotation, 270)
        XCTAssertEqual(source.bounds(for: .cropBox), crop)
    }

    private enum Edge { case leading, trailing }

    private func point(in page: PDFPage, word: String, edge: Edge) throws -> CGPoint {
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: word)
        XCTAssertNotEqual(range.location, NSNotFound)
        let index = edge == .leading ? range.location : NSMaxRange(range) - 1
        let bounds = page.characterBounds(at: index)
        return CGPoint(x: edge == .leading ? bounds.minX + 0.1 : bounds.maxX - 0.1, y: bounds.midY)
    }

    private func normalizeWhitespace(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func makeDocument(ascent: Int = 800, rotation: Int = 0) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: PDFMalformedSelectionTestFixture.data(ascent: ascent, rotation: rotation)))
    }

    private func formFixtureData(content formContent: String, rotation: Int = 0) -> Data {
        let content = "q 1 0 0 1 -33 -33 cm /Fm0 Do Q q 1 0 0 1 -33 -33 cm /Fm0 Do Q "
            + "BT /F1 12 Tf 90 400 Td (Alpha bravo charlie.) Tj 0 -30 Td (Delta echo foxtrot.) Tj ET "
            + "BT /F1 12 Tf 90 90 Td (Recovered bottom line.) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /CropBox [30 60 330 440] /Rotate \(rotation) /Resources << /Font << /F1 4 0 R >> /XObject << /Fm0 6 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 500] /Length \(formContent.utf8.count) >>\nstream\n\(formContent)\nendstream"
        ]
        return PDFMalformedSelectionTestFixture.pdfData(objects: objects)
    }

    private func assertEqual(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }
}

// Shared malformed-font fixture exercises the builder and real pointer path.
enum PDFMalformedSelectionTestFixture {
    static func data(ascent: Int = 800, rotation: Int = 0) -> Data {
        let content = "BT /F1 18 Tf 40 400 Td (Alpha bravo charlie delta.) Tj 0 -30 Td (Echo foxtrot golf hotel.) Tj 0 -30 Td (India juliet kilo lima.) Tj ET"
        let widths = Array(repeating: "500", count: 95).joined(separator: " ")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /CropBox [30 60 330 440] /Rotate \(rotation) /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /SelectionFixtureFont /FirstChar 32 /LastChar 126 /Widths [\(widths)] /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>",
            "<< /Type /FontDescriptor /FontName /SelectionFixtureFont /Flags 32 /FontBBox [0 -200 1000 800] /ItalicAngle 0 /Ascent \(ascent) /Descent -200 /CapHeight 700 /StemV 80 >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
        return pdfData(objects: objects)
    }

    static func pdfData(objects: [String]) -> Data {
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let crossReferenceOffset = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(crossReferenceOffset)\n%%EOF\n".utf8))
        return data
    }

}
