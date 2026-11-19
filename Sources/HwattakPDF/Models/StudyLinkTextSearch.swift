// SPDX-License-Identifier: MPL-2.0

import Combine
import PDFKit

/// Read the selected tab's live reading position at the moment the shortcut
/// is pressed, independently of a typed page draft or a selected search hit.
@MainActor
enum StudyLinkReadingLocation {
    static func pageIndex(in workspace: PDFWorkspaceState) -> Int? {
        guard let document = workspace.document, !document.isLocked,
              workspace.currentPageIndex >= 0, workspace.currentPageIndex < document.pageCount else { return nil }
        return workspace.currentPageIndex
    }
}

/// Private, transient page search for the link picker. The PDF's ordinary
/// search, current selection, navigation and unsaved contents are untouched.
@MainActor
final class StudyLinkTextSearch: ObservableObject {
    enum Status: Equatable { case idle, searching, completed, changed, unavailable, copyRestricted }
    @Published private(set) var results: [PDFSearchResult] = []
    @Published private(set) var progress: PDFSearchProgress = .idle
    @Published private(set) var status: Status = .idle
    @Published private(set) var textlessPageCount = 0
    @Published private(set) var queryForResults = ""

    private let engine: PDFSearchEngine
    private let maximumResultPages: Int
    private let debounceNanoseconds: UInt64
    private var generation = UUID()
    private var searchTask: Task<Void, Never>?
    private weak var searchedWorkspace: PDFWorkspaceState?
    private weak var searchedDocument: PDFDocument?
    private var searchedRevision: UUID?

    init(maximumResultPages: Int = 200, debounceNanoseconds: UInt64 = 220_000_000) {
        self.maximumResultPages = min(200, max(1, maximumResultPages))
        self.debounceNanoseconds = debounceNanoseconds
        var configuration = PDFSearchEngine.Configuration.standard
        configuration.maximumResultCount = self.maximumResultPages
        // Linking chooses a page, so one contextual excerpt per page is
        // enough even when a word occurs thousands of times on that page.
        configuration.maximumResultsPerPage = 1
        configuration.snippetContextCharacters = 72
        engine = PDFSearchEngine(configuration: configuration)
    }

    deinit { searchTask?.cancel() }

    func search(query: String, in workspace: PDFWorkspaceState) async {
        guard !Task.isCancelled else { return }
        cancel()
        let request = UUID()
        generation = request
        let prepared = engine.prepare(query: Self.boundedQuery(query))
        queryForResults = prepared.source
        guard !prepared.isEmpty else { return }
        guard let document = workspace.document, !document.isLocked else { status = .unavailable; return }
        guard document.allowsCopying || document.permissionsStatus == .owner else {
            status = .copyRestricted; return
        }
        searchedWorkspace = workspace
        searchedDocument = document
        searchedRevision = workspace.revision
        let revision = workspace.revision
        let order = PDFSearchPageOrder(pageCount: document.pageCount, startingAt: workspace.currentPageIndex)
        status = .searching
        progress = PDFSearchProgress(phase: .searching, completedPages: 0, totalPages: document.pageCount,
                                     resultCount: 0, isTruncated: false)
        let task = Task { @MainActor [weak self, weak workspace, weak document] in
            guard let self, let workspace, let document else { return }
            await self.perform(query: prepared, workspace: workspace, document: document,
                               revision: revision, order: order, request: request)
        }
        searchTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        generation = UUID()
        results = []; progress = .idle; status = .idle; textlessPageCount = 0; queryForResults = ""
        searchedWorkspace = nil; searchedDocument = nil; searchedRevision = nil
    }

    /// The Add button may only use a result from the exact current document
    /// graph, revision and query, including while later pages are scanning.
    func pageIndex(for resultID: UUID?, query: String, in workspace: PDFWorkspaceState) -> Int? {
        guard let resultID, searchedWorkspace === workspace,
              searchedDocument === workspace.document, searchedRevision == workspace.revision,
              engine.prepare(query: Self.boundedQuery(query)).source == queryForResults,
              let result = results.first(where: { $0.id == resultID }),
              result.pageIndex >= 0, result.pageIndex < workspace.pageCount else { return nil }
        return result.pageIndex
    }

    static func boundedQuery(_ query: String) -> String {
        String(decoding: query.utf16.prefix(256), as: UTF16.self)
    }

    private func perform(query: PDFSearchEngine.PreparedQuery, workspace: PDFWorkspaceState,
                         document: PDFDocument, revision: UUID,
                         order: PDFSearchPageOrder, request: UUID) async {
        defer { if generation == request { searchTask = nil } }
        do {
            if debounceNanoseconds > 0 { try await Task.sleep(nanoseconds: debounceNanoseconds) }
            var completedPages = 0
            var textlessPages = 0
            for pageIndex in order {
                try Task.checkCancellation()
                guard isCurrent(request, workspace, document, revision) else {
                    invalidateIfOwned(request); return
                }
                let outcome = try await engine.searchPage(in: document, pageIndex: pageIndex,
                    query: query, remainingResultCapacity: maximumResultPages - results.count)
                guard isCurrent(request, workspace, document, revision) else {
                    invalidateIfOwned(request); return
                }
                if !outcome.results.isEmpty { results.append(contentsOf: outcome.results) }
                textlessPages += outcome.hasExtractableText ? 0 : 1
                completedPages += 1
                let reachedLimit = results.count >= maximumResultPages
                if completedPages == 1 || completedPages % 6 == 0 || !outcome.results.isEmpty
                    || completedPages == document.pageCount || reachedLimit {
                    textlessPageCount = textlessPages
                    progress = PDFSearchProgress(phase: .searching, completedPages: completedPages,
                        totalPages: document.pageCount, resultCount: results.count,
                        isTruncated: reachedLimit && completedPages < document.pageCount)
                }
                if reachedLimit { break }
                await Task.yield()
            }
            guard isCurrent(request, workspace, document, revision) else {
                invalidateIfOwned(request); return
            }
            progress.phase = .completed
            status = .completed
        } catch is CancellationError {
            if generation == request {
                results = []
                progress.phase = .cancelled
                status = .idle
            }
        } catch {
            if generation == request {
                results = []
                progress.phase = .cancelled
                status = .unavailable
            }
        }
    }

    private func isCurrent(_ request: UUID, _ workspace: PDFWorkspaceState,
                           _ document: PDFDocument, _ revision: UUID) -> Bool {
        !Task.isCancelled && generation == request && workspace.document === document
            && workspace.revision == revision && searchedWorkspace === workspace
    }

    private func invalidateIfOwned(_ request: UUID) {
        guard generation == request else { return }
        results = []
        progress.phase = .cancelled
        status = .changed
    }
}
