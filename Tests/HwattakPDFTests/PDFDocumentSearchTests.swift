// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFDocumentSearchTests: XCTestCase {
    func testUnicodeNormalizerCoversKoreanEnglishJapaneseChineseAndArabic() throws {
        let cases: [(document: String, query: String, expected: String)] = [
            ("한글 검색", "한글 검색", "한글 검색"),
            ("CAFÉ ﬁle", "cafe file", "cafe file"),
            ("ＡＩとｶﾀｶﾅ", "aiとカタカナ", "aiとカタカナ"),
            ("长篇文档 分析", "长篇文档 分析", "长篇文档 分析"),
            ("ﻻ اَلْعِلْمُ", "لا العلم", "لا العلم")
        ]

        for item in cases {
            let document = try PDFUnicodeSearchNormalizer
                .normalizeDocumentText(item.document).text
            let query = PDFUnicodeSearchNormalizer.normalizeQuery(item.query)
            XCTAssertEqual(document, item.expected)
            XCTAssertEqual(query, item.expected)
            XCTAssertNotEqual(
                (document as NSString).range(of: query).location,
                NSNotFound,
                "Expected \(item.query) to match \(item.document)"
            )
        }
    }

    func testNormalizerMatchesPhrasesAcrossWhitespaceAndLineWrapHyphen() throws {
        let whitespace = try PDFUnicodeSearchNormalizer.normalizeDocumentText(
            "first\n\t   second"
        )
        XCTAssertEqual(whitespace.text, "first second")
        XCTAssertEqual(
            PDFUnicodeSearchNormalizer.normalizeQuery("first   second"),
            "first second"
        )

        let hyphenatedSource = "international research can be inter-\nnational too"
        let hyphenated = try PDFUnicodeSearchNormalizer.normalizeDocumentText(hyphenatedSource)
        let query = PDFUnicodeSearchNormalizer.normalizeQuery("international")
        let secondMatch = (hyphenated.text as NSString).range(
            of: query,
            options: [],
            range: NSRange(
                location: query.utf16.count,
                length: hyphenated.text.utf16.count - query.utf16.count
            )
        )
        let sourceRange = try XCTUnwrap(
            hyphenated.sourceRange(forNormalizedRange: secondMatch)
        )
        XCTAssertEqual(
            (hyphenatedSource as NSString).substring(with: sourceRange),
            "inter-\nnational"
        )
    }

    @MainActor
    func testDocumentSearchBuildsPageNavigatorSnippetsAndExactSelection() async throws {
        let fixture = try makeTextPDF(pages: [
            "Alpha needle one.",
            "This page is unrelated.",
            "Second NEEDLE context. Another needle follows."
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))

        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        XCTAssertEqual(workspace.searchCompletedQuery, "needle")
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.pageIndex), [0, 2, 2])
        XCTAssertEqual(workspace.searchProgress.completedPages, 3)
        XCTAssertEqual(workspace.searchProgress.totalPages, 3)
        XCTAssertEqual(workspace.searchProgress.resultCount, 3)
        XCTAssertFalse(workspace.searchResultsWereTruncated)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)

        for result in workspace.searchNavigatorResults {
            XCTAssertFalse(result.snippet.isEmpty)
            let range = try XCTUnwrap(result.snippetMatchRanges.first)
            XCTAssertNotNil(Range(range, in: result.snippet))
            XCTAssertEqual(result.matchedText.lowercased(), "needle")
        }

        let lastID = try XCTUnwrap(workspace.searchNavigatorResults.last?.id)
        workspace.selectSearchResult(id: lastID)
        XCTAssertEqual(workspace.currentPageIndex, 2)
        XCTAssertEqual(workspace.searchResultIndex, 2)
        XCTAssertEqual(workspace.searchResults.count, 1)
        XCTAssertTrue(workspace.activeSearchSelection === workspace.searchResults.first)
        XCTAssertEqual(workspace.activeSearchSelection?.string?.lowercased(), "needle")

        workspace.showNextSearchResult()
        XCTAssertEqual(workspace.searchResultIndex, 0)
        XCTAssertEqual(workspace.currentPageIndex, 0)
        workspace.showNextSearchResult(backwards: true)
        XCTAssertEqual(workspace.searchResultIndex, 2)
        XCTAssertEqual(workspace.currentPageIndex, 2)
    }

    @MainActor
    func testSearchResultActivationAndResetOwnCurrentSelectionByIdentity() async throws {
        let fixture = try makeTextPDF(pages: ["prefix needle middle needle suffix"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        let first = try XCTUnwrap(workspace.activeSearchSelection)
        XCTAssertTrue(workspace.currentSelection === first)

        workspace.recordPDFViewport(
            autoScales: false,
            scaleFactor: 1.5,
            scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.8)
        )
        XCTAssertNotNil(workspace.pdfViewportState(for: .normal).scrollProgress)
        workspace.showNextSearchResult()
        let second = try XCTUnwrap(workspace.activeSearchSelection)
        XCTAssertFalse(second === first)
        XCTAssertTrue(workspace.currentSelection === second)
        XCTAssertNil(workspace.pdfViewportState(for: .normal).scrollProgress)
        XCTAssertEqual(workspace.pdfViewportState(for: .normal).scaleFactor, 1.5)
        XCTAssertFalse(workspace.pdfViewportState(for: .normal).autoScales)

        workspace.clearSearch()
        XCTAssertNil(workspace.activeSearchSelection)
        XCTAssertNil(
            workspace.currentSelection,
            "Clearing search must remove the exact selection that search installed."
        )

        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)
        let searchSelection = try XCTUnwrap(workspace.activeSearchSelection)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let ordinarySelection = try XCTUnwrap(
            page.selection(for: NSRange(location: 0, length: 6))
        )
        XCTAssertFalse(ordinarySelection === searchSelection)
        workspace.currentSelection = ordinarySelection

        workspace.clearSearch()
        XCTAssertNil(workspace.activeSearchSelection)
        XCTAssertTrue(
            workspace.currentSelection === ordinarySelection,
            "A newer user selection must survive search reset."
        )
    }

    @MainActor
    func testInvalidSearchResultClearsOnlyTheSelectionStillOwnedBySearch() async throws {
        let ownedFixture = try makeTextPDF(pages: ["prefix needle suffix"])
        addTeardownBlock { try? FileManager.default.removeItem(at: ownedFixture.directory) }
        let ownedWorkspace = PDFWorkspaceState()
        XCTAssertTrue(ownedWorkspace.open(url: ownedFixture.url))
        ownedWorkspace.searchText = "needle"
        ownedWorkspace.performSearch()
        await waitForSearchToFinish(ownedWorkspace)
        let ownedSelection = try XCTUnwrap(ownedWorkspace.activeSearchSelection)
        XCTAssertTrue(ownedWorkspace.currentSelection === ownedSelection)

        ownedWorkspace.document?.removePage(at: 0)
        ownedWorkspace.selectSearchResult(at: 0)
        XCTAssertNil(ownedWorkspace.activeSearchSelection)
        XCTAssertNil(ownedWorkspace.currentSelection)

        let userFixture = try makeTextPDF(pages: ["prefix needle suffix"])
        addTeardownBlock { try? FileManager.default.removeItem(at: userFixture.directory) }
        let userWorkspace = PDFWorkspaceState()
        XCTAssertTrue(userWorkspace.open(url: userFixture.url))
        userWorkspace.searchText = "needle"
        userWorkspace.performSearch()
        await waitForSearchToFinish(userWorkspace)
        let page = try XCTUnwrap(userWorkspace.document?.page(at: 0))
        let ordinarySelection = try XCTUnwrap(
            page.selection(for: NSRange(location: 0, length: 6))
        )
        userWorkspace.currentSelection = ordinarySelection

        userWorkspace.document?.removePage(at: 0)
        userWorkspace.selectSearchResult(at: 0)
        XCTAssertNil(userWorkspace.activeSearchSelection)
        XCTAssertTrue(
            userWorkspace.currentSelection === ordinarySelection,
            "Invalidating a result must not erase a newer user selection."
        )
    }

    @MainActor
    func testSearchNavigationSynchronizesPDFViewAndWorkspaceSelection() async throws {
        let fixture = try makeTextPDF(pages: ["prefix needle middle needle suffix"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        let first = try XCTUnwrap(workspace.activeSearchSelection)
        workspace.currentSelection = nil

        let pdfView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        pdfView.document = workspace.document
        let coordinator = PDFKitViewer.Coordinator(state: workspace)
        coordinator.attach(to: pdfView)
        defer { coordinator.detach() }
        // A real activation, rather than the initial subscription replay,
        // explicitly takes selection ownership from a mounted reader.
        workspace.activeSearchSelection = first
        coordinator.applySearchSelection(first, to: pdfView)

        XCTAssertTrue(workspace.currentSelection === first)
        XCTAssertTrue(pdfView.currentSelection === first)

        workspace.showNextSearchResult()
        let second = try XCTUnwrap(workspace.activeSearchSelection)
        XCTAssertFalse(second === first)
        XCTAssertTrue(
            workspace.currentSelection === second,
            "The model must update as soon as a new search result becomes active."
        )
        coordinator.applySearchSelection(second, to: pdfView)
        XCTAssertTrue(pdfView.currentSelection === second)

        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let ordinarySelection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))
        workspace.currentSelection = ordinarySelection
        pdfView.setCurrentSelection(ordinarySelection, animate: false)
        workspace.clearSearch()
        coordinator.applySearchSelection(nil, to: pdfView)

        XCTAssertTrue(workspace.currentSelection === ordinarySelection)
        XCTAssertTrue(pdfView.currentSelection === ordinarySelection)
    }

    @MainActor
    func testRepeatedSearchRenderingPreservesCommittedNativeDragInNormalAndComparisonViews() async throws {
        for context in [PDFViewerViewportContext.normal, .comparison] {
            let fixture = try makeTextPDF(pages: ["prefix needle middle needle suffix"])
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: fixture.url))
            let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
            view.viewportContext = context
            view.document = workspace.document
            view.configure(with: workspace)
            let coordinator = PDFKitViewer.Coordinator(state: workspace, viewportContext: context)
            coordinator.attach(to: view)
            defer { coordinator.detach() }
            workspace.searchText = "needle"
            workspace.performSearch()
            await waitForSearchToFinish(workspace)
            let hit = try XCTUnwrap(workspace.activeSearchSelection)
            coordinator.applySearchSelection(hit, to: view)

            let page = try XCTUnwrap(workspace.document?.page(at: 0))
            let manual = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
            view.beginNativeSelectionPreview()
            view.setCurrentSelection(manual, animate: false)
            NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
            view.finishNativeSelectionPreview()
            XCTAssertTrue(workspace.currentSelection === manual)
            for _ in 0..<4 {
                // This is the search boundary called by updateNSView for tool,
                // locale and toolbar changes while the query remains active.
                coordinator.applySearchSelection(hit, to: view)
                XCTAssertTrue(workspace.currentSelection === manual)
                XCTAssertTrue(view.currentSelection === manual)
            }
            XCTAssertTrue(workspace.activeSearchSelection === hit)
            workspace.clearSearch()
            coordinator.applySearchSelection(nil, to: view)
            XCTAssertTrue(workspace.currentSelection === manual)
            XCTAssertTrue(view.currentSelection === manual)
            XCTAssertFalse(workspace.isDirty)
        }
    }

    @MainActor
    func testNormalAndComparisonRemountDoNotReplayOldSearchOverManualSelection() async throws {
        for context in [PDFViewerViewportContext.normal, .comparison] {
            let fixture = try makeTextPDF(pages: ["prefix needle middle needle suffix"])
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: fixture.url))
            workspace.searchText = "needle"
            workspace.performSearch()
            await waitForSearchToFinish(workspace)
            let hit = try XCTUnwrap(workspace.activeSearchSelection)
            let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
            view.viewportContext = context
            view.document = workspace.document
            view.configure(with: workspace)
            let first = PDFKitViewer.Coordinator(state: workspace, viewportContext: context)
            first.attach(to: view)
            first.applySearchSelection(hit, to: view)
            let page = try XCTUnwrap(workspace.document?.page(at: 0))
            let manual = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))
            view.setCurrentSelection(manual, animate: false)
            NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
            XCTAssertTrue(workspace.currentSelection === manual)
            first.detach()

            let remounted = PDFKitViewer.Coordinator(state: workspace, viewportContext: context)
            remounted.attach(to: view)
            defer { remounted.detach() }
            XCTAssertTrue(workspace.currentSelection === manual,
                          "Combine's initial replay is presentation state, not a new search command.")
            remounted.applySearchSelection(hit, to: view)
            XCTAssertTrue(workspace.currentSelection === manual)
            XCTAssertTrue(view.currentSelection === manual)
            XCTAssertFalse(workspace.isDirty)
        }
    }

    @MainActor
    func testExplicitSameAndDifferentSearchActivationsReclaimNativeSelectionAfterDrag() async throws {
        let fixture = try makeTextPDF(pages: ["prefix needle middle needle suffix"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        view.document = workspace.document
        view.configure(with: workspace)
        let coordinator = PDFKitViewer.Coordinator(state: workspace)
        coordinator.attach(to: view)
        defer { coordinator.detach() }
        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)
        let first = try XCTUnwrap(workspace.activeSearchSelection)
        coordinator.applySearchSelection(first, to: view)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let manual = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))

        // A real publisher emission must reassert even the identical hit object.
        view.setCurrentSelection(manual, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        workspace.activeSearchSelection = first
        coordinator.applySearchSelection(first, to: view)
        XCTAssertTrue(workspace.currentSelection === first)
        XCTAssertTrue(view.currentSelection === first)

        // Clicking the same navigator row builds a fresh exact PDFSelection.
        view.setCurrentSelection(manual, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        workspace.selectSearchResult(at: 0)
        let sameOccurrence = try XCTUnwrap(workspace.activeSearchSelection)
        coordinator.applySearchSelection(sameOccurrence, to: view)
        XCTAssertTrue(workspace.currentSelection === sameOccurrence)
        XCTAssertTrue(view.currentSelection === sameOccurrence)
        XCTAssertEqual(sameOccurrence.bounds(for: page), first.bounds(for: page))

        view.setCurrentSelection(manual, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        workspace.showNextSearchResult()
        let second = try XCTUnwrap(workspace.activeSearchSelection)
        coordinator.applySearchSelection(second, to: view)
        XCTAssertTrue(workspace.currentSelection === second)
        XCTAssertTrue(view.currentSelection === second)
        XCTAssertNotEqual(second.bounds(for: page), first.bounds(for: page))
        workspace.clearSearch()
        coordinator.applySearchSelection(nil, to: view)
        XCTAssertNil(workspace.currentSelection)
        XCTAssertNil(view.currentSelection)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testSearchRenderingDoesNotReviveSelectionClearedForAnEditor() async throws {
        let fixture = try makeTextPDF(pages: ["prefix needle suffix"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)
        let hit = try XCTUnwrap(workspace.activeSearchSelection)
        workspace.currentSelection = nil
        let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        view.document = workspace.document
        let coordinator = PDFKitViewer.Coordinator(state: workspace)
        coordinator.attach(to: view)
        defer { coordinator.detach() }
        coordinator.applySearchSelection(hit, to: view)
        XCTAssertNil(workspace.currentSelection)
        XCTAssertNil(view.currentSelection)
        XCTAssertTrue(workspace.activeSearchSelection === hit)
    }

    @MainActor
    func testPDFBackedMultilingualSearchNavigatesEachLanguagePage() async throws {
        let fixtures: [(text: String, query: String)] = [
            ("한국어 문서 검색 연습", "문서 검색"),
            ("Reviewing a CAFÉ document", "cafe document"),
            ("日本語の資料を検索します", "資料を検索"),
            ("中文长篇文档分析", "文档分析"),
            ("تحليل اَلْعِلْمُ والدراسة", "العلم")
        ]
        let fixture = try makeTextPDF(pages: fixtures.map(\.text))
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))

        for (pageIndex, item) in fixtures.enumerated() {
            workspace.searchText = item.query
            workspace.performSearch()
            await waitForSearchToFinish(workspace)
            XCTAssertEqual(
                workspace.searchNavigatorResults.first?.pageIndex,
                pageIndex,
                "Failed query: \(item.query)"
            )
            XCTAssertNotNil(workspace.activeSearchSelection)
            XCTAssertEqual(workspace.currentPageIndex, pageIndex)
        }
    }

    @MainActor
    func testQueryChangeCancelAndMutationCannotCommitStaleResults() async throws {
        let page = String(repeating: "first needle filler ", count: 4_000)
        let fixture = try makeTextPDF(pages: Array(repeating: page, count: 12))
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.setMode(.editing)

        workspace.searchText = "first"
        workspace.performSearch()
        XCTAssertTrue(workspace.isSearching)
        workspace.searchText = "second"
        XCTAssertFalse(workspace.isSearching)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertNil(workspace.activeSearchQuery)
        XCTAssertNil(workspace.searchCompletedQuery)

        workspace.performSearch()
        workspace.cancelSearch()
        XCTAssertFalse(workspace.isSearching)
        XCTAssertEqual(workspace.searchProgress.phase, .cancelled)
        XCTAssertFalse(workspace.isDirty)

        workspace.searchText = "needle"
        workspace.performSearch()
        workspace.movePage(from: 0, before: 2)
        XCTAssertFalse(workspace.isSearching)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertNil(workspace.activeSearchSelection)

        // Give the detached worker enough time to attempt a late return. Its
        // captured generation/revision must prevent any stale publication.
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertFalse(workspace.isSearching)
    }

    @MainActor
    func testImageOnlyDocumentOffersOCROnlyAfterFullScan() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scan.pdf")
        let document = PDFDocument()
        for index in 0..<2 {
            let image = NSImage(size: CGSize(width: 240, height: 320), flipped: false) { rect in
                (index == 0 ? NSColor.white : NSColor.lightGray).setFill()
                rect.fill()
                return true
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        XCTAssertTrue(document.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.searchText = "unavailable"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertEqual(workspace.searchUnsearchablePageCount, 2)
        XCTAssertTrue(workspace.searchRequiresOCR)
    }

    @MainActor
    func testBlankPageInOtherwiseSearchablePDFDoesNotClaimWholeDocumentNeedsOCR() async throws {
        let fixture = try makeTextPDF(pages: ["This page has a searchable text layer."])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let document = try XCTUnwrap(PDFDocument(url: fixture.url))
        let blankImage = NSImage(size: CGSize(width: 240, height: 320), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        document.insert(try XCTUnwrap(PDFPage(image: blankImage)), at: 1)
        XCTAssertTrue(document.write(to: fixture.url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "not present anywhere"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertEqual(workspace.searchUnsearchablePageCount, 1)
        XCTAssertFalse(workspace.searchRequiresOCR)
    }

    @MainActor
    func testLocalizationRefreshCancelsGenerationWithoutLeavingBusyOrLateResults() async throws {
        let densePage = String(repeating: "searchable localization text ", count: 4_000)
        let fixture = try makeTextPDF(pages: Array(repeating: densePage, count: 8))
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "localization"
        workspace.performSearch()
        XCTAssertTrue(workspace.isSearching)

        workspace.refreshLocalization()
        XCTAssertFalse(workspace.isSearching)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertNil(workspace.activeSearchSelection)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(workspace.isSearching)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
    }

    @MainActor
    func testPerPageSafetyLimitReportsOnlyActualTruncation() async throws {
        var configuration = PDFSearchEngine.Configuration.standard
        configuration.maximumResultsPerPage = 2
        let engine = PDFSearchEngine(configuration: configuration)

        let exactFixture = try makeTextPDF(pages: ["needle needle"])
        addTeardownBlock { try? FileManager.default.removeItem(at: exactFixture.directory) }
        let exactDocument = try XCTUnwrap(PDFDocument(url: exactFixture.url))
        let exact = try await engine.searchPage(
            in: exactDocument,
            pageIndex: 0,
            query: engine.prepare(query: "needle"),
            remainingResultCapacity: 10
        )
        XCTAssertEqual(exact.results.count, 2)
        XCTAssertFalse(exact.reachedPageLimit)

        let overflowFixture = try makeTextPDF(pages: ["needle needle needle"])
        addTeardownBlock { try? FileManager.default.removeItem(at: overflowFixture.directory) }
        let overflowDocument = try XCTUnwrap(PDFDocument(url: overflowFixture.url))
        let overflow = try await engine.searchPage(
            in: overflowDocument,
            pageIndex: 0,
            query: engine.prepare(query: "needle"),
            remainingResultCapacity: 10
        )
        XCTAssertEqual(overflow.results.count, 2)
        XCTAssertTrue(overflow.reachedPageLimit)
    }

    @MainActor
    func testGlobalLimitDistinguishesExactFinalMatchFromActualOmission() async throws {
        var configuration = PDFSearchEngine.Configuration.standard
        configuration.maximumResultCount = 4
        configuration.maximumResultsPerPage = 2
        configuration.publicationPageBatch = 1

        let exactFixture = try makeTextPDF(pages: [
            "needle needle",
            "needle needle"
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: exactFixture.directory) }
        let exactWorkspace = PDFWorkspaceState(searchEngineConfiguration: configuration)
        XCTAssertTrue(exactWorkspace.open(url: exactFixture.url))
        exactWorkspace.searchText = "needle"
        exactWorkspace.performSearch()
        await waitForSearchToFinish(exactWorkspace)
        XCTAssertEqual(exactWorkspace.searchNavigatorResults.count, 4)
        XCTAssertEqual(exactWorkspace.searchProgress.completedPages, 2)
        XCTAssertFalse(exactWorkspace.searchResultsWereTruncated)

        let unscannedFixture = try makeTextPDF(pages: [
            "needle needle",
            "needle needle",
            "needle needle"
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: unscannedFixture.directory) }
        let unscannedWorkspace = PDFWorkspaceState(searchEngineConfiguration: configuration)
        XCTAssertTrue(unscannedWorkspace.open(url: unscannedFixture.url))
        unscannedWorkspace.searchText = "needle"
        unscannedWorkspace.performSearch()
        await waitForSearchToFinish(unscannedWorkspace)
        XCTAssertEqual(unscannedWorkspace.searchNavigatorResults.count, 4)
        XCTAssertEqual(unscannedWorkspace.searchProgress.completedPages, 2)
        XCTAssertTrue(unscannedWorkspace.searchResultsWereTruncated)

        let samePageOverflowFixture = try makeTextPDF(pages: [
            "needle needle",
            "needle needle needle"
        ])
        addTeardownBlock {
            try? FileManager.default.removeItem(at: samePageOverflowFixture.directory)
        }
        let overflowWorkspace = PDFWorkspaceState(searchEngineConfiguration: configuration)
        XCTAssertTrue(overflowWorkspace.open(url: samePageOverflowFixture.url))
        overflowWorkspace.searchText = "needle"
        overflowWorkspace.performSearch()
        await waitForSearchToFinish(overflowWorkspace)
        XCTAssertEqual(overflowWorkspace.searchNavigatorResults.count, 4)
        XCTAssertEqual(overflowWorkspace.searchProgress.completedPages, 2)
        XCTAssertTrue(overflowWorkspace.searchResultsWereTruncated)
    }

    func testSearchPageOrderStartsAtAnchorAndWrapsWithoutDuplicates() {
        XCTAssertEqual(Array(PDFSearchPageOrder(pageCount: 5, startingAt: 3)), [3, 4, 0, 1, 2])
        XCTAssertEqual(Array(PDFSearchPageOrder(pageCount: 3, startingAt: 99)), [2, 0, 1])
        XCTAssertEqual(Array(PDFSearchPageOrder(pageCount: 3, startingAt: -10)), [0, 1, 2])
        XCTAssertTrue(Array(PDFSearchPageOrder(pageCount: 0, startingAt: 0)).isEmpty)
        XCTAssertTrue(Array(PDFSearchPageOrder(pageCount: Int.min, startingAt: 0)).isEmpty)
    }

    @MainActor
    func testSearchCapturesViewedPageAndKeepsAnchorWhileNavigating() async throws {
        let fixture = try makeTextPDF(pages: ["needle zero", "needle one", "needle two", "needle three"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.setCurrentPage(2)
        workspace.searchText = "needle"
        workspace.submitSearch()
        XCTAssertEqual(workspace.searchAnchorPageIndex, 2)
        // A manual page change while the async scan starts cannot change its order.
        workspace.setCurrentPage(0)
        await waitForSearchToFinish(workspace)
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.pageIndex), [2, 3, 0, 1])
        XCTAssertEqual(workspace.currentPageIndex, 2)
        XCTAssertEqual(workspace.searchProgress.completedPages, 4)
        XCTAssertEqual(workspace.searchAnchorPageIndex, 2)
        workspace.submitSearch()
        XCTAssertEqual(workspace.currentPageIndex, 3)
        workspace.submitSearch(backwards: true)
        XCTAssertEqual(workspace.currentPageIndex, 2)
        workspace.submitSearch(backwards: true)
        XCTAssertEqual(workspace.currentPageIndex, 1)
        XCTAssertFalse(workspace.isSearching)
    }

    @MainActor
    func testSubmittingCancelledQueryWithPartialResultsSearchesThroughLastPage() async throws {
        let fixture = try makeTextPDF(pages: ["needle first", "middle", "needle last"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))

        let firstBatch = expectation(description: "First page search result published")
        let observation = workspace.$searchProgress.first { $0.completedPages == 1 }.sink { _ in
            firstBatch.fulfill()
        }
        defer { observation.cancel() }
        workspace.searchText = "needle"
        workspace.submitSearch()
        await fulfillment(of: [firstBatch], timeout: 2)
        workspace.prepareForDeactivation()
        XCTAssertEqual(workspace.searchProgress.phase, .cancelled)
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.pageIndex), [0])

        workspace.submitSearch()
        XCTAssertTrue(workspace.isSearching)
        await waitForSearchToFinish(workspace)
        XCTAssertEqual(workspace.searchProgress.phase, .completed)
        XCTAssertEqual(workspace.searchProgress.completedPages, 3)
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.pageIndex), [0, 2])
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testEnterBeforeFirstPublicationQueuesNextWithoutRestartingSearch() async throws {
        let fixture = try makeTextPDF(pages: ["needle zero", "needle one", "needle two"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.setCurrentPage(1)
        workspace.searchText = "needle"
        workspace.submitSearch()
        XCTAssertTrue(workspace.isSearching)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        workspace.submitSearch()
        await waitForSearchToFinish(workspace)
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.pageIndex), [1, 2, 0])
        XCTAssertEqual(workspace.searchResultIndex, 1)
        XCTAssertEqual(workspace.currentPageIndex, 2)
        XCTAssertEqual(workspace.searchAnchorPageIndex, 1)
    }

    @MainActor
    func testNextAtPartialEndWaitsForActualNextAndRowsCanOverridePendingNavigation() async throws {
        let fixture = try makeTextPDF(pages: ["needle zero", "needle one", "needle two"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        var configuration = PDFSearchEngine.Configuration.standard
        configuration.publicationPageBatch = 99
        let workspace = PDFWorkspaceState(searchEngineConfiguration: configuration)
        XCTAssertTrue(workspace.open(url: fixture.url))
        var requestedNext = false
        var firstID: UUID?
        let observation = workspace.$searchProgress.sink { progress in
            guard progress.completedPages == 1, !requestedNext,
                  workspace.searchNavigatorResults.count == 1 else { return }
            requestedNext = true
            firstID = workspace.searchNavigatorResults.first?.id
            XCTAssertTrue(workspace.isSearching)
            workspace.submitSearch()
            // There is only one published hit. Next must not wrap back to it
            // or restart the scan while the next page is still outstanding.
            XCTAssertEqual(workspace.searchResultIndex, 0)
        }
        workspace.searchText = "needle"
        workspace.submitSearch()
        await waitForSearchToFinish(workspace)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(requestedNext, "The anchor page must publish before the rest of a large batch.")
        XCTAssertEqual(workspace.searchNavigatorResults.first?.id, firstID)
        XCTAssertEqual(workspace.searchResultIndex, 1)
        XCTAssertEqual(workspace.currentPageIndex, 1)

        // A second run queues a backward wrap before anything is published.
        // A concrete row click during publication supersedes that request.
        workspace.clearSearch()
        workspace.setCurrentPage(0)
        var clicked = false
        let clickObservation = workspace.$searchProgress.sink { progress in
            guard progress.completedPages == 1, !clicked,
                  let result = workspace.searchNavigatorResults.first else { return }
            clicked = true
            workspace.selectSearchResult(id: result.id)
        }
        workspace.searchText = "needle"
        workspace.submitSearch()
        workspace.submitSearch(backwards: true)
        await waitForSearchToFinish(workspace)
        withExtendedLifetime(clickObservation) {}
        XCTAssertTrue(clicked)
        XCTAssertEqual(workspace.searchResultIndex, 0)
        XCTAssertEqual(workspace.currentPageIndex, 0)
    }

    @MainActor
    func testPendingBackwardNavigationResolvesAtCompletionAndNewQueryResetsAnchor() async throws {
        let fixture = try makeTextPDF(pages: ["needle zero other", "needle one other", "needle two other"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.setCurrentPage(1)
        workspace.searchText = "needle"
        workspace.submitSearch()
        workspace.submitSearch(backwards: true)
        await waitForSearchToFinish(workspace)
        XCTAssertEqual(workspace.searchResultIndex, 2)
        XCTAssertEqual(workspace.currentPageIndex, 0)
        workspace.setCurrentPage(2)
        workspace.searchText = "other"
        workspace.submitSearch()
        await waitForSearchToFinish(workspace)
        XCTAssertEqual(workspace.searchAnchorPageIndex, 2)
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.pageIndex), [2, 0, 1])
        XCTAssertEqual(workspace.searchResultIndex, 0)
    }


    @MainActor
    func testLocalizationPreservesCompletedResultsNavigationAndSelectionOwnership() async throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: AppPreferences.languageDefaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: AppPreferences.languageDefaultsKey) }
        }
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppPreferences.languageDefaultsKey)
        let fixture = try makeTextPDF(pages: ["needle one needle two needle three", "needle four needle five"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "needle"; workspace.performSearch()
        await waitForSearchToFinish(workspace)
        XCTAssertEqual(workspace.searchNavigatorResults.count, 5)
        workspace.selectSearchResult(at: 3)
        let ids = workspace.searchNavigatorResults.map(\.id)
        let progress = workspace.searchProgress, document = workspace.document
        let selection = try XCTUnwrap(workspace.activeSearchSelection)
        let revision = workspace.revision
        // The editor may own selection now. Localization must not revive the
        // search-owned selection or start scanning this unchanged PDF again.
        workspace.currentSelection = nil
        var completionEmissions = 0
        let observation = workspace.$searchCompletedQuery.sink { if $0 == "needle" { completionEmissions += 1 } }
        defer { observation.cancel() }
        UserDefaults.standard.set(AppLanguage.japanese.rawValue, forKey: AppPreferences.languageDefaultsKey)
        workspace.refreshLocalization()
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.id), ids)
        XCTAssertEqual(workspace.searchProgress, progress)
        XCTAssertEqual(workspace.searchCompletedQuery, "needle")
        XCTAssertTrue(workspace.searchHasCompletedCurrentQuery)
        XCTAssertEqual(workspace.searchResultIndex, 3)
        XCTAssertEqual(workspace.currentPageIndex, 1)
        XCTAssertTrue(workspace.activeSearchSelection === selection)
        XCTAssertNil(workspace.currentSelection)
        XCTAssertTrue(workspace.document === document)
        XCTAssertNotEqual(workspace.revision, revision)
        XCTAssertFalse(workspace.isSearchBusy)
        XCTAssertEqual(completionEmissions, 1)
        XCTAssertEqual(workspace.statusMessage, L10n.format("status.search_results", 5))
        XCTAssertFalse(workspace.isDirty); XCTAssertFalse(workspace.canUndo)
        workspace.showNextSearchResult()
        XCTAssertEqual(workspace.searchResultIndex, 4)
        XCTAssertEqual(workspace.activeSearchSelection?.string?.lowercased(), "needle")
    }

    @MainActor
    func testLocalizationPreservesCompletedNoMatchesAndRelocalizesSummary() async throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: AppPreferences.languageDefaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: AppPreferences.languageDefaultsKey) }
        }
        let fixture = try makeTextPDF(pages: ["searchable first page", "searchable second page"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState(); defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "absent"; workspace.performSearch()
        await waitForSearchToFinish(workspace)
        XCTAssertTrue(workspace.searchHasCompletedCurrentQuery)
        let progress = workspace.searchProgress
        UserDefaults.standard.set(AppLanguage.japanese.rawValue, forKey: AppPreferences.languageDefaultsKey)
        workspace.refreshLocalization()
        XCTAssertEqual(workspace.searchText, "absent")
        XCTAssertEqual(workspace.searchCompletedQuery, "absent")
        XCTAssertTrue(workspace.searchHasCompletedCurrentQuery)
        XCTAssertEqual(workspace.searchProgress, progress)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertFalse(workspace.searchRequiresOCR)
        XCTAssertEqual(workspace.statusMessage, L10n.string("status.search_no_results"))
        XCTAssertFalse(workspace.isSearchBusy)
    }

    @MainActor
    func testLocalizationPreservesCompletedOCRNeedWithoutInventingMatches() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scan-localization.pdf"), document = PDFDocument()
        for index in 0..<2 {
            let image = NSImage(size: CGSize(width: 240, height: 320), flipped: false) { rect in
                (index == 0 ? NSColor.white : NSColor.lightGray).setFill(); rect.fill(); return true
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState(); defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: url))
        workspace.searchText = "unavailable"; workspace.performSearch()
        await waitForSearchToFinish(workspace)
        XCTAssertTrue(workspace.searchRequiresOCR)
        let progress = workspace.searchProgress
        workspace.refreshLocalization()
        XCTAssertTrue(workspace.searchHasCompletedCurrentQuery)
        XCTAssertEqual(workspace.searchCompletedQuery, "unavailable")
        XCTAssertEqual(workspace.searchProgress, progress)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertEqual(workspace.searchUnsearchablePageCount, 2)
        XCTAssertTrue(workspace.searchRequiresOCR)
        XCTAssertNil(workspace.activeSearchSelection)
        XCTAssertFalse(workspace.isSearchBusy)
    }

    @MainActor
    func testLocalizationDoesNotPromoteCancelledSearchToCompletedResults() async throws {
        let fixture = try makeTextPDF(pages: ["needle first", "needle second"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState(); defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "needle"; workspace.performSearch(); workspace.cancelSearch()
        XCTAssertEqual(workspace.searchProgress.phase, .cancelled)
        workspace.refreshLocalization()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(workspace.searchText, "needle")
        XCTAssertNil(workspace.searchCompletedQuery)
        XCTAssertFalse(workspace.searchHasCompletedCurrentQuery)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertEqual(workspace.searchProgress.phase, .idle)
        XCTAssertFalse(workspace.isSearchBusy); XCTAssertFalse(workspace.searchRequiresOCR)
        XCTAssertEqual(workspace.statusMessage, L10n.format("status.opened_pages", 2))
    }

    @MainActor
    private func waitForSearchToFinish(
        _ workspace: PDFWorkspaceState,
        timeoutIterations: Int = 1_000
    ) async {
        for _ in 0..<timeoutIterations {
            if !workspace.isSearching { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Search did not finish before the test timeout")
    }

    @MainActor
    private func makeTextPDF(pages: [String]) throws -> (directory: URL, url: URL) {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("multilingual-search.pdf")
        let result = PDFDocument()

        for (index, text) in pages.enumerated() {
            let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 720, height: 900))
            textView.backgroundColor = .white
            textView.textColor = .black
            textView.font = .systemFont(ofSize: 17)
            textView.isHorizontallyResizable = false
            textView.textContainer?.containerSize = CGSize(
                width: 680,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = true
            textView.string = text
            let data = textView.dataWithPDF(inside: textView.bounds)
            let pageDocument = try XCTUnwrap(PDFDocument(data: data))
            result.insert(try XCTUnwrap(pageDocument.page(at: 0)), at: index)
        }
        XCTAssertTrue(result.write(to: url))
        return (directory, url)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-SearchTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
