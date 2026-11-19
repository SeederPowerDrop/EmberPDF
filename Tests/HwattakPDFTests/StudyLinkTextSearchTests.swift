// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class StudyLinkTextSearchTests: XCTestCase {
    @MainActor
    func testSearchStartsAtReadingPageAndShowsOneSnippetPerMatchingPage() async throws {
        let workspace = try makeWorkspace(pages: ["needle before", "unrelated", "NEEDLE current needle twice", "needle after"])
        workspace.currentPageIndex = 2
        let search = StudyLinkTextSearch(debounceNanoseconds: 0)
        await search.search(query: "needle", in: workspace)
        XCTAssertEqual(search.results.map(\.pageIndex), [2, 3, 0])
        XCTAssertEqual(search.status, .completed)
        XCTAssertEqual(search.progress.completedPages, 4)
        XCTAssertFalse(search.progress.isTruncated, "multiple matches on one page are intentionally represented by one page row")
        XCTAssertTrue(search.results.allSatisfy { !$0.snippet.isEmpty && !$0.snippetMatchRanges.isEmpty })
        XCTAssertEqual(workspace.currentPageIndex, 2)
    }

    @MainActor
    func testPrivateSearchDoesNotChangeOrdinarySearchSelectionNavigationOrDirtyState() async throws {
        let workspace = try makeWorkspace(pages: ["ordinary needle one", "private second", "private current"])
        workspace.annotationChanged()
        workspace.searchText = "ordinary"
        workspace.performSearch()
        for _ in 0..<1_000 where workspace.isSearching { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(workspace.isSearching)
        let resultIDs = workspace.searchNavigatorResults.map(\.id)
        let selection = workspace.currentSelection
        let searchSelection = workspace.activeSearchSelection
        workspace.currentPageIndex = 2
        workspace.selectedPages = [1, 2]
        let revision = workspace.revision
        let search = StudyLinkTextSearch(debounceNanoseconds: 0)
        await search.search(query: "private", in: workspace)
        XCTAssertEqual(search.results.map(\.pageIndex), [2, 1])
        XCTAssertEqual(workspace.searchText, "ordinary")
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.id), resultIDs)
        XCTAssertTrue(workspace.currentSelection === selection)
        XCTAssertTrue(workspace.activeSearchSelection === searchSelection)
        XCTAssertEqual(workspace.currentPageIndex, 2)
        XCTAssertEqual(workspace.selectedPages, [1, 2])
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertTrue(workspace.isDirty)
    }

    @MainActor
    func testReplacingAQueryCancelsOldResultsAndRejectsWrongQuerySelection() async throws {
        let workspace = try makeWorkspace(pages: ["alpha only", "beta only"])
        let search = StudyLinkTextSearch(debounceNanoseconds: 5_000_000)
        let first = Task { @MainActor in await search.search(query: "alpha", in: workspace) }
        await Task.yield()
        await search.search(query: "beta", in: workspace)
        await first.value
        XCTAssertEqual(search.queryForResults, "beta")
        XCTAssertEqual(search.results.map(\.pageIndex), [1])
        let id = try XCTUnwrap(search.results.first?.id)
        XCTAssertEqual(search.pageIndex(for: id, query: "beta", in: workspace), 1)
        XCTAssertNil(search.pageIndex(for: id, query: "alpha", in: workspace))
        search.cancel()
        XCTAssertTrue(search.results.isEmpty)
        XCTAssertEqual(search.status, .idle)
        XCTAssertNil(search.pageIndex(for: id, query: "beta", in: workspace))
    }

    @MainActor
    func testRevisionChangeDiscardsInFlightResultsAndInvalidatesExistingSelection() async throws {
        let workspace = try makeWorkspace(pages: ["needle first", "needle second"])
        let search = StudyLinkTextSearch(debounceNanoseconds: 10_000_000)
        let task = Task { @MainActor in await search.search(query: "needle", in: workspace) }
        while search.status != .searching { await Task.yield() }
        workspace.annotationChanged()
        await task.value
        XCTAssertEqual(search.status, .changed)
        XCTAssertTrue(search.results.isEmpty)
        await search.search(query: "needle", in: workspace)
        let id = try XCTUnwrap(search.results.first?.id)
        workspace.annotationChanged()
        XCTAssertNil(search.pageIndex(for: id, query: "needle", in: workspace))
    }

    @MainActor
    func testResultCapacityBoundsPagesWithoutClaimingMissingOccurrences() async throws {
        let workspace = try makeWorkspace(pages: ["needle needle needle", "needle two", "needle three"])
        let search = StudyLinkTextSearch(maximumResultPages: 2, debounceNanoseconds: 0)
        await search.search(query: "needle", in: workspace)
        XCTAssertEqual(search.results.map(\.pageIndex), [0, 1])
        XCTAssertEqual(search.progress.completedPages, 2)
        XCTAssertTrue(search.progress.isTruncated)
        let exact = try makeWorkspace(pages: ["needle needle", "needle needle"])
        await search.search(query: "needle", in: exact)
        XCTAssertEqual(search.results.count, 2)
        XCTAssertFalse(search.progress.isTruncated)
    }

    @MainActor
    func testInvisibleOCRTextLayerIsSearchableAndImageOnlyPageIsCounted() async throws {
        let workspace = try makeWorkspace(pages: ["", "hidden OCR constellation"], invisibleText: true)
        let search = StudyLinkTextSearch(debounceNanoseconds: 0)
        await search.search(query: "constellation", in: workspace)
        XCTAssertEqual(search.results.map(\.pageIndex), [1])
        XCTAssertEqual(search.textlessPageCount, 1)
        XCTAssertTrue(search.results.first?.snippet.contains("constellation") == true)
        let blank = try makeWorkspace(pages: ["", ""])
        await search.search(query: "anything", in: blank)
        XCTAssertTrue(search.results.isEmpty)
        XCTAssertEqual(search.textlessPageCount, 2)
        XCTAssertEqual(search.status, .completed)
    }

    @MainActor
    func testCopyRestrictedPDFDoesNotExposeSearchSnippets() async throws {
        let workspace = try makeWorkspace(pages: ["restricted needle"], protected: true)
        XCTAssertFalse(try XCTUnwrap(workspace.document).allowsCopying)
        let search = StudyLinkTextSearch(debounceNanoseconds: 0)
        await search.search(query: "needle", in: workspace)
        XCTAssertEqual(search.status, .copyRestricted)
        XCTAssertTrue(search.results.isEmpty)
        XCTAssertEqual(search.progress.completedPages, 0)
    }

    @MainActor
    func testDirectReadingPageUsesLivePageFortyNineAndLinkCreationKeepsSourceTab() throws {
        let source = try makeWorkspace(pages: ["source draft"])
        let target = try makeWorkspace(pages: Array(repeating: "target", count: 50))
        target.currentPageIndex = 48
        target.selectedPages = [48]
        source.annotationChanged()
        let container = MultiDocumentWorkspaceState(initialSession: PDFTabSession(workspace: source))
        let activeID = container.activeTabID
        let pageDraft = StudyLinkPageDraft(pageIndex: 11)
        XCTAssertEqual(pageDraft.pageIndex(pageCount: target.pageCount), 11)
        let livePage = try XCTUnwrap(StudyLinkReadingLocation.pageIndex(in: target))
        XCTAssertEqual(livePage, 48)
        let store = StudyLinkStore(persistence: TextSearchLinkPersistence(), bookmarkCoder: TextSearchLinkBookmarks())
        let link = try store.add(from: source, to: target, targetPage: livePage)
        XCTAssertEqual(link.second.pageIndex, 48)
        XCTAssertEqual(target.currentPageIndex, 48)
        XCTAssertEqual(target.selectedPages, [48])
        XCTAssertEqual(container.activeTabID, activeID)
        XCTAssertTrue(container.activeWorkspace === source)
        XCTAssertTrue(source.isDirty)
        target.currentPageIndex = 49
        XCTAssertEqual(StudyLinkReadingLocation.pageIndex(in: target), 49)
    }

    @MainActor
    func testUnloadedTargetIsNotSilentlyOpenedBySearchOrReadingShortcut() async {
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(url: URL(fileURLWithPath: "/tmp/StudyLinkNotAuthorized-\(UUID()).pdf"), pageCount: 50,
                                    currentPageIndex: 48)
        let search = StudyLinkTextSearch(debounceNanoseconds: 0)
        await search.search(query: "needle", in: workspace)
        XCTAssertEqual(search.status, .unavailable)
        XCTAssertTrue(workspace.isHibernated)
        XCTAssertNil(StudyLinkReadingLocation.pageIndex(in: workspace))
    }

    @MainActor
    private func makeWorkspace(pages: [String], invisibleText: Bool = false,
                               protected: Bool = false) throws -> PDFWorkspaceState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StudyLinkSearch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 640, height: 840)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for text in pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
            context.setTextDrawingMode(invisibleText ? .invisible : .fill)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 25, y: 760)
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            let line = CTLineCreateWithAttributedString(try XCTUnwrap(CFAttributedStringCreate(nil, text as CFString, attributes)))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let url = directory.appendingPathComponent("Search Target.pdf")
        if protected {
            XCTAssertTrue(document.write(to: url, withOptions: [
                .ownerPasswordOption: "OwnerPass9", .userPasswordOption: "ReaderPass9",
                .accessPermissionsOption: NSNumber(value: 0),
                PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128
            ]))
        } else { XCTAssertTrue(document.write(to: url)) }
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in "ReaderPass9" })
        XCTAssertTrue(workspace.open(url: url))
        return workspace
    }
}

private final class TextSearchLinkPersistence: RecentDocumentsPersisting { var data: Data? }
private struct TextSearchLinkBookmarks: RecentDocumentBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        guard let path = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return (URL(fileURLWithPath: path), false)
    }
}
