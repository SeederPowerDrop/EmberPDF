// SPDX-License-Identifier: MPL-2.0

import Combine
import PDFKit

/// Keep partially typed page numbers separate from the committed destination.
/// In particular, replacing “1” with “120” must never snap back after “12”.
struct StudyLinkPageDraft {
    var text: String

    init(pageIndex: Int) { text = String(max(0, pageIndex) + 1) }

    func pageIndex(pageCount: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 10 else { return nil }
        var digits = ""
        for character in trimmed {
            guard let value = character.wholeNumberValue, value >= 0, value <= 9 else { return nil }
            digits += String(value)
        }
        guard let page = Int(digits), page > 0, page <= pageCount else { return nil }
        return page - 1
    }
}

struct StudyLinkBookmarkTarget: Identifiable {
    let id: String
    let title: String
    let pageIndex: Int
}

/// The selected PDF alone is materialized. A revision cache prevents page
/// input and filtering from rescanning a book, and each page yields to UI.
@MainActor
final class StudyLinkTargetCatalog: ObservableObject {
    static let maximumTargets = 10_000
    @Published private(set) var notes: [StudyNoteItem] = []
    @Published private(set) var bookmarks: [StudyLinkBookmarkTarget] = []
    @Published private(set) var pageCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isScanning = false
    @Published private(set) var isTruncated = false
    @Published private(set) var errorMessage: String?
    private weak var workspace: PDFWorkspaceState?
    private weak var document: PDFDocument?
    private var wasHibernated = false
    private var cachedRevision: UUID?
    private var generation = UUID()
    private(set) var scannedPageCount = 0

    func load(workspace selected: PDFWorkspaceState) async {
        let request = UUID()
        generation = request
        if workspace !== selected {
            clearSnapshots()
            workspace = selected
            wasHibernated = selected.isHibernated
        }
        errorMessage = nil
        isLoading = selected.document == nil
        if isLoading {
            await Task.yield()
            guard !Task.isCancelled, generation == request, workspace === selected else { return }
            guard selected.resumeIfNeeded(), selected.document != nil else {
                isLoading = false
                errorMessage = selected.presentedError
                    ?? L10n.string("study.links.target_load_failed", defaultValue: "이 PDF를 불러오지 못했습니다. 파일 접근 권한을 확인한 뒤 다시 시도하세요.")
                return
            }
        }
        guard !Task.isCancelled, generation == request, workspace === selected,
              let current = selected.document else { return }
        isLoading = false
        pageCount = current.pageCount
        if document === current, cachedRevision == selected.revision { return }
        notes = []; bookmarks = []; isTruncated = false
        document = current
        let revision = selected.revision
        isScanning = true
        defer { if generation == request { isScanning = false } }
        var collected: [StudyNoteItem] = []
        for index in 0..<current.pageCount {
            guard isCurrent(request, selected, current, revision) else { return }
            let pageNotes = selected.studyNotes(on: index)
            let capacity = max(0, Self.maximumTargets - collected.count)
            collected.append(contentsOf: pageNotes.prefix(capacity))
            scannedPageCount += 1
            if collected.count == Self.maximumTargets {
                isTruncated = index + 1 < current.pageCount || pageNotes.count > capacity
                notes = collected
                break
            }
            if index % 16 == 0 { notes = collected }
            do { try await Task.sleep(nanoseconds: 1_000_000) } catch { return }
        }
        guard isCurrent(request, selected, current, revision) else { return }
        notes = collected
        var outlines = current.outlineRoot.map { [($0, "root", 0)] } ?? []
        var visited: Set<ObjectIdentifier> = []
        var collectedBookmarks: [StudyLinkBookmarkTarget] = []
        while let (outline, path, depth) = outlines.popLast() {
            guard isCurrent(request, selected, current, revision) else { return }
            guard visited.insert(ObjectIdentifier(outline)).inserted else { continue }
            if visited.count > Self.maximumTargets { isTruncated = true; break }
            // Accept only an in-document destination. External/Launch/URI
            // actions are never executed or converted into file authority.
            let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
            if let page = destination?.page {
                let pageIndex = current.index(for: page)
                if pageIndex != NSNotFound {
                    let bounded = String(decoding: (outline.label ?? "").utf16.prefix(1_024), as: UTF16.self)
                    let title = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        collectedBookmarks.append(StudyLinkBookmarkTarget(id: path, title: title, pageIndex: pageIndex))
                    }
                }
            }
            let available = depth < 64 ? max(0, Self.maximumTargets - visited.count - outlines.count) : 0
            let childCount = min(max(0, outline.numberOfChildren), available)
            if outline.numberOfChildren > childCount { isTruncated = true }
            for index in (0..<childCount).reversed() {
                if let child = outline.child(at: index) { outlines.append((child, path + "." + String(index), depth + 1)) }
            }
            if visited.count % 32 == 0 {
                bookmarks = collectedBookmarks
                await Task.yield()
            }
        }
        guard isCurrent(request, selected, current, revision) else { return }
        bookmarks = collectedBookmarks
        cachedRevision = revision
    }

    /// Restore only the residency this picker borrowed. Dirty/pending drafts
    /// and the currently active tab are protected by the existing workspace
    /// hibernation policy, rather than a second memory policy in this feature.
    func releaseIfEligible(isActive: Bool) {
        generation = UUID()
        let selected = workspace
        let shouldRelease = wasHibernated && !isActive && selected?.document === document
        clearSnapshots()
        workspace = nil
        wasHibernated = false
        if shouldRelease { _ = selected?.hibernateIfPossible() }
    }

    private func isCurrent(_ request: UUID, _ selected: PDFWorkspaceState,
                           _ current: PDFDocument, _ revision: UUID) -> Bool {
        !Task.isCancelled && generation == request && workspace === selected
            && selected.document === current && selected.revision == revision
    }

    private func clearSnapshots() {
        notes = []; bookmarks = []; pageCount = 0; cachedRevision = nil
        document = nil; isLoading = false; isScanning = false; isTruncated = false
    }
}
