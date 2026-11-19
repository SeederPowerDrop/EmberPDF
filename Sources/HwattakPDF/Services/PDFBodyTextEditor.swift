// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import CryptoKit
import ObjectiveC
import CPDFium
import PDFKit

/// Issued only after the actual private native lossless branch, final font
/// handling, factory construction and current-text check have all succeeded.
/// A worker must independently validate it before granting any tag permission.
final class PDFBodyLosslessCommit: @unchecked Sendable {
    /// Authored paragraph formatting intent, not equal glyph ink or layout.
    /// Only the actual Editor transaction in this file can construct it.
    fileprivate final class ParagraphStyleIntent: @unchecked Sendable {
        private let sourceDictionary: CGPDFDictionaryRef
        private let sourceRaw: PDFRawStreamSource
        private let construction: PDFBodyResourceCopyWitness

        @MainActor fileprivate init?(page: PDFPage, original: CGPDFPage, raw: PDFRawStreamSource,
                                    target: PDFBodyTextTarget?, text: String,
                                    style: InlineTextStyle, bounds: CGRect,
                                    construction: PDFBodyResourceCopyWitness) {
            guard let target, target.sourcePageID == ObjectIdentifier(page),
                  let dictionary = original.dictionary, dictionary == page.pageRef?.dictionary,
                  style == target.style, bounds == target.bounds,
                  !target.text.isEmpty, !text.isEmpty, text != target.text,
                  PDFBodyLosslessCommit.preservesParagraphSeparators(before: target.text, after: text) else { return nil }
            sourceDictionary = dictionary; sourceRaw = raw; self.construction = construction
        }

        fileprivate func matches(_ commit: PDFBodyLosslessCommit) -> Bool {
            sourceDictionary == commit.original.dictionary && sourceRaw === commit.originalRaw
                && construction === commit.copy
        }
    }

    // Pure non-authoritative policy, shared by tests; only the fileprivate
    // receipt initializer can turn it into transaction-bound evidence.
    // A single correction can grow or shrink before an unchanged line
    // break, but cannot move, insert or delete a separator. Views/slices
    // avoid retaining either transcript or allocating per-character arrays.
    static func preservesParagraphSeparators(before: String, after: String) -> Bool {
        let left = before.utf16, right = after.utf16
        var prefix = 0
        for (a, b) in zip(left, right) {
            if a != b { break }; prefix += 1
        }
        let remaining = min(left.count, right.count) - prefix
        var suffix = 0
        for (a, b) in zip(left.reversed(), right.reversed()) {
            if suffix >= remaining || a != b { break }; suffix += 1
        }
        func isSeparator(_ value: UInt16) -> Bool {
            switch value {
            case 0x000A, 0x000B, 0x000C, 0x000D, 0x0085, 0x2028, 0x2029: true
            default: false
            }
        }
        return !left.dropFirst(prefix).dropLast(suffix).contains(where: isSeparator)
            && !right.dropFirst(prefix).dropLast(suffix).contains(where: isSeparator)
    }


    let original: CGPDFPage
    let originalRaw: PDFRawStreamSource
    let originalOwner: CGPDFDocument
    let current: CGPDFPage
    let currentRaw: PDFRawStreamSource
    let currentOwner: CGPDFDocument
    let copy: PDFBodyResourceCopyWitness
    let rewrite: PDFBodyLosslessRewriteReceipt
    private let paragraphStyleIntent: ParagraphStyleIntent?

