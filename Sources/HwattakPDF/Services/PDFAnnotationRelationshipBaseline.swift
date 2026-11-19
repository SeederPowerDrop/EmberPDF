// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Darwin
import Foundation
import PDFKit

/// A relationship-only public baseline measured from exact native objects.
/// It grants no page geometry, annotation painting, or tagged-object lineage.
enum PDFAnnotationRelationshipBaseline {
    enum Parent: Equatable, Sendable { case absent, null, linked }
    struct Fingerprint: Hashable, Sendable {
        let subtype: String
        let rectangle: [Double]
        let name: String?
        let contents: String?
        var byteCount: Int { 96 + (name?.utf8.count ?? 0) + (contents?.utf8.count ?? 0) }
        init?(_ annotation: PDFAnnotation) {
            guard let subtype = annotation.type, ["Text", "Popup"].contains(subtype) else { return nil }
            let b = annotation.bounds
            let values = [Double(b.minX), Double(b.minY), Double(b.width), Double(b.height)]
            guard values.allSatisfy(\.isFinite) else { return nil }
            let rawName = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
            guard rawName == nil || rawName is NSNull || rawName is String else { return nil }
            let name = rawName as? String, contents = annotation.contents
            guard (name?.utf8.prefix(4_097).count ?? 0) <= 4_096,
                  (contents?.utf8.prefix(16_385).count ?? 0) <= 16_384 else { return nil }
            self.subtype = subtype; rectangle = values; self.name = name; self.contents = contents
        }
    }
    struct Entry: @unchecked Sendable {
        let note: CGPDFDictionaryRef
        let popup: CGPDFDictionaryRef?
        let parent: Parent
        var popupIsNull = false
    }
    struct Source: @unchecked Sendable {
        let owner: CGPDFDocument
        let page: CGPDFPage
        let cache: Cache
        let knownInput: Bool
    }
    struct PublicBaseline: Sendable {
        let note: Fingerprint
        let popup: Fingerprint?
        let parent: Parent
        let popupIsNull: Bool
        var byteCount: Int { note.byteCount + (popup?.byteCount ?? 0) + 64 }
    }
    struct Key: Hashable { let page: UInt; let note: UInt; let popup: UInt }
    final class WorkBudget {
        private(set) var remainingBytes: Int
        private(set) var remainingVisits: Int
        private let externalCharge: ((Int, Int) throws -> Void)?
        init(bytes: Int = 64 * 1_024 * 1_024, visits: Int = 500_000,
             externalCharge: ((Int, Int) throws -> Void)? = nil) {
            remainingBytes = bytes; remainingVisits = visits
            self.externalCharge = externalCharge
        }
        func consume(bytes: Int, visits: Int = 1) throws {
            try PDFSaveCancellation.checkCurrent()
            guard bytes >= 0, visits >= 0, bytes <= remainingBytes, visits <= remainingVisits else {
                throw PDFPageStructurePreserver.Failure.tooComplex
            }
            try externalCharge?(bytes, visits)
            remainingBytes -= bytes; remainingVisits -= visits
        }
    }
    final class Cache: @unchecked Sendable {
        private struct Cached { let value: PublicBaseline?; let bytes: Int }
        private let lock = NSLock()
        private var values: [Key: Cached] = [:], recency: [Key] = []
        private var bytes = 0
        private(set) var measurements = 0
        #if DEBUG
        private var readers = 0
        // measure runs only inside this cache's serialized build closure.
        func recordReaderConstruction() { readers += 1 }
        #endif
        // Scalars only. Eviction changes working set, never lifetime coverage.
        private let maximumEntries = 128, maximumBytes = 256 * 1_024
        func value(for key: Key, build: () throws -> PublicBaseline?) throws -> PublicBaseline? {
            if Thread.isMainThread {
                guard lock.try() else { return nil }
                defer { lock.unlock() }
                return values[key]?.value
            }
            lock.lock(); defer { lock.unlock() }
            try PDFSaveCancellation.checkCurrent()
            if let cached = values[key] {
                recency.removeAll { $0 == key }; recency.append(key)
                return cached.value
            }
            let value = try build(), cost = value?.byteCount ?? 32
            guard cost <= maximumBytes else { return nil }
            try PDFSaveCancellation.checkCurrent()
            while values.count >= maximumEntries || bytes > maximumBytes - cost {
                guard let oldest = recency.first else { values.removeAll(); bytes = 0; break }
                recency.removeFirst(); bytes -= values.removeValue(forKey: oldest)?.bytes ?? 0
            }
            values[key] = Cached(value: value, bytes: cost); recency.append(key); bytes += cost
            if value != nil { measurements += 1 }
            return value
        }
        #if DEBUG
        var footprint: (entries: Int, bytes: Int, measurements: Int, readers: Int) {
            lock.lock(); defer { lock.unlock() }; return (values.count, bytes, measurements, readers)
        }
        #endif
    }

