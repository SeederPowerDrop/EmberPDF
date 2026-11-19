// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Keeps the document-level information PDFKit exposes when importing detached
/// pages. Unsupported catalog structures are rejected before either document is
/// changed; this is deliberately not a general lossless PDF object rewriter.
enum PDFPageStructurePreserver {
    enum Failure: LocalizedError, Equatable {
        case unsupportedStructure, unsupportedPageLabels, invalidDestination, conflictingFormFields, tooComplex, invalidCopy

        var errorDescription: String? {
            switch self {
            case .unsupportedStructure:
                return L10n.string("page_structure.error.unsupported", defaultValue: "첨부·레이어·접근성 태그·전자서명 등 이 PDF의 특수 구조를 페이지 조립 후 안전하게 유지할 수 없습니다. 원본은 변경되지 않았습니다.")
            case .unsupportedPageLabels:
                return L10n.string("page_structure.error.page_labels", defaultValue: "이 PDF의 사용자 지정 페이지 번호는 현재 페이지 조립 후 저장할 때 유지할 수 없습니다. 원본은 변경되지 않았습니다.")
            case .invalidDestination:
                return L10n.string("page_structure.error.destination", defaultValue: "PDF 내부 이동의 대상 페이지를 안전하게 확인할 수 없어 페이지를 조립하지 않았습니다.")
            case .conflictingFormFields:
                return L10n.string("page_structure.error.form_fields", defaultValue: "같은 이름의 입력 양식이나 복잡한 양식 연결이 있어 값을 안전하게 유지할 수 없습니다. 양식 이름을 정리한 사본으로 다시 시도해 주세요.")
            case .tooComplex:
                return L10n.string("page_structure.error.too_complex", defaultValue: "PDF의 목차·링크·입력 양식 구조가 안전하게 조립할 수 있는 범위를 초과합니다.")
            case .invalidCopy:
                return L10n.string("page_structure.error.copy", defaultValue: "페이지의 주석과 내부 이동을 독립된 사본으로 만들지 못했습니다. 원본은 변경되지 않았습니다.")
            }
        }
    }

    /// No source document/page is retained after preparation. Links into pages
    /// outside an extraction are removed, and outlines are pruned to retained
    /// destinations (parents with retained children remain as section headings).
    struct Import {
        let pages: [PDFPage]
        let outline: PDFOutline?
        let attributes: [AnyHashable: Any]?
        fileprivate let fieldNames: Set<String>
        fileprivate let formFields: [FormFieldSnapshot]
        var containsFormFields: Bool { !fieldNames.isEmpty }

        /// PDFKit can register copied widgets under fresh names when their page
        /// joins a document. Restore captured values after the final insertion.
        func restoreFormFields() throws { try formFields.forEach { try $0.restore() } }
    }

    fileprivate struct FormFieldSnapshot {
        let page: PDFPage
        let annotationIndex: Int
        let name: String
        let type: PDFAnnotationWidgetSubtype
        let value: String?
        let defaultValue: String?
        let rawDefault: DefaultSnapshot
        let button: (type: PDFWidgetControlType, state: PDFWidgetCellState, stateString: String)?

        init(_ original: PDFAnnotation, page: PDFPage, annotationIndex: Int, remainingBytes: inout Int) throws {
            guard let name = original.fieldName else { throw Failure.invalidCopy }
            try Self.account(name, maximum: 4_096, remainingBytes: &remainingBytes)
            self.page = page
            self.annotationIndex = annotationIndex
            self.name = name
            type = original.widgetFieldType
            value = original.widgetStringValue
            try Self.account(value, remainingBytes: &remainingBytes)
            defaultValue = original.widgetDefaultStringValue
            try Self.account(defaultValue, remainingBytes: &remainingBytes)
            rawDefault = try DefaultSnapshot(original, remainingBytes: &remainingBytes)
            button = type == .button
                ? (original.widgetControlType, original.buttonWidgetState, original.buttonWidgetStateString)
                : nil
            try Self.account(button?.stateString, remainingBytes: &remainingBytes)
        }

        func restore() throws {
            let annotations = page.annotations
            guard annotations.indices.contains(annotationIndex), annotations[annotationIndex].type == "Widget" else {
                throw Failure.invalidCopy
            }
            let annotation = annotations[annotationIndex]
            if annotation.widgetFieldType != type { annotation.widgetFieldType = type }
            if annotation.fieldName != name { annotation.fieldName = name }
            let restoredValue = annotation.widgetStringValue != value
            if restoredValue { annotation.widgetStringValue = value }
            if let button {
                if annotation.widgetControlType != button.type { annotation.widgetControlType = button.type }
                if restoredValue || annotation.buttonWidgetStateString != button.stateString { annotation.buttonWidgetStateString = button.stateString }
                if restoredValue || annotation.buttonWidgetState != button.state { annotation.buttonWidgetState = button.state }
            }
            try rawDefault.restore(on: annotation)
            guard annotation.fieldName == name, annotation.widgetFieldType == type,
                  annotation.widgetStringValue == value,
                  rawDefault.matches(annotation),
                  rawDefault.isAbsent || annotation.widgetDefaultStringValue == defaultValue else {
                throw Failure.invalidCopy
            }
        }

        private static func account(_ value: String?, maximum: Int = 65_536, remainingBytes: inout Int) throws {
            guard let value else { return }
            let count = value.utf8.prefix(min(maximum, remainingBytes) + 1).count
            guard count <= maximum, count <= remainingBytes else { throw Failure.tooComplex }
            remainingBytes -= count
        }

        /// A missing /DV is not the default-string getter's fallback to /V.
        /// Unsupported defaults may survive unchanged, but no string setter
        /// is allowed to reinterpret a name/array/unknown original default.
        enum DefaultSnapshot {
            case absent, string(String)
            case simpleNative(publicValue: Data)
            case opaque(publicValue: Data, nativeValue: Data?)
            var isAbsent: Bool { if case .absent = self { return true }; return false }

            init(_ annotation: PDFAnnotation, remainingBytes: inout Int) throws {
                let raw = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))
                let native = try Self.nativeDefault(annotation)
                // A proven missing/null native DV can expose a scalar /V
                // fallback through PDFKit. Preserve that exact public state
                // across our independent NSCopying boundary without asking a
                // setter-invalidated copied page to recreate a native pageRef.
                // The worker's independent original-default proof still owns
                // the stored absent/null/current-edit decision when saving.
                if let native, native.kind == nil || native.kind == .null,
                   raw == nil || raw is NSNull || raw is String {
                    guard let fingerprint = PDFWidgetAppearancePreserver.boundedDefaultFingerprint(raw),
                          fingerprint.count <= remainingBytes else { throw Failure.tooComplex }
                    remainingBytes -= fingerprint.count
                    self = .simpleNative(publicValue: fingerprint); return
                }
                // A valid choice-array default can be invisible to the public
                // getter, while an absent native default can look like /V.
                // Consult proven native type before using that public value.
                if let native, native.kind == nil || native.kind == .null || native.kind == .string,
                   raw == nil || raw is NSNull { self = .absent; return }
                if let string = raw as? String, let native, native.kind == .string {
                    try FormFieldSnapshot.account(string, remainingBytes: &remainingBytes)
                    self = .string(string); return
                }
                guard let fingerprint = PDFWidgetAppearancePreserver.boundedDefaultFingerprint(raw),
                      fingerprint.count <= remainingBytes else { throw Failure.tooComplex }
                remainingBytes -= fingerprint.count
                if let native {
                    guard native.bytes.count <= remainingBytes else { throw Failure.tooComplex }
                    remainingBytes -= native.bytes.count
                }
                self = .opaque(publicValue: fingerprint, nativeValue: native?.bytes)
            }

