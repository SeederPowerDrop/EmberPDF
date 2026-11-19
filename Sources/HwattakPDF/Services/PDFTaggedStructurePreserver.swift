// SPDX-License-Identifier: MPL-2.0

import Foundation
import CoreGraphics
import PDFKit

/// Rebuilds the tagged-PDF links that refer to a selected source page graph.
/// MCIDs remain unchanged in the painting streams; only document-wide parent
/// keys and page/annotation references are remapped. No source object is edited.
enum PDFTaggedStructurePreserver {
    enum Failure: Error {
        case invalidStructure, unsupportedReference, tooComplex
        case annotationSemanticConflict(Set<Int>)
    }
    private typealias Value = PDFCatalogGraphValue
    private typealias Node = PDFCatalogGraphNode

    static func addPreservedTags(from groups: [PDFCatalogSourceGroup], to plan: inout PDFCatalogGraphPlan) throws {
        try PDFSaveCancellation.checkCurrent()
        let builder = Builder()
        for (index, group) in groups.enumerated() { try builder.add(group, namespace: index) }
        try PDFSaveCancellation.checkCurrent()
        try builder.commit(to: &plan)
    }

    private enum PageContext { case unknown, excluded, output(Int) }
    private struct AnnotationOrigin { let page: Int; let index: Int; let sourceIndex: Int; let dictionary: CGPDFDictionaryRef }
    private struct Element {
        let dictionary: CGPDFDictionaryRef
        let parent: CGPDFDictionaryRef?
        let node: Node
    }
    private struct ParentUse {
        let key: Int
        let output: Int?
        let annotation: AnnotationOrigin?
        let streamDictionary: CGPDFDictionaryRef?
    }

    private final class Builder {
        private let maximumVisits = 500_000
        private var visits = 0
        private let root = Node()
        private var roots: [Value] = []
        private var aliases: [UInt: Value] = [:]
        private var pageEntries: [Int: [String: Value]] = [:]
        private var annotationEntries: [Int: [Int: [String: Value]]] = [:]
        private var dictionaryOverrides: [UInt: [String: Value]] = [:]
        private var roleMap: [String: Value] = [:]
        private var classMap: [String: Value] = [:]
        private var namespaces: [Value] = []
        private var ids: [(Data, Value)] = []
        private var parentNums: [(Int, Value)] = []
        private var nextParentKey = 0
        private var documents: [CGPDFDocument] = []
        private var marked = false
        private var hadSourceKids = false
        private var suspects = false
        private var userProperties = false

        // Per independent source-document namespace.
        private var pages: [UInt: Int] = [:]
        private var annotations: [UInt: AnnotationOrigin] = [:]
        private var sourceParents: [Int: CGPDFObjectRef] = [:]
        private var pageParentKeys: [Int: Int] = [:]
        private var forwardPageParents: [Int: [Int: CGPDFDictionaryRef]] = [:]
        private var uses: [Int: ParentUse] = [:]
        private var streamOwners: [Int: [UInt: CGPDFDictionaryRef]] = [:]
        private var elements: [UInt: Element] = [:]
        private var visiting = Set<UInt>()
        private var finished = Set<UInt>()
        private var rejected = Set<UInt>()
        private var roleNames: [String: String] = [:]
        private var classNames: [String: String] = [:]
        private var importingDetachedForest = false
        private var sourceRoot: CGPDFDictionaryRef?
        private var bodyTagPermissions: [Int: PDFBodyEditedTagPreserver.Permission] = [:]
        private var bodyTagDocument: CGPDFDocument?
        private var annotationTagPermissions: [Int: PDFCatalogStructurePreserver.AnnotationTagPermission] = [:]
        private var annotationOnlyPages = Set<Int>()
        private var suppressedPainting = 0
        private var survivingAnnotationPages: [Int] = []
        private var semanticConflictPages = Set<Int>()
        private var sourceLanguage: CGPDFObjectRef?
        private var namespace = ""