    /// Only native dictionary identities choose the original relationship.
    /// No public fingerprint or array offset chooses its target.
    static func entries(in source: Source, budget: WorkBudget?) throws -> [Entry] {
        try entries(in: source.page, budget: budget)
    }
    private static func entries(in page: CGPDFPage, budget: WorkBudget?) throws -> [Entry] {
        guard let dictionary = page.dictionary else { throw invalid() }
        guard let list = PDFCatalogStructurePreserver.array(dictionary, "Annots") else {
            guard PDFCatalogStructurePreserver.object(dictionary, "Annots") == nil else { throw invalid() }
            return []
        }
        guard CGPDFArrayGetCount(list) <= 100_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
        try budget?.consume(bytes: CGPDFArrayGetCount(list) * 64, visits: CGPDFArrayGetCount(list) * 2)
        var annotations: [CGPDFDictionaryRef] = [], indexes: [UInt: Int] = [:]
        for index in 0..<CGPDFArrayGetCount(list) {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(list, index, &annotation), let annotation,
                  indexes.updateValue(index, forKey: pdfReferenceIdentity(annotation)) == nil else { throw invalid() }
            annotations.append(annotation)
        }
        var result: [Entry] = [], claimed = Set<UInt>()
        for note in annotations where subtype(note) == "Text" {
            try PDFSaveCancellation.checkCurrent()
            guard let object = PDFCatalogStructurePreserver.object(note, "Popup"), CGPDFObjectGetType(object) != .null else {
                result.append(Entry(note: note, popup: nil, parent: .absent,
                    popupIsNull: PDFCatalogStructurePreserver.object(note, "Popup").map(CGPDFObjectGetType) == .null)); continue
            }
            guard let popup = PDFCatalogStructurePreserver.dictionary(note, "Popup"),
                  indexes[pdfReferenceIdentity(popup)] != nil, subtype(popup) == "Popup",
                  claimed.insert(pdfReferenceIdentity(popup)).inserted else { throw invalid() }
            let parent: Parent
            if let value = PDFCatalogStructurePreserver.object(popup, "Parent") {
                if CGPDFObjectGetType(value) == .null { parent = .null }
                else {
                    guard let nativeParent = PDFCatalogStructurePreserver.dictionary(popup, "Parent"),
                          pdfReferenceIdentity(nativeParent) == pdfReferenceIdentity(note) else { throw invalid() }
                    parent = .linked
                }
            } else { parent = .absent }
            result.append(Entry(note: note, popup: popup, parent: parent))
        }
        return result
    }

    /// Before the public full-key deep copy, bound every possible native
    /// Text/Popup candidate. No SDK reader or scalar cache is created here.
    /// A native Popup/Parent P edge could lead to a page/resource graph. A
    /// no-Popup Text's own P is not copied by the synthetic-target full getter.
    static func preflightInitialState(on page: CGPDFPage, budget: WorkBudget) throws -> Bool {
        guard let dictionary = page.dictionary else { return false }
        let entries = try entries(in: page, budget: budget)
        guard !entries.isEmpty else { return false }
        let claimed = Set(entries.compactMap { $0.popup.map(pdfReferenceIdentity) })
        if let list = PDFCatalogStructurePreserver.array(dictionary, "Annots") {
            for index in 0..<CGPDFArrayGetCount(list) {
                var item: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(list, index, &item), let item else { return false }
                if subtype(item) == "Popup", !claimed.contains(pdfReferenceIdentity(item)) { return false }
            }
        }
        for entry in entries {
            let proof = Preflight(note: entry.note, popup: entry.popup, page: dictionary, budget: budget, allowPageReference: false)
            guard proof.check(entry.note), entry.popup.map(proof.check) ?? true else {
                if let failure = proof.failure { throw failure }; return false
            }
        }
        return true
    }

    static func publicBaseline(for entry: Entry, source: Source, budget: WorkBudget) throws -> PublicBaseline? {
        guard let page = source.page.dictionary else { return nil }
        let key = Key(page: pdfReferenceIdentity(page), note: pdfReferenceIdentity(entry.note), popup: entry.popup.map(pdfReferenceIdentity) ?? 0)
        return try source.cache.value(for: key) {
            // A caller cannot attach an arbitrary native graph to these bytes.
            guard source.knownInput else { return nil }
            return try measure(entry, source: source, budget: budget)
        }
    }

