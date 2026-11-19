// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import CryptoKit
import PDFKit
import ObjectiveC
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextSourcePreservationTests: XCTestCase {
    private let firstShow = "[(Keep) -43 (First)] TJ"
    private let lastShow = "[(Keep) 27 (Last)] TJ"

    func testTextOnlyMiddleRowEditRetainsUntouchedOperatorsAndPixelsWithoutDuplicateText() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let original = try PDFBodyTextPageSnapshot.contentData(for: page)
        let target = try paragraph(in: source)
        XCTAssertEqual(target.text.components(separatedBy: "\n").count, 3)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "ChangeMe", with: "Replaced"),
            style: target.style, bounds: target.bounds)
        let content = String(decoding: try PDFBodyTextPageSnapshot.contentData(for: edited), as: UTF8.self)
        XCTAssertTrue(content.contains(firstShow))
        XCTAssertTrue(content.contains(lastShow))
        XCTAssertFalse(content.contains("(ChangeMe)"))
        for y: CGFloat in [260, 212] {
            XCTAssertEqual(try pixels(page, y: y), try pixels(edited, y: y))
        }
        let reopened = try reopen(edited)
        for phrase in ["KeepFirst", "KeepLast", "Replaced"] {
            XCTAssertEqual(reopened.findString(phrase, withOptions: []).count, 1,
                           "Retained rows must not also occur in the donor's searchable text.")
        }
        XCTAssertTrue(reopened.findString("ChangeMe", withOptions: []).isEmpty)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), original)
        try export(source, name: "source-rows-before")
        try export(reopened, name: "source-rows-after")
    }

    func testExplicitFormattingAndReflowUseWholeReplacement() throws {
        for reflow in [false, true] {
            let source = try fixture()
            let page = try XCTUnwrap(source.page(at: 0))
            let target = try paragraph(in: source)
            var style = target.style
            if !reflow { style.fontSize += 1 }
            let replacement = reflow ? "Changed words wrap" : "Replaced"
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: target.text.replacingOccurrences(of: "ChangeMe", with: replacement),
                style: style, bounds: target.bounds)
            let content = String(decoding: try PDFBodyTextPageSnapshot.contentData(for: edited), as: UTF8.self)
            XCTAssertFalse(content.contains(firstShow))
            XCTAssertFalse(content.contains(lastShow))
            let reopened = try reopen(edited)
            XCTAssertEqual(reopened.findString("KeepFirst", withOptions: []).count, 1)
            XCTAssertEqual(reopened.findString("KeepLast", withOptions: []).count, 1)
        }
    }

    func testRetainingEarlierRowsUsesTheChangedRowsOwnGraphicsTransform() throws {
        let source = try fixture(translatedMiddle: true)
        let page = try XCTUnwrap(source.page(at: 0)), target = try paragraph(in: source)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "ChangeMe", with: "Replaced"),
            style: target.style, bounds: target.bounds)
        let reopened = try reopen(edited)
        let selection = try XCTUnwrap(reopened.findString("Replaced", withOptions: []).first)
        let replacement = try XCTUnwrap(PDFBodyTextEditor.target(on: XCTUnwrap(reopened.page(at: 0)), selection: selection))
        XCTAssertEqual(replacement.baseline.x, 40, accuracy: 0.05)
        XCTAssertEqual(replacement.baseline.y, 236, accuracy: 0.05)
        let content = String(decoding: try PDFBodyTextPageSnapshot.contentData(for: edited), as: UTF8.self)
        XCTAssertTrue(content.contains(firstShow)); XCTAssertTrue(content.contains(lastShow))
    }

    func testDisjointChangesReemitInteriorRowsToKeepSearchAndCopyReadingOrder() throws {
        let source = try fixture(fourthLine: true)
        let page = try XCTUnwrap(source.page(at: 0)), target = try paragraph(in: source, through: "ChangeLast")
        let revised = target.text.replacingOccurrences(of: "ChangeMe", with: "Replaced")
            .replacingOccurrences(of: "ChangeLast", with: "LastEdited")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: revised, style: target.style, bounds: target.bounds)
        let content = String(decoding: try PDFBodyTextPageSnapshot.contentData(for: edited), as: UTF8.self)
        XCTAssertTrue(content.contains(firstShow))
        XCTAssertFalse(content.contains(lastShow), "The unchanged interior row belongs in the contiguous donor span.")
        let reopened = try reopen(edited)
        let extracted = try XCTUnwrap(reopened.string) as NSString
        let order = ["KeepFirst", "Replaced", "KeepLast", "LastEdited"].map { extracted.range(of: $0).location }
        XCTAssertFalse(order.contains(NSNotFound)); XCTAssertEqual(order, order.sorted())
        for phrase in ["KeepFirst", "Replaced", "KeepLast", "LastEdited"] {
            XCTAssertEqual(reopened.findString(phrase, withOptions: []).count, 1)
        }
        try export(source, name: "disjoint-rows-before")
        try export(reopened, name: "disjoint-rows-after")
    }

    func testWholeParagraphCanBeReselectedAndEditedAfterRowPreservationBeforeAndAfterSave() throws {
        let source = try fixture(), originalPage = try XCTUnwrap(source.page(at: 0))
        let original = try paragraph(in: source)
        let first = try PDFBodyTextEditor.replacementPage(for: originalPage, target: original,
            text: original.text.replacingOccurrences(of: "ChangeMe", with: "Replaced"),
            style: original.style, bounds: original.bounds)
        let live = PDFDocument(); live.insert(first, at: 0)
        let saved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(live.dataRepresentation())))
        for document in [live, saved] {
            let page = try XCTUnwrap(document.page(at: 0)), target = try paragraph(in: document)
            XCTAssertEqual(target.text.components(separatedBy: "\n").count, 3)
            XCTAssertTrue(target.text.contains("Replaced"))
            let second = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: target.text.replacingOccurrences(of: "Replaced", with: "Again"),
                style: target.style, bounds: target.bounds)
            let reopened = try reopen(second)
            XCTAssertEqual(reopened.findString("Again", withOptions: []).count, 1)
            XCTAssertTrue(reopened.findString("Replaced", withOptions: []).isEmpty)
            XCTAssertEqual(reopened.findString("KeepFirst", withOptions: []).count, 1)
            XCTAssertEqual(reopened.findString("KeepLast", withOptions: []).count, 1)
            XCTAssertNotNil(try paragraph(in: reopened))
            try export(reopened, name: document === live ? "mixed-paragraph-live-reedited" : "mixed-paragraph-saved-reedited")
        }
    }


    /// A real first edit creates the own Form; no marker or proof is injected.
    /// This checks declared clearance separately from font-fit acceptance.
    func testMixedOwnFormDoesNotShrinkBlankClearanceAcrossTwoAtomicColdReopens() async throws {
        let source = try fixture(), originalPage = try XCTUnwrap(source.page(at: 0))
        let originalBytes = try PDFBodyTextPageSnapshot.data(for: originalPage)
        let initial = try paragraph(in: source), extent = initial.paintBounds
        XCTAssertEqual(extent, originalPage.bounds(for: .mediaBox))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmberMixedClearance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed = false
        defer {
            if completed { try? FileManager.default.removeItem(at: folder) }
            else { print("EMBER_MIXED_CLEARANCE_FAILED_OUTPUTS", folder.path) }
        }
        var current = source
        for (cycle, pair) in [("ChangeMe", "ChangeMx"), ("ChangeMx", "ChangeMe")].enumerated() {
            let page = try XCTUnwrap(current.page(at: 0)), selected = try paragraph(in: current)
            XCTAssertEqual(selected.paintBounds, extent, "A selected own text Form cannot become another-paint obstacle.")
            let changed = selected.text.replacingOccurrences(of: pair.0, with: pair.1)
            XCTAssertNotEqual(changed, selected.text)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: changed, style: selected.style, bounds: selected.bounds)
            let raw = String(decoding: try PDFBodyTextPageSnapshot.contentData(for: edited), as: UTF8.self)
            if cycle == 0 {
                XCTAssertTrue(raw.contains(firstShow)); XCTAssertTrue(raw.contains(lastShow))
                XCTAssertFalse(raw.contains("(ChangeMe)"))
                let snapshot = try PDFBodyTextPageSnapshot.data(for: edited)
                XCTAssertNotNil(snapshot.range(of: Data("/EmberPDFBodyText true".utf8)))
                // The first donor affects only the middle row. These retained
                // rows must keep their original pixels as well as raw shows.
                for y: CGFloat in [260, 212] { XCTAssertEqual(try pixels(edited, y: y), try pixels(originalPage, y: y)) }
            }
            let live = PDFDocument(); live.insert(edited, at: 0)
            let snapshot = try PDFRecoverySnapshot(capturing: live)
            let destination = folder.appendingPathComponent("cycle-\(cycle + 1).pdf")
            _ = try await Task.detached { try AtomicPDFWriter.write(snapshot.takeDocument(), to: destination) }.value
            PDFBodyTextDocumentFonts.invalidate(current); PDFBodyTextDocumentFonts.invalidate(live)
            current = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: destination)))
            let reopened = try paragraph(in: current)
            XCTAssertEqual(reopened.paintBounds, extent)
            let extracted = try XCTUnwrap(current.string) as NSString
            let positions = ["KeepFirst", pair.1, "KeepLast"].map { extracted.range(of: $0).location }
            XCTAssertFalse(positions.contains(NSNotFound)); XCTAssertEqual(positions, positions.sorted())
            for phrase in ["KeepFirst", pair.1, "KeepLast"] { XCTAssertEqual(current.findString(phrase, withOptions: []).count, 1) }
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: originalPage), originalBytes)
        completed = (testRun?.totalFailureCount ?? 0) == 0
    }

    func testMixedOwnMarkerWithPaintedSiblingOrRepeatedInvocationCannotGrantClearance() throws {
        for variant in ["painted-child", "repeated-invocation"] {
            let body = "BT /F1 16 Tf 1 0 0 1 40 236 Tm (ChangeMe) Tj ET\n"
                + (variant == "painted-child" ? "0.8 g 25 220 170 34 re f\n" : "")
            let content = "BT /F1 16 Tf 1 0 0 1 40 260 Tm \(firstShow) ET\n/Owned Do\n"
                + "BT /F1 16 Tf 1 0 0 1 40 212 Tm \(lastShow) ET\n"
                + (variant == "repeated-invocation" ? "q 1 0 0 1 0 -80 cm /Owned Do Q\n" : "")
            let bytes = PDFMalformedSelectionTestFixture.pdfData(objects: [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> /XObject << /Owned 6 0 R >> >> /Contents 5 0 R >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
                "<< /Type /XObject /Subtype /Form /EmberPDFBodyText true /BBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
            ])
            let document = try XCTUnwrap(PDFDocument(data: bytes)), page = try XCTUnwrap(document.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            let selection = try paragraphSelection(in: document)
            do {
                XCTAssertNil(try PDFBodyTextEditor.target(on: page, selection: selection), variant)
            } catch { /* Explicit refusal is valid; a marker never proves safe leaves or unique use. */ }
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before, variant)
        }
    }

    func testMixedParagraphWithAnUnownedFormStillRefusesSelection() throws {
        let source = try fixture(), page = try XCTUnwrap(source.page(at: 0)), target = try paragraph(in: source)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "ChangeMe", with: "Replaced"),
            style: target.style, bounds: target.bounds)
        var bytes = try PDFBodyTextPageSnapshot.data(for: edited)
        let marker = try XCTUnwrap(bytes.range(of: Data("/EmberPDFBodyText true".utf8)))
        // Preserve xref offsets while removing our ownership declaration.
        bytes.replaceSubrange(marker, with: Data("/OtherPDFBodyText true".utf8))
        let unowned = try XCTUnwrap(PDFDocument(data: bytes)), unownedPage = try XCTUnwrap(unowned.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: unownedPage)
        let selection = try paragraphSelection(in: unowned)
        do {
            let target = try PDFBodyTextEditor.target(on: unownedPage, selection: selection)
            XCTAssertNil(target)
        }
        catch { /* An unsupported-structure refusal also preserves the gate. */ }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: unownedPage), before)
    }

    func testUninstalledEmbeddedTrueTypeFaceIsUsedByPreviewAndSavedReplacement() throws {
        let name = "EmberMemory" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        XCTAssertNil(NSFont(name: name, size: 16))
        let program = try renamedTrueType(name)
        let source = try fixture(fontProgram: program, name: name)
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try paragraph(in: source)
        XCTAssertEqual(target.style.font.fontName, name)
        let memoryGlyf = CTFontCopyTable(target.style.font as CTFont, CTFontTableTag(kCTFontTableGlyf), []) as Data?
        let provider = try XCTUnwrap(CGDataProvider(data: program as CFData))
        let expected = CTFontCreateWithGraphicsFont(try XCTUnwrap(CGFont(provider)), 16, nil, nil)
        XCTAssertEqual(memoryGlyf, CTFontCopyTable(expected, CTFontTableTag(kCTFontTableGlyf), []) as Data?)
        let changed = target.text.replacingOccurrences(of: "ChangeMe", with: "Replaced")
        let preview = PDFBodyTextAttributedLayout.attributedString(text: changed, style: target.style,
            sourceText: target.text, sourceStyle: target.style, sourceRuns: target.sourceRuns)
        XCTAssertEqual((preview.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName, name)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: changed, style: target.style, bounds: target.bounds)
        let reopened = try reopen(edited)
        let selection = try XCTUnwrap(reopened.findString("Replaced", withOptions: []).first)
        let saved = try XCTUnwrap(PDFBodyTextEditor.target(on: XCTUnwrap(reopened.page(at: 0)), selection: selection))
        XCTAssertEqual(saved.style.font.fontName.split(separator: "+").last.map(String.init), name)
        XCTAssertEqual(reopened.findString("Replaced", withOptions: []).count, 1)
        try export(source, name: "embedded-face-before")
        try export(reopened, name: "embedded-face-after")
    }

    func testEditableEmbeddedFontObjectSurvivesStyleCopyNormalizeAndPreviewZoomWithoutRegistration() throws {
        let name = "EmberEditable" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let program = try renamedTrueType(name, embeddingFlags: 0x0008)
        let source = try fixture(fontProgram: program, name: name), target = try paragraph(in: source)
        let lease = try XCTUnwrap(target.style.sourceFont, "A real fsType8/cmap face must be admitted.")
        XCTAssertTrue(lease.isValid(for: source)); XCTAssertNil(NSFont(name: name, size: 16))
        let expected = CTFontCreateWithGraphicsFont(try XCTUnwrap(CGFont(XCTUnwrap(CGDataProvider(data: program as CFData)))), 16, nil, nil)
        XCTAssertEqual(CTFontCopyTable(target.style.font as CTFont, CTFontTableTag(kCTFontTableGlyf), []) as Data?,
                       CTFontCopyTable(expected, CTFontTableTag(kCTFontTableGlyf), []) as Data?)
        var copied = target.style; copied.fontSize = 18; copied.normalize()
        XCTAssertEqual(copied.sourceFont, lease)
        let zoomed = copied.renderingFont(copied.font, size: 36)
        try assertSameGlyphs("KeepFirstChangeMeKeepLast", expected: expected, actual: zoomed as CTFont,
                            compareAtSize: 16)
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 246))
        panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: target.bounds,
            isEditingExistingAnnotation: false, purpose: .bodyText, text: target.text, style: target.style,
            bodyTextSourceText: target.text, bodyTextSourceStyle: target.style, bodyTextSourceRuns: target.sourceRuns))
        XCTAssertEqual(panel.currentStyle.sourceFont, lease)
        var explicit = panel.currentStyle; explicit.fontName = "Helvetica"
        XCTAssertNil(explicit.sourceFont)
        XCTAssertEqual(explicit.font.fontName, "Helvetica", "Changing the name takes effect before normalize.")
        explicit.normalize()
        XCTAssertNil(explicit.sourceFont, "Choosing an installed face must opt out of the private program.")
        XCTAssertEqual(explicit.font.fontName, "Helvetica")
        XCTAssertNil(NSFont(name: name, size: 16), "No process-wide registration may appear.")
    }

    func testEditableSameNameDifferentProgramsRemainDistinctWithinOneAttributedParagraph() throws {
        let name = "EmberTwin" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let a = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0x0008), name: name)
        let b = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0x0008, adjustKAdvanceBy: 64), name: name)
        let left = try paragraph(in: a).style, right = try paragraph(in: b).style
        let leftLease = try XCTUnwrap(left.sourceFont), rightLease = try XCTUnwrap(right.sourceFont)
        XCTAssertNotEqual(leftLease, rightLease); XCTAssertEqual(left.fontName, right.fontName)
        let leftWidth = try glyphAdvance("K", font: left.font as CTFont)
        let rightWidth = try glyphAdvance("K", font: right.font as CTFont)
        XCTAssertGreaterThan(rightWidth, leftWidth)
        let result = PDFBodyTextAttributedLayout.attributedString(text: "KK", style: left,
            sourceText: "KK", sourceStyle: left, sourceRuns: [
                .init(range: NSRange(location: 0, length: 1), style: left),
                .init(range: NSRange(location: 1, length: 1), style: right)])
        let first = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let second = try XCTUnwrap(result.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(try glyphAdvance("K", font: first as CTFont), leftWidth, accuracy: 0.0001)
        XCTAssertEqual(try glyphAdvance("K", font: second as CTFont), rightWidth, accuracy: 0.0001)
        XCTAssertNil(NSFont(name: name, size: 16))
    }

    func testEditableOneCharacterEditKeepsUnchangedGlyphsInsideTheEditedRow() throws {
        let name = "EmberPixels" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0x0008), name: name)
        let page = try XCTUnwrap(source.page(at: 0)), target = try paragraph(in: source)
        _ = try XCTUnwrap(target.style.sourceFont)
        let sourceFont = target.style.font as CTFont
        XCTAssertEqual(try glyphAdvance("a", font: sourceFont), try glyphAdvance("e", font: sourceFont), accuracy: 0.0001)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "ChangeMe", attributes: [.font: sourceFont]))
        let x = 40 + CTLineGetOffsetForStringIndex(line, 2, nil)
        // Captured before mutation: only the changed a/e cell, never the row.
        let changedCell = CGRect(x: x, y: 232, width: try glyphAdvance("a", font: sourceFont), height: 22)
        let text = target.text.replacingOccurrences(of: "ChangeMe", with: "ChengeMe")
        let preview = PDFBodyTextAttributedLayout.attributedString(text: text, style: target.style,
            sourceText: target.text, sourceStyle: target.style, sourceRuns: target.sourceRuns)
        let range = (text as NSString).range(of: "ChengeMe")
        let font = try XCTUnwrap(preview.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        try assertSameGlyphs("ChngeMe", expected: sourceFont, actual: font as CTFont)
        let originalContent = try PDFBodyTextPageSnapshot.contentData(for: page)
        let before = try pixels(page, y: 236)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target, text: text,
            style: target.style, bounds: target.bounds)
        let after = try pixels(edited, y: 236)
        XCTAssertEqual(before.count, after.count)
        var checked = 0, mismatched = 0
        var firstMismatches: [Int] = []
        for y in 0..<22 { for x in 0..<400 {
            if CGRect(x: x, y: 232 + y, width: 1, height: 1).intersects(changedCell) { continue }
            let offset = (y * 400 + x) * 4
            if before.subdata(in: offset..<(offset + 4)) != after.subdata(in: offset..<(offset + 4)) {
                mismatched += 1
                if firstMismatches.count < 8 { firstMismatches.append(y * 400 + x) }
            }
            checked += 1
        }}
        XCTAssertGreaterThan(checked, 8_000, "A whole-line mask would make this oracle vacuous.")
        if mismatched > 0,
           let directory = ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_QA_DIRECTORY"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (label, image, imagePage) in [("before", before, page), ("after", after, edited)] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400,
                    pixelsHigh: 22, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 1600, bitsPerPixel: 32))
                image.copyBytes(to: try XCTUnwrap(bitmap.bitmapData), count: image.count)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("editable-cell-\(label).png"))
                try PDFBodyTextPageSnapshot.originalPageData(for: imagePage)
                    .write(to: folder.appendingPathComponent("editable-cell-\(label).pdf"))
            }
        }
        XCTAssertEqual(mismatched, 0, "Changed pixels outside predeclared changed cell: \(firstMismatches)")
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), originalContent)
    }

    func testCompressionDoesNotLoseAnEditableEmbeddedProgramToAQuartzSubset() throws {
        let name = "EmberCompress" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let program = try renamedTrueType(name, embeddingFlags: 0x0008)
        let source = try fixture(fontProgram: program, name: name)
        let target = try paragraph(in: source)
        _ = try XCTUnwrap(target.style.sourceFont)
        let licensing = try XCTUnwrap(CTFontCopyTable(target.style.font as CTFont,
            CTFontTableTag(kCTFontTableOS2), []) as Data?)
        XCTAssertGreaterThanOrEqual(licensing.count, 10)
        XCTAssertEqual(UInt16(licensing[8]) << 8 | UInt16(licensing[9]), 0x0008)
        let page = try XCTUnwrap(source.page(at: 0))
        let originalContent = try PDFBodyTextPageSnapshot.contentData(for: page)
        // The source-only native writer retains the full, approved FontFile2.
        // Do not create the compression input through the lossy SDK serializer.
        let input = try PDFBodyTextPageSnapshot.originalPageData(for: page)
        let raw = try XCTUnwrap(PDFDocument(data: input))
        let sdkSubset = try XCTUnwrap(raw.dataRepresentation())
        XCTAssertLessThan(sdkSubset.count, input.count,
                          "Fixture must exercise the real smaller SDK rewrite, not an already-small file.")
        let result = try PDFCompressionService.compress(data: input, quality: .balanced)
        XCTAssertFalse(result.didReduce,
                       "A smaller unlicensed subset is not an acceptable image-compression result.")
        XCTAssertEqual(result.data, input)
        XCTAssertEqual(result.originalBytes, input.count)
        XCTAssertEqual(result.compressedBytes, input.count)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), originalContent)
        XCTAssertNil(NSFont(name: name, size: 16))
    }

    func testEditableFontFreshSavedSubsetMustRetainPermissionAndGlyphIdentityForTwoReopens() throws {
        let name = "EmberReopen" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var source = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0x0008), name: name)
        var target = try paragraph(in: source)
        let expected = target.style.font as CTFont
        _ = try XCTUnwrap(target.style.sourceFont)
        let directDirectory = ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_QA_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true)
                .appendingPathComponent("editable-direct-" + UUID().uuidString, isDirectory: true) }
        if let directDirectory {
            try FileManager.default.createDirectory(at: directDirectory, withIntermediateDirectories: true)
        }
        var diagnosticBytes = 0
        for (index, change) in [("ChangeMe", "ChengeMe"), ("ChengeMe", "ChangeMe")].enumerated() {
            let (old, new) = change
            let page = try XCTUnwrap(source.page(at: 0))
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: target.text.replacingOccurrences(of: old, with: new), style: target.style, bounds: target.bounds)
            PDFBodyTextDocumentFonts.invalidate(source)
            // Serialize exactly once, as reopen(_:) did. Export that same Data;
            // no extra page/font getter or alternate writer runs before it.
            let direct = PDFDocument(); direct.insert(edited, at: 0)
            let directData = try XCTUnwrap(direct.dataRepresentation())
            if let directDirectory {
                let digest = SHA256.hash(data: directData).map { String(format: "%02x", $0) }.joined()
                let retained = directData.count <= 8 * 1_024 * 1_024 - diagnosticBytes
                fputs("EDITABLE_DIRECT cycle=\(index) bytes=\(directData.count) sha256=\(digest) retained=\(retained)\n", stderr)
                if retained {
                    try directData.write(to: directDirectory.appendingPathComponent("direct-cycle-\(index).pdf"))
                    diagnosticBytes += directData.count
                }
            }
            source = try XCTUnwrap(PDFDocument(data: directData))
            target = try paragraph(in: source)
            let text = target.text as NSString
            let changedRuns = target.sourceRuns.filter { text.substring(with: $0.range).contains(new) }
            XCTAssertFalse(changedRuns.isEmpty)
            for run in changedRuns {
                _ = try XCTUnwrap(run.style.sourceFont,
                    "Missing OS/2 in a fresh generated subset must remain a visible failure, never name-authorized.")
                try assertSameGlyphs("ChngeMe", expected: expected, actual: run.style.font as CTFont)
            }
            XCTAssertEqual(source.findString(new, withOptions: []).count, 1)
            XCTAssertNil(NSFont(name: name, size: 16))
        }
    }

    /// Production snapshot + atomic writer, distinct from the intentionally
    /// strict direct PDFKit dataRepresentation roundtrip above. Re-select only
    /// the changed row after a fresh open; never prewarm an untouched font row.
    func testEditableFontAtomicWriterSurvivesTwoFreshReopensWithoutUntouchedRowPrewarming() async throws {
        let name = "EmberAtomic" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var source = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0x0008), name: name)
        var target = try paragraph(in: source)
        let expected = target.style.font as CTFont
        _ = try XCTUnwrap(target.style.sourceFont)
        let retainedRowPixels = try [CGFloat(260), 212].map { try pixels(XCTUnwrap(source.page(at: 0)), y: $0) }
        let retained = ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_QA_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("editable-atomic-" + UUID().uuidString) }
        let directory = retained ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if retained == nil { try? FileManager.default.removeItem(at: directory) } }
        for (index, change) in [("ChangeMe", "ChengeMe"), ("ChengeMe", "ChangeMe")].enumerated() {
            let (old, new) = change, page = try XCTUnwrap(source.page(at: 0))
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: target.text.replacingOccurrences(of: old, with: new), style: target.style, bounds: target.bounds)
            let live = PDFDocument(); live.insert(edited, at: 0)
            let snapshot = try PDFRecoverySnapshot(capturing: live)
            let destination = directory.appendingPathComponent("atomic-cycle-\(index).pdf")
            try await Task.detached {
                XCTAssertFalse(Thread.isMainThread)
                try AtomicPDFWriter.write(snapshot.takeDocument(), to: destination)
            }.value
            PDFBodyTextDocumentFonts.invalidate(source)
            PDFBodyTextDocumentFonts.invalidate(live)
            source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: destination)))
            let savedPage = try XCTUnwrap(source.page(at: 0))
            let selected = try XCTUnwrap(source.findString(new, withOptions: []).first)
            target = try XCTUnwrap(PDFBodyTextEditor.target(on: savedPage, selection: selected))
            XCTAssertLessThan(target.paintBounds.height, savedPage.bounds(for: .mediaBox).height,
                              "Reselecting the changed row cannot retain the former paragraph's page-wide clearance.")
            for (row, y) in [CGFloat(260), 212].enumerated() {
                XCTAssertEqual(try pixels(savedPage, y: y), retainedRowPixels[row])
            }
            let text = target.text as NSString
            let editedRuns = target.sourceRuns.filter { text.substring(with: $0.range).contains(new) }
            XCTAssertFalse(editedRuns.isEmpty)
            for run in editedRuns {
                _ = try XCTUnwrap(run.style.sourceFont,
                    "A retained source font needs bounded same-document admission, not hidden UI preselection.")
                try assertSameGlyphs("ChngeMe", expected: expected, actual: run.style.font as CTFont)
            }
            XCTAssertEqual(source.findString(new, withOptions: []).count, 1)
            XCTAssertEqual(source.findString("KeepFirst", withOptions: []).count, 1)
            XCTAssertEqual(source.findString("KeepLast", withOptions: []).count, 1)
            XCTAssertNil(NSFont(name: name, size: 16))
        }
    }

    func testCopyFailureFallbackRetainsEditableProgramThroughExtractAppendAndTwoColdSaves() async throws {
        let name = "EmberCopyFallback" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let program = try renamedTrueType(name, embeddingFlags: 0x0008)
        let programDigest = Data(SHA256.hash(data: program))
        var source = try fixture(fontProgram: program, name: name)
        var target = try paragraph(in: source)
        let expectedFont = target.style.font as CTFont
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (cycle, change) in [("ChangeMe", "ChengeMe"), ("ChengeMe", "ChangeMe")].enumerated() {
            let (before, after) = change
            let page = try XCTUnwrap(source.page(at: 0))
            let retained = try [CGFloat(260), 212].map { try pixels(page, y: $0) }
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: target.text.replacingOccurrences(of: before, with: after),
                style: target.style, bounds: target.bounds)
            let snapshotData = try PDFBodyTextPageSnapshot.originalPageData(for: edited)
            let failing = try fallbackCopyFixture(data: snapshotData)
            let order = try XCTUnwrap(failing.document.string)
            let ordinary = try ordinaryCopyOrders(data: snapshotData)
            XCTAssertEqual(ordinary.source, order)
            let content = try PDFBodyTextPageSnapshot.contentData(for: failing.page)
            let callsBeforeExtract = failing.state.calls
            let extracted = try PDFPageOperations.extract(from: failing.document, indexes: [0])
            XCTAssertGreaterThan(failing.state.calls, callsBeforeExtract,
                "The real extraction must invoke the refusing page's NSCopying path.")
            let callsBeforeAppend = failing.state.calls
            let merged = PDFDocument()
            XCTAssertEqual(try PDFPageOperations.append(contentsOf: failing.document, to: merged), 1)
            XCTAssertGreaterThan(failing.state.calls, callsBeforeAppend,
                "The real append path must independently reach the same fallback.")
            // Exact ordinary-NSCopy baseline: live insertion changes PDFKit
            // extraction context even though raw contents and cold text agree.
            for (output, expectedLiveOrder) in zip([extracted, merged], [ordinary.extracted, ordinary.appended]) {
                let outputPage = try XCTUnwrap(output.page(at: 0))
                XCTAssertFalse(outputPage === failing.page)
                XCTAssertEqual(output.string, expectedLiveOrder)
                XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: outputPage), content)
                XCTAssertEqual(try fallbackFontProgramDigests(on: outputPage), [programDigest])
                for (row, y) in [CGFloat(260), 212].enumerated() {
                    XCTAssertEqual(try pixels(outputPage, y: y), retained[row])
                }
            }
            // Exercise both downstream assembled graphs, without a second SDK
            // dataRepresentation boundary or an untouched-font prewarm.
            let live = cycle == 0 ? extracted : merged
            let snapshot = try PDFRecoverySnapshot(capturing: live)
            let destination = directory.appendingPathComponent("fallback-cycle-\(cycle).pdf")
            _ = try await Task.detached { try AtomicPDFWriter.write(snapshot.takeDocument(), to: destination) }.value
            PDFBodyTextDocumentFonts.invalidate(source)
            PDFBodyTextDocumentFonts.invalidate(live)
            source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: destination)))
            let savedPage = try XCTUnwrap(source.page(at: 0))
            XCTAssertEqual(source.string, order)
            XCTAssertEqual(try fallbackFontProgramDigests(on: savedPage), [programDigest])
            let selection = try XCTUnwrap(source.findString(after, withOptions: []).first)
            target = try XCTUnwrap(PDFBodyTextEditor.target(on: savedPage, selection: selection))
            let text = target.text as NSString
            let changed = target.sourceRuns.filter { text.substring(with: $0.range).contains(after) }
            XCTAssertFalse(changed.isEmpty)
            for run in changed {
                _ = try XCTUnwrap(run.style.sourceFont)
                let os2 = try XCTUnwrap(CTFontCopyTable(run.style.font as CTFont, CTFontTableTag(kCTFontTableOS2), []) as Data?)
                XCTAssertGreaterThanOrEqual(os2.count, 10)
                XCTAssertEqual(UInt16(os2[8]) << 8 | UInt16(os2[9]), 0x0008)
                try assertSameGlyphs("ChngeMe", expected: expectedFont, actual: run.style.font as CTFont)
            }
            XCTAssertEqual(source.findString(after, withOptions: []).count, 1)
            XCTAssertEqual(source.findString(before, withOptions: []).count, 0)
            XCTAssertNil(NSFont(name: name, size: 16))
            withExtendedLifetime(failing.delegate) {}
        }
    }

    func testCopyReturningSelfUsesIndependentFallbackWithExactGeometryAndContent() throws {
        let source = try fixture()
        let snapshotData = try PDFBodyTextPageSnapshot.originalPageData(for: XCTUnwrap(source.page(at: 0)))
        let failing = try fallbackCopyFixture(data: snapshotData)
        failing.state.returnsSelf = true
        failing.page.rotation = 90
        failing.page.setBounds(CGRect(x: 5.25, y: 7.5, width: 380.5, height: 281.25), for: .cropBox)
        let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        let geometry = boxes.map { failing.page.bounds(for: $0) }
        let content = try PDFBodyTextPageSnapshot.contentData(for: failing.page)
        let order = failing.document.string
        let ordinary = try ordinaryCopyOrders(data: snapshotData) { page in
            page.rotation = 90
            page.setBounds(CGRect(x: 5.25, y: 7.5, width: 380.5, height: 281.25), for: .cropBox)
        }
        XCTAssertEqual(ordinary.source, order)
        let copied = try XCTUnwrap(PDFPageOperations.detachedCopy(of: failing.page))
        XCTAssertGreaterThan(failing.state.calls, 0)
        XCTAssertFalse(copied === failing.page)
        XCTAssertEqual(copied.rotation, 90)
        XCTAssertEqual(boxes.map { copied.bounds(for: $0) }, geometry)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: copied), content)
        let output = PDFDocument(); output.insert(copied, at: 0)
        XCTAssertEqual(output.string, ordinary.directInserted)
        let cold = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.originalPageData(for: copied)))
        XCTAssertEqual(cold.string, order)
        copied.rotation = 180
        XCTAssertEqual(failing.page.rotation, 90)
        XCTAssertEqual(boxes.map { failing.page.bounds(for: $0) }, geometry)
        withExtendedLifetime(failing.delegate) {}
    }

    func testAnnotatedCopyFailureLeavesExtractAndAppendAtomicIncludingWidgets() throws {
        for widget in [false, true] {
            let source = try fixture()
            let failing = try fallbackCopyFixture(data: PDFBodyTextPageSnapshot.originalPageData(for: XCTUnwrap(source.page(at: 0))))
            failing.state.returnsSelf = widget
            let type: PDFAnnotationSubtype = widget ? .widget : .link
            let annotation = PDFAnnotation(bounds: CGRect(x: 12, y: 12, width: 20, height: 15), forType: type, withProperties: nil)
            if widget {
                annotation.widgetFieldType = .text
                annotation.fieldName = "OwnedFallbackField"
                annotation.widgetStringValue = "OwnedValue"
            }
            failing.page.addAnnotation(annotation)
            let content = try PDFBodyTextPageSnapshot.contentData(for: failing.page)
            let order = failing.document.string
            XCTAssertNil(PDFPageOperations.detachedCopy(of: failing.page))
            XCTAssertGreaterThan(failing.state.calls, 0)
            XCTAssertThrowsError(try PDFPageOperations.extract(from: failing.document, indexes: [0]))
            let destination = try fixture()
            let originalPage = try XCTUnwrap(destination.page(at: 0))
            let destinationText = destination.string
            XCTAssertThrowsError(try PDFPageOperations.append(contentsOf: failing.document, to: destination))
            XCTAssertEqual(destination.pageCount, 1)
            XCTAssertTrue(destination.page(at: 0) === originalPage)
            XCTAssertEqual(destination.string, destinationText)
            XCTAssertEqual(failing.document.string, order)
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: failing.page), content)
            XCTAssertTrue(failing.page.annotations.contains { $0 === annotation })
            if widget { XCTAssertEqual(annotation.widgetStringValue, "OwnedValue") }
            withExtendedLifetime(failing.delegate) {}
        }
    }

    func testCopyFailureRefusesNativeAnnotationsHiddenByThePublicPageGetter() throws {
        // This SDK serialization creates only a synthetic native-Annots
        // negative fixture, never an edited-font preservation oracle.
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 12, y: 12, width: 20, height: 15), forType: .link, withProperties: nil))
        let failing = try fallbackCopyFixture(data: XCTUnwrap(source.dataRepresentation()))
        let dictionary = try XCTUnwrap(failing.page.pageRef?.dictionary)
        var nativeAnnotations: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &nativeAnnotations))
        XCTAssertGreaterThan(CGPDFArrayGetCount(try XCTUnwrap(nativeAnnotations)), 0)
        failing.state.hidesAnnotations = true
        XCTAssertTrue(failing.page.annotations.isEmpty)
        XCTAssertNil(PDFPageOperations.detachedCopy(of: failing.page))
        XCTAssertGreaterThan(failing.state.calls, 0)
        XCTAssertEqual(failing.page.pageRef?.dictionary, dictionary)
        withExtendedLifetime(failing.delegate) {}
    }

    // The independent control uses the same bytes and page geometry, without
    // the refusing delegate. No whitespace normalization enters this oracle.
    private func ordinaryCopyOrders(data: Data, configure: (PDFPage) -> Void = { _ in }) throws
        -> (source: String?, directInserted: String?, extracted: String?, appended: String?) {
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        configure(page)
        let sourceOrder = document.string
        let copied = try XCTUnwrap(page.copy() as? PDFPage)
        XCTAssertFalse(copied === page, "The ordinary control must actually return an independent copy.")
        let direct = PDFDocument(); direct.insert(copied, at: 0)
        let directOrder = direct.string
        let extracted = try PDFPageOperations.extract(from: document, indexes: [0])
        let appended = PDFDocument()
        _ = try PDFPageOperations.append(contentsOf: document, to: appended)
        return (sourceOrder, directOrder, extracted.string, appended.string)
    }

    private func fallbackCopyFixture(data: Data) throws -> (document: PDFDocument, delegate: SourcePreservingCopyFailureDelegate,
        page: SourcePreservingCopyFailurePage, state: SourcePreservingCopyFailureState) {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let delegate = SourcePreservingCopyFailureDelegate()
        document.delegate = delegate
        let page = try XCTUnwrap(document.page(at: 0) as? SourcePreservingCopyFailurePage,
            "The SDK classForPage delegate must actually inject the refusing page.")
        let state = SourcePreservingCopyFailureState()
        page.install(state)
        return (document, delegate, page, state)
    }

    private func fallbackFontProgramDigests(on page: PDFPage) throws -> Set<Data> {
        let pageDictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var root: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &root))
        var pending: [(CGPDFDictionaryRef, Int)] = [(try XCTUnwrap(root), 0)]
        var seen = Set<UInt>(), result = Set<Data>(), bytes = 0, valid = true
        while let (resources, depth) = pending.popLast() {
            guard seen.insert(pdfReferenceIdentity(resources)).inserted else { continue }
            guard depth < 8, seen.count <= 32 else { XCTFail("Owned font graph limit"); return [] }
            var fonts: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts {
                guard CGPDFDictionaryGetCount(fonts) <= 32 else { XCTFail("Owned font count limit"); return [] }
                CGPDFDictionaryApplyBlock(fonts, { name, _, _ in
                    var font: CGPDFDictionaryRef?, descriptor: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
                    guard CGPDFDictionaryGetDictionary(fonts, name, &font), let font else { valid = false; return false }
                    var subtype: UnsafePointer<CChar>?
                    guard CGPDFDictionaryGetName(font, "Subtype", &subtype), let subtype else { valid = false; return false }
                    var programFont = font
                    if String(cString: subtype) == "Type0" {
                        var descendants: CGPDFArrayRef?, descendant: CGPDFDictionaryRef?, childSubtype: UnsafePointer<CChar>?
                        guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
                              CGPDFArrayGetCount(descendants) == 1,
                              CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant,
                              CGPDFDictionaryGetName(descendant, "Subtype", &childSubtype), let childSubtype,
                              String(cString: childSubtype) == "CIDFontType2" else { valid = false; return false }
                        programFont = descendant
                    } else if String(cString: subtype) != "TrueType" { valid = false; return false }
                    var alternate: CGPDFObjectRef?
                    var format = CGPDFDataFormat.raw
                    guard CGPDFDictionaryGetDictionary(programFont, "FontDescriptor", &descriptor), let descriptor,
                          !CGPDFDictionaryGetObject(descriptor, "FontFile", &alternate),
                          !CGPDFDictionaryGetObject(descriptor, "FontFile3", &alternate),
                          CGPDFDictionaryGetStream(descriptor, "FontFile2", &stream), let stream,
                          let data = CGPDFStreamCopyData(stream, &format) as Data?,
                          data.count <= 4 * 1_024 * 1_024 - bytes else { valid = false; return false }
                    bytes += data.count; result.insert(Data(SHA256.hash(data: data))); return true
                }, nil)
            }
            var forms: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, "XObject", &forms), let forms {
                guard CGPDFDictionaryGetCount(forms) <= 32 else { XCTFail("Owned Form count limit"); return [] }
                CGPDFDictionaryApplyBlock(forms, { name, _, _ in
                    var stream: CGPDFStreamRef?, child: CGPDFDictionaryRef?
                    guard CGPDFDictionaryGetStream(forms, name, &stream), let stream else { valid = false; return false }
                    guard let dictionary = CGPDFStreamGetDictionary(stream) else { valid = false; return false }
                    if CGPDFDictionaryGetDictionary(dictionary, "Resources", &child), let child { pending.append((child, depth + 1)) }
                    return true
                }, nil)
            }
        }
        XCTAssertTrue(valid)
        XCTAssertFalse(result.isEmpty)
        return result
    }

    func testApprovedEditableProgramTokenRejectsDifferentFontAndInvalidatesWithDocument() throws {
        let name = "EmberToken" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0x0008), name: name)
        let target = try paragraph(in: source), lease = try XCTUnwrap(target.style.sourceFont)
        let token = try XCTUnwrap(lease.approvedProgramToken(for: target.style.font as CTFont))
        XCTAssertTrue(token.isValid)
        XCTAssertNil(lease.approvedProgramToken(for: NSFont.systemFont(ofSize: 16) as CTFont))
        let page = try XCTUnwrap(source.page(at: 0))
        let original = try PDFBodyTextPageSnapshot.originalPageData(for: page)
        PDFBodyTextDocumentFonts.invalidate(source)
        XCTAssertFalse(token.isValid)
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingApprovedFontPrograms(in: original, tokens: [token]))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.originalPageData(for: page), original)
    }

    func testApprovedFontProgramWriterLeavesNonMacRomanResourcesByteExact() throws {
        let name = "EmberEncoding" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0x0008), name: name)
        let target = try paragraph(in: source), lease = try XCTUnwrap(target.style.sourceFont)
        let token = try XCTUnwrap(lease.approvedProgramToken(for: target.style.font as CTFont))
        let page = try XCTUnwrap(source.page(at: 0))
        let original = try PDFBodyTextPageSnapshot.originalPageData(for: page)
        // This fixture declares WinAnsi. Its font program must never be
        // rewritten through the newly generated MacRoman donor route.
        XCTAssertEqual(try PDFBodyTextPageSnapshot.preservingApprovedFontPrograms(in: original, tokens: [token]), original)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.originalPageData(for: page), original)
    }

    func testClosingDocumentInvalidatesEditableFontLeaseAndRejectsStaleTarget() throws {
        let name = "EmberClose" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0x0008), name: name)
        let target = try paragraph(in: source), page = try XCTUnwrap(source.page(at: 0))
        let lease = try XCTUnwrap(target.style.sourceFont)
        let before = try PDFBodyTextPageSnapshot.contentData(for: page)
        PDFBodyTextDocumentFonts.invalidate(source)
        XCTAssertFalse(lease.isValid(for: source)); XCTAssertNil(lease.font(ofSize: 16))
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "ChangeMe", with: "ChengeMe"), style: target.style, bounds: target.bounds))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), before)
    }

    func testMissingOS2SubsetCannotBorrowAnEditableLeaseFromAnotherDocument() throws {
        let name = "EmberScope" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let licensed = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0x0008), name: name)
        _ = try XCTUnwrap(paragraph(in: licensed).style.sourceFont)
        let other = try fixture()
        let subsetBytes = try renamedTrueType(name, omittingOS2: true)
        let subset = try XCTUnwrap(CGFont(XCTUnwrap(CGDataProvider(data: subsetBytes as CFData))))
        XCTAssertNil(PDFBodyTextDocumentFonts.lease(matchingSubsetWithoutOS2: subset,
                                                   document: other, covering: "ChangeMe"))
        PDFBodyTextDocumentFonts.invalidate(licensed)
        XCTAssertNil(PDFBodyTextDocumentFonts.lease(matchingSubsetWithoutOS2: subset,
                                                   document: licensed, covering: "ChangeMe"))
        XCTAssertNil(NSFont(name: name, size: 16))
    }

    func testCompleteSubsetMappingRejectsConflictsUnreferencedGlyphsAndLimits() {
        func append16(_ value: Int, to data: inout Data) {
            data.append(UInt8((value >> 8) & 255)); data.append(UInt8(value & 255))
        }
        func append32(_ value: Int, to data: inout Data) {
            append16(value >> 16, to: &data); append16(value & 65_535, to: &data)
        }
        func maxp(_ count: Int) -> Data {
            var result = Data(); append32(0x00010000, to: &result); append16(count, to: &result); return result
        }
        func cmap(_ tables: [[(Int, Int, Int)]]) -> Data {
            var result = Data(); append16(0, to: &result); append16(tables.count, to: &result)
            var bodies: [Data] = [], offset = 4 + tables.count * 8
            for (index, groups) in tables.enumerated() {
                append16(index == 0 ? 0 : 3, to: &result); append16(index == 0 ? 4 : 10, to: &result)
                append32(offset, to: &result)
                var body = Data(); append16(12, to: &body); append16(0, to: &body)
                append32(16 + groups.count * 12, to: &body); append32(0, to: &body); append32(groups.count, to: &body)
                for (lower, upper, glyph) in groups {
                    append32(lower, to: &body); append32(upper, to: &body); append32(glyph, to: &body)
                }
                offset += body.count; bodies.append(body)
            }
            for body in bodies { result.append(body) }; return result
        }
        for usesGlyphArray in [false, true] {
            var format4 = Data()
            for value in [4, usesGlyphArray ? 36 : 32, 0, 4, 4, 1, 0,
                          66, 65_535, 0, 65, 65_535,
                          usesGlyphArray ? 0 : 65_472, 1, usesGlyphArray ? 4 : 0, 0] {
                append16(value, to: &format4)
            }
            if usesGlyphArray { append16(1, to: &format4); append16(2, to: &format4) }
            var wrapper = Data()
            for value in [0, 1, 0, 3] { append16(value, to: &wrapper) }
            append32(12, to: &wrapper); wrapper.append(format4)
            XCTAssertEqual(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(cmap: wrapper,
                                                                                maxp: maxp(3)), [65: 1, 66: 2])
        }
        XCTAssertEqual(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap([[(65, 66, 1)]]), maxp: maxp(3)), [65: 1, 66: 2])
        XCTAssertEqual(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap([[(1, 512, 1)]]), maxp: maxp(513))?.count, 512)
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap([[(1, 513, 1)]]), maxp: maxp(514)))
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap([[(65, 65, 1)]]), maxp: maxp(3)), "Unmapped nonzero GID cannot be ignored.")
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap([[(65, 66, 1)], [(65, 65, 2), (66, 66, 1)]]), maxp: maxp(3)))
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap([[(0xD800, 0xD800, 1)]]), maxp: maxp(2)))
        var truncated = cmap([[(65, 66, 1)]]); truncated.removeLast()
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(cmap: truncated, maxp: maxp(3)))
    }

    func testMacRomanFormat6SubsetMapsExactScalarsAndRejectsTruncationAndRanges() {
        func append16(_ value: Int, to data: inout Data) {
            data.append(UInt8((value >> 8) & 255)); data.append(UInt8(value & 255))
        }
        func maxp(_ glyphs: Int) -> Data {
            var data = Data([0, 1, 0, 0]); append16(glyphs, to: &data); return data
        }
        func cmap(first: Int, glyphs: [Int], language: Int = 0) -> Data {
            var data = Data([0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 12])
            for value in [6, 10 + glyphs.count * 2, language, first, glyphs.count] {
                append16(value, to: &data)
            }
            for glyph in glyphs { append16(glyph, to: &data) }; return data
        }
        XCTAssertEqual(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap(first: 65, glyphs: [1, 0, 2]), maxp: maxp(3)), [65: 1, 67: 2])
        for (code, scalar): (Int, UInt32) in [(0x80, 0x00C4), (0xBD, 0x03A9), (0xDB, 0x20AC), (0xF0, 0xF8FF)] {
            XCTAssertEqual(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
                cmap: cmap(first: code, glyphs: [1]), maxp: maxp(2)), [scalar: 1])
        }
        XCTAssertEqual(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap(first: 0, glyphs: Array(1...256)), maxp: maxp(257))?.count, 256)
        var truncated = cmap(first: 65, glyphs: [1]); truncated.removeLast()
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(cmap: truncated, maxp: maxp(2)))
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap(first: 255, glyphs: [1, 2]), maxp: maxp(3)))
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap(first: 256, glyphs: [1]), maxp: maxp(2)))
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap(first: 65, glyphs: [1], language: 1), maxp: maxp(2)))
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap(first: 65, glyphs: [2]), maxp: maxp(2)))
        XCTAssertNil(PDFBodyTextDocumentFonts.completeSubsetUnicodeMapping(
            cmap: cmap(first: 65, glyphs: [1]), maxp: maxp(3)), "All nonzero GIDs remain required.")
    }

    func testOutOfRangePDFiumWeightDoesNotBecomeABoldHint() {
        for value: Int32 in [-1, 0, 99, 400, 901, 2092] { XCTAssertFalse(PDFBodyTextEditor.sourceWeightSuggestsBold(value)) }
        for value: Int32 in [600, 700, 900] { XCTAssertTrue(PDFBodyTextEditor.sourceWeightSuggestsBold(value)) }
    }

    private func glyphAdvance(_ text: String, font: CTFont) throws -> CGFloat {
        var character = try XCTUnwrap(text.utf16.first), glyph = CGGlyph(), advance = CGSize()
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }

    private func assertSameGlyphs(_ text: String, expected: CTFont, actual: CTFont,
                                 compareAtSize: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let left = compareAtSize.map { CTFontCreateCopyWithAttributes(expected, $0, nil, nil) } ?? expected
        let right = compareAtSize.map { CTFontCreateCopyWithAttributes(actual, $0, nil, nil) } ?? actual
        for unit in Set(text.utf16) {
            var character = unit, a = CGGlyph(), b = CGGlyph()
            XCTAssertTrue(CTFontGetGlyphsForCharacters(left, &character, &a, 1), file: file, line: line)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(right, &character, &b, 1), file: file, line: line)
            XCTAssertEqual(CTFontCreatePathForGlyph(left, a, nil), CTFontCreatePathForGlyph(right, b, nil), file: file, line: line)
            var aa = CGSize(), bb = CGSize()
            CTFontGetAdvancesForGlyphs(left, .horizontal, &a, &aa, 1)
            CTFontGetAdvancesForGlyphs(right, .horizontal, &b, &bb, 1)
            XCTAssertEqual(aa.width, bb.width, accuracy: 0.0001, file: file, line: line)
        }
    }

    func testMissingGlyphUsesSearchableFallbackWithoutChangingRetainedLatinRows() throws {
        let name = "EmberLatin" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = try fixture(fontProgram: renamedTrueType(name), name: name)
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try paragraph(in: source)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "ChangeMe", with: "새 글자"),
            style: target.style, bounds: target.bounds)
        let reopened = try reopen(edited)
        XCTAssertEqual(reopened.findString("새 글자", withOptions: []).count, 1)
        XCTAssertEqual(reopened.findString("KeepFirst", withOptions: []).count, 1)
        let content = String(decoding: try PDFBodyTextPageSnapshot.contentData(for: edited), as: UTF8.self)
        XCTAssertTrue(content.contains(firstShow)); XCTAssertTrue(content.contains(lastShow))
        for y: CGFloat in [260, 212] { XCTAssertEqual(try pixels(page, y: y), try pixels(edited, y: y)) }
        try export(source, name: "embedded-fallback-before")
        try export(reopened, name: "embedded-fallback-after")
    }

    func testRestrictedProgramAndSameNameCollisionUseTheExistingSubstituteRoute() throws {
        let name = "EmberConflict" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let allowed = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: 0), name: name)
        let original = try paragraph(in: allowed)
        XCTAssertEqual(original.style.font.fontName, name)
        _ = try PDFBodyTextEditor.replacementPage(for: XCTUnwrap(allowed.page(at: 0)), target: original,
            text: original.text.replacingOccurrences(of: "ChangeMe", with: "Replaced"),
            style: original.style, bounds: original.bounds)
        let colliding = try fixture(fontProgram: renamedTrueType(name, adjustKAdvanceBy: 64), name: name)
        XCTAssertNotEqual(try paragraph(in: colliding).style.font.fontName, name,
                          "An exported face with the same name must not override a different Unicode glyph advance.")
        let installedCollision = try fixture(fontProgram: renamedTrueType("ArialMT", adjustKAdvanceBy: 64), name: "ArialMT")
        XCTAssertNotEqual(try paragraph(in: installedCollision).style.font.fontName, "ArialMT",
                          "An installed face with the same name must also match the embedded glyphs.")
        // Same PostScript name, different program: a restricted/no-subsetting
        // face must not pick up the earlier document's process registration.
        for flags in [UInt16(0x0002), 0x0004, 0x0008, 0x0100, 0x0200] {
            let source = try fixture(fontProgram: renamedTrueType(name, embeddingFlags: flags), name: name)
            let target = try paragraph(in: source)
            XCTAssertNotEqual(target.style.font.fontName, name)
        }
    }

    func testCachedInstalledSubsetCannotReuseANameForALaterMismatchedGlyph() throws {
        let source = try fixture(fontProgram: renamedTrueType("ArialMT", adjustKAdvanceBy: 64), name: "ArialMT")
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let text = try XCTUnwrap(page.string) as NSString
        let first = text.range(of: "First"), last = text.range(of: "KeepLast")
        XCTAssertNotEqual(first.location, NSNotFound)
        XCTAssertNotEqual(last.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: NSUnionRange(first, last)))
        // Starting inside the first line makes paragraph expansion inspect
        // "First" before its "Keep" prefix. Only the later K differs from
        // the installed face, so a cached subset must be checked again.
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let targetText = target.text as NSString
        let changedGlyphRuns = target.sourceRuns.filter { targetText.substring(with: $0.range).contains("K") }
        XCTAssertFalse(changedGlyphRuns.isEmpty)
        for run in changedGlyphRuns {
            XCTAssertNotEqual(run.style.font.fontName, "ArialMT",
                              "A cached subset failure must not fall back to the same installed name.")
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testEmbeddedProgramWithoutLicensingTableCannotReuseAnUnverifiedInstalledName() throws {
        let program = try renamedTrueType("ArialMT", adjustKAdvanceBy: 64, omittingOS2: true)
        let source = try fixture(fontProgram: program, name: "ArialMT")
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let target = try paragraph(in: source)
        XCTAssertNotEqual(target.style.font.fontName, "ArialMT",
                          "A missing licensing table must not bypass embedded glyph verification.")
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testUnavailableGlyphIsRefusedWithoutChangingTheSource() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try paragraph(in: source)
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "ChangeMe", with: "\u{10FFFF}"),
            style: target.style, bounds: target.bounds))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    /// Private books stay outside the repository. All edits and save/reopen
    /// checks use detached pages and memory; verify the input file's SHA too.
    func testOptInRealKoreanBooksRetainUntouchedContentAndSurviveTwoReopens() throws {
        guard let directory = ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_PDF_DIRECTORY"] else {
            throw XCTSkip("Set EMBER_BODY_SOURCE_PDF_DIRECTORY to run private read-only book checks.")
        }
        let examples = [
            ("파이썬으로 웹 크롤러 만들기 (라이언 미첼).pdf", 171, "이 테이블", "그림 8-1", "오랜 시간", "긴 시간"),
            ("잠 못들 정도로 재미있는 이야기 - 영양소 (그림으로 읽는) (성안당 편집부).pdf", 82, "수확한", "", "수확한", "수확된")
        ]
        for (book, example) in examples.enumerated() {
            let (file, index, start, end, old, new) = example
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(file)
            let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
            let original = try XCTUnwrap(PDFDocument(url: url))
            let originalPage = try XCTUnwrap(original.page(at: index))
            let originalBytes = try PDFBodyTextPageSnapshot.data(for: originalPage)
            if ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_QA_DIRECTORY"] != nil {
                let detached = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.restoringFontNames(in: originalBytes)))
                try export(detached, name: "real-book-\(book + 1)-before")
            }
            var current = original, page = originalPage
            for (pass, change) in [(old, new), (new, old)].enumerated() {
                let (before, after) = change
                let content = try XCTUnwrap(page.string) as NSString
                let selected: PDFSelection
                if page === originalPage, !end.isEmpty {
                    let first = content.range(of: start), last = content.range(of: end)
                    XCTAssertNotEqual(first.location, NSNotFound); XCTAssertNotEqual(last.location, NSNotFound)
                    selected = try XCTUnwrap(page.selection(for: NSRange(location: first.location, length: last.location - first.location)))
                } else {
                    selected = try XCTUnwrap(current.findString(before, withOptions: []).first)
                }
                let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
                let revised = target.text.replacingOccurrences(of: before, with: after)
                XCTAssertNotEqual(target.text, revised)
                let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                    text: revised, style: target.style, bounds: target.bounds)
                current = try reopen(edited)
                XCTAssertEqual(current.findString(after, withOptions: []).count, 1)
                page = try XCTUnwrap(current.page(at: 0))
                try export(current, name: "real-book-\(book + 1)-" + (pass == 0 ? "after" : "restored"))
            }
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: originalPage), originalBytes)
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)), digest)
        }
    }

    /// Exercise the application's snapshot/atomic save path independently for
    /// both private books, so one failed case cannot hide the other document.
    func testOptInRealKoreanBooksSurviveAtomicSaveAndColdReedit() async throws {
        guard let directory = ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_PDF_DIRECTORY"] else {
            throw XCTSkip("Set EMBER_BODY_SOURCE_PDF_DIRECTORY for private read-only book checks.")
        }
        let examples = [
            ("파이썬으로 웹 크롤러 만들기 (라이언 미첼).pdf", 171, "이 테이블", "그림 8-1", "오랜 시간", "긴 시간"),
            ("잠 못들 정도로 재미있는 이야기 - 영양소 (그림으로 읽는) (성안당 편집부).pdf", 82, "수확한", "", "수확한", "수확된")
        ]
        let retained = ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_QA_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("real-books-atomic-" + UUID().uuidString) }
        let output = retained ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { if retained == nil { try? FileManager.default.removeItem(at: output) } }
        for (book, example) in examples.enumerated() {
            let (file, index, start, end, old, new) = example
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(file)
            let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
            let original = try XCTUnwrap(PDFDocument(url: url))
            let originalPage = try XCTUnwrap(original.page(at: index))
            let originalBytes = try PDFBodyTextPageSnapshot.data(for: originalPage)
            var stage = "select"
            do {
                var current = original, page = originalPage
                for (pass, change) in [(old, new), (new, old)].enumerated() {
                    let (before, after) = change
                    stage = "cycle-\(pass)-target"
                    let content = try XCTUnwrap(page.string) as NSString
                    let selected: PDFSelection
                    if page === originalPage, !end.isEmpty {
                        let first = content.range(of: start), last = content.range(of: end)
                        guard first.location != NSNotFound, last.location != NSNotFound,
                              last.location > first.location else { throw NSError(domain: "EmberPDFTests.BookSelection", code: 1) }
                        selected = try XCTUnwrap(page.selection(for: NSRange(location: first.location, length: last.location - first.location)))
                    } else {
                        selected = try XCTUnwrap(current.findString(before, withOptions: []).first(where: { $0.pages.contains(where: { $0 === page }) }))
                    }
                    let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
                    let revised = target.text.replacingOccurrences(of: before, with: after)
                    XCTAssertNotEqual(target.text, revised)
                    stage = "cycle-\(pass)-replace"
                    let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                        text: revised, style: target.style, bounds: target.bounds)
                    let live = PDFDocument(); live.insert(edited, at: 0)
                    let snapshot = try PDFRecoverySnapshot(capturing: live)
                    let destination = output.appendingPathComponent("book-\(book + 1)-cycle-\(pass).pdf")
                    stage = "cycle-\(pass)-save"
                    _ = try await Task.detached { try AtomicPDFWriter.write(snapshot.takeDocument(), to: destination) }.value
                    PDFBodyTextDocumentFonts.invalidate(current)
                    PDFBodyTextDocumentFonts.invalidate(live)
                    stage = "cycle-\(pass)-reopen"
                    current = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: destination)))
                    page = try XCTUnwrap(current.page(at: 0))
                    XCTAssertEqual(current.findString(after, withOptions: []).count, 1)
                    // A fresh selection must work before any unrelated row is selected.
                    _ = try XCTUnwrap(PDFBodyTextEditor.target(on: page,
                        selection: XCTUnwrap(current.findString(after, withOptions: []).first)))
                }
            } catch {
                XCTFail("Book \(book + 1), \(stage): \(error)")
            }
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: originalPage), originalBytes)
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)), digest)
        }
    }

    private func paragraph(in source: PDFDocument, through last: String = "KeepLast") throws -> PDFBodyTextTarget {
        let page = try XCTUnwrap(source.page(at: 0))
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: paragraphSelection(in: source, through: last)))
    }

    private func paragraphSelection(in source: PDFDocument, through last: String = "KeepLast") throws -> PDFSelection {
        let page = try XCTUnwrap(source.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let start = text.range(of: "KeepFirst"), end = text.range(of: last)
        XCTAssertNotEqual(start.location, NSNotFound)
        XCTAssertNotEqual(end.location, NSNotFound)
        return try XCTUnwrap(page.selection(for: NSUnionRange(start, end)))
    }

    private func fixture(fontProgram: Data? = nil, name: String = "Helvetica", translatedMiddle: Bool = false,
                         fourthLine: Bool = false) throws -> PDFDocument {
        let middle = translatedMiddle
            ? "q 1 0 0 1 12 0 cm BT /F1 16 Tf 1 0 0 1 28 236 Tm (ChangeMe) Tj ET Q\n"
            : "BT /F1 16 Tf 1 0 0 1 40 236 Tm (ChangeMe) Tj ET\n"
        let content = "BT /F1 16 Tf 1 0 0 1 40 260 Tm \(firstShow) ET\n"
            + middle
            + "BT /F1 16 Tf 1 0 0 1 40 212 Tm \(lastShow) ET\n"
            + (fourthLine ? "BT /F1 16 Tf 1 0 0 1 40 188 Tm (ChangeLast) Tj ET\n" : "")
        var objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            stream(Data(content.utf8))
        ]
        if let fontProgram {
            let graphics = try XCTUnwrap(CGFont(XCTUnwrap(CGDataProvider(data: fontProgram as CFData))))
            let font = CTFontCreateWithGraphicsFont(graphics, 1000, nil, nil)
            let widths = (32...126).map { value -> String in
                var character = UniChar(value), glyph = CGGlyph(), advance = CGSize()
                _ = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
                _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
                return String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), advance.width)
            }.joined(separator: " ")
            objects[3] = Data("<< /Type /Font /Subtype /TrueType /BaseFont /\(name) /FirstChar 32 /LastChar 126 /Widths [\(widths)] /Encoding /WinAnsiEncoding /FontDescriptor 6 0 R >>".utf8)
            objects.append(Data("<< /Type /FontDescriptor /FontName /\(name) /Flags 32 /FontBBox [-1000 -1000 2000 2000] /ItalicAngle 0 /Ascent 1000 /Descent -300 /CapHeight 700 /StemV 80 /FontFile2 7 0 R >>".utf8))
            objects.append(stream(fontProgram, extra: "/Length1 \(fontProgram.count)"))
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n".utf8)); data.append(object); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func stream(_ bytes: Data, extra: String = "") -> Data {
        var result = Data("<< /Length \(bytes.count) \(extra) >>\nstream\n".utf8)
        result.append(bytes); result.append(Data("\nendstream".utf8)); return result
    }

    private func reopen(_ page: PDFPage) throws -> PDFDocument {
        let document = PDFDocument(); document.insert(page, at: 0)
        return try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
    }

    private func export(_ document: PDFDocument, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_QA_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicPDFWriter.write(document, to: directory.appendingPathComponent(name + ".pdf"))
    }

    private func pixels(_ page: PDFPage, y: CGFloat) throws -> Data {
        var bytes = Data(count: 400 * 22 * 4)
        try bytes.withUnsafeMutableBytes { pixels in
            let context = try XCTUnwrap(CGContext(data: pixels.baseAddress, width: 400, height: 22,
                bitsPerComponent: 8, bytesPerRow: 400 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 22))
            context.translateBy(x: 0, y: -y + 4)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        return bytes
    }

    /// Build a renamed face from system font tables in memory. No font binary
    /// or licensed source file is copied into the repository or installed.
    private func renamedTrueType(_ name: String, embeddingFlags: UInt16 = 0, adjustKAdvanceBy: Int = 0,
                                 omittingOS2: Bool = false) throws -> Data {
        let original = CTFontCreateWithName("ArialMT" as CFString, 16, nil)
        let tags = try XCTUnwrap(CTFontCopyAvailableTables(original, []))
        var tables: [UInt32: Data] = [:]
        // CoreText stores unboxed table tags, not CFNumber objects.
        for index in 0..<CFArrayGetCount(tags) {
            let tag = CTFontTableTag(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tags, index)))
            if tag != 0x44534947,
               let bytes = CTFontCopyTable(original, tag, []) as Data? { tables[tag] = bytes }
        }
        XCTAssertNotNil(tables[CTFontTableTag(kCTFontTableGlyf)])
        let names = try XCTUnwrap(tables[CTFontTableTag(kCTFontTableName)])
        func u16(_ bytes: Data, _ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        let count = u16(names, 2), strings = u16(names, 4)
        var records = Data(), storage = Data()
        for index in 0..<count {
            let start = 6 + index * 12, platform = u16(names, start), identifier = u16(names, start + 6)
            let length = u16(names, start + 8), offset = u16(names, start + 10)
            let value: Data
            if [1, 3, 4, 6, 16].contains(identifier) {
                value = try XCTUnwrap(name.data(using: platform == 1 ? .macOSRoman : .utf16BigEndian))
            } else { value = names.subdata(in: (strings + offset)..<(strings + offset + length)) }
            records.append(names.subdata(in: start..<(start + 8)))
            records.append(be16(value.count)); records.append(be16(storage.count)); storage.append(value)
        }
        tables[CTFontTableTag(kCTFontTableName)] = be16(0) + be16(count) + be16(6 + count * 12) + records + storage
        var os2 = try XCTUnwrap(tables[CTFontTableTag(kCTFontTableOS2)])
        os2.replaceSubrange(8..<10, with: be16(Int(embeddingFlags)))
        tables[CTFontTableTag(kCTFontTableOS2)] = os2
        if adjustKAdvanceBy != 0 {
            var character = UniChar(75), glyph = CGGlyph()
            XCTAssertTrue(CTFontGetGlyphsForCharacters(original, &character, &glyph, 1))
            let hhea = try XCTUnwrap(tables[CTFontTableTag(kCTFontTableHhea)])
            XCTAssertLessThan(Int(glyph), u16(hhea, 34))
            var metrics = try XCTUnwrap(tables[CTFontTableTag(kCTFontTableHmtx)])
            let offset = Int(glyph) * 4
            metrics.replaceSubrange(offset..<(offset + 2), with: be16(u16(metrics, offset) + adjustKAdvanceBy))
            tables[CTFontTableTag(kCTFontTableHmtx)] = metrics
        }
        if omittingOS2 { tables.removeValue(forKey: CTFontTableTag(kCTFontTableOS2)) }
        var head = try XCTUnwrap(tables[CTFontTableTag(kCTFontTableHead)]); head.replaceSubrange(8..<12, with: [0, 0, 0, 0]); tables[CTFontTableTag(kCTFontTableHead)] = head
        let sorted = tables.keys.sorted(), power = Int(pow(2, floor(log2(Double(sorted.count)))))
        var result = Data([0, 1, 0, 0]) + be16(sorted.count) + be16(power * 16)
            + be16(Int(log2(Double(power)))) + be16(sorted.count * 16 - power * 16)
        var directory = Data(), contents = Data(), headOffset = 0
        for tag in sorted {
            let bytes = tables[tag]!, offset = 12 + sorted.count * 16 + contents.count
            if tag == CTFontTableTag(kCTFontTableHead) { headOffset = offset }
            directory.append(be32(tag)); directory.append(be32(checksum(bytes)))
            directory.append(be32(UInt32(offset))); directory.append(be32(UInt32(bytes.count)))
            contents.append(bytes)
            while contents.count % 4 != 0 { contents.append(0) }
        }
        result.append(directory); result.append(contents)
        result.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: be32(0xB1B0AFBA &- checksum(result)))
        return result
    }

    private func be16(_ value: Int) -> Data { Data([UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
    private func be32(_ value: UInt32) -> Data { Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }) }
    private func checksum(_ input: Data) -> UInt32 {
        var bytes = input
        while bytes.count % 4 != 0 { bytes.append(0) }
        var sum: UInt32 = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let highByte: UInt32 = UInt32(bytes[offset]) << 24
            let secondByte: UInt32 = UInt32(bytes[offset + 1]) << 16
            let thirdByte: UInt32 = UInt32(bytes[offset + 2]) << 8
            let lowByte: UInt32 = UInt32(bytes[offset + 3])
            let word: UInt32 = highByte | secondByte | thirdByte | lowByte
            sum = sum &+ word
        }
        return sum
    }
}

