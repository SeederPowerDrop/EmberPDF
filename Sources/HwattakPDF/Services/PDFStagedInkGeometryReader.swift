// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import CoreGraphics
import Darwin
import Foundation

/// An alternative numeric view of this writer's exact staged bytes. It grants
/// no original-file, page-painting, annotation-lineage or general writer authority.
/// CG is always tried first; the C reader is created only by a failed Ink proof.
final class PDFStagedInkGeometryReader {
    typealias Geometry = PDFPageGeometryPreserver.AnnotationGeometry
    private typealias Failure = PDFPageGeometryPreserver.Failure
    static let maximumInputBytes = 64 * 1_024 * 1_024
    private static let maximumObjects: UInt32 = 500_000
    private static let maximumAnnotations = 100_000

    let document: CGPDFDocument
    private let data: Data
    private var context: EmberRawPDFRef?
    // Aggregate across every fallback page, shared with its borrowed parser.
    private var budget = PDFInkGeometryWorkBudget()
    #if DEBUG
    var rawReaderCreated: Bool { context != nil }
    #endif

    private init(data: Data, document: CGPDFDocument) {
        self.data = data; self.document = document
    }
    deinit { if let context { ember_raw_pdf_destroy(context) } }

    /// The CG owner and lazy raw reader can only be created from the same
    /// canonicalized stagedData at this boundary. No independently supplied
    /// native graph or file path can be bound to this reader.
    static func open(_ stagedData: Data) throws -> PDFStagedInkGeometryReader {
        guard stagedData.count <= Self.maximumInputBytes else { throw Failure.tooComplex }
        guard let provider = CGDataProvider(data: stagedData as CFData),
              let document = CGPDFDocument(provider) else { throw Failure.invalidGeometry }
        return PDFStagedInkGeometryReader(data: stagedData, document: document)
    }

    func geometries(onPage index: Int, annotations: CGPDFArrayRef?) throws -> [Int: Geometry] {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, index >= 0,
              index < document.numberOfPages,
              let page = document.page(at: index + 1)?.dictionary,
              let annotations,
              let nativeArray = PDFCatalogStructurePreserver.array(page, "Annots"),
              pdfReferenceIdentity(nativeArray) == pdfReferenceIdentity(annotations) else { throw Failure.invalidGeometry }
        let count = CGPDFArrayGetCount(annotations)
        guard count <= Self.maximumAnnotations else { throw Failure.tooComplex }
        try loadContext()
        var rawPage: EmberRawPDFObject = 0
        try checked(ember_raw_pdf_page(context, UInt32(index), &rawPage))
        let rawAnnotations = try value(rawPage, "Annots")
        guard try kind(rawAnnotations) == Int32(EMBER_RAW_PDF_ARRAY.rawValue) else { throw Failure.invalidGeometry }
        var rawCount: UInt32 = 0
        try checked(ember_raw_pdf_array_count(context, rawAnnotations, &rawCount))
        guard Int(rawCount) == count else { throw Failure.invalidGeometry }
        var result: [Int: Geometry] = [:]
        for offset in 0..<count {
            try PDFSaveCancellation.checkCurrent()
            var native: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, offset, &native), let native else { throw Failure.invalidGeometry }
            let raw = try item(rawAnnotations, offset)
            if let geometry = try PDFInkGeometryNumericParser.read(native, raw: raw, context: context, budget: &budget) {
                result[offset] = geometry
            }
        }
        try PDFSaveCancellation.checkCurrent()
        return result
    }

    private func loadContext() throws {
        if context != nil { return }
        guard !Thread.isMainThread, !document.isEncrypted, document.isUnlocked,
              data.count <= Self.maximumInputBytes else { throw Failure.tooComplex }
        try PDFSaveCancellation.checkCurrent()
        var status = Int32(EMBER_RAW_PDF_INTERNAL.rawValue)
        let created = data.withUnsafeBytes {
            ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, data.count,
                                 Self.maximumInputBytes, Self.maximumObjects, &status)
        }
        guard let created else { try checked(status); throw Failure.invalidGeometry }
        do {
            try checked(status)
            try PDFSaveCancellation.checkCurrent()
            var count: UInt32 = 0
            try checked(ember_raw_pdf_page_count(created, &count))
            guard Int(count) == document.numberOfPages else { throw Failure.invalidGeometry }
            context = created
        } catch { ember_raw_pdf_destroy(created); throw error }
    }

    private func kind(_ object: EmberRawPDFObject) throws -> Int32 {
        var result: Int32 = -1; try checked(ember_raw_pdf_kind(context, object, &result)); return result
    }
    private func item(_ array: EmberRawPDFObject, _ index: Int) throws -> EmberRawPDFObject {
        var result: EmberRawPDFObject = 0
        try checked(ember_raw_pdf_array_item(context, array, UInt32(index), &result)); return result
    }
    private func value(_ dictionary: EmberRawPDFObject, _ key: String) throws -> EmberRawPDFObject {
        let key = Data(("/" + key).utf8); var result: EmberRawPDFObject = 0
        let status = key.withUnsafeBytes { ember_raw_pdf_dictionary_get(context, dictionary,
            $0.bindMemory(to: UInt8.self).baseAddress, key.count, &result) }
        try checked(status); return result
    }
    private func checked(_ status: Int32) throws {
        if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }
        if status == Int32(EMBER_RAW_PDF_LIMIT.rawValue) { throw Failure.tooComplex }
        guard status == Int32(EMBER_RAW_PDF_OK.rawValue) else { throw Failure.invalidGeometry }
    }
}

