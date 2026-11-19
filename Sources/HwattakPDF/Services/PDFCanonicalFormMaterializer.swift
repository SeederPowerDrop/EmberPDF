// SPDX-License-Identifier: MPL-2.0

import Foundation
import ObjectiveC
import PDFKit

/// PDFKit can serialize editable page widgets without an AcroForm /Fields
/// tree. Add that tree for independently named, terminal widgets only. The
/// original objects/streams stay byte-for-byte in the PDF; a bounded classic
/// cross-reference reader authorizes an incremental catalog update.
/// This never runs an external tool or attempts to rewrite encrypted bytes.
enum PDFCanonicalFormMaterializer {
    private static let markerKey = NSObject()
    private static var associationKey: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(markerKey).toOpaque()) }
    private static let maximumBytes = 256 * 1_024 * 1_024
    private static let maximumObjects = 100_000
    private enum CanonicalIdentityFailure: Error { case mismatch }

    enum Failure: LocalizedError {
        case unsupported, tooLarge
        var errorDescription: String? {
            switch self {
            case .unsupported:
                L10n.string("page_structure.error.form_fields", defaultValue: "입력 양식의 구조를 안전하게 유지할 수 없어 PDF를 저장하지 않았습니다.")
            case .tooLarge:
                L10n.string("page_structure.error.too_complex", defaultValue: "PDF 입력 양식의 구조가 안전하게 저장할 수 있는 범위를 초과합니다.")
            }
        }
    }

    static func mark(_ document: PDFDocument) {
        objc_setAssociatedObject(document, associationKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN)
    }

    /// O(1) for an ordinary PDF: no page/widget scan and no serialization.
    static func shouldMaterialize(_ document: PDFDocument) -> Bool {
        if (objc_getAssociatedObject(document, associationKey) as? NSNumber)?.boolValue == true { return true }
        guard let catalog = document.documentRef?.catalog else { return false }
        var form: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(catalog, "AcroForm", &form)
    }

    static func materialize(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw Failure.unsupported }
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw Failure.unsupported
        }
        // Existing protected-save behavior stays intact. This service makes
        // no claim about canonical reconstruction inside encrypted outputs.
        if document.isEncrypted { return data }
        guard document.isUnlocked else { throw Failure.unsupported }
        do {
            if try hasValidCanonicalForm(document) { return data }
        } catch is CanonicalIdentityFailure {
            // PDFKit sometimes writes one widget into /Annots and a second,
            // identical object into /Fields. The raw references below must
            // prove a unique flat-field match before that tree is repaired.
        }
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let reader = try Reader(data)
        let root = try reader.object(reader.root)
        guard root.name("Type") == "Catalog", let pages = root.reference("Pages") else { throw Failure.unsupported }
        let pageReferences = try reader.pages(pages)
        guard pageReferences.count == document.numberOfPages else { throw Failure.unsupported }
        var widgets: [Reference] = [], names = Set<String>()
        for (pageIndex, reference) in pageReferences.enumerated() {
            let page = try reader.object(reference)
            guard let nativePage = document.page(at: pageIndex + 1), let nativeDictionary = nativePage.dictionary else {
                throw Failure.unsupported
            }
            let annotations = try reader.array(page["Annots"])
            var nativeAnnotations: CGPDFArrayRef?
            let hasAnnotations = CGPDFDictionaryGetArray(nativeDictionary, "Annots", &nativeAnnotations)
            guard annotations.count == (hasAnnotations ? nativeAnnotations.map(CGPDFArrayGetCount) ?? 0 : 0) else { throw Failure.unsupported }
            for (index, annotation) in annotations.enumerated() {
                guard let reference = annotation.reference else { throw Failure.unsupported }
                let raw = try reader.object(reference)
                guard raw.name("Subtype") == "Widget" else { continue }
                guard let nativeAnnotations else { throw Failure.unsupported }
                var native: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(nativeAnnotations, index, &native), let native,
                      let name = native.string("T"), !name.isEmpty, name.utf8.count <= 4_096,
                      names.insert(name).inserted,
                      ["Tx", "Ch", "Btn"].contains(raw.name("FT") ?? ""),
                      raw["T"]?.isString == true,
                      ["Parent", "Kids", "AA", "A"].allSatisfy({ raw[$0] == nil }),
                      raw["AP"] != nil else { throw Failure.unsupported }
                if raw.name("FT") == "Btn" {
                    let flags = raw["Ff"]?.integer ?? 0
                    guard flags & ((1 << 15) | (1 << 16)) == 0 else { throw Failure.unsupported }
                }
                widgets.append(reference)
                guard widgets.count <= 10_000 else { throw Failure.tooLarge }
            }
        }
        guard Set(widgets).count == widgets.count else { throw Failure.unsupported }
        var existingForm: Value?
        if let form = root["AcroForm"] {
            let resolved = try reader.resolve(form)
            guard resolved.isDictionary,
                  ["XFA", "CO", "SigFlags"].allSatisfy({ resolved[$0] == nil }) else { throw Failure.unsupported }
            let fields = try reader.array(resolved["Fields"])
            let references = fields.compactMap(\.reference)
            guard references.count == fields.count, Set(references).count == references.count else { throw Failure.unsupported }
            if Set(references) == Set(widgets) { return data }
            // Reconnect only independently named flat widgets. Every existing
            // field must be exactly equivalent to one actual page widget,
            // including its appearance/resource references and all values.
            // A name/value-only match could hide a conflicting field object.
            if !references.isEmpty {
                guard references.count <= widgets.count else { throw Failure.unsupported }
                var unmatched = Set(widgets)
                var widgetsByEncodedName: [Data: Reference] = [:]
                for widget in widgets {
                    guard let name = try reader.object(widget)["T"] else { throw Failure.unsupported }
                    widgetsByEncodedName[data[name.range]] = widget
                }
                for reference in references {
                    let field = try reader.object(reference)
                    guard field.isDictionary, let name = field["T"],
                          let match = widgetsByEncodedName[data[name.range]], unmatched.contains(match),
                          try reader.equivalent(field, reader.object(match)) else { throw Failure.unsupported }
                    unmatched.remove(match)
                }
                // PDFKit can also emit a partial /Fields list after inserting
                // pages. The remaining page widgets passed the same strict
                // flat/unique-name checks and can join the repaired tree.
            }
            existingForm = resolved
        }
        guard !widgets.isEmpty else { return data }
        let formNumber = reader.nextNumber
        let formReference = Reference(number: formNumber, generation: 0)
        let fields = widgets.map(\.encoded).joined(separator: " ")
        let catalog = try reader.dictionaryBytes(root, dropping: ["AcroForm"],
            additions: ["/AcroForm \(formReference.encoded)"])
        var result = data
        if result.last != 10 { result.append(10) }
        let formOffset = result.count
        result.append(Data("\(formReference.number) 0 obj\n".utf8))
        if let existingForm {
            result.append(try reader.dictionaryBytes(existingForm, dropping: ["Fields", "NeedAppearances"],
                additions: ["/Fields [\(fields)]", "/NeedAppearances false"]))
        } else {
            result.append(Data("<< /Fields [\(fields)] /NeedAppearances false >>".utf8))
        }
        result.append(Data("\nendobj\n".utf8))
        let rootOffset = result.count
        result.append(Data("\(reader.root.number) \(reader.root.generation) obj\n".utf8))
        result.append(catalog)
        result.append(Data("\nendobj\n".utf8))
        let xref = result.count
        result.append(Data("xref\n".utf8))
        for (reference, offset) in [(reader.root, rootOffset), (formReference, formOffset)].sorted(by: { $0.0.number < $1.0.number }) {
            result.append(Data("\(reference.number) 1\n".utf8))
            result.append(Data(String(format: "%010d %05d n \n", offset, reference.generation).utf8))
        }
        result.append(Data("trailer\n".utf8))
        result.append(try reader.dictionaryBytes(reader.trailer, dropping: ["Size", "Root", "Prev"],
            additions: ["/Size \(formNumber + 1)", "/Root \(reader.root.encoded)", "/Prev \(reader.startXref)"]))
        result.append(Data("\nstartxref\n\(xref)\n%%EOF\n".utf8))
        guard result.count <= maximumBytes,
              let outputProvider = CGDataProvider(data: result as CFData), let output = CGPDFDocument(outputProvider),
              output.numberOfPages == document.numberOfPages, let catalog = output.catalog else { throw Failure.unsupported }
        var form: CGPDFDictionaryRef?, fieldsArray: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
              CGPDFDictionaryGetArray(form, "Fields", &fieldsArray), let fieldsArray,
              CGPDFArrayGetCount(fieldsArray) == widgets.count else { throw Failure.unsupported }
        var outputNames = Set<String>()
        for index in 0..<CGPDFArrayGetCount(fieldsArray) {
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(fieldsArray, index, &field), let field, let name = field.string("T"),
                  outputNames.insert(name).inserted else { throw Failure.unsupported }
        }
        guard outputNames == names else { throw Failure.unsupported }
        return result
    }

    /// Existing canonical trees are validated before the deliberately narrower
    /// orphan-widget importer. Normal hierarchical/radio forms need no rewrite.
    private static func hasValidCanonicalForm(_ document: CGPDFDocument) throws -> Bool {
        guard let catalog = document.catalog else { throw Failure.unsupported }
        var form: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form else { return false }
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(form, "Fields", &fields), let fields else { throw Failure.unsupported }
        var pageWidgets: Set<UInt> = []
        for pageIndex in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: pageIndex), let dictionary = page.dictionary else { throw Failure.unsupported }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { continue }
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { throw Failure.unsupported }
                if nativeName(annotation, "Subtype") == "Widget" {
                    guard pageWidgets.insert(pdfReferenceIdentity(annotation)).inserted else { throw Failure.unsupported }
                }
            }
        }
        var visited: Set<UInt> = [], connectedWidgets: Set<UInt> = [], fieldNames: Set<String> = []
        func visit(_ field: CGPDFDictionaryRef, parent: CGPDFDictionaryRef?, prefix: String,
                   inheritedValue: CGPDFObjectRef?, depth: Int) throws {
            guard depth < 64, visited.insert(pdfReferenceIdentity(field)).inserted, visited.count <= maximumObjects else { throw Failure.tooLarge }
            var declaredParent: CGPDFDictionaryRef?
            let hasParent = CGPDFDictionaryGetDictionary(field, "Parent", &declaredParent)
            guard (parent == nil && !hasParent) || (parent != nil && declaredParent == parent) else { throw Failure.unsupported }
            let partial = field.string("T")
            let name = partial.map { prefix.isEmpty ? $0 : prefix + "." + $0 } ?? prefix
            if let partial {
                guard !partial.isEmpty, name.utf8.count <= 4_096, fieldNames.insert(name).inserted else { throw Failure.unsupported }
            }
            var ownValue: CGPDFObjectRef?
            let hasValue = CGPDFDictionaryGetObject(field, "V", &ownValue)
            let isWidget = nativeName(field, "Subtype") == "Widget"
            if isWidget {
                guard !name.isEmpty else { throw Failure.unsupported }
                guard pageWidgets.contains(pdfReferenceIdentity(field)) else { throw CanonicalIdentityFailure.mismatch }
                connectedWidgets.insert(pdfReferenceIdentity(field))
                if hasValue, let ownValue, let inheritedValue,
                   !equivalent(ownValue, inheritedValue, depth: 0) { throw Failure.unsupported }
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(field, "Kids", &kids), let kids {
                for index in 0..<CGPDFArrayGetCount(kids) {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(kids, index, &child), let child else { throw Failure.unsupported }
                    try visit(child, parent: field, prefix: name, inheritedValue: ownValue ?? inheritedValue, depth: depth + 1)
                }
            } else if !isWidget, name.isEmpty {
                throw Failure.unsupported
            }
        }
        for index in 0..<CGPDFArrayGetCount(fields) {
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(fields, index, &field), let field else { throw Failure.unsupported }
            try visit(field, parent: nil, prefix: "", inheritedValue: nil, depth: 0)
        }
        guard connectedWidgets == pageWidgets else { throw CanonicalIdentityFailure.mismatch }
        return true
    }

    private static func nativeName(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var name: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &name), let name else { return nil }
        return String(cString: name)
    }
    private static func equivalent(_ left: CGPDFObjectRef, _ right: CGPDFObjectRef, depth: Int) -> Bool {
        if left == right { return true }
        guard depth < 16, CGPDFObjectGetType(left) == CGPDFObjectGetType(right) else { return false }
        switch CGPDFObjectGetType(left) {
        case .null: return true
        case .string:
            var lhs: CGPDFStringRef?, rhs: CGPDFStringRef?
            guard CGPDFObjectGetValue(left, .string, &lhs), CGPDFObjectGetValue(right, .string, &rhs), let lhs, let rhs else { return false }
            // A field value can be encoded as PDFDocEncoding in its parent
            // and UTF-16 in its widget while representing the same text.
            if let a = CGPDFStringCopyTextString(lhs), let b = CGPDFStringCopyTextString(rhs) {
                return (a as String) == (b as String)
            }
            let length = CGPDFStringGetLength(lhs)
            guard length == CGPDFStringGetLength(rhs) else { return false }
            if length == 0 { return true }
            guard let a = CGPDFStringGetBytePtr(lhs), let b = CGPDFStringGetBytePtr(rhs) else { return false }
            return UnsafeBufferPointer(start: a, count: length).elementsEqual(UnsafeBufferPointer(start: b, count: length))
        case .name:
            var lhs: UnsafePointer<CChar>?, rhs: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(left, .name, &lhs), CGPDFObjectGetValue(right, .name, &rhs), let lhs, let rhs else { return false }
            return strcmp(lhs, rhs) == 0
        case .integer:
            var lhs: CGPDFInteger = 0, rhs: CGPDFInteger = 0
            return CGPDFObjectGetValue(left, .integer, &lhs) && CGPDFObjectGetValue(right, .integer, &rhs) && lhs == rhs
        case .real:
            var lhs: CGPDFReal = 0, rhs: CGPDFReal = 0
            return CGPDFObjectGetValue(left, .real, &lhs) && CGPDFObjectGetValue(right, .real, &rhs) && lhs == rhs
        case .boolean:
            var lhs: CGPDFBoolean = 0, rhs: CGPDFBoolean = 0
            return CGPDFObjectGetValue(left, .boolean, &lhs) && CGPDFObjectGetValue(right, .boolean, &rhs) && lhs == rhs
        case .array:
            var lhs: CGPDFArrayRef?, rhs: CGPDFArrayRef?
            guard CGPDFObjectGetValue(left, .array, &lhs), CGPDFObjectGetValue(right, .array, &rhs), let lhs, let rhs,
                  CGPDFArrayGetCount(lhs) == CGPDFArrayGetCount(rhs), CGPDFArrayGetCount(lhs) <= 10_000 else { return false }
            for index in 0..<CGPDFArrayGetCount(lhs) {
                var a: CGPDFObjectRef?, b: CGPDFObjectRef?
                guard CGPDFArrayGetObject(lhs, index, &a), CGPDFArrayGetObject(rhs, index, &b), let a, let b,
                      equivalent(a, b, depth: depth + 1) else { return false }
            }
            return true
        default: return false
        }
    }

    private struct Reference: Hashable {
        let number: Int
        let generation: Int
        var encoded: String { "\(number) \(generation) R" }
    }
    private struct Entry { let key: String; let keyRange: Range<Int>; let value: Value }
    private indirect enum Value {
        case integer(Int, Range<Int>), number(Range<Int>), name(String, Range<Int>), string(Range<Int>)
        case array([Value], Range<Int>), dictionary([Entry], Range<Int>), reference(Reference, Range<Int>), keyword(String, Range<Int>)
        var range: Range<Int> {
            switch self {
            case .integer(_, let range), .number(let range), .name(_, let range), .string(let range),
                 .array(_, let range), .dictionary(_, let range), .reference(_, let range), .keyword(_, let range): range
            }
        }
        var integer: Int? { if case .integer(let value, _) = self { return value }; return nil }
        var reference: Reference? { if case .reference(let value, _) = self { return value }; return nil }
        var isString: Bool { if case .string = self { return true }; return false }
        var isDictionary: Bool { if case .dictionary = self { return true }; return false }
        subscript(_ key: String) -> Value? {
            if case .dictionary(let entries, _) = self { return entries.first { $0.key == key }?.value }
            return nil
        }
        func name(_ key: String) -> String? {
            if case .name(let value, _) = self[key] { return value }
            return nil
        }
        func reference(_ key: String) -> Reference? { self[key]?.reference }
    }

    private final class Reader {
        private var comparisonVisits = 0
        private func countComparison() throws {
            guard comparisonVisits < 100_000 else { throw Failure.tooLarge }
            comparisonVisits += 1
        }
        let bytes: [UInt8]
        let data: Data
        private(set) var root: Reference!
        private(set) var trailer: Value!
        private(set) var startXref = 0
        private(set) var nextNumber = 0
        private var locations: [Int: (offset: Int, generation: Int, live: Bool)] = [:]
        private var cache: [Reference: Value] = [:]
        init(_ data: Data) throws {
            self.data = data
            bytes = Array(data)
            // Only the final trailer controls the current object generations.
            let tailStart = max(0, bytes.count - 4_096)
            let marker = Array("startxref".utf8)
            var found: Int?
            if bytes.count >= marker.count {
                for index in stride(from: bytes.count - marker.count, through: tailStart, by: -1) {
                    if bytes[index..<(index + marker.count)].elementsEqual(marker) { found = index + marker.count; break }
                }
            }
            guard let found else { throw Failure.unsupported }
            var parser = Parser(bytes: bytes, offset: found)
            guard let offset = Int(try parser.word()), offset >= 0, offset < bytes.count else { throw Failure.unsupported }
            startXref = offset
            var current: Int? = offset, visited: Set<Int> = []
            var merged: [Entry] = []
            while let offset = current {
                guard visited.insert(offset).inserted, visited.count <= 32 else { throw Failure.unsupported }
                var parser = Parser(bytes: bytes, offset: offset)
                guard try parser.word() == "xref" else { throw Failure.unsupported }
                while true {
                    let token = try parser.word()
                    if token == "trailer" { break }
                    guard let first = Int(token), let count = Int(try parser.word()), first >= 0, count > 0,
                          first <= maximumObjects, count <= maximumObjects - first else { throw Failure.tooLarge }
                    for number in first..<(first + count) {
                        guard let location = Int(try parser.word()), let generation = Int(try parser.word()),
                              location >= 0, generation >= 0, generation <= 65_535 else { throw Failure.unsupported }
                        let flag = try parser.word()
                        guard flag == "n" || flag == "f", flag != "n" || location < bytes.count else { throw Failure.unsupported }
                        if locations[number] == nil { locations[number] = (location, generation, flag == "n") }
                    }
                }
                let table = try parser.value()
                guard case .dictionary(let entries, _) = table, table["XRefStm"] == nil, table["Encrypt"] == nil else {
                    throw Failure.unsupported
                }
                for entry in entries where !merged.contains(where: { $0.key == entry.key }) { merged.append(entry) }
                if let previous = table["Prev"] {
                    guard let position = previous.integer, position >= 0, position < bytes.count else { throw Failure.unsupported }
                    current = position
                } else { current = nil }
            }
            guard let size = merged.first(where: { $0.key == "Size" })?.value.integer,
                  size > 0, size <= maximumObjects,
                  let root = merged.first(where: { $0.key == "Root" })?.value.reference else { throw Failure.unsupported }
            self.root = root
            trailer = .dictionary(merged, 0..<0)
            nextNumber = max(size, (locations.keys.max() ?? 0) + 1)
            guard nextNumber < maximumObjects else { throw Failure.tooLarge }
        }

        func object(_ reference: Reference) throws -> Value {
            if let value = cache[reference] { return value }
            guard let location = locations[reference.number], location.live,
                  location.generation == reference.generation else { throw Failure.unsupported }
            var parser = Parser(bytes: bytes, offset: location.offset)
            guard Int(try parser.word()) == reference.number, Int(try parser.word()) == reference.generation,
                  try parser.word() == "obj" else { throw Failure.unsupported }
            let value = try parser.value()
            guard try parser.word() == "endobj" else { throw Failure.unsupported }
            cache[reference] = value
            guard cache.count <= maximumObjects else { throw Failure.tooLarge }
            return value
        }
        func resolve(_ value: Value) throws -> Value {
            if let reference = value.reference { return try object(reference) }
            return value
        }
        func array(_ value: Value?) throws -> [Value] {
            guard let value else { return [] }
            guard case .array(let values, _) = try resolve(value) else { throw Failure.unsupported }
            return values
        }
        func pages(_ reference: Reference) throws -> [Reference] {
            var visited: Set<Reference> = [], pages: [Reference] = []
            func visit(_ reference: Reference, depth: Int) throws {
                guard depth < 64, visited.insert(reference).inserted, visited.count <= maximumObjects else { throw Failure.tooLarge }
                let value = try object(reference)
                if value.name("Type") == "Page" { pages.append(reference); return }
                guard value.name("Type") == "Pages" else { throw Failure.unsupported }
                for child in try array(value["Kids"]) {
                    guard let reference = child.reference else { throw Failure.unsupported }
                    try visit(reference, depth: depth + 1)
                }
            }
            try visit(reference, depth: 0)
            return pages
        }
        func dictionaryBytes(_ dictionary: Value, dropping: Set<String>, additions: [String]) throws -> Data {
            guard case .dictionary(let entries, _) = dictionary else { throw Failure.unsupported }
            var result = Data("<<\n".utf8)
            for entry in entries where !dropping.contains(entry.key) {
                result.append(data[entry.keyRange.lowerBound..<entry.value.range.upperBound])
                result.append(10)
            }
            for entry in additions { result.append(Data((entry + "\n").utf8)) }
            result.append(Data(">>".utf8))
            return result
        }
        /// Compare referenced dictionaries without resolving their resources.
        /// Equal-looking fields that reference different appearance objects
        /// remain distinct and cannot silently replace each other.
        func equivalent(_ left: Value, _ right: Value, depth: Int = 0) throws -> Bool {
            try countComparison()
            guard depth < 64 else { throw Failure.tooLarge }
            switch (left, right) {
            case (.integer(let a, _), .integer(let b, _)): return a == b
            case (.name(let a, _), .name(let b, _)): return a == b
            case (.reference(let a, _), .reference(let b, _)): return a == b
            case (.keyword(let a, _), .keyword(let b, _)): return a == b
            case (.string(let a), .string(let b)), (.number(let a), .number(let b)):
                return data[a] == data[b]
            case (.array(let a, _), .array(let b, _)):
                guard a.count == b.count else { return false }
                for (a, b) in zip(a, b) where try !equivalent(a, b, depth: depth + 1) { return false }
                return true
            case (.dictionary(let a, _), .dictionary(let b, _)):
                guard a.count == b.count else { return false }
                for entry in a {
                    guard let other = b.first(where: { $0.key == entry.key }) else { return false }
                    // The catalog graph writer can emit identical scalar
                    // arrays as separate indirect objects in /Fields and
                    // /Annots. Geometry and choice/value arrays compare by
                    // value; appearance/resource references remain strict.
                    if ["Rect", "Border", "Opt", "I", "V", "DV"].contains(entry.key),
                       let same = try equivalentFieldArray(entry.value, other.value,
                           geometryNumbers: ["Rect", "Border"].contains(entry.key)) {
                        guard same else { return false }
                    } else if try !equivalent(entry.value, other.value, depth: depth + 1) { return false }
                }
                return true
            default: return false
            }
        }
        private func equivalentFieldArray(_ left: Value, _ right: Value, geometryNumbers: Bool) throws -> Bool? {
            let left = try resolve(left), right = try resolve(right)
            guard case .array = left, case .array = right else { return nil }
            func compare(_ left: Value, _ right: Value, depth: Int) throws -> Bool {
                try countComparison()
                guard depth < 16 else { throw Failure.tooLarge }
                let left = try resolve(left), right = try resolve(right)
                if geometryNumbers, let a = exactDecimal(left), let b = exactDecimal(right) {
                    return a == b
                }
                switch (left, right) {
                case (.array(let a, _), .array(let b, _)):
                    guard a.count == b.count, a.count <= 10_000 else { return false }
                    for (a, b) in zip(a, b) where try !compare(a, b, depth: depth + 1) { return false }
                    return true
                case (.integer, .integer), (.number, .number), (.name, .name), (.string, .string), (.keyword, .keyword):
                    return try equivalent(left, right, depth: depth + 1)
                default:
                    // No dictionaries or streams may pass through this
                    // scalar-array exception, even via an indirect reference.
                    return false
                }
            }
            return try compare(left, right, depth: 0)
        }

        private struct DecimalGeometryNumber: Equatable {
            let negative: Bool
            let digits: [UInt8]
            let fractionalDigits: Int
        }

        /// PDF geometry numbers have decimal syntax, without exponents. Keep
        /// all digits: Double would collapse distinct integers beyond 2^53.
        /// The parser already caps numeric tokens at 128 bytes; this stricter
        /// normalization applies only inside Rect/Border scalar arrays.
        private func exactDecimal(_ value: Value) -> DecimalGeometryNumber? {
            switch value {
            case .integer, .number: break
            default: return nil
            }
            let token = Array(data[value.range])
            guard !token.isEmpty, token.count <= 128 else { return nil }
            var index = 0, negative = false, point = false, fractional = 0
            if token[0] == 43 || token[0] == 45 {
                negative = token[0] == 45; index = 1
            }
            var digits: [UInt8] = []
            while index < token.count {
                let byte = token[index]; index += 1
                if byte == 46 {
                    guard !point else { return nil }
                    point = true
                } else {
                    guard (48...57).contains(byte) else { return nil }
                    digits.append(byte)
                    if point { fractional += 1 }
                }
            }
            guard !digits.isEmpty else { return nil }
            guard let firstNonzero = digits.firstIndex(where: { $0 != 48 }) else {
                return DecimalGeometryNumber(negative: false, digits: [48], fractionalDigits: 0)
            }
            digits.removeFirst(firstNonzero)
            while fractional > 0, digits.last == 48 {
                digits.removeLast(); fractional -= 1
            }
            return DecimalGeometryNumber(negative: negative, digits: digits, fractionalDigits: fractional)
        }
    }

    /// Lex only referenced non-stream dictionaries/arrays. Do not search for
    /// object headers, /T or /Fields in arbitrary binary stream contents.
    private struct Parser {
        let bytes: [UInt8]
        var offset: Int
        private var visits = 0
        init(bytes: [UInt8], offset: Int) { self.bytes = bytes; self.offset = offset }
        mutating func skip() {
            while offset < bytes.count {
                if Self.space(bytes[offset]) { offset += 1 }
                else if bytes[offset] == 37 {
                    while offset < bytes.count, bytes[offset] != 10, bytes[offset] != 13 { offset += 1 }
                } else { return }
            }
        }
        mutating func word() throws -> String {
            skip()
            let start = offset
            while offset < bytes.count, !Self.space(bytes[offset]), !Self.delimiter(bytes[offset]) { offset += 1 }
            guard offset > start, offset - start <= 128 else { throw Failure.unsupported }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }
        mutating func value(depth: Int = 0) throws -> Value {
            visits += 1
            guard depth < 64, visits <= maximumObjects else { throw Failure.tooLarge }
            skip()
            guard offset < bytes.count else { throw Failure.unsupported }
            let start = offset, first = bytes[offset]
            if first == 47 {
                offset += 1
                var decoded: [UInt8] = []
                while offset < bytes.count, !Self.space(bytes[offset]), !Self.delimiter(bytes[offset]) {
                    if bytes[offset] == 35 {
                        guard offset + 2 < bytes.count,
                              let value = UInt8(String(decoding: bytes[(offset + 1)...(offset + 2)], as: UTF8.self), radix: 16) else { throw Failure.unsupported }
                        decoded.append(value); offset += 3
                    } else { decoded.append(bytes[offset]); offset += 1 }
                    guard decoded.count <= 4_096 else { throw Failure.tooLarge }
                }
                return .name(String(decoding: decoded, as: UTF8.self), start..<offset)
            }
            if first == 40 {
                offset += 1
                var nesting = 1
                while offset < bytes.count {
                    let value = bytes[offset]; offset += 1
                    if value == 92 {
                        guard offset < bytes.count else { throw Failure.unsupported }
                        if bytes[offset] == 13, offset + 1 < bytes.count, bytes[offset + 1] == 10 { offset += 1 }
                        offset += 1
                    } else if value == 40 { nesting += 1; guard nesting < 64 else { throw Failure.tooLarge } }
                    else if value == 41 { nesting -= 1; if nesting == 0 { return .string(start..<offset) } }
                    guard offset - start <= 1_048_576 else { throw Failure.tooLarge }
                }
                throw Failure.unsupported
            }
            if first == 60, offset + 1 < bytes.count, bytes[offset + 1] == 60 {
                offset += 2
                var entries: [Entry] = [], names = Set<String>()
                while true {
                    skip()
                    guard offset + 1 < bytes.count else { throw Failure.unsupported }
                    if bytes[offset] == 62, bytes[offset + 1] == 62 {
                        offset += 2; return .dictionary(entries, start..<offset)
                    }
                    let key = try value(depth: depth + 1)
                    guard case .name(let name, let range) = key, names.insert(name).inserted else { throw Failure.unsupported }
                    entries.append(Entry(key: name, keyRange: range, value: try value(depth: depth + 1)))
                }
            }
            if first == 60 {
                offset += 1
                while offset < bytes.count {
                    let value = bytes[offset]; offset += 1
                    if value == 62 { return .string(start..<offset) }
                    guard Self.space(value) || (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value),
                          offset - start <= 1_048_576 else { throw Failure.unsupported }
                }
                throw Failure.unsupported
            }
            if first == 91 {
                offset += 1
                var values: [Value] = []
                while true {
                    skip()
                    guard offset < bytes.count else { throw Failure.unsupported }
                    if bytes[offset] == 93 { offset += 1; return .array(values, start..<offset) }
                    values.append(try value(depth: depth + 1))
                }
            }
            let token = try word()
            if let number = Int(token) {
                let end = offset
                if number >= 0 {
                    if let next = try? word(), let generation = Int(next), (0...65_535).contains(generation),
                       (try? word()) == "R" {
                        guard number < maximumObjects else { throw Failure.tooLarge }
                        return .reference(Reference(number: number, generation: generation), start..<offset)
                    }
                    offset = end
                }
                return .integer(number, start..<offset)
            }
            if let number = Double(token), number.isFinite { return .number(start..<offset) }
            guard ["true", "false", "null"].contains(token) else { throw Failure.unsupported }
            return .keyword(token, start..<offset)
        }
        private static func space(_ value: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(value) }
        private static func delimiter(_ value: UInt8) -> Bool { [40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(value) }
    }
}

private extension CGPDFDictionaryRef {
    func string(_ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(self, key, &value), let value,
              let decoded = CGPDFStringCopyTextString(value) else { return nil }
        return decoded as String
    }
}
