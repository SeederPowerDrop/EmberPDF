// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFSearchHitGeometryTests: XCTestCase {
    @MainActor
    func testMultilineMatchKeepsOnlyTheMatchedPartsOfEachLine() throws {
        let document = try makeDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let first = try sourceRange(of: "bravo", on: page)
        let second = try sourceRange(of: "Second", on: page)
        let spanning = NSRange(
            location: first.location,
            length: NSMaxRange(second) - first.location
        )
        let result = makeResult(pageIndex: 0, range: spanning)

        let geometry = try XCTUnwrap(PDFSearchHitGeometry.resolve(result, in: document))

        XCTAssertEqual(geometry.id, result.id)
        XCTAssertEqual(geometry.pageIndex, 0)
        XCTAssertEqual(geometry.lineRects.count, 2)
        let actual = geometry.lineRects.sorted { $0.minY > $1.minY }
        let expected = try [first, second].map { range in
            try XCTUnwrap(page.selection(for: range)).bounds(for: page)
        }.sorted { $0.minY > $1.minY }
        for (rect, line) in zip(actual, expected) { assertEqual(rect, line) }
        XCTAssertGreaterThan(actual[0].minY, actual[1].maxY)
        XCTAssertGreaterThan(actual[0].minX, actual[1].minX)
        XCTAssertTrue(actual.allSatisfy { $0.width < 100 && $0.height < 25 })
    }

    @MainActor
    func testSourceRangeSelectsTheCorrectOccurrenceOnTheRequestedPage() throws {
        let document = try makeDocument()
        let secondDocument = try makeDocument()
        document.insert(try XCTUnwrap(secondDocument.page(at: 0)), at: 1)
        let page = try XCTUnwrap(document.page(at: 1))
        let first = try sourceRange(of: "target", on: page)
        let text = try XCTUnwrap(page.string) as NSString
        let second = text.range(
            of: "target",
            range: NSRange(location: NSMaxRange(first), length: text.length - NSMaxRange(first))
        )
        XCTAssertNotEqual(second.location, NSNotFound)
        let result = makeResult(pageIndex: 1, range: second)

        let geometry = try XCTUnwrap(PDFSearchHitGeometry.resolve(result, in: document))

        XCTAssertEqual(geometry.pageIndex, 1)
        XCTAssertEqual(geometry.id, result.id)
        XCTAssertEqual(geometry.lineRects.count, 1)
        assertEqual(
            try XCTUnwrap(geometry.lineRects.first),
            try XCTUnwrap(page.selection(for: second)).bounds(for: page)
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(geometry.lineRects.first).minX,
            try XCTUnwrap(page.selection(for: first)).bounds(for: page).maxX
        )
    }

    @MainActor
    func testInvalidPageIndicesAndUTF16RangesAreRejectedWithoutOverflow() throws {
        let document = try makeDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let count = page.numberOfCharacters
        XCTAssertGreaterThan(count, 0)
        for pageIndex in [-1, 1, Int.max] {
            XCTAssertNil(PDFSearchHitGeometry.resolve(
                makeResult(pageIndex: pageIndex, range: NSRange(location: 0, length: 1)),
                in: document
            ))
        }
        let ranges = [
            NSRange(location: -1, length: 1),
            NSRange(location: 0, length: -1),
            NSRange(location: 0, length: 0),
            NSRange(location: count, length: 1),
            NSRange(location: count - 1, length: 2),
            NSRange(location: 0, length: Int.max),
            NSRange(location: Int.max, length: 1),
            NSRange(location: Int.max - 1, length: Int.max)
        ]
        for range in ranges {
            XCTAssertNil(
                PDFSearchHitGeometry.resolve(makeResult(pageIndex: 0, range: range), in: document),
                "Invalid source range must be rejected before passing it to PDFKit: \(range)"
            )
        }
    }

    @MainActor
    func testRotationDoesNotTransformStoredPageCoordinates() throws {
        let unrotated = try makeDocument()
        let originalPage = try XCTUnwrap(unrotated.page(at: 0))
        let range = try sourceRange(of: "bravo", on: originalPage)
        let expected = try XCTUnwrap(originalPage.selection(for: range)).bounds(for: originalPage)

        for rotation in [0, 90, 180, 270] {
            let document = try makeDocument(rotation: rotation)
            let page = try XCTUnwrap(document.page(at: 0))
            let geometry = try XCTUnwrap(PDFSearchHitGeometry.resolve(
                makeResult(pageIndex: 0, range: range), in: document
            ))

            XCTAssertEqual(page.rotation, rotation)
            XCTAssertEqual(page.bounds(for: .cropBox).origin, CGPoint(x: 30, y: 60))
            XCTAssertEqual(geometry.lineRects.count, 1)
            assertEqual(try XCTUnwrap(geometry.lineRects.first), expected)
            XCTAssertTrue(page.bounds(for: .cropBox).contains(expected))
        }
    }

    @MainActor
    func testLineBoundsAreClippedToTheVisibleCropBox() throws {
        for rotation in [0, 90, 180, 270] {
            let document = try makeDocument(rotation: rotation)
            let page = try XCTUnwrap(document.page(at: 0))
            let range = try sourceRange(of: "Alpha", on: page)
            let nativeBounds = try XCTUnwrap(page.selection(for: range)).bounds(for: page)
            let crop = CGRect(x: nativeBounds.midX, y: 60, width: 200, height: 380)
            page.setBounds(crop, for: .cropBox)

            let geometry = try XCTUnwrap(PDFSearchHitGeometry.resolve(
                makeResult(pageIndex: 0, range: range), in: document
            ))

            XCTAssertEqual(geometry.lineRects.count, 1)
            let clipped = try XCTUnwrap(geometry.lineRects.first)
            assertEqual(clipped, nativeBounds.intersection(crop))
            XCTAssertEqual(clipped.minX, crop.minX, accuracy: 0.001)
            XCTAssertLessThan(clipped.width, nativeBounds.width)
            XCTAssertTrue(crop.contains(clipped))
        }
    }

    @MainActor
    func testGeometryLookupPreservesSourceBytesAnnotationsAndExistingSelection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-search-geometry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.pdf")
        // Preserve the raw synthetic font data: PDFKit's writer may replace
        // an unembedded fixture font and lose its text extraction mapping.
        try fixtureData().write(to: url)
        let beforeBytes = try Data(contentsOf: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 45, y: 280, width: 75, height: 35),
            forType: .square,
            withProperties: nil
        )
        annotation.contents = "Existing reader annotation"
        annotation.color = .red
        page.addAnnotation(annotation)
        let preservedAnnotation = try XCTUnwrap(page.annotations.first)
        let existingSelection = try XCTUnwrap(page.selection(for: sourceRange(of: "Alpha", on: page)))
        let selectionText = existingSelection.string
        let selectionBounds = existingSelection.bounds(for: page)
        let pageText = page.string
        let range = try sourceRange(of: "bravo", on: page)

        for _ in 0..<3 {
            XCTAssertNotNil(PDFSearchHitGeometry.resolve(makeResult(pageIndex: 0, range: range), in: document))
        }

        XCTAssertEqual(try Data(contentsOf: url), beforeBytes)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertTrue(page.annotations.first === preservedAnnotation)
        XCTAssertEqual(preservedAnnotation.contents, "Existing reader annotation")
        assertEqual(preservedAnnotation.bounds, annotation.bounds)
        XCTAssertEqual(page.string, pageText)
        XCTAssertEqual(existingSelection.string, selectionText)
        assertEqual(existingSelection.bounds(for: page), selectionBounds)
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.documentURL, url)
    }

    @MainActor
    func testCorruptFontMetricsCannotBecomeAFullPageSearchHighlight() throws {
        for rotation in [0, 90, 180, 270] {
            let document = try makeDocument(ascent: 67_306_242, rotation: rotation)
            let page = try XCTUnwrap(document.page(at: 0))
            let range = try sourceRange(of: "bravo", on: page)
            let native = try XCTUnwrap(page.selection(for: range)).bounds(for: page)
            XCTAssertGreaterThan(max(native.width, native.height), 1_000_000)

            XCTAssertNil(PDFSearchHitGeometry.resolve(makeResult(pageIndex: 0, range: range), in: document))
        }
    }

    private func sourceRange(of text: String, on page: PDFPage) throws -> NSRange {
        let source = try XCTUnwrap(page.string) as NSString
        let range = source.range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "Fixture must contain \(text)")
        return range
    }

    private func makeResult(pageIndex: Int, range: NSRange) -> PDFSearchResult {
        PDFSearchResult(
            pageIndex: pageIndex,
            pageLabel: String(pageIndex == Int.max ? pageIndex : pageIndex + 1),
            snippet: "A search result",
            snippetMatchRanges: [],
            sourceRange: range,
            matchedText: "Unused presentation text"
        )
    }

    private func makeDocument(ascent: Int = 800, rotation: Int = 0) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: fixtureData(ascent: ascent, rotation: rotation)))
    }

    private func fixtureData(ascent: Int = 800, rotation: Int = 0) -> Data {
        // Fixed-width glyphs and two explicit baselines make partial-line and
        // multiline hit geometry independent of user PDFs or installed fonts.
        let content = "BT /F1 18 Tf 40 400 Td (Alpha bravo) Tj 0 -32 Td (Second target target) Tj ET"
        let widths = Array(repeating: "500", count: 95).joined(separator: " ")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /CropBox [30 60 330 440] /Rotate \(rotation) /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /SearchGeometryFixtureFont /FirstChar 32 /LastChar 126 /Widths [\(widths)] /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>",
            "<< /Type /FontDescriptor /FontName /SearchGeometryFixtureFont /Flags 32 /FontBBox [0 -200 1000 800] /ItalicAngle 0 /Ascent \(ascent) /Descent -200 /CapHeight 700 /StemV 80 >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
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
