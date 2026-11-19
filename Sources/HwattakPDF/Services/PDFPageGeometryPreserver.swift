// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Geometry is captured separately from PDFKit's display getters and its
/// rounded, origin-normalized serialization. No appearance stream is copied.
enum PDFPageGeometryPreserver {
    static let boxes: [(String, PDFDisplayBox)] = [
        ("MediaBox", .mediaBox), ("CropBox", .cropBox), ("BleedBox", .bleedBox),
        ("TrimBox", .trimBox), ("ArtBox", .artBox)
    ]
    static let coordinateKeys = ["L", "QuadPoints", "Vertices", "InkList", "CL"]
    private static let maximumNumbers = 1_000_000

    struct PageGeometry {
        let raw: [String: PDFCatalogGraphValue]
        let baseline: [CGRect]
        let originalRotation: Int
        let rawRotation: PDFCatalogGraphValue?
        let reference: CGPDFPage
        let rawIsAuthoritative: Bool

        func resolved(for page: PDFPage, rawSources: [PDFRawStreamSource] = []) throws -> [String: PDFCatalogGraphValue] {
            let live = PDFPageGeometryPreserver.boxes.map { page.bounds(for: $0.1) }
            guard live.allSatisfy(PDFPageGeometryPreserver.valid) else { throw Failure.invalidGeometry }
            // A later crop/resize is an explicit live edit. Never restore an
            // old box merely because its painting still has source provenance.
            var result = live == baseline ? raw : Dictionary(uniqueKeysWithValues:
                zip(PDFPageGeometryPreserver.boxes.map(\.0), live).map {
                    ($0.0, PDFCatalogGraphValue.array(PDFPageGeometryPreserver.numbers($0.1).map(PDFCatalogGraphValue.real)))
                })
            if live == baseline, rawIsAuthoritative {
                for source in rawSources {
                    if let original = try source.originalPageGeometry(for: reference) {
                        result = original
                        break
                    }
                }
            }
            guard page.rotation % 90 == 0 else { throw Failure.invalidGeometry }
            if ((page.rotation % 360) + 360) % 360 == originalRotation {
                if result["Rotate"] == nil, let rawRotation { result["Rotate"] = rawRotation }
            } else { result["Rotate"] = .integer(page.rotation) }
            return result
        }
    }

    indirect enum Numbers: Hashable {
        case value(Double), array([Numbers])
        var graphValue: PDFCatalogGraphValue {
            switch self {
            case .value(let value): return .real(value)
            case .array(let values): return .array(values.map(\.graphValue))
            }
        }
    }

    struct AnnotationGeometry: Equatable {
        let rectangle: [Double]
        let coordinates: [String: Numbers]
        var entries: [String: PDFCatalogGraphValue] {
            var values = coordinates.mapValues(\.graphValue)
            values["Rect"] = .array(rectangle.map(PDFCatalogGraphValue.real))
            return values
        }
        var numberCount: Int {
            func count(_ value: Numbers) -> Int {
                switch value { case .value: return 1; case .array(let values): return values.reduce(0) { $0 + count($1) } }
            }
            return 4 + coordinates.values.reduce(0) { $0 + count($1) }
        }
    }

    enum Failure: Error { case invalidGeometry, tooComplex }

