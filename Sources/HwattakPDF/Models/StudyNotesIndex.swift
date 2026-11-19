// SPDX-License-Identifier: MPL-2.0

import Combine
import PDFKit

/// Page-local snapshots keep a note edit from reopening every page of a book.
/// All PDFKit access stays on the main actor, with a yield between pages.
@MainActor
final class StudyNotesIndex: ObservableObject {
    @Published private(set) var notes: [StudyNoteItem] = []
    @Published private(set) var isScanning = false
    /// Bulk actions require the entire current document snapshot, including
    /// the interval between invalidation and the next sidebar refresh task.
    @Published private(set) var isComplete = false
    private weak var document: PDFDocument?
    private var pages: [Int: [StudyNoteItem]] = [:]
    private var dirtyPages: Set<Int> = []
    private var pageCount = 0
    private var refreshGeneration = UUID()
    private(set) var scannedPageCount = 0

    func reset() {
        refreshGeneration = UUID()
        document = nil
        pages = [:]
        dirtyPages = []
        pageCount = 0
        scannedPageCount = 0
        notes = []
        isScanning = false
        isComplete = false
    }

    func invalidate(pageIndexes: Set<Int>?) {
        guard let document else { return }
        if let pageIndexes, document.pageCount == pageCount {
            dirtyPages.formUnion(pageIndexes.filter { $0 >= 0 && $0 < pageCount })
        } else {
            pageCount = document.pageCount
            pages = pages.filter { $0.key < pageCount }
            dirtyPages = Set(0..<pageCount)
        }
        if !dirtyPages.isEmpty { isComplete = false }
    }

    func refresh(workspace: PDFWorkspaceState) async {
        guard !Task.isCancelled else { return }
        guard let current = workspace.document else { reset(); return }
        if document !== current {
            reset()
            document = current
            pageCount = current.pageCount
            dirtyPages = Set(0..<pageCount)
        }
        let generation = UUID()
        refreshGeneration = generation
        guard !dirtyPages.isEmpty else {
            if !isComplete { publish() }
            isScanning = false
            isComplete = true
            return
        }
        isComplete = false
        isScanning = true
        defer {
            // A canceled sidebar task can finish after its replacement starts.
            // It must never mark that replacement's partial index as complete.
            if refreshGeneration == generation, document === current {
                if dirtyPages.isEmpty { publish() }
                isComplete = dirtyPages.isEmpty
                isScanning = false
            }
        }
        var completed = 0
        // Prioritize the page the person is reading without changing the list order.
        let order = dirtyPages.sorted { a, b in
            if a == workspace.currentPageIndex { return true }
            if b == workspace.currentPageIndex { return false }
            return a < b
        }
        for index in order {
            guard !Task.isCancelled, refreshGeneration == generation,
                  workspace.document === current, document === current else { return }
            pages[index] = workspace.studyNotes(on: index)
            dirtyPages.remove(index)
            scannedPageCount += 1
            completed += 1
            if completed == 1 || completed % 16 == 0 { publish() }
            do { try await Task.sleep(nanoseconds: 1_000_000) } catch { return }
        }
    }

    private func publish() {
        notes = pages.keys.sorted().flatMap { pages[$0] ?? [] }
    }
}
