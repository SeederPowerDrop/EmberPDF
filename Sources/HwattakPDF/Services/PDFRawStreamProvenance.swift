// SPDX-License-Identifier: MPL-2.0

import Foundation
import ObjectiveC
import PDFKit

/// Bind raw-stream lookup only at an input boundary whose bytes are known.
/// Equal image dictionaries alone never establish that their pixels match.
enum PDFRawStreamProvenance {
    private static let documentKey = NSObject(), pageKey = NSObject(), knownNativeKey = NSObject(), numberFactoryKey = NSObject(), bodyResultKey = NSObject()
    private static var numberFactoryAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(numberFactoryKey).toOpaque())
    }
    private static var documentAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(documentKey).toOpaque())
    }
    private static var pageAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(pageKey).toOpaque())
    }
    private static var knownNativeAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(knownNativeKey).toOpaque())
    }

    /// Keeps only the existing native owner alive. This is neither a retained
    /// byte buffer nor permission to extract, modify, or decrypt the document.
    private final class KnownNativeInput {
        let native: CGPDFDocument
        init(_ native: CGPDFDocument) { self.native = native }
    }

    private static var bodyResultAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(bodyResultKey).toOpaque())
    }

    /// Owns only a freshly parsed, bounded one-page result. The original input
    /// book and workspace never enter this holder. The holder owns no detached
    /// copy, so the last associated copy releases the factory document.
    final class BodyResultFactory {
        private let document: PDFDocument
        private let originalPage: PDFPage
        fileprivate init(document: PDFDocument, page: PDFPage) {
            self.document = document; originalPage = page
        }
        #if DEBUG
        /// Weak test observations expose no mutable document in Release and
        /// never extend any page, holder, or PDFDocument lifetime.
        final class LifetimeReferences {
            private(set) weak var factory: BodyResultFactory?
            private(set) weak var document: PDFDocument?
            private(set) weak var originalPage: PDFPage?
            fileprivate init(_ factory: BodyResultFactory, document: PDFDocument, page: PDFPage) {
                self.factory = factory; self.document = document; originalPage = page
            }
        }
        func debugLifetimeReferences() -> LifetimeReferences {
            LifetimeReferences(self, document: document, page: originalPage)
        }
        #endif
        fileprivate func canRetain(on detached: PDFPage) -> Bool {
            // Explicit copy inheritance can run on a staging worker. The
            // private factory document is immutable; do not query PDFKit here.
            detached !== originalPage
        }
        func copyPage() -> PDFPage? {
            guard document.pageCount == 1, document.page(at: 0) === originalPage,
                  let result = originalPage.copy() as? PDFPage, canRetain(on: result) else { return nil }
            PDFRawStreamProvenance.inherit(from: originalPage, to: result)
            objc_setAssociatedObject(result, PDFRawStreamProvenance.bodyResultAssociation, self, .OBJC_ASSOCIATION_RETAIN)
            return result
        }
    }

    /// The data boundary guarantees the retained document is a fresh result,
    /// not a caller-provided live source book. Check the body writer's 64 MiB
    /// bound before copying or parsing. Retention changes no resource authority.
    static func bodyResultFactory(data: Data) -> BodyResultFactory? {
        guard !data.isEmpty, data.count <= 64 * 1_024 * 1_024,
              let document = createdDocument(data: data), document.pageCount == 1,
              let page = document.page(at: 0) else { return nil }
        return BodyResultFactory(document: document, page: page)
    }

    /// Only constructors in this file can mint this authority. Existing
    /// bindCreated/bindOpened APIs alone cannot prove which bytes created a
    /// caller-supplied PDFDocument and deliberately retain strict comparison.
    final class OriginalNumberAuthority {
        private let native: CGPDFDocument
        private let openedURL: URL?
        private let openedVersion: PDFSourceFileVersion?
        fileprivate init(native: CGPDFDocument, url: URL? = nil, version: PDFSourceFileVersion? = nil) {
            self.native = native; openedURL = url?.standardizedFileURL.resolvingSymlinksInPath()
            openedVersion = version
        }
        func matches(_ owner: CGPDFDocument) -> Bool { native === owner }
        fileprivate func matchesOpened(_ owner: CGPDFDocument, url: URL, version: PDFSourceFileVersion) -> Bool {
            matches(owner) && openedURL == url.standardizedFileURL.resolvingSymlinksInPath() && openedVersion == version
        }
    }

    /// The existing coordinated loader supplies its BEFORE version and still
    /// checks AFTER. This creates no page/annotation scan or extra input read.
    static func documentForGuardedLoader(at url: URL, before: PDFSourceFileVersion) -> PDFDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        if !document.isLocked, !document.isEncrypted, let native = document.documentRef {
            objc_setAssociatedObject(document, numberFactoryAssociation,
                OriginalNumberAuthority(native: native, url: url, version: before), .OBJC_ASSOCIATION_RETAIN)
            PDFCatalogStructurePreserver.rememberFactoryOutlineStyles(in: document, native: native)
        }
        return document
    }

    /// A fresh exact-Data factory; it never stamps an already exposed document.
    /// Existing callers of bindCreated remain unchanged and strict.
    static func createdDocument(data: Data) -> PDFDocument? {
        // This optional factory owns a bounded byte copy before either parser
        // sees it; externally mutable/bytesNoCopy input cannot change its truth.
        guard !data.isEmpty, data.count <= 256 * 1_024 * 1_024 else { return nil }
        let owned = data.withUnsafeBytes { Data($0) }
        guard let document = PDFDocument(data: owned) else { return nil }
        let authority = (!document.isLocked && !document.isEncrypted)
            ? document.documentRef.map { OriginalNumberAuthority(native: $0) } : nil
        if let native = document.documentRef, authority != nil {
            PDFCatalogStructurePreserver.rememberFactoryOutlineStyles(in: document, native: native)
        }
        bindCreated(document, data: owned, numberAuthority: authority)
        return document
    }

    /// Called only after the coordinated open proved the source version stayed
    /// unchanged around PDFDocument(url:). Reading bytes remains lazy: opening
    /// many tabs must not allocate a second copy of every book at startup.
    static func bindOpened(_ document: PDFDocument, url: URL, version: PDFSourceFileVersion) {
        let pending = objc_getAssociatedObject(document, numberFactoryAssociation) as? OriginalNumberAuthority
        defer { objc_setAssociatedObject(document, numberFactoryAssociation, nil, .OBJC_ASSOCIATION_RETAIN) }
        // The coordinated loader already proved this exact input boundary.
        // Record it without reading source bytes when raw payload lookup is capped
        // by file size or the original native document is still locked.
        guard version.fileSize > 0,
              version.canonicalURL == url.standardizedFileURL.resolvingSymlinksInPath(),
              let native = document.documentRef else { return }
        objc_setAssociatedObject(document, knownNativeAssociation, KnownNativeInput(native), .OBJC_ASSOCIATION_RETAIN)
        PDFAnnotationRelationshipLifecycle.install(on: document)
        guard !document.isLocked, !document.isEncrypted,
              let source = PDFRawStreamSource.opened(native: native, url: url, version: version,
                numberAuthority: pending?.matchesOpened(native, url: url, version: version) == true ? pending : nil) else { return }
        objc_setAssociatedObject(document, documentAssociation, source, .OBJC_ASSOCIATION_RETAIN)
    }

    /// The caller must have just constructed this document from exactly data.
    /// This is not a way to attach an arbitrary file with similar dictionaries.
    static func bindCreated(_ document: PDFDocument, data: Data) {
        objc_setAssociatedObject(document, numberFactoryAssociation, nil, .OBJC_ASSOCIATION_RETAIN)
        bindCreated(document, data: data, numberAuthority: nil)
    }

    private static func bindCreated(_ document: PDFDocument, data: Data, numberAuthority: OriginalNumberAuthority?) {
        guard !data.isEmpty, let native = document.documentRef else { return }
        objc_setAssociatedObject(document, knownNativeAssociation, KnownNativeInput(native), .OBJC_ASSOCIATION_RETAIN)
        PDFAnnotationRelationshipLifecycle.install(on: document)
        guard !document.isLocked, !document.isEncrypted,
              let source = PDFRawStreamSource.created(native: native, data: data, numberAuthority: numberAuthority) else { return }
        objc_setAssociatedObject(document, documentAssociation, source, .OBJC_ASSOCIATION_RETAIN)
    }

    /// A lightweight input-origin witness, separate from encoded-stream and
    /// widget byte limits. Native identity must still match after unlocking;
    /// copies receive no witness here. Operation security policies remain
    /// authoritative even when an encrypted document is currently unlocked.
    static func hasKnownNativeInput(_ document: PDFDocument) -> Bool {
        guard !document.isLocked, let native = document.documentRef, native.isUnlocked,
              let known = objc_getAssociatedObject(document, knownNativeAssociation) as? KnownNativeInput else { return false }
        return known.native === native
    }

    static func source(for document: PDFDocument) -> PDFRawStreamSource? {
        objc_getAssociatedObject(document, documentAssociation) as? PDFRawStreamSource
    }

    static func source(for page: PDFPage) -> PDFRawStreamSource? {
        if let source = objc_getAssociatedObject(page, pageAssociation) as? PDFRawStreamSource { return source }
        guard let document = page.document, let source = source(for: document) else { return nil }
        // A detached page can outlive its original PDFDocument. This explicit
        // owner also keeps the native parser identities used by lookup alive.
        objc_setAssociatedObject(page, pageAssociation, source, .OBJC_ASSOCIATION_RETAIN)
        return source
    }

    /// A copy with a new parser graph is not proven to retain encoded bytes.
    /// Fall back for that painting instead of binding it by equal dimensions
    /// or dictionaries: PDFKit may have normalized the stream itself.
    static func inherit(from original: PDFPage, to copy: PDFPage) {
        guard let originalDictionary = original.pageRef?.dictionary,
              let copiedDictionary = copy.pageRef?.dictionary,
              originalDictionary == copiedDictionary,
              let source = source(for: original) else { return }
        objc_setAssociatedObject(copy, pageAssociation, source, .OBJC_ASSOCIATION_RETAIN)
        // Transfer an existing bounded result owner only along the same native
        // page graph. Never attach it to the factory's own page: that would
        // create factory -> document -> page -> factory retention.
        if let factory = objc_getAssociatedObject(original, bodyResultAssociation) as? BodyResultFactory,
           factory.canRetain(on: copy) {
            objc_setAssociatedObject(copy, bodyResultAssociation, factory, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}