    /// Metadata-only evidence, consumed after the worker's existing complete
    /// commit proof. It cannot authorize painting or a foreign/current graph.
    func retainsParagraphStyle(in owner: CGPDFDocument, page: CGPDFPage, raw: PDFRawStreamSource) -> Bool {
        originalOwner === owner && original.dictionary == page.dictionary && originalRaw === raw
            && paragraphStyleIntent?.matches(self) == true
    }
    /// Newly retained transcript payload only, not CoreGraphics/QPDF allocator
    /// memory or the already-associated shared original/current RawSource.
    var retainedTranscriptBytes: Int {
        rewrite.source.count + rewrite.rewritten.count
            + rewrite.patches.reduce(0) { $0 + $1.bytes.count } + (copy.donorProgram?.count ?? 0)
    }
    fileprivate init(original: CGPDFPage, originalRaw: PDFRawStreamSource, originalOwner: CGPDFDocument,
                     current: CGPDFPage, currentRaw: PDFRawStreamSource, currentOwner: CGPDFDocument,
                     copy: PDFBodyResourceCopyWitness, rewrite: PDFBodyLosslessRewriteReceipt,
                     paragraphStyleIntent: ParagraphStyleIntent?) {
        self.original = original; self.originalRaw = originalRaw; self.originalOwner = originalOwner
        self.current = current; self.currentRaw = currentRaw; self.currentOwner = currentOwner
        self.copy = copy; self.rewrite = rewrite
        self.paragraphStyleIntent = paragraphStyleIntent
    }
}
enum PDFBodyLosslessProvenance {
    private static let key = NSObject()
    private static var association: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(key).toOpaque()) }
    static func commit(for page: PDFPage) -> PDFBodyLosslessCommit? {
        objc_getAssociatedObject(page, association) as? PDFBodyLosslessCommit
    }
    fileprivate static func record(_ commit: PDFBodyLosslessCommit, on page: PDFPage) {
        objc_setAssociatedObject(page, association, commit, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// A newly inserted native donor, bound before its native owner closes. Only
/// the editor's creation path can issue this receipt; no saved marker, font
/// name or caller-selected Form is sufficient. It grants no raw/tag authority.
@MainActor
final class PDFBodyGeneratedDonorTag {
    private enum InvalidReceipt: Error { case changed }
    private let owner: PDFDocument
    private let page: PDFPage
    private let reference: CGPDFPage
    private let form: CGPDFDictionaryRef
    private let snapshotDigest: SHA256.Digest

    fileprivate init(owner: PDFDocument, page: PDFPage, reference: CGPDFPage,
                     form: CGPDFDictionaryRef, snapshot: Data) {
        self.owner = owner; self.page = page; self.reference = reference
        self.form = form; snapshotDigest = SHA256.hash(data: snapshot)
    }

    func withSnapshot<T>(matching data: Data,
        _ body: (PDFPage, CGPDFPage, CGPDFDictionaryRef) throws -> T) throws -> T {
        guard data.count <= 64 * 1_024 * 1_024, SHA256.hash(data: data) == snapshotDigest,
              owner.pageCount == 1, owner.page(at: 0) === page,
              page.pageRef?.dictionary == reference.dictionary else {
            throw InvalidReceipt.changed
        }
        return try withExtendedLifetime(owner) { try body(page, reference, form) }
    }
}

/// A bounded, detached description of compatible native PDF text objects. No PDFium
/// pointer escapes a call: opening an editor does not retain native documents.
struct PDFBodyTextTarget {
    let text: String
    let bounds: CGRect
    /// Source-declared paint clearance; hit/editor geometry remains `bounds`.
    var paintBounds: CGRect {
        // These rows were inspected before mutation, including the paper that
        // the existing scan writer restores. Hit/layout bounds remain separate.
        let erasures = scannedSource?.erasedRects ?? outlinedSource?.metadata.erasedRects
            ?? scannedReeditMetadata?.erasedRects
        if let erasures, let first = erasures.first {
            return erasures.dropFirst().reduce(first) { $0.union($1) }
        }
        return declaredPaintBounds ?? bounds
    }
    fileprivate var declaredPaintBounds: CGRect? = nil
    fileprivate var protectedPaintBounds: [CGRect] = []
    let style: InlineTextStyle
    fileprivate let objectPath: [Int]
    fileprivate let sourcePageID: ObjectIdentifier
    fileprivate let glyphBounds: CGRect
    let baseline: CGPoint
    fileprivate var horizontalAdvance: CGFloat?
    fileprivate var leadingWhitespaceAdvance: CGFloat = 0
    fileprivate var additionalObjects: [PDFBodyTextTarget] = []
    var lineHeight: CGFloat?
    var firstLineIndent: CGFloat = 0
    var sourceRuns: [InlineTextSourceRun] = []
    var initialSelectedRange: NSRange?
    fileprivate var textBlockIndices: [Int]?
    fileprivate var textBlockSource: Data?
    fileprivate var scannedSource: PDFScannedBodyTextEditor.Source?
    fileprivate var outlinedSource: PDFOutlinedOCRSource?
    fileprivate var scannedReeditMetadata: PDFScannedErasureMetadata?
    var previewPaperColor: PDFTextColor? {
        scannedSource?.paperColor ?? outlinedSource?.metadata.paperColor ?? scannedReeditMetadata?.paperColor
    }
}

/// Edits page content, rather than hiding the old glyphs behind an annotation.
/// All work happens in a detached one-page snapshot; failure leaves PDFKit's
/// live document untouched. PDFium is confined to the main actor because its
/// process-wide library and document handles are not generally thread-safe.
@MainActor
enum PDFBodyTextEditor {
    private static let maximumPageBytes = 64 * 1_024 * 1_024
    private static let maximumObjects = 50_000
    private static let maximumPageCharacters = 250_000
    private static let maximumDepth = 16
    private static let initialized: Void = { FPDF_InitLibrary() }()

    private enum Failure: LocalizedError {
        case restricted, unreadable, tooComplex, unsupported, changed, doesNotFit, readingOrder, reopenForBodyEdit, failed
        var errorDescription: String? {
            switch self {
            case .restricted:
                return L10n.string("body_text.error.restricted", defaultValue: "이 PDF의 본문을 편집하려면 소유자 권한으로 열어 주세요.")
            case .unreadable:
                return L10n.string("body_text.error.unreadable", defaultValue: "PDF 본문을 편집 가능한 형태로 읽지 못했습니다.")
            case .tooComplex:
                return L10n.string("body_text.error.too_complex", defaultValue: "이 페이지나 텍스트는 안전하게 편집할 수 있는 크기를 초과합니다.")
            case .unsupported:
                return L10n.string("body_text.error.unsupported", defaultValue: "이 텍스트 또는 페이지의 구조·변형·표시 방식은 아직 본문 편집을 지원하지 않습니다.")
            case .changed:
                return L10n.string("body_text.error.changed", defaultValue: "편집 중 원문이 변경되었습니다. 텍스트를 다시 선택해 주세요.")
            case .doesNotFit:
                return L10n.string("body_text.error.does_not_fit", defaultValue: "입력한 내용을 현재 편집 영역에 배치할 수 없습니다. 글꼴이나 글자 크기를 조정하거나 내용을 줄여 주세요.")
            case .readingOrder:
                return L10n.string("body_text.error.reading_order", defaultValue: "이 변경을 적용하면 페이지의 텍스트 읽기 순서가 달라질 수 있습니다. PDF는 변경되지 않았으며 입력한 내용은 편집기에 남아 있습니다.")
            case .reopenForBodyEdit:
                return L10n.string("body_text.error.reopen_for_edit", defaultValue: "이 페이지의 접근성 태그를 유지하려면 현재 초안을 취소하고 PDF를 저장한 뒤 다시 열어 편집해 주세요.")
            case .failed:
                return L10n.string("body_text.error.failed", defaultValue: "PDF 본문 변경을 완료하지 못했습니다. 원본은 변경되지 않았습니다.")
            }
        }
    }

    /// QA diagnostics classify only this fixed private error enum. Never
    /// expose arbitrary error descriptions, source text, font names or paths.
    static func diagnosticFailureCode(for error: Error) -> String? {
        guard let failure = error as? Failure else { return nil }
        switch failure {
        case .restricted: return "editor.restricted"
        case .unreadable: return "editor.unreadable"
        case .tooComplex: return "editor.tooComplex"
        case .unsupported: return "editor.unsupported"
        case .changed: return "editor.changed"
        case .doesNotFit: return "editor.doesNotFit"
        case .readingOrder: return "editor.readingOrder"
        case .reopenForBodyEdit: return "editor.reopenForBodyEdit"
        case .failed: return "editor.failed"
        }
    }

    static func target(on page: PDFPage, at point: CGPoint) throws -> PDFBodyTextTarget? {
        try validatePermission(page)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let sourceData = try snapshot(page)
        return try withPage(sourceData, sourceDocument: page.document) { _, nativePage in
            guard let textPage = FPDFText_LoadPage(nativePage) else { throw Failure.unreadable }
            defer { FPDFText_ClosePage(textPage) }
            let count = FPDFText_CountChars(textPage)
            guard count >= 0, count <= maximumPageCharacters else { throw Failure.tooComplex }
            let outlined = try outlinedTarget(on: page, selection: nil, point: point,
                nativePage: nativePage, textPage: textPage, characterCount: count, snapshot: sourceData)
            if let target = outlined.target { return target }
            // A small tolerance includes the interior whitespace of an ordinary
            // glyph, without selecting a neighbouring line after a blank click.
            let index = FPDFText_GetCharIndexAtPos(textPage, point.x, point.y, 1.5, 1.5)
            guard index >= 0, let object = FPDFText_GetTextObject(textPage, index) else { return nil }
            let path = try path(to: object, on: nativePage)
            if path.count == 1, let target = try wholeBlockTarget(on: page, nativePage: nativePage,
                textPage: textPage, characterCount: count, selectedRoots: [path[0]], selection: nil) {
                return target
            }
            let resolved = try resolve(path, on: nativePage, requiringFinalLeaf: false)
            let description = try describe(object, in: textPage, characterCount: count)
            if let parent = resolved.parent, FPDFFormObj_CountObjects(parent) > 1 {
                // Earlier lines of a generated paragraph share one Form. Edit
                // its compatible lines together so later text never
                // moves across the changed text's painting position.
                let selection = PDFRegionTextSelection(document: page.document ?? PDFDocument(), page: page,
                    fragments: [.init(text: description.text, bounds: description.glyphBounds)])
                guard let target = try target(on: page, selection: selection) else { throw Failure.unsupported }
                return target
            }
            var target = PDFBodyTextTarget(
                text: description.text, bounds: description.bounds, style: description.style,
                objectPath: path, sourcePageID: ObjectIdentifier(page),
                glyphBounds: description.glyphBounds, baseline: description.baseline,
                horizontalAdvance: description.horizontalAdvance
            )
            target.leadingWhitespaceAdvance = leadingAdvance(for: description, content: target.text)
            target.sourceRuns = sourceRuns(for: description, content: target.text, offset: 0, baselineOffset: 0)
            try validateEditingRoute(page, nativePage: nativePage, originals: [target])
            return try declaredPaintTarget(target, on: page, nativePage: nativePage,
                textPage: textPage, characterCount: count)?.target
        }
    }

    /// Resolve the whole visible selection, never just the first hit text run.
    /// PDFKit reading order can differ from the repaired selection's geometry;
    /// matching both its glyph positions and Unicode text avoids editing a
    /// nearby caption or accepting OCR text that has no corresponding content.
    static func target(on page: PDFPage, selection: PDFSelection) throws -> PDFBodyTextTarget? {
        try validatePermission(page)
        guard selection.pages.count == 1, selection.pages.first === page,
              let selectedText = selection.string,
              !selectionKey(selectedText).isEmpty,
              !InlineTextDraftLimiter.limit(selectedText).wasTruncated else { return nil }
        let fragments = selection.selectionsByLine().map { $0.bounds(for: page) }
        guard !fragments.isEmpty, fragments.count <= 256,
              fragments.allSatisfy({ valid($0) && !$0.isEmpty }) else { return nil }
        // The scanned route retains this same immutable source for its later
        // stale-page check. Reuse the bytes already being inspected instead of
        // serializing the image/font resource graph a second time on entry.
        let sourceData = try snapshot(page)
        return try withPage(sourceData, sourceDocument: page.document) { _, nativePage in
            guard let textPage = FPDFText_LoadPage(nativePage) else { throw Failure.unreadable }
            defer { FPDFText_ClosePage(textPage) }
            let count = FPDFText_CountChars(textPage)
            guard count >= 0, count <= maximumPageCharacters else { throw Failure.tooComplex }

            let outlined = try outlinedTarget(on: page, selection: selection, point: nil,
                nativePage: nativePage, textPage: textPage, characterCount: count, snapshot: sourceData)
            if let target = outlined.target { return target }

            if let scanned = try PDFScannedBodyTextEditor.target(on: page, selection: selection,
                nativePage: nativePage, textPage: textPage, characterCount: count, snapshot: { sourceData },
                protectedFormBounds: outlined.bounds, protectedFormNames: outlined.names) {
                var target = PDFBodyTextTarget(text: scanned.text, bounds: scanned.bounds, style: scanned.style,
                    objectPath: [], sourcePageID: ObjectIdentifier(page), glyphBounds: scanned.bounds,
                    baseline: scanned.baseline, horizontalAdvance: nil)
                target.lineHeight = scanned.lineHeight
                target.firstLineIndent = scanned.firstLineIndent
                target.sourceRuns = scanned.sourceRuns
                target.initialSelectedRange = scanned.selectedRange
                target.scannedSource = scanned.source
                return target
            }

            struct Glyph {
                let text: String
                let selected: Bool
            }
            var glyphs: [FPDF_PAGEOBJECT: [Glyph]] = [:]
            var characterIndices: [FPDF_PAGEOBJECT: [Int32]] = [:]
            var touched = Set<FPDF_PAGEOBJECT>()
            for index in 0..<count {
                guard let object = FPDFText_GetTextObject(textPage, index) else { continue }
                characterIndices[object, default: []].append(index)
                let value = FPDFText_GetUnicode(textPage, index)
                guard let scalar = UnicodeScalar(value), value != 0 else { continue }
                let isGenerated = FPDFText_IsGenerated(textPage, index) != 0
                // PDFs often encode word spaces as positioning adjustments
                // inside TJ rather than literal space glyphs. PDFium marks
                // those spaces generated while still assigning them to this
                // text object. Retain owned horizontal whitespace so a drag
                // resolves the same words as GetText; generated line breaks
                // and all other generated content remain excluded.
                guard !isGenerated
                    || (CharacterSet.whitespaces.contains(scalar)
                        && !CharacterSet.newlines.contains(scalar)) else { continue }
                var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
                guard FPDFText_GetCharBox(textPage, index, &left, &right, &bottom, &top) != 0 else {
                    throw Failure.unreadable
                }
                let point = CGPoint(x: (left + right) / 2, y: (bottom + top) / 2)
                // Synthetic space boxes can overlap the neighbouring glyph's
                // selection bounds. They belong between selected letters, but
                // must not extend a phrase into its unselected prefix/suffix.
                let selected = !isGenerated
                    && fragments.contains { $0.insetBy(dx: -0.15, dy: -0.15).contains(point) }
                glyphs[object, default: []].append(Glyph(text: String(scalar), selected: selected))
                if selected { touched.insert(object) }
            }
            guard !touched.isEmpty, touched.count <= 256 else { return nil }
            var objectPaths = try paths(to: touched, on: nativePage)
            if objectPaths.values.allSatisfy({ $0.count == 1 }),
               let target = try wholeBlockTarget(on: page, nativePage: nativePage,
                   textPage: textPage, characterCount: count,
                   selectedRoots: Set(objectPaths.values.map { $0[0] }), selection: selection) {
                return target
            }
            // A Form has no indexed insertion API. Preserve its font/resource
            // isolation by replacing the whole compatible text paragraph,
            // with only the user's original glyphs selected in the editor.
            // This also accepts paragraphs saved by earlier app versions.
            var expandedParents = Set<[Int]>()
            var inertPaths = Set<[Int]>()
            let directRoots = Set(objectPaths.values.filter { $0.count == 1 }.map { $0[0] })
            for root in inertRootGaps(between: directRoots, on: nativePage, in: textPage,
                hasOwnedCharacters: { characterIndices[$0] != nil }) {
                inertPaths.insert([root])
            }
            for path in Array(objectPaths.values) where path.count > 1 {
                guard expandedParents.insert(Array(path.dropLast())).inserted else { continue }
                let resolved = try resolve(path, on: nativePage, requiringFinalLeaf: false)
                guard let parent = resolved.parent else { continue }
                let count = Int(FPDFFormObj_CountObjects(parent))
                guard count > 0, count <= maximumObjects else { throw Failure.tooComplex }
                var verifiedOwned: Bool?
                for index in 0..<count {
                    guard let object = FPDFFormObj_GetObject(parent, UInt(index)),
                          FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT else { return nil }
                    if isInertEmptySpace(object, in: textPage, hasOwnedCharacters: characterIndices[object] != nil) {
                        if verifiedOwned == nil {
                            verifiedOwned = path.count == 2 && uniqueOwnedForm(on: page, nativePage: nativePage, root: path[0])
                        }
                        if verifiedOwned == true {
                            inertPaths.insert(Array(path.dropLast()) + [index])
                            continue
                        }
                    }
                    touched.insert(object)
                    objectPaths[object] = Array(path.dropLast()) + [index]
                    guard touched.count <= 256 else { throw Failure.tooComplex }
                }
            }
            struct Run {
                let target: PDFBodyTextTarget
                let glyphs: [Glyph]
                let description: Description
            }
            var runs: [Run] = []
            for object in touched {
                guard let path = objectPaths[object] else { throw Failure.unreadable }
                // The text-only Form is removed in full. Ancestor Forms must
                // contain only that child so they can be removed in full too.
                _ = try resolve(path, on: nativePage, requiringFinalLeaf: touched.count == 1 && inertPaths.isEmpty)
                let description = try describe(object, in: textPage, characterCount: count,
                                               characterIndices: characterIndices[object])
                let objectGlyphs = glyphs[object] ?? []
                // GetText can append a boundary space owned by the next text
                // object. Use actual character ownership for editor text, but
                // retain the original description for stale-source checking.
                guard objectGlyphs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    == description.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                let target = PDFBodyTextTarget(
                    text: description.text, bounds: description.bounds, style: description.style,
                    objectPath: path, sourcePageID: ObjectIdentifier(page),
                    glyphBounds: description.glyphBounds, baseline: description.baseline,
                    horizontalAdvance: description.horizontalAdvance,
                    leadingWhitespaceAdvance: leadingAdvance(for: description, content: objectGlyphs.map(\.text).joined())
                )
                runs.append(Run(target: target, glyphs: objectGlyphs, description: description))
            }
            runs.sort {
                if abs($0.target.baseline.y - $1.target.baseline.y) > 1 {
                    return $0.target.baseline.y > $1.target.baseline.y
                }
                return $0.target.baseline.x < $1.target.baseline.x
            }
            guard let first = runs.first?.target else { return nil }
            let mixedParents = Set(runs.map { Array($0.target.objectPath.dropLast()) }).count > 1
            let verifiedMixed = mixedParents && mixedLosslessPlan(on: page, nativePage: nativePage,
                originals: runs.map(\.target)) != nil
            if mixedParents && !verifiedMixed { return nil }
            if runs.count > 1, first.objectPath.count > 1, !verifiedMixed {
                guard let last = runs.last?.target,
                      let parent = try resolve(last.objectPath, on: nativePage, requiringFinalLeaf: false).parent,
                      let lastIndex = last.objectPath.last else { return nil }
                let end = Int(FPDFFormObj_CountObjects(parent))
                guard lastIndex < end, ((lastIndex + 1)..<end).allSatisfy({
                    inertPaths.contains(Array(last.objectPath.dropLast()) + [$0])
                }) else { return nil }
            }
            var text = ""
            var utf16Count = 0
            var rangeStart: Int?
            var rangeEnd = 0
            var bounds = first.bounds
            var inkBounds = first.glyphBounds
            var previous: PDFBodyTextTarget?
            var previousDescription: Description?
            var geometry = ParagraphGeometry(first: first)
            var sourceRuns: [InlineTextSourceRun] = []
            var verifiedScaleSource: Bool? = verifiedMixed ? true : nil
            for run in runs {
                let current = run.target
                if !compatibleParagraphStyle(first.style, current.style) {
                    // A saved fallback face can need a wider punctuation run
                    // to retain the source advance. Accept that scale only
                    // after the raw writer proves every selected text/geometry
                    // prefix. Size, colour, alignment and paragraph geometry
                    // still use their original gates.
                    guard compatibleParagraphStyle(first.style, current.style,
                        allowingVerifiedHorizontalScale: true) else { return nil }
                    if verifiedScaleSource == nil {
                        verifiedScaleSource = losslessPlan(on: page, nativePage: nativePage,
                            originals: runs.map(\.target)) != nil
                    }
                    guard verifiedScaleSource == true else { return nil }
                }
                if let previous {
                    // Other objects between the selected runs might paint
                    // over them. Refuse a group instead of changing that order.
                    if !verifiedMixed {
                        guard current.objectPath.dropLast() == previous.objectPath.dropLast(),
                              let currentIndex = current.objectPath.last, let previousIndex = previous.objectPath.last,
                              currentIndex > previousIndex,
                              ((previousIndex + 1)..<currentIndex).allSatisfy({
                                  inertPaths.contains(Array(current.objectPath.dropLast()) + [$0])
                              }) else { return nil }
                    }
                    guard let startsLine = geometry.append(current) else { return nil }
                    if !startsLine {
                        let gap = current.bounds.minX - previous.glyphBounds.maxX
                        guard gap >= -1, gap <= max(12, first.style.fontSize * 1.5) else { return nil }
                        let nativeGap = previousDescription?.ownedAdvance.map {
                            current.baseline.x - previous.baseline.x - $0
                        }
                        let hasInertBoundarySpace = previousDescription?.foreignTrailingWhitespaceLength ?? 0 > 0
                            && text.last?.isWhitespace == false
                            && run.glyphs.first?.text.first?.isWhitespace == false
                            && nativeGap.map { $0.isFinite && $0 > 0 } == true
                            && previous.objectPath.dropLast() == current.objectPath.dropLast()
                            && previous.objectPath.last.map { before in
                                current.objectPath.last.map { after in
                                    after > before && ((before + 1)..<after).contains {
                                        inertPaths.contains(Array(previous.objectPath.dropLast()) + [$0])
                                    }
                                } ?? false
                            } == true
                        // A confirmed native boundary space is meaningful
                        // after punctuation too. Keep the heuristic below
                        // strict for ordinary punctuation side bearings.
                        let addsSpace = hasInertBoundarySpace
                            || needsInferredSpace(before: text, after: run.glyphs.map(\.text).joined(),
                                gap: gap, fontSize: first.style.fontSize)
                        if addsSpace {
                            text += " "
                            utf16Count += 1
                        }
                        // An exact native foreign boundary space can lie
                        // between adjacent words or inert ActualText roots.
                        // Preserve its measured gap in both cases; the preceding
                        // available-font word keeps its original glyph scale.
                        if addsSpace, previousDescription?.foreignTrailingWhitespaceLength ?? 0 > 0,
                           let last = sourceRuns.last, last.horizontalAdvance == nil,
                           let nativeGap, nativeGap.isFinite, nativeGap > 0,
                           previous.objectPath.dropLast() == current.objectPath.dropLast(),
                           let before = previous.objectPath.last, let after = current.objectPath.last,
                           after > before, ((before + 1)..<after).allSatisfy({
                               inertPaths.contains(Array(previous.objectPath.dropLast()) + [$0])
                           }) {
                            sourceRuns.append(InlineTextSourceRun(range: NSRange(location: utf16Count - 1, length: 1),
                                style: last.style, baselineOffset: last.baselineOffset,
                                horizontalAdvance: calibratedBoundarySpaceAdvance(previous: previous,
                                    next: current, last: last, text: text, fallback: nativeGap,
                                    confirmed: true),
                                usesSourceUnkernedAdvances: last.usesSourceUnkernedAdvances))
                        } else {
                            preserveAdvance(to: current.baseline.x, from: previous,
                                extendingForSpace: addsSpace, in: &sourceRuns)
                        }
                    } else {
                        text += "\n"
                        utf16Count += 1
                    }
                }
                let runStart = utf16Count
                for glyph in run.glyphs {
                    let offset = utf16Count
                    text += glyph.text
                    utf16Count += glyph.text.utf16.count
                    if glyph.selected {
                        if rangeStart == nil { rangeStart = offset }
                        rangeEnd = utf16Count
                    }
                }
                let content = (text as NSString).substring(with: NSRange(location: runStart, length: utf16Count - runStart))
                sourceRuns += Self.sourceRuns(for: run.description, content: content, offset: runStart,
                    baselineOffset: current.baseline.y - geometry.lineBaseline.y)
                bounds = bounds.union(current.bounds)
                inkBounds = inkBounds.union(current.glyphBounds)
                previous = current
                previousDescription = run.description
            }
            guard let start = rangeStart, rangeEnd > start,
                  !InlineTextDraftLimiter.limit(text).wasTruncated else { return nil }
            let selectedRange = NSRange(location: start, length: rangeEnd - start)
            guard selectionKey((text as NSString).substring(with: selectedRange)) == selectionKey(selectedText) else {
                return nil
            }
            var target = PDFBodyTextTarget(text: text, bounds: bounds, style: first.style,
                objectPath: first.objectPath, sourcePageID: first.sourcePageID,
                glyphBounds: inkBounds, baseline: first.baseline)
            // Keep every original descriptor, including the first, for the
            // stale-source check. The aggregate's text/bounds are editor data.
            if runs.count > 1 || first.text != text { target.additionalObjects = runs.map(\.target) }
            target.lineHeight = geometry.lineHeight
            target.firstLineIndent = geometry.firstLineIndent
            target.sourceRuns = sourceRuns
            target.initialSelectedRange = selectedRange
            try validateEditingRoute(page, nativePage: nativePage, originals: runs.map(\.target))
            return try declaredPaintTarget(target, on: page, nativePage: nativePage,
                textPage: textPage, characterCount: count)?.target
        }
    }

    private struct OutlinedResolution {
        var target: PDFBodyTextTarget?
        var bounds: [Int: [CGRect]] = [:]
        var names: [Int: String] = [:]
    }

    /// Only the complete, independently verified app-owned outline Form may
    /// bypass the ordinary visible-text leaf guards. Its native Unicode must
    /// exactly match the marker, and every painted clip stays in its erasures.
    private static func outlinedTarget(on page: PDFPage, selection: PDFSelection?, point: CGPoint?,
                                       nativePage: FPDF_PAGE, textPage: FPDF_TEXTPAGE,
                                       characterCount: Int32, snapshot: Data) throws -> OutlinedResolution {
        let rootCount = Int(FPDFPage_CountObjects(nativePage))
        guard rootCount >= 0, rootCount <= maximumObjects else { throw Failure.tooComplex }
        guard (0..<rootCount).contains(where: {
            FPDFPage_GetObject(nativePage, Int32($0)).map { FPDFPageObj_GetType($0) == FPDF_PAGEOBJ_FORM } ?? false
        }), let reference = page.pageRef,
              let content = try? PDFBodyTextPageSnapshot.contentData(for: page),
              let stream = try? PDFBodyTextContentStream.parse(content) else { return OutlinedResolution() }
        let fragments = selection?.selectionsByLine().map { $0.bounds(for: page) } ?? []
        var resolution = OutlinedResolution()
        var seenIDs = Set<UUID>(), ownedCount = 0
        let media = page.bounds(for: .mediaBox)

        struct NativeGlyph { let scalar: UnicodeScalar; let bounds: CGRect }
        func glyph(at index: Int32) -> NativeGlyph? {
            guard let raw = UnicodeScalar(FPDFText_GetUnicode(textPage, index)), raw.value != 0 else { return nil }
            let scalar = raw.value == 2 && FPDFText_IsHyphen(textPage, index) == 1 ? UnicodeScalar(45)! : raw
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar), FPDFText_IsGenerated(textPage, index) == 0 else { return nil }
            var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0, x = 0.0, y = 0.0
            var transform = FS_MATRIX()
            guard FPDFText_GetCharBox(textPage, index, &left, &right, &bottom, &top) != 0,
                  FPDFText_GetCharOrigin(textPage, index, &x, &y) != 0,
                  FPDFText_GetMatrix(textPage, index, &transform) != 0,
                  [left, right, bottom, top, x, y].allSatisfy(\.isFinite),
                  [transform.a, transform.b, transform.c, transform.d].allSatisfy(\.isFinite),
                  transform.a > 0, transform.d > 0, abs(transform.b) < 0.001, abs(transform.c) < 0.001 else { return nil }
            let size = CGFloat(FPDFText_GetFontSize(textPage, index)) * CGFloat(transform.d)
            guard size > 0, size <= 1_000_000, right > left else { return nil }
            let box = top - bottom < 0.1
                ? CGRect(x: left, y: y - Double(size) * 0.25, width: right - left, height: Double(size) * 1.25)
                : CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
            guard valid(box) else { return nil }
            return NativeGlyph(scalar: scalar, bounds: box)
        }
        func ambiguous(_ boxes: [(CGRect, Bool)]) -> Bool {
            var active: [(CGRect, Bool)] = [], comparisons = 0
            for cell in boxes.sorted(by: { $0.0.minX < $1.0.minX }) {
                active.removeAll { $0.0.maxX <= cell.0.minX }
                for other in active where cell.1 || other.1 {
                    comparisons += 1
                    guard comparisons <= 500_000 else { return true }
                    let overlap = other.0.intersection(cell.0)
                    if !overlap.isNull,
                       overlap.width > min(other.0.width, cell.0.width) * 0.45,
                       overlap.height > min(other.0.height, cell.0.height) * 0.65 { return true }
                }
                active.append(cell)
            }
            return false
        }

        for invocation in stream.forms {
            guard let raw = PDFBodyTextPageSnapshot.outlinedOCRMetadata(named: invocation.name, on: page) else { continue }
            ownedCount += 1
            guard ownedCount <= 64 else { throw Failure.tooComplex }
            // An invalid marker does not earn a narrowed protected region.
            // The ordinary scanner will retain that foreign Form's raw bounds.
            guard let metadata = try? PDFOutlinedOCRMetadata.decode(raw) else { continue }
            let candidate = point.map { metadata.bounds.insetBy(dx: -2, dy: -2).contains($0) }
                ?? fragments.contains { $0.intersects(metadata.bounds) }
            do {
                guard seenIDs.insert(metadata.id).inserted, invocation.isSupported, valid(metadata.bounds),
                      metadata.erasedRects.allSatisfy({ media.insetBy(dx: -0.1, dy: -0.1).contains($0) }),
                      losslessGraphicsStateIsSupported(invocation.graphicsStateNames, on: page),
                      PDFBodyTextPageSnapshot.isBodyTextXObject(named: invocation.name, on: page),
                      try PDFBodyFormUsageAudit().isFormInvokedExactlyOnce(named: invocation.name, on: reference) else { throw Failure.unsupported }
                let before = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: Data(content.prefix(invocation.showRange.lowerBound)))
                let rootIndex = try withPage(before) { _, prefix in Int(FPDFPage_CountObjects(prefix)) }
                let after = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: Data(content.prefix(invocation.insertionOffset)))
                guard rootIndex >= 0, rootIndex < rootCount,
                      try withPage(after, body: { _, prefix in Int(FPDFPage_CountObjects(prefix)) == rootIndex + 1 }),
                      let form = FPDFPage_GetObject(nativePage, Int32(rootIndex)),
                      let artwork = PDFOutlinedOCRArtwork.inspect(form, metadata: metadata, mediaBox: media),
                      abs(artwork.transform.a - invocation.transform.a) < 0.001,
                      abs(artwork.transform.d - invocation.transform.d) < 0.001,
                      abs(artwork.transform.tx - invocation.transform.tx) < 0.05,
                      abs(artwork.transform.ty - invocation.transform.ty) < 0.05 else { throw Failure.unsupported }
                var glyphs: [NativeGlyph] = [], cells: [(CGRect, Bool)] = []
                for index in 0..<characterCount {
                    guard let object = FPDFText_GetTextObject(textPage, index) else { continue }
                    let owned = artwork.textObjects.contains(object)
                    let raw = FPDFText_GetUnicode(textPage, index)
                    if owned, let scalar = UnicodeScalar(raw), !CharacterSet.whitespacesAndNewlines.contains(scalar), raw != 0 {
                        guard let value = glyph(at: index) else { throw Failure.unsupported }
                        glyphs.append(value); cells.append((value.bounds, true))
                    } else if let value = glyph(at: index), value.bounds.intersects(metadata.bounds) {
                        cells.append((value.bounds, false))
                    }
                }
                var offsets: [(scalar: UnicodeScalar, range: NSRange)] = []
                var offset = 0
                for scalar in metadata.text.unicodeScalars {
                    let length = scalar.value > 0xFFFF ? 2 : 1
                    if !CharacterSet.whitespacesAndNewlines.contains(scalar) { offsets.append((scalar, NSRange(location: offset, length: length))) }
                    offset += length
                }
                guard glyphs.count == offsets.count, zip(glyphs, offsets).allSatisfy({ $0.scalar == $1.scalar }),
                      !ambiguous(cells) else { throw Failure.unsupported }
                resolution.bounds[rootIndex] = artwork.bounds
                resolution.names[rootIndex] = invocation.name
                guard candidate else { continue }
                let selected = glyphs.indices.filter { index in
                    if let point { return glyphs[index].bounds.insetBy(dx: -1.5, dy: -1.5).contains(point) }
                    let box = glyphs[index].bounds
                    return fragments.contains { $0.insetBy(dx: -0.2, dy: -0.2).contains(CGPoint(x: box.midX, y: box.midY)) }
                }
                guard let first = selected.first, let last = selected.last else { continue }
                let range = NSRange(location: offsets[first].range.location,
                                    length: NSMaxRange(offsets[last].range) - offsets[first].range.location)
                if let selection,
                   selectionKey((metadata.text as NSString).substring(with: range)) != selectionKey(selection.string ?? "") {
                    throw Failure.unsupported
                }
                guard resolution.target == nil else { throw Failure.unsupported }
                var result = PDFBodyTextTarget(text: metadata.text, bounds: metadata.bounds, style: metadata.style,
                    objectPath: [], sourcePageID: ObjectIdentifier(page), glyphBounds: metadata.bounds,
                    baseline: metadata.baseline)
                result.lineHeight = metadata.lineHeight; result.firstLineIndent = metadata.firstLineIndent
                result.sourceRuns = metadata.sourceRuns; result.initialSelectedRange = selection == nil ? nil : range
                result.outlinedSource = PDFOutlinedOCRSource(snapshot: snapshot, metadata: metadata,
                    resourceName: invocation.name, formRootIndex: rootIndex, showRange: invocation.showRange,
                    insertionOffset: invocation.insertionOffset, transform: invocation.transform)
                resolution.target = result
            } catch {
                if candidate { throw error }
            }
        }
        return resolution
    }

    /// A tagged line may store each word and logical space in separate native
    /// objects. Treat its complete BT/ET group as one editable run, so removing
    /// a show never changes the advance of an unselected following word.
    private static func wholeBlockTarget(on page: PDFPage, nativePage: FPDF_PAGE,
                                         textPage: FPDF_TEXTPAGE, characterCount: Int32,
                                         selectedRoots: Set<Int>, selection: PDFSelection?) throws -> PDFBodyTextTarget? {
        guard !selectedRoots.isEmpty, page.bounds(for: .mediaBox).origin == .zero,
              let stream = try? PDFBodyTextContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: page)) else { return nil }
        let rootCount = Int(FPDFPage_CountObjects(nativePage))
        guard rootCount >= 0, rootCount <= maximumObjects else { return nil }
        let textRoots = (0..<rootCount).filter {
            FPDFPage_GetObject(nativePage, Int32($0)).map { FPDFPageObj_GetType($0) == FPDF_PAGEOBJ_TEXT } ?? false
        }
        guard textRoots.count == stream.records.count else { return nil }
        let recordByRoot = Dictionary(uniqueKeysWithValues: textRoots.enumerated().map { ($0.element, $0.offset) })
        var scopedRoots = selectedRoots
        let selectedLines = selection?.selectionsByLine().filter { !$0.bounds(for: page).isEmpty } ?? []
        if selectedLines.count > 1, let firstRoot = selectedRoots.min(), firstRoot > 0,
           let firstObject = FPDFPage_GetObject(nativePage, Int32(firstRoot)),
           var next = try? describe(firstObject, in: textPage, characterCount: characterCount) {
            // A saved paragraph may become one BT per word. A drag beginning
            // mid-line still needs that line's true origin to distinguish a
            // paragraph indent from a separate column. Include only adjacent,
            // compatible text on the same baseline; retain the original drag
            // range when selecting text in the editor.
            for root in stride(from: firstRoot - 1, through: max(0, firstRoot - 256), by: -1) {
                guard let object = FPDFPage_GetObject(nativePage, Int32(root)),
                      FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT,
                      let record = recordByRoot[root],
                      let block = stream.blocks.first(where: { $0.showRanges.contains(stream.records[record].showRange) }),
                      block.isSupported else { break }
                if FPDFTextObj_GetText(object, textPage, nil, 0) <= 2, hasEmptyInkBounds(object) {
                    scopedRoots.insert(root)
                    continue
                }
                guard let previous = try? describe(object, in: textPage, characterCount: characterCount),
                      compatibleParagraphStyle(next.style, previous.style),
                      abs(previous.baseline.y - next.baseline.y) <= 1,
                      previous.baseline.x < next.baseline.x,
                      next.glyphBounds.minX - previous.glyphBounds.maxX >= -1,
                      next.glyphBounds.minX - previous.glyphBounds.maxX <= max(12, next.style.fontSize * 1.5) else { break }
                scopedRoots.insert(root)
                next = previous
            }
        }
        let selectedRanges = scopedRoots.compactMap { recordByRoot[$0].map { stream.records[$0].showRange } }
        guard selectedRanges.count == scopedRoots.count else { return nil }
        var indices = stream.blocks.indices.filter { index in
            stream.blocks[index].showRanges.contains { selectedRanges.contains($0) }
        }
        guard !indices.isEmpty, indices.count <= 256 else { return nil }
        // Semantic/visibility scopes must not fall through to regeneration,
        // which cannot preserve their meaning even on otherwise simple pages.
        guard indices.allSatisfy({ stream.blocks[$0].isSupported }) else { throw Failure.unsupported }
        var ranges = Set(indices.flatMap { stream.blocks[$0].showRanges })
        var roots = textRoots.enumerated().compactMap { ranges.contains(stream.records[$0.offset].showRange) ? $0.element : nil }
        var bridgedEmptyRuns = false
        if let first = roots.first, let last = roots.last {
            let covered = Set(roots)
            // PDFKit can flatten our saved Form into one BT per word and
            // another zero-ink object for each space. PDFium reports that
            // space on the preceding word, leaving the space object unselected.
            // Include only proven empty text objects between selected runs;
            // their original graphics/text state stays in the source stream.
            for root in first...last where !covered.contains(root) {
                guard let object = FPDFPage_GetObject(nativePage, Int32(root)),
                      FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT,
                      FPDFTextObj_GetText(object, textPage, nil, 0) <= 2,
                      hasEmptyInkBounds(object), let record = recordByRoot[root],
                      let block = stream.blocks.indices.first(where: {
                          stream.blocks[$0].showRanges.contains(stream.records[record].showRange)
                      }), stream.blocks[block].isSupported else { return nil }
                indices.append(block)
                bridgedEmptyRuns = true
            }
        }
        // Keep ordinary glyph selection unless fragmented/tagged content or
        // proven empty intervening runs require complete block replacement.
        guard bridgedEmptyRuns || scopedRoots != selectedRoots || selectedRoots.contains(where: { root in
            recordByRoot[root].map { !stream.records[$0].isSupported } ?? false
        }) else { return nil }
        indices = Array(Set(indices)).sorted()
        guard indices.count <= 256 else { return nil }
        ranges = Set(indices.flatMap { stream.blocks[$0].showRanges })
        roots = textRoots.enumerated().compactMap { ranges.contains(stream.records[$0.offset].showRange) ? $0.element : nil }
        guard !roots.isEmpty, roots.count <= 1_024,
              Set(roots).isSuperset(of: selectedRoots),
              roots == Array(roots.first!...roots.last!) else { return nil }
        var characterIndices: [FPDF_PAGEOBJECT: [Int32]] = [:]
        for index in 0..<characterCount {
            if let object = FPDFText_GetTextObject(textPage, index) { characterIndices[object, default: []].append(index) }
        }
        var originals: [PDFBodyTextTarget] = []
        var text = ""
        var bounds = CGRect.null
        var glyphBounds = CGRect.null
        var geometry: ParagraphGeometry?
        var sourceRuns: [InlineTextSourceRun] = []
        var selectedRunRange: NSRange?
        var previousDescription: Description?
        for root in roots {
            guard let object = FPDFPage_GetObject(nativePage, Int32(root)) else { return nil }
            // ActualText spaces can be represented by an empty native object.
            // The stream rewrite still removes its encoded show and markup.
            let length = FPDFTextObj_GetText(object, textPage, nil, 0)
            if length <= 2 {
                guard hasEmptyInkBounds(object) else { throw Failure.unsupported }
                continue
            }
            let description = try describe(object, in: textPage, characterCount: characterCount,
                characterIndices: characterIndices[object])
            if description.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard hasEmptyInkBounds(object) else { throw Failure.unsupported }
                continue
            }
            if let first = originals.first, let previous = originals.last {
                guard compatibleParagraphStyle(first.style, description.style),
                      let startsLine = geometry?.append(baseline: description.baseline, fontSize: first.style.fontSize) else { return nil }
                if !startsLine {
                    let gap = description.glyphBounds.minX - previous.glyphBounds.maxX
                    guard gap >= -1, gap <= max(12, first.style.fontSize * 1.5) else { return nil }
                    let addsSpace = needsInferredSpace(before: text, after: description.text,
                        gap: gap, fontSize: first.style.fontSize)
                    if addsSpace { text += " " }
                    if !preserveForeignBoundarySpace(from: previousDescription, to: description,
                                                     in: &sourceRuns) {
                        preserveAdvance(to: description.baseline.x, from: previous,
                            extendingForSpace: addsSpace, in: &sourceRuns)
                    }
                } else {
                    text += "\n"
                }
            }
            let offset = (text as NSString).length
            text += description.text
            if selectedRoots.contains(root) {
                let run = NSRange(location: offset, length: (description.text as NSString).length)
                selectedRunRange = selectedRunRange.map { NSUnionRange($0, run) } ?? run
            }
            originals.append(PDFBodyTextTarget(text: description.text, bounds: description.bounds,
                style: description.style, objectPath: [root], sourcePageID: ObjectIdentifier(page),
                glyphBounds: description.glyphBounds, baseline: description.baseline,
                horizontalAdvance: description.horizontalAdvance,
                leadingWhitespaceAdvance: leadingAdvance(for: description, content: description.text)))
            if geometry == nil { geometry = ParagraphGeometry(first: originals[0]) }
            sourceRuns += Self.sourceRuns(for: description, content: description.text, offset: offset,
                baselineOffset: description.baseline.y - geometry!.lineBaseline.y)
            previousDescription = description
            bounds = bounds.union(description.bounds)
            glyphBounds = glyphBounds.union(description.glyphBounds)
        }
        guard let first = originals.first, !InlineTextDraftLimiter.limit(text).wasTruncated,
              let selectedRunRange else { return nil }
        var selectedRange = selectedRunRange
        if let selection {
            guard let selectedText = selection.string,
                  let range = matchingRange(of: selectedText, in: text, within: selectedRunRange) else { throw Failure.unsupported }
            selectedRange = range
        }
        var target = PDFBodyTextTarget(text: text, bounds: bounds, style: first.style,
            objectPath: first.objectPath, sourcePageID: ObjectIdentifier(page),
            glyphBounds: glyphBounds, baseline: first.baseline)
        target.additionalObjects = originals
        target.initialSelectedRange = selectedRange
        target.lineHeight = geometry?.lineHeight
        target.firstLineIndent = geometry?.firstLineIndent ?? 0
        target.sourceRuns = sourceRuns
        target.textBlockIndices = indices
        target.textBlockSource = stream.data
        return try declaredPaintTarget(target, on: page, nativePage: nativePage,
            textPage: textPage, characterCount: characterCount)?.target
    }

    /// Geometry only: plan was independently bound by native before/after
    /// prefixes. The private withPage scope supplies that exact native owner's
    /// immutable canonical snapshot, never a caller-selected file or bool.
    private static func exactOriginalGlyphInk(plan: LosslessPlan, originals: [PDFBodyTextTarget],
        page: PDFPage, nativePage: FPDF_PAGE, textPage: FPDF_TEXTPAGE) throws -> CGRect? {
        guard originals.count == 1, let original = originals.first,
              !plan.replacesBlocks, plan.mixedFormIndices.isEmpty, plan.recordIndices.count == 1,
              let ordinal = plan.recordIndices.first,
              let snapshot = EmbeddedSourceFonts.originalInkSnapshot(for: nativePage) else { return nil }
        let object = try resolve(original.objectPath, on: nativePage, requiringFinalLeaf: false).object
        let formName: String?, showRange: Range<Int>?
        if plan.replacesForm {
            guard original.objectPath.count == 2, original.objectPath.last == 0,
                  let root = original.objectPath.first,
                  let form = FPDFPage_GetObject(nativePage, Int32(root)),
                  FPDFFormObj_CountObjects(form) == 1, let reference = page.pageRef,
                  try PDFBodyFormUsageAudit().hasSafeUnclippedTextForm(
                    named: plan.stream.forms[ordinal].name, on: reference) else { return nil }
            formName = plan.stream.forms[ordinal].name; showRange = nil
        } else {
            guard original.objectPath.count == 1 else { return nil }
            formName = nil; showRange = plan.stream.records[ordinal].showRange
        }
        return try PDFBodyTextOriginalGlyphInk.envelope(snapshot: snapshot,
            sourceContent: plan.stream.data, showRange: showRange, sourceFormName: formName,
            expectedText: original.text, nativeObject: object, nativeTextPage: textPage,
            invocation: plan.transform)
    }

    /// A local declaration result; selection callers expose only `target`.
    /// The verified plan stays inside one immutable native page operation; it
    /// never enters a persisted draft or survives a page mutation.
    private struct PaintDeclaration {
        let target: PDFBodyTextTarget
        let verifiedPlan: LosslessPlan?
        let observation: PDFBodyTextFitDiagnostics.PaintObservation?
    }

    /// Capture the source's ink and verified blank row space before the user
    /// edits. A marker only suggests an old extent: the existing unique/native
    /// donor proof and current obstacle clearance must independently accept it.
    private static func declaredPaintTarget(_ input: PDFBodyTextTarget, on page: PDFPage,
                                           nativePage: FPDF_PAGE, textPage: FPDF_TEXTPAGE,
                                           characterCount: Int32) throws -> PaintDeclaration? {
        try Task.checkCancellation()
        guard characterCount >= 0, characterCount <= maximumPageCharacters else { throw Failure.tooComplex }
        var target = input
        var source = input.bounds.union(input.glyphBounds)
        let visible = page.bounds(for: .mediaBox).intersection(page.bounds(for: .cropBox))
        guard valid(source), valid(visible), visible.contains(source) else { throw Failure.unsupported }
        let originals = input.additionalObjects.isEmpty ? [input] : input.additionalObjects
        let selected = try Set(originals.map {
            try resolve($0.objectPath, on: nativePage, requiringFinalLeaf: false).object
        })
        let roots = Set(originals.compactMap { $0.objectPath.first })
        let plan: LosslessPlan?
        if let blocks = input.textBlockIndices {
            // Rebind the complete BT/ET route once to this current immutable
            // withPage scope. Indices or a saved source marker grant no proof.
            let current = try PDFBodyTextPageSnapshot.contentData(for: page)
            guard input.textBlockSource == current,
                  let verified = try wholeBlockPlan(on: page, nativePage: nativePage,
                    blockIndices: blocks, originals: originals,
                    parsedStream: PDFBodyTextContentStream.parse(current)) else { return nil }
            plan = verified
        } else {
            plan = losslessPlan(on: page, nativePage: nativePage, originals: originals)
        }
        let observedPlan: PDFBodyTextFitDiagnostics.PaintPlan
        if let plan {
            observedPlan = plan.replacesBlocks ? .wholeBlock
                : (plan.replacesForm ? .ownForm : (plan.mixedFormIndices.isEmpty ? .shows : .mixed))
        } else { observedPlan = .missing }
        var observation = PDFBodyTextFitDiagnostics.beginPaintObservation(
            plan: observedPlan, selectedObjects: selected.count)
        // Only the existing native-prefix-bound raw show can contribute a
        // source glyph envelope. No inferred font name or fit tolerance.
        if let plan, let exact = try exactOriginalGlyphInk(plan: plan, originals: originals,
            page: page, nativePage: nativePage, textPage: textPage), visible.contains(exact) {
            source = source.union(exact)
        }
        if let plan, plan.replacesForm, plan.recordIndices.count == 1,
           let ordinal = plan.recordIndices.first,
           let raw = PDFBodyTextPageSnapshot.scannedErasureMetadata(
                named: plan.stream.forms[ordinal].name, on: page) {
            do {
                let metadata = try PDFScannedErasureMetadata.decode(raw)
                let record = plan.stream.forms[ordinal]
                // The preceding lossless plan independently binds every native
                // text child, this exact sole invocation and its graphics state.
                // The marker/digest alone never bypasses an image obstacle.
                let envelope = PDFScannedBodyTextEditor.Source(snapshot: Data(), rootIndices: [],
                    erasedRects: metadata.erasedRects, paperColor: metadata.paperColor)
                if let root = originals.first?.objectPath.first,
                   let form = FPDFPage_GetObject(nativePage, Int32(root)),
                   let reference = page.pageRef,
                   try PDFBodyFormUsageAudit().hasSafeScannedErasureResources(on: reference),
                   losslessGraphicsStateIsSupported(record.graphicsStateNames, on: page),
                   try PDFBodyFormUsageAudit().hasSafeUnclippedTextForm(named: record.name, on: reference),
                   try PDFScannedBodyTextEditor.currentTextFormFits(form, on: nativePage,
                       source: envelope, independentlyUnclipped: true),
                   try metadata.provesCurrentProgram(plan.stream.data,
                    mediaBox: page.bounds(for: .mediaBox), donorName: record.name, donorRange: record.showRange) {
                    target.scannedReeditMetadata = metadata
                    target.declaredPaintBounds = metadata.bounds
                    observation?.finish(source: source, declared: metadata.bounds, savedExtent: true)
                    return PaintDeclaration(target: target, verifiedPlan: plan, observation: observation)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Unknown/changed evidence retains the ordinary obstacle checks. */ }
        }
        var savedExtent: CGRect?
        if let plan, plan.replacesForm, let record = plan.recordIndices.first,
           let saved = try PDFBodyTextPageSnapshot.bodyTextLayoutBounds(named: plan.stream.forms[record].name, on: page) {
            let matrix = plan.stream.forms[record].transform
            guard [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].allSatisfy(\.isFinite),
                  matrix.a > 0, matrix.d > 0, abs(matrix.b) < 0.000001, abs(matrix.c) < 0.000001 else {
                throw Failure.unsupported
            }
            let transformed = saved.applying(matrix)
            guard let clipped = savedPaintExtent(transformed, within: visible, containing: input.glyphBounds) else {
                throw Failure.unsupported
            }
            savedExtent = clipped
        }
        var otherText: [CGRect] = []
        for index in 0..<characterCount {
            if index % 256 == 0 { try Task.checkCancellation() }
            let scalar = FPDFText_GetUnicode(textPage, index)
            if scalar == 0 || scalar == 9 || scalar == 10 || scalar == 13 || scalar == 32 { continue }
            guard let object = FPDFText_GetTextObject(textPage, index) else { throw Failure.unreadable }
            if selected.contains(object) { continue }
            var l = 0.0, r = 0.0, b = 0.0, t = 0.0
            guard FPDFText_GetCharBox(textPage, index, &l, &r, &b, &t) != 0 else { throw Failure.unreadable }
            let ink = CGRect(x: l, y: b, width: r - l, height: t - b)
            guard valid(ink) else { throw Failure.unsupported }
            // One object may cross columns/rows. Its union would incorrectly
            // mark the untouched space between those glyphs as occupied.
            if !ink.isEmpty, ink.intersects(visible) { otherText.append(ink) }
        }
        var otherPaint: [CGRect] = []
        var underlayCoverage: CGRect?
        let count = Int(FPDFPage_CountObjects(nativePage))
        guard count >= 0, count <= maximumObjects else { throw Failure.tooComplex }
        var occlusionAudit: PDFBodyFormUsageAudit?
        var occlusionAuditCompleted = false
        func auditOcclusion() -> PDFBodyFormUsageAudit? {
            if occlusionAuditCompleted { return occlusionAudit }
            occlusionAuditCompleted = true
            let audit = PDFBodyFormUsageAudit(visibleClipBox: visible)
            guard let reference = page.pageRef, (try? audit.hasRepeatedForm(on: reference)) != nil else {
                observation?.unavailableAudit()
                return nil
            }
            observation?.observedAudit(nestedUnsafe: audit.hasUnsafeNestedCompositing,
                unsupportedPaint: audit.hasUnsupportedPaint, occlusionUnsafe: audit.hasOcclusionUnsafePaint,
                explicitClip: audit.hasExplicitClipping, textClip: audit.hasTextClipping,
                pageClipsOnly: audit.hasOnlyPageCoveringClips)
            occlusionAudit = audit
            return audit
        }
        for index in 0..<count {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard let object = FPDFPage_GetObject(nativePage, Int32(index)) else { throw Failure.unreadable }
            let objectType = FPDFPageObj_GetType(object)
            if objectType == FPDF_PAGEOBJ_TEXT { continue }
            if observation != nil, let first = roots.min(), index < first { observation?.increment(.precedingPaint) }
            // Omit only complete text-only own donors already bound by the
            // lossless prefix proof. A mixed paragraph has the same proof for
            // its selected donor roots even though it also retains root text.
            // Arbitrary selected Forms still constrain clearance as artwork.
            if let plan, roots.contains(index),
               plan.replacesForm || plan.verifiedMixedTextFormRoots.contains(index) {
                observation?.increment(.selectedFormsOmitted)
                continue
            }
            // The existing lossless prefix proof fixes the donor before this
            // later root. Only a proved opaque overlapping rectangle can hide
            // new ink without turning arbitrary artwork into blank clearance.
            if plan != nil, let audit = auditOcclusion(), !audit.hasUnsafeNestedCompositing {
                if let last = roots.max(), index > last, !audit.hasUnsupportedPaint, !audit.hasOcclusionUnsafePaint, !audit.hasExplicitClipping, !audit.hasTextClipping,
                   let cover = opaqueRootRectangle(object, independentlyUnclipped: true),
                   cover.intersects(source) {
                    observation?.increment(.laterOpaqueAccepted)
                    continue
                }
                // Uniform opaque paint before the selected root supplies a
                // bounded background, not a page-wide blank-space assumption.
                // Every native clip must cover the source declaration. All
                // other glyphs/artwork still constrain the clearance below.
                let required = source
                if let first = roots.min(), index < first,
                   !audit.hasOcclusionUnsafePaint, !audit.hasTextClipping {
                    observation?.increment(.underlayEligible)
                    if let cover = opaqueRootRectangle(object,
                        independentlyUnclipped: !audit.hasExplicitClipping || audit.hasOnlyPageCoveringClips,
                        containingClips: required) {
                        observation?.increment(.underlayRectangleAccepted)
                        if cover.contains(required) {
                            observation?.increment(.underlayAccepted)
                            let coverage = cover.intersection(visible)
                            underlayCoverage = underlayCoverage.map { $0.intersection(coverage) } ?? coverage
                            continue
                        }
                    }
                }
            }
            var l: Float = 0, b: Float = 0, r: Float = 0, t: Float = 0
            guard FPDFPageObj_GetBounds(object, &l, &b, &r, &t) != 0 else { throw Failure.unreadable }
            let box = CGRect(x: CGFloat(l), y: CGFloat(b), width: CGFloat(r - l), height: CGFloat(t - b))
            guard valid(box) else { throw Failure.unsupported }
            if !box.isEmpty, box.intersects(visible) {
                otherPaint.append(box)
                switch objectType {
                case FPDF_PAGEOBJ_PATH: observation?.increment(.otherPaths)
                case FPDF_PAGEOBJ_IMAGE: observation?.increment(.otherImages)
                case FPDF_PAGEOBJ_FORM: observation?.increment(.otherForms)
                case FPDF_PAGEOBJ_SHADING: observation?.increment(.otherShadings)
                default: observation?.increment(.otherUnknown)
                }
            }
        }
        // Declare clearance from the unchanged source in every direction.
        // Prefer row boundaries for diagonal neighbours, retaining natural
        // single-line width; same-row neighbours bound the left/right edges.
        let clearance = underlayCoverage ?? visible
        var left = clearance.minX, right = clearance.maxX
        var bottom = clearance.minY, top = clearance.maxY
        for (index, obstacle) in (otherText + otherPaint).enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            let previousEdges = (left, bottom, right, top)
            if obstacle.intersects(source) {
                observation?.increment(index < otherText.count ? .overlappingOtherText : .overlappingOtherPaint)
                // Existing overlap cannot prove blank paper. Retain the old
                // source area, but grant no expansion into this object's ink.
                if obstacle.minX < source.minX { left = max(left, source.minX) }
                if obstacle.maxX > source.maxX { right = min(right, source.maxX) }
                if obstacle.minY < source.minY { bottom = max(bottom, source.minY) }
                if obstacle.maxY > source.maxY { top = min(top, source.maxY) }
            } else if obstacle.minY >= source.maxY {
                top = min(top, obstacle.minY)
            } else if obstacle.maxY <= source.minY {
                bottom = max(bottom, obstacle.maxY)
            } else if obstacle.minX >= source.maxX {
                right = min(right, obstacle.minX)
            } else if obstacle.maxX <= source.minX {
                left = max(left, obstacle.maxX)
            } else { throw Failure.unsupported }
            observation?.clamped(left: left != previousEdges.0, bottom: bottom != previousEdges.1,
                right: right != previousEdges.2, top: top != previousEdges.3)
        }
        let free = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        // A paragraph donor may retain only the changed rows while its old
        // declaration still spans the whole paragraph. On a later selection,
        // unchanged rows are independent obstacles. Narrow the saved extent
        // to independently proved current clearance, never enlarge it or
        // authorize painting through the retained text.
        let declared = savedExtent.map { $0.intersection(free) } ?? free
        guard valid(free), valid(declared), visible.contains(declared), free.contains(declared),
              declared.contains(input.glyphBounds) else { throw Failure.unsupported }
        // Unknown images/shapes never authorize expansion.
        for obstacle in otherPaint where obstacle.intersects(declared) {
            guard source.contains(obstacle.intersection(declared)) else { throw Failure.unsupported }
        }
        target.declaredPaintBounds = declared
        target.protectedPaintBounds = otherText.filter { $0.intersects(declared) }
        observation?.finish(source: source, declared: declared, savedExtent: savedExtent != nil)
        return PaintDeclaration(target: target, verifiedPlan: plan,
            observation: observation)
    }

    /// Native geometry is only an occlusion hint after the independent
    /// lossless order proof. No clipping, stroke, transparency or curved path.
    private static func opaqueRootRectangle(_ object: FPDF_PAGEOBJECT, independentlyUnclipped: Bool, containingClips required: CGRect? = nil) -> CGRect? {
        guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_PATH,
              FPDFPageObj_HasTransparency(object) == 0 else { return nil }
        var clipCoverage: CGRect?
        if let clip = FPDFPageObj_GetClipPath(object) {
            let count = FPDFClipPath_CountPaths(clip)
            // -1 alone proves nothing. The alternate proof scans every invoked
            // stream: no clipping, or only identity-root rectangles containing
            // the complete visible page. Text clipping is checked separately.
            if count == -1 { guard independentlyUnclipped else { return nil } }
            else {
                guard count >= 0, count <= 16 else { return nil }
                if count > 0 {
                    guard let required else { return nil }
                    for path in 0..<count {
                        let count = FPDFClipPath_CountPathSegments(clip, path)
                        guard let bounds = axisRectangle(count: count, transform: .identity,
                            segment: { FPDFClipPath_GetPathSegment(clip, path, $0) }),
                              bounds.contains(required) else { return nil }
                        clipCoverage = clipCoverage.map { $0.intersection(bounds) } ?? bounds
                    }
                }
            }
        } else { guard independentlyUnclipped else { return nil } }
        var fill: Int32 = 0, stroke: FPDF_BOOL = 0
        var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 0
        var matrix = FS_MATRIX()
        guard FPDFPath_GetDrawMode(object, &fill, &stroke) != 0,
              [FPDF_FILLMODE_ALTERNATE, FPDF_FILLMODE_WINDING].contains(fill), stroke == 0,
              FPDFPageObj_GetFillColor(object, &red, &green, &blue, &alpha) != 0, alpha == 255,
              FPDFPageObj_GetMatrix(object, &matrix) != 0,
              [matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f].allSatisfy(\.isFinite),
              matrix.a != 0, matrix.d != 0, matrix.b == 0, matrix.c == 0 else { return nil }
        guard let fillBounds = axisRectangle(count: FPDFPath_CountSegments(object),
            transform: CGAffineTransform(a: CGFloat(matrix.a), b: CGFloat(matrix.b),
                c: CGFloat(matrix.c), d: CGFloat(matrix.d), tx: CGFloat(matrix.e), ty: CGFloat(matrix.f)),
            segment: { FPDFPath_GetPathSegment(object, $0) }) else { return nil }
        let coverage = clipCoverage.map { fillBounds.intersection($0) } ?? fillBounds
        return valid(coverage) && !coverage.isEmpty ? coverage : nil
    }

    private static func axisRectangle(count: Int32, transform: CGAffineTransform,
                                      segment: (Int32) -> FPDF_PATHSEGMENT?) -> CGRect? {
        guard count == 4 || count == 5 else { return nil }
        var points: [CGPoint] = []
        for index in 0..<count {
            guard let segment = segment(index),
                  FPDFPathSegment_GetType(segment) == (index == 0 ? FPDF_SEGMENT_MOVETO : FPDF_SEGMENT_LINETO),
                  (FPDFPathSegment_GetClose(segment) != 0) == (index == count - 1) else { return nil }
            var x: Float = 0, y: Float = 0
            guard FPDFPathSegment_GetPoint(segment, &x, &y) != 0, x.isFinite, y.isFinite else { return nil }
            points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)).applying(transform))
        }
        if points.count == 5 {
            guard points.first == points.last else { return nil }; points.removeLast()
        }
        let xs = Set(points.map(\.x)), ys = Set(points.map(\.y))
        guard xs.count == 2, ys.count == 2,
              let left = xs.min(), let right = xs.max(), let bottom = ys.min(), let top = ys.max(),
              points.allSatisfy({ point in points.filter { $0 == point }.count == 1 }) else { return nil }
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            guard points[index].x == next.x || points[index].y == next.y else { return nil }
        }
        let bounds = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        return valid(bounds) && !bounds.isEmpty ? bounds : nil
    }

    private static func hasEmptyInkBounds(_ object: FPDF_PAGEOBJECT) -> Bool {
        var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
        return FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0
            && [left, bottom, right, top].allSatisfy(\.isFinite)
            && abs(right - left) < 0.001 && abs(top - bottom) < 0.001
    }

    /// Match within the geometrically selected native runs. Ignore only spaces
    /// that PDF engines synthesize differently; never guess between duplicate
    /// matches or discard meaningful characters.
    private static func matchingRange(of needle: String, in text: String, within scope: NSRange) -> NSRange? {
        let source = text as NSString
        guard NSMaxRange(scope) <= source.length else { return nil }
        let slice = source.substring(with: scope)
        var offsets: [NSRange] = []
        var normalized = ""
        var offset = scope.location
        for character in slice {
            let value = String(character)
            let length = (value as NSString).length
            if !character.isWhitespace {
                let mapped = value.precomposedStringWithCanonicalMapping
                normalized += mapped
                offsets.append(contentsOf: Array(repeating: NSRange(location: offset, length: length),
                    count: (mapped as NSString).length))
            }
            offset += length
        }
        let key = selectionKey(needle)
        guard !key.isEmpty else { return nil }
        let searchable = normalized as NSString
        let match = searchable.range(of: key)
        guard match.location != NSNotFound, NSMaxRange(match) <= offsets.count else { return nil }
        let remaining = NSRange(location: match.location + 1, length: searchable.length - match.location - 1)
        guard searchable.range(of: key, range: remaining).location == NSNotFound else { return nil }
        return NSUnionRange(offsets[match.location], offsets[NSMaxRange(match) - 1])
    }

    /// Verify block boundaries against independently parsed native prefixes.
    /// Record counts alone cannot authorize removal of neighboring PDF content.
    private static func wholeBlockPlan(on page: PDFPage, nativePage: FPDF_PAGE,
                                       blockIndices: [Int], originals: [PDFBodyTextTarget],
                                       parsedStream: PDFBodyTextContentStream? = nil) throws -> LosslessPlan? {
        guard !originals.isEmpty, !blockIndices.isEmpty,
              page.bounds(for: .mediaBox).origin == .zero else { return nil }
        let stream: PDFBodyTextContentStream
        if let parsedStream { stream = parsedStream }
        else { stream = try PDFBodyTextContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: page)) }
        guard blockIndices == Array(Set(blockIndices)).sorted(),
              blockIndices.allSatisfy({ stream.blocks.indices.contains($0) && stream.blocks[$0].isSupported
                  && losslessGraphicsStateIsSupported(stream.blocks[$0].graphicsStateNames, on: page) }) else { return nil }
        let roots = (0..<Int(FPDFPage_CountObjects(nativePage))).filter {
            FPDFPage_GetObject(nativePage, Int32($0)).map { FPDFPageObj_GetType($0) == FPDF_PAGEOBJ_TEXT } ?? false
        }
        guard roots.count == stream.records.count else { return nil }
        let ranges = Set(blockIndices.flatMap { stream.blocks[$0].showRanges })
        let covered = roots.enumerated().compactMap { ranges.contains(stream.records[$0.offset].showRange) ? $0.element : nil }
        guard let firstRoot = covered.first, let lastRoot = covered.last,
              covered == Array(firstRoot...lastRoot),
              originals.allSatisfy({ $0.objectPath.count == 1 && covered.contains($0.objectPath[0]) }) else { return nil }
        let described = Set(originals.map { $0.objectPath[0] })
        guard let textPage = FPDFText_LoadPage(nativePage) else { return nil }
        defer { FPDFText_ClosePage(textPage) }
        for root in covered where !described.contains(root) {
            guard let object = FPDFPage_GetObject(nativePage, Int32(root)),
                  FPDFTextObj_GetText(object, textPage, nil, 0) <= 2,
                  hasEmptyInkBounds(object) else { return nil }
        }
        let first = stream.blocks[blockIndices[0]], last = stream.blocks[blockIndices.last!]
        let before = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: Data(stream.data.prefix(first.range.lowerBound)))
        guard try withPage(before, body: { _, prefix in Int(FPDFPage_CountObjects(prefix)) == firstRoot }) else { return nil }
        let after = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: Data(stream.data.prefix(last.range.upperBound)))
        guard try withPage(after, body: { _, prefix in
            guard Int(FPDFPage_CountObjects(prefix)) == lastRoot + 1 else { return false }
            for original in originals {
                let object = try resolve(original.objectPath, on: prefix, requiringFinalLeaf: false).object
                let current = try description(of: object, on: prefix)
                guard prefixTextMatches(current.text, original.text),
                      approximatelyEqual(current.glyphBounds, original.glyphBounds),
                      sameStyle(current.style, original.style) else { return false }
            }
            return true
        }) else { return nil }
        return LosslessPlan(stream: stream, recordIndices: blockIndices, transform: first.transform,
            replacesForm: false, replacesBlocks: true,
            recordRoots: Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($0.offset, $0.element) }))
    }

    private static func selectionKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init).joined()
    }

    /// PDFium can synthesize a trailing inter-object space only when the next
    /// object is present. A prefix snapshot intentionally ends before it.
    /// Preserve every interior character and compare the same glyph geometry.
    private static func prefixTextMatches(_ actual: String, _ expected: String) -> Bool {
        func trimBoundary(_ value: String) -> Substring {
            var result = value[...]
            while let last = result.last, last == " " || last == "\t" { result.removeLast() }
            return result
        }
        return trimBoundary(actual) == trimBoundary(expected)
    }

    private static func sameStyle(_ lhs: InlineTextStyle, _ rhs: InlineTextStyle) -> Bool {
        lhs.fontName == rhs.fontName && abs(lhs.fontSize - rhs.fontSize) < 0.01
            && abs(lhs.horizontalScale - rhs.horizontalScale) < 0.001
            && lhs.alignment == rhs.alignment && lhs.textColor.visuallyEquals(rhs.textColor)
            && lhs.backgroundColor.visuallyEquals(rhs.backgroundColor)
    }

    /// Italic loose bounds can extend past the actual font advance. Subtract
    /// the advance that CoreText will draw, so a confirmed space preserves the
    /// next word's origin instead of shrinking the separator by that overhang.
    private static func calibratedBoundarySpaceAdvance(previous: PDFBodyTextTarget,
        next: PDFBodyTextTarget, last: InlineTextSourceRun, text: String,
        fallback: CGFloat, confirmed: Bool) -> CGFloat {
        let length = text.utf16.count
        guard confirmed, last.horizontalAdvance == nil, last.range.location >= 0,
              last.range.length > 0, last.range.location <= length,
              last.range.length <= length - last.range.location else { return fallback }
        let fragment = (text as NSString).substring(with: last.range)
        let resolvedFont = replacementFont(for: fragment, preferred: last.style.font)
        let font = last.style.renderingFont(resolvedFont)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if last.usesSourceUnkernedAdvances,
           PDFBodySourceSpacing.fontMatches(resolvedFont, last.style.font) {
            attributes[.kern] = NSNumber(value: 0)
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: fragment, attributes: attributes))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let gap = next.baseline.x - previous.baseline.x - previous.leadingWhitespaceAdvance - advance
        guard advance.isFinite, advance > 0, gap.isFinite, gap > 0,
              gap <= max(12, previous.style.fontSize * 1.5) else { return fallback }
        return gap
    }

    private static func needsInferredSpace(before: String, after: String, gap: CGFloat, fontSize: CGFloat) -> Bool {
        PDFBodyTextInferredSpacing.needsSpace(before: before, after: after, gap: gap, fontSize: fontSize)
    }

    private static func preserveAdvance(to nextX: CGFloat, from previous: PDFBodyTextTarget,
                                        extendingForSpace: Bool, in runs: inout [InlineTextSourceRun]) {
        guard let last = runs.last, last.horizontalAdvance != nil else { return }
        // The last run can be the visible remainder after an independently
        // measured leading gap; that gap already has its own source run.
        let advance = nextX - previous.baseline.x - previous.leadingWhitespaceAdvance
        guard advance.isFinite, advance > 0 else { return }
        runs[runs.count - 1] = InlineTextSourceRun(
            range: NSRange(location: last.range.location, length: last.range.length + (extendingForSpace ? 1 : 0)),
            style: last.style, baselineOffset: last.baselineOffset, horizontalAdvance: advance,
            usesSourceUnkernedAdvances: last.usesSourceUnkernedAdvances)
    }

    /// PDFium can append a generated boundary space to a preceding object's
    /// text even when that object owns no space glyph. The original gap may
    /// use a different font's space width. Preserve only that gap's native
    /// advance; the preceding letters or numbers keep their original scale.
    private static func preserveForeignBoundarySpace(from previous: Description?, to next: Description,
                                                     in runs: inout [InlineTextSourceRun]) -> Bool {
        guard let previous, previous.foreignTrailingWhitespaceLength > 0,
              let ownedAdvance = previous.ownedAdvance, let last = runs.last,
              last.range.length > previous.foreignTrailingWhitespaceLength else { return false }
        let gap = next.baseline.x - previous.baseline.x - ownedAdvance
        guard gap.isFinite, gap > 0 else { return false }
        let ownedLength = last.range.length - previous.foreignTrailingWhitespaceLength
        let remainingAdvance = ownedAdvance - leadingAdvance(for: previous, content: previous.text)
        guard remainingAdvance.isFinite, remainingAdvance > 0 else { return false }
        runs[runs.count - 1] = InlineTextSourceRun(
            range: NSRange(location: last.range.location, length: ownedLength),
            style: last.style, baselineOffset: last.baselineOffset,
            horizontalAdvance: last.horizontalAdvance == nil ? nil : remainingAdvance,
            usesSourceUnkernedAdvances: last.usesSourceUnkernedAdvances)
        runs.append(InlineTextSourceRun(
            range: NSRange(location: last.range.location + ownedLength,
                           length: previous.foreignTrailingWhitespaceLength),
            style: last.style, baselineOffset: last.baselineOffset, horizontalAdvance: gap,
            usesSourceUnkernedAdvances: last.usesSourceUnkernedAdvances))
        return true
    }

    /// Book paragraphs commonly switch fonts for Latin digits, and indent the
    /// first line. Keep those runs as attributed text rather than flattening
    /// them or rejecting an otherwise ordinary paragraph.
    private static func compatibleParagraphStyle(_ lhs: InlineTextStyle, _ rhs: InlineTextStyle,
                                                allowingVerifiedHorizontalScale: Bool = false) -> Bool {
        (0.8...1.25).contains(rhs.fontSize / lhs.fontSize)
            && (allowingVerifiedHorizontalScale || (0.8...1.25).contains(rhs.horizontalScale / lhs.horizontalScale))
            && lhs.alignment == rhs.alignment && lhs.textColor.visuallyEquals(rhs.textColor)
            && lhs.backgroundColor.visuallyEquals(rhs.backgroundColor)
    }

    private struct ParagraphGeometry {
        let firstBaseline: CGPoint
        let fontSize: CGFloat
        var lineBaseline: CGPoint
        var continuationX: CGFloat?
        var lineHeight: CGFloat?
        var firstLineIndent: CGFloat { continuationX.map { firstBaseline.x - $0 } ?? 0 }

        init(first: PDFBodyTextTarget) {
            firstBaseline = first.baseline
            lineBaseline = first.baseline
            fontSize = first.style.fontSize
        }

        mutating func append(_ target: PDFBodyTextTarget) -> Bool? {
            append(baseline: target.baseline, fontSize: fontSize)
        }

        mutating func append(baseline: CGPoint, fontSize: CGFloat) -> Bool? {
            let delta = lineBaseline.y - baseline.y
            if abs(delta) <= 1 { return false }
            guard delta >= fontSize * 0.8, delta <= fontSize * 2.5,
                  lineHeight.map({ abs($0 - delta) <= 1 }) ?? true else { return nil }
            if let continuationX {
                guard abs(baseline.x - continuationX) <= 1 else { return nil }
            } else {
                // A bounded paragraph indent must not merge separate columns.
                guard abs(baseline.x - firstBaseline.x) <= min(48, fontSize * 4) else { return nil }
                continuationX = baseline.x
            }
            if lineHeight == nil { lineHeight = delta }
            lineBaseline = baseline
            return true
        }
    }

    static func replacementPage(
        for page: PDFPage,
        target: PDFBodyTextTarget?,
        text: String,
        style: InlineTextStyle,
        bounds: CGRect
    ) throws -> PDFPage {
        try validatePermission(page)
        guard !InlineTextDraftLimiter.limit(text).wasTruncated else { throw Failure.tooComplex }
        guard valid(bounds), bounds.width > 0, bounds.height > 0 else { throw Failure.failed }
        if let target, target.sourcePageID != ObjectIdentifier(page) { throw Failure.changed }
        if PDFBodyLosslessProvenance.commit(for: page)?.rewrite.kind == .glyph {
            throw Failure.reopenForBodyEdit
        }
        let fontLeases = [style.sourceFont, target?.style.sourceFont]
            + (target?.sourceRuns.map { $0.style.sourceFont } ?? [])
        guard fontLeases.compactMap({ $0 }).allSatisfy({ $0.isValid(for: page.document) }) else {
            throw Failure.changed
        }
        let mediaBox = page.bounds(for: .mediaBox)
        guard valid(mediaBox), mediaBox.width > 0, mediaBox.height > 0 else { throw Failure.unreadable }
        let currentData = try PDFBodyTextFitDiagnostics.withReplacementPhase(.sourceSnapshot, {
            try snapshot(page)
        })
        // Admission here is only a cheap pending-evidence choice. No raw input
        // is read and no original resource/tag tree is traversed on Main.
        let originalPainting = page.pageRef
        let originalOwner = originalPainting?.document
        let originalRaw = PDFRawStreamProvenance.source(for: page)
        let captureStructure = originalOwner.flatMap { owner in
            originalRaw.map { $0.provesExactFactoryOwner(owner) }
        } == true && originalPainting?.dictionary.flatMap {
            PDFCatalogStructurePreserver.object($0, "StructParents")
        } != nil
        var losslessCopy: PDFBodyResourceCopyOutput?
        var nativeDonorTag: PDFBodyGeneratedDonorTag?
        var losslessRewrite: PDFBodyLosslessRewriteReceipt?
        let recordLossless: ((PDFBodyResourceCopyOutput, PDFBodyLosslessRewriteReceipt) -> Void)? = captureStructure ? { copy, rewrite in
            losslessCopy = copy; losslessRewrite = rewrite
        } : nil
        let output = try withPage(currentData, sourceDocument: page.document) { nativeDocument, nativePage in
            if let target, let owned = target.outlinedSource {
                guard owned.snapshot == currentData else { throw Failure.changed }
                let donor = text.isEmpty ? nil : try PDFBodyTextFitDiagnostics.withReplacementPhase(.donorGeneration, {
                    try outlinedDonor(on: page, target: target,
                        text: text, style: style, bounds: bounds, source: owned.metadata)
                })
                let name = donor == nil ? nil : try PDFBodyTextPageSnapshot.unusedXObjectName(for: page)
                var content = try PDFBodyTextPageSnapshot.contentData(for: page)
                guard owned.showRange.lowerBound >= 0, owned.showRange.upperBound <= content.count else {
                    throw Failure.changed
                }
                var invocation = ""
                if let name {
                    let inverse = owned.transform.inverted()
                    let values = [inverse.a, inverse.b, inverse.c, inverse.d, inverse.tx, inverse.ty]
                    guard values.allSatisfy(\.isFinite) else { throw Failure.unsupported }
                    invocation = try "q " + values.map(pdfNumber).joined(separator: " ") + " cm /\(name) Do Q"
                }
                content.replaceSubrange(owned.showRange, with: Data(invocation.utf8))
                return try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessSnapshotWrite, {
                    try PDFBodyTextPageSnapshot.data(for: page, contentOverride: content,
                        donorPDF: donor, donorName: name, droppingXObjectNames: [owned.resourceName],
                        preservePageContent: true, donorOCRFontName: donor == nil ? nil : owned.metadata.semanticFontName)
                })
            }
            if let target, let scanned = target.scannedSource {
                guard scanned.snapshot == currentData else { throw Failure.changed }
                let cleanContent = try scannedContentPreservingUnselectedOCR(on: page,
                    nativePage: nativePage, source: scanned)
                let cleanData = try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessSnapshotWrite, {
                    try PDFBodyTextPageSnapshot.data(for: page, contentOverride: cleanContent)
                })
                guard let cleaned = PDFDocument(data: cleanData),
                      let cleanPage = cleaned.page(at: 0) else { throw Failure.failed }
                PDFRawStreamProvenance.bindCreated(cleaned, data: cleanData)
                guard try PDFScannedBodyTextEditor.preservesAppearance(of: page, in: cleanPage) else {
                    PDFBodyTextFitDiagnostics.recordReplacementFailure(.scannedAppearance, error: Failure.unsupported)
                    throw Failure.unsupported
                }
                let donor: Data?
                if text.isEmpty { donor = nil }
                else if let fontName = scanned.semanticFontName, let encoding = scanned.semanticEncoding {
                    let source = try PDFOutlinedOCRMetadata(text: target.text, style: target.style,
                        bounds: target.bounds, baseline: target.baseline, lineHeight: target.lineHeight,
                        firstLineIndent: target.firstLineIndent, sourceRuns: target.sourceRuns,
                        erasedRects: scanned.erasedRects, paperColor: scanned.paperColor,
                        semanticFontName: fontName, semanticEncoding: encoding,
                        semanticDefaultWidth: scanned.semanticDefaultWidth,
                        semanticLineMatrices: scanned.semanticLineMatrices,
                        semanticLineFontSizes: scanned.semanticLineFontSizes,
                        semanticLineWidths: scanned.semanticLineWidths)
                    donor = try PDFBodyTextFitDiagnostics.withReplacementPhase(.donorGeneration, {
                        try outlinedDonor(on: page, target: target, text: text, style: style,
                                                  bounds: bounds, source: source)
                    })
                } else {
                    donor = try PDFBodyTextFitDiagnostics.withReplacementPhase(.donorGeneration, {
                        try textPDF(text, style: style, bounds: bounds,
                            mediaBox: mediaBox, visibleBox: mediaBox.intersection(page.bounds(for: .cropBox)),
                            baseline: approximatelyEqual(target.bounds, bounds) ? target.baseline : nil,
                            lineHeight: target.lineHeight, firstLineIndent: target.firstLineIndent,
                            sourceText: target.text, sourceStyle: target.style, sourceRuns: target.sourceRuns)
                    })
                }
                if let donor {
                    let plain = scanned.semanticFontName == nil || scanned.semanticEncoding == nil
                    var paintFits = true
                    if plain { paintFits = try PDFScannedInkPlacement.fits(donor,erasedRects:scanned.erasedRects) }
                    guard paintFits,try withPage(donor, body: { _, page in PDFScannedBodyTextEditor.replacementFits(page, source: scanned) }) else {
                        PDFBodyTextFitDiagnostics.record(.scannedInitialEnvelope, bounds: bounds,
                            paintExtent: scanned.erasedRects.reduce(CGRect.null) { $0.union($1) },
                            obstacleCount: scanned.erasedRects.count)
                        throw PDFScannedBodyTextEditor.Failure.doesNotFit
                    }
                }
                let name = donor == nil ? nil : try PDFBodyTextPageSnapshot.unusedXObjectName(for: cleanPage)
                let content = try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessRewrite, {
                    try PDFScannedBodyTextEditor.clippedContent(
                        try PDFBodyTextPageSnapshot.contentData(for: cleanPage), source: scanned,
                        mediaBox: mediaBox, donorName: name)
                })
                let normalErasureMetadata: Data?
                if donor != nil, scanned.semanticFontName == nil || scanned.semanticEncoding == nil {
                    normalErasureMetadata = try PDFScannedErasureMetadata(erasedRects: scanned.erasedRects,
                        paperColor: scanned.paperColor, program: content).encoded()
                } else { normalErasureMetadata = nil }
                return try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessSnapshotWrite, {
                    try PDFBodyTextPageSnapshot.data(for: cleanPage, contentOverride: content,
                        donorPDF: donor, donorName: name, preservePageContent: true,
                        donorOCRFontName: donor == nil ? nil : scanned.semanticFontName,
                        donorScannedErasureMetadata: normalErasureMetadata)
                })
            }
            // Recheck neighbours against the current page before preparing a
            // detached replacement. A stale draft cannot authorize new space.
            var currentTarget = target
            var currentVerifiedPlan: LosslessPlan?
            var currentPaintObservation: PDFBodyTextFitDiagnostics.PaintObservation?
            if let target {
                guard let textPage = FPDFText_LoadPage(nativePage) else { throw Failure.unreadable }
                defer { FPDFText_ClosePage(textPage) }
                guard let declaration = try PDFBodyTextFitDiagnostics.withReplacementPhase(.declaration, {
                    try declaredPaintTarget(target, on: page, nativePage: nativePage,
                        textPage: textPage, characterCount: FPDFText_CountChars(textPage))
                }),
                      approximatelyEqual(declaration.target.paintBounds, target.paintBounds) else {
                    PDFBodyTextFitDiagnostics.recordReplacementFailure(.declaration, error: Failure.changed)
                    throw Failure.changed
                }
                currentTarget = declaration.target
                currentVerifiedPlan = declaration.verifiedPlan
                currentPaintObservation = declaration.observation
            }
            var removedObjects: [(object: FPDF_PAGEOBJECT, parent: FPDF_PAGEOBJECT?)] = []
            if let target = currentTarget {
                let originals = target.additionalObjects.isEmpty ? [target] : target.additionalObjects
                // The declaration already rebound this plan to this same native
                // page. No await, page mutation, or content rewrite has occurred.
                // Keep the independent object/text/bounds checks below, without
                // decoding the same raw stream and both native prefixes again.
                let preservedPlan = target.textBlockIndices == nil
                    ? (currentVerifiedPlan ?? losslessPlan(on: page, nativePage: nativePage, originals: originals)) : nil
                for original in originals {
                    let resolved = try PDFBodyTextFitDiagnostics.withReplacementPhase(.nativeResolve, {
                        try resolve(original.objectPath, on: nativePage,
                                                   requiringFinalLeaf: target.additionalObjects.count <= 1 && preservedPlan == nil)
                    })
                    let description = try PDFBodyTextFitDiagnostics.withReplacementPhase(.nativeResolve, {
                        try Self.description(of: resolved.object, on: nativePage)
                    })
                    guard description.text == original.text,
                          approximatelyEqual(description.glyphBounds, original.glyphBounds) else {
                        PDFBodyTextFitDiagnostics.recordReplacementFailure(.nativeResolve, error: Failure.changed)
                        throw Failure.changed
                    }
                    removedObjects.append(resolved)
                }
                if let plan = currentVerifiedPlan ?? preservedPlan {
                    do {
                        if let correction = try replacingOriginalGlyph(on: page, plan: plan, target: target,
                            text: text, style: style, bounds: bounds, nativePage: nativePage,
                            requireTagProof: captureStructure) {
                            losslessCopy = correction.copy; losslessRewrite = correction.rewrite
                            return correction.copy.data
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* The existing renderer still checks its own admission. */ }
                }
                if let blocks = target.textBlockIndices {
                    // No await or native mutation occurs between declaration
                    // and this use. The plan is local to this withPage call.
                    guard let plan = currentVerifiedPlan, plan.replacesBlocks,
                          plan.recordIndices == blocks else { throw Failure.changed }
                    return try losslessReplacement(on: page, plan: plan, target: target,
                        text: text, style: style, bounds: bounds, recordStructure: recordLossless,
                        paintObservation: currentPaintObservation)
                }
                if let plan = preservedPlan {
                    return try losslessReplacement(on: page, plan: plan, target: target,
                        text: text, style: style, bounds: bounds, recordStructure: recordLossless,
                        paintObservation: currentPaintObservation)
                }
                try PDFBodyTextFitDiagnostics.withReplacementPhase(.nativeGraphics, {
                    try validateNativeGraphics(page, nativePage: nativePage,
                                               rejectingSharedForms: originals.contains { $0.objectPath.count > 1 })
                })
                try PDFBodyTextFitDiagnostics.withReplacementPhase(.nativeGraphics, {
                    ScannedAncestorClips.invalidate(on: nativePage)
                    try preserveSolidColors(on: nativePage)
                })
            }

            var insertedDonor: FPDF_PAGEOBJECT?
            // Prepare the complete replacement first. CoreText embeds the
            // actual fonts and Unicode mapping, including fallback Korean fonts.
            // The resulting objects remain native, searchable PDF page content.
            if !text.isEmpty {
                let baseline = currentTarget.flatMap {
                    // Changing font size must grow around the existing text
                    // baseline, not re-anchor the run to a new font's ascent.
                    // PDF font sizes also commonly carry fractional precision
                    // beyond what the size field displays.
                    approximatelyEqual($0.bounds, bounds) ? $0.baseline : nil
                }
                let newContent = try PDFBodyTextFitDiagnostics.withReplacementPhase(.donorGeneration, {
                    try textPDF(text, style: style, bounds: bounds, mediaBox: mediaBox,
                        visibleBox: mediaBox.intersection(page.bounds(for: .cropBox)), baseline: baseline,
                        lineHeight: currentTarget?.lineHeight, firstLineIndent: currentTarget?.firstLineIndent ?? 0,
                        sourceText: currentTarget?.text, sourceStyle: currentTarget?.style, sourceRuns: currentTarget?.sourceRuns ?? [],
                        paintExtent: currentTarget?.paintBounds,
                        protectedPaintBounds: currentTarget?.protectedPaintBounds ?? [],
                        paintObservation: currentPaintObservation)
                })
                try withPage(newContent) { textDocument, _ in
                    guard let xobject = FPDF_NewXObjectFromPage(nativeDocument, textDocument, 0) else { throw Failure.failed }
                    defer { FPDF_CloseXObject(xobject) }
                    guard let form = FPDF_NewFormObjectFromXObject(xobject) else { throw Failure.failed }
                    // A Form isolates the donor's embedded fonts/resources from
                    // similarly named resources in the original page.
                    FPDFPageObj_Transform(form, 1, 0, 0, 1, mediaBox.minX, mediaBox.minY)
                    let inserted: FPDF_BOOL
                    if let target = currentTarget {
                        let index = target.objectPath[0] + (target.objectPath.count > 1 ? 1 : 0)
                        inserted = FPDFPage_InsertObjectAtIndex(nativePage, form, index)
                    } else {
                        inserted = FPDFPage_InsertObject(nativePage, form)
                    }
                    guard inserted != 0 else { throw Failure.failed }
                    insertedDonor = form
                }
            }
            for (removedObject, parent) in removedObjects {
                let removed: FPDF_BOOL
                if let parent { removed = FPDFFormObj_RemoveObject(parent, removedObject) }
                else { removed = FPDFPage_RemoveObject(nativePage, removedObject) }
                guard removed != 0 else { throw Failure.failed }
                FPDFPageObj_Destroy(removedObject)
            }
            try removeEmptyEditedForms(on: nativePage, parents: Set(removedObjects.compactMap(\.parent)))
            guard FPDFPage_GenerateContent(nativePage) != 0 else { throw Failure.failed }
            let saved = try save(nativeDocument)
            if let insertedDonor {
                do {
                    nativeDonorTag = try generatedDonorTag(snapshot: saved, on: nativePage,
                        inserted: insertedDonor, donorBox: CGRect(origin: .zero, size: mediaBox.size))
                } catch is CancellationError { throw CancellationError() }
                catch { nativeDonorTag = nil }
            }
            return saved
        }
        let restoredOutput: Data
        var finalCopy: PDFBodyResourceCopyWitness?
        if losslessRewrite?.kind == .glyph, let captured = losslessCopy, captured.data == output {
            // The correction keeps the original font names and resource graph.
            restoredOutput = output; finalCopy = captured.witness
        } else if let captured = losslessCopy, captured.data == output {
            let restored = try PDFBodyTextFitDiagnostics.withReplacementPhase(.restoredFontNames, {
                try PDFBodyTextPageSnapshot.restoringFontNamesPreservingBodyCopy(captured)
            })
            restoredOutput = restored.data; finalCopy = restored.witness
        } else {
            restoredOutput = try PDFBodyTextFitDiagnostics.withReplacementPhase(.restoredFontNames, {
                try PDFBodyTextPageSnapshot.restoringFontNames(in: output, preservePageContent: true,
                    generatedDonor: nativeDonorTag)
            })
        }
        guard let factory = PDFRawStreamProvenance.bodyResultFactory(data: restoredOutput) else {
            PDFBodyTextFitDiagnostics.recordReplacementFailure(.outputFactory, error: Failure.failed)
            throw Failure.failed
        }
        guard let result = factory.copyPage() else {
            PDFBodyTextFitDiagnostics.recordReplacementFailure(.copyPage, error: Failure.failed)
            throw Failure.failed
        }
        // Preserve PDFKit's explicitly edited geometry as well as native boxes.
        for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            if result.bounds(for: box) != page.bounds(for: box) {
                result.setBounds(page.bounds(for: box), for: box)
            }
        }
        if result.rotation != page.rotation { result.rotation = page.rotation }
        // The raw content snapshot deliberately excludes annotations. Return
        // detached copies; the workspace replaces these with the original live
        // instances when registering its page-swap undo transaction.
        for annotation in page.annotations {
            guard let copied = annotation.copy() as? PDFAnnotation else {
                PDFBodyTextFitDiagnostics.recordReplacementFailure(.copyAnnotation, error: Failure.failed)
                throw Failure.failed
            }
            result.addAnnotation(copied)
        }
        // PDFKit's reading order can depend on widget/annotation context.
        // Validate the fully assembled detached result, with the same current
        // annotation context it will carry into the page-swap transaction.
        if let target {
            let preserved = withExtendedLifetime(factory) {
                preservesTextSequence(before: page.string ?? "", after: result.string ?? "",
                                      original: target.text, replacement: text)
            }
            guard preserved else {
                PDFBodyTextFitDiagnostics.recordReplacementFailure(.finalPDFKitTextSequence, error: Failure.readingOrder)
                throw Failure.readingOrder
            }
        }
        if captureStructure, let originalPainting, let originalOwner, let originalRaw,
           let finalCopy, let losslessRewrite,
           let reference = result.pageRef, let currentOwner = reference.document,
           let currentRaw = PDFRawStreamProvenance.source(for: result),
           originalRaw.provesExactFactoryOwner(originalOwner), currentRaw.provesExactFactoryOwner(currentOwner),
           originalPainting.dictionary == finalCopy.source.dictionary,
           finalCopy.contentSHA256 == Data(SHA256.hash(data: losslessRewrite.rewritten)) {
            let styleIntent = PDFBodyLosslessCommit.ParagraphStyleIntent(page: page,
                original: originalPainting, raw: originalRaw, target: target,
                text: text, style: style, bounds: bounds, construction: finalCopy)
            PDFBodyLosslessProvenance.record(PDFBodyLosslessCommit(original: originalPainting,
                originalRaw: originalRaw, originalOwner: originalOwner, current: reference,
                currentRaw: currentRaw, currentOwner: currentOwner, copy: finalCopy, rewrite: losslessRewrite,
                paragraphStyleIntent: styleIntent), on: result)
        }
        return result
    }

    /// An edit may replace one bounded text span, but must never let a
    /// renderer's spatial heuristics reorder any other text on the page.
    static func preservesTextSequence(before: String, after: String,
                                              original: String, replacement: String) -> Bool {
        let source = Data(selectionKey(before).utf8), actual = Data(selectionKey(after).utf8)
        let old = Data(selectionKey(original).utf8), new = Data(selectionKey(replacement).utf8)
        guard !old.isEmpty, source.count >= old.count,
              actual.count == source.count - old.count + new.count else { return false }
        if old == new, source != actual { return false }
        let sourceBytes = Array(source), actualBytes = Array(actual)
        var head = 0
        while head < min(sourceBytes.count, actualBytes.count), sourceBytes[head] == actualBytes[head] {
            head += 1
        }
        var tail = 0
        while tail < min(sourceBytes.count, actualBytes.count),
              sourceBytes[sourceBytes.count - 1 - tail] == actualBytes[actualBytes.count - 1 - tail] {
            tail += 1
        }
        let first = max(0, sourceBytes.count - old.count - tail)
        let last = min(head, sourceBytes.count - old.count)
        guard first <= last else { return false }
        // Prefix/suffix equality bounds every valid substitution. Match the
        // two middle spans with KMP so long repeated OCR text cannot trigger
        // quadratic substring copies/comparisons on the UI thread.
        func matches(_ needle: [UInt8], in bytes: [UInt8]) -> [Int] {
            guard !needle.isEmpty, first + needle.count <= bytes.count else { return [] }
            var prefix = [Int](repeating: 0, count: needle.count)
            if needle.count > 1 {
                var length = 0
                for index in 1..<needle.count {
                    while length > 0, needle[index] != needle[length] { length = prefix[length - 1] }
                    if needle[index] == needle[length] { length += 1 }
                    prefix[index] = length
                }
            }
            var length = 0, found: [Int] = []
            let end = min(bytes.count, last + needle.count)
            for index in first..<end {
                while length > 0, bytes[index] != needle[length] { length = prefix[length - 1] }
                if bytes[index] == needle[length] { length += 1 }
                if length == needle.count {
                    let offset = index + 1 - needle.count
                    if offset <= last { found.append(offset) }
                    length = prefix[length - 1]
                }
            }
            return found
        }
        let oldMatches = matches(Array(old), in: sourceBytes)
        guard !oldMatches.isEmpty else { return false }
        if new.isEmpty || old == new { return true }
        let newMatches = matches(Array(new), in: actualBytes)
        var left = 0, right = 0
        while left < oldMatches.count, right < newMatches.count {
            if oldMatches[left] == newMatches[right] { return true }
            if oldMatches[left] < newMatches[right] { left += 1 } else { right += 1 }
        }
        return false
    }

    /// Keep the original stream and every unrelated OCR font mapping. Verify
    /// each selected token against native prefix snapshots before byte removal.
    private static func scannedContentPreservingUnselectedOCR(on page: PDFPage,
        nativePage: FPDF_PAGE, source: PDFScannedBodyTextEditor.Source) throws -> Data {
        let stream = try PDFScannedContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: page))
        let count = Int(FPDFPage_CountObjects(nativePage))
        guard count >= 0, count <= maximumObjects else { throw Failure.tooComplex }
        let textRoots = (0..<count).filter {
            FPDFPage_GetObject(nativePage, Int32($0)).map { FPDFPageObj_GetType($0) == FPDF_PAGEOBJ_TEXT } ?? false
        }
        guard textRoots.count == stream.shows.count else { throw Failure.unsupported }
        let contentTemplate = try PDFBodyTextPageSnapshot.contentTemplate(for: page)
        var ordinals: [Int] = []
        for root in source.rootIndices {
            guard let ordinal = textRoots.firstIndex(of: root),
                  let original = FPDFPage_GetObject(nativePage, Int32(root)),
                  FPDFTextObj_GetTextRenderMode(original) == FPDF_TEXTRENDERMODE_INVISIBLE else { throw Failure.changed }
            let show = stream.shows[ordinal]
            guard show.invisible, !show.marked else { throw Failure.unsupported }
            if let recovered = source.recoveredZeroWidthRoots[root] {
                guard recovered.utf16.count == 1, let bytes = show.stringBytes, bytes.count == 2,
                      String(data: Data(bytes), encoding: .utf16BigEndian) == recovered else { throw Failure.unsupported }
            }
            func prefix(_ offset: Int) throws -> Data {
                var content = Data(stream.data.prefix(offset))
                content.append(Data("\nET\n".utf8))
                return try contentTemplate.data(contentOverride: content)
            }
            guard try withPage(prefix(show.range.lowerBound), body: { _, candidate in
                Int(FPDFPage_CountObjects(candidate)) == root
            }) else { throw Failure.unsupported }
            let matches = try withPage(prefix(show.range.upperBound)) { _, candidate in
                guard Int(FPDFPage_CountObjects(candidate)) == root + 1,
                      let object = FPDFPage_GetObject(candidate, Int32(root)),
                      FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT,
                      FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_INVISIBLE else { return false }
                var a = FS_MATRIX(), b = FS_MATRIX()
                guard FPDFPageObj_GetMatrix(original, &a) != 0, FPDFPageObj_GetMatrix(object, &b) != 0 else { return false }
                let actual = [a.a,a.b,a.c,a.d,a.e,a.f], expected = [b.a,b.b,b.c,b.d,b.e,b.f]
                return zip(actual,expected).allSatisfy { abs($0-$1) < 0.0001 }
            }
            guard matches else { throw Failure.unsupported }
            ordinals.append(ordinal)
        }
        return try stream.removing(ordinals)
    }

    /// The pointer comes only from this Apply's successful new Form insertion.
    /// Bind its post-mutation root position to the serialized invocation before
    /// issuing a dictionary-only marker. Old/unrelated Forms cannot enter here.
    private static func generatedDonorTag(snapshot: Data, on nativePage: FPDF_PAGE,
                                          inserted form: FPDF_PAGEOBJECT,
                                          donorBox: CGRect) throws -> PDFBodyGeneratedDonorTag? {
        let count = Int(FPDFPage_CountObjects(nativePage))
        guard count > 0, count <= maximumObjects, snapshot.count <= 64 * 1_024 * 1_024,
              FPDFPageObj_GetType(form) == FPDF_PAGEOBJ_FORM,
              let actual = try ScannedAncestorClips.fingerprint(form, page: nativePage),
              let owner = PDFRawStreamProvenance.createdDocument(data: snapshot),
              owner.pageCount == 1, let page = owner.page(at: 0), let reference = page.pageRef,
              let dictionary = reference.dictionary else { return nil }
        var root: Int?, formRoots: [Int] = []
        for index in 0..<count {
            try Task.checkCancellation()
            guard let object = FPDFPage_GetObject(nativePage, Int32(index)) else { return nil }
            if object == form {
                guard root == nil else { return nil }
                root = index
            }
            if FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM { formRoots.append(index) }
        }
        guard let root, let ordinal = formRoots.firstIndex(of: root) else { return nil }
        let data = try PDFBodyTextPageSnapshot.contentData(for: page)
        guard data.count <= 2 * 1_024 * 1_024 else { return nil }
        let stream = try PDFBodyTextContentStream.parse(data)
        guard !stream.forms.isEmpty, stream.forms.count <= 32 else { return nil }
        var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return nil }
        // Ordinal alignment only chooses a candidate. The two independent
        // native prefix snapshots below still prove its exact root identity.
        // Ambiguous serialization falls back without marking any dictionary.
        var formRecordIndices: [Int] = []
        for (index, record) in stream.forms.enumerated() {
            try Task.checkCancellation()
            var raw: CGPDFStreamRef?, subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetStream(xobjects, record.name, &raw), let raw,
                  let candidate = CGPDFStreamGetDictionary(raw),
                  CGPDFDictionaryGetName(candidate, "Subtype", &subtype), let subtype else { return nil }
            if String(cString: subtype) == "Form" { formRecordIndices.append(index) }
        }
        guard formRecordIndices.count == formRoots.count, ordinal < formRecordIndices.count else { return nil }
        let record = stream.forms[formRecordIndices[ordinal]]
        guard record.isSupported else { return nil }
        var raw: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(xobjects, record.name, &raw), let raw,
              let candidate = CGPDFStreamGetDictionary(raw) else { return nil }
        var forbidden: CGPDFObjectRef?
        guard ["Group", "OC", "Ref", "StructParent", "StructParents", "EmberPDFBodyText",
               "EmberPDFBodyTextBounds", "EmberPDFOutlinedOCR", "EmberPDFScannedErasure"].allSatisfy({ (key: String) in
            key.withCString { !CGPDFDictionaryGetObject(candidate, $0, &forbidden) }
        }) else { return nil }
        var bbox: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(candidate, "BBox", &bbox), let bbox,
              CGPDFArrayGetCount(bbox) == 4 else { return nil }
        let expected = [donorBox.minX, donorBox.minY, donorBox.maxX, donorBox.maxY]
        for index in 0..<4 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(bbox, index, &value), value.isFinite,
                  value == expected[index] else { return nil }
        }
        var matrixObject: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(candidate, "Matrix", &matrixObject) {
            var matrix: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(candidate, "Matrix", &matrix), let matrix,
                  CGPDFArrayGetCount(matrix) == 6 else { return nil }
            for (index, expected) in [CGFloat(1), 0, 0, 1, 0, 0].enumerated() {
                var value: CGPDFReal = 0
                guard CGPDFArrayGetNumber(matrix, index, &value), value == expected else { return nil }
            }
        }
        guard losslessGraphicsStateIsSupported(record.graphicsStateNames, on: page),
              try PDFBodyFormUsageAudit().isFormInvokedExactlyOnce(named: record.name, on: reference),
              try PDFBodyFormUsageAudit().hasSafeUnclippedTextForm(named: record.name, on: reference)
        else { return nil }
        let template = try PDFBodyTextPageSnapshot.contentTemplate(for: page)
        let before = try template.data(contentOverride: Data(data.prefix(record.showRange.lowerBound)))
        guard try withPage(before, body: { _, prefix in
            Int(FPDFPage_CountObjects(prefix)) == root
        }) else { return nil }
        let after = try template.data(contentOverride: Data(data.prefix(record.insertionOffset)))
        guard try withPage(after, body: { _, prefix in
            guard Int(FPDFPage_CountObjects(prefix)) == root + 1,
                  let object = FPDFPage_GetObject(prefix, Int32(root)),
                  FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM else { return false }
            return try ScannedAncestorClips.fingerprint(object, page: prefix) == actual
        }), FPDFPage_GetObject(nativePage, Int32(root)) == form,
              Int(FPDFPage_CountObjects(nativePage)) == count,
              try ScannedAncestorClips.fingerprint(form, page: nativePage) == actual else { return nil }
        return PDFBodyGeneratedDonorTag(owner: owner, page: page, reference: reference,
            form: candidate, snapshot: snapshot)
    }

    /// PDFium can retain an emptied Form's old Tf operators while dropping its
    /// font resources. Those inert leftovers then fail the next edit's resource
    /// audit. Remove only Forms emptied by this edit and their empty ancestors.
    private static func removeEmptyEditedForms(on page: FPDF_PAGE, parents: Set<FPDF_PAGEOBJECT>) throws {
        guard !parents.isEmpty else { return }
        var remaining = maximumObjects
        func visit(_ parent: FPDF_PAGEOBJECT?, depth: Int) throws -> Bool {
            guard depth < maximumDepth else { throw Failure.tooComplex }
            let count = parent.map(FPDFFormObj_CountObjects) ?? FPDFPage_CountObjects(page)
            guard count >= 0, count <= remaining else { throw Failure.tooComplex }
            remaining -= Int(count)
            var removedChild = false
            for index in (0..<Int(count)).reversed() {
                let candidate = parent.flatMap { FPDFFormObj_GetObject($0, UInt(index)) }
                    ?? (parent == nil ? FPDFPage_GetObject(page, Int32(index)) : nil)
                guard let object = candidate else { throw Failure.failed }
                guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM else { continue }
                let removedDescendant = try visit(object, depth: depth + 1)
                guard FPDFFormObj_CountObjects(object) == 0,
                      parents.contains(object) || removedDescendant else { continue }
                let removed = parent.map { FPDFFormObj_RemoveObject($0, object) }
                    ?? FPDFPage_RemoveObject(page, object)
                guard removed != 0 else { throw Failure.failed }
                FPDFPageObj_Destroy(object)
                removedChild = true
            }
            return removedChild
        }
        _ = try visit(nil, depth: 0)
    }

    private static func validatePermission(_ page: PDFPage) throws {
        if let dictionary = page.pageRef?.dictionary {
            var unit: CGPDFReal = 1
            var value: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, "UserUnit", &value) {
                guard CGPDFDictionaryGetNumber(dictionary, "UserUnit", &unit),
                      unit.isFinite, abs(unit - 1) < 0.000001 else { throw Failure.unsupported }
            }
        }
        if let document = page.document,
           document.isLocked || (document.isEncrypted && document.permissionsStatus != .owner) {
            throw Failure.restricted
        }
    }

    /// CoreText may emit an ActualText space as an empty native text object.
    /// It can accompany a complete paragraph transaction only when it has no
    /// native characters, no ink extent and no compositing or clipping effect.
    static func isInertEmptySpace(_ object: FPDF_PAGEOBJECT, in textPage: FPDF_TEXTPAGE,
                                  hasOwnedCharacters: Bool) -> Bool {
        guard !hasOwnedCharacters, FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT,
              FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_FILL,
              FPDFPageObj_HasTransparency(object) == 0,
              FPDFTextObj_GetText(object, textPage, nil, 0) == 2 else { return false }
        if let clip = FPDFPageObj_GetClipPath(object), FPDFClipPath_CountPaths(clip) > 0 { return false }
        var text: UInt16 = 1
        var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 0
        guard FPDFPageObj_GetFillColor(object, &red, &green, &blue, &alpha) != 0, alpha == 255 else { return false }
        var left: Float = 0, right: Float = 0, bottom: Float = 0, top: Float = 0
        guard FPDFTextObj_GetText(object, textPage, &text, 2) == 2, text == 0,
              FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0,
              [left, right, bottom, top].allSatisfy(\.isFinite), left == right, bottom == top else { return false }
        return true
    }

    /// A PDFKit full save may flatten a donor and leave its empty line-end
    /// spaces as direct page objects. Only inspect gaps inside the selected
    /// root interval, and retain every skipped show unchanged. The existing
    /// no-character/no-ink/no-clip predicate applies without a weaker variant.
    private static func inertRootGaps(between roots: Set<Int>, on page: FPDF_PAGE,
                                     in textPage: FPDF_TEXTPAGE,
                                     hasOwnedCharacters: (FPDF_PAGEOBJECT) -> Bool) -> Set<Int> {
        let count = Int(FPDFPage_CountObjects(page))
        guard count >= 0, count <= maximumObjects,
              let first = roots.min(), let last = roots.max(),
              first >= 0, last < count, first < last else { return [] }
        var result = Set<Int>()
        for index in first...last where !roots.contains(index) {
            guard let object = FPDFPage_GetObject(page, Int32(index)),
                  isInertEmptySpace(object, in: textPage,
                      hasOwnedCharacters: hasOwnedCharacters(object)) else { return [] }
            result.insert(index)
        }
        return result
    }

    private static func formContainsOnlySelectedTextAndInertSpaces(_ form: FPDF_PAGEOBJECT,
        selected: Set<Int>, on nativePage: FPDF_PAGE) -> Bool {
        let count = Int(FPDFFormObj_CountObjects(form))
        guard count > 0, count <= maximumObjects, !selected.isEmpty,
              selected.allSatisfy({ (0..<count).contains($0) }),
              let textPage = FPDFText_LoadPage(nativePage) else { return false }
        defer { FPDFText_ClosePage(textPage) }
        let characters = FPDFText_CountChars(textPage)
        guard characters >= 0, characters <= maximumPageCharacters else { return false }
        let owners = Set((0..<characters).compactMap { FPDFText_GetTextObject(textPage, $0) })
        for index in 0..<count {
            guard let object = FPDFFormObj_GetObject(form, UInt(index)),
                  FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT else { return false }
            if !selected.contains(index), !isInertEmptySpace(object, in: textPage,
                hasOwnedCharacters: owners.contains(object)) { return false }
        }
        return true
    }

    private static func uniqueOwnedForm(on page: PDFPage, nativePage: FPDF_PAGE, root: Int) -> Bool {
        guard let reference = page.pageRef,
              let data = try? PDFBodyTextPageSnapshot.contentData(for: page),
              let stream = try? PDFBodyTextContentStream.parse(data) else { return false }
        do {
            var matches = 0
            for record in stream.forms where record.isSupported {
                guard PDFBodyTextPageSnapshot.isBodyTextXObject(named: record.name, on: page),
                      losslessGraphicsStateIsSupported(record.graphicsStateNames, on: page),
                      try PDFBodyFormUsageAudit().isFormInvokedExactlyOnce(named: record.name, on: reference) else { continue }
                let before = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: Data(data.prefix(record.showRange.lowerBound)))
                guard try withPage(before, body: { _, candidate in Int(FPDFPage_CountObjects(candidate)) == root }) else { continue }
                let after = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: Data(data.prefix(record.insertionOffset)))
                guard try withPage(after, body: { _, candidate in Int(FPDFPage_CountObjects(candidate)) == root + 1 }),
                      let object = FPDFPage_GetObject(nativePage, Int32(root)), FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM else { continue }
                matches += 1
            }
            return matches == 1
        } catch { return false }
    }

    private struct LosslessPlan {
        let stream: PDFBodyTextContentStream
        let recordIndices: [Int]
        let transform: CGAffineTransform
        let replacesForm: Bool
        var replacesBlocks = false
        var recordRoots: [Int: Int] = [:]
        var mixedFormIndices: [Int] = []
        var mixedInsertionOffset: Int?
        // Populated only after mixedLosslessPlan validates every selected leaf,
        // unique invocation, resources/order and both native prefix snapshots.
        var verifiedMixedTextFormRoots = Set<Int>()
    }

    private static func validateEditingRoute(_ page: PDFPage, nativePage: FPDF_PAGE,
                                             originals: [PDFBodyTextTarget]) throws {
        if losslessPlan(on: page, nativePage: nativePage, originals: originals) != nil { return }
        try validateNativeGraphics(page, nativePage: nativePage,
                                   rejectingSharedForms: originals.contains { $0.objectPath.count > 1 })
    }

    /// Leave unrelated PDF operators and resource streams byte-for-byte intact.
    /// A token's paint position is verified with two independent native prefix
    /// snapshots before it is ever allowed to bypass the regeneration audit.
    private static func losslessPlan(on page: PDFPage, nativePage: FPDF_PAGE,
                                     originals: [PDFBodyTextTarget]) -> LosslessPlan? {
        if Set(originals.map { Array($0.objectPath.dropLast()) }).count > 1 {
            return mixedLosslessPlan(on: page, nativePage: nativePage, originals: originals)
        }
        do {
            guard !originals.isEmpty,
                  page.bounds(for: .mediaBox).origin == .zero else { return nil }
            let data = try PDFBodyTextPageSnapshot.contentData(for: page)
            let stream = try PDFBodyTextContentStream.parse(data)
            let count = Int(FPDFPage_CountObjects(nativePage))
            guard count >= 0, count <= maximumObjects else { return nil }

            func verifyPrefix(before: Int, after: Int, rootIndex: Int, lastRootIndex: Int? = nil,
                              targets: [PDFBodyTextTarget]) throws -> Bool {
                guard before >= 0, after > before, after <= data.count else { return false }
                let beforeData = try PDFBodyTextPageSnapshot.data(for: page,
                    contentOverride: Data(data.prefix(before)))
                guard try withPage(beforeData, body: { _, prefix in
                    Int(FPDFPage_CountObjects(prefix)) == rootIndex
                }) else { return false }
                let afterData = try PDFBodyTextPageSnapshot.data(for: page,
                    contentOverride: Data(data.prefix(after)))
                return try withPage(afterData) { _, prefix in
                    guard Int(FPDFPage_CountObjects(prefix)) == (lastRootIndex ?? rootIndex) + 1 else { return false }
                    for target in targets {
                        let object = try resolve(target.objectPath, on: prefix, requiringFinalLeaf: false).object
                        let actual = try description(of: object, on: prefix)
                        guard prefixTextMatches(actual.text, target.text),
                              approximatelyEqual(actual.glyphBounds, target.glyphBounds) else { return false }
                    }
                    return true
                }
            }

            if originals.allSatisfy({ $0.objectPath.count == 1 }) {
                let rootTextIndices = (0..<count).filter { index in
                    FPDFPage_GetObject(nativePage, Int32(index)).map {
                        FPDFPageObj_GetType($0) == FPDF_PAGEOBJ_TEXT
                    } ?? false
                }
                guard rootTextIndices.count == stream.records.count else { return nil }
                var indices: [Int] = []
                for target in originals {
                    guard let rootIndex = target.objectPath.first,
                          let ordinal = rootTextIndices.firstIndex(of: rootIndex) else { return nil }
                    let record = stream.records[ordinal]
                    guard record.isSupported,
                          losslessGraphicsStateIsSupported(record.graphicsStateNames, on: page) else { return nil }
                    indices.append(ordinal)
                }
                indices.sort()
                let roots = originals.map { $0.objectPath[0] }.sorted()
                guard let first = indices.first, let last = indices.last,
                      Set(indices).count == indices.count,
                      let firstRoot = roots.first, let lastRoot = roots.last else { return nil }
                let selectedRoots = Set(roots)
                if selectedRoots.count != lastRoot - firstRoot + 1 {
                    guard let textPage = FPDFText_LoadPage(nativePage) else { return nil }
                    defer { FPDFText_ClosePage(textPage) }
                    let characterCount = FPDFText_CountChars(textPage)
                    guard characterCount >= 0, characterCount <= maximumPageCharacters else { return nil }
                    let owners = Set((0..<characterCount).compactMap { FPDFText_GetTextObject(textPage, $0) })
                    let inert = inertRootGaps(between: selectedRoots, on: nativePage, in: textPage,
                        hasOwnedCharacters: { owners.contains($0) })
                    guard selectedRoots.union(inert) == Set(firstRoot...lastRoot) else { return nil }
                }
                guard
                      try verifyPrefix(before: stream.records[first].blockStart,
                                       after: stream.records[last].insertionOffset,
                                       rootIndex: firstRoot, lastRootIndex: lastRoot,
                                       targets: originals) else { return nil }
                return LosslessPlan(stream: stream, recordIndices: indices,
                                    transform: stream.records[first].transform, replacesForm: false,
                                    recordRoots: Dictionary(uniqueKeysWithValues: rootTextIndices.enumerated().map { ($0.offset, $0.element) }))
            }

            // Our own isolated donor is replaced as a whole on later edits.
            // Never rewrite another application's arbitrary Form invocation.
            guard let rootIndex = originals.first?.objectPath.first,
                  originals.allSatisfy({ $0.objectPath.count == 2 && $0.objectPath[0] == rootIndex }),
                  let form = FPDFPage_GetObject(nativePage, Int32(rootIndex)),
                  FPDFPageObj_GetType(form) == FPDF_PAGEOBJ_FORM,
                  formContainsOnlySelectedTextAndInertSpaces(form, selected: Set(originals.compactMap { $0.objectPath.last }),
                      on: nativePage) else { return nil }
            guard let reference = page.pageRef else { return nil }
            // Inline images have native object indices but no Do invocation.
            // Locate our donor by independently verified before/after prefixes
            // instead of equating all image objects with XObject invocations.
            var candidates: [Int] = []
            for (ordinal, record) in stream.forms.enumerated() {
                guard record.isSupported,
                      PDFBodyTextPageSnapshot.isBodyTextXObject(named: record.name, on: page),
                      try PDFBodyFormUsageAudit().isFormInvokedExactlyOnce(named: record.name, on: reference),
                      try (ScannedAncestorClips.cached(on: nativePage, root: rootIndex)
                            .map { $0.matches(record, program: data) } ?? verifyPrefix(
                                before: record.showRange.lowerBound, after: record.insertionOffset,
                                rootIndex: rootIndex, targets: originals)) else { continue }
                candidates.append(ordinal)
            }
            guard candidates.count == 1, let ordinal = candidates.first else { return nil }
            return LosslessPlan(stream: stream, recordIndices: [ordinal],
                                transform: stream.forms[ordinal].transform, replacesForm: true)
        } catch {
            // A failed mapping never relaxes the original native safety gates.
            return nil
        }
    }

    /// Row preservation leaves original root text around our own text Form.
    /// Permit that mixed paragraph only when every selected root, native child,
    /// stream boundary and donor resource is independently accounted for.
    private static func mixedLosslessPlan(on page: PDFPage, nativePage: FPDF_PAGE,
                                          originals: [PDFBodyTextTarget]) -> LosslessPlan? {
        do {
            guard originals.count > 1, page.bounds(for: .mediaBox).origin == .zero,
                  originals.allSatisfy({ (1...2).contains($0.objectPath.count) }),
                  originals.map(\.objectPath) == originals.map(\.objectPath).sorted(by: { $0.lexicographicallyPrecedes($1) }),
                  let reference = page.pageRef else { return nil }
            let stream = try PDFBodyTextContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: page))
            let count = Int(FPDFPage_CountObjects(nativePage))
            guard count >= 0, count <= maximumObjects else { return nil }
            let textRoots = (0..<count).filter {
                FPDFPage_GetObject(nativePage, Int32($0)).map { FPDFPageObj_GetType($0) == FPDF_PAGEOBJ_TEXT } ?? false
            }
            let invocationRoots = (0..<count).filter {
                FPDFPage_GetObject(nativePage, Int32($0)).map {
                    [FPDF_PAGEOBJ_FORM, FPDF_PAGEOBJ_IMAGE].contains(FPDFPageObj_GetType($0))
                } ?? false
            }
            guard textRoots.count == stream.records.count, invocationRoots.count == stream.forms.count else { return nil }
            let rawRoots = Set(originals.filter { $0.objectPath.count == 1 }.map { $0.objectPath[0] })
            let formGroups = Dictionary(grouping: originals.filter { $0.objectPath.count == 2 }, by: { $0.objectPath[0] })
            guard !formGroups.isEmpty, rawRoots.count + formGroups.count > 1 else { return nil }
            let rootToRecord = Dictionary(uniqueKeysWithValues: textRoots.enumerated().map { ($0.element, $0.offset) })
            let selectedShows = Set(rawRoots.compactMap { rootToRecord[$0].map { stream.records[$0].showRange } })
            guard selectedShows.count == rawRoots.count else { return nil }
            let blockIndices = stream.blocks.indices.filter { index in
                stream.blocks[index].showRanges.contains { selectedShows.contains($0) }
            }
            var covered = Set<Int>()
            var units: [(root: Int, before: Int, after: Int, transform: CGAffineTransform)] = []
            guard let textPage = FPDFText_LoadPage(nativePage) else { return nil }
            defer { FPDFText_ClosePage(textPage) }
            for index in blockIndices {
                let block = stream.blocks[index]
                guard block.isSupported, losslessGraphicsStateIsSupported(block.graphicsStateNames, on: page) else { return nil }
                let roots = stream.records.indices.filter { block.showRanges.contains(stream.records[$0].showRange) }.map { textRoots[$0] }
                guard let first = roots.first, !roots.isEmpty else { return nil }
                for root in roots where !rawRoots.contains(root) {
                    guard let object = FPDFPage_GetObject(nativePage, Int32(root)),
                          FPDFTextObj_GetText(object, textPage, nil, 0) <= 2,
                          hasEmptyInkBounds(object) else { return nil }
                }
                covered.formUnion(roots)
                units.append((first, block.range.lowerBound, block.range.upperBound, block.transform))
            }
            var formIndices: [Int] = []
            for (root, targets) in formGroups {
                guard let form = FPDFPage_GetObject(nativePage, Int32(root)),
                      FPDFPageObj_GetType(form) == FPDF_PAGEOBJ_FORM,
                      formContainsOnlySelectedTextAndInertSpaces(form, selected: Set(targets.map { $0.objectPath[1] }),
                          on: nativePage),
                      let index = invocationRoots.firstIndex(of: root) else { return nil }
                let invocation = stream.forms[index]
                guard invocation.isSupported,
                      losslessGraphicsStateIsSupported(invocation.graphicsStateNames, on: page),
                      PDFBodyTextPageSnapshot.isBodyTextXObject(named: invocation.name, on: page),
                      try PDFBodyFormUsageAudit().isFormInvokedExactlyOnce(named: invocation.name, on: reference) else { return nil }
                // Only complete direct text children of our isolated Form are
                // supported, never another application's nested object graph.
                for child in 0..<Int(FPDFFormObj_CountObjects(form)) {
                    guard let object = FPDFFormObj_GetObject(form, UInt(child)),
                          FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT else { return nil }
                }
                covered.insert(root)
                formIndices.append(index)
                units.append((root, invocation.showRange.lowerBound, invocation.insertionOffset, invocation.transform))
            }
            let orderedRoots = covered.sorted()
            guard let firstRoot = orderedRoots.first, let lastRoot = orderedRoots.last,
                  orderedRoots == Array(firstRoot...lastRoot), covered.isSuperset(of: rawRoots),
                  let first = units.min(by: { $0.root < $1.root }),
                  let last = units.max(by: { $0.root < $1.root }) else { return nil }
            let before = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: Data(stream.data.prefix(first.before)))
            guard try withPage(before, body: { _, prefix in Int(FPDFPage_CountObjects(prefix)) == firstRoot }) else { return nil }
            let after = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: Data(stream.data.prefix(last.after)))
            guard try withPage(after, body: { _, prefix in
                guard Int(FPDFPage_CountObjects(prefix)) == lastRoot + 1 else { return false }
                for original in originals {
                    let object = try resolve(original.objectPath, on: prefix, requiringFinalLeaf: false).object
                    let actual = try description(of: object, on: prefix)
                    guard prefixTextMatches(actual.text, original.text),
                          approximatelyEqual(actual.glyphBounds, original.glyphBounds),
                          sameStyle(actual.style, original.style) else { return false }
                }
                return true
            }) else { return nil }
            return LosslessPlan(stream: stream, recordIndices: blockIndices, transform: first.transform,
                replacesForm: false, replacesBlocks: true, mixedFormIndices: formIndices.sorted(),
                mixedInsertionOffset: first.after,
                verifiedMixedTextFormRoots: Set(formGroups.keys))
        } catch { return nil }
    }

    private struct SourceRows {
        var text: [String]
        var baselines: [CGFloat]
        var units: [[Int]]
    }

    /// Only complete, independently validated text objects/blocks can survive.
    /// A block spanning several visual rows stays on the whole-replacement
    /// path; retaining one show could otherwise change the next show's advance.
    private static func sourceRows(for target: PDFBodyTextTarget, plan: LosslessPlan,
                                   style: InlineTextStyle, bounds: CGRect) -> SourceRows? {
        guard !plan.replacesForm, plan.mixedFormIndices.isEmpty, sameStyle(target.style, style),
              style.backgroundColor.alpha == 0, approximatelyEqual(target.bounds, bounds),
              let height = target.lineHeight, height.isFinite, height > 0 else { return nil }
        let originals = target.additionalObjects.isEmpty ? [target] : target.additionalObjects
        guard originals.count > 1,
              originals.allSatisfy({ $0.objectPath.count == 1 }),
              originals.map({ $0.objectPath[0] }) == originals.map({ $0.objectPath[0] }).sorted() else { return nil }
        var baselines: [CGFloat] = []
        var rowByRoot: [Int: Int] = [:]
        var rowText: [String] = []
        for original in originals {
            guard original.objectPath.count == 1, !original.text.contains("\n") else { return nil }
            if baselines.last.map({ abs($0 - original.baseline.y) > 1 }) ?? true {
                baselines.append(original.baseline.y)
                rowText.append("")
            }
            rowByRoot[original.objectPath[0]] = baselines.count - 1
            rowText[rowText.count - 1] += original.text
        }
        let lines = target.text.components(separatedBy: "\n")
        guard lines.count > 1, lines.count == baselines.count,
              zip(lines, rowText).allSatisfy({ selectionKey($0) == selectionKey($1) }) else { return nil }
        var units = [[Int]](repeating: [], count: lines.count)
        for unit in plan.recordIndices {
            let records = plan.replacesBlocks ? plan.stream.records.indices.filter {
                plan.stream.blocks[unit].showRanges.contains(plan.stream.records[$0].showRange)
            } : [unit]
            let rows = Set(records.compactMap { plan.recordRoots[$0].flatMap { rowByRoot[$0] } })
            guard rows.count == 1, let row = rows.first else { return nil }
            units[row].append(unit)
        }
        guard units.allSatisfy({ !$0.isEmpty }) else { return nil }
        return SourceRows(text: lines, baselines: baselines, units: units)
    }

    private static func replacingOriginalGlyph(
        on page: PDFPage, plan: LosslessPlan, target: PDFBodyTextTarget,
        text: String, style: InlineTextStyle, bounds: CGRect,
        nativePage: FPDF_PAGE, requireTagProof: Bool
    ) throws -> (copy: PDFBodyResourceCopyOutput, rewrite: PDFBodyLosslessRewriteReceipt)? {
        guard style == target.style, bounds == target.bounds, !plan.replacesForm,
              plan.mixedFormIndices.isEmpty, target.scannedReeditMetadata == nil,
              let pageRef = page.pageRef, plan.stream.data.count <= 2 * 1_024 * 1_024,
              text.utf16.count == target.text.utf16.count,
              let selected = target.initialSelectedRange, selected.length > 0 else { return nil }
        var change: (from: UInt16, to: UInt16)?
        for (index, pair) in zip(target.text.utf16, text.utf16).enumerated() where pair.0 != pair.1 {
            guard change == nil, NSLocationInRange(index, selected),
                  let from = UnicodeScalar(pair.0), let to = UnicodeScalar(pair.1),
                  !CharacterSet.whitespacesAndNewlines.contains(from),
                  !CharacterSet.whitespacesAndNewlines.contains(to) else { return nil }
            change = (pair.0, pair.1)
        }
        guard let change else { return nil }
        // Require unique source text within the verified span. The page-level
        // sequence and native geometry must then identify the exact correction.
        guard target.text.utf16.filter({ $0 == change.from }).count == 1,
              let textPage = FPDFText_LoadPage(nativePage) else { return nil }
        defer { FPDFText_ClosePage(textPage) }
        let blockStarts = plan.replacesBlocks
            ? Set(plan.recordIndices.map { plan.stream.blocks[$0].range.lowerBound }) : []
        let recordIndexes = plan.replacesBlocks ? plan.stream.records.indices.filter {
            blockStarts.contains(plan.stream.records[$0].blockStart)
        } : plan.recordIndices
        var matchingObjects = Set<FPDF_PAGEOBJECT>()
        let characterCount = FPDFText_CountChars(textPage)
        guard (1...maximumPageCharacters).contains(Int(characterCount)) else { return nil }
        for index in 0..<characterCount where FPDFText_GetUnicode(textPage, index) == UInt32(change.from) {
            if let object = FPDFText_GetTextObject(textPage, index) { matchingObjects.insert(object) }
        }
        var patch: PDFBodyTextGlyphSubstitution.Patch?
        for index in recordIndexes {
            guard let root = plan.recordRoots[index], let object = FPDFPage_GetObject(nativePage, Int32(root)) else { return nil }
            guard matchingObjects.contains(object) else { continue }
            if let match = try PDFBodyTextGlyphSubstitution.patch(record: plan.stream.records[index], page: pageRef,
                textPage: textPage, object: object, from: change.from, to: change.to,
                envelope: target.paintBounds, obstacles: target.protectedPaintBounds) {
                guard patch == nil else { return nil }
                patch = match
            }
        }
        guard let patch else { return nil }
        var receipt: PDFBodyLosslessRewriteReceipt?
        let content = try plan.stream.replacingGlyph(patch, capture: { receipt = $0 })
        guard let receipt else { return nil }
        if requireTagProof {
            var budget = PDFBodyEditedTagPreserver.Budget()
            guard (try? PDFBodyEditedTagPreserver.validateRewrite(receipt, donorName: nil, budget: &budget)) != nil else {
                return nil
            }
        }
        let output = try PDFBodyTextPageSnapshot.losslessData(for: page, contentOverride: content,
            donorPDF: nil, donorName: nil, droppingXObjectNames: [], glyphRewrite: receipt)
        guard try withPage(output.data, body: { _, candidate in
            guard let edited = FPDFText_LoadPage(candidate) else { return false }
            defer { FPDFText_ClosePage(edited) }
            return try PDFBodyTextGlyphSubstitution.hasSameLayout(textPage, edited, index: patch.characterIndex,
                to: change.to, envelope: target.paintBounds, obstacles: target.protectedPaintBounds)
        }) else { return nil }
        // A tagged correction must carry its page's original owners through
        // save. The worker checks the complete source and candidate graph.
        guard output.witness != nil else { return nil }
        return (output, receipt)
    }

    private static func losslessReplacement(on page: PDFPage, plan: LosslessPlan,
                                            target: PDFBodyTextTarget, text: String,
                                            style: InlineTextStyle, bounds: CGRect,
                                            preservingUnchangedRows: Bool = true,
                                            recordStructure: ((PDFBodyResourceCopyOutput, PDFBodyLosslessRewriteReceipt) -> Void)? = nil,
                                            paintObservation: PDFBodyTextFitDiagnostics.PaintObservation? = nil) throws -> Data {
        var donor: Data?
        var name: String?
        var invocation: String?
        var selectedUnits = plan.recordIndices
        var retainedSourceRows = false
        if !text.isEmpty {
            let mediaBox = page.bounds(for: .mediaBox)
            let sourceRows = preservingUnchangedRows && target.scannedReeditMetadata == nil
                ? sourceRows(for: target, plan: plan, style: style, bounds: bounds) : nil
            let rendered = try PDFBodyTextFitDiagnostics.withReplacementPhase(.donorGeneration, {
                try textPDFRendering(text, style: style, bounds: bounds, mediaBox: mediaBox,
                    visibleBox: mediaBox.intersection(page.bounds(for: .cropBox)),
                    baseline: approximatelyEqual(target.bounds, bounds) ? target.baseline : nil,
                    lineHeight: target.lineHeight, firstLineIndent: target.firstLineIndent,
                    sourceText: target.text, sourceStyle: target.style, sourceRuns: target.sourceRuns,
                    preserving: sourceRows, paintExtent: target.paintBounds,
                    protectedPaintBounds: target.protectedPaintBounds, paintObservation: paintObservation)
            })
            donor = rendered.data
            if let metadata = target.scannedReeditMetadata {
                let envelope = PDFScannedBodyTextEditor.Source(snapshot: Data(), rootIndices: [],
                    erasedRects: metadata.erasedRects, paperColor: metadata.paperColor)
                guard try withPage(rendered.data, body: { _, native in
                    PDFScannedBodyTextEditor.replacementFits(native, source: envelope, tolerance: 0)
                }), try PDFScannedInkPlacement.fits(rendered.data, erasedRects: metadata.erasedRects) else {
                    PDFBodyTextFitDiagnostics.record(.scannedReeditEnvelope, bounds: bounds,
                        paintExtent: metadata.bounds, obstacleCount: metadata.erasedRects.count,
                        paintObservation: paintObservation)
                    throw Failure.doesNotFit
                }
            }
            if let sourceRows, !rendered.retainedRows.isEmpty {
                retainedSourceRows = true
                let retained = Set(rendered.retainedRows.flatMap { sourceRows.units[$0] })
                selectedUnits.removeAll { retained.contains($0) }
                if selectedUnits.isEmpty {
                    return try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessSnapshotWrite, {
                        try PDFBodyTextPageSnapshot.data(for: page, contentOverride: plan.stream.data)
                    })
                }
            }
            let resource = try PDFBodyTextPageSnapshot.unusedXObjectName(for: page)
            name = resource
            // Retaining an earlier row moves the insertion point. Its source
            // graphics transform may differ even when page baselines agree.
            let insertionTransform: CGAffineTransform
            if let first = selectedUnits.first, !plan.replacesForm, plan.mixedInsertionOffset == nil {
                insertionTransform = plan.replacesBlocks ? plan.stream.blocks[first].transform : plan.stream.records[first].transform
            } else { insertionTransform = plan.transform }
            let inverse = insertionTransform.inverted()
            let values = [inverse.a, inverse.b, inverse.c, inverse.d, inverse.tx, inverse.ty]
            guard values.allSatisfy(\.isFinite),
                  abs(insertionTransform.a * insertionTransform.d - insertionTransform.b * insertionTransform.c) > 0.000001 else {
                throw Failure.unsupported
            }
            let matrix = try values.map(PDFDecimalNumber.string)
                .joined(separator: " ")
            invocation = "q \(matrix) cm /\(resource) Do Q"
        }
        var rewriteReceipt: PDFBodyLosslessRewriteReceipt?
        let captureRewrite: ((PDFBodyLosslessRewriteReceipt) -> Void)? = recordStructure.map { _ in
            { rewriteReceipt = $0 }
        }
        let content: Data
        if let offset = plan.mixedInsertionOffset {
            content = try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessRewrite, {
                try plan.stream.rewritingMixed(blockIndices: selectedUnits,
                    formIndices: plan.mixedFormIndices, insertionOffset: offset, donorInvocation: invocation, capture: captureRewrite)
            })
        } else if plan.replacesBlocks {
            content = try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessRewrite, {
                try plan.stream.rewritingBlocks(blockIndices: selectedUnits, donorInvocation: invocation, capture: captureRewrite)
            })
        } else if plan.replacesForm {
            content = try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessRewrite, {
                try plan.stream.rewritingForms(recordIndices: plan.recordIndices, donorInvocation: invocation, capture: captureRewrite)
            })
        } else {
            content = try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessRewrite, {
                try plan.stream.rewriting(recordIndices: selectedUnits, donorInvocation: invocation, capture: captureRewrite)
            })
        }
        let removedResources = Set((plan.replacesForm ? plan.recordIndices : plan.mixedFormIndices)
            .map { plan.stream.forms[$0].name })
        let updatedScanMetadata: Data?
        if donor != nil, let metadata = target.scannedReeditMetadata {
            updatedScanMetadata = try metadata.replacingProgram(content).encoded()
        } else { updatedScanMetadata = nil }
        let copied: PDFBodyResourceCopyOutput?
        let output: Data
        if recordStructure != nil, rewriteReceipt != nil {
            let result = try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessSnapshotWrite, {
                try PDFBodyTextPageSnapshot.losslessData(for: page, contentOverride: content,
                    donorPDF: donor, donorName: name, droppingXObjectNames: removedResources,
                    donorLayoutBounds: donor == nil ? nil : target.paintBounds.offsetBy(
                        dx: -page.bounds(for: .mediaBox).minX, dy: -page.bounds(for: .mediaBox).minY),
                    donorScannedErasureMetadata: updatedScanMetadata)
            })
            copied = result; output = result.data
        } else {
            copied = nil
            output = try PDFBodyTextFitDiagnostics.withReplacementPhase(.losslessSnapshotWrite, {
                try PDFBodyTextPageSnapshot.data(for: page, contentOverride: content,
                    donorPDF: donor, donorName: name, droppingXObjectNames: removedResources,
                    donorLayoutBounds: donor == nil ? nil : target.paintBounds.offsetBy(
                        dx: -page.bounds(for: .mediaBox).minX, dy: -page.bounds(for: .mediaBox).minY),
                    donorScannedErasureMetadata: updatedScanMetadata)
            })
        }
        if retainedSourceRows {
            // An optimization must not turn a previously editable paragraph
            // into a mixed structure our next edit cannot safely resolve.
            let canReselect: Bool
            if let check = PDFDocument(data: output), let checkPage = check.page(at: 0),
               let pageText = checkPage.string,
               let range = matchingRange(of: text, in: pageText,
                   within: NSRange(location: 0, length: pageText.utf16.count)),
               let selection = checkPage.selection(for: range),
               bounds.insetBy(dx: -2, dy: -2).contains(selection.bounds(for: checkPage)) {
                canReselect = (try? Self.target(on: checkPage, selection: selection))
                    .map { selectionKey($0.text) == selectionKey(text) } ?? false
            } else { canReselect = false }
            if !canReselect {
                return try losslessReplacement(on: page, plan: plan, target: target,
                    text: text, style: style, bounds: bounds, preservingUnchangedRows: false, recordStructure: recordStructure,
                    paintObservation: paintObservation)
            }
        }
        // Publish only the final successful optimization/fallback branch.
        if let copied, let rewriteReceipt { recordStructure?(copied, rewriteReceipt) }
        return output
    }

    /// RGB/alpha text controls cannot reproduce soft masks, custom transfer
    /// functions or blending. Reject these only when active on the text being
    /// edited; unrelated artwork remains untouched by the lossless route.
    private static func losslessGraphicsStateIsSupported(_ names: [String], on page: PDFPage) -> Bool {
        guard let reference = page.pageRef else { return false }
        let content = CGPDFContentStreamCreateWithPage(reference)
        defer { CGPDFContentStreamRelease(content) }
        for name in names {
            guard let object = name.withCString({ CGPDFContentStreamGetResource(content, "ExtGState", $0) }) else {
                return false
            }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return false }
            for (key, allowed) in [("BM", Set(["Normal", "Compatible"])),
                                   ("SMask", Set(["None"])),
                                   ("TR", Set(["Identity", "Default"])),
                                   ("TR2", Set(["Identity", "Default"]))] {
                var value: CGPDFObjectRef?
                guard CGPDFDictionaryGetObject(dictionary, key, &value), let value else { continue }
                var mode: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(value, .name, &mode), let mode,
                      allowed.contains(String(cString: mode)) else { return false }
            }
        }
        return true
    }

    private static func validateNativeGraphics(_ page: PDFPage, nativePage: FPDF_PAGE, rejectingSharedForms: Bool) throws {
        guard let reference = page.pageRef else { throw Failure.unreadable }
        let audit = PDFBodyFormUsageAudit()
        do {
            let repeated = try audit.hasRepeatedForm(on: reference)
            if audit.hasUnsupportedPaint || (rejectingSharedForms && (repeated || audit.hasUnsafeNestedCompositing)) {
                throw Failure.unsupported
            }
            // CoreGraphics consumes inline-image syntax internally and does
            // not reliably invoke BI callbacks. Each native image must have a
            // matching external-image Do invocation; extra images are inline
            // and would be omitted by PDFium's content generator.
            var remaining = maximumObjects
            func imageCount(_ parent: FPDF_PAGEOBJECT?, depth: Int) throws -> Int {
                guard depth < maximumDepth else { throw Failure.tooComplex }
                let count = parent.map(FPDFFormObj_CountObjects) ?? FPDFPage_CountObjects(nativePage)
                guard count >= 0, count <= remaining else { throw Failure.tooComplex }
                remaining -= Int(count)
                var images = 0
                for index in 0..<Int(count) {
                    let candidate = parent.flatMap { FPDFFormObj_GetObject($0, UInt(index)) }
                        ?? (parent == nil ? FPDFPage_GetObject(nativePage, Int32(index)) : nil)
                    guard let object = candidate else { throw Failure.unreadable }
                    switch FPDFPageObj_GetType(object) {
                    case FPDF_PAGEOBJ_FORM: images += try imageCount(object, depth: depth + 1)
                    case FPDF_PAGEOBJ_IMAGE: images += 1
                    case FPDF_PAGEOBJ_TEXT, FPDF_PAGEOBJ_PATH: break
                    default: throw Failure.unsupported
                    }
                }
                return images
            }
            guard try imageCount(nil, depth: 0) == audit.externalImageInvocations else { throw Failure.unsupported }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.tooComplex
        }
    }

    /// PDFium 8086's generator writes only DeviceRGB/Gray paint. Its public
    /// getters resolve supported RGB ICC colors, so transfer those
    /// rendered RGBA values before regeneration instead of silently inheriting
    /// black. Images retain their original pixel streams/color profiles. This
    /// intentionally preserves display color, not press/spot-color semantics.
    private static func preserveSolidColors(on page: FPDF_PAGE) throws {
        var remaining = maximumObjects
        func visit(_ parent: FPDF_PAGEOBJECT?, depth: Int) throws {
            guard depth < maximumDepth else { throw Failure.tooComplex }
            let count = parent.map(FPDFFormObj_CountObjects) ?? FPDFPage_CountObjects(page)
            guard count >= 0, count <= remaining else { throw Failure.tooComplex }
            remaining -= Int(count)
            for index in 0..<Int(count) {
                let candidate = parent.flatMap { FPDFFormObj_GetObject($0, UInt(index)) }
                    ?? (parent == nil ? FPDFPage_GetObject(page, Int32(index)) : nil)
                guard let object = candidate else { throw Failure.unreadable }
                let type = FPDFPageObj_GetType(object)
                guard [FPDF_PAGEOBJ_TEXT, FPDF_PAGEOBJ_PATH, FPDF_PAGEOBJ_FORM, FPDF_PAGEOBJ_IMAGE].contains(type) else {
                    throw Failure.unsupported
                }
                if type == FPDF_PAGEOBJ_FORM { try visit(object, depth: depth + 1) }
                // Color states on image masks/forms can be inherited. Preserve
                // any available state while leaving the image itself untouched.
                var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 0
                if FPDFPageObj_GetFillColor(object, &r, &g, &b, &a) != 0 {
                    guard FPDFPageObj_SetFillColor(object, r, g, b, a) != 0 else { throw Failure.failed }
                }
                if FPDFPageObj_GetStrokeColor(object, &r, &g, &b, &a) != 0 {
                    guard FPDFPageObj_SetStrokeColor(object, r, g, b, a) != 0 else { throw Failure.failed }
                }
            }
        }
        try visit(nil, depth: 0)
    }

    private static func snapshot(_ page: PDFPage) throws -> Data {
        // Preserve the exact source content/resources. PDFKit's convenience
        // page serialization can redraw, shift origins and re-encode glyphs.
        let data = try PDFBodyTextPageSnapshot.data(for: page)
        guard data.count <= maximumPageBytes else { throw Failure.tooComplex }
        return data
    }

    #if DEBUG || EMBER_SCAN_SCOPE_TESTING
    /// Test-only scope observations; no native handle or reusable permission escapes.
    static func scannedAncestorScopeChecksForTesting(on page: PDFPage, unrelated: PDFPage) throws -> [Bool] {
        try ScannedAncestorClips.lifetimeChecks(snapshot: PDFBodyTextPageSnapshot.data(for: page),
            unrelated: PDFBodyTextPageSnapshot.data(for: unrelated))
    }
    #endif

    /// Ephemeral permission for one directly owned scan Form. Native handles,
    /// the immutable snapshot and the negative result live only inside withPage.
    /// Nested loads install their own scope and restore this exact instance.
    @MainActor
    private enum ScannedAncestorClips {
        final class Scope {
            let snapshot: Data
            let document: FPDF_DOCUMENT
            let page: FPDF_PAGE
            var attemptedRoot: Int?
            var witness: Witness?
            var invalidated = false
            init(snapshot: Data, document: FPDF_DOCUMENT, page: FPDF_PAGE) {
                self.snapshot = snapshot; self.document = document; self.page = page
            }
        }
        struct Witness {
            let root: Int
            let object: FPDF_PAGEOBJECT
            let name: String
            let range: Range<Int>
            let insertionOffset: Int
            let transform: CGAffineTransform
            let programDigest: SHA256.Digest
            func matches(_ record: PDFBodyTextContentStream.FormRecord, program: Data) -> Bool {
                record.name == name && record.showRange == range && record.insertionOffset == insertionOffset
                    && record.transform == transform && SHA256.hash(data: program) == programDigest
            }
        }
        private static var current: Scope?
        static func withScope<T>(snapshot: Data, document: FPDF_DOCUMENT, page: FPDF_PAGE,
                                  body: () throws -> T) rethrows -> T {
            let previous = current
            current = Scope(snapshot: snapshot, document: document, page: page)
            defer { current = previous }
            return try body()
        }
        static func invalidate(on page: FPDF_PAGE) {
            guard let scope = current, scope.page == page else { return }
            scope.invalidated = true; scope.witness = nil
        }
        static func cached(on page: FPDF_PAGE, root: Int) -> Witness? {
            guard let scope = current, !scope.invalidated, scope.page == page,
                  let value = scope.witness, value.root == root,
                  FPDFPage_GetObject(page, Int32(root)) == value.object else { return nil }
            return value
        }
        static func permits(on page: FPDF_PAGE, root: Int, object: FPDF_PAGEOBJECT) throws -> Bool {
            guard let scope = current, !scope.invalidated, scope.page == page,
                  FPDFPage_GetObject(page, Int32(root)) == object else { return false }
            if scope.attemptedRoot == nil {
                scope.attemptedRoot = root
                do { scope.witness = try prove(scope: scope, root: root, object: object) }
                catch is CancellationError { throw CancellationError() }
                catch { scope.witness = nil }
            }
            return current === scope && cached(on: page, root: root)?.object == object
        }
        #if DEBUG || EMBER_SCAN_SCOPE_TESTING
        static func lifetimeChecks(snapshot: Data, unrelated: Data) throws -> [Bool] {
            let previous = current
            weak var expired: Scope?
            var checks: [Bool] = []
            try withPage(snapshot) { _, page in
                guard let scope = current else { throw Failure.unreadable }
                expired = scope
                let count = Int(FPDFPage_CountObjects(page))
                guard count > 0, count <= maximumObjects,
                      let root = (0..<count).first(where: { index in
                          guard let object = FPDFPage_GetObject(page, Int32(index)),
                                FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM,
                                let clip = FPDFPageObj_GetClipPath(object) else { return false }
                          return FPDFClipPath_CountPaths(clip) > 0
                      }), let object = FPDFPage_GetObject(page, Int32(root)) else { throw Failure.unreadable }
                checks.append(try permits(on: page, root: root, object: object))
                checks.append(try !permits(on: page, root: root+1, object: object))
                try withPage(unrelated) { _, foreign in
                    checks.append(try !permits(on: page, root: root, object: object))
                    let foreignCount = Int(FPDFPage_CountObjects(foreign))
                    checks.append(try (0..<foreignCount).allSatisfy { index in
                        guard let value = FPDFPage_GetObject(foreign, Int32(index)) else { return false }
                        return try !permits(on: foreign, root: index, object: value)
                    })
                }
                checks.append(try current === scope && permits(on: page, root: root, object: object))
                invalidate(on: page)
                checks.append(try !permits(on: page, root: root, object: object))
            }
            checks.append(current === previous)
            checks.append(expired == nil)
            return checks
        }
        #endif
        fileprivate struct Fingerprint: Equatable {
            let matrix: [Float]
            let bounds: [Float]
            let children: [Child]
        }
        fileprivate struct Child: Equatable {
            let matrix: [Float]
            let bounds: [Float]
            let fill: [UInt32]
            let text: [UInt16]
            let fontSize: Float
            let program: SHA256.Digest
        }
        fileprivate static func fingerprint(_ form: FPDF_PAGEOBJECT, page: FPDF_PAGE) throws -> Fingerprint? {
            let count = Int(FPDFFormObj_CountObjects(form))
            guard count > 0, count <= 512, let textPage = FPDFText_LoadPage(page) else { return nil }
            defer { FPDFText_ClosePage(textPage) }
            let characters = FPDFText_CountChars(textPage)
            guard characters >= 0, characters <= maximumPageCharacters else { return nil }
            func geometry(_ object: FPDF_PAGEOBJECT) -> ([Float],[Float])? {
                var matrix = FS_MATRIX(), l: Float = 0, b: Float = 0, r: Float = 0, t: Float = 0
                guard FPDFPageObj_GetMatrix(object, &matrix) != 0,
                      FPDFPageObj_GetBounds(object, &l, &b, &r, &t) != 0 else { return nil }
                let values = [matrix.a,matrix.b,matrix.c,matrix.d,matrix.e,matrix.f]
                let bounds = [l,b,r,t]
                guard (values+bounds).allSatisfy(\.isFinite) else { return nil }
                return (values,bounds)
            }
            guard let parent = geometry(form) else { return nil }
            var children: [Child] = [], programs: [FPDF_FONT:SHA256.Digest] = [:]
            var totalProgramBytes = 0, totalTextUnits = 0
            for index in 0..<count {
                try Task.checkCancellation()
                guard let child = FPDFFormObj_GetObject(form, UInt(index)),
                      FPDFPageObj_GetType(child) == FPDF_PAGEOBJ_TEXT,
                      FPDFTextObj_GetTextRenderMode(child) == FPDF_TEXTRENDERMODE_FILL,
                      FPDFPageObj_HasTransparency(child) == 0,
                      let shape = geometry(child), let font = FPDFTextObj_GetFont(child),
                      FPDFFont_GetIsEmbedded(font) == 1 else { return nil }
                var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 0
                var size: Float = 0
                guard FPDFPageObj_GetFillColor(child, &red, &green, &blue, &alpha) != 0, alpha == 255,
                      FPDFTextObj_GetFontSize(child, &size) != 0, size.isFinite, size > 0 else { return nil }
                let length = Int(FPDFTextObj_GetText(child, textPage, nil, 0))
                guard length >= 2, length % 2 == 0, length <= 100_002,
                      totalTextUnits <= 50_000 - (length/2-1) else { return nil }
                totalTextUnits += length/2-1
                var text = [UInt16](repeating: 0, count: length/2)
                guard FPDFTextObj_GetText(child, textPage, &text, UInt(length)) == UInt(length) else { return nil }
                let digest: SHA256.Digest
                if let cached = programs[font] { digest = cached }
                else {
                    var length = 0
                    guard programs.count < 64, FPDFFont_GetFontData(font, nil, 0, &length) != 0,
                          length > 0, length <= 16*1_024*1_024,
                          totalProgramBytes <= 32*1_024*1_024-length else { return nil }
                    var data = Data(count: length)
                    let actual = data.withUnsafeMutableBytes {
                        FPDFFont_GetFontData(font, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), length, &length)
                    }
                    guard actual != 0, length == data.count else { return nil }
                    digest = SHA256.hash(data: data); programs[font] = digest; totalProgramBytes += length
                }
                children.append(Child(matrix: shape.0, bounds: shape.1, fill: [red,green,blue,alpha],
                    text: text, fontSize: size, program: digest))
            }
            return Fingerprint(matrix: parent.0, bounds: parent.1, children: children)
        }
        private static func prove(scope: Scope, root: Int, object: FPDF_PAGEOBJECT) throws -> Witness? {
            guard root >= 0, root < maximumObjects, FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM,
                  let factory = PDFRawStreamProvenance.createdDocument(data: scope.snapshot),
                  factory.pageCount == 1, let page = factory.page(at: 0), let reference = page.pageRef,
                  page.bounds(for: .mediaBox).origin == .zero else { return nil }
            return try withExtendedLifetime(factory) {
                let data = try PDFBodyTextPageSnapshot.contentData(for: page)
                let stream = try PDFBodyTextContentStream.parse(data)
                guard stream.forms.count <= 64,
                      try PDFBodyFormUsageAudit().hasSafeScannedErasureResources(on: reference),
                      let actual = try fingerprint(object, page: scope.page) else { return nil }
                var matches: [Witness] = []
                for record in stream.forms where record.isSupported {
                    try Task.checkCancellation()
                    guard PDFBodyTextPageSnapshot.isBodyTextXObject(named: record.name, on: page),
                          let raw = PDFBodyTextPageSnapshot.scannedErasureMetadata(named: record.name, on: page),
                          let metadata = try? PDFScannedErasureMetadata.decode(raw),
                          losslessGraphicsStateIsSupported(record.graphicsStateNames, on: page),
                          try PDFBodyFormUsageAudit().isFormInvokedExactlyOnce(named: record.name, on: reference),
                          try PDFBodyFormUsageAudit().hasSafeUnclippedTextForm(named: record.name, on: reference),
                          try metadata.provesCurrentProgram(data, mediaBox: page.bounds(for: .mediaBox),
                              donorName: record.name, donorRange: record.showRange, requiringPositiveDonorClip: true) else { continue }
                    let envelope = PDFScannedBodyTextEditor.Source(snapshot: Data(), rootIndices: [],
                        erasedRects: metadata.erasedRects, paperColor: metadata.paperColor)
                    guard try PDFScannedBodyTextEditor.currentTextFormFits(object, on: scope.page,
                        source: envelope, independentlyUnclipped: true) else { continue }
                    let before = try PDFBodyTextPageSnapshot.data(for: page,
                        contentOverride: Data(data.prefix(record.showRange.lowerBound)))
                    guard try withPage(before, body: { _, prefix in Int(FPDFPage_CountObjects(prefix)) == root }) else { continue }
                    let after = try PDFBodyTextPageSnapshot.data(for: page,
                        contentOverride: Data(data.prefix(record.insertionOffset)))
                    guard try withPage(after, body: { _, prefix in
                        guard Int(FPDFPage_CountObjects(prefix)) == root+1,
                              let candidate = FPDFPage_GetObject(prefix, Int32(root)),
                              FPDFPageObj_GetType(candidate) == FPDF_PAGEOBJ_FORM,
                              try fingerprint(candidate, page: prefix) == actual else { return false }
                        return try PDFScannedBodyTextEditor.currentTextFormFits(candidate, on: prefix,
                            source: envelope, independentlyUnclipped: true)
                    }) else { continue }
                    matches.append(Witness(root: root, object: object, name: record.name, range: record.showRange,
                        insertionOffset: record.insertionOffset, transform: record.transform, programDigest: SHA256.hash(data: data)))
                }
                guard matches.count == 1 else { return nil }
                return matches[0]
            }
        }
    }

    private static func withPage<T>(_ data: Data, sourceDocument: PDFDocument? = nil,
                                    body: (FPDF_DOCUMENT, FPDF_PAGE) throws -> T) throws -> T {
        _ = initialized
        guard !data.isEmpty, data.count <= maximumPageBytes else { throw Failure.tooComplex }
        // LoadMemDocument borrows this exact buffer until CloseDocument.
        return try data.withUnsafeBytes { buffer in
            guard let document = FPDF_LoadMemDocument64(buffer.baseAddress, data.count, nil) else { throw Failure.unreadable }
            defer { FPDF_CloseDocument(document) }
            guard FPDF_GetPageCount(document) == 1, let page = FPDF_LoadPage(document, 0) else { throw Failure.unreadable }
            defer { FPDF_ClosePage(page) }
            return try ScannedAncestorClips.withScope(snapshot: data, document: document, page: page) {
                try EmbeddedSourceFonts.withScope(owner: sourceDocument, snapshot: data, nativePage: page) { try body(document, page) }
            }
        }
    }

    private static func path(to needle: FPDF_PAGEOBJECT, on page: FPDF_PAGE) throws -> [Int] {
        var remaining = maximumObjects
        func visit(_ parent: FPDF_PAGEOBJECT?, prefix: [Int]) throws -> [Int]? {
            guard prefix.count < maximumDepth else { throw Failure.tooComplex }
            let count = parent.map(FPDFFormObj_CountObjects) ?? FPDFPage_CountObjects(page)
            guard count >= 0, count <= remaining else { throw Failure.tooComplex }
            remaining -= Int(count)
            for index in 0..<Int(count) {
                let candidate = parent.flatMap { FPDFFormObj_GetObject($0, UInt(index)) }
                    ?? (parent == nil ? FPDFPage_GetObject(page, Int32(index)) : nil)
                guard let candidate else { throw Failure.unreadable }
                let next = prefix + [index]
                if candidate == needle { return next }
                if FPDFPageObj_GetType(candidate) == FPDF_PAGEOBJ_FORM,
                   let found = try visit(candidate, prefix: next) { return found }
            }
            return nil
        }
        guard let found = try visit(nil, prefix: []) else { throw Failure.unreadable }
        return found
    }

    /// A selection can touch hundreds of runs. Traverse native object order
    /// once rather than restarting at the first page object for every run.
    private static func paths(to needles: Set<FPDF_PAGEOBJECT>, on page: FPDF_PAGE) throws -> [FPDF_PAGEOBJECT: [Int]] {
        var remaining = maximumObjects
        var result: [FPDF_PAGEOBJECT: [Int]] = [:]
        func visit(_ parent: FPDF_PAGEOBJECT?, prefix: [Int]) throws {
            guard prefix.count < maximumDepth else { throw Failure.tooComplex }
            let count = parent.map(FPDFFormObj_CountObjects) ?? FPDFPage_CountObjects(page)
            guard count >= 0, count <= remaining else { throw Failure.tooComplex }
            remaining -= Int(count)
            for index in 0..<Int(count) {
                if result.count == needles.count { return }
                let object = parent.flatMap { FPDFFormObj_GetObject($0, UInt(index)) }
                    ?? (parent == nil ? FPDFPage_GetObject(page, Int32(index)) : nil)
                guard let object else { throw Failure.unreadable }
                let next = prefix + [index]
                if needles.contains(object) { result[object] = next }
                if FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM {
                    try visit(object, prefix: next)
                }
            }
        }
        try visit(nil, prefix: [])
        guard result.count == needles.count else { throw Failure.unreadable }
        return result
    }

    private static func resolve(_ path: [Int], on page: FPDF_PAGE, requiringFinalLeaf: Bool = true) throws -> (object: FPDF_PAGEOBJECT, parent: FPDF_PAGEOBJECT?) {
        guard !path.isEmpty, path.count <= maximumDepth else { throw Failure.changed }
        var parent: FPDF_PAGEOBJECT?
        for (depth, index) in path.enumerated() {
            guard index >= 0, index < maximumObjects else { throw Failure.changed }
            // PDFium does not safely rewrite partially retained Form streams.
            // A nested ancestor must be a single-child chain, so removing the
            // full text paragraph also removes every edited ancestor Form.
            if let parent {
                let count = Int(FPDFFormObj_CountObjects(parent))
                if depth < path.count - 1 {
                    guard count == 1, index == 0 else { throw Failure.unsupported }
                } else if requiringFinalLeaf, index != count - 1 {
                    throw Failure.unsupported
                }
            }
            let object = parent.flatMap { FPDFFormObj_GetObject($0, UInt(index)) }
                ?? (parent == nil ? FPDFPage_GetObject(page, Int32(index)) : nil)
            guard let object else { throw Failure.changed }
            if depth == path.count - 1 {
                guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT else { throw Failure.changed }
                return (object, parent)
            }
            guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM else { throw Failure.changed }
            if let clip = FPDFPageObj_GetClipPath(object), FPDFClipPath_CountPaths(clip) > 0 {
                guard depth == 0, path.count == 2,
                      try ScannedAncestorClips.permits(on: page, root: index, object: object) else { throw Failure.unsupported }
            }
            var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, alpha: UInt32 = 255
            if FPDFPageObj_GetFillColor(object, &r, &g, &b, &alpha) != 0, alpha != 255 { throw Failure.unsupported }
            parent = object
        }
        throw Failure.changed
    }

    private struct Description {
        let text: String
        let bounds: CGRect
        let glyphBounds: CGRect
        let baseline: CGPoint
        let style: InlineTextStyle
        let horizontalAdvance: CGFloat?
        let ownedAdvance: CGFloat?
        let foreignTrailingWhitespaceLength: Int
        let leadingWhitespace: PDFBodyLeadingWhitespace.Proof?
        let usesSourceUnkernedAdvances: Bool
    }

    private static func leadingAdvance(for description: Description, content: String) -> CGFloat {
        guard let proof = description.leadingWhitespace,
              proof.fragments(for: content, offset: 0, remainderAdvance: description.horizontalAdvance) != nil else { return 0 }
        return proof.advance
    }

    private static func sourceRuns(for description: Description, content: String,
                                   offset: Int, baselineOffset: CGFloat) -> [InlineTextSourceRun] {
        let fallback = [InlineTextSourceRun(range: NSRange(location: offset, length: content.utf16.count),
            style: description.style, baselineOffset: baselineOffset, horizontalAdvance: description.horizontalAdvance,
            usesSourceUnkernedAdvances: description.usesSourceUnkernedAdvances)]
        guard let fragments = description.leadingWhitespace?.fragments(for: content, offset: offset,
            remainderAdvance: description.horizontalAdvance) else { return fallback }
        return fragments.map { InlineTextSourceRun(range: $0.range, style: description.style,
            baselineOffset: baselineOffset, horizontalAdvance: $0.horizontalAdvance,
            usesSourceUnkernedAdvances: description.usesSourceUnkernedAdvances) }
    }

    private static func description(of object: FPDF_PAGEOBJECT, on page: FPDF_PAGE) throws -> Description {
        guard let textPage = FPDFText_LoadPage(page) else { throw Failure.unreadable }
        defer { FPDFText_ClosePage(textPage) }
        let count = FPDFText_CountChars(textPage)
        guard count >= 0, count <= maximumPageCharacters else { throw Failure.tooComplex }
        return try describe(object, in: textPage, characterCount: count)
    }

    private static func describe(_ object: FPDF_PAGEOBJECT, in textPage: FPDF_TEXTPAGE, characterCount: Int32,
                                 characterIndices: [Int32]? = nil) throws -> Description {
        guard FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_FILL else { throw Failure.unsupported }
        if let clip = FPDFPageObj_GetClipPath(object), FPDFClipPath_CountPaths(clip) > 0 {
            throw Failure.unsupported
        }
        let byteCount = FPDFTextObj_GetText(object, textPage, nil, 0)
        guard byteCount >= 2, byteCount % 2 == 0, byteCount <= (InlineTextDraftLimiter.maximumUTF16CodeUnitCount + 1) * 2 else { throw Failure.tooComplex }
        var buffer = [UInt16](repeating: 0, count: Int(byteCount) / 2)
        guard FPDFTextObj_GetText(object, textPage, &buffer, byteCount) == byteCount else { throw Failure.unreadable }
        let text = String(decoding: buffer.dropLast(), as: UTF16.self)
        guard !text.isEmpty, !InlineTextDraftLimiter.limit(text).wasTruncated else { throw Failure.tooComplex }
        var glyphBounds = CGRect.null
        var firstIndex: Int32?
        var origin = CGPoint.zero
        var effectiveSize: CGFloat = 0
        var horizontalScale: CGFloat = 1
        var advanceRight: CGFloat?
        var ownedText = ""
        var leadingSamples: [PDFBodyLeadingWhitespace.Sample] = []
        var leadingEnded = false, leadingEvidenceValid = true
        var spacingSamples: [PDFBodySourceSpacing.Sample] = []
        var spacingEvidenceValid = true
        let indices: AnySequence<Int32>
        if let characterIndices { indices = AnySequence(characterIndices) }
        else {
            indices = AnySequence((0..<characterCount).lazy.filter {
                FPDFText_GetTextObject(textPage, $0) == object
            })
        }
        for index in indices {
            var matrix = FS_MATRIX()
            guard FPDFText_GetMatrix(textPage, index, &matrix) != 0,
                  [matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f].allSatisfy(\.isFinite),
                  abs(matrix.b) < 0.001, abs(matrix.c) < 0.001,
                  matrix.a > 0, matrix.d > 0,
                  (0.1...10).contains(matrix.a / matrix.d) else { throw Failure.unsupported }
            var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
            guard FPDFText_GetCharBox(textPage, index, &left, &right, &bottom, &top) != 0 else { throw Failure.unreadable }
            let box = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
            guard valid(box) else { throw Failure.unreadable }
            glyphBounds = glyphBounds.union(box)
            // Loose bounds include the glyph cell rather than just painted
            // ink. Use this run extent only to compensate a missing embedded
            // face, never to rescale an available original font.
            var loose = FS_RECTF()
            let unicode = FPDFText_GetUnicode(textPage, index)
            if spacingEvidenceValid {
                if spacingSamples.count < PDFBodySourceSpacing.maximumGlyphs {
                    var x = 0.0, y = 0.0
                    if unicode != 0, FPDFText_GetTextObject(textPage, index) == object,
                       FPDFText_GetCharOrigin(textPage, index, &x, &y) != 0 {
                        spacingSamples.append(.init(scalar: unicode, origin: CGPoint(x: x, y: y),
                            matrix: CGAffineTransform(a: CGFloat(matrix.a), b: CGFloat(matrix.b),
                                c: CGFloat(matrix.c), d: CGFloat(matrix.d), tx: 0, ty: 0),
                            generated: FPDFText_IsGenerated(textPage, index) != 0))
                    } else { spacingEvidenceValid = false }
                } else { spacingEvidenceValid = false }
            }
            if unicode != 0, let scalar = UnicodeScalar(unicode) { ownedText.unicodeScalars.append(scalar) }
            else { leadingEvidenceValid = false }
            if !leadingEnded, unicode == 0x20 || !leadingSamples.isEmpty {
                if leadingSamples.count <= PDFBodyLeadingWhitespace.maximumLeadingCharacters {
                    var x = 0.0, y = 0.0
                    if FPDFText_GetCharOrigin(textPage, index, &x, &y) != 0 {
                        leadingSamples.append(.init(scalar: unicode, origin: CGPoint(x: x, y: y),
                            linear: CGAffineTransform(a: CGFloat(matrix.a), b: CGFloat(matrix.b),
                                c: CGFloat(matrix.c), d: CGFloat(matrix.d), tx: 0, ty: 0),
                            generated: FPDFText_IsGenerated(textPage, index) != 0))
                    } else { leadingEvidenceValid = false }
                } else { leadingEvidenceValid = false }
            }
            if unicode != 0x20 { leadingEnded = true }
            if unicode != 10, unicode != 13,
               FPDFText_GetLooseCharBox(textPage, index, &loose) != 0,
               loose.right.isFinite, loose.left.isFinite, loose.right >= loose.left {
                advanceRight = max(advanceRight ?? CGFloat(loose.right), CGFloat(loose.right))
            }
            if firstIndex == nil {
                firstIndex = index
                var x = 0.0, y = 0.0
                guard FPDFText_GetCharOrigin(textPage, index, &x, &y) != 0 else { throw Failure.unreadable }
                origin = CGPoint(x: x, y: y)
                effectiveSize = CGFloat(FPDFText_GetFontSize(textPage, index)) * CGFloat(matrix.d)
                horizontalScale = CGFloat(matrix.a / matrix.d)
            }
        }
        guard firstIndex != nil, !glyphBounds.isNull,
              effectiveSize.isFinite,
              effectiveSize >= InlineTextStyle.minimumFontSize,
              effectiveSize <= InlineTextStyle.maximumFontSize else { throw Failure.unsupported }
        var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 255
        guard FPDFPageObj_GetFillColor(object, &red, &green, &blue, &alpha) != 0 else { throw Failure.unreadable }
        let source = sourceFont(object, size: effectiveSize, text: text)
        let font = source.font
        let style = InlineTextStyle(fontName: font.fontName, fontSize: effectiveSize,
                                   textColor: PDFTextColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                                                          blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255),
                                   backgroundColor: .clear, alignment: .left, horizontalScale: horizontalScale,
                                   sourceFont: source.lease)
        // Hit/layout metrics do not always contain the actual embedded glyph
        // ink (CJK ascenders and negative sidebearings). Keep the real origin.
        let bounds = CGRect(x: origin.x, y: origin.y + font.descender,
                            width: max(1, glyphBounds.maxX - origin.x),
                            height: max(1, font.ascender - font.descender)).union(glyphBounds)
        let advance = advanceRight.map { $0 - origin.x }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let foreignSuffix = text.hasPrefix(ownedText) ? String(text.dropFirst(ownedText.count)) : ""
        let foreignWhitespaceLength = foreignSuffix.allSatisfy { $0 == " " || $0 == "\t" }
            ? foreignSuffix.utf16.count : 0
        return Description(text: text, bounds: bounds, glyphBounds: glyphBounds, baseline: origin,
            style: style, horizontalAdvance: source.isSubstitute ? advance : nil,
            ownedAdvance: advance, foreignTrailingWhitespaceLength: foreignWhitespaceLength,
            leadingWhitespace: leadingEvidenceValid ? PDFBodyLeadingWhitespace.prove(nativeText: text,
                ownedText: ownedText, samples: leadingSamples, sourceOrigin: origin, fontSize: effectiveSize) : nil,
            usesSourceUnkernedAdvances: spacingEvidenceValid && !source.isSubstitute
                && text.utf16.elementsEqual(ownedText.utf16)
                && PDFBodySourceSpacing.evidence(text: ownedText, samples: spacingSamples,
                    availableFont: style.renderingFont(font)) != nil)
    }

    private static func sourceFont(_ object: FPDF_PAGEOBJECT, size: CGFloat, text: String) -> (font: NSFont, isSubstitute: Bool, lease: PDFBodyTextDocumentFonts.Lease?) {
        guard let font = FPDFTextObj_GetFont(object) else { return (.systemFont(ofSize: size), true, nil) }
        let count = FPDFFont_GetBaseFontName(font, nil, 0)
        var name = ""
        if count > 0, count <= 1_024 {
            var bytes = [CChar](repeating: 0, count: count)
            _ = FPDFFont_GetBaseFontName(font, &bytes, count)
            name = String(cString: bytes)
        }
        let unprefixed = name.split(separator: "+", maxSplits: 1).last.map(String.init) ?? name
        if let embedded = EmbeddedSourceFonts.font(from: font, size: size, covering: text) {
            return (embedded, false, EmbeddedSourceFonts.documentLease(for: font))
        }
        if !EmbeddedSourceFonts.shouldAvoidName(unprefixed),
           let installed = NSFont(name: unprefixed, size: size),
           !EmbeddedSourceFonts.shouldAvoidName(installed.fontName) { return (installed, false, nil) }
        let aliases = ["Times-Roman": "TimesNewRomanPSMT", "Times-Bold": "TimesNewRomanPS-BoldMT",
                       "Times-Italic": "TimesNewRomanPS-ItalicMT", "Times-BoldItalic": "TimesNewRomanPS-BoldItalicMT",
                       "Helvetica": "Helvetica", "Courier": "Courier"]
        if !EmbeddedSourceFonts.shouldAvoidName(unprefixed), let alias = aliases[unprefixed],
           let installed = NSFont(name: alias, size: size),
           !EmbeddedSourceFonts.shouldAvoidName(installed.fontName) { return (installed, false, nil) }
        // An embedded subset is not necessarily installed in macOS. Preserve
        // its broad family/weight/slant instead of turning a serif textbook
        // paragraph into a system sans font. The chosen font is shown by the UI.
        let flags = max(0, FPDFFont_GetFlags(font))
        let family = flags & 1 != 0 ? "Courier" : (flags & 2 != 0 ? "TimesNewRomanPSMT" : "Helvetica")
        var substitute = NSFont(name: family, size: size) ?? .systemFont(ofSize: size)
        let lowerName = unprefixed.lowercased()
        if sourceWeightSuggestsBold(FPDFFont_GetWeight(font)) || flags & (1 << 18) != 0 || lowerName.contains("bold") {
            substitute = NSFontManager.shared.convert(substitute, toHaveTrait: .boldFontMask)
        }
        var angle: Int32 = 0
        let hasAngle = FPDFFont_GetItalicAngle(font, &angle) != 0 && angle != 0
        if flags & 64 != 0 || hasAngle || lowerName.contains("italic") || lowerName.contains("oblique") {
            substitute = NSFontManager.shared.convert(substitute, toHaveTrait: .italicFontMask)
        }
        return (substitute, true, nil)
    }

    /// Invalid renderer estimates (for example2092) are not bold weights.
    /// This bounds fallback only; it does not restore an unavailable source face.
    static func sourceWeightSuggestsBold(_ weight: Int32) -> Bool {
        (100...900).contains(weight) && weight >= 600
    }

    /// CoreText registrations live only in this process. Retain their graphics
    /// fonts for the session so a detached editor's font name remains usable,
    /// and bound the store instead of evicting fonts from an open draft.
    /// PDF-only encodings and raw Type 1/CFF programs without a Unicode sfnt
    /// cmap keep the existing explicit substitute path.
    @MainActor
    private enum EmbeddedSourceFonts {
        private static let maximumProgramBytes = 16 * 1_024 * 1_024
        private static let maximumStoredBytes = 32 * 1_024 * 1_024
        private static var programs: [Data: CGFont] = [:]
        private static var storedBytes = 0
        private static var registeredNames = Set<String>()
        private static var exportedNames = Set<String>()
        private enum ScopedFont {
            case unavailable
            case unverifiedSubset(CGFont)
            case available(NSFont)
            case documentOwned(PDFBodyTextDocumentFonts.Lease)
            case verifiedSubset(NSFont, CGFont)
        }
        private static var scopedFonts: [FPDF_FONT: ScopedFont] = [:]
        private static var scopedOwner: PDFDocument?
        private static var scopedSnapshot: Data?
        private static var scopedNativePage: FPDF_PAGE?
        private static var scopedRejectedNames = Set<String>()

        static func shouldAvoidName(_ name: String) -> Bool {
            registeredNames.contains(name) || scopedRejectedNames.contains(name)
        }

        static func rememberExportedFont(_ font: CTFont) {
            let name = CTFontCopyPostScriptName(font) as String
            if registeredNames.contains(name) { exportedNames.insert(name) }
        }

        static func originalInkSnapshot(for page: FPDF_PAGE) -> Data? {
            guard page == scopedNativePage, let snapshot = scopedSnapshot,
                  snapshot.count <= PDFBodyTextOriginalGlyphInk.maximumSnapshotBytes else { return nil }
            return snapshot
        }

        static func withScope<T>(owner: PDFDocument? = nil, snapshot: Data? = nil,
                                 nativePage: FPDF_PAGE? = nil, _ body: () throws -> T) rethrows -> T {
            // Native handles can be reused after CloseDocument. Never cache
            // them across documents; nested prefix checks have their own map.
            let previous = scopedFonts
            let previousOwner = scopedOwner
            let previousSnapshot = scopedSnapshot, previousNativePage = scopedNativePage
            scopedSnapshot = snapshot; scopedNativePage = nativePage
            scopedOwner = owner ?? previousOwner
            let previousRejectedNames = scopedRejectedNames
            scopedFonts = [:]
            scopedRejectedNames = []
            defer {
                scopedFonts = previous; scopedRejectedNames = previousRejectedNames; scopedOwner = previousOwner
                scopedSnapshot = previousSnapshot; scopedNativePage = previousNativePage
            }
            return try body()
        }

        private static func covers(_ text: String, font: CTFont) -> Bool {
            let characters = Array(text.utf16).filter { ![9, 10, 13].contains($0) }
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            return !characters.isEmpty && CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        }

        static func documentLease(for source: FPDF_FONT) -> PDFBodyTextDocumentFonts.Lease? {
            if case .documentOwned(let lease)? = scopedFonts[source] { return lease }
            return nil
        }

        static func font(from source: FPDF_FONT, size: CGFloat, covering text: String) -> NSFont? {
            if let previous = scopedFonts[source] {
                switch previous {
                case .unavailable: return nil
                case .unverifiedSubset(let subset):
                    let memoryFont = CTFontCreateWithGraphicsFont(subset, size, nil, nil)
                    rejectKnownInstalledMismatch(subset, memoryFont: memoryFont, size: size, covering: text)
                    return nil
                case .documentOwned(let lease):
                    guard let font = lease.font(ofSize: size), covers(text, font: font as CTFont) else {
                        scopedRejectedNames.insert(lease.postScriptName)
                        scopedRejectedNames.insert(lease.postScriptName.split(separator: "+", maxSplits: 1).last.map(String.init) ?? lease.postScriptName)
                        return nil
                    }
                    return font
                case .available(let font):
                    guard let resized = NSFont(name: font.fontName, size: size), covers(text, font: resized as CTFont) else { return nil }
                    return resized
                case .verifiedSubset(let font, let subset):
                    guard let resized = NSFont(name: font.fontName, size: size) else { return nil }
                    guard subsetMatchesRegisteredFont(subset, registered: resized, covering: text) else {
                        let memoryFont = CTFontCreateWithGraphicsFont(subset, size, nil, nil)
                        // Missing Unicode mappings are inconclusive. A known
                        // mismatch must not reuse the installed name below.
                        if covers(text, font: memoryFont) { scopedRejectedNames.insert(font.fontName) }
                        return nil
                    }
                    return resized
                }
            }
            // Cache failures too: an unsupported subset shared by hundreds of
            // runs must not be repeatedly decoded and parsed on the UI thread.
            scopedFonts[source] = .unavailable
            guard FPDFFont_GetIsEmbedded(source) == 1 else { return nil }
            var length = 0
            guard FPDFFont_GetFontData(source, nil, 0, &length) != 0,
                  length > 12, length <= maximumProgramBytes else { return nil }
            var bytes = Data(count: length)
            let read = bytes.withUnsafeMutableBytes {
                FPDFFont_GetFontData(source, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), length, &length)
            }
            guard read != 0, length == bytes.count else { return nil }
            let signature = Array(bytes.prefix(4))
            guard signature == [0, 1, 0, 0] || signature == Array("OTTO".utf8)
                || signature == Array("true".utf8) else { return nil }
            let graphics: CGFont
            let cached = programs[bytes]
            if let cached { graphics = cached }
            else {
                guard programs.count < 64, bytes.count <= maximumStoredBytes - storedBytes,
                      let provider = CGDataProvider(data: bytes as CFData),
                      let candidate = CGFont(provider) else { return nil }
                graphics = candidate
            }
            let memoryFont = CTFontCreateWithGraphicsFont(graphics, size, nil, nil)
            guard let licensing = CTFontCopyTable(memoryFont, CTFontTableTag(kCTFontTableOS2), []) as Data? else {
                // Quartz can omit OS/2 when saving a subset. That does not
                // authorize registering its program. Reuse an already licensed
                // full face only after validating every requested glyph against
                // this subset; a matching PostScript name alone is insufficient.
                if let owner = scopedOwner,
                   let lease = PDFBodyTextDocumentFonts.lease(matchingSubsetWithoutOS2: graphics,
                                                              document: owner, covering: text),
                   let font = lease.font(ofSize: size) {
                    scopedFonts[source] = .documentOwned(lease)
                    return font
                }
                guard let registered = registeredFont(matching: graphics, size: size, covering: text) else {
                    scopedFonts[source] = .unverifiedSubset(graphics)
                    rejectKnownInstalledMismatch(graphics, memoryFont: memoryFont, size: size, covering: text)
                    return nil
                }
                scopedFonts[source] = .verifiedSubset(registered, graphics)
                return registered
            }
            guard licensing.count >= 10 else { return nil }
            let flags = UInt16(licensing[8]) << 8 | UInt16(licensing[9])
            if flags == 0x0008 {
                // Editable permission admits temporary document use, not this
                // process-wide registry. Keep the actual font object in a
                // document lease and never pick an earlier registered program.
                let name = CTFontCopyPostScriptName(memoryFont) as String
                guard !registeredNames.contains(name),
                      let owner = scopedOwner,
                      let lease = PDFBodyTextDocumentFonts.lease(program: bytes, document: owner, covering: text),
                      let font = lease.font(ofSize: size) else {
                    scopedRejectedNames.insert(name)
                    scopedRejectedNames.insert(name.split(separator: "+", maxSplits: 1).last.map(String.init) ?? name)
                    return nil
                }
                scopedFonts[source] = .documentOwned(lease)
                return font
            }
            // Quartz embeds a subset and this bounded registry lasts for the
            // process. Only installable embedding suits both lifetimes;
            // editable-only faces require document-owned in-memory leases.
            guard flags & 0x030F == 0 else {
                let name = CTFontCopyPostScriptName(memoryFont) as String
                scopedRejectedNames.insert(name)
                scopedRejectedNames.insert(name.split(separator: "+", maxSplits: 1).last.map(String.init) ?? name)
                return nil
            }
            guard covers(text, font: memoryFont) else { return nil }
            if cached == nil, let registered = registeredFont(matching: graphics, size: size, covering: text) {
                scopedFonts[source] = .verifiedSubset(registered, graphics)
                return registered
            }
            let name = CTFontCopyPostScriptName(memoryFont) as String
            if cached == nil {
                // CoreText can report successful registration of a second
                // program with this name while NSFont still resolves the first.
                // Only the verified glyph-equivalent subset route may reuse it.
                guard !registeredNames.contains(name) else { return nil }
                if let installed = NSFont(name: name, size: size) {
                    guard subsetMatchesRegisteredFont(graphics, registered: installed, covering: text) else {
                        scopedRejectedNames.insert(name)
                        return nil
                    }
                    scopedFonts[source] = .verifiedSubset(installed, graphics)
                    return installed
                }
                guard CTFontManagerRegisterGraphicsFont(graphics, nil) else { return nil }
            }
            guard let resolved = NSFont(name: name, size: size), resolved.fontName == name else {
                if cached == nil { CTFontManagerUnregisterGraphicsFont(graphics, nil) }
                return nil
            }
            if cached == nil {
                programs[bytes] = graphics
                storedBytes += bytes.count
                registeredNames.insert(name)
            }
            scopedFonts[source] = .available(resolved)
            return resolved
        }

        private static func rejectKnownInstalledMismatch(_ subset: CGFont, memoryFont: CTFont,
                                                         size: CGFloat, covering text: String) {
            guard covers(text, font: memoryFont), let name = subset.postScriptName as String? else { return }
            let components = name.split(separator: "+", maxSplits: 1)
            let prefix = components.first.map(String.init) ?? ""
            let isSubsetPrefix = components.count == 2 && prefix.utf8.count == 6
                && prefix.utf8.allSatisfy { (65...90).contains($0) }
            let unprefixed = isSubsetPrefix ? String(components[1]) : name
            guard let installed = NSFont(name: unprefixed, size: size),
                  !subsetMatchesRegisteredFont(subset, registered: installed, covering: text) else { return }
            scopedRejectedNames.insert(unprefixed)
            scopedRejectedNames.insert(installed.fontName)
        }

        private static func registeredFont(matching subset: CGFont, size: CGFloat, covering text: String) -> NSFont? {
            guard let subsetName = subset.postScriptName as String? else { return nil }
            let components = subsetName.split(separator: "+", maxSplits: 1)
            let prefix = components.first.map(String.init) ?? ""
            let isSubsetPrefix = components.count == 2 && prefix.utf8.count == 6
                && prefix.utf8.allSatisfy { (65...90).contains($0) }
            let unprefixed = isSubsetPrefix ? String(components[1]) : subsetName
            for program in programs.values {
                guard let name = program.postScriptName as String?, name == unprefixed,
                      registeredNames.contains(name), exportedNames.contains(name),
                      let font = NSFont(name: name, size: size),
                      subsetMatchesRegisteredFont(subset, registered: font, covering: text) else { continue }
                return font
            }
            return nil
        }

        private static func subsetMatchesRegisteredFont(_ subset: CGFont, registered: NSFont,
                                                         covering text: String) -> Bool {
            // Compare in design units, so preview zoom or the source font size
            // cannot hide differing outlines or advances. Deduplicating Unicode
            // units bounds repeated paragraph text without skipping any glyph.
            let units = CTFontGetUnitsPerEm(registered as CTFont)
            guard units > 0, subset.unitsPerEm == Int32(units) else { return false }
            let subsetFont = CTFontCreateWithGraphicsFont(subset, CGFloat(units), nil, nil)
            let fullFont = CTFontCreateCopyWithAttributes(registered as CTFont, CGFloat(units), nil, nil)
            let characters = Array(Set(text.utf16.filter { ![9, 10, 13].contains($0) })).sorted()
            guard !characters.isEmpty, characters.count <= 512 else { return false }
            var subsetGlyphs = [CGGlyph](repeating: 0, count: characters.count)
            var fullGlyphs = subsetGlyphs
            guard CTFontGetGlyphsForCharacters(subsetFont, characters, &subsetGlyphs, characters.count),
                  CTFontGetGlyphsForCharacters(fullFont, characters, &fullGlyphs, characters.count) else { return false }
            var subsetAdvances = [CGSize](repeating: .zero, count: characters.count)
            var fullAdvances = subsetAdvances
            CTFontGetAdvancesForGlyphs(subsetFont, .horizontal, subsetGlyphs, &subsetAdvances, characters.count)
            CTFontGetAdvancesForGlyphs(fullFont, .horizontal, fullGlyphs, &fullAdvances, characters.count)
            for index in characters.indices {
                let left = subsetAdvances[index], right = fullAdvances[index]
                guard left.width.isFinite, left.height.isFinite, right.width.isFinite, right.height.isFinite,
                      abs(left.width - right.width) < 0.001, abs(left.height - right.height) < 0.001 else { return false }
                let subsetPath = CTFontCreatePathForGlyph(subsetFont, subsetGlyphs[index], nil)
                let fullPath = CTFontCreatePathForGlyph(fullFont, fullGlyphs[index], nil)
                switch (subsetPath, fullPath) {
                case let (left?, right?):
                    guard PDFGlyphOutlineIdentity.matches(left, right) else { return false }
                case (nil, nil):
                    guard let scalar = UnicodeScalar(characters[index]),
                          CharacterSet.whitespaces.contains(scalar) else { return false }
                default: return false
                }
            }
            return true
        }
    }

    private static func pdfNumber(_ value: CGFloat) throws -> String {
        try PDFDecimalNumber.string(value)
    }

    private static func outlinedDonor(on page: PDFPage, target: PDFBodyTextTarget,
                                     text: String, style: InlineTextStyle, bounds: CGRect,
                                     source: PDFOutlinedOCRMetadata) throws -> Data {
        let media = page.bounds(for: .mediaBox)
        let rendered = try textPDFRendering(text, style: style, bounds: bounds, mediaBox: media,
            visibleBox: media.intersection(page.bounds(for: .cropBox)),
            baseline: approximatelyEqual(target.bounds, bounds) ? target.baseline : nil,
            lineHeight: target.lineHeight, firstLineIndent: target.firstLineIndent,
            sourceText: target.text, sourceStyle: target.style, sourceRuns: target.sourceRuns,
            outlinedOCR: true)
        guard !rendered.textLines.isEmpty,
              rendered.textLines.count <= source.semanticLineMatrices.count else {
            PDFBodyTextFitDiagnostics.record(rendered.textLines.isEmpty ? .outlinedNoLines : .outlinedLineCapacity,
                bounds: bounds, lineCount: rendered.textLines.count,
                expectedLineCount: source.semanticLineMatrices.count)
            throw Failure.doesNotFit
        }
        var semantic = Data()
        var matrices: [CGAffineTransform] = []
        for (index, line) in rendered.textLines.enumerated() {
            guard let bytes = line.data(using: source.semanticEncoding == .utf16BE ? .utf16BigEndian : .ascii),
                  !bytes.isEmpty else { throw Failure.unsupported }
            let codeCount = source.semanticEncoding == .utf16BE ? bytes.count / 2 : bytes.count
            let size = source.semanticLineFontSizes[index]
            var matrix = source.semanticLineMatrices[index]
            // Keep the original OCR row's cell envelope and baseline. Using
            // the replacement font's compact ink width can split one logical
            // row into two columns in PDFKit's spatial text extraction.
            matrix.a = source.semanticLineWidths[index] * 1_000
                / (size * source.semanticDefaultWidth * CGFloat(codeCount))
            guard matrix.a.isFinite, matrix.a > 0 else { throw Failure.unsupported }
            matrices.append(matrix)
            let values = [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty]
            let hex = bytes.map { String(format: "%02X", $0) }.joined()
            let command = try "BT /EmberOCRSource \(pdfNumber(size)) Tf 3 Tr 0 Tc 0 Tw 100 Tz 0 TL 0 Ts\n"
                + values.map(pdfNumber).joined(separator: " ") + " Tm <\(hex)> Tj ET\n"
            semantic.append(Data(command.utf8))
        }
        let count = rendered.textLines.count
        let metadata = try PDFOutlinedOCRMetadata(id: source.id, text: text, style: style,
            bounds: bounds, baseline: rendered.firstBaseline ?? target.baseline,
            lineHeight: target.lineHeight, firstLineIndent: target.firstLineIndent,
            sourceRuns: rendered.currentRuns, erasedRects: source.erasedRects, paperColor: source.paperColor,
            semanticFontName: source.semanticFontName, semanticEncoding: source.semanticEncoding,
            semanticDefaultWidth: source.semanticDefaultWidth, semanticLineMatrices: matrices,
            semanticLineFontSizes: Array(source.semanticLineFontSizes.prefix(count)),
            semanticLineWidths: Array(source.semanticLineWidths.prefix(count)))
        let encodedMetadata = try metadata.encodedData()
        let donor = try PDFBodyTextPageSnapshot.outlinedOCRDonor(rendered.data,
            semanticContent: semantic, sourceFontName: source.semanticFontName,
            sourcePage: page, metadata: encodedMetadata)
        let envelope = PDFScannedBodyTextEditor.Source(snapshot: Data(), rootIndices: [],
            erasedRects: source.erasedRects, paperColor: source.paperColor)
        @MainActor func validateDonor(_ data: Data) throws {
            try withPage(data) { _, native in
                guard PDFScannedBodyTextEditor.replacementFits(native, source: envelope) else {
                    PDFBodyTextFitDiagnostics.record(.outlinedEnvelope, bounds: bounds,
                        paintExtent: source.erasedRects.reduce(CGRect.null) { $0.union($1) },
                        obstacleCount: source.erasedRects.count)
                    throw Failure.doesNotFit
                }
                guard let textPage = FPDFText_LoadPage(native) else {
                    PDFBodyTextFitDiagnostics.record(.outlinedTextPageUnavailable, bounds: bounds)
                    throw Failure.doesNotFit
                }
                defer { FPDFText_ClosePage(textPage) }
                let count = FPDFText_CountChars(textPage)
                guard count >= 0, count <= maximumPageCharacters else { throw Failure.tooComplex }
                var actual = ""
                for index in 0..<count {
                    let code = FPDFText_GetUnicode(textPage, index)
                    if code == 2, FPDFText_IsHyphen(textPage, index) == 1 {
                        actual.append("-")
                        continue
                    }
                    if let scalar = UnicodeScalar(code), code != 0 { actual.unicodeScalars.append(scalar) }
                }
                guard selectionKey(actual) == selectionKey(text) else { throw Failure.unsupported }
            }
        }
        try validateDonor(donor)
        // Validate the complete, unclipped glyph geometry above before
        // confining its visible paint to the original erasure union. Even a
        // subpixel descender accepted by the geometric tolerance must not
        // change neighbouring paper. The searchable OCR rows stay unclipped.
        let clipped = try PDFBodyTextPageSnapshot.outlinedOCRDonor(rendered.data,
            semanticContent: semantic, sourceFontName: source.semanticFontName,
            sourcePage: page, metadata: encodedMetadata, visibleClipRects: source.erasedRects)
        try validateDonor(clipped)
        return clipped
    }

    /// Source-only plain scan measurement. This uses the committed layout and
    /// does not publish font-name hints or serialize the scanned image again.
    static func scannedSourceDonor(_ text: String, style: InlineTextStyle, bounds: CGRect,
                                   mediaBox: CGRect, visibleBox: CGRect, baseline: CGPoint,
                                   lineHeight: CGFloat?, firstLineIndent: CGFloat,
                                   sourceRuns: [InlineTextSourceRun]) throws -> Data {
        try textPDFRendering(text, style: style, bounds: bounds, mediaBox: mediaBox,
            visibleBox: visibleBox, baseline: baseline, lineHeight: lineHeight,
            firstLineIndent: firstLineIndent, sourceText: text, sourceStyle: style,
            sourceRuns: sourceRuns, recordExportedFonts: false).data
    }

    private static func textPDF(_ text: String, style: InlineTextStyle, bounds: CGRect, mediaBox: CGRect,
                                visibleBox: CGRect, baseline: CGPoint?, lineHeight: CGFloat? = nil,
                                firstLineIndent: CGFloat = 0, sourceText: String? = nil,
                                sourceStyle: InlineTextStyle? = nil, sourceRuns: [InlineTextSourceRun] = [],
                                outlinedOCR: Bool = false, paintExtent: CGRect? = nil,
                                protectedPaintBounds: [CGRect] = [],
                                paintObservation: PDFBodyTextFitDiagnostics.PaintObservation? = nil) throws -> Data {
        try textPDFRendering(text, style: style, bounds: bounds, mediaBox: mediaBox,
            visibleBox: visibleBox, baseline: baseline, lineHeight: lineHeight,
            firstLineIndent: firstLineIndent, sourceText: sourceText, sourceStyle: sourceStyle,
            sourceRuns: sourceRuns, outlinedOCR: outlinedOCR, paintExtent: paintExtent,
            protectedPaintBounds: protectedPaintBounds, paintObservation: paintObservation).data
    }

    private struct TextPDFRendering {
        let data: Data
        let retainedRows: Set<Int>
        let textLines: [String]
        let currentRuns: [InlineTextSourceRun]
        let firstBaseline: CGPoint?
    }

    private static func textPDFRendering(_ text: String, style: InlineTextStyle, bounds: CGRect, mediaBox: CGRect,
                                         visibleBox: CGRect, baseline: CGPoint?, lineHeight: CGFloat? = nil,
                                         firstLineIndent: CGFloat = 0, sourceText: String? = nil,
                                         sourceStyle: InlineTextStyle? = nil, sourceRuns: [InlineTextSourceRun] = [],
                                         preserving sourceRows: SourceRows? = nil,
                                         outlinedOCR: Bool = false, paintExtent: CGRect? = nil,
                                         protectedPaintBounds: [CGRect] = [],
                                         paintObservation: PDFBodyTextFitDiagnostics.PaintObservation? = nil,
                                         recordExportedFonts: Bool = true) throws -> TextPDFRendering {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw Failure.failed }
        var donorBox = CGRect(origin: .zero, size: mediaBox.size)
        guard let context = CGContext(consumer: consumer, mediaBox: &donorBox, nil) else { throw Failure.failed }
        let font = style.renderingFont(replacementFont(for: text, preferred: style.font))
        let attributed = PDFBodyTextAttributedLayout.attributedString(text: text, style: style,
            sourceText: sourceText, sourceStyle: sourceStyle, sourceRuns: sourceRuns,
            lineHeight: lineHeight, firstLineIndent: firstLineIndent)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // A native run has no wrapping rectangle. Permit its replacement to
        // use the remaining line width, so a slightly longer word is not split
        // merely because the old glyph's ink bounds were narrower.
        let width = layoutWidth(text: text, style: style, bounds: bounds,
                                visibleBox: visibleBox, baseline: baseline, lineHeight: lineHeight,
                                firstLineIndent: firstLineIndent, sourceText: sourceText,
                                sourceStyle: sourceStyle, sourceRuns: sourceRuns)
        guard width > 0 else {
            PDFBodyTextFitDiagnostics.record(.rendererWidth, bounds: bounds,
                visible: visibleBox, paintExtent: paintExtent, width: width, lineHeight: lineHeight,
                obstacleCount: protectedPaintBounds.count, paintObservation: paintObservation)
            throw Failure.doesNotFit
        }
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                              CGSize(width: width, height: 100_000), nil)
        guard measured.height.isFinite, measured.height < 100_000 else { throw Failure.tooComplex }
        // Add a small horizontal allowance for the final glyph's advance, whose
        // width can exceed its painted box (the original hit-test rectangle).
        let height = max(bounds.height, ceil(measured.height) + style.fontSize)
        let top = baseline.map { $0.y + font.ascender } ?? bounds.maxY
        let layout = CGRect(x: baseline.map { $0.x - firstLineIndent } ?? bounds.minX, y: top - height,
                            width: width, height: height)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: layout, transform: nil), nil)
        guard CTFrameGetVisibleStringRange(frame).length == attributed.length else { throw Failure.failed }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        let fixedBaselineAdvance = lineHeight.flatMap { value -> CGFloat? in
            value.isFinite && value > 0 ? value : nil
        }
        if let advance = fixedBaselineAdvance, let firstOrigin = origins.first {
            // PDF line height is the distance between baselines. CoreText's
            // paragraph line-height limits still add rounded font leading and
            // can move a fallback face's baseline within its line fragment.
            // Keep CoreText's wrapping and horizontal alignment, but place the
            // actual lines on the source's fixed baseline grid.
            for index in origins.indices {
                origins[index].y = firstOrigin.y - CGFloat(index) * advance
            }
        }
        if let sourceRows, sourceRows.baselines.count == origins.count,
           let firstOrigin = origins.first, let firstBaseline = sourceRows.baselines.first {
            // Native paragraphs can have slightly different advances per row.
            // Keep those exact baselines when the replacement has the same
            // number of rows, so unchanged shows can remain byte-for-byte.
            for index in origins.indices {
                origins[index].y = firstOrigin.y + sourceRows.baselines[index] - firstBaseline
            }
        }
        let baselineAdjustment = baseline.flatMap { baseline in
            origins.first.map { baseline.y - (layout.minY + $0.y) }
        } ?? 0
        var retainedRows = Set<Int>()
        if let sourceRows, lines.count == sourceRows.text.count {
            let draftRows = text.components(separatedBy: "\n")
            // An insertion that wraps or moves any row invalidates this fast
            // path. Compare the actual CoreText layout, not a width estimate.
            let stableLayout = draftRows.count == lines.count && lines.enumerated().allSatisfy { index, line in
                let range = CTLineGetStringRange(line)
                guard range.location >= 0, range.length >= 0,
                      range.location + range.length <= attributed.length else { return false }
                let content = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
                    .trimmingCharacters(in: .newlines)
                return content == draftRows[index]
                    && abs(layout.minY + origins[index].y + baselineAdjustment - sourceRows.baselines[index]) < 0.05
            }
            if stableLayout {
                let changed = draftRows.indices.filter { draftRows[$0] != sourceRows.text[$0] }
                if let first = changed.first, let last = changed.last {
                    // One donor has one paint/reading position. Re-emit any
                    // unchanged interior rows with that contiguous changed
                    // span, or A/B'/D'/C would replace the original A/B/C/D.
                    retainedRows = Set(draftRows.indices.filter { $0 < first || $0 > last })
                } else {
                    retainedRows = Set(draftRows.indices)
                }
            }
        }
        let visible = visibleBox.insetBy(dx: -0.5, dy: -0.5)
        func recordFitRefusal(_ branch: PDFBodyTextFitDiagnostics.Branch, index: Int,
                              line: CTLine, ink: CGRect, obstacleIndex: Int? = nil, obstacle: CGRect? = nil) {
            PDFBodyTextFitDiagnostics.record(branch, bounds: bounds, visible: visible,
                paintExtent: paintExtent, ink: ink, layout: layout, width: width, lineHeight: lineHeight,
                lineIndex: index, lineCount: lines.count, retainedCount: retainedRows.count,
                lineRetained: retainedRows.contains(index), obstacleIndex: obstacleIndex,
                obstacleCount: protectedPaintBounds.count, obstacle: obstacle,
                line: line, attributed: attributed, preferred: style.font, paintObservation: paintObservation)
        }
        for (lineIndex, pair) in zip(lines, origins).enumerated() {
            let (line, origin) = pair
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                if let runFont = attributes[kCTFontAttributeName] {
                    let name = CTFontCopyPostScriptName(runFont as! CTFont) as String
                    guard name != ".LastResort", name != "LastResort" else {
                        PDFBodyTextFitDiagnostics.recordReplacementFailure(.nativeFontFallback, error: Failure.unsupported)
                        throw Failure.unsupported
                    }
                }
            }
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                .offsetBy(dx: layout.minX + origin.x, dy: layout.minY + origin.y + baselineAdjustment)
            if !ink.isEmpty {
                guard visible.contains(ink) else {
                    recordFitRefusal(.rendererVisibleBounds, index: lineIndex, line: line, ink: ink)
                    throw Failure.doesNotFit
                }
                guard paintExtent.map({ $0.contains(ink) }) ?? true else {
                    recordFitRefusal(.rendererPaintExtent, index: lineIndex, line: line, ink: ink)
                    throw Failure.doesNotFit
                }
                for (index, obstacle) in protectedPaintBounds.enumerated() {
                    if index % 256 == 0 { try Task.checkCancellation() }
                    if obstacle.intersects(ink) {
                        recordFitRefusal(.rendererTextObstacle, index: lineIndex, line: line, ink: ink,
                            obstacleIndex: index, obstacle: obstacle)
                        throw Failure.doesNotFit
                    }
                }
            }
        }
        if style.backgroundColor.alpha > 0,
           let index = protectedPaintBounds.firstIndex(where: { $0.intersects(bounds) }) {
            PDFBodyTextFitDiagnostics.record(.rendererBackgroundObstacle, bounds: bounds,
                visible: visible, paintExtent: paintExtent, ink: bounds, layout: layout,
                width: width, lineHeight: lineHeight, lineCount: lines.count, retainedCount: retainedRows.count,
                obstacleIndex: index, obstacleCount: protectedPaintBounds.count, obstacle: protectedPaintBounds[index],
                paintObservation: paintObservation)
            throw Failure.doesNotFit
        }
        var leadingSpacePlans: [Int: PDFBodyLeadingSpaceDrawing.Plan] = [:]
        if !outlinedOCR {
            for (index, line) in lines.enumerated() where !retainedRows.contains(index) {
                if index % 64 == 0 { try Task.checkCancellation() }
                if let plan = try PDFBodyLeadingSpaceDrawing.make(line: line, text: attributed) {
                    leadingSpacePlans[index] = plan
                }
            }
        }
        context.beginPDFPage(nil)
        context.translateBy(x: -mediaBox.minX, y: -mediaBox.minY + baselineAdjustment)
        if style.backgroundColor.alpha > 0 {
            context.setFillColor(style.backgroundColor.nsColor.cgColor)
            context.fill(bounds)
        }
        context.textMatrix = .identity
        if outlinedOCR {
            // A scanned page already has an invisible search/copy layer.
            // Keep that layer separate from the visible glyph outlines, using
            // exactly the same CoreText layout for both representations.
            context.setTextDrawingMode(.invisible)
            for (index, line) in lines.enumerated() where !retainedRows.contains(index) {
                context.textPosition = CGPoint(x: layout.minX + origins[index].x,
                                               y: layout.minY + origins[index].y)
                CTLineDraw(line, context)
            }
            context.setTextDrawingMode(.fill)
            for (index, line) in lines.enumerated() where !retainedRows.contains(index) {
                let origin = CGPoint(x: layout.minX + origins[index].x, y: layout.minY + origins[index].y)
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let value = attributes[kCTFontAttributeName] else {
                        PDFBodyTextFitDiagnostics.recordReplacementFailure(.nativeFontAttributes, error: Failure.unsupported)
                        throw Failure.unsupported
                    }
                    let runFont = value as! CTFont
                    let count = CTRunGetGlyphCount(run)
                    guard count >= 0, count <= maximumPageCharacters else { throw Failure.tooComplex }
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    CTRunGetGlyphs(run, CFRange(), &glyphs)
                    CTRunGetPositions(run, CFRange(), &positions)
                    let color = (attributes[NSAttributedString.Key.foregroundColor] as? NSColor)
                        ?? style.textColor.nsColor
                    let outlines = try outlinedGlyphPath(font: runFont, glyphs: glyphs,
                        positions: positions, runMatrix: CTRunGetTextMatrix(run), origin: origin)
                    if !outlines.isEmpty {
                        context.saveGState()
                        context.addPath(outlines)
                        context.clip()
                        context.setFillColor(color.cgColor)
                        // PDFKit treats a small opaque fill as a layout
                        // obstacle even when the text itself is invisible.
                        // A full-page fill clipped to the exact glyph paths
                        // paints the same vector outlines without that hint.
                        context.fill(CGRect(x: mediaBox.minX, y: mediaBox.minY - baselineAdjustment,
                                            width: mediaBox.width, height: mediaBox.height))
                        context.restoreGState()
                    }
                }
            }
        } else if retainedRows.isEmpty, fixedBaselineAdvance == nil, leadingSpacePlans.isEmpty {
            CTFrameDraw(frame, context)
        } else {
            // Use the exact baseline origins above, and omit unchanged rows
            // from the donor entirely. Clipping or painting over retained text
            // would still duplicate search/copy text.
            for (index, line) in lines.enumerated() where !retainedRows.contains(index) {
                if index % 64 == 0 { try Task.checkCancellation() }
                let origin = CGPoint(x: layout.minX + origins[index].x, y: layout.minY + origins[index].y)
                if let plan = leadingSpacePlans[index] {
                    try plan.draw(in: context, origin: origin)
                } else {
                    context.textPosition = origin
                    CTLineDraw(line, context)
                }
            }
        }
        context.endPDFPage()
        context.closePDF()
        guard data.length <= maximumPageBytes else { throw Failure.tooComplex }
        for (index, line) in lines.enumerated() where !retainedRows.contains(index) {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                if recordExportedFonts, let font = attributes[kCTFontAttributeName] {
                    EmbeddedSourceFonts.rememberExportedFont(font as! CTFont)
                }
            }
        }
        var finalData = data as Data
        if !outlinedOCR {
            var candidates: [PDFBodyTextDocumentFonts.Lease] = []
            var candidateIDs = Set<UUID>()
            for value in [style.sourceFont] + sourceRuns.map({ $0.style.sourceFont }) {
                guard let lease = value, candidateIDs.insert(lease.identity).inserted else { continue }
                guard candidates.count < 64 else { throw Failure.tooComplex }
                candidates.append(lease)
            }
            var tokens: [PDFBodyTextDocumentFonts.ApprovedProgramToken] = []
            var admitted = Set<UUID>()
            for (index, line) in lines.enumerated() where !retainedRows.contains(index) {
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let value = attributes[kCTFontAttributeName] else { continue }
                    let actual = value as! CTFont
                    for lease in candidates where !admitted.contains(lease.identity) {
                        if let token = lease.approvedProgramToken(for: actual) {
                            admitted.insert(lease.identity); tokens.append(token)
                        }
                    }
                }
            }
            if !tokens.isEmpty {
                finalData = try PDFBodyTextFitDiagnostics.withReplacementPhase(.approvedFontProgramRestore, {
                    try PDFBodyTextPageSnapshot.preservingApprovedFontPrograms(in: finalData, tokens: tokens)
                })
            }
        }
        var textLines: [String] = []
        var currentRuns: [InlineTextSourceRun] = []
        if outlinedOCR {
            for line in lines {
                let lineRange = CTLineGetStringRange(line)
                let range = NSRange(location: lineRange.location, length: lineRange.length)
                textLines.append((text as NSString).substring(with: range).trimmingCharacters(in: .newlines))
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let rawRange = CTRunGetStringRange(run)
                    let range = NSRange(location: rawRange.location, length: rawRange.length)
                    guard range.length > 0, range.location >= 0, NSMaxRange(range) <= attributed.length else { continue }
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let value = attributes[kCTFontAttributeName] else {
                        PDFBodyTextFitDiagnostics.recordReplacementFailure(.nativeFontAttributes, error: Failure.unsupported)
                        throw Failure.unsupported
                    }
                    let runFont = value as! CTFont
                    let matrix = CTFontGetMatrix(runFont)
                    guard matrix.d.isFinite, matrix.d > 0 else { throw Failure.unsupported }
                    let color = (attributes[NSAttributedString.Key.foregroundColor] as? NSColor)
                        ?? style.textColor.nsColor
                    let actualStyle = InlineTextStyle(fontName: CTFontCopyPostScriptName(runFont) as String,
                        fontSize: CTFontGetSize(runFont), textColor: PDFTextColor(color),
                        backgroundColor: .clear, alignment: style.alignment,
                        horizontalScale: matrix.a / matrix.d)
                    let baselineOffset = (attributed.attribute(.baselineOffset, at: range.location,
                        effectiveRange: nil) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                    currentRuns.append(.init(range: range, style: actualStyle, baselineOffset: baselineOffset))
                }
            }
            currentRuns.sort { $0.range.location < $1.range.location }
        }
        return TextPDFRendering(data: finalData, retainedRows: retainedRows,
            textLines: textLines, currentRuns: currentRuns,
            firstBaseline: origins.first.map {
                CGPoint(x: layout.minX + $0.x, y: layout.minY + $0.y + baselineAdjustment)
            })
    }

    /// CoreText returns run positions before its text matrix, while glyph
    /// paths already include the font matrix. Convert the paths back to that
    /// coordinate space before placing both through the run matrix once.
    static func outlinedGlyphPath(font: CTFont, glyphs: [CGGlyph], positions: [CGPoint],
                                  runMatrix: CGAffineTransform, origin: CGPoint) throws -> CGPath {
        let fontMatrix = CTFontGetMatrix(font)
        let values = [fontMatrix.a, fontMatrix.b, fontMatrix.c, fontMatrix.d, fontMatrix.tx, fontMatrix.ty,
                      runMatrix.a, runMatrix.b, runMatrix.c, runMatrix.d, runMatrix.tx, runMatrix.ty,
                      origin.x, origin.y]
        let determinant = fontMatrix.a * fontMatrix.d - fontMatrix.b * fontMatrix.c
        let runDeterminant = runMatrix.a * runMatrix.d - runMatrix.b * runMatrix.c
        guard glyphs.count == positions.count, glyphs.count <= maximumPageCharacters,
              values.allSatisfy(\.isFinite), determinant.isFinite, abs(determinant) > 0.000_001,
              runDeterminant.isFinite, abs(runDeterminant) > 0.000_001 else {
            throw Failure.unsupported
        }
        let glyphMatrix = fontMatrix.inverted().concatenating(runMatrix)
        let outlines = CGMutablePath()
        for (glyph, position) in zip(glyphs, positions) {
            guard position.x.isFinite, position.y.isFinite else { throw Failure.unsupported }
            guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
                var checked = glyph
                guard CTFontGetBoundingRectsForGlyphs(font, .default, &checked, nil, 1).isEmpty else {
                    throw Failure.unsupported
                }
                continue
            }
            var transform = glyphMatrix
            transform.tx += origin.x + runMatrix.a * position.x + runMatrix.c * position.y
            transform.ty += origin.y + runMatrix.b * position.x + runMatrix.d * position.y
            guard let placed = path.copy(using: &transform) else { throw Failure.unsupported }
            outlines.addPath(placed)
        }
        return outlines
    }

    /// The live editor and committed PDF use one wrapping width in page units.
    static func layoutWidth(text: String, style: InlineTextStyle, bounds: CGRect,
                            visibleBox: CGRect, baseline: CGPoint?, lineHeight: CGFloat?,
                            firstLineIndent: CGFloat = 0, sourceText: String? = nil,
                            sourceStyle: InlineTextStyle? = nil, sourceRuns: [InlineTextSourceRun] = []) -> CGFloat {
        let attributed = PDFBodyTextAttributedLayout.attributedString(text: text, style: style,
            sourceText: sourceText, sourceStyle: sourceStyle, sourceRuns: sourceRuns,
            lineHeight: lineHeight, firstLineIndent: firstLineIndent)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let naturalWidth = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                              CGSize(width: 100_000, height: 100_000), nil).width
        var paragraphWidth = bounds.width + 1
        if lineHeight != nil, let sourceText {
            // Painted glyph bounds omit sidebearings. After saving, using those
            // bounds as the next wrapping width can move the last glyph of every
            // unchanged line. Preserve the original lines' full advances too.
            let original = PDFBodyTextAttributedLayout.attributedString(text: sourceText,
                style: sourceStyle ?? style, sourceText: sourceText, sourceStyle: sourceStyle,
                sourceRuns: sourceRuns, lineHeight: lineHeight, firstLineIndent: firstLineIndent)
            var firstLine = true
            sourceText.enumerateSubstrings(in: sourceText.startIndex..<sourceText.endIndex,
                                           options: .byLines) { substring, range, _, _ in
                let lineText = substring ?? ""
                let trimmed = lineText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    // Keep leading spaces, but discard extraction-only trailing
                    // tabs/spaces before measuring the last visible glyph.
                    let end = lineText.lastIndex(where: { !$0.isWhitespace })!
                    let length = lineText[..<lineText.index(after: end)].utf16.count
                    let nativeRange = NSRange(range, in: sourceText)
                    let line = CTLineCreateWithAttributedString(original.attributedSubstring(
                        from: NSRange(location: nativeRange.location, length: length)))
                    let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                        + (firstLine ? firstLineIndent : 0)
                    if advance.isFinite { paragraphWidth = max(paragraphWidth, advance + 1) }
                }
                firstLine = false
            }
        }
        return min(lineHeight == nil ? max(bounds.width + 1, ceil(naturalWidth) + 1) : paragraphWidth,
                   visibleBox.maxX - (baseline.map { $0.x - firstLineIndent } ?? bounds.minX))
    }

    /// CoreText normally substitutes only missing glyphs. For a Latin font and
    /// Korean text this can leave each space as a separate Latin-font object,
    /// making the generated Form impossible to re-edit as one native run.
    /// Keep the requested font when it covers the text; otherwise use one of
    /// CoreText's own fallbacks only when it covers the entire replacement.
    static func replacementFont(for text: String, preferred: NSFont) -> NSFont {
        let characters = Array(text.utf16).filter { ![9, 10, 13].contains($0) }
        guard !characters.isEmpty else { return preferred }
        let requested = preferred as CTFont
        func coversText(_ font: CTFont) -> Bool {
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        }
        if coversText(requested) { return preferred }
        let string = text as NSString
        var checked = Set<String>([preferred.fontName])
        var offset = 0
        while offset < string.length, checked.count < 16 {
            let range = string.rangeOfComposedCharacterSequence(at: offset)
            let candidate = CTFontCreateForString(requested, text as CFString,
                CFRange(location: range.location, length: range.length))
            let name = CTFontCopyPostScriptName(candidate) as String
            if checked.insert(name).inserted, name != ".LastResort", name != "LastResort",
               coversText(candidate), let font = NSFont(name: name, size: preferred.pointSize) {
                return font
            }
            offset = NSMaxRange(range)
        }
        return preferred
    }

    private final class SaveBuffer {
        var data = Data()
    }

    private static func save(_ document: FPDF_DOCUMENT) throws -> Data {
        let storage = SaveBuffer()
        let pointerOffset = (MemoryLayout<FPDF_FILEWRITE>.stride + MemoryLayout<UnsafeRawPointer>.alignment - 1)
            & ~(MemoryLayout<UnsafeRawPointer>.alignment - 1)
        let allocation = UnsafeMutableRawPointer.allocate(
            byteCount: pointerOffset + MemoryLayout<UnsafeRawPointer>.stride,
            alignment: max(MemoryLayout<FPDF_FILEWRITE>.alignment, MemoryLayout<UnsafeRawPointer>.alignment))
        defer { allocation.deallocate() }
        allocation.advanced(by: pointerOffset).storeBytes(of: Unmanaged.passUnretained(storage).toOpaque(), as: UnsafeMutableRawPointer.self)
        let writer = allocation.bindMemory(to: FPDF_FILEWRITE.self, capacity: 1)
        writer.initialize(to: FPDF_FILEWRITE())
        defer { writer.deinitialize(count: 1) }
        writer.pointee.version = 1
        writer.pointee.WriteBlock = { writer, bytes, count in
            guard let writer, let bytes else { return 0 }
            let offset = (MemoryLayout<FPDF_FILEWRITE>.stride + MemoryLayout<UnsafeRawPointer>.alignment - 1)
                & ~(MemoryLayout<UnsafeRawPointer>.alignment - 1)
            let context = UnsafeRawPointer(writer).advanced(by: offset).load(as: UnsafeMutableRawPointer.self)
            let buffer = Unmanaged<SaveBuffer>.fromOpaque(context).takeUnretainedValue()
            guard count <= 64 * 1_024 * 1_024 - buffer.data.count else { return 0 }
            buffer.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(count))
            return 1
        }
        guard FPDF_SaveAsCopy(document, writer, UInt(FPDF_NO_INCREMENTAL)) != 0,
              !storage.data.isEmpty else { throw Failure.failed }
        return storage.data
    }

    /// Intersect a saved declaration with the current visible page only when
    /// its overshoot is limited to floating-point boundary noise. This never
    /// expands a declaration or relaxes the independently measured glyph test.
    /// The fixed 128-ULP ceiling is a precision cap, not a geometric fit margin.
    static func savedPaintExtent(_ extent: CGRect, within visible: CGRect,
                                 containing glyphs: CGRect) -> CGRect? {
        guard valid(extent), valid(visible), valid(glyphs),
              !extent.isEmpty, !visible.isEmpty, !glyphs.isEmpty,
              visible.contains(glyphs) else { return nil }
        if visible.contains(extent) { return extent.contains(glyphs) ? extent : nil }
        let scale = max(1, abs(visible.minX), abs(visible.maxX),
                        abs(visible.minY), abs(visible.maxY), visible.width, visible.height)
        let precisionLimit = scale.ulp * 128
        guard max(0, visible.minX - extent.minX) <= precisionLimit,
              max(0, extent.maxX - visible.maxX) <= precisionLimit,
              max(0, visible.minY - extent.minY) <= precisionLimit,
              max(0, extent.maxY - visible.maxY) <= precisionLimit else { return nil }
        let clipped = extent.intersection(visible)
        guard valid(clipped), !clipped.isEmpty, visible.contains(clipped),
              extent.contains(clipped), clipped.contains(glyphs) else { return nil }
        return clipped
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && abs(rect.minX) < 1_000_000 && abs(rect.minY) < 1_000_000
            && rect.width >= 0 && rect.height >= 0 && rect.width < 1_000_000 && rect.height < 1_000_000
    }

    private static func approximatelyEqual(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) < 0.05 && abs(left.minY - right.minY) < 0.05
            && abs(left.width - right.width) < 0.05 && abs(left.height - right.height) < 0.05
    }
}


