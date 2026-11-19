// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextMultiEditStyleTests: XCTestCase {
    private let base = InlineTextStyle(fontName: "Courier", fontSize: 14,
        textColor: PDFTextColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1),
        backgroundColor: .clear, alignment: .left)
    private let accent = InlineTextStyle(fontName: "Helvetica-Bold", fontSize: 11,
        textColor: PDFTextColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1),
        backgroundColor: .clear, alignment: .left, horizontalScale: 0.9)

    func testTwoSeparatedEditsKeepUntouchedInteriorFontColorBaselineAndWidth() throws {
        let source = "alpha MIDDLE omega", draft = "Alpha MIDDLE Omega"
        for scale: CGFloat in [1, 2] {
            let value = layout(source, draft, marker: "MIDDLE", scale: scale)
            try assertAccent(value, marker: "MIDDLE", scale: scale)
            XCTAssertEqual(value.string, draft)
            let font = try XCTUnwrap(value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.fontName, base.fontName)
        }
    }

    func testInsertionsAndDeletionsKeepCompleteEmojiAndCJKSourceRanges() throws {
        let marker = "👨‍👩‍👧‍👦 中國語 かな e\u{301}"
        let source = "alpha \(marker) omega"
        for draft in ["A longer prefix \(marker) end", "a \(marker) z", "\(marker)!"] {
            let value = layout(source, draft, marker: marker)
            try assertAccent(value, marker: marker)
            XCTAssertEqual(value.string.utf16.count, draft.utf16.count)
        }
    }

    func testRepeatedWordsDoNotDiscardAUniqueUnchangedStyledIsland() throws {
        let source = "alpha repeat MIDDLE repeat omega"
        let draft = "Alpha repeat MIDDLE repeat Omega"
        try assertAccent(layout(source, draft, marker: "MIDDLE"), marker: "MIDDLE")
    }

    func testSingleEditKeepsItsExistingLocalInheritance() throws {
        let source = "alpha MIDDLE omega", draft = "alpha CHANGED omega"
        let value = layout(source, draft, marker: "MIDDLE")
        try assertAccent(value, marker: "CHANGED")
    }

    func testAnExplicitStyleChangeStillFormatsTheEntireDraft() throws {
        let source = "alpha MIDDLE omega", draft = "Alpha MIDDLE Omega"
        var style = base
        style.fontSize = 20
        let value = PDFBodyTextAttributedLayout.attributedString(text: draft, style: style,
            sourceText: source, sourceStyle: base, sourceRuns: runs(source, marker: "MIDDLE"))
        let index = (draft as NSString).range(of: "MIDDLE").location
        let font = try XCTUnwrap(value.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.fontName, base.fontName)
        XCTAssertEqual(font.pointSize, 20)
        XCTAssertEqual(value.attribute(.baselineOffset, at: index, effectiveRange: nil) as? CGFloat, 0)
    }

    func testVeryLongOrHeavilyChangedMiddleUsesBoundedSingleEditFallback() throws {
        let cases = [
            ("alpha " + String(repeating: "x", count: 33000) + " MIDDLE omega",
             "Alpha " + String(repeating: "x", count: 33000) + " MIDDLE Omega"),
            (String(repeating: "a", count: 80) + " MIDDLE " + String(repeating: "b", count: 80),
             String(repeating: "c", count: 80) + " MIDDLE " + String(repeating: "d", count: 80))
        ]
        for (source, draft) in cases {
            let value = layout(source, draft, marker: "MIDDLE")
            let index = (draft as NSString).range(of: "MIDDLE").location
            let font = try XCTUnwrap(value.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.fontName, base.fontName)
            XCTAssertEqual(value.string, draft)
        }
    }

    func testMixedFontPDFKeepsInteriorAppearanceAfterApplyingAndReopeningTwoEdits() throws {
        let document = try fixture(), page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("alpha MIDDLE omega", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let oldMiddle = try XCTUnwrap(document.findString("MIDDLE", withOptions: []).first)
        let oldAppearance = try appearance(oldMiddle)
        let revised = target.text.replacingOccurrences(of: "alpha", with: "Alpha")
            .replacingOccurrences(of: "omega", with: "Omega")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: revised, style: target.style, bounds: target.bounds)
        let output = try PDFBodyTextPageSnapshot.originalPageData(for: edited)
        let reopened = try XCTUnwrap(PDFDocument(data: output)), result = try XCTUnwrap(reopened.page(at: 0))
        let newMiddle = try XCTUnwrap(reopened.findString("MIDDLE", withOptions: []).first)
        let newAppearance = try appearance(newMiddle)
        XCTAssertEqual(newAppearance.font, oldAppearance.font)
        XCTAssertEqual(newAppearance.size, oldAppearance.size, accuracy: 0.001)
        XCTAssertTrue(newAppearance.color.visuallyEquals(oldAppearance.color),
            "Original \(oldAppearance.color); saved \(newAppearance.color)")
        XCTAssertEqual(newMiddle.bounds(for: result).midY, oldMiddle.bounds(for: page).midY, accuracy: 0.05)
        XCTAssertEqual(result.string?.filter { !$0.isWhitespace },
            page.string?.replacingOccurrences(of: "alpha", with: "Alpha")
                .replacingOccurrences(of: "omega", with: "Omega").filter { !$0.isWhitespace })
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(reopened.pageCount, 1)
    }

    private func layout(_ source: String, _ draft: String, marker: String,
                        scale: CGFloat = 1) -> NSAttributedString {
        PDFBodyTextAttributedLayout.attributedString(text: draft, style: base,
            sourceText: source, sourceStyle: base, sourceRuns: runs(source, marker: marker), textScale: scale)
    }

    private func runs(_ text: String, marker: String) -> [InlineTextSourceRun] {
        let middle = (text as NSString).range(of: marker)
        return [InlineTextSourceRun(range: NSRange(location: 0, length: middle.location), style: base),
            InlineTextSourceRun(range: middle, style: accent, baselineOffset: 2.5),
            InlineTextSourceRun(range: NSRange(location: NSMaxRange(middle),
                length: text.utf16.count - NSMaxRange(middle)), style: base)]
    }

    private func assertAccent(_ value: NSAttributedString, marker: String, scale: CGFloat = 1,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let range = (value.string as NSString).range(of: marker)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        for character in range.location..<NSMaxRange(range) {
            let font = try XCTUnwrap(value.attribute(.font, at: character, effectiveRange: nil) as? NSFont,
                                    file: file, line: line)
            let expectedFont = PDFBodyTextEditor.replacementFont(for: marker, preferred: accent.font)
            XCTAssertEqual(font.fontName, expectedFont.fontName, file: file, line: line)
            XCTAssertEqual(font.pointSize, accent.fontSize * scale, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(CTFontGetMatrix(font as CTFont).a, accent.horizontalScale, accuracy: 0.001,
                           file: file, line: line)
            let color = try XCTUnwrap(value.attribute(.foregroundColor, at: character, effectiveRange: nil) as? NSColor,
                                     file: file, line: line)
            XCTAssertTrue(PDFTextColor(color).visuallyEquals(accent.textColor), file: file, line: line)
            let baseline = try XCTUnwrap(value.attribute(.baselineOffset, at: character, effectiveRange: nil) as? CGFloat,
                                        file: file, line: line)
            XCTAssertEqual(baseline, 2.5 * scale, accuracy: 0.001, file: file, line: line)
        }
    }

    private func appearance(_ selection: PDFSelection) throws -> (font: String, size: CGFloat, color: PDFTextColor) {
        let attributes = try XCTUnwrap(selection.attributedString)
        let font = try XCTUnwrap(attributes.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let color = try XCTUnwrap(attributes.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let name = font.fontName.split(separator: "+").last.map(String.init) ?? font.fontName
        return (name, font.pointSize, PDFTextColor(color))
    }

    private func fixture() throws -> PDFDocument {
        // Use exact 8-bit components: PDFium's colour API quantizes source
        // colours to bytes, independently of this source-run mapping change.
        let commands = "BT /F1 14 Tf 0.2 0.4 0.8 rg 1 0 0 1 40 140 Tm (alpha ) Tj "
            // Native paragraph grouping deliberately permits only compatible
            // sizes/colours and small baseline offsets. Exercise those exact
            // guards here; larger colour/superscript differences are covered
            // by the shared live-preview attributed-string tests above.
            + "/F2 12 Tf 0.2 0.4 0.8 rg 0.5 Ts (MIDDLE) Tj "
            + "/F1 14 Tf 0.2 0.4 0.8 rg 0 Ts ( omega) Tj ET\n"
            + "BT /F1 14 Tf 0 0 0 rg 1 0 0 1 40 40 Tm (UNTOUCHED) Tj ET\n"
        let bodies = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 220] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
            "<< /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, body) in bodies.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer << /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
