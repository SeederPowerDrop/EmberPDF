// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import Darwin
import Foundation
import PDFKit

/// PDFKit can regenerate a widget appearance even when its value did not
/// change. Original AP graphs are eligible only after comparing the live
/// widget with a separate reader of the proven original input. A late first
/// capture is therefore not mistaken for an unedited baseline.
enum PDFWidgetAppearancePreserver {
    struct State: Equatable {
        fileprivate let bytes: Data

        init?(_ annotation: PDFAnnotation) {
            guard annotation.type == "Widget",
                  [PDFAnnotationWidgetSubtype.text, .choice, .button].contains(annotation.widgetFieldType),
                  let name = annotation.fieldName, !name.isEmpty,
                  name.utf8.count <= 4_096 else { return nil }
            var values: [String: Any] = [
                "class": NSStringFromClass(type(of: annotation)),
                "name": name, "type": annotation.widgetFieldType.rawValue,
                "value": annotation.widgetStringValue.map { $0 as Any } ?? NSNull(),
                "default": annotation.widgetDefaultStringValue.map { $0 as Any } ?? NSNull(),
                "buttonType": annotation.widgetControlType.rawValue,
                "buttonState": annotation.buttonWidgetState.rawValue,
                "buttonString": annotation.buttonWidgetStateString,
                "choices": annotation.choices ?? [],
                "values": annotation.values ?? [],
                "multiline": annotation.isMultiline, "comb": annotation.hasComb,
                "maximumLength": annotation.maximumLength,
                "alignment": annotation.alignment.rawValue,
                "display": annotation.shouldDisplay, "print": annotation.shouldPrint,
                "readOnly": annotation.isReadOnly,
                "rect": [annotation.bounds.origin.x, annotation.bounds.origin.y,
                         annotation.bounds.width, annotation.bounds.height],
                "appearance": annotation.hasAppearanceStream,
                "contents": annotation.contents.map { $0 as Any } ?? NSNull()
            ]
            if let font = annotation.font {
                var attributes: [String: Any] = [:]
                for (key, value) in font.fontDescriptor.fontAttributes { attributes[key.rawValue] = value }
                values["font"] = ["name": font.fontName, "size": font.pointSize,
                                  "descriptor": attributes]
            } else { values["font"] = NSNull() }
            for (key, color) in [("color", annotation.value(forAnnotationKey: .color) == nil ? nil : annotation.color),
                                 ("fontColor", annotation.fontColor),
                                 ("interiorColor", annotation.interiorColor)] {
                if let color {
                    guard let rgb = color.usingColorSpace(.extendedSRGB) else { return nil }
                    values[key] = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                } else { values[key] = NSNull() }
            }
            if let border = annotation.border {
                values["border"] = ["width": border.lineWidth, "style": border.style.rawValue,
                                    "dash": border.dashPattern ?? []]
            } else { values["border"] = NSNull() }
            // These public values catch explicit style/AP replacement as well
            // as changes to the inherited appearance controls. Unknown objects
            // are refused rather than compared by an unstable pointer.
            for key in ["/AP", "/DA", "/Q", "/MK", "/DS", "/RC", "/F", "/Ff",
                        "/Opt", "/I", "/TI", "/MaxLen", "/AS", "/DV"] {
                values[key] = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: key)) ?? NSNull()
            }
            guard let encoded = Self.fingerprint(values) else { return nil }
            bytes = encoded
        }

        fileprivate static func fingerprint(_ value: Any) -> Data? {
            var visits = 0, remainingBytes = 256 * 1_024
            guard let canonical = Self.canonical(value, depth: 0, visits: &visits, remainingBytes: &remainingBytes),
                  JSONSerialization.isValidJSONObject(canonical),
                  let encoded = try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]),
                  encoded.count <= 256 * 1_024 else { return nil }
            return encoded
        }

        private static func canonical(_ value: Any, depth: Int, visits: inout Int,
                                      remainingBytes: inout Int) -> Any? {
            visits += 1
            guard depth <= 12, visits <= 8_192, remainingBytes >= 16 else { return nil }
            remainingBytes -= 16
            if value is NSNull { return NSNull() }
            if let string = value as? String {
                let count = string.utf8.count
                // JSON escaping may expand a byte up to sixfold. Charge before
                // retaining/encoding the collection, not after allocating it.
                guard count <= 65_536, count <= remainingBytes / 6 else { return nil }
                remainingBytes -= count * 6; return string
            }
            if let number = value as? NSNumber {
                guard number.doubleValue.isFinite, remainingBytes >= 64 else { return nil }
                remainingBytes -= 64; return number
            }
            if let data = value as? Data {
                guard data.count <= 65_536, data.count <= remainingBytes / 8 else { return nil }
                remainingBytes -= data.count * 8
                return ["data": data.base64EncodedString()]
            }
            if let transform = value as? NSAffineTransform {
                let t = transform.transformStruct
                return canonical([t.m11, t.m12, t.m21, t.m22, t.tX, t.tY], depth: depth + 1,
                    visits: &visits, remainingBytes: &remainingBytes)
            }
            if let color = value as? NSColor {
                guard let rgb = color.usingColorSpace(.extendedSRGB) else { return nil }
                return canonical([rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent],
                    depth: depth + 1, visits: &visits, remainingBytes: &remainingBytes)
            }
            if let characteristics = value as? PDFAppearanceCharacteristics {
                let scalars: [String: Any] = ["control": characteristics.controlType.rawValue,
                    "rotation": characteristics.rotation,
                    "caption": characteristics.caption.map { $0 as Any } ?? NSNull(),
                    "rollover": characteristics.rolloverCaption.map { $0 as Any } ?? NSNull(),
                    "down": characteristics.downCaption.map { $0 as Any } ?? NSNull(),
                    "background": characteristics.backgroundColor.map { $0 as Any } ?? NSNull(),
                    "border": characteristics.borderColor.map { $0 as Any } ?? NSNull()]
                return canonical(scalars, depth: depth + 1, visits: &visits, remainingBytes: &remainingBytes)
            }
            if let array = value as? [Any] {
                guard array.count <= 4_096 else { return nil }
                var result: [Any] = []
                for child in array {
                    guard let item = canonical(child, depth: depth + 1, visits: &visits,
                        remainingBytes: &remainingBytes) else { return nil }
                    result.append(item)
                }
                return result
            }
            if let dictionary = value as? [String: Any] {
                guard dictionary.count <= 512 else { return nil }
                var result: [String: Any] = [:]
                for (key, child) in dictionary {
                    let count = key.utf8.count
                    guard count <= 4_096, count <= remainingBytes / 6 else { return nil }
                    remainingBytes -= count * 6
                    guard let item = canonical(child, depth: depth + 1, visits: &visits,
                        remainingBytes: &remainingBytes) else { return nil }
                    result[key] = item
                }
                return result
            }
            return nil
        }

        var byteCount: Int { bytes.count }

    }

    /// Default intent needs only these bounded scalar observations from the
    /// independent original reader. Unknown fonts/AP objects and whole-form
    /// eligibility must not prevent a separate stored-default presence proof.
    struct DefaultState: Equatable {
        private let bytes: Data

        init?(_ annotation: PDFAnnotation) {
            let getter = annotation.widgetDefaultStringValue.map { $0 as Any } ?? NSNull()
            let value = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV")) ?? NSNull()
            guard (value is String || value is NSNull),
                  let encoded = State.fingerprint(["default": getter, "/DV": value]) else { return nil }
            bytes = encoded
        }

        var byteCount: Int { bytes.count }
        func matches(_ annotation: PDFAnnotation) -> Bool? {
            guard let current = DefaultState(annotation) else { return nil }
            return self == current
        }
    }

    /// Shared bounded scalar encoding for an import's current raw defaults.
    /// Keep an object wrapper so scalar/null roots are valid JSON containers.
    static func boundedDefaultFingerprint(_ value: Any?) -> Data? {
        let kind: String
        if value == nil { kind = "absent" }
        else if value is NSNull { kind = "null" }
        else if value is String { kind = "string" }
        else if let number = value as? NSNumber { kind = "number:" + String(cString: number.objCType) }
        else if value is Data { kind = "data" }
        else if value is [Any] { kind = "array" }
        else if value is [String: Any] { kind = "dictionary" }
        else { return nil }
        return State.fingerprint(["publicType": kind, "value": value ?? NSNull()])
    }

    struct Origin {
        let baseline: State
        let appearance: CGPDFObjectRef
        let annotation: CGPDFDictionaryRef

        func matches(_ live: PDFAnnotation) -> Bool { State(live) == baseline }
    }

    /// PDFKit can serialize the original /DV after the live default changed.
    /// Preserve this current scalar independently of original-AP eligibility;
    /// no original field value is imported and buttons/array defaults are not
    /// inferred through the string API.
    enum CurrentDefaultIntent { case string(String), explicitNull, remove }

    private enum OriginalDefault { case absent, explicitNull, string(String) }

    private static func simpleOriginalDefault(_ annotation: PDFAnnotation,
                                              original: CGPDFDictionaryRef?) -> OriginalDefault? {
        guard annotation.type == "Widget", [.text, .choice].contains(annotation.widgetFieldType), let original,
              ["Parent", "Kids"].allSatisfy({ PDFCatalogStructurePreserver.object(original, $0) == nil }) else { return nil }
        var nativeType: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(original, "FT", &nativeType), let nativeType,
              String(cString: nativeType) == (annotation.widgetFieldType == .text ? "Tx" : "Ch") else { return nil }
        if annotation.widgetFieldType == .choice {
            var originalFlags: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(original, "Ff", &originalFlags), originalFlags & (1 << 21) != 0 { return nil }
            let flags = (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Ff")) as? NSNumber)?.intValue ?? 0
            if flags & (1 << 21) != 0 { return nil }
        }
        if let value = PDFCatalogStructurePreserver.object(original, "DV") {
            if CGPDFObjectGetType(value) == .null { return .explicitNull }
            guard CGPDFObjectGetType(value) == .string else { return nil }
            var string: CGPDFStringRef?
            guard CGPDFObjectGetValue(value, .string, &string), let string,
                  CGPDFStringGetLength(string) <= 131_072,
                  let decoded = CGPDFStringCopyTextString(string) as String? else { return nil }
            return .string(decoded)
        }
        return .absent
    }

    /// Main-thread selection only. An originally absent simple default may
    /// need worker repair even when the SDK's fallback looks unchanged.
    static func isPotentialDefaultCandidate(_ annotation: PDFAnnotation,
                                            original: CGPDFDictionaryRef?) -> Bool {
        guard let previous = simpleOriginalDefault(annotation, original: original) else { return false }
        let publicValue = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))
        guard publicValue == nil || publicValue is NSNull || publicValue is String else { return false }
        switch previous {
        case .absent, .explicitNull: return true
        case .string(let value):
            return publicValue == nil || publicValue is NSNull || annotation.widgetDefaultStringValue != value
        }
    }

    static func currentDefaultIntent(_ annotation: PDFAnnotation, original: CGPDFDictionaryRef?,
                                     baseline: DefaultState?) throws -> CurrentDefaultIntent? {
        guard let previous = simpleOriginalDefault(annotation, original: original) else { return nil }
        let publicDefault = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))
        guard publicDefault == nil || publicDefault is NSNull || publicDefault is String else {
            throw PDFPageStructurePreserver.Failure.unsupportedStructure
        }
        if case .explicitNull = previous {
            guard let unchanged = baseline?.matches(annotation) else {
                throw PDFPageStructurePreserver.Failure.unsupportedStructure
            }
            if unchanged { return .explicitNull }
            if publicDefault == nil || publicDefault is NSNull { return .remove }
            guard let current = annotation.widgetDefaultStringValue else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            return .string(current)
        }
        // For a supported simple field, clearing the current public value is
        // observable. It is never an absence oracle for an original array/name.
        if publicDefault == nil || publicDefault is NSNull { return .remove }
        guard let current = annotation.widgetDefaultStringValue else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        switch previous {
        case .string(let original): return current == original ? nil : .string(current)
        case .explicitNull: throw PDFPageStructurePreserver.Failure.invalidCopy // handled with its independent proof above
        case .absent:
            guard let unchanged = baseline?.matches(annotation) else {
                throw PDFPageStructurePreserver.Failure.unsupportedStructure
            }
            return unchanged ? .remove : .string(current)
        }
    }

    static func preserveCurrentDefault(_ annotation: PDFAnnotation, original: CGPDFDictionaryRef?, page: Int, index: Int,
                                       baseline: DefaultState?,
                                       plan: inout PDFCatalogGraphPlan) throws {
        guard let intent = try currentDefaultIntent(annotation, original: original, baseline: baseline) else { return }
        plan.preservesCurrentWidgetDefaults = true
        plan.annotationDrops[page, default: [:]][index, default: []].insert("DV")
        if case let .string(current) = intent {
            guard current.utf8.count <= 65_536, let encoded = current.data(using: .utf16BigEndian),
                  encoded.count <= 131_072 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            plan.annotationEntries[page, default: [:]][index, default: [:]]["DV"] = .string(Data([0xfe, 0xff]) + encoded)
        } else if case .explicitNull = intent {
            plan.annotationEntries[page, default: [:]][index, default: [:]]["DV"] = .null
        }
    }

    /// Only terminal, independent widgets are eligible for the first defaults
    /// restoration path. Hierarchical/shared fields, signatures and radio
    /// groups keep the established guarded form path.
    static func origin(annotation: PDFAnnotation, native: CGPDFDictionaryRef,
                       baseline: State?) -> Origin? {
        guard let baseline, baseline == State(annotation),
              PDFCatalogStructurePreserver.object(native, "Parent") == nil,
              PDFCatalogStructurePreserver.object(native, "Kids") == nil,
              PDFCatalogStructurePreserver.object(native, "AA") == nil,
              PDFCatalogStructurePreserver.object(native, "A") == nil,
              let appearance = PDFCatalogStructurePreserver.object(native, "AP"),
              CGPDFObjectGetType(appearance) == .dictionary else { return nil }
        var flags: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(native, "Ff", &flags),
           annotation.widgetFieldType == .button,
           flags & ((1 << 15) | (1 << 16)) != 0 { return nil }
        if let mk = PDFCatalogStructurePreserver.dictionary(native, "MK") {
            var supported = true
            guard CGPDFDictionaryGetCount(mk) <= 6 else { return nil }
            CGPDFDictionaryApplyBlock(mk, { key, _, _ in
                if !["BC", "BG", "R", "CA", "RC", "AC"].contains(String(cString: key)) { supported = false }
                return supported
            }, nil)
            guard supported else { return nil }
        }
        return Origin(baseline: baseline, appearance: appearance, annotation: native)
    }

    static func defaults(from document: CGPDFDocument) throws -> [String: PDFCatalogGraphValue]? {
        guard let catalog = document.catalog,
              let form = PDFCatalogStructurePreserver.dictionary(catalog, "AcroForm"),
              ["XFA", "CO", "SigFlags", "AA"].allSatisfy({ PDFCatalogStructurePreserver.object(form, $0) == nil }) else { return nil }
        guard try terminalFieldIdentities(in: document) != nil else { return nil }
        var need: CGPDFBoolean = 0
        if PDFCatalogStructurePreserver.object(form, "NeedAppearances") != nil {
            guard CGPDFDictionaryGetBoolean(form, "NeedAppearances", &need), need == 0 else { return nil }
        }
        for (key, kind) in [("DA", CGPDFObjectType.string), ("DR", .dictionary), ("Q", .integer)] {
            if let value = PDFCatalogStructurePreserver.object(form, key), CGPDFObjectGetType(value) != kind { return nil }
        }
        var alignment: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(form, "Q", &alignment), !(0...2).contains(alignment) { return nil }
        var entries: [String: PDFCatalogGraphValue] = [:]
        for key in ["DA", "DR", "Q", "NeedAppearances"] {
            if let object = PDFCatalogStructurePreserver.object(form, key) { entries[key] = .original(object) }
        }
        return entries
    }

    /// Prove the entire form, not just the selected/extracted page subset.
    /// A hidden/non-page/signature/parent/shared field must never disappear
    /// because a later catalog rewrite manufactured a smaller Fields array.
    private static func terminalFieldIdentities(in document: CGPDFDocument) throws -> Set<UInt>? {
        guard document.numberOfPages <= 100_000, let catalog = document.catalog,
              let form = PDFCatalogStructurePreserver.dictionary(catalog, "AcroForm"),
              let fields = PDFCatalogStructurePreserver.array(form, "Fields"),
              CGPDFArrayGetCount(fields) <= 10_000 else { return nil }
        var fieldIDs = Set<UInt>(), names = Set<String>()
        for index in 0..<CGPDFArrayGetCount(fields) {
            try PDFSaveCancellation.checkCurrent()
            var field: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?, type: UnsafePointer<CChar>?, name: CGPDFStringRef?
            guard CGPDFArrayGetDictionary(fields, index, &field), let field,
                  CGPDFDictionaryGetName(field, "Subtype", &subtype), let subtype, String(cString: subtype) == "Widget",
                  CGPDFDictionaryGetName(field, "FT", &type), let type, ["Tx", "Ch", "Btn"].contains(String(cString: type)),
                  CGPDFDictionaryGetString(field, "T", &name), let name, CGPDFStringGetLength(name) <= 4_096,
                  let text = CGPDFStringCopyTextString(name) as String?, !text.isEmpty,
                  names.insert(text).inserted, fieldIDs.insert(pdfReferenceIdentity(field)).inserted,
                  boundedPublicFieldValues(field),
                  ["Parent", "Kids", "AA", "A"].allSatisfy({ PDFCatalogStructurePreserver.object(field, $0) == nil }) else { return nil }
            var flags: CGPDFInteger = 0
            if String(cString: type) == "Btn", CGPDFDictionaryGetInteger(field, "Ff", &flags),
               flags & ((1 << 15) | (1 << 16)) != 0 { return nil }
        }
        var pageIDs = Set<UInt>(), visits = 0
        for index in 0..<document.numberOfPages {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index + 1)?.dictionary else { return nil }
            guard let annotations = PDFCatalogStructurePreserver.array(page, "Annots") else { continue }
            let count = CGPDFArrayGetCount(annotations)
            guard count <= 100_000 - visits else { return nil }; visits += count
            for offset in 0..<count {
                if offset & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                var annotation: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?
                guard CGPDFArrayGetDictionary(annotations, offset, &annotation), let annotation else { return nil }
                if CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype, String(cString: subtype) == "Widget" {
                    guard pageIDs.insert(pdfReferenceIdentity(annotation)).inserted else { return nil }
                }
            }
        }
        return fieldIDs == pageIDs ? fieldIDs : nil
    }

    /// Refuse large raw option/value collections before asking the fresh
    /// PDFKit reader to materialize choices and their bridged string arrays.
    private static func boundedPublicFieldValues(_ field: CGPDFDictionaryRef) -> Bool {
        var remaining = 256 * 1_024
        return boundedPublicFieldValues(field, remainingBudget: &remaining)
    }

    static func boundedPublicFieldValues(_ field: CGPDFDictionaryRef, remainingBudget: inout Int) -> Bool {
        var remaining = min(256 * 1_024, remainingBudget), visits = 0
        let startingBudget = remaining
        defer { remainingBudget -= startingBudget - remaining }
        func visit(_ value: CGPDFObjectRef, depth: Int) -> Bool {
            visits += 1
            guard depth <= 12, visits <= 8_192, remaining >= 64 else { return false }
            remaining -= 64
            switch CGPDFObjectGetType(value) {
            case .string:
                var string: CGPDFStringRef?
                guard CGPDFObjectGetValue(value, .string, &string), let string else { return false }
                let count = CGPDFStringGetLength(string)
                guard count <= 65_536, count <= remaining / 6 else { return false }
                remaining -= count * 6; return true
            case .array:
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(value, .array, &array), let array,
                      CGPDFArrayGetCount(array) <= 4_096 else { return false }
                for index in 0..<CGPDFArrayGetCount(array) {
                    var child: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(array, index, &child), let child, visit(child, depth: depth + 1) else { return false }
                }
                return true
            case .dictionary:
                var dictionary: CGPDFDictionaryRef?, valid = true
                guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary,
                      CGPDFDictionaryGetCount(dictionary) <= 512 else { return false }
                CGPDFDictionaryApplyBlock(dictionary, { key, child, _ in
                    let count = strnlen(key, 4_097)
                    guard count <= 4_096, count <= remaining / 6 else { valid = false; return false }
                    remaining -= count * 6
                    valid = visit(child, depth: depth + 1); return valid
                }, nil)
                return valid
            case .real:
                var number: CGPDFReal = 0
                return CGPDFObjectGetValue(value, .real, &number) && number.isFinite
            case .name:
                var name: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(value, .name, &name), let name else { return false }
                let count = strnlen(name, 4_097)
                guard count <= 4_096, count <= remaining / 6 else { return false }
                remaining -= count * 6; return true
            case .integer, .boolean, .null: return true
            default: return false
            }
        }
        for key in ["T", "V", "DV", "DA", "Q", "MK", "DS", "RC", "Contents", "F", "Ff", "Opt", "I", "TI", "MaxLen", "AS"] {
            if let value = PDFCatalogStructurePreserver.object(field, key), !visit(value, depth: 0) { return false }
        }
        return true
    }

    /// Reconnect current staged terminal widgets, never original /Fields.
    /// Called only when every live output widget proved the same original
    /// state and all form widgets come from one original form source.
    static func formEntries(staged: CGPDFDocument, defaults: [String: PDFCatalogGraphValue],
                            widgets: [(page: Int, index: Int)]) throws -> [String: PDFCatalogGraphValue] {
        guard !widgets.isEmpty, widgets.count <= 10_000, let catalog = staged.catalog,
              let form = PDFCatalogStructurePreserver.dictionary(catalog, "AcroForm"),
              ["XFA", "CO", "SigFlags", "AA"].allSatisfy({ PDFCatalogStructurePreserver.object(form, $0) == nil }) else {
            throw PDFPageStructurePreserver.Failure.invalidCopy
        }
        guard let fieldIDs = try terminalFieldIdentities(in: staged), fieldIDs.count == widgets.count else {
            throw PDFPageStructurePreserver.Failure.invalidCopy
        }
        var entries: [String: PDFCatalogGraphValue] = [:], valid = true
        guard CGPDFDictionaryGetCount(form) <= 512 else { throw PDFPageStructurePreserver.Failure.tooComplex }
        CGPDFDictionaryApplyBlock(form, { key, value, _ in
            let name = String(cString: key)
            if !["Fields", "DA", "DR", "Q", "NeedAppearances"].contains(name) { entries[name] = .original(value) }
            return true
        }, nil)
        var names = Set<String>(), widgetIDs = Set<UInt>()
        for location in widgets {
            guard let page = staged.page(at: location.page + 1)?.dictionary,
                  let annotations = PDFCatalogStructurePreserver.array(page, "Annots"),
                  location.index < CGPDFArrayGetCount(annotations) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            var annotation: CGPDFDictionaryRef?, name: CGPDFStringRef?
            guard CGPDFArrayGetDictionary(annotations, location.index, &annotation), let annotation,
                  CGPDFDictionaryGetString(annotation, "T", &name), let name,
                  let text = CGPDFStringCopyTextString(name) as String?, names.insert(text).inserted,
                  widgetIDs.insert(pdfReferenceIdentity(annotation)).inserted,
                  ["Parent", "Kids", "AA", "A"].allSatisfy({ PDFCatalogStructurePreserver.object(annotation, $0) == nil }) else {
                valid = false; break
            }
        }
        guard valid, widgetIDs == fieldIDs else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        entries.merge(defaults) { _, original in original }
        entries["Fields"] = .array(widgets.map { .annotation(page: $0.page, index: $0.index) })
        return entries
    }
}
