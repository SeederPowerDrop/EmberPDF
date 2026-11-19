// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Merges configurations against the same OCG nodes used by live page
/// resources. A source's global state/usage rules never spill into another
/// imported document's groups.
enum PDFOptionalContentPreserver {
    enum Failure: LocalizedError {
        case invalidMetadata, conflictingIntents, tooComplex
        var errorDescription: String? {
            switch self {
            case .tooComplex:
                return L10n.string("page_structure.error.too_complex", defaultValue: "문서 구조가 너무 복잡하여 안전하게 페이지를 조립하지 못했습니다. 원본은 변경되지 않았습니다.")
            case .invalidMetadata, .conflictingIntents:
                return L10n.string("page_structure.error.unsupported", defaultValue: "이 PDF의 특수 구조를 페이지 조립 후 안전하게 유지할 수 없습니다. 원본은 변경되지 않았습니다.")
            }
        }
    }

    private struct Source {
        let groupIndex: Int
        let document: CGPDFDocument
        let properties: CGPDFDictionaryRef
        let groups: [UInt]
        let groupIdentities: Set<UInt>
        let defaultConfiguration: CGPDFDictionaryRef?
        let alternatives: [CGPDFDictionaryRef]
        let intents: Set<String>
        let budget: Budget
    }
    private final class Budget {
        private var visits = 0
        func consume(_ count: Int) throws {
            guard count >= 0, count <= 2_000_000 - visits else { throw Failure.tooComplex }
            visits += count
        }
    }
    private struct State {
        var on: Set<UInt>
        var off: Set<UInt>
    }
    private struct UI {
        var order: [PDFCatalogGraphValue] = []
        var locked: [UInt] = []
        var radio: [PDFCatalogGraphValue] = []
        var usage: [PDFCatalogGraphValue] = []
    }

