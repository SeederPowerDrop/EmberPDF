// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Builds page-number and initial-view metadata against the final output page
/// identities. It never mutates a source document or a partially built plan.
enum PDFCatalogPageMetadataPreserver {
    enum Failure: LocalizedError {
        case invalidMetadata, tooComplex

        var errorDescription: String? {
            switch self {
            case .invalidMetadata:
                return L10n.string("page_structure.error.copy", defaultValue: "페이지의 주석과 내부 이동을 독립된 사본으로 만들지 못했습니다. 원본은 변경되지 않았습니다.")
            case .tooComplex:
                return L10n.string("page_structure.error.too_complex", defaultValue: "문서 구조가 너무 복잡하여 안전하게 페이지를 조립하지 못했습니다. 원본은 변경되지 않았습니다.")
            }
        }
    }

    private struct LabelRange {
        let start: Int
        let style: String?
        let prefix: Data?
        let number: Int
        let lookupBounds: ClosedRange<Int>?
    }
    private struct NamedDestination {
        let bytes: Data
        let text: String
        let value: CGPDFObjectRef
    }
    private struct DestinationNames {
        var modern: [NamedDestination] = []
        var legacy: [String: CGPDFObjectRef] = [:]
        var hasModern = false
        var hasLegacy = false
    }
    private static let destinationArities = ["XYZ": 5, "Fit": 2, "FitH": 3, "FitV": 3,
                                            "FitR": 6, "FitB": 2, "FitBH": 3, "FitBV": 3]

