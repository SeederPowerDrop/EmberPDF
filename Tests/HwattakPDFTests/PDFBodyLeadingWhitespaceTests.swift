// SPDX-License-Identifier: MPL-2.0
// General constructed fixtures for native leading-space advance preservation.
import AppKit
import CoreText
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyLeadingWhitespaceTests: XCTestCase {
    private func sample(_ scalar: UInt32, x: CGFloat, y: CGFloat = 220,
                        generated: Bool = false, matrix: CGAffineTransform = .identity) -> PDFBodyLeadingWhitespace.Sample {
        .init(scalar: scalar, origin: CGPoint(x: x, y: y), linear: matrix, generated: generated)
    }
    private func proof(text: String = " alphaCode", owned: String? = nil,
                       samples: [PDFBodyLeadingWhitespace.Sample]? = nil) -> PDFBodyLeadingWhitespace.Proof? {
        PDFBodyLeadingWhitespace.prove(nativeText: text, ownedText: owned ?? text,
            samples: samples ?? [sample(32, x: 40), sample(97, x: 70)],
            sourceOrigin: CGPoint(x: 40, y: 220), fontSize: 10)
    }

    func testExactOwnedPrefixSplitsAtUTF16BoundaryBeforeSupplementaryScalar() throws {
        let value = try XCTUnwrap(proof(text: " 😀word ", owned: " 😀word",
            samples: [sample(32, x: 40), sample(0x1F600, x: 70)]))
        let fragments = try XCTUnwrap(value.fragments(for: " 😀word", offset: 7, remainderAdvance: nil))
        XCTAssertEqual(fragments.map(\.range), [NSRange(location: 7, length: 1), NSRange(location: 8, length: 6)])
        XCTAssertEqual(fragments[0].horizontalAdvance, 30)
        XCTAssertNil(fragments[1].horizontalAdvance, "An available original font must not be scaled.")
        XCTAssertNil(value.fragments(for: "😀word", offset: 7, remainderAdvance: nil))
    }

    func testSubstituteRemainderAdvanceExcludesAlreadyPreservedLeadingGap() throws {
        let value = try XCTUnwrap(proof())
        let fragments = try XCTUnwrap(value.fragments(for: " alphaCode", offset: 0, remainderAdvance: 84))
        XCTAssertEqual(fragments[0].horizontalAdvance, 30)
        XCTAssertEqual(fragments[1].horizontalAdvance, 54)
        XCTAssertNil(value.fragments(for: " alphaCode", offset: 0, remainderAdvance: 29))
        XCTAssertNil(value.fragments(for: " alphaCode", offset: Int.max, remainderAdvance: nil))
    }

    func testForeignTrailingWhitespaceMayBeExcludedButLeadingOwnershipCannotBeInvented() {
        XCTAssertNotNil(proof(text: " alphaCode \t", owned: " alphaCode"))
        XCTAssertNil(proof(text: " alphaCode", owned: "alphaCode"))
        XCTAssertNil(proof(text: " alphaCodeX", owned: " alphaCode"))
        XCTAssertNil(proof(text: " e\u{301}", owned: " é", samples: [sample(32, x: 40), sample(0xE9, x: 70)]))
    }

    func testUnprovenGeometryGeneratedLettersAndUnsafeTextRefuseGapProof() {
        for samples in [
            [sample(32, x: 40), sample(97, x: 70, generated: true)],
            [sample(32, x: 40), sample(97, x: 70, y: 219)],
            [sample(32, x: 40), sample(97, x: 39)],
            [sample(32, x: 40), sample(97, x: 40)],
            [sample(32, x: 40), sample(97, x: 500)],
            [sample(32, x: 40), sample(97, x: .nan)],
            [sample(32, x: 40), sample(97, x: 70, matrix: CGAffineTransform(scaleX: 2, y: 1))],
            [sample(32, x: 40), sample(98, x: 70)]
        ] { XCTAssertNil(proof(samples: samples)) }
        XCTAssertNil(proof(text: "\talphaCode", samples: [sample(9, x: 40), sample(97, x: 70)]))
        XCTAssertNil(proof(text: " alpha\nCode"))
        XCTAssertNil(proof(text: " alphaCode", samples: []))
        XCTAssertNil(proof(text: String(repeating: " ", count: 65) + "alphaCode"))
    }

    func testSeveralOwnedSpacesMayRepresentOneBoundedLeadingGap() throws {
        let value = try XCTUnwrap(proof(text: "   alphaCode", samples: [
            sample(32, x: 40), sample(32, x: 46, generated: true),
            sample(32, x: 52), sample(97, x: 76)]))
        XCTAssertEqual(value.leadingUTF16, 3)
        XCTAssertEqual(value.advance, 36)
    }

    func testLayoutPreservesLargeWhitespaceAdvanceWithoutScalingVisibleFont() throws {
        let style = InlineTextStyle(fontName: "Courier", fontSize: 10, textColor: .black,
            backgroundColor: .clear, alignment: .left)
        let source = " alphaCode"
        let fragments = try XCTUnwrap(try XCTUnwrap(proof()).fragments(for: source, offset: 0, remainderAdvance: nil))
        let runs = fragments.map { InlineTextSourceRun(range: $0.range, style: style, horizontalAdvance: $0.horizontalAdvance) }
        let attributed = PDFBodyTextAttributedLayout.attributedString(text: " alphaCade", style: style,
            sourceText: source, sourceStyle: style, sourceRuns: runs)
        let line = CTLineCreateWithAttributedString(attributed)
        XCTAssertEqual(CTLineGetOffsetForStringIndex(line, 1, nil), 30, accuracy: 0.01)
        let visibleFont = try XCTUnwrap(attributed.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(CTFontGetMatrix(visibleFont as CTFont).a, 1, accuracy: 0.0001)
        let deleted = PDFBodyTextAttributedLayout.attributedString(text: "alphaCade", style: style,
            sourceText: source, sourceStyle: style, sourceRuns: runs)
        XCTAssertEqual(CTLineGetOffsetForStringIndex(CTLineCreateWithAttributedString(deleted), 0, nil), 0, accuracy: 0.01)
        let replaced = PDFBodyTextAttributedLayout.attributedString(text: "XalphaCade", style: style,
            sourceText: source, sourceStyle: style, sourceRuns: runs)
        let newFont = try XCTUnwrap(replaced.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(CTFontGetMatrix(newFont as CTFont).a, 1, accuracy: 0.0001)
    }

    func testTJLargeLeadingGapAndOrdinarySpacesKeepUnchangedGlyphPositions() throws {
        for show in ["( alphaCode) Tj", "(    alphaCode) Tj",
                     "[( ) -2400 (alphaCode)] TJ", "[-3000 (alphaCode)] TJ"] {
            let source = try fixture(show: show)
            let page = try XCTUnwrap(source.page(at: 0)), target = try self.target("alphaCode", on: page)
            let alpha = try origins("alpha", on: page), other = try origins("otherRow", on: page)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: target.text.replacingOccurrences(of: "alphaCode", with: "alphaCade"),
                style: target.style, bounds: target.bounds)
            assertSameOrigins(try origins("alpha", on: edited), alpha)
            assertSameOrigins(try origins("otherRow", on: edited), other)
            XCTAssertTrue(try XCTUnwrap(edited.string).contains("alphaCade"))
        }
    }

    func testDifferentRowAndHangingIndentsDoNotCollapseIntoFirstRunGap() throws {
        let source = try fixture(show: "[( ) -2400 (alphaCode)] TJ", secondIndentedRow: true)
        let page = try XCTUnwrap(source.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let begin = text.range(of: "alphaCode"), end = text.range(of: "betaLine")
        XCTAssertNotEqual(begin.location, NSNotFound); XCTAssertNotEqual(end.location, NSNotFound)
        let selected = try XCTUnwrap(page.selection(for: NSRange(location: begin.location,
            length: NSMaxRange(end) - begin.location)))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
        let alpha = try origins("alpha", on: page), beta = try origins("betaLine", on: page)
        let other = try origins("otherRow", on: page)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "alphaCode", with: "alphaCade"),
            style: target.style, bounds: target.bounds)
        assertSameOrigins(try origins("alpha", on: edited), alpha)
        assertSameOrigins(try origins("betaLine", on: edited), beta)
        assertSameOrigins(try origins("otherRow", on: edited), other)
    }

    func testTJLeadingGapSurvivesTwoAtomicSaveReopenEditCycles() async throws {
        var source = try fixture(show: "[( ) -2400 (alphaCode)] TJ")
        let page = try XCTUnwrap(source.page(at: 0))
        let initialTarget = try self.target("alphaCode", on: page)
        let originalLeading = initialTarget.text.prefix(while: { $0 == " " }).count
        let originalAlpha = try origins("alpha", on: page), originalOther = try origins("otherRow", on: page)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leading-gap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (cycle, change) in [("alphaCode", "alphaCade"), ("alphaCade", "alphaCode")].enumerated() {
            let current = try XCTUnwrap(source.page(at: 0)), target = try self.target(change.0, on: current)
            let edited = try PDFBodyTextEditor.replacementPage(for: current, target: target,
                text: target.text.replacingOccurrences(of: change.0, with: change.1),
                style: target.style, bounds: target.bounds)
            assertSameOrigins(try origins("alpha", on: edited), originalAlpha)
            let live = PDFDocument(); live.insert(edited, at: 0)
            let snapshot = try PDFRecoverySnapshot(capturing: live)
            let output = directory.appendingPathComponent("cycle-\(cycle).pdf")
            try await Task.detached { try AtomicPDFWriter.write(snapshot.takeDocument(), to: output) }.value
            PDFBodyTextDocumentFonts.invalidate(source); PDFBodyTextDocumentFonts.invalidate(live)
            source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: output)))
            let reopened = try XCTUnwrap(source.page(at: 0))
            let reselected = try self.target(change.1, on: reopened)
            XCTAssertEqual(reselected.text.prefix(while: { $0 == " " }).count, originalLeading,
                "Cold re-selection must not silently lose the original logical whitespace prefix.")
            assertSameOrigins(try origins("alpha", on: reopened), originalAlpha)
            assertSameOrigins(try origins("otherRow", on: reopened), originalOther)
            XCTAssertEqual(source.findString(change.1, withOptions: []).count, 1)
        }
    }


    func testDeletingLeadingWhitespaceReleasesOnlyItsPositionedGap() throws {
        let source = try fixture(show: "[( ) -2400 (alphaCode)] TJ")
        let page = try XCTUnwrap(source.page(at: 0)), target = try self.target("alphaCode", on: page)
        let other = try origins("otherRow", on: page)
        XCTAssertTrue(target.text.hasPrefix(" "))
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: String(target.text.drop(while: { $0 == " " })), style: target.style, bounds: target.bounds)
        XCTAssertEqual(try XCTUnwrap(origins("alpha", on: edited).first).x, target.baseline.x, accuracy: 0.05)
        assertSameOrigins(try origins("otherRow", on: edited), other)
    }

    func testLeadingGapAndFollowingSameLineRunUseIndependentAdvances() throws {
        let source = try fixture(show: "[( ) -2400 (alphaCode)] TJ", followingRun: true)
        let page = try XCTUnwrap(source.page(at: 0)), text = try XCTUnwrap(page.string) as NSString
        let begin = text.range(of: "alphaCode"), end = text.range(of: "42")
        XCTAssertNotEqual(begin.location, NSNotFound); XCTAssertNotEqual(end.location, NSNotFound)
        let selected = try XCTUnwrap(page.selection(for: NSRange(location: begin.location, length: NSMaxRange(end) - begin.location)))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
        let numeric = try origins("42", on: page), alpha = try origins("alpha", on: page)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "alphaCode", with: "alphaCade"),
            style: target.style, bounds: target.bounds)
        assertSameOrigins(try origins("alpha", on: edited), alpha)
        assertSameOrigins(try origins("42", on: edited), numeric)
    }

    func testLeadingTJGapAndForeignBoundaryKeepCompatibleFollowingFontOrigin() throws {
        // The unchanged same-line adjacency gate is 15 pt. Exercise admitted
        // 8/12 pt boundaries and retain the 18 pt refusal separately.
        for followingX in [132, 136] {
        let source = try fixture(show: "[( ) -2400 (alphaCode)] TJ", foreignBoundary: true, followingX: followingX)
        let page = try XCTUnwrap(source.page(at: 0)), text = try XCTUnwrap(page.string) as NSString
        let begin = text.range(of: "alphaCode"), end = text.range(of: "tailWord")
        XCTAssertNotEqual(begin.location, NSNotFound); XCTAssertNotEqual(end.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: begin.location,
            length: NSMaxRange(end) - begin.location)))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        XCTAssertTrue(target.text.contains("alphaCode "), "Constructed gap must remain a logical boundary space.")
        let alpha = try origins("alpha", on: page), tail = try origins("tailWord", on: page)
        let other = try origins("otherRow", on: page)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "alphaCode", with: "alphaCade"),
            style: target.style, bounds: target.bounds)
        assertSameOrigins(try origins("alpha", on: edited), alpha)
        assertSameOrigins(try origins("tailWord", on: edited), tail)
        assertSameOrigins(try origins("otherRow", on: edited), other)
        }
    }

    func testForeignBoundaryBeyondExistingAdjacencyLimitIsRefused() throws {
        let source = try fixture(show: "[( ) -2400 (alphaCode)] TJ", foreignBoundary: true, followingX: 142)
        let page = try XCTUnwrap(source.page(at: 0)), text = try XCTUnwrap(page.string) as NSString
        let begin = text.range(of: "alphaCode"), end = text.range(of: "tailWord")
        XCTAssertNotEqual(begin.location, NSNotFound); XCTAssertNotEqual(end.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: begin.location,
            length: NSMaxRange(end) - begin.location)))
        XCTAssertNil(try PDFBodyTextEditor.target(on: page, selection: selection))
    }

    private func target(_ phrase: String, on page: PDFPage) throws -> PDFBodyTextTarget {
        let text = try XCTUnwrap(page.string) as NSString, range = text.range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: range))
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
    }
    private func assertSameOrigins(_ actual: [CGPoint], _ expected: [CGPoint],
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.05, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: 0.05, file: file, line: line)
        }
    }
    private func origins(_ phrase: String, on source: PDFPage) throws -> [CGPoint] {
        let data = try PDFBodyTextPageSnapshot.data(for: source)
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0)); defer { FPDF_ClosePage(page) }
            let textPage = try XCTUnwrap(FPDFText_LoadPage(page)); defer { FPDFText_ClosePage(textPage) }
            var text = "", indices: [Int32] = []
            for index in 0..<FPDFText_CountChars(textPage) {
                guard let scalar = UnicodeScalar(FPDFText_GetUnicode(textPage, index)), scalar.value != 0 else { continue }
                text.unicodeScalars.append(scalar)
                indices += Array(repeating: index, count: String(scalar).utf16.count)
            }
            let range = (text as NSString).range(of: phrase)
            XCTAssertNotEqual(range.location, NSNotFound)
            guard range.location != NSNotFound else { return [] }
            return indices[range.location..<NSMaxRange(range)].map { index in
                var x = 0.0, y = 0.0
                XCTAssertNotEqual(FPDFText_GetCharOrigin(textPage, index, &x, &y), 0)
                return CGPoint(x: x, y: y)
            }
        }
    }
    private func fixture(show: String, secondIndentedRow: Bool = false, followingRun: Bool = false,
                         foreignBoundary: Bool = false, followingX: Int = 142) throws -> PDFDocument {
        var content = "BT /F1 10 Tf 1 0 0 1 40 220 Tm \(show) ET\n"
        if followingRun { content += "BT /F1 10 Tf 1 0 0 1 124 220 Tm (42) Tj ET\n" }
        if foreignBoundary { content += "BT /F2 10 Tf 1 0 0 1 \(followingX) 220 Tm (tailWord) Tj ET\n" }
        if secondIndentedRow { content += "BT /F1 10 Tf 1 0 0 1 52 206 Tm [( ) -600 (betaLine)] TJ ET\n" }
        content += "BT /F1 10 Tf 1 0 0 1 40 160 Tm (otherRow) Tj ET\n"
        content += "q 0.2 0.5 0.8 rg 250 40 40 40 re f Q\n"
        let stream = Data(content.utf8)
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R /F2 6 0 R >> >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>".utf8),
            Data("<< /Length \(stream.count) >>\nstream\n".utf8) + stream + Data("endstream".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8)
        ]
        var pdf = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count); pdf.append(Data("\(index + 1) 0 obj\n".utf8)); pdf.append(object); pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: pdf))
    }
}
