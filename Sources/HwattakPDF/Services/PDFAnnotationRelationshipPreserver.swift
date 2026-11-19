// SPDX-License-Identifier: MPL-2.0

import Foundation
import ObjectiveC
import PDFKit

/// Current same-page Text/Popup links. Optional raw Parent presence is separate
/// from PDFKit's synthesized getter. Widget.Parent is never changed here.
enum PDFAnnotationRelationshipPreserver {
    private typealias Fingerprint = PDFAnnotationRelationshipBaseline.Fingerprint
    private typealias Parent = PDFAnnotationRelationshipBaseline.Parent
    private static let associationKey = NSObject()
    private static var association: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(associationKey).toOpaque()) }
    private static let maximumAnnotations = 100_000
    /// A separate operation-wide bound for temporary SDK-copy cleanup records.
    /// Final inherited records have their existing independent 8 MiB budget.
    final class CopyBudget {
        private(set) var remaining = 8 * 1_024 * 1_024
        func consume(_ bytes: Int) throws {
            try PDFSaveCancellation.checkCurrent()
            guard bytes >= 0, bytes <= remaining else { throw PDFPageStructurePreserver.Failure.tooComplex }; remaining -= bytes
        }
    }
    final class MoveCapture {
        private let completion: (PDFPage) throws -> Void
        private let restoration: (PDFPage) throws -> Void
        init(completion: @escaping (PDFPage) throws -> Void, restoration: @escaping (PDFPage) throws -> Void) {
            self.completion = completion; self.restoration = restoration
        }
        func complete(on page: PDFPage) throws { try completion(page) }
        /// Invoke after the caller restores the original page and saved objects.
        /// Captured relations/scalars are restored before strict validation.
        func restore(on page: PDFPage) throws { try restoration(page) }
    }

    private final class Observation {
        weak var note: PDFAnnotation?
        weak var expectedPopup: PDFAnnotation?
        weak var observedPopup: PDFAnnotation?
        weak var observedParent: PDFAnnotation?
        let popupAbsent: Bool, parentAbsent: Bool, sourceNote: Fingerprint, sourcePopup: Fingerprint?
        let sourceSynthetic: PDFAnnotationRelationshipLifecycle.SyntheticState?
        let legacyNoPopup: Bool
        let legacyPopupIsNull: Bool
        init(note: PDFAnnotation, expectedPopup: PDFAnnotation?, sourceNote: Fingerprint,
             sourcePopup: Fingerprint?, legacyNoPopup: Bool = false, legacyPopupIsNull: Bool = false,
             sourceSynthetic: PDFAnnotationRelationshipLifecycle.SyntheticState? = nil) throws {
            self.note = note; self.expectedPopup = expectedPopup; self.sourceNote = sourceNote
            self.sourcePopup = sourcePopup; self.legacyNoPopup = legacyNoPopup
            self.legacyPopupIsNull = legacyNoPopup && legacyPopupIsNull
            self.sourceSynthetic = sourceSynthetic
            observedPopup = note.popup; popupAbsent = observedPopup == nil
            let parent = try expectedPopup.map { try PDFAnnotationRelationshipPreserver.parent(of: $0) } ?? nil
            observedParent = parent; parentAbsent = parent == nil
        }
        func matches(_ note: PDFAnnotation) throws -> Bool {
            guard self.note === note else { return false }
            let current = note.popup
            guard popupAbsent ? current == nil : observedPopup != nil && current === observedPopup else { return false }
            if let sourceSynthetic {
                guard let current,
                      PDFAnnotationRelationshipLifecycle.SyntheticState.identity(of: current) == sourceSynthetic.identity,
                      PDFAnnotationRelationshipLifecycle.SyntheticState(current) == sourceSynthetic else { return false }
            }
            let parent = try expectedPopup.map { try PDFAnnotationRelationshipPreserver.parent(of: $0) } ?? nil
            return parentAbsent ? parent == nil : observedParent != nil && parent === observedParent
        }
    }
    private final class PageObservations {
        var values: [Observation]
        init(_ values: [Observation]) { self.values = values }
    }
    private struct Pair { let note: Int; let popup: Int; var parent: Parent }
    private struct PairFingerprint: Hashable { let note: Fingerprint; let popup: Fingerprint }
    private struct PageResult { var pairs: [Pair] = []; var drops = Set<Int>(); var nulls = Set<Int>(); var deferred = Set<Int>() }

    private struct SyntheticProof {
        let note: Fingerprint
        let popup: PDFAnnotationRelationshipLifecycle.SyntheticState
    }
    private static func syntheticProof(for note: PDFAnnotation, on page: PDFPage,
                                       records: [ObjectIdentifier: Observation]) throws -> SyntheticProof? {
        if let record = records[ObjectIdentifier(note)], let value = record.sourceSynthetic {
            guard try record.matches(note) else { return nil }
            return SyntheticProof(note: record.sourceNote, popup: value)
        }
        guard let initial = PDFAnnotationRelationshipLifecycle.observation(for: note, on: page), initial.matches(note) else { return nil }
        return SyntheticProof(note: initial.noteState, popup: initial.popupState)
    }

    private static func parent(of annotation: PDFAnnotation) throws -> PDFAnnotation? {
        let value = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent"))
        guard let value, !(value is NSNull) else { return nil }
        guard let annotation = value as? PDFAnnotation else { throw invalid() }; return annotation
    }
    private static func stored(on page: PDFPage) -> [ObjectIdentifier: Observation] {
        var result: [ObjectIdentifier: Observation] = [:]
        for value in (objc_getAssociatedObject(page, association) as? PageObservations)?.values ?? [] {
            if let note = value.note { result[ObjectIdentifier(note)] = value }
        }
        return result
    }
    private static func nativeEntries(on page: PDFPage, budget: PDFAnnotationRelationshipBaseline.WorkBudget?) throws -> (PDFAnnotationRelationshipBaseline.Source?, [PDFAnnotationRelationshipBaseline.Entry]) {
        guard let source = PDFCatalogStructurePreserver.relationshipSource(for: page) else { return (nil, []) }
        do { return (source, try PDFAnnotationRelationshipBaseline.entries(in: source, budget: budget)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if let failure = error as? PDFPageStructurePreserver.Failure, case .tooComplex = failure { throw failure }
            // An unbound SDK-created pageRef can contain the hidden clones
            // being repaired. It is not an original-input proof.
            if !source.knownInput { return (nil, []) }
            throw error
        }
    }
    private static func inspect(_ page: PDFPage, remaining: inout Int, writing: Bool,
                                workBudget: PDFAnnotationRelationshipBaseline.WorkBudget? = nil) throws -> PageResult {
        try PDFSaveCancellation.checkCurrent()
        let annotations = page.annotations
        guard annotations.count <= remaining else { throw PDFPageStructurePreserver.Failure.tooComplex }
        remaining -= annotations.count
        var hasText = false, hasPopup = false
        for (index, annotation) in annotations.enumerated() {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            hasText = hasText || annotation.type == "Text"; hasPopup = hasPopup || annotation.type == "Popup"
        }
        guard hasText || hasPopup else { return PageResult() }
        var indexes: [ObjectIdentifier: Int] = [:]
        for (index, annotation) in annotations.enumerated() {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard indexes.updateValue(index, forKey: ObjectIdentifier(annotation)) == nil else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        }
        let records = stored(on: page)
        let (nativeSource, entries) = try hasText ? nativeEntries(on: page, budget: workBudget) : (nil, [])
        let noPopup = entries.filter { $0.popup == nil }
        let optionalParents = entries.filter { $0.popup != nil && $0.parent != .linked }
        var result = PageResult(), claimed = Set<Int>(), changed = Set<Int>()
        for (index, note) in annotations.enumerated() where note.type == "Text" {
            try PDFSaveCancellation.checkCurrent()
            let record = records[ObjectIdentifier(note)]
            let matches = try record?.matches(note) ?? false
            if let record, record.legacyNoPopup, record.sourceSynthetic == nil, matches {
                guard note.popup.map({ indexes[ObjectIdentifier($0)] == nil }) ?? true else { throw invalid() }
                // This exact manual-cleanup record proves original native
                // absence versus explicit null. Do not serialize the SDK's
                // unlisted getter Popup as a new relationship.
                if writing {
                    result.drops.insert(index)
                    if record.legacyPopupIsNull { result.nulls.insert(index) }
                }
                continue
            }
            guard let current = note.popup else {
                let raw = note.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup"))
                guard raw == nil || raw is NSNull else { throw invalid() }
                result.drops.insert(index); continue
            }
            let popupIndex: Int, currentParent: PDFAnnotation?
            if let direct = indexes[ObjectIdentifier(current)] {
                guard current.type == "Popup" else { throw invalid() }
                popupIndex = direct
                currentParent = try parent(of: current)
                if !(matches && record?.expectedPopup === current) {
                    guard currentParent == nil || currentParent === note else { throw invalid() }
                }
            } else if let record, matches, let expected = record.expectedPopup,
                      let inherited = indexes[ObjectIdentifier(expected)], expected.type == "Popup" {
                popupIndex = inherited; currentParent = try parent(of: expected)
            } else {
                // A getter synthesizes an unlisted popup for a raw Text with
                // no Popup key. Capture defers; durable writing proves it.
                if let record, record.sourcePopup == nil, !matches { throw invalid() }
                if record?.sourceSynthetic == nil,
                   let initial = PDFAnnotationRelationshipLifecycle.observation(for: note, on: page), !initial.matches(note) { throw invalid() }
                guard !noPopup.isEmpty || (record != nil && record?.sourcePopup == nil && matches) else { throw invalid() }
                result.deferred.insert(index); continue
            }
            guard claimed.insert(popupIndex).inserted else { throw invalid() }
            if record != nil && !matches { changed.insert(index) }
            result.pairs.append(Pair(note: index, popup: popupIndex, parent: currentParent == nil ? .absent : .linked))
            result.drops.insert(index)
        }
        for (index, popup) in annotations.enumerated() where popup.type == "Popup" && !claimed.contains(index) {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            if let value = popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation,
               value.type == "Text" { throw invalid() }
        }
        guard writing else { return result }
        if optionalParents.isEmpty && result.deferred.isEmpty { return result }

        // Existing exact origins can answer without constructing a reader.
        var unresolvedPairs = Set(result.pairs.indices.filter { !changed.contains(result.pairs[$0].note) })
        for offset in unresolvedPairs {
            let pair = result.pairs[offset], note = annotations[pair.note], popup = annotations[pair.popup]
            if let nativeNote = PDFCatalogStructurePreserver.relationshipOriginal(note, at: pair.note, on: page, currentAnnotations: annotations),
               let nativePopup = PDFCatalogStructurePreserver.relationshipOriginal(popup, at: pair.popup, on: page, currentAnnotations: annotations),
               PDFCatalogStructurePreserver.dictionary(nativeNote, "Popup").map(pdfReferenceIdentity) == pdfReferenceIdentity(nativePopup) {
                if let original = PDFCatalogStructurePreserver.object(nativePopup, "Parent") {
                    if CGPDFObjectGetType(original) == .null { result.pairs[offset].parent = .null }
                    else {
                        guard PDFCatalogStructurePreserver.dictionary(nativePopup, "Parent").map(pdfReferenceIdentity) == pdfReferenceIdentity(nativeNote) else { throw invalid() }
                        result.pairs[offset].parent = .linked
                    }
                } else { result.pairs[offset].parent = .absent }
                unresolvedPairs.remove(offset)
            }
        }
        if unresolvedPairs.isEmpty && result.deferred.isEmpty { return result }
        guard let nativeSource, nativeSource.knownInput, let workBudget else { throw invalid() }
        var baselines: [PDFAnnotationRelationshipBaseline.PublicBaseline] = []
        for entry in optionalParents + noPopup {
            try PDFSaveCancellation.checkCurrent()
            guard let baseline = try PDFAnnotationRelationshipBaseline.publicBaseline(for: entry, source: nativeSource, budget: workBudget) else { throw invalid() }
            baselines.append(baseline)
        }
        var noteCounts: [Fingerprint: Int] = [:], popupCounts: [Fingerprint: Int] = [:]
        func noteState(_ index: Int) throws -> Fingerprint {
            let note = annotations[index]
            if let record = records[ObjectIdentifier(note)], try record.matches(note) { return record.sourceNote }
            if let proof = try syntheticProof(for: note, on: page, records: records) { return proof.note }
            guard let value = Fingerprint(note) else { throw PDFPageStructurePreserver.Failure.tooComplex }; return value
        }
        func popupState(_ pair: Pair) throws -> Fingerprint {
            let note = annotations[pair.note]
            if let record = records[ObjectIdentifier(note)], try record.matches(note), let value = record.sourcePopup { return value }
            guard let value = Fingerprint(annotations[pair.popup]) else { throw PDFPageStructurePreserver.Failure.tooComplex }; return value
        }
        for index in result.pairs.map(\.note) + Array(result.deferred) { noteCounts[try noteState(index), default: 0] += 1 }
        for pair in result.pairs { popupCounts[try popupState(pair), default: 0] += 1 }
        var pairOffsets: [PairFingerprint: [Int]] = [:], deferredIndexes: [Fingerprint: [Int]] = [:]
        for offset in result.pairs.indices where !changed.contains(result.pairs[offset].note) {
            let pair = result.pairs[offset]
            let key = PairFingerprint(note: try noteState(pair.note), popup: try popupState(pair))
            pairOffsets[key, default: []].append(offset)
        }
        for index in result.deferred { deferredIndexes[try noteState(index), default: []].append(index) }
        var originalNoteCounts: [Fingerprint: Int] = [:], originalPopupCounts: [Fingerprint: Int] = [:]
        for baseline in baselines {
            originalNoteCounts[baseline.note, default: 0] += 1
            if let popup = baseline.popup { originalPopupCounts[popup, default: 0] += 1 }
        }
        var covered = Set<Int>()
        for (baselineIndex, baseline) in baselines.enumerated() {
            guard noteCounts[baseline.note] == 1, originalNoteCounts[baseline.note] == 1 else { continue }
            if let popup = baseline.popup {
                guard popupCounts[popup] == 1, originalPopupCounts[popup] == 1 else { continue }
                let matches = pairOffsets[PairFingerprint(note: baseline.note, popup: popup)] ?? []
                guard matches.count == 1, let offset = matches.first else { continue }
                result.pairs[offset].parent = baseline.parent; unresolvedPairs.remove(offset); covered.insert(baselineIndex)
            } else {
                let matches = deferredIndexes[baseline.note] ?? []
                guard matches.count == 1, let index = matches.first else { continue }
                // Only a factory-before-exposure observation (or its exact
                // owned-copy inheritance) can classify unchanged SDK synthesis.
                guard try syntheticProof(for: annotations[index], on: page, records: records) != nil else { throw invalid() }
                result.drops.insert(index)
                if baseline.popupIsNull { result.nulls.insert(index) }
                result.deferred.remove(index); covered.insert(baselineIndex)
            }
        }
        guard result.deferred.isEmpty else { throw invalid() }
        if !unresolvedPairs.isEmpty, !optionalParents.isEmpty {
            guard covered.count == baselines.count else { throw invalid() }
        }
        try PDFSaveCancellation.checkCurrent()
        return result
    }

    static func validate(_ page: PDFPage, remainingAnnotations: inout Int,
                         workBudget: PDFAnnotationRelationshipBaseline.WorkBudget? = nil) throws {
        _ = try inspect(page, remaining: &remainingAnnotations, writing: false,
                        workBudget: workBudget ?? PDFAnnotationRelationshipBaseline.WorkBudget())
    }
    static func prepareForWriting(_ document: PDFDocument) throws {
        try PDFSaveCancellation.checkCurrent()
        let hasText = (0..<document.pageCount).contains { document.page(at: $0)?.annotations.contains { $0.type == "Text" } ?? false }
        guard hasText else { return }
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        var remaining = maximumAnnotations
        let workBudget = PDFAnnotationRelationshipBaseline.WorkBudget()
        for index in 0..<document.pageCount {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            _ = try inspect(page, remaining: &remaining, writing: true, workBudget: workBudget)
        }
        PDFCatalogStructurePreserver.mark(document)
    }

    static func inherit(from source: PDFPage, to copy: PDFPage, remainingMetadata: inout Int,
                        workBudget: PDFAnnotationRelationshipBaseline.WorkBudget? = nil,
                        copyBudget: CopyBudget? = nil) throws {
        let originals = source.annotations
        guard originals.contains(where: { $0.type == "Text" }) else { return }
        try prepareOwnedCopy(from: source, to: copy, budget: copyBudget ?? CopyBudget())
        PDFCatalogStructurePreserver.prepareRelationshipSource(on: source)
        var remaining = maximumAnnotations
        let workBudget = workBudget ?? PDFAnnotationRelationshipBaseline.WorkBudget()
        let state = try inspect(source, remaining: &remaining, writing: false, workBudget: workBudget)
        let copies = copy.annotations
        let originalIDs = Set(originals.map(ObjectIdentifier.init)), copiedIDs = Set(copies.map(ObjectIdentifier.init))
        guard originals.count == copies.count, copiedIDs.count == copies.count, originalIDs.isDisjoint(with: copiedIDs),
              zip(originals, copies).allSatisfy({ $0.type == $1.type }) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        let old = stored(on: source), existing = stored(on: copy)
        let pairsByNote = Dictionary(uniqueKeysWithValues: state.pairs.map { ($0.note, $0) })
        var values: [Observation] = []
        for (index, note) in originals.enumerated() where note.type == "Text" {
            try PDFSaveCancellation.checkCurrent()
            let copied = copies[index], oldRecord = old[ObjectIdentifier(note)]
            let oldMatches = try oldRecord?.matches(note) ?? false
            let initialProof = try syntheticProof(for: note, on: source, records: old)
            guard note.bounds == copied.bounds, note.contents == copied.contents,
                  let noteFingerprint = oldMatches ? oldRecord?.sourceNote : initialProof?.note ?? Fingerprint(note) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            let pair = pairsByNote[index], popupFingerprint: Fingerprint?
            if let pair {
                let originalPopup = originals[pair.popup], copiedPopup = copies[pair.popup]
                guard originalPopup.bounds == copiedPopup.bounds, originalPopup.contents == copiedPopup.contents,
                      let fingerprint = oldMatches ? oldRecord?.sourcePopup : Fingerprint(originalPopup) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                popupFingerprint = fingerprint
            } else { popupFingerprint = nil }
            let existingRecord = existing[ObjectIdentifier(copied)]
            let existingMatches = try existingRecord?.matches(copied) ?? false
            let legacy = (oldMatches && oldRecord?.legacyNoPopup == true) || (existingMatches && existingRecord?.legacyNoPopup == true)
            // Prefer the matching source record: the temporary encoded copy
            // may expose SDK absence even when the original proved null.
            let legacyPopupIsNull: Bool
            if oldMatches, oldRecord?.legacyNoPopup == true { legacyPopupIsNull = oldRecord?.legacyPopupIsNull == true }
            else { legacyPopupIsNull = existingMatches && existingRecord?.legacyNoPopup == true && existingRecord?.legacyPopupIsNull == true }
            let synthetic: PDFAnnotationRelationshipLifecycle.SyntheticState?
            if existingMatches, let value = existingRecord?.sourceSynthetic { synthetic = value }
            else if !legacy, let initialProof {
                guard let target = copied.popup,
                      PDFAnnotationRelationshipLifecycle.SyntheticState(target) == initialProof.popup else { throw invalid() }
                synthetic = initialProof.popup
            } else { synthetic = nil }
            let cost = noteFingerprint.byteCount + (popupFingerprint?.byteCount ?? 0) + (synthetic?.byteCount ?? 0) + 128
            guard cost <= remainingMetadata else { throw PDFPageStructurePreserver.Failure.tooComplex }; remainingMetadata -= cost
            values.append(try Observation(note: copied, expectedPopup: pair.map { copies[$0.popup] }, sourceNote: noteFingerprint,
                                          sourcePopup: popupFingerprint, legacyNoPopup: legacy,
                                          legacyPopupIsNull: legacyPopupIsNull, sourceSynthetic: synthetic))
        }
        objc_setAssociatedObject(copy, association, PageObservations(values), .OBJC_ASSOCIATION_RETAIN)
        PDFCatalogStructurePreserver.inheritRelationshipSource(from: source, to: copy)
        var copiedBudget = maximumAnnotations
        _ = try inspect(copy, remaining: &copiedBudget, writing: false, workBudget: workBudget)
    }

    /// PDFKit may append an initially unlisted SDK popup while copying a page.
    /// Remove only the exact, independently copied counterpart proven by the
    /// factory observation, before enforcing the ordinary annotation bijection.
    static func prepareOwnedCopy(from source: PDFPage, to copy: PDFPage, budget: CopyBudget = CopyBudget()) throws {
        let originals = source.annotations, copies = copy.annotations
        guard copies.count != originals.count else { return }
        guard originals.count <= maximumAnnotations, copies.count <= maximumAnnotations,
              copies.count > originals.count else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        let originalIDs = Set(originals.map(ObjectIdentifier.init)), copyIDs = Set(copies.map(ObjectIdentifier.init))
        guard originalIDs.count == originals.count, copyIDs.count == copies.count,
              originalIDs.isDisjoint(with: copyIDs) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        let originalRecords = stored(on: source)
        var identityCounts: [PDFAnnotationRelationshipLifecycle.SyntheticState.Identity: Int] = [:]
        for annotation in copies where annotation.type == "Popup" {
            try PDFSaveCancellation.checkCurrent()
            if let identity = PDFAnnotationRelationshipLifecycle.SyntheticState.identity(of: annotation) { identityCounts[identity, default: 0] += 1 }
        }
        var extras = Set<ObjectIdentifier>(), pending: [(PDFAnnotation, PDFAnnotation, SyntheticProof)] = [], cursor = 0
        for original in originals {
            try PDFSaveCancellation.checkCurrent()
            while cursor < copies.count, extras.contains(ObjectIdentifier(copies[cursor])) { cursor += 1 }
            guard cursor < copies.count else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            let copied = copies[cursor]; cursor += 1
            guard original.type == copied.type, original.bounds == copied.bounds, original.contents == copied.contents else {
                throw PDFPageStructurePreserver.Failure.invalidCopy
            }
            guard original.type == "Text", let target = original.popup, !originalIDs.contains(ObjectIdentifier(target)),
                  let proof = try syntheticProof(for: original, on: source, records: originalRecords),
                  let copiedTarget = copied.popup, copyIDs.contains(ObjectIdentifier(copiedTarget)) else { continue }
            guard target !== copiedTarget, identityCounts[proof.popup.identity] == 1,
                  PDFAnnotationRelationshipLifecycle.SyntheticState(copiedTarget) == proof.popup,
                  extras.insert(ObjectIdentifier(copiedTarget)).inserted else { throw invalid() }
            pending.append((copied, copiedTarget, proof))
        }
        while cursor < copies.count, extras.contains(ObjectIdentifier(copies[cursor])) { cursor += 1 }
        guard cursor == copies.count, extras.count == copies.count - originals.count else { throw invalid() }
        // NSCopying can leave an independent extracted page pointing at its
        // encrypted donor. Adopt only this proven copy while normalizing its
        // SDK-created extra; the donor's permissions and pages stay untouched.
        var temporaryOwner: PDFDocument?
        var copiedDonor: PDFDocument?
        defer {
            if let temporaryOwner, temporaryOwner.page(at: 0) === copy {
                temporaryOwner.removePage(at: 0)
            }
        }
        if !pending.isEmpty, let donor = copy.document, donor.isEncrypted,
           donor.permissionsStatus == .user, !donor.allowsCommenting {
            guard source !== copy, source.document === donor else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            try PDFDocumentSecurityPolicy.validateCanExtractPages(donor)
            try PDFSaveCancellation.checkCurrent()
            let owner = PDFDocument()
            temporaryOwner = owner
            copiedDonor = donor
            owner.insert(copy, at: 0)
            guard owner.pageCount == 1, owner.page(at: 0) === copy,
                  copy.document === owner, source.document === donor else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        }
        var records = stored(on: copy)
        let remainingIDs = copyIDs.subtracting(extras)
        for (note, popup, proof) in pending {
            let contents = note.contents, bounds = note.bounds, modification = note.modificationDate
            copy.removeAnnotation(popup)
            let accepted = note.setValue(popup, forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup"))
            note.contents = contents
            guard accepted, note.bounds == bounds, note.contents == contents, note.modificationDate == modification,
                  note.popup === popup, !remainingIDs.contains(ObjectIdentifier(popup)),
                  let synthetic = PDFAnnotationRelationshipLifecycle.SyntheticState(popup), synthetic == proof.popup else { throw invalid() }
            let cost = proof.note.byteCount + synthetic.byteCount + 128
            try budget.consume(cost)
            records[ObjectIdentifier(note)] = try Observation(note: note, expectedPopup: nil, sourceNote: proof.note, sourcePopup: nil, sourceSynthetic: synthetic)
        }
        guard copy.annotations.map(ObjectIdentifier.init) == copies.filter({ !extras.contains(ObjectIdentifier($0)) }).map(ObjectIdentifier.init) else { throw invalid() }
        if let temporaryOwner {
            guard temporaryOwner.pageCount == 1, temporaryOwner.page(at: 0) === copy,
                  copy.document === temporaryOwner, source.document === copiedDonor else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            temporaryOwner.removePage(at: 0)
            guard temporaryOwner.pageCount == 0, copy.document == nil,
                  source.document === copiedDonor else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        }
        objc_setAssociatedObject(copy, association, PageObservations(Array(records.values)), .OBJC_ASSOCIATION_RETAIN)
    }
    static func inherit(from source: PDFPage, to copy: PDFPage) throws {
        var remaining = 8 * 1_024 * 1_024
        try inherit(from: source, to: copy, remainingMetadata: &remaining)
    }

    /// The body-page transaction moves the same annotation objects. This is
    /// separate from NSCopying lineage and confers no painting/OBJR authority.
    /// The token temporarily owns the already-owned objects only for the swap;
    /// persistent observations contain weak annotation references.
    static func captureForMove(from source: PDFPage) throws -> MoveCapture {
        let originals = source.annotations
        guard originals.count <= maximumAnnotations else { throw PDFPageStructurePreserver.Failure.tooComplex }
        let ids = originals.map(ObjectIdentifier.init), expectedIDs = Set(ids)
        guard expectedIDs.count == originals.count else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        let hasText = originals.contains(where: { $0.type == "Text" })
        if hasText { PDFCatalogStructurePreserver.prepareRelationshipSource(on: source) }
        var remaining = maximumAnnotations
        try validate(source, remainingAnnotations: &remaining)
        let records = stored(on: source)
        var budget = 8 * 1_024 * 1_024 - originals.count * 64
        guard budget >= 0 else { throw PDFPageStructurePreserver.Failure.tooComplex }
        var units: [(note: PDFAnnotation, popup: PDFAnnotation, proof: SyntheticProof, current: Fingerprint, date: Date?)] = []
        for note in originals where note.type == "Text" {
            try PDFSaveCancellation.checkCurrent()
            guard let popup = note.popup, !expectedIDs.contains(ObjectIdentifier(popup)) else { continue }
            guard let proof = try syntheticProof(for: note, on: source, records: records), let current = Fingerprint(note) else { throw invalid() }
            let cost = proof.note.byteCount + proof.popup.byteCount + current.byteCount + 192
            guard cost <= budget else { throw PDFPageStructurePreserver.Failure.tooComplex }; budget -= cost
            units.append((note, popup, proof, current, note.modificationDate))
        }
        let context = hasText ? PDFCatalogStructurePreserver.relationshipSource(for: source) : nil
        if !units.isEmpty, context == nil { throw invalid() }
        var introduced: [ObjectIdentifier: PDFAnnotation] = [:]
        let completion: (PDFPage) throws -> Void = { page in
            // Cancellation was checked before the caller mutated the live
            // document. Complete/rollback must finish this bounded transaction.
            let current = page.annotations, currentIDs = current.map(ObjectIdentifier.init), currentSet = Set(currentIDs)
            guard currentSet.count == current.count, expectedIDs.isSubset(of: currentSet) else { throw invalid() }
            if units.isEmpty {
                guard currentIDs == ids else { throw invalid() }
                if let context { PDFCatalogStructurePreserver.acceptRelationshipSourceAfterIdentityMove(context, on: page) }
                return
            }
            var promoted = Set<ObjectIdentifier>()
            for unit in units {
                guard unit.note.popup === unit.popup, Fingerprint(unit.note) == unit.current,
                      unit.note.modificationDate?.timeIntervalSinceReferenceDate.bitPattern == unit.date?.timeIntervalSinceReferenceDate.bitPattern,
                      let state = PDFAnnotationRelationshipLifecycle.SyntheticState(unit.popup),
                      unit.proof.popup.matchesAfterPageMove(state) else { throw invalid() }
                if currentSet.contains(ObjectIdentifier(unit.popup)) {
                    guard !expectedIDs.contains(ObjectIdentifier(unit.popup)), promoted.insert(ObjectIdentifier(unit.popup)).inserted else { throw invalid() }
                }
            }
            guard currentSet == expectedIDs.union(promoted) else { throw invalid() }
            var observations = stored(on: page)
            var metadata = 8 * 1_024 * 1_024
            for unit in units {
                if promoted.contains(ObjectIdentifier(unit.popup)) {
                    let contents = unit.note.contents
                    page.removeAnnotation(unit.popup)
                    let accepted = unit.note.setValue(unit.popup, forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup"))
                    if let observed = unit.note.popup, observed !== unit.popup { introduced[ObjectIdentifier(observed)] = observed }
                    unit.note.contents = contents
                    if unit.note.modificationDate?.timeIntervalSinceReferenceDate.bitPattern != unit.date?.timeIntervalSinceReferenceDate.bitPattern {
                        unit.note.modificationDate = unit.date
                    }
                    guard accepted else { throw invalid() }
                }
                guard unit.note.popup === unit.popup, Fingerprint(unit.note) == unit.current,
                      unit.note.modificationDate?.timeIntervalSinceReferenceDate.bitPattern == unit.date?.timeIntervalSinceReferenceDate.bitPattern,
                      let state = PDFAnnotationRelationshipLifecycle.SyntheticState(unit.popup),
                      unit.proof.popup.matchesAfterPageMove(state) else { throw invalid() }
                let cost = unit.proof.note.byteCount + state.byteCount + 128
                guard cost <= metadata else { throw PDFPageStructurePreserver.Failure.tooComplex }; metadata -= cost
                observations[ObjectIdentifier(unit.note)] = try Observation(note: unit.note, expectedPopup: nil,
                    sourceNote: unit.proof.note, sourcePopup: nil, sourceSynthetic: state)
            }
            guard page.annotations.map(ObjectIdentifier.init) == ids else { throw invalid() }
            if let context { PDFCatalogStructurePreserver.acceptRelationshipSourceAfterIdentityMove(context, on: page) }
            objc_setAssociatedObject(page, association, PageObservations(Array(observations.values)), .OBJC_ASSOCIATION_RETAIN)
            withExtendedLifetime(originals) {}
        }
        return MoveCapture(completion: completion, restoration: { page in
            // A failed completion may have changed the current getter. Restore
            // captured targets before invoking the ordinary strict preconditions.
            let listed = page.annotations
            let owned = Set(units.map { ObjectIdentifier($0.popup) }).union(introduced.keys)
            guard listed.allSatisfy({ expectedIDs.contains(ObjectIdentifier($0)) || owned.contains(ObjectIdentifier($0)) }) else { throw invalid() }
            for annotation in listed where !expectedIDs.contains(ObjectIdentifier(annotation)) { page.removeAnnotation(annotation) }
            for unit in units {
                guard unit.note.setValue(unit.popup, forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup")) else { throw invalid() }
                let r = unit.current.rectangle
                unit.note.bounds = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
                unit.note.contents = unit.current.contents
                unit.note.modificationDate = unit.date
                try unit.proof.popup.restoreMutableScalars(to: unit.popup)
            }
            try completion(page)
        })
    }
    static func forward(from source: PDFPage, to copy: PDFPage) {
        guard objc_getAssociatedObject(copy, association) == nil else { return }
        do { var budget = 64 * 1_024; try inherit(from: source, to: copy, remainingMetadata: &budget) }
        catch { objc_setAssociatedObject(copy, association, PageObservations([]), .OBJC_ASSOCIATION_RETAIN) }
    }
    /// Only an already recorded, still matching owned manual-cleanup note
    /// needs a snapshot path that does not promote its unlisted SDK popup.
    static func requiresManualCopy(on page: PDFPage) throws -> Bool {
        try PDFSaveCancellation.checkCurrent()
        let records = stored(on: page)
        guard !records.isEmpty else { return false }
        let annotations = page.annotations
        guard annotations.count <= maximumAnnotations else { throw PDFPageStructurePreserver.Failure.tooComplex }
        let identities = Set(annotations.map(ObjectIdentifier.init))
        guard identities.count == annotations.count else { throw invalid() }
        for (index, note) in annotations.enumerated() {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let record = records[ObjectIdentifier(note)], record.legacyNoPopup,
                  record.sourceSynthetic == nil, record.expectedPopup == nil,
                  note.type == "Text", note.page === page, try record.matches(note) else { continue }
            guard note.popup.map({ !identities.contains(ObjectIdentifier($0)) }) ?? true else { throw invalid() }
            return true
        }
        return false
    }

    /// Existing indexed copy owner only, immediately after its intentional
    /// removal of an SDK popup under known native absence.
    static func recordLegacyNoPopup(_ note: PDFAnnotation, on page: PDFPage, nativeOriginal: CGPDFDictionaryRef) throws {
        let value = PDFCatalogStructurePreserver.object(nativeOriginal, "Popup")
        guard note.type == "Text", page.annotations.contains(where: { $0 === note }),
              value == nil || value.map(CGPDFObjectGetType) == .null,
              note.popup.map({ candidate in !page.annotations.contains { $0 === candidate } }) ?? true,
              let fingerprint = Fingerprint(note) else { throw invalid() }
        if let record = stored(on: page)[ObjectIdentifier(note)], record.sourceSynthetic != nil, try record.matches(note) { return }
        let observation = try Observation(note: note, expectedPopup: nil, sourceNote: fingerprint, sourcePopup: nil,
                                          legacyNoPopup: true, legacyPopupIsNull: value.map(CGPDFObjectGetType) == .null)
        let state = (objc_getAssociatedObject(page, association) as? PageObservations) ?? PageObservations([])
        state.values.removeAll { $0.note === note }; state.values.append(observation)
        objc_setAssociatedObject(page, association, state, .OBJC_ASSOCIATION_RETAIN)
    }

    static func addCurrentRelationships(in document: PDFDocument, to plan: inout PDFCatalogGraphPlan) throws {
        var remaining = maximumAnnotations
        let workBudget = PDFAnnotationRelationshipBaseline.WorkBudget()
        for pageIndex in 0..<document.pageCount {
            if pageIndex & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: pageIndex) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            let result = try inspect(page, remaining: &remaining, writing: true, workBudget: workBudget)
            for index in result.drops { plan.annotationDrops[pageIndex, default: [:]][index, default: []].insert("Popup") }
            for index in result.nulls { plan.annotationEntries[pageIndex, default: [:]][index, default: [:]]["Popup"] = .null }
            for pair in result.pairs {
                plan.annotationEntries[pageIndex, default: [:]][pair.note, default: [:]]["Popup"] = .annotation(page: pageIndex, index: pair.popup)
                plan.annotationDrops[pageIndex, default: [:]][pair.popup, default: []].insert("Parent")
                switch pair.parent {
                case .linked: plan.annotationEntries[pageIndex, default: [:]][pair.popup, default: [:]]["Parent"] = .annotation(page: pageIndex, index: pair.note)
                case .null: plan.annotationEntries[pageIndex, default: [:]][pair.popup, default: [:]]["Parent"] = .null
                case .absent: break
                }
            }
        }
    }
    private static func invalid() -> Error { PDFPageStructurePreserver.Failure.unsupportedStructure }
}
