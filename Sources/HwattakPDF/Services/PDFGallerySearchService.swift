// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation
import PDFKit

/// Bounded transient search, not a persistent text index. Resident documents
/// stay on their owner actor so unsaved edits are searched; sleeping tabs use
/// one background-owned PDF at a time and never change workspace state.
@MainActor
final class PDFGallerySearchController: ObservableObject {
    @Published private(set) var documentResults: [PDFGalleryDocumentSearchResult] = []
    @Published private(set) var progress: PDFGallerySearchProgress = .idle
    @Published private(set) var query = ""

    private let configuration: PDFGallerySearchConfiguration
    private let engine: PDFSearchEngine
    private let reader = PDFGalleryTransientSearchReader()
    private var requestID = UUID()
    private var searchTask: Task<Void, Never>?

    init(configuration: PDFGallerySearchConfiguration = .standard) {
        self.configuration = configuration
        var engineConfiguration = PDFSearchEngine.Configuration.standard
        engineConfiguration.maximumResultsPerPage = max(1, configuration.maximumResultsPerPage)
        engine = PDFSearchEngine(configuration: engineConfiguration)
    }

    deinit { searchTask?.cancel() }

    func search(query: String, documents: [PDFGalleryDocument]) async {
        guard !Task.isCancelled else { return }
        searchTask?.cancel()
        let previousRequest = requestID
        let request = UUID()
        requestID = request
        let prepared = engine.prepare(query: query)
        self.query = prepared.source
        var seen: Set<UUID> = []
        let uniqueDocuments = documents.filter { seen.insert($0.id).inserted }
        guard !prepared.isEmpty else {
            documentResults = []
            progress = .idle
            await reader.close(request: previousRequest)
            return
        }

        // Name matches appear before reading even one PDF page. Retain status
        // rows for all documents so the UI can honestly summarize skipped files.
        documentResults = uniqueDocuments.map { document in
            PDFGalleryDocumentSearchResult(
                document: document,
                filenameMatched: PDFUnicodeSearchNormalizer.normalizeQuery(document.session.displayName)
                    .contains(prepared.normalized),
                documentRevision: document.session.workspace.revision,
                totalPages: document.session.workspace.pageCount
            )
        }
        progress = PDFGallerySearchProgress(phase: .searching, totalDocuments: uniqueDocuments.count)
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.perform(query: prepared, request: request)
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
        let previousRequest = requestID
        requestID = UUID()
        if progress.phase == .searching { progress.phase = .cancelled }
        // Closing on the actor releases the sole transient document and scope.
        // An old request's keyed close cannot dispose of a newer document.
        Task { await reader.close(request: previousRequest) }
    }

    private func perform(query: PDFSearchEngine.PreparedQuery, request: UUID) async {
        do {
            try await Task.sleep(nanoseconds: configuration.debounceNanoseconds)
            try requireCurrent(request)
            for index in documentResults.indices {
                try requireCurrent(request)
                if progress.resultCount >= max(1, configuration.maximumTotalResults) {
                    for remaining in index..<documentResults.count {
                        documentResults[remaining].status = .notSearched
                        documentResults[remaining].isTruncated = true
                    }
                    refreshProgress()
                    break
                }
                await searchDocument(at: index, query: query, request: request)
            }
            try requireCurrent(request)
            progress.phase = .completed
            searchTask = nil
        } catch {
            if requestID == request { progress.phase = .cancelled }
        }
        await reader.close(request: request)
    }

    private func searchDocument(at index: Int, query: PDFSearchEngine.PreparedQuery, request: UUID) async {
        let initial = documentResults[index]
        let workspace = initial.document.session.workspace
        guard workspace.revision == initial.documentRevision else {
            finish(index, status: .changed)
            return
        }
        let revision = workspace.revision
        let url = workspace.documentURL
        let resident = workspace.document
        let residentID = resident.map(ObjectIdentifier.init)
        let documentToken = UUID()
        var hasText = false
        var nextPage = 0
        var totalPages = workspace.pageCount
        let identityIsCurrent = {
            workspace.revision == revision && workspace.documentURL == url &&
                workspace.document.map(ObjectIdentifier.init) == residentID
        }

        do {
            if let resident {
                guard !resident.isLocked else { finish(index, status: .locked); return }
                guard resident.allowsCopying || resident.permissionsStatus == .owner else {
                    finish(index, status: .copyRestricted); return
                }
                totalPages = resident.pageCount
            } else {
                guard let url, url.isFileURL else { finish(index, status: .unavailable); return }
                let opened = await reader.open(url: url, request: request, token: documentToken)
                try requireCurrent(request)
                guard identityIsCurrent() else { finish(index, status: .changed, discardMatches: true); return }
                guard opened.status == .searching else { finish(index, status: opened.status); return }
                totalPages = opened.pageCount
                documentResults[index].sourceVersion = opened.version
            }
            documentResults[index].totalPages = totalPages
            while nextPage < totalPages {
                try requireCurrent(request)
                guard identityIsCurrent() else { finish(index, status: .changed, discardMatches: true); break }
                let capacity = min(max(1, configuration.maximumResultsPerDocument) - documentResults[index].matches.count,
                                   max(1, configuration.maximumTotalResults) - progress.resultCount)
                guard capacity > 0 else {
                    documentResults[index].isTruncated = true
                    finish(index, status: .completed)
                    break
                }
                let batch: PDFGallerySearchBatch
                if let resident {
                    let outcome = try await engine.searchPage(in: resident, pageIndex: nextPage,
                                                              query: query, remainingResultCapacity: capacity)
                    batch = PDFGallerySearchBatch(results: outcome.results, nextPage: nextPage + 1,
                        hasText: outcome.hasExtractableText, isTruncated: outcome.reachedPageLimit)
                } else {
                    batch = try await reader.scan(token: documentToken, from: nextPage, query: query,
                        capacity: capacity, engine: engine, pageBatch: max(1, configuration.publicationPageBatch))
                }
                try requireCurrent(request)
                guard identityIsCurrent(), !batch.sourceChanged else {
                    finish(index, status: .changed, discardMatches: true); break
                }
                nextPage = batch.nextPage
                hasText = hasText || batch.hasText
                documentResults[index].matches.append(contentsOf: batch.results)
                documentResults[index].scannedPages = nextPage
                documentResults[index].isTruncated = documentResults[index].isTruncated || batch.isTruncated
                refreshProgress()
                if nextPage == totalPages {
                    finish(index, status: hasText ? .completed : .noText)
                }
                await Task.yield()
            }
            if totalPages == 0 { finish(index, status: .noText) }
        } catch is CancellationError {
            // The next request owns all published state; no stale completion.
        } catch {
            if requestID == request { finish(index, status: .unavailable, discardMatches: true) }
        }
        await reader.close(token: documentToken)
    }