        func add(_ group: PDFCatalogSourceGroup, namespace index: Int) throws {
            try PDFSaveCancellation.checkCurrent()
            guard let catalog = group.document.catalog else { throw Failure.invalidStructure }
            for origin in group.pages {
                guard let page = group.document.page(at: origin.sourceIndex + 1), let dictionary = page.dictionary else { throw Failure.invalidStructure }
                if let list = array(dictionary, "Annots") {
                    guard CGPDFArrayGetCount(list) <= 100_000 else { throw Failure.tooComplex }
                    if let indexes = origin.annotationIndexes {
                        let count = origin.livePage.annotations.count
                        guard indexes.keys.allSatisfy({ $0 >= 0 && $0 < CGPDFArrayGetCount(list) }),
                              indexes.values.allSatisfy({ $0 >= 0 && $0 < count }),
                              Set(indexes.values).count == indexes.count else { throw Failure.invalidStructure }
                    }
                    for index in 0..<CGPDFArrayGetCount(list) {
                        guard let mappedIndex = annotationIndex(index, in: origin) else { continue }
                        guard let annotation = arrayDictionary(list, index) else { throw Failure.invalidStructure }
                        let key = identity(annotation)
                        if let previous = aliases[key] {
                            guard case .annotation(let page, let annotationIndex) = previous,
                                  page == origin.outputIndex, annotationIndex == mappedIndex else { throw Failure.invalidStructure }
                        }
                        aliases[key] = .annotation(page: origin.outputIndex, index: mappedIndex)
                    }
                }
            }
            guard let structure = object(catalog, "StructTreeRoot"), CGPDFObjectGetType(structure) != .null else { return }
            guard let sourceRoot = objectDictionary(structure) else { throw Failure.invalidStructure }
            let rootKey = identity(sourceRoot)
            guard aliases[rootKey] == nil else { throw Failure.invalidStructure }
            documents.append(group.document)
            marked = true
            if let info = readDictionary(catalog, "MarkInfo") {
                suspects = suspects || boolean(info, "Suspects") == true
                userProperties = userProperties || boolean(info, "UserProperties") == true
            }
            self.sourceRoot = sourceRoot
            sourceLanguage = object(catalog, "Lang")
            namespace = "EmberTag\(index)_"
            pages = [:]; annotations = [:]; sourceParents = [:]; pageParentKeys = [:]; forwardPageParents = [:]; uses = [:]; streamOwners = [:]
            bodyTagPermissions = [:]; bodyTagDocument = group.document
            annotationTagPermissions = [:]; annotationOnlyPages = []
            suppressedPainting = 0; survivingAnnotationPages = []
            for origin in group.pages {
                if let permission = origin.annotationTagPermission {
                    guard permission.tagDocument === group.document,
                          permission.sourceIndex == origin.sourceIndex,
                          permission.outputIndex == origin.outputIndex,
                          permission.matchesCurrent(origin.livePage) else { throw Failure.invalidStructure }
                    annotationTagPermissions[origin.outputIndex] = permission
                }
                if !origin.contentUnchanged {
                    if let permission = origin.bodyTagPermission {
                        guard permission.tagDocument === group.document,
                              permission.sourceIndex == origin.sourceIndex,
                              permission.matchesCurrent(origin.livePage) else { throw Failure.invalidStructure }
                        bodyTagPermissions[origin.outputIndex] = permission
                    } else {
                        guard origin.annotationTagPermission != nil else { throw Failure.invalidStructure }
                        annotationOnlyPages.insert(origin.outputIndex)
                    }
                }
            }
            elements = [:]; visiting = []; finished = []; rejected = []; roleNames = [:]; classNames = [:]
            var selected = Set<Int>()
            for origin in group.pages {
                guard origin.sourceIndex >= 0, origin.sourceIndex < group.document.numberOfPages,
                      origin.outputIndex >= 0, selected.insert(origin.sourceIndex).inserted,
                      let page = group.document.page(at: origin.sourceIndex + 1), let dictionary = page.dictionary,
                      pages.updateValue(origin.outputIndex, forKey: identity(dictionary)) == nil else { throw Failure.invalidStructure }
                if !annotationOnlyPages.contains(origin.outputIndex), object(dictionary, "StructParents") != nil {
                    guard let key = integer(dictionary, "StructParents"), key >= 0,
                          pageParentKeys.updateValue(key, forKey: origin.outputIndex) == nil else { throw Failure.invalidStructure }
                }
                if let array = array(dictionary, "Annots") {
                    guard CGPDFArrayGetCount(array) <= 100_000 else { throw Failure.tooComplex }
                    for index in 0..<CGPDFArrayGetCount(array) {
                        guard let mappedIndex = annotationIndex(index, in: origin) else { continue }
                        guard let annotation = arrayDictionary(array, index) else { throw Failure.invalidStructure }
                        let location = AnnotationOrigin(page: origin.outputIndex, index: mappedIndex, sourceIndex: index, dictionary: annotation)
                        guard annotations.updateValue(location, forKey: identity(annotation)) == nil else { throw Failure.invalidStructure }
                        aliases[identity(annotation)] = .annotation(page: location.page, index: location.index)
                    }
                }
            }
            if let tree = readDictionary(sourceRoot, "ParentTree") { sourceParents = try numberTree(tree) }
            else if object(sourceRoot, "ParentTree") != nil { throw Failure.invalidStructure }
            for (output, key) in pageParentKeys {
                try registerUse(ParentUse(key: key, output: output, annotation: nil, streamDictionary: nil))
            }
            for annotation in annotations.values where object(annotation.dictionary, "StructParent") != nil {
                guard let key = integer(annotation.dictionary, "StructParent"), key >= 0 else { throw Failure.invalidStructure }
                try registerUse(ParentUse(key: key, output: nil, annotation: annotation, streamDictionary: nil))
            }
            try collectReachableForms(group)
            try collectMaps(sourceRoot)
            let rebuilt: Set<String> = ["Type", "K", "ParentTree", "ParentTreeNextKey", "RoleMap", "ClassMap", "IDTree", "Namespaces"]
            for (key, value) in try entries(sourceRoot) where !rebuilt.contains(key) && root.entries[key] == nil {
                root.entries[key] = .original(value)
            }
            aliases[rootKey] = .node(root)
            if let kids = object(sourceRoot, "K") {
                hadSourceKids = true
                roots.append(contentsOf: try children(kids, context: .unknown, parent: sourceRoot, depth: 0))
            }
            // The original can contain ParentTree-only disconnected forests.
            // Preserve only factory-bound, verified surviving annotation paths.
            // Snapshot root traversal state before importing any such forest.
            try preserveDetachedAnnotationForests(group, rootFinished: finished, rootRejected: rejected)
            // Make all parent references lazy original-dictionary references.
            // The aliases resolve them to nodes during writing, avoiding Swift
            // strong-reference cycles between /P and /K.
            for element in elements.values {
                let key = identity(element.dictionary)
                aliases[key] = .node(element.node)
                element.node.entries["P"] = element.parent.map { .dictionaryReference($0) }
                if let refs = object(element.dictionary, "Ref") {
                    let values = try referencedElements(refs)
                    if !values.isEmpty { element.node.entries["Ref"] = .array(values) }
                }
            }
            try collectIDs(sourceRoot)
            try materializeParents(from: group)
            for origin in group.pages {
                if let permission = origin.annotationTagPermission {
                    guard permission.matchesCurrent(origin.livePage) else { throw Failure.invalidStructure }
                }
            }
        }

        private func annotationIndex(_ sourceIndex: Int, in origin: PDFCatalogPageOrigin) -> Int? {
            // A nil map is retained for direct graph-builder fixtures. The
            // production plan always supplies a lineage map, including an empty
            // map after every source annotation has been removed.
            if !origin.contentUnchanged {
                return origin.annotationTagPermission?.indexes[sourceIndex]
            }
            if let indexes = origin.annotationIndexes { return indexes[sourceIndex] }
            return sourceIndex
        }

