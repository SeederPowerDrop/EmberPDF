// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class StudyNotesPerformanceTests: XCTestCase {
    func testEditingAndUndoOnlyRescanTheChangedPage() async throws {
        let (workspace, url) = try makeWorkspace(pageCount: 80)
        defer { try? FileManager.default.removeItem(at: url) }
        let index = workspace.studyNotesIndex
        XCTAssertFalse(index.isComplete)
        await index.refresh(workspace: workspace)
        XCTAssertEqual(index.scannedPageCount, 80)
        XCTAssertTrue(index.isComplete)
        workspace.requestTextEdit(pageIndex: 39, point: CGPoint(x: 20, y: 170), annotation: nil)
        workspace.commitPendingText("Middle of book")
        XCTAssertFalse(index.isComplete, "Bulk actions must stop before the next refresh task starts.")
        XCTAssertFalse(index.isScanning)
        await index.refresh(workspace: workspace)
        XCTAssertEqual(index.scannedPageCount, 81)
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.notes.map(\.pageIndex), [39])
        workspace.undo()
        await index.refresh(workspace: workspace)
        XCTAssertEqual(index.scannedPageCount, 82)
        XCTAssertTrue(index.notes.isEmpty)
        workspace.redo()
        await index.refresh(workspace: workspace)
        XCTAssertEqual(index.scannedPageCount, 83)
        XCTAssertEqual(index.notes.first?.contents, "Middle of book")
        await index.refresh(workspace: workspace)
        XCTAssertEqual(index.scannedPageCount, 83, "Reopening the sidebar should reuse the index.")
    }

    func testTypingDraftDoesNotPublishWorkspaceOrMutatePDF() throws {
        let (workspace, url) = try makeWorkspace(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        workspace.addStudyNote()
        let draft = try XCTUnwrap(workspace.pendingTextEdit)
        var publications = 0
        let observer = workspace.objectWillChange.sink { publications += 1 }
        defer { observer.cancel() }
        for number in 1...100 { workspace.updatePendingTextDraft(id: draft.id, text: "Typing \(number)") }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(draft.initialText, "Typing 100")
        XCTAssertTrue(workspace.pendingTextEdit === draft)
        XCTAssertEqual(workspace.document?.page(at: 0)?.annotations.count, 0)
        XCTAssertFalse(workspace.isDirty)
        workspace.noteEditorFloating = true
        workspace.prepareForDeactivation()
        XCTAssertEqual(workspace.pendingTextEdit?.initialText, "Typing 100")
    }

    func testClosingDocumentReleasesCachedNotes() async throws {
        let (workspace, url) = try makeWorkspace(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        workspace.addStudyNote()
        workspace.commitPendingText("Cached")
        await workspace.studyNotesIndex.refresh(workspace: workspace)
        XCTAssertEqual(workspace.studyNotesIndex.notes.count, 1)
        workspace.closeDiscardingChanges()
        XCTAssertTrue(workspace.studyNotesIndex.notes.isEmpty)
        XCTAssertFalse(workspace.studyNotesIndex.isComplete)
    }

    func testSupersededRefreshCannotClearReplacementScanState() async throws {
        let (workspace, url) = try makeWorkspace(pageCount: 80)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(workspace.document)
        for pageIndex in 0..<document.pageCount {
            let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 100, height: 40),
                                           forType: .freeText, withProperties: nil)
            annotation.contents = "Page \(pageIndex + 1)"
            document.page(at: pageIndex)?.addAnnotation(annotation)
        }
        let index = workspace.studyNotesIndex
        let original = Task { @MainActor in await index.refresh(workspace: workspace) }
        let beganOriginal = await waitUntil { index.isScanning }
        XCTAssertTrue(beganOriginal)
        var beganReplacement = false
        let replacement = Task { @MainActor in
            beganReplacement = true
            await index.refresh(workspace: workspace)
        }
        let startedReplacement = await waitUntil { beganReplacement }
        XCTAssertTrue(startedReplacement)
        original.cancel()
        await original.value
        XCTAssertTrue(index.isScanning, "An old task's defer must not finish the current scan.")
        XCTAssertFalse(index.isComplete)
        XCTAssertLessThan(index.notes.count, 80)
        await replacement.value
        XCTAssertFalse(index.isScanning)
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.notes.count, 80)
        XCTAssertEqual(index.scannedPageCount, 80, "A superseded task must stop scanning pages.")
    }

    func testCanceledPartialIndexRemainsIncompleteUntilResumed() async throws {
        let (workspace, url) = try makeWorkspace(pageCount: 80)
        defer { try? FileManager.default.removeItem(at: url) }
        let index = workspace.studyNotesIndex
        let scan = Task { @MainActor in await index.refresh(workspace: workspace) }
        let started = await waitUntil { index.isScanning }
        XCTAssertTrue(started)
        scan.cancel()
        await scan.value
        XCTAssertFalse(index.isScanning)
        XCTAssertFalse(index.isComplete, "Canceled partial results cannot drive an all-notes action.")
        XCTAssertLessThan(index.scannedPageCount, 80)
        await index.refresh(workspace: workspace)
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.scannedPageCount, 80)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    private func makeWorkspace(pageCount: Int) throws -> (PDFWorkspaceState, URL) {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
            document.insert(page, at: index)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-note-perf-\(UUID()).pdf")
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.study)
        return (workspace, url)
    }
}