/// PDFium's Form removal mutates its backing stream. A Form reused twice on
/// the same page cannot be edited independently through the public API yet.
/// Count actual `Do` invocations by raw stream identity, rather than guessing
/// from repeated words or scanning PDF syntax with regular expressions.
private final class PDFBodyFormUsageAudit {
    private enum AuditFailure: Error { case invalid, limit }
    private var references: [UInt: Int] = [:]
    private var activeStreams = Set<UInt>()
    private var resourceStack: [CGPDFDictionaryRef] = []
    private var visits = 0
    private var error: Error?
    private var repeated = false
    private var scannedErasureResourceAudit = false
    private var scannedRootResourcesOnly = false
    private(set) var hasUnsupportedPaint = false
    private(set) var hasOcclusionUnsafePaint = false

    private func unsupportedPaint(occlusionUnsafe: Bool = true) {
        hasUnsupportedPaint = true
        hasOcclusionUnsafePaint = hasOcclusionUnsafePaint || occlusionUnsafe
    }
    private(set) var externalImageInvocations = 0
    private(set) var hasUnsafeNestedCompositing = false
    private(set) var hasExplicitClipping = false
    private(set) var hasTextClipping = false
    private let visibleClipBox: CGRect?
    private var hasUnprovedClipGeometry = false
    var hasOnlyPageCoveringClips: Bool { visibleClipBox != nil && !hasUnprovedClipGeometry }
    init(visibleClipBox: CGRect? = nil) { self.visibleClipBox = visibleClipBox }