            func matches(_ annotation: PDFAnnotation) -> Bool {
                let raw = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))
                switch self {
                case .absent: return raw == nil || raw is NSNull
                case .string(let value): return (raw as? String) == value
                case .simpleNative(let value):
                    return PDFWidgetAppearancePreserver.boundedDefaultFingerprint(raw) == value
                case .opaque(let value, let native):
                    guard PDFWidgetAppearancePreserver.boundedDefaultFingerprint(raw) == value else { return false }
                    if let native { return (try? Self.nativeDefault(annotation))?.bytes == native }
                    return true
                }
            }

            func restore(on annotation: PDFAnnotation) throws {
                if matches(annotation) { return }
                switch self {
                case .absent: annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))
                case .string(let value): annotation.widgetDefaultStringValue = value
                case .simpleNative, .opaque: throw Failure.invalidCopy
                }
                guard matches(annotation) else { throw Failure.invalidCopy }
            }

            /// This reads only the existing page reference. A changed/reordered
            /// annotation with no exact field identity receives no native proof.
            private static func nativeDefault(_ annotation: PDFAnnotation) throws -> (kind: CGPDFObjectType?, bytes: Data)? {
                guard let page = annotation.page, let index = page.annotations.firstIndex(where: { $0 === annotation }),
                      let dictionary = page.pageRef?.dictionary,
                      let annotations = PDFCatalogStructurePreserver.array(dictionary, "Annots"),
                      CGPDFArrayGetCount(annotations) == page.annotations.count else { return nil }
                var field: CGPDFDictionaryRef?, name: CGPDFStringRef?
                guard CGPDFArrayGetDictionary(annotations, index, &field), let field,
                      CGPDFDictionaryGetString(field, "T", &name), let name, CGPDFStringGetLength(name) <= 4_096,
                      (CGPDFStringCopyTextString(name) as String?) == annotation.fieldName else { return nil }
                guard let object = PDFCatalogStructurePreserver.object(field, "DV") else {
                    return (nil, Data("absent".utf8))
                }
                var remaining = 256 * 1_024, visits = 0
                func scalar(_ object: CGPDFObjectRef, depth: Int) throws -> Any {
                    visits += 1
                    if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    guard depth <= 12, visits <= 8_192, remaining >= 64 else { throw Failure.tooComplex }
                    remaining -= 64
                    let type = CGPDFObjectGetType(object)
                    var value: Any
                    switch type {
                    case .null: value = NSNull()
                    case .boolean:
                        var scalar: CGPDFBoolean = 0
                        guard CGPDFObjectGetValue(object, .boolean, &scalar) else { throw Failure.invalidCopy }
                        value = scalar != 0
                    case .integer:
                        var scalar: CGPDFInteger = 0
                        guard CGPDFObjectGetValue(object, .integer, &scalar) else { throw Failure.invalidCopy }
                        value = String(scalar)
                    case .name:
                        var scalar: UnsafePointer<CChar>?
                        guard CGPDFObjectGetValue(object, .name, &scalar), let scalar,
                              strnlen(scalar, 65_537) <= 65_536 else { throw Failure.tooComplex }
                        let count = strnlen(scalar, 65_537)
                        guard count <= remaining else { throw Failure.tooComplex }
                        remaining -= count
                        value = Data(bytes: scalar, count: count)
                    case .string:
                        var scalar: CGPDFStringRef?
                        guard CGPDFObjectGetValue(object, .string, &scalar), let scalar,
                              CGPDFStringGetLength(scalar) <= 65_536,
                              let string = CGPDFStringCopyTextString(scalar) as String? else { throw Failure.tooComplex }
                        try FormFieldSnapshot.account(string, remainingBytes: &remaining); value = string
                    case .array:
                        var array: CGPDFArrayRef?
                        guard CGPDFObjectGetValue(object, .array, &array), let array,
                              CGPDFArrayGetCount(array) <= 4_096 else { throw Failure.tooComplex }
                        var values: [Any] = []
                        for index in 0..<CGPDFArrayGetCount(array) {
                            var member: CGPDFObjectRef?
                            guard CGPDFArrayGetObject(array, index, &member), let member else { throw Failure.invalidCopy }
                            values.append(try scalar(member, depth: depth + 1))
                        }
                        value = values
                    default: throw Failure.unsupportedStructure
                    }
                    return ["kind": type.rawValue, "value": value]
                }
                let value = try scalar(object, depth: 0)
                guard let bytes = PDFWidgetAppearancePreserver.boundedDefaultFingerprint(value) else { throw Failure.tooComplex }
                return (CGPDFObjectGetType(object), bytes)
            }
        }
    }

    /// The workspace records this transaction in its existing delta undo stack.
    /// Existing destination pages/links and metadata keep their object identity.
    struct Merge {
        let pages: [PDFPage]
        let beforeOutline: PDFOutline?
        let afterOutline: PDFOutline?
        private let document: PDFDocument
        private let start: Int
        private let beforePages: [PDFPage]
        private let beforeAssemblyImagePruning: Bool
        private let containsFormFields: Bool
        private let formFields: [FormFieldSnapshot]

        fileprivate init(pages: [PDFPage], beforeOutline: PDFOutline?, afterOutline: PDFOutline?,
                         document: PDFDocument, start: Int, containsFormFields: Bool, formFields: [FormFieldSnapshot]) {
            self.pages = pages
            self.beforeOutline = beforeOutline
            self.afterOutline = afterOutline
            self.document = document
            self.start = start
            self.containsFormFields = containsFormFields
            self.formFields = formFields
            self.beforePages = (0..<document.pageCount).compactMap { document.page(at: $0) }
            self.beforeAssemblyImagePruning = PDFCatalogStructurePreserver.permitsAssemblyImagePruning(document)
        }

        func apply() throws { try redo() }
        func redo() throws {
            guard samePages(beforePages), pages.allSatisfy({ document.index(for: $0) == NSNotFound }) else {
                throw Failure.invalidCopy
            }
            for (offset, page) in pages.enumerated() { document.insert(page, at: start + offset) }
            do {
                try formFields.forEach { try $0.restore() }
            } catch {
                for index in (start..<(start + pages.count)).reversed() { document.removePage(at: index) }
                throw error
            }
            document.outlineRoot = afterOutline
            PDFCatalogStructurePreserver.refreshMarker(document)
            if containsFormFields { PDFCanonicalFormMaterializer.mark(document) }
            if !pages.isEmpty { PDFCatalogStructurePreserver.setAssemblyImagePruning(true, for: document) }
        }
        func undo() throws {
            var expected = beforePages
            expected.insert(contentsOf: pages, at: start)
            guard samePages(expected) else { throw Failure.invalidCopy }
            for index in (start..<(start + pages.count)).reversed() { document.removePage(at: index) }
            document.outlineRoot = beforeOutline
            PDFCatalogStructurePreserver.refreshMarker(document)
            PDFCatalogStructurePreserver.setAssemblyImagePruning(beforeAssemblyImagePruning, for: document)
        }
        private func samePages(_ expected: [PDFPage]) -> Bool {
            document.pageCount == expected.count && expected.enumerated().allSatisfy {
                document.page(at: $0.offset) === $0.element
            }
        }
    }

    static func prepareImport(from source: PDFDocument, indexes: [Int]) throws -> Import {
        try prepareImport(from: source, indexes: indexes, nativeStaging: false)
    }

    /// An SDK shell made only of blank pages and current detached annotations.
    /// The final native writer supplies painting; the SDK never draws the old
    /// document's accessibility tree or original page resource graph.
    static func nativeStagingCarrier(from source: PDFDocument,
                                     proof: PDFCatalogStructurePreserver.NativeStagingSource) throws -> PDFDocument {
        guard try PDFCatalogStructurePreserver.matches(proof, document: source) else { throw Failure.invalidCopy }
        let imported = try prepareImport(from: source, indexes: Array(0..<source.pageCount), nativeStaging: true)
        guard !imported.containsFormFields else { throw Failure.invalidCopy }
        let carrier = PDFDocument()
        for page in imported.pages { carrier.insert(page, at: carrier.pageCount) }
        carrier.documentAttributes = imported.attributes; carrier.outlineRoot = imported.outline
        try PDFSaveCancellation.checkCurrent()
        return carrier
    }

    /// A full recovery copy, not a page import: all pages stay ordered and
    /// RecoverySnapshot rebuilds the complete current outline afterwards.
    static func manualRecoverySnapshotCopy(from source: PDFDocument) throws -> PDFDocument {
        let imported = try prepareImport(from: source, indexes: Array(0..<source.pageCount),
                                         nativeStaging: false, manualRecovery: true)
        guard !imported.containsFormFields else { throw Failure.invalidCopy }
        let copy = PDFDocument()
        for page in imported.pages {
            try PDFSaveCancellation.checkCurrent()
            copy.insert(page, at: copy.pageCount)
        }
        copy.documentAttributes = imported.attributes
        try imported.restoreFormFields()
        guard copy.pageCount == source.pageCount else { throw Failure.invalidCopy }
        return copy
    }

    private static func prepareImport(from source: PDFDocument, indexes: [Int], nativeStaging: Bool,
                                      manualRecovery: Bool = false) throws -> Import {
        try PDFDocumentSecurityPolicy.validateCanExtractPages(source)
        try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: source)
        let indexes = try PDFPageOperations.normalizedSelection(indexes, pageCount: source.pageCount)
        try validateCatalog(source)
        try PDFCatalogStructurePreserver.prepare(source, force: true, pageIndexes: indexes)
        let fieldNames = try validateFields(in: source, indexes: indexes)
        let originals = try indexes.map { index -> PDFPage in
            guard let page = source.page(at: index) else { throw Failure.invalidCopy }
            return page
        }
        try PDFRemoteNavigationPreserver.validateForCopy(in: source, pages: originals)
        var remainingRelationshipAnnotations = 100_000
        let relationshipValidationWork = PDFAnnotationRelationshipBaseline.WorkBudget()
        for page in originals {
            try PDFAnnotationRelationshipPreserver.validate(page, remainingAnnotations: &remainingRelationshipAnnotations,
                workBudget: relationshipValidationWork)
        }
        let relationshipCopyCleanup = PDFAnnotationRelationshipPreserver.CopyBudget()
        var originalContentBytes = 0
        let pages = try originals.map { page -> PDFPage in
            if !nativeStaging, !manualRecovery,
               let compact = try PDFPageOperations.compactAssemblyCopy(of: page,
                    remainingBytes: 512 * 1_024 * 1_024 - originalContentBytes) {
                originalContentBytes += compact.bytes
                return compact.page
            }
            if try nativeStaging || manualRecovery || containsIndexedImage(on: page) {
                // PDFKit may turn an absent /Interpolate (default false) into
                // true for palette images. Keep the raw painting graph only
                // for affected pages; normal page copies stay inexpensive.
                let copy: PDFPage
                if nativeStaging { copy = try blankStagingPage(for: page) }
                else {
                    // A factory-bound, unchanged SDK copy can retain the exact
                    // native painting without expanding every Flate image on
                    // Main. The existing Origin/worker Catalog writer restores
                    // its original resources; unproved copies keep the strict
                    // established snapshot path below.
                    // SDK page copying can materialize an unproved Popup on
                    // an AP-bearing Text note before the optional gate rejects
                    // it. Use the encoded painting/manual annotation route for
                    // these pages without changing relationship/AP policies.
                    if !manualRecovery, !page.annotations.contains(where: { $0.type == "Text" }),
                       let copied = page.copy() as? PDFPage,
                       try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: copied, copyBudget: relationshipCopyCleanup) {
                        return copied
                    }
                    let data: Data
                    if manualRecovery {
                        // No canonical/CG decoded fallback on the full manual
                        // snapshot route: every stream must have raw ownership.
                        data = try PDFBodyTextPageSnapshot.encodedRecoveryAssemblyPageData(for: page)
                    } else {
                        data = try PDFBodyTextPageSnapshot.encodedAssemblyPageData(for: page)
                            ?? PDFBodyTextPageSnapshot.originalPageData(for: page)
                    }
                    guard data.count <= 512 * 1_024 * 1_024 - originalContentBytes else { throw Failure.tooComplex }
                    originalContentBytes += data.count
                    guard let snapshot = PDFDocument(data: data), snapshot.pageCount == 1,
                          let detached = snapshot.page(at: 0), detached !== page else { throw Failure.invalidCopy }
                    copy = detached
                }
                let annotations = page.annotations
                let annotationIdentities = Set(annotations.map(ObjectIdentifier.init))
                var nativeAnnotations: CGPDFArrayRef?
                if let dictionary = page.pageRef?.dictionary {
                    _ = CGPDFDictionaryGetArray(dictionary, "Annots", &nativeAnnotations)
                }
                for (annotationIndex, annotation) in annotations.enumerated() {
                    let originalContents = annotation.contents
                    var hadPopup = annotation.popup.map { annotationIdentities.contains(ObjectIdentifier($0)) } ?? false
                    var nativePopupAbsent: CGPDFDictionaryRef?
                    if let nativeAnnotations, CGPDFArrayGetCount(nativeAnnotations) == annotations.count {
                        var native: CGPDFDictionaryRef?
                        if CGPDFArrayGetDictionary(nativeAnnotations, annotationIndex, &native), let native {
                            if let popup = object(native, "Popup") {
                                if manualRecovery, CGPDFObjectGetType(popup) == .null { nativePopupAbsent = native }
                                else { hadPopup = true }
                            } else { nativePopupAbsent = native }
                        }
                    }
                    guard let detached = annotation.copy() as? PDFAnnotation, detached !== annotation else {
                        throw Failure.invalidCopy
                    }
                    copy.addAnnotation(detached)
                    if !hadPopup {
                        // Adding a copied Text note makes PDFKit synthesize a
                        // Popup that was absent from the source annotation.
                        // Keep the source annotation count/relationships.
                        let synthesizedPopup = detached.popup
                        detached.popup = nil
                        detached.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup"))
                        if let synthesizedPopup,
                           copy.annotations.contains(where: { $0 === synthesizedPopup }) {
                            copy.removeAnnotation(synthesizedPopup)
                        }
                        detached.contents = originalContents
                        if detached.type == "Text", let nativePopupAbsent {
                            try PDFAnnotationRelationshipPreserver.recordLegacyNoPopup(detached, on: copy,
                                nativeOriginal: nativePopupAbsent)
                        }
                    }
                }
                return copy
            }
            guard let copy = PDFPageOperations.detachedCopy(of: page), copy !== page else { throw Failure.invalidCopy }
            return copy
        }
        var remainingRelationshipMetadata = 8 * 1_024 * 1_024
        let relationshipCopyWork = PDFAnnotationRelationshipBaseline.WorkBudget()
        for (original, copy) in zip(originals, pages) {
            PDFCatalogStructurePreserver.inherit(from: original, to: copy)
            try PDFAnnotationRelationshipPreserver.inherit(from: original, to: copy,
                remainingMetadata: &remainingRelationshipMetadata, workBudget: relationshipCopyWork, copyBudget: relationshipCopyCleanup)
        }
        let mapping = Dictionary(uniqueKeysWithValues: zip(originals, pages).map { (ObjectIdentifier($0.0), $0.1) })
        let navigation = NativeNavigation(source: source)
        var formFields: [FormFieldSnapshot] = []
        var remainingFormScalarBytes = 8 * 1_024 * 1_024
        for (original, copy) in zip(originals, pages) {
            let originals = original.annotations, copies = copy.annotations
            guard originals.count == copies.count else { throw Failure.invalidCopy }
            for (annotationIndex, pair) in zip(originals, copies).enumerated() {
                let (annotation, copied) = pair
                guard annotation !== copied else { throw Failure.invalidCopy }
                if annotation.type == "Widget", ["Sig", "/Sig"].contains(annotation.widgetFieldType.rawValue) {
                    // A signature authenticates the original byte ranges. The
                    // signed input is embedded unchanged; retain only this
                    // widget's appearance, without an invalid signature claim.
                    let signatureState = PDFSignatureAppearancePreserver.State(annotation)
                    guard copied.setValue("Stamp", forAnnotationKey: PDFAnnotationKey(rawValue: "/Subtype")) else { throw Failure.invalidCopy }
                    for key in ["/FT", "/V", "/DV", "/T", "/TU", "/Ff", "/Parent", "/Kids", "/Lock", "/SV"] {
                        copied.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: key))
                    }
                    try PDFCatalogStructurePreserver.recordSignatureConversion(from: annotation, to: copied, sourceState: signatureState)
                    continue
                }
                if annotation.type == "Widget" {
                    guard formFields.count < 10_000 else { throw Failure.tooComplex }
                    if formFields.count & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    let field = try FormFieldSnapshot(annotation, page: copy, annotationIndex: annotationIndex,
                                                      remainingBytes: &remainingFormScalarBytes)
                    try field.restore()
                    formFields.append(field)
                }
                let action = annotation.action, destination = annotation.destination
                let hasLiveDestination = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")) != nil
                let native = navigation.annotation(on: original, index: annotationIndex)
                // A detached pageRef may still expose the donor's original
                // link after its live annotation was explicitly cleared by an
                // earlier extraction. Never resurrect that obsolete raw link.
                let rawDestination = hasLiveDestination || destination != nil || action is PDFActionGoTo
                    ? try navigation.destination(in: native) : nil
                if let action = action as? PDFActionGoTo {
                    try clearNavigation(copied)
                    copied.action = try navigation.mapped(action.destination, raw: rawDestination, pages: mapping)
                        .map(PDFActionGoTo.init(destination:))
                } else if let destination {
                    try clearNavigation(copied)
                    copied.destination = try navigation.mapped(destination, raw: rawDestination, pages: mapping)
                } else if let rawDestination {
                    try clearNavigation(copied)
                    copied.destination = try navigation.mapped(nil, raw: rawDestination, pages: mapping)
                } else if hasLiveDestination {
                    throw Failure.invalidDestination
                } else if let action {
                    guard let detached = action.copy() as? PDFAction else { throw Failure.invalidCopy }
                    copied.action = detached
                    PDFRemoteNavigationPreserver.inherit(from: annotation, to: copied)
                }
            }
        }
        var remaining = 100_000
        let outline: PDFOutline?
        if manualRecovery { outline = nil }
        else { outline = try copyOutline(source.outlineRoot, in: source, pages: mapping, navigation: navigation, native: navigation.outlines, depth: 0, remaining: &remaining, root: true) }
        return Import(pages: pages, outline: outline, attributes: source.documentAttributes,
                      fieldNames: fieldNames, formFields: formFields)
    }

    private static func blankStagingPage(for source: PDFPage) throws -> PDFPage {
        try PDFSaveCancellation.checkCurrent()
        var media = source.bounds(for: .mediaBox)
        guard media.origin.x.isFinite, media.origin.y.isFinite,
              media.width.isFinite, media.height.isFinite, media.width > 0, media.height > 0,
              abs(media.minX) <= 1_000_000, abs(media.minY) <= 1_000_000,
              media.width <= 1_000_000, media.height <= 1_000_000,
              source.rotation % 90 == 0 else { throw Failure.invalidCopy }
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw Failure.invalidCopy }
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        guard let document = PDFDocument(data: bytes as Data), document.pageCount == 1,
              let page = document.page(at: 0) else { throw Failure.invalidCopy }
        for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            page.setBounds(source.bounds(for: box), for: box)
        }
        page.rotation = source.rotation
        return page
    }

    /// Inspect resource dictionaries only. No image pixels/streams are decoded,
    /// and shared/cyclic Form resource graphs are visited at most once.
    private static func containsIndexedImage(on page: PDFPage) throws -> Bool {
        guard let pageDictionary = page.pageRef?.dictionary else { return false }
        var current: CGPDFDictionaryRef? = pageDictionary
        var ancestors: Set<UInt> = []
        var resources: CGPDFDictionaryRef?
        while let dictionary = current {
            guard ancestors.insert(pdfReferenceIdentity(dictionary)).inserted, ancestors.count < 64 else {
                throw Failure.tooComplex
            }
            if object(dictionary, "Resources") != nil {
                guard let found = Self.dictionary(dictionary, "Resources") else { throw Failure.invalidCopy }
                resources = found
                break
            }
            current = Self.dictionary(dictionary, "Parent")
        }
        guard let resources else { return false }
        var visited: Set<UInt> = [], visits = 0
        func indexed(_ colorSpace: CGPDFObjectRef, resources: CGPDFDictionaryRef, depth: Int) throws -> Bool {
            guard depth < 64 else { throw Failure.tooComplex }
            if CGPDFObjectGetType(colorSpace) == .array {
                var array: CGPDFArrayRef?, name: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(colorSpace, .array, &array), let array,
                      CGPDFArrayGetCount(array) > 0, CGPDFArrayGetName(array, 0, &name), let name else { return false }
                return ["Indexed", "I"].contains(String(cString: name))
            }
            if CGPDFObjectGetType(colorSpace) == .name {
                var name: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(colorSpace, .name, &name), let name else { throw Failure.invalidCopy }
                let key = String(cString: name)
                guard let spaces = Self.dictionary(resources, "ColorSpace"), let resolved = object(spaces, key) else { return false }
                return try indexed(resolved, resources: resources, depth: depth + 1)
            }
            return false
        }
        func visit(_ resources: CGPDFDictionaryRef, depth: Int) throws -> Bool {
            guard depth < 64 else { throw Failure.tooComplex }
            guard visited.insert(pdfReferenceIdentity(resources)).inserted else { return false }
            guard let xobjects = Self.dictionary(resources, "XObject") else { return false }
            let count = CGPDFDictionaryGetCount(xobjects)
            guard count <= 50_000 - visits else { throw Failure.tooComplex }
            visits += count
            var objects: [CGPDFObjectRef] = []
            CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in objects.append(object); return true }, nil)
            for object in objects {
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream) else { throw Failure.invalidCopy }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { continue }
                switch String(cString: subtype) {
                case "Image":
                    if let colorSpace = Self.object(dictionary, "ColorSpace"),
                       try indexed(colorSpace, resources: resources, depth: 0) { return true }
                case "Form":
                    if let nested = Self.dictionary(dictionary, "Resources"), try visit(nested, depth: depth + 1) { return true }
                default: break
                }
            }
            return false
        }
        return try visit(resources, depth: 0)
    }

    static func prepareMerge(imports: [Import], into destination: PDFDocument, at index: Int) throws -> Merge {
        try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: destination)
        try validateCatalog(destination)
        try PDFCatalogStructurePreserver.prepare(destination, force: true)
        guard !destination.isEncrypted || destination.permissionsStatus == .owner || destination.allowsDocumentAssembly else {
            throw Failure.unsupportedStructure
        }
        guard (0...destination.pageCount).contains(index) else { throw Failure.invalidCopy }
        var names = try validateFields(in: destination, indexes: Array(0..<destination.pageCount))
        for imported in imports {
            guard names.isDisjoint(with: imported.fieldNames) else { throw Failure.conflictingFormFields }
            names.formUnion(imported.fieldNames)
        }
        let pages = imports.flatMap(\.pages)
        guard Set(pages.map(ObjectIdentifier.init)).count == pages.count else { throw Failure.invalidCopy }
        let root = PDFOutline()
        root.label = destination.outlineRoot?.label
        root.isOpen = destination.outlineRoot?.isOpen ?? true
        if let existing = destination.outlineRoot {
            var remaining = 100_000
            let mapping = Dictionary(uniqueKeysWithValues: (0..<destination.pageCount).compactMap { destination.page(at: $0) }.map {
                (ObjectIdentifier($0), $0)
            })
            let navigation = NativeNavigation(source: destination)
            if let copied = try copyOutline(existing, in: destination, pages: mapping, navigation: navigation, native: navigation.outlines, depth: 0, remaining: &remaining, root: true) {
                while copied.numberOfChildren > 0 {
                    guard let child = copied.child(at: 0) else { throw Failure.invalidCopy }
                    child.removeFromParent()
                    root.insertChild(child, at: root.numberOfChildren)
                }
            }
        }
        for imported in imports {
            guard let outline = imported.outline, outline.numberOfChildren > 0 else { continue }
            // Group an imported table of contents by document title. Moving
            // children does not touch the original PDF's outline tree.
            let section = PDFOutline()
            section.label = (imported.attributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if section.label?.isEmpty != false { section.label = L10n.string("page_structure.imported_document", defaultValue: "가져온 PDF") }
            section.isOpen = true
            while outline.numberOfChildren > 0 {
                guard let child = outline.child(at: 0) else { throw Failure.invalidCopy }
                child.removeFromParent()
                section.insertChild(child, at: section.numberOfChildren)
            }
            root.insertChild(section, at: root.numberOfChildren)
        }
        return Merge(pages: pages, beforeOutline: destination.outlineRoot,
                     afterOutline: root.numberOfChildren > 0 ? root : nil, document: destination, start: index,
                     containsFormFields: !names.isEmpty, formFields: imports.flatMap(\.formFields))
    }

    /// Fail closed for structures that PDFKit page copying cannot reconstruct.
    /// Standard document Info attributes and simple AcroForm widgets are copied.
    static func validateCatalog(_ document: PDFDocument) throws {
        guard !document.isLocked else { throw Failure.invalidCopy }
        guard let catalog = document.documentRef?.catalog else { return }
        if let form = dictionary(catalog, "AcroForm") {
            if object(form, "XFA") != nil || !PDFCatalogStructurePreserver.hasNoCalculationOrderWork(form) {
                throw Failure.unsupportedStructure
            }
        }
    }

    private static func validateFields(in document: PDFDocument, indexes: [Int]) throws -> Set<String> {
        var names: Set<String> = []
        for index in indexes {
            guard let page = document.page(at: index) else { throw Failure.invalidCopy }
            if let dictionary = page.pageRef?.dictionary {
                if let annotations = array(dictionary, "Annots") {
                    guard CGPDFArrayGetCount(annotations) <= 100_000 else { throw Failure.tooComplex }
                    for index in 0..<CGPDFArrayGetCount(annotations) {
                        var annotation: CGPDFDictionaryRef?
                        guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { throw Failure.invalidCopy }
                        if let action = Self.dictionary(annotation, "A"), object(action, "Next") != nil {
                            throw Failure.unsupportedStructure
                        }
                        var parent = Self.dictionary(annotation, "Parent")
                        var depth = 0
                        while let field = parent {
                            depth += 1
                            guard depth < 64 else { throw Failure.tooComplex }
                            // Separate widget copies cannot preserve shared or
                            // hierarchical field relationships. Unique terminal
                            // widgets with one field parent are supported.
                            if depth > 1 || object(field, "AA") != nil {
                                throw Failure.conflictingFormFields
                            }
                            if let kids = array(field, "Kids"), CGPDFArrayGetCount(kids) != 1 {
                                throw Failure.conflictingFormFields
                            }
                            parent = Self.dictionary(field, "Parent")
                        }
                    }
                }
            }
            guard page.annotations.count <= 100_000 else { throw Failure.tooComplex }
            for annotation in page.annotations {
                if ["FileAttachment", "Sound", "Movie", "Screen", "RichMedia", "3D"].contains(annotation.type ?? "") {
                    throw Failure.unsupportedStructure
                }
                if let action = annotation.action {
                    guard ["GoTo", "GoToR", "URI", "Named", "ResetForm"].contains(action.type) else { throw Failure.unsupportedStructure }
                }
                guard annotation.type == "Widget" else { continue }
                if ["Sig", "/Sig"].contains(annotation.widgetFieldType.rawValue) {
                    guard PDFCatalogStructurePreserver.containsSignedOriginal(document) else { throw Failure.unsupportedStructure }
                    continue
                }
                guard let name = annotation.fieldName, !name.isEmpty, name.utf8.count <= 4_096,
                      names.insert(name).inserted else { throw Failure.conflictingFormFields }
                // Additional field actions/calculations and hierarchical/shared
                // field trees need an object-level form importer.
                if annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/AA")) != nil {
                    throw Failure.unsupportedStructure
                }
            }
        }
        return names
    }

    /// PDFKit may expose a destination with a nil page for an explicit deleted
    /// target, a named destination, or a zero-based page number. Resolve only
    /// those cases against the read-only native catalog; ordinary cached page
    /// destinations keep their existing inexpensive path.
    private final class NativeNavigation {
        private enum ResolutionFailure: Error { case missingName }
        let source: PDFDocument
        private let native: CGPDFDocument?
        private var pageIndexes: [UInt: Int]?
        private var nativePageIdentities: Set<UInt>?
        private var modernNames: [Data: CGPDFObjectRef]?
        private var modernTexts: [String: CGPDFObjectRef] = [:]
        private var ambiguousModernTexts = Set<String>()
        init(source: PDFDocument) { self.source = source; native = source.documentRef }
        var outlines: CGPDFDictionaryRef? { native?.catalog.flatMap { dictionary($0, "Outlines") } }

        func pendingInertParent(_ node: CGPDFDictionaryRef?, path: [Int]) throws -> PDFRawStreamSource.PendingInertOutlineParent? {
            guard let native, let node, let rawSource = PDFRawStreamProvenance.source(for: source) else { return nil }
            return try rawSource.pendingOriginalInertOutlineParent(in: native, node: node, path: path)
        }
        func annotation(on page: PDFPage, index: Int) -> CGPDFDictionaryRef? {
            guard let dictionary = page.pageRef?.dictionary, let list = array(dictionary, "Annots"),
                  CGPDFArrayGetCount(list) == page.annotations.count, index < CGPDFArrayGetCount(list) else { return nil }
            var annotation: CGPDFDictionaryRef?
            return CGPDFArrayGetDictionary(list, index, &annotation) ? annotation : nil
        }
        func destination(in node: CGPDFDictionaryRef?) throws -> CGPDFObjectRef? {
            guard let node else { return nil }
            if let destination = object(node, "Dest") { return destination }
            if let action = dictionary(node, "A"), name(action, "S") == "GoTo" {
                guard object(action, "Next") == nil, let destination = object(action, "D") else { throw Failure.invalidDestination }
                return destination
            }
            return nil
        }
        func mapped(_ cached: PDFDestination?, raw: CGPDFObjectRef?, pages: [ObjectIdentifier: PDFPage]) throws -> PDFDestination? {
            // A published PDF can contain a link name absent from both of its
            // destination tables. Prove that absence while still rejecting
            // malformed or ambiguous tables. An explicit current destination
            // may replace that old name while immutable pageRef still retains
            // it; preserve a live target belonging to this source document.
            var namedDestination: CGPDFArrayRef?
            // A document assembled in memory has no documentRef/catalog. Its
            // pages can still expose donor dictionaries containing old names;
            // only the already mapped live target belongs to this document.
            if let raw, native != nil {
                do { namedDestination = try resolved(raw) }
                catch ResolutionFailure.missingName {
                    guard let page = cached?.page, source.index(for: page) != NSNotFound else { return nil }
                }
            }
            if let cached, let page = cached.page, source.index(for: page) != NSNotFound,
               !(try obsoleteIntegerCache(cached, raw: raw)) {
                guard let copy = pages[ObjectIdentifier(page)] else { return nil }
                let result = PDFDestination(page: copy, at: cached.point); result.zoom = cached.zoom
                return result
            }
            guard let raw else {
                if cached != nil { throw Failure.invalidDestination }
                return nil
            }
            let destination: CGPDFArrayRef
            do { destination = try namedDestination ?? resolved(raw) }
            catch ResolutionFailure.missingName { return nil }
            let count = CGPDFArrayGetCount(destination)
            guard count >= 2, count <= 6 else { throw Failure.invalidDestination }
            var target: CGPDFObjectRef?, mode: UnsafePointer<CChar>?
            guard CGPDFArrayGetObject(destination, 0, &target), let target,
                  CGPDFArrayGetName(destination, 1, &mode), let mode else { throw Failure.invalidDestination }
            let view = String(cString: mode)
            let arities = ["XYZ": 5, "Fit": 2, "FitH": 3, "FitV": 3, "FitR": 6, "FitB": 2, "FitBH": 3, "FitBV": 3]
            guard let arity = arities[view], count <= arity, view != "FitR" || count == arity else { throw Failure.invalidDestination }
            for index in 2..<count {
                var value: CGPDFObjectRef?, number: CGPDFReal = 0
                guard CGPDFArrayGetObject(destination, index, &value), let value else { throw Failure.invalidDestination }
                if CGPDFObjectGetType(value) != .null {
                    guard CGPDFArrayGetNumber(destination, index, &number), number.isFinite else { throw Failure.invalidDestination }
                }
            }
            // A null page is an explicitly dead link in a source PDF. Pruning
            // it keeps all valid neighbors and never guesses a replacement.
            if CGPDFObjectGetType(target) == .null { return nil }
            let targetDictionary: CGPDFDictionaryRef
            if CGPDFObjectGetType(target) == .integer {
                var integer: CGPDFInteger = -1
                guard let native, CGPDFObjectGetValue(target, .integer, &integer), integer >= 0,
                      integer < native.numberOfPages, let dictionary = native.page(at: integer + 1)?.dictionary else { throw Failure.invalidDestination }
                targetDictionary = dictionary
            } else {
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(target, .dictionary, &dictionary), let dictionary else { throw Failure.invalidDestination }
                targetDictionary = dictionary
            }
            let key = pdfReferenceIdentity(targetDictionary)
            guard let index = try indexes()[key] else {
                // A recognized original page may have been removed since the
                // catalog was parsed. It has no current target to copy.
                guard try originalPageIdentities().contains(key) else { throw Failure.invalidDestination }
                return nil
            }
            guard let page = source.page(at: index) else { throw Failure.invalidDestination }
            guard let copy = pages[ObjectIdentifier(page)] else { return nil }
            let point: CGPoint
            let zoom: CGFloat
            do {
                func coordinate(_ index: Int) -> CGFloat {
                    var number: CGPDFReal = 0
                    return index < count && CGPDFArrayGetNumber(destination, index, &number) ? CGFloat(number) : kPDFDestinationUnspecifiedValue
                }
                switch view {
                case "XYZ": point = CGPoint(x: coordinate(2), y: coordinate(3)); zoom = coordinate(4)
                case "FitH", "FitBH": point = CGPoint(x: kPDFDestinationUnspecifiedValue, y: coordinate(2)); zoom = kPDFDestinationUnspecifiedValue
                case "FitV", "FitBV": point = CGPoint(x: coordinate(2), y: kPDFDestinationUnspecifiedValue); zoom = kPDFDestinationUnspecifiedValue
                case "FitR": point = CGPoint(x: coordinate(2), y: coordinate(5)); zoom = kPDFDestinationUnspecifiedValue
                default: point = CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue); zoom = kPDFDestinationUnspecifiedValue
                }
            }
            let result = PDFDestination(page: copy, at: point); result.zoom = zoom
            return result
        }
        func rememberView(from original: PDFOutline, to copy: PDFOutline, raw: CGPDFObjectRef?) throws {
            guard ((copy.action as? PDFActionGoTo)?.destination ?? copy.destination)?.page != nil else { return }
            if PDFCatalogStructurePreserver.inheritOutlineDestination(from: original, to: copy) { return }
            guard let raw, let native else { return }
            let destination: CGPDFArrayRef
            do { destination = try resolved(raw) }
            catch ResolutionFailure.missingName {
                // mapped already retained a valid, explicitly current target.
                // An obsolete unresolved name has no original view operands
                // to restore over that edit.
                return
            }
            PDFCatalogStructurePreserver.rememberOutlineDestination(copy, destination: destination, document: native)
        }
        private func obsoleteIntegerCache(_ cached: PDFDestination, raw: CGPDFObjectRef?) throws -> Bool {
            guard let raw, let native else { return false }
            var list: CGPDFArrayRef?, integer: CGPDFInteger = -1
            guard CGPDFObjectGetValue(raw, .array, &list), let list,
                  CGPDFArrayGetInteger(list, 0, &integer), integer >= 0, integer < native.numberOfPages,
                  let target = native.page(at: integer + 1)?.dictionary,
                  let current = try indexes()[pdfReferenceIdentity(target)], let page = cached.page else { return false }
            // PDFKit can lazily interpret an original integer against the new
            // order. A retained native target gives an exact identity check.
            // A replaced page instead follows its explicit live destination.
            return source.index(for: page) != current
        }
        private func indexes() throws -> [UInt: Int] {
            if let pageIndexes { return pageIndexes }
            guard source.pageCount <= 250_000 else { throw Failure.tooComplex }
            var result: [UInt: Int] = [:]
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index)?.pageRef?.dictionary,
                      result.updateValue(index, forKey: pdfReferenceIdentity(page)) == nil else { throw Failure.invalidDestination }
            }
            pageIndexes = result
            return result
        }
        private func originalPageIdentities() throws -> Set<UInt> {
            if let nativePageIdentities { return nativePageIdentities }
            guard let native, native.numberOfPages <= 250_000 else { throw Failure.invalidDestination }
            var result = Set<UInt>()
            for index in 0..<native.numberOfPages {
                guard let page = native.page(at: index + 1)?.dictionary else { throw Failure.invalidDestination }
                result.insert(pdfReferenceIdentity(page))
            }
            nativePageIdentities = result
            return result
        }
        private func resolved(_ value: CGPDFObjectRef, depth: Int = 0) throws -> CGPDFArrayRef {
            guard depth < 64 else { throw Failure.tooComplex }
            var list: CGPDFArrayRef?
            if CGPDFObjectGetValue(value, .array, &list), let list { return list }
            var dictionary: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary, let next = object(dictionary, "D") {
                return try resolved(next, depth: depth + 1)
            }
            if CGPDFObjectGetType(value) == .name {
                var pointer: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(value, .name, &pointer), let pointer, strnlen(pointer, 1_048_576) < 1_048_576 else { throw Failure.invalidDestination }
                let key = String(cString: pointer)
                if let found = try legacyDestination(named: key) {
                    return try resolved(found, depth: depth + 1)
                }
                try readModernNames()
                guard !ambiguousModernTexts.contains(key) else { throw Failure.invalidDestination }
                if let found = modernTexts[key] { return try resolved(found, depth: depth + 1) }
                throw ResolutionFailure.missingName
            } else if CGPDFObjectGetType(value) == .string {
                var string: CGPDFStringRef?
                guard CGPDFObjectGetValue(value, .string, &string), let string else { throw Failure.invalidDestination }
                let key = try bytes(string)
                try readModernNames()
                if let found = modernNames?[key] { return try resolved(found, depth: depth + 1) }
                if let text = CGPDFStringCopyTextString(string) as String? {
                    guard !ambiguousModernTexts.contains(text) else { throw Failure.invalidDestination }
                    if let found = modernTexts[text] { return try resolved(found, depth: depth + 1) }
                    if let found = try legacyDestination(named: text) {
                        return try resolved(found, depth: depth + 1)
                    }
                    throw ResolutionFailure.missingName
                }
            }
            throw Failure.invalidDestination
        }
        private func legacyDestination(named key: String) throws -> CGPDFObjectRef? {
            guard let catalog = native?.catalog else { throw Failure.invalidDestination }
            guard let value = object(catalog, "Dests"), CGPDFObjectGetType(value) != .null else { return nil }
            var legacy: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &legacy), let legacy,
                  CGPDFDictionaryGetCount(legacy) <= 100_000 else { throw Failure.invalidDestination }
            return object(legacy, key)
        }
        private func readModernNames() throws {
            guard modernNames == nil else { return }
            var names: [Data: CGPDFObjectRef] = [:], texts: [String: CGPDFObjectRef] = [:], ambiguous = Set<String>()
            guard let catalog = native?.catalog else { throw Failure.invalidDestination }
            guard let treesObject = object(catalog, "Names"), CGPDFObjectGetType(treesObject) != .null else {
                modernNames = [:]; return
            }
            var trees: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(treesObject, .dictionary, &trees), let trees else { throw Failure.invalidDestination }
            guard let rootObject = object(trees, "Dests"), CGPDFObjectGetType(rootObject) != .null else {
                modernNames = [:]; return
            }
            var root: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(rootObject, .dictionary, &root), let root else { throw Failure.invalidDestination }
            var pending = [(root, 0)], seen = Set<UInt>(), visits = 0
            while let (node, depth) = pending.popLast() {
                guard depth < 64, seen.insert(pdfReferenceIdentity(node)).inserted, seen.count <= 100_000 else { throw Failure.tooComplex }
                let hasValues = object(node, "Names").map { CGPDFObjectGetType($0) != .null } ?? false
                let hasChildren = object(node, "Kids").map { CGPDFObjectGetType($0) != .null } ?? false
                guard hasValues != hasChildren else { throw Failure.invalidDestination }
                if let value = object(node, "Names"), CGPDFObjectGetType(value) != .null {
                    var values: CGPDFArrayRef?
                    guard CGPDFObjectGetValue(value, .array, &values), let values else { throw Failure.invalidDestination }
                    let count = CGPDFArrayGetCount(values)
                    guard count % 2 == 0, count <= 200_000 else { throw Failure.invalidDestination }
                    for index in stride(from: 0, to: count, by: 2) {
                        visits += 1; guard visits <= 100_000 else { throw Failure.tooComplex }
                        var key: CGPDFStringRef?, value: CGPDFObjectRef?
                        guard CGPDFArrayGetString(values, index, &key), let key,
                              CGPDFArrayGetObject(values, index + 1, &value), let value else { throw Failure.invalidDestination }
                        let raw = try bytes(key)
                        guard names.updateValue(value, forKey: raw) == nil else { throw Failure.invalidDestination }
                        if let text = CGPDFStringCopyTextString(key) as String? {
                            // Name-tree keys retain their original bytes. Two
                            // distinct keys may decode to the same display
                            // text; exact-byte lookup remains unambiguous.
                            if texts[text] != nil { texts[text] = nil; ambiguous.insert(text) }
                            else if !ambiguous.contains(text) { texts[text] = value }
                        }
                    }
                }
                if let value = object(node, "Kids"), CGPDFObjectGetType(value) != .null {
                    var children: CGPDFArrayRef?
                    guard CGPDFObjectGetValue(value, .array, &children), let children else { throw Failure.invalidDestination }
                    guard CGPDFArrayGetCount(children) <= 100_000 else { throw Failure.tooComplex }
                    for index in 0..<CGPDFArrayGetCount(children) {
                        var child: CGPDFDictionaryRef?
                        guard CGPDFArrayGetDictionary(children, index, &child), let child else { throw Failure.invalidDestination }
                        pending.append((child, depth + 1))
                    }
                }
            }
            modernNames = names; modernTexts = texts; ambiguousModernTexts = ambiguous
        }
        private func bytes(_ string: CGPDFStringRef) throws -> Data {
            let count = CGPDFStringGetLength(string)
            guard count <= 1_048_576 else { throw Failure.tooComplex }
            if count == 0 { return Data() }
            guard let pointer = CGPDFStringGetBytePtr(string) else { throw Failure.invalidDestination }
            return Data(bytes: pointer, count: count)
        }
        private func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
            PDFPageStructurePreserver.dictionary(dictionary, key)
        }
        private func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var value: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
            return String(cString: value)
        }
    }

    private static func clearNavigation(_ annotation: PDFAnnotation) throws {
        annotation.destination = nil
        annotation.action = nil
        // A copied link may still have its donor's raw destination/action even
        // after the property setters clear PDFKit's cached navigation objects.
        annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest"))
        annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/A"))
        guard annotation.destination == nil, annotation.action == nil,
              annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")) == nil,
              annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/A")) == nil else {
            throw Failure.invalidCopy
        }
    }

    private static func copyOutline(_ original: PDFOutline?, in source: PDFDocument,
                                    pages: [ObjectIdentifier: PDFPage], navigation: NativeNavigation,
                                    native: CGPDFDictionaryRef?, depth: Int, remaining: inout Int,
                                    root: Bool = false, path: [Int] = []) throws -> PDFOutline? {
        guard let original else { return nil }
        guard depth < 128, remaining > 0 else { throw Failure.tooComplex }
        remaining -= 1
        let copy = PDFOutline()
        PDFCatalogStructurePreserver.inheritOutlineStyle(from: original, to: copy)
        copy.label = original.label
        copy.isOpen = original.isOpen
        let matchingNative: CGPDFDictionaryRef?
        if root { matchingNative = native }
        else if let native {
            var title: CGPDFStringRef?
            matchingNative = CGPDFDictionaryGetString(native, "Title", &title)
                && title.flatMap(CGPDFStringCopyTextString).map({ $0 as String }) == original.label ? native : nil
        } else { matchingNative = nil }
        let hadInertRecord = PDFCatalogStructurePreserver.hasPendingInertOutlineRecord(original)
        let candidate: PDFRawStreamSource.PendingInertOutlineParent?
        if hadInertRecord { candidate = PDFCatalogStructurePreserver.pendingInertOutlineCandidate(original) }
        else { candidate = try navigation.pendingInertParent(matchingNative, path: path) }
        // A changed current action/destination invalidates the old inactive
        // record. Do not resurrect its immutable native metadata over that edit.
        let rawDestination = hadInertRecord && candidate == nil ? nil : try navigation.destination(in: matchingNative)
        var pendingInert: PDFRawStreamSource.PendingInertOutlineParent?
        if let candidate, PDFCatalogStructurePreserver.isInactiveOutlineParent(original) {
            pendingInert = candidate // parent stays non-navigating; proof is deferred
        } else if candidate != nil, let action = original.action, !(action is PDFActionGoTo) {
            guard ["GoToR", "URI", "Named"].contains(action.type), let detached = action.copy() as? PDFAction else {
                throw Failure.unsupportedStructure
            }
            copy.action = detached
        } else if let action = original.action as? PDFActionGoTo {
            copy.action = try navigation.mapped(action.destination, raw: rawDestination, pages: pages).map(PDFActionGoTo.init(destination:))
        } else if let destination = original.destination {
            copy.destination = try navigation.mapped(destination, raw: rawDestination, pages: pages)
        } else if let rawDestination {
            copy.destination = try navigation.mapped(nil, raw: rawDestination, pages: pages)
        } else if let action = original.action {
            guard ["GoToR", "URI", "Named"].contains(action.type), let detached = action.copy() as? PDFAction else {
                throw Failure.unsupportedStructure
            }
            copy.action = detached
        }
        try navigation.rememberView(from: original, to: copy, raw: rawDestination)
        var nativeChild = matchingNative.flatMap { dictionary($0, "First") }
        var visitedNative = Set<UInt>()
        for index in 0..<original.numberOfChildren {
            if let node = nativeChild {
                guard visitedNative.insert(pdfReferenceIdentity(node)).inserted else { throw Failure.invalidDestination }
            }
            if let child = try copyOutline(original.child(at: index), in: source, pages: pages, navigation: navigation,
                                           native: nativeChild, depth: depth + 1, remaining: &remaining, path: path + [index]) {
                copy.insertChild(child, at: copy.numberOfChildren)
            }
            nativeChild = nativeChild.flatMap { dictionary($0, "Next") }
        }
        if let pendingInert, copy.numberOfChildren > 0 {
            if !hadInertRecord { PDFCatalogStructurePreserver.rememberPendingInertOutline(original, candidate: pendingInert) }
            PDFCatalogStructurePreserver.rememberPendingInertOutline(copy, candidate: pendingInert)
        }
        if !root && copy.action == nil && copy.destination == nil && copy.numberOfChildren == 0 { return nil }
        return copy
    }

    private static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var result: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &result) ? result : nil
    }
    private static func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var result: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary, key, &result) ? result : nil
    }
    private static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var result: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(dictionary, key, &result) ? result : nil
    }
}