    /// The native graph is already owned by catalog provenance. Only ten
    /// rectangles are retained per page; no PDF/image/font bytes are allocated.
    static func capture(_ page: PDFPage, reference: CGPDFPage) throws -> PageGeometry {
        guard let dictionary = reference.dictionary else { throw Failure.invalidGeometry }
        let media = try rawBox(dictionary, name: "MediaBox")
        let raw = try boxes.map { try rawBox(dictionary, name: $0.0) }
        let live = boxes.map { page.bounds(for: $0.1) }
        guard live.allSatisfy(valid) else { throw Failure.invalidGeometry }
        let mediaRect = try rectangle(media)
        // PDFPage.h specifies that bounds(for:) intersects every box with
        // MediaBox. This distinguishes original print boxes from clamped UI
        // bounds, without eagerly opening every page at document startup.
        let originalDisplay = try raw.map { try rectangle($0).intersection(mediaRect) }
        var authoritative: [String: PDFCatalogGraphValue] = [:]
        for (index, box) in boxes.enumerated() {
            if originalDisplay == live {
                // Keep the actual numeric array objects. Reconstructing a
                // maxY from minY+height can change485.4 by one ULP and alter
                // an image resampler across a whole scanned page.
                if let value = try inheritedBoxObject(dictionary, name: box.0) { authoritative[box.0] = .original(value) }
            } else { authoritative[box.0] = .array(numbers(live[index]).map(PDFCatalogGraphValue.real)) }
        }
        var rawRotation: PDFCatalogGraphValue?, rotation = 0
        if let value = try inheritedBoxObject(dictionary, name: "Rotate") {
            var number: CGPDFInteger = 0
            guard CGPDFObjectGetValue(value, .integer, &number), number % 90 == 0 else { throw Failure.invalidGeometry }
            rotation = ((Int(number) % 360) + 360) % 360; rawRotation = .original(value)
        }
        return PageGeometry(raw: authoritative, baseline: live, originalRotation: rotation,
            rawRotation: rawRotation, reference: reference, rawIsAuthoritative: originalDisplay == live)
    }

    static func current(_ page: PDFPage) throws -> [[Double]] {
        let bounds = boxes.map { page.bounds(for: $0.1) }
        guard bounds.allSatisfy(valid) else { throw Failure.invalidGeometry }
        return bounds.map(numbers)
    }

    static func liveAnnotation(_ annotation: PDFAnnotation) throws -> AnnotationGeometry {
        guard numbers(annotation.bounds).allSatisfy({ $0.isFinite && abs($0) < 1_000_000_000 }) else { throw Failure.invalidGeometry }
        var coordinates: [String: Numbers] = [:], budget = maximumNumbers
        for key in coordinateKeys {
            guard let value = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/" + key)) else { continue }
            let parsed: Numbers
            if key == "QuadPoints", let points = value as? [NSValue], !points.isEmpty,
               points.allSatisfy({ !($0 is NSNumber) }) {
                // The raw accessor returns PAGE-space NSValue points for
                // loaded markup and convenience setters. Its convenience
                // quadrilateralPoints property instead returns LOCAL points.
                let pointType = String(cString: NSValue(point: .zero).objCType)
                var values: [Numbers] = []
                for point in points {
                    guard String(cString: point.objCType) == pointType else { throw Failure.invalidGeometry }
                    try append(point.pointValue, to: &values, budget: &budget)
                }
                parsed = .array(values)
            } else if key == "InkList", let paths = value as? [NSBezierPath] {
                // PDFKit's raw InkList accessor is the exception: its paths
                // are annotation-local. Its serializer writes endpoints in
                // page space, including the endpoint of a curve; the complete
                // curve appearance remains in the unchanged AP stream.
                var strokes: [Numbers] = []
                for path in paths {
                    guard path.elementCount <= budget / 2 else { throw Failure.tooComplex }
                    var values: [Numbers] = [], points = [CGPoint](repeating: .zero, count: 3)
                    for index in 0..<path.elementCount {
                        let element = path.element(at: index, associatedPoints: &points)
                        let point: CGPoint
                        switch element {
                        case .moveTo, .lineTo: point = points[0]
                        case .cubicCurveTo: point = points[2]
                        case .quadraticCurveTo: point = points[1]
                        case .closePath: continue
                        @unknown default: throw Failure.invalidGeometry
                        }
                        try append(CGPoint(x: annotation.bounds.minX + point.x,
                            y: annotation.bounds.minY + point.y), to: &values, budget: &budget)
                    }
                    strokes.append(.array(values))
                }
                parsed = .array(strokes)
            } else { parsed = try parse(value, budget: &budget, depth: 0) }
            try validate(parsed, key: key)
            coordinates[key] = parsed
        }
        return AnnotationGeometry(rectangle: numbers(annotation.bounds), coordinates: coordinates)
    }