        func commit(to plan: inout PDFCatalogGraphPlan) throws {
            guard semanticConflictPages.isEmpty else { throw Failure.annotationSemanticConflict(semanticConflictPages) }
            guard marked else {
                plan.aliases.merge(aliases) { _, new in new }
                return
            }
            root.entries["Type"] = .name("StructTreeRoot")
            if hadSourceKids { root.entries["K"] = .array(roots) }
            if !roleMap.isEmpty { root.entries["RoleMap"] = .dictionary(roleMap) }
            if !classMap.isEmpty { root.entries["ClassMap"] = .dictionary(classMap) }
            if !namespaces.isEmpty { root.entries["Namespaces"] = .array(namespaces) }
            if !parentNums.isEmpty {
                root.entries["ParentTree"] = balancedTree(parentNums.sorted(by: { $0.0 < $1.0 }).map { (.integer($0.0), $0.1) }, nameTree: false)
                root.entries["ParentTreeNextKey"] = .integer(nextParentKey)
            }
            if !ids.isEmpty {
                ids.sort { $0.0.lexicographicallyPrecedes($1.0) }
                guard Set(ids.map(\.0)).count == ids.count else { throw Failure.invalidStructure }
                root.entries["IDTree"] = balancedTree(ids.map { (.string($0.0), $0.1) }, nameTree: true)
            }
            plan.catalogEntries["StructTreeRoot"] = .node(root)
            var info: [String: Value] = ["Marked": .boolean(true)]
            if suspects { info["Suspects"] = .boolean(true) }
            if userProperties { info["UserProperties"] = .boolean(true) }
            plan.catalogEntries["MarkInfo"] = .dictionary(info)
            plan.aliases.merge(aliases) { _, new in new }
            for (page, entries) in pageEntries { plan.pageEntries[page, default: [:]].merge(entries) { _, new in new } }
            for (page, annotations) in annotationEntries {
                for (index, entries) in annotations { plan.annotationEntries[page, default: [:]][index, default: [:]].merge(entries) { _, new in new } }
            }
            for (key, entries) in dictionaryOverrides { plan.dictionaryOverrides[key, default: [:]].merge(entries) { _, new in new } }
            plan.retainedDocuments.append(contentsOf: documents)
        }

        private func balancedTree(_ pairs: [(Value, Value)], nameTree: Bool) -> Value {
            struct Branch { let first: Value; let last: Value; let value: Value }
            var level: [Branch] = []
            for start in stride(from: 0, to: pairs.count, by: 128) {
                let chunk = Array(pairs[start..<min(start + 128, pairs.count)])
                let entries = chunk.flatMap { [$0.0, $0.1] }
                let value = Value.dictionary([nameTree ? "Names" : "Nums": .array(entries),
                    "Limits": .array([chunk[0].0, chunk[chunk.count - 1].0])])
                level.append(Branch(first: chunk[0].0, last: chunk[chunk.count - 1].0, value: value))
            }
            while level.count > 1 {
                var next: [Branch] = []
                for start in stride(from: 0, to: level.count, by: 128) {
                    let chunk = Array(level[start..<min(start + 128, level.count)])
                    let first = chunk[0].first, last = chunk[chunk.count - 1].last
                    let value = Value.dictionary(["Kids": .array(chunk.map(\.value)), "Limits": .array([first, last])])
                    next.append(Branch(first: first, last: last, value: value))
                }
                level = next
            }
            return level.first?.value ?? .dictionary([nameTree ? "Names" : "Nums": .array([])])
        }

        private func collectMaps(_ source: CGPDFDictionaryRef) throws {
            if let roles = readDictionary(source, "RoleMap") {
                for (name, _) in try entries(roles) { roleNames[name] = namespace + name }
                for (name, value) in try entries(roles) {
                    let mapped: Value
                    if let role = objectName(value) { mapped = .name(roleNames[role] ?? role) }
                    else { mapped = .original(value) }
                    roleMap[roleNames[name]!] = mapped
                }
            }
            if let classes = readDictionary(source, "ClassMap") {
                for (name, value) in try entries(classes) {
                    let renamed = namespace + name
                    classNames[name] = renamed
                    classMap[renamed] = .original(value)
                }
            }
            if let list = array(source, "Namespaces") {
                guard CGPDFArrayGetCount(list) <= 4_096 else { throw Failure.tooComplex }
                for index in 0..<CGPDFArrayGetCount(list) {
                    guard let value = arrayObject(list, index) else { throw Failure.invalidStructure }
                    namespaces.append(.original(value))
                }
            }
        }

        private func children(_ value: CGPDFObjectRef, context: PageContext,
                              parent: CGPDFDictionaryRef, depth: Int) throws -> [Value] {
            try visit(depth)
            switch CGPDFObjectGetType(value) {
            case .null: return []
            case .array:
                guard let array = objectArray(value), CGPDFArrayGetCount(array) <= 100_000 else { throw Failure.invalidStructure }
                var result: [Value] = []
                for index in 0..<CGPDFArrayGetCount(array) {
                    guard let child = arrayObject(array, index) else { throw Failure.invalidStructure }
                    result += try children(child, context: context, parent: parent, depth: depth + 1)
                }
                return result
            case .integer:
                guard let mcid = objectInteger(value), mcid >= 0 else { throw Failure.invalidStructure }
                return try markedContent(mcid: mcid, source: nil, context: context, owner: parent).map { [$0] } ?? []
            case .dictionary:
                guard let dictionary = objectDictionary(value) else { throw Failure.invalidStructure }
                if dictionaryName(dictionary, "Type") == "OBJR" || object(dictionary, "Obj") != nil {
                    guard let target = readDictionary(dictionary, "Obj") else { throw Failure.unsupportedReference }
                    guard let annotation = annotations[identity(target)] else { return [] }
                    var copied = try copiedEntries(dictionary, dropping: ["Pg", "Obj"])
                    copied["Type"] = .name("OBJR")
                    copied["Pg"] = .page(annotation.page)
                    copied["Obj"] = .annotation(page: annotation.page, index: annotation.index)
                    if annotationOnlyPages.contains(annotation.page) {
                        survivingAnnotationPages.append(annotation.page)
                    }
                    return [.dictionary(copied)]
                }
                if dictionaryName(dictionary, "Type") == "MCR" || object(dictionary, "MCID") != nil {
                    guard let mcid = integer(dictionary, "MCID"), mcid >= 0 else { throw Failure.invalidStructure }
                    return try markedContent(mcid: mcid, source: dictionary,
                        context: try pageContext(dictionary, inherited: context), owner: parent).map { [$0] } ?? []
                }
                return try element(dictionary, context: context, parent: parent, depth: depth + 1).map { [.node($0)] } ?? []
            default:
                throw Failure.invalidStructure
            }
        }

