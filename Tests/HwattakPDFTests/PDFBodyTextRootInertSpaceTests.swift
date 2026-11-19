// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextRootInertSpaceTests: XCTestCase {
    func testDirectRootEmptySlotsAllowParagraphSelectionAndRepeatedSavedEdits() throws {
        let original = try fixture()
        let first = try revise(original, from: "alpha", to: "aloha")
        let second = try revise(first, from: "beta", to: "zeta")
        XCTAssertEqual(first.page(at: 0)?.string?.filter { !$0.isWhitespace },
            original.page(at: 0)?.string?.replacingOccurrences(of: "alpha", with: "aloha").filter { !$0.isWhitespace })
        XCTAssertEqual(second.page(at: 0)?.string?.filter { !$0.isWhitespace },
            original.page(at: 0)?.string?.replacingOccurrences(of: "alpha", with: "aloha")
                .replacingOccurrences(of: "beta", with: "zeta").filter { !$0.isWhitespace })
        for document in [first, second] {
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertNotNil(try PDFBodyTextEditor.target(on: page, selection: paragraph(document)))
            let old = try XCTUnwrap(original.findString("UNTOUCHED", withOptions: []).first)
            let new = try XCTUnwrap(document.findString("UNTOUCHED", withOptions: []).first)
            XCTAssertEqual(new.bounds(for: page), old.bounds(for: original.page(at: 0)!))
        }
    }

    func testPaintedHiddenClippedTransparentAndCharacterOwnedGapsRemainBlocked() throws {
        let variants = [
            ("", "X", " "),
            ("3 Tr", " ", " "),
            ("4 Tr", " ", " "),
            ("99 159 2 2 re W n", " ", " "),
            ("/Fade gs", " ", " "),
            ("", " ", "X")
        ]
        for (modifier, glyph, actualText) in variants {
            let document = try fixture(modifier: modifier, glyph: glyph, actualText: actualText)
            let page = try XCTUnwrap(document.page(at: 0))
            do {
                let target = try PDFBodyTextEditor.target(on: page, selection: paragraph(document))
                XCTAssertNil(target,
                    "Unsafe intervening root: \(modifier), glyph \(glyph), ActualText \(actualText)")
            } catch { /* A rejected editing route also preserves the document. */ }
        }
    }

    func testInterveningVectorPaintCannotUseTheEmptyTextException() throws {
        let document = try fixture(vectorGap: true), page = try XCTUnwrap(document.page(at: 0))
        do {
            let target = try PDFBodyTextEditor.target(on: page, selection: paragraph(document))
            XCTAssertNil(target)
        }
        catch { /* Safe rejection. */ }
    }

    func testTinySelectedHeadingIsStillRejectedRatherThanSilentlyIgnored() throws {
        let document = try fixture(tinyHeading: true), page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: CGRect(x: 15, y: 120, width: 120, height: 55)))
        XCTAssertTrue(selection.string?.contains("tiny") == true)
        do {
            let target = try PDFBodyTextEditor.target(on: page, selection: selection)
            XCTAssertNil(target)
        }
        catch { /* Font-size safety remains enforced. */ }
    }

    func testPrefixVerifiedWidePunctuationRetainsItsOwnScaleAfterSavedEdits() throws {
        let original = try fixture(widePunctuation: true)
        let first = try revise(original, from: "alpha", to: "aloha")
        let second = try revise(first, from: "beta", to: "zeta")
        for document in [original, first, second] {
            let page = try XCTUnwrap(document.page(at: 0))
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: paragraph(document)))
            let punctuation = try XCTUnwrap(target.sourceRuns.first {
                (target.text as NSString).substring(with: $0.range).trimmingCharacters(in: .whitespaces) == "."
            })
            XCTAssertEqual(punctuation.style.horizontalScale, 1.4, accuracy: 0.01)
        }
    }

    func testWideScaleWithoutAPrefixProofAndOtherStyleOrGeometryChangesStayBlocked() throws {
        let variants = [
            try fixture(widePunctuation: true, unprovenPunctuation: true),
            try fixture(widePunctuation: true, wideFontSize: 20),
            try fixture(widePunctuation: true, wideColor: "1 0 0 rg"),
            try fixture(widePunctuation: true, wideBaseline: 150)
        ]
        for document in variants {
            let page = try XCTUnwrap(document.page(at: 0))
            do {
                let target = try PDFBodyTextEditor.target(on: page, selection: paragraph(document))
                XCTAssertNil(target)
            }
            catch { /* The verified-scale exception does not bypass another gate. */ }
        }
    }

    func testProvenNativeSpaceAfterPunctuationSurvivesRepeatedSavedEdits() throws {
        let original = try fixture(punctuationBoundary: true)
        let first = try revise(original, from: "alpha", to: "aloha")
        let second = try revise(first, from: "beta", to: "zeta")
        for (document, phrase) in [(original, "alpha, row"), (first, "aloha, row"), (second, "aloha, row")] {
            let page = try XCTUnwrap(document.page(at: 0))
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: paragraph(document)))
            XCTAssertTrue(target.text.contains(phrase), "A proven native word space must survive punctuation")
            XCTAssertFalse(target.text.contains(",row"))
            let words = page.string?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            XCTAssertTrue(words?.contains(phrase) == true)
            XCTAssertEqual(target.text.components(separatedBy: "\n").count, 3)
        }
    }

    func testPunctuationSideBearingWithoutAnInertBoundaryDoesNotInventSpace() throws {
        let document = try fixture(punctuationBoundary: true, boundarySlot: false)
        let page = try XCTUnwrap(document.page(at: 0))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: paragraph(document)))
        XCTAssertTrue(target.text.contains("alpha,row"))
        XCTAssertFalse(target.text.contains("alpha, row"))
    }

    func testItalicPunctuationBoundaryUsesActualAdvanceAndKeepsNextWordOrigin() throws {
        let original = try fixture(punctuationBoundary: true, italicBoundary: true, boundaryPunctuation: "–")
        let page = try XCTUnwrap(original.page(at: 0))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: paragraph(original)))
        let word = try XCTUnwrap(target.sourceRuns.first {
            (target.text as NSString).substring(with: $0.range) == "alpha–"
        })
        let space = try XCTUnwrap(target.sourceRuns.first {
            $0.range.location == NSMaxRange(word.range)
                && (target.text as NSString).substring(with: $0.range) == " "
        })
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "alpha–",
            attributes: [.font: word.style.renderingFont(word.style.font)]))
        let expected = 59 - 20 - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        XCTAssertEqual(try XCTUnwrap(space.horizontalAdvance), expected, accuracy: 0.001)
        let first = try revise(original, from: "alpha", to: "aloha")
        let second = try revise(first, from: "aloha", to: "alpha")
        let originalWord = try XCTUnwrap(original.findString("row", withOptions: []).first)
        let originalX = originalWord.bounds(for: page).minX
        for document in [first, second] {
            let current = try XCTUnwrap(document.page(at: 0))
            let selected = try XCTUnwrap(document.findString("row", withOptions: []).first)
            XCTAssertEqual(selected.bounds(for: current).minX, originalX, accuracy: 0.03)
            XCTAssertTrue(current.string?.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").contains("– row") == true)
        }
    }

    private func paragraph(_ document: PDFDocument) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = PDFSelection(document: document)
        for baseline: CGFloat in [160, 142, 124] {
            selection.add(try XCTUnwrap(page.selection(for:
                CGRect(x: 19, y: baseline - 3, width: 76, height: 15))))
        }
        return selection
    }

    private func revise(_ document: PDFDocument, from old: String, to new: String) throws -> PDFDocument {
        let page = try XCTUnwrap(document.page(at: 0))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: paragraph(document)))
        XCTAssertTrue(target.text.contains(old))
        let replacement = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: old, with: new), style: target.style, bounds: target.bounds)
        let data = try PDFBodyTextPageSnapshot.originalPageData(for: replacement)
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func fixture(modifier: String = "", glyph: String = " ", actualText: String = " ",
                         vectorGap: Bool = false, tinyHeading: Bool = false,
                         widePunctuation: Bool = false, unprovenPunctuation: Bool = false,
                         wideFontSize: Int = 12, wideColor: String = "0 0 0 rg",
                         wideBaseline: Int = 142, punctuationBoundary: Bool = false,
                         boundarySlot: Bool = true, italicBoundary: Bool = false,
                         boundaryPunctuation: String = ",") throws -> PDFDocument {
        func gap(_ y: Int) -> String {
            if vectorGap { return "q 0 0 0 rg 100 \(y) 2 2 re f Q\n" }
            return "q \(modifier) /Span << /ActualText (\(actualText)) >> BDC "
                + "BT /F1 12 Tf 1 0 0 1 100 \(y) Tm (\(glyph)) Tj ET EMC Q\n"
        }
        let punctuation = widePunctuation
            ? (unprovenPunctuation ? "/Span BMC " : "")
                + "q \(wideColor) BT /F1 \(wideFontSize) Tf 1.4 0 0 1 90 \(wideBaseline) Tm (.) Tj ET Q "
                + (unprovenPunctuation ? "EMC\n" : "\n") : ""
        let encodedPunctuation = boundaryPunctuation == "–" ? "\\226" : ","
        let firstRow = punctuationBoundary
            ? "BT /\(italicBoundary ? "F2" : "F1") 12 Tf 1 0 0 1 20 160 Tm (alpha\(encodedPunctuation)) Tj ET\n"
                + (boundarySlot ? gap(160) : "")
                + "BT /F1 12 Tf 1 0 0 1 59 160 Tm (row) Tj ET\n" + gap(160)
            : "BT /F1 12 Tf 1 0 0 1 20 160 Tm (alpha row) Tj ET\n" + gap(160)
        let content = (tinyHeading ? "BT /F1 2 Tf 1 0 0 1 20 170 Tm (tiny) Tj ET\n" : "")
            + firstRow
            + "BT /F1 12 Tf 1 0 0 1 20 142 Tm (beta second) Tj ET\n" + punctuation + gap(142)
            + "BT /F1 12 Tf 1 0 0 1 20 124 Tm (gamma third) Tj ET\n"
            + "BT /F1 12 Tf 1 0 0 1 20 40 Tm (UNTOUCHED) Tj ET\n"
        let bodies = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << /Font << /F1 4 0 R /F2 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding >> >> /ExtGState << /Fade << /Type /ExtGState /ca 0.5 >> >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
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
