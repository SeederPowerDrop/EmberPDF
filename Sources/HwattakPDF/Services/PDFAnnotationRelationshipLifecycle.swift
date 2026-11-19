// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import ObjectiveC
import PDFKit

/// Captures SDK-created popup identity and scalar state before public exposure.
/// Installation visits no pages. This grants only relationship lineage, never
/// native geometry, appearance, resource, or tagged-object identity.
enum PDFAnnotationRelationshipLifecycle {
    private static let associationKey = NSObject(), pageKey = NSObject()
    private static var association: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(associationKey).toOpaque())
    }
    private static var pageAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(pageKey).toOpaque())
    }

    /// Bounded, exact public scalar state. In particular, M is retained and
    /// compared; a modification-date edit is never treated as SDK noise.
    struct SyntheticState: Equatable, Sendable {
        struct Identity: Hashable {
            let rectangle: [UInt64]
            let contents: String?
            let modification: UInt64?
        }
        indirect enum Value: Equatable, Sendable {
            case null, string(String), number(String, String, UInt64?), date(UInt64)
            case rectangle([UInt64]), array([Value]), dictionary([String: Value])
        }
        let values: [String: Value]
        let rectangle: [UInt64]
        let contents: String?
        let byteCount: Int
        /// Only the explicit same-object page move may add P:null. All other
        /// keys (including M) and every scalar bit remain exact.
        func matchesAfterPageMove(_ current: SyntheticState) -> Bool {
            guard rectangle == current.rectangle, contents == current.contents else { return false }
            if values["/P"] == nil, current.values["/P"] == .null {
                var adjusted = current.values; adjusted.removeValue(forKey: "/P"); return values == adjusted
            }
            return values == current.values
        }
        /// Rollback only for an already-started owned page transaction. These
        /// are the mutable SDK synthetic scalars; no resource/key graph is set.
        func restoreMutableScalars(to popup: PDFAnnotation) throws {
            guard popup.type == "Popup", rectangle.count == 4 else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            let numbers = rectangle.map(Double.init(bitPattern:))
            popup.bounds = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            popup.contents = contents
            if case let .number(_, value, _)? = values["/Open"] {
                guard value == "0" || value == "1" else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                popup.isOpen = value == "1"
            }
            if case let .number(_, value, _)? = values["/F"] {
                guard let flags = Int64(value), popup.setValue(NSNumber(value: flags), forAnnotationKey: PDFAnnotationKey(rawValue: "/F")) else {
                    throw PDFPageStructurePreserver.Failure.invalidCopy
                }
            }
            if case let .date(value)? = values["/M"] {
                popup.modificationDate = Date(timeIntervalSinceReferenceDate: Double(bitPattern: value))
            }
        }
        var identity: Identity {
            let modification: UInt64?
            if case let .date(value)? = values["/M"] { modification = value } else { modification = nil }
            return Identity(rectangle: rectangle, contents: contents, modification: modification)
        }
        static func identity(of popup: PDFAnnotation) -> Identity? {
            guard popup.type == "Popup" else { return nil }
            let r = popup.bounds, numbers = [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
            let contents = popup.contents, modification = popup.modificationDate?.timeIntervalSinceReferenceDate
            guard numbers.allSatisfy(\.isFinite), (contents?.utf8.prefix(4_097).count ?? 0) <= 4_096,
                  modification?.isFinite ?? true else { return nil }
            return Identity(rectangle: numbers.map(\.bitPattern), contents: contents, modification: modification?.bitPattern)
        }

        init?(_ popup: PDFAnnotation) {
            guard popup.type == "Popup" else { return nil }
            var budget = 16 * 1_024, nodes = 256
            func take(_ count: Int) -> Bool {
                guard count >= 0, count <= budget, nodes > 0 else { return false }
                budget -= count; nodes -= 1; return true
            }
            func text(_ value: String, limit: Int = 4_096) -> String? {
                let count = value.utf8.prefix(min(limit, budget) + 1).count
                guard count <= limit, take(count) else { return nil }; return value
            }
            func visit(_ value: Any, depth: Int) -> Value? {
                guard depth < 4, take(32) else { return nil }
                if value is NSNull { return .null }
                if let value = value as? String { return text(value).map(Value.string) }
                if let value = value as? Date {
                    let number = value.timeIntervalSinceReferenceDate
                    return number.isFinite ? .date(number.bitPattern) : nil
                }
                if let value = value as? NSNumber {
                    let type = String(cString: value.objCType)
                    guard type.count == 1, "cCsSiIlLqQfdB".contains(type), value.doubleValue.isFinite,
                          let number = text(value.stringValue, limit: 128) else { return nil }
                    let bits: UInt64?
                    if type == "f" {
                        guard value.floatValue.isFinite, take(8) else { return nil }; bits = UInt64(value.floatValue.bitPattern)
                    } else if type == "d" {
                        guard take(8) else { return nil }; bits = value.doubleValue.bitPattern
                    } else { bits = nil }
                    return .number(type, number, bits)
                }
                if let value = value as? NSArray {
                    guard value.count <= 32, take(value.count * 8) else { return nil }
                    var result: [Value] = []
                    for element in value {
                        guard let next = visit(element, depth: depth + 1) else { return nil }; result.append(next)
                    }
                    return .array(result)
                }
                if let value = value as? NSDictionary {
                    guard value.count <= 32, take(value.count * 32) else { return nil }
                    var result: [String: Value] = [:]
                    for (key, element) in value {
                        guard let key = key as? String, let name = text(key, limit: 128), result[name] == nil,
                              let next = visit(element, depth: depth + 1) else { return nil }
                        result[name] = next
                    }
                    return .dictionary(result)
                }
                if let value = value as? NSValue,
                   strcmp(value.objCType, NSValue(rect: .zero).objCType) == 0 {
                    let r = value.rectValue, numbers = [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
                    guard numbers.allSatisfy(\.isFinite) else { return nil }
                    return .rectangle(numbers.map(\.bitPattern))
                }
                // References, colors, borders and unknown containers cannot be
                // initial synthetic state. Adding any of them later is an edit.
                return nil
            }
            let dictionary = popup.annotationKeyValues as NSDictionary
            guard case let .dictionary(values)? = visit(dictionary, depth: 0) else { return nil }
            let r = popup.bounds, rectangle = [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
            guard rectangle.allSatisfy(\.isFinite) else { return nil }
            let contents: String?
            if let value = popup.contents {
                guard let value = text(value) else { return nil }; contents = value
            } else { contents = nil }
            self.values = values; self.rectangle = rectangle.map(\.bitPattern); self.contents = contents
            byteCount = 16 * 1_024 - budget + 96
        }
    }

    final class InitialObservation {
        weak var note: PDFAnnotation?
        weak var popup: PDFAnnotation?
        let noteState: PDFAnnotationRelationshipBaseline.Fingerprint
        let popupState: SyntheticState
        var byteCount: Int { noteState.byteCount + popupState.byteCount + 128 }
        init?(note: PDFAnnotation, popup: PDFAnnotation) {
            guard let noteState = PDFAnnotationRelationshipBaseline.Fingerprint(note), let popupState = SyntheticState(popup) else { return nil }
            self.note = note; self.popup = popup; self.noteState = noteState; self.popupState = popupState
        }
        func matches(_ current: PDFAnnotation) -> Bool {
            guard note === current, let popup, current.popup === popup else { return false }
            guard SyntheticState.identity(of: popup) == popupState.identity else { return false }
            return SyntheticState(popup) == popupState
        }
    }

    private final class Factory: NSObject, PDFDocumentDelegate {
        private let lock = NSLock()
        private var remainingBytes = 8 * 1_024 * 1_024, remainingAnnotations = 100_000
        private var remainingWork = 64 * 1_024 * 1_024, remainingVisits = 500_000
        #if DEBUG
        private(set) var pages = 0, annotationReads = 0, captured = 0
        #endif
        func classForPage() -> AnyClass {
            #if DEBUG
            lock.lock(); pages += 1; lock.unlock()
            #endif
            return ObservedPage.self
        }
        func begin(annotationCount: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            #if DEBUG
            annotationReads += 1
            #endif
            guard annotationCount <= remainingAnnotations else { return false }
            remainingAnnotations -= annotationCount
            return true
        }
        func accept(_ value: InitialObservation) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard value.byteCount <= remainingBytes else { return false }
            remainingBytes -= value.byteCount
            #if DEBUG
            captured += 1
            #endif
            return true
        }
        func workBudget() -> PDFAnnotationRelationshipBaseline.WorkBudget {
            PDFAnnotationRelationshipBaseline.WorkBudget(externalCharge: { [weak self] bytes, visits in
                guard let self else { throw PDFPageStructurePreserver.Failure.unsupportedStructure }
                self.lock.lock(); defer { self.lock.unlock() }
                guard bytes <= self.remainingWork, visits <= self.remainingVisits else { throw PDFPageStructurePreserver.Failure.tooComplex }
                self.remainingWork -= bytes; self.remainingVisits -= visits
            })
        }
        #if DEBUG
        var footprint: (pages: Int, annotationReads: Int, captured: Int, bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            return (pages, annotationReads, captured, 8 * 1_024 * 1_024 - remainingBytes)
        }
        #endif
    }

    private final class PageState: NSObject {
        var capturing = true
        var initial: [ObjectIdentifier: InitialObservation] = [:]
    }
    // PDFKit constructs classForPage subclasses through an Objective-C factory;
    // no Swift stored-property initializer is assumed to have run on this page.
    private final class ObservedPage: PDFPage {
        private func capture(_ annotations: [PDFAnnotation]) {
            guard objc_getAssociatedObject(self, pageAssociation) == nil, let document,
                  let factory = objc_getAssociatedObject(document, association) as? Factory,
                  document.delegate === factory, PDFRawStreamProvenance.hasKnownNativeInput(document) else { return }
            let state = PageState()
            objc_setAssociatedObject(self, pageAssociation, state, .OBJC_ASSOCIATION_RETAIN)
            defer { state.capturing = false }
            guard annotations.count <= 100_000, factory.begin(annotationCount: annotations.count),
                  annotations.contains(where: { $0.type == "Text" }) else { return }
            // The full-key SDK API deep-copies values. Its native candidate
            // graph must be bounded before this service invokes that getter.
            let index = document.index(for: self)
            guard index != NSNotFound, let native = document.documentRef, index < native.numberOfPages,
                  let raw = native.page(at: index + 1), let rawDictionary = raw.dictionary,
                  let currentDictionary = pageRef?.dictionary,
                  pdfReferenceIdentity(currentDictionary) == pdfReferenceIdentity(rawDictionary),
                  (try? PDFAnnotationRelationshipBaseline.preflightInitialState(on: raw, budget: factory.workBudget())) == true else { return }
            let listed = Set(annotations.map(ObjectIdentifier.init))
            for note in annotations where note.type == "Text" {
                guard (try? PDFSaveCancellation.checkCurrent()) != nil else { return }
                if let popup = note.popup, !listed.contains(ObjectIdentifier(popup)) {
                    guard let value = InitialObservation(note: note, popup: popup), factory.accept(value) else { return }
                    state.initial[ObjectIdentifier(note)] = value
                }
            }
        }
        override var annotations: [PDFAnnotation] {
            let values = super.annotations; capture(values); return values
        }
        override func annotation(at point: NSPoint) -> PDFAnnotation? {
            capture(super.annotations); return super.annotation(at: point)
        }
        override func draw(with box: PDFDisplayBox, to context: CGContext) {
            capture(super.annotations); super.draw(with: box, to: context)
        }
        override func addAnnotation(_ annotation: PDFAnnotation) {
            capture(super.annotations); super.addAnnotation(annotation)
        }
        override func removeAnnotation(_ annotation: PDFAnnotation) {
            capture(super.annotations); super.removeAnnotation(annotation)
        }
        override func copy(with zone: NSZone? = nil) -> Any {
            capture(super.annotations); return super.copy(with: zone)
        }
        func observation(for note: PDFAnnotation) -> InitialObservation? {
            guard let state = objc_getAssociatedObject(self, pageAssociation) as? PageState, !state.capturing,
                  let value = state.initial[ObjectIdentifier(note)], value.note === note else { return nil }; return value
        }
    }

    /// An existing delegate retains its own class/notification contract. Without
    /// this exact factory boundary, this service grants no initial proof.
    static func install(on document: PDFDocument) {
        guard document.delegate == nil, objc_getAssociatedObject(document, association) == nil else { return }
        let factory = Factory()
        objc_setAssociatedObject(document, association, factory, .OBJC_ASSOCIATION_RETAIN)
        document.delegate = factory
    }
    static func observation(for note: PDFAnnotation, on page: PDFPage) -> InitialObservation? {
        (page as? ObservedPage)?.observation(for: note)
    }
    #if DEBUG
    static func footprint(for document: PDFDocument) -> (pages: Int, annotationReads: Int, captured: Int, bytes: Int)? {
        (objc_getAssociatedObject(document, association) as? Factory)?.footprint
    }
    #endif
}