        private func element(_ dictionary: CGPDFDictionaryRef, context inherited: PageContext,
                             parent: CGPDFDictionaryRef?, depth: Int) throws -> Node? {
            try visit(depth)
            let key = identity(dictionary)
            // The ordinary root walk retains its established policy. A new
            // detached import must never synthesize a missing descendant P.
            if importingDetachedForest, parent != nil, object(dictionary, "P") == nil { throw Failure.invalidStructure }
            guard !visiting.contains(key) else { throw Failure.invalidStructure }
            if let previous = elements[key] {
                guard previous.parent.map(identity) == parent.map(identity) else { throw Failure.invalidStructure }
                return previous.node
            }
            if rejected.contains(key) { return nil }
            guard !finished.contains(key), let role = dictionaryName(dictionary, "S") else { throw Failure.invalidStructure }
            if object(dictionary, "P") != nil {
                guard let declaredParent = readDictionary(dictionary, "P"), let parent, identity(declaredParent) == identity(parent) else { throw Failure.invalidStructure }
            }
            visiting.insert(key)
            defer { visiting.remove(key); finished.insert(key) }
            let context = try pageContext(dictionary, inherited: inherited)
            let sourceKids = object(dictionary, "K")
            let beforeSuppressed = suppressedPainting, beforeAnnotations = survivingAnnotationPages.count
            let kids = try sourceKids.map { try children($0, context: context, parent: dictionary, depth: depth + 1) } ?? []
            let hasContent = !kids.isEmpty
            if suppressedPainting > beforeSuppressed,
               ["ActualText", "Alt", "E", "T"].contains(where: { object(dictionary, $0) != nil }) {
                // Presence, including null, is significant. A shared source
                // override cannot describe removed body text through a new
                // annotation-only survivor. Pure annotation Alt is unchanged.
                semanticConflictPages.formUnion(survivingAnnotationPages.dropFirst(beforeAnnotations))
            }
            let emptyKids = sourceKids.map { CGPDFObjectGetType($0) == .null || objectArray($0).map { CGPDFArrayGetCount($0) == 0 } == true } ?? true
            let annotationOnlyContext: Bool
            if case .output(let output) = context { annotationOnlyContext = annotationOnlyPages.contains(output) }
            else { annotationOnlyContext = false }
            let metadataOnly = emptyKids && !isExcluded(context) && !annotationOnlyContext
            guard hasContent || metadataOnly else { rejected.insert(key); return nil }
            let node = Node()
            node.entries = try copiedEntries(dictionary, dropping: ["P", "K", "Pg", "Ref", "S", "C", "ID"])
            node.entries["Type"] = .name("StructElem")
            node.entries["S"] = .name(object(dictionary, "NS") == nil ? roleNames[role] ?? role : role)
            if hasContent || sourceKids != nil { node.entries["K"] = .array(kids) }
            if case .output(let output) = context, object(dictionary, "Pg") != nil { node.entries["Pg"] = .page(output) }
            if parent.map(identity) == sourceRoot.map(identity), node.entries["Lang"] == nil, let sourceLanguage {
                node.entries["Lang"] = .original(sourceLanguage)
            }
            if let classes = object(dictionary, "C") { node.entries["C"] = try mappedClasses(classes) }
            elements[key] = Element(dictionary: dictionary, parent: parent, node: node)
            return node
        }

