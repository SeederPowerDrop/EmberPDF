// SPDX-License-Identifier: MPL-2.0

import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFContentStreamBoundaryTests: XCTestCase {
    private let before = "BT /F1 16 Tf 20 150 Td (Before comment) Tj ET % unfinished"
    private let after = "BT /F1 16 Tf 20 110 Td (HIDDEN) Tj ET\n"
        + "BT /F1 16 Tf 20 70 Td (Visible after newline) Tj ET"

    func testCrossStreamCommentMatchesTheSingleStreamSpaceControl() throws {
        let source = try fixture([before, after])
        let page = try XCTUnwrap(source.page(at: 0))
        let joined = try PDFBodyTextPageSnapshot.contentData(for: page)
        XCTAssertEqual(joined, Data((before + " " + after).utf8))
        XCTAssertEqual(try strings(in: joined), ["Before comment", "Visible after newline"])
        let flattened = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.data(for: page,
            contentOverride: joined)))
        let control = try fixture([before + " " + after])
        // PDFKit parses the original content array differently from Poppler.
        // Compare against an unambiguous single-stream control, not its array
        // extraction, which can already contain the commented-out first line.
        XCTAssertEqual(flattened.string, control.string)
        XCTAssertFalse((flattened.string ?? "").contains("HIDDEN"))
        XCTAssertEqual(render(try XCTUnwrap(flattened.page(at: 0))),
                       render(try XCTUnwrap(control.page(at: 0))))
    }

    func testEditingVisibleTextDoesNotRevealTheCommentedFirstLine() throws {
        let source = try fixture([before, after])
        let page = try XCTUnwrap(source.page(at: 0))
        let joined = try PDFBodyTextPageSnapshot.contentData(for: page)
        let parsed = try PDFScannedContentStream.parse(joined)
        XCTAssertEqual(parsed.shows.count, 2)
        var edited = joined
        edited.replaceSubrange(try XCTUnwrap(parsed.shows.last).range,
                               with: Data("(Edited after newline) Tj".utf8))
        let saved = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: edited,
            preservePageContent: true)
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        let reopenedContent = try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(reopened.page(at: 0)))
        XCTAssertEqual(try strings(in: reopenedContent), ["Before comment", "Edited after newline"])
        XCTAssertTrue(String(decoding: reopenedContent, as: UTF8.self).contains("(HIDDEN) Tj"),
                      "Commented source bytes must remain present and inactive.")
        XCTAssertFalse((reopened.string ?? "").contains("HIDDEN"))
    }

    func testOriginalCRAndLFTerminateCommentsAndEmptyStreamsKeepTheirBoundaries() throws {
        for ending in ["", "\r", "\n", "\r\n"] {
            let pieces = ["", before + ending, "", after, ""]
            let document = try fixture(pieces)
            let joined = try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(document.page(at: 0)))
            XCTAssertEqual(joined, Data(pieces.joined(separator: " ").utf8))
            XCTAssertEqual(try strings(in: joined), ending.isEmpty
                ? ["Before comment", "Visible after newline"]
                : ["Before comment", "HIDDEN", "Visible after newline"])
        }
        let pieces = [before, "", "\r", after]
        let document = try fixture(pieces)
        XCTAssertEqual(try strings(in: PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(document.page(at: 0)))),
                       ["Before comment", "HIDDEN", "Visible after newline"])
    }

    func testSpaceSeparatesAdjacentOperatorsWithoutChangingSourceBytes() throws {
        let pieces = ["q", "1 0 0 1 0 0 cm", "Q",
            "BT /F1 16 Tf 20 150 Td (First) Tj ET", "BT /F1 16 Tf 20 70 Td (Second) Tj ET"]
        let document = try fixture(pieces)
        let joined = try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(document.page(at: 0)))
        XCTAssertEqual(joined, Data(pieces.joined(separator: " ").utf8))
        XCTAssertEqual(try strings(in: joined), ["First", "Second"])
    }

    func testDonorTrailingCommentCannotSwallowTheOwnedClosingQ() throws {
        let source = try fixture(["BT /F1 16 Tf 20 150 Td (Original) Tj ET"])
        let page = try XCTUnwrap(source.page(at: 0))
        let donor = try fixture(["BT /F1 16 Tf 20 70 Td (Donor) Tj ET % trailing comment"])
        let name = try PDFBodyTextPageSnapshot.unusedXObjectName(for: page)
        let donorData = try PDFBodyTextPageSnapshot.originalPageData(for: XCTUnwrap(donor.page(at: 0)))
        let data = try PDFBodyTextPageSnapshot.data(for: page,
            contentOverride: Data("q /\(name) Do Q".utf8), donorPDF: donorData, donorName: name)
        let result = try XCTUnwrap(PDFDocument(data: data))
        let dictionary = try XCTUnwrap(result.page(at: 0)?.pageRef?.dictionary)
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &objects))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(objects), name, &stream))
        var format = CGPDFDataFormat.raw
        let content = try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format) as Data?)
        XCTAssertEqual(format, .raw)
        XCTAssertTrue(String(decoding: content, as: UTF8.self).hasSuffix("% trailing comment\nQ"))
        XCTAssertNoThrow(try PDFScannedContentStream.parse(content),
                         "The generated wrapper q must still have an active closing Q.")
        XCTAssertTrue((result.string ?? "").contains("Donor"))
    }

    private func strings(in data: Data) throws -> [String] {
        try PDFScannedContentStream.parse(data).shows.map {
            String(decoding: $0.stringBytes ?? [], as: UTF8.self)
        }
    }

    private func fixture(_ streams: [String]) throws -> PDFDocument {
        let references = streams.indices.map { "\($0 + 5) 0 R" }.joined(separator: " ")
        var objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] "
                + "/Resources << /Font << /F1 4 0 R >> >> /Contents [\(references)] >>").utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)
        ]
        for stream in streams {
            var object = Data("<< /Length \(stream.utf8.count) >>\nstream\n".utf8)
            object.append(Data(stream.utf8))
            object.append(Data("\nendstream".utf8))
            objects.append(object)
        }
        var result = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n".utf8)); result.append(object)
            result.append(Data("\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data(("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
            + "startxref\n\(xref)\n%%EOF\n").utf8))
        return try XCTUnwrap(PDFDocument(data: result))
    }

    private func render(_ page: PDFPage) -> Data {
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 1200,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        context.drawPDFPage(page.pageRef!)
        return Data(bytes: context.data!, count: 240_000)
    }
}