    static func addPageMetadata(from groups: [PDFCatalogSourceGroup], to plan: inout PDFCatalogGraphPlan) throws {
        let maximumPages = 250_000
        var outputIndexes = Set<Int>()
        var hasLabels = false
        for group in groups {
            for origin in group.pages {
                guard origin.sourceIndex >= 0, origin.sourceIndex < group.document.numberOfPages,
                      origin.outputIndex >= 0, origin.outputIndex < maximumPages,
                      outputIndexes.insert(origin.outputIndex).inserted else {
                    throw Failure.invalidMetadata
                }
                guard outputIndexes.count <= maximumPages else { throw Failure.tooComplex }
            }
            if let catalog = group.document.catalog, object(catalog, "PageLabels") != nil { hasLabels = true }
        }
        var labelEntries: [(Int, PDFCatalogGraphValue)] = []
        let destinationNames = try groups.map { try readDestinationNames(in: $0.document) }
        if hasLabels {
            for group in groups {
                let ranges = try labelRanges(in: group.document)
                for origin in group.pages {
                    let range = range(at: origin.sourceIndex, in: ranges)
                    var dictionary: [String: PDFCatalogGraphValue] = [:]
                    if let prefix = range.prefix { dictionary["P"] = .string(prefix) }
                    if let style = range.style {
                        let (number, overflow) = range.number.addingReportingOverflow(origin.sourceIndex - range.start)
                        guard !overflow, number > 0 else { throw Failure.invalidMetadata }
                        dictionary["S"] = .name(style)
                        dictionary["St"] = .integer(number)
                    }
                    labelEntries.append((origin.outputIndex, .dictionary(dictionary)))
                }
            }
        }
        var examinedOpenAction = false
        var openAction: PDFCatalogGraphValue?
        var preservesEmptyOpeningAction = false
        for (groupIndex, group) in groups.enumerated() {
            guard let catalog = group.document.catalog, let original = object(catalog, "OpenAction") else { continue }
            let originalType = CGPDFObjectGetType(original)
            if originalType == .null { continue }
            guard originalType == .array || originalType == .dictionary else { throw Failure.invalidMetadata }
            examinedOpenAction = true
            if originalType == .array {
                openAction = try mappedDestination(original, in: group, names: destinationNames[groupIndex])
            } else if let action = dictionary(original), name(action, "S") == "GoTo" {
                guard let destination = object(action, "D") else { throw Failure.invalidMetadata }
                if try preservedEmptyOpeningAction(action, in: group, names: destinationNames[groupIndex]) {
                    openAction = .original(original)
                    preservesEmptyOpeningAction = true
                } else if let source = group.rawStreamSource,
                          try source.provesOriginalNullFitOpeningAction(in: group.document, action: action) {
                    // Preserve this exact inert source action; never invent a
                    // page target or broaden active destination resolution.
                    openAction = .original(original)
                } else if let mapped = try mappedDestination(destination, in: group, names: destinationNames[groupIndex]) {
                    var entries: [String: PDFCatalogGraphValue] = [:]
                    var error: Error?
                    CGPDFDictionaryApplyBlock(action, { key, value, _ in
                        let key = String(cString: key)
                        if key != "D" { entries[key] = .original(value) }
                        if entries.count > 4_096 { error = Failure.tooComplex; return false }
                        return true
                    }, nil)
                    if let error { throw error }
                    entries["D"] = mapped
                    openAction = .dictionary(entries)
                }
            } else {
                // Other action kinds belong to the general catalog graph
                // copier. This helper neither interprets nor executes them.
                openAction = .original(original)
            }
            // The first source with an opening action has priority. If its
            // target was excluded, removing that action avoids a false jump.
            break
        }
        var modernNames: [(Data, PDFCatalogGraphValue)] = []
        var usedModern = Set<Data>(), legacyNames: [String: PDFCatalogGraphValue] = [:]
        for (groupIndex, group) in groups.enumerated() {
            let names = destinationNames[groupIndex]
            for destination in names.modern {
                guard let mapped = try storedDestination(destination.value, in: group, names: names) else { continue }
                var key = destination.bytes, suffix = 1
                while usedModern.contains(key) {
                    key = unicodeBytes("EmberPDF_Source\(groupIndex + 1)_\(suffix)_" + destination.text)
                    suffix += 1
                    guard suffix <= 250_000 else { throw Failure.tooComplex }
                }
                usedModern.insert(key)
                modernNames.append((key, mapped))
                guard modernNames.count <= 250_000 else { throw Failure.tooComplex }
            }
            for originalKey in names.legacy.keys.sorted() {
                guard let original = names.legacy[originalKey],
                      let mapped = try storedDestination(original, in: group, names: names) else { continue }
                var key = originalKey, suffix = 1
                while legacyNames[key] != nil {
                    key = "EmberPDF_Source\(groupIndex + 1)_\(suffix)_" + originalKey
                    suffix += 1
                    guard suffix <= 250_000 else { throw Failure.tooComplex }
                }
                legacyNames[key] = mapped
                guard legacyNames.count <= 250_000 else { throw Failure.tooComplex }
            }
        }
        // A different merged source must not give a formerly broken empty-name
        // action a new working target. Refuse before changing the caller's plan.
        if preservesEmptyOpeningAction, legacyNames[""] != nil { throw Failure.invalidMetadata }
        if hasLabels {
            let values: [PDFCatalogGraphValue] = labelEntries.sorted { $0.0 < $1.0 }.flatMap { [.integer($0.0), $0.1] }
            plan.catalogEntries["PageLabels"] = .dictionary(["Nums": .array(values)])
        }
        if examinedOpenAction { plan.catalogEntries["OpenAction"] = openAction }
        if destinationNames.contains(where: \.hasModern) {
            var names: [String: PDFCatalogGraphValue] = [:]
            if case .dictionary(let existing) = plan.catalogEntries["Names"] { names = existing }
            let values: [PDFCatalogGraphValue] = modernNames.sorted { $0.0.lexicographicallyPrecedes($1.0) }
                .flatMap { [.string($0.0), $0.1] }
            names["Dests"] = .dictionary(["Names": .array(values)])
            plan.catalogEntries["Names"] = .dictionary(names)
        }
        if destinationNames.contains(where: \.hasLegacy) { plan.catalogEntries["Dests"] = .dictionary(legacyNames) }
        plan.retainedDocuments.append(contentsOf: groups.map(\.document))
    }