/// Shared conservative metadata/work charge, not C/QPDF/SDK allocation or RSS.
/// Value-only accounting never carries an origin, parser handle or PDF object.
struct PDFInkGeometryWorkBudget {
    fileprivate(set) var remainingBytes: Int
    fileprivate(set) var remainingNumbers: Int
    fileprivate(set) var remainingVisits: Int
    /// Cache hits consume exactly the same published work charge as cold
    /// success. Refusal is atomic; a small caller budget never changes a cache.
    mutating func consume(bytes: Int, numbers: Int, visits: Int) -> Bool {
        guard bytes >= 0, numbers >= 0, visits >= 0,
              bytes <= remainingBytes, numbers <= remainingNumbers,
              visits <= remainingVisits else { return false }
        remainingBytes -= bytes; remainingNumbers -= numbers; remainingVisits -= visits
        return true
    }
    init(bytes: Int = 8 * 1_024 * 1_024, numbers: Int = 2_000_000, visits: Int = 2_000_000) {
        remainingBytes = min(max(0, bytes), 8 * 1_024 * 1_024)
        remainingNumbers = min(max(0, numbers), 2_000_000)
        remainingVisits = min(max(0, visits), 2_000_000)
    }
}

/// Pure bounded metadata decoding of a caller-proven CG/C dictionary pair.
/// This does not prove input provenance or mint original-number authority.
/// The borrowed C handle stays inside one synchronous read; its owner retains
/// the live context (and, for RawSource, its lock) for the entire call.
enum PDFInkGeometryNumericParser {
    static func read(_ native: CGPDFDictionaryRef, raw: EmberRawPDFObject,
                     context: EmberRawPDFRef?, budget: inout PDFInkGeometryWorkBudget) throws
        -> PDFPageGeometryPreserver.AnnotationGeometry? {
        guard let context else { throw PDFPageGeometryPreserver.Failure.invalidGeometry }
        let parser = Borrowed(context: context, budget: budget)
        defer { budget = parser.budget }
        return try parser.read(native, raw: raw)
    }