    private static func measure(_ entry: Entry, source: Source, budget: WorkBudget) throws -> PublicBaseline? {
        guard !Thread.isMainThread, let sourcePage = source.page.dictionary else { return nil }
        try budget.consume(bytes: 4_096)
        let proof = Preflight(note: entry.note, popup: entry.popup, page: sourcePage, budget: budget)
        guard proof.check(entry.note), entry.popup.map(proof.check) ?? true else {
            if let failure = proof.failure { throw failure }; return nil
        }
        var geometry: [String: PDFCatalogGraphValue] = [:]
        for key in PDFPageGeometryPreserver.boxes.map(\.0) + ["Rotate", "UserUnit"] {
            if let value = try inherited(sourcePage, key: key, budget: budget) {
                guard proof.geometry(value, key: key) else { if let failure = proof.failure { throw failure }; return nil }
                geometry[key] = .original(value)
            }
        }
        try PDFSaveCancellation.checkCurrent()
        let bytes = blankData
        #if DEBUG
        source.cache.recordReaderConstruction()
        #endif
        guard let blank = PDFDocument(data: bytes), blank.pageCount == 1 else { throw invalid() }
        var plan = PDFCatalogGraphPlan()
        plan.retainedDocuments = [source.owner]
        plan.aliases[pdfReferenceIdentity(sourcePage)] = .page(0)
        geometry["Annots"] = .array([.dictionaryReference(entry.note)] + (entry.popup.map { [.dictionaryReference($0)] } ?? []))
        plan.pageEntries[0] = geometry
        let isolated = try PDFBodyTextPageSnapshot.preservingCatalog(in: bytes, from: blank, plan: plan)
        guard isolated.count <= 64 * 1_024 else { return nil }
        try PDFSaveCancellation.checkCurrent()
        #if DEBUG
        source.cache.recordReaderConstruction()
        #endif
        guard let document = PDFDocument(data: isolated), document.pageCount == 1, let page = document.page(at: 0),
              page.annotations.count == (entry.popup == nil ? 1 : 2),
              page.annotations.filter({ $0.type == "Text" }).count == 1,
              let note = page.annotations.first(where: { $0.type == "Text" }), let noteState = Fingerprint(note) else { return nil }
        let popupState: Fingerprint?
        if entry.popup != nil {
            guard page.annotations.filter({ $0.type == "Popup" }).count == 1,
                  let popup = page.annotations.first(where: { $0.type == "Popup" }), note.popup === popup,
                  let state = Fingerprint(popup) else { return nil }
            popupState = state
        } else { popupState = nil }
        try PDFSaveCancellation.checkCurrent()
        return PublicBaseline(note: noteState, popup: popupState, parent: entry.parent, popupIsNull: entry.popupIsNull)
    }

