// SPDX-License-Identifier: MPL-2.0

import AppKit
import CPDFium
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFOutlinedOCRArtworkTests: XCTestCase {
    func testFullMediaFillReportsSeparateConservativeGlyphClips() throws {
        try nativePage(content: clippedPaint) { page in
            let object = try XCTUnwrap(FPDFPage_GetObject(page, 0))
            let bounds = try XCTUnwrap(PDFOutlinedOCRArtwork.paintBounds(of: object, mediaBox: media))
            XCTAssertEqual(bounds.count, 2)
            XCTAssertTrue(bounds.contains { $0.contains(CGRect(x: 20, y: 50, width: 5, height: 10)) })
            XCTAssertTrue(bounds.contains { $0.contains(CGRect(x: 35, y: 50, width: 5, height: 10)) })
            XCTAssertFalse(bounds.contains { $0.contains(CGPoint(x: 30, y: 55)) },
                "Separate clip contours must not claim the blank gap as protected ink.")
        }
    }

    func testUnclippedFullPageAndClippedSmallPaintRemainUnsupported() throws {
        for content in ["0 0 200 200 re f", clippedPaint.replacingOccurrences(of: "0 0 200 200 re f", with: "20 50 20 10 re f")] {
            try nativePage(content: content) { page in
                XCTAssertNil(PDFOutlinedOCRArtwork.paintBounds(of: try XCTUnwrap(FPDFPage_GetObject(page, 0)), mediaBox: media))
            }
        }
    }

    func testOwnedFormRequiresInvisibleSemanticsAndCoveredOpaquePaint() throws {
        try nativePage(content: clippedPaint + " BT /F1 12 Tf 3 Tr 1 0 0 1 20 50 Tm (AB) Tj ET", form: true) { page in
            let object = try XCTUnwrap(FPDFPage_GetObject(page, 0))
            let inspection = try XCTUnwrap(PDFOutlinedOCRArtwork.inspect(object, metadata: try metadata(), mediaBox: media))
            XCTAssertEqual(inspection.bounds.count, 2)
            XCTAssertEqual(inspection.textObjects.count, 1)
            XCTAssertNil(PDFOutlinedOCRArtwork.inspect(object,
                metadata: try metadata(erasures: [CGRect(x: 19, y: 49, width: 8, height: 12)]), mediaBox: media))
        }
        for content in [clippedPaint + " BT /F1 12 Tf 0 Tr 20 50 Td (AB) Tj ET",
                        clippedPaint.replacingOccurrences(of: "0 g", with: "1 0 0 rg") + " BT /F1 12 Tf 3 Tr 20 50 Td (AB) Tj ET"] {
            try nativePage(content: content, form: true) { page in
                XCTAssertNil(PDFOutlinedOCRArtwork.inspect(try XCTUnwrap(FPDFPage_GetObject(page, 0)), metadata: try metadata(), mediaBox: media))
            }
        }
    }

    private let media = CGRect(x: 0, y: 0, width: 200, height: 200)
    private var clippedPaint: String { "q 20 50 5 10 re 35 50 5 10 re W n 0 g 0 0 200 200 re f Q" }

    private func metadata(erasures: [CGRect]? = nil) throws -> PDFOutlinedOCRMetadata {
        let style = InlineTextStyle(fontName: "Helvetica", fontSize: 12, textColor: .black,
            backgroundColor: .clear, alignment: .left)
        return try PDFOutlinedOCRMetadata(text: "AB", style: style,
            bounds: CGRect(x: 20, y: 48, width: 20, height: 15), baseline: CGPoint(x: 20, y: 50),
            lineHeight: nil, firstLineIndent: 0, sourceRuns: [],
            erasedRects: erasures ?? [CGRect(x: 19, y: 49, width: 22, height: 12)], paperColor: .white,
            semanticFontName: "F1", semanticEncoding: .ascii, semanticDefaultWidth: 500,
            semanticLineMatrices: [.init(a: 1, b: 0, c: 0, d: 1, tx: 20, ty: 50)],
            semanticLineFontSizes: [12], semanticLineWidths: [12])
    }

    private func nativePage(content: String, form: Bool = false, body: (FPDF_PAGE) throws -> Void) throws {
        FPDF_InitLibrary()
        let formObject = "<< /Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources << /Font << /F1 4 0 R >> >> /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        let pageContent = form ? "q /Owned Do Q" : content
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 4 0 R >> /XObject << /Owned 6 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(pageContent.utf8.count) >>\nstream\n\(pageContent)\nendstream",
            formObject
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
        try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0))
            defer { FPDF_ClosePage(page) }
            try body(page)
        }
    }
}