// Owned-only failure injection through the real PDFDocument classForPage
// delegate. No production seam/global mutable test hook is introduced.
private let sourcePreservingCopyFailureStateKey = NSObject()
private final class SourcePreservingCopyFailureState: NSObject {
    var calls = 0
    var returnsSelf = false
    var hidesAnnotations = false
}
private final class SourcePreservingCopyFailureDelegate: NSObject, PDFDocumentDelegate {
    func classForPage() -> AnyClass { SourcePreservingCopyFailurePage.self }
}
private final class SourcePreservingCopyFailurePage: PDFPage {
    // PDFKit may construct this subclass without Swift property initialization.
    // State is therefore explicitly installed after the page is created.
    private var state: SourcePreservingCopyFailureState? {
        objc_getAssociatedObject(self, UnsafeRawPointer(Unmanaged.passUnretained(sourcePreservingCopyFailureStateKey).toOpaque())) as? SourcePreservingCopyFailureState
    }
    func install(_ state: SourcePreservingCopyFailureState) {
        objc_setAssociatedObject(self, UnsafeRawPointer(Unmanaged.passUnretained(sourcePreservingCopyFailureStateKey).toOpaque()), state, .OBJC_ASSOCIATION_RETAIN)
    }
    override var annotations: [PDFAnnotation] { state?.hidesAnnotations == true ? [] : super.annotations }
    override func copy(with zone: NSZone? = nil) -> Any {
        if let state {
            state.calls += 1
            if state.returnsSelf { return self }
        }
        return NSNull()
    }
}
