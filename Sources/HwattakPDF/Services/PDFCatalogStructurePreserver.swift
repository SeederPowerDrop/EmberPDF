// SPDX-License-Identifier: MPL-2.0

import Foundation
import CryptoKit
import ObjectiveC
import PDFKit

/// Values imported into a staged PDF graph. References are resolved by the
/// existing bounded native writer, never by an external PDF executable.
indirect enum PDFCatalogGraphValue {
    case original(CGPDFObjectRef)
    case dictionaryReference(CGPDFDictionaryRef)
    case node(PDFCatalogGraphNode)
    case array([PDFCatalogGraphValue])
    /// ParentTree indices are MCIDs. Keep holes without allocating one Value
    /// per null; serialization must preserve the exact count and positions.
    case sparseArray(count: Int, members: [Int: PDFCatalogGraphValue])
    case dictionary([String: PDFCatalogGraphValue])
    case name(String), string(Data), integer(Int), real(Double), boolean(Bool), null
    case page(Int), annotation(page: Int, index: Int)
}

final class PDFCatalogGraphNode {
    var entries: [String: PDFCatalogGraphValue]
    var streamData: Data?
    init(entries: [String: PDFCatalogGraphValue] = [:], streamData: Data? = nil) {
        self.entries = entries
        self.streamData = streamData
    }
}

struct PDFCatalogPageOrigin {
    let sourceIndex: Int
    let outputIndex: Int
    let livePage: PDFPage
    var contentUnchanged = true
    /// Opaque, worker-verified page-MCID mapping only; never painting/AP.
    var bodyTagPermission: PDFBodyEditedTagPreserver.Permission? = nil
    /// Worker-only unchanged Link OBJRs; grants no old page/Form MCIDs or AP.
    var annotationTagPermission: PDFCatalogStructurePreserver.AnnotationTagPermission? = nil
    /// nil is reserved for standalone native fixtures; production always supplies a verified map.
    var annotationIndexes: [Int: Int]? = nil
}

struct PDFCatalogSourceGroup {
    let document: CGPDFDocument
    var pages: [PDFCatalogPageOrigin]
    var signedOriginalData: Data? = nil
    var paintingPages: [Int: CGPDFPage] = [:]
    /// Exact immutable bytes for optional complete ParentTree slot validation.
    /// The tag builder continues to resolve every nonnull owner natively.
    var rawStreamSource: PDFRawStreamSource? = nil
}

struct PDFCatalogGraphPlan {
    var catalogEntries: [String: PDFCatalogGraphValue] = [:]
    var aliases: [UInt: PDFCatalogGraphValue] = [:]
    var dictionaryOverrides: [UInt: [String: PDFCatalogGraphValue]] = [:]
    var dictionaryDrops: [UInt: Set<String>] = [:]
    var catalogDrops: Set<String> = []
    var pageEntries: [Int: [String: PDFCatalogGraphValue]] = [:]
    var annotationEntries: [Int: [Int: [String: PDFCatalogGraphValue]]] = [:]
    var pageDrops: [Int: Set<String>] = [:]
    var annotationDrops: [Int: [Int: Set<String>]] = [:]
    var outlineDestinations: [[Int]: PDFCatalogGraphValue] = [:]
    /// Only factory-bound immutable C/F values; current navigation/tree wins.
    var outlineStyleEntries: [[Int]: [String: PDFCatalogGraphValue]] = [:]
    /// No native value may be restored until the final writer independently
    /// proves the exact literal original. Main only captures opaque candidates.
    var pendingInertOutlineDestinations: [[Int]: PDFRawStreamSource.PendingInertOutlineParent] = [:]
    var retainedDocuments: [CGPDFDocument] = []
    var paintingSources: [Int: CGPDFPage] = [:]
    var pageGeometry: [Int: PDFPageGeometryPreserver.PageGeometry] = [:]
    var annotationGeometry: [Int: [Int: PDFPageGeometryPreserver.AnnotationGeometry]] = [:]
    var annotationNames: [Int: [Int: PDFPageGeometryPreserver.AnnotationName]] = [:]
    /// Optional immutable-byte owners, used only to retain encoded resource
    /// streams. Catalog/tag/page decisions still belong to this graph plan.
    var rawStreamSources: [PDFRawStreamSource] = []
    var retainedTagReadAuxiliaries: [PDFTagReadAuxiliary] = []
    var bodyTagPermissions: [Int: PDFBodyEditedTagPreserver.Permission] = [:]
    var linkControlProofs: [PDFCatalogStructurePreserver.LinkControlProof] = []
    var annotationTagPermissions: [Int: PDFCatalogStructurePreserver.AnnotationTagPermission] = [:]
    var widgetAppearanceCount = 0
    var emptyFormSource: PDFCatalogStructurePreserver.EmptyFormSource? = nil
    var emptyOutlineSource: PDFCatalogStructurePreserver.EmptyOutlineSource? = nil
    var widgetFormDefaults: [String: PDFCatalogGraphValue]? = nil
    var widgetFormLocations: [(page: Int, index: Int)] = []
    var preservesCurrentWidgetDefaults = false
}