    private final class Context {
        let audit: PDFBodyFormUsageAudit
        let depth: Int
        var cidFonts: [String: UInt] = [:]
        var identityCTM = true
        var transformStack: [Bool] = []
        var clipRectangle: CGRect?
        var nonRectangularPath = false
        var clipProofOperations = 0
        var pendingClip = false
        func invalidatePendingClip() {
            if pendingClip { audit.hasUnprovedClipGeometry = true }
        }
        func finishClipPath() {
            defer { pendingClip = false; nonRectangularPath = false; clipRectangle = nil }
            guard pendingClip else { return }
            // W/W* changes the clip only when the current path ends.
            // Authorize the complete path, never the prefix seen at W.
            guard depth == 0, identityCTM, !nonRectangularPath,
                  let rectangle = clipRectangle, let visible = audit.visibleClipBox,
                  rectangle.contains(visible) else {
                audit.hasUnprovedClipGeometry = true
                return
            }
        }
        func trackClipProof() -> Bool {
            clipProofOperations += 1
            guard clipProofOperations <= 50_000 else {
                audit.hasUnprovedClipGeometry = true
                return false
            }
            return true
        }

        init(_ audit: PDFBodyFormUsageAudit, depth: Int) { self.audit = audit; self.depth = depth }
    }

    func hasRepeatedForm(on page: CGPDFPage) throws -> Bool {
        resourceStack = [try pageResources(page)]
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        scan(content, depth: 0)
        if let error { throw error }
        return repeated
    }