    static func addOptionalContent(from groups: [PDFCatalogSourceGroup], to plan: inout PDFCatalogGraphPlan) throws {
        var sources: [Source] = [], seenProperties = Set<UInt>()
        let budget = Budget()
        var nodes: [UInt: PDFCatalogGraphNode] = [:], order: [UInt] = []
        for (groupIndex, group) in groups.enumerated() {
            guard let catalog = group.document.catalog, let value = object(catalog, "OCProperties") else { continue }
            guard let properties = dictionary(value) else { throw Failure.invalidMetadata }
            guard seenProperties.insert(identity(properties)).inserted else { continue }
            var sourceGroups: [UInt] = [], sourceIdentities = Set<UInt>()
            for original in try arrayValues(object(properties, "OCGs"), budget: budget) {
                guard let dictionary = dictionary(original), name(dictionary, "Type") == "OCG" else { throw Failure.invalidMetadata }
                let key = identity(dictionary)
                if sourceIdentities.insert(key).inserted { sourceGroups.append(key) }
                if nodes[key] == nil {
                    if let existing = plan.aliases[key] {
                        guard case .node(let node) = existing else { throw Failure.invalidMetadata }
                        nodes[key] = node
                    } else { nodes[key] = PDFCatalogGraphNode(entries: try originalEntries(dictionary, budget: budget)) }
                    order.append(key)
                    guard order.count <= 100_000 else { throw Failure.tooComplex }
                }
            }
            let configuration = try optionalDictionary(object(properties, "D"))
            let alternatives = try arrayValues(object(properties, "Configs"), budget: budget).map { value -> CGPDFDictionaryRef in
                guard let dictionary = dictionary(value) else { throw Failure.invalidMetadata }
                return dictionary
            }
            sources.append(Source(groupIndex: groupIndex, document: group.document, properties: properties,
                groups: sourceGroups, groupIdentities: sourceIdentities, defaultConfiguration: configuration, alternatives: alternatives,
                intents: try configurationIntents(configuration, budget: budget), budget: budget))
        }
        guard !sources.isEmpty else { return }
        let activeSources = sources.filter { !$0.groups.isEmpty }
        let intents = activeSources.first?.intents ?? ["View"]
        guard activeSources.allSatisfy({ $0.intents == intents }) else { throw Failure.conflictingIntents }

        var defaultOn = Set<UInt>(), defaultOff = Set<UInt>(), defaultUI = UI()
        var sourceUI: [UI] = []
        for source in sources {
            let states = try state(source.defaultConfiguration, source: source, allowUnchanged: false)
            guard defaultOn.isDisjoint(with: states.off), defaultOff.isDisjoint(with: states.on) else { throw Failure.invalidMetadata }
            defaultOn.formUnion(states.on); defaultOff.formUnion(states.off)
            let ui = try configurationUI(source.defaultConfiguration, source: source, nodes: nodes)
            sourceUI.append(ui)
            append(ui, to: &defaultUI, wrapOrder: activeSources.count > 1)
        }
        var defaults: [String: PDFCatalogGraphValue] = [:]
        if let first = sources.first?.defaultConfiguration {
            defaults = try originalEntries(first, budget: budget)
        }
        defaults["BaseState"] = .name("ON")
        defaults["ON"] = nodeArray(order.filter { defaultOn.contains($0) }, nodes: nodes)
        defaults["OFF"] = nodeArray(order.filter { defaultOff.contains($0) }, nodes: nodes)
        defaults["Intent"] = .array(intents.sorted().map(PDFCatalogGraphValue.name))
        setUI(defaultUI, in: &defaults, nodes: nodes)

        var alternativeValues: [PDFCatalogGraphValue] = [], usedNames = Set<String>()
        if let first = sources.first?.defaultConfiguration, let value = text(first, "Name") { usedNames.insert(value) }
        for (sourceIndex, source) in sources.enumerated() {
            var configurations = source.alternatives
            // A merged default has one Name/Creator/UI dictionary. Retain each
            // source default as an independently applicable configuration too.
            if activeSources.count > 1, let original = source.defaultConfiguration { configurations.insert(original, at: 0) }
            for (configurationIndex, configuration) in configurations.enumerated() {
                try budget.consume(source.groups.count * 2 + sources.count + defaultUI.locked.count + defaultUI.radio.count + defaultUI.usage.count)
                let alternativeIntents = try configurationIntents(configuration, budget: budget)
                if activeSources.count > 1, alternativeIntents != intents { throw Failure.conflictingIntents }
                var entries = try originalEntries(configuration, budget: budget)
                let state = try state(configuration, source: source, allowUnchanged: true)
                entries["BaseState"] = .name("Unchanged")
                entries["ON"] = nodeArray(source.groups.filter { state.on.contains($0) }, nodes: nodes)
                entries["OFF"] = nodeArray(source.groups.filter { state.off.contains($0) }, nodes: nodes)
                var combinedUI = UI()
                for otherIndex in sources.indices {
                    if otherIndex == sourceIndex {
                        let own = try configurationUI(configuration, source: source, nodes: nodes,
                            inheritedOrder: sourceUI[sourceIndex].order, inheritedRadio: sourceUI[sourceIndex].radio)
                        append(own, to: &combinedUI, wrapOrder: activeSources.count > 1)
                    } else { append(sourceUI[otherIndex], to: &combinedUI, wrapOrder: activeSources.count > 1) }
                }
                setUI(combinedUI, in: &entries, nodes: nodes)
                let originalName = text(configuration, "Name")
                var displayName = originalName ?? "Source \(source.groupIndex + 1) configuration \(configurationIndex + 1)"
                var suffix = 1
                while usedNames.contains(displayName) {
                    displayName = "Source \(source.groupIndex + 1)-\(suffix): " + (originalName ?? "Configuration \(configurationIndex + 1)")
                    suffix += 1
                    guard suffix <= 100_000 else { throw Failure.tooComplex }
                }
                usedNames.insert(displayName)
                if originalName != displayName { entries["Name"] = .string(unicodeBytes(displayName)) }
                alternativeValues.append(.dictionary(entries))
                guard alternativeValues.count <= 100_000 else { throw Failure.tooComplex }
            }
        }
        var properties = try originalEntries(sources[0].properties, budget: budget)
        properties["OCGs"] = nodeArray(order, nodes: nodes)
        properties["D"] = .dictionary(defaults)
        properties["Configs"] = .array(alternativeValues)
        // Commit only after every source/configuration has been validated.
        plan.catalogEntries["OCProperties"] = .dictionary(properties)
        for (key, node) in nodes { plan.aliases[key] = .node(node) }
        plan.retainedDocuments.append(contentsOf: sources.map(\.document))
    }

