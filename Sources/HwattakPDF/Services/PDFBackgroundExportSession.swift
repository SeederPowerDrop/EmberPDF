// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Takes ownership of a freshly detached export document. The UI must never
/// read that document again; only this serial worker uses it after transfer.
/// A Builder session may write a private OCR input before its final export.
final class PDFBackgroundExportSession: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.vibepdf.selected-export-writer", qos: .userInitiated)
    private static let admissionLock = NSLock()
    private static let maximumSessions = 2
    private static var admittedSessions = 0
    private var document: PDFDocument?
    private var hasAdmission = false
    private let expectedPageCount: Int
    private let cancellation: PDFSaveCancellation
    private let access: [SecurityScopedAccess]
    private let beforeWriting: @Sendable () throws -> Void

    @MainActor
    init(consuming document: PDFDocument, retainingAccess: [SecurityScopedAccess] = [],
         beforeWriting: @escaping @Sendable () throws -> Void = {}) throws {
        Self.admissionLock.lock()
        guard Self.admittedSessions < Self.maximumSessions else {
            Self.admissionLock.unlock()
            throw WorkspaceError.operationFailed(L10n.string("error.save_in_progress"))
        }
        Self.admittedSessions += 1
        Self.admissionLock.unlock()
        hasAdmission = true
        self.document = document
        expectedPageCount = document.pageCount
        access = retainingAccess
        cancellation = PDFSaveCancellation()
        self.beforeWriting = beforeWriting
    }

    deinit { document = nil; releaseAdmission() }

    static func validateAdmissionAvailable() throws {
        admissionLock.lock(); defer { admissionLock.unlock() }
        guard admittedSessions < maximumSessions else {
            throw WorkspaceError.operationFailed(L10n.string("error.save_in_progress"))
        }
    }

    #if DEBUG
    static var retainedSessionCount: Int {
        admissionLock.lock(); defer { admissionLock.unlock() }
        return admittedSessions
    }
    #endif

    private func releaseAdmission() {
        Self.admissionLock.lock(); defer { Self.admissionLock.unlock() }
        if hasAdmission { Self.admittedSessions -= 1; hasAdmission = false }
    }

    /// A queue barrier for callers which cancelled after the UI task detached.
    /// It waits for actual work/cleanup, rather than just clearing a busy flag.
    func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume() }
        }
    }

    func cancel() {
        cancellation.cancel()
        Self.queue.async {
            autoreleasepool { self.document = nil }
            self.releaseAdmission()
        }
    }

    func write(to destination: URL, protectedSourceURLs: [URL] = [],
               destinationPrecondition: PDFDestinationPrecondition? = nil,
               finishing: Bool = true,
               validateBeforeCommit: @escaping @Sendable () throws -> Void = {}) async throws -> URL {
        let precondition = try destinationPrecondition ?? PDFDestinationPrecondition(destination: destination)
        return try await perform(finishing: finishing) { document in
            try Self.validate(destination, sources: protectedSourceURLs, precondition: precondition)
            try validateBeforeCommit()
            let count = document.pageCount
            let result = try AtomicPDFWriter.write(document, to: destination,
                validateDestinationBeforeCommit: {
                    try Self.validate(destination, sources: protectedSourceURLs, precondition: precondition)
                    try validateBeforeCommit()
                }, destinationPrecondition: precondition)
            guard PDFDocument(url: result)?.pageCount == count else {
                throw WorkspaceError.operationFailed(L10n.string("error.validate_saved_pdf"))
            }
            return result
        }
    }

    func exportIndividually(to directory: URL, originalPageIndices: [Int],
                            sourceURL: URL?) async throws -> IndividualPagePDFExportResult {
        try await perform { document in
            try SelectedPagePDFExporter.exportPreparedIndividually(from: document,
                originalPageIndices: originalPageIndices, to: directory, sourceURL: sourceURL)
        }
    }

    func exportSearchable(checkpoint: OCRCheckpoint, to destination: URL,
                          renderDPI: CGFloat, protectedSourceURLs: [URL],
                          destinationPrecondition: PDFDestinationPrecondition,
                          validateBeforeCommit: @escaping @Sendable () throws -> Void = {}) async throws -> URL {
        try await perform { document in
            try Self.validate(destination, sources: protectedSourceURLs, precondition: destinationPrecondition)
            try validateBeforeCommit()
            let count = document.pageCount
            try SearchablePDFExporter.export(document: document, checkpoint: checkpoint,
                to: destination, renderDPI: renderDPI, beforeDestinationCommit: {
                    try Self.validate(destination, sources: protectedSourceURLs, precondition: destinationPrecondition)
                    try validateBeforeCommit()
                })
            guard PDFDocument(url: destination)?.pageCount == count else {
                throw WorkspaceError.operationFailed(L10n.string("error.validate_saved_pdf"))
            }
            return destination
        }
    }

    private static func validate(_ destination: URL, sources: [URL],
                                 precondition: PDFDestinationPrecondition) throws {
        try PDFSaveCancellation.checkCurrent()
        guard !sources.contains(where: { PDFSourceFileVersion.refersToSameLocation($0, destination) }) else {
            throw WorkspaceError.operationFailed(L10n.string("error.save_copy_same_as_original"))
        }
        try precondition.validate()
    }

    private func perform<T: Sendable>(finishing: Bool = true,
                                     _ body: @escaping @Sendable (PDFDocument) throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try cancellation.check()
            return try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    let outcome: Result<T, Error> = autoreleasepool {
                        do {
                            let result = try PDFSaveCancellation.withCurrent(self.cancellation) {
                                try self.cancellation.check()
                                try self.beforeWriting()
                                try self.cancellation.check()
                                guard let document = self.document else {
                                    throw WorkspaceError.operationFailed(L10n.string("error.validate_saved_pdf"))
                                }
                                guard document.pageCount == self.expectedPageCount, self.expectedPageCount > 0 else {
                                    throw WorkspaceError.operationFailed(L10n.string("error.validate_saved_pdf"))
                                }
                                let result = try body(document)
                                if finishing { self.document = nil }
                                return result
                            }
                            withExtendedLifetime(self.access) {}
                            return .success(result)
                        } catch {
                            self.document = nil
                            return .failure(error)
                        }
                    }
                    // Do not release an admission until temporary PDFKit
                    // objects have left the actual worker autorelease pool.
                    if self.document == nil { self.releaseAdmission() }
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: { self.cancel() }
    }
}