    /// A top-level resource can also be inherited and invoked inside another
    /// Form. Count the exact stream recursively before dropping a donor entry.
    func isFormInvokedExactlyOnce(named name: String, on page: CGPDFPage) throws -> Bool {
        resourceStack = [try pageResources(page)]
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        guard let object = name.withCString({ CGPDFContentStreamGetResource(content, "XObject", $0) }) else {
            throw AuditFailure.invalid
        }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { throw AuditFailure.invalid }
        scan(content, depth: 0)
        if let error { throw error }
        return references[pdfReferenceIdentity(stream)] == 1
    }

    /// The raw erasure grammar independently validates every inline image's
    /// exclusion wrapper. Still audit all current fonts, GS resources and Form
    /// contents so hidden Type3 text or inherited unsafe GS cannot be treated
    /// as inert by the grammar's operator-shape check.
    func hasSafeScannedErasureResources(on page: CGPDFPage) throws -> Bool {
        scannedErasureResourceAudit = true
        scannedRootResourcesOnly = true
        _ = try hasRepeatedForm(on: page)
        return !hasUnsupportedPaint && !hasOcclusionUnsafePaint
            && !hasUnsafeNestedCompositing && !hasTextClipping
    }

    /// The global page necessarily contains erasure clips. Prove absence of
    /// clipping on the exact current donor stream separately before treating
    /// PDFium's missing-default clip handle (-1) as unclipped. The caller has
    /// independently matched this unique Form to all current native children.
    func hasSafeUnclippedTextForm(named name: String, on page: CGPDFPage) throws -> Bool {
        scannedErasureResourceAudit = true
        let inherited = try pageResources(page)
        resourceStack = [inherited]
        let parent = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(parent) }
        guard let object = name.withCString({ CGPDFContentStreamGetResource(parent, "XObject", $0) }) else {
            return false
        }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return false }
        var group: CGPDFObjectRef?
        guard !CGPDFDictionaryGetObject(dictionary, "Group", &group) else { return false }
        var resources: CGPDFDictionaryRef?, value: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "Resources", &value) {
            guard let value, CGPDFObjectGetValue(value, .dictionary, &resources), resources != nil else { return false }
        }
        let effective = resources ?? inherited
        resourceStack.append(effective)
        defer { resourceStack.removeLast() }
        let content = CGPDFContentStreamCreateWithStream(stream, effective, parent)
        defer { CGPDFContentStreamRelease(content) }
        scan(content, depth: 0)
        if let error { throw error }
        return !hasExplicitClipping && !hasTextClipping && !hasUnsupportedPaint
            && !hasOcclusionUnsafePaint && !hasUnsafeNestedCompositing
    }

    private func pageResources(_ page: CGPDFPage) throws -> CGPDFDictionaryRef {
        var current = page.dictionary
        for _ in 0..<16 {
            guard let dictionary = current else { break }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources { return resources }
            var parent: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent)
            current = parent
        }
        throw AuditFailure.invalid
    }

    private func scan(_ content: CGPDFContentStreamRef, depth: Int) {
        guard error == nil else { return }
        guard depth < 16 else { error = AuditFailure.limit; return }
        guard let table = CGPDFOperatorTableCreate() else { error = AuditFailure.invalid; return }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, context in
            guard let context else { return }
            let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
            state.audit.visit(scanner, depth: state.depth)
        }
        // A native missing clip handle is insufficient. Independently accept
        // only redundant visible-page rectangular clips at the page root.
        // No transformed/nested/compound/curved path is used for this proof.
        // Other audits need only the W/W* observation, without path callbacks.
        if visibleClipBox != nil {
            CGPDFOperatorTableSetCallback(table, "q") { _, context in
                guard let context else { return }
                let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                guard state.trackClipProof() else { return }
                state.invalidatePendingClip()
                if state.transformStack.count < 64 { state.transformStack.append(state.identityCTM) }
                else { state.audit.hasUnprovedClipGeometry = true }
            }
            CGPDFOperatorTableSetCallback(table, "Q") { _, context in
                guard let context else { return }
                let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                guard state.trackClipProof() else { return }
                state.invalidatePendingClip()
                if let saved = state.transformStack.popLast() { state.identityCTM = saved }
                else { state.audit.hasUnprovedClipGeometry = true }
            }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, context in
                guard let context else { return }
                let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                guard state.trackClipProof() else { return }
                state.invalidatePendingClip()
                var values = [CGPDFReal](repeating: 0, count: 6)
                for index in (0..<6).reversed() {
                    guard CGPDFScannerPopNumber(scanner, &values[index]), values[index].isFinite else {
                        state.audit.hasUnprovedClipGeometry = true; state.identityCTM = false; return
                    }
                }
                if values != [1, 0, 0, 1, 0, 0] { state.identityCTM = false }
            }
            CGPDFOperatorTableSetCallback(table, "re") { scanner, context in
                guard let context else { return }
                let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                guard state.trackClipProof() else { return }
                state.invalidatePendingClip()
                var h: CGPDFReal = 0, w: CGPDFReal = 0, y: CGPDFReal = 0, x: CGPDFReal = 0
                guard state.clipRectangle == nil, !state.nonRectangularPath, state.identityCTM,
                      CGPDFScannerPopNumber(scanner, &h), CGPDFScannerPopNumber(scanner, &w),
                      CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x),
                      [x,y,w,h].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }), w > 0, h > 0 else {
                    state.nonRectangularPath = true; state.clipRectangle = nil; return
                }
                state.clipRectangle = CGRect(x: x, y: y, width: w, height: h)
            }
            for operation in ["m", "l", "c", "v", "y", "h"] {
                CGPDFOperatorTableSetCallback(table, operation) { _, context in
                    guard let context else { return }
                    let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                    guard state.trackClipProof() else { return }
                    state.invalidatePendingClip()
                    state.nonRectangularPath = true; state.clipRectangle = nil
                }
            }
            for operation in ["n", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*"] {
                CGPDFOperatorTableSetCallback(table, operation) { _, context in
                    guard let context else { return }
                    let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                    guard state.trackClipProof() else { return }
                    state.finishClipPath()
                }
            }
        }
        for operation in ["W", "W*"] {
            CGPDFOperatorTableSetCallback(table, operation) { _, context in
                guard let context else { return }
                let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                state.audit.hasExplicitClipping = true
                guard state.audit.visibleClipBox != nil else { return }
                guard state.trackClipProof() else { return }
                state.invalidatePendingClip()
                state.pendingClip = true
            }
        }
        for operation in ["scn", "SCN"] {
            CGPDFOperatorTableSetCallback(table, operation) { scanner, context in
                guard let context else { return }
                let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                var name: UnsafePointer<CChar>?
                if CGPDFScannerPopName(scanner, &name) { state.audit.unsupportedPaint() }
            }
        }
        // These paint operators cannot be regenerated by PDFium 8086 without
        // silently dropping their content. Reject before any live-page change.
        for operation in scannedErasureResourceAudit ? ["sh", "k", "K"] : ["sh", "BI", "k", "K"] {
            CGPDFOperatorTableSetCallback(table, operation) { _, context in
                guard let context else { return }
                Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().audit.unsupportedPaint()
            }
        }
        for operation in ["cs", "CS"] {
            CGPDFOperatorTableSetCallback(table, operation) { scanner, context in
                guard let context else { return }
                Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().audit.auditColorSpace(scanner)
            }
        }
        CGPDFOperatorTableSetCallback(table, "gs") { scanner, context in
            guard let context else { return }
            Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().audit.auditGraphicsState(scanner)
        }
        CGPDFOperatorTableSetCallback(table, "BDC") { scanner, context in
            guard let context else { return }
            let audit = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().audit
            var properties: CGPDFObjectRef?
            var tag: UnsafePointer<CChar>?
            guard CGPDFScannerPopObject(scanner, &properties), let properties,
                  CGPDFScannerPopName(scanner, &tag), let tag else {
                audit.unsupportedPaint(); return
            }
            var dictionary: CGPDFDictionaryRef?
            guard strcmp(tag, "OC") != 0,
                  CGPDFObjectGetValue(properties, .dictionary, &dictionary), let dictionary else {
                audit.unsupportedPaint(); return
            }
            var actualText: CGPDFObjectRef?
            // Regeneration has no semantic replacement support. The lossless
            // block route separately handles verified whitespace-only spans.
            if CGPDFDictionaryGetObject(dictionary, "ActualText", &actualText) {
                audit.unsupportedPaint(occlusionUnsafe: false)
            }
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, context in
            guard let context else { return }
            let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
            state.audit.auditFont(scanner, scope: state)
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, context in
            guard let context else { return }
            let audit = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().audit
            var mode: CGPDFInteger = 0
            let parsed = CGPDFScannerPopInteger(scanner, &mode)
            // Preserve every older regeneration rejection, including Tr >= 8.
            if parsed, mode >= 4 { audit.unsupportedPaint() }
            guard parsed, (0...7).contains(mode) else {
                audit.hasTextClipping = true
                audit.hasOcclusionUnsafePaint = true
                return
            }
            if mode >= 4 { audit.hasTextClipping = true }
        }
        CGPDFOperatorTableSetCallback(table, "M") { scanner, context in
            guard let context else { return }
            let audit = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().audit
            var limit: CGPDFReal = 10
            if CGPDFScannerPopNumber(scanner, &limit), limit != 10 { audit.unsupportedPaint() }
        }
        let context = Context(self, depth: depth)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(context).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        let completed = withExtendedLifetime(context) { CGPDFScannerScan(scanner) }
        if context.pendingClip { hasUnprovedClipGeometry = true }
        if !completed, error == nil { error = AuditFailure.invalid }
    }

    private func auditColorSpace(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { unsupportedPaint(); return }
        if ["DeviceCMYK", "CMYK", "Separation", "DeviceN"].contains(String(cString: name)) {
            unsupportedPaint(); return
        }
        if strcmp(name, "Pattern") == 0 { hasOcclusionUnsafePaint = true }
        let content = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(content, "ColorSpace", name) else { return }
        var array: CGPDFArrayRef?, base: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .array, &array), let array,
           CGPDFArrayGetName(array, 0, &base), let base, strcmp(base, "Pattern") == 0 {
            hasOcclusionUnsafePaint = true
        }
        if unsupportedColorSpace(object, depth: 0) { unsupportedPaint() }
    }

    private func unsupportedColorSpace(_ object: CGPDFObjectRef, depth: Int) -> Bool {
        guard depth < 16 else { return true }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name {
            return ["DeviceCMYK", "CMYK", "Separation", "DeviceN"].contains(String(cString: name))
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array,
              CGPDFArrayGetName(array, 0, &name), let name else { return true }
        switch String(cString: name) {
        case "ICCBased":
            var stream: CGPDFStreamRef?
            var components: CGPDFInteger = 0
            guard CGPDFArrayGetStream(array, 1, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetInteger(dictionary, "N", &components) else { return true }
            return components != 1 && components != 3
        case "Indexed", "I":
            var base: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, 1, &base), let base else { return true }
            return unsupportedColorSpace(base, depth: depth + 1)
        case "Separation", "DeviceN", "DeviceCMYK": return true
        default: return false
        }
    }

    private func auditGraphicsState(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name,
              let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", name) else {
            unsupportedPaint(); return
        }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { unsupportedPaint(); return }
        if scannedErasureResourceAudit {
            // Only exact inert defaults emitted by our reset are allowed. In
            // particular Font/unknown controls cannot change the audited Tf.
            let keys = ["Type", "CA", "ca", "BM", "SMask", "TR", "TR2", "ML", "OP", "op", "OPM", "AIS", "TK", "SA"]
            var present = 0
            for key in keys {
                var value: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(dictionary, key, &value) {
                    guard value != nil else { unsupportedPaint(); return }
                    present += 1
                }
            }
            guard present == CGPDFDictionaryGetCount(dictionary) else { unsupportedPaint(); return }
            for (key, expected) in [("CA", CGPDFReal(1)), ("ca", 1), ("ML", 10), ("OPM", 0)] {
                var value: CGPDFObjectRef?, actual: CGPDFReal = 0
                if CGPDFDictionaryGetObject(dictionary, key, &value) {
                    guard CGPDFDictionaryGetNumber(dictionary, key, &actual), actual == expected else {
                        unsupportedPaint(); return
                    }
                }
            }
            for (key, expected) in [("OP", false), ("op", false), ("AIS", false), ("TK", true), ("SA", false)] {
                var value: CGPDFObjectRef?, actual: CGPDFBoolean = 0
                if CGPDFDictionaryGetObject(dictionary, key, &value) {
                    guard let value, CGPDFObjectGetValue(value, .boolean, &actual), (actual != 0) == expected else {
                        unsupportedPaint(); return
                    }
                }
            }
            for (key, allowed) in [("Type", ["ExtGState"]), ("BM", ["Normal", "Compatible"]),
                                   ("SMask", ["None"]), ("TR", ["Identity", "Default"]),
                                   ("TR2", ["Identity", "Default"])] {
                var value: CGPDFObjectRef?, name: UnsafePointer<CChar>?
                if CGPDFDictionaryGetObject(dictionary, key, &value) {
                    guard let value, CGPDFObjectGetValue(value, .name, &name), let name,
                          strnlen(name, 64) < 64, allowed.contains(String(cString: name)) else {
                        unsupportedPaint(); return
                    }
                }
            }
        }
        // A nested replacement is moved outside its Form. Even with opaque
        // alpha and preserved paint order, leaving a blend/group boundary can
        // change compositing, so nested edits need a stricter check.
        var blend: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "BM", &blend), let blend {
            var mode: UnsafePointer<CChar>?
            if !CGPDFObjectGetValue(blend, .name, &mode)
                || mode.map({ !["Normal", "Compatible"].contains(String(cString: $0)) }) != false {
                hasUnsafeNestedCompositing = true
            }
        }
        // The generator preserves alpha/blend, but omits soft masks, transfer
        // functions and nondefault miter limits. Refuse their destructive loss.
        for key in ["SMask", "TR", "TR2"] {
            var value: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, key, &value), let value {
                var mode: UnsafePointer<CChar>?
                if !CGPDFObjectGetValue(value, .name, &mode) || mode.map({ !["None", "Identity", "Default"].contains(String(cString: $0)) }) != false {
                    unsupportedPaint()
                }
            }
        }
        // Overprint can leave a nominally opaque fill unpainted. It is not
        // evidence of an underlay; keep the old regeneration flags unchanged.
        for key in ["OP", "op"] {
            var object: CGPDFObjectRef?
            var flag: CGPDFBoolean = 0
            if CGPDFDictionaryGetObject(dictionary, key, &object), let object {
                if !CGPDFObjectGetValue(object, .boolean, &flag) || flag != 0 { hasOcclusionUnsafePaint = true }
            }
        }
        var overprint: CGPDFObjectRef?, mode: CGPDFInteger = 0
        if CGPDFDictionaryGetObject(dictionary, "OPM", &overprint), let overprint {
            if !CGPDFObjectGetValue(overprint, .integer, &mode) || mode != 0 { hasOcclusionUnsafePaint = true }
        }
        var miter: CGPDFReal = 10
        if CGPDFDictionaryGetNumber(dictionary, "ML", &miter), miter != 10 { unsupportedPaint() }
    }

    private func auditFont(_ scanner: CGPDFScannerRef, scope: Context) {
        var size: CGPDFReal = 0
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name,
              let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Font", name) else {
            unsupportedPaint(); return
        }
        var dictionary: CGPDFDictionaryRef?
        var subtype: UnsafePointer<CChar>?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary,
              CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { unsupportedPaint(); return }
        if !["Type0", "Type1", "MMType1", "TrueType"].contains(String(cString: subtype)) {
            // Type3 prevents regeneration, but cannot change an earlier root
            // path's opacity. Current native glyph bounds remain obstacles.
            unsupportedPaint(occlusionUnsafe: strcmp(subtype, "Type3") != 0)
        }
        guard strcmp(subtype, "Type0") == 0 else { return }
        var descendants: CGPDFArrayRef?
        var descendant: CGPDFDictionaryRef?
        var baseName: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants,
              CGPDFArrayGetCount(descendants) == 1,
              CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant,
              CGPDFDictionaryGetName(descendant, "BaseFont", &baseName), let baseName,
              strnlen(baseName, 4_096) < 4_096 else { unsupportedPaint(); return }
        // PDFium's generator keys Type0 fonts only by this descendant name,
        // ignoring the root font's encoding, ToUnicode map and CID widths.
        // Distinct dictionaries with that key can therefore corrupt retained
        // text. Each Form has its own generator map, so compare only fonts
        // actually selected in this scope; aliases of one dictionary are safe.
        let key = String(cString: baseName)
        let identity = pdfReferenceIdentity(dictionary)
        if let existing = scope.cidFonts[key], existing != identity { unsupportedPaint() }
        scope.cidFonts[key] = identity
    }

    private func visit(_ scanner: CGPDFScannerRef, depth: Int) {
        visits += 1
        guard error == nil, visits <= 50_000 else {
            error = error ?? AuditFailure.limit
            CGPDFScannerStop(scanner)
            return
        }
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else {
            error = AuditFailure.invalid; CGPDFScannerStop(scanner); return
        }
        let content = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
        if strcmp(subtype, "Image") == 0 { externalImageInvocations += 1; return }
        guard strcmp(subtype, "Form") == 0 else { return }
        // The raw page grammar puts every other Form under exact hole clips.
        // Its private resources cannot leak into the page or changed donor.
        // Audit that donor's own stream separately, not unrelated backgrounds.
        if scannedRootResourcesOnly { return }
        var group: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "Group", &group) { hasUnsafeNestedCompositing = true }
        let identity = pdfReferenceIdentity(stream)
        references[identity, default: 0] += 1
        if references[identity, default: 0] > 1 { repeated = true }
        guard activeStreams.insert(identity).inserted else {
            error = AuditFailure.limit; CGPDFScannerStop(scanner); return
        }
        defer { activeStreams.remove(identity) }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        guard let effectiveResources = resources ?? resourceStack.last else {
            error = AuditFailure.invalid; CGPDFScannerStop(scanner); return
        }
        resourceStack.append(effectiveResources)
        defer { resourceStack.removeLast() }
        let nested = CGPDFContentStreamCreateWithStream(stream, effectiveResources, content)
        defer { CGPDFContentStreamRelease(nested) }
        scan(nested, depth: depth + 1)
    }
}