        /// Preserve the pre-existing disconnected topology; never add a Root.K
        /// edge or synthesize a missing top P. This is not an accessibility repair.
        private func preserveDetachedAnnotationForests(_ group: PDFCatalogSourceGroup,
                                                       rootFinished: Set<UInt>, rootRejected: Set<UInt>) throws {
            let pending = uses.keys.filter { key in
                guard uses[key]?.annotation != nil, let value = sourceParents[key],
                      let owner = objectDictionary(value) else { return false }
                return elements[identity(owner)] == nil
            }.sorted()
            guard !pending.isEmpty else { return }
            guard group.rawStreamSource?.provesExactFactoryOwner(group.document) == true else { throw Failure.invalidStructure }
            var origins: [Int: PDFCatalogPageOrigin] = [:]
            for origin in group.pages {
                try visit(0)
                guard origins.updateValue(origin, forKey: origin.outputIndex) == nil else { throw Failure.invalidStructure }
            }
            // Cache one authoritative current array per selected page. Avoid
            // repeated map inversion / PDFKit array bridging for each OBJR.
            var currents: [Int: [PDFAnnotation]] = [:]
            var nativePages: [Int: CGPDFDictionaryRef] = [:]
            for key in pending {
                try PDFSaveCancellation.checkCurrent()
                guard let use = uses[key], let annotation = use.annotation,
                      let value = sourceParents[key], let owner = objectDictionary(value) else { throw Failure.invalidStructure }
                guard let origin = origins[annotation.page],
                      let indexes = origin.annotationIndexes, indexes[annotation.sourceIndex] == annotation.index else { throw Failure.invalidStructure }
                let permission = origin.annotationTagPermission
                let permits = permission?.permits(sourceAnnotation: annotation.sourceIndex,
                    currentAnnotation: annotation.index, dictionary: annotation.dictionary, in: group.document) == true
                guard origin.contentUnchanged || permits else { throw Failure.invalidStructure }
                if currents[annotation.page] == nil {
                    guard let pageDictionary = group.document.page(at: origin.sourceIndex + 1)?.dictionary else { throw Failure.invalidStructure }
                    if !permits {
                        guard let context = PDFCatalogStructurePreserver.relationshipSource(for: origin.livePage),
                              context.knownInput, context.owner === group.document,
                              context.page.dictionary.map(identity) == identity(pageDictionary) else { throw Failure.invalidStructure }
                    }
                    currents[annotation.page] = origin.livePage.annotations
                    nativePages[annotation.page] = pageDictionary
                }
                guard let current = currents[annotation.page], current.indices.contains(annotation.index),
                      let pageDictionary = nativePages[annotation.page],
                      let nativeAnnotations = array(pageDictionary, "Annots"),
                      let nativeAnnotation = arrayDictionary(nativeAnnotations, annotation.sourceIndex),
                      identity(nativeAnnotation) == identity(annotation.dictionary) else { throw Failure.invalidStructure }
                if permits {
                    // The opaque permission keeps the original live authority
                    // while its qualified tag-reader dictionary may be distinct.
                    guard permission?.matchesCurrent(origin.livePage) == true else { throw Failure.invalidStructure }
                } else {
                    guard let original = PDFCatalogStructurePreserver.relationshipOriginal(current[annotation.index],
                        at: annotation.index, on: origin.livePage, currentAnnotations: current),
                        identity(original) == identity(annotation.dictionary) else { throw Failure.invalidStructure }
                }
                guard try directOBJRCount(object(owner, "K"), target: annotation.dictionary,
                                          page: pageDictionary, depth: 0) == 1 else { throw Failure.invalidStructure }
                if elements[identity(owner)] != nil { continue }
                var top = owner, path = Set<UInt>()
                for depth in 0..<128 {
                    try visit(depth)
                    let id = identity(top)
                    guard path.insert(id).inserted, !rootFinished.contains(id), !rootRejected.contains(id),
                          id != sourceRoot.map(identity) else { throw Failure.invalidStructure }
                    guard let declared = object(top, "P") else { break }
                    guard let parent = objectDictionary(declared),
                          try directMemberCount(object(parent, "K"), child: top, depth: 0) == 1 else { throw Failure.invalidStructure }
                    top = parent
                    if depth == 127 { throw Failure.tooComplex }
                }
                // The preceding ascent terminates only at truly absent P.
                guard object(top, "P") == nil else { throw Failure.invalidStructure }
                do {
                    let previous = importingDetachedForest
                    importingDetachedForest = true
                    defer { importingDetachedForest = previous }
                    _ = try element(top, context: .unknown, parent: nil, depth: 0)
                }
                guard elements[identity(owner)] != nil else { throw Failure.invalidStructure }
            }
            for (output, current) in currents {
                guard let origin = origins[output] else { throw Failure.invalidStructure }
                let latest = origin.livePage.annotations
                guard latest.count == current.count else { throw Failure.invalidStructure }
                for index in current.indices {
                    try visit(0)
                    guard latest[index] === current[index] else { throw Failure.invalidStructure }
                }
            }
        }

        private func directMemberCount(_ value: CGPDFObjectRef?, child: CGPDFDictionaryRef, depth: Int) throws -> Int {
            try visit(depth)
            guard let value else { return 0 }
            if let dictionary = objectDictionary(value) { return identity(dictionary) == identity(child) ? 1 : 0 }
            guard let list = objectArray(value) else { return 0 }
            guard CGPDFArrayGetCount(list) <= 100_000 else { throw Failure.tooComplex }
            var result = 0
            for index in 0..<CGPDFArrayGetCount(list) {
                guard let value = arrayObject(list, index) else { throw Failure.invalidStructure }
                result += try directMemberCount(value, child: child, depth: depth + 1)
            }
            return result
        }

        private func directOBJRCount(_ value: CGPDFObjectRef?, target: CGPDFDictionaryRef,
                                     page: CGPDFDictionaryRef, depth: Int) throws -> Int {
            try visit(depth)
            guard let value else { return 0 }
            if let dictionary = objectDictionary(value) {
                guard dictionaryName(dictionary, "Type") == "OBJR" || object(dictionary, "Obj") != nil else { return 0 }
                guard let referenced = readDictionary(dictionary, "Obj") else { throw Failure.unsupportedReference }
                guard identity(referenced) == identity(target) else { return 0 }
                if PDFTaggedStructurePreserver.object(dictionary, "Pg") != nil {
                    guard let declaredPage = readDictionary(dictionary, "Pg"), identity(declaredPage) == identity(page) else { throw Failure.invalidStructure }
                }
                return 1
            }
            guard let list = objectArray(value) else { return 0 }
            guard CGPDFArrayGetCount(list) <= 100_000 else { throw Failure.tooComplex }
            var result = 0
            for index in 0..<CGPDFArrayGetCount(list) {
                guard let value = arrayObject(list, index) else { throw Failure.invalidStructure }
                result += try directOBJRCount(value, target: target, page: page, depth: depth + 1)
            }
            return result
        }

