// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class StudyLinkTargetCatalogTests: XCTestCase {
    func testPageDraftAcceptsTwelveAndLocalizedDigitsWithoutChangingIntermediateInput() {
        var draft = StudyLinkPageDraft(pageIndex: 0)
        draft.text = "1"
        XCTAssertEqual(draft.pageIndex(pageCount: 120), 0)
        draft.text = "12"
        XCTAssertEqual(draft.pageIndex(pageCount: 120), 11)
        draft.text = "120"
        XCTAssertEqual(draft.pageIndex(pageCount: 120), 119)
        draft.text = "١٢"
        XCTAssertEqual(draft.pageIndex(pageCount: 120), 11)
        draft.text = "１２"
        XCTAssertEqual(draft.pageIndex(pageCount: 120), 11)
        for text in ["", "0", "121", "-1", "12.0", "123456789012345", "page 12"] {
            draft.text = text
            XCTAssertNil(draft.pageIndex(pageCount: 120))
            XCTAssertEqual(draft.text, text, "validation must never rewrite an in-progress draft")
        }
    }

    @MainActor
    func testLazyTargetLoadsActualPageCountWithoutChangingActiveDocumentOrTargetPage() async throws {
        let target = try makeWorkspace(pageCount: 12)
        target.currentPageIndex = 4
        target.selectedPages = [4]
        XCTAssertTrue(target.hibernateIfPossible())
        let source = PDFWorkspaceState()
        let container = MultiDocumentWorkspaceState(initialSession: PDFTabSession(workspace: source))
        let activeID = container.activeTabID
        let catalog = StudyLinkTargetCatalog()
        await catalog.load(workspace: target)
        XCTAssertEqual(catalog.pageCount, 12)
        XCTAssertEqual(target.currentPageIndex, 4)
        XCTAssertEqual(target.selectedPages, [4])
        XCTAssertEqual(container.activeTabID, activeID)
        XCTAssertTrue(container.activeWorkspace === source)
        XCTAssertFalse(target.isDirty)
        XCTAssertFalse(target.isHibernated)
        catalog.releaseIfEligible(isActive: false)
        XCTAssertTrue(target.isHibernated)
        XCTAssertTrue(catalog.notes.isEmpty)
    }

    @MainActor
    func testStaleOnePageDescriptorIsReplacedByActualTwelvePageCount() async throws {
        let original = try makeWorkspace(pageCount: 12)
        let target = PDFWorkspaceState()
        target.restoreHibernated(url: try XCTUnwrap(original.documentURL), pageCount: 1)
        XCTAssertEqual(target.pageCount, 1)
        let catalog = StudyLinkTargetCatalog()
        await catalog.load(workspace: target)
        XCTAssertEqual(catalog.pageCount, 12)
        XCTAssertEqual(target.pageCount, 12)
        XCTAssertEqual(StudyLinkPageDraft(pageIndex: 11).pageIndex(pageCount: catalog.pageCount), 11)
    }

    @MainActor
    func testAllPagesNotesAndNestedLocalBookmarksAreListedWithoutFollowingExternalActions() async throws {
        let target = try makeWorkspace(pageCount: 12)
        let document = try XCTUnwrap(target.document)
        addNote("First", pageIndex: 0, document: document)
        addNote("On page twelve", pageIndex: 11, document: document)
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter two"
        chapter.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 5)), at: .zero)
        let nested = PDFOutline()
        nested.label = "Nested section"
        nested.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(document.page(at: 9)), at: .zero))
        chapter.insertChild(nested, at: 0)
        root.insertChild(chapter, at: 0)
        let external = PDFOutline()
        external.label = "External link"
        external.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/private")))
        root.insertChild(external, at: 1)
        document.outlineRoot = root
        let catalog = StudyLinkTargetCatalog()
        await catalog.load(workspace: target)
        XCTAssertEqual(catalog.notes.map(\.pageIndex), [0, 11])
        XCTAssertEqual(catalog.bookmarks.map(\.title), ["Chapter two", "Nested section"])
        XCTAssertEqual(catalog.bookmarks.map(\.pageIndex), [5, 9])
        XCTAssertFalse(catalog.isScanning)
        XCTAssertFalse(target.isDirty)
    }

    @MainActor
    func testRevisionCacheAvoidsRepeatedBookScansAndRefreshesEditedNotes() async throws {
        let target = try makeWorkspace(pageCount: 12)
        let document = try XCTUnwrap(target.document)
        addNote("Before", pageIndex: 8, document: document)
        let catalog = StudyLinkTargetCatalog()
        await catalog.load(workspace: target)
        let scanned = catalog.scannedPageCount
        await catalog.load(workspace: target)
        XCTAssertEqual(catalog.scannedPageCount, scanned)
        document.page(at: 8)?.annotations.first?.contents = "After"
        target.annotationChanged()
        await catalog.load(workspace: target)
        XCTAssertEqual(catalog.notes.first?.contents, "After")
        XCTAssertGreaterThan(catalog.scannedPageCount, scanned)
    }

    @MainActor
    func testCancelledScanDoesNotPublishIntoReplacedTarget() async throws {
        let first = try makeWorkspace(pageCount: 80)
        let second = try makeWorkspace(pageCount: 2)
        addNote("Old target", pageIndex: 79, document: try XCTUnwrap(first.document))
        addNote("New target", pageIndex: 1, document: try XCTUnwrap(second.document))
        let catalog = StudyLinkTargetCatalog()
        let oldTask = Task { @MainActor in await catalog.load(workspace: first) }
        await Task.yield()
        oldTask.cancel()
        await catalog.load(workspace: second)
        await oldTask.value
        XCTAssertEqual(catalog.pageCount, 2)
        XCTAssertEqual(catalog.notes.map(\.contents), ["New target"])
        XCTAssertFalse(catalog.isScanning)
    }

    @MainActor
    func testBorrowedTargetRemainsResidentWhenEditedOrActivated() async throws {
        let target = try makeWorkspace(pageCount: 2)
        XCTAssertTrue(target.hibernateIfPossible())
        let catalog = StudyLinkTargetCatalog()
        await catalog.load(workspace: target)
        catalog.releaseIfEligible(isActive: true)
        XCTAssertNotNil(target.document)
        XCTAssertTrue(target.hibernateIfPossible())
        await catalog.load(workspace: target)
        target.annotationChanged()
        catalog.releaseIfEligible(isActive: false)
        XCTAssertNotNil(target.document)
        XCTAssertTrue(target.isDirty)
    }

    @MainActor
    func testUnreadableTargetShowsErrorInsteadOfFakeOnePagePicker() async {
        let target = PDFWorkspaceState()
        target.restoreHibernated(url: URL(fileURLWithPath: "/tmp/EmberPDF-Missing-\(UUID()).pdf"), pageCount: 1)
        let catalog = StudyLinkTargetCatalog()
        await catalog.load(workspace: target)
        XCTAssertEqual(catalog.pageCount, 0)
        XCTAssertNotNil(catalog.errorMessage)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertTrue(catalog.notes.isEmpty)
    }

    @MainActor
    func testDeepOutlineTraversalIsBounded() async throws {
        let target = try makeWorkspace(pageCount: 1)
        let document = try XCTUnwrap(target.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let root = PDFOutline()
        var parent = root
        for index in 0..<100 {
            let item = PDFOutline()
            item.label = "Level \(index)"
            item.destination = PDFDestination(page: page, at: .zero)
            parent.insertChild(item, at: 0)
            parent = item
        }
        document.outlineRoot = root
        let catalog = StudyLinkTargetCatalog()
        await catalog.load(workspace: target)
        XCTAssertTrue(catalog.isTruncated)
        XCTAssertLessThanOrEqual(catalog.bookmarks.count, 65)
    }

    @MainActor
    private func addNote(_ text: String, pageIndex: Int, document: PDFDocument) {
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 20, width: 100, height: 30), forType: .freeText, withProperties: nil)
        note.contents = text
        StudyLinkNoteIdentity.assignIfNeeded(to: note)
        document.page(at: pageIndex)?.addAnnotation(note)
    }

    @MainActor
    private func makeWorkspace(pageCount: Int) throws -> PDFWorkspaceState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StudyLinkCatalog-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let document = PDFDocument()
        for _ in 0..<pageCount {
            let image = NSImage(size: CGSize(width: 120, height: 160), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill(); return true
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: document.pageCount)
        }
        let url = directory.appendingPathComponent("Target.pdf")
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        return workspace
    }
}
