// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class StudyNoteVisibilityTests: XCTestCase {
    private let flagsKey = PDFAnnotationKey(rawValue: "/F")

    func testSingleNoteHidingPreservesAppearanceLinkIdentityPrintAndAllOtherFlags() throws {
        let workspace = try makeWorkspace(pageCount: 1)
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let note = makeNote()
        let originalFlags = 4 | 8 | 16 | 64 | 128 | 256 | 512
        note.setValue(NSNumber(value: originalFlags), forAnnotationKey: flagsKey)
        let name = "Ember stable linked note"
        note.setValue(name, forAnnotationKey: .name)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        note.modificationDate = date
        page.addAnnotation(note)
        let item = try XCTUnwrap(workspace.studyNotes(on: 0).first)
        let contents = note.contents, bounds = note.bounds, background = note.color, ink = note.fontColor
        let metadata = note.value(forAnnotationKey: PDFStudyNoteStyle.metadataKey) as? String
        XCTAssertTrue(workspace.selectStudyNoteForLayout(item))

        XCTAssertTrue(workspace.setStudyNoteHidden(true, note: item))
        XCTAssertFalse(note.shouldDisplay)
        XCTAssertTrue(note.shouldPrint)
        XCTAssertNil(workspace.studyNoteLayoutSelection)
        XCTAssertEqual(flags(note), originalFlags | 32)
        XCTAssertEqual(note.contents, contents)
        XCTAssertEqual(note.bounds, bounds)
        XCTAssertEqual(note.color, background)
        XCTAssertEqual(note.fontColor, ink)
        XCTAssertEqual(note.value(forAnnotationKey: .name) as? String, name)
        XCTAssertEqual(note.value(forAnnotationKey: PDFStudyNoteStyle.metadataKey) as? String, metadata)
        XCTAssertEqual(workspace.studyNotes(on: 0).count, 1, "Hidden notes remain in the note list.")
        XCTAssertTrue(workspace.revealStudyNote(item))
        XCTAssertFalse(note.shouldDisplay, "Jumping to a hidden note must not implicitly reveal it.")
        workspace.undo()
        XCTAssertTrue(note.shouldDisplay)
        XCTAssertEqual(flags(note), originalFlags)
        XCTAssertEqual(note.modificationDate, date)
        XCTAssertFalse(workspace.isDirty)
        workspace.redo()
        XCTAssertFalse(note.shouldDisplay)
        XCTAssertEqual(flags(note), originalFlags | 32)
    }

    func testAllNotesAcrossPagesUseOneUndoAndNeverChangeOtherAnnotationKinds() throws {
        let workspace = try makeWorkspace(pageCount: 3)
        let document = try XCTUnwrap(workspace.document)
        var notes: [StudyNoteItem] = []
        var others: [PDFAnnotation] = []
        for index in 0..<3 {
            let page = try XCTUnwrap(document.page(at: index))
            let note = makeNote()
            note.shouldDisplay = index != 1
            note.shouldPrint = index != 2
            page.addAnnotation(note)
            for type in [PDFAnnotationSubtype.ink, .highlight, .link, .stamp] {
                let other = PDFAnnotation(bounds: CGRect(x: 1, y: 1, width: 8, height: 8), forType: type, withProperties: nil)
                page.addAnnotation(other)
                others.append(other)
            }
            notes.append(try XCTUnwrap(workspace.studyNotes(on: index).first))
        }
        let originalFlags = notes.map { flags($0.annotation) }
        let otherFlags = others.map(flags)
        XCTAssertTrue(workspace.setAllStudyNotesHidden(true, notes: notes + [notes[0]]))
        XCTAssertTrue(notes.allSatisfy { !$0.annotation.shouldDisplay })
        XCTAssertEqual(others.map(flags), otherFlags)
        XCTAssertTrue(notes[0].annotation.shouldPrint)
        XCTAssertFalse(notes[2].annotation.shouldPrint)
        workspace.undo()
        XCTAssertEqual(notes.map { flags($0.annotation) }, originalFlags)
        XCTAssertFalse(workspace.canUndo, "The bulk operation must be one history entry.")
        workspace.redo()
        XCTAssertTrue(notes.allSatisfy { !$0.annotation.shouldDisplay })
        XCTAssertTrue(workspace.setAllStudyNotesHidden(false, notes: notes))
        XCTAssertTrue(notes.allSatisfy { $0.annotation.shouldDisplay })
        workspace.undo()
        XCTAssertTrue(notes.allSatisfy { !$0.annotation.shouldDisplay })
    }

    func testHiddenNoteSurvivesSaveAndReopenAndDoesNotCoverThePage() throws {
        let workspace = try makeWorkspace(pageCount: 1)
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let note = makeNote()
        note.shouldPrint = true
        page.addAnnotation(note)
        let item = try XCTUnwrap(workspace.studyNotes(on: 0).first)
        XCTAssertLessThan(try backgroundPixel(page).greenComponent, 0.1)
        XCTAssertTrue(workspace.setStudyNoteHidden(true, note: item))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-note-\(UUID()).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: output) }
        XCTAssertTrue(workspace.saveSynchronously(as: output))
        let reopened = PDFWorkspaceState()
        XCTAssertTrue(reopened.open(url: output))
        reopened.setMode(.study)
        let saved = try XCTUnwrap(reopened.studyNotes(on: 0).first)
        let savedPage = try XCTUnwrap(reopened.document?.page(at: 0))
        XCTAssertFalse(saved.annotation.shouldDisplay)
        XCTAssertTrue(saved.annotation.shouldPrint)
        XCTAssertGreaterThan(try backgroundPixel(savedPage).greenComponent, 0.95)
        XCTAssertTrue(reopened.setStudyNoteHidden(false, note: saved))
        XCTAssertTrue(reopened.saveSynchronously())
        let shownDocument = try XCTUnwrap(PDFDocument(url: output))
        let shownPage = try XCTUnwrap(shownDocument.page(at: 0))
        XCTAssertTrue(try XCTUnwrap(shownPage.annotations.first).shouldDisplay)
        XCTAssertLessThan(try backgroundPixel(shownPage).greenComponent, 0.1)
    }

    func testAbsentFlagsFieldAndUnchangedVisibilityRemainExact() throws {
        let workspace = try makeWorkspace(pageCount: 1)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let note = makeNote()
        note.removeValue(forAnnotationKey: flagsKey)
        note.modificationDate = nil
        page.addAnnotation(note)
        let item = try XCTUnwrap(workspace.studyNotes(on: 0).first)
        XCTAssertFalse(workspace.setStudyNoteHidden(false, note: item))
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertTrue(workspace.setStudyNoteHidden(true, note: item))
        workspace.undo()
        XCTAssertNil(note.value(forAnnotationKey: flagsKey))
        XCTAssertNil(note.modificationDate)
        XCTAssertTrue(note.shouldDisplay)
    }

    func testPendingDraftForeignDetachedAndWrongKindTargetsAreRejectedAtomically() throws {
        let workspace = try makeWorkspace(pageCount: 1)
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let note = makeNote()
        page.addAnnotation(note)
        let item = try XCTUnwrap(workspace.studyNotes(on: 0).first)
        workspace.addStudyNote()
        XCTAssertFalse(workspace.canSetStudyNoteVisibility(item))
        XCTAssertFalse(workspace.setStudyNoteHidden(true, note: item))
        XCTAssertNotNil(workspace.pendingTextEdit)
        workspace.cancelPendingText()
        let foreign = StudyNoteItem(documentID: ObjectIdentifier(PDFDocument()), pageIndex: 0, annotation: note, contents: "foreign")
        XCTAssertFalse(workspace.setAllStudyNotesHidden(true, notes: [item, foreign]))
        XCTAssertTrue(note.shouldDisplay)
        let highlight = PDFAnnotation(bounds: .zero, forType: .highlight, withProperties: nil)
        page.addAnnotation(highlight)
        let wrongKind = StudyNoteItem(documentID: ObjectIdentifier(document), pageIndex: 0, annotation: highlight, contents: "")
        XCTAssertFalse(workspace.setAllStudyNotesHidden(true, notes: [item, wrongKind]))
        page.removeAnnotation(note)
        XCTAssertFalse(workspace.setStudyNoteHidden(true, note: item))
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
    }

    func testViewerAndUserPasswordSessionCannotSaveVisibilityChanges() throws {
        let workspace = try makeWorkspace(pageCount: 1)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        page.addAnnotation(makeNote())
        let item = try XCTUnwrap(workspace.studyNotes(on: 0).first)
        workspace.setMode(.viewer)
        XCTAssertFalse(workspace.setStudyNoteHidden(true, note: item))
        let encrypted = FileManager.default.temporaryDirectory.appendingPathComponent("visibility-permission-\(UUID()).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: encrypted) }
        XCTAssertTrue(try XCTUnwrap(workspace.document).write(to: encrypted, withOptions: [
            .ownerPasswordOption: "Owner9", .userPasswordOption: "Reader9",
            .accessPermissionsOption: NSNumber(value: 0)
        ]))
        let reader = PDFWorkspaceState(passwordProvider: { _, _ in "Reader9" })
        XCTAssertTrue(reader.open(url: encrypted))
        reader.setMode(.study)
        let protected = try XCTUnwrap(reader.studyNotes(on: 0).first)
        XCTAssertFalse(reader.canSetStudyNoteVisibility(protected))
        XCTAssertFalse(reader.setStudyNoteHidden(true, note: protected))
        XCTAssertTrue(protected.annotation.shouldDisplay)
        XCTAssertFalse(reader.isDirty)
    }

    func testBulkUndoValidatesEveryAnnotationBeforeRestoringAnyFlags() throws {
        let workspace = try makeWorkspace(pageCount: 2)
        var notes: [StudyNoteItem] = []
        for index in 0..<2 {
            let page = try XCTUnwrap(workspace.document?.page(at: index))
            page.addAnnotation(makeNote())
            notes.append(try XCTUnwrap(workspace.studyNotes(on: index).first))
        }
        XCTAssertTrue(workspace.setAllStudyNotesHidden(true, notes: notes))
        notes[1].annotation.shouldPrint.toggle() // An external, untracked change.
        workspace.undo()
        XCTAssertFalse(notes[0].annotation.shouldDisplay)
        XCTAssertFalse(notes[1].annotation.shouldDisplay)
        XCTAssertNotNil(workspace.presentedError)
    }

    private func flags(_ annotation: PDFAnnotation) -> Int? {
        (annotation.value(forAnnotationKey: flagsKey) as? NSNumber)?.intValue
    }

    private func makeNote() -> PDFAnnotation {
        PDFStudyNoteAnnotation(bounds: CGRect(x: 20, y: 30, width: 150, height: 90),
            contents: "Visible note", font: .systemFont(ofSize: 15), background: .red, foreground: .black)
    }

    private func makeWorkspace(pageCount: Int) throws -> PDFWorkspaceState {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { bounds in
                NSColor.white.setFill(); bounds.fill(); return true
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-visibility-\(UUID()).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.study)
        return workspace
    }

    private func backgroundPixel(_ page: PDFPage) throws -> NSColor {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        page.draw(with: .cropBox, to: graphics.cgContext)
        graphics.flushGraphics()
        return try XCTUnwrap(bitmap.colorAt(x: 80, y: 150)?.usingColorSpace(.sRGB))
    }
}