        private func markedContent(mcid: Int, source: CGPDFDictionaryRef?, context: PageContext,
                                   owner: CGPDFDictionaryRef) throws -> Value? {
            let output: Int
            switch context {
            case .excluded:
                if !annotationOnlyPages.isEmpty { suppressedPainting += 1 }
                return nil
            case .output(let page): output = page
            case .unknown:
                let candidates = pageParentKeys.compactMap { page, key -> Int? in
                    guard let value = sourceParents[key], let array = objectArray(value), mcid < CGPDFArrayGetCount(array),
                          let target = arrayDictionary(array, mcid), identity(target) == identity(owner) else { return nil }
                    return page
                }
                guard candidates.count <= 1 else { throw Failure.invalidStructure }
                guard let page = candidates.first else {
                    // No page authority is inferred from the surviving OBJR.
                    // Still record pruning for shared semantic-override checks.
                    if !annotationOnlyPages.isEmpty { suppressedPainting += 1 }
                    return nil
                }
                output = page
            }
            if annotationOnlyPages.contains(output) {
                suppressedPainting += 1
                return nil
            }
            if let permission = bodyTagPermissions[output] {
                guard let document = bodyTagDocument,
                      source.flatMap({ object($0, "Stm") }) == nil,
                      permission.permits(mcid: mcid, owner: owner, document: document) else { throw Failure.invalidStructure }
            }
            var value = try source.map { try copiedEntries($0, dropping: ["Pg", "Stm", "MCID"]) } ?? [:]
            value["Type"] = .name("MCR"); value["Pg"] = .page(output); value["MCID"] = .integer(mcid)
            if let source, let streamObject = object(source, "Stm") {
                guard let stream = objectStream(streamObject), let dictionary = CGPDFStreamGetDictionary(stream),
                      let key = integer(dictionary, "StructParents"), key >= 0 else { throw Failure.unsupportedReference }
                try registerUse(ParentUse(key: key, output: nil, annotation: nil, streamDictionary: dictionary))
                value["Stm"] = .original(streamObject)
            } else if let key = pageParentKeys[output] {
                try registerUse(ParentUse(key: key, output: output, annotation: nil, streamDictionary: nil))
                // /Pg plus the unchanged /K MCID identifies this forward
                // owner independently of the reverse ParentTree. Some scan
                // producers omit reverse keys or point them at the owner's
                // /A layout dictionary. Repair only that proven backlink.
                guard mcid < 100_000 else { throw Failure.tooComplex }
                if let previous = forwardPageParents[key]?[mcid] {
                    guard identity(previous) == identity(owner) else { throw Failure.invalidStructure }
                } else { forwardPageParents[key, default: [:]][mcid] = owner }
            } else { throw Failure.invalidStructure }
            return .dictionary(value)
        }

        private func registerUse(_ use: ParentUse) throws {
            // A missing page key can be reconstructed after the complete
            // forward tree proves unique ownership. Annotation/Form parents
            // have different semantics and still require the source mapping.
            guard sourceParents[use.key] != nil
                || (use.output != nil && use.annotation == nil && use.streamDictionary == nil)
            else { throw Failure.invalidStructure }
            if let dictionary = use.streamDictionary {
                // Some producers leave an explicit MCR pointing at an older
                // Form while the page paints another Form with the same
                // authoritative ParentTree key. Keep both stream payloads and
                // that existing association; never substitute their MCIDs.
                if let previous = uses[use.key] {
                    guard previous.streamDictionary != nil, previous.output == nil,
                          previous.annotation == nil else { throw Failure.invalidStructure }
                } else { uses[use.key] = use }
                streamOwners[use.key, default: [:]][identity(dictionary)] = dictionary
                return
            }
            if let previous = uses[use.key] {
                guard previous.output == use.output,
                      previous.annotation.map({ identity($0.dictionary) }) == use.annotation.map({ identity($0.dictionary) }),
                      previous.streamDictionary.map(identity) == use.streamDictionary.map(identity) else { throw Failure.invalidStructure }
            } else { uses[use.key] = use }
        }

        private func collectReachableForms(_ group: PDFCatalogSourceGroup) throws {
            var seen = Set<UInt>()
            func resources(_ dictionary: CGPDFDictionaryRef, depth: Int) throws {
                try visit(depth)
                guard seen.insert(identity(dictionary)).inserted else { return }
                guard let objects = readDictionary(dictionary, "XObject") else { return }
                for (_, object) in try entries(objects) {
                    try visit(depth)
                    guard let stream = objectStream(object), let form = CGPDFStreamGetDictionary(stream),
                          dictionaryName(form, "Subtype") == "Form" else { continue }
                    if PDFTaggedStructurePreserver.object(form, "StructParents") != nil {
                        guard let key = integer(form, "StructParents"), key >= 0 else { throw Failure.invalidStructure }
                        try registerUse(ParentUse(key: key, output: nil, annotation: nil, streamDictionary: form))
                    }
                    if let nested = readDictionary(form, "Resources") { try resources(nested, depth: depth + 1) }
                }
            }
            func pageResources(_ page: CGPDFPage) throws {
                guard var dictionary = page.dictionary else { throw Failure.invalidStructure }
                var ancestors = Set<UInt>()
                for _ in 0..<64 {
                    guard ancestors.insert(identity(dictionary)).inserted else { throw Failure.invalidStructure }
                    if let value = readDictionary(dictionary, "Resources") { try resources(value, depth: 0); return }
                    guard let parent = readDictionary(dictionary, "Parent") else { return }
                    dictionary = parent
                }
                throw Failure.tooComplex
            }
            for origin in group.pages where !annotationOnlyPages.contains(origin.outputIndex) {
                guard let page = group.document.page(at: origin.sourceIndex + 1) else { throw Failure.invalidStructure }
                try pageResources(page)
                if let painting = group.paintingPages[origin.sourceIndex] { try pageResources(painting) }
            }
        }

