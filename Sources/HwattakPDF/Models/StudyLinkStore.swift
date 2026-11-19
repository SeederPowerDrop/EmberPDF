// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit

/// Bidirectional local links with the same explicit bookmark boundary as
/// Recent Documents. A stored path is only a matching/display hint, never a
/// grant to open a file. No PDF-supplied JavaScript, URI or Launch action runs.
@MainActor
final class StudyLinkStore: ObservableObject {
    static let shared = StudyLinkStore()
    static let maximumLinks = 500
    static let maximumDocuments = 250
    static let maximumStoredBytes = 16 * 1_024 * 1_024

    @Published private(set) var links: [StudyLink] = []
    @Published private(set) var documents: [StudyLinkDocument] = []
    @Published private(set) var loadError: StudyLinkError?

    private struct Archive: Codable {
        var version = 1
        var documents: [StudyLinkDocument]
        var links: [StudyLink]
    }

    private let persistence: any RecentDocumentsPersisting
    private let bookmarkCoder: any RecentDocumentBookmarkCoding
    private var checkedPaths: Set<String> = []

    init(persistence: any RecentDocumentsPersisting = UserDefaultsRecentDocumentsPersistence(
        key: "com.emberpdf.study-links.v1"
    ), bookmarkCoder: any RecentDocumentBookmarkCoding = SecurityScopedRecentDocumentBookmarkCoder()) {
        self.persistence = persistence
        self.bookmarkCoder = bookmarkCoder
        guard let data = persistence.data else { return }
        guard data.count <= Self.maximumStoredBytes,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              Self.isValid(archive) else { loadError = .corruptStorage; return }
        documents = archive.documents
        links = archive.links
    }

    func endpoint(workspace: PDFWorkspaceState, note: StudyNoteItem? = nil,
                  pageIndex: Int? = nil) -> StudyLinkEndpoint? {
        guard let url = workspace.documentURL,
              let saved = document(matching: url) else { return nil }
        let index = note?.pageIndex ?? pageIndex ?? workspace.currentPageIndex
        guard index >= 0, index < workspace.pageCount else { return nil }
        if let note {
            guard let document = workspace.document, note.documentID == ObjectIdentifier(document),
                  note.annotation.page === document.page(at: index),
                  note.annotation.page?.annotations.contains(where: { $0 === note.annotation }) == true
            else { return nil }
        }
        return StudyLinkEndpoint(documentID: saved.id, pageIndex: index,
                                 note: note.map { StudyLinkNoteLocator(annotation: $0.annotation) })
    }

    func connections(to endpoint: StudyLinkEndpoint?) -> [StudyLink] {
        guard let endpoint else { return [] }
        return links.filter { $0.destination(from: endpoint) != nil }
    }

    func document(id: UUID) -> StudyLinkDocument? { documents.first { $0.id == id } }

    /// Called once when an already-authorized document is shown. Bookmark
    /// relocation is bounded and cached, never repeated during SwiftUI layout.
    func recognizeOpenedDocument(_ url: URL) {
        guard url.isFileURL, loadError == nil else { return }
        let path = Self.path(url)
        guard document(matching: url) == nil, checkedPaths.insert(path).inserted else { return }
        for (index, saved) in documents.enumerated() {
            guard let resolution = try? bookmarkCoder.resolveBookmark(saved.bookmark),
                  resolution.url.isFileURL, Self.path(resolution.url) == path else { continue }
            var updated = documents
            updated[index].path = path
            updated[index].displayName = url.lastPathComponent
            // The open workspace owns access to this URL. Failure to refresh a
            // stale bookmark preserves the original grant for a later retry.
            if let bookmark = try? bookmarkCoder.makeBookmark(for: url) { updated[index].bookmark = bookmark }
            try? save(documents: updated, links: links)
            return
        }
    }