    private static func range(at index: Int, in ranges: [LabelRange]) -> LabelRange {
        var lower = 0, upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].start <= index { lower = middle + 1 } else { upper = middle }
        }
        if lower > 0 {
            let candidate = ranges[lower - 1]
            if candidate.lookupBounds?.contains(index) != false { return candidate }
        }
        return LabelRange(start: 0, style: "D", prefix: nil, number: 1, lookupBounds: nil)
    }

    private static func labelRanges(in document: CGPDFDocument) throws -> [LabelRange] {
        guard let catalog = document.catalog, let root = object(catalog, "PageLabels") else { return [] }
        guard let root = dictionary(root) else { throw Failure.invalidMetadata }
        var stack: [(CGPDFDictionaryRef, Int, ClosedRange<Int>?)] = [(root, 0, nil)]
        var visited = Set<UInt>(), starts = Set<Int>(), result: [LabelRange] = []
        while let (node, depth, inheritedBounds) = stack.popLast() {
            guard depth < 64, visited.insert(pdfReferenceIdentity(node)).inserted,
                  visited.count <= 250_000 else { throw Failure.tooComplex }
            let lookupBounds: ClosedRange<Int>?
            // Preserve the source labels PDFKit actually displays. For a Kids
            // lookup, PDFKit skips a child outside its Limits and uses physical
            // page numbers; carrying its last range would change those labels.
            // A flat root Nums array keeps its existing range-carry semantics.
            if depth == 0 { lookupBounds = nil }
            else { lookupBounds = try labelLookupBounds(node, in: document, parent: inheritedBounds) }
            guard object(node, "Nums") == nil || object(node, "Kids") == nil else { throw Failure.invalidMetadata }
            if let kidsObject = object(node, "Kids") {
                guard let kids = array(kidsObject), CGPDFArrayGetCount(kids) <= 250_000 else { throw Failure.invalidMetadata }
                var previousUpperBound: Int?
                for index in 0..<CGPDFArrayGetCount(kids) {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(kids, index, &child), let child else { throw Failure.invalidMetadata }
                    let bounds = try labelLookupBounds(child, in: document, parent: lookupBounds)
                    guard previousUpperBound.map({ $0 < bounds.lowerBound }) != false else { throw Failure.invalidMetadata }
                    previousUpperBound = bounds.upperBound
                    stack.append((child, depth + 1, lookupBounds))
                }
            }
            if let numbersObject = object(node, "Nums") {
                guard let numbers = array(numbersObject), CGPDFArrayGetCount(numbers) % 2 == 0,
                      CGPDFArrayGetCount(numbers) <= 500_000 else { throw Failure.invalidMetadata }
                for index in stride(from: 0, to: CGPDFArrayGetCount(numbers), by: 2) {
                    var start: CGPDFInteger = 0
                    var label: CGPDFDictionaryRef?
                    guard CGPDFArrayGetInteger(numbers, index, &start), start >= 0, start < document.numberOfPages,
                          starts.insert(start).inserted, lookupBounds?.contains(start) != false,
                          CGPDFArrayGetDictionary(numbers, index + 1, &label), let label else { throw Failure.invalidMetadata }
                    var style: String?
                    if object(label, "S") != nil {
                        guard let value = name(label, "S"), ["D", "R", "r", "A", "a"].contains(value) else { throw Failure.invalidMetadata }
                        style = value
                    }
                    var number: CGPDFInteger = 1
                    if object(label, "St") != nil {
                        guard CGPDFDictionaryGetInteger(label, "St", &number), number > 0 else { throw Failure.invalidMetadata }
                    }
                    var prefix: Data?
                    if let value = object(label, "P") { prefix = try stringBytes(value) }
                    var unsupported = false
                    CGPDFDictionaryApplyBlock(label, { key, _, _ in
                        unsupported = !["S", "P", "St"].contains(String(cString: key))
                        return !unsupported
                    }, nil)
                    guard !unsupported else { throw Failure.invalidMetadata }
                    result.append(LabelRange(start: start, style: style, prefix: prefix, number: number, lookupBounds: lookupBounds))
                    guard result.count <= 250_000 else { throw Failure.tooComplex }
                }
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func labelLookupBounds(_ node: CGPDFDictionaryRef, in document: CGPDFDocument,
                                          parent: ClosedRange<Int>?) throws -> ClosedRange<Int> {
        guard let value = object(node, "Limits"), let limits = array(value),
              CGPDFArrayGetCount(limits) == 2 else { throw Failure.invalidMetadata }
        var lower: CGPDFInteger = 0, upper: CGPDFInteger = 0
        guard CGPDFArrayGetInteger(limits, 0, &lower), CGPDFArrayGetInteger(limits, 1, &upper),
              lower >= 0, lower <= upper, upper < document.numberOfPages,
              parent?.contains(lower) != false, parent?.contains(upper) != false else { throw Failure.invalidMetadata }
        return lower...upper
    }

    private static func readDestinationNames(in document: CGPDFDocument) throws -> DestinationNames {
        var result = DestinationNames()
        guard let catalog = document.catalog else { return result }
        if let value = object(catalog, "Dests") {
            guard let legacy = dictionary(value), CGPDFDictionaryGetCount(legacy) <= 250_000 else { throw Failure.invalidMetadata }
            result.hasLegacy = true
            CGPDFDictionaryApplyBlock(legacy, { key, value, _ in result.legacy[String(cString: key)] = value; return true }, nil)
        }
        guard let namesObject = object(catalog, "Names"), let names = dictionary(namesObject),
              let rootObject = object(names, "Dests") else { return result }
        guard let root = dictionary(rootObject) else { throw Failure.invalidMetadata }
        result.hasModern = true
        var stack: [(CGPDFDictionaryRef, Int)] = [(root, 0)], visited = Set<UInt>(), seen = Set<Data>()
        while let (node, depth) = stack.popLast() {
            guard depth < 64, visited.insert(pdfReferenceIdentity(node)).inserted,
                  visited.count <= 250_000 else { throw Failure.tooComplex }
            if let kidsObject = object(node, "Kids") {
                guard let kids = array(kidsObject), CGPDFArrayGetCount(kids) <= 250_000 else { throw Failure.invalidMetadata }
                for index in 0..<CGPDFArrayGetCount(kids) {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(kids, index, &child), let child else { throw Failure.invalidMetadata }
                    stack.append((child, depth + 1))
                }
            }
            if let valuesObject = object(node, "Names") {
                guard let values = array(valuesObject), CGPDFArrayGetCount(values) % 2 == 0,
                      CGPDFArrayGetCount(values) <= 500_000 else { throw Failure.invalidMetadata }
                for index in stride(from: 0, to: CGPDFArrayGetCount(values), by: 2) {
                    var key: CGPDFObjectRef?, value: CGPDFObjectRef?, nativeString: CGPDFStringRef?
                    guard CGPDFArrayGetObject(values, index, &key), let key,
                          CGPDFArrayGetObject(values, index + 1, &value), let value,
                          CGPDFObjectGetValue(key, .string, &nativeString), let nativeString else { throw Failure.invalidMetadata }
                    let bytes = try stringBytes(key)
                    guard seen.insert(bytes).inserted else { throw Failure.invalidMetadata }
                    let text = CGPDFStringCopyTextString(nativeString).map { $0 as String } ?? bytes.map { String(format: "%02X", $0) }.joined()
                    result.modern.append(NamedDestination(bytes: bytes, text: text, value: value))
                    guard result.modern.count <= 250_000 else { throw Failure.tooComplex }
                }
            }
        }
        return result
    }

    private static func resolvedDestination(_ original: CGPDFObjectRef, names: DestinationNames, depth: Int = 0) throws -> CGPDFArrayRef {
        guard depth < 64 else { throw Failure.tooComplex }
        if let direct = array(original) { return direct }
        if let dictionary = dictionary(original), let value = object(dictionary, "D") {
            return try resolvedDestination(value, names: names, depth: depth + 1)
        }
        if CGPDFObjectGetType(original) == .string {
            let bytes = try stringBytes(original)
            if let found = names.modern.first(where: { $0.bytes == bytes }) {
                return try resolvedDestination(found.value, names: names, depth: depth + 1)
            }
        } else if CGPDFObjectGetType(original) == .name {
            var name: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(original, .name, &name), let name else { throw Failure.invalidMetadata }
            if let found = names.legacy[String(cString: name)] {
                return try resolvedDestination(found, names: names, depth: depth + 1)
            }
        }
        throw Failure.invalidMetadata
    }

    private static func mappedDestination(_ original: CGPDFObjectRef, in group: PDFCatalogSourceGroup,
                                          names: DestinationNames) throws -> PDFCatalogGraphValue? {
        let destination: CGPDFArrayRef
        destination = try resolvedDestination(original, names: names)
        let count = CGPDFArrayGetCount(destination)
        guard count >= 2, count <= 6 else { throw Failure.invalidMetadata }
        var target: CGPDFDictionaryRef?, integerTarget: CGPDFInteger = -1
        let hasDictionary = CGPDFArrayGetDictionary(destination, 0, &target)
        let hasInteger = !hasDictionary && CGPDFArrayGetInteger(destination, 0, &integerTarget)
        guard hasDictionary || hasInteger else { throw Failure.invalidMetadata }
        let matching = group.pages.first { origin in
            if hasInteger { return origin.sourceIndex == integerTarget }
            return group.document.page(at: origin.sourceIndex + 1)?.dictionary == target
        }
        guard let matching else { return nil }
        var view: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(destination, 1, &view), let view else { throw Failure.invalidMetadata }
        let viewName = String(cString: view)
        guard let expectedCount = destinationArities[viewName], count <= expectedCount,
              viewName != "FitR" || count == expectedCount else { throw Failure.invalidMetadata }
        var values: [PDFCatalogGraphValue] = [.page(matching.outputIndex), .name(viewName)]
        for index in 2..<count {
            var parameter: CGPDFObjectRef?
            guard CGPDFArrayGetObject(destination, index, &parameter), let parameter,
                  [.integer, .real, .null].contains(CGPDFObjectGetType(parameter)) else { throw Failure.invalidMetadata }
            values.append(.original(parameter))
        }
        // Some published PDFs omit a trailing XYZ zoom (or other optional
        // coordinate). Explicit null retains the viewer's current value.
        while values.count < expectedCount { values.append(.null) }
        return .array(values)
    }

    private static func storedDestination(_ original: CGPDFObjectRef, in group: PDFCatalogSourceGroup,
                                          names: DestinationNames) throws -> PDFCatalogGraphValue? {
        // Stored definitions are data, not an active navigation request. Keep
        // an explicit null scalar or exactly one /D wrapper without guessing a
        // page. Aliases and active destinations still use the strict resolver.
        if CGPDFObjectGetType(original) == .null { return .original(original) }
        if let wrapper = dictionary(original), CGPDFDictionaryGetCount(wrapper) == 1,
           let value = object(wrapper, "D"), try preservedNullStoredDestination(value) != nil {
            return .original(original)
        }
        if let unusable = try preservedNullStoredDestination(original) { return unusable }
        guard let mapped = try mappedDestination(original, in: group, names: names) else { return nil }
        guard let dictionary = dictionary(original), object(dictionary, "D") != nil else { return mapped }
        guard CGPDFDictionaryGetCount(dictionary) <= 4_096 else { throw Failure.tooComplex }
        var entries: [String: PDFCatalogGraphValue] = [:]
        CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
            let key = String(cString: key)
            if key != "D" { entries[key] = .original(value) }
            return true
        }, nil)
        entries["D"] = mapped
        return .dictionary(entries)
    }

    private static func preservedEmptyOpeningAction(_ action: CGPDFDictionaryRef,
                                                    in group: PDFCatalogSourceGroup,
                                                    names: DestinationNames) throws -> Bool {
        guard CGPDFDictionaryGetCount(action) == 2, name(action, "S") == "GoTo",
              names.legacy[""] == nil,
              let target = object(action, "D"), CGPDFObjectGetType(target) == .name else { return false }
        var value: UnsafePointer<CChar>?
        guard CGPDFObjectGetValue(target, .name, &value), let value, value.pointee == 0,
              let source = group.rawStreamSource else { return false }
        return try source.provesOriginalEmptyOpeningAction(in: group.document, action: action)
    }

    /// Some published PDFs retain unused named destinations whose page target
    /// is explicitly null. Preserve that unusable definition without guessing
    /// a page. Active destinations and aliases still use mappedDestination's
    /// strict target check; only the stored array itself can take this route.
    private static func preservedNullStoredDestination(_ original: CGPDFObjectRef) throws -> PDFCatalogGraphValue? {
        guard let destination = array(original), CGPDFArrayGetCount(destination) >= 2 else { return nil }
        var target: CGPDFObjectRef?
        guard CGPDFArrayGetObject(destination, 0, &target), let target,
              CGPDFObjectGetType(target) == .null else { return nil }
        let count = CGPDFArrayGetCount(destination)
        var view: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(destination, 1, &view), let view,
              let expectedCount = destinationArities[String(cString: view)], count <= expectedCount,
              String(cString: view) != "FitR" || count == expectedCount else { throw Failure.invalidMetadata }
        for index in 2..<count {
            var parameter: CGPDFObjectRef?
            guard CGPDFArrayGetObject(destination, index, &parameter), let parameter else { throw Failure.invalidMetadata }
            switch CGPDFObjectGetType(parameter) {
            case .null: break
            case .integer, .real:
                var number: CGPDFReal = 0
                guard CGPDFArrayGetNumber(destination, index, &number), number.isFinite else { throw Failure.invalidMetadata }
            default: throw Failure.invalidMetadata
            }
        }
        return .original(original)
    }

    private static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &value) ? value : nil
    }
    private static func dictionary(_ object: CGPDFObjectRef) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFObjectGetValue(object, .dictionary, &value) ? value : nil
    }
    private static func array(_ object: CGPDFObjectRef) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        return CGPDFObjectGetValue(object, .array, &value) ? value : nil
    }
    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
    private static func stringBytes(_ object: CGPDFObjectRef) throws -> Data {
        var value: CGPDFStringRef?
        guard CGPDFObjectGetValue(object, .string, &value), let value else { throw Failure.invalidMetadata }
        let count = CGPDFStringGetLength(value)
        guard count <= 1_048_576 else { throw Failure.tooComplex }
        guard count > 0 else { return Data() }
        guard let bytes = CGPDFStringGetBytePtr(value) else { throw Failure.invalidMetadata }
        return Data(bytes: bytes, count: count)
    }
    private static func unicodeBytes(_ text: String) -> Data {
        var result = Data([0xFE, 0xFF])
        for value in text.utf16 { result.append(UInt8(value >> 8)); result.append(UInt8(value & 0xFF)) }
        return result
    }
}