        private func materializeParents(from group: PDFCatalogSourceGroup) throws {
            for (old, use) in uses.sorted(by: { $0.key < $1.key }) {
                try PDFSaveCancellation.checkCurrent()
                guard nextParentKey < 250_000 else { throw Failure.tooComplex }
                let key = nextParentKey; nextParentKey += 1
                let value: Value
                if let source = sourceParents[old], let array = objectArray(source) {
                    guard use.annotation == nil, CGPDFArrayGetCount(array) <= 100_000 else { throw Failure.invalidStructure }
                    let count = CGPDFArrayGetCount(array)
                    var members: [Int: Value] = [:]
                    func addMember(_ dictionary: CGPDFDictionaryRef, at index: Int) throws {
                        if let output = use.output, let permission = bodyTagPermissions[output] {
                            guard let document = bodyTagDocument,
                                  permission.permits(mcid: index, owner: dictionary, document: document) else { throw Failure.invalidStructure }
                        }
                        let existing = elements[identity(dictionary)]
                        let forward = forwardPageParents[old]?[index]
                        if let existing, let forward {
                            guard identity(existing.dictionary) == identity(forward) else { throw Failure.invalidStructure }
                        }
                        if let existing { members[index] = .node(existing.node) }
                        else if use.output != nil, dictionaryName(dictionary, "O") != nil,
                                PDFTaggedStructurePreserver.object(dictionary, "S") == nil,
                                PDFTaggedStructurePreserver.object(dictionary, "K") == nil,
                                PDFTaggedStructurePreserver.object(dictionary, "Pg") == nil, let forward,
                                let owner = elements[identity(forward)],
                                let attributes = readDictionary(forward, "A"),
                                identity(attributes) == identity(dictionary) {
                            // The malformed entry is exactly this owner's
                            // attribute dictionary, not an arbitrary object.
                            members[index] = .node(owner.node)
                        }
                    }
                    if let indices = try group.rawStreamSource?.parentArrayMemberIndices(
                        for: array, key: old, in: group.document) {
                        // The exact immutable source's QPDF parser validates
                        // EVERY slot, including unclaimed nulls and invalid
                        // types. Resolve only its nonnull positions through CG
                        // and retain the existing native owner identity checks.
                        var previous = -1
                        for (offset, index) in indices.enumerated() {
                            if offset & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                            guard index > previous, index < count,
                                  let dictionary = arrayDictionary(array, index) else { throw Failure.invalidStructure }
                            previous = index
                            try addMember(dictionary, at: index)
                        }
                    } else {
                        // Unproven graphs, parser warnings, unavailable bytes
                        // and unsupported arrays keep the original validation.
                        for index in 0..<count {
                            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                            guard let object = arrayObject(array, index) else { throw Failure.invalidStructure }
                            if CGPDFObjectGetType(object) == .null { continue }
                            guard let dictionary = objectDictionary(object) else { throw Failure.invalidStructure }
                            try addMember(dictionary, at: index)
                        }
                    }
                    value = .sparseArray(count: count, members: members)
                } else if let source = sourceParents[old], let dictionary = objectDictionary(source), let element = elements[identity(dictionary)] {
                    guard use.annotation != nil else { throw Failure.invalidStructure }
                    value = .node(element.node)
                } else if sourceParents[old] == nil, use.output != nil,
                          let owners = forwardPageParents[old], let last = owners.keys.max(), last < 100_000 {
                    var members: [Int: Value] = [:]
                    for (mcid, dictionary) in owners {
                        guard let owner = elements[identity(dictionary)] else { throw Failure.invalidStructure }
                        members[mcid] = .node(owner.node)
                    }
                    value = .sparseArray(count: last + 1, members: members)
                } else if use.annotation != nil {
                    // A tagged annotation whose owning element was pruned is
                    // inconsistent; do not create an orphaned StructParent.
                    throw Failure.invalidStructure
                } else { throw Failure.invalidStructure }
                parentNums.append((key, value))
                if let output = use.output { pageEntries[output, default: [:]]["StructParents"] = .integer(key) }
                if let annotation = use.annotation { annotationEntries[annotation.page, default: [:]][annotation.index, default: [:]]["StructParent"] = .integer(key) }
                for dictionary in streamOwners[old, default: [:]].values {
                    dictionaryOverrides[identity(dictionary), default: [:]]["StructParents"] = .integer(key)
                }
            }
        }

        private func collectIDs(_ source: CGPDFDictionaryRef) throws {
            var recorded = Set<UInt>()
            if let tree = readDictionary(source, "IDTree") {
                var pending = [tree], seen = Set<UInt>()
                while let dictionary = pending.popLast() {
                    try visit(0)
                    guard seen.insert(identity(dictionary)).inserted else { throw Failure.invalidStructure }
                    if let names = array(dictionary, "Names") {
                        guard CGPDFArrayGetCount(names) % 2 == 0, CGPDFArrayGetCount(names) <= 100_000 else { throw Failure.invalidStructure }
                        for index in stride(from: 0, to: CGPDFArrayGetCount(names), by: 2) {
                            guard let key = arrayObject(names, index).flatMap(stringData),
                                  let value = arrayDictionary(names, index + 1) else { throw Failure.invalidStructure }
                            if let element = elements[identity(value)] {
                                if let declared = object(value, "ID").flatMap(stringData), declared != key { throw Failure.invalidStructure }
                                guard recorded.insert(identity(value)).inserted else { throw Failure.invalidStructure }
                                try recordID(key, element: element)
                            }
                        }
                    }
                    if let kids = array(dictionary, "Kids") {
                        guard CGPDFArrayGetCount(kids) <= 25_000 else { throw Failure.tooComplex }
                        for index in 0..<CGPDFArrayGetCount(kids) {
                            guard let child = arrayDictionary(kids, index) else { throw Failure.invalidStructure }
                            pending.append(child)
                        }
                    }
                }
            }
            for (key, element) in elements where !recorded.contains(key) {
                if let id = object(element.dictionary, "ID") {
                    guard let value = stringData(id) else { throw Failure.invalidStructure }
                    try recordID(value, element: element)
                }
            }
        }

        private func recordID(_ value: Data, element: Element) throws {
            guard value.count <= 4_096 else { throw Failure.tooComplex }
            let id = Data(namespace.utf8) + value
            element.node.entries["ID"] = .string(id)
            ids.append((id, .node(element.node)))
        }

        private func referencedElements(_ object: CGPDFObjectRef) throws -> [Value] {
            let values: [CGPDFObjectRef]
            if let array = objectArray(object) {
                guard CGPDFArrayGetCount(array) <= 100_000 else { throw Failure.tooComplex }
                values = try (0..<CGPDFArrayGetCount(array)).map { guard let value = arrayObject(array, $0) else { throw Failure.invalidStructure }; return value }
            } else { values = [object] }
            return try values.compactMap {
                guard let dictionary = objectDictionary($0) else { throw Failure.invalidStructure }
                return elements[identity(dictionary)].map { _ in .dictionaryReference(dictionary) }
            }
        }