    private static func state(_ configuration: CGPDFDictionaryRef?, source: Source, allowUnchanged: Bool) throws -> State {
        let base = configuration.flatMap { name($0, "BaseState") } ?? "ON"
        guard ["ON", "OFF", "Unchanged"].contains(base) else { throw Failure.invalidMetadata }
        let on = try identifiers(configuration.flatMap { object($0, "ON") }, source: source)
        let off = try identifiers(configuration.flatMap { object($0, "OFF") }, source: source)
        guard Set(on).isDisjoint(with: off) else { throw Failure.invalidMetadata }
        if base == "Unchanged", allowUnchanged { return State(on: Set(on), off: Set(off)) }
        try source.budget.consume(source.groups.count)
        // Initial document load has no prior per-document context; the base is
        // ON unless the source explicitly supplies OFF. Output D is always ON.
        var states = Dictionary(uniqueKeysWithValues: source.groups.map { ($0, base != "OFF") })
        for key in on { states[key] = true }
        for key in off { states[key] = false }
        return State(on: Set(states.filter(\.value).map(\.key)), off: Set(states.filter { !$0.value }.map(\.key)))
    }

    private static func configurationUI(_ configuration: CGPDFDictionaryRef?, source: Source,
                                         nodes: [UInt: PDFCatalogGraphNode],
                                         inheritedOrder: [PDFCatalogGraphValue] = [],
                                         inheritedRadio: [PDFCatalogGraphValue] = []) throws -> UI {
        var result = UI()
        if let order = configuration.flatMap({ object($0, "Order") }) {
            var visits = 0
            result.order = try orderValues(order, source: source, nodes: nodes, depth: 0, visits: &visits)
        } else { result.order = inheritedOrder }
        result.locked = try identifiers(configuration.flatMap { object($0, "Locked") }, source: source)
        if let radio = configuration.flatMap({ object($0, "RBGroups") }) {
            result.radio = try arrayValues(radio, budget: source.budget).map { nodeArray(try identifiers($0, source: source), nodes: nodes) }
        } else { result.radio = inheritedRadio }
        for original in try arrayValues(configuration.flatMap { object($0, "AS") }, budget: source.budget) {
            guard let dictionary = dictionary(original) else { throw Failure.invalidMetadata }
            var entries = try originalEntries(dictionary, budget: source.budget)
            // Missing OCGs means all groups in the source document, not all
            // groups of the newly assembled document.
            if let originalGroups = object(dictionary, "OCGs") {
                entries["OCGs"] = nodeArray(try identifiers(originalGroups, source: source), nodes: nodes)
            } else { entries["OCGs"] = nodeArray(source.groups, nodes: nodes) }
            result.usage.append(.dictionary(entries))
        }
        return result
    }

