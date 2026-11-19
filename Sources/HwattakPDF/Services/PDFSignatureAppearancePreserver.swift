// SPDX-License-Identifier: MPL-2.0
import AppKit
import CryptoKit
import PDFKit

/// A signature becomes an inactive Stamp only at the explicit page-import
/// transaction. This captures bounded public drawing state, never an AP graph
/// or source bytes on the main actor. Native provenance is checked by the worker.
enum PDFSignatureAppearancePreserver {
    static let markerKey = "EmberPDFSignatureAppearance"
    struct State: Equatable {
        let bytes: Data
        var digest: Data { Data(SHA256.hash(data: bytes)) }
        init?(_ annotation: PDFAnnotation) {
            guard ["Widget", "Stamp"].contains(annotation.type ?? ""),
                  annotation.value(forAnnotationKey: .init(rawValue: "/AP")) == nil else { return nil }
            var values: [String: Any] = [
                "class": NSStringFromClass(type(of: annotation)), "type": annotation.type ?? "",
                "rect": [annotation.bounds.minX, annotation.bounds.minY, annotation.bounds.width, annotation.bounds.height],
                "display": annotation.shouldDisplay, "print": annotation.shouldPrint,
                "appearance": annotation.hasAppearanceStream,
                "contents": annotation.contents.map { $0 as Any } ?? NSNull()]
            if let font = annotation.font {
                var attributes: [String: Any] = [:]
                for (key, value) in font.fontDescriptor.fontAttributes { attributes[key.rawValue] = value }
                values["font"] = ["name": font.fontName, "size": font.pointSize, "descriptor": attributes]
            } else { values["font"] = NSNull() }
            for (key, color) in [("color", annotation.value(forAnnotationKey: .color) == nil ? nil : annotation.color),
                                 ("fontColor", annotation.fontColor), ("interiorColor", annotation.interiorColor)] {
                if let color {
                    guard let rgb = color.usingColorSpace(.extendedSRGB) else { return nil }
                    values[key] = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                } else { values[key] = NSNull() }
            }
            if let border = annotation.border {
                values["border"] = ["width": border.lineWidth, "style": border.style.rawValue, "dash": border.dashPattern ?? []]
            } else { values["border"] = NSNull() }
            for key in ["/C", "/IC", "/CA", "/ca", "/BM", "/Rotate", "/Name", "/F", "/BS", "/BE", "/DA", "/DS", "/RC", "/MK", "/Q", "/AS", "/NM"] {
                values[key] = annotation.value(forAnnotationKey: .init(rawValue: key)) ?? NSNull()
            }
            guard let encoded = PDFWidgetAppearancePreserver.boundedDefaultFingerprint(values) else { return nil }
            bytes = encoded
        }
    }
    /// Seal stored controls at the validated staging boundary, after PDFKit's
    /// default serialization and with the final exact Rect override. This is
    /// separate from the strict public live-state witness; no getter spelling
    /// or drawing-state edits are normalized away to recover AP authority.
    static func storedDrawingDigest(_ annotation: CGPDFDictionaryRef,
                                    rectangle: PDFCatalogGraphValue? = nil) throws -> Data {
        var bytes = Data(), visits = 0, remaining = 256 * 1_024
        func emit(_ kind: String, _ data: Data) throws {
            let header = Data((kind + String(data.count) + ":").utf8)
            guard header.count <= remaining, data.count <= remaining - header.count else { throw PDFPageStructurePreserver.Failure.tooComplex }
            remaining -= header.count + data.count; bytes.append(header); bytes.append(data)
        }
        func number(_ value: Double) throws {
            guard value.isFinite, abs(value) <= 1_000_000_000 else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            try emit("n", Data(String(value == 0 ? 0 : value).utf8))
        }
        func object(_ value: CGPDFObjectRef, depth: Int) throws {
            visits += 1
            if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard depth <= 12, visits <= 8_192 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            switch CGPDFObjectGetType(value) {
            case .null: try emit("z", Data())
            case .boolean:
                var v: CGPDFBoolean = 0; guard CGPDFObjectGetValue(value, .boolean, &v) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                try emit("b", Data([v == 0 ? 0 : 1]))
            case .integer:
                var v: CGPDFInteger = 0; guard CGPDFObjectGetValue(value, .integer, &v), (-1_000_000_000...1_000_000_000).contains(v) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                try number(Double(v))
            case .real:
                var v: CGPDFReal = 0; guard CGPDFObjectGetValue(value, .real, &v) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                try number(Double(v))
            case .name:
                var v: UnsafePointer<CChar>?; guard CGPDFObjectGetValue(value, .name, &v), let v else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                let count = strnlen(v, 4_097); guard count <= 4_096 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                try emit("N", Data(bytes: v, count: count))
            case .string:
                var v: CGPDFStringRef?; guard CGPDFObjectGetValue(value, .string, &v), let v, CGPDFStringGetLength(v) <= 65_536 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                try emit("s", CGPDFStringGetBytePtr(v).map { Data(bytes: $0, count: CGPDFStringGetLength(v)) } ?? Data())
            case .array:
                var v: CGPDFArrayRef?; guard CGPDFObjectGetValue(value, .array, &v), let v, CGPDFArrayGetCount(v) <= 512 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                try emit("[", Data())
                for index in 0..<CGPDFArrayGetCount(v) {
                    var member: CGPDFObjectRef?; guard CGPDFArrayGetObject(v, index, &member), let member else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                    try object(member, depth: depth + 1)
                }
                try emit("]", Data())
            case .dictionary:
                var v: CGPDFDictionaryRef?; guard CGPDFObjectGetValue(value, .dictionary, &v), let v, CGPDFDictionaryGetCount(v) <= 128 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                var entries: [(Data, CGPDFObjectRef)] = [], invalid = false
                CGPDFDictionaryApplyBlock(v, { key, value, _ in
                    let count = strnlen(key, 4_097)
                    guard count <= 4_096 else { invalid = true; return false }
                    entries.append((Data(bytes: key, count: count), value)); return true
                }, nil)
                guard !invalid else { throw PDFPageStructurePreserver.Failure.tooComplex }
                try emit("{", Data())
                for (key, value) in entries.sorted(by: { $0.0.lexicographicallyPrecedes($1.0) }) {
                    try emit("k", key); try object(value, depth: depth + 1)
                }
                try emit("}", Data())
            default: throw PDFPageStructurePreserver.Failure.invalidCopy
            }
        }
        for key in ["Subtype", "Rect", "Contents", "C", "IC", "CA", "ca", "BM", "Rotate", "Name", "F", "Border", "BS", "BE", "DA", "DS", "RC", "MK", "Q", "AS"].sorted() {
            try emit("k", Data(key.utf8))
            if key == "Rect", let rectangle {
                guard case .array(let coordinates) = rectangle, coordinates.count == 4 else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                try emit("[", Data())
                for value in coordinates {
                    switch value {
                    case .integer(let n): try number(Double(n))
                    case .real(let n): try number(n)
                    default: throw PDFPageStructurePreserver.Failure.invalidCopy
                    }
                }
                try emit("]", Data())
            } else if let value = PDFCatalogStructurePreserver.object(annotation, key) { try object(value, depth: 0) }
            else { try emit("absent", Data()) }
        }
        try PDFSaveCancellation.checkCurrent()
        return Data(SHA256.hash(data: bytes))
    }

