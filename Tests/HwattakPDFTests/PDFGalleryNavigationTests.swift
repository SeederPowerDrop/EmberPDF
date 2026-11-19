// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFGalleryNavigationTests: XCTestCase {
    @MainActor
    func testCrossWorkspaceCardRestoresTargetViewportWithoutResumingOtherTab() throws {
        let fixture = try makePDFs(names: ["source", "target", "unrelated"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = MultiDocumentWorkspaceState()
        let sourceWorkspaceID = state.activeWorkspaceID
        let sourceID = try XCTUnwrap(state.openPDFsInTabs(urls: [fixture.urls[0]]).first)
        let source = try XCTUnwrap(state.activeWorkspace)
        source.setCurrentPage(1)
        source.recordPDFViewport(autoScales: false, scaleFactor: 1.4,
                                 scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.5))
        let sourceViewport = source.pdfViewportState

        let targetWorkspaceID = state.createWorkspace(title: "Research")
        let targetID = try XCTUnwrap(state.openPDFsInTabs(urls: [fixture.urls[1]]).first)
        let target = try XCTUnwrap(state.activeWorkspace)
        target.setCurrentPage(2)
        target.selectedPages = [2]
        target.recordPDFViewport(autoScales: false, scaleFactor: 1.8,
                                 scrollProgress: PDFScrollProgress(horizontal: 0.3, vertical: 0.7))
        let targetViewport = target.pdfViewportState
        _ = state.openPDFsInTabs(urls: [fixture.urls[2]])
        let unrelated = try XCTUnwrap(state.activeWorkspace)
        XCTAssertTrue(target.hibernateIfPossible())
        XCTAssertTrue(unrelated.hibernateIfPossible())
        XCTAssertTrue(state.selectWorkspace(sourceWorkspaceID))

        // Merely browsing workspace metadata keeps every reader state intact.
        XCTAssertEqual(state.sessions(inWorkspace: targetWorkspaceID).count, 2)
        XCTAssertEqual(state.activeTabID, sourceID)
        XCTAssertTrue(target.isHibernated)
        XCTAssertTrue(unrelated.isHibernated)

        XCTAssertTrue(state.selectGalleryDocument(workspaceID: targetWorkspaceID, tabID: targetID))
        XCTAssertEqual(state.activeWorkspaceID, targetWorkspaceID)
        XCTAssertEqual(state.activeTabID, targetID)
        XCTAssertTrue(state.activeWorkspace === target)
        XCTAssertFalse(target.isHibernated)
        XCTAssertTrue(unrelated.isHibernated, "The destination's previous tab must not be resumed.")
        XCTAssertEqual(target.currentPageIndex, 2)
        XCTAssertEqual(target.selectedPages, [2])
        XCTAssertEqual(target.pdfViewportState, targetViewport)
        XCTAssertEqual(source.currentPageIndex, 1)
        XCTAssertEqual(source.pdfViewportState, sourceViewport)
    }

    @MainActor
    func testExactGalleryHitNavigatesAndHighlightsWithoutStartingAnotherSearch() async throws {
        let fixture = try makePDFs(names: ["source", "target"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = MultiDocumentWorkspaceState()
        let sourceWorkspaceID = state.activeWorkspaceID
        _ = state.openPDFsInTabs(urls: [fixture.urls[0]])
        let source = try XCTUnwrap(state.activeWorkspace)
        source.setCurrentPage(1)
        let targetWorkspaceID = state.createWorkspace(title: "Reading")
        let targetID = try XCTUnwrap(state.openPDFsInTabs(urls: [fixture.urls[1]]).first)
        let target = try XCTUnwrap(state.activeWorkspace)
        let document = try XCTUnwrap(target.document)
        let result = try makeHit(document: document, pageIndex: 2, text: "needle")
        target.setCurrentPage(2)
        target.recordPDFViewport(autoScales: false, scaleFactor: 1.8,
                                 scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.6))
        let revision = target.revision
        let sourceBytes = try Data(contentsOf: fixture.urls[1])
        XCTAssertTrue(state.selectWorkspace(sourceWorkspaceID))

        XCTAssertTrue(state.selectGalleryDocument(workspaceID: targetWorkspaceID,
                                                 tabID: targetID, searchResult: result))
        XCTAssertEqual(target.currentPageIndex, 2)
        XCTAssertEqual(target.activeSearchSelection?.string, "needle")
        XCTAssertTrue(target.currentSelection === target.activeSearchSelection)
        XCTAssertEqual(target.searchResults.count, 1)
        XCTAssertFalse(target.isSearching)
        XCTAssertTrue(target.searchNavigatorResults.isEmpty,
                      "One gallery hit must not pretend to be an exhaustive document search.")
        XCTAssertEqual(target.searchProgress, .idle)
        XCTAssertNil(target.pdfViewportState.scrollProgress)
        XCTAssertEqual(target.pdfViewportState.scaleFactor, 1.8)
        XCTAssertEqual(source.currentPageIndex, 1)

        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(target.document === document)
        XCTAssertEqual(target.revision, revision)
        XCTAssertFalse(target.isDirty)
        XCTAssertFalse(target.canUndo)
        XCTAssertFalse(target.isSearching)
        XCTAssertEqual(target.activeSearchSelection?.string, "needle")
        XCTAssertEqual(try Data(contentsOf: fixture.urls[1]), sourceBytes)

        target.clearSearch()
        XCTAssertNil(target.activeSearchSelection)
        XCTAssertNil(target.currentSelection)
    }

    @MainActor
    func testStaleRangesAndChangedTextCannotReplaceCurrentPageOrSelection() throws {
        let fixture = try makePDFs(names: ["source"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let target = PDFWorkspaceState()
        XCTAssertTrue(target.open(url: fixture.urls[0]))
        let document = try XCTUnwrap(target.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let priorSelection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5)))
        target.currentSelection = priorSelection
        target.searchText = "preserved query"
        let valid = try makeHit(document: document, pageIndex: 2, text: "needle")
        let variants: [(Int, NSRange, String)] = [
            (2, NSRange(location: NSNotFound, length: 1), "needle"),
            (2, NSRange(location: 0, length: Int.max), "needle"),
            (2, NSRange(location: -1, length: 1), "needle"),
            (2, NSRange(location: 0, length: 0), ""),
            (2, valid.sourceRange, "changed"),
            (document.pageCount, valid.sourceRange, "needle"),
            (-1, valid.sourceRange, "needle")
        ]
        for (pageIndex, range, text) in variants {
            let stale = PDFSearchResult(pageIndex: pageIndex, pageLabel: "3", snippet: text,
                                        snippetMatchRanges: [], sourceRange: range, matchedText: text)
            XCTAssertFalse(target.activateGallerySearchResult(stale))
            XCTAssertEqual(target.currentPageIndex, 0)
            XCTAssertTrue(target.currentSelection === priorSelection)
            XCTAssertEqual(target.searchText, "preserved query")
            XCTAssertNil(target.activeSearchSelection)
            XCTAssertFalse(target.isDirty)
        }
    }

    @MainActor
    func testStaleWorkspaceTabPairsAndEmptyTabsDoNotChangeActiveReader() throws {
        let fixture = try makePDFs(names: ["source"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = MultiDocumentWorkspaceState()
        let sourceWorkspaceID = state.activeWorkspaceID
        let tabID = try XCTUnwrap(state.openPDFsInTabs(urls: [fixture.urls[0]]).first)
        let source = try XCTUnwrap(state.activeWorkspace)
        let otherWorkspaceID = state.createWorkspace(title: "Empty", activate: false)
        let emptyTabID = try XCTUnwrap(state.sessions(inWorkspace: otherWorkspaceID).first?.id)
        XCTAssertFalse(state.selectGalleryDocument(workspaceID: otherWorkspaceID, tabID: tabID))
        XCTAssertFalse(state.selectGalleryDocument(workspaceID: UUID(), tabID: tabID))
        XCTAssertFalse(state.selectGalleryDocument(workspaceID: sourceWorkspaceID, tabID: UUID()))
        XCTAssertFalse(state.selectGalleryDocument(workspaceID: otherWorkspaceID, tabID: emptyTabID))
        XCTAssertEqual(state.activeWorkspaceID, sourceWorkspaceID)
        XCTAssertEqual(state.activeTabID, tabID)
        XCTAssertTrue(state.activeWorkspace === source)

        XCTAssertTrue(state.moveTab(tabID, toWorkspace: otherWorkspaceID))
        let replacementTabID = state.activeTabID
        XCTAssertFalse(state.selectGalleryDocument(workspaceID: sourceWorkspaceID, tabID: tabID))
        XCTAssertEqual(state.activeTabID, replacementTabID)
        XCTAssertTrue(state.selectGalleryDocument(workspaceID: otherWorkspaceID, tabID: tabID))
        XCTAssertTrue(state.activeWorkspace === source)
    }

    @MainActor
    func testTargetedHitCancelsPendingSearchAndCannotPublishLateResults() async throws {
        let fixture = try makePDFs(names: ["source"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let target = PDFWorkspaceState()
        XCTAssertTrue(target.open(url: fixture.urls[0]))
        let document = try XCTUnwrap(target.document)
        let result = try makeHit(document: document, pageIndex: 2, text: "needle")
        target.searchText = "page"
        target.performSearch()
        XCTAssertTrue(target.isSearching)
        XCTAssertTrue(target.activateGallerySearchResult(result))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertFalse(target.isSearching)
        XCTAssertTrue(target.searchNavigatorResults.isEmpty)
        XCTAssertEqual(target.searchProgress, .idle)
        XCTAssertEqual(target.currentPageIndex, 2)
        XCTAssertEqual(target.activeSearchSelection?.string, "needle")
    }

    @MainActor
    private func makeHit(document: PDFDocument, pageIndex: Int, text: String) throws -> PDFSearchResult {
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let source = try XCTUnwrap(page.string)
        let range = (source as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound)
        return PDFSearchResult(pageIndex: pageIndex, pageLabel: String(pageIndex + 1),
                               snippet: source, snippetMatchRanges: [range],
                               sourceRange: range, matchedText: text)
    }

    @MainActor
    private func makePDFs(names: [String]) throws -> (directory: URL, urls: [URL]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-GalleryNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for name in names {
            let document = PDFDocument()
            for index in 0..<3 {
                let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
                view.backgroundColor = .white
                view.textColor = .black
                view.font = .systemFont(ofSize: 17)
                view.string = "\(name) page \(index + 1), prefix needle suffix."
                let rendered = try XCTUnwrap(PDFDocument(data: view.dataWithPDF(inside: view.bounds)))
                document.insert(try XCTUnwrap(rendered.page(at: 0)), at: index)
            }
            let url = directory.appendingPathComponent(name + ".pdf")
            XCTAssertTrue(document.write(to: url))
            urls.append(url)
        }
        return (directory, urls)
    }
}
