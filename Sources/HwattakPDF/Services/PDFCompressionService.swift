// SPDX-License-Identifier: MPL-2.0

import AppKit
import CEmberPDFRawStreams
import PDFKit
import Quartz
import zlib

/// These choices affect embedded raster images only. Native text, vector
/// graphics and editable annotations are never rasterized into whole pages.
enum PDFCompressionQuality: String, CaseIterable, Hashable, Sendable {
    case highQuality, balanced, small

    fileprivate var settings: (quality: Double, resolution: Int, maximumPixels: Int) {
        switch self {
        case .highQuality: (0.9, 300, 6_000)
        case .balanced: (0.75, 150, 3_200)
        case .small: (0.55, 96, 2_000)
        }
    }
}

struct PDFCompressionResult: Sendable {
    let data: Data
    let originalBytes: Int
    let compressedBytes: Int
    let didReduce: Bool
}

/// Operates solely on a detached serialized document. Call from a worker task;
/// no live PDFView/document, native PDFium handle or destination file is touched.
/// Cancellation is checked around the synchronous Quartz call and between pages.
enum PDFCompressionService {
    private static let maximumBytes = 512 * 1_024 * 1_024
    private static let maximumPages = 10_000
    private static let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]

    private enum Failure: LocalizedError {
        case unreadable, protected, unsupported, tooLarge, validationFailed

        var errorDescription: String? {
            switch self {
            case .unreadable:
                L10n.string("compression.error.unreadable", defaultValue: "용량을 줄일 PDF를 읽지 못했습니다.")
            case .protected:
                L10n.string("compression.error.protected", defaultValue: "암호화되거나 디지털 서명된 PDF는 용량을 줄일 수 없습니다.")
            case .unsupported:
                L10n.string("compression.error.unsupported", defaultValue: "이 PDF의 특수 구조를 안전하게 유지할 수 없어 용량을 줄이지 않았습니다.")
            case .tooLarge:
                L10n.string("compression.error.too_large", defaultValue: "이 PDF는 현재 용량 줄이기 기능의 처리 한도를 초과합니다.")
            case .validationFailed:
                L10n.string("compression.error.validation_failed", defaultValue: "PDF의 내용과 편집 정보를 유지했는지 확인하지 못했습니다. 원본은 변경되지 않았습니다.")
            }
        }
    }

    /// Also call on the live document before taking dataRepresentation(): a
    /// snapshot may no longer retain its original encryption/signature status.
    static func validateSource(_ document: PDFDocument) throws {
        guard !document.isLocked, !document.isEncrypted else { throw Failure.protected }
        guard document.pageCount > 0 else { throw Failure.unreadable }
        guard document.pageCount <= maximumPages else { throw Failure.tooLarge }
        if let catalog = document.documentRef?.catalog {
            if object(catalog, "Perms") != nil { throw Failure.protected }
            // PDFKit's filtered rewrite does not promise preservation of these
            // structures. Refusing the operation preserves the original rather
            // than silently losing accessibility, attachments, or layer states.
            for key in ["StructTreeRoot", "Collection", "OCProperties", "AF", "Requirements"] {
                if object(catalog, key) != nil { throw Failure.unsupported }
            }
            if let names = dictionary(catalog, "Names") {
                for key in ["EmbeddedFiles", "JavaScript", "Renditions"] {
                    if object(names, key) != nil { throw Failure.unsupported }
                }
            }
            if let form = dictionary(catalog, "AcroForm") {
                if object(form, "XFA") != nil { throw Failure.unsupported }
                var remaining = 100_000
                try validateFields(array(form, "Fields"), depth: 0, remaining: &remaining)
            }
        }
        let supported: Set<String> = ["Text", "Link", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine",
            "Highlight", "Underline", "Squiggly", "StrikeOut", "Stamp", "Caret", "Ink", "Popup", "Widget"]
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw Failure.unreadable }
            for annotation in page.annotations {
                if annotation.type == "Widget",
                   annotation.widgetFieldType.rawValue == "Sig" || annotation.widgetFieldType.rawValue == "/Sig" {
                    throw Failure.protected
                }
                guard let type = annotation.type, supported.contains(type) else { throw Failure.unsupported }
            }
        }
    }

    static func compress(data: Data, quality: PDFCompressionQuality) throws -> PDFCompressionResult {
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        return try autoreleasepool {
            guard let source = PDFDocument(data: data) else { throw Failure.unreadable }
            try validateSource(source)
            // Quartz may replace an editable-only full sfnt with a subset
            // lacking OS/2. That loses both cold-edit permission and proven
            // glyph raster identity. A retained unused full resource would not
            // prove which program paints the result: keep the original bytes
            // whenever this bounded source scan finds such a program, or cannot
            // prove their absence. Other supported image compression is unchanged.
            do {
                if try EditableFontPrograms.containsEditableProgram(in: data) {
                    try Task.checkCancellation()
                    try PDFSaveCancellation.checkCurrent()
                    return PDFCompressionResult(data: data, originalBytes: data.count,
                        compressedBytes: data.count, didReduce: false)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                try PDFSaveCancellation.checkCurrent()
                return PDFCompressionResult(data: data, originalBytes: data.count,
                    compressedBytes: data.count, didReduce: false)
            }
            let settings = quality.settings
            let properties: [String: Any] = [
                "Domains": ["Applications": true], "FilterType": 1, "Name": "EmberPDF Image Compression",
                "FilterData": ["ColorSettings": ["ImageSettings": [
                    "Compression Quality": settings.quality,
                    "ImageCompression": "ImageJPEGCompress",
                    "ImageScaleSettings": [
                        "ImageResolution": settings.resolution, "ImageScaleInterpolate": true,
                        "ImageSizeMax": settings.maximumPixels, "ImageSizeMin": 0
                    ]
                ]]]
            ]
            guard let filter = QuartzFilter(properties: properties),
                  let writer = PDFDocument(data: data) else { throw Failure.unreadable }
            // Keep validation separate from PDFKit's mutable serialization state.
            try compressImageAppearances(in: writer, filter: filter)
            try Task.checkCancellation()
            guard let serialized = writer.dataRepresentation(options: [
                PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter
            ]) else { throw Failure.unreadable }
            // PDFKit's filtered serialization can omit /AcroForm even while
            // retaining widgets. Preserve canonical fields on form copies
            // before comparing byte counts or validating the final candidate.
            let candidate: Data
            if PDFCanonicalFormMaterializer.shouldMaterialize(source) {
                candidate = try PDFCanonicalFormMaterializer.materialize(serialized)
            } else { candidate = serialized }
            try Task.checkCancellation()
            // A smaller setting cannot make an already optimized document
            // smaller in every case. Never offer a larger replacement.
            guard candidate.count < data.count else {
                return PDFCompressionResult(data: data, originalBytes: data.count,
                    compressedBytes: data.count, didReduce: false)
            }
            guard let output = PDFDocument(data: candidate), !output.isLocked, !output.isEncrypted else {
                throw Failure.validationFailed
            }
            try validate(source: source, output: output)
            try Task.checkCancellation()
            return PDFCompressionResult(data: candidate, originalBytes: data.count,
                compressedBytes: candidate.count, didReduce: true)
        }
    }


    /// Negative-only preflight over the immutable input. No font is admitted,
    /// registered or decoded by CoreGraphics. Canonical raw handles bound cycles;
    /// only embedded sfnt payloads are read, never painting/image streams.
    private enum EditableFontPrograms {
        private static let maximumProgramBytes = 16 * 1_024 * 1_024
        private static let maximumProgramTotal = 32 * 1_024 * 1_024
        private static let maximumVisits = 250_000

        static func containsEditableProgram(in data: Data) throws -> Bool {
            try checkpoint()
            var status: Int32 = 0
            guard data.count <= 256 * 1_024 * 1_024,
                  let context = data.withUnsafeBytes({ bytes in
                      ember_raw_pdf_create(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          data.count, 256 * 1_024 * 1_024, 500_000, &status)
                  }) else { throw Failure.unsupported }
            defer { ember_raw_pdf_destroy(context) }
            try checked(status)
            var root: EmberRawPDFObject = 0
            try checked(ember_raw_pdf_catalog(context, &root))
            var pending: [(EmberRawPDFObject, Int)] = [(root, 0)]
            var seen = Set<EmberRawPDFObject>(), programs = Set<EmberRawPDFObject>()
            var programBytes = 0
            while let (object, depth) = pending.popLast() {
                try checkpoint()
                guard depth < 64 else { throw Failure.tooLarge }
                guard seen.insert(object).inserted else { continue }
                guard seen.count <= maximumVisits else { throw Failure.tooLarge }
                let kind = try kind(context, object)
                if kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue) {
                    var count: UInt32 = 0
                    try checked(ember_raw_pdf_array_count(context, object, &count))
                    guard Int(count) <= maximumVisits - pending.count else { throw Failure.tooLarge }
                    for index in 0..<count {
                        if index & 255 == 0 { try checkpoint() }
                        var member: EmberRawPDFObject = 0
                        try checked(ember_raw_pdf_array_item(context, object, index, &member))
                        pending.append((member, depth + 1))
                    }
                } else if kind == Int32(EMBER_RAW_PDF_DICTIONARY.rawValue)
                    || kind == Int32(EMBER_RAW_PDF_STREAM.rawValue) {
                    var dictionary = object
                    if kind == Int32(EMBER_RAW_PDF_STREAM.rawValue) {
                        try checked(ember_raw_pdf_stream_dictionary(context, object, &dictionary))
                    }
                    var count: UInt32 = 0
                    try checked(ember_raw_pdf_dictionary_count(context, dictionary, &count))
                    guard count <= 4_096, Int(count) <= maximumVisits - pending.count else { throw Failure.tooLarge }
                    for index in 0..<count {
                        if index & 255 == 0 { try checkpoint() }
                        var pointer: UnsafeMutablePointer<UInt8>?, size = 0
                        try checked(ember_raw_pdf_bounded_key_copy(context, dictionary, index, 4_096, &pointer, &size))
                        guard size > 0, size <= 4_096, let keyPointer = pointer else {
                            if let pointer { ember_raw_pdf_free(pointer) }
                            throw Failure.unsupported
                        }
                        let key = Data(bytes: keyPointer, count: size)
                        ember_raw_pdf_free(keyPointer)
                        let member = try value(context, dictionary, key)
                        if key == Data("/FontFile2".utf8) || key == Data("/FontFile3".utf8) {
                            guard programs.insert(member).inserted else { continue }
                            guard programs.count <= 64 else { throw Failure.tooLarge }
                            if try editableProgram(context, member, isFontFile3: key == Data("/FontFile3".utf8),
                                                   total: &programBytes) { return true }
                        } else { pending.append((member, depth + 1)) }
                    }
                }
            }
            try checkpoint()
            return false
        }

        private static func editableProgram(_ context: EmberRawPDFRef, _ object: EmberRawPDFObject,
                                            isFontFile3: Bool, total: inout Int) throws -> Bool {
            guard try kind(context, object) == Int32(EMBER_RAW_PDF_STREAM.rawValue) else { throw Failure.unsupported }
            var dictionary: EmberRawPDFObject = 0
            try checked(ember_raw_pdf_stream_dictionary(context, object, &dictionary))
            var cff = false
            if isFontFile3 {
                let subtype = try name(context, value(context, dictionary, Data("/Subtype".utf8)))
                cff = subtype == Data("/Type1C".utf8) || subtype == Data("/CIDFontType0C".utf8)
                guard cff || subtype == Data("/OpenType".utf8) else { throw Failure.unsupported }
            }
            for key in ["/F", "/FFilter", "/FDecodeParms", "/DecodeParms"] {
                guard try kind(context, value(context, dictionary, Data(key.utf8))) == Int32(EMBER_RAW_PDF_NULL.rawValue)
                else { throw Failure.unsupported }
            }
            let filter = try value(context, dictionary, Data("/Filter".utf8))
            let filterKind = try kind(context, filter)
            let flate: Bool
            if filterKind == Int32(EMBER_RAW_PDF_NULL.rawValue) { flate = false }
            else {
                guard try name(context, filter) == Data("/FlateDecode".utf8) else { throw Failure.unsupported }
                flate = true
            }
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = ember_raw_pdf_stream_copy(context, object, maximumProgramBytes, { _ in
                do { try Task.checkCancellation(); try PDFSaveCancellation.checkCurrent(); return 0 }
                catch { return 1 }
            }, nil, &pointer, &count)
            defer { if let pointer { ember_raw_pdf_free(pointer) } }
            try checked(status)
            guard count <= maximumProgramBytes, count == 0 || pointer != nil else { throw Failure.tooLarge }
            let encoded = pointer.map { Data(bytes: $0, count: count) } ?? Data()
            let program: Data
            if flate { program = try inflated(encoded) } else { program = encoded }
            guard program.count <= maximumProgramTotal - total else { throw Failure.tooLarge }
            total += program.count
            if cff, program.count >= 4, program[0] == 1, program[1] == 0,
               program[2] >= 4, Int(program[2]) <= program.count, (1...4).contains(program[3]) {
                // A real CFF1 header is not an sfnt and has no OS/2 table.
                return false
            }
            return try sfntIsEditable(program)
        }

        private static func sfntIsEditable(_ data: Data) throws -> Bool {
            guard data.count >= 12,
                  [[UInt8]([0, 1, 0, 0]), Array("true".utf8), Array("OTTO".utf8)]
                    .contains(Array(data.prefix(4))) else { throw Failure.unsupported }
            func u16(_ offset: Int) -> Int { Int(data[offset]) << 8 | Int(data[offset + 1]) }
            func u32(_ offset: Int) -> Int {
                Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
                    | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            }
            let count = u16(4)
            guard count > 0, count <= 128, 12 + count * 16 <= data.count else { throw Failure.unsupported }
            var tags = Set<Data>(), editable = false
            for index in 0..<count {
                let entry = 12 + index * 16, tag = data.subdata(in: entry..<(entry + 4))
                let offset = u32(entry + 8), length = u32(entry + 12)
                guard tags.insert(tag).inserted, offset <= data.count, length <= data.count - offset
                else { throw Failure.unsupported }
                if tag == Data("OS/2".utf8) {
                    guard length >= 10 else { throw Failure.unsupported }
                    editable = u16(offset + 8) & 0x0008 != 0
                }
            }
            return editable
        }

        private static func inflated(_ encoded: Data) throws -> Data {
            var stream = z_stream()
            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.unsupported }
            defer { inflateEnd(&stream) }
            return try encoded.withUnsafeBytes { input in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(input.count)
                var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    try checkpoint()
                    let before = stream.avail_in
                    let status = buffer.withUnsafeMutableBytes { output -> Int32 in
                        stream.next_out = output.baseAddress?.assumingMemoryBound(to: Bytef.self)
                        stream.avail_out = uInt(output.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    let made = buffer.count - Int(stream.avail_out)
                    guard made <= maximumProgramBytes - result.count else { throw Failure.tooLarge }
                    result.append(contentsOf: buffer.prefix(made))
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw Failure.unsupported }
                        return result
                    }
                    guard status == Z_OK, made > 0 || stream.avail_in < before else { throw Failure.unsupported }
                }
            }
        }

        private static func kind(_ context: EmberRawPDFRef, _ object: EmberRawPDFObject) throws -> Int32 {
            var result: Int32 = 0
            try checked(ember_raw_pdf_kind(context, object, &result))
            return result
        }
        private static func value(_ context: EmberRawPDFRef, _ dictionary: EmberRawPDFObject, _ key: Data) throws -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0
            try checked(key.withUnsafeBytes { bytes in
                ember_raw_pdf_dictionary_get(context, dictionary, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), key.count, &result)
            })
            return result
        }
        private static func name(_ context: EmberRawPDFRef, _ object: EmberRawPDFObject) throws -> Data {
            guard try kind(context, object) == Int32(EMBER_RAW_PDF_NAME.rawValue) else { throw Failure.unsupported }
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = ember_raw_pdf_bounded_scalar_copy(context, object, 64, &pointer, &count)
            defer { if let pointer { ember_raw_pdf_free(pointer) } }
            try checked(status)
            return pointer.map { Data(bytes: $0, count: count) } ?? Data()
        }
        private static func checkpoint() throws {
            try Task.checkCancellation()
            try PDFSaveCancellation.checkCurrent()
        }
        private static func checked(_ status: Int32) throws {
            if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }
            guard status == Int32(EMBER_RAW_PDF_OK.rawValue) else { throw Failure.unsupported }
        }
    }

    /// Quartz's document filter leaves existing /AP streams untouched. Filter
    /// only app-owned image stamps through a detached PDF appearance, preserving
    /// their annotation dictionaries and place in the mixed annotation stack.
    /// Drawing an appearance into PDF keeps its native paths and transparency;
    /// this does not rasterize a page or restore pixels removed by cropping.
    private static func compressImageAppearances(in document: PDFDocument, filter: QuartzFilter) throws {
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw Failure.unreadable }
            let original = page.annotations
            var changed = false
            let replacements = try original.map { annotation -> PDFAnnotation in
                guard ImageAnnotationIdentity.isEditableImage(annotation) else { return annotation }
                return try autoreleasepool {
                    try Task.checkCancellation()
                    let unfiltered = try appearanceData(annotation, filter: nil)
                    let filtered = try appearanceData(annotation, filter: filter)
                    guard filtered.count < unfiltered.count,
                          let provider = CGDataProvider(data: filtered as CFData),
                          let appearanceDocument = CGPDFDocument(provider),
                          let appearance = appearanceDocument.page(at: 1) else { return annotation }
                    changed = true
                    return CompressedImageAnnotation(copying: annotation, appearance: appearance)
                }
            }
            if changed {
                original.forEach(page.removeAnnotation)
                replacements.forEach(page.addAnnotation)
            }
        }
    }

    private static func appearanceData(_ annotation: PDFAnnotation, filter: QuartzFilter?) throws -> Data {
        var bounds = annotation.bounds
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0, bounds.width < 100_000, bounds.height < 100_000 else {
            throw Failure.unsupported
        }
        let storage = NSMutableData()
        guard let consumer = CGDataConsumer(data: storage),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw Failure.unreadable }
        context.beginPDFPage(nil)
        if let filter, !filter.apply(to: context) { throw Failure.unreadable }
        // This detached appearance uses the annotation's raw page bounds.
        // PDFAnnotation.draw expects a display-box context and applies the
        // page transform itself, so cancel that transform for this direct call.
        // Detaching/reassigning annotation.page here would mutate PDFKit state.
        if let page = annotation.page { context.concatenate(page.transform(for: .mediaBox).inverted()) }
        annotation.draw(with: .mediaBox, in: context)
        filter?.remove(from: context)
        context.endPDFPage()
        context.closePDF()
        guard storage.length <= maximumBytes else { throw Failure.tooLarge }
        return storage as Data
    }

    private final class CompressedImageAnnotation: PDFAnnotation {
        private let appearance: CGPDFPage

        init(copying source: PDFAnnotation, appearance: CGPDFPage) {
            self.appearance = appearance
            var properties = source.annotationKeyValues
            for key in ["/AP", "/P", "/Parent"] { properties.removeValue(forKey: key) }
            super.init(bounds: source.bounds, forType: .stamp, withProperties: properties)
            userName = source.userName
            if source.value(forAnnotationKey: .color) != nil { color = source.color }
            else { removeValue(forAnnotationKey: .color) }
        }

        required init?(coder: NSCoder) { nil }

        override func draw(with box: PDFDisplayBox, in context: CGContext) {
            context.saveGState()
            defer { context.restoreGState() }
            if let page { context.concatenate(page.transform(for: box)) }
            context.clip(to: bounds)
            let source = appearance.getBoxRect(.mediaBox)
            guard source.width > 0, source.height > 0 else { return }
            // Keep a compressed image editable: subsequent moves/resizes must
            // map the original appearance bounds to its current rectangle.
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: bounds.width / source.width, y: bounds.height / source.height)
            context.translateBy(x: -source.minX, y: -source.minY)
            context.drawPDFPage(appearance)
        }

        override func copy(with zone: NSZone? = nil) -> Any {
            CompressedImageAnnotation(copying: self, appearance: appearance)
        }
    }

    private static func validate(source: PDFDocument, output: PDFDocument) throws {
        guard source.pageCount == output.pageCount else { throw Failure.validationFailed }
        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let before = source.page(at: index), let after = output.page(at: index),
                      before.rotation == after.rotation, before.string == after.string,
                      before.label == after.label,
                      before.annotations.count == after.annotations.count else { throw Failure.validationFailed }
                for box in boxes {
                    guard equal(before.bounds(for: box), after.bounds(for: box)) else { throw Failure.validationFailed }
                }
                for (first, second) in zip(before.annotations, after.annotations) {
                    try validate(annotation: first, against: second, source: source, output: output)
                }
            }
        }
        var remaining = 100_000
        try validate(outline: source.outlineRoot, against: output.outlineRoot,
            source: source, output: output, depth: 0, remaining: &remaining)
        for key: PDFDocumentAttribute in [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute] {
            let lhs = source.documentAttributes?[key] as? NSObject
            let rhs = output.documentAttributes?[key] as? NSObject
            guard lhs == rhs else { throw Failure.validationFailed }
        }
    }

    private static func validate(annotation first: PDFAnnotation, against second: PDFAnnotation,
                                 source: PDFDocument, output: PDFDocument) throws {
        guard first.type == second.type, equal(first.bounds, second.bounds),
              first.contents == second.contents, first.userName == second.userName, first.shouldDisplay == second.shouldDisplay,
              first.shouldPrint == second.shouldPrint, first.isReadOnly == second.isReadOnly,
              first.widgetFieldType == second.widgetFieldType, first.fieldName == second.fieldName,
              first.widgetStringValue == second.widgetStringValue,
              first.buttonWidgetState == second.buttonWidgetState,
              first.buttonWidgetStateString == second.buttonWidgetStateString,
              first.choices == second.choices, first.values == second.values,
              first.isMultiline == second.isMultiline, first.maximumLength == second.maximumLength,
              first.hasComb == second.hasComb, first.alignment == second.alignment,
              first.url == second.url,
              colorsEqual(first.value(forAnnotationKey: .color) == nil ? nil : first.color,
                          second.value(forAnnotationKey: .color) == nil ? nil : second.color), colorsEqual(first.fontColor, second.fontColor),
              colorsEqual(first.interiorColor, second.interiorColor) else { throw Failure.validationFailed }
        // These preserve mark-up geometry, widget behavior/defaults, annotation
        // identity, custom editing provenance and additional action dictionaries.
        for key in ["/NM", "/F", "/Ff", "/QuadPoints", "/InkList", "/L", "/LE", "/Vertices",
                    "/DV", "/Opt", "/MaxLen", "/AS", "/TU", "/AA", "/RC", "/DS", "/IT", "/RT", "/DA", "/HwattakPDFKind"] {
            let lhs = first.value(forAnnotationKey: PDFAnnotationKey(rawValue: key)) as? NSObject
            let rhs = second.value(forAnnotationKey: PDFAnnotationKey(rawValue: key)) as? NSObject
            guard lhs == rhs else { throw Failure.validationFailed }
        }
        guard approximately(first.border?.lineWidth ?? 0, second.border?.lineWidth ?? 0),
              first.border?.style == second.border?.style,
              (first.border?.dashPattern as NSArray?) == (second.border?.dashPattern as NSArray?) else { throw Failure.validationFailed }
        try validate(action: first.action, against: second.action, source: source, output: output)
        try validate(destination: first.destination, against: second.destination, source: source, output: output)
    }

    private static func validate(outline first: PDFOutline?, against second: PDFOutline?, source: PDFDocument,
                                 output: PDFDocument, depth: Int, remaining: inout Int) throws {
        guard depth < 64, remaining > 0 else { throw Failure.tooLarge }
        remaining -= 1
        guard (first == nil) == (second == nil) else { throw Failure.validationFailed }
        guard let first, let second else { return }
        guard first.label == second.label, first.numberOfChildren == second.numberOfChildren,
              first.isOpen == second.isOpen else { throw Failure.validationFailed }
        try validate(action: first.action, against: second.action, source: source, output: output)
        try validate(destination: first.destination, against: second.destination, source: source, output: output)
        for index in 0..<first.numberOfChildren {
            try validate(outline: first.child(at: index), against: second.child(at: index),
                source: source, output: output, depth: depth + 1, remaining: &remaining)
        }
    }

    private static func validate(action first: PDFAction?, against second: PDFAction?,
                                 source: PDFDocument, output: PDFDocument) throws {
        guard (first == nil) == (second == nil), first?.type == second?.type else { throw Failure.validationFailed }
        guard let first, let second else { return }
        switch (first, second) {
        case let (lhs as PDFActionGoTo, rhs as PDFActionGoTo):
            try validate(destination: lhs.destination, against: rhs.destination, source: source, output: output)
        case let (lhs as PDFActionURL, rhs as PDFActionURL):
            guard lhs.url == rhs.url else { throw Failure.validationFailed }
        case let (lhs as PDFActionNamed, rhs as PDFActionNamed):
            guard lhs.name == rhs.name else { throw Failure.validationFailed }
        case let (lhs as PDFActionRemoteGoTo, rhs as PDFActionRemoteGoTo):
            guard lhs.url == rhs.url, lhs.pageIndex == rhs.pageIndex, lhs.point == rhs.point else { throw Failure.validationFailed }
        case let (lhs as PDFActionResetForm, rhs as PDFActionResetForm):
            guard lhs.fields == rhs.fields, lhs.fieldsIncludedAreCleared == rhs.fieldsIncludedAreCleared else { throw Failure.validationFailed }
        default: throw Failure.unsupported
        }
    }

    private static func validate(destination first: PDFDestination?, against second: PDFDestination?,
                                 source: PDFDocument, output: PDFDocument) throws {
        guard (first == nil) == (second == nil) else { throw Failure.validationFailed }
        guard let first, let second else { return }
        guard first.page.map(source.index(for:)) == second.page.map(output.index(for:)),
              first.point == second.point,
              approximately(first.zoom, second.zoom) else { throw Failure.validationFailed }
    }

    private static func colorsEqual(_ first: NSColor?, _ second: NSColor?) -> Bool {
        guard (first == nil) == (second == nil) else { return false }
        guard let first, let second else { return true }
        guard let lhs = first.usingColorSpace(.sRGB), let rhs = second.usingColorSpace(.sRGB) else { return first == second }
        return zip([lhs.redComponent, lhs.greenComponent, lhs.blueComponent, lhs.alphaComponent],
            [rhs.redComponent, rhs.greenComponent, rhs.blueComponent, rhs.alphaComponent])
            .allSatisfy { abs($0 - $1) <= 0.002 }
    }

    private static func equal(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        approximately(lhs.minX, rhs.minX) && approximately(lhs.minY, rhs.minY)
            && approximately(lhs.width, rhs.width) && approximately(lhs.height, rhs.height)
    }

    private static func approximately(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        lhs == rhs || (lhs.isFinite && rhs.isFinite && abs(lhs - rhs) < 0.001)
    }

    private static func validateFields(_ fields: CGPDFArrayRef?, depth: Int, remaining: inout Int) throws {
        guard depth < 64 else { throw Failure.tooLarge }
        guard let fields else { return }
        for index in 0..<CGPDFArrayGetCount(fields) {
            remaining -= 1
            guard remaining > 0 else { throw Failure.tooLarge }
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(fields, index, &field), let field else { throw Failure.unreadable }
            var type: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(field, "FT", &type), let type, String(cString: type) == "Sig" {
                throw Failure.protected
            }
            if let value = dictionary(field, "V"), object(value, "ByteRange") != nil { throw Failure.protected }
            try validateFields(array(field, "Kids"), depth: depth + 1, remaining: &remaining)
        }
    }

    private static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var result: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &result) ? result : nil
    }
    private static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var result: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(dictionary, key, &result) ? result : nil
    }
    private static func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var result: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary, key, &result) ? result : nil
    }
}
