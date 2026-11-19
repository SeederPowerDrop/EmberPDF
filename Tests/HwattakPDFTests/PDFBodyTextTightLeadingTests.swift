// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import CPDFium
import CryptoKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextTightLeadingTests: XCTestCase {
    func testExplicitFontChangePreservesSourceBaselinesSmallerThanFontEm() throws {
        let document = try nativeFixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0,
            length: try XCTUnwrap(page.string).utf16.count)))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        XCTAssertEqual(try XCTUnwrap(target.lineHeight), 13, accuracy: 0.05)
        var style = target.style
        style.fontSize = 16.5
        XCTAssertLessThan(try XCTUnwrap(target.lineHeight), style.fontSize)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "One\nTwo\nEnd", style: style, bounds: target.bounds)
        let reopened = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.data(for: edited)))
        let saved = try XCTUnwrap(reopened.page(at: 0))
        for (index, text) in ["One", "Two", "End"].enumerated() {
            XCTAssertEqual(try baseline(of: text, on: saved), 260 - CGFloat(index) * 13, accuracy: 0.05,
                           "A font's em size must not replace the PDF's explicit baseline distance.")
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
        XCTAssertTrue(saved.annotations.isEmpty)
    }

    func testLiveEditorKeepsTightBaselineGridAfterZoomAndNewlineInsertion() throws {
        let text = "Alpha\nBravo\nCharlie"
        let style = InlineTextStyle(fontName: "ArialMT", fontSize: 16.5,
            textColor: .black, backgroundColor: .clear, alignment: .left)
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 300))
        panel.configure(with: PendingInlineTextEdit(pageIndex: 0,
            bounds: CGRect(x: 40, y: 180, width: 250, height: 60),
            isEditingExistingAnnotation: false, purpose: .bodyText, text: text, style: style,
            bodyTextLineHeight: 13, bodyTextSourceText: text, bodyTextSourceStyle: style))
        for scale: CGFloat in [1, 2] {
            panel.setTextPresentationScale(scale)
            let baselines = try editorBaselines(panel.textView, words: ["Alpha", "Bravo", "Charlie"])
            XCTAssertEqual(baselines[1] - baselines[0], 13 * scale, accuracy: 0.05)
            XCTAssertEqual(baselines[2] - baselines[1], 13 * scale, accuracy: 0.05)
        }
        panel.textView.setSelectedRange(NSRange(location: panel.textView.string.utf16.count, length: 0))
        panel.textView.insertText("\nDelta", replacementRange: panel.textView.selectedRange())
        let baselines = try editorBaselines(panel.textView, words: ["Charlie", "Delta"])
        XCTAssertEqual(baselines[1] - baselines[0], 26, accuracy: 0.05,
                       "Typing a new paragraph must use the same scaled source spacing as the preview.")
    }

    func testInvalidPreviewLineHeightsKeepFiniteForwardLayout() throws {
        let style = InlineTextStyle(fontName: "ArialMT", fontSize: 16.5,
            textColor: .black, backgroundColor: .clear, alignment: .left)
        for height: CGFloat in [0, -1, .infinity, .nan] {
            let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 300))
            panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
                isEditingExistingAnnotation: false, purpose: .bodyText,
                text: "Alpha\nBravo", style: style, bodyTextLineHeight: height))
            let baselines = try editorBaselines(panel.textView, words: ["Alpha", "Bravo"])
            XCTAssertTrue(baselines.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(baselines[1], baselines[0])
        }
    }

    func testTightLeadingPolicyKeepsFreeTextAndDefaultBodyLayoutUnchanged() throws {
        let style = InlineTextStyle(fontName: "ArialMT", fontSize: 16.5,
            textColor: .black, backgroundColor: .clear, alignment: .left)
        let text = "Alpha\nBravo\nCharlie"
        func draft(_ purpose: InlineTextEditPurpose, _ height: CGFloat?) -> PendingInlineTextEdit {
            PendingInlineTextEdit(pageIndex: 0, bounds: CGRect(x: 40, y: 180, width: 250, height: 60),
                isEditingExistingAnnotation: false, purpose: purpose, text: text, style: style,
                bodyTextLineHeight: height)
        }
        let reused = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 300))
        let cases: [(InlineTextEditPurpose, CGFloat?)] = [
            (.freeText, nil), (.bodyText, nil), (.bodyText, 0), (.bodyText, -1),
            (.bodyText, .infinity), (.bodyText, .nan)
        ]
        for (purpose, height) in cases {
            reused.configure(with: draft(.bodyText, 13))
            let tight = try editorBaselines(reused.textView, words: ["Alpha", "Bravo"])
            XCTAssertEqual(tight[1] - tight[0], 13, accuracy: 0.05)
            reused.configure(with: draft(purpose, height))
            let fresh = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 300))
            fresh.configure(with: draft(purpose, height))
            let actual = try editorBaselines(reused.textView, words: ["Alpha", "Bravo", "Charlie"])
            let expected = try editorBaselines(fresh.textView, words: ["Alpha", "Bravo", "Charlie"])
            for (left, right) in zip(actual, expected) {
                XCTAssertEqual(left, right, accuracy: 0.001,
                               "A previously edited tight paragraph must not affect the next editor's native layout.")
            }
            XCTAssertTrue(try XCTUnwrap(reused.textView.layoutManager).usesFontLeading)
        }
    }

    func testOptInReportedGermanFourRowsSaveReopenReeditAndUndoWithoutChangingSource() async throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_STADIUM_PDF"], path.hasPrefix("/") else {
            throw XCTSkip("Set EMBER_STADIUM_PDF for the original German page 184 tight-leading regression.")
        }
        let source = URL(fileURLWithPath: path)
        let originalSHA = try digest(source)
        XCTAssertEqual(originalSHA, "0c4ccdaece61be9a562094c25c6c5f9618ab804d266481354a3283327d1f3133")
        guard originalSHA == "0c4ccdaece61be9a562094c25c6c5f9618ab804d266481354a3283327d1f3133" else {
            throw NSError(domain: "GermanTightLeadingFixture", code: 1)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GermanTightLeading-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("German-copy.pdf")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-c", "-p", source.path, copy.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        guard process.terminationStatus == 0 else { throw NSError(domain: "GermanClone", code: 1) }
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let copyAttributes = try FileManager.default.attributesOfItem(atPath: copy.path)
        XCTAssertNotEqual(originalAttributes[.systemFileNumber] as? NSNumber,
                          copyAttributes[.systemFileNumber] as? NSNumber)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: copy))
        defer { workspace.closeDiscardingChanges() }
        workspace.setMode(.editing)
        let originalDocument = try XCTUnwrap(workspace.document)
        let originalPage = try XCTUnwrap(originalDocument.page(at: 183))
        let originalSnapshot = try PDFBodyTextPageSnapshot.data(for: originalPage)
        let originalText = originalPage.string
        let untouchedIndices = [0, 182, 184, 407]
        let untouchedContent = try untouchedIndices.map {
            try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(workspace.document?.page(at: $0)))
        }
        var currentYear = "1976"
        for year in ["1975", "1974"] {
            let page = try XCTUnwrap(workspace.document?.page(at: 183))
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            let selection = try germanSelection(on: page, year: currentYear)
            XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection, preservesSelectionTool: false))
            let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
            XCTAssertEqual(draft.text.components(separatedBy: "\n").count, 4)
            XCTAssertLessThan(try XCTUnwrap(draft.bodyTextLineHeight), draft.style.fontSize)
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before,
                           "Opening the editor cannot modify the recognition layer or scan.")
            if year == "1975" {
                let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
                var oversized = draft.style
                oversized.fontSize *= 2
                // One short row fits the semantic-row limit and page box, but
                // its ink exceeds the original selected-paper union. Visible
                // clipping must never make such a replacement acceptable.
                XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: target,
                    text: "g", style: oversized, bounds: draft.bounds)) { error in
                    XCTAssertEqual(error.localizedDescription,
                        L10n.string("body_text.error.does_not_fit", defaultValue:
                            "입력한 글자가 페이지 밖으로 넘어갑니다. 글자 크기를 줄이거나 내용을 짧게 입력해 주세요."))
                }
                XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
            }
            let changed = draft.text.replacingOccurrences(of: currentYear, with: year)
            workspace.commitPendingInlineText(id: draft.id, text: changed, style: draft.style, bounds: draft.bounds)
            XCTAssertNil(workspace.presentedError)
            XCTAssertNil(workspace.pendingInlineTextEdit)
            let edited = try XCTUnwrap(workspace.document?.page(at: 183))
            XCTAssertTrue(edited.string?.contains("stieg \(year) mit Ausnahme") == true)
            XCTAssertEqual(edited.annotations.count, originalPage.annotations.count)
            XCTAssertEqual(try pixelsOutsideOriginalMasks(originalPage), try pixelsOutsideOriginalMasks(edited))
            workspace.undo()
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: XCTUnwrap(workspace.document?.page(at: 183))), before)
            workspace.redo()
            XCTAssertTrue(workspace.document?.page(at: 183)?.string?.contains("stieg \(year) mit Ausnahme") == true)
            let saved = await workspace.saveAsynchronously()
            XCTAssertTrue(saved, workspace.presentedError ?? "The tight-leading edit must save successfully.")
            workspace.closeDiscardingChanges()
            XCTAssertTrue(workspace.open(url: copy))
            workspace.setMode(.editing)
            XCTAssertEqual(workspace.document?.pageCount, 408)
            let reopened = try XCTUnwrap(workspace.document?.page(at: 183))
            XCTAssertTrue(reopened.string?.contains("stieg \(year) mit Ausnahme") == true)
            XCTAssertEqual(try pixelsOutsideOriginalMasks(originalPage), try pixelsOutsideOriginalMasks(reopened))
            for (index, content) in zip(untouchedIndices, untouchedContent) {
                XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(workspace.document?.page(at: index))), content)
            }
            currentYear = year
        }
        let unchangedSnapshot = try PDFBodyTextPageSnapshot.data(for: originalPage)
        XCTAssertEqual(unchangedSnapshot, originalSnapshot)
        // Replacing a page detaches its old PDFPage from the document.
        // PDFKit changes detached-page extraction order even after a pure
        // remove/insert with byte-identical resources. Compare independent,
        // document-backed extraction from those unchanged bytes instead.
        let unchangedDocument = try XCTUnwrap(PDFDocument(data: unchangedSnapshot))
        XCTAssertEqual(try XCTUnwrap(unchangedDocument.page(at: 0)).string, originalText)
        XCTAssertEqual(originalDocument.pageCount, 408)
        XCTAssertEqual(try digest(source), originalSHA)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date,
                       originalAttributes[.modificationDate] as? Date)
    }

    private func editorBaselines(_ view: NSTextView, words: [String]) throws -> [CGFloat] {
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        return try words.map { word in
            let range = (view.string as NSString).range(of: word)
            XCTAssertNotEqual(range.location, NSNotFound)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            return fragment.minY + manager.location(forGlyphAt: glyphs.location).y
        }
    }

    private func nativeFixture() throws -> PDFDocument {
        let font = try XCTUnwrap(NSFont(name: "ArialMT", size: 1000)) as CTFont
        let widths = (32...126).map { code -> String in
            var character = UniChar(code), glyph = CGGlyph(), advance = CGSize()
            _ = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            return String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), advance.width)
        }.joined(separator: " ")
        let content = "BT /F1 16 Tf 1 0 0 1 40 260 Tm (First) Tj ET\n"
            + "BT /F1 16 Tf 1 0 0 1 40 247 Tm (Middle) Tj ET\n"
            + "BT /F1 16 Tf 1 0 0 1 40 234 Tm (Last) Tj ET\n"
        return try XCTUnwrap(PDFDocument(data: PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /TrueType /BaseFont /ArialMT /FirstChar 32 /LastChar 126 /Widths [\(widths)] /Encoding /WinAnsiEncoding /FontDescriptor 6 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /FontDescriptor /FontName /ArialMT /Flags 32 /FontBBox [-1000 -1000 2000 2000] /ItalicAngle 0 /Ascent \(CTFontGetAscent(font)) /Descent \(-CTFontGetDescent(font)) /CapHeight \(CTFontGetCapHeight(font)) /StemV 80 >>"
        ])))
    }

    private func baseline(of phrase: String, on source: PDFPage) throws -> CGFloat {
        let data = try PDFBodyTextPageSnapshot.data(for: source)
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0)); defer { FPDF_ClosePage(page) }
            let textPage = try XCTUnwrap(FPDFText_LoadPage(page)); defer { FPDFText_ClosePage(textPage) }
            var text = "", indices: [Int32] = []
            for index in 0..<FPDFText_CountChars(textPage) {
                guard let scalar = UnicodeScalar(FPDFText_GetUnicode(textPage, index)) else { continue }
                text.unicodeScalars.append(scalar)
                indices.append(contentsOf: repeatElement(index, count: String(scalar).utf16.count))
            }
            let range = (text as NSString).range(of: phrase)
            XCTAssertNotEqual(range.location, NSNotFound)
            guard range.location != NSNotFound else { throw NSError(domain: "TightLeadingBaseline", code: 1) }
            var x = 0.0, y = 0.0
            XCTAssertNotEqual(FPDFText_GetCharOrigin(textPage, indices[range.location], &x, &y), 0)
            return CGFloat(y)
        }
    }

    private func germanSelection(on page: PDFPage, year: String) throws -> PDFSelection {
        let text = try XCTUnwrap(page.string) as NSString
        let start = text.range(of: "alte Tribüne, deren Holzpfeiler die Sicht")
        XCTAssertNotEqual(start.location, NSNotFound)
        let end = text.range(of: "stieg \(year) mit Ausnahme der Grund-", options: [],
                             range: NSRange(location: start.location, length: text.length - start.location))
        XCTAssertNotEqual(end.location, NSNotFound)
        return try XCTUnwrap(page.selection(for: NSRange(location: start.location, length: NSMaxRange(end) - start.location)))
    }

    // Captured from the unchanged original source target before any replacement
    // in diagnostic-r2.jsonl, whose source SHA is checked above. Never output-derived.
    private let originalMasks: [[CGFloat]] = [
        [357.29998779296875, 383.1705780029297, 506.5013952255249, 394.51754264831544],
        [357.1000061035156, 372.2957763671875, 506.5013952255249, 383.1705780029297],
        [357.1000061035156, 361.18658447265625, 506.5013952255249, 372.2957763671875],
        [357.1000061035156, 350.00000495910643, 506.5013952255249, 361.18658447265625]
    ]

    private func pixelsOutsideOriginalMasks(_ page: PDFPage) throws -> Data {
        let box = page.bounds(for: .mediaBox), scale: CGFloat = 2
        let width = Int(ceil(box.width * scale)), height = Int(ceil(box.height * scale))
        var data = Data(repeating: 255, count: width * height * 4)
        try data.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale); context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        for mask in originalMasks {
            let left = max(0, Int(floor(mask[0] * scale))), right = min(width, Int(ceil(mask[2] * scale)))
            let bottom = max(0, Int(floor(mask[1] * scale))), top = min(height, Int(ceil(mask[3] * scale)))
            for y in bottom..<top {
                let offset = ((height - y - 1) * width + left) * 4
                data.replaceSubrange(offset..<offset + (right - left) * 4,
                                     with: repeatElement(UInt8(255), count: (right - left) * 4))
            }
        }
        return data
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
    }
}
