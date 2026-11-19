// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class StudyNoteStyleTests: XCTestCase {
    func testTransparentBackgroundAndOpaqueTextSurviveSaveAndReopen() throws {
        let document = try makeDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let noteBounds = CGRect(x: 20, y: 30, width: 150, height: 90)
        let background = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 0.3)
        // Paint an independent reference swatch in the same explicit color
        // space. NSColor's generic/device colors are color managed and do
        // not necessarily become the nominal 77/77/177 RGB bytes.
        let reference = try render(page, backgroundSwatch: (noteBounds, background))
        let expected = pixel(reference, x: 80, y: 150)
        let note = PDFStudyNoteAnnotation(bounds: noteBounds,
            contents: "VISIBLE TEXT", font: .systemFont(ofSize: 15),
            background: background, foreground: .black)
        page.addAnnotation(note)
        XCTAssertNil(note.userName)
        let reopened = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
        let loaded = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertEqual(loaded.type, "FreeText")
        XCTAssertEqual(loaded.contents, "VISIBLE TEXT")
        XCTAssertEqual(PDFStudyNoteStyle(annotation: loaded).backgroundOpacity, 0.3, accuracy: 0.001)
        XCTAssertNil(loaded.userName)
        let pixels = try render(XCTUnwrap(reopened.page(at: 0)))
        let color = pixel(pixels, x: 80, y: 150)
        XCTAssertEqual(color.0, expected.0, accuracy: 4)
        XCTAssertEqual(color.1, expected.1, accuracy: 4)
        XCTAssertEqual(color.2, expected.2, accuracy: 4)
        XCTAssertGreaterThan(color.2, 100, "The blue PDF must show through the yellow note background.")
        let blackPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] < 20 && pixels[$0 + 1] < 20 && pixels[$0 + 2] < 20 && pixels[$0 + 3] > 245
        }
        XCTAssertGreaterThan(blackPixels.count, 10, "Text must remain opaque while the background reveals the PDF.")
    }

    func testStyleEditPreservesContentsAndExactAnnotationOrderWithUndoRedo() throws {
        let (workspace, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let first = PDFAnnotation(bounds: CGRect(x: 1, y: 1, width: 5, height: 5), forType: .link, withProperties: nil)
        let note = makePlainNote()
        let last = PDFAnnotation(bounds: CGRect(x: 2, y: 2, width: 5, height: 5), forType: .widget, withProperties: nil)
        [first, note, last].forEach(page.addAnnotation)
        let item = item(note, in: document)
        var style = PDFStudyNoteStyle(annotation: note)
        style.bounds = CGRect(x: 40, y: 50, width: 90, height: 60)
        style.backgroundOpacity = 0.25
        style.background = .green
        style.foreground = .red
        let updated = try XCTUnwrap(workspace.applyStudyNoteStyle(style, to: item))
        XCTAssertTrue(updated.annotation is PDFStudyNoteAnnotation)
        XCTAssertEqual(updated.annotation.contents, note.contents)
        XCTAssertEqual(page.annotations.count, 3)
        XCTAssertTrue(page.annotations[0] === first)
        XCTAssertTrue(page.annotations[1] === updated.annotation)
        XCTAssertTrue(page.annotations[2] === last)
        XCTAssertEqual(updated.annotation.bounds, style.bounds)
        XCTAssertTrue(workspace.allowsAnnotationEditing(.freeText, annotation: updated.annotation))
        workspace.undo()
        XCTAssertTrue(page.annotations[1] === note)
        XCTAssertEqual(note.bounds, CGRect(x: 20, y: 30, width: 150, height: 90))
        workspace.redo()
        XCTAssertTrue(page.annotations[1] === updated.annotation)
        XCTAssertEqual(PDFStudyNoteStyle(annotation: updated.annotation).backgroundOpacity, 0.25, accuracy: 0.001)
    }

    func testApplyingChosenRGBAndOpacityToReopenedNotePreservesSavedAppearance() throws {
        for opacity: CGFloat in [0.35, 0, 1] {
            let source = try makeDocument()
            source.page(at: 0)?.addAnnotation(makePlainNote())
            let reopened = try XCTUnwrap(PDFDocument(data: XCTUnwrap(source.dataRepresentation())))
            let original = try XCTUnwrap(reopened.page(at: 0)?.annotations.first?.copy() as? PDFAnnotation)
            let (workspace, url) = try makeWorkspace()
            defer { workspace.closeDiscardingChanges(); try? FileManager.default.removeItem(at: url) }
            let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
            let background = NSColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 1)
            let foreground = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            let reference = try render(page, backgroundSwatch: (original.bounds, background.withAlphaComponent(opacity)))
            page.addAnnotation(original)
            var style = PDFStudyNoteStyle(annotation: original)
            style.background = background
            style.foreground = foreground
            style.backgroundOpacity = opacity
            let updated = try XCTUnwrap(workspace.applyStudyNoteStyle(style, to: item(original, in: document)))
            XCTAssertEqual(updated.contents, original.contents)
            // This fails without retaining the chosen sRGB: PDFKit's /DA
            // roundtrip changes pure sRGB red to a calibrated red with green.
            assertRGB(PDFStudyNoteStyle(annotation: updated.annotation).foreground, equals: foreground)
            let saved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
            let savedPage = try XCTUnwrap(saved.page(at: 0)), savedNote = try XCTUnwrap(savedPage.annotations.first)
            let savedStyle = PDFStudyNoteStyle(annotation: savedNote)
            assertRGB(savedStyle.background, equals: background)
            assertRGB(savedStyle.foreground, equals: foreground)
            XCTAssertEqual(savedStyle.backgroundOpacity, opacity, accuracy: 0.001)
            let pixels = try render(savedPage), expected = pixel(reference, x: 80, y: 150)
            let actual = pixel(pixels, x: 80, y: 150)
            XCTAssertEqual(actual.0, expected.0, accuracy: 3)
            XCTAssertEqual(actual.1, expected.1, accuracy: 3)
            XCTAssertEqual(actual.2, expected.2, accuracy: 3)
            let opaqueRedPixels = stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 245 && pixels[$0 + 1] < 15 && pixels[$0 + 2] < 15 && pixels[$0 + 3] > 245
            }
            XCTAssertGreaterThan(opaqueRedPixels.count, 20, "The chosen text color must stay opaque at every background opacity.")
        }
    }

    func testExternalDefaultAppearanceChangeOverridesSavedTextColorMetadata() throws {
        let original = makePlainNote()
        var style = PDFStudyNoteStyle(annotation: original)
        style.foreground = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let note = PDFStudyNoteAnnotation(copying: original, style: style)
        assertRGB(PDFStudyNoteStyle(annotation: note).foreground, equals: style.foreground)
        // Another PDF editor can change the standard DA without knowing our
        // private metadata. Its new color must win when that happens.
        note.fontColor = NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1)
        assertRGB(PDFStudyNoteStyle(annotation: note).foreground, equals: try XCTUnwrap(note.fontColor))
    }

    func testStyleEditPreservesHiddenAndOtherStandardFlags() throws {
        let (workspace, url) = try makeWorkspace()
        defer { workspace.closeDiscardingChanges(); try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let note = makePlainNote()
        let flags = 4 | 8 | 16 | 32 | 128 // Print, NoZoom, NoRotate, NoView, Locked.
        note.setValue(flags, forAnnotationKey: .flags)
        page.addAnnotation(note)
        let original = item(note, in: document)
        XCTAssertFalse(workspace.selectStudyNoteForLayout(original))
        var style = PDFStudyNoteStyle(annotation: note)
        style.backgroundOpacity = 0.4
        let updated = try XCTUnwrap(workspace.applyStudyNoteStyle(style, to: original))
        XCTAssertEqual((updated.annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue, flags)
        XCTAssertFalse(updated.annotation.shouldDisplay)
        XCTAssertTrue(updated.annotation.shouldPrint)
        XCTAssertFalse(workspace.isExplicitlySelectedStudyNote(updated.annotation))
        workspace.undo()
        XCTAssertTrue(page.annotations.first === note)
        XCTAssertEqual((note.value(forAnnotationKey: .flags) as? NSNumber)?.intValue, flags)
        workspace.redo()
        XCTAssertTrue(page.annotations.first === updated.annotation)
        let saved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
        let savedNote = try XCTUnwrap(saved.page(at: 0)?.annotations.first)
        XCTAssertEqual((savedNote.value(forAnnotationKey: .flags) as? NSNumber)?.intValue, flags)
    }

    func testOnlyExplicitLiveNoteGetsStudyGeometryAuthority() throws {
        let (workspace, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let note = makePlainNote(), other = makePlainNote()
        EditableAnnotationIdentity.assign(.freeText, to: note)
        EditableAnnotationIdentity.assign(.freeText, to: other)
        page.addAnnotation(note); page.addAnnotation(other)
        XCTAssertFalse(workspace.allowsAnnotationEditing(.freeText, annotation: note))
        XCTAssertTrue(workspace.selectStudyNoteForLayout(item(note, in: document)))
        XCTAssertTrue(workspace.allowsAnnotationEditing(.freeText, annotation: note))
        XCTAssertFalse(workspace.allowsAnnotationEditing(.freeText, annotation: other))
        let originalBounds = note.bounds
        note.bounds.origin.x += 10
        workspace.registerAnnotationGeometryChange(note, on: page, from: originalBounds,
            originalModificationDate: note.modificationDate, message: "Resize selected note")
        workspace.undo()
        XCTAssertEqual(note.bounds, originalBounds)
        page.removeAnnotation(note)
        XCTAssertFalse(workspace.isExplicitlySelectedStudyNote(note))
        workspace.setMode(.viewer)
        XCTAssertFalse(workspace.selectStudyNoteForLayout(item(other, in: document)))
    }

    func testStyleAndTextRequestsRejectOtherDocumentAndStaleAnnotations() throws {
        let (workspace, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let note = makePlainNote()
        page.addAnnotation(note)
        let other = try makeDocument()
        let stale = item(note, in: other)
        XCTAssertNil(workspace.applyStudyNoteStyle(PDFStudyNoteStyle(annotation: note), to: stale))
        page.removeAnnotation(note)
        XCTAssertFalse(workspace.commitExistingStudyNoteText(note, on: page, text: "Unexpected"))
        XCTAssertFalse(workspace.selectStudyNoteForLayout(item(note, in: document)))
    }

    func testEditingReopenedNoteTextPreservesIndependentOpacity() throws {
        let (workspace, url) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let plain = makePlainNote()
        var style = PDFStudyNoteStyle(annotation: plain)
        style.backgroundOpacity = 0
        let styled = PDFStudyNoteAnnotation(copying: plain, style: style)
        let detached = try makeDocument()
        detached.page(at: 0)?.addAnnotation(styled)
        let saved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(detached.dataRepresentation())))
        let reopened = try XCTUnwrap(saved.page(at: 0)?.annotations.first?.copy() as? PDFAnnotation)
        page.addAnnotation(reopened)
        XCTAssertFalse(reopened is PDFStudyNoteAnnotation)
        XCTAssertTrue(workspace.commitExistingStudyNoteText(reopened, on: page, text: "Revised"))
        let edited = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(edited.contents, "Revised")
        XCTAssertEqual(PDFStudyNoteStyle(annotation: edited).backgroundOpacity, 0)
        XCTAssertEqual(edited.bounds, reopened.bounds)
        let resaved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
        XCTAssertEqual(PDFStudyNoteStyle(annotation: try XCTUnwrap(resaved.page(at: 0)?.annotations.first)).backgroundOpacity, 0)
        workspace.undo()
        XCTAssertTrue(page.annotations.first === reopened)
        workspace.redo()
        XCTAssertTrue(page.annotations.first === edited)
    }

    func testInvalidStyleIsRejectedAndOversizeDimensionsStayOnPage() throws {
        let pageBounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        var style = PDFStudyNoteStyle(annotation: makePlainNote())
        style.bounds = CGRect(x: -1000, y: 5000, width: 8000, height: 5000)
        let clamped = try XCTUnwrap(style.constrained(to: pageBounds))
        XCTAssertEqual(clamped.bounds, pageBounds)
        style.backgroundOpacity = .nan
        XCTAssertNil(style.constrained(to: pageBounds))
    }

    private func makePlainNote() -> PDFAnnotation {
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 150, height: 90), forType: .freeText, withProperties: nil)
        note.contents = "Original note"
        note.color = .yellow
        note.font = .systemFont(ofSize: 15)
        note.fontColor = .black
        return note
    }

    private func item(_ annotation: PDFAnnotation, in document: PDFDocument) -> StudyNoteItem {
        StudyNoteItem(documentID: ObjectIdentifier(document), pageIndex: 0,
                      annotation: annotation, contents: annotation.contents ?? "")
    }

    private func makeWorkspace() throws -> (PDFWorkspaceState, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-note-style-\(UUID()).pdf")
        XCTAssertTrue(try makeDocument().write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.study)
        return (workspace, url)
    }

    private func makeDocument() throws -> PDFDocument {
        let image = NSImage(size: CGSize(width: 200, height: 200), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        return document
    }

    private func render(_ page: PDFPage, backgroundSwatch: (CGRect, NSColor)? = nil) throws -> [UInt8] {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
            bytesPerRow: 800, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        page.draw(with: .cropBox, to: context)
        if let (bounds, color) = backgroundSwatch {
            context.setFillColor(color.cgColor)
            context.fill(bounds)
        }
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 160_000))
    }

    private func pixel(_ pixels: [UInt8], x: Int, y: Int) -> (Double, Double, Double) {
        let offset = y * 800 + x * 4
        return (Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
    }

    private func assertRGB(_ actual: NSColor, equals expected: NSColor,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let actual = actual.usingColorSpace(.sRGB), let expected = expected.usingColorSpace(.sRGB) else {
            XCTFail("Expected convertible RGB colors", file: file, line: line); return
        }
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
    }
}