    static func rawAnnotation(_ dictionary: CGPDFDictionaryRef) throws -> AnnotationGeometry {
        guard let rect = object(dictionary, "Rect") else { throw Failure.invalidGeometry }
        var budget = maximumNumbers
        let parsed = try parse(rect, budget: &budget, depth: 0)
        let rectangle = try flat(parsed)
        guard rectangle.count == 4 else { throw Failure.invalidGeometry }
        var coordinates: [String: Numbers] = [:]
        for key in coordinateKeys {
            guard let value = object(dictionary, key) else { continue }
            let parsed = try parse(value, budget: &budget, depth: 0)
            try validate(parsed, key: key)
            coordinates[key] = parsed
        }
        return AnnotationGeometry(rectangle: rectangle, coordinates: coordinates)
    }

    /// Current values win after any coordinate edit; untouched annotations may
    /// retain their exact original arrays, including sub-float precision.
    static func annotation(_ live: PDFAnnotation, original: AnnotationGeometry?, baseline: AnnotationGeometry?) throws -> AnnotationGeometry {
        annotation(try liveAnnotation(live), original: original, baseline: baseline)
    }
    static func annotation(_ current: AnnotationGeometry, original: AnnotationGeometry?, baseline: AnnotationGeometry?) -> AnnotationGeometry {
        annotationSelection(current, original: original, baseline: baseline).chosen
    }
    struct AnnotationGeometrySelection {
        let current: AnnotationGeometry
        let chosen: AnnotationGeometry
    }
    static func annotationSelection(_ current: AnnotationGeometry, original: AnnotationGeometry?,
                                    baseline: AnnotationGeometry?) -> AnnotationGeometrySelection {
        if let baseline, current == baseline {
            return AnnotationGeometrySelection(current: baseline, chosen: original ?? current)
        }
        return AnnotationGeometrySelection(current: current, chosen: current)
    }

    fileprivate final class AnnotationNameGeometryWitness {
        weak var annotation: PDFAnnotation?
        let current: AnnotationGeometry
        let chosen: AnnotationGeometry
        let subtype: String
        init(annotation: PDFAnnotation, current: AnnotationGeometry, chosen: AnnotationGeometry, subtype: String) {
            self.annotation = annotation; self.current = current; self.chosen = chosen; self.subtype = subtype
        }
    }
    struct AnnotationName {
        let current: String?
        let originalDecoded: String?
        let originalWasNull: Bool
        let value: PDFCatalogGraphValue?
        fileprivate let geometryWitness: AnnotationNameGeometryWitness
    }
    struct MissingNameProof {
        fileprivate let live: ObjectIdentifier
        fileprivate let staged: UInt
    }
    private struct InkNameIdentity: Hashable {
        let rectangle: [Double]
        let ink: Numbers
        let contents: Data?
    }
    private struct OrdinaryNameCoordinate: Hashable { let key: String; let value: Numbers }
    private struct OrdinaryNameIdentity: Hashable {
        let subtype: String
        let rectangle: [Double]
        let coordinates: [OrdinaryNameCoordinate]
        let contents: Data?
    }
    private static let maximumIdentityStringBytes = 65_536

