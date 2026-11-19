// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

@MainActor
struct ImageInsertionRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let documentIdentity: ObjectIdentifier
    let documentRevision: UUID
    let pageIdentity: ObjectIdentifier
    let pageIndex: Int
    private let access: [SecurityScopedAccess]

    init(urls: [URL], documentIdentity: ObjectIdentifier, documentRevision: UUID,
         pageIdentity: ObjectIdentifier, pageIndex: Int) {
        self.urls = urls
        self.documentIdentity = documentIdentity
        self.documentRevision = documentRevision
        self.pageIdentity = pageIdentity
        self.pageIndex = pageIndex
        access = urls.map { SecurityScopedAccess(url: $0) }
    }
}

struct PDFCompressionRequest: Identifiable {
    let id: UUID
    let documentIdentity: ObjectIdentifier
    let documentRevision: UUID
    let sourceURL: URL?
    let documentData: Data
    let originalBytes: Int
    let pageCount: Int
}

@MainActor
extension PDFWorkspaceState {
    var canRequestPDFCompression: Bool {
        guard let document else { return false }
        return !document.isEncrypted && !document.isLocked && document.pageCount > 0
            && !isWritingOCRResult && !isPreparingPDFCompression
            && pendingImageInsertion == nil && pendingPDFCompression == nil
            && pendingProtectedExport == nil
    }

    func requestPDFCompression() {
        guard canRequestPDFCompression else { return }
        prepareForDeactivation()
        guard let document, pendingInlineTextEdit == nil, !hasPendingReviewTextDraft else { return }
        do {
            try PDFCompressionService.validateSource(document)
            let sourceURL = documentURL
            let snapshot = try PDFRecoverySnapshot(capturing: document,
                retainingAccess: sourceURL.map { SecurityScopedAccess(url: $0) })
            let identity = ObjectIdentifier(document), expectedRevision = revision
            let pageCount = document.pageCount, storedBytes = compressionStoredByteCount
            let token = UUID()
            compressionPreparationID = token
            setPreparingPDFCompression(true)
            compressionPreparationTask = Task { @MainActor [weak self] in
                defer {
                    if self?.compressionPreparationID == token {
                        self?.setPreparingPDFCompression(false)
                        self?.compressionPreparationTask = nil
                        self?.compressionPreparationID = nil
                    }
                }
                let worker = Task.detached(priority: .userInitiated) { try snapshot.serializedData() }
                do {
                    let data = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    guard let self, self.compressionPreparationID == token,
                          let current = self.document, ObjectIdentifier(current) == identity,
                          self.revision == expectedRevision,
                          self.documentURL == sourceURL else { return }
                    self.pendingPDFCompression = PDFCompressionRequest(id: token,
                        documentIdentity: identity, documentRevision: expectedRevision,
                        sourceURL: sourceURL, documentData: data,
                        originalBytes: min(data.count, storedBytes ?? data.count), pageCount: pageCount)
                } catch is CancellationError {
                    // Cancellation never changes the live document or a file.
                } catch {
                    if self?.compressionPreparationID == token { self?.presentedError = error.localizedDescription }
                }
            }
        } catch { presentedError = error.localizedDescription }
    }

    func cancelPDFCompression() {
        compressionPreparationTask?.cancel()
        compressionPreparationTask = nil
        compressionPreparationID = nil
        setPreparingPDFCompression(false)
        pendingPDFCompression = nil
    }

    /// Commit exactly the previewed bytes, to a separate destination. A normal
    /// PDFKit reserialization here could change the measured size again.
    @discardableResult
    func saveCompressedCopy(_ data: Data, request: PDFCompressionRequest, to destination: URL) -> Bool {
        prepareForDeactivation()
        guard pendingPDFCompression?.id == request.id,
              let document, ObjectIdentifier(document) == request.documentIdentity,
              revision == request.documentRevision, documentURL == request.sourceURL,
              data.count < request.originalBytes else {
            presentedError = L10n.string("compression.document_changed",
                defaultValue: "문서가 변경되었습니다. 다시 시도해 주세요.")
            return false
        }
        do {
            try PDFCompressionService.validateSource(document)
            let access = SecurityScopedAccess(url: destination)
            defer { withExtendedLifetime(access) {} }
            func validateDestination() throws {
                if let sourceURL = request.sourceURL,
                   PDFSourceFileVersion.refersToSameLocation(sourceURL, destination) {
                    throw WorkspaceError.operationFailed(L10n.string("error.save_copy_same_as_original"))
                }
            }
            try validateDestination()
            let precondition = try PDFDestinationPrecondition(destination: destination)
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".EmberPDF-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            guard let output = PDFDocument(data: data), !output.isEncrypted,
                  output.pageCount == request.pageCount else {
                throw WorkspaceError.operationFailed(L10n.string("error.validate_saved_pdf"))
            }
            try data.write(to: staged, options: .withoutOverwriting)
            guard let reopened = PDFDocument(url: staged), reopened.pageCount == request.pageCount else {
                throw WorkspaceError.operationFailed(L10n.string("error.validate_saved_pdf"))
            }
            try precondition.validate()
            try validateDestination()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else { try FileManager.default.moveItem(at: staged, to: destination) }
            cancelPDFCompression()
            presentedError = nil
            statusMessage = L10n.format("compression.saved", destination.lastPathComponent)
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }
}
