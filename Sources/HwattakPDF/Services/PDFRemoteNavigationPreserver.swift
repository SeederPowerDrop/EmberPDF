// SPDX-License-Identifier: MPL-2.0
import Foundation
import ObjectiveC
import PDFKit

/// PDFKit can write only /S for a GoToR action, losing its file and target,
/// or omit a native URI action whose original string Foundation cannot parse.
/// Local GoTo actions with extra native fields must fail before a detached
/// public-action copy can silently discard those unsupported fields.
/// Capture at fresh document load, before authoring can replace/mutate actions.
/// Native annotation dictionaries qualify pages; no text/image/layout is read.
enum PDFRemoteNavigationPreserver {
    private static let documentKey = NSObject(), annotationKey = NSObject(), pageKey = NSObject()
    private static var documentAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(documentKey).toOpaque()) }
    private static var annotationAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(annotationKey).toOpaque()) }
    private static var pageAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(pageKey).toOpaque()) }
    private struct State: Equatable {
        let url: String?
        let pageIndex: Int
        let point: CGPoint
        init(_ action: PDFActionRemoteGoTo) {
            // PDFKit can return nil despite the Objective-C nonnull declaration.
            // Call the documented URL getter without force-bridging nil to URL.
            let url = action.perform(#selector(getter: PDFActionRemoteGoTo.url))?.takeUnretainedValue() as? NSURL
            self.url = url?.absoluteString; pageIndex = action.pageIndex; point = action.point
        }
    }
    private final class Original {
        weak var action: PDFActionRemoteGoTo?
        let state: State
        let native: CGPDFDocument
        let value: CGPDFObjectRef
        init(action: PDFActionRemoteGoTo, native: CGPDFDocument, value: CGPDFObjectRef) {
            self.action = action; state = State(action); self.native = native; self.value = value
        }
        func matches(_ annotation: PDFAnnotation) -> Bool {
            guard let current = annotation.action as? PDFActionRemoteGoTo else { return false }
            return action === current && state == State(current)
        }
    }
    /// An opaque original URI is preserved as PDF data, never interpreted as a
    /// URL to open. PDFKit exposes either no action or an action with no URL.
    private final class OpaqueURI {
        weak var action: PDFActionURL?
        let wasNil: Bool
        let native: CGPDFDocument
        let value: CGPDFObjectRef
        init(annotation: PDFAnnotation, native: CGPDFDocument, value: CGPDFObjectRef) {
            action = annotation.action as? PDFActionURL; wasNil = annotation.action == nil
            self.native = native; self.value = value
        }
        func matches(_ annotation: PDFAnnotation) -> Bool {
            if wasNil { return annotation.action == nil }
            guard let current = annotation.action as? PDFActionURL else { return false }
            return action === current && PDFRemoteNavigationPreserver.isUnparsedURIAction(current)
        }
    }
    private enum Candidate {
        case remote(CGPDFObjectRef)
        case opaqueURI(CGPDFObjectRef)
    }
    /// An unsupported native action must not look safe merely because PDFKit
    /// could not parse it, or because its annotation moved to a new page.
    private final class Rejected {
        weak var action: PDFAction?
        let wasNil: Bool
        init(_ annotation: PDFAnnotation) { action = annotation.action; wasNil = annotation.action == nil }
        func isActive(on annotation: PDFAnnotation) -> Bool {
            if annotation.action is PDFActionRemoteGoTo { return true }
            if let current = annotation.action { return action === current }
            return wasNil
        }
    }
    private final class PageState {
        let unresolved: Bool
        init(unresolved: Bool) { self.unresolved = unresolved }
    }
    private final class Capture {
        // PDFKit may weakly cache page/annotation objects. Retain only the few
        // qualified pages, so their original identities survive a hidden tab.
        var pages: [PDFPage] = []
        var scanIncomplete = false
    }

    /// Only call at a trusted fresh-load boundary. Repeated calls never replace
    /// the immutable baseline after a user edits an action.
    static func captureOriginalActions(in document: PDFDocument) {
        guard objc_getAssociatedObject(document, documentAssociation) == nil,
              let native = document.documentRef, native.isUnlocked else { return }
        // Viewing must remain available even if a metadata scan exceeds the
        // bounded authoring budget. Never enumerate every PDFKit page here.
        let capture = Capture()
        objc_setAssociatedObject(document, documentAssociation, capture, .OBJC_ASSOCIATION_RETAIN)
        guard native.numberOfPages <= 250_000 else { capture.scanIncomplete = true; return }
        var visits = 0
        for pageIndex in 0..<native.numberOfPages {
            guard let dictionary = native.page(at: pageIndex + 1)?.dictionary,
                  let annotations = PDFCatalogStructurePreserver.array(dictionary, "Annots") else { continue }
            let count = CGPDFArrayGetCount(annotations)
            guard count <= 100_000 - visits else { capture.scanIncomplete = true; break }
            visits += count
            var candidates: [Int: Candidate] = [:]
            var qualifiedIndexes: Set<Int> = []
            var originalFingerprints: [PDFCatalogStructurePreserver.AnnotationFingerprint: [Int]] = [:]
            CGPDFArrayApplyBlock(annotations, { index, value, _ in
                var annotation: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &annotation), let annotation else { return true }
                if let fingerprint = try? PDFCatalogStructurePreserver.annotationFingerprint(annotation) {
                    originalFingerprints[fingerprint, default: []].append(index)
                }
                guard let action = PDFCatalogStructurePreserver.dictionary(annotation, "A") else { return true }
                if name(action, "S") == "GoToR" {
                    qualifiedIndexes.insert(index)
                    guard PDFCatalogStructurePreserver.object(action, "Next") == nil,
                          PDFCatalogStructurePreserver.object(action, "F") != nil,
                          PDFCatalogStructurePreserver.object(action, "D") != nil,
                          let value = PDFCatalogStructurePreserver.object(annotation, "A") else { return true }
                    candidates[index] = .remote(value)
                } else if name(action, "S") == "URI", hasUnparsedURI(action) {
                    // Qualify using native strings before requesting PDFKit
                    // pages. Ordinary valid URI links add no page retention.
                    qualifiedIndexes.insert(index)
                    guard PDFCatalogStructurePreserver.object(action, "Next") == nil,
                          let value = PDFCatalogStructurePreserver.object(annotation, "A") else { return true }
                    candidates[index] = .opaqueURI(value)
                } else if name(action, "S") == "GoTo", hasUnsupportedLocalActionFields(action) {
                    // The local-destination carrier preserves view operands,
                    // not action chains or extension fields. Record rejection
                    // only at this immutable load boundary; a later explicit
                    // action replacement/removal remains authoritative.
                    qualifiedIndexes.insert(index)
                }
                return true
            }, nil)
            guard !qualifiedIndexes.isEmpty else { continue }
            guard let page = document.page(at: pageIndex) else {
                capture.scanIncomplete = true
                continue
            }
            let live = page.annotations
            var currentFingerprints: [PDFCatalogStructurePreserver.AnnotationFingerprint: [Int]] = [:]
            for (index, annotation) in live.enumerated() {
                if let fingerprint = PDFCatalogStructurePreserver.annotationFingerprint(annotation) {
                    currentFingerprints[fingerprint, default: []].append(index)
                }
            }
            var covered: Set<Int> = []
            for (fingerprint, indexes) in currentFingerprints {
                guard let originalIndexes = originalFingerprints[fingerprint] else { continue }
                let qualified = originalIndexes.filter { qualifiedIndexes.contains($0) }
                guard !qualified.isEmpty else { continue }
                if indexes.count == 1, originalIndexes.count == 1,
                   let candidate = candidates[originalIndexes[0]],
                   install(candidate, on: live[indexes[0]], native: native) {
                    // Only a unique native/live match can retain raw actions.
                } else {
                    // A nonunique match can reject, but must never restore a
                    // payload onto an annotation whose identity is uncertain.
                    for index in indexes {
                        objc_setAssociatedObject(live[index], annotationAssociation, Rejected(live[index]), .OBJC_ASSOCIATION_RETAIN)
                    }
                }
                covered.formUnion(qualified)
            }
            objc_setAssociatedObject(page, pageAssociation,
                PageState(unresolved: !qualifiedIndexes.isSubset(of: covered)), .OBJC_ASSOCIATION_RETAIN)
            capture.pages.append(page)
        }
        objc_setAssociatedObject(document, documentAssociation, capture, .OBJC_ASSOCIATION_RETAIN)
    }

    static func hasOriginalActions(_ document: PDFDocument) -> Bool {
        guard let capture = objc_getAssociatedObject(document, documentAssociation) as? Capture else { return false }
        return !capture.pages.isEmpty || capture.scanIncomplete
    }

    /// A deliberate detached copy may replace the PDFKit action object. Only
    /// verified unmodified source provenance can cross that boundary.
    static func inherit(from original: PDFAnnotation, to copy: PDFAnnotation) {
        if let rejected = objc_getAssociatedObject(original, annotationAssociation) as? Rejected,
           rejected.isActive(on: original) {
            objc_setAssociatedObject(copy, annotationAssociation, Rejected(copy), .OBJC_ASSOCIATION_RETAIN)
            return
        }
        if let saved = objc_getAssociatedObject(original, annotationAssociation) as? OpaqueURI {
            if saved.matches(original), isUnparsedURIAction(copy.action) {
                objc_setAssociatedObject(copy, annotationAssociation,
                    OpaqueURI(annotation: copy, native: saved.native, value: saved.value), .OBJC_ASSOCIATION_RETAIN)
            }
            return
        }
        guard let saved = objc_getAssociatedObject(original, annotationAssociation) as? Original,
              let action = copy.action as? PDFActionRemoteGoTo else { return }
        guard saved.matches(original) else {
            // Keep the rejection evidence across a copy; never turn an edited
            // unsupported remote action into an apparently unmodified one.
            objc_setAssociatedObject(copy, annotationAssociation, saved, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        objc_setAssociatedObject(copy, annotationAssociation,
            Original(action: action, native: saved.native, value: saved.value), .OBJC_ASSOCIATION_RETAIN)
    }

    static func inheritPageState(from original: PDFPage, to copy: PDFPage) {
        objc_setAssociatedObject(copy, pageAssociation,
            objc_getAssociatedObject(original, pageAssociation), .OBJC_ASSOCIATION_RETAIN)
    }

    /// Called before an import transaction can mutate its destination. An
    /// incomplete scan cannot prove that the selected tail contains no links.
    static func validateForCopy(in document: PDFDocument, pages: [PDFPage]) throws {
        if let capture = objc_getAssociatedObject(document, documentAssociation) as? Capture, capture.scanIncomplete {
            throw PDFPageStructurePreserver.Failure.tooComplex
        }
        try pages.forEach(validate)
    }

    static func validate(_ page: PDFPage) throws {
        guard let state = objc_getAssociatedObject(page, pageAssociation) as? PageState else { return }
        guard !state.unresolved else { throw PDFPageStructurePreserver.Failure.unsupportedStructure }
        try page.annotations.forEach(validate)
    }

    private static func validate(_ annotation: PDFAnnotation) throws {
        if let rejected = objc_getAssociatedObject(annotation, annotationAssociation) as? Rejected,
           rejected.isActive(on: annotation) { throw PDFPageStructurePreserver.Failure.unsupportedStructure }
        if let saved = objc_getAssociatedObject(annotation, annotationAssociation) as? Original,
           annotation.action is PDFActionRemoteGoTo, !saved.matches(annotation) {
            throw PDFPageStructurePreserver.Failure.unsupportedStructure
        }
    }

    static func addAction(for annotation: PDFAnnotation, page: Int, index: Int, to plan: inout PDFCatalogGraphPlan) throws {
        try validate(annotation)
        if let saved = objc_getAssociatedObject(annotation, annotationAssociation) as? OpaqueURI {
            guard saved.matches(annotation) else { return }
            plan.annotationEntries[page, default: [:]][index, default: [:]]["A"] = .original(saved.value)
            plan.retainedDocuments.append(saved.native)
            return
        }
        guard let saved = objc_getAssociatedObject(annotation, annotationAssociation) as? Original else { return }
        guard saved.matches(annotation) else {
            if annotation.action is PDFActionRemoteGoTo { throw PDFPageStructurePreserver.Failure.unsupportedStructure }
            return
        }
        plan.annotationEntries[page, default: [:]][index, default: [:]]["A"] = .original(saved.value)
        plan.retainedDocuments.append(saved.native)
    }

    static func addActions(in document: PDFDocument, to plan: inout PDFCatalogGraphPlan) throws {
        guard let capture = objc_getAssociatedObject(document, documentAssociation) as? Capture else { return }
        guard !capture.scanIncomplete else { throw PDFPageStructurePreserver.Failure.tooComplex }
        for page in capture.pages {
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { continue }
            try validate(page)
            for (index, annotation) in page.annotations.enumerated() {
                try addAction(for: annotation, page: pageIndex, index: index, to: &plan)
            }
        }
    }
    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var pointer: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(dictionary, key, &pointer) ? pointer.map(String.init(cString:)) : nil
    }
    private static func hasUnparsedURI(_ action: CGPDFDictionaryRef) -> Bool {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(action, "URI", &value), let value,
              let decoded = CGPDFStringCopyTextString(value) else { return false }
        return URL(string: decoded as String) == nil
    }
    private static func hasUnsupportedLocalActionFields(_ action: CGPDFDictionaryRef) -> Bool {
        var unsupported = false
        CGPDFDictionaryApplyBlock(action, { key, _, _ in
            switch String(cString: key) {
            case "Type", "S", "D": return true
            default: unsupported = true; return false
            }
        }, nil)
        return unsupported
    }
    private static func isUnparsedURIAction(_ action: PDFAction?) -> Bool {
        guard let action else { return true }
        guard let action = action as? PDFActionURL else { return false }
        // Like RemoteGoTo.url, PDFActionURL.url can return nil despite its
        // Objective-C nonnull declaration. Never force-bridge that getter.
        return (action.perform(#selector(getter: PDFActionURL.url))?.takeUnretainedValue() as? NSURL) == nil
    }
    private static func install(_ candidate: Candidate, on annotation: PDFAnnotation,
                                native: CGPDFDocument) -> Bool {
        switch candidate {
        case .remote(let value):
            guard let action = annotation.action as? PDFActionRemoteGoTo else { return false }
            objc_setAssociatedObject(annotation, annotationAssociation,
                Original(action: action, native: native, value: value), .OBJC_ASSOCIATION_RETAIN)
        case .opaqueURI(let value):
            guard isUnparsedURIAction(annotation.action) else { return false }
            objc_setAssociatedObject(annotation, annotationAssociation,
                OpaqueURI(annotation: annotation, native: native, value: value), .OBJC_ASSOCIATION_RETAIN)
        }
        return true
    }
}
