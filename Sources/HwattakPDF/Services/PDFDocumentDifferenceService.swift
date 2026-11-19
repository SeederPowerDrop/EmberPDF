// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation
import PDFKit

/// Reading PDFKit stays on its owning actor. Only copied strings enter the
/// worker, and every completion/navigation revalidates both source revisions.
@MainActor
final class PDFDocumentDifferenceService: ObservableObject {
    enum Phase: Equatable { case idle, capturing, comparing, completed, cancelled, invalidated, failed(PDFDocumentDifferenceFailure) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var capturedPages = 0
    @Published private(set) var totalPages = 0
    @Published private(set) var report: PDFDocumentDifferenceReport?
    @Published private(set) var beforeID: UUID?
    @Published private(set) var afterID: UUID?

    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var beforeSource: Source?
    private var afterSource: Source?
    let limits: PDFDocumentDifferenceLimits
    /// Test seam at the immutable boundary, also exercises stale completion.
    private let compare: @Sendable (PDFDocumentDifferenceSnapshot, PDFDocumentDifferenceSnapshot, PDFDocumentDifferenceLimits) async throws -> PDFDocumentDifferenceReport

    private struct Source {
        let id: UUID
        weak var workspace: PDFWorkspaceState?
        let revision: UUID
        let identity: ObjectIdentifier

        @MainActor var isCurrent: Bool {
            guard let workspace, let document = workspace.document else { return false }
            return workspace.comparisonRevision == revision && ObjectIdentifier(document) == identity
        }
    }

    init(limits: PDFDocumentDifferenceLimits = .init(),
         compare: @escaping @Sendable (PDFDocumentDifferenceSnapshot, PDFDocumentDifferenceSnapshot, PDFDocumentDifferenceLimits) async throws -> PDFDocumentDifferenceReport = { before, after, limits in
             let worker = Task.detached(priority: .userInitiated) {
                 try PDFDocumentDifferenceEngine.compare(before, after, limits: limits)
             }
             return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
         }) {
        self.limits = limits
        self.compare = compare
    }

    deinit { task?.cancel() }

    var isRunning: Bool { phase == .capturing || phase == .comparing }

    func start(before: ComparisonDocument, after: ComparisonDocument) {
        cancel()
        beforeID = before.id; afterID = after.id
        report = nil
        beforeSource = nil; afterSource = nil
        capturedPages = 0; totalPages = 0
        guard before.id != after.id else { phase = .failed(.unavailable); return }
        do {
            beforeSource = try source(before)
            afterSource = try source(after)
            guard let beforeSource, let afterSource else { throw PDFDocumentDifferenceFailure.unavailable }
            totalPages = before.pageCount + after.pageCount
            let request = UUID()
            requestID = request
            phase = .capturing
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    var remaining = self.limits.maximumTotalUTF16Count
                    let started = ProcessInfo.processInfo.systemUptime
                    let old = try await self.capture(beforeSource, remaining: &remaining, started: started)
                    let new = try await self.capture(afterSource, remaining: &remaining, started: started)
                    try self.requireCurrent(request)
                    self.phase = .comparing
                    let result = try await self.compare(old, new, self.limits)
                    try self.requireCurrent(request)
                    self.report = result
                    self.phase = .completed
                } catch is CancellationError {
                    if self.requestID == request { self.phase = .cancelled }
                } catch let error as PDFDocumentDifferenceFailure {
                    if self.requestID == request { self.phase = error == .changed ? .invalidated : .failed(error) }
                } catch {
                    if self.requestID == request { self.phase = .failed(.unavailable) }
                }
                if self.requestID == request { self.task = nil }
            }
        } catch let failure as PDFDocumentDifferenceFailure {
            phase = .failed(failure)
        } catch {
            phase = .failed(.unavailable)
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        requestID = nil
        if isRunning { phase = .cancelled }
    }

    func reset() {
        cancel()
        report = nil; phase = .idle
        beforeSource = nil; afterSource = nil
        beforeID = nil; afterID = nil
        capturedPages = 0; totalPages = 0
    }

    /// Membership changes and PDF edits hide stale rows immediately. Language
    /// changes intentionally do not restart the language-independent worker.
    func invalidateIfNeeded(availableIDs: Set<UUID>) {
        guard let beforeSource, let afterSource else { return }
        guard availableIDs.contains(beforeSource.id), availableIDs.contains(afterSource.id),
              beforeSource.isCurrent, afterSource.isCurrent else {
            cancel(); report = nil; phase = .invalidated
            return
        }
    }

    func locations(for change: PDFDocumentDifferenceChange, lockedIDs: Set<UUID>) -> [UUID: PDFDocumentDifferenceLocation] {
        guard phase == .completed, let report, report.changes.contains(change),
              let beforeSource, let afterSource, beforeSource.isCurrent, afterSource.isCurrent else {
            if phase == .completed { cancel(); self.report = nil; phase = .invalidated }
            return [:]
        }
        var result: [UUID: PDFDocumentDifferenceLocation] = [:]
        if !lockedIDs.contains(beforeSource.id), let location = change.before { result[beforeSource.id] = location }
        if !lockedIDs.contains(afterSource.id), let location = change.after { result[afterSource.id] = location }
        return result
    }

    func waitForCompletion() async { await task?.value }

    private func source(_ document: ComparisonDocument) throws -> Source {
        guard let pdf = document.workspace.document, !pdf.isLocked, pdf.pageCount > 0 else {
            throw PDFDocumentDifferenceFailure.unavailable
        }
        guard pdf.allowsCopying || pdf.permissionsStatus == .owner else { throw PDFDocumentDifferenceFailure.restricted }
        guard pdf.pageCount <= limits.maximumPagesPerDocument else { throw PDFDocumentDifferenceFailure.tooLarge }
        return Source(id: document.id, workspace: document.workspace, revision: document.workspace.comparisonRevision,
                      identity: ObjectIdentifier(pdf))
    }

    private func capture(_ source: Source, remaining: inout Int, started: TimeInterval) async throws -> PDFDocumentDifferenceSnapshot {
        guard let workspace = source.workspace, let document = workspace.document else { throw PDFDocumentDifferenceFailure.unavailable }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard source.isCurrent else { throw PDFDocumentDifferenceFailure.changed }
            guard ProcessInfo.processInfo.systemUptime - started <= limits.maximumDuration else { throw PDFDocumentDifferenceFailure.timedOut }
            // PDFKit's synchronous extraction cannot be interrupted mid-page.
            // Yielding before each page prevents a whole-document main-queue loop.
            await Task.yield()
            try Task.checkCancellation()
            guard source.isCurrent, let page = document.page(at: index) else { throw PDFDocumentDifferenceFailure.changed }
            let text = autoreleasepool { page.string ?? "" }
            let count = text.utf16.count
            guard count <= limits.maximumPageUTF16Count, count <= remaining else { throw PDFDocumentDifferenceFailure.tooLarge }
            remaining -= count
            pages.append(text)
            capturedPages += 1
        }
        return .init(pages: pages)
    }

    private func requireCurrent(_ request: UUID) throws {
        try Task.checkCancellation()
        guard requestID == request else { throw CancellationError() }
        guard beforeSource?.isCurrent == true, afterSource?.isCurrent == true else { throw PDFDocumentDifferenceFailure.changed }
    }
}