        private func mappedClasses(_ value: CGPDFObjectRef) throws -> Value {
            if let name = objectName(value) { return .name(classNames[name] ?? name) }
            guard let array = objectArray(value), CGPDFArrayGetCount(array) <= 1_024 else { throw Failure.invalidStructure }
            return .array(try (0..<CGPDFArrayGetCount(array)).map {
                guard let object = arrayObject(array, $0) else { throw Failure.invalidStructure }
                if let name = objectName(object) { return .name(classNames[name] ?? name) }
                guard let revision = objectInteger(object), revision >= 0 else { throw Failure.invalidStructure }
                return .integer(revision)
            })
        }

        private func pageContext(_ dictionary: CGPDFDictionaryRef, inherited: PageContext) throws -> PageContext {
            guard object(dictionary, "Pg") != nil else { return inherited }
            guard let page = readDictionary(dictionary, "Pg"), dictionaryName(page, "Type") == "Page" else { throw Failure.invalidStructure }
            return pages[identity(page)].map(PageContext.output) ?? .excluded
        }
        private func isExcluded(_ context: PageContext) -> Bool { if case .excluded = context { return true }; return false }
        private func visit(_ depth: Int) throws {
            visits += 1
            if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard depth < 128, visits <= maximumVisits else { throw Failure.tooComplex }
        }
        private func copiedEntries(_ dictionary: CGPDFDictionaryRef, dropping: Set<String>) throws -> [String: Value] {
            Dictionary(uniqueKeysWithValues: try entries(dictionary).filter { !dropping.contains($0.0) }.map { ($0.0, .original($0.1)) })
        }
        private func entries(_ dictionary: CGPDFDictionaryRef) throws -> [(String, CGPDFObjectRef)] {
            guard CGPDFDictionaryGetCount(dictionary) <= 4_096 else { throw Failure.tooComplex }
            var result: [(String, CGPDFObjectRef)] = [], invalid = false
            CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
                guard strnlen(key, 4_096) < 4_096 else { invalid = true; return false }
                result.append((String(cString: key), value)); return true
            }, nil)
            if invalid { throw Failure.tooComplex }; return result
        }
        private func numberTree(_ root: CGPDFDictionaryRef) throws -> [Int: CGPDFObjectRef] {
            var pending = [root], seen = Set<UInt>(), result: [Int: CGPDFObjectRef] = [:]
            while let dictionary = pending.popLast() {
                try visit(0)
                guard seen.insert(identity(dictionary)).inserted else { throw Failure.invalidStructure }
                if let nums = array(dictionary, "Nums") {
                    guard CGPDFArrayGetCount(nums) % 2 == 0, CGPDFArrayGetCount(nums) <= 500_000 else { throw Failure.invalidStructure }
                    for index in stride(from: 0, to: CGPDFArrayGetCount(nums), by: 2) {
                        if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                        guard let key = arrayObject(nums, index).flatMap(objectInteger), key >= 0,
                              let value = arrayObject(nums, index + 1), result.updateValue(value, forKey: key) == nil else { throw Failure.invalidStructure }
                    }
                }
                if let kids = array(dictionary, "Kids") {
                    guard CGPDFArrayGetCount(kids) <= 25_000 else { throw Failure.tooComplex }
                    for index in 0..<CGPDFArrayGetCount(kids) {
                        if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                        guard let child = arrayDictionary(kids, index) else { throw Failure.invalidStructure }; pending.append(child)
                    }
                }
            }
            return result
        }
    }

    private static func identity(_ dictionary: CGPDFDictionaryRef) -> UInt { pdfReferenceIdentity(dictionary) }
    private static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? { var result: CGPDFObjectRef?; return CGPDFDictionaryGetObject(dictionary, key, &result) ? result : nil }
    private static func readDictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? { object(dictionary, key).flatMap(objectDictionary) }
    private static func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? { object(dictionary, key).flatMap(objectArray) }
    private static func integer(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Int? { object(dictionary, key).flatMap(objectInteger) }
    private static func boolean(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool? { guard let object = object(dictionary, key) else { return nil }; var value: CGPDFBoolean = 0; return CGPDFObjectGetValue(object, .boolean, &value) ? value != 0 : nil }
    private static func dictionaryName(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? { object(dictionary, key).flatMap(objectName) }
    private static func objectDictionary(_ object: CGPDFObjectRef) -> CGPDFDictionaryRef? { var value: CGPDFDictionaryRef?; return CGPDFObjectGetValue(object, .dictionary, &value) ? value : nil }
    private static func objectArray(_ object: CGPDFObjectRef) -> CGPDFArrayRef? { var value: CGPDFArrayRef?; return CGPDFObjectGetValue(object, .array, &value) ? value : nil }
    private static func objectStream(_ object: CGPDFObjectRef) -> CGPDFStreamRef? { var value: CGPDFStreamRef?; return CGPDFObjectGetValue(object, .stream, &value) ? value : nil }
    private static func objectInteger(_ object: CGPDFObjectRef) -> Int? { var value: CGPDFInteger = 0; return CGPDFObjectGetValue(object, .integer, &value) ? value : nil }
    private static func objectName(_ object: CGPDFObjectRef) -> String? { var value: UnsafePointer<CChar>?; guard CGPDFObjectGetValue(object, .name, &value), let value, strnlen(value, 4_096) < 4_096 else { return nil }; return String(cString: value) }
    private static func stringData(_ object: CGPDFObjectRef) -> Data? { var value: CGPDFStringRef?; guard CGPDFObjectGetValue(object, .string, &value), let value, CGPDFStringGetLength(value) <= 4_096, let bytes = CGPDFStringGetBytePtr(value) else { return nil }; return Data(bytes: bytes, count: CGPDFStringGetLength(value)) }
    private static func arrayObject(_ array: CGPDFArrayRef, _ index: Int) -> CGPDFObjectRef? { var value: CGPDFObjectRef?; return CGPDFArrayGetObject(array, index, &value) ? value : nil }
    private static func arrayDictionary(_ array: CGPDFArrayRef, _ index: Int) -> CGPDFDictionaryRef? { arrayObject(array, index).flatMap(objectDictionary) }
}
