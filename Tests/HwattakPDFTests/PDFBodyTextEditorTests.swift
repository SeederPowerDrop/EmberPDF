// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFBodyTextEditorTests: XCTestCase {
    @MainActor
    func testReplacementRemovesOriginalFromSearchAndCopyAfterReopen() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try lookupTarget("Original text", in: source)
        XCTAssertEqual(target.text, "Original text")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target, text: "Changed text", style: target.style, bounds: target.bounds)
        let reopened = try reopen(edited)
        XCTAssertFalse((reopened.string ?? "").contains("Original"))
        XCTAssertTrue((reopened.string ?? "").contains("Changed text"))
        XCTAssertTrue(reopened.findString("Original", withOptions: []).isEmpty)
        XCTAssertEqual(reopened.findString("Changed text", withOptions: []).count, 1)
        XCTAssertTrue((reopened.string ?? "").contains("Unaffected text"))
        XCTAssertTrue((source.string ?? "").contains("Original text"), "Service edits a detached page only")
        let editedPage = try XCTUnwrap(reopened.page(at: 0))
        let nextTarget = try lookupTarget("Changed text", in: reopened)
        let twice = try PDFBodyTextEditor.replacementPage(for: editedPage, target: nextTarget, text: "Edited twice", style: nextTarget.style, bounds: nextTarget.bounds)
        let twiceReopened = try reopen(twice)
        XCTAssertFalse((twiceReopened.string ?? "").contains("Changed"))
        XCTAssertTrue((twiceReopened.string ?? "").contains("Edited twice"))
    }

    @MainActor
    func testEmptyReplacementDeletesOnlyTargetText() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try lookupTarget("Original text", in: source)
        let result = try PDFBodyTextEditor.replacementPage(for: page, target: target, text: "", style: target.style, bounds: target.bounds)
        let reopened = try reopen(result)
        XCTAssertFalse((reopened.string ?? "").contains("Original"))
        XCTAssertTrue((reopened.string ?? "").contains("Unaffected text"))
    }

    @MainActor
    func testAddsSearchableKoreanAndCanEditItAgain() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let style = InlineTextStyle(fontName: "AppleSDGothicNeo-Regular", fontSize: 18, textColor: .black, backgroundColor: .clear, alignment: .left)
        let beforePixels = try sampleImageRegion(page)
        let bounds = CGRect(x: 50, y: 50, width: 260, height: 40)
        let inserted = try PDFBodyTextEditor.replacementPage(for: page, target: nil, text: "한글 본문 추가", style: style, bounds: bounds)
        let reopened = try reopen(inserted)
        XCTAssertEqual(try sampleImageRegion(XCTUnwrap(reopened.page(at: 0))), beforePixels, "Insertion/reopen preserves unrelated graphics")
        XCTAssertTrue((reopened.string ?? "").contains("한글 본문 추가"))
        XCTAssertEqual(reopened.findString("한글 본문 추가", withOptions: []).count, 1)
        XCTAssertTrue((reopened.string ?? "").contains("Original text"))
        let korean = try lookupTarget("한글 본문 추가", in: reopened)
        let edited = try PDFBodyTextEditor.replacementPage(for: XCTUnwrap(reopened.page(at: 0)), target: korean, text: "한글 본문 수정", style: korean.style, bounds: korean.bounds)
        let editedDocument = try reopen(edited)
        XCTAssertEqual(try sampleImageRegion(XCTUnwrap(editedDocument.page(at: 0))), beforePixels, "Korean replacement/reopen preserves unrelated graphics")
        XCTAssertFalse((editedDocument.string ?? "").contains("추가"))
        XCTAssertTrue((editedDocument.string ?? "").contains("한글 본문 수정"))
        let ascii = try lookupTarget("Original text", in: editedDocument)
        let finalPage = try PDFBodyTextEditor.replacementPage(for: XCTUnwrap(editedDocument.page(at: 0)),
            target: ascii, text: "Updated text", style: ascii.style, bounds: ascii.bounds)
        let finalDocument = try reopen(finalPage)
        XCTAssertEqual(try sampleImageRegion(XCTUnwrap(finalDocument.page(at: 0))), beforePixels, "Third edit/reopen preserves unrelated graphics")
        XCTAssertTrue((finalDocument.string ?? "").contains("Updated text"))
        XCTAssertTrue((finalDocument.string ?? "").contains("한글 본문 수정"))
        // Opt-in fixture export supports visual QA without touching a user PDF.
        if let directory = ProcessInfo.processInfo.environment["EMBER_BODY_TEXT_QA_DIRECTORY"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(source.dataRepresentation()).write(to: folder.appendingPathComponent("before.pdf"))
            try XCTUnwrap(finalDocument.dataRepresentation()).write(to: folder.appendingPathComponent("after.pdf"))
        }
    }

    @MainActor
    func testLatinFontKoreanAndMixedReplacementRemainOneEditableRun() throws {
        for phrase in ["본문 수정 성공", "EmberPDF 본문 수정 성공"] {
            let source = try fixture()
            let page = try XCTUnwrap(source.page(at: 0))
            let original = try lookupTarget("Original text", in: source)
            XCTAssertEqual(original.style.font.fontName, "Helvetica")
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: original,
                text: phrase, style: original.style, bounds: original.bounds)
            let live = PDFDocument()
            live.insert(edited, at: 0)
            let liveTarget = try lookupTarget(phrase, in: live)
            XCTAssertEqual(liveTarget.text, phrase, "A fallback must not split Korean words from Latin spaces")
            let saved = try reopen(try XCTUnwrap(edited.copy() as? PDFPage))
            let savedTarget = try lookupTarget(phrase, in: saved)
            XCTAssertEqual(savedTarget.text, phrase)
            for (document, target) in [(live, liveTarget), (saved, savedTarget)] {
                let twice = try PDFBodyTextEditor.replacementPage(for: XCTUnwrap(document.page(at: 0)),
                    target: target, text: "본문 다시 수정 성공", style: target.style, bounds: target.bounds)
                let reopened = try reopen(twice)
                XCTAssertEqual(reopened.findString("본문 다시 수정 성공", withOptions: []).count, 1)
                XCTAssertTrue(reopened.findString(phrase, withOptions: []).isEmpty)
                XCTAssertTrue((reopened.string ?? "").contains("Unaffected text"))
                XCTAssertEqual(try sampleImageRegion(XCTUnwrap(reopened.page(at: 0))), try sampleImageRegion(page))
            }
        }
    }

    @MainActor
    func testPreservesPageGeometryAnnotationAndUnrelatedImage() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 20, width: 360, height: 260), for: .cropBox)
        page.setBounds(CGRect(x: 25, y: 25, width: 350, height: 250), for: .trimBox)
        page.rotation = 90
        let note = PDFAnnotation(bounds: CGRect(x: 300, y: 230, width: 20, height: 20), forType: .square, withProperties: nil)
        note.contents = "Keep this annotation"
        page.addAnnotation(note)
        let target = try lookupTarget("Original text", in: source)
        let beforePixels = try sampleImageRegion(page)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target, text: "New", style: target.style, bounds: target.bounds)
        let result = try XCTUnwrap(try reopen(edited).page(at: 0))
        XCTAssertEqual(result.rotation, 90)
        for box in [PDFDisplayBox.mediaBox, .cropBox, .trimBox, .bleedBox, .artBox] {
            XCTAssertEqual(result.bounds(for: box), page.bounds(for: box))
        }
        XCTAssertEqual(result.annotations.map(\.contents), ["Keep this annotation"])
        let afterPixels = try sampleImageRegion(result)
        XCTAssertEqual(afterPixels, beforePixels)
    }

    @MainActor
    func testSharedFormRefusesEditWithoutChangingEitherInstance() throws {
        let source = try fixture(nested: true)
        let page = try XCTUnwrap(source.page(at: 0))
        let matches = source.findString("Shared text", withOptions: [])
        XCTAssertEqual(matches.count, 2)
        let first = try XCTUnwrap(matches.max { $0.bounds(for: page).midY < $1.bounds(for: page).midY })
        let box = first.bounds(for: page)
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: box.midX, y: box.midY)))
        XCTAssertEqual(source.findString("Shared text", withOptions: []).count, 2)
        XCTAssertEqual(try reopen(XCTUnwrap(page.copy() as? PDFPage)).findString("Shared text", withOptions: []).count, 2)
    }

    @MainActor
    func testRefusesUnsupportedTransformAndForeignTargetWithoutChangingOriginal() throws {
        let angled = try fixture(angled: true)
        let page = try XCTUnwrap(angled.page(at: 0))
        let selection = try XCTUnwrap(angled.findString("Original text", withOptions: []).first)
        let rect = selection.bounds(for: page)
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertTrue((angled.string ?? "").contains("Original text"))
        let source = try fixture()
        let target = try lookupTarget("Original text", in: source)
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: target, text: "Wrong page", style: target.style, bounds: target.bounds))
        XCTAssertTrue((angled.string ?? "").contains("Original text"))
    }

    @MainActor
    func testNonzeroMediaOriginKeepsReplacementAtOriginalPosition() throws {
        let source = try fixture(nonzeroOrigin: true)
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try lookupTarget("Original text", in: source)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target, text: "Updated text", style: target.style, bounds: target.bounds)
        let reopened = try reopen(edited)
        let resultTarget = try lookupTarget("Updated text", in: reopened)
        let originalSaved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(source.dataRepresentation())))
        let savedOriginalTarget = try lookupTarget("Original text", in: originalSaved)
        let directTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: edited, at: CGPoint(x: target.bounds.midX, y: target.bounds.midY)))
        XCTAssertEqual(edited.bounds(for: .mediaBox), page.bounds(for: .mediaBox))
        XCTAssertEqual(directTarget.bounds.minX, target.bounds.minX, accuracy: 0.1)
        XCTAssertEqual(directTarget.bounds.maxY, target.bounds.maxY, accuracy: 0.1)
        // PDFKit normalizes a nonzero origin even when saving the untouched
        // original. Compare against that baseline and physical page position.
        XCTAssertEqual(reopened.page(at: 0)?.bounds(for: .mediaBox), originalSaved.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertEqual(resultTarget.bounds.minX, savedOriginalTarget.bounds.minX, accuracy: 0.1)
        XCTAssertEqual(resultTarget.bounds.maxY, savedOriginalTarget.bounds.maxY, accuracy: 0.1)
        let savedMedia = try XCTUnwrap(reopened.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(resultTarget.bounds.minX - savedMedia.minX, target.bounds.minX - page.bounds(for: .mediaBox).minX, accuracy: 0.1)
        XCTAssertEqual(resultTarget.bounds.maxY - savedMedia.minY, target.bounds.maxY - page.bounds(for: .mediaBox).minY, accuracy: 0.1)
    }

    @MainActor
    func testUnsavedMediaOriginKeepsReplacementAtOriginalPosition() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        page.setBounds(CGRect(x: 10, y: 15, width: 390, height: 285), for: .mediaBox)
        let target = try lookupTarget("Original text", in: source)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target, text: "Updated text", style: target.style, bounds: target.bounds)
        let reopened = try reopen(edited)
        let resultTarget = try lookupTarget("Updated text", in: reopened)
        let originalSaved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(source.dataRepresentation())))
        let savedOriginalTarget = try lookupTarget("Original text", in: originalSaved)
        let directTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: edited, at: CGPoint(x: target.bounds.midX, y: target.bounds.midY)))
        XCTAssertEqual(edited.bounds(for: .mediaBox), page.bounds(for: .mediaBox))
        XCTAssertEqual(directTarget.bounds.minX, target.bounds.minX, accuracy: 0.1)
        XCTAssertEqual(directTarget.bounds.maxY, target.bounds.maxY, accuracy: 0.1)
        // PDFKit normalizes a nonzero origin even when saving the untouched
        // original. Compare against that baseline and physical page position.
        XCTAssertEqual(reopened.page(at: 0)?.bounds(for: .mediaBox), originalSaved.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertEqual(resultTarget.bounds.minX, savedOriginalTarget.bounds.minX, accuracy: 0.1)
        XCTAssertEqual(resultTarget.bounds.maxY, savedOriginalTarget.bounds.maxY, accuracy: 0.1)
        let savedMedia = try XCTUnwrap(reopened.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(resultTarget.bounds.minX - savedMedia.minX, target.bounds.minX - page.bounds(for: .mediaBox).minX, accuracy: 0.1)
        XCTAssertEqual(resultTarget.bounds.maxY - savedMedia.minY, target.bounds.maxY - page.bounds(for: .mediaBox).minY, accuracy: 0.1)
    }

    @MainActor
    func testOverflowingReplacementFailsAtomically() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: nil,
            text: Array(repeating: "More lines", count: 30).joined(separator: "\n"),
            style: .standard(for: .freeText), bounds: CGRect(x: 50, y: 20, width: 100, height: 30)))
        XCTAssertFalse((source.string ?? "").contains("More lines"))
    }

    @MainActor
    func testNondefaultUserUnitIsRejectedWithoutChangingSource() throws {
        let source = try fixture(userUnit: 2)
        let page = try XCTUnwrap(source.page(at: 0))
        let original = page.string
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 60, y: 180)))
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: nil, text: "Unsafe scale",
            style: .standard(for: .freeText), bounds: CGRect(x: 50, y: 50, width: 100, height: 30)))
        XCTAssertEqual(page.string, original)
    }

    @MainActor
    func testJPEGImageAndDecodeParametersRemainUnchanged() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.orange.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.setFillColor(NSColor.purple.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        let commands = "BT /F1 18 Tf 1 0 0 1 50 180 Tm (Original text) Tj ET q 35 0 0 35 300 80 cm /Im1 Do Q"
        var image = Data("<< /Type /XObject /Subtype /Image /Width 8 /Height 8 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /DCTDecode /DecodeParms << /ColorTransform 1 >> /Length \(jpeg.count) >>\nstream\n".utf8)
        image.append(jpeg)
        image.append(Data("\nendstream".utf8))
        let objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            Data("<< /Length \(commands.utf8.count) >>\nstream\n\(commands)\nendstream".utf8), image
        ]
        let source = try document(objects: objects)
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try lookupTarget("Original text", in: source)
        let before = try sampleImageRegion(page)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Updated text", style: target.style, bounds: target.bounds)
        let reopened = try reopen(edited)
        XCTAssertEqual(try sampleImageRegion(XCTUnwrap(reopened.page(at: 0))), before)
        XCTAssertTrue((reopened.string ?? "").contains("Updated text"))
    }

    @MainActor
    func testCMYKPaintSurvivesLosslessTextEditingWithoutChangingSource() throws {
        let cases: [(paint: String, resources: String)] = [
            ("1 1 0 0 k", ""),
            ("/DeviceCMYK cs 1 1 0 0 sc", ""),
            ("/Print cs 1 1 0 0 scn", "/ColorSpace << /Print /DeviceCMYK >>"),
            ("/Profile cs 1 1 0 0 scn", "/ColorSpace << /Profile [/ICCBased 9 0 R] >>"),
            ("/Spot cs 1 scn", "/ColorSpace << /Spot [/Separation /Ink /DeviceRGB << /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0 0 1] /N 1 >>] >>")
        ]
        for testCase in cases {
            let source = try fixture(paintOverride: testCase.paint, additionalResources: testCase.resources)
            let page = try XCTUnwrap(source.page(at: 0))
            let before = try sampleImageRegion(page)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, at: CGPoint(x: 60, y: 184)), testCase.paint)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: "Updated text", style: target.style, bounds: target.bounds)
            XCTAssertEqual(try sampleImageRegion(edited), before, testCase.paint)
            XCTAssertTrue(edited.string?.contains("Updated text") == true)
            XCTAssertFalse(edited.string?.contains("Original text") == true)
            XCTAssertEqual(try sampleImageRegion(page), before)
            XCTAssertTrue((source.string ?? "").contains("Original text"))
        }
    }

    @MainActor
    func testInlineImagePageRefusesDestructiveStreamRegeneration() throws {
        let source = try fixture(inlineImage: true)
        let page = try XCTUnwrap(source.page(at: 0))
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 60, y: 184)))
        XCTAssertTrue((page.string ?? "").contains("Original text"))
    }

    @MainActor
    func testReplacementKeepsOriginalPaintOrderBehindLaterVector() throws {
        let source = try fixture(coverText: true)
        let page = try XCTUnwrap(source.page(at: 0))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, at: CGPoint(x: 60, y: 184)))
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Updated text", style: target.style, bounds: target.bounds)
        let finalPage = try XCTUnwrap(try reopen(edited).page(at: 0))
        XCTAssertEqual(try sampleImageRegion(finalPage, xRange: 112..<169, yRange: 178..<199),
                       try sampleImageRegion(page, xRange: 112..<169, yRange: 178..<199))
    }

    @MainActor
    func testLosslessEditPreservesPatternWhileUnsafeNestedSiblingIsRefused() throws {
        let patterned = try fixture(pattern: true)
        let patternedPage = try XCTUnwrap(patterned.page(at: 0))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: patternedPage, at: CGPoint(x: 60, y: 184)))
        let before = try sampleImageRegion(patternedPage)
        let edited = try PDFBodyTextEditor.replacementPage(for: patternedPage, target: target,
            text: "Updated text", style: target.style, bounds: target.bounds)
        XCTAssertEqual(try sampleImageRegion(edited), before)
        XCTAssertTrue((patterned.string ?? "").contains("Original text"))
        let nested = try fixture(nested: true, laterFormSibling: true)
        let page = try XCTUnwrap(nested.page(at: 0))
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 60, y: 184)))
        XCTAssertEqual(nested.findString("Shared text", withOptions: []).count, 1)
    }

    @MainActor
    func testUnrelatedSoftMaskAndMiterStateRemainUnchanged() throws {
        for (paint, resources) in [
            ("/Soft gs 0 0 1 rg", "/ExtGState << /Soft << /SMask << /S /Alpha /G 7 0 R >> >> >>"),
            ("3 M 0 0 1 rg", "")
        ] {
            let source = try fixture(paintOverride: paint, additionalResources: resources)
            let page = try XCTUnwrap(source.page(at: 0))
            let before = try sampleImageRegion(page)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, at: CGPoint(x: 60, y: 184)))
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: "Updated text", style: target.style, bounds: target.bounds)
            XCTAssertEqual(try sampleImageRegion(edited), before)
            XCTAssertTrue((source.string ?? "").contains("Original text"))
        }
    }

    @MainActor
    func testTextInsideActiveSoftMaskStillRefusesUnsupportedAppearanceChange() throws {
        let source = try fixture(additionalResources: "/ExtGState << /Soft << /SMask << /S /Alpha /G 7 0 R >> >> >>",
                                 contentPrefix: "/Soft gs ")
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: XCTUnwrap(source.page(at: 0)), at: CGPoint(x: 60, y: 184)))
        XCTAssertTrue(source.string?.contains("Original text") == true)
    }

    @MainActor
    func testNestedTransparencyGroupAndBlendBoundaryAreRefused() throws {
        let grouped = try fixture(nested: true, singleForm: true,
            formProperties: "/Group << /S /Transparency /I true >>")
        let blended = try fixture(nested: true,
            additionalResources: "/ExtGState << /Blend << /BM /Multiply >> >>",
            singleForm: true, contentPrefix: "/Blend gs ")
        for source in [grouped, blended] {
            let page = try XCTUnwrap(source.page(at: 0))
            XCTAssertEqual(source.findString("Shared text", withOptions: []).count, 1)
            XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 60, y: 184)))
            XCTAssertEqual(source.findString("Shared text", withOptions: []).count, 1)
        }
    }

    @MainActor
    func testUserPasswordCannotBypassOwnerRequirement() throws {
        let source = try fixture()
        let data = try XCTUnwrap(source.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "owner-password", PDFDocumentWriteOption.userPasswordOption: "user-password"
        ]))
        let protected = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(protected.unlock(withPassword: "user-password"))
        let page = try XCTUnwrap(protected.page(at: 0))
        XCTAssertNotEqual(protected.permissionsStatus, .owner)
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 60, y: 185)))
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: nil, text: "Bypass", style: .standard(for: .freeText), bounds: CGRect(x: 50, y: 50, width: 100, height: 30)))
    }

    @MainActor
    func testBlankClickAndOversizedDraftDoNotAlterPage() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        XCTAssertNil(try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 350, y: 80)))
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: nil,
            text: String(repeating: "a", count: InlineTextDraftLimiter.maximumCharacterCount + 1),
            style: .standard(for: .freeText), bounds: CGRect(x: 50, y: 50, width: 100, height: 30)))
        XCTAssertTrue((source.string ?? "").contains("Original text"))
    }

    @MainActor
    private func lookupTarget(_ text: String, in document: PDFDocument) throws -> PDFBodyTextTarget {
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString(text, withOptions: []).first)
        let rect = selection.bounds(for: page)
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, at: CGPoint(x: rect.midX, y: rect.midY)))
    }

    private func reopen(_ page: PDFPage) throws -> PDFDocument {
        let document = PDFDocument()
        document.insert(page, at: 0)
        return try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
    }

    private func fixture(nested: Bool = false, angled: Bool = false, userUnit: Int = 1, nonzeroOrigin: Bool = false, cmyk: Bool = false, inlineImage: Bool = false, coverText: Bool = false, laterFormSibling: Bool = false, pattern: Bool = false, paintOverride: String? = nil, additionalResources: String = "", singleForm: Bool = false, formProperties: String = "", contentPrefix: String = "") throws -> PDFDocument {
        let media = nonzeroOrigin ? "10 15 400 300" : "0 0 400 300"
        let matrix = angled ? "0.866 0.5 -0.5 0.866 50 180" : "1 0 0 1 50 180"
        let content = nested
            ? (laterFormSibling || singleForm ? "q 1 0 0 1 50 180 cm /Shared Do Q" : "q 1 0 0 1 50 180 cm /Shared Do Q q 1 0 0 1 50 120 cm /Shared Do Q")
            : "BT /F1 18 Tf \(matrix) Tm (Original text) Tj ET BT /F1 18 Tf 1 0 0 1 50 130 Tm (Unaffected text) Tj ET"
        let bluePaint = paintOverride ?? (pattern ? "/Pattern cs /P1 scn" : cmyk ? "1 1 0 0 k" : "0 0 1 rg")
        let inline = inlineImage ? " q 10 0 0 10 260 80 cm BI /W 1 /H 1 /BPC 8 /CS /RGB /F /AHx ID 00FF00> EI Q" : ""
        let cover = coverText ? " q 0 0 1 rg 110 176 60 25 re f Q" : ""
        let drawing = contentPrefix + content + " q \(bluePaint) 290 40 40 30 re f Q q 35 0 0 35 300 80 cm /Im1 Do Q" + inline + cover
        func stream(_ text: String, dictionary: String = "") -> String {
            "<< \(dictionary) /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(media)] /UserUnit \(userUnit) /Resources << /Font << /F1 4 0 R >> /XObject << /Im1 6 0 R /Shared 7 0 R >> /Pattern << /P1 8 0 R >> \(additionalResources) >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            stream(drawing),
            stream("00FF00>", dictionary: "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode"),
            stream("BT /F1 18 Tf 1 0 0 1 0 0 Tm (Shared text) Tj ET" + (laterFormSibling ? " 0 0 1 rg 40 -4 60 25 re f" : ""), dictionary: "/Type /XObject /Subtype /Form /BBox [0 -10 200 40] /Resources << /Font << /F1 4 0 R >> >> \(formProperties)"),
            stream("1 0 0 rg 0 0 3 3 re f", dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 5 5] /XStep 5 /YStep 5 /Resources << >>"),
            stream("", dictionary: "/N 4 /Alternate /DeviceCMYK")
        ]
        return try document(objects: objects.map { Data($0.utf8) })
    }

    private func document(objects: [Data]) throws -> PDFDocument {
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n".utf8))
            data.append(object)
            data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func sampleImageRegion(_ page: PDFPage, xRange: Range<Int> = 290..<336, yRange: Range<Int> = 40..<116) throws -> Data {
        let width = 400, height = 300
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        var region = Data()
        for y in yRange {
            region.append(contentsOf: bytes[((height - 1 - y) * width + xRange.lowerBound) * 4..<((height - 1 - y) * width + xRange.upperBound) * 4])
        }
        XCTAssertTrue(region.contains { $0 != 255 }, "The fixture really contains nonwhite image/vector pixels")
        return region
    }
}
