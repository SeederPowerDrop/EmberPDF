// SPDX-License-Identifier: MPL-2.0
import AppKit
import Combine
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFSearchDebounceTests: XCTestCase {
    @MainActor
    func testRapidTypingSearchesOnlyLatestQueryAndActivatesGermanPhrase() async throws {
        let fixture = try makePDF(["alpha first", "unrelated", "die alte Tribüne bleibt erhalten"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = PendingClock()
        let workspace = PDFWorkspaceState(searchDebounceDelay: { await clock.wait() })
        defer { workspace.closeDiscardingChanges(); clock.releaseAll() }
        XCTAssertTrue(workspace.open(url: fixture.url)); workspace.setCurrentPage(2)
        for (index, query) in ["missing", "alpha", "alte Tribune"].enumerated() {
            workspace.searchText = query
            await waitUntil { clock.count == index + 1 }
            XCTAssertTrue(workspace.isSearchPending)
            XCTAssertFalse(workspace.isSearching)
            XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
            XCTAssertEqual(workspace.searchProgress.completedPages, 0)
            XCTAssertFalse(workspace.searchRequiresOCR)
        }
        clock.releaseAll()
        await waitUntil { workspace.searchCompletedQuery == "alte Tribune" }
        XCTAssertFalse(workspace.isSearchBusy)
        XCTAssertEqual(workspace.searchNavigatorResults.count, 1)
        XCTAssertEqual(workspace.searchNavigatorResults.first?.pageIndex, 2)
        XCTAssertEqual(workspace.activeSearchSelection?.string, "alte Tribüne")
        XCTAssertEqual(workspace.searchAnchorPageIndex, 2)
        XCTAssertFalse(workspace.isDirty); XCTAssertFalse(workspace.canUndo)
    }

    @MainActor
    func testEnterCancelsDebounceAndLateClockDoesNotRestartOrResetNavigation() async throws {
        let fixture = try makePDF(["needle zero", "needle one", "needle two"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = PendingClock()
        let workspace = PDFWorkspaceState(searchDebounceDelay: { await clock.wait() })
        defer { workspace.closeDiscardingChanges(); clock.releaseAll() }
        XCTAssertTrue(workspace.open(url: fixture.url))
        var completions = 0
        let observer = workspace.$searchCompletedQuery.sink { if $0 == "needle" { completions += 1 } }
        defer { observer.cancel() }
        workspace.searchText = "needle"
        await waitUntil { clock.count == 1 }
        workspace.submitSearch()
        XCTAssertFalse(workspace.isSearchPending); XCTAssertTrue(workspace.isSearching)
        await waitUntil { workspace.searchCompletedQuery == "needle" }
        workspace.submitSearch(); XCTAssertEqual(workspace.searchResultIndex, 1)
        workspace.submitSearch(backwards: true); XCTAssertEqual(workspace.searchResultIndex, 0)
        workspace.submitSearch(); XCTAssertEqual(workspace.searchResultIndex, 1)
        let ids = workspace.searchNavigatorResults.map(\.id)
        clock.releaseAll() // Deliberately deliver a cancelled timer late.
        await drainTasks()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(workspace.searchResultIndex, 1)
        XCTAssertEqual(workspace.searchAnchorPageIndex, 0)
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.id), ids)
        XCTAssertFalse(workspace.isSearchBusy)
    }

    @MainActor
    func testClearCancelCloseDeactivationRevisionLocalizationAndReplacementCancelPendingWork() async throws {
        let fixture = try makePDF(["needle first", "needle second", "needle third"])
        let replacement = try makePDF(["different document"])
        defer { try? FileManager.default.removeItem(at: fixture.directory); try? FileManager.default.removeItem(at: replacement.directory) }
        for action in ["clear", "cancel", "close", "deactivate", "revision", "localize", "replace"] {
            let clock = PendingClock()
            let workspace = PDFWorkspaceState(searchDebounceDelay: { await clock.wait() })
            XCTAssertTrue(workspace.open(url: fixture.url))
            workspace.setMode(.editing)
            workspace.searchText = "needle"
            await waitUntil { clock.count == 1 }
            switch action {
            case "clear": workspace.clearSearch()
            case "cancel": workspace.cancelSearch()
            case "close": workspace.close()
            case "deactivate": workspace.prepareForDeactivation()
            case "revision": workspace.movePage(from: 0, before: 2)
            case "localize": workspace.refreshLocalization()
            default: XCTAssertTrue(workspace.open(url: replacement.url))
            }
            XCTAssertFalse(workspace.isSearchPending, action)
            clock.releaseAll(); await drainTasks()
            XCTAssertFalse(workspace.isSearchBusy, action)
            XCTAssertTrue(workspace.searchNavigatorResults.isEmpty, action)
            XCTAssertNil(workspace.searchCompletedQuery, action)
            XCTAssertFalse(workspace.searchRequiresOCR, action)
            workspace.closeDiscardingChanges()
        }
    }

    @MainActor
    func testPendingTimerDoesNotRetainWorkspaceOrItsDocument() async throws {
        let fixture = try makePDF(["needle"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = PendingClock()
        var workspace: PDFWorkspaceState?
        weak var weakWorkspace: PDFWorkspaceState?
        weak var weakDocument: PDFDocument?
        autoreleasepool {
            workspace = PDFWorkspaceState(searchDebounceDelay: { await clock.wait() })
            XCTAssertTrue(workspace!.open(url: fixture.url))
            weakWorkspace = workspace; weakDocument = workspace?.document
            workspace?.searchText = "needle"
        }
        await waitUntil { clock.count == 1 }
        workspace = nil
        XCTAssertNil(weakWorkspace)
        XCTAssertNil(weakDocument)
        clock.releaseAll(); await drainTasks()
    }

    @MainActor
    func testDefaultTypingStartsSearchWithoutReturnAndEmptyQueryDoesNotQueue() async throws {
        let fixture = try makePDF(["die alte Tribüne bleibt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "alte Tribüne"
        XCTAssertTrue(workspace.isSearchPending)
        XCTAssertFalse(workspace.isSearching)
        await waitUntil { workspace.searchCompletedQuery == "alte Tribüne" }
        XCTAssertEqual(workspace.activeSearchSelection?.string, "alte Tribüne")
        workspace.searchText = " \n "
        XCTAssertFalse(workspace.isSearchBusy)
        XCTAssertNil(workspace.searchCompletedQuery)
    }

    func testIdleAndPendingPresentationCannotClaimNoMatchesOrOCRBeforeCompletion() {
        XCTAssertEqual(SearchNavigatorEmptyContent.resolve(isSearching: false, queryIsEmpty: false,
            wasCancelled: false, completedPages: 0, totalPages: 0, requiresOCR: true,
            unsearchablePageCount: 4, hasCompletedQuery: false), .queryPrompt)
        XCTAssertEqual(SearchNavigatorEmptyContent.resolve(isSearching: true, queryIsEmpty: false,
            wasCancelled: false, completedPages: 0, totalPages: 0, requiresOCR: true,
            unsearchablePageCount: 4, hasCompletedQuery: false), .searching)
        XCTAssertEqual(SearchNavigatorEmptyContent.resolve(isSearching: false, queryIsEmpty: false,
            wasCancelled: false, completedPages: 4, totalPages: 4, requiresOCR: false,
            unsearchablePageCount: 0, hasCompletedQuery: true), .noMatches)
    }


    @MainActor
    func testLocalizationDoesNotPreserveOldCompletedResultsForChangedPendingQuery() async throws {
        let fixture = try makePDF(["needle zero other", "needle one other"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = PendingClock()
        let workspace = PDFWorkspaceState(searchDebounceDelay: { await clock.wait() })
        defer { workspace.closeDiscardingChanges(); clock.releaseAll() }
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "needle"; await waitUntil { clock.count == 1 }
        workspace.submitSearch(); await waitUntil { workspace.searchHasCompletedCurrentQuery }
        XCTAssertEqual(workspace.searchNavigatorResults.count, 2)
        workspace.searchText = "other"; await waitUntil { clock.count == 2 }
        XCTAssertTrue(workspace.isSearchPending)
        workspace.refreshLocalization()
        clock.releaseAll(); await drainTasks()
        XCTAssertEqual(workspace.searchText, "other")
        XCTAssertNil(workspace.searchCompletedQuery)
        XCTAssertFalse(workspace.searchHasCompletedCurrentQuery)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertNil(workspace.activeSearchSelection)
        XCTAssertFalse(workspace.isSearchBusy)
        XCTAssertEqual(workspace.searchProgress.phase, .idle)
        XCTAssertEqual(workspace.statusMessage, L10n.format("status.opened_pages", 2))
    }

    @MainActor
    func testLocalizationDoesNotPromoteFailedDebounceAndRefreshesTransientStatus() async throws {
        struct DeliberateDelayFailure: Error {}
        let fixture = try makePDF(["needle one"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState(searchDebounceDelay: { throw DeliberateDelayFailure() })
        defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "needle"
        await waitUntil { !workspace.isSearchPending }
        XCTAssertFalse(workspace.searchHasCompletedCurrentQuery)
        workspace.statusMessage = "old transient search status"
        workspace.refreshLocalization(); await drainTasks()
        XCTAssertEqual(workspace.searchText, "needle")
        XCTAssertNil(workspace.searchCompletedQuery)
        XCTAssertFalse(workspace.searchHasCompletedCurrentQuery)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertFalse(workspace.isSearchBusy)
        XCTAssertEqual(workspace.searchProgress.phase, .idle)
        XCTAssertEqual(workspace.statusMessage, L10n.format("status.opened_pages", 1))
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<2_500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for the search state")
    }
    @MainActor private func drainTasks() async {
        for _ in 0..<12 { await Task.yield() }
    }
    @MainActor private func makePDF(_ strings: [String]) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-debounce-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = PDFDocument()
        for (index, string) in strings.enumerated() {
            let bytes = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 400, height: 500)
            let consumer = try XCTUnwrap(CGDataConsumer(data: bytes)), context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil); context.textPosition = CGPoint(x: 20, y: 400)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 18)])), context)
            context.endPDFPage(); context.closePDF()
            let page = try XCTUnwrap(PDFDocument(data: bytes as Data)?.page(at: 0))
            document.insert(page, at: index)
        }
        let url = directory.appendingPathComponent("search.pdf"); XCTAssertTrue(document.write(to: url))
        return (directory, url)
    }

    /// Deliberately ignores cancellation until releaseAll, exercising a late
    /// clock delivery independently of the model's generation/task checks.
    private final class PendingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock(); waiters.append(continuation); lock.unlock()
            }
        }
        func releaseAll() {
            lock.lock(); let pending = waiters; waiters.removeAll(); lock.unlock()
            pending.forEach { $0.resume() }
        }
    }
}
