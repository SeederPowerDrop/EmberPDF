// SPDX-License-Identifier: MPL-2.0
import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFEraserGestureTests: XCTestCase {
    func testHiddenNotesAndInkAreNeverErasedByAPointerGesture() throws {
        let (workspace, page) = try fixture()
        workspace.setMode(.editing)
        workspace.activeTool = .eraser
        let line = ink()
        let note = PDFAnnotation(bounds: line.bounds, forType: .freeText, withProperties: nil)
        note.contents = "Hidden explanation"
        for annotation in [note, line] {
            annotation.shouldDisplay = false
            page.addAnnotation(annotation)
        }
        for mode in [PDFEraserMode.stroke, .partial] {
            let gesture = try XCTUnwrap(PDFEraserGesture(workspace: workspace, page: page))
            XCTAssertFalse(gesture.erase(from: CGPoint(x: 90, y: 40), to: CGPoint(x: 90, y: 60), radius: 4, mode: mode))
            gesture.finish()
        }
        XCTAssertFalse(workspace.removeAnnotationWithEraser(note, from: page))
        XCTAssertEqual(page.annotations.count, 2)
        XCTAssertTrue(page.annotations[0] === note)
        XCTAssertTrue(page.annotations[1] === line)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
    }

    func testContinuousPartialErasingHasOneUndoAndKeepsOtherAnnotationsInOrder() throws {
        let (workspace, page) = try fixture()
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 140, height: 100), forType: .freeText, withProperties: nil)
        note.contents = "Keep this note"
        let line = ink()
        let stamp = PDFAnnotation(bounds: note.bounds, forType: .stamp, withProperties: nil)
        [note, line, stamp].forEach(page.addAnnotation)
        let gesture = try XCTUnwrap(PDFEraserGesture(workspace: workspace, page: page))
        XCTAssertTrue(gesture.erase(from: CGPoint(x: 70, y: 40), to: CGPoint(x: 70, y: 60), radius: 4, mode: .partial))
        XCTAssertTrue(gesture.erase(from: CGPoint(x: 120, y: 40), to: CGPoint(x: 120, y: 60), radius: 4, mode: .partial))
        gesture.finish()
        gesture.finish()
        XCTAssertEqual(page.annotations.count, 3)
        XCTAssertTrue(page.annotations[0] === note)
        XCTAssertTrue(page.annotations[2] === stamp)
        XCTAssertFalse(page.annotations[1] === line)
        XCTAssertEqual(page.annotations[1].paths?.count, 3)
        XCTAssertTrue(workspace.isDirty)
        workspace.undo()
        XCTAssertTrue(page.annotations[1] === line)
        XCTAssertFalse(workspace.canUndo, "The whole drag is one transaction.")
        XCTAssertFalse(workspace.isDirty)
        workspace.redo()
        XCTAssertEqual(page.annotations[1].paths?.count, 3)
    }

    func testStrokeModeErasesActualInkAndDoesNotEraseUntrustedNoteOrStamp() throws {
        let (workspace, page) = try fixture()
        let line = ink()
        let note = PDFAnnotation(bounds: line.bounds, forType: .freeText, withProperties: nil)
        let stamp = PDFAnnotation(bounds: line.bounds, forType: .stamp, withProperties: nil)
        [note, line, stamp].forEach(page.addAnnotation)
        let gesture = try XCTUnwrap(PDFEraserGesture(workspace: workspace, page: page))
        XCTAssertTrue(gesture.erase(from: CGPoint(x: 90, y: 40), to: CGPoint(x: 90, y: 60), radius: 3, mode: .stroke))
        gesture.finish()
        XCTAssertEqual(page.annotations.count, 2)
        XCTAssertTrue(page.annotations[0] === note)
        XCTAssertTrue(page.annotations[1] === stamp)
        workspace.undo()
        XCTAssertTrue(page.annotations[1] === line)
    }

    func testReopenedInkCanBePartiallyErasedInStudy() throws {
        let (workspace, page) = try fixture(annotations: [ink()])
        let original = try XCTUnwrap(page.annotations.first)
        XCTAssertFalse(workspace.allowsEraserRemoval(of: original), "The older arbitrary-object API still requires runtime provenance.")
        let gesture = try XCTUnwrap(PDFEraserGesture(workspace: workspace, page: page))
        XCTAssertTrue(gesture.erase(from: CGPoint(x: 90, y: 40), to: CGPoint(x: 90, y: 60), radius: 4, mode: .partial))
        gesture.finish()
        XCTAssertEqual(page.annotations.first?.paths?.count, 2)
        let data = try XCTUnwrap(workspace.document?.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        XCTAssertEqual(reopened.annotations.first?.paths?.count, 2)
    }

    func testBlankSpaceAndRevokedToolDoNotCreateEdits() throws {
        let (workspace, page) = try fixture(annotations: [ink()])
        let original = try XCTUnwrap(page.annotations.first)
        let gesture = try XCTUnwrap(PDFEraserGesture(workspace: workspace, page: page))
        XCTAssertFalse(gesture.erase(from: CGPoint(x: 90, y: 180), to: CGPoint(x: 100, y: 180), radius: 4, mode: .partial))
        workspace.activeTool = .select
        XCTAssertFalse(gesture.erase(from: CGPoint(x: 90, y: 40), to: CGPoint(x: 90, y: 60), radius: 4, mode: .stroke))
        gesture.finish()
        XCTAssertTrue(page.annotations.first === original)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertNil(PDFEraserGesture(workspace: workspace, page: page))
        workspace.setMode(.viewer)
        workspace.activeTool = .eraser
        XCTAssertNil(PDFEraserGesture(workspace: workspace, page: page))
    }

    func testExternalAnnotationMutationRejectsStaleGesture() throws {
        let (workspace, page) = try fixture(annotations: [ink()])
        let gesture = try XCTUnwrap(PDFEraserGesture(workspace: workspace, page: page))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 150, width: 50, height: 30), forType: .text, withProperties: nil))
        let externalOrder = page.annotations
        XCTAssertFalse(gesture.erase(from: CGPoint(x: 90, y: 40), to: CGPoint(x: 90, y: 60), radius: 4, mode: .stroke))
        gesture.finish()
        XCTAssertEqual(page.annotations.count, externalOrder.count)
        XCTAssertTrue(zip(page.annotations, externalOrder).allSatisfy { $0 === $1 })
        XCTAssertFalse(workspace.canUndo)
    }

    func testUndoDuringDragSettlesTheGestureBeforeHistoryTraversal() throws {
        let (workspace, page) = try fixture(annotations: [ink()])
        let original = try XCTUnwrap(page.annotations.first)
        let gesture = try XCTUnwrap(PDFEraserGesture(workspace: workspace, page: page))
        let hookID = UUID()
        workspace.installDeactivationCommitHandler(id: hookID) { gesture.finish() }
        defer { workspace.removeDeactivationCommitHandler(id: hookID) }
        XCTAssertTrue(gesture.erase(from: CGPoint(x: 90, y: 40), to: CGPoint(x: 90, y: 60), radius: 4, mode: .partial))
        workspace.undo()
        XCTAssertTrue(gesture.isFinished)
        XCTAssertTrue(page.annotations.first === original)
        XCTAssertFalse(workspace.isDirty)
        workspace.redo()
        XCTAssertEqual(page.annotations.first?.paths?.count, 2)
    }

    private func ink() -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: 15, y: 45, width: 150, height: 10), forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 5, y: 5))
        path.line(to: CGPoint(x: 145, y: 5))
        path.lineCapStyle = .round
        annotation.add(path)
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        annotation.color = .blue
        return annotation
    }

    private func fixture(annotations: [PDFAnnotation] = []) throws -> (PDFWorkspaceState, PDFPage) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Eraser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.pdf")
        let image = NSImage(size: CGSize(width: 200, height: 240), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: image))
        document.insert(page, at: 0)
        annotations.forEach(page.addAnnotation)
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.study)
        workspace.activeTool = .eraser
        return (workspace, try XCTUnwrap(workspace.document?.page(at: 0)))
    }
}