    private static func append(_ source: UI, to destination: inout UI, wrapOrder: Bool) {
        if !source.order.isEmpty {
            if wrapOrder { destination.order.append(.array(source.order)) } else { destination.order += source.order }
        }
        var locked = Set(destination.locked)
        for key in source.locked where locked.insert(key).inserted { destination.locked.append(key) }
        destination.radio += source.radio
        destination.usage += source.usage
    }
    private static func setUI(_ ui: UI, in configuration: inout [String: PDFCatalogGraphValue], nodes: [UInt: PDFCatalogGraphNode]) {
        configuration["Order"] = .array(ui.order)
        configuration["Locked"] = nodeArray(ui.locked, nodes: nodes)
        configuration["RBGroups"] = .array(ui.radio)
        configuration["AS"] = .array(ui.usage)
    }
    private static func orderValues(_ original: CGPDFObjectRef, source: Source, nodes: [UInt: PDFCatalogGraphNode],
                                    depth: Int, visits: inout Int) throws -> [PDFCatalogGraphValue] {
        guard depth < 64 else { throw Failure.tooComplex }
        return try arrayValues(original, budget: source.budget).map { value in
            visits += 1
            guard visits <= 100_000 else { throw Failure.tooComplex }
            switch CGPDFObjectGetType(value) {
            case .array: return .array(try orderValues(value, source: source, nodes: nodes, depth: depth + 1, visits: &visits))
            case .string: return .original(value)
            case .dictionary:
                guard let dictionary = dictionary(value), source.groupIdentities.contains(identity(dictionary)),
                      let node = nodes[identity(dictionary)] else { throw Failure.invalidMetadata }
                return .node(node)
            default: throw Failure.invalidMetadata
            }
        }
    }
    private static func identifiers(_ original: CGPDFObjectRef?, source: Source) throws -> [UInt] {
        var result: [UInt] = [], seen = Set<UInt>()
        for value in try arrayValues(original, budget: source.budget) {
            guard let dictionary = dictionary(value), source.groupIdentities.contains(identity(dictionary)) else { throw Failure.invalidMetadata }
            let key = identity(dictionary)
            if seen.insert(key).inserted { result.append(key) }
        }
        return result
    }
    private static func nodeArray(_ keys: [UInt], nodes: [UInt: PDFCatalogGraphNode]) -> PDFCatalogGraphValue {
        .array(keys.compactMap { nodes[$0].map(PDFCatalogGraphValue.node) })
    }
    private static func configurationIntents(_ configuration: CGPDFDictionaryRef?, budget: Budget) throws -> Set<String> {
        guard let value = configuration.flatMap({ object($0, "Intent") }) else { return ["View"] }
        if CGPDFObjectGetType(value) == .name { return [try nameValue(value)] }
        let values = try arrayValues(value, budget: budget)
        return Set(try values.map(nameValue))
    }
    private static func originalEntries(_ dictionary: CGPDFDictionaryRef, budget: Budget) throws -> [String: PDFCatalogGraphValue] {
        guard CGPDFDictionaryGetCount(dictionary) <= 4_096 else { throw Failure.tooComplex }
        try budget.consume(CGPDFDictionaryGetCount(dictionary))
        var entries: [String: PDFCatalogGraphValue] = [:], error: Error?
        CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
            guard strnlen(key, 4_096) < 4_096 else { error = Failure.tooComplex; return false }
            entries[String(cString: key)] = .original(value)
            return true
        }, nil)
        if let error { throw error }
        return entries
    }
    private static func arrayValues(_ value: CGPDFObjectRef?, budget: Budget) throws -> [CGPDFObjectRef] {
        guard let value else { return [] }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(value, .array, &array), let array, CGPDFArrayGetCount(array) <= 100_000 else { throw Failure.invalidMetadata }
        try budget.consume(CGPDFArrayGetCount(array))
        return try (0..<CGPDFArrayGetCount(array)).map { index in
            var value: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, index, &value), let value else { throw Failure.invalidMetadata }
            return value
        }
    }
    private static func optionalDictionary(_ value: CGPDFObjectRef?) throws -> CGPDFDictionaryRef? {
        guard let value else { return nil }
        guard let dictionary = dictionary(value) else { throw Failure.invalidMetadata }
        return dictionary
    }
    private static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &value) ? value : nil
    }
    private static func dictionary(_ object: CGPDFObjectRef) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFObjectGetValue(object, .dictionary, &value) ? value : nil
    }
    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
    private static func nameValue(_ object: CGPDFObjectRef) throws -> String {
        var value: UnsafePointer<CChar>?
        guard CGPDFObjectGetValue(object, .name, &value), let value else { throw Failure.invalidMetadata }
        return String(cString: value)
    }
    private static func text(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value, let text = CGPDFStringCopyTextString(value) else { return nil }
        return text as String
    }
    private static func identity(_ dictionary: CGPDFDictionaryRef) -> UInt { pdfReferenceIdentity(dictionary) }
    private static func unicodeBytes(_ text: String) -> Data {
        var result = Data([0xFE, 0xFF])
        for value in text.utf16 { result.append(UInt8(value >> 8)); result.append(UInt8(value & 0xFF)) }
        return result
    }
}