    private final class Borrowed {
        typealias Geometry = PDFPageGeometryPreserver.AnnotationGeometry
        typealias Numbers = PDFPageGeometryPreserver.Numbers
        private typealias Failure = PDFPageGeometryPreserver.Failure
        private static let maximumDictionaryKeys = 256
        private static let maximumKeyBytes = 4_096
        private static let maximumStringBytes = 65_536
        let context: EmberRawPDFRef
        var budget: PDFInkGeometryWorkBudget
        init(context: EmberRawPDFRef, budget: PDFInkGeometryWorkBudget) {
            self.context = context; self.budget = budget
        }
        func read(_ native: CGPDFDictionaryRef, raw: EmberRawPDFObject) throws -> Geometry? {
            try visit()
            guard try kind(raw) == Int32(EMBER_RAW_PDF_DICTIONARY.rawValue) else { throw Failure.invalidGeometry }
            let keys = try matchingKeys(native, raw: raw)
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(native, "Subtype", &subtype), let subtype else { throw Failure.invalidGeometry }
            let length = strnlen(subtype, 65)
            guard length <= 64 else { throw Failure.invalidGeometry }
            try charge(length + 65)
            var nativeSubtype = Data([0x2F]); nativeSubtype.append(Data(bytes: subtype, count: length))
            let rawSubtype = try value(raw, "Subtype")
            guard try kind(rawSubtype) == Int32(EMBER_RAW_PDF_NAME.rawValue),
                  try copyBytes(rawSubtype, name: true, limit: 65) == nativeSubtype else { throw Failure.invalidGeometry }
            guard nativeSubtype == Data("/Ink".utf8) else { return nil }
            try sameString("Contents", native: native, raw: raw, keys: keys)
            try sameString("NM", native: native, raw: raw, keys: keys)
            guard let nativeRect = PDFCatalogStructurePreserver.object(native, "Rect") else { throw Failure.invalidGeometry }
            let rect = try flat(parse(value(raw, "Rect"), native: nativeRect, depth: 0))
            guard rect.count == 4 else { throw Failure.invalidGeometry }
            var coordinates: [String: Numbers] = [:]
            for key in PDFPageGeometryPreserver.coordinateKeys {
                let rawValue = try value(raw, key)
                guard let nativeValue = PDFCatalogStructurePreserver.object(native, key) else {
                    guard !keys.contains(Data(("/" + key).utf8)),
                          try kind(rawValue) == Int32(EMBER_RAW_PDF_NULL.rawValue) else { throw Failure.invalidGeometry }
                    continue
                }
                guard key == "InkList" else { throw Failure.invalidGeometry }
                let parsed = try parse(rawValue, native: nativeValue, depth: 0)
                guard case .array(let strokes) = parsed, !strokes.isEmpty else { throw Failure.invalidGeometry }
                for stroke in strokes {
                    let values = try flat(stroke)
                    guard values.count >= 2, values.count % 2 == 0 else { throw Failure.invalidGeometry }
                }
                try charge(64); coordinates[key] = parsed
            }
            guard coordinates.count == 1, coordinates["InkList"] != nil else { throw Failure.invalidGeometry }
            try charge(256)
            try PDFSaveCancellation.checkCurrent()
            return Geometry(rectangle: rect, coordinates: coordinates)
        }
        private func matchingKeys(_ native: CGPDFDictionaryRef, raw: EmberRawPDFObject) throws -> Set<Data> {
            let count = CGPDFDictionaryGetCount(native)
            guard count <= Self.maximumDictionaryKeys else { throw Failure.tooComplex }
            var rawCount: UInt32 = 0
            try checked(ember_raw_pdf_dictionary_count(context, raw, &rawCount))
            guard Int(rawCount) == count else { throw Failure.invalidGeometry }
            var nativeKeys = Set<Data>(), refused = false
            CGPDFDictionaryApplyBlock(native, { key, _, _ in
                let count = strnlen(key, Self.maximumKeyBytes + 1)
                guard count <= Self.maximumKeyBytes, count + 65 <= self.budget.remainingBytes else { refused = true; return false }
                self.budget.remainingBytes -= count + 65
                var bytes = Data([0x2F]); bytes.append(Data(bytes: key, count: count))
                nativeKeys.insert(bytes); return true
            }, nil)
            guard !refused, nativeKeys.count == count else { throw Failure.tooComplex }
            var rawKeys = Set<Data>()
            for index in 0..<rawCount {
                try visit()
                var bytes: UnsafeMutablePointer<UInt8>?, size = 0
                let status = ember_raw_pdf_dictionary_key_copy(context, raw, index, &bytes, &size)
                defer { if let bytes { ember_raw_pdf_free(bytes) } }
                try checked(status)
                guard size <= Self.maximumKeyBytes + 1, size > 0, let bytes else { throw Failure.tooComplex }
                try charge(size + 64)
                guard rawKeys.insert(Data(bytes: bytes, count: size)).inserted else { throw Failure.invalidGeometry }
            }
            guard rawKeys == nativeKeys else { throw Failure.invalidGeometry }
            return rawKeys
        }

        private func sameString(_ key: String, native: CGPDFDictionaryRef,
                                raw: EmberRawPDFObject, keys: Set<Data>) throws {
            let other = try value(raw, key)
            guard let object = PDFCatalogStructurePreserver.object(native, key) else {
                guard !keys.contains(Data(("/" + key).utf8)), try kind(other) == Int32(EMBER_RAW_PDF_NULL.rawValue) else { throw Failure.invalidGeometry }
                return
            }
            if CGPDFObjectGetType(object) == .null {
                guard try kind(other) == Int32(EMBER_RAW_PDF_NULL.rawValue) else { throw Failure.invalidGeometry }
                return
            }
            var string: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &string), let string,
                  try kind(other) == Int32(EMBER_RAW_PDF_STRING.rawValue) else { throw Failure.invalidGeometry }
            let length = CGPDFStringGetLength(string)
            guard length <= Self.maximumStringBytes else { throw Failure.tooComplex }
            try charge(length + 64)
            let expected: Data
            if length == 0 { expected = Data() }
            else {
                guard let pointer = CGPDFStringGetBytePtr(string) else { throw Failure.invalidGeometry }
                expected = Data(bytes: pointer, count: length)
            }
            guard try copyBytes(other, name: false, limit: Self.maximumStringBytes) == expected else { throw Failure.invalidGeometry }
        }