/// Keeps catalog provenance beside detached pages, across merge undo/redo and
/// serialization. CGPDFDocument retains its immutable parser graph; no live
/// source PDFDocument/workspace/view is retained by the output.
enum PDFCatalogStructurePreserver {
    private static let relationshipPageKey = NSObject(), relationshipOwnerKey = NSObject()
    private static var relationshipPageAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(relationshipPageKey).toOpaque()) }
    private static var relationshipOwnerAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(relationshipOwnerKey).toOpaque()) }
    private final class RelationshipPageSource {
        let value: PDFAnnotationRelationshipBaseline.Source
        init(_ value: PDFAnnotationRelationshipBaseline.Source) { self.value = value }
    }
    private final class RelationshipOwner {
        let native: CGPDFDocument
        private let lock = NSLock()
        private var storedCache: PDFAnnotationRelationshipBaseline.Cache?
        init(_ native: CGPDFDocument) { self.native = native }
        func cache() -> PDFAnnotationRelationshipBaseline.Cache {
            lock.lock(); defer { lock.unlock() }
            if let storedCache { return storedCache }
            let cache = PDFAnnotationRelationshipBaseline.Cache(); storedCache = cache; return cache
        }
        #if DEBUG
        var footprint: (entries: Int, bytes: Int, measurements: Int, readers: Int)? {
            lock.lock(); defer { lock.unlock() }; return storedCache?.footprint
        }
        #endif
    }
    private static let metadataSourceKey = NSObject()
    private static var metadataSourceAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(metadataSourceKey).toOpaque()) }
    private static let pageKey = NSObject(), documentKey = NSObject(), outlineKey = NSObject(), annotationKey = NSObject(), annotationDestinationKey = NSObject(), widgetCandidatesKey = NSObject(), assemblySourceKey = NSObject()
    private static let assemblyImagePruningKey = NSObject()
    private static var assemblyImagePruningAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(assemblyImagePruningKey).toOpaque()) }
    private static var pageAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(pageKey).toOpaque()) }
    private static var documentAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(documentKey).toOpaque()) }
    private static var outlineAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(outlineKey).toOpaque()) }
    private static var annotationAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(annotationKey).toOpaque()) }
    private static var annotationDestinationAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(annotationDestinationKey).toOpaque()) }
    private static var widgetCandidatesAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(widgetCandidatesKey).toOpaque()) }
    private static var assemblySourceAssociation: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(assemblySourceKey).toOpaque()) }
    private final class WeakWidget {
        weak var annotation: PDFAnnotation?
        init(_ annotation: PDFAnnotation) { self.annotation = annotation }
    }
    private final class WidgetCandidates {
        let widgets: [WeakWidget]
        init(_ widgets: [WeakWidget]) { self.widgets = widgets }
    }
    private static let pendingInertOutlineKey = NSObject()
    private static var pendingInertOutlineAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(pendingInertOutlineKey).toOpaque())
    }
    private final class PendingInertOutlineDestination {
        let candidate: PDFRawStreamSource.PendingInertOutlineParent
        weak var action: PDFAction?
        weak var destination: PDFDestination?
        let hadAction: Bool, hadDestination: Bool
        let point: CGPoint?, zoom: CGFloat?
        init(_ outline: PDFOutline, candidate: PDFRawStreamSource.PendingInertOutlineParent) {
            self.candidate = candidate; action = outline.action; hadAction = outline.action != nil
            let current = (outline.action as? PDFActionGoTo)?.destination ?? outline.destination
            destination = current; hadDestination = current != nil; point = current?.point; zoom = current?.zoom
        }
        func matches(_ outline: PDFOutline) -> Bool {
            guard outline.numberOfChildren > 0, PDFCatalogStructurePreserver.isInactiveOutlineParent(outline) else { return false }
            if hadAction { guard let action, outline.action === action else { return false } }
            else if outline.action != nil { return false }
            let current = (outline.action as? PDFActionGoTo)?.destination ?? outline.destination
            if hadDestination {
                guard let destination, current === destination, current?.point == point, current?.zoom == zoom else { return false }
            } else if current != nil { return false }
            return true
        }
    }
    private static func matchingNativeOutline(_ node: CGPDFDictionaryRef?, to outline: PDFOutline) -> CGPDFDictionaryRef? {
        guard let node else { return nil }
        var title: CGPDFStringRef?
        guard CGPDFDictionaryGetString(node, "Title", &title), let title,
              CGPDFStringGetLength(title) <= 65_536,
              (CGPDFStringCopyTextString(title) as String?) == outline.label else { return nil }
        return node
    }
    static func isInactiveOutlineParent(_ outline: PDFOutline) -> Bool {
        if let action = outline.action, !(action is PDFActionGoTo) { return false }
        return ((outline.action as? PDFActionGoTo)?.destination ?? outline.destination)?.page == nil
    }
    static func hasPendingInertOutlineRecord(_ outline: PDFOutline) -> Bool {
        objc_getAssociatedObject(outline, pendingInertOutlineAssociation) is PendingInertOutlineDestination
    }
    static func pendingInertOutlineCandidate(_ outline: PDFOutline) -> PDFRawStreamSource.PendingInertOutlineParent? {
        guard let record = objc_getAssociatedObject(outline, pendingInertOutlineAssociation) as? PendingInertOutlineDestination,
              record.matches(outline) else { return nil }
        return record.candidate
    }
    static func rememberPendingInertOutline(_ outline: PDFOutline,
                                            candidate: PDFRawStreamSource.PendingInertOutlineParent) {
        guard isInactiveOutlineParent(outline) else { return }
        objc_setAssociatedObject(outline, pendingInertOutlineAssociation,
            PendingInertOutlineDestination(outline, candidate: candidate), .OBJC_ASSOCIATION_RETAIN)
    }

    private static let outlineStyleKey = NSObject(), outlineStyleFactoryKey = NSObject()
    private static var outlineStyleAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(outlineStyleKey).toOpaque())
    }
    private static var outlineStyleFactoryAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(outlineStyleFactoryKey).toOpaque())
    }
    /// Immutable factory result. A failed bounded capture must not become an
    /// unqualified SDK reconstruction. This token grants no C/F values itself.
    private final class OutlineStyleCapture {
        weak var document: PDFDocument?
        let completed: Bool
        init(document: PDFDocument, completed: Bool) {
            self.document = document; self.completed = completed
        }
    }

    static func validateOutlineStyleReconstruction(in document: PDFDocument) throws {
        guard let capture = objc_getAssociatedObject(document, outlineStyleFactoryAssociation) as? OutlineStyleCapture else { return }
        guard capture.document === document, capture.completed else {
            throw PDFPageStructurePreserver.Failure.unsupportedStructure
        }
    }

    private final class OutlineStyle {
        weak var outline: PDFOutline?
        let document: CGPDFDocument
        let values: [String: PDFCatalogGraphValue]
        init(outline: PDFOutline, document: CGPDFDocument, values: [String: PDFCatalogGraphValue]) {
            self.outline = outline; self.document = document; self.values = values
        }
    }

    /// Called only while an exact loader/Data factory still owns the document.
    /// A native-only pass does not instantiate PDFKit outline nodes on books
    /// without C/F. Both success and refusal are terminal; prepare never mints.
    /// Work is limited to 4,096 native nodes, depth 64, and their live prefixes.
    static func rememberFactoryOutlineStyles(in document: PDFDocument, native: CGPDFDocument) {
        guard objc_getAssociatedObject(document, outlineStyleFactoryAssociation) == nil else { return }
        objc_setAssociatedObject(document, outlineStyleFactoryAssociation,
            OutlineStyleCapture(document: document, completed: false), .OBJC_ASSOCIATION_RETAIN)
        func complete() {
            objc_setAssociatedObject(document, outlineStyleFactoryAssociation,
                OutlineStyleCapture(document: document, completed: true), .OBJC_ASSOCIATION_RETAIN)
        }
        // PDF dictionary null values have the semantics of absent entries.
        // This applies only to optional factory fields; required Title and all
        // non-null invalid types retain their existing strict checks.
        func optional(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
            guard let value = object(dictionary, key), CGPDFObjectGetType(value) != .null else { return nil }
            return value
        }
        guard document.documentRef === native, !document.isLocked, !document.isEncrypted,
              let catalog = native.catalog else { return }
        guard optional(catalog, "Outlines") != nil else { complete(); return }
        guard let root = dictionary(catalog, "Outlines") else { return }
        var candidates: [(path: [Int], label: String, values: [String: PDFCatalogGraphValue])] = []
        var pending: [(CGPDFDictionaryRef, [Int])] = []
        var seen: Set<UInt> = [pdfReferenceIdentity(root)]
        var nativeChildCounts: [[Int]: Int] = [[]: 0]
        var remainingTitleBytes = 1_024 * 1_024
        if optional(root, "First") != nil {
            guard let first = dictionary(root, "First") else { return }
            pending.append((first, [0]))
        }
        while let (node, path) = pending.popLast() {
            guard path.count < 64, seen.count < 4_096,
                  seen.insert(pdfReferenceIdentity(node)).inserted, let ordinal = path.last else { return }
            let parentPath = Array(path.dropLast())
            guard nativeChildCounts[parentPath] == ordinal else { return }
            nativeChildCounts[parentPath] = ordinal + 1
            nativeChildCounts[path] = 0
            var values: [String: PDFCatalogGraphValue] = [:]
            if let color = optional(node, "C") {
                guard let components = array(node, "C"), (3...16).contains(CGPDFArrayGetCount(components)) else { return }
                for index in 0..<3 {
                    var value: CGPDFReal = 0
                    guard CGPDFArrayGetNumber(components, index, &value), value.isFinite, value >= 0, value <= 1 else { return }
                }
                // Some original files append null padding to the RGB array.
                // Retain that bounded representation verbatim; do not treat a
                // fourth number as RGB, discard padding, or normalize the color.
                for index in 3..<CGPDFArrayGetCount(components) {
                    var padding: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(components, index, &padding), let padding,
                          CGPDFObjectGetType(padding) == .null else { return }
                }
                values["C"] = .original(color)
            }
            if let flags = optional(node, "F") {
                var value: CGPDFInteger = 0
                guard CGPDFObjectGetType(flags) == .integer,
                      CGPDFDictionaryGetInteger(node, "F", &value), (0...3).contains(value) else { return }
                values["F"] = .original(flags)
            }
            if !values.isEmpty {
                var title: CGPDFStringRef?
                guard CGPDFDictionaryGetString(node, "Title", &title), let title,
                      CGPDFStringGetLength(title) <= 65_536,
                      let label = CGPDFStringCopyTextString(title) as String?,
                      label.utf8.count <= remainingTitleBytes else { return }
                remainingTitleBytes -= label.utf8.count
                candidates.append((path, label, values))
            }
            if optional(node, "Next") != nil {
                guard let next = dictionary(node, "Next"), let index = path.last else { return }
                pending.append((next, Array(path.dropLast()) + [index + 1]))
            }
            if optional(node, "First") != nil {
                guard let first = dictionary(node, "First") else { return }
                pending.append((first, path + [0]))
            }
        }
        // Complete native-only absence proof keeps the no-style fast path.
        guard !candidates.isEmpty else { complete(); return }
        guard let liveRoot = document.outlineRoot else { return }
        var live: [[Int]: PDFOutline] = [[]: liveRoot]
        var livePaths: [ObjectIdentifier: [Int]] = [ObjectIdentifier(liveRoot): []]
        guard liveRoot.numberOfChildren == nativeChildCounts[[]] else { return }
        var bindings: [(PDFOutline, [String: PDFCatalogGraphValue])] = []
        for candidate in candidates {
            var current = liveRoot, prefix: [Int] = []
            for index in candidate.path {
                prefix.append(index)
                if let cached = live[prefix] { current = cached }
                else {
                    guard index < current.numberOfChildren, let child = current.child(at: index),
                          child.numberOfChildren == nativeChildCounts[prefix] else { return }
                    let identity = ObjectIdentifier(child)
                    if let earlier = livePaths[identity], earlier != prefix { return }
                    livePaths[identity] = prefix
                    live[prefix] = child; current = child
                }
            }
            guard current.document === document, current.label == candidate.label else { return }
            bindings.append((current, candidate.values))
        }
        guard document.documentRef === native else { return }
        for (outline, values) in bindings {
            objc_setAssociatedObject(outline, outlineStyleAssociation,
                OutlineStyle(outline: outline, document: native, values: values), .OBJC_ASSOCIATION_RETAIN)
        }
        complete()
    }

    static func inheritOutlineStyle(from source: PDFOutline, to copy: PDFOutline) {
        guard source !== copy,
              let style = objc_getAssociatedObject(source, outlineStyleAssociation) as? OutlineStyle,
              style.outline === source else { return }
        objc_setAssociatedObject(copy, outlineStyleAssociation,
            OutlineStyle(outline: copy, document: style.document, values: style.values), .OBJC_ASSOCIATION_RETAIN)
    }

    private final class OutlineDestination {
        let operands: [PDFCatalogGraphValue]
        let document: CGPDFDocument
        weak var destination: PDFDestination?
        let restoresSerializedView: Bool
        let point: CGPoint
        let zoom: CGFloat
        init(operands: [PDFCatalogGraphValue], document: CGPDFDocument, destination: PDFDestination, restoresSerializedView: Bool = true) {
            self.operands = operands; self.document = document; self.destination = destination
            self.restoresSerializedView = restoresSerializedView
            point = destination.point; zoom = destination.zoom
        }
    }
    /// No edit generation is global or reset by saving this live document.
    /// A fresh input factory receives a fresh intent object.
    private final class LinkEditIntent {
        private let lock = NSLock()
        private var edited = false
        func record() { lock.lock(); edited = true; lock.unlock() }
        var isEdited: Bool { lock.lock(); defer { lock.unlock() }; return edited }
    }
    private static let linkIntentKey = NSObject()
    private static var linkIntentAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(linkIntentKey).toOpaque())
    }
    private static let linkIntentLock = NSRecursiveLock()
    private static func linkIntent(for document: PDFDocument) -> LinkEditIntent {
        linkIntentLock.lock(); defer { linkIntentLock.unlock() }
        if let existing = objc_getAssociatedObject(document, linkIntentAssociation) as? LinkEditIntent { return existing }
        let value = LinkEditIntent()
        objc_setAssociatedObject(document, linkIntentAssociation, value, .OBJC_ASSOCIATION_RETAIN)
        return value
    }
    static func recordExplicitAnnotationEdit(in document: PDFDocument) {
        linkIntentLock.lock(); defer { linkIntentLock.unlock() }
        linkIntent(for: document).record()
        (objc_getAssociatedObject(document, assemblySourceAssociation) as? Source)?.linkIntent.record()
        (objc_getAssociatedObject(document, metadataSourceAssociation) as? Source)?.linkIntent.record()
    }
    private static func forwardLinkIntent(from page: PDFPage) {
        guard let document = page.document, linkIntent(for: document).isEdited,
              let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin else { return }
        origin.source.linkIntent.record()
    }

    /// A bounded scalar observation only. AP-present links are ineligible;
    /// neither original nor current appearance programs are traversed here.
    struct LinkControlState: Equatable, Sendable {
        let bytes: Data
        init?(_ annotation: PDFAnnotation, destinationIndex: (PDFPage) -> Int?) {
            guard annotation.type == "Link" else { return nil }
            let ap = annotation.value(forAnnotationKey: .init(rawValue: "/AP"))
            guard ap == nil || ap is NSNull else { return nil }
            var values: [String: Any] = [
                "class": NSStringFromClass(type(of: annotation)),
                "display": annotation.shouldDisplay, "print": annotation.shouldPrint,
                "rect": [annotation.bounds.minX, annotation.bounds.minY, annotation.bounds.width, annotation.bounds.height],
                "contents": annotation.contents.map { $0 as Any } ?? NSNull(),
                "appearance": annotation.hasAppearanceStream,
                "modification": annotation.modificationDate.map { $0.timeIntervalSinceReferenceDate as Any } ?? NSNull()
            ]
            for key in ["/F", "/AP", "/DA", "/BS", "/Border", "/C", "/IC", "/H", "/NM", "/M", "/AS", "/QuadPoints", "/StructParent"] {
                let raw = annotation.value(forAnnotationKey: .init(rawValue: key))
                if (key == "/Border" || key == "/BS"), let border = raw as? PDFBorder {
                    guard type(of: border) == PDFBorder.self, border.lineWidth.isFinite,
                          (border.dashPattern?.count ?? 0) <= 32,
                          border.dashPattern?.allSatisfy({ ($0 as? NSNumber)?.doubleValue.isFinite == true }) ?? true else { return nil }
                    // PDFKit copies a solid border's nil dash as an empty array.
                    // Keep presence distinct for other styles and nonempty patterns.
                    let hasDash = border.dashPattern != nil
                        && (border.style != .solid || border.dashPattern?.isEmpty == false)
                    values[key] = ["class": NSStringFromClass(type(of: border)), "width": border.lineWidth,
                                   "style": border.style.rawValue, "hasDash": hasDash,
                                   "dash": border.dashPattern ?? []]
                } else {
                    values[key] = (raw as? Date).map { ["date": $0.timeIntervalSinceReferenceDate] as Any } ?? raw ?? NSNull()
                }
            }
            for (key, color) in [("color", annotation.value(forAnnotationKey: .color) == nil ? nil : annotation.color),
                                 ("fontColor", annotation.fontColor), ("interiorColor", annotation.interiorColor)] {
                if let color {
                    guard let rgb = color.usingColorSpace(.extendedSRGB) else { return nil }
                    values[key] = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                } else { values[key] = NSNull() }
            }
            if let border = annotation.border {
                guard (border.dashPattern?.count ?? 0) <= 32 else { return nil }
                values["border"] = ["width": border.lineWidth, "style": border.style.rawValue, "dash": border.dashPattern ?? []]
            } else { values["border"] = NSNull() }
            if let action = annotation.action, !(action is PDFActionGoTo), !(action is PDFActionURL) { return nil }
            if let url = (annotation.action as? PDFActionURL)?.url {
                values["url"] = url.absoluteString
            } else if let destination = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination {
                guard let page = destination.page, let index = destinationIndex(page) else { return nil }
                values["destination"] = ["page": index, "point": [destination.point.x, destination.point.y], "zoom": destination.zoom]
            } else { values["destination"] = NSNull() }
            guard let encoded = PDFWidgetAppearancePreserver.boundedDefaultFingerprint(values),
                  encoded.count <= 32 * 1_024 else { return nil }
            bytes = encoded
        }
    }

    /// Native preflight before any independent-reader Link getters. The
    /// initial lane is simple Link-only pages and absent/null AP, never a new
    /// permission to restore arbitrary AP, FS, actions, layers, or unknown keys.
    static func boundedOriginalLink(_ annotation: CGPDFDictionaryRef, page: CGPDFDictionaryRef) -> Bool {
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(annotation, "Subtype", &subtype), subtype.map({ strcmp($0, "Link") == 0 }) == true,
              CGPDFDictionaryGetCount(annotation) <= 20 else { return false }
        let allowed: Set<String> = ["Type", "Subtype", "Rect", "P", "AP", "DA", "BS", "Border", "C", "F", "Contents", "NM", "M", "A", "Dest", "H", "QuadPoints", "StructParent"]
        guard let keys = try? dictionaryKeys(annotation), Set(keys).isSubset(of: allowed),
              keys.allSatisfy({ object(annotation, $0) != nil }) else { return false }
        if keys.contains("AP") {
            guard let appearance = object(annotation, "AP"), CGPDFObjectGetType(appearance) == .null else { return false }
        }
        if let parent = object(annotation, "P"), CGPDFObjectGetType(parent) != .null {
            guard dictionary(annotation, "P") == page else { return false }
        }
        if let flags = object(annotation, "F") {
            var number: CGPDFInteger = 0
            guard CGPDFObjectGetType(flags) == .integer, CGPDFObjectGetValue(flags, .integer, &number),
                  number >= 0, UInt64(number) <= UInt64(UInt32.max) else { return false }
        }
        for key in ["Contents", "NM", "DA", "M"] {
            if let value = object(annotation, key), CGPDFObjectGetType(value) != .null {
                var string: CGPDFStringRef?
                guard CGPDFObjectGetType(value) == .string, CGPDFObjectGetValue(value, .string, &string),
                      let string, CGPDFStringGetLength(string) <= (key == "M" ? 128 : 4_096) else { return false }
            }
        }
        if let style = object(annotation, "BS"), ![CGPDFObjectType.dictionary, .null].contains(CGPDFObjectGetType(style)) { return false }
        var budget = 64 * 1_024
        guard PDFWidgetAppearancePreserver.boundedPublicFieldValues(annotation, remainingBudget: &budget) else { return false }
        if let action = dictionary(annotation, "A") {
            var actionType: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(action, "S", &actionType), let actionType,
                  ["GoTo", "URI"].contains(String(cString: actionType)),
                  let actionKeys = try? dictionaryKeys(action),
                  Set(actionKeys).isSubset(of: ["Type", "S", "D", "URI", "IsMap"]) else { return false }
            for key in ["D", "URI"] {
                if let value = object(action, key), CGPDFObjectGetType(value) == .string {
                    var string: CGPDFStringRef?
                    guard CGPDFObjectGetValue(value, .string, &string), let string, CGPDFStringGetLength(string) <= 4_096 else { return false }
                }
            }
        } else if let action = object(annotation, "A"), CGPDFObjectGetType(action) != .null { return false }
        func scalars(_ value: CGPDFObjectRef, depth: Int = 0) -> Bool {
            guard depth < 4, budget >= 64 else { return false }; budget -= 64
            switch CGPDFObjectGetType(value) {
            case .null, .integer, .boolean: return true
            case .real:
                var number: CGPDFReal = 0; return CGPDFObjectGetValue(value, .real, &number) && number.isFinite
            case .name:
                var name: UnsafePointer<CChar>?; return CGPDFObjectGetValue(value, .name, &name) && name.map { strnlen($0, 129) <= 128 } == true
            case .array:
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(value, .array, &array), let array, CGPDFArrayGetCount(array) <= 256 else { return false }
                for index in 0..<CGPDFArrayGetCount(array) {
                    var child: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(array, index, &child), let child, scalars(child, depth: depth + 1) else { return false }
                }
                return true
            case .dictionary:
                var native: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &native), let native,
                      let names = try? dictionaryKeys(native), Set(names).isSubset(of: ["Type", "W", "S", "D"]), names.count <= 4 else { return false }
                return names.allSatisfy { key in object(native, key).map { scalars($0, depth: depth + 1) } == true }
            default: return false
            }
        }
        for key in ["BS", "Border", "C", "H", "QuadPoints", "StructParent"] {
            if let value = object(annotation, key), !scalars(value) { return false }
        }
        return true
    }

    final class LinkControlProof {
        let originalDocument: CGPDFDocument
        let originalRaw: PDFRawStreamSource
        let sourcePageIndex: Int, sourceAnnotationIndex: Int
        let outputPageIndex: Int, currentAnnotationIndex: Int
        let originalDictionary: CGPDFDictionaryRef
        fileprivate weak var livePage: PDFPage?
        private let recheck: () -> Bool
        fileprivate init(original: CGPDFDocument, raw: PDFRawStreamSource,
                         sourcePage: Int, sourceAnnotation: Int, outputPage: Int,
                         currentAnnotation: Int, dictionary: CGPDFDictionaryRef,
                         page: PDFPage, recheck: @escaping () -> Bool) {
            originalDocument = original; originalRaw = raw
            sourcePageIndex = sourcePage; sourceAnnotationIndex = sourceAnnotation
            outputPageIndex = outputPage; currentAnnotationIndex = currentAnnotation
            originalDictionary = dictionary; livePage = page; self.recheck = recheck
        }
        func matches() -> Bool { recheck() }
    }

    /// Minted from current worker Link proofs plus the exact page lineage map.
    /// It can alias only the surviving Link annotation, never its appearance
    /// or any original page/Form marked content. No live PDFKit owner is retained.
    final class AnnotationTagPermission {
        let tagDocument: CGPDFDocument
        let sourceIndex: Int, outputIndex: Int
        let indexes: [Int: Int]
        private let proofs: [LinkControlProof]
        private let dictionaries: [Int: CGPDFDictionaryRef]
        private weak var livePage: PDFPage?
        fileprivate init(document: CGPDFDocument, page: PDFCatalogPageOrigin,
                         proofs: [LinkControlProof], dictionaries: [Int: CGPDFDictionaryRef]) {
            tagDocument = document; sourceIndex = page.sourceIndex; outputIndex = page.outputIndex
            indexes = Dictionary(uniqueKeysWithValues: proofs.map { ($0.sourceAnnotationIndex, $0.currentAnnotationIndex) })
            self.proofs = proofs; self.dictionaries = dictionaries; livePage = page.livePage
        }
        func matchesCurrent(_ page: PDFPage) -> Bool {
            guard livePage === page, !proofs.isEmpty, proofs.count <= 100_000,
                  let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
                  let first = proofs.first, origin.source.document === first.originalDocument,
                  origin.index == sourceIndex,
                  let current = try? annotationIndexes(on: page, origin: origin),
                  Set(indexes.values).count == indexes.count else { return false }
            return proofs.allSatisfy { proof in
                proof.livePage === page && proof.originalDocument === first.originalDocument
                    && proof.sourcePageIndex == sourceIndex && proof.outputPageIndex == outputIndex
                    && current[proof.sourceAnnotationIndex] == proof.currentAnnotationIndex
                    && indexes[proof.sourceAnnotationIndex] == proof.currentAnnotationIndex && proof.matches()
            }
        }
        func matches() -> Bool { livePage.map(matchesCurrent) ?? false }
        func permits(sourceAnnotation: Int, currentAnnotation: Int, dictionary: CGPDFDictionaryRef,
                     in document: CGPDFDocument) -> Bool {
            tagDocument === document && indexes[sourceAnnotation] == currentAnnotation
                && dictionaries[sourceAnnotation] == dictionary
        }
        func rebound(to auxiliary: PDFTagReadAuxiliary) -> AnnotationTagPermission? {
            guard let page = livePage, matchesCurrent(page), let first = proofs.first,
                  auxiliary.matches(original: first.originalDocument, raw: first.originalRaw),
                  let nativePage = auxiliary.document.page(at: sourceIndex + 1)?.dictionary,
                  let list = array(nativePage, "Annots"), CGPDFArrayGetCount(list) <= 100_000 else { return nil }
            var rebound: [Int: CGPDFDictionaryRef] = [:], seen = Set<UInt>(), tagKeys = Set<Int>()
            for proof in proofs {
                var key: CGPDFInteger = -1, otherKey: CGPDFInteger = -1
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetInteger(proof.originalDictionary, "StructParent", &key), key >= 0,
                      tagKeys.insert(Int(key)).inserted,
                      CGPDFArrayGetDictionary(list, proof.sourceAnnotationIndex, &dictionary), let dictionary,
                      CGPDFDictionaryGetInteger(dictionary, "StructParent", &otherKey), otherKey == key,
                      boundedOriginalLink(dictionary, page: nativePage),
                      seen.insert(pdfReferenceIdentity(dictionary)).inserted else { return nil }
                rebound[proof.sourceAnnotationIndex] = dictionary
            }
            // Qualification proves the raw tag graph, including OBJR targets,
            // equivalent. Its unique StructParent plus page/annotation ordinal
            // joins that graph to this auxiliary's distinct native dictionaries.
            var counts: [Int: Int] = [:]
            for index in 0..<CGPDFArrayGetCount(list) {
                var annotation: CGPDFDictionaryRef?, key: CGPDFInteger = -1
                guard CGPDFArrayGetDictionary(list, index, &annotation), let annotation else { return nil }
                if CGPDFDictionaryGetInteger(annotation, "StructParent", &key), tagKeys.contains(Int(key)) {
                    counts[Int(key), default: 0] += 1
                }
            }
            guard tagKeys.allSatisfy({ counts[$0] == 1 }) else { return nil }
            let origin = PDFCatalogPageOrigin(sourceIndex: sourceIndex, outputIndex: outputIndex, livePage: page)
            return AnnotationTagPermission(document: auxiliary.document, page: origin, proofs: proofs, dictionaries: rebound)
        }
    }

    private static func annotationTagPermission(for page: PDFCatalogPageOrigin,
                                               document: CGPDFDocument,
                                               proofs: [LinkControlProof]) -> AnnotationTagPermission? {
        guard !Thread.isMainThread, let indexes = page.annotationIndexes else { return nil }
        let selected = proofs.filter { $0.originalDocument === document && $0.sourcePageIndex == page.sourceIndex
            && $0.outputPageIndex == page.outputIndex && $0.livePage === page.livePage
            && indexes[$0.sourceAnnotationIndex] == $0.currentAnnotationIndex }
        guard !selected.isEmpty, selected.count <= 100_000,
              Set(selected.map(\.sourceAnnotationIndex)).count == selected.count,
              Set(selected.map(\.currentAnnotationIndex)).count == selected.count,
              Set(selected.map { pdfReferenceIdentity($0.originalDictionary) }).count == selected.count else { return nil }
        var dictionaries: [Int: CGPDFDictionaryRef] = [:], keys = Set<Int>(), tagged: [LinkControlProof] = []
        for proof in selected {
            guard object(proof.originalDictionary, "StructParent") != nil else { continue }
            var key: CGPDFInteger = -1
            guard CGPDFDictionaryGetInteger(proof.originalDictionary, "StructParent", &key), key >= 0,
                  keys.insert(Int(key)).inserted else { return nil }
            dictionaries[proof.sourceAnnotationIndex] = proof.originalDictionary
            tagged.append(proof)
        }
        guard !tagged.isEmpty,
              let nativePage = document.page(at: page.sourceIndex + 1)?.dictionary,
              let list = array(nativePage, "Annots"), CGPDFArrayGetCount(list) <= 100_000 else { return nil }
        var counts: [Int: Int] = [:]
        for index in 0..<CGPDFArrayGetCount(list) {
            var annotation: CGPDFDictionaryRef?, key: CGPDFInteger = -1
            guard CGPDFArrayGetDictionary(list, index, &annotation), let annotation else { return nil }
            if CGPDFDictionaryGetInteger(annotation, "StructParent", &key), keys.contains(Int(key)) {
                counts[Int(key), default: 0] += 1
            }
        }
        guard keys.allSatisfy({ counts[$0] == 1 }) else { return nil }
        let permission = AnnotationTagPermission(document: document, page: page, proofs: tagged, dictionaries: dictionaries)
        return permission.matchesCurrent(page.livePage) ? permission : nil
    }

    private final class Source {
        let document: CGPDFDocument
        let signedData: Data?
        let needsPreservation: Bool
        let rawStreamSource: PDFRawStreamSource?
        let knownNativeInput: Bool
        let linkIntent: LinkEditIntent
        let relationshipOwner: RelationshipOwner
        let baselineOutlineRootLabel: String?
        let baselineOutlineRootWasPresent: Bool
        let baselineOutlineRootIsOpen: Bool?
        private let signedHashLock = NSLock()
        private var signedHash: Data?
        /// The AF bytes and exact raw factory must describe the same input,
        /// even if its old URL was replaced after the raw context was frozen.
        func signedInputMatches(_ expected: Data) throws -> Bool {
            guard !Thread.isMainThread, let signedData else { return false }
            signedHashLock.lock(); defer { signedHashLock.unlock() }
            try PDFSaveCancellation.checkCurrent()
            if signedHash == nil { signedHash = Data(SHA256.hash(data: signedData)) }
            try PDFSaveCancellation.checkCurrent()
            return signedHash == expected
        }
        init(document: CGPDFDocument, signedData: Data?, needsPreservation: Bool,
             rawStreamSource: PDFRawStreamSource?, knownNativeInput: Bool, linkIntent: LinkEditIntent, relationshipOwner: RelationshipOwner,
             baselineOutlineRoot: PDFOutline?) {
            self.document = document; self.signedData = signedData; self.needsPreservation = needsPreservation
            self.rawStreamSource = rawStreamSource
            self.knownNativeInput = knownNativeInput; self.linkIntent = linkIntent
            self.relationshipOwner = relationshipOwner
            self.baselineOutlineRootLabel = baselineOutlineRoot?.label
            self.baselineOutlineRootWasPresent = baselineOutlineRoot != nil
            self.baselineOutlineRootIsOpen = baselineOutlineRoot?.isOpen
        }
    }
    private final class Origin {
        let source: Source
        let index: Int
        let contentUnchanged: Bool
        let bodyCommit: PDFBodyLosslessCommit?
        let geometry: PDFPageGeometryPreserver.PageGeometry
        let painting: CGPDFPage
        init(source: Source, index: Int, painting: CGPDFPage, geometry: PDFPageGeometryPreserver.PageGeometry,
             contentUnchanged: Bool = true, bodyCommit: PDFBodyLosslessCommit? = nil) {
            self.source = source; self.index = index; self.contentUnchanged = contentUnchanged; self.bodyCommit = bodyCommit
            self.geometry = geometry; self.painting = painting
        }
    }

    private final class AnnotationOrigin {
        let source: Source
        let pageIndex: Int
        let annotationIndex: Int
        let baselineGeometry: PDFPageGeometryPreserver.AnnotationGeometry
        let originalGeometry: PDFPageGeometryPreserver.AnnotationGeometry
        init(source: Source, pageIndex: Int, annotationIndex: Int,
             baselineGeometry: PDFPageGeometryPreserver.AnnotationGeometry,
             originalGeometry: PDFPageGeometryPreserver.AnnotationGeometry) {
            self.source = source; self.pageIndex = pageIndex; self.annotationIndex = annotationIndex
            self.baselineGeometry = baselineGeometry; self.originalGeometry = originalGeometry
        }
    }
    private static let signatureWitnessKey = NSObject()
    private static var signatureWitnessAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(signatureWitnessKey).toOpaque())
    }
    /// Only explicit Widget/Sig conversion or an existing exact native marker
    /// enters this provisional witness. Marker/shape alone never grants AP.
    private final class SignatureWitness {
        weak var annotation: PDFAnnotation?
        let origin: AnnotationOrigin
        let sourceState: PDFSignatureAppearancePreserver.State
        let currentState: PDFSignatureAppearancePreserver.State
        let explicitConversion: Bool
        init(_ annotation: PDFAnnotation, origin: AnnotationOrigin,
             sourceState: PDFSignatureAppearancePreserver.State,
             currentState: PDFSignatureAppearancePreserver.State, explicit: Bool) {
            self.annotation = annotation; self.origin = origin
            self.sourceState = sourceState; self.currentState = currentState; explicitConversion = explicit
        }
    }
    static func recordSignatureConversion(from original: PDFAnnotation, to stamp: PDFAnnotation,
                                          sourceState: PDFSignatureAppearancePreserver.State?) throws {
        guard let sourceState, let current = PDFSignatureAppearancePreserver.State(stamp),
              let origin = objc_getAssociatedObject(original, annotationAssociation) as? AnnotationOrigin,
              (objc_getAssociatedObject(stamp, annotationAssociation) as? AnnotationOrigin) === origin,
              let raw = originalAnnotation(origin), nativeName(raw, "Subtype") == "Widget", nativeName(raw, "FT") == "Sig",
              origin.source.rawStreamSource?.provesExactFactoryOwner(origin.source.document) == true,
              stamp.type == "Stamp", ["/FT", "/T", "/V"].allSatisfy({ stamp.value(forAnnotationKey: .init(rawValue: $0)) == nil }) else {
            throw PDFPageStructurePreserver.Failure.invalidCopy
        }
        objc_setAssociatedObject(stamp, signatureWitnessAssociation,
            SignatureWitness(stamp, origin: origin, sourceState: sourceState, currentState: current, explicit: true), .OBJC_ASSOCIATION_RETAIN)
    }
    private static func nativeName(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var pointer: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &pointer), let pointer, strnlen(pointer, 65) < 65 else { return nil }
        return String(cString: pointer)
    }
    private static func inheritSignatureWitness(from original: PDFAnnotation, to copy: PDFAnnotation) {
        guard original.type == "Stamp", copy.type == "Stamp",
              let origin = objc_getAssociatedObject(original, annotationAssociation) as? AnnotationOrigin,
              (objc_getAssociatedObject(copy, annotationAssociation) as? AnnotationOrigin) === origin,
              let current = PDFSignatureAppearancePreserver.State(copy),
              let before = PDFSignatureAppearancePreserver.State(original) else { return }
        if let witness = objc_getAssociatedObject(original, signatureWitnessAssociation) as? SignatureWitness,
           witness.annotation === original, witness.origin === origin, witness.currentState == before {
            objc_setAssociatedObject(copy, signatureWitnessAssociation,
                SignatureWitness(copy, origin: origin, sourceState: witness.sourceState, currentState: current,
                                 explicit: witness.explicitConversion), .OBJC_ASSOCIATION_RETAIN)
        } else if let native = originalAnnotation(origin), nativeName(native, "Subtype") == "Stamp",
                  PDFSignatureAppearancePreserver.Record(native) != nil {
            // Deferred worker verification must prove AF bytes, original Sig,
            // exact AP graph and independent current-input drawing state.
            objc_setAssociatedObject(copy, signatureWitnessAssociation,
                SignatureWitness(copy, origin: origin, sourceState: before, currentState: current, explicit: false), .OBJC_ASSOCIATION_RETAIN)
        }
    }
    private static func preserveSignatureAppearance(_ annotation: PDFAnnotation, origin: AnnotationOrigin,
                                                    page: Int, index: Int, plan: inout PDFCatalogGraphPlan) throws {
        let marker = PDFSignatureAppearancePreserver.markerKey
        guard annotation.type == "Stamp" else { return }
        // A failed or edited witness must not retain a stale reusable marker.
        plan.annotationDrops[page, default: [:]][index, default: []].insert(marker)
        guard !Thread.isMainThread,
              let witness = objc_getAssociatedObject(annotation, signatureWitnessAssociation) as? SignatureWitness,
              witness.annotation === annotation, witness.origin === origin,
              PDFSignatureAppearancePreserver.State(annotation) == witness.currentState,
              ["/FT", "/T", "/V"].allSatisfy({ annotation.value(forAnnotationKey: .init(rawValue: $0)) == nil }),
              let native = originalAnnotation(origin), let raw = origin.source.rawStreamSource,
              raw.provesExactFactoryOwner(origin.source.document) else { return }
        let sourceState = try raw.signatureState(in: origin.source.document, pageIndex: origin.pageIndex,
            annotationIndex: origin.annotationIndex, annotation: native)
        // An explicit unchanged conversion with an original AP cannot safely
        // fall back to SDK serialization: zero-area signature forms lose AP.
        // Edited current Stamps have already missed the fresh witness above.
        if sourceState == nil, witness.explicitConversion, object(native, "AP") != nil {
            throw PDFPageStructurePreserver.Failure.unsupportedStructure
        }
        guard sourceState == witness.sourceState else { return }
        guard let exact = try raw.exactAnnotationAppearance(in: origin.source.document, pageIndex: origin.pageIndex,
            annotationIndex: origin.annotationIndex, annotation: native) else {
            if witness.explicitConversion, object(native, "AP") != nil { throw PDFPageStructurePreserver.Failure.unsupportedStructure }
            return
        }
        let record: PDFSignatureAppearancePreserver.Record
        if witness.explicitConversion {
            guard nativeName(native, "Subtype") == "Widget", nativeName(native, "FT") == "Sig",
                  let signed = origin.source.signedData, signed.count <= 64 * 1_024 * 1_024,
                  let input = try raw.signatureInputDigest(in: origin.source.document) else {
                // This fresh unchanged conversion has already proved original
                // AP. Missing/over-budget signed input cannot choose the known
                // lossy SDK fallback either.
                throw PDFPageStructurePreserver.Failure.unsupportedStructure
            }
            guard try origin.source.signedInputMatches(input) else { throw PDFPageStructurePreserver.Failure.unsupportedStructure }
            record = .init(input: input, appearance: exact.digest, state: witness.currentState.digest,
                           page: origin.pageIndex, annotation: origin.annotationIndex)
        } else {
            guard nativeName(native, "Subtype") == "Stamp",
                  ["FT", "T", "V"].allSatisfy({ object(native, $0) == nil }),
                  let stored = PDFSignatureAppearancePreserver.Record(native),
                  stored.state == (try PDFSignatureAppearancePreserver.storedDrawingDigest(native)), stored.appearance == exact.digest,
                  let embedded = try raw.embeddedSignatureOriginal(in: origin.source.document, digest: stored.input),
                  let owner = embedded.documentRef, let embeddedRaw = PDFRawStreamProvenance.source(for: embedded),
                  embeddedRaw.provesExactFactoryOwner(owner), stored.page < owner.numberOfPages,
                  let originalPage = owner.page(at: stored.page + 1)?.dictionary,
                  let originalAnnotations = array(originalPage, "Annots"), stored.annotation < CGPDFArrayGetCount(originalAnnotations) else { return }
            var signature: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(originalAnnotations, stored.annotation, &signature), let signature,
                  nativeName(signature, "Subtype") == "Widget", nativeName(signature, "FT") == "Sig",
                  let originalAP = try embeddedRaw.exactAnnotationAppearance(in: owner, pageIndex: stored.page,
                      annotationIndex: stored.annotation, annotation: signature), originalAP.digest == exact.digest else { return }
            record = .init(input: stored.input, appearance: stored.appearance, state: witness.currentState.digest,
                           page: stored.page, annotation: stored.annotation)
        }
        try PDFSaveCancellation.checkCurrent()
        plan.annotationEntries[page, default: [:]][index, default: [:]]["AP"] = .original(exact.appearance)
        plan.annotationEntries[page, default: [:]][index, default: [:]][marker] = record.value
        plan.annotationDrops[page, default: [:]][index, default: []].remove(marker)
    }

    struct AnnotationFingerprint: Hashable {
        let subtype: String
        let rectangle: [Int64]
        let name: String?
        let contents: String?
        let parent: Int?
    }

    /// A late first capture may see annotations already edited/reordered. Match
    /// only unique native/live fingerprints and never infer lineage from an
    /// array offset or give an unverified new annotation an old OBJR target.
    private static func registerAnnotationOrigins(on page: PDFPage, source: Source, pageIndex: Int, remainingCoordinates: inout Int) throws {
        guard let native = source.document.page(at: pageIndex + 1)?.dictionary else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        let live = page.annotations
        guard live.count <= 100_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
        guard let annotations = array(native, "Annots"), CGPDFArrayGetCount(annotations) == live.count else { return }
        var originals: [AnnotationFingerprint: [Int]] = [:], current: [AnnotationFingerprint: [Int]] = [:]
        for index in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            if let fingerprint = try annotationFingerprint(annotation) { originals[fingerprint, default: []].append(index) }
        }
        for (index, annotation) in live.enumerated() {
            if let fingerprint = annotationFingerprint(annotation) { current[fingerprint, default: []].append(index) }
        }
        for (fingerprint, indexes) in current {
            guard indexes.count == 1, let nativeIndexes = originals[fingerprint], nativeIndexes.count == 1 else { continue }
            let annotation = live[indexes[0]]
            guard objc_getAssociatedObject(annotation, annotationAssociation) == nil else { continue }
            var nativeAnnotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, nativeIndexes[0], &nativeAnnotation), let nativeAnnotation else {
                throw PDFPageStructurePreserver.Failure.invalidCopy
            }
            let baseline = try PDFPageGeometryPreserver.liveAnnotation(annotation)
            let geometry = try PDFPageGeometryPreserver.rawAnnotation(nativeAnnotation)
            let cost = baseline.numberCount + geometry.numberCount
            guard cost <= remainingCoordinates else { throw PDFPageStructurePreserver.Failure.tooComplex }
            remainingCoordinates -= cost
            objc_setAssociatedObject(annotation, annotationAssociation,
                AnnotationOrigin(source: source, pageIndex: pageIndex, annotationIndex: nativeIndexes[0],
                    baselineGeometry: baseline, originalGeometry: geometry), .OBJC_ASSOCIATION_RETAIN)
        }
    }
    static func annotationFingerprint(_ annotation: PDFAnnotation) -> AnnotationFingerprint? {
        guard let subtype = annotation.type, let rectangle = annotationRectangle(annotation.bounds) else { return nil }
        return AnnotationFingerprint(subtype: subtype, rectangle: rectangle,
            name: annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String,
            contents: annotation.contents,
            parent: (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/StructParent")) as? NSNumber)?.intValue)
    }
    static func annotationFingerprint(_ annotation: CGPDFDictionaryRef) throws -> AnnotationFingerprint? {
        var subtype: UnsafePointer<CChar>?, rect: CGPDFArrayRef?
        guard CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype,
              CGPDFDictionaryGetArray(annotation, "Rect", &rect), let rect, CGPDFArrayGetCount(rect) == 4 else { return nil }
        var coordinates = [CGPDFReal](repeating: 0, count: 4)
        for index in coordinates.indices { guard CGPDFArrayGetNumber(rect, index, &coordinates[index]) else { return nil } }
        guard let rectangle = annotationRectangle(CGRect(x: coordinates[0], y: coordinates[1],
            width: coordinates[2] - coordinates[0], height: coordinates[3] - coordinates[1])) else { return nil }
        func text(_ key: String) throws -> String? {
            var string: CGPDFStringRef?
            guard CGPDFDictionaryGetString(annotation, key, &string), let string else { return nil }
            guard CGPDFStringGetLength(string) <= 1_048_576 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            return CGPDFStringCopyTextString(string).map { $0 as String }
        }
        var parent: CGPDFInteger = 0
        let hasParent = CGPDFDictionaryGetInteger(annotation, "StructParent", &parent)
        return AnnotationFingerprint(subtype: String(cString: subtype), rectangle: rectangle,
            name: try text("NM"), contents: try text("Contents"), parent: hasParent ? parent : nil)
    }
    private static func annotationRectangle(_ bounds: CGRect) -> [Int64]? {
        let bounds = bounds.standardized
        let values = [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]
        guard values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000_000 }) else { return nil }
        return values.map { Int64(($0 * 1_000_000).rounded()) }
    }
    private static func inheritAnnotationOrigins(from source: PDFPage, to copy: PDFPage) {
        let originals = source.annotations, copies = copy.annotations
        guard originals.count == copies.count else { return }
        for (original, copied) in zip(originals, copies) {
            guard original !== copied, original.type == copied.type,
                  annotationRectangle(original.bounds) == annotationRectangle(copied.bounds) else { continue }
            objc_setAssociatedObject(copied, annotationAssociation,
                objc_getAssociatedObject(original, annotationAssociation), .OBJC_ASSOCIATION_RETAIN)
            PDFRemoteNavigationPreserver.inherit(from: original, to: copied)
            inheritSignatureWitness(from: original, to: copied)
        }
    }
    // This proof belongs only to a freshly loaded, unexposed private OCR
    // snapshot. It is not a baseline stamped onto a caller's existing document,
    // and it grants no original appearance or page-painting authority.
    private static let privateDefaultKey = NSObject()
    private static var privateDefaultAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(privateDefaultKey).toOpaque())
    }
    private final class PrivateDefaultProof {
        weak var document: PDFDocument?
        weak var page: PDFPage?
        weak var annotation: PDFAnnotation?
        let origin: AnnotationOrigin
        let owner: CGPDFDocument
        let dictionaryIdentity: UInt
        let state: PDFWidgetAppearancePreserver.DefaultState
        init(document: PDFDocument, page: PDFPage, annotation: PDFAnnotation,
             origin: AnnotationOrigin, dictionary: CGPDFDictionaryRef,
             state: PDFWidgetAppearancePreserver.DefaultState) {
            self.document = document; self.page = page; self.annotation = annotation
            self.origin = origin; owner = origin.source.document
            dictionaryIdentity = pdfReferenceIdentity(dictionary); self.state = state
        }
    }

    /// Opens the completed unencrypted private Searchable snapshot itself.
    /// No caller can attach this initial-state privilege to an exposed document.
    /// Raw scalar/field graphs are bounded before PDFKit annotation getters run.
    static func loadPrivateSearchableSnapshot(at url: URL) throws -> PDFDocument {
        func checkpoint() throws {
            try Task.checkCancellation()
            try PDFSaveCancellation.checkCurrent()
        }
        try checkpoint()
        let loaded = try PDFSourceFileAccess.loadDocument(at: url)
        let document = loaded.document
        guard !document.isLocked, !document.isEncrypted,
              PDFRawStreamProvenance.hasKnownNativeInput(document),
              let native = document.documentRef, native.isUnlocked,
              native.numberOfPages == document.pageCount,
              native.numberOfPages <= 250_000 else {
            throw PDFPageStructurePreserver.Failure.unsupportedStructure
        }
        var remainingNativeBytes = 8 * 1_024 * 1_024
        var remainingVisits = 100_000
        // Every queued edge is charged, including aliases already visited.
        // Unique-node and queue bounds alone do not bound shared Kids arrays.
        var remainingFieldEdges = 250_000
        func chargeFieldEdge() throws {
            try checkpoint()
            guard remainingFieldEdges > 0 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            remainingFieldEdges -= 1
        }
        var boundedFields = Set<UInt>()
        func preflightField(_ field: CGPDFDictionaryRef) throws {
            try checkpoint()
            guard boundedFields.insert(pdfReferenceIdentity(field)).inserted else { return }
            guard remainingVisits > 0 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            remainingVisits -= 1
            var fieldBudget = min(256 * 1_024, remainingNativeBytes)
            let before = fieldBudget
            guard PDFWidgetAppearancePreserver.boundedPublicFieldValues(field, remainingBudget: &fieldBudget) else {
                throw PDFPageStructurePreserver.Failure.tooComplex
            }
            remainingNativeBytes -= before - fieldBudget
        }
        // Include non-page field parents/children before any bridged field
        // values are exposed. Cycles cannot cause unbounded traversal here;
        // normal form/relationship validators retain their semantic decisions.
        let form = native.catalog.flatMap { dictionary($0, "AcroForm") }
        if let catalog = native.catalog, let value = object(catalog, "AcroForm"),
           CGPDFObjectGetType(value) != .null, form == nil {
            throw PDFPageStructurePreserver.Failure.unsupportedStructure
        }
        if let form, let value = object(form, "Fields"),
           CGPDFObjectGetType(value) != .null, array(form, "Fields") == nil {
            throw PDFPageStructurePreserver.Failure.unsupportedStructure
        }
        if let form, let fields = array(form, "Fields") {
            guard CGPDFArrayGetCount(fields) <= 100_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            var pending: [CGPDFDictionaryRef] = []
            for index in 0..<CGPDFArrayGetCount(fields) {
                try chargeFieldEdge()
                var field: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(fields, index, &field), let field else {
                    throw PDFPageStructurePreserver.Failure.unsupportedStructure
                }
                pending.append(field)
            }
            var visited = Set<UInt>()
            while let field = pending.popLast() {
                try checkpoint()
                guard visited.insert(pdfReferenceIdentity(field)).inserted else { continue }
                try preflightField(field)
                if let kids = array(field, "Kids") {
                    guard CGPDFArrayGetCount(kids) <= remainingFieldEdges,
                          pending.count <= 100_000 - CGPDFArrayGetCount(kids) else {
                        throw PDFPageStructurePreserver.Failure.tooComplex
                    }
                    for index in 0..<CGPDFArrayGetCount(kids) {
                        try chargeFieldEdge()
                        var child: CGPDFDictionaryRef?
                        guard CGPDFArrayGetDictionary(kids, index, &child), let child else {
                            throw PDFPageStructurePreserver.Failure.unsupportedStructure
                        }
                        pending.append(child)
                    }
                } else if let kids = object(field, "Kids"), CGPDFObjectGetType(kids) != .null {
                    throw PDFPageStructurePreserver.Failure.unsupportedStructure
                }
                if let parent = dictionary(field, "Parent") {
                    try chargeFieldEdge()
                    guard pending.count < 100_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                    pending.append(parent)
                } else if let parent = object(field, "Parent"), CGPDFObjectGetType(parent) != .null {
                    throw PDFPageStructurePreserver.Failure.unsupportedStructure
                }
            }
        }
        var candidateIDs = Set<UInt>()
        var annotationVisits = 0
        for index in 0..<native.numberOfPages {
            if index & 255 == 0 { try checkpoint() }
            guard let page = native.page(at: index + 1)?.dictionary else {
                throw PDFPageStructurePreserver.Failure.invalidCopy
            }
            guard let annotations = array(page, "Annots") else { continue }
            let count = CGPDFArrayGetCount(annotations)
            guard count <= 100_000 - annotationVisits else { throw PDFPageStructurePreserver.Failure.tooComplex }
            annotationVisits += count
            for offset in 0..<count {
                if offset & 255 == 0 { try checkpoint() }
                var field: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?
                guard CGPDFArrayGetDictionary(annotations, offset, &field), let field else {
                    throw PDFPageStructurePreserver.Failure.unsupportedStructure
                }
                guard CGPDFDictionaryGetName(field, "Subtype", &subtype), let subtype,
                      strcmp(subtype, "Widget") == 0 else { continue }
                try preflightField(field)
                // Complex/inherited/array/name defaults keep the ordinary
                // policy. Only simple absent/null defaults need this proof.
                guard object(field, "Parent") == nil, object(field, "Kids") == nil else { continue }
                var type: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(field, "FT", &type), let type else { continue }
                let isChoice = strcmp(type, "Ch") == 0
                guard strcmp(type, "Tx") == 0 || isChoice else { continue }
                if let value = object(field, "DV"), CGPDFObjectGetType(value) != .null { continue }
                var flags: CGPDFInteger = 0
                if isChoice, CGPDFDictionaryGetInteger(field, "Ff", &flags), flags & (1 << 21) != 0 { continue }
                guard candidateIDs.insert(pdfReferenceIdentity(field)).inserted else {
                    throw PDFPageStructurePreserver.Failure.invalidCopy
                }
            }
        }
        // Books without candidate widgets never create public annotation
        // arrays or Catalog origins merely to perform this optional capture.
        if !candidateIDs.isEmpty {
            // Standard origin matching reads these fingerprint keys on every
            // annotation, including non-widgets. Bound their native types and
            // aggregate expansion before any bridged getter can deep-copy one.
            for pageIndex in 0..<native.numberOfPages {
                try checkpoint()
                guard let page = native.page(at: pageIndex + 1)?.dictionary else {
                    throw PDFPageStructurePreserver.Failure.invalidCopy
                }
                guard let annotations = array(page, "Annots") else { continue }
                for offset in 0..<CGPDFArrayGetCount(annotations) {
                    try checkpoint()
                    var annotation: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?
                    guard CGPDFArrayGetDictionary(annotations, offset, &annotation), let annotation,
                          CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype else {
                        throw PDFPageStructurePreserver.Failure.unsupportedStructure
                    }
                    func charge(_ bytes: Int) throws {
                        guard bytes >= 0, bytes <= remainingNativeBytes else { throw PDFPageStructurePreserver.Failure.tooComplex }
                        remainingNativeBytes -= bytes
                    }
                    let subtypeLength = strnlen(subtype, 4_097)
                    guard subtypeLength <= 4_096 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                    try charge(64 + subtypeLength * 6)
                    for key in ["NM", "Contents"] {
                        guard let value = object(annotation, key), CGPDFObjectGetType(value) != .null else { continue }
                        var string: CGPDFStringRef?
                        guard CGPDFObjectGetValue(value, .string, &string), let string else {
                            throw PDFPageStructurePreserver.Failure.unsupportedStructure
                        }
                        let count = CGPDFStringGetLength(string)
                        guard count <= 1_048_576 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                        // Widget field preflight already charged Contents.
                        // Its stricter scalar bound remains in force.
                        if key != "Contents" || !boundedFields.contains(pdfReferenceIdentity(annotation)) {
                            guard count <= remainingNativeBytes / 6 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                            try charge(64 + count * 6)
                        }
                    }
                    if let parent = object(annotation, "StructParent"), CGPDFObjectGetType(parent) != .null {
                        guard CGPDFObjectGetType(parent) == .integer else {
                            throw PDFPageStructurePreserver.Failure.unsupportedStructure
                        }
                        try charge(64)
                    }
                    guard let rectangle = array(annotation, "Rect"), CGPDFArrayGetCount(rectangle) == 4 else {
                        throw PDFPageStructurePreserver.Failure.unsupportedStructure
                    }
                    try charge(320)
                    for index in 0..<4 {
                        var number: CGPDFReal = 0
                        guard CGPDFArrayGetNumber(rectangle, index, &number), number.isFinite else {
                            throw PDFPageStructurePreserver.Failure.unsupportedStructure
                        }
                    }
                }
            }
            try checkpoint()
            try prepare(document, force: true)
            var remainingRecords = 100_000, remainingBytes = 8 * 1_024 * 1_024
            var captured = Set<UInt>()
            for index in 0..<document.pageCount {
                try checkpoint()
                guard let page = document.page(at: index) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                for annotation in page.annotations where annotation.type == "Widget" {
                    guard let origin = objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin,
                          origin.source.document === native, origin.source.knownNativeInput,
                          let original = originalAnnotation(origin),
                          candidateIDs.contains(pdfReferenceIdentity(original)) else { continue }
                    guard let pageOrigin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
                          pageOrigin.source === origin.source, pageOrigin.index == origin.pageIndex,
                          captured.insert(pdfReferenceIdentity(original)).inserted else {
                        throw PDFPageStructurePreserver.Failure.invalidCopy
                    }
                    try checkpoint()
                    guard remainingRecords > 0, remainingBytes >= 192 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                    remainingRecords -= 1; remainingBytes -= 192
                    // The native scalar preflight above precedes this bounded
                    // public encoding (at most 256 KiB transient per field).
                    guard let state = PDFWidgetAppearancePreserver.DefaultState(annotation),
                          state.byteCount <= remainingBytes else { throw PDFPageStructurePreserver.Failure.tooComplex }
                    remainingBytes -= state.byteCount
                    objc_setAssociatedObject(annotation, privateDefaultAssociation,
                        PrivateDefaultProof(document: document, page: page, annotation: annotation,
                            origin: origin, dictionary: original, state: state), .OBJC_ASSOCIATION_RETAIN)
                }
            }
            guard captured == candidateIDs else { throw PDFPageStructurePreserver.Failure.unsupportedStructure }
        }
        try checkpoint()
        guard document.documentRef === native, !document.isLocked, !document.isEncrypted,
              PDFRawStreamProvenance.hasKnownNativeInput(document), document.pageCount == native.numberOfPages,
              try PDFSourceFileVersion.capture(at: url) == loaded.version else {
            throw PDFPageStructurePreserver.Failure.unsupportedStructure
        }
        return document
    }

    /// Read the factory's original observation; callers still use the exact
    /// existing DefaultState.matches check to distinguish later default edits.
    static func privateSnapshotDefaultBaseline(for annotation: PDFAnnotation) -> PDFWidgetAppearancePreserver.DefaultState? {
        guard let record = objc_getAssociatedObject(annotation, privateDefaultAssociation) as? PrivateDefaultProof,
              record.annotation === annotation, let page = annotation.page, record.page === page,
              let document = page.document, record.document === document,
              !document.isLocked, !document.isEncrypted,
              PDFRawStreamProvenance.hasKnownNativeInput(document),
              document.documentRef === record.owner,
              let origin = objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin,
              origin === record.origin, origin.source.document === record.owner,
              let pageOrigin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
              pageOrigin.source === origin.source, pageOrigin.index == origin.pageIndex,
              let original = originalAnnotation(origin),
              pdfReferenceIdentity(original) == record.dictionaryIdentity else { return nil }
        return record.state
    }

    private static func preserveOriginalLinkControls(_ annotation: PDFAnnotation, origin: AnnotationOrigin,
                                                     baseline: LinkControlState, page: PDFPage,
                                                     outputIndex: Int, annotationIndex: Int,
                                                     plan: inout PDFCatalogGraphPlan) {
        guard let document = page.document, !linkIntent(for: document).isEdited, !origin.source.linkIntent.isEdited,
              let raw = origin.source.rawStreamSource, raw.provesExactFactoryOwner(origin.source.document),
              let native = originalAnnotation(origin),
              let nativePage = origin.source.document.page(at: origin.pageIndex + 1)?.dictionary,
              boundedOriginalLink(native, page: nativePage) else { return }
        func targetIndex(_ target: PDFPage) -> Int? {
            if let targetOrigin = objc_getAssociatedObject(target, pageAssociation) as? Origin,
               targetOrigin.source.document === origin.source.document { return targetOrigin.index }
            guard let owner = target.document, owner.documentRef === origin.source.document else { return nil }
            let index = owner.index(for: target)
            guard index != NSNotFound, index >= 0, index < origin.source.document.numberOfPages,
                  target.pageRef?.dictionary == origin.source.document.page(at: index + 1)?.dictionary else { return nil }
            return index
        }
        guard baseline == LinkControlState(annotation, destinationIndex: targetIndex) else { return }
        let proof = LinkControlProof(original: origin.source.document, raw: raw,
            sourcePage: origin.pageIndex, sourceAnnotation: origin.annotationIndex,
            outputPage: outputIndex, currentAnnotation: annotationIndex, dictionary: native,
            page: page) { [weak annotation, weak page, weak document] in
            guard let annotation, let page, let document,
                  annotation.page === page, page.document === document,
                  !origin.source.linkIntent.isEdited, !linkIntent(for: document).isEdited,
                  document.index(for: page) == outputIndex,
                  page.annotations.indices.contains(annotationIndex), page.annotations[annotationIndex] === annotation,
                  (objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin) === origin,
                  let pageOrigin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
                  pageOrigin.source === origin.source, pageOrigin.index == origin.pageIndex,
                  originalAnnotation(origin) == native,
                  raw.provesExactFactoryOwner(origin.source.document),
                  baseline == LinkControlState(annotation, destinationIndex: targetIndex) else { return false }
            return true
        }
        guard proof.matches() else { return }
        guard let keys = try? dictionaryKeys(native) else { return }
        var entries: [String: PDFCatalogGraphValue] = [:], drops = Set<String>()
        for key in ["F", "AP", "DA", "BS"] {
            if keys.contains(key) {
                guard let value = object(native, key) else { return }
                entries[key] = .original(value)
            } else { drops.insert(key) }
        }
        plan.annotationEntries[outputIndex, default: [:]][annotationIndex, default: [:]].merge(entries) { _, original in original }
        plan.annotationDrops[outputIndex, default: [:]][annotationIndex, default: []].formUnion(drops)
        plan.linkControlProofs.append(proof)
    }

    private static func widgetBaseline(_ origin: AnnotationOrigin) throws -> PDFWidgetAppearancePreserver.State? {
        // Main captured only lightweight lineage. Resolve the independently
        // read baseline later on the save worker; a main cache miss performs
        // no I/O and cannot poison the immutable geometry association.
        // Baselines belong to the bounded source cache, not to every live
        // annotation for the document's entire lifetime.
        guard let raw = origin.source.rawStreamSource,
              let states = try raw.originalWidgetStates(onPage: origin.pageIndex),
              let baseline = states[origin.annotationIndex] else { return nil }
        return baseline
    }
    private static func widgetDefaultBaseline(_ annotation: PDFAnnotation,
                                              origin: AnnotationOrigin) throws -> PDFWidgetAppearancePreserver.DefaultState? {
        if let raw = origin.source.rawStreamSource,
           let states = try raw.originalWidgetDefaultStates(onPage: origin.pageIndex),
           let state = states[origin.annotationIndex] { return state }
        return privateSnapshotDefaultBaseline(for: annotation)
    }
    private static func widgetAppearance(_ annotation: PDFAnnotation, origin: AnnotationOrigin,
                                         baseline: PDFWidgetAppearancePreserver.State?) -> PDFWidgetAppearancePreserver.Origin? {
        guard let baseline, let native = originalAnnotation(origin) else { return nil }
        return PDFWidgetAppearancePreserver.origin(annotation: annotation, native: native, baseline: baseline)
    }
    private static func originalAnnotation(_ origin: AnnotationOrigin) -> CGPDFDictionaryRef? {
        guard let page = origin.source.document.page(at: origin.pageIndex + 1)?.dictionary,
              let annotations = array(page, "Annots") else { return nil }
        var annotation: CGPDFDictionaryRef?
        return CGPDFArrayGetDictionary(annotations, origin.annotationIndex, &annotation) ? annotation : nil
    }
    /// Relationship-only access. The caller already proves the current index
    /// by exact page.annotations membership; no late native-array fallback is
    /// introduced when the established unique annotation origin is absent.
    static func relationshipOriginal(_ annotation: PDFAnnotation, at index: Int, on page: PDFPage,
                                     currentAnnotations: [PDFAnnotation]) -> CGPDFDictionaryRef? {
        guard currentAnnotations.indices.contains(index), currentAnnotations[index] === annotation,
              let pageOrigin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
              let origin = objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin,
              origin.source === pageOrigin.source, origin.pageIndex == pageOrigin.index else { return nil }
        return originalAnnotation(origin)
    }
    static func relationshipSource(for page: PDFPage) -> PDFAnnotationRelationshipBaseline.Source? {
        if let context = objc_getAssociatedObject(page, relationshipPageAssociation) as? RelationshipPageSource { return context.value }
        guard let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
              let native = origin.source.document.page(at: origin.index + 1) else { return nil }
        return PDFAnnotationRelationshipBaseline.Source(owner: origin.source.document, page: native,
            cache: origin.source.relationshipOwner.cache(), knownInput: origin.source.knownNativeInput)
    }
    /// Only the explicit retained-identity annotation move invokes this after
    /// exact current membership and unchanged relationship-state validation.
    static func acceptRelationshipSourceAfterIdentityMove(_ source: PDFAnnotationRelationshipBaseline.Source, on page: PDFPage) {
        objc_setAssociatedObject(page, relationshipPageAssociation, RelationshipPageSource(source), .OBJC_ASSOCIATION_RETAIN)
    }
    /// Builder can carry annotation relationships without granting its output
    /// generic page-painting, geometry or tagged-catalog provenance.
    static func prepareRelationshipSource(on page: PDFPage) {
        guard relationshipSource(for: page) == nil,
              let document = page.document, PDFRawStreamProvenance.hasKnownNativeInput(document),
              let native = document.documentRef, !document.isLocked, native.isUnlocked,
              let dictionary = page.pageRef?.dictionary else { return }
        let index = document.index(for: page)
        guard index >= 0, index < native.numberOfPages,
              let original = native.page(at: index + 1), let originalDictionary = original.dictionary,
              pdfReferenceIdentity(dictionary) == pdfReferenceIdentity(originalDictionary) else { return }
        let owner = relationshipOwner(for: document, native: native)
        let source = PDFAnnotationRelationshipBaseline.Source(owner: owner.native, page: original, cache: owner.cache(), knownInput: true)
        objc_setAssociatedObject(page, relationshipPageAssociation, RelationshipPageSource(source), .OBJC_ASSOCIATION_RETAIN)
    }
    /// Called only after the relationship helper proves the NSCopying boundary.
    static func inheritRelationshipSource(from source: PDFPage, to copy: PDFPage) {
        guard let context = relationshipSource(for: source) else { return }
        objc_setAssociatedObject(copy, relationshipPageAssociation, RelationshipPageSource(context), .OBJC_ASSOCIATION_RETAIN)
    }
    private static func relationshipOwner(for document: PDFDocument, native: CGPDFDocument) -> RelationshipOwner {
        if let owner = objc_getAssociatedObject(document, relationshipOwnerAssociation) as? RelationshipOwner,
           let original = owner.native.catalog, let current = native.catalog,
           pdfReferenceIdentity(original) == pdfReferenceIdentity(current) { return owner }
        let owner = RelationshipOwner(native)
        objc_setAssociatedObject(document, relationshipOwnerAssociation, owner, .OBJC_ASSOCIATION_RETAIN)
        return owner
    }
    #if DEBUG
    static func relationshipCacheFootprint(for document: PDFDocument) -> (entries: Int, bytes: Int, measurements: Int, readers: Int)? {
        (objc_getAssociatedObject(document, relationshipOwnerAssociation) as? RelationshipOwner)?.footprint
    }
    #endif
    /// Current-value repair on an isolated recovery copy must not guess how a
    /// shared/parent/radio field propagates changes through other widgets.
    static func permitsIndependentWidgetValueRestoration(_ annotation: PDFAnnotation) -> Bool {
        guard let origin = objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin,
              let original = originalAnnotation(origin),
              ["Parent", "Kids"].allSatisfy({ object(original, $0) == nil }) else { return false }
        var flags: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(original, "Ff", &flags) {
            if annotation.widgetFieldType == .choice, flags & (1 << 21) != 0 { return false }
            if annotation.widgetFieldType == .button, flags & ((1 << 15) | (1 << 16)) != 0 { return false }
        }
        return true
    }
    private static func annotationIndexes(on page: PDFPage, origin: Origin) throws -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (index, annotation) in page.annotations.enumerated() {
            guard let original = objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin,
                  original.source === origin.source, original.pageIndex == origin.index else { continue }
            guard result.updateValue(index, forKey: original.annotationIndex) == nil else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        }
        return result
    }

    static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &value) ? value : nil
    }
    static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(dictionary, key, &value) ? value : nil
    }
    static func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary, key, &value) ? value : nil
    }

    static func shouldPreserve(_ document: PDFDocument) -> Bool {
        if PDFRemoteNavigationPreserver.hasOriginalActions(document) { return true }
        if objc_getAssociatedObject(document, documentAssociation) != nil { return true }
        guard let catalog = document.documentRef?.catalog else { return false }
        return ["PageLabels", "StructTreeRoot", "MarkInfo", "OCProperties", "Names", "AF", "OpenAction", "AA", "Outlines",
                "Lang", "Metadata", "OutputIntents", "EmberPDFSourceOutputIntents", "ViewerPreferences", "Collection", "Perms"].contains { object(catalog, $0) != nil }
    }
    static func prepareForOrdinaryWriting(_ document: PDFDocument) throws {
        // Recovery and assembly already selected the graph writer and carried
        // their page provenance. A detached body-edit snapshot may have no
        // native document of its own; do not recapture it as a fresh source.
        // Remote-action capture alone is not this marker and still needs prep.
        guard objc_getAssociatedObject(document, documentAssociation) == nil,
              shouldPreserve(document) else { return }
        try prepare(document)
        mark(document)
    }
    static func needsMaterialization(_ document: PDFDocument) -> Bool {
        if objc_getAssociatedObject(document, documentAssociation) != nil || PDFRemoteNavigationPreserver.hasOriginalActions(document) { return true }
        // A form-only original need not have an assembled-document marker.
        // Read only registered weak widget candidates here, not a deep catalog
        // plan or a fresh PDF. Moved/deleted annotations cannot select another
        // document's save path through a stale candidate.
        guard let candidates = objc_getAssociatedObject(document, widgetCandidatesAssociation) as? WidgetCandidates else { return false }
        return candidates.widgets.contains { candidate in
            guard let annotation = candidate.annotation, annotation.page?.document === document,
                  let origin = objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin else { return false }
            return PDFWidgetAppearancePreserver.isPotentialDefaultCandidate(annotation, original: originalAnnotation(origin))
        }
    }
    /// Plain assemblies use the graph writer to retain exact painting. A user
    /// requested encryption/flattening transform may keep its established
    /// PDFKit path when there is no additional catalog structure to preserve.
    static func requiresCatalogSemantics(_ document: PDFDocument) -> Bool {
        (0..<document.pageCount).contains { index in
            guard let page = document.page(at: index),
                  let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin else { return false }
            return origin.source.needsPreservation
        }
    }

    /// Capture before PDFKit serialization can normalize the original graph.
    static func prepare(_ document: PDFDocument, force: Bool = false, pageIndexes: [Int]? = nil) throws {
        let needsPreservation = shouldPreserve(document)
        guard force || needsPreservation else { return }
        try rememberLiveOutlineDestinations(in: document)
        // Assembly may capture only its normalized selection. All other callers
        // retain the existing whole-document preparation contract.
        let candidates: [PDFPage]
        if let pageIndexes {
            let indexes = try PDFPageOperations.normalizedSelection(pageIndexes, pageCount: document.pageCount)
            candidates = try indexes.map { index in
                guard let page = document.page(at: index) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                return page
            }
        } else { candidates = (0..<document.pageCount).compactMap { document.page(at: $0) } }
        let missing = candidates.filter { objc_getAssociatedObject($0, pageAssociation) == nil }
        guard !missing.isEmpty else { return }
        guard let native = document.documentRef, native.isUnlocked else {
            if !needsPreservation { return }
            throw PDFPageStructurePreserver.Failure.invalidCopy
        }
        // PDFKit's immutable documentRef keeps its original page tree after
        // live removals/reordering. Match native dictionaries rather than
        // interpreting a current sidebar index as an original source index.
        guard native.numberOfPages <= 250_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
        var nativeIndexes: [UInt: Int] = [:]
        for index in 0..<native.numberOfPages {
            guard let dictionary = native.page(at: index + 1)?.dictionary,
                  nativeIndexes.updateValue(index, forKey: pdfReferenceIdentity(dictionary)) == nil else {
                throw PDFPageStructurePreserver.Failure.invalidCopy
            }
        }
        var matched: [(PDFPage, Int)] = [], paintings: [Int: CGPDFPage] = [:]
        for page in missing {
            guard let painting = page.pageRef, let dictionary = painting.dictionary,
                  let sourceIndex = nativeIndexes[pdfReferenceIdentity(dictionary)] else {
                // A newly inserted/synthetic page has no catalog provenance
                // in this native graph. Its current painting stays authoritative.
                continue
            }
            matched.append((page, sourceIndex))
            paintings[sourceIndex] = painting
        }
        guard !matched.isEmpty else { return }
        let signed = try signedOriginalBytes(document, native: native)
        let raw = PDFRawStreamProvenance.source(for: document)
        let known = PDFRawStreamProvenance.hasKnownNativeInput(document)
        let source: Source
        if let cached = objc_getAssociatedObject(document, assemblySourceAssociation) as? Source,
           cached.document === native, cached.needsPreservation == needsPreservation,
           cached.knownNativeInput == known, cached.rawStreamSource === raw,
           cached.signedData == signed {
            source = cached
        } else {
            // Source stays immutable after a snapshot shares it with a writer.
            // Per-selection painting references belong to each immutable Origin.
            source = Source(document: native, signedData: signed, needsPreservation: needsPreservation,
                            rawStreamSource: raw, knownNativeInput: known, linkIntent: linkIntent(for: document),
                            relationshipOwner: relationshipOwner(for: document, native: native), baselineOutlineRoot: document.outlineRoot)
            objc_setAssociatedObject(document, assemblySourceAssociation, source, .OBJC_ASSOCIATION_RETAIN)
        }
        if objc_getAssociatedObject(document, metadataSourceAssociation) == nil {
            objc_setAssociatedObject(document, metadataSourceAssociation, source, .OBJC_ASSOCIATION_RETAIN)
        }
        var remainingCoordinates = 2_000_000
        for (page, sourceIndex) in matched {
            try registerAnnotationOrigins(on: page, source: source, pageIndex: sourceIndex, remainingCoordinates: &remainingCoordinates)
            guard let reference = paintings[sourceIndex] else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            objc_setAssociatedObject(page, pageAssociation,
                Origin(source: source, index: sourceIndex, painting: reference, geometry: try PDFPageGeometryPreserver.capture(page, reference: reference)), .OBJC_ASSOCIATION_RETAIN)
        }
        var widgets = (objc_getAssociatedObject(document, widgetCandidatesAssociation) as? WidgetCandidates)?.widgets
            .filter { $0.annotation?.page?.document === document } ?? []
        var widgetIDs = Set(widgets.compactMap { $0.annotation.map(ObjectIdentifier.init) })
        for (page, _) in matched {
            for annotation in page.annotations where annotation.type == "Widget" {
                if widgetIDs.insert(ObjectIdentifier(annotation)).inserted { widgets.append(WeakWidget(annotation)) }
            }
        }
        if !widgets.isEmpty {
            objc_setAssociatedObject(document, widgetCandidatesAssociation, WidgetCandidates(widgets), .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// A one-operation witness over an existing unchanged Origin. This does
    /// not mark an assembled document as a new factory or body-edit source.
    struct EncodedAssemblyOrigin {
        let reference: CGPDFPage
        let raw: PDFRawStreamSource
        fileprivate let validate: (PDFPage, CGPDFPage, PDFRawStreamSource) throws -> Bool
        func matches(_ page: PDFPage, reference: CGPDFPage, raw: PDFRawStreamSource) throws -> Bool {
            try validate(page, reference, raw)
        }
    }

    static func encodedAssemblyOrigin(for page: PDFPage) throws -> EncodedAssemblyOrigin? {
        try PDFSaveCancellation.checkCurrent()
        guard let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
              origin.contentUnchanged, origin.source.knownNativeInput,
              origin.source.signedData == nil, let raw = origin.source.rawStreamSource,
              raw.provesExactFactoryOwner(origin.source.document),
              !origin.source.document.isEncrypted, origin.source.document.isUnlocked,
              origin.painting.document === origin.source.document,
              origin.index >= 0, origin.index < origin.source.document.numberOfPages,
              let paintingDictionary = origin.painting.dictionary,
              origin.source.document.page(at: origin.index + 1)?.dictionary == paintingDictionary,
              let document = page.document, !document.isEncrypted, !document.isLocked else { return nil }
        // An app-assembled page may retain a live dictionary after PDFKit
        // releases its native owner, or have no live pageRef at all. These
        // optional values only witness live stability; the private unchanged
        // Origin above remains the sole painting/raw ownership authority.
        let currentReference = page.pageRef
        let currentDictionary = currentReference?.dictionary
        let currentOwner = currentReference?.document
        guard currentReference == nil || currentDictionary != nil else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound, index >= 0, index < document.pageCount,
              document.page(at: index) === page else { return nil }
        let geometry = try PDFPageGeometryPreserver.current(page), rotation = page.rotation
        return EncodedAssemblyOrigin(reference: origin.painting, raw: raw) { [weak page, weak document] candidate, reference, candidateRaw in
            try PDFSaveCancellation.checkCurrent()
            guard let page, let document, candidate === page, page.document === document,
                  document.index(for: page) == index, document.page(at: index) === page,
                  (objc_getAssociatedObject(page, pageAssociation) as? Origin) === origin,
                  origin.contentUnchanged, origin.source.knownNativeInput,
                  origin.source.rawStreamSource === candidateRaw, candidateRaw === raw,
                  candidateRaw.provesExactFactoryOwner(origin.source.document),
                  reference.document === origin.source.document, reference.dictionary == paintingDictionary,
                  origin.painting.dictionary == paintingDictionary,
                  origin.source.document.page(at: origin.index + 1)?.dictionary == paintingDictionary else { return false }
            let current = page.pageRef
            guard (current == nil) == (currentReference == nil),
                  current?.dictionary == currentDictionary, current?.document === currentOwner,
                  page.rotation == rotation, try PDFPageGeometryPreserver.current(page) == geometry else { return false }
            return true
        }
    }

    private static func requiresManualRecoverySnapshot(_ document: PDFDocument, widgetCount: Int) throws -> Bool {
        guard widgetCount == 0, document.pageCount > 0, document.pageCount <= 4_096,
              !document.isEncrypted, !document.isLocked else { return false }
        var found = false
        for index in 0..<document.pageCount {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index) else { return false }
            if try PDFAnnotationRelationshipPreserver.requiresManualCopy(on: page) { found = true }
        }
        guard found else { return false }
        // An app-assembled document need not have its own native Catalog.
        // Existing global/per-page provenance and all live Widgets are still
        // checked below; a present native Catalog retains every old check.
        if let current = document.documentRef {
            guard let catalog = current.catalog, object(catalog, "AcroForm") == nil,
                  !hasActualSignature(current) else { return false }
        }
        if let metadata = objc_getAssociatedObject(document, metadataSourceAssociation) as? Source {
            guard metadata.signedData == nil, let catalog = metadata.document.catalog,
                  object(catalog, "AcroForm") == nil else { return false }
        } else { return false }
        var remaining = 100_000
        for index in 0..<document.pageCount {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index),
                  let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
                  origin.contentUnchanged, origin.source.signedData == nil,
                  let catalog = origin.source.document.catalog, object(catalog, "AcroForm") == nil else { return false }
            let annotations = page.annotations
            guard annotations.count <= remaining, annotations.allSatisfy({ $0.type != "Widget" }) else { return false }
            remaining -= annotations.count
        }
        return true
    }

    /// An optional assembly shortcut, not a painting/metadata authority issuer.
    /// The caller has just made this independent SDK copy after prepare(force:).
    /// Every permission comes from its existing immutable Origin and exact
    /// native owner; no raw input is read or parsed on this path.
    static func canReuseIndexedNativeCopy(from source: PDFPage, to copy: PDFPage,
                                         copyBudget: PDFAnnotationRelationshipPreserver.CopyBudget = .init()) throws -> Bool {
        do {
            try PDFSaveCancellation.checkCurrent()
            guard source !== copy,
                  let origin = objc_getAssociatedObject(source, pageAssociation) as? Origin,
                  origin.contentUnchanged, origin.source.knownNativeInput,
                  let raw = origin.source.rawStreamSource,
                  raw.provesExactFactoryOwner(origin.source.document),
                  !origin.source.document.isEncrypted, origin.source.document.isUnlocked,
                  let document = source.document, !document.isEncrypted, !document.isLocked,
                  let metadata = objc_getAssociatedObject(document, metadataSourceAssociation) as? Source,
                  metadata === origin.source,
                  let current = source.pageRef, let copied = copy.pageRef,
                  let currentDictionary = current.dictionary, let copiedDictionary = copied.dictionary,
                  let originalDictionary = origin.painting.dictionary,
                  currentDictionary == copiedDictionary, currentDictionary == originalDictionary,
                  let currentOwner = current.document, let copiedOwner = copied.document,
                  let originalOwner = origin.painting.document,
                  currentOwner === origin.source.document, copiedOwner === currentOwner,
                  originalOwner === currentOwner,
                  copy.rotation == source.rotation,
                  try PDFPageGeometryPreserver.current(copy) == PDFPageGeometryPreserver.current(source) else { return false }
            let originals = source.annotations
            guard originals.count <= 100_000 else { return false }
            let originalIDs = Set(originals.map(ObjectIdentifier.init))
            guard originalIDs.count == originals.count else { return false }
            // Exact factory/native/geometry checks above precede any mutation.
            // Use only the established factory-observed SDK-popup cleanup, with
            // the caller's same operation-wide budget. No arbitrary count/alias
            // mismatch is accepted. This only touches the owned copy's annotations.
            try PDFAnnotationRelationshipPreserver.prepareOwnedCopy(from: source, to: copy, budget: copyBudget)
            let copies = copy.annotations
            guard originals.count == copies.count,
                  source.document === document,
                  source.pageRef?.dictionary == currentDictionary,
                  source.pageRef?.document === currentOwner,
                  (objc_getAssociatedObject(source, pageAssociation) as? Origin) === origin,
                  (objc_getAssociatedObject(document, metadataSourceAssociation) as? Source) === metadata,
                  source.annotations.map(ObjectIdentifier.init) == originals.map(ObjectIdentifier.init),
                  copy.rotation == source.rotation,
                  try PDFPageGeometryPreserver.current(copy) == PDFPageGeometryPreserver.current(source) else { return false }
            // A proven annotation-only SDK cleanup may invalidate the copied
            // pageRef. Its before-cleanup native painting remains the exact
            // original; current annotations still pass the normal outer checks.
            var copiedIDs = Set<ObjectIdentifier>()
            for (index, annotation) in copies.enumerated() {
                if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                guard annotation.page === copy,
                      !originalIDs.contains(ObjectIdentifier(annotation)),
                      copiedIDs.insert(ObjectIdentifier(annotation)).inserted else { return false }
            }
            try PDFSaveCancellation.checkCurrent()
            // No Origin or marker is minted here. Existing annotation relationship,
            // navigation, field, signature-conversion and Catalog inheritance below
            // remain authoritative, including current annotation edits.
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { return false } // Optional copy/geometry misses keep the established snapshot path.
    }

    static func inherit(from source: PDFPage, to copy: PDFPage) {
        forwardLinkIntent(from: source)
        // Only exact same native dictionaries inherit the current raw owner.
        // This preserves an edited painting across the detached SDK snapshot;
        // it cannot bind a new parser graph by equal boxes or page counts.
        PDFRawStreamProvenance.inherit(from: source, to: copy)
        PDFRemoteNavigationPreserver.inheritPageState(from: source, to: copy)
        PDFAnnotationRelationshipPreserver.forward(from: source, to: copy)
        if let origin = objc_getAssociatedObject(source, pageAssociation) as? Origin {
            objc_setAssociatedObject(copy, pageAssociation, origin, .OBJC_ASSOCIATION_RETAIN)
            inheritAnnotationOrigins(from: source, to: copy)
        }
    }
    /// A replacement keeps document metadata and label provenance, while its
    /// current painting and newly generated text remain authoritative. Old
    /// MCID relationships cannot describe a newly edited content program.
    static func inheritMetadata(from source: PDFPage, to replacement: PDFPage) {
        forwardLinkIntent(from: source)
        PDFRemoteNavigationPreserver.inheritPageState(from: source, to: replacement)
        PDFAnnotationRelationshipPreserver.forward(from: source, to: replacement)
        guard let origin = objc_getAssociatedObject(source, pageAssociation) as? Origin else { return }
        // Initial support is one actual lossless edit from an unchanged
        // source baseline. A second unsaved edit cannot invent a chain.
        let candidate = origin.contentUnchanged ? PDFBodyLosslessProvenance.commit(for: replacement) : nil
        let body = candidate.flatMap { $0.original.dictionary == source.pageRef?.dictionary ? $0 : nil }
        objc_setAssociatedObject(replacement, pageAssociation,
            Origin(source: origin.source, index: origin.index, painting: origin.painting, geometry: origin.geometry,
                contentUnchanged: false, bodyCommit: body), .OBJC_ASSOCIATION_RETAIN)
        inheritAnnotationOrigins(from: source, to: replacement)
    }

    struct EditedPageTagSaveFailure: LocalizedError {
        let pageNumber: Int

        var errorDescription: String? {
            L10n.format("body_text.error.save_accessibility_tags", pageNumber)
        }
    }

    /// An edited page may be useful in memory even when its original tag
    /// ownership cannot be proven. Never serialize it with that ownership
    /// silently removed. The original page survives on the inherited origin
    /// even after a detached snapshot or another unsaved replacement.
    static func validateEditedPageTags(in document: PDFDocument, plan: PDFCatalogGraphPlan? = nil) throws {
        for index in 0..<document.pageCount {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index),
                  let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
                  !origin.contentUnchanged,
                  let original = origin.painting.dictionary,
                  object(original, "StructParents") != nil,
                  let catalog = origin.source.document.catalog,
                  let tree = object(catalog, "StructTreeRoot"), CGPDFObjectGetType(tree) != .null else { continue }
            guard origin.bodyCommit != nil else { throw EditedPageTagSaveFailure(pageNumber: index + 1) }
            if let plan {
                guard plan.bodyTagPermissions[index]?.matchesCurrent(page) == true,
                      plan.catalogEntries["StructTreeRoot"] != nil,
                      case .integer? = plan.pageEntries[index]?["StructParents"] else {
                    throw EditedPageTagSaveFailure(pageNumber: index + 1)
                }
            }
        }
    }
    @discardableResult
    static func rememberOutlineDestination(_ outline: PDFOutline, destination: CGPDFArrayRef, document: CGPDFDocument,
                                           restoresSerializedView: Bool = true) -> Bool {
        guard let current = (outline.action as? PDFActionGoTo)?.destination ?? outline.destination,
              (2...7).contains(CGPDFArrayGetCount(destination)) else { return false }
        var mode: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(destination, 1, &mode), let mode,
              let count = ["XYZ": 5, "Fit": 2, "FitH": 3, "FitV": 3, "FitR": 6,
                           "FitB": 2, "FitBH": 3, "FitBV": 3][String(cString: mode)],
              CGPDFArrayGetCount(destination) <= count,
              String(cString: mode) != "FitR" || CGPDFArrayGetCount(destination) == count else { return false }
        var operands: [PDFCatalogGraphValue] = []
        for index in 1..<CGPDFArrayGetCount(destination) {
            var value: CGPDFObjectRef?
            guard CGPDFArrayGetObject(destination, index, &value), let value else { return false }
            operands.append(.original(value))
        }
        while operands.count < count - 1 { operands.append(.null) }
        objc_setAssociatedObject(outline, outlineAssociation,
            OutlineDestination(operands: operands, document: document, destination: current,
                               restoresSerializedView: restoresSerializedView), .OBJC_ASSOCIATION_RETAIN)
        return true
    }
    @discardableResult
    static func inheritOutlineDestination(from source: PDFOutline, to copy: PDFOutline) -> Bool {
        if let candidate = pendingInertOutlineCandidate(source), isInactiveOutlineParent(copy) {
            rememberPendingInertOutline(copy, candidate: candidate)
            return true
        }
        guard let original = objc_getAssociatedObject(source, outlineAssociation) as? OutlineDestination,
              let sourceDestination = (source.action as? PDFActionGoTo)?.destination ?? source.destination,
              original.destination === sourceDestination, original.point == sourceDestination.point,
              original.zoom == sourceDestination.zoom,
              let current = (copy.action as? PDFActionGoTo)?.destination ?? copy.destination else { return false }
        objc_setAssociatedObject(copy, outlineAssociation,
            OutlineDestination(operands: original.operands, document: original.document, destination: current), .OBJC_ASSOCIATION_RETAIN)
        return true
    }

    /// Capture public local-link destination copies before a snapshot rebinds
    /// their page. Point/zoom alone cannot represent FitH/FitR view operands.
    static func rememberLiveAnnotationDestinations(in document: PDFDocument) throws {
        var candidates: [(PDFAnnotation, PDFDestination)] = []
        var visits = 0
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            for annotation in page.annotations {
                visits += 1
                guard visits <= 100_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                guard let destination = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination,
                      let target = destination.page, document.index(for: target) != NSNotFound else { continue }
                let previous = objc_getAssociatedObject(annotation, annotationDestinationAssociation) as? OutlineDestination
                if previous?.destination !== destination || previous?.point != destination.point || previous?.zoom != destination.zoom {
                    candidates.append((annotation, destination))
                }
            }
        }
        guard !candidates.isEmpty else { return }
        let carrier = PDFDocument(), page = PDFPage(), navigation = PDFOutline()
        page.setBounds(CGRect(x: 0, y: 0, width: 100, height: 100), for: .mediaBox)
        carrier.insert(page, at: 0)
        for (index, candidate) in candidates.enumerated() {
            guard let destination = candidate.1.copy() as? PDFDestination else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            let item = PDFOutline(); item.label = String(index); item.destination = destination
            navigation.insertChild(item, at: navigation.numberOfChildren)
        }
        carrier.outlineRoot = navigation
        guard let data = carrier.dataRepresentation(), data.count <= 32 * 1_024 * 1_024,
              let provider = CGDataProvider(data: data as CFData), let native = CGPDFDocument(provider),
              native.numberOfPages == 1, let catalog = native.catalog,
              let outlines = dictionary(catalog, "Outlines") else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        var node = dictionary(outlines, "First")
        for (index, candidate) in candidates.enumerated() {
            var title: CGPDFStringRef?
            guard let current = node,
                  CGPDFDictionaryGetString(current, "Title", &title),
                  title.flatMap(CGPDFStringCopyTextString).map({ $0 as String }) == String(index),
                  let serialized = array(current, "Dest"),
                  let item = navigation.child(at: index),
                  rememberOutlineDestination(item, destination: serialized, document: native),
                  let saved = objc_getAssociatedObject(item, outlineAssociation) as? OutlineDestination else {
                throw PDFPageStructurePreserver.Failure.invalidDestination
            }
            objc_setAssociatedObject(candidate.0, annotationDestinationAssociation,
                OutlineDestination(operands: saved.operands, document: native, destination: candidate.1), .OBJC_ASSOCIATION_RETAIN)
            node = dictionary(current, "Next")
        }
        guard node == nil else { throw PDFPageStructurePreserver.Failure.invalidDestination }
        // A plain local-link PDF may have no catalog-level preservation keys.
        // Its captured view operands still require page origins and a graph
        // write when the snapshot replaces the public destination objects.
        mark(document)
    }

    /// Called only after the snapshot has explicitly mapped the old target
    /// page to its detached counterpart. A replaced/edited destination wins.
    static func inheritAnnotationDestination(from source: PDFAnnotation, to copy: PDFAnnotation,
                                             sourceDocument: PDFDocument, copiedDocument: PDFDocument) {
        guard let original = objc_getAssociatedObject(source, annotationDestinationAssociation) as? OutlineDestination,
              let before = (source.action as? PDFActionGoTo)?.destination ?? source.destination,
              original.destination === before, original.point == before.point, original.zoom == before.zoom,
              let current = (copy.action as? PDFActionGoTo)?.destination ?? copy.destination,
              current.point == before.point, current.zoom == before.zoom,
              let beforePage = before.page, let afterPage = current.page,
              afterPage.document === copiedDocument,
              sourceDocument.index(for: beforePage) != NSNotFound,
              sourceDocument.index(for: beforePage) == copiedDocument.index(for: afterPage) else { return }
        objc_setAssociatedObject(copy, annotationDestinationAssociation,
            OutlineDestination(operands: original.operands, document: original.document, destination: current), .OBJC_ASSOCIATION_RETAIN)
    }

    /// A body edit intentionally replaces a page while keeping its navigation.
    /// Only this verified lineage transfer may give a new destination object
    /// the old view mode; an independently replaced bookmark remains authoritative.
    static func rebindOutlineDestination(_ outline: PDFOutline, from before: PDFDestination, to after: PDFDestination) {
        guard let original = objc_getAssociatedObject(outline, outlineAssociation) as? OutlineDestination,
              original.destination === before, original.point == before.point, original.zoom == before.zoom,
              before.point == after.point, before.zoom == after.zoom,
              let beforePage = before.page, let afterPage = after.page,
              let beforeOrigin = objc_getAssociatedObject(beforePage, pageAssociation) as? Origin,
              let afterOrigin = objc_getAssociatedObject(afterPage, pageAssociation) as? Origin,
              beforeOrigin.source === afterOrigin.source, beforeOrigin.index == afterOrigin.index else {
            objc_setAssociatedObject(outline, outlineAssociation, nil, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        objc_setAssociatedObject(outline, outlineAssociation,
            OutlineDestination(operands: original.operands, document: original.document, destination: after), .OBJC_ASSOCIATION_RETAIN)
    }

    /// PDFDestination's public point/zoom omit FitH/FitR and other view-mode
    /// operands. Copy its current state into a small navigation-only carrier
    /// before rebinding, without serializing any source page painting. Reading
    /// the carrier also respects bookmarks edited before this first capture;
    /// no native/live outline matching or private PDFKit fields are needed.
    private static func rememberLiveOutlineDestinations(in document: PDFDocument) throws {
        guard let root = document.outlineRoot else { return }
        let native = document.documentRef, rawSource = PDFRawStreamProvenance.source(for: document)
        let nativeRoot = rawSource == nil ? nil : native?.catalog.flatMap { dictionary($0, "Outlines") }
        var pending: [(PDFOutline, Int, [Int], CGPDFDictionaryRef?)] = [(root, 0, [], nativeRoot)]
        var seen = Set<ObjectIdentifier>()
        var candidates: [(PDFOutline, PDFDestination)] = []
        while let (outline, depth, path, nativeNode) = pending.popLast() {
            guard depth < 64, seen.insert(ObjectIdentifier(outline)).inserted,
                  seen.count <= 100_000, outline.numberOfChildren <= 100_000 - pending.count else {
                throw PDFPageStructurePreserver.Failure.tooComplex
            }
            // Piggyback on this existing metadata walk; Main does not add a
            // second outline scan or touch the independent reader.
            if outline !== root, !hasPendingInertOutlineRecord(outline), isInactiveOutlineParent(outline),
               outline.numberOfChildren > 0, let native, let nativeNode, let rawSource,
               let candidate = try rawSource.pendingOriginalInertOutlineParent(in: native, node: nativeNode, path: path) {
                rememberPendingInertOutline(outline, candidate: candidate)
            }
            if outline !== root, let destination = (outline.action as? PDFActionGoTo)?.destination ?? outline.destination,
               let page = destination.page, document.index(for: page) != NSNotFound {
                let previous = objc_getAssociatedObject(outline, outlineAssociation) as? OutlineDestination
                if previous?.destination !== destination || previous?.point != destination.point || previous?.zoom != destination.zoom {
                    candidates.append((outline, destination))
                }
            }
            var nativeChild = nativeNode.flatMap { dictionary($0, "First") }
            for index in 0..<outline.numberOfChildren {
                if let child = outline.child(at: index) {
                    pending.append((child, depth + 1, path + [index], matchingNativeOutline(nativeChild, to: child)))
                }
                nativeChild = nativeChild.flatMap { dictionary($0, "Next") }
            }
        }
        guard !candidates.isEmpty else { return }
        let carrier = PDFDocument(), page = PDFPage(), navigation = PDFOutline()
        page.setBounds(CGRect(x: 0, y: 0, width: 100, height: 100), for: .mediaBox)
        carrier.insert(page, at: 0)
        for (index, candidate) in candidates.enumerated() {
            guard let destination = candidate.1.copy() as? PDFDestination else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            let item = PDFOutline(); item.label = String(index); item.destination = destination
            navigation.insertChild(item, at: navigation.numberOfChildren)
        }
        carrier.outlineRoot = navigation
        guard let data = carrier.dataRepresentation(), data.count <= 32 * 1_024 * 1_024,
              let provider = CGDataProvider(data: data as CFData), let native = CGPDFDocument(provider),
              native.numberOfPages == 1, let catalog = native.catalog,
              let outlines = dictionary(catalog, "Outlines") else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        var node = dictionary(outlines, "First")
        for (index, candidate) in candidates.enumerated() {
            var title: CGPDFStringRef?
            guard let current = node,
                  CGPDFDictionaryGetString(current, "Title", &title),
                  title.flatMap(CGPDFStringCopyTextString).map({ $0 as String }) == String(index),
                  let destination = array(current, "Dest"),
                  rememberOutlineDestination(candidate.0, destination: destination, document: native,
                                             restoresSerializedView: false) else {
                throw PDFPageStructurePreserver.Failure.invalidDestination
            }
            node = dictionary(current, "Next")
        }
        guard node == nil else { throw PDFPageStructurePreserver.Failure.invalidDestination }
    }
    /// An explicit page-assembly output may omit proven unused image names.
    /// This intent grants no font, raw-source, tag or painting authority.
    static func permitsAssemblyImagePruning(_ document: PDFDocument) -> Bool {
        (objc_getAssociatedObject(document, assemblyImagePruningAssociation) as? NSNumber)?.boolValue == true
    }

    static func setAssemblyImagePruning(_ enabled: Bool, for document: PDFDocument) {
        objc_setAssociatedObject(document, assemblyImagePruningAssociation,
            enabled ? NSNumber(value: true) : nil, .OBJC_ASSOCIATION_RETAIN)
    }

    static func mark(_ document: PDFDocument) {
        objc_setAssociatedObject(document, documentAssociation, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN)
    }
    static func refreshMarker(_ document: PDFDocument) {
        let needed = (0..<document.pageCount).contains { index in
            guard let page = document.page(at: index) else { return false }
            return objc_getAssociatedObject(page, pageAssociation) is Origin
        }
        objc_setAssociatedObject(document, documentAssociation, needed ? NSNumber(value: true) : nil, .OBJC_ASSOCIATION_RETAIN)
    }
    static func containsSignedOriginal(_ document: PDFDocument) -> Bool {
        (0..<document.pageCount).contains { index in
            guard let page = document.page(at: index), let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin else { return false }
            if origin.source.signedData != nil { return true }
            guard let catalog = origin.source.document.catalog else { return false }
            var archived: CGPDFBoolean = 0
            return CGPDFDictionaryGetBoolean(catalog, "EmberPDFContainsSignedOriginal", &archived) && archived != 0
        }
    }
    /// `force` is reserved for an exact detached snapshot after prepare(force:)
    /// registered its live/native page identities. A plain native document
    /// also needs those paintings; PDFKit serialization can redraw them.
    static func inheritDocumentMetadata(from source: PDFDocument, to copy: PDFDocument) {
        if source !== copy,
           let capture = objc_getAssociatedObject(source, outlineStyleFactoryAssociation) as? OutlineStyleCapture {
            let existing = objc_getAssociatedObject(copy, outlineStyleFactoryAssociation) as? OutlineStyleCapture
            let completed = capture.document === source && capture.completed
                && (existing.map { $0.document === copy && $0.completed } ?? true)
            objc_setAssociatedObject(copy, outlineStyleFactoryAssociation,
                OutlineStyleCapture(document: copy, completed: completed), .OBJC_ASSOCIATION_RETAIN)
        }
        linkIntentLock.lock()
        let inheritedIntent = linkIntent(for: source)
        if (objc_getAssociatedObject(copy, linkIntentAssociation) as? LinkEditIntent)?.isEdited == true { inheritedIntent.record() }
        objc_setAssociatedObject(copy, linkIntentAssociation, inheritedIntent, .OBJC_ASSOCIATION_RETAIN)
        linkIntentLock.unlock()
        if let owner = objc_getAssociatedObject(source, metadataSourceAssociation) as? Source {
            objc_setAssociatedObject(copy, metadataSourceAssociation, owner, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    static func forward(from source: PDFDocument, to copy: PDFDocument, force: Bool = false) {
        inheritDocumentMetadata(from: source, to: copy)
        guard (force || needsMaterialization(source)), source.pageCount == copy.pageCount else { return }
        for index in 0..<source.pageCount {
            if let original = source.page(at: index), let page = copy.page(at: index) { inherit(from: original, to: page) }
        }
        // Only this exact forward/recovery copy carries the assembly intent;
        // generic metadata inheritance and transformed outputs do not.
        setAssemblyImagePruning(permitsAssemblyImagePruning(source), for: copy)
        mark(copy)
    }

    /// This token can only be minted from existing page provenance. It does not
    /// grant the auxiliary authority over current painting or global metadata.
    struct NativeStagingSource {
        let owner: CGPDFDocument
        let rawSource: PDFRawStreamSource
        fileprivate let sourceIdentity: ObjectIdentifier
        let hasTags: Bool
        let metadataOwner: CGPDFDocument
        let baselineOutlineRootLabel: String?
        fileprivate let metadataIdentity: ObjectIdentifier
        fileprivate let currentState: Data
        fileprivate init(owner: CGPDFDocument, raw: PDFRawStreamSource, identity: ObjectIdentifier, tags: Bool,
                         metadataOwner: CGPDFDocument, metadataIdentity: ObjectIdentifier, rootLabel: String?, state: Data) {
            self.owner = owner; rawSource = raw; sourceIdentity = identity; hasTags = tags
            self.metadataOwner = metadataOwner; self.metadataIdentity = metadataIdentity
            baselineOutlineRootLabel = rootLabel; currentState = state
        }
    }

    private static let emptyFormSnapshotKey = NSObject()
    private static var emptyFormSnapshotAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(emptyFormSnapshotKey).toOpaque())
    }
    /// One SDK-created recovery copy, never a transferable marker. The current
    /// document is weak; retaining its native graph keeps only borrowed refs
    /// alive. Previous snapshot documents/nonces are not retained.
    private final class EmptyFormSnapshotWitness {
        weak var document: PDFDocument?
        let native: CGPDFDocument
        let metadata: Source
        let originalForm: CGPDFObjectRef
        let currentForm: CGPDFObjectRef?
        let generation: UInt64
        init(document: PDFDocument, native: CGPDFDocument, metadata: Source,
             original: CGPDFObjectRef, current: CGPDFObjectRef?, generation: UInt64) {
            self.document = document; self.native = native; self.metadata = metadata
            originalForm = original; currentForm = current; self.generation = generation
        }
    }
    private static func sameEmptyFormObject(_ lhs: CGPDFObjectRef?, _ rhs: CGPDFObjectRef?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return pdfReferenceIdentity(lhs) == pdfReferenceIdentity(rhs)
        default: return false
        }
    }
    private static func emptyFormSnapshotWitness(for document: PDFDocument, metadata: Source,
                                                 original: CGPDFObjectRef) -> EmptyFormSnapshotWitness? {
        guard let witness = objc_getAssociatedObject(document, emptyFormSnapshotAssociation) as? EmptyFormSnapshotWitness,
              witness.document === document, witness.metadata === metadata,
              sameEmptyFormObject(witness.originalForm, original),
              let native = document.documentRef, native === witness.native, let catalog = native.catalog,
              sameEmptyFormObject(object(catalog, "AcroForm"), witness.currentForm) else { return nil }
        return witness
    }
    private static func emptyFormSnapshotHasNoWidgets(_ document: PDFDocument) throws -> Bool {
        guard !document.isEncrypted, !document.isLocked,
              document.pageCount > 0, document.pageCount <= 4_096 else { return false }
        var remaining = 100_000
        for index in 0..<document.pageCount {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index) else { return false }
            let annotations = page.annotations
            guard annotations.count <= remaining,
                  annotations.allSatisfy({ $0.type != "Widget" }) else { return false }
            remaining -= annotations.count
        }
        return true
    }

    /// Only this Main-owned boundary invokes the actual SDK copy and can mint
    /// an empty-form nonce. Generic forward/inherit never creates or transfers
    /// it. Optional metadata misses keep the normal copy path; only explicit
    /// cancellation propagates a new error.
    @MainActor
    static func recoverySnapshotCopy(of source: PDFDocument, capturedWidgetCount: Int) throws -> PDFDocument? {
        try PDFSaveCancellation.checkCurrent()
        if try requiresManualRecoverySnapshot(source, widgetCount: capturedWidgetCount) {
            return try PDFPageStructurePreserver.manualRecoverySnapshotCopy(from: source)
        }
        var captured: (proof: EmptyFormSource, metadata: Source, native: CGPDFDocument,
                       form: CGPDFObjectRef?, generation: UInt64)?
        do {
            if capturedWidgetCount == 0,
               let proof = try emptyFormSource(for: source, widgetCount: 0),
               let metadata = objc_getAssociatedObject(source, metadataSourceAssociation) as? Source,
               let native = source.documentRef, !native.isEncrypted, native.isUnlocked,
               !hasActualSignature(native), let catalog = native.catalog,
               try emptyFormSnapshotHasNoWidgets(source) {
                let currentForm = object(catalog, "AcroForm")
                if sameEmptyFormObject(currentForm, proof.form) {
                    captured = (proof, metadata, native, currentForm, 1)
                } else if let witness = emptyFormSnapshotWitness(for: source, metadata: metadata, original: proof.form) {
                    let next = witness.generation.addingReportingOverflow(1)
                    if !next.overflow { captured = (proof, metadata, native, currentForm, next.partialValue) }
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { captured = nil }
        // This operation is unchanged for ordinary, Widget and unsupported
        // form documents. No optional restoration test may suppress the copy.
        guard let copy = source.copy() as? PDFDocument, copy !== source else { return nil }
        try PDFSaveCancellation.checkCurrent()
        guard let captured else { return copy }
        do {
            guard capturedWidgetCount == 0, source.documentRef === captured.native,
                  let sourceCatalog = captured.native.catalog,
                  sameEmptyFormObject(object(sourceCatalog, "AcroForm"), captured.form),
                  (objc_getAssociatedObject(source, metadataSourceAssociation) as? Source) === captured.metadata,
                  let fresh = try emptyFormSource(for: source, widgetCount: 0),
                  fresh.sourceIdentity == captured.proof.sourceIdentity,
                  sameEmptyFormObject(fresh.form, captured.proof.form),
                  !copy.isEncrypted, !copy.isLocked, copy.pageCount == source.pageCount,
                  try emptyFormSnapshotHasNoWidgets(source), try emptyFormSnapshotHasNoWidgets(copy),
                  let native = copy.documentRef, !native.isEncrypted, native.isUnlocked,
                  !hasActualSignature(native), let catalog = native.catalog else { return copy }
            let currentForm = object(catalog, "AcroForm")
            if let currentForm {
                guard CGPDFObjectGetType(currentForm) == .dictionary,
                      let form = dictionary(catalog, "AcroForm"), try isSupportedEmptyForm(form) else { return copy }
            }
            let witness = EmptyFormSnapshotWitness(document: copy, native: native, metadata: captured.metadata,
                original: captured.proof.form, current: currentForm, generation: captured.generation)
            objc_setAssociatedObject(copy, emptyFormSnapshotAssociation, witness, .OBJC_ASSOCIATION_RETAIN)
        } catch is CancellationError { throw CancellationError() }
        catch { /* Optional metadata refusal does not change SDK copy success. */ }
        return copy
    }

    /// Recover only a factory-bound, originally empty outline dictionary that
    /// the SDK omitted. This token never carries an outline item/destination.
    struct EmptyOutlineSource {
        fileprivate let owner: CGPDFDocument
        fileprivate let raw: PDFRawStreamSource
        fileprivate let sourceIdentity: ObjectIdentifier
        fileprivate let outlines: CGPDFObjectRef
    }

    private static func isSupportedEmptyOutline(_ outlines: CGPDFDictionaryRef) throws -> Bool {
        guard CGPDFDictionaryGetCount(outlines) <= 3,
              Set(try dictionaryKeys(outlines)).isSubset(of: ["Type", "Count", "Title"]) else { return false }
        // Present null, First/Last (including null), unknown controls and any
        // positive/negative child count are outside this empty-root policy.
        if object(outlines, "Type") != nil, nativeName(outlines, "Type") != "Outlines" { return false }
        if let value = object(outlines, "Count") {
            var count: CGPDFInteger = 0
            guard CGPDFObjectGetType(value) == .integer,
                  CGPDFObjectGetValue(value, .integer, &count), count == 0 else { return false }
        }
        if let value = object(outlines, "Title") {
            var title: CGPDFStringRef?
            guard CGPDFObjectGetType(value) == .string,
                  CGPDFObjectGetValue(value, .string, &title), let title,
                  CGPDFStringGetLength(title) <= 65_536 else { return false }
        }
        return true
    }

    private static func currentEmptyOutlineMatchesBaseline(_ document: PDFDocument, source: Source) -> Bool {
        guard source.baselineOutlineRootWasPresent else { return document.outlineRoot == nil }
        guard let root = document.outlineRoot else { return false } // Explicit removal wins.
        return root.numberOfChildren == 0 && root.action == nil && root.destination == nil
            && root.label == source.baselineOutlineRootLabel
            && root.isOpen == source.baselineOutlineRootIsOpen
    }

    private static func emptyOutlineSource(for document: PDFDocument) throws -> EmptyOutlineSource? {
        try PDFSaveCancellation.checkCurrent()
        guard !document.isEncrypted, !document.isLocked, document.pageCount > 0,
              let source = objc_getAssociatedObject(document, metadataSourceAssociation) as? Source,
              source.signedData == nil, !source.document.isEncrypted, source.document.isUnlocked,
              source.knownNativeInput, let raw = source.rawStreamSource,
              raw.provesExactFactoryOwner(source.document),
              currentEmptyOutlineMatchesBaseline(document, source: source),
              let catalog = source.document.catalog,
              object(catalog, "EmberPDFContainsSignedOriginal") == nil,
              let value = object(catalog, "Outlines"), CGPDFObjectGetType(value) == .dictionary,
              let outlines = dictionary(catalog, "Outlines"), try isSupportedEmptyOutline(outlines) else { return nil }
        if source.baselineOutlineRootWasPresent {
            // A label already changed before first preparation is current
            // intent, not permission to restore a different original Title.
            if let title = object(outlines, "Title") {
                var string: CGPDFStringRef?
                guard CGPDFObjectGetValue(title, .string, &string), let string,
                      let text = CGPDFStringCopyTextString(string),
                      (text as String) == source.baselineOutlineRootLabel else { return nil }
            } else if source.baselineOutlineRootLabel != nil { return nil }
        }
        return EmptyOutlineSource(owner: source.document, raw: raw,
            sourceIdentity: ObjectIdentifier(source), outlines: value)
    }

    /// Revalidate at the final graph boundary. A current/nonempty/null staged
    /// root and caller-supplied catalog overrides never borrow this authority.
    static func originalEmptyOutline(_ proof: EmptyOutlineSource, for document: PDFDocument,
                                     staged: CGPDFDocument) throws -> CGPDFObjectRef? {
        try PDFSaveCancellation.checkCurrent()
        guard !staged.isEncrypted, staged.isUnlocked, staged.numberOfPages == document.pageCount,
              let catalog = staged.catalog, object(catalog, "Outlines") == nil,
              let current = try emptyOutlineSource(for: document),
              current.sourceIdentity == proof.sourceIdentity, current.owner === proof.owner,
              current.raw === proof.raw,
              pdfReferenceIdentity(current.outlines) == pdfReferenceIdentity(proof.outlines) else { return nil }
        return proof.outlines
    }

    /// The metadata owner is inherited explicitly by the app's document
    /// transaction; a first page/source group cannot grant global form authority.
    /// This token grants only recovery of an absent, originally empty form.
    struct EmptyFormSource {
        fileprivate let owner: CGPDFDocument
        fileprivate let raw: PDFRawStreamSource
        fileprivate let sourceIdentity: ObjectIdentifier
        fileprivate let form: CGPDFObjectRef
        fileprivate init(owner: CGPDFDocument, raw: PDFRawStreamSource, identity: ObjectIdentifier, form: CGPDFObjectRef) {
            self.owner = owner; self.raw = raw
            sourceIdentity = identity; self.form = form
        }
    }

    /// A literal empty calculation order with no fields has no executable
    /// work. This shape check grants no raw-copy or snapshot authority.
    /// Present null, malformed, nonempty or field-bearing CO stays guarded.
    static func hasNoCalculationOrderWork(_ form: CGPDFDictionaryRef) -> Bool {
        var stored: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(form, "CO", &stored) else { return true }
        guard let value = stored, CGPDFObjectGetType(value) == .array,
              let order = array(form, "CO"), CGPDFArrayGetCount(order) == 0,
              let fields = array(form, "Fields"), CGPDFArrayGetCount(fields) == 0 else { return false }
        return true
    }

    private static func isSupportedEmptyForm(_ form: CGPDFDictionaryRef) throws -> Bool {
        guard Set(try dictionaryKeys(form)).isSubset(of: ["Fields", "DA", "DR", "Q", "NeedAppearances", "CO"]),
              hasNoCalculationOrderWork(form),
              let fields = array(form, "Fields"), CGPDFArrayGetCount(fields) == 0 else { return false }
        for (key, kind) in [("DA", CGPDFObjectType.string), ("DR", .dictionary),
                            ("Q", .integer), ("NeedAppearances", .boolean)] {
            if let value = object(form, key), CGPDFObjectGetType(value) != kind { return false }
        }
        return true
    }

    private static func emptyFormSource(for document: PDFDocument, widgetCount: Int) throws -> EmptyFormSource? {
        guard !document.isEncrypted, !document.isLocked,
              widgetCount == 0, document.pageCount > 0, document.pageCount <= 4_096,
              let source = objc_getAssociatedObject(document, metadataSourceAssociation) as? Source,
              source.signedData == nil, !source.document.isEncrypted, source.document.isUnlocked,
              source.knownNativeInput, let raw = source.rawStreamSource,
              raw.provesExactFactoryOwner(source.document), let catalog = source.document.catalog,
              let value = object(catalog, "AcroForm"), CGPDFObjectGetType(value) == .dictionary,
              let form = dictionary(catalog, "AcroForm"), try isSupportedEmptyForm(form) else { return nil }
        for index in 0..<document.pageCount {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index),
                  let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
                  origin.source === source else { return nil }
        }
        // A stale nonce cannot downgrade into the legacy absent-form path.
        // The exact SDK copy/native/form/metadata generation must still match.
        let witness = emptyFormSnapshotWitness(for: document, metadata: source, original: value)
        if objc_getAssociatedObject(document, emptyFormSnapshotAssociation) != nil, witness == nil { return nil }
        // A distinct present current native form remains current metadata,
        // except for that exact owned recovery copy. No numeric comparison.
        if let currentNative = document.documentRef {
            guard !currentNative.isEncrypted, currentNative.isUnlocked,
                  !hasActualSignature(currentNative) else { return nil }
            if let currentCatalog = currentNative.catalog,
               let current = object(currentCatalog, "AcroForm"),
               pdfReferenceIdentity(current) != pdfReferenceIdentity(value), witness == nil { return nil }
        }
        return EmptyFormSource(owner: source.document, raw: raw, identity: ObjectIdentifier(source), form: value)
    }

    /// Run on the confined save worker against the actual serialized carrier.
    /// Any present form, including different defaults or an explicit null,
    /// remains authoritative. No equality through CGFloat/Double is used.
    static func originalEmptyForm(_ proof: EmptyFormSource, for document: PDFDocument,
                                  staged: CGPDFDocument) throws -> CGPDFObjectRef? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, !document.isEncrypted, !document.isLocked,
              !proof.owner.isEncrypted, proof.owner.isUnlocked,
              !staged.isEncrypted, staged.isUnlocked, !hasActualSignature(staged), let catalog = staged.catalog,
              object(catalog, "AcroForm") == nil,
              let metadata = objc_getAssociatedObject(document, metadataSourceAssociation) as? Source,
              ObjectIdentifier(metadata) == proof.sourceIdentity, metadata.document === proof.owner,
              metadata.rawStreamSource === proof.raw, proof.raw.provesExactFactoryOwner(proof.owner),
              let current = try emptyFormSource(for: document, widgetCount: 0),
              current.sourceIdentity == proof.sourceIdentity,
              pdfReferenceIdentity(current.form) == pdfReferenceIdentity(proof.form),
              document.pageCount == staged.numberOfPages else { return nil }
        var remainingLiveAnnotations = 100_000, remainingStagedAnnotations = 100_000
        for index in 0..<document.pageCount {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index),
                  let saved = staged.page(at: index + 1)?.dictionary else { return nil }
            let liveAnnotations = page.annotations
            guard liveAnnotations.count <= remainingLiveAnnotations,
                  liveAnnotations.allSatisfy({ $0.type != "Widget" }) else { return nil }
            remainingLiveAnnotations -= liveAnnotations.count
            if let annotationsObject = object(saved, "Annots") {
                guard CGPDFObjectGetType(annotationsObject) == .array,
                      let annotations = array(saved, "Annots"),
                      CGPDFArrayGetCount(annotations) <= remainingStagedAnnotations else { return nil }
                remainingStagedAnnotations -= CGPDFArrayGetCount(annotations)
                for annotationIndex in 0..<CGPDFArrayGetCount(annotations) {
                    if annotationIndex & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    var annotation: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(annotations, annotationIndex, &annotation), let annotation,
                          let subtype = nativeName(annotation, "Subtype"), subtype != "Widget" else { return nil }
                }
            }
        }
        try PDFSaveCancellation.checkCurrent()
        return proof.form
    }

    private static func dictionaryKeys(_ dictionary: CGPDFDictionaryRef) throws -> [String] {
        guard CGPDFDictionaryGetCount(dictionary) <= 4_096 else { throw PDFPageStructurePreserver.Failure.tooComplex }
        var keys: [String] = [], valid = true
        CGPDFDictionaryApplyBlock(dictionary, { key, _, _ in
            guard strnlen(key, 4_097) <= 4_096 else { valid = false; return false }
            keys.append(String(cString: key)); return true
        }, nil)
        guard valid else { throw PDFPageStructurePreserver.Failure.tooComplex }
        return keys
    }

    private static func stagingRefused<T>(_ line: Int) -> T? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_TRACE"] == "1" {
            FileHandle.standardError.write(Data("native-staging-admission-refused-line=\(line)\n".utf8))
        }
        #endif
        return nil
    }

    static func nativeStagingSource(for document: PDFDocument) throws -> NativeStagingSource? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, !document.isEncrypted, !document.isLocked,
              document.pageCount > 0, document.pageCount <= 4_096 else { return stagingRefused(#line) }
        var source: Source?, annotations = 0, neutralBytes = 4_096
        for index in 0..<document.pageCount {
            if index & 31 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index) else { return stagingRefused(#line) }
            let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin
            // A detached SDK page can lose its direct RawSource association.
            // Its immutable, unchanged Origin still binds the exact original
            // blank painting to the factory owner; current annotations remain
            // authoritative and a changed body cannot borrow this proof.
            if page.annotations.isEmpty, let origin, origin.contentUnchanged,
               origin.source.knownNativeInput, origin.source.signedData == nil,
               let neutralRaw = origin.source.rawStreamSource,
               try neutralRaw.provesNeutralNativeStagingPage(origin.painting, remainingBytes: &neutralBytes) {
                continue
            }
            guard let origin, origin.source.knownNativeInput, origin.source.signedData == nil,
                  let raw = origin.source.rawStreamSource, raw.provesExactFactoryOwner(origin.source.document),
                  let painting = origin.contentUnchanged ? origin.painting : page.pageRef,
                  let dictionary = painting.dictionary else { return stagingRefused(#line) }
            if let source, source !== origin.source { return stagingRefused(#line) }
            source = origin.source
            // Modified bodies use their current, factory-bound painting only.
            // The ordinary writer remains responsible for arbitrary new pages.
            if !origin.contentUnchanged {
                var marker: CGPDFBoolean = 0
                guard CGPDFDictionaryGetBoolean(dictionary, "EmberPDFPreservePageContent", &marker), marker != 0,
                      PDFRawStreamProvenance.source(for: page) != nil else { return stagingRefused(#line) }
            }
            if let unit = object(dictionary, "UserUnit") {
                var value: CGPDFReal = 0
                guard CGPDFObjectGetValue(unit, .real, &value), value == 1 else { return stagingRefused(#line) }
            }
            annotations += page.annotations.count
            guard annotations <= 100_000 else { return stagingRefused(#line) }
            for annotation in page.annotations {
                guard annotation.type == "Link", annotation.popup == nil,
                      annotation.value(forAnnotationKey: .init(rawValue: "/AP")) == nil,
                      annotation.value(forAnnotationKey: .init(rawValue: "/AA")) == nil else { return stagingRefused(#line) }
                if let action = annotation.action, !(action is PDFActionGoTo), !(action is PDFActionURL) { return stagingRefused(#line) }
                if let origin = objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin,
                   let native = originalAnnotation(origin),
                   object(native, "AP") != nil || object(native, "AA") != nil { return stagingRefused(#line) }
            }
        }
        guard let source, let catalog = source.document.catalog,
              CGPDFDictionaryGetCount(catalog) <= 4_096,
              object(catalog, "EmberPDFContainsSignedOriginal") == nil,
              let pages = dictionary(catalog, "Pages"), CGPDFDictionaryGetCount(pages) <= 4_096 else { return stagingRefused(#line) }
        // Only this scalar vendor key has a defined root-Pages preservation
        // policy here. Unknown root keys keep the established serialization.
        let pageKeys = try dictionaryKeys(pages)
        guard Set(pageKeys).isSubset(of: ["Type", "Kids", "Count", "Resources", "MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox", "Rotate", "ITXT"]),
              object(pages, "ITXT").map({ CGPDFObjectGetType($0) == .string }) ?? true else { return stagingRefused(#line) }
        if let outlines = dictionary(catalog, "Outlines") {
            guard Set(try dictionaryKeys(outlines)).isSubset(of: ["Type", "First", "Last", "Count", "Title"]),
                  object(outlines, "Title").map({ CGPDFObjectGetType($0) == .string }) ?? true else { return stagingRefused(#line) }
        }
        if let formObject = object(catalog, "AcroForm") {
            guard CGPDFObjectGetType(formObject) == .dictionary,
                  let form = dictionary(catalog, "AcroForm"),
                  Set(try dictionaryKeys(form)).isSubset(of: ["Fields", "DA", "DR", "Q", "NeedAppearances", "CO"]),
              hasNoCalculationOrderWork(form),
                  object(form, "DA").map({ CGPDFObjectGetType($0) == .string }) ?? true,
                  object(form, "DR").map({ CGPDFObjectGetType($0) == .dictionary }) ?? true,
                  object(form, "Q").map({ CGPDFObjectGetType($0) == .integer }) ?? true,
                  object(form, "NeedAppearances").map({ CGPDFObjectGetType($0) == .boolean }) ?? true,
                  let fields = array(form, "Fields"), CGPDFArrayGetCount(fields) == 0 else { return stagingRefused(#line) }
        }
        guard let metadata = objc_getAssociatedObject(document, metadataSourceAssociation) as? Source,
              let state = try nativeStagingCurrentState(document) else { return stagingRefused(#line) }
        return NativeStagingSource(owner: source.document, raw: source.rawStreamSource!, identity: ObjectIdentifier(source),
            tags: object(catalog, "StructTreeRoot") != nil, metadataOwner: metadata.document,
            metadataIdentity: ObjectIdentifier(metadata), rootLabel: metadata.baselineOutlineRootLabel, state: state)
    }

    /// Only the blank SDK carrier may synthesize a Link appearance. The
    /// current snapshot and its exact original annotation both prove absence;
    /// the final writer removes the carrier-only AP, never a real/current AP.
    static func preserveNativeStagingAppearanceAbsence(in plan: inout PDFCatalogGraphPlan,
            document: PDFDocument, proof: NativeStagingSource) throws -> Bool {
        guard try matches(proof, document: document) else { return false }
        var seen = Set<UInt>(), count = 0
        for pageIndex in 0..<document.pageCount {
            if pageIndex & 31 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: pageIndex) else { return false }
            for (index, annotation) in page.annotations.enumerated() {
                if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                count += 1
                guard count <= 100_000, annotation.type == "Link", annotation.popup == nil,
                      Bundle(for: type(of: annotation)) == Bundle(for: PDFAnnotation.self),
                      annotation.value(forAnnotationKey: .init(rawValue: "/AP")) == nil,
                      annotation.value(forAnnotationKey: .init(rawValue: "/AA")) == nil,
                      let pageOrigin = objc_getAssociatedObject(page, pageAssociation) as? Origin,
                      let origin = objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin,
                      origin.source === pageOrigin.source, origin.pageIndex == pageOrigin.index,
                      origin.source.knownNativeInput, origin.source.document === proof.owner,
                      origin.source.rawStreamSource === proof.rawSource,
                      proof.rawSource.provesExactFactoryOwner(proof.owner),
                      let native = originalAnnotation(origin),
                      object(native, "AP") == nil, object(native, "AA") == nil,
                      seen.insert(pdfReferenceIdentity(native)).inserted else { return false }
                guard nativeName(native, "Subtype") == "Link" else { return false }
                plan.annotationDrops[pageIndex, default: [:]][index, default: []].insert("AP")
            }
        }
        return try matches(proof, document: document)
    }

    static func matches(_ proof: NativeStagingSource, document: PDFDocument) throws -> Bool {
        guard let current = try nativeStagingSource(for: document) else { return false }
        guard current.sourceIdentity == proof.sourceIdentity, current.owner === proof.owner,
              current.rawSource === proof.rawSource, current.metadataIdentity == proof.metadataIdentity,
              current.metadataOwner === proof.metadataOwner, current.currentState == proof.currentState else { return false }
        return try PDFBodyTextPageSnapshot.metadataMatches(document, source: proof)
    }

    /// A bounded current-model witness supplements confined-snapshot ownership.
    /// It never decodes a font, image, page program or original Catalog tree.
    private static func nativeStagingCurrentState(_ document: PDFDocument) throws -> Data? {
        var digest = SHA256(), remaining = 16 * 1_024 * 1_024
        func emit(_ value: [String: Any]) -> Bool {
            guard let bytes = PDFWidgetAppearancePreserver.boundedDefaultFingerprint(value), bytes.count <= remaining else { return false }
            remaining -= bytes.count; digest.update(data: bytes); return true
        }
        func identity(_ object: AnyObject?) -> String { object.map { String(describing: ObjectIdentifier($0)) } ?? "nil" }
        func number(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
        func destination(_ destination: PDFDestination?) -> [String] {
            guard let destination else { return [] }
            return [identity(destination.page), number(Double(destination.point.x)),
                    number(Double(destination.point.y)), number(Double(destination.zoom))]
        }
        guard emit(["document": identity(document), "pages": document.pageCount]) else { return stagingRefused(#line) }
        for index in 0..<document.pageCount {
            if index & 31 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index) else { return stagingRefused(#line) }
            let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin
            let painting = origin?.contentUnchanged == true ? origin?.painting : page.pageRef
            let raw = PDFRawStreamProvenance.source(for: page)
            guard let painting, let dictionary = painting.dictionary,
                  emit(["page": identity(page), "origin": identity(origin), "painting": pdfReferenceIdentity(dictionary),
                        "raw": identity(raw), "unchanged": origin?.contentUnchanged ?? false,
                        "rotation": page.rotation, "boxes": try PDFPageGeometryPreserver.current(page).map { $0.map(number) },
                        "annotations": page.annotations.count]) else { return stagingRefused(#line) }
            for annotation in page.annotations {
                let geometry = try PDFPageGeometryPreserver.liveAnnotation(annotation)
                func numbers(_ value: PDFPageGeometryPreserver.Numbers) -> Any {
                    switch value { case .value(let value): return number(value); case .array(let values): return values.map(numbers) }
                }
                var controls: [String: Any] = ["annotation": identity(annotation),
                    "actionType": annotation.action?.type ?? "nil", "destination": destination(annotation.destination),
                    "goTo": destination((annotation.action as? PDFActionGoTo)?.destination),
                    "url": (annotation.action as? PDFActionURL)?.url?.absoluteString ?? "nil",
                    "contents": annotation.contents.map { $0 as Any } ?? NSNull(),
                    "display": annotation.shouldDisplay, "print": annotation.shouldPrint,
                    "rect": geometry.rectangle.map(number), "coordinates": geometry.coordinates.mapValues(numbers)]
                for key in ["/C", "/IC", "/CA", "/ca", "/BM", "/Rotate", "/Name", "/F", "/BS", "/BE", "/NM", "/H", "/Border"] {
                    let value = annotation.value(forAnnotationKey: .init(rawValue: key))
                    if let border = value as? PDFBorder {
                        let originalDash: [Any] = border.dashPattern ?? []
                        var dash: [String] = []
                        for item in originalDash {
                            guard let numeric = item as? NSNumber, numeric.doubleValue.isFinite else { return stagingRefused(#line) }
                            dash.append(number(numeric.doubleValue))
                        }
                        controls[key] = ["publicClass": NSStringFromClass(type(of: border)), "width": number(Double(border.lineWidth)),
                            "style": border.style.rawValue, "hasDash": border.dashPattern != nil, "dash": dash]
                    } else if let color = value as? NSColor {
                        guard let rgb = color.usingColorSpace(.extendedSRGB) else { return stagingRefused(#line) }
                        controls[key] = ["publicClass": NSStringFromClass(type(of: color)),
                            "rgba": [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map { number(Double($0)) }]
                    } else { controls[key] = value ?? NSNull() }
                }
                // This document is an exclusively owned recovery snapshot.
                // Bind scalar custom/metadata keys too; SDK-owned page/action/
                // geometry wrappers above are normalized by current semantics.
                // An unknown object graph cannot be guessed into authority.
                let keyValues = annotation.annotationKeyValues
                guard keyValues.count <= 4_096 else { return stagingRefused(#line) }
                let normalizedKeys: Set<String> = ["/P", "/A", "/Dest", "/Rect", "/QuadPoints", "/InkList", "/L", "/Vertices", "/CL", "/RD",
                    "/C", "/IC", "/CA", "/ca", "/BM", "/Rotate", "/Name", "/F", "/BS", "/BE", "/NM", "/H", "/Border"]
                var extra: [String: Any] = [:], allKeys = Set<String>()
                for (rawKey, value) in keyValues {
                    let name: String
                    if let key = rawKey.base as? PDFAnnotationKey { name = key.rawValue }
                    else if let key = rawKey.base as? String { name = key }
                    else { return stagingRefused(#line) }
                    guard name.utf8.count <= 1_024 else { return stagingRefused(#line) }
                    let key = name.hasPrefix("/") ? name : "/" + name
                    guard allKeys.insert(key).inserted else { return stagingRefused(#line) }
                    if key == "/M" {
                        // The SDK persists a PDF modification date at whole-
                        // second precision. Invalid strings/fractional dates
                        // cannot receive an exact current-state proof here.
                        // Check the raw public type before asking the typed
                        // getter: PDFKit assumes NSDate and an invalid string
                        // can raise an Objective-C selector exception.
                        guard let current = value as? Date,
                              let date = annotation.modificationDate, current == date else { return stagingRefused(#line) }
                        let seconds = date.timeIntervalSince1970
                        guard seconds.isFinite, seconds.rounded(.towardZero) == seconds else { return stagingRefused(#line) }
                        extra[key] = ["publicType": NSStringFromClass(type(of: current as NSDate)), "seconds": number(seconds)]
                    } else if !normalizedKeys.contains(key) { extra[key] = value }
                }
                controls["currentKeys"] = allKeys.sorted()
                controls["currentExtraScalars"] = extra
                guard emit(controls) else {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_TRACE"] == "1" {
                        let types = controls.mapValues { String(describing: type(of: $0)) }
                        if let bytes = try? JSONSerialization.data(withJSONObject: types, options: [.sortedKeys]) {
                            FileHandle.standardError.write(bytes); FileHandle.standardError.write(Data([10]))
                        }
                    }
                    #endif
                    return stagingRefused(#line)
                }
            }
        }
        var pending: [(PDFOutline, Int)] = document.outlineRoot.map { [($0, 0)] } ?? [], visited = Set<ObjectIdentifier>()
        guard emit(["hasOutline": document.outlineRoot != nil]) else { return stagingRefused(#line) }
        while let (outline, depth) = pending.popLast() {
            if visited.count & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard depth < 64, visited.insert(ObjectIdentifier(outline)).inserted, visited.count <= 100_000,
                  outline.numberOfChildren <= 100_000,
                  emit(["outline": identity(outline), "depth": depth, "children": outline.numberOfChildren,
                        "label": outline.label.map { $0 as Any } ?? NSNull(), "open": outline.isOpen,
                        "actionType": outline.action?.type ?? "nil",
                        "destination": destination(outline.destination), "goTo": destination((outline.action as? PDFActionGoTo)?.destination),
                        "url": (outline.action as? PDFActionURL)?.url?.absoluteString ?? "nil"]) else { return stagingRefused(#line) }
            for index in (0..<outline.numberOfChildren).reversed() {
                guard let child = outline.child(at: index) else { return stagingRefused(#line) }; pending.append((child, depth + 1))
            }
        }
        return Data(digest.finalize())
    }

    static func plan(for document: PDFDocument, tagReadAuxiliary: PDFTagReadAuxiliary? = nil) throws -> PDFCatalogGraphPlan {
        try PDFSaveCancellation.checkCurrent()
        try validateOutlineStyleReconstruction(in: document)
        var sources: [Source] = [], pages: [[PDFCatalogPageOrigin]] = [], groupPaintings: [[Int: CGPDFPage]] = []
        var positions: [ObjectIdentifier: Int] = [:]
        for index in 0..<document.pageCount {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard let page = document.page(at: index) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            try PDFRemoteNavigationPreserver.validate(page)
            guard let origin = objc_getAssociatedObject(page, pageAssociation) as? Origin else { continue }
            let key = ObjectIdentifier(origin.source)
            let group: Int
            if let existing = positions[key] { group = existing }
            else { group = sources.count; positions[key] = group; sources.append(origin.source); pages.append([]); groupPaintings.append([:]) }
            groupPaintings[group][origin.index] = origin.painting
            pages[group].append(PDFCatalogPageOrigin(sourceIndex: origin.index, outputIndex: index, livePage: page,
                                                     contentUnchanged: origin.contentUnchanged,
                                                     annotationIndexes: try annotationIndexes(on: page, origin: origin)))
        }
        let groups = sources.enumerated().map { PDFCatalogSourceGroup(document: $0.element.document,
            pages: pages[$0.offset], signedOriginalData: $0.element.signedData,
            paintingPages: groupPaintings[$0.offset], rawStreamSource: $0.element.rawStreamSource) }
        var plan = PDFCatalogGraphPlan()
        var originalLinkStates: [ObjectIdentifier: [Int: [Int: LinkControlState]]] = [:]
        var remainingLinkStateBytes = 8 * 1_024 * 1_024
        if !Thread.isMainThread, !linkIntent(for: document).isEdited {
            for (groupIndex, group) in groups.enumerated() {
                let source = sources[groupIndex]
                guard remainingLinkStateBytes > 0, !source.linkIntent.isEdited, let raw = source.rawStreamSource,
                      raw.provesExactFactoryOwner(source.document) else { continue }
                let requested = Set(group.pages.map(\.sourceIndex))
                if let states = try raw.originalLinkControlStates(onPages: requested, maximumStateBytes: remainingLinkStateBytes) {
                    let cost = states.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.bytes.count } }
                    guard cost <= remainingLinkStateBytes else { continue }
                    remainingLinkStateBytes -= cost
                    originalLinkStates[ObjectIdentifier(source)] = states
                }
            }
        }
        var appearanceSources: [ObjectIdentifier: Source] = [:]
        // The state has already been compared at each location. Retain only
        // immutable drawing references, not every page's cached baseline Data.
        var appearanceLocations: [(page: Int, index: Int, appearance: CGPDFObjectRef,
                                   annotation: CGPDFDictionaryRef, sourcePage: Int, sourceAnnotation: Int)] = []
        var outputWidgetCount = 0
        var remainingGeometryCoordinates = 2_000_000
        var originalInkBudget = PDFInkGeometryWorkBudget()
        var remainingAnnotationNameBytes = 8 * 1024 * 1024
        var remainingAnnotationNameCoordinates = 2_000_000
        plan.retainedDocuments = groups.map(\.document)
        plan.rawStreamSources = sources.compactMap(\.rawStreamSource)
        var rawSourceIDs = Set(plan.rawStreamSources.map(ObjectIdentifier.init))
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) {
                outputWidgetCount += page.annotations.filter { $0.type == "Widget" }.count
                if let raw = PDFRawStreamProvenance.source(for: page),
                   rawSourceIDs.insert(ObjectIdentifier(raw)).inserted { plan.rawStreamSources.append(raw) }
            }
        }
        plan.emptyFormSource = try emptyFormSource(for: document, widgetCount: outputWidgetCount)
        plan.emptyOutlineSource = try emptyOutlineSource(for: document)
        if let empty = plan.emptyOutlineSource, !plan.retainedDocuments.contains(where: { $0 === empty.owner }) {
            plan.retainedDocuments.append(empty.owner)
        }
        for group in groups {
            try PDFSaveCancellation.checkCurrent()
            for page in group.pages {
                guard let dictionary = group.document.page(at: page.sourceIndex + 1)?.dictionary else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                let key = pdfReferenceIdentity(dictionary)
                if plan.aliases[key] != nil { throw PDFPageStructurePreserver.Failure.conflictingFormFields }
                plan.aliases[key] = .page(page.outputIndex)
                if let origin = objc_getAssociatedObject(page.livePage, pageAssociation) as? Origin {
                    plan.pageGeometry[page.outputIndex] = origin.geometry
                }
                for (index, annotation) in page.livePage.annotations.enumerated() {
                    let original = objc_getAssociatedObject(annotation, annotationAssociation) as? AnnotationOrigin
                    if !Thread.isMainThread, let original,
                       let state = originalLinkStates[ObjectIdentifier(original.source)]?[original.pageIndex]?[original.annotationIndex] {
                        preserveOriginalLinkControls(annotation, origin: original, baseline: state,
                            page: page.livePage, outputIndex: page.outputIndex, annotationIndex: index, plan: &plan)
                    }
                    let baseline: PDFWidgetAppearancePreserver.State?
                    let defaultBaseline: PDFWidgetAppearancePreserver.DefaultState?
                    if annotation.type == "Widget", let original {
                        baseline = try widgetBaseline(original)
                        defaultBaseline = try widgetDefaultBaseline(annotation, origin: original)
                    } else { baseline = nil; defaultBaseline = nil }
                    try PDFWidgetAppearancePreserver.preserveCurrentDefault(annotation,
                        original: original.flatMap(originalAnnotation), page: page.outputIndex, index: index,
                        baseline: defaultBaseline, plan: &plan)
                    let capturedGeometry = try PDFPageGeometryPreserver.liveAnnotation(annotation)
                    let selection = PDFPageGeometryPreserver.annotationSelection(
                        capturedGeometry, original: original?.originalGeometry, baseline: original?.baselineGeometry)
                    let geometry: PDFPageGeometryPreserver.AnnotationGeometry
                    if annotation.type == "Ink", let original, original.source.knownNativeInput,
                       capturedGeometry == original.baselineGeometry,
                       original.baselineGeometry == original.originalGeometry,
                       let nativeAnnotation = originalAnnotation(original),
                       let exact = try original.source.rawStreamSource?.originalInkGeometry(
                           in: original.source.document, pageIndex: original.pageIndex,
                           annotationIndex: original.annotationIndex, annotation: nativeAnnotation,
                           budget: &originalInkBudget) {
                        // This whole original numeric view is justified by the
                        // exact input factory and untouched CG baseline, not
                        // epsilon, rounding, or a per-coordinate combination.
                        geometry = exact
                    } else { geometry = selection.chosen }
                    guard geometry.numberCount <= remainingGeometryCoordinates else { throw PDFPageStructurePreserver.Failure.tooComplex }
                    remainingGeometryCoordinates -= geometry.numberCount
                    plan.annotationGeometry[page.outputIndex, default: [:]][index] = geometry
                    let pageOrigin = objc_getAssociatedObject(page.livePage, pageAssociation) as? Origin
                    let currentNameOnKnownPage = annotation.type != "Ink" && original == nil
                        && pageOrigin?.source.knownNativeInput == true
                        && pageOrigin?.source.document === group.document && pageOrigin?.index == page.sourceIndex
                    let nativeNameOrigin = original.flatMap { origin -> CGPDFDictionaryRef? in
                        guard origin.source.knownNativeInput, origin.source.document === group.document else { return nil }
                        return originalAnnotation(origin)
                    }
                    if (nativeNameOrigin != nil || currentNameOnKnownPage),
                       let name = try PDFPageGeometryPreserver.annotationName(annotation, original: nativeNameOrigin,
                           currentGeometry: selection.current,
                           chosenGeometry: geometry, remainingBytes: &remainingAnnotationNameBytes,
                           remainingCurrentCoordinates: &remainingAnnotationNameCoordinates) {
                        plan.annotationNames[page.outputIndex, default: [:]][index] = name
                        if let value = name.value { plan.annotationEntries[page.outputIndex, default: [:]][index, default: [:]]["NM"] = value }
                        else { plan.annotationDrops[page.outputIndex, default: [:]][index, default: []].insert("NM") }
                    }
                    if page.contentUnchanged, let original, annotation.type == "Stamp" {
                        try preserveSignatureAppearance(annotation, origin: original, page: page.outputIndex, index: index, plan: &plan)
                    }
                    if page.contentUnchanged, let original, annotation.type == "Widget",
                       let appearance = widgetAppearance(annotation, origin: original, baseline: baseline), appearance.matches(annotation) {
                        appearanceSources[ObjectIdentifier(original.source)] = original.source
                        appearanceLocations.append((page.outputIndex, index, appearance.appearance, appearance.annotation,
                                                    original.pageIndex, original.annotationIndex))
                    }
                }
                if page.contentUnchanged {
                    plan.paintingSources[page.outputIndex] = group.paintingPages[page.sourceIndex] ?? group.document.page(at: page.sourceIndex + 1)
                } else {
                    plan.pageDrops[page.outputIndex, default: []].insert("StructParents")
                    for annotationIndex in page.livePage.annotations.indices {
                        plan.annotationDrops[page.outputIndex, default: [:]][annotationIndex, default: []].insert("StructParent")
                    }
                    try dropStaleResourceParents(on: page.livePage, to: &plan)
                }
                for key in ["AA", "AF", "PresSteps", "Tabs", "VP", "PieceInfo", "SeparationInfo"] {
                    if let value = object(dictionary, key) { plan.pageEntries[page.outputIndex, default: [:]][key] = .original(value) }
                }
                // All staged annotations first lose an old parent number;
                // the tag builder adds it back only for verified surviving OBJRs.
                for annotationIndex in page.livePage.annotations.indices {
                    plan.annotationDrops[page.outputIndex, default: [:]][annotationIndex, default: []].insert("StructParent")
                }
                if let annotations = array(dictionary, "Annots") {
                    for annotationIndex in 0..<CGPDFArrayGetCount(annotations) {
                        if annotationIndex & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                        guard let liveIndex = page.annotationIndexes?[annotationIndex] else { continue }
                        var annotation: CGPDFDictionaryRef?
                        guard CGPDFArrayGetDictionary(annotations, annotationIndex, &annotation), let annotation else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                        for key in ["OC", "AF", "FS", "Sound", "Movie", "RichMediaContent", "RichMediaSettings", "3DD", "3DV", "3DA", "AA"] {
                            if let value = object(annotation, key) {
                                plan.annotationEntries[page.outputIndex, default: [:]][liveIndex, default: [:]][key] = .original(value)
                            }
                        }
                        try PDFRemoteNavigationPreserver.addAction(for: page.livePage.annotations[liveIndex], page: page.outputIndex, index: liveIndex, to: &plan)
                    }
                }
            }
        }
        // Original default resource names are safe only when every output
        // widget proved unchanged and all belong to one independent form.
        // Mixed/new/edited forms keep staged defaults, never an arbitrary DR.
        if outputWidgetCount > 0, outputWidgetCount <= 10_000, outputWidgetCount == appearanceLocations.count,
           appearanceSources.count == 1, let source = appearanceSources.values.first,
           let defaults = try source.rawStreamSource?.originalWidgetFormDefaults() {
            plan.widgetAppearanceCount = appearanceLocations.count
            plan.widgetFormDefaults = defaults
            plan.widgetFormLocations = appearanceLocations.map { ($0.page, $0.index) }
            for location in appearanceLocations {
                // The whole-form/current-State proof above grants only this
                // unchanged original widget's AP. Pair its exact raw graph on
                // the worker before the generic CG encoder can decode Flate
                // streams or round stored resource numbers through CGFloat.
                // Legacy/unbound and main callers retain their existing path;
                // a proven factory AP that exceeds its bounded proof fails
                // closed rather than claiming exact preservation via fallback.
                if !Thread.isMainThread, let raw = source.rawStreamSource,
                   raw.provesExactFactoryOwner(source.document) {
                    guard try raw.exactAnnotationAppearance(in: source.document,
                        pageIndex: location.sourcePage, annotationIndex: location.sourceAnnotation,
                        annotation: location.annotation) != nil else {
                        throw PDFPageStructurePreserver.Failure.unsupportedStructure
                    }
                }
                plan.annotationEntries[location.page, default: [:]][location.index, default: [:]]["AP"] = .original(location.appearance)
                for key in ["DA", "Q", "AS", "MK", "V", "T"] {
                    // The unchanged independent-reader State proof above permits
                    // original direct scalar V, including absence and exact bytes.
                    // Complex values retain the staged authoritative form path.
                    // The independent State also proves the field name unchanged;
                    // whole-form defaults require unique bounded string /T values.
                    // Keep their original encoding alongside the original AP graph.
                    if key == "V", let value = object(location.annotation, key),
                       ![CGPDFObjectType.null, .name, .string].contains(CGPDFObjectGetType(value)) { continue }
                    plan.annotationDrops[location.page, default: [:]][location.index, default: []].insert(key)
                    if let value = object(location.annotation, key) {
                        plan.annotationEntries[location.page, default: [:]][location.index, default: [:]][key] = .original(value)
                    }
                }
            }
        }
        try PDFSaveCancellation.checkCurrent()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: groups, to: &plan)
        var replacedTagSource = false
        let tagLinkProofs = Dictionary(grouping: plan.linkControlProofs, by: \.outputPageIndex)
        let tagGroups = try groups.map { group -> PDFCatalogSourceGroup in
            var filtered = group
            let usesAuxiliary = group.rawStreamSource.map { tagReadAuxiliary?.matches(original: group.document, raw: $0) == true } ?? false
            filtered.pages = try group.pages.compactMap { page in
                // Existing unchanged-page policy needs no new permission. Only
                // a selected auxiliary may need the original/reader Link join.
                if page.contentUnchanged && !usesAuxiliary { return page }
                var admitted = page
                admitted.annotationTagPermission = annotationTagPermission(for: page,
                    document: group.document, proofs: tagLinkProofs[page.outputIndex] ?? [])
                if page.contentUnchanged { return admitted }
                let origin = objc_getAssociatedObject(page.livePage, pageAssociation) as? Origin
                if !Thread.isMainThread,
                   let origin,
                   let commit = origin.bodyCommit {
                    admitted.bodyTagPermission = try PDFBodyEditedTagPreserver.prove(commit, source: group.document,
                        sourceIndex: page.sourceIndex, painting: origin.painting, livePage: page.livePage)
                }
                if origin?.bodyCommit?.rewrite.kind == .glyph, admitted.bodyTagPermission == nil {
                    throw EditedPageTagSaveFailure(pageNumber: page.outputIndex + 1)
                }
                guard admitted.bodyTagPermission != nil || admitted.annotationTagPermission != nil else { return nil }
                // Only the separately proven, unchanged Link objects gain OBJR
                // aliases. The edited page remains ineligible for old painting.
                admitted.annotationIndexes = admitted.annotationTagPermission?.indexes ?? [:]
                return admitted
            }
            if let auxiliary = tagReadAuxiliary, let raw = group.rawStreamSource,
               auxiliary.matches(original: group.document, raw: raw) {
                guard !replacedTagSource else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                replacedTagSource = true
                // Retain the original tag reader if a new Link join cannot
                // be rebound. Auxiliary qualification is not permission to
                // discard an otherwise valid original annotation receipt.
                var rebound: [PDFCatalogPageOrigin] = [], canRebindLinks = true
                for var page in filtered.pages {
                    if let permission = page.bodyTagPermission {
                        page.bodyTagPermission = try permission.rebound(to: auxiliary)
                    }
                    if let permission = page.annotationTagPermission {
                        guard let translated = permission.rebound(to: auxiliary) else {
                            canRebindLinks = false; break
                        }
                        page.annotationTagPermission = translated
                    }
                    if !page.contentUnchanged {
                        let origin = objc_getAssociatedObject(page.livePage, pageAssociation) as? Origin
                        if origin?.bodyCommit?.rewrite.kind == .glyph, page.bodyTagPermission == nil {
                            canRebindLinks = false; break
                        }
                        guard page.bodyTagPermission != nil || page.annotationTagPermission != nil else { continue }
                        page.annotationIndexes = page.annotationTagPermission?.indexes ?? [:]
                    }
                    rebound.append(page)
                }
                if canRebindLinks {
                    filtered = PDFCatalogSourceGroup(document: auxiliary.document, pages: rebound,
                        rawStreamSource: auxiliary.rawSource)
                    for page in rebound {
                        guard let dictionary = auxiliary.document.page(at: page.sourceIndex + 1)?.dictionary else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                        plan.aliases[pdfReferenceIdentity(dictionary)] = .page(page.outputIndex)
                    }
                    plan.retainedDocuments.append(auxiliary.document)
                    plan.rawStreamSources.append(auxiliary.rawSource)
                    plan.retainedTagReadAuxiliaries.append(auxiliary)
                }
            }
            return filtered
        }
        guard tagReadAuxiliary == nil || replacedTagSource else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        for group in tagGroups {
            for page in group.pages {
                if let permission = page.bodyTagPermission { plan.bodyTagPermissions[page.outputIndex] = permission }
                if let permission = page.annotationTagPermission { plan.annotationTagPermissions[page.outputIndex] = permission }
            }
        }
        // An optional annotation-only subtree cannot reactivate semantic text
        // shared with removed old MCIDs. Reject only those page admissions and
        // rebuild once; no bytes from the rejected builder can escape.
        func addTags(_ input: [PDFCatalogSourceGroup], to output: inout PDFCatalogGraphPlan) throws {
            let baseline = output
            do { try PDFTaggedStructurePreserver.addPreservedTags(from: input, to: &output) }
            catch PDFTaggedStructurePreserver.Failure.annotationSemanticConflict(let pages) {
                output = baseline
                let filtered = input.map { group -> PDFCatalogSourceGroup in
                    var copy = group
                    copy.pages.removeAll { !$0.contentUnchanged && $0.bodyTagPermission == nil && pages.contains($0.outputIndex) }
                    return copy
                }
                for page in pages { output.annotationTagPermissions.removeValue(forKey: page) }
                try PDFTaggedStructurePreserver.addPreservedTags(from: filtered, to: &output)
            }
        }
        var baselineTagPlan = plan
        baselineTagPlan.bodyTagPermissions.removeAll()
        do {
            try addTags(tagGroups, to: &plan)
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard !plan.bodyTagPermissions.isEmpty else { throw error }
            if let index = plan.bodyTagPermissions.filter({ $0.value.requiresPreservation }).keys.min() {
                throw EditedPageTagSaveFailure(pageNumber: index + 1)
            }
            // Page-MCID authority remains optional and all-or-nothing. Its
            // fallback retains independently valid annotation-only authority;
            // unrelated tag errors still fail rather than widening painting.
            plan = baselineTagPlan
            let baseline = tagGroups.map { group -> PDFCatalogSourceGroup in
                var copy = group
                copy.pages = group.pages.compactMap { page in
                    if page.contentUnchanged { return page }
                    guard page.annotationTagPermission?.matchesCurrent(page.livePage) == true else { return nil }
                    var annotationOnly = page; annotationOnly.bodyTagPermission = nil
                    annotationOnly.annotationIndexes = page.annotationTagPermission?.indexes ?? [:]
                    return annotationOnly
                }
                return copy
            }
            try addTags(baseline, to: &plan)
        }
        try PDFSaveCancellation.checkCurrent()
        try PDFOptionalContentPreserver.addOptionalContent(from: groups, to: &plan)
        try PDFSaveCancellation.checkCurrent()
        try addCatalogs(from: groups, pageCount: document.pageCount, to: &plan)
        try PDFSaveCancellation.checkCurrent()
        try addOutlineDestinations(from: document, to: &plan)
        try addAnnotationDestinations(from: document, to: &plan)
        try PDFAnnotationRelationshipPreserver.addCurrentRelationships(in: document, to: &plan)
        try PDFRemoteNavigationPreserver.addActions(in: document, to: &plan)
        // Ordinary preservation saves keep every original resource name.
        // Only an explicit assembly output may optimize a complete, unchanged
        // final painting set with no live annotation consumers. The pruner
        // still proves image-only namespaces and unions every shared use.
        if permitsAssemblyImagePruning(document), plan.paintingSources.count == document.pageCount {
            var paintings: [CGPDFPage] = []
            paintings.reserveCapacity(document.pageCount)
            for index in 0..<document.pageCount {
                if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                guard let live = document.page(at: index), live.annotations.isEmpty,
                      let painting = plan.paintingSources[index] else { break }
                paintings.append(painting)
            }
            if paintings.count == document.pageCount {
                // A limit/cancellation/error cannot partially change the plan.
                var optimized = plan
                do {
                    try PDFCatalogImageResourcePruner.addPrunedImageResources(pages: paintings, to: &optimized)
                    try PDFSaveCancellation.checkCurrent()
                    plan = optimized
                } catch is CancellationError { throw CancellationError() }
                  catch PDFCatalogImageResourcePruner.Failure.tooComplex { /* Keep all original resources. */ }
            }
        }
        try PDFSaveCancellation.checkCurrent()
        return plan
    }

    private static func addAnnotationDestinations(from document: PDFDocument, to plan: inout PDFCatalogGraphPlan) throws {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            for (index, annotation) in page.annotations.enumerated() {
                if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                guard let original = objc_getAssociatedObject(annotation, annotationDestinationAssociation) as? OutlineDestination,
                      let current = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination,
                      original.destination === current, original.point == current.point, original.zoom == current.zoom,
                      let target = current.page else { continue }
                let targetIndex = document.index(for: target)
                guard targetIndex != NSNotFound else { throw PDFPageStructurePreserver.Failure.invalidDestination }
                let value = PDFCatalogGraphValue.array([.page(targetIndex)] + original.operands)
                if annotation.action is PDFActionGoTo {
                    plan.annotationEntries[pageIndex, default: [:]][index, default: [:]]["A"] = .dictionary(["S": .name("GoTo"), "D": value])
                    plan.annotationDrops[pageIndex, default: [:]][index, default: []].insert("Dest")
                } else {
                    plan.annotationEntries[pageIndex, default: [:]][index, default: [:]]["Dest"] = value
                    plan.annotationDrops[pageIndex, default: [:]][index, default: []].insert("A")
                }
                plan.retainedDocuments.append(original.document)
            }
        }
    }

    private static func addOutlineDestinations(from document: PDFDocument, to plan: inout PDFCatalogGraphPlan) throws {
        guard let root = document.outlineRoot else { return }
        let native = document.documentRef, rawSource = PDFRawStreamProvenance.source(for: document)
        let nativeRoot = rawSource == nil ? nil : native?.catalog.flatMap { dictionary($0, "Outlines") }
        var pending: [(PDFOutline, [Int], CGPDFDictionaryRef?)] = [(root, [], nativeRoot)], visits = 0
        var nativeSeen = Set<UInt>()
        while let (outline, path, nativeNode) = pending.popLast() {
            visits += 1
            if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard visits <= 100_000, path.count < 64 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            if !path.isEmpty, !hasPendingInertOutlineRecord(outline), isInactiveOutlineParent(outline),
               outline.numberOfChildren > 0, let native, let nativeNode, let rawSource,
               let candidate = try rawSource.pendingOriginalInertOutlineParent(in: native, node: nativeNode, path: path) {
                rememberPendingInertOutline(outline, candidate: candidate)
            }
            if !path.isEmpty,
               let style = objc_getAssociatedObject(outline, outlineStyleAssociation) as? OutlineStyle,
               style.outline === outline {
                plan.outlineStyleEntries[path] = style.values
                plan.retainedDocuments.append(style.document)
            }
            if !path.isEmpty, let candidate = pendingInertOutlineCandidate(outline) {
                guard plan.pendingInertOutlineDestinations.count < 4_096 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                plan.pendingInertOutlineDestinations[path] = candidate
                plan.retainedDocuments.append(candidate.retainedDocument)
            }
            if !path.isEmpty, let original = objc_getAssociatedObject(outline, outlineAssociation) as? OutlineDestination,
               original.restoresSerializedView,
               let current = (outline.action as? PDFActionGoTo)?.destination ?? outline.destination,
               original.destination === current,
               current.point == original.point, current.zoom == original.zoom,
               let page = current.page {
                let index = document.index(for: page)
                guard index != NSNotFound else { throw PDFPageStructurePreserver.Failure.invalidDestination }
                plan.outlineDestinations[path] = .array([.page(index)] + original.operands)
                plan.retainedDocuments.append(original.document)
            }
            guard outline.numberOfChildren <= 100_000 - pending.count else { throw PDFPageStructurePreserver.Failure.tooComplex }
            var nativeChild = nativeNode.flatMap { dictionary($0, "First") }
            for index in 0..<outline.numberOfChildren {
                let matching: CGPDFDictionaryRef?
                if let child = outline.child(at: index), let node = nativeChild {
                    var title: CGPDFStringRef?
                    matching = nativeSeen.insert(pdfReferenceIdentity(node)).inserted
                        && CGPDFDictionaryGetString(node, "Title", &title)
                        && title.map({ CGPDFStringGetLength($0) <= 65_536 }) == true
                        && title.flatMap(CGPDFStringCopyTextString).map({ $0 as String }) == child.label ? node : nil
                } else { matching = nil }
                if let child = outline.child(at: index) { pending.append((child, path + [index], matching)) }
                nativeChild = nativeChild.flatMap { dictionary($0, "Next") }
            }
        }
    }

    private static func signedOriginalBytes(_ document: PDFDocument, native: CGPDFDocument) throws -> Data? {
        guard hasActualSignature(native) else { return nil }
        guard let url = document.documentURL else { throw PDFPageStructurePreserver.Failure.unsupportedStructure }
        let version = try PDFSourceFileVersion.capture(at: url)
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 256 * 1_024 * 1_024, try PDFSourceFileVersion.capture(at: url) == version,
              let provider = CGDataProvider(data: bytes as CFData), let original = CGPDFDocument(provider),
              original.numberOfPages == native.numberOfPages else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        return bytes
    }

    /// Edited pages use an independent painting graph. Strip orphaned parent
    /// numbers inside that graph rather than claiming its new text still has
    /// the source document's MCIDs. Unchanged pages keep their tag mappings.
    private static func dropStaleResourceParents(on page: PDFPage, to plan: inout PDFCatalogGraphPlan) throws {
        guard let pageDictionary = page.pageRef?.dictionary, let resources = dictionary(pageDictionary, "Resources") else { return }
        var pending: [CGPDFDictionaryRef] = [resources], arrays: [CGPDFArrayRef] = []
        var seen = Set<UInt>(), visits = 0
        func enqueue(_ value: CGPDFObjectRef) throws {
            visits += 1
            if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard visits <= 250_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            var dictionary: CGPDFDictionaryRef?, stream: CGPDFStreamRef?, array: CGPDFArrayRef?
            switch CGPDFObjectGetType(value) {
            case .dictionary:
                if CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary { pending.append(dictionary) }
            case .stream:
                if CGPDFObjectGetValue(value, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) { pending.append(dictionary) }
            case .array:
                if CGPDFObjectGetValue(value, .array, &array), let array { arrays.append(array) }
            default: break
            }
        }
        while !pending.isEmpty || !arrays.isEmpty {
            if let array = arrays.popLast() {
                guard seen.insert(pdfReferenceIdentity(array)).inserted else { continue }
                for index in 0..<CGPDFArrayGetCount(array) {
                    var value: CGPDFObjectRef?
                    if CGPDFArrayGetObject(array, index, &value), let value { try enqueue(value) }
                }
                continue
            }
            guard let node = pending.popLast(), seen.insert(pdfReferenceIdentity(node)).inserted else { continue }
            plan.dictionaryDrops[pdfReferenceIdentity(node), default: []].formUnion(["StructParent", "StructParents"])
            var failure: Error?
            CGPDFDictionaryApplyBlock(node, { key, value, _ in
                if ["Parent", "P", "Pg"].contains(String(cString: key)) { return true }
                do { try enqueue(value); return true }
                catch { failure = error; return false }
            }, nil)
            if let failure { throw failure }
        }
    }

    private static func hasActualSignature(_ native: CGPDFDocument) -> Bool {
        guard let catalog = native.catalog else { return false }
        if let permissions = dictionary(catalog, "Perms"), object(permissions, "DocMDP") != nil { return true }
        guard let form = dictionary(catalog, "AcroForm"), let fields = array(form, "Fields") else { return false }
        var visits = 0, seen: Set<UInt> = []
        func visit(_ fields: CGPDFArrayRef, depth: Int) -> Bool {
            guard depth < 64 else { return false }
            for index in 0..<CGPDFArrayGetCount(fields) {
                visits += 1
                guard visits <= 100_000 else { return false }
                var field: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(fields, index, &field), let field,
                      seen.insert(pdfReferenceIdentity(field)).inserted else { continue }
                if let value = dictionary(field, "V"), object(value, "ByteRange") != nil { return true }
                if let kids = array(field, "Kids"), visit(kids, depth: depth + 1) { return true }
            }
            return false
        }
        return visit(fields, depth: 0)
    }

    private static func addCatalogs(from groups: [PDFCatalogSourceGroup], pageCount: Int, to plan: inout PDFCatalogGraphPlan) throws {
        var associated: [PDFCatalogGraphValue] = [], embedded: [PDFCatalogGraphValue] = []
        var names: [String: [PDFCatalogGraphValue]] = [:]
        var embeddedNameText: [Data: String] = [:]
        var totalNameKeyBytes = 0
        func appendNames(_ entries: [PDFCatalogGraphValue], kind: String) throws {
            let existing = names[kind]?.count ?? 0
            guard entries.count % 2 == 0, entries.count <= 250_000,
                  existing <= 250_000 - entries.count,
                  names[kind] != nil || names.count < 4_096 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            var bytes = 0
            for index in stride(from: 0, to: entries.count, by: 2) {
                guard case .string(let key) = entries[index], key.count <= 1_024 * 1_024,
                      bytes <= 64 * 1_024 * 1_024 - key.count else { throw PDFPageStructurePreserver.Failure.tooComplex }
                bytes += key.count
            }
            guard totalNameKeyBytes <= 64 * 1_024 * 1_024 - bytes else { throw PDFPageStructurePreserver.Failure.tooComplex }
            totalNameKeyBytes += bytes
            names[kind, default: []].append(contentsOf: entries)
        }
        if case .dictionary(let existing)? = plan.catalogEntries["Names"] {
            for (key, value) in existing {
                if case .dictionary(let tree) = value, case .array(let list)? = tree["Names"] {
                    try appendNames(list, kind: key)
                }
            }
        }
        for (groupIndex, group) in groups.enumerated() {
            guard let catalog = group.document.catalog else { continue }
            for key in ["MarkInfo", "Lang", "Metadata", "ViewerPreferences", "PageMode", "PageLayout", "AA", "Collection", "Requirements"] {
                if plan.catalogEntries[key] == nil, let value = object(catalog, key) { plan.catalogEntries[key] = .original(value) }
            }
            var archived: CGPDFBoolean = 0
            if CGPDFDictionaryGetBoolean(catalog, "EmberPDFContainsSignedOriginal", &archived), archived != 0 {
                plan.catalogEntries["EmberPDFContainsSignedOriginal"] = .boolean(true)
            }
            if let list = array(catalog, "AF") { associated += try values(list) }
            if let tree = dictionary(catalog, "Names") {
                guard CGPDFDictionaryGetCount(tree) <= 4_096 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                var children: [(String, CGPDFObjectRef)] = []
                var invalidKey = false
                CGPDFDictionaryApplyBlock(tree, { key, value, _ in
                    guard strnlen(key, 4_096) < 4_096 else { invalidKey = true; return false }
                    children.append((String(cString: key), value)); return true
                }, nil)
                if invalidKey { throw PDFPageStructurePreserver.Failure.tooComplex }
                for (key, value) in children where key != "Dests" {
                    var node: CGPDFDictionaryRef?
                    guard CGPDFObjectGetValue(value, .dictionary, &node), let node else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                    var decoded: [Data: String] = [:]
                    let values = try nameTree(node, prefix: groupIndex == 0 ? "" : "Source\(groupIndex + 1)-", decodedKeys: &decoded)
                    if key == "EmbeddedFiles" { embeddedNameText.merge(decoded) { _, new in new } }
                    try appendNames(values, kind: key)
                }
            }
            if let bytes = group.signedOriginalData {
                plan.catalogDrops.insert("Perms")
                let file = PDFCatalogGraphNode(entries: ["Type": .name("EmbeddedFile"), "Subtype": .name("application/pdf"),
                    "Params": .dictionary(["Size": .integer(bytes.count)])], streamData: bytes)
                let name = "Signed-original-\(groupIndex + 1).pdf"
                let specification = PDFCatalogGraphNode(entries: ["Type": .name("Filespec"), "F": .string(Data(name.utf8)),
                    "UF": .string(Data(name.utf8)), "AFRelationship": .name("Source"),
                    "Desc": .string(Data("Original signed PDF; the assembled document is unsigned.".utf8)),
                    "EF": .dictionary(["F": .node(file), "UF": .node(file)])])
                embedded += [.string(Data(name.utf8)), .node(specification)]
                embeddedNameText[Data(name.utf8)] = name
                associated.append(.node(specification))
                plan.catalogEntries["EmberPDFContainsSignedOriginal"] = .boolean(true)
            }
        }
        try addOutputIntentScopes(from: groups, pageCount: pageCount, to: &plan)
        if !associated.isEmpty { plan.catalogEntries["AF"] = .array(associated) }
        try appendNames(embedded, kind: "EmbeddedFiles")
        if let files = names["EmbeddedFiles"], allowsEmbeddedNameCanonicalization(groups) {
            names["EmbeddedFiles"] = canonicalEmbeddedNames(files, decoded: embeddedNameText)
        }
        if !names.values.allSatisfy(\.isEmpty) {
            let sorted = names.filter { !$0.value.isEmpty }.mapValues { entries -> PDFCatalogGraphValue in
                let pairs = stride(from: 0, to: entries.count, by: 2).map { (entries[$0], entries[$0 + 1]) }.sorted { first, second in
                    guard case .string(let a) = first.0, case .string(let b) = second.0 else { return false }
                    return a.lexicographicallyPrecedes(b)
                }
                return .dictionary(["Names": .array(pairs.flatMap { [$0.0, $0.1] })])
            }
            plan.catalogEntries["Names"] = .dictionary(sorted)
        }
    }

    /// A PDF 1.7 output intent describes the whole document, rather than a
    /// source page. Applying the first imported profile to unrelated pages can
    /// change their colours. Keep an active intent only when its immutable
    /// source object is proven common to every painted output page, with
    /// independently proven empty pages allowed as neutral. Otherwise retain
    /// each complete original intent graph as inactive, page-scoped provenance.
    /// This does not claim PDF/X or PDF/A conformance for a mixed assembly.
    private static func addOutputIntentScopes(from groups: [PDFCatalogSourceGroup], pageCount: Int,
                                             to plan: inout PDFCatalogGraphPlan) throws {
        let archiveKey = "EmberPDFSourceOutputIntents"
        var active: CGPDFObjectRef?, condition: UInt?, conflictingConditions = false, covered = Set<Int>()
        var activeHasEntries = false
        var missingIntentGroups: [PDFCatalogSourceGroup] = []
        for group in groups {
            guard let catalog = group.document.catalog else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            if let value = object(catalog, "OutputIntents") {
                guard CGPDFObjectGetType(value) == .array,
                      let intents = array(catalog, "OutputIntents") else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                let identity = pdfReferenceIdentity(value)
                if let condition { conflictingConditions = conflictingConditions || condition != identity }
                else {
                    condition = identity; active = value
                    activeHasEntries = CGPDFArrayGetCount(intents) > 0
                }
            } else { missingIntentGroups.append(group) }
            for page in group.pages {
                guard page.outputIndex >= 0, page.outputIndex < pageCount,
                      covered.insert(page.outputIndex).inserted else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            }
        }
        // No-intent files, conflicting profiles and unmatched live pages
        // never trigger a raw parser initialization or blank-content scan.
        var hasCommonCondition = active != nil && !conflictingConditions && covered.count == pageCount
        if hasCommonCondition, !missingIntentGroups.isEmpty {
            hasCommonCondition = activeHasEntries
            var remainingBlankBytes = 4_096
            missingSources: for group in missingIntentGroups where hasCommonCondition {
                guard let raw = group.rawStreamSource else { hasCommonCondition = false; break }
                for page in group.pages {
                    try PDFSaveCancellation.checkCurrent()
                    guard page.contentUnchanged, page.livePage.annotations.isEmpty,
                          let reference = group.document.page(at: page.sourceIndex + 1),
                          try raw.provesEmptyPageContents(for: reference, remainingEncodedBytes: &remainingBlankBytes) else {
                        hasCommonCondition = false; break missingSources
                    }
                }
            }
        }
        if hasCommonCondition, let active {
            plan.catalogEntries["OutputIntents"] = .original(active)
        } else {
            plan.catalogDrops.insert("OutputIntents")
        }

        var records: [PDFCatalogGraphValue] = [], references = 0
        var inspectedRecords = 0, inspectedReferences = 0, inspectedNativePages = 0
        func append(_ intents: CGPDFObjectRef, pages: [Int]) throws {
            guard !pages.isEmpty else { return }
            guard CGPDFObjectGetType(intents) == .array else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            guard records.count < 100_000, pages.count <= 250_000 - references else {
                throw PDFPageStructurePreserver.Failure.tooComplex
            }
            references += pages.count
            records.append(.dictionary(["OutputIntents": .original(intents), "Pages": .array(pages.sorted().map { .page($0) })]))
        }
        for group in groups {
            guard let catalog = group.document.catalog else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            if !hasCommonCondition, let intents = object(catalog, "OutputIntents") {
                try append(intents, pages: group.pages.map(\.outputIndex))
            }
            guard object(catalog, archiveKey) != nil else { continue }
            guard let archived = array(catalog, archiveKey), CGPDFArrayGetCount(archived) <= 100_000 - inspectedRecords,
                  group.document.numberOfPages <= 250_000 - inspectedNativePages else { throw PDFPageStructurePreserver.Failure.tooComplex }
            inspectedRecords += CGPDFArrayGetCount(archived)
            inspectedNativePages += group.document.numberOfPages
            var selected: [UInt: [Int]] = [:], nativePages = Set<UInt>()
            for index in 0..<group.document.numberOfPages {
                guard let page = group.document.page(at: index + 1)?.dictionary else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                nativePages.insert(pdfReferenceIdentity(page))
            }
            for page in group.pages {
                guard let native = group.document.page(at: page.sourceIndex + 1)?.dictionary else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                selected[pdfReferenceIdentity(native), default: []].append(page.outputIndex)
            }
            for index in 0..<CGPDFArrayGetCount(archived) {
                var record: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(archived, index, &record), let record,
                      let intents = object(record, "OutputIntents"), let scope = array(record, "Pages") else {
                    throw PDFPageStructurePreserver.Failure.invalidCopy
                }
                let count = CGPDFArrayGetCount(scope)
                guard count <= 250_000 - inspectedReferences else { throw PDFPageStructurePreserver.Failure.tooComplex }
                inspectedReferences += count
                var retained = Set<Int>()
                for pageIndex in 0..<count {
                    var page: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(scope, pageIndex, &page), let page,
                          nativePages.contains(pdfReferenceIdentity(page)) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                    if let outputIndexes = selected[pdfReferenceIdentity(page)] { retained.formUnion(outputIndexes) }
                }
                try append(intents, pages: Array(retained))
            }
        }
        if !records.isEmpty { plan.catalogEntries[archiveKey] = .array(records) }
        else { plan.catalogDrops.insert(archiveKey) }
    }

    /// Name-tree ordering is bytewise. Mixed PDFDocEncoding/UTF-16 keys can
    /// nevertheless confuse readers that compare decoded names. For embedded
    /// files only, a common text encoding makes both orders agree. Destination
    /// identifiers, binary keys and equal-text/different-byte keys stay intact.
    private static func canonicalEmbeddedNames(_ entries: [PDFCatalogGraphValue], decoded: [Data: String]) -> [PDFCatalogGraphValue] {
        var pairs: [(raw: Data, text: String, value: PDFCatalogGraphValue)] = []
        var texts = Set<Data>()
        for index in stride(from: 0, to: entries.count, by: 2) {
            guard case .string(let raw) = entries[index], let text = decoded[raw],
                  texts.insert(Data(text.utf8)).inserted else { return entries }
            pairs.append((raw, text, entries[index + 1]))
        }
        let rawOrder = pairs.sorted { $0.raw.lexicographicallyPrecedes($1.raw) }
        let textOrder = pairs.sorted { Data($0.text.utf8).lexicographicallyPrecedes(Data($1.text.utf8)) }
        guard rawOrder.map(\.raw) != textOrder.map(\.raw) else { return entries }
        var normalized: [(Data, PDFCatalogGraphValue, Data)] = []
        var bytes = 0
        for pair in pairs {
            guard let encoded = pair.text.data(using: .utf16BigEndian) else { return entries }
            let key = Data([0xfe, 0xff]) + encoded
            guard key.count <= 1_024 * 1_024, bytes <= 64 * 1_024 * 1_024 - key.count else { return entries }
            bytes += key.count
            normalized.append((key, pair.value, Data(pair.text.utf8)))
        }
        let sorted = normalized.sorted { $0.0.lexicographicallyPrecedes($1.0) }
        // UTF-16 code-unit order and Unicode scalar/UTF-8 order differ around
        // supplementary characters. Preserve the original tree in that case.
        guard sorted.map({ $0.2 }) == normalized.sorted(by: { $0.2.lexicographicallyPrecedes($1.2) }).map({ $0.2 }) else { return entries }
        return sorted.flatMap { [.string($0.0), $0.1] }
    }

    private static func allowsEmbeddedNameCanonicalization(_ groups: [PDFCatalogSourceGroup]) -> Bool {
        var pending: [(CGPDFObjectRef, Bool)] = [], seen = Set<UInt>()
        func enqueue(_ dictionary: CGPDFDictionaryRef, _ key: String, container: Bool = false) {
            if let value = object(dictionary, key) { pending.append((value, container)) }
        }
        for group in groups {
            guard let catalog = group.document.catalog else { return false }
            // Field ancestors and named JavaScript actions have additional action
            // containers. Keep their lookup identifiers byte-exact rather than
            // infer that no embedded-file name is referenced there.
            if object(catalog, "AcroForm") != nil {
                guard let form = dictionary(catalog, "AcroForm"),
                      let fields = array(form, "Fields"), CGPDFArrayGetCount(fields) == 0,
                      ["A", "AA", "XFA"].allSatisfy({ object(form, $0) == nil }),
                      hasNoCalculationOrderWork(form) else { return false }
            }
            if let names = dictionary(catalog, "Names"), object(names, "JavaScript") != nil { return false }
            if object(catalog, "Collection") != nil {
                guard let collection = dictionary(catalog, "Collection"), object(collection, "D") == nil else { return false }
            }
            enqueue(catalog, "Outlines"); enqueue(catalog, "OpenAction"); enqueue(catalog, "AA", container: true)
            for origin in group.pages {
                guard let page = group.document.page(at: origin.sourceIndex + 1)?.dictionary else { return false }
                enqueue(page, "AA", container: true)
                if let annotations = array(page, "Annots") {
                    guard CGPDFArrayGetCount(annotations) <= 100_000 else { return false }
                    for index in 0..<CGPDFArrayGetCount(annotations) {
                        var value: CGPDFObjectRef?
                        if CGPDFArrayGetObject(annotations, index, &value), let value { pending.append((value, false)) }
                    }
                }
            }
        }
        while let (value, container) = pending.popLast() {
            guard seen.count < 250_000, pending.count < 250_000 else { return false }
            if CGPDFObjectGetType(value) == .dictionary {
                var node: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &node), let node else { return false }
                guard seen.insert(pdfReferenceIdentity(node)).inserted else { continue }
                var action: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(node, "S", &action), let action, String(cString: action) == "GoToE" { return false }
                if container {
                    guard CGPDFDictionaryGetCount(node) <= 4_096 else { return false }
                    CGPDFDictionaryApplyBlock(node, { _, child, _ in pending.append((child, false)); return true }, nil)
                } else {
                    for key in ["A", "First", "Next"] { enqueue(node, key) }
                    enqueue(node, "AA", container: true)
                }
            } else if CGPDFObjectGetType(value) == .array {
                var values: CGPDFArrayRef?
                guard CGPDFObjectGetValue(value, .array, &values), let values,
                      CGPDFArrayGetCount(values) <= 250_000 - pending.count else { return false }
                guard seen.insert(pdfReferenceIdentity(values)).inserted else { continue }
                for index in 0..<CGPDFArrayGetCount(values) {
                    var child: CGPDFObjectRef?
                    if CGPDFArrayGetObject(values, index, &child), let child { pending.append((child, false)) }
                }
            }
        }
        return true
    }

    private static func values(_ array: CGPDFArrayRef) throws -> [PDFCatalogGraphValue] {
        guard CGPDFArrayGetCount(array) <= 100_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
        return try (0..<CGPDFArrayGetCount(array)).map { index in
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            var value: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, index, &value), let value else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            return .original(value)
        }
    }
    private static func nameTree(_ root: CGPDFDictionaryRef, prefix: String, decodedKeys: inout [Data: String]) throws -> [PDFCatalogGraphValue] {
        var result: [PDFCatalogGraphValue] = []
        var seen = Set<UInt>(), totalKeyBytes = 0
        func visit(_ node: CGPDFDictionaryRef, depth: Int) throws {
            try PDFSaveCancellation.checkCurrent()
            guard depth < 64, seen.count < 250_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            guard seen.insert(pdfReferenceIdentity(node)).inserted else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            if object(node, "Names") != nil {
                guard let entries = array(node, "Names"), CGPDFArrayGetCount(entries) % 2 == 0 else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                guard CGPDFArrayGetCount(entries) <= 250_000 - result.count else { throw PDFPageStructurePreserver.Failure.tooComplex }
                for index in stride(from: 0, to: CGPDFArrayGetCount(entries), by: 2) {
                    if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    var key: CGPDFStringRef?, value: CGPDFObjectRef?
                    guard CGPDFArrayGetString(entries, index, &key), let key,
                          CGPDFArrayGetObject(entries, index + 1, &value), let value else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                    let count = CGPDFStringGetLength(key)
                    guard count <= 1_024 * 1_024 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                    let name: Data
                    if prefix.isEmpty {
                        if count == 0 { name = Data() }
                        else {
                            guard let bytes = CGPDFStringGetBytePtr(key) else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                            name = Data(bytes: bytes, count: count)
                        }
                    } else {
                        let decoded = CGPDFStringCopyTextString(key) as String? ?? "Attachment"
                        name = Data([0xfe, 0xff]) + ((prefix + decoded).data(using: .utf16BigEndian) ?? Data())
                    }
                    guard name.count <= 1_024 * 1_024, totalKeyBytes <= 64 * 1_024 * 1_024 - name.count else { throw PDFPageStructurePreserver.Failure.tooComplex }
                    totalKeyBytes += name.count
                    if let text = CGPDFStringCopyTextString(key).map({ $0 as String }) { decodedKeys[name] = prefix + text }
                    result += [.string(name), .original(value)]
                }
            }
            if object(node, "Kids") != nil {
                guard let kids = array(node, "Kids") else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                guard CGPDFArrayGetCount(kids) <= 250_000 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                for index in 0..<CGPDFArrayGetCount(kids) {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(kids, index, &child), let child else { throw PDFPageStructurePreserver.Failure.invalidCopy }
                    try visit(child, depth: depth + 1)
                }
            }
        }
        try visit(root, depth: 0)
        return result
    }
}