    private func finish(_ index: Int, status: PDFGalleryDocumentSearchStatus, discardMatches: Bool = false) {
        documentResults[index].status = status
        if discardMatches { documentResults[index].matches = [] }
        refreshProgress()
    }

    private func refreshProgress() {
        progress.scannedDocuments = documentResults.filter {
            $0.status != .searching && $0.status != .notSearched
        }.count
        progress.scannedPages = documentResults.reduce(0) { $0 + $1.scannedPages }
        progress.resultCount = documentResults.reduce(0) { $0 + $1.matches.count }
        progress.isTruncated = documentResults.contains { $0.isTruncated }
        progress.skippedDocumentCount = documentResults.filter { $0.status.isSkipped }.count
    }

    private func requireCurrent(_ request: UUID) throws {
        try Task.checkCancellation()
        if requestID != request { throw CancellationError() }
    }
}

private struct PDFGallerySearchBatch: Sendable {
    var results: [PDFSearchResult] = []
    var nextPage: Int
    var hasText = false
    var isTruncated = false
    var sourceChanged = false
}

/// Each method is synchronous on this actor: PDFKit page extraction and text
/// matching cannot interleave with a replacement open. Only Sendable values
/// leave it, and every new open releases the previous document first.
private actor PDFGalleryTransientSearchReader {
    struct Opened {
        var status: PDFGalleryDocumentSearchStatus
        var pageCount = 0
        var version: PDFSourceFileVersion?
    }

    private var document: PDFDocument?
    private var access: SecurityScopedAccess?
    private var url: URL?
    private var version: PDFSourceFileVersion?
    private var request: UUID?
    private var token: UUID?

    func open(url: URL, request: UUID, token: UUID) -> Opened {
        close()
        guard !Task.isCancelled else { return Opened(status: .notSearched) }
        access = SecurityScopedAccess(url: url)
        guard let loaded = try? PDFSourceFileAccess.loadDocument(at: url) else {
            close(); return Opened(status: .unavailable)
        }
        guard !loaded.document.isLocked else { close(); return Opened(status: .locked) }
        guard loaded.document.allowsCopying || loaded.document.permissionsStatus == .owner else {
            close(); return Opened(status: .copyRestricted)
        }
        self.document = loaded.document
        self.url = url
        self.version = loaded.version
        self.request = request
        self.token = token
        return Opened(status: .searching, pageCount: loaded.document.pageCount, version: loaded.version)
    }

    func scan(token: UUID, from start: Int, query: PDFSearchEngine.PreparedQuery,
              capacity: Int, engine: PDFSearchEngine, pageBatch: Int) throws -> PDFGallerySearchBatch {
        try Task.checkCancellation()
        guard token == self.token, let document, let url, let version,
              (try? PDFSourceFileVersion.capture(at: url)) == version else {
            return PDFGallerySearchBatch(nextPage: start, sourceChanged: true)
        }
        var batch = PDFGallerySearchBatch(nextPage: start)
        for pageIndex in start..<min(document.pageCount, start + pageBatch) {
            try Task.checkCancellation()
            let outcome = try autoreleasepool { () throws -> PDFSearchEngine.PageOutcome in
                let page = document.page(at: pageIndex)
                return try engine.searchText(page?.string ?? "", pageIndex: pageIndex,
                    pageLabel: page?.label ?? String(pageIndex + 1), query: query,
                    remainingResultCapacity: capacity - batch.results.count)
            }
            batch.results.append(contentsOf: outcome.results)
            batch.nextPage = pageIndex + 1
            batch.hasText = batch.hasText || outcome.hasExtractableText
            batch.isTruncated = batch.isTruncated || outcome.reachedPageLimit
            // Publish the first hits promptly even in a very large PDF.
            if !batch.results.isEmpty { break }
        }
        if (try? PDFSourceFileVersion.capture(at: url)) != version { batch.sourceChanged = true }
        return batch
    }

    func close(request: UUID? = nil, token: UUID? = nil) {
        if let request, request != self.request { return }
        if let token, token != self.token { return }
        document = nil
        access = nil
        url = nil
        version = nil
        self.request = nil
        self.token = nil
    }
}