        private func parse(_ object: EmberRawPDFObject, native: CGPDFObjectRef, depth: Int) throws -> Numbers {
            try visit()
            guard depth < 3 else { throw Failure.invalidGeometry }
            let type = try kind(object)
            if type == Int32(EMBER_RAW_PDF_INTEGER.rawValue) || type == Int32(EMBER_RAW_PDF_REAL.rawValue) {
                let number: Double
                if type == Int32(EMBER_RAW_PDF_INTEGER.rawValue) {
                    guard CGPDFObjectGetType(native) == .integer else { throw Failure.invalidGeometry }
                    var value: Int64 = 0; try checked(ember_raw_pdf_integer(context, object, &value)); number = Double(value)
                } else {
                    guard CGPDFObjectGetType(native) == .real else { throw Failure.invalidGeometry }
                    var value: Double = 0; try checked(ember_raw_pdf_real(context, object, &value)); number = value
                }
                guard budget.remainingNumbers > 0, number.isFinite, abs(number) < 1_000_000_000 else { throw Failure.invalidGeometry }
                try charge(64); budget.remainingNumbers -= 1
                return .value(number)
            }
            var nativeArray: CGPDFArrayRef?
            guard type == Int32(EMBER_RAW_PDF_ARRAY.rawValue),
                  CGPDFObjectGetValue(native, .array, &nativeArray), let nativeArray else { throw Failure.invalidGeometry }
            var count: UInt32 = 0; try checked(ember_raw_pdf_array_count(context, object, &count))
            guard Int(count) == CGPDFArrayGetCount(nativeArray) else { throw Failure.invalidGeometry }
            guard Int(count) <= budget.remainingVisits else { throw Failure.tooComplex }
            try charge(64 + Int(count) * MemoryLayout<Numbers>.stride)
            var result: [Numbers] = []; result.reserveCapacity(Int(count))
            for index in 0..<Int(count) {
                var nativeValue: CGPDFObjectRef?
                guard CGPDFArrayGetObject(nativeArray, index, &nativeValue), let nativeValue else { throw Failure.invalidGeometry }
                result.append(try parse(item(object, index), native: nativeValue, depth: depth + 1))
            }
            return .array(result)
        }
        private func flat(_ value: Numbers) throws -> [Double] {
            guard case .array(let array) = value else { throw Failure.invalidGeometry }
            try charge(array.count * MemoryLayout<Double>.stride)
            return try array.map { guard case .value(let number) = $0 else { throw Failure.invalidGeometry }; return number }
        }
        private func visit() throws {
            try PDFSaveCancellation.checkCurrent()
            guard budget.remainingVisits > 0 else { throw Failure.tooComplex }; budget.remainingVisits -= 1
        }
        private func charge(_ bytes: Int) throws {
            guard bytes >= 0, bytes <= budget.remainingBytes else { throw Failure.tooComplex }; budget.remainingBytes -= bytes
        }
        private func kind(_ object: EmberRawPDFObject) throws -> Int32 {
            var result: Int32 = -1; try checked(ember_raw_pdf_kind(context, object, &result)); return result
        }
        private func item(_ array: EmberRawPDFObject, _ index: Int) throws -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0
            try checked(ember_raw_pdf_array_item(context, array, UInt32(index), &result)); return result
        }
        private func value(_ dictionary: EmberRawPDFObject, _ key: String) throws -> EmberRawPDFObject {
            let key = Data(("/" + key).utf8); var result: EmberRawPDFObject = 0
            let status = key.withUnsafeBytes { ember_raw_pdf_dictionary_get(context, dictionary,
                $0.bindMemory(to: UInt8.self).baseAddress, key.count, &result) }
            try checked(status); return result
        }
        private func copyBytes(_ object: EmberRawPDFObject, name: Bool, limit: Int) throws -> Data {
            try PDFSaveCancellation.checkCurrent()
            var bytes: UnsafeMutablePointer<UInt8>?, count = 0
            let status = name ? ember_raw_pdf_name_copy(context, object, &bytes, &count)
                              : ember_raw_pdf_string_copy(context, object, &bytes, &count)
            defer { if let bytes { ember_raw_pdf_free(bytes) } }
            try checked(status)
            guard count <= limit else { throw Failure.tooComplex }
            try charge(count + 64); try PDFSaveCancellation.checkCurrent()
            guard count > 0 else { return Data() }
            guard let bytes else { throw Failure.invalidGeometry }
            return Data(bytes: bytes, count: count)
        }
        private func checked(_ status: Int32) throws {
            if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }
            if status == Int32(EMBER_RAW_PDF_LIMIT.rawValue) { throw Failure.tooComplex }
            guard status == Int32(EMBER_RAW_PDF_OK.rawValue) else { throw Failure.invalidGeometry }
        }
    }
}
