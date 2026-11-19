// SPDX-License-Identifier: MPL-2.0

import AppKit
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextLineSpacingTests: XCTestCase {
    func testFixedBaselineSpacingExcludesFontLeadingWhenAllRowsChange() throws {
        for spacing: CGFloat in [24, 33] {
            let source = try fixture(spacing: spacing)
            let page = try XCTUnwrap(source.page(at: 0))
            let target = try target(on: page)
            XCTAssertGreaterThan(target.style.font.leading, 0,
                                 "Arial exposes the extra leading that CoreText adds beyond fixed line height.")
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: "NewOne\nNewTwo\nNewLast", style: target.style, bounds: target.bounds)
            for (index, phrase) in ["NewOne", "NewTwo", "NewLast"].enumerated() {
                XCTAssertEqual(try baseline(of: phrase, on: edited), 260 - CGFloat(index) * spacing, accuracy: 0.05)
            }
        }
    }

    func testFallbackGlyphsKeepNativeRowBaselinesAndUntouchedOperators() throws {
        for spacing: CGFloat in [24, 33] {
            let source = try fixture(spacing: spacing)
            let page = try XCTUnwrap(source.page(at: 0))
            let target = try target(on: page)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: target.text.replacingOccurrences(of: "ChangeMe", with: "새 글자"),
                style: target.style, bounds: target.bounds)
            for (index, phrase) in ["KeepFirst", "새 글자", "KeepLast"].enumerated() {
                XCTAssertEqual(try baseline(of: phrase, on: edited), 260 - CGFloat(index) * spacing, accuracy: 0.05)
            }
            let content = String(decoding: try PDFBodyTextPageSnapshot.contentData(for: edited), as: UTF8.self)
            XCTAssertTrue(content.contains("[(Keep) -43 (First)] TJ"),
                          "Changing a fallback glyph must not force an unrelated row's positioned text to be regenerated.")
            XCTAssertTrue(content.contains("[(Keep) 27 (Last)] TJ"))
        }
    }

    private func fixture(spacing: CGFloat) throws -> PDFDocument {
        let font = try XCTUnwrap(NSFont(name: "ArialMT", size: 1000)) as CTFont
        let widths = (32...126).map { value -> String in
            var character = UniChar(value), glyph = CGGlyph(), advance = CGSize()
            _ = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            return String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), advance.width)
        }.joined(separator: " ")
        let content = "BT /F1 16 Tf 1 0 0 1 40 260 Tm [(Keep) -43 (First)] TJ ET\n"
            + "BT /F1 16 Tf 1 0 0 1 40 \(260 - spacing) Tm (ChangeMe) Tj ET\n"
            + "BT /F1 16 Tf 1 0 0 1 40 \(260 - 2 * spacing) Tm [(Keep) 27 (Last)] TJ ET\n"
        let data = PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /TrueType /BaseFont /ArialMT /FirstChar 32 /LastChar 126 /Widths [\(widths)] /Encoding /WinAnsiEncoding /FontDescriptor 6 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [-1000 -1000 2000 2000] /ItalicAngle 0 /Ascent \(CTFontGetAscent(font)) /Descent \(-CTFontGetDescent(font)) /CapHeight \(CTFontGetCapHeight(font)) /StemV 80 >>"
        ])
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func target(on page: PDFPage) throws -> PDFBodyTextTarget {
        let text = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: text.utf16.count)))
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
    }

    private func baseline(of phrase: String, on source: PDFPage) throws -> CGFloat {
        // target() initialized PDFium. Read actual native text origins rather
        // than font-dependent PDFKit selection rectangles.
        let data = try PDFBodyTextPageSnapshot.data(for: source)
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0))
            defer { FPDF_ClosePage(page) }
            let textPage = try XCTUnwrap(FPDFText_LoadPage(page))
            defer { FPDFText_ClosePage(textPage) }
            var text = ""
            var indices: [Int32] = []
            for index in 0..<FPDFText_CountChars(textPage) {
                guard let scalar = UnicodeScalar(FPDFText_GetUnicode(textPage, index)) else { continue }
                let character = String(scalar)
                text += character
                indices.append(contentsOf: repeatElement(index, count: character.utf16.count))
            }
            let range = (text as NSString).range(of: phrase)
            XCTAssertNotEqual(range.location, NSNotFound)
            guard range.location != NSNotFound else { throw NSError(domain: "BodyTextLineSpacingTests", code: 1) }
            var x = 0.0, y = 0.0
            XCTAssertNotEqual(FPDFText_GetCharOrigin(textPage, indices[range.location], &x, &y), 0)
            return CGFloat(y)
        }
    }
}