    @discardableResult
    func add(from source: PDFWorkspaceState, sourceNote: StudyNoteItem? = nil,
             to target: PDFWorkspaceState, targetPage: Int, targetNote: StudyNoteItem? = nil,
             targetBookmarkTitle: String? = nil) throws -> StudyLink {
        guard loadError == nil else { throw StudyLinkError.corruptStorage }
        guard links.count < Self.maximumLinks else { throw StudyLinkError.storageLimit }
        guard let sourceURL = source.documentURL, let targetURL = target.documentURL,
              sourceURL.isFileURL, targetURL.isFileURL else { throw StudyLinkError.saveFirst }
        recognizeOpenedDocument(sourceURL)
        recognizeOpenedDocument(targetURL)
        guard source.pageCount > 0, targetPage >= 0, targetPage < target.pageCount else {
            throw StudyLinkError.invalidDestination
        }
        // Prepare both bookmarks before changing in-memory or persisted state.
        // A failure must not leave a half-created graph or replace old grants.
        var updated = documents
        let firstDocument = try prepareDocument(sourceURL, in: &updated)
        let secondDocument = try prepareDocument(targetURL, in: &updated)
        var first = try validatedEndpoint(workspace: source, note: sourceNote,
                                          pageIndex: sourceNote?.pageIndex ?? source.currentPageIndex,
                                          documentID: firstDocument.id)
        var second = try validatedEndpoint(workspace: target, note: targetNote,
                                           pageIndex: targetPage, documentID: secondDocument.id)
        guard !StudyLink.matches(first, second) else { throw StudyLinkError.invalidDestination }
        guard !links.contains(where: { link in
            link.destination(from: first).map { StudyLink.matches($0, second) } == true
        }) else { throw StudyLinkError.duplicate }
        // Stable note IDs are PDF metadata, unlike the app-local graph itself.
        // Check both permission boundaries before changing either document.
        let notes = [(source, sourceNote), (target, targetNote)].compactMap { workspace, note in
            note.map { (workspace, $0) }
        }
        guard notes.allSatisfy({ workspace, note in
            StudyLinkNoteIdentity.identifier(in: note.annotation) != nil || workspace.allows(.typedNotes)
        }) else { throw StudyLinkError.notePermission }
        guard notes.allSatisfy({ workspace, note in
            StudyLinkNoteIdentity.identifier(in: note.annotation) != nil
                || (workspace.pendingTextEdit == nil && workspace.pendingInlineTextEdit == nil)
        }) else { throw StudyLinkError.invalidDestination }
        for (workspace, note) in notes where StudyLinkNoteIdentity.identifier(in: note.annotation) == nil {
            guard workspace.ensureStudyLinkNoteIdentifier(note.annotation) else { throw StudyLinkError.notePermission }
        }
        first = try validatedEndpoint(workspace: source, note: sourceNote, pageIndex: first.pageIndex,
                                      documentID: first.documentID)
        second = try validatedEndpoint(workspace: target, note: targetNote, pageIndex: second.pageIndex,
                                       documentID: second.documentID)
        if let targetBookmarkTitle, targetNote == nil {
            let bounded = String(decoding: targetBookmarkTitle.utf16.prefix(1_024), as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            second.bookmarkTitle = bounded.isEmpty ? nil : bounded
        }
        let link = StudyLink(id: UUID(), first: first, second: second, createdAt: Date())
        try save(documents: updated, links: links + [link])
        return link
    }

    func remove(_ link: StudyLink) throws {
        let remaining = links.filter { $0.id != link.id }
        let retained = Set(remaining.flatMap { [$0.first.documentID, $0.second.documentID] })
        try save(documents: documents.filter { retained.contains($0.id) }, links: remaining)
    }

    /// Only called by a visible connection button. Resident tabs are reused;
    /// otherwise security-scoped resolution remains mandatory, even if the
    /// recorded path still happens to be readable outside a sandbox.
    @discardableResult
    func open(_ endpoint: StudyLinkEndpoint, in container: MultiDocumentWorkspaceState) async throws -> Bool {
        guard let saved = document(id: endpoint.documentID) else { throw StudyLinkError.invalidDestination }
        let existing = container.allTabs.first {
            $0.workspace.document != nil && $0.workspace.documentURL.map(Self.path) == saved.path
        }
        let destination: PDFWorkspaceState
        if let existing, let group = container.workspace(containingTab: existing.id),
           container.selectGalleryDocument(workspaceID: group.id, tabID: existing.id) {
            destination = existing.workspace
        } else {
            let resolved: (url: URL, isStale: Bool)
            do { resolved = try bookmarkCoder.resolveBookmark(saved.bookmark) }
            catch { throw StudyLinkError.unavailable }
            guard resolved.url.isFileURL else { throw StudyLinkError.unavailable }
            let access = SecurityScopedAccess(url: resolved.url)
            let ids = await container.openPDFsInTabsAsync(urls: [resolved.url])
            withExtendedLifetime(access) {}
            guard let id = ids.first, let session = container.allTabs.first(where: { $0.id == id }),
                  session.workspace.document != nil else { throw StudyLinkError.unavailable }
            destination = session.workspace
            recognizeOpenedDocument(resolved.url)
        }
        return try navigate(endpoint, in: destination)
    }

    /// URL must originate from NSOpenPanel. Successful PDF opening precedes
    /// replacement of the stale bookmark. Cancel/failure preserves the graph.
    @discardableResult
    func reconnect(_ endpoint: StudyLinkEndpoint, authorizedURL: URL,
                   in container: MultiDocumentWorkspaceState) async throws -> Bool {
        guard authorizedURL.isFileURL,
              documents.contains(where: { $0.id == endpoint.documentID }) else {
            throw StudyLinkError.invalidDestination
        }
        guard !documents.contains(where: {
            $0.id != endpoint.documentID && $0.path == Self.path(authorizedURL)
        }) else { throw StudyLinkError.invalidDestination }
        let access = SecurityScopedAccess(url: authorizedURL)
        defer { withExtendedLifetime(access) {} }
        let ids = await container.openPDFsInTabsAsync(urls: [authorizedURL])
        guard let id = ids.first, let session = container.allTabs.first(where: { $0.id == id }),
              session.workspace.document != nil else { throw StudyLinkError.unavailable }
        // Opening may yield while another popover deletes a link. Revalidate
        // the identity after the await rather than keeping an array index.
        guard let index = documents.firstIndex(where: { $0.id == endpoint.documentID }),
              !documents.contains(where: {
                  $0.id != endpoint.documentID && $0.path == Self.path(authorizedURL)
              }) else { throw StudyLinkError.invalidDestination }
        let bookmark = try bookmarkCoder.makeBookmark(for: authorizedURL)
        guard !bookmark.isEmpty, bookmark.count <= 1_024 * 1_024 else { throw StudyLinkError.unavailable }
        var updated = documents
        updated[index].bookmark = bookmark
        updated[index].path = Self.path(authorizedURL)
        updated[index].displayName = authorizedURL.lastPathComponent
        try save(documents: updated, links: links)
        return try navigate(endpoint, in: session.workspace)
    }

    private func navigate(_ endpoint: StudyLinkEndpoint, in workspace: PDFWorkspaceState) throws -> Bool {
        guard let document = workspace.document, let page = document.page(at: endpoint.pageIndex) else {
            throw StudyLinkError.invalidDestination
        }
        workspace.cancelSearch()
        workspace.activeSearchSelection = nil
        workspace.currentSelection = nil
        workspace.invalidatePDFViewportScrollPosition()
        workspace.currentPageIndex = endpoint.pageIndex
        workspace.selectedPages = [endpoint.pageIndex]
        if let locator = endpoint.note {
            guard let annotation = locator.resolve(on: page) else {
                workspace.statusMessage = L10n.string("study.links.note_missing", defaultValue: "연결된 메모를 찾지 못해 해당 페이지를 열었습니다.")
                return false
            }
            workspace.setMode(.study)
            workspace.studyNotesVisible = true
            return workspace.revealStudyNote(StudyNoteItem(documentID: ObjectIdentifier(document),
                pageIndex: endpoint.pageIndex, annotation: annotation, contents: annotation.contents ?? ""))
        }
        return true
    }

    private func validatedEndpoint(workspace: PDFWorkspaceState, note: StudyNoteItem?,
                                   pageIndex: Int, documentID: UUID) throws -> StudyLinkEndpoint {
        guard pageIndex >= 0, pageIndex < workspace.pageCount else { throw StudyLinkError.invalidDestination }
        if let note {
            guard let document = workspace.document, note.documentID == ObjectIdentifier(document),
                  note.pageIndex == pageIndex, let page = document.page(at: pageIndex),
                  page.annotations.contains(where: { $0 === note.annotation }),
                  note.annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
            else { throw StudyLinkError.invalidDestination }
        }
        let locator = note.map { StudyLinkNoteLocator(annotation: $0.annotation) }
        guard locator?.isValid != false else { throw StudyLinkError.invalidDestination }
        return StudyLinkEndpoint(documentID: documentID, pageIndex: pageIndex, note: locator)
    }

    private func prepareDocument(_ url: URL, in values: inout [StudyLinkDocument]) throws -> StudyLinkDocument {
        let path = Self.path(url)
        if let known = values.first(where: { $0.path == path }) { return known }
        guard values.count < Self.maximumDocuments else { throw StudyLinkError.storageLimit }
        let bookmark = try bookmarkCoder.makeBookmark(for: url)
        guard !bookmark.isEmpty, bookmark.count <= 1_024 * 1_024 else { throw StudyLinkError.unavailable }
        let document = StudyLinkDocument(id: UUID(), bookmark: bookmark, path: path,
                                         displayName: url.lastPathComponent)
        values.append(document)
        return document
    }

    private func document(matching url: URL) -> StudyLinkDocument? {
        let path = Self.path(url)
        return documents.first { $0.path == path }
    }

    private func save(documents: [StudyLinkDocument], links: [StudyLink]) throws {
        guard loadError == nil else { throw StudyLinkError.corruptStorage }
        let archive = Archive(documents: documents, links: links)
        guard Self.isValid(archive) else { throw StudyLinkError.invalidDestination }
        let data = try JSONEncoder().encode(archive)
        guard data.count <= Self.maximumStoredBytes else { throw StudyLinkError.storageLimit }
        persistence.data = data
        self.documents = documents
        self.links = links
    }

    private static func path(_ url: URL) -> String { url.standardizedFileURL.path }

    private static func isValid(_ archive: Archive) -> Bool {
        guard archive.version == 1, archive.links.count <= maximumLinks,
              archive.documents.count <= maximumDocuments,
              Set(archive.links.map(\.id)).count == archive.links.count,
              Set(archive.documents.map(\.id)).count == archive.documents.count,
              archive.documents.allSatisfy({ !$0.bookmark.isEmpty && $0.bookmark.count <= 1_024 * 1_024
                  && $0.path.hasPrefix("/") && $0.path.utf8.count <= 16_384 && $0.displayName.utf8.count <= 4_096 })
        else { return false }
        let ids = Set(archive.documents.map(\.id))
        return archive.links.allSatisfy { link in
            [link.first, link.second].allSatisfy { endpoint in
                ids.contains(endpoint.documentID) && endpoint.pageIndex >= 0 && endpoint.pageIndex < 1_000_000
                    && endpoint.note?.isValid != false
                    && endpoint.bookmarkTitle.map { $0.utf8.count <= 8_192 } != false
            } && !StudyLink.matches(link.first, link.second)
        }
    }
}