    struct Record {
        let input: Data, appearance: Data, state: Data
        let page: Int, annotation: Int
        var value: PDFCatalogGraphValue { .dictionary([
            "Version": .integer(1), "Input": .string(input), "AP": .string(appearance), "State": .string(state),
            "Page": .integer(page), "Annotation": .integer(annotation)]) }
        init(input: Data, appearance: Data, state: Data, page: Int, annotation: Int) {
            self.input = input; self.appearance = appearance; self.state = state; self.page = page; self.annotation = annotation
        }
        init?(_ annotation: CGPDFDictionaryRef) {
            guard let dictionary = PDFCatalogStructurePreserver.dictionary(annotation, markerKey), CGPDFDictionaryGetCount(dictionary) == 6 else { return nil }
            func integer(_ key: String) -> Int? {
                var value: CGPDFInteger = 0
                guard CGPDFDictionaryGetInteger(dictionary, key, &value), (0...100_000).contains(value) else { return nil }
                return value
            }
            func hash(_ key: String) -> Data? {
                var string: CGPDFStringRef?
                guard CGPDFDictionaryGetString(dictionary, key, &string), let string, CGPDFStringGetLength(string) == 32,
                      let bytes = CGPDFStringGetBytePtr(string) else { return nil }
                return Data(bytes: bytes, count: 32)
            }
            guard integer("Version") == 1, let page = integer("Page"), let slot = integer("Annotation"),
                  let input = hash("Input"), let ap = hash("AP"), let state = hash("State") else { return nil }
            self.init(input: input, appearance: ap, state: state, page: page, annotation: slot)
        }
    }
}
