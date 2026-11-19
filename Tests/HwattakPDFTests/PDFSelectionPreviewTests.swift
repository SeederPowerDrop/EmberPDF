// SPDX-License-Identifier: MPL-2.0

import Combine
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFSelectionPreviewTests: XCTestCase {
    func testPreviewReadsLatestTextWithoutPublishingAndCommitsOnce() {
        let workspace = PDFWorkspaceState()
        let document = makeDocument()
        var notifications = 0
        let observer = workspace.objectWillChange.sink { notifications += 1 }
        defer { observer.cancel() }
        let id = workspace.beginSelectionPreview()

        for index in 0..<120 {
            let selection = makeSelection("Current text \(index)", document: document)
            XCTAssertTrue(workspace.updateSelectionPreview(selection, id: id))
            XCTAssertTrue(workspace.currentSelection === selection)
            XCTAssertEqual(workspace.currentSelection?.string, "Current text \(index)")
        }

        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(workspace.commitSelectionPreview(id))
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(workspace.currentSelection?.string, "Current text 119")
        XCTAssertFalse(workspace.ownsSelectionPreview(id))
        XCTAssertFalse(workspace.commitSelectionPreview(id))
        workspace.cancelSelectionPreview(id)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(workspace.currentSelection?.string, "Current text 119")
    }

    func testOrdinarySelectionPublishesBeforeMutationAndSkipsIdenticalValues() {
        let workspace = PDFWorkspaceState()
        let document = makeDocument()
        let first = makeSelection("First", document: document)
        let second = makeSelection("Second", document: document)
        var observedValues: [PDFSelection?] = []
        let observer = workspace.objectWillChange.sink {
            observedValues.append(workspace.currentSelection)
        }
        defer { observer.cancel() }

        workspace.currentSelection = first
        workspace.currentSelection = first
        workspace.currentSelection = second
        workspace.currentSelection = nil
        workspace.currentSelection = nil

        XCTAssertEqual(observedValues.count, 3)
        XCTAssertNil(observedValues[0])
        XCTAssertTrue(observedValues[1] === first)
        XCTAssertTrue(observedValues[2] === second)
    }

    func testExternalNilWriteTakesOverEvenBeforeAnyPreviewTextExists() {
        let workspace = PDFWorkspaceState()
        let document = makeDocument()
        let id = workspace.beginSelectionPreview()
        workspace.currentSelection = nil

        XCTAssertFalse(workspace.ownsSelectionPreview(id))
        XCTAssertFalse(workspace.updateSelectionPreview(makeSelection("Stale", document: document), id: id))
        XCTAssertFalse(workspace.commitSelectionPreview(id))
        workspace.cancelSelectionPreview(id)
        XCTAssertNil(workspace.currentSelection)
    }

    func testSearchTakeoverAndNewPreviewRejectOldCallbacks() {
        let workspace = PDFWorkspaceState()
        let document = makeDocument()
        let oldID = workspace.beginSelectionPreview()
        XCTAssertTrue(workspace.updateSelectionPreview(makeSelection("Drag", document: document), id: oldID))
        let search = makeSelection("Search result", document: document)
        workspace.currentSelection = search

        workspace.cancelSelectionPreview(oldID)
        XCTAssertFalse(workspace.commitSelectionPreview(oldID))
        XCTAssertTrue(workspace.currentSelection === search)

        let newerID = workspace.beginSelectionPreview()
        XCTAssertFalse(workspace.updateSelectionPreview(nil, id: oldID))
        XCTAssertTrue(workspace.ownsSelectionPreview(newerID))
        // The ordinary setter must also revoke ownership for the same object.
        workspace.currentSelection = search
        XCTAssertFalse(workspace.ownsSelectionPreview(newerID))
        workspace.cancelSelectionPreview(newerID)
        XCTAssertTrue(workspace.currentSelection === search)
    }

    func testCancelClearsOnlyOwnedPreviewAndPublishesOnceWhenNeeded() {
        let workspace = PDFWorkspaceState()
        let document = makeDocument()
        var notifications = 0
        let observer = workspace.objectWillChange.sink { notifications += 1 }
        defer { observer.cancel() }
        let emptyID = workspace.beginSelectionPreview()
        workspace.cancelSelectionPreview(emptyID)
        XCTAssertEqual(notifications, 0)

        let id = workspace.beginSelectionPreview()
        XCTAssertTrue(workspace.updateSelectionPreview(makeSelection("Preview", document: document), id: id))
        workspace.cancelSelectionPreview(id)
        XCTAssertNil(workspace.currentSelection)
        XCTAssertEqual(notifications, 1)
        workspace.cancelSelectionPreview(id)
        XCTAssertEqual(notifications, 1)

        let replacementID = workspace.beginSelectionPreview()
        let latestID = workspace.beginSelectionPreview()
        XCTAssertTrue(workspace.updateSelectionPreview(makeSelection("Latest", document: document), id: latestID))
        workspace.cancelSelectionPreview(replacementID)
        XCTAssertEqual(workspace.currentSelection?.string, "Latest")
        XCTAssertTrue(workspace.ownsSelectionPreview(latestID))
    }

    private func makeDocument() -> PDFDocument {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        return document
    }

    private func makeSelection(_ text: String, document: PDFDocument) -> PDFRegionTextSelection {
        PDFRegionTextSelection(document: document, page: document.page(at: 0)!, fragments: [
            PDFRegionTextFragment(text: text, bounds: CGRect(x: 10, y: 10, width: 100, height: 12))
        ])
    }
}
