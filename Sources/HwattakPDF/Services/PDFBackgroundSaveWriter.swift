// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Explicit cancellation also works inside DispatchQueue/PDFKit callbacks,
/// where Swift's Task-local cancellation state is not available.
final class PDFSaveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private static let currentKey = "com.vibepdf.save-cancellation-context"

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }

    /// Confined to this synchronous worker call; never crosses an await.
    static func withCurrent<T>(_ cancellation: PDFSaveCancellation, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[currentKey]
        dictionary[currentKey] = cancellation
        defer {
            if let previous { dictionary[currentKey] = previous }
            else { dictionary.removeObject(forKey: currentKey) }
        }
        return try body()
    }

    static func checkCurrent() throws {
        try (Thread.current.threadDictionary[currentKey] as? PDFSaveCancellation)?.check()
    }
}

/// Immutable paths, permissions and request-time destination identity. No
/// background closure may consult the live workspace or its mutable PDF.
struct PDFBackgroundSaveRequest: @unchecked Sendable {
    let destinationURL: URL
    let originalURL: URL?
    let imageSourceURL: URL?
    let expectedSourceVersion: PDFSourceFileVersion?
    let overwritingOriginal: Bool
    let destinationPrecondition: PDFDestinationPrecondition
    private let retainedAccess: [SecurityScopedAccess]

    @MainActor
    init(destinationURL: URL, originalURL: URL?, imageSourceURL: URL? = nil,
         expectedSourceVersion: PDFSourceFileVersion? = nil, overwritingOriginal: Bool,
         retainingSourceAccess: SecurityScopedAccess? = nil) throws {
        self.destinationURL = destinationURL; self.originalURL = originalURL
        self.imageSourceURL = imageSourceURL; self.expectedSourceVersion = expectedSourceVersion
        self.overwritingOriginal = overwritingOriginal
        var access = [SecurityScopedAccess(url: destinationURL)]
        if let retainingSourceAccess { access.append(retainingSourceAccess) }
        else if let originalURL { access.append(SecurityScopedAccess(url: originalURL)) }
        if let imageSourceURL { access.append(SecurityScopedAccess(url: imageSourceURL)) }
        retainedAccess = access
        if overwritingOriginal {
            guard let originalURL, expectedSourceVersion != nil,
                  PDFSourceFileVersion.refersToSameLocation(originalURL, destinationURL) else {
                throw WorkspaceError.externalModification(destinationURL)
            }
        }
        try Self.validateCopyAliases(destination: destinationURL, original: originalURL,
                                    image: imageSourceURL, overwrite: overwritingOriginal)
        destinationPrecondition = try PDFDestinationPrecondition(destination: destinationURL)
    }

    func validateBeforeCommit() throws {
        try destinationPrecondition.validate()
        try Self.validateCopyAliases(destination: destinationURL, original: originalURL,
                                    image: imageSourceURL, overwrite: overwritingOriginal)
    }

    private static func validateCopyAliases(destination: URL, original: URL?, image: URL?, overwrite: Bool) throws {
        if let image, PDFSourceFileVersion.refersToSameLocation(image, destination) {
            throw WorkspaceError.operationFailed(L10n.string("error.save_copy_same_as_original"))
        }
        if !overwrite, let original, PDFSourceFileVersion.refersToSameLocation(original, destination) {
            throw WorkspaceError.operationFailed(L10n.string("error.save_copy_same_as_original"))
        }
    }
}

enum PDFBackgroundSaveWriter {
    // Foreground saves do not queue behind a cancelled recovery serialization.
    // Each queue owns separate detached graphs; foreground saves are serial.
    private static let queue = DispatchQueue(label: "com.vibepdf.explicit-save-writer", qos: .userInitiated)

    static func write(snapshot: PDFRecoverySnapshot, request: PDFBackgroundSaveRequest,
                      cancellation: PDFSaveCancellation) async throws -> PDFSourceFileAccess.SavedDocument {
        try await write(snapshot: snapshot, request: request, cancellation: cancellation, beforeWriting: {})
    }

    /// A worker-boundary seam for deterministic conflict/cancellation tests.
    /// The production overload never supplies a live-model callback.
    static func write(snapshot: PDFRecoverySnapshot, request: PDFBackgroundSaveRequest,
                      cancellation: PDFSaveCancellation,
                      beforeWriting: @escaping @Sendable () throws -> Void) async throws -> PDFSourceFileAccess.SavedDocument {
        try await withTaskCancellationHandler {
            try cancellation.check()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    autoreleasepool {
                        do {
                            let result = try PDFSaveCancellation.withCurrent(cancellation) {
                                try cancellation.check()
                                try beforeWriting()
                                try cancellation.check()
                                let document = try snapshot.takeDocument()
                                defer { withExtendedLifetime((snapshot, request)) {} }
                                try request.validateBeforeCommit()
                                if request.overwritingOriginal {
                                    guard let expected = request.expectedSourceVersion else {
                                        throw WorkspaceError.externalModification(request.destinationURL)
                                    }
                                    return try PDFSourceFileAccess.overwriteDocument(document,
                                        at: request.destinationURL, expectedVersion: expected,
                                        destinationPrecondition: request.destinationPrecondition,
                                        checkCancellation: cancellation.check)
                                }
                                let destination = try AtomicPDFWriter.write(document, to: request.destinationURL,
                                    validateDestinationBeforeCommit: request.validateBeforeCommit,
                                    allowDirectOverwriteFallback: false,
                                    destinationPrecondition: request.destinationPrecondition,
                                    checkCancellation: cancellation.check)
                                return PDFSourceFileAccess.SavedDocument(url: destination,
                                    version: try PDFSourceFileVersion.capture(at: destination))
                            }
                            // Once replacement succeeds, cancellation cannot
                            // turn committed bytes into a reported failed save.
                            continuation.resume(returning: result)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}