    /// Import the complete dictionary, after ruling out every graph that can
    /// escape the known pair or inflate metadata beyond the small buffer.
    private final class Preflight {
        let note: UInt, popup: UInt?, page: UInt
        let allowPageReference: Bool
        let budget: WorkBudget
        var failure: Error?
        var remaining = 56 * 1_024, visits = 512
        init(note: CGPDFDictionaryRef, popup: CGPDFDictionaryRef?, page: CGPDFDictionaryRef, budget: WorkBudget,
             allowPageReference: Bool = true) {
            self.note = pdfReferenceIdentity(note); self.popup = popup.map(pdfReferenceIdentity); self.page = pdfReferenceIdentity(page)
            self.budget = budget
            self.allowPageReference = allowPageReference
        }
        private func take(_ count: Int, visits: Int = 0) -> Bool {
            guard count >= 0, count <= remaining else { return false }
            do { try budget.consume(bytes: count, visits: visits); remaining -= count; return true }
            catch { failure = error; return false }
        }
        private final class Context {
            let proof: Preflight, owner: UInt, border: Bool
            var valid = true
            init(_ proof: Preflight, owner: UInt, border: Bool) { self.proof = proof; self.owner = owner; self.border = border }
        }
        func check(_ dictionary: CGPDFDictionaryRef) -> Bool { dictionaryValue(dictionary, border: false) }
        private func dictionaryValue(_ dictionary: CGPDFDictionaryRef, border: Bool) -> Bool {
            guard CGPDFDictionaryGetCount(dictionary) <= 32 else { return false }
            let context = Context(self, owner: pdfReferenceIdentity(dictionary), border: border)
            CGPDFDictionaryApplyFunction(dictionary, { key, value, info in
                guard let info else { return }
                let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
                guard context.valid else { return }
                let count = strnlen(key, 129)
                guard count <= 128, count <= context.proof.remaining / 6 else { context.valid = false; return }
                guard context.proof.take(count * 6) else { context.valid = false; return }
                let name = String(cString: key)
                if context.border && !["W", "S", "D"].contains(name) { context.valid = false; return }
                context.valid = context.proof.value(value, key: name, owner: context.owner, depth: 0)
            }, Unmanaged.passUnretained(context).toOpaque())
            return context.valid
        }
        func geometry(_ object: CGPDFObjectRef, key: String) -> Bool {
            if key == "Rotate" {
                var number: CGPDFInteger = 0
                guard CGPDFObjectGetType(object) == .integer, CGPDFObjectGetValue(object, .integer, &number),
                      number % 90 == 0, (-360_000...360_000).contains(number) else { return false }
            } else if key == "UserUnit" {
                var number: Double = 0
                if CGPDFObjectGetType(object) == .integer {
                    var value: CGPDFInteger = 0; guard CGPDFObjectGetValue(object, .integer, &value) else { return false }; number = Double(value)
                } else {
                    var value: CGPDFReal = 0; guard CGPDFObjectGetType(object) == .real,
                        CGPDFObjectGetValue(object, .real, &value) else { return false }; number = Double(value)
                }
                guard number.isFinite, number > 0, number <= 75_000 else { return false }
            } else if CGPDFObjectGetType(object) != .array { return false }
            return value(object, key: key, owner: 0, depth: 0)
        }
        private func value(_ object: CGPDFObjectRef, key: String, owner: UInt, depth: Int) -> Bool {
            guard visits > 0, depth < 4, take(32, visits: 1) else { return false }; visits -= 1
            if ["AP", "A", "AA", "IRT", "FS", "Sound", "Movie", "RichMediaContent"].contains(key), CGPDFObjectGetType(object) != .null { return false }
            switch CGPDFObjectGetType(object) {
            case .null, .boolean: return true
            case .integer: var value: CGPDFInteger = 0; return CGPDFObjectGetValue(object, .integer, &value)
            case .real:
                var value: CGPDFReal = 0
                return CGPDFObjectGetValue(object, .real, &value) && value.isFinite && take(352)
            case .name:
                var name: UnsafePointer<CChar>?; guard CGPDFObjectGetValue(object, .name, &name), let name else { return false }
                let count = strnlen(name, 257); return count <= 256 && count <= remaining / 6 && take(count * 6)
            case .string:
                var string: CGPDFStringRef?; guard CGPDFObjectGetValue(object, .string, &string), let string else { return false }
                let count = CGPDFStringGetLength(string); return count <= 8_192 && count <= remaining / 6 && take(count * 6)
            case .array:
                guard ["Rect", "C", "Border", "D", "MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox"].contains(key) else { return false }
                var array: CGPDFArrayRef?; guard CGPDFObjectGetValue(object, .array, &array), let array else { return false }
                let count = CGPDFArrayGetCount(array)
                guard count <= 32, (!["Rect", "MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox"].contains(key) || count == 4) else { return false }
                for index in 0..<count {
                    var item: CGPDFObjectRef?; guard CGPDFArrayGetObject(array, index, &item), let item else { return false }
                    let type = CGPDFObjectGetType(item)
                    guard type == .integer || type == .real || (key == "Border" && index == 3 && type == .array),
                          value(item, key: key == "Border" ? "D" : key, owner: owner, depth: depth + 1) else { return false }
                }
                return true
            case .dictionary:
                var dictionary: CGPDFDictionaryRef?; guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return false }
                let identity = pdfReferenceIdentity(dictionary)
                if key == "P" { return identity == page && (allowPageReference || (owner == note && popup == nil)) }
                if key == "Popup" { return owner == note && identity == popup }
                if key == "Parent" { return owner == popup && identity == note }
                return key == "BS" && dictionaryValue(dictionary, border: true)
            case .stream: return false
            @unknown default: return false
            }
        }
    }
    private static func inherited(_ dictionary: CGPDFDictionaryRef, key: String, budget: WorkBudget) throws -> CGPDFObjectRef? {
        var current = dictionary, seen = Set<UInt>()
        for _ in 0..<64 {
            try budget.consume(bytes: 0)
            guard seen.insert(pdfReferenceIdentity(current)).inserted else { throw invalid() }
            if let value = PDFCatalogStructurePreserver.object(current, key) { return value }
            guard let parent = PDFCatalogStructurePreserver.dictionary(current, "Parent") else { return nil }
            current = parent
        }
        throw invalid()
    }
    private static func subtype(_ dictionary: CGPDFDictionaryRef) -> String? {
        var name: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &name), let name, strnlen(name, 65) <= 64 else { return nil }
        return String(cString: name)
    }
    private static func invalid() -> Error { PDFPageStructurePreserver.Failure.unsupportedStructure }
    private static let blankData: Data = {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> >>"]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let offset = bytes.count; bytes.append(Data("xref\n0 4\n0000000000 65535 f \n".utf8))
        for value in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", value).utf8)) }
        bytes.append(Data("trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(offset)\n%%EOF\n".utf8)); return bytes
    }()
}
