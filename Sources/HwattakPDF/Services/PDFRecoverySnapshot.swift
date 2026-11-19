// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// A one-use copy whose only consumer is a serial background writer. The live
/// PDFDocument never crosses the main-actor boundary. PDFKit's copy is cheap,
/// but delegates and internal GoTo destinations need explicit detachment.
final class PDFRecoverySnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var document: PDFDocument?
    private let sourceAccess: SecurityScopedAccess?

    @MainActor
    init(capturing source: PDFDocument, retainingAccess: SecurityScopedAccess? = nil) throws {
        sourceAccess = retainingAccess
        guard !source.isEncrypted, source.pageCount > 0 else { throw WorkspaceError.noDocument }
        try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: source)
        // Public point/zoom values omit Fit/FitH/etc. Capture those view modes
        // before rebinding local links to exclusively owned snapshot pages.
        try PDFCatalogStructurePreserver.rememberLiveAnnotationDestinations(in: source)
        // Register lightweight native/page/annotation and bookmark provenance
        // before copying. The deep tagged catalog plan belongs to the worker.
        // Plain native PDFs also need their original painting graph. PDFKit
        // serialization can redraw image commands and round fractional boxes
        // even when the document has no catalog features requiring repair.
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        // Capture current scalars before PDFDocument.copy(). PDFKit can copy
        // an independent checkbox annotation while dropping its live value.
        // These records stay on main and are released after this initializer.
        let capturedWidgets = try Self.currentWidgets(in: source)
        let widgets = capturedWidgets.widgets
        guard
              let copy = try PDFCatalogStructurePreserver.recoverySnapshotCopy(of: source, capturedWidgetCount: widgets.count), copy !== source,
              copy.pageCount == source.pageCount else { throw WorkspaceError.noDocument }
        guard widgets.allSatisfy({ $0.matchesSource() }) else { throw Self.invalidSnapshot() }
        copy.delegate = nil
        // Associated save markers are not part of PDFDocument.copy(). Carry
        // the existing O(1) form decision into the isolated recovery writer.
        if PDFCanonicalFormMaterializer.shouldMaterialize(source) {
            PDFCanonicalFormMaterializer.mark(copy)
        }
        var remainingRelationshipMetadata = 8 * 1_024 * 1_024
        let relationshipCopyWork = PDFAnnotationRelationshipBaseline.WorkBudget()
        let relationshipCopyCleanup = PDFAnnotationRelationshipPreserver.CopyBudget()
        for index in 0..<source.pageCount {
            guard let originalPage = source.page(at: index), let copiedPage = copy.page(at: index),
                  originalPage !== copiedPage else { throw Self.invalidSnapshot() }
            guard originalPage.rotation == copiedPage.rotation else { throw Self.invalidSnapshot() }
            for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                guard originalPage.bounds(for: box) == copiedPage.bounds(for: box) else {
                    throw Self.invalidSnapshot()
                }
            }
            try PDFAnnotationRelationshipPreserver.prepareOwnedCopy(from: originalPage, to: copiedPage, budget: relationshipCopyCleanup)
            let originals = originalPage.annotations, copies = copiedPage.annotations
            guard originals.count == copies.count else { throw Self.invalidSnapshot() }
            for (original, copied) in zip(originals, copies) {
                guard original !== copied else { throw Self.invalidSnapshot() }
                if let action = original.action as? PDFActionGoTo {
                    copied.action = try Self.detachedAction(action, source: source, copy: copy)
                } else if let destination = original.destination {
                    copied.destination = try Self.detachedDestination(destination, source: source, copy: copy)
                }
                PDFCatalogStructurePreserver.inheritAnnotationDestination(from: original, to: copied,
                    sourceDocument: source, copiedDocument: copy)
            }
            try PDFAnnotationRelationshipPreserver.inherit(from: originalPage, to: copiedPage,
                remainingMetadata: &remainingRelationshipMetadata, workBudget: relationshipCopyWork, copyBudget: relationshipCopyCleanup)
        }
        for widget in widgets {
            try widget.restore(in: copy, independentName: widget.name.map { capturedWidgets.nameCounts[$0] == 1 } ?? false)
        }
        guard widgets.allSatisfy({ $0.matchesSource() && $0.matchesCopy(in: copy) }) else { throw Self.invalidSnapshot() }
        if let originalOutline = source.outlineRoot {
            // PDFDocument.copy can omit an outline added since the source
            // was opened. Rebuild missing nodes from the live snapshot state.
            let copiedOutline = copy.outlineRoot ?? PDFOutline()
            var remaining = 100_000
            try Self.detachOutline(originalOutline, copied: copiedOutline,
                                   source: source, copy: copy, depth: 0, remaining: &remaining)
            copy.outlineRoot = copiedOutline
        }
        // Only this exact detached copy inherits an assembled catalog's source
        // graph. Transformed compression/OCR results must establish their own
        // provenance instead of borrowing an earlier page's painting.
        PDFCatalogStructurePreserver.forward(from: source, to: copy, force: true)
        document = copy
    }

    private struct CurrentWidget {
        let original: PDFAnnotation
        let page: Int
        let index: Int
        let name: String?
        let type: PDFAnnotationWidgetSubtype
        let value: String?
        let defaultValue: String?
        let rawDefault: String?
        let defaultAbsent: Bool
        let scalarDefault: Bool
        let rawValue: String?
        let valueAbsent: Bool
        let scalarValue: Bool
        let sourceAppearance: Bool
        let control: PDFWidgetControlType
        let state: PDFWidgetCellState
        let stateString: String
        let supportsRestore: Bool

        init(_ original: PDFAnnotation, page: Int, index: Int, remainingBytes: inout Int) throws {
            self.original = original; self.page = page; self.index = index
            name = original.fieldName
            try Self.account(name, maximum: 4_096, remainingBytes: &remainingBytes)
            type = original.widgetFieldType
            value = original.widgetStringValue
            try Self.account(value, remainingBytes: &remainingBytes)
            defaultValue = original.widgetDefaultStringValue
            try Self.account(defaultValue, remainingBytes: &remainingBytes)
            let raw = original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))
            rawDefault = raw as? String
            try Self.account(rawDefault, remainingBytes: &remainingBytes)
            defaultAbsent = raw == nil || raw is NSNull
            scalarDefault = rawDefault != nil || defaultAbsent
            let rawV = original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/V"))
            rawValue = rawV as? String
            try Self.account(rawValue, remainingBytes: &remainingBytes)
            valueAbsent = rawV == nil || rawV is NSNull
            scalarValue = rawValue != nil || valueAbsent
            sourceAppearance = original.hasAppearanceStream
            control = original.widgetControlType
            state = original.buttonWidgetState; stateString = original.buttonWidgetStateString
            try Self.account(stateString, remainingBytes: &remainingBytes)
            let flags = (original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Ff")) as? NSNumber)?.intValue ?? 0
            supportsRestore = name != nil && scalarValue
                && PDFCatalogStructurePreserver.permitsIndependentWidgetValueRestoration(original)
                && (type == .text || (type == .choice && flags & (1 << 21) == 0)
                || (type == .button && control == .checkBoxControl))
        }

        /// Bound before retaining another scalar or building name indexes.
        /// Prefix traversal also stops without allocating a second UTF8 Data
        /// buffer when a bridged PDFKit string is unexpectedly large.
        private static func account(_ value: String?, maximum: Int = 65_536,
                                    remainingBytes: inout Int) throws {
            guard let value else { return }
            let limit = min(maximum, remainingBytes)
            let count = value.utf8.prefix(limit + 1).count
            guard count <= limit else { throw PDFPageStructurePreserver.Failure.tooComplex }
            remainingBytes -= count
        }

        func matches(_ annotation: PDFAnnotation) -> Bool {
            let rawV = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/V"))
            let rawDV = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))
            return annotation.fieldName == name && annotation.widgetFieldType == type
                && annotation.widgetStringValue == value && annotation.widgetDefaultStringValue == defaultValue
                && (!scalarValue || ((rawV as? String) == rawValue && (rawV == nil || rawV is NSNull) == valueAbsent))
                && (!scalarDefault || ((rawDV as? String) == rawDefault && (rawDV == nil || rawDV is NSNull) == defaultAbsent))
                && (type != .button || (annotation.widgetControlType == control
                    && annotation.buttonWidgetState == state && annotation.buttonWidgetStateString == stateString))
        }

        func matchesSource() -> Bool { matches(original) && original.hasAppearanceStream == sourceAppearance }

        func matchesCopy(in document: PDFDocument) -> Bool {
            guard let page = document.page(at: page), page.annotations.indices.contains(index) else { return false }
            return matches(page.annotations[index])
        }

        func restore(in document: PDFDocument, independentName: Bool) throws {
            guard let page = document.page(at: page), page.annotations.indices.contains(index) else { throw PDFRecoverySnapshot.invalidSnapshot() }
            let copied = page.annotations[index]
            guard copied !== original, copied.type == "Widget", copied.fieldName == name,
                  copied.widgetFieldType == type else { throw PDFRecoverySnapshot.invalidSnapshot() }
            if matches(copied) { return }
            guard supportsRestore, independentName else { throw PDFRecoverySnapshot.invalidSnapshot() }
            let copiedRawV = copied.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/V"))
            let sameRawV = (copiedRawV as? String) == rawValue && (copiedRawV == nil || copiedRawV is NSNull) == valueAbsent
            let restoresValue = copied.widgetStringValue != value || !sameRawV
            if restoresValue { copied.widgetStringValue = value }
            if type == .button {
                if copied.widgetControlType != control { copied.widgetControlType = control }
                if restoresValue || copied.buttonWidgetStateString != stateString { copied.buttonWidgetStateString = stateString }
                if restoresValue || copied.buttonWidgetState != state { copied.buttonWidgetState = state }
            } else {
                let copiedRawDV = copied.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))
                let sameRawDV = (copiedRawDV as? String) == rawDefault && (copiedRawDV == nil || copiedRawDV is NSNull) == defaultAbsent
                if copied.widgetDefaultStringValue != defaultValue || (scalarDefault && !sameRawDV) {
                    guard scalarDefault else { throw PDFRecoverySnapshot.invalidSnapshot() }
                    if defaultAbsent { copied.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV")) }
                    else { copied.widgetDefaultStringValue = defaultValue }
                }
            }
            guard matches(copied) else { throw PDFRecoverySnapshot.invalidSnapshot() }
        }
    }

    @MainActor
    private static func currentWidgets(in document: PDFDocument) throws -> (widgets: [CurrentWidget], nameCounts: [String: Int]) {
        var widgets: [CurrentWidget] = []
        var nameCounts: [String: Int] = [:], remainingBytes = 8 * 1_024 * 1_024
        var remainingAnnotations = 100_000
        let relationshipWork = PDFAnnotationRelationshipBaseline.WorkBudget()
        try Task.checkCancellation()
        try PDFSaveCancellation.checkCurrent()
        for index in 0..<document.pageCount {
            if index & 255 == 0 {
                try Task.checkCancellation()
                try PDFSaveCancellation.checkCurrent()
            }
            guard let page = document.page(at: index) else { throw invalidSnapshot() }
            try PDFAnnotationRelationshipPreserver.validate(page, remainingAnnotations: &remainingAnnotations, workBudget: relationshipWork)
            for (offset, annotation) in page.annotations.enumerated() {
                if offset & 255 == 0 {
                    try Task.checkCancellation()
                    try PDFSaveCancellation.checkCurrent()
                }
                guard annotation.type == "Widget" else { continue }
                guard widgets.count < 10_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                let widget = try CurrentWidget(annotation, page: index, index: offset, remainingBytes: &remainingBytes)
                widgets.append(widget)
                if let name = widget.name { nameCounts[name, default: 0] += 1 }
            }
        }
        return (widgets, nameCounts)
    }

    /// Ownership transfer is protected so accidental second consumption fails
    /// rather than concurrently operating on one PDFKit graph.
    func takeDocument() throws -> PDFDocument {
        lock.lock()
        defer { lock.unlock() }
        guard let document else { throw Self.invalidSnapshot() }
        self.document = nil
        return document
    }

    /// The compression preview owns this detached copy for one background
    /// serialization; the live PDF and its custom annotations stay on main.
    func serializedData() throws -> Data {
        try Task.checkCancellation()
        let document = try takeDocument()
        try PDFAnnotationRelationshipPreserver.prepareForWriting(document)
        guard let data = document.dataRepresentation() else { throw Self.invalidSnapshot() }
        try Task.checkCancellation()
        let preserved: Data
        if PDFCatalogStructurePreserver.needsMaterialization(document) {
            preserved = try PDFBodyTextPageSnapshot.preservingCatalog(in: data, from: document,
                plan: PDFCatalogStructurePreserver.plan(for: document))
        } else if PDFBodyTextPageSnapshot.requiresPageContentPreservation(document) {
            preserved = try PDFBodyTextPageSnapshot.preservingPageContents(in: data, from: document)
        } else { preserved = data }
        // A Data boundary cannot carry an associated document marker. Encode
        // the canonical tree now, only for an already marked form snapshot.
        if PDFCanonicalFormMaterializer.shouldMaterialize(document) {
            return try PDFCanonicalFormMaterializer.materialize(preserved)
        }
        return preserved
    }

    private static func invalidSnapshot() -> WorkspaceError {
        .operationFailed(L10n.string("error.validate_saved_pdf"))
    }

    private static func detachedDestination(_ destination: PDFDestination,
                                            source: PDFDocument, copy: PDFDocument) throws -> PDFDestination {
        guard let sourcePage = destination.page else { throw invalidSnapshot() }
        let index = source.index(for: sourcePage)
        guard index != NSNotFound, let copiedPage = copy.page(at: index) else { throw invalidSnapshot() }
        let detached = PDFDestination(page: copiedPage, at: destination.point)
        detached.zoom = destination.zoom
        return detached
    }

    private static func detachedAction(_ action: PDFActionGoTo,
                                       source: PDFDocument, copy: PDFDocument) throws -> PDFActionGoTo {
        PDFActionGoTo(destination: try detachedDestination(action.destination, source: source, copy: copy))
    }

    private static func detachOutline(_ original: PDFOutline, copied: PDFOutline,
                                      source: PDFDocument, copy: PDFDocument,
                                      depth: Int, remaining: inout Int) throws {
        guard depth < 128, remaining > 0, original !== copied else { throw invalidSnapshot() }
        remaining -= 1
        PDFCatalogStructurePreserver.inheritOutlineStyle(from: original, to: copied)
        copied.label = original.label
        if PDFCatalogStructurePreserver.pendingInertOutlineCandidate(original) != nil {
            // Keep this group inactive. Its opaque source witness is inherited
            // below; only the isolated writer may restore the original value.
            copied.destination = nil
            copied.action = nil
        } else if let action = original.action as? PDFActionGoTo {
            copied.action = try detachedAction(action, source: source, copy: copy)
        } else if let action = original.action {
            copied.action = action.copy() as? PDFAction
        } else if let destination = original.destination {
            copied.destination = try detachedDestination(destination, source: source, copy: copy)
        } else {
            if PDFCatalogStructurePreserver.hasPendingInertOutlineRecord(original) { copied.destination = nil }
            copied.action = nil
        }
        // Bind hidden Fit/FitH/etc operands to the final detached destination,
        // rather than the temporary destination created by PDFDocument.copy.
        PDFCatalogStructurePreserver.inheritOutlineDestination(from: original, to: copied)
        if original.numberOfChildren != copied.numberOfChildren {
            while copied.numberOfChildren > 0 {
                guard let child = copied.child(at: 0) else { throw invalidSnapshot() }
                child.removeFromParent()
            }
            for _ in 0..<original.numberOfChildren {
                copied.insertChild(PDFOutline(), at: copied.numberOfChildren)
            }
        }
        for index in 0..<original.numberOfChildren {
            guard let oldChild = original.child(at: index), let newChild = copied.child(at: index)
            else { throw invalidSnapshot() }
            try detachOutline(oldChild, copied: newChild, source: source, copy: copy,
                              depth: depth + 1, remaining: &remaining)
        }
        copied.isOpen = original.isOpen
    }
}

enum PDFRecoveryBackgroundWriter {
    private static let queue = DispatchQueue(label: "com.vibepdf.recovery-writer", qos: .utility)

    static func stage(_ snapshot: PDFRecoverySnapshot, store: PDFRecoveryStore,
                      id: UUID, displayName: String) async throws -> PDFRecoveryStore.PreparedGeneration {
        let cancellation = PDFSaveCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    autoreleasepool {
                        do {
                            try cancellation.check()
                            let document = try snapshot.takeDocument()
                            defer { withExtendedLifetime(snapshot) {} }
                            let prepared = try PDFSaveCancellation.withCurrent(cancellation) {
                                try store.prepareGeneration(document: document, id: id, displayName: displayName)
                            }
                            do { try cancellation.check() }
                            catch { store.discard(prepared); throw error }
                            continuation.resume(returning: prepared)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}
