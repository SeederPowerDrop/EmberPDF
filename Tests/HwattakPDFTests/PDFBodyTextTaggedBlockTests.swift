// SPDX-License-Identifier: MPL-2.0

import AppKit
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextTaggedBlockTests: XCTestCase {
    func testCondensedTaggedWordsOpenFromPointAndPartialSelection() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let selection = try XCTUnwrap(source.findString("original", withOptions: []).first)
        let selected = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        XCTAssertEqual(selected.text.trimmingCharacters(in: .whitespacesAndNewlines), "Keep original words")
        let range = try XCTUnwrap(selected.initialSelectedRange)
        XCTAssertEqual((selected.text as NSString).substring(with: range), "original")
        XCTAssertEqual(selected.style.fontSize, 16, accuracy: 0.01)

        let point = try firstCharacterPoint(of: "original", in: source)
        let clicked = try XCTUnwrap(PDFBodyTextEditor.target(on: page, at: point))
        XCTAssertEqual(clicked.text.trimmingCharacters(in: .whitespacesAndNewlines), "Keep original words")
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testPartialEditSaveReopenAndReeditKeepOtherWordsAndOutsidePixels() throws {
        let original = try fixture()
        let originalPage = try XCTUnwrap(original.page(at: 0))
        let originalBytes = try PDFBodyTextPageSnapshot.data(for: originalPage)
        var source = original
        var control = try fixture()

        for (before, after) in [("original", "revised"), ("revised", "final")] {
            let page = try XCTUnwrap(source.page(at: 0))
            let selection = try XCTUnwrap(source.findString(before, withOptions: []).first)
            let prefixPointBefore = try firstCharacterPoint(of: "Keep", in: source)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
            let range = try XCTUnwrap(target.initialSelectedRange)
            XCTAssertEqual((target.text as NSString).substring(with: range), before)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: (target.text as NSString).replacingCharacters(in: range, with: after),
                style: target.style, bounds: target.bounds)
            let live = document(edited)
            XCTAssertEqual(live.findString("Keep \(after) words", withOptions: []).count, 1)
            XCTAssertTrue(live.findString(before, withOptions: []).isEmpty)
            XCTAssertEqual(live.findString("Unaffected caption", withOptions: []).count, 1)
            XCTAssertEqual(try outsidePixels(edited), try outsidePixels(page))
            let livePrefixPoint = try firstCharacterPoint(of: "Keep", in: live)
            XCTAssertEqual(livePrefixPoint.x, prefixPointBefore.x, accuracy: 0.5)
            XCTAssertEqual(livePrefixPoint.y, prefixPointBefore.y, accuracy: 0.5)
            let liveEditedPoint = try firstCharacterPoint(of: after, in: live)
            if before == "original" {
                let content = try PDFBodyTextPageSnapshot.contentData(for: edited)
                XCTAssertTrue(String(decoding: content, as: UTF8.self).contains(Self.graphics),
                    "Editing tagged text must not regenerate unrelated spot colors or shading.")
            }

            source = try XCTUnwrap(PDFDocument(data: XCTUnwrap(live.dataRepresentation())))
            // PDFKit may normalize resource/color encodings on save. Compare
            // against the same untouched save cycle after each reopen.
            let controlCopy = try XCTUnwrap(XCTUnwrap(control.page(at: 0)).copy() as? PDFPage)
            control = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document(controlCopy).dataRepresentation())))
            let reopened = try XCTUnwrap(source.page(at: 0))
            XCTAssertEqual(source.findString("Keep \(after) words", withOptions: []).count, 1)
            XCTAssertTrue(source.findString(before, withOptions: []).isEmpty)
            XCTAssertEqual(try outsidePixels(reopened), try outsidePixels(XCTUnwrap(control.page(at: 0))))
            let savedSelection = try XCTUnwrap(source.findString(after, withOptions: []).first)
            XCTAssertNotNil(try PDFBodyTextEditor.target(on: reopened, selection: savedSelection))
            // Reopening can split a donor into different native text objects.
            // Compare actual selected glyph positions, not an aggregate run's
            // baseline, which can legitimately belong to an earlier word.
            let savedEditedPoint = try firstCharacterPoint(of: after, in: source)
            XCTAssertEqual(savedEditedPoint.x, liveEditedPoint.x, accuracy: 0.1)
            XCTAssertEqual(savedEditedPoint.y, liveEditedPoint.y, accuracy: 0.1)
            XCTAssertNotNil(try PDFBodyTextEditor.target(on: reopened,
                at: firstCharacterPoint(of: after, in: source)))
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: originalPage), originalBytes)
        XCTAssertEqual(original.findString("Keep original words", withOptions: []).count, 1)
    }

    func testDeletingWholeTaggedBlockRemovesSemanticSpacesAndKeepsCaption() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page,
            at: firstCharacterPoint(of: "original", in: source)))
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "", style: target.style, bounds: target.bounds)
        let output = document(edited)
        XCTAssertEqual(output.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Unaffected caption")
        XCTAssertEqual(try outsidePixels(edited), try outsidePixels(page))
        let content = String(decoding: try PDFBodyTextPageSnapshot.contentData(for: edited), as: UTF8.self)
        XCTAssertFalse(content.contains("/ActualText"), "Empty tagged shows must not leave semantic space placeholders.")
    }

    func testSavedKoreanWordWithGeneratedTrailingSpaceCanBeEditedAgain() throws {
        let original = try fixture()
        let originalPage = try XCTUnwrap(original.page(at: 0))
        let originalBytes = try PDFBodyTextPageSnapshot.data(for: originalPage)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: originalPage,
            at: firstCharacterPoint(of: "original", in: original)))
        var style = target.style
        style.fontName = "AppleMyungjo"
        style.fontSize = 10.3
        let inserted = try PDFBodyTextEditor.replacementPage(for: originalPage, target: target,
            text: "문서를 차분히 확인해요", style: style, bounds: target.bounds)
        let saved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document(inserted).dataRepresentation())))
        let page = try XCTUnwrap(saved.page(at: 0))
        XCTAssertEqual(saved.findString("문서를 차분히 확인해요", withOptions: []).count, 1)
        let prefixBefore = try firstCharacterPoint(of: "문서를", in: saved)
        let suffixBefore = try firstCharacterPoint(of: "확인해요", in: saved)
        let selection = try XCTUnwrap(saved.findString("차분히", withOptions: []).first)
        // PDFKit flattens the donor into positioned native words. PDFium's
        // full-page extraction appends a generated boundary space to this
        // word; the prefix ending at its ET has no following word or space.
        // Verify that difference independently: the editor may correctly omit
        // the boundary space from its own glyph-based selection string.
        let nativeWords = try nativeTextObjects(in: PDFBodyTextPageSnapshot.data(for: page))
        let ordinal = try XCTUnwrap(nativeWords.firstIndex(of: "차분히 "))
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let records = try PDFBodyTextContentStream.parse(content).records
        XCTAssertEqual(records.count, nativeWords.count)
        let prefix = try PDFBodyTextPageSnapshot.data(for: page,
            contentOverride: Data(content.prefix(records[ordinal].insertionOffset)))
        XCTAssertEqual(try nativeTextObjects(in: prefix).last, "차분히")
        let next = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let range = try XCTUnwrap(next.initialSelectedRange)
        XCTAssertEqual((next.text as NSString).substring(with: range), "차분히")
        let revised = try PDFBodyTextEditor.replacementPage(for: page, target: next,
            text: (next.text as NSString).replacingCharacters(in: range, with: "빠르게"),
            style: next.style, bounds: next.bounds)
        let result = document(revised)
        XCTAssertEqual(result.findString("문서를 빠르게 확인해요", withOptions: []).count, 1)
        XCTAssertTrue(result.findString("차분히", withOptions: []).isEmpty)
        XCTAssertEqual(result.findString("Unaffected caption", withOptions: []).count, 1)
        XCTAssertEqual(try outsidePixels(revised), try outsidePixels(page))
        let prefixAfter = try firstCharacterPoint(of: "문서를", in: result)
        let suffixAfter = try firstCharacterPoint(of: "확인해요", in: result)
        XCTAssertEqual(prefixAfter.x, prefixBefore.x, accuracy: 0.1)
        XCTAssertEqual(prefixAfter.y, prefixBefore.y, accuracy: 0.1)
        XCTAssertEqual(suffixAfter.x, suffixBefore.x, accuracy: 0.1)
        XCTAssertEqual(suffixAfter.y, suffixBefore.y, accuracy: 0.1)
        let revisedSelection = try XCTUnwrap(result.findString("빠르게", withOptions: []).first)
        let revisedTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: revised, selection: revisedSelection))
        XCTAssertEqual(revisedTarget.baseline.x, next.baseline.x, accuracy: 0.1)
        XCTAssertEqual(revisedTarget.baseline.y, next.baseline.y, accuracy: 0.1)
        let resaved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(result.dataRepresentation())))
        XCTAssertEqual(resaved.findString("문서를 빠르게 확인해요", withOptions: []).count, 1)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: originalPage), originalBytes)
    }

    func testNonspaceActualTextRotationAndShearStayRejectedWithoutMutation() throws {
        let unsupported = [
            try fixture(actualText: "(semantic replacement)"),
            try fixture(matrix: "0.965926 0.258819 -0.258819 0.965926"),
            try fixture(matrix: "0.98 0 0.15 1")
        ]
        for source in unsupported {
            try assertRejectedWithoutMutation(source)
        }
    }

    func testSemanticActualTextAndOptionalContentCannotFallBackOnPlainPages() throws {
        try assertRejectedWithoutMutation(fixture(actualText: "(semantic replacement)", hasGraphics: false))
        try assertRejectedWithoutMutation(fixture(outerTag: "/OC /Layer1 BDC", hasGraphics: false))
    }

    func testVisibleGlyphWithEmptyExtractedTextCannotBeDiscardedAsASpacer() throws {
        // The visible X is hidden from text extraction by whitespace ActualText,
        // but its nonempty ink cannot be silently removed with blank spacers.
        let source = try fixture(spaceShow: "(X)", hasGraphics: false)
        XCTAssertFalse((source.string ?? "").contains("X"))
        try assertRejectedWithoutMutation(source)
    }

    func testOverlappingRepeatedPhraseNeverEditsTheWrongOccurrence() throws {
        let source = try fixture(word: "banana", hasGraphics: false)
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let text = try XCTUnwrap(page.string) as NSString
        let banana = text.range(of: "banana")
        XCTAssertNotEqual(banana.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: banana.location + 3, length: 3)))
        XCTAssertEqual(selection.string, "ana")
        let target: PDFBodyTextTarget?
        do {
            target = try PDFBodyTextEditor.target(on: page, selection: selection)
        } catch {
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
            return
        }
        if let target {
            let range = try XCTUnwrap(target.initialSelectedRange)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: (target.text as NSString).replacingCharacters(in: range, with: "XYZ"),
                style: target.style, bounds: target.bounds)
            let result = document(edited)
            XCTAssertEqual(result.findString("Keep banXYZ words", withOptions: []).count, 1)
            XCTAssertTrue(result.findString("bXYZna", withOptions: []).isEmpty)
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    private func assertRejectedWithoutMutation(_ source: PDFDocument) throws {
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let selection = try XCTUnwrap(source.findString("original", withOptions: []).first)
        do {
            let result = try PDFBodyTextEditor.target(on: page, selection: selection)
            XCTAssertNil(result)
        } catch {
            // Evaluate the throwing call before XCTest's nonthrowing assertion
            // autoclosure, so a deliberate unsupported error reaches this catch.
        }
        let point = try firstCharacterPoint(of: "original", in: source)
        do {
            let result = try PDFBodyTextEditor.target(on: page, at: point)
            XCTAssertNil(result)
        } catch {}
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    private static let graphics = """
    % unrelated graphics must remain unchanged
    q 0.8 0.1 0 0.15 k 22 25 88 65 re f Q
    q /Spot cs 0.65 scn 128 25 88 65 re f Q
    q 242 25 130 65 re W n /Sh1 sh Q
    q 3.864 M 0 j 6 w 0.1 0.6 0 0 K 30 125 m 78 188 l 126 125 l S Q
    % end unrelated graphics
    """

    private func fixture(matrix: String = "0.98 0 0 1", actualText: String = "<FEFF0020>",
                         spaceShow: String = "<01>", word: String = "original",
                         outerTag: String = "/Span << /Lang (en-US) /MCID 0 >> BDC",
                         hasGraphics: Bool = true) throws -> PDFDocument {
        // The encoded 01 space is a separate PDFium text object. ActualText
        // supplies its logical whitespace, as in tagged typesetting output.
        let space = "/Span << /ActualText \(actualText) >> BDC \(spaceShow) Tj EMC"
        let content = outerTag + "\n"
            + "BT /F1 16 Tf 0 Tc 0 Tw /DeviceRGB cs 0 0 0 scn /GS1 gs /Perceptual ri "
            + "\(matrix) 40 265 Tm (Keep) Tj \(space) (\(word)) Tj \(space) (words) Tj ET\nEMC\n"
            + "BT 1 0 0 1 40 228 Tm (Unaffected caption) Tj ET\n" + (hasGraphics ? Self.graphics : "")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [10 0 R] /D << /ON [10 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> /ColorSpace << /Spot [/Separation /TestInk /DeviceRGB 6 0 R] >> /Shading << /Sh1 7 0 R >> /ExtGState << /GS1 9 0 R >> /Properties << /Layer1 10 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [1 /space] >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0.1 0.3 0.8] /N 1 >>",
            "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [242 25 372 90] /Function 8 0 R /Extend [true true] >>",
            "<< /FunctionType 2 /Domain [0 1] /C0 [0.9 0.1 0.2] /C1 [0.1 0.7 0.4] /N 1 >>",
            "<< /Type /ExtGState /BM /Normal /ca 1 /CA 1 >>",
            "<< /Type /OCG /Name (Visible fixture layer) >>"
        ]
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

    private func firstCharacterPoint(of phrase: String, in document: PDFDocument) throws -> CGPoint {
        let page = try XCTUnwrap(document.page(at: 0))
        let range = (try XCTUnwrap(page.string) as NSString).range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound)
        let first = try XCTUnwrap(page.selection(for: NSRange(location: range.location, length: 1)))
        let bounds = first.bounds(for: page)
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func nativeTextObjects(in data: Data) throws -> [String] {
        // The editor has initialized PDFium before this fixture check. Keep
        // every native handle inside the lifetime of the immutable byte buffer.
        try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0))
            defer { FPDF_ClosePage(page) }
            let textPage = try XCTUnwrap(FPDFText_LoadPage(page))
            defer { FPDFText_ClosePage(textPage) }
            return try (0..<FPDFPage_CountObjects(page)).compactMap { index in
                let object = try XCTUnwrap(FPDFPage_GetObject(page, index))
                guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT else { return nil }
                let count = FPDFTextObj_GetText(object, textPage, nil, 0)
                XCTAssertGreaterThanOrEqual(count, 2)
                var buffer = [UInt16](repeating: 0, count: Int(count) / 2)
                XCTAssertEqual(FPDFTextObj_GetText(object, textPage, &buffer, count), count)
                return String(decoding: buffer.dropLast(), as: UTF16.self)
            }
        }
    }

    private func document(_ page: PDFPage) -> PDFDocument {
        let result = PDFDocument()
        result.insert(page, at: 0)
        return result
    }

    private func outsidePixels(_ page: PDFPage) throws -> Data {
        // Include the following line and every illustration, excluding only
        // the edited strip near the top of the 400×300pt page.
        let width = 800, height = 600
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: 2, y: 2)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        var result = Data()
        for y in 0..<492 {
            result.append(contentsOf: bytes[(height - 1 - y) * width * 4..<(height - y) * width * 4])
        }
        XCTAssertTrue(result.contains { $0 != 255 })
        return result
    }
}