    /// Bound NSString's UTF-16 length and its UTF-8 budget before bridging or
    /// retaining a potentially edited scalar returned by the SDK.
    private static func publicIdentityText(_ value: Any?, remainingBytes: inout Int) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? NSString else { throw Failure.invalidGeometry }
        guard text.length <= maximumIdentityStringBytes else { throw Failure.tooComplex }
        let count = text.lengthOfBytes(using: String.Encoding.utf8.rawValue)
        guard count <= maximumIdentityStringBytes, count <= remainingBytes / 6 else { throw Failure.tooComplex }
        remainingBytes -= count * 6
        guard let data = text.data(using: String.Encoding.utf8.rawValue, allowLossyConversion: false),
              data.count == count, let result = String(data: data, encoding: .utf8) else { throw Failure.invalidGeometry }
        return result
    }

    private static func identityText(_ value: String, remainingBytes: inout Int) throws -> String {
        let count = value.utf8.prefix(maximumIdentityStringBytes + 1).count
        guard count <= maximumIdentityStringBytes, count <= remainingBytes / 6 else { throw Failure.tooComplex }
        remainingBytes -= count * 6
        return value
    }
    private static func nativeIdentityText(_ dictionary: CGPDFDictionaryRef, key: String,
                                           remainingBytes: inout Int) throws -> String? {
        guard let value = object(dictionary, key) else { return nil }
        if CGPDFObjectGetType(value) == .null { return nil }
        var string: CGPDFStringRef?
        guard CGPDFObjectGetValue(value, .string, &string), let string else { throw Failure.invalidGeometry }
        let count = CGPDFStringGetLength(string)
        guard count <= maximumIdentityStringBytes, count <= remainingBytes / 6 else { throw Failure.tooComplex }
        remainingBytes -= count * 6
        guard let decoded = CGPDFStringCopyTextString(string) else { throw Failure.invalidGeometry }
        return try identityText(decoded as String, remainingBytes: &remainingBytes)
    }
    /// The catalog caller supplies either an immutable exact AnnotationOrigin or
    /// a proven page for CURRENT non-Ink names. No unbound copy gains authority.
    static func annotationName(_ live: PDFAnnotation, original: CGPDFDictionaryRef?,
                               currentGeometry: AnnotationGeometry, chosenGeometry: AnnotationGeometry,
                               remainingBytes: inout Int, remainingCurrentCoordinates: inout Int) throws -> AnnotationName? {
        guard let currentSubtype = live.type, !currentSubtype.isEmpty,
              currentSubtype.utf8.prefix(65).count <= 64 else { throw Failure.invalidGeometry }
        // A new non-Ink annotation can prove only its CURRENT scalar name on
        // an already proven page. Ink retains its existing original-only path.
        if original == nil, currentSubtype == "Ink" { return nil }
        if let original {
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(original, "Subtype", &subtype), let subtype,
                  strnlen(subtype, 65) <= 64 else { throw Failure.invalidGeometry }
            if String(cString: subtype) != currentSubtype {
                // Extraction intentionally turns a signature Widget into an
                // inactive Stamp. When neither side has NM, there is no name
                // to preserve or repair. This grants no name override/proof.
                var fieldType: UnsafePointer<CChar>?
                guard String(cString: subtype) == "Widget", currentSubtype == "Stamp",
                      CGPDFDictionaryGetName(original, "FT", &fieldType), let fieldType,
                      strnlen(fieldType, 4) == 3, strcmp(fieldType, "Sig") == 0,
                      object(original, "NM") == nil,
                      ["/NM", "/FT", "/T", "/V"].allSatisfy({
                          live.value(forAnnotationKey: PDFAnnotationKey(rawValue: $0)) == nil
                      }) else { throw Failure.invalidGeometry }
                return nil
            }
        }
        let native = original.flatMap { object($0, "NM") }
        let originalWasNull = native.map { CGPDFObjectGetType($0) == .null } ?? false
        let originalDecoded = try original.flatMap { try nativeIdentityText($0, key: "NM", remainingBytes: &remainingBytes) }
        let raw = live.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
        // An originally unnamed annotation with no current name keeps its existing
        // path. It gains neither a drop override nor fallback authority.
        if native == nil, raw == nil || raw is NSNull { return nil }
        try PDFSaveCancellation.checkCurrent()
        // The chosen program already belongs to the graph's coordinate budget.
        // Retained current/chosen values share the existing baseline/output
        // arrays; count the extra witness metadata and current-coordinate work
        // before retaining either program in the weak-instance witness.
        let currentCoordinates = currentGeometry.numberCount
        guard remainingBytes >= 384, currentCoordinates <= remainingCurrentCoordinates else { throw Failure.tooComplex }
        remainingBytes -= 384; remainingCurrentCoordinates -= currentCoordinates
        let current = try publicIdentityText(raw, remainingBytes: &remainingBytes)
        let value: PDFCatalogGraphValue?
        if let current {
            if let originalDecoded, current.utf8.elementsEqual(originalDecoded.utf8), let native { value = .original(native) }
            else {
                guard let encoded = current.data(using: .utf16BigEndian) else { throw Failure.invalidGeometry }
                var bytes = Data([0xFE, 0xFF]); bytes.append(encoded); value = .string(bytes)
            }
        } else if originalWasNull, let native { value = .original(native) }
        else { value = nil }
        try PDFSaveCancellation.checkCurrent()
        return AnnotationName(current: current, originalDecoded: originalDecoded,
                              originalWasNull: originalWasNull, value: value,
                              geometryWitness: AnnotationNameGeometryWitness(annotation: live,
                                  current: currentGeometry, chosen: chosenGeometry, subtype: currentSubtype))
    }

    /// Missing names are repaired only after an exact, NM-independent bijection
    /// among this page's current/staged programs. Reordered or duplicate
    /// candidates are rejected; annotation indices and OBJR policy stay intact.
    static func missingNameProofs(staged: CGPDFArrayRef?, live: [PDFAnnotation],
                                  names: [Int: AnnotationName], geometries: [Int: AnnotationGeometry], remainingBytes: inout Int,
                                  remainingNumbers: inout Int,
                                  alternateStagedReader: PDFStagedInkGeometryReader? = nil,
                                  stagedPageIndex: Int? = nil) throws -> [Int: MissingNameProof] {
        guard !names.isEmpty else { return [:] }
        guard live.count <= 100_000, (staged.map(CGPDFArrayGetCount) ?? 0) == live.count else { throw Failure.tooComplex }
        var candidates = Set<Int>()
        for (index, name) in names {
            try PDFSaveCancellation.checkCurrent()
            guard live.indices.contains(index), let staged else { throw Failure.invalidGeometry }
            let witness = name.geometryWitness
            guard witness.annotation === live[index], live[index].type == witness.subtype,
                  try liveAnnotation(live[index]) == witness.current,
                  geometries[index] == witness.chosen else { throw Failure.invalidGeometry }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(staged, index, &dictionary), let dictionary else { throw Failure.invalidGeometry }
            let raw = object(dictionary, "NM")
            let publicValue = live[index].value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
            let observed = try publicIdentityText(publicValue, remainingBytes: &remainingBytes)
            if let current = name.current {
                guard let observed, observed.utf8.elementsEqual(current.utf8) else { throw Failure.invalidGeometry }
                if raw == nil { candidates.insert(index) }
                else {
                    let saved = try nativeIdentityText(dictionary, key: "NM", remainingBytes: &remainingBytes)
                    guard let saved, saved.utf8.elementsEqual(current.utf8) else { throw Failure.invalidGeometry }
                }
            } else {
                guard publicValue == nil || publicValue is NSNull else { throw Failure.invalidGeometry }
                if let raw {
                    if CGPDFObjectGetType(raw) == .null, name.originalWasNull { continue }
                    let saved = try nativeIdentityText(dictionary, key: "NM", remainingBytes: &remainingBytes)
                    guard let original = name.originalDecoded, let saved,
                          saved.utf8.elementsEqual(original.utf8) else { throw Failure.invalidGeometry }
                    candidates.insert(index)
                }
            }
        }
        guard !candidates.isEmpty else { return [:] }
        let ordinaryCandidates = Set(candidates.filter { live[$0].type != "Ink" })
        let ordinaryProofs = try ordinaryMissingNameProofs(staged: staged, live: live, names: names,
            candidates: ordinaryCandidates, geometries: geometries, remainingBytes: &remainingBytes, remainingNumbers: &remainingNumbers)
        candidates.subtract(ordinaryCandidates)
        guard !candidates.isEmpty else { return ordinaryProofs }
        var current: [InkNameIdentity: [Int]] = [:], saved: [InkNameIdentity: [Int]] = [:]
        var currentKeys: [Int: InkNameIdentity] = [:]
        var savedDictionaries: [Int: CGPDFDictionaryRef] = [:]
        func identity(_ geometry: AnnotationGeometry, contents: String?) throws -> InkNameIdentity {
            guard geometry.coordinates.count == 1, let ink = geometry.coordinates["InkList"],
                  geometry.numberCount <= remainingNumbers else { throw Failure.invalidGeometry }
            remainingNumbers -= geometry.numberCount
            guard remainingBytes >= 128 else { throw Failure.tooComplex }; remainingBytes -= 128
            return InkNameIdentity(rectangle: geometry.rectangle, ink: ink, contents: contents.map { Data($0.utf8) })
        }
        for (index, annotation) in live.enumerated() {
            try PDFSaveCancellation.checkCurrent()
            guard let staged else { throw Failure.invalidGeometry }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(staged, index, &dictionary), let dictionary else { throw Failure.invalidGeometry }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  strnlen(subtype, 65) <= 64 else { throw Failure.invalidGeometry }
            let savedType = String(cString: subtype)
            if annotation.type == "Ink" {
                let text = try annotation.contents.map { try identityText($0, remainingBytes: &remainingBytes) }
                // Only a source-authorized name can use the exact same program
                // the graph writer selected. Other Ink keeps the existing live
                // identity path; all staged programs still compare exactly.
                let geometry = try names[index]?.geometryWitness.chosen ?? liveAnnotation(annotation)
                let key = try identity(geometry, contents: text)
                current[key, default: []].append(index); currentKeys[index] = key
            }
            if savedType == "Ink" {
                let text = try nativeIdentityText(dictionary, key: "Contents", remainingBytes: &remainingBytes)
                let key = try identity(rawAnnotation(dictionary), contents: text)
                saved[key, default: []].append(index); savedDictionaries[index] = dictionary
            }
        }
        // The normal CoreGraphics proof is always first. Never combine values
        // from two parsers, or use an alternative to disambiguate current Ink.
        for index in candidates {
            guard let key = currentKeys[index], current[key] == [index] else { throw Failure.invalidGeometry }
            // A positive CG match at another slot (or a duplicate match) is
            // contradictory evidence, not a numeric-reader disagreement.
            if let indices = saved[key], indices != [index] { throw Failure.invalidGeometry }
        }
        let nativeMatches = candidates.allSatisfy { index in
            guard let key = currentKeys[index] else { return false }
            return saved[key] == [index]
        }
        if !nativeMatches {
            guard let alternateStagedReader, let stagedPageIndex else { throw Failure.invalidGeometry }
            let programs = try alternateStagedReader.geometries(onPage: stagedPageIndex, annotations: staged)
            guard Set(programs.keys) == Set(savedDictionaries.keys) else { throw Failure.invalidGeometry }
            var alternate: [InkNameIdentity: [Int]] = [:]
            for index in savedDictionaries.keys.sorted() {
                try PDFSaveCancellation.checkCurrent()
                guard let program = programs[index], let dictionary = savedDictionaries[index] else { throw Failure.invalidGeometry }
                let text = try nativeIdentityText(dictionary, key: "Contents", remainingBytes: &remainingBytes)
                let key = try identity(program, contents: text)
                alternate[key, default: []].append(index)
            }
            saved = alternate
        }
        var result = ordinaryProofs
        for index in candidates {
            try PDFSaveCancellation.checkCurrent()
            guard let key = currentKeys[index], current[key] == [index], saved[key] == [index],
                  let dictionary = savedDictionaries[index] else { throw Failure.invalidGeometry }
            result[index] = MissingNameProof(live: ObjectIdentifier(live[index]), staged: pdfReferenceIdentity(dictionary))
        }
        try PDFSaveCancellation.checkCurrent()
        return result
    }

    /// Only scalar NM repair uses this proof. It grants no annotation-origin,
    /// tag/OBJR, appearance, relationship, field-value or default authority.
    private static func ordinaryMissingNameProofs(staged: CGPDFArrayRef?, live: [PDFAnnotation],
        names: [Int: AnnotationName], candidates: Set<Int>, geometries: [Int: AnnotationGeometry], remainingBytes: inout Int,
        remainingNumbers: inout Int) throws -> [Int: MissingNameProof] {
        guard !candidates.isEmpty else { return [:] }
        guard let staged, CGPDFArrayGetCount(staged) == live.count else { throw Failure.invalidGeometry }
        var current: [OrdinaryNameIdentity: [Int]] = [:], saved: [OrdinaryNameIdentity: [Int]] = [:]
        var keys: [Int: OrdinaryNameIdentity] = [:], dictionaries: [Int: CGPDFDictionaryRef] = [:]
        var dictionaryIDs = Set<UInt>()
        func identity(_ subtype: String, _ geometry: AnnotationGeometry, _ contents: String?) throws -> OrdinaryNameIdentity {
            let count = geometry.numberCount
            let cost = 192 + geometry.coordinates.count * 32
            guard count <= remainingNumbers, cost <= remainingBytes else { throw Failure.tooComplex }
            remainingNumbers -= count; remainingBytes -= cost
            let coordinates = geometry.coordinates.keys.sorted().map { OrdinaryNameCoordinate(key: $0, value: geometry.coordinates[$0]!) }
            return OrdinaryNameIdentity(subtype: subtype, rectangle: geometry.rectangle,
                coordinates: coordinates, contents: contents.map { Data($0.utf8) })
        }
        for (index, annotation) in live.enumerated() {
            try PDFSaveCancellation.checkCurrent()
            var dictionary: CGPDFDictionaryRef?, rawSubtype: UnsafePointer<CChar>?
            guard CGPDFArrayGetDictionary(staged, index, &dictionary), let dictionary,
                  dictionaryIDs.insert(pdfReferenceIdentity(dictionary)).inserted,
                  CGPDFDictionaryGetName(dictionary, "Subtype", &rawSubtype), let rawSubtype,
                  strnlen(rawSubtype, 65) <= 64 else { throw Failure.invalidGeometry }
            let savedSubtype = String(cString: rawSubtype)
            if annotation.type != "Ink" {
                guard let subtype = annotation.type, !subtype.isEmpty, subtype.utf8.prefix(65).count <= 64 else { throw Failure.invalidGeometry }
                let text = try publicIdentityText(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Contents")), remainingBytes: &remainingBytes)
                guard let geometry = geometries[index] else { throw Failure.invalidGeometry }
                let key = try identity(subtype, geometry, text)
                current[key, default: []].append(index); keys[index] = key
            }
            if savedSubtype != "Ink" {
                let text = try nativeIdentityText(dictionary, key: "Contents", remainingBytes: &remainingBytes)
                let key = try identity(savedSubtype, rawAnnotation(dictionary), text)
                saved[key, default: []].append(index); dictionaries[index] = dictionary
            }
        }
        var proofs: [Int: MissingNameProof] = [:]
        for index in candidates {
            try PDFSaveCancellation.checkCurrent()
            guard let key = keys[index], current[key] == [index], saved[key] == [index],
                  let dictionary = dictionaries[index] else { throw Failure.invalidGeometry }
            proofs[index] = MissingNameProof(live: ObjectIdentifier(live[index]), staged: pdfReferenceIdentity(dictionary))
        }
        try PDFSaveCancellation.checkCurrent()
        return proofs
    }

    static func stagedAnnotation(_ dictionary: CGPDFDictionaryRef, matches live: PDFAnnotation,
                                 nameProof: MissingNameProof? = nil) throws {

        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
              String(cString: subtype) == live.type else { throw Failure.invalidGeometry }
        // Geometry will be replaced from its authoritative live/original
        // capture, but malformed staged programs still cannot enter the graph.
        _ = try rawAnnotation(dictionary)
        if let expected = live.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String {
            var name: CGPDFStringRef?
            if CGPDFDictionaryGetString(dictionary, "NM", &name), let name,
               let saved = CGPDFStringCopyTextString(name), expected.utf8.elementsEqual((saved as String).utf8) { return }
            guard object(dictionary, "NM") == nil,
                  nameProof?.live == ObjectIdentifier(live), nameProof?.staged == pdfReferenceIdentity(dictionary) else {
                throw Failure.invalidGeometry
            }
        }
    }

    static func rectangle(_ values: [Double]) throws -> CGRect {
        guard values.count == 4, values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000_000 }),
              values[2] != values[0], values[3] != values[1] else { throw Failure.invalidGeometry }
        return CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1]).standardized
    }
    static func numbers(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.maxX, rect.maxY].map(Double.init) }
    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy { $0.isFinite && abs($0) < 1_000_000_000 }
            && rect.width > 0 && rect.height > 0
    }
    private static func rawBox(_ dictionary: CGPDFDictionaryRef, name: String) throws -> [Double] {
        if let value = try inheritedBoxObject(dictionary, name: name) {
            var budget = 4
            let result = try flat(parse(value, budget: &budget, depth: 0))
            _ = try rectangle(result); return result
        }
        guard name != "MediaBox" else { throw Failure.invalidGeometry }
        return try rawBox(dictionary, name: name == "CropBox" ? "MediaBox" : "CropBox")
    }
    private static func inheritedBoxObject(_ dictionary: CGPDFDictionaryRef, name: String) throws -> CGPDFObjectRef? {
        var current = dictionary, seen = Set<UInt>()
        for _ in 0..<64 {
            guard seen.insert(pdfReferenceIdentity(current)).inserted else { throw Failure.invalidGeometry }
            if let value = object(current, name), CGPDFObjectGetType(value) != .null { return value }
            guard ["MediaBox", "CropBox", "Rotate"].contains(name) else { return nil }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent), let parent else { return nil }
            current = parent
        }
        throw Failure.tooComplex
    }
    private static func object(_ dictionary: CGPDFDictionaryRef, _ name: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?; return CGPDFDictionaryGetObject(dictionary, name, &value) ? value : nil
    }
    private static func parse(_ object: CGPDFObjectRef, budget: inout Int, depth: Int) throws -> Numbers {
        guard depth < 3 else { throw Failure.invalidGeometry }
        if [.integer, .real].contains(CGPDFObjectGetType(object)) {
            let value: Double
            if CGPDFObjectGetType(object) == .integer {
                var number: CGPDFInteger = 0; guard CGPDFObjectGetValue(object, .integer, &number) else { throw Failure.invalidGeometry }
                value = Double(number)
            } else {
                var number: CGPDFReal = 0; guard CGPDFObjectGetValue(object, .real, &number) else { throw Failure.invalidGeometry }
                value = Double(number)
            }
            guard budget > 0, value.isFinite, abs(value) < 1_000_000_000 else { throw Failure.invalidGeometry }
            budget -= 1; return .value(value)
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array,
              CGPDFArrayGetCount(array) <= budget else { throw Failure.tooComplex }
        var values: [Numbers] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var value: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, index, &value), let value else { throw Failure.invalidGeometry }
            values.append(try parse(value, budget: &budget, depth: depth + 1))
        }
        return .array(values)
    }
    private static func parse(_ object: Any, budget: inout Int, depth: Int) throws -> Numbers {
        guard depth < 3 else { throw Failure.invalidGeometry }
        if let value = object as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), budget > 0,
                  value.doubleValue.isFinite, abs(value.doubleValue) < 1_000_000_000 else { throw Failure.invalidGeometry }
            budget -= 1; return .value(value.doubleValue)
        }
        guard let array = object as? [Any], array.count <= budget else { throw Failure.invalidGeometry }
        return .array(try array.map { try parse($0, budget: &budget, depth: depth + 1) })
    }
    private static func append(_ point: CGPoint, to values: inout [Numbers], budget: inout Int) throws {
        guard budget >= 2, point.x.isFinite, point.y.isFinite,
              abs(point.x) < 1_000_000_000, abs(point.y) < 1_000_000_000 else { throw Failure.invalidGeometry }
        budget -= 2; values.append(.value(Double(point.x))); values.append(.value(Double(point.y)))
    }
    private static func flat(_ numbers: Numbers) throws -> [Double] {
        guard case .array(let values) = numbers else { throw Failure.invalidGeometry }
        return try values.map { guard case .value(let value) = $0 else { throw Failure.invalidGeometry }; return value }
    }
    private static func validate(_ value: Numbers, key: String) throws {
        if key == "InkList" {
            guard case .array(let paths) = value, !paths.isEmpty else { throw Failure.invalidGeometry }
            for path in paths { let values = try flat(path); guard values.count >= 2, values.count % 2 == 0 else { throw Failure.invalidGeometry } }
        } else {
            let count = try flat(value).count
            switch key {
            case "L": guard count == 4 else { throw Failure.invalidGeometry }
            case "CL": guard count == 4 || count == 6 else { throw Failure.invalidGeometry }
            case "QuadPoints": guard count > 0, count % 8 == 0 else { throw Failure.invalidGeometry }
            case "Vertices": guard count >= 4, count % 2 == 0 else { throw Failure.invalidGeometry }
            default: throw Failure.invalidGeometry
            }
        }
    }
}
