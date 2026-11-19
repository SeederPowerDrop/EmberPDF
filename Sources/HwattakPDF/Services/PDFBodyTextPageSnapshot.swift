// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import CoreText
import Darwin
import CryptoKit
import Foundation
import PDFKit
import zlib

/// A construction receipt, not an assertion of equal encoded PDF streams.
/// Only PageWriter in this file can issue or compose it. Its normal source
/// stream decoder/re-encoder remains the existing fixed lossless policy.
final class PDFBodyResourceCopyWitness: @unchecked Sendable {
    let source: CGPDFPage
    let resources: CGPDFObjectRef?
    let outputSHA256: Data
    let contentSHA256: Data
    let donorName: String?
    let donorProgram: Data?
    let droppedForms: Set<String>
    fileprivate init(source: CGPDFPage, resources: CGPDFObjectRef?, output: Data,
                     contentSHA256: Data, donorName: String?, donorProgram: Data?, droppedForms: Set<String>) {
        self.source = source; self.resources = resources
        outputSHA256 = Data(SHA256.hash(data: output)); self.contentSHA256 = contentSHA256
        self.donorName = donorName; self.donorProgram = donorProgram; self.droppedForms = droppedForms
    }
    fileprivate func matches(_ data: Data) -> Bool {
        data.count <= 16 * 1_024 * 1_024 && Data(SHA256.hash(data: data)) == outputSHA256
    }
    fileprivate func resealed(_ data: Data) -> PDFBodyResourceCopyWitness {
        PDFBodyResourceCopyWitness(source: source, resources: resources, output: data,
            contentSHA256: contentSHA256, donorName: donorName, donorProgram: donorProgram, droppedForms: droppedForms)
    }
}
struct PDFBodyResourceCopyOutput {
    let data: Data
    let witness: PDFBodyResourceCopyWitness?
}

/// Serializes only the original page resource graph. PDFKit's page/document
/// serialization may redraw content, normalize a nonzero page origin, or alter
/// calibrated colors, none of which is acceptable before a native body edit.
@MainActor
enum PDFBodyTextPageSnapshot {
    /// Private freshly generated donor only. Copy matched font descriptors;
    /// never override a shared raw descriptor or FontFile2 object globally.
    static func preservingApprovedFontPrograms(in serialized: Data,
        tokens: [PDFBodyTextDocumentFonts.ApprovedProgramToken]) throws -> Data {
        guard !tokens.isEmpty, tokens.count <= 64, tokens.allSatisfy({ $0.isValid }),
              serialized.count <= 64 * 1_024 * 1_024,
              let donor = PDFDocument(data: serialized), donor.pageCount == 1, !donor.isEncrypted,
              let page = donor.page(at: 0), let reference = page.pageRef,
              let pageDictionary = reference.dictionary else { throw SnapshotFailure.invalidObject(#line) }
        func obj(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
            var value: CGPDFObjectRef?; return CGPDFDictionaryGetObject(dictionary, key, &value) ? value : nil
        }
        func named(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var value: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, key, &value), let value,
                  strnlen(value, 129) <= 128 else { return nil }; return String(cString: value)
        }
        var resources: CGPDFDictionaryRef?, fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts,
              CGPDFDictionaryGetCount(fonts) <= 64 else { throw SnapshotFailure.invalidObject(#line) }
        var overrides: [UInt: (bytes: Data, digest: Data)] = [:]
        var unique = Set<Data>(), ownedBytes = 0, failure: Error?
        CGPDFDictionaryApplyBlock(fonts, { key, _, _ in
            do {
                guard strnlen(key, 129) <= 128 else { throw SnapshotFailure.limitExceeded }
                var font: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(fonts, key, &font), let font else { throw SnapshotFailure.invalidObject(#line) }
                guard named(font, "Type") == "Font", named(font, "Subtype") == "TrueType",
                      named(font, "Encoding") == "MacRomanEncoding", obj(font, "Differences") == nil else { return true }
                var descriptor: CGPDFDictionaryRef?, widths: CGPDFArrayRef?, first: CGPDFInteger = 0, last: CGPDFInteger = 0
                guard CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor,
                      named(descriptor, "Type") == "FontDescriptor",
                      CGPDFDictionaryGetInteger(font, "FirstChar", &first), CGPDFDictionaryGetInteger(font, "LastChar", &last),
                      first >= 0, last >= first, last <= 255,
                      CGPDFDictionaryGetArray(font, "Widths", &widths), let widths,
                      CGPDFArrayGetCount(widths) == last - first + 1 else { return true }
                for index in 0..<CGPDFArrayGetCount(widths) {
                    var width: CGPDFReal = 0
                    guard CGPDFArrayGetNumber(widths, index, &width), width.isFinite, abs(width) <= 100_000 else { return true }
                }
                var flags: CGPDFInteger = 0, stream: CGPDFStreamRef?
                guard CGPDFDictionaryGetInteger(descriptor, "Flags", &flags), flags >= 0,
                      flags & 4 == 0, flags & 32 != 0,
                      obj(descriptor, "FontFile") == nil, obj(descriptor, "FontFile3") == nil,
                      CGPDFDictionaryGetStream(descriptor, "FontFile2", &stream), let stream,
                      let streamDictionary = CGPDFStreamGetDictionary(stream),
                      obj(streamDictionary, "F") == nil, obj(streamDictionary, "FFilter") == nil,
                      obj(streamDictionary, "FDecodeParms") == nil else { return true }
                var declared: CGPDFInteger = 0
                guard CGPDFDictionaryGetInteger(streamDictionary, "Length1", &declared),
                      declared > 12, declared <= 16 * 1_024 * 1_024 else { return true }
                var format = CGPDFDataFormat.raw
                guard let copied = CGPDFStreamCopyData(stream, &format), format == .raw else { return true }
                let bytes = copied as Data
                guard bytes.count == declared, let provider = CGDataProvider(data: copied), let graphics = CGFont(provider),
                      let approved = PDFBodyTextDocumentFonts.approvedProgram(forGeneratedSubset: graphics, tokens: tokens)
                else { return true }
                if unique.insert(approved.digest).inserted {
                    guard approved.bytes.count <= 32 * 1_024 * 1_024 - ownedBytes else { throw SnapshotFailure.limitExceeded }
                    ownedBytes += approved.bytes.count
                }
                overrides[pdfReferenceIdentity(font)] = approved
                return true
            } catch { failure = error; return false }
        }, nil)
        if let failure { throw failure }
        guard tokens.allSatisfy({ $0.isValid }) else { throw SnapshotFailure.invalidObject(#line) }
        guard !overrides.isEmpty else { return serialized }
        let output = try PageWriter(fontNames: .unchanged, approvedDonorPrograms: overrides)
            .write(reference: reference, source: page)
        guard tokens.allSatisfy({ $0.isValid }), output.count <= 64 * 1_024 * 1_024 else {
            throw SnapshotFailure.invalidObject(#line)
        }
        return output
    }

    /// A permission-checked, unmodified painting graph for page assembly.
    /// The marker makes the existing save pipeline retain these resources
    /// instead of accepting PDFKit's image/color-space normalization.
    nonisolated static func originalPageData(for page: PDFPage) throws -> Data {
        if let document = page.document { try PDFDocumentSecurityPolicy.validateCanExtractPages(document) }
        guard let reference = page.pageRef else { throw SnapshotFailure.invalidObject(#line) }
        return try PageWriter(fontNames: .unchanged).write(reference: reference, source: page,
            preservePageContent: true)
    }

    /// Optional assembly backing: omit only image names proved unused by this
    /// current page. The source and its catalog Origin remain unchanged.
    nonisolated static func compactAssemblyPageData(for page: PDFPage, maximumBytes: Int) throws -> Data? {
        try PDFSaveCancellation.checkCurrent()
        if let document = page.document { try PDFDocumentSecurityPolicy.validateCanExtractPages(document) }
        guard maximumBytes > 0, page.annotations.isEmpty, let reference = page.pageRef else { return nil }
        var raw: PDFRawStreamSource?
        if let document = page.document, PDFRawStreamProvenance.hasKnownNativeInput(document),
           let native = reference.document, document.documentRef === native,
           let dictionary = reference.dictionary,
           let candidate = PDFRawStreamProvenance.source(for: page), candidate.provesExactFactoryOwner(native) {
            let index = document.index(for: page)
            if index >= 0, index < native.numberOfPages,
               native.page(at: index + 1)?.dictionary == dictionary { raw = candidate }
        }
        return try PageWriter(fontNames: .unchanged, encodedAssemblySource: raw, maximumBytes: maximumBytes)
            .writeCompactAssemblyPage(reference: reference, source: page)
    }

    /// Assembly-only painting copy. No annotation, tag or canonical body-edit
    /// authority is issued. An absent current factory witness keeps the old
    /// snapshot route; a missing encoded payload on this route fails closed.
    nonisolated static func encodedAssemblyPageData(for page: PDFPage) throws -> Data? {
        try PDFSaveCancellation.checkCurrent()
        guard let document = page.document else { return nil }
        try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
        guard PDFRawStreamProvenance.hasKnownNativeInput(document),
              let reference = page.pageRef, let native = reference.document,
              document.documentRef === native, let dictionary = reference.dictionary,
              let raw = PDFRawStreamProvenance.source(for: page), raw.provesExactFactoryOwner(native)
        else { return nil }
        let index = document.index(for: page)
        guard index >= 0, index < native.numberOfPages,
              native.page(at: index + 1)?.dictionary == dictionary else { return nil }
        let data = try PageWriter(fontNames: .unchanged, encodedAssemblySource: raw)
            .write(reference: reference, source: page, preservePageContent: true)
        guard page.pageRef?.dictionary == dictionary, page.pageRef?.document === native,
              document.documentRef === native, raw.provesExactFactoryOwner(native)
        else { throw SnapshotFailure.invalidObject(#line) }
        return data
    }

    /// Recovery-only assembled pages keep their existing immutable Origin;
    /// the live page supplies current geometry and annotations stay separate.
    nonisolated static func encodedRecoveryAssemblyPageData(for page: PDFPage) throws -> Data {
        guard let document = page.document else { throw SnapshotFailure.invalidObject(#line) }
        try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
        guard let witness = try PDFCatalogStructurePreserver.encodedAssemblyOrigin(for: page),
              try witness.matches(page, reference: witness.reference, raw: witness.raw) else {
            throw SnapshotFailure.invalidObject(#line)
        }
        let data = try PageWriter(fontNames: .unchanged, encodedAssemblySource: witness.raw,
                                  encodedAssemblyOrigin: witness)
            .write(reference: witness.reference, source: page, preservePageContent: true)
        guard try witness.matches(page, reference: witness.reference, raw: witness.raw) else {
            throw SnapshotFailure.invalidObject(#line)
        }
        return data
    }

    static func data(for page: PDFPage) throws -> Data {
        if let document = page.document,
           document.isLocked || (document.isEncrypted && document.permissionsStatus != .owner) {
            throw SnapshotFailure.restricted
        }
        guard let reference = page.pageRef else { throw SnapshotFailure.invalidObject(#line) }
        return try PageWriter(fontNames: .protectForEditing).write(reference: reference, source: page)
    }

    /// One Apply operation can validate many content prefixes against the same
    /// immutable painting/font resources. Keep the already encoded bodies,
    /// rather than decoding and recompressing every image for every prefix.
    /// No live PDFKit/CoreGraphics object or cross-document cache is retained.
    struct ContentTemplate {
        fileprivate let bodies: [Data]
        fileprivate let contentObjectID: Int

        func data(contentOverride: Data) throws -> Data {
            try PageWriter(fontNames: .unchanged).write(template: self, contentOverride: contentOverride)
        }
    }

    static func contentTemplate(for page: PDFPage,
                                onResourceStreamEncoded: (() -> Void)? = nil) throws -> ContentTemplate {
        if let document = page.document,
           document.isLocked || (document.isEncrypted && document.permissionsStatus != .owner) {
            throw SnapshotFailure.restricted
        }
        guard let reference = page.pageRef else { throw SnapshotFailure.invalidObject(#line) }
        return try PageWriter(fontNames: .unchanged, onResourceStreamEncoded: onResourceStreamEncoded)
            .contentTemplate(reference: reference, source: page)
    }

    /// PDFium's content generator identifies simple fonts by their family
    /// name after stripping the subset prefix. Distinct embedded subsets can
    /// then accidentally share one font dictionary and its character widths.
    /// Editing snapshots use temporary unique aliases; remove those aliases
    /// before returning a page to PDFKit so saved font names remain consistent
    /// with the original descriptors and embedded font programs.
    static func restoringFontNames(in data: Data, preservePageContent: Bool = false,
                                   generatedDonor: PDFBodyGeneratedDonorTag? = nil) throws -> Data {
        if let generatedDonor {
            return try generatedDonor.withSnapshot(matching: data) { page, reference, form in
                let writer = PageWriter(fontNames: .restoreOriginals, markingGeneratedBodyForm: form)
                let output = try writer.write(reference: reference, source: page,
                    preservePageContent: preservePageContent)
                guard writer.generatedBodyMarkerApplied else { throw SnapshotFailure.invalidObject(#line) }
                return output
            }
        }
        guard let document = PDFDocument(data: data), document.pageCount == 1,
              let page = document.page(at: 0), let reference = page.pageRef else {
            throw SnapshotFailure.invalidObject(#line)
        }
        PDFRawStreamProvenance.bindCreated(document, data: data)
        return try PageWriter(fontNames: .restoreOriginals).write(reference: reference, source: page,
            preservePageContent: preservePageContent)
    }

    static func contentData(for page: PDFPage) throws -> Data {
        guard let reference = page.pageRef else { throw SnapshotFailure.invalidObject(#line) }
        return try PageWriter(fontNames: .unchanged).contentData(reference: reference)
    }

    static func unusedXObjectName(for page: PDFPage) throws -> String {
        guard let dictionary = page.pageRef?.dictionary else { throw SnapshotFailure.invalidObject(#line) }
        return try PageWriter(fontNames: .unchanged).unusedXObjectName(in: dictionary)
    }

    static func isBodyTextXObject(named name: String, on page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return false }
        return PageWriter(fontNames: .unchanged).isBodyTextXObject(named: name, in: dictionary)
    }

    /// Optional geometry of our native donor. The editor must independently
    /// match its invocation/native contents and current neighbour clearance.
    /// This is not an authority to retain raw bytes or structure ownership.
    static func bodyTextLayoutBounds(named name: String, on page: PDFPage) throws -> CGRect? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        return try PageWriter(fontNames: .unchanged).bodyTextLayoutBounds(named: name, in: dictionary)
    }

    /// The marker is opaque here; the dedicated editor validates its version,
    /// fields and relationship to the native Form before using it.
    static func outlinedOCRMetadata(named name: String, on page: PDFPage) -> Data? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        return PageWriter(fontNames: .unchanged).outlinedOCRMetadata(named: name, in: dictionary)
    }

    static func scannedErasureMetadata(named name: String, on page: PDFPage) -> Data? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        return PageWriter(fontNames: .unchanged).scannedErasureMetadata(named: name, in: dictionary)
    }

    static func scannedOCRFont(named name: String, on page: PDFPage) -> (object: CGPDFObjectRef, defaultWidth: CGFloat)? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        return PageWriter(fontNames: .unchanged).scannedOCRFont(named: name, in: dictionary)
    }

    /// Retain genuine drawing-font programs as unused resources for re-editing,
    /// but use the source OCR font for the single searchable semantic layer.
    static func outlinedOCRDonor(_ pathsPDF: Data, semanticContent: Data,
                                 sourceFontName: String, sourcePage: PDFPage,
                                 metadata: Data, visibleClipRects: [CGRect]? = nil) throws -> Data {
        guard pathsPDF.count <= 64 * 1_024 * 1_024, semanticContent.count <= 1_024 * 1_024,
              !metadata.isEmpty, metadata.count <= 1_024 * 1_024,
              let font = scannedOCRFont(named: sourceFontName, on: sourcePage),
              let document = PDFDocument(data: pathsPDF), document.pageCount == 1,
              let page = document.page(at: 0), let reference = page.pageRef else {
            throw SnapshotFailure.invalidObject(#line)
        }
        PDFRawStreamProvenance.bindCreated(document, data: pathsPDF)
        let raw = try contentData(for: page)
        let shows = try PDFScannedContentStream.parse(raw)
        guard shows.shows.allSatisfy(\.invisible) else { throw SnapshotFailure.invalidObject(#line) }
        let parsed = try PDFBodyTextContentStream.parse(raw)
        let markup = try donorRecognitionMarkup(in: raw)
        var ranges: [Range<Int>] = []
        for range in (parsed.blocks.map(\.range) + markup).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { ranges.append(range) }
        }
        var content = raw
        for range in ranges.reversed() { content.removeSubrange(range) }
        if let visibleClipRects {
            guard !visibleClipRects.isEmpty, visibleClipRects.count <= 256,
                  visibleClipRects.allSatisfy({
                      [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite)
                          && $0.width > 0 && $0.height > 0
                  }) else { throw SnapshotFailure.invalidObject(#line) }
            var clipping = Data("q\n".utf8)
            for rectangle in visibleClipRects {
                let values = [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height]
                let command = try values.map(PDFDecimalNumber.string).joined(separator: " ") + " re\n"
                clipping.append(Data(command.utf8))
            }
            clipping.append(Data("W n\n".utf8))
            clipping.append(content)
            clipping.append(Data("\nQ\n".utf8))
            content = clipping
        }
        content.append(Data("\n".utf8))
        content.append(semanticContent)
        return try PageWriter(fontNames: .unchanged).write(reference: reference, source: page,
            contentOverride: content, fontOverrides: ["EmberOCRSource": font.object],
            outlinedOCRMetadata: metadata)
    }

    /// CoreText can encode an accented glyph with an ActualText span around a
    /// separate invisible BT/ET. Removing BT alone would leave an empty span
    /// whose extraction differs across PDF engines. Accept only generated
    /// semantic spans with no painted artwork, and remove both delimiters.
    private static func donorRecognitionMarkup(in data: Data) throws -> [Range<Int>] {
        var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(data))
        var operands: [PDFBodyTextContentStream.Lexer.Token] = []
        var ranges: [Range<Int>] = [], depth = 0
        let semanticCommands: Set<String> = ["q", "Q", "cm", "BT", "ET", "Tf", "Tr", "Tm", "Td", "TD",
            "T*", "Tj", "TJ", "'", "\"", "Tc", "Tw", "Tz", "TL", "Ts", "g", "G", "rg", "RG",
            "k", "K", "cs", "CS", "sc", "SC", "scn", "SCN", "ri"]
        while let token = try lexer.next() {
            guard let command = token.command else { operands.append(token); continue }
            switch command {
            case "BDC":
                guard operands.count == 2, operands[0].name == "Span",
                      let properties = operands[1].dictionary, properties.count == 1,
                      let actual = properties["ActualText"]?.stringBytes, !actual.isEmpty,
                      actual.count <= 1_024 * 1_024, depth < 64 else { throw SnapshotFailure.invalidObject(#line) }
                ranges.append(operands[0].range.lowerBound..<token.range.upperBound)
                depth += 1
            case "BMC": throw SnapshotFailure.invalidObject(#line)
            case "EMC":
                guard operands.isEmpty, depth > 0 else { throw SnapshotFailure.invalidObject(#line) }
                depth -= 1
                ranges.append(token.range)
            default:
                guard depth == 0 || semanticCommands.contains(command) else { throw SnapshotFailure.invalidObject(#line) }
            }
            operands.removeAll(keepingCapacity: true)
        }
        guard depth == 0, operands.isEmpty else { throw SnapshotFailure.invalidObject(#line) }
        return ranges
    }

    /// Replaces a validated slice of raw content without asking PDFium to
    /// regenerate unrelated text, colors, or drawing operators. A new text
    /// page can be included as an isolated Form with its own resources.
    static func data(for page: PDFPage, contentOverride: Data,
                     donorPDF: Data? = nil, donorName: String? = nil,
                     droppingXObjectNames: Set<String> = [], preservePageContent: Bool = false,
                     donorOCRFontName: String? = nil, donorLayoutBounds: CGRect? = nil,
                     donorScannedErasureMetadata: Data? = nil) throws -> Data {
        if let document = page.document,
           document.isLocked || (document.isEncrypted && document.permissionsStatus != .owner) {
            throw SnapshotFailure.restricted
        }
        guard let reference = page.pageRef else { throw SnapshotFailure.invalidObject(#line) }
        let writer = PageWriter(fontNames: .unchanged)
        return try writer.write(reference: reference, source: page,
                                contentOverride: contentOverride, donorPDF: donorPDF, donorName: donorName,
                                droppingXObjectNames: droppingXObjectNames, preservePageContent: preservePageContent,
                                donorOCRFontName: donorOCRFontName, donorLayoutBounds: donorLayoutBounds,
                                donorScannedErasureMetadata: donorScannedErasureMetadata)
    }

    /// Optional receipt for the actual native lossless edit branch. The
    /// normal editing admission, encoder policy and byte limits do not change.
    static func losslessData(for page: PDFPage, contentOverride: Data,
                             donorPDF: Data?, donorName: String?,
                             droppingXObjectNames: Set<String>, donorLayoutBounds: CGRect? = nil,
                             donorScannedErasureMetadata: Data? = nil,
                             glyphRewrite: PDFBodyLosslessRewriteReceipt? = nil) throws -> PDFBodyResourceCopyOutput {
        if let document = page.document,
           document.isLocked || (document.isEncrypted && document.permissionsStatus != .owner) {
            throw SnapshotFailure.restricted
        }
        guard let reference = page.pageRef else { throw SnapshotFailure.invalidObject(#line) }
        let glyphOnly: Bool
        if let glyphRewrite {
            guard glyphRewrite.kind == .glyph, glyphRewrite.rewritten == contentOverride,
                  glyphRewrite.source == (try contentData(for: page)),
                  donorPDF == nil, donorName == nil, droppingXObjectNames.isEmpty else {
                throw SnapshotFailure.invalidObject(#line)
            }
            glyphOnly = true
        } else { glyphOnly = false }
        let glyphSource: PDFRawStreamSource?
        if glyphOnly {
            guard let owner = reference.document, let raw = PDFRawStreamProvenance.source(for: page),
                  try raw.provesGlyphPaintingRoots(reference, in: owner) else {
                throw SnapshotFailure.invalidObject(#line)
            }
            glyphSource = raw
        } else { glyphSource = nil }
        let writer = PageWriter(fontNames: .unchanged, captureBodyCopy: contentOverride.count <= 2 * 1_024 * 1_024,
                                carriesUnmodifiedType3Resources: glyphOnly, encodedAssemblySource: glyphSource)
        let data = try writer.write(reference: reference, source: page, contentOverride: contentOverride,
            donorPDF: donorPDF, donorName: donorName, droppingXObjectNames: droppingXObjectNames,
            preservePageContent: glyphOnly,
            donorLayoutBounds: donorLayoutBounds, donorScannedErasureMetadata: donorScannedErasureMetadata)
        return PDFBodyResourceCopyOutput(data: data, witness: writer.bodyCopyWitness)
    }

    static func restoringFontNamesPreservingBodyCopy(_ output: PDFBodyResourceCopyOutput) throws -> PDFBodyResourceCopyOutput {
        guard let witness = output.witness, witness.matches(output.data),
              let document = PDFDocument(data: output.data), document.pageCount == 1,
              let page = document.page(at: 0), let reference = page.pageRef else {
            return PDFBodyResourceCopyOutput(data: try restoringFontNames(in: output.data, preservePageContent: true), witness: nil)
        }
        PDFRawStreamProvenance.bindCreated(document, data: output.data)
        let writer = PageWriter(fontNames: .restoreOriginals, captureBodyCopy: true)
        let data = try writer.write(reference: reference, source: page, preservePageContent: true)
        // A normal reconstruction copies this already witnessed graph. Any
        // font-name restoration, OCR override, tagged Form or unknown transform
        // prevents issuing the composite witness; editing itself still succeeds.
        let sealed = writer.bodyCopyWitness != nil && data.count <= 16 * 1_024 * 1_024
            ? witness.resealed(data) : nil
        return PDFBodyResourceCopyOutput(data: data, witness: sealed)
    }

    /// Read-only opt-in used by the save pipeline, including its confined
    /// background PDFDocument instances. No serialization is performed here.
    nonisolated static func requiresPageContentPreservation(_ document: PDFDocument) -> Bool {
        for index in 0..<document.pageCount {
            guard let dictionary = document.page(at: index)?.pageRef?.dictionary else { continue }
            var enabled: CGPDFBoolean = 0
            if CGPDFDictionaryGetBoolean(dictionary, "EmberPDFPreservePageContent", &enabled), enabled != 0 {
                return true
            }
        }
        return false
    }

    /// Preserve PDFKit's newly saved document structure and annotation edits,
    /// while restoring each live page's original painting/font resource graph.
    /// This deliberately refuses encrypted inputs instead of emitting plaintext
    /// from a password-protected save. The caller owns the document exclusively.
    nonisolated static func preservingPageContents(in serialized: Data, from document: PDFDocument) throws -> Data {
        guard !document.isEncrypted, !document.isLocked else { throw SnapshotFailure.restricted }
        return try PageWriter(fontNames: .unchanged, documentGraph: true)
            .writeDocument(serialized: serialized, source: document)
    }

    nonisolated static func preservingCatalog(in serialized: Data, from document: PDFDocument,
                                             plan: PDFCatalogGraphPlan,
                                             metadataSource: PDFCatalogStructurePreserver.NativeStagingSource? = nil) throws -> Data {
        guard !document.isEncrypted, !document.isLocked else { throw SnapshotFailure.restricted }
        try PDFCatalogStructurePreserver.validateEditedPageTags(in: document, plan: plan)
        if let metadataSource {
            guard try PDFCatalogStructurePreserver.matches(metadataSource, document: document) else { throw SnapshotFailure.invalidObject(#line) }
        }
        for (index, permission) in plan.bodyTagPermissions {
            try PDFSaveCancellation.checkCurrent()
            guard let page = document.page(at: index), permission.matchesCurrent(page) else { throw SnapshotFailure.invalidObject(#line) }
        }
        let data = try PageWriter(fontNames: .unchanged, documentGraph: true, catalogGraph: true)
            .writeDocument(serialized: serialized, source: document, catalogPlan: plan, metadataSource: metadataSource)
        for (index, permission) in plan.bodyTagPermissions {
            try PDFSaveCancellation.checkCurrent()
            guard let page = document.page(at: index), permission.matchesCurrent(page) else { throw SnapshotFailure.invalidObject(#line) }
        }
        return data
    }

    nonisolated static func metadataMatches(_ document: PDFDocument,
            source: PDFCatalogStructurePreserver.NativeStagingSource) throws -> Bool {
        try PDFSaveCancellation.checkCurrent()
        guard let metadata = try? PageWriter(fontNames: .unchanged).metadataDocument(from: source.metadataOwner),
              let baseline = PDFDocument(data: metadata) else { return false }
        return NSDictionary(dictionary: document.documentAttributes ?? [:]).isEqual(to: baseline.documentAttributes ?? [:])
    }

    /// A body-only change in an otherwise unchanged, unannotated document can
    /// reuse its immutable native catalog as the staging graph. PDFKit would
    /// otherwise redraw every scanned page before this writer restores their
    /// exact original painting. Any unproven live structure uses normal saving.
    nonisolated static func directlyPreservingBodyContentsIfEligible(_ document: PDFDocument) throws -> Data? {
        guard requiresPageContentPreservation(document), !document.isEncrypted, !document.isLocked,
              document.pageCount > 0, document.pageCount <= 250_000,
              document.outlineRoot == nil else { return nil }
        for index in 0..<document.pageCount {
            guard let live = document.page(at: index), live.annotations.isEmpty else { return nil }
        }
        let plan = try PDFCatalogStructurePreserver.plan(for: document)
        try PDFCatalogStructurePreserver.validateEditedPageTags(in: document, plan: plan)
        // PDFDocument.copy creates a different native parser graph. Its page
        // dictionaries cannot match aliases inherited from the immutable source.
        // Choose only one proven whole source sequence, after deduplicating
        // retained references, so detached recovery/foreground saves can use
        // the same safe body-only route as the live document.
        var candidates: [CGPDFDocument] = []
        var seen = Set<ObjectIdentifier>()
        for candidate in [document.documentRef].compactMap({ $0 }) + plan.retainedDocuments {
            if seen.insert(ObjectIdentifier(candidate)).inserted { candidates.append(candidate) }
        }
        var selected: CGPDFDocument?
        for candidate in candidates {
            guard try canStageBodyContents(from: candidate, document: document, plan: plan) else { continue }
            guard selected == nil else { return nil }
            selected = candidate
        }
        guard let native = selected else { return nil }
        return try PageWriter(fontNames: .unchanged, documentGraph: true, catalogGraph: true)
            .writeDocument(staged: native, source: document, catalogPlan: plan)
    }

    private nonisolated static func canStageBodyContents(from native: CGPDFDocument,
                                                         document: PDFDocument,
                                                         plan: PDFCatalogGraphPlan) throws -> Bool {
        guard !native.isEncrypted, native.isUnlocked,
              document.pageCount == native.numberOfPages, let catalog = native.catalog,
              !hasObject(catalog, "Outlines"), !hasObject(catalog, "AcroForm") else { return false }
        for index in 0..<document.pageCount {
            guard let live = document.page(at: index), let original = native.page(at: index + 1),
                  let dictionary = original.dictionary, emptyAnnotations(dictionary),
                  let originalRotation = inheritedNativeRotation(dictionary), live.rotation % 90 == 0,
                  ((live.rotation % 360) + 360) % 360 == originalRotation,
                  case .page(let outputIndex)? = plan.aliases[pdfReferenceIdentity(dictionary)],
                  outputIndex == index else { return false }
            for (liveBox, nativeBox) in [(PDFDisplayBox.mediaBox, CGPDFBox.mediaBox), (.cropBox, .cropBox),
                                        (.bleedBox, .bleedBox), (.trimBox, .trimBox), (.artBox, .artBox)] {
                guard live.bounds(for: liveBox) == original.getBoxRect(nativeBox) else { return false }
            }
        }
        // Decode the original Info through PDFKit itself so date and keyword
        // normalization is identical to the live document's attributes. This
        // tiny blank staging file never reads a page image or font resource.
        guard let metadata = try? PageWriter(fontNames: .unchanged).metadataDocument(from: native),
              let baseline = PDFDocument(data: metadata),
              NSDictionary(dictionary: document.documentAttributes ?? [:])
                .isEqual(to: baseline.documentAttributes ?? [:]) else { return false }
        return true
    }

    private nonisolated static func hasObject(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &object)
    }

    private nonisolated static func emptyAnnotations(_ dictionary: CGPDFDictionaryRef) -> Bool {
        guard hasObject(dictionary, "Annots") else { return true }
        var annotations: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary, "Annots", &annotations)
            && annotations.map { CGPDFArrayGetCount($0) == 0 } == true
    }

    private nonisolated static func inheritedNativeRotation(_ dictionary: CGPDFDictionaryRef) -> Int? {
        // PDFPage.rotation may alter CGPDFPage.rotationAngle without changing
        // the immutable dictionary we will serialize. Read the actual saved
        // inheritance chain rather than accepting that mutable native getter.
        var current = dictionary, visited = Set<UInt>()
        for _ in 0..<64 {
            guard visited.insert(pdfReferenceIdentity(current)).inserted else { return nil }
            if hasObject(current, "Rotate") {
                var value: CGPDFInteger = 0
                guard CGPDFDictionaryGetInteger(current, "Rotate", &value), value % 90 == 0 else { return nil }
                return ((Int(value) % 360) + 360) % 360
            }
            guard hasObject(current, "Parent") else { return 0 }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent), let parent else { return nil }
            current = parent
        }
        return nil
    }

    private enum FontNames { case unchanged, protectForEditing, restoreOriginals }

    private enum SnapshotFailure: LocalizedError {
        case restricted, invalidObject(Int), limitExceeded

        var errorDescription: String? {
            switch self {
            case .restricted:
                return L10n.string("body_text.error.restricted", defaultValue:
                    "이 PDF의 본문을 편집하려면 소유자 권한으로 열어 주세요.")
            case .invalidObject:
                return L10n.string("body_text.error.unreadable", defaultValue:
                    "PDF 본문을 편집 가능한 형태로 읽지 못했습니다.")
            case .limitExceeded:
                return L10n.string("body_text.error.too_complex", defaultValue:
                    "이 페이지나 텍스트는 안전하게 편집할 수 있는 크기를 초과합니다.")
            }
        }
    }

    /// Based on the bounded resource writer used by PDFNativeSelectionProxy,
    /// retaining every image/resource stream and every embedded font program.
    private final class PageWriter {
        private let maximumBytes: Int
        private let maximumObjects: Int
        private let maximumVisits: Int
        private let documentGraph: Bool
        private var bodies: [Data?]
        private var identifiers: [UInt: Int] = [:]
        private var dictionaryIdentifiers: [UInt: Int] = [:]
        private var streamIdentifiers: [UInt: Int] = [:]
        private struct PageOverride {
            let reference: CGPDFPage
            let dictionary: CGPDFDictionaryRef
            let translation: CGPoint
        }
        private enum PendingBody {
            case object(CGPDFObjectRef)
            case dictionary(CGPDFDictionaryRef)
            case outline(CGPDFDictionaryRef, edges: [String: Int])
            case custom(PDFCatalogGraphNode)
            case sparseArray(count: Int, members: [Int: PDFCatalogGraphValue], depth: Int, aliases: Set<UInt>)
        }
        private var pendingBodies: [(Int, PendingBody)] = []
        private var outlineRootID: Int?
        private var pageOverrides: [UInt: PageOverride] = [:]
        private var appliedPageOverrides: Set<UInt> = []
        private var retainedPages: [CGPDFPage] = []
        private var storedBytes = 0
        private var inlineBytes = 0
        private var visits = 0
        // Object identities are pointer keys. Retain every imported document
        // until serialization ends so later lazy resource reads cannot reuse
        // an address from a released donor and resolve to its unrelated body.
        private var retainedDonors: [CGPDFDocument] = []
        private var catalogPlan: PDFCatalogGraphPlan?
        private var stagedPages: [CGPDFDictionaryRef] = []
        private var stagedCatalog: CGPDFDictionaryRef?
        private var customIdentifiers: [ObjectIdentifier: Int] = [:]
        private var activeAliases: Set<UInt> = []
        private var stagedPageTreeDictionaries: Set<UInt> = []
        private var resolvedCatalogOverrides: [UInt: [String: PDFCatalogGraphValue]] = [:]
        private var resolvedCatalogDrops: [UInt: Set<String>] = [:]
        private var compactAssembly = false
        private var compactContents: [UInt: Data] = [:]
        private let captureBodyCopy: Bool
        private let carriesUnmodifiedType3Resources: Bool
        private var bodyCopyUnsafe = false
        private var bodyDonorProgram: Data?
        var bodyCopyWitness: PDFBodyResourceCopyWitness?
        private let fontNames: FontNames
        private let onResourceStreamEncoded: (() -> Void)?
        private let encodedAssemblySource: PDFRawStreamSource?
        private let encodedAssemblyOrigin: PDFCatalogStructurePreserver.EncodedAssemblyOrigin?
        private var rawStreamSources: [PDFRawStreamSource] = []
        private var rawStreamSourceIDs = Set<ObjectIdentifier>()
        private var numberDictionarySources: [UInt: [PDFRawStreamSource]] = [:]
        private var numberArraySources: [UInt: [PDFRawStreamSource]] = [:]
        private var singlePageContentObjectID: Int?
        private var fontAliasCount = 0
        private let markingGeneratedBodyForm: CGPDFDictionaryRef?
        private(set) var generatedBodyMarkerApplied = false
        private let approvedDonorPrograms: [UInt: (bytes: Data, digest: Data)]
        private var approvedProgramIDs: [Data: Int] = [:]
        private var approvedProgramBytes = 0
        private static let originalFontNameKey = "EmberPDFBodyOriginalBaseFont"

        init(fontNames: FontNames, documentGraph: Bool = false, catalogGraph: Bool = false,
             onResourceStreamEncoded: (() -> Void)? = nil, captureBodyCopy: Bool = false,
             carriesUnmodifiedType3Resources: Bool = false,
             encodedAssemblySource: PDFRawStreamSource? = nil,
             encodedAssemblyOrigin: PDFCatalogStructurePreserver.EncodedAssemblyOrigin? = nil,
             approvedDonorPrograms: [UInt: (bytes: Data, digest: Data)] = [:],
             markingGeneratedBodyForm: CGPDFDictionaryRef? = nil, maximumBytes requestedMaximumBytes: Int? = nil) {
            self.markingGeneratedBodyForm = markingGeneratedBodyForm
            self.approvedDonorPrograms = approvedDonorPrograms
            self.captureBodyCopy = captureBodyCopy
            self.carriesUnmodifiedType3Resources = carriesUnmodifiedType3Resources
            self.fontNames = fontNames
            self.onResourceStreamEncoded = onResourceStreamEncoded
            self.encodedAssemblySource = encodedAssemblySource
            self.encodedAssemblyOrigin = encodedAssemblyOrigin
            self.documentGraph = documentGraph
            let standardMaximumBytes = (catalogGraph ? 1_024 : (documentGraph ? 512 : 64)) * 1_024 * 1_024
            maximumBytes = min(standardMaximumBytes, max(0, requestedMaximumBytes ?? standardMaximumBytes))
            maximumObjects = documentGraph ? 250_000 : 50_000
            maximumVisits = documentGraph ? 2_000_000 : 100_000
            bodies = documentGraph ? [] : [nil, nil, nil]
        }

        func contentTemplate(reference: CGPDFPage, source: PDFPage) throws -> ContentTemplate {
            // The ordinary writer owns and validates all resource identities,
            // geometry and size limits. Its blank content object has a known
            // ID; no external PDF is searched or patched to find that object.
            _ = try write(reference: reference, source: source, contentOverride: Data())
            guard let contentObjectID = singlePageContentObjectID else {
                throw SnapshotFailure.invalidObject(#line)
            }
            let completed: [Data] = try bodies.map {
                guard let body = $0 else { throw SnapshotFailure.invalidObject(#line) }
                return body
            }
            return ContentTemplate(bodies: completed, contentObjectID: contentObjectID)
        }

        func writeCompactAssemblyPage(reference: CGPDFPage, source: PDFPage) throws -> Data? {
            var plan = PDFCatalogGraphPlan()
            var limits = PDFCatalogImageResourcePruner.Limits()
            limits.maximumDecodedBytes = maximumBytes
            try PDFCatalogImageResourcePruner.addPrunedImageResources(pages: [reference], to: &plan, limits: limits, onContentDecoded: {
                [self] stream, bytes in
                // Reuse the pruner's already bounded content; do not run its
                // decoder again or retain this cache beyond the one writer.
                if encodedAssemblySource == nil { compactContents[pdfReferenceIdentity(stream)] = bytes }
            }, requireImageOnlyPainting: true)
            guard !plan.dictionaryDrops.isEmpty else { return nil }
            // Drops are derived here from this exact painting, not supplied
            // by callers or accepted as a body/font reconstruction witness.
            // Text pages retain their existing backing: a fresh one-page
            // context can change PDFKit's inferred line/space extraction.
            resolvedCatalogDrops = plan.dictionaryDrops
            compactAssembly = true
            return try write(reference: reference, source: source, preservePageContent: true)
        }

        func write(template: ContentTemplate, contentOverride: Data) throws -> Data {
            guard !documentGraph, template.bodies.count >= 4, template.bodies.count <= maximumObjects,
                  (1...template.bodies.count).contains(template.contentObjectID),
                  contentOverride.count <= maximumBytes else { throw SnapshotFailure.limitExceeded }
            bodies = template.bodies.map(Optional.some)
            // Exclude the one replaced body from the retained resource budget.
            // A fresh writer per result makes failures/reuse independent.
            for (index, body) in template.bodies.enumerated() where index + 1 != template.contentObjectID {
                guard body.count <= maximumBytes - storedBytes else { throw SnapshotFailure.limitExceeded }
                storedBytes += body.count
            }
            bodies[template.contentObjectID - 1] = nil
            var body = Data("<< /Length \(contentOverride.count) >>\nstream\n".utf8)
            try append(contentOverride, to: &body)
            try append(Data("\nendstream".utf8), to: &body)
            try setBody(template.contentObjectID, body)
            return try finish(trailerEntries: ["/Root 1 0 R"])
        }

        func writeDocument(serialized: Data, source: PDFDocument, catalogPlan: PDFCatalogGraphPlan? = nil,
                           metadataSource: PDFCatalogStructurePreserver.NativeStagingSource? = nil) throws -> Data {
            guard documentGraph, serialized.count <= maximumBytes else { throw SnapshotFailure.limitExceeded }
            // Establish current widget/Fields identity before replacing AP.
            // The existing canonicalizer accepts detached field copies only
            // after complete dictionary equivalence, never name/value alone.
            let repairsCurrentWidgets = catalogPlan?.widgetFormDefaults != nil
                || catalogPlan?.preservesCurrentWidgetDefaults == true
            let stagedData = repairsCurrentWidgets ? try PDFCanonicalFormMaterializer.materialize(serialized) : serialized
            let staged: CGPDFDocument
            let stagedInk: PDFStagedInkGeometryReader?
            if catalogPlan?.annotationNames.isEmpty == false,
               stagedData.count <= PDFStagedInkGeometryReader.maximumInputBytes {
                let reader = try PDFStagedInkGeometryReader.open(stagedData)
                staged = reader.document; stagedInk = reader
            } else {
                guard let provider = CGDataProvider(data: stagedData as CFData),
                      let native = CGPDFDocument(provider) else { throw SnapshotFailure.invalidObject(#line) }
                staged = native; stagedInk = nil
            }
            return try writeDocument(staged: staged, source: source,
                                     catalogPlan: catalogPlan, stagedInk: stagedInk, metadataSource: metadataSource)
        }

        func metadataDocument(from native: CGPDFDocument) throws -> Data {
            guard !documentGraph else { throw SnapshotFailure.invalidObject(#line) }
            try setBody(1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
            try setBody(2, Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
            try setBody(3, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] >>".utf8))
            var trailer = ["/Root 1 0 R"]
            if let info = native.info { trailer.append("/Info \(try documentDictionaryReference(info))") }
            return try finish(trailerEntries: trailer)
        }

        func writeDocument(staged: CGPDFDocument, source: PDFDocument,
                           catalogPlan: PDFCatalogGraphPlan?, stagedInk: PDFStagedInkGeometryReader? = nil,
                           metadataSource: PDFCatalogStructurePreserver.NativeStagingSource? = nil) throws -> Data {
            guard documentGraph else { throw SnapshotFailure.invalidObject(#line) }
            guard catalogPlan?.linkControlProofs.allSatisfy({ $0.matches() }) ?? true,
                  catalogPlan?.annotationTagPermissions.values.allSatisfy({ $0.matches() }) ?? true else { throw SnapshotFailure.invalidObject(#line) }
            defer { for raw in rawStreamSources { raw.releaseCachedPayloads() } }
            guard !staged.isEncrypted, staged.isUnlocked else { throw SnapshotFailure.restricted }
            if let stagedInk, stagedInk.document !== staged { throw SnapshotFailure.invalidObject(#line) }
            guard source.pageCount > 0, source.pageCount == staged.numberOfPages,
                  source.pageCount < maximumObjects, let catalog = staged.catalog else { throw SnapshotFailure.invalidObject(#line) }
            // A pending native shape grants no output authority. Resolve every
            // opaque factory witness before any graph body is scheduled; a
            // failed/cancelled proof returns no document bytes to the caller.
            var outlineDestinations = catalogPlan?.outlineDestinations ?? [:]
            var restoredEmptyOutline: PDFCatalogStructurePreserver.EmptyOutlineSource?
            let pendingInert = catalogPlan?.pendingInertOutlineDestinations ?? [:]
            guard pendingInert.count <= 4_096 else { throw SnapshotFailure.limitExceeded }
            for (path, candidate) in pendingInert {
                try PDFSaveCancellation.checkCurrent()
                guard outlineDestinations.index(forKey: path) == nil,
                      let value = try candidate.provenValue() else { throw SnapshotFailure.invalidObject(#line) }
                outlineDestinations[path] = value
            }
            try PDFSaveCancellation.checkCurrent()
            retainedDonors.append(staged)
            self.catalogPlan = catalogPlan
            for raw in catalogPlan?.rawStreamSources ?? [] { retainRawSource(raw) }
            if let raw = PDFRawStreamProvenance.source(for: source) { retainRawSource(raw) }
            resolvedCatalogOverrides = catalogPlan?.dictionaryOverrides ?? [:]
            stagedCatalog = catalog
            retainedDonors += catalogPlan?.retainedDocuments ?? []
            let normalizedRotation: (Int) -> Int = { (($0 % 360) + 360) % 360 }
            var remainingGeometryCoordinates = 2_000_000
            var remainingNameIdentityBytes = 8 * 1024 * 1024
            var remainingNameIdentityNumbers = 2_000_000
            for index in 0..<source.pageCount {
                // Restoring copied widget scalars can invalidate PDFKit's
                // pageRef. A verified unchanged painting already owns its
                // immutable graph; current edited annotations still come
                // from the staged page below.
                guard let savedPage = staged.page(at: index + 1), let savedDictionary = savedPage.dictionary,
                      let livePage = source.page(at: index),
                      let liveReference = catalogPlan?.paintingSources[index] ?? livePage.pageRef,
                      let liveDictionary = liveReference.dictionary else {
                    throw SnapshotFailure.invalidObject(#line)
                }
                try prepareRawSources(for: livePage, reference: liveReference)
                let key = pdfReferenceIdentity(savedDictionary)
                stagedPages.append(savedDictionary)
                var ancestor = savedDictionary
                for _ in 0..<64 {
                    guard let parent = try dictionaryObject(object(ancestor, "Parent")) else { break }
                    guard stagedPageTreeDictionaries.insert(pdfReferenceIdentity(parent)).inserted else { break }
                    // Every output page owns its resolved geometry. Staged
                    // ancestors must not reintroduce a PDFKit-normalized crop
                    // or rotation when an original optional key was absent.
                    resolvedCatalogDrops[pdfReferenceIdentity(parent), default: []]
                        .formUnion(PDFPageGeometryPreserver.boxes.map(\.0) + ["Rotate"])
                    ancestor = parent
                }
                guard pageOverrides[key] == nil else { throw SnapshotFailure.invalidObject(#line) }
                let translation: CGPoint
                if let catalogPlan {
                    // Keep one coordinate program: exact source/current boxes,
                    // unshifted painting, and exact current annotation geometry.
                    // Staged boxes/Rect arrays are rounded and translated by
                    // PDFKit, so they cannot be the authority for this branch.
                    let geometry = try catalogPlan.pageGeometry[index]
                        ?? PDFPageGeometryPreserver.capture(livePage, reference: liveReference)
                    let entries = try geometry.resolved(for: livePage, rawSources: rawStreamSources)
                    resolvedCatalogDrops[key, default: []]
                        .formUnion(PDFPageGeometryPreserver.boxes.map(\.0) + ["Rotate"])
                    resolvedCatalogOverrides[key, default: [:]].merge(entries) { _, current in current }
                    let annotations = livePage.annotations
                    let savedAnnotations = array(savedDictionary, "Annots")
                    let liveUnit = try userUnit(in: liveDictionary)
                    let stagedUnit = try userUnit(in: savedDictionary)
                    guard (savedAnnotations.map(CGPDFArrayGetCount) ?? 0) == annotations.count,
                          normalizedRotation(livePage.rotation) == normalizedRotation(Int(savedPage.rotationAngle)) else {
                        throw SnapshotFailure.invalidObject(#line)
                    }
                    if liveUnit != stagedUnit {
                        // PDFKit can omit UserUnit while serializing a plain
                        // native page. This verified, annotation-free path
                        // writes the original unit with the same native
                        // Contents/Resources below; no coordinate conversion
                        // or annotation scaling is inferred from staged bytes.
                        guard annotations.isEmpty,
                              catalogPlan.paintingSources[index] != nil,
                              catalogPlan.pageGeometry[index] != nil,
                              object(savedDictionary, "UserUnit") == nil else {
                            throw SnapshotFailure.invalidObject(#line)
                        }
                    }
                    let nameProofs = try PDFPageGeometryPreserver.missingNameProofs(staged: savedAnnotations, live: annotations,
                        names: catalogPlan.annotationNames[index] ?? [:], geometries: catalogPlan.annotationGeometry[index] ?? [:],
                        remainingBytes: &remainingNameIdentityBytes,
                        remainingNumbers: &remainingNameIdentityNumbers, alternateStagedReader: stagedInk, stagedPageIndex: index)
                    for (annotationIndex, annotation) in annotations.enumerated() {
                        var savedAnnotation: CGPDFDictionaryRef?
                        guard let savedAnnotations,
                              CGPDFArrayGetDictionary(savedAnnotations, annotationIndex, &savedAnnotation),
                              let savedAnnotation else { throw SnapshotFailure.invalidObject(#line) }
                        try PDFPageGeometryPreserver.stagedAnnotation(savedAnnotation, matches: annotation,
                            nameProof: nameProofs[annotationIndex])
                        let program = try catalogPlan.annotationGeometry[index]?[annotationIndex]
                            ?? PDFPageGeometryPreserver.liveAnnotation(annotation)
                        guard program.numberCount <= remainingGeometryCoordinates else { throw SnapshotFailure.limitExceeded }
                        remainingGeometryCoordinates -= program.numberCount
                        let identity = pdfReferenceIdentity(savedAnnotation)
                        resolvedCatalogDrops[identity, default: []]
                            .formUnion(PDFPageGeometryPreserver.coordinateKeys + ["Rect"])
                        resolvedCatalogOverrides[identity, default: [:]].merge(program.entries) { _, current in current }
                    }
                    translation = .zero
                } else {
                    translation = try contentTranslation(from: livePage, to: savedPage,
                        liveDictionary: liveDictionary, savedDictionary: savedDictionary)
                }
                pageOverrides[key] = PageOverride(reference: liveReference, dictionary: liveDictionary,
                    translation: translation)
                retainedPages.append(liveReference)
            }
            // Every staged leaf now has an exclusive painting override. Its
            // dictionary encoder emits the source's effective Resources, or
            // an explicit empty dictionary. Parent Resources from PDFKit are
            // therefore shadowed; retaining that SDK-only edge can keep a
            // decoded copy of every large image alive in the output graph.
            // Remove only this inheritance edge, never a resource dictionary
            // or an annotation/AP reference that independently needs it.
            guard stagedPages.count == source.pageCount,
                  pageOverrides.count == stagedPages.count else {
                throw SnapshotFailure.invalidObject(#line)
            }
            for (offset, parent) in stagedPageTreeDictionaries.enumerated() {
                if offset & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                resolvedCatalogDrops[parent, default: []].insert("Resources")
            }
            if let catalogPlan {
                for (key, drops) in catalogPlan.dictionaryDrops {
                    resolvedCatalogDrops[key, default: []].formUnion(drops)
                }
                resolvedCatalogDrops[pdfReferenceIdentity(catalog), default: []].formUnion(catalogPlan.catalogDrops)
                resolvedCatalogOverrides[pdfReferenceIdentity(catalog), default: [:]].merge(catalogPlan.catalogEntries) { _, new in new }
                if let defaults = catalogPlan.widgetFormDefaults {
                    let entries = try PDFWidgetAppearancePreserver.formEntries(staged: staged,
                        defaults: defaults, widgets: catalogPlan.widgetFormLocations)
                    resolvedCatalogOverrides[pdfReferenceIdentity(catalog), default: [:]]["AcroForm"] = .dictionary(entries)
                } else if let empty = catalogPlan.emptyFormSource,
                          catalogPlan.catalogEntries["AcroForm"] == nil,
                          !catalogPlan.catalogDrops.contains("AcroForm"),
                          let original = try PDFCatalogStructurePreserver.originalEmptyForm(empty, for: source, staged: staged) {
                    resolvedCatalogOverrides[pdfReferenceIdentity(catalog), default: [:]]["AcroForm"] = .original(original)
                }
                if let empty = catalogPlan.emptyOutlineSource,
                   catalogPlan.catalogEntries["Outlines"] == nil,
                   !catalogPlan.catalogDrops.contains("Outlines"),
                   let original = try PDFCatalogStructurePreserver.originalEmptyOutline(empty, for: source, staged: staged) {
                    resolvedCatalogOverrides[pdfReferenceIdentity(catalog), default: [:]]["Outlines"] = .original(original)
                    restoredEmptyOutline = empty
                }
                for (index, entries) in catalogPlan.pageEntries {
                    guard stagedPages.indices.contains(index) else { throw SnapshotFailure.invalidObject(#line) }
                    resolvedCatalogOverrides[pdfReferenceIdentity(stagedPages[index]), default: [:]].merge(entries) { _, new in new }
                }
                for (index, drops) in catalogPlan.pageDrops {
                    guard stagedPages.indices.contains(index) else { throw SnapshotFailure.invalidObject(#line) }
                    resolvedCatalogDrops[pdfReferenceIdentity(stagedPages[index]), default: []].formUnion(drops)
                }
                for (page, annotations) in catalogPlan.annotationEntries {
                    guard stagedPages.indices.contains(page), let list = array(stagedPages[page], "Annots") else { throw SnapshotFailure.invalidObject(#line) }
                    for (index, entries) in annotations {
                        var annotation: CGPDFDictionaryRef?
                        guard CGPDFArrayGetDictionary(list, index, &annotation), let annotation else { throw SnapshotFailure.invalidObject(#line) }
                        var sealedEntries = entries
                        if case .dictionary(var record)? = entries[PDFSignatureAppearancePreserver.markerKey], entries["AP"] != nil {
                            // AP authority has already been proved by the worker.
                            // Seal only the exact controls that this staged
                            // dictionary plus final geometry will actually emit.
                            record["State"] = .string(try PDFSignatureAppearancePreserver.storedDrawingDigest(annotation,
                                rectangle: catalogPlan.annotationGeometry[page]?[index]?.entries["Rect"]))
                            sealedEntries[PDFSignatureAppearancePreserver.markerKey] = .dictionary(record)
                        }
                        resolvedCatalogOverrides[pdfReferenceIdentity(annotation), default: [:]].merge(sealedEntries) { _, new in new }
                    }
                }
                for (page, annotations) in catalogPlan.annotationDrops {
                    guard stagedPages.indices.contains(page) else { throw SnapshotFailure.invalidObject(#line) }
                    guard let list = array(stagedPages[page], "Annots") else {
                        if annotations.isEmpty { continue }
                        throw SnapshotFailure.invalidObject(#line)
                    }
                    for (index, drops) in annotations {
                        var annotation: CGPDFDictionaryRef?
                        guard CGPDFArrayGetDictionary(list, index, &annotation), let annotation else { throw SnapshotFailure.invalidObject(#line) }
                        resolvedCatalogDrops[pdfReferenceIdentity(annotation), default: []].formUnion(drops)
                    }
                }
                let outlineStyles = catalogPlan.outlineStyleEntries
                if !outlineDestinations.isEmpty || !outlineStyles.isEmpty {
                    let expectedPaths = Set(outlineDestinations.keys).union(outlineStyles.keys)
                    guard let outlines = try dictionaryObject(object(catalog, "Outlines")) else { throw SnapshotFailure.invalidObject(#line) }
                    var pending: [(CGPDFDictionaryRef, [Int])] = [(outlines, [])]
                    var visited = Set<UInt>(), applied = Set<[Int]>()
                    while let (parent, path) = pending.popLast() {
                        guard path.count < 64 else { throw SnapshotFailure.limitExceeded }
                        var node = try dictionaryObject(object(parent, "First")), index = 0
                        while let current = node {
                            let identity = pdfReferenceIdentity(current)
                            guard visited.insert(identity).inserted, visited.count <= 100_000 else { throw SnapshotFailure.limitExceeded }
                            let childPath = path + [index]
                            if let destination = outlineDestinations[childPath] {
                                resolvedCatalogOverrides[identity, default: [:]]["Dest"] = destination
                                resolvedCatalogDrops[identity, default: []].insert("A")
                                applied.insert(childPath)
                            }
                            if let entries = outlineStyles[childPath] {
                                guard entries.count <= 2, Set(entries.keys).isSubset(of: ["C", "F"]) else {
                                    throw SnapshotFailure.invalidObject(#line)
                                }
                                resolvedCatalogOverrides[identity, default: [:]].merge(entries) { _, current in current }
                                applied.insert(childPath)
                            }
                            if object(current, "First") != nil { pending.append((current, childPath)) }
                            node = try dictionaryObject(object(current, "Next")); index += 1
                        }
                    }
                    guard applied == expectedPaths else { throw SnapshotFailure.invalidObject(#line) }
                }
            }
            if let metadataSource {
                let donor = metadataSource.owner
                retainedDonors.append(donor)
                retainedDonors.append(metadataSource.metadataOwner)
                guard let originalCatalog = donor.catalog,
                      let originalPages = try dictionaryObject(object(originalCatalog, "Pages")),
                      let stagedPagesRoot = try dictionaryObject(object(catalog, "Pages")) else { throw SnapshotFailure.invalidObject(#line) }
                // Empty forms use the same factory-bound, absent-carrier-only
                // plan above on both native and ordinary serialization paths.
                // This vendor scalar remains qualified by the native source.
                if let itxt = object(originalPages, "ITXT") {
                    resolvedCatalogOverrides[pdfReferenceIdentity(stagedPagesRoot), default: [:]]["ITXT"] = .original(itxt)
                }
                if source.outlineRoot != nil, let stagedOutlines = try dictionaryObject(object(catalog, "Outlines")) {
                    let current = source.outlineRoot?.label
                    resolvedCatalogDrops[pdfReferenceIdentity(stagedOutlines), default: []].insert("Title")
                    let metadataCatalog = metadataSource.metadataOwner.catalog
                    let originalOutlines = try metadataCatalog.flatMap { try dictionaryObject(object($0, "Outlines")) }
                    let originalTitle = originalOutlines.flatMap { object($0, "Title") }
                    var titleWasUnchanged = false
                    if let originalTitle {
                        var originalString: CGPDFStringRef?
                        guard CGPDFObjectGetType(originalTitle) == .string,
                              CGPDFObjectGetValue(originalTitle, .string, &originalString), let originalString,
                              CGPDFStringGetLength(originalString) <= 65_536 else { throw SnapshotFailure.invalidObject(#line) }
                        guard let decoded = CGPDFStringCopyTextString(originalString).map({ $0 as String }) else { throw SnapshotFailure.invalidObject(#line) }
                        titleWasUnchanged = current == decoded
                        if titleWasUnchanged {
                            resolvedCatalogOverrides[pdfReferenceIdentity(stagedOutlines), default: [:]]["Title"] = .original(originalTitle)
                        }
                    } else { titleWasUnchanged = current == metadataSource.baselineOutlineRootLabel }
                    if !titleWasUnchanged, let current {
                        guard current.utf16.count <= 32_768 else { throw SnapshotFailure.limitExceeded }
                        var bytes = Data([0xfe, 0xff])
                        for unit in current.utf16 { bytes.append(UInt8(unit >> 8)); bytes.append(UInt8(unit & 255)) }
                        resolvedCatalogOverrides[pdfReferenceIdentity(stagedOutlines), default: [:]]["Title"] = .string(bytes)
                    }
                }
            }
            // Rebind only the navigation relationships to the exact staged
            // forward tree before any dictionary body is serialized.
            try prepareOutlineRelationships(in: catalog)
            // All page painting preparation is complete. Build one bounded
            // candidate index before traversing pending graph bodies.
            try prepareOriginalNumberIndex()
            var trailer = ["/Root \(try documentDictionaryReference(catalog))"]
            if let info = (metadataSource?.metadataOwner ?? staged).info { trailer.append("/Info \(try documentDictionaryReference(info))") }
            if let ids = (metadataSource?.metadataOwner ?? staged).fileIdentifier {
                guard CGPDFArrayGetCount(ids) == 2 else { throw SnapshotFailure.invalidObject(#line) }
                var values: [String] = []
                for index in 0..<2 {
                    var value: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(ids, index, &value), let value,
                          CGPDFObjectGetType(value) == .string else { throw SnapshotFailure.invalidObject(#line) }
                    values.append(try encode(value, depth: 0))
                }
                trailer.append("/ID [\(values.joined(separator: " "))]")
            }
            let completed = try finish(trailerEntries: trailer)
            if let empty = restoredEmptyOutline {
                guard try PDFCatalogStructurePreserver.originalEmptyOutline(empty, for: source, staged: staged) != nil else {
                    throw SnapshotFailure.invalidObject(#line)
                }
            }
            guard catalogPlan?.linkControlProofs.allSatisfy({ $0.matches() }) ?? true,
                  catalogPlan?.annotationTagPermissions.values.allSatisfy({ $0.matches() }) ?? true else { throw SnapshotFailure.invalidObject(#line) }
            return completed
        }

        /// Keep backward links bound to the one reachable forward outline tree,
        /// including when wrappers resolve to duplicate dictionaries. Serialize
        /// every edge from one bounded, unique walk; never import a second tree through
        /// Parent/Prev/Last. All nonrelationship values keep the existing writer.
        private func prepareOutlineRelationships(in catalog: CGPDFDictionaryRef) throws {
            guard documentGraph else { throw SnapshotFailure.invalidObject(#line) }
            let catalogKey = pdfReferenceIdentity(catalog)
            // A separately proven replacement/removal (including an originally
            // empty outline) retains its own authority and is not reinterpreted.
            guard !(resolvedCatalogDrops[catalogKey]?.contains("Outlines") ?? false),
                  resolvedCatalogOverrides[catalogKey]?["Outlines"] == nil,
                  let root = try dictionaryObject(object(catalog, "Outlines")) else { return }
            guard pdfReferenceIdentity(root) != catalogKey else { throw SnapshotFailure.invalidObject(#line) }
            if let type = object(root, "Type") {
                var name: UnsafePointer<CChar>?
                guard CGPDFObjectGetType(type) == .name,
                      CGPDFObjectGetValue(type, .name, &name), let name,
                      String(cString: name) == "Outlines" else { throw SnapshotFailure.invalidObject(#line) }
            }
            let keys: Set<String> = ["First", "Last", "Next", "Prev", "Parent"]
            var seen: Set<UInt> = [pdfReferenceIdentity(root)]
            var pending: [(CGPDFDictionaryRef, Int)] = [(root, 0)]
            var order: [UInt] = [pdfReferenceIdentity(root)]
            var relationships: [UInt: (CGPDFDictionaryRef, [String: UInt])] = [
                pdfReferenceIdentity(root): (root, [:])
            ]
            while let (parent, depth) = pending.popLast() {
                try PDFSaveCancellation.checkCurrent()
                guard depth < 64 else { throw SnapshotFailure.limitExceeded }
                let parentKey = pdfReferenceIdentity(parent)
                guard catalogPlan?.aliases[parentKey] == nil else { throw SnapshotFailure.invalidObject(#line) }
                var siblings: [CGPDFDictionaryRef] = []
                var next = try dictionaryObject(object(parent, "First"))
                while let child = next {
                    try PDFSaveCancellation.checkCurrent()
                    let childKey = pdfReferenceIdentity(child)
                    // Refuse references into another catalog role. The narrow
                    // outline-item route requires its own bounded Title string.
                    guard childKey != catalogKey,
                          let title = object(child, "Title"), CGPDFObjectGetType(title) == .string else {
                        throw SnapshotFailure.invalidObject(#line)
                    }
                    if let type = dictionaryName(child, "Type"),
                       ["Catalog", "Page", "Pages", "Outlines", "Annot", "Font", "FontDescriptor",
                        "XObject", "StructElem", "StructTreeRoot", "OCG", "OCMD", "Metadata"].contains(type) {
                        throw SnapshotFailure.invalidObject(#line)
                    }
                    // Unrecognized extension Type values are semantic fields,
                    // not authority. The private clone namespace leaves any
                    // unrelated reference to this dictionary untouched.
                    var titleString: CGPDFStringRef?
                    guard CGPDFObjectGetValue(title, .string, &titleString), let titleString,
                          CGPDFStringGetLength(titleString) <= 65_536 else { throw SnapshotFailure.limitExceeded }
                    guard seen.insert(childKey).inserted else { throw SnapshotFailure.invalidObject(#line) }
                    guard seen.count <= 100_000 else { throw SnapshotFailure.limitExceeded }
                    guard catalogPlan?.aliases[childKey] == nil else { throw SnapshotFailure.invalidObject(#line) }
                    order.append(childKey)
                    relationships[childKey] = (child, ["Parent": parentKey])
                    siblings.append(child)
                    if object(child, "First") != nil { pending.append((child, depth + 1)) }
                    next = try dictionaryObject(object(child, "Next"))
                }
                if let first = siblings.first, let last = siblings.last {
                    relationships[parentKey]!.1["First"] = pdfReferenceIdentity(first)
                    relationships[parentKey]!.1["Last"] = pdfReferenceIdentity(last)
                }
                for index in siblings.indices {
                    let key = pdfReferenceIdentity(siblings[index])
                    if index > 0 { relationships[key]!.1["Prev"] = pdfReferenceIdentity(siblings[index - 1]) }
                    if index + 1 < siblings.count { relationships[key]!.1["Next"] = pdfReferenceIdentity(siblings[index + 1]) }
                }
            }
            // Reserve a private object-ID namespace after validating the whole
            // tree. An unrelated catalog/resource alias keeps its original
            // dictionary, including every original relationship. Numeric edges
            // introduce no cyclic Swift object ownership.
            for key in order {
                guard Set((resolvedCatalogOverrides[key] ?? [:]).keys).isDisjoint(with: keys),
                      (resolvedCatalogDrops[key] ?? []).isDisjoint(with: keys) else {
                    throw SnapshotFailure.invalidObject(#line)
                }
            }
            guard order.count <= maximumObjects - bodies.count else { throw SnapshotFailure.limitExceeded }
            var ids: [UInt: Int] = [:]
            for key in order {
                try PDFSaveCancellation.checkCurrent()
                ids[key] = bodies.count + 1
                bodies.append(nil)
            }
            for key in order {
                try PDFSaveCancellation.checkCurrent()
                guard let entry = relationships[key], let id = ids[key] else { throw SnapshotFailure.invalidObject(#line) }
                var edges: [String: Int] = [:]
                for (name, target) in entry.1 {
                    guard let targetID = ids[target] else { throw SnapshotFailure.invalidObject(#line) }
                    edges[name] = targetID
                }
                pendingBodies.append((id, .outline(entry.0, edges: edges)))
            }
            outlineRootID = ids[pdfReferenceIdentity(root)]
        }

        private func documentDictionaryReference(_ dictionary: CGPDFDictionaryRef) throws -> String {
            let key = pdfReferenceIdentity(dictionary)
            if let id = dictionaryIdentifiers[key] { return "\(id) 0 R" }
            guard bodies.count < maximumObjects else { throw SnapshotFailure.limitExceeded }
            let id = bodies.count + 1
            dictionaryIdentifiers[key] = id
            bodies.append(nil)
            pendingBodies.append((id, .dictionary(dictionary)))
            return "\(id) 0 R"
        }

        /// PDFKit may translate a nonzero MediaBox origin when saving. Only a
        /// common translation of every current page box is safe to apply to
        /// the original content; other geometry changes cannot be guessed.
        private func contentTranslation(from livePage: PDFPage, to savedPage: CGPDFPage,
                                        liveDictionary: CGPDFDictionaryRef,
                                        savedDictionary: CGPDFDictionaryRef) throws -> CGPoint {
            let normalizedRotation: (Int) -> Int = { (($0 % 360) + 360) % 360 }
            guard livePage.rotation % 90 == 0,
                  normalizedRotation(livePage.rotation) == normalizedRotation(Int(savedPage.rotationAngle)),
                  try userUnit(in: liveDictionary) == userUnit(in: savedDictionary) else {
                throw SnapshotFailure.invalidObject(#line)
            }
            let tolerance: CGFloat = 0.00001
            var translation: CGPoint?
            for (liveBox, savedBox) in [(PDFDisplayBox.mediaBox, CGPDFBox.mediaBox), (.cropBox, .cropBox),
                                        (.bleedBox, .bleedBox), (.trimBox, .trimBox), (.artBox, .artBox)] {
                let live = livePage.bounds(for: liveBox), saved = savedPage.getBoxRect(savedBox)
                guard valid(live), valid(saved), abs(live.width - saved.width) <= tolerance,
                      abs(live.height - saved.height) <= tolerance else { throw SnapshotFailure.invalidObject(#line) }
                let shift = CGPoint(x: saved.minX - live.minX, y: saved.minY - live.minY)
                if let translation {
                    guard abs(translation.x - shift.x) <= tolerance,
                          abs(translation.y - shift.y) <= tolerance else { throw SnapshotFailure.invalidObject(#line) }
                } else { translation = shift }
            }
            guard let translation else { throw SnapshotFailure.invalidObject(#line) }
            return CGPoint(x: abs(translation.x) <= tolerance ? 0 : translation.x,
                           y: abs(translation.y) <= tolerance ? 0 : translation.y)
        }

        private func userUnit(in dictionary: CGPDFDictionaryRef) throws -> CGPDFReal {
            guard object(dictionary, "UserUnit") != nil else { return 1 }
            var value: CGPDFReal = 0
            guard CGPDFDictionaryGetNumber(dictionary, "UserUnit", &value), value.isFinite, value > 0 else {
                throw SnapshotFailure.invalidObject(#line)
            }
            return value
        }

        func write(reference: CGPDFPage, source: PDFPage, contentOverride: Data? = nil,
                   donorPDF: Data? = nil, donorName: String? = nil,
                   droppingXObjectNames: Set<String> = [], preservePageContent: Bool = false,
                   fontOverrides: [String: CGPDFObjectRef] = [:], outlinedOCRMetadata: Data? = nil,
                   donorOCRFontName: String? = nil, donorLayoutBounds: CGRect? = nil,
                   donorScannedErasureMetadata: Data? = nil) throws -> Data {
            guard let dictionary = reference.dictionary else { throw SnapshotFailure.invalidObject(#line) }
            guard donorScannedErasureMetadata == nil || (donorPDF != nil && donorName != nil) else {
                throw SnapshotFailure.invalidObject(#line)
            }
            var pageEntries = ["/Type /Page", "/Parent 2 0 R"]
            // Apply compares canonical one-page snapshots repeatedly. Keep
            // their geometry independent of optional raw-source availability
            // or lock/cache state, just like the established stream encoding.
            // The final document graph writer restores trusted source decimals.
            let geometry = try PDFPageGeometryPreserver.capture(source, reference: reference)
                .resolved(for: source)
            for key in PDFPageGeometryPreserver.boxes.map(\.0) + ["Rotate"] {
                if let value = geometry[key] { pageEntries.append("/\(key) \(try encodeCatalogValue(value, depth: 0))") }
            }
            try prepareRawSources(for: source, reference: reference)
            if carriesUnmodifiedType3Resources { try prepareOriginalNumberIndex() }
            if donorPDF != nil || donorName != nil || !droppingXObjectNames.isEmpty || !fontOverrides.isEmpty {
                let resources = try dictionaryObject(inheritedObject(dictionary, "Resources"))
                let xobjects = try dictionaryObject(resources.flatMap { object($0, "XObject") })
                // Callers remove only a validated, uniquely invoked text Form.
                // Never prune arbitrary original page resources by name.
                guard droppingXObjectNames.allSatisfy({ isBodyTextXObject(named: $0, in: dictionary) }) else {
                    throw SnapshotFailure.invalidObject(#line)
                }
                var entries: [String] = []
                if let donorPDF, let donorName {
                    guard !donorName.isEmpty, donorName.utf8.count <= 128,
                          xobjects.flatMap({ object($0, donorName) }) == nil else { throw SnapshotFailure.invalidObject(#line) }
                    let font = donorOCRFontName.flatMap { scannedOCRFont(named: $0, in: dictionary)?.object }
                    guard donorOCRFontName == nil || font != nil else { throw SnapshotFailure.invalidObject(#line) }
                    let donor = try donorForm(donorPDF, ocrFont: font, layoutBounds: donorLayoutBounds,
                        scannedErasureMetadata: donorScannedErasureMetadata)
                    entries.append(try donorName.withCString { try name($0) } + " \(donor) 0 R")
                } else if donorPDF != nil || donorName != nil { throw SnapshotFailure.invalidObject(#line) }
                let xobjectBody = try xobjects.map {
                    try encodeDictionary($0, depth: 0, dropping: droppingXObjectNames, additions: entries)
                } ?? Data(("<< " + entries.joined(separator: " ") + " >>").utf8)
                let xobjectID = try addBody(xobjectBody)
                var resourceEntries = ["/XObject \(xobjectID) 0 R"]
                var resourceDrops: Set<String> = ["XObject"]
                if !fontOverrides.isEmpty {
                    guard fontOverrides.count == 1 else { throw SnapshotFailure.invalidObject(#line) }
                    let fonts = try dictionaryObject(resources.flatMap { object($0, "Font") })
                    var additions: [String] = []
                    for (key, value) in fontOverrides {
                        guard key == "EmberOCRSource", fonts.flatMap({ object($0, key) }) == nil else {
                            throw SnapshotFailure.invalidObject(#line)
                        }
                        additions.append("/\(key) \(try encode(value, depth: 0))")
                    }
                    let body = try fonts.map { try encodeDictionary($0, depth: 0, additions: additions) }
                        ?? Data(("<< " + additions.joined(separator: " ") + " >>").utf8)
                    resourceEntries.append("/Font \(try addBody(body)) 0 R")
                    resourceDrops.insert("Font")
                }
                let resourceBody = try resources.map {
                    try encodeDictionary($0, depth: 0, dropping: resourceDrops, additions: resourceEntries)
                } ?? Data(("<< " + resourceEntries.joined(separator: " ") + " >>").utf8)
                pageEntries.append("/Resources \(try addBody(resourceBody)) 0 R")
            } else if let resources = inheritedObject(dictionary, "Resources") {
                pageEntries.append("/Resources \(try encode(resources, depth: 0))")
            } else {
                pageEntries.append("/Resources << >>")
            }
            if let contentOverride {
                var body = Data("<< /Length \(contentOverride.count) >>\nstream\n".utf8)
                try append(contentOverride, to: &body)
                try append(Data("\nendstream".utf8), to: &body)
                let contentObjectID = try addBody(body)
                singlePageContentObjectID = contentObjectID
                pageEntries.append("/Contents \(contentObjectID) 0 R")
            } else if let contents = object(dictionary, "Contents") {
                pageEntries.append("/Contents \(try encode(contents, depth: 0))")
            }
            // These properties affect page rendering or describe the page.
            // Parent/Annots/AA/StructParents are deliberately not followed:
            // they can lead into the entire document or executable actions.
            for key in ["Group", "UserUnit", "Metadata", "LastModified", "EmberPDFPreservePageContent", "EmberPDFOutlinedOCR"] {
                if key == "EmberPDFPreservePageContent", preservePageContent { continue }
                if key == "EmberPDFOutlinedOCR", outlinedOCRMetadata != nil { continue }
                if let value = object(dictionary, key) {
                    pageEntries.append("/\(key) \(try encode(value, depth: 0))")
                }
            }
            if preservePageContent { pageEntries.append("/EmberPDFPreservePageContent true") }
            if let outlinedOCRMetadata {
                guard !outlinedOCRMetadata.isEmpty, outlinedOCRMetadata.count <= 1_024 * 1_024 else {
                    throw SnapshotFailure.invalidObject(#line)
                }
                pageEntries.append("/EmberPDFOutlinedOCR <\(hex(outlinedOCRMetadata))>")
            }
            try setBody(1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
            try setBody(2, Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
            try setBody(3, Data(("<< " + pageEntries.joined(separator: " ") + " >>").utf8))
            let data = try finish(trailerEntries: ["/Root 1 0 R"])
            if captureBodyCopy, !bodyCopyUnsafe, !documentGraph,
               fontOverrides.isEmpty, outlinedOCRMetadata == nil, donorOCRFontName == nil,
               data.count <= 16 * 1_024 * 1_024,
               contentOverride.map({ $0.count <= 2 * 1_024 * 1_024 }) ?? true,
               donorName == nil || bodyDonorProgram != nil {
                bodyCopyWitness = PDFBodyResourceCopyWitness(source: reference,
                    resources: inheritedObject(dictionary, "Resources"), output: data,
                    contentSHA256: contentOverride.map { Data(SHA256.hash(data: $0)) } ?? Data(),
                    donorName: donorName, donorProgram: bodyDonorProgram, droppedForms: droppingXObjectNames)
            }
            return data
        }

        private func finish(trailerEntries: [String]) throws -> Data {
            // A document's outline siblings, page tree, and annotation links
            // are a graph, not resource nesting. Reserve references before
            // visiting their bodies so a long /Next chain never recurses.
            var cursor = 0
            while cursor < pendingBodies.count {
                let (id, pending) = pendingBodies[cursor]
                cursor += 1
                let body: Data
                switch pending {
                case .object(let object): body = try encodeObjectBody(object, depth: 0)
                case .dictionary(let dictionary): body = try encodeDictionary(dictionary, depth: 0)
                case .outline(let dictionary, let edges):
                    let additions = edges.keys.sorted().map { "/\($0) \(edges[$0]!) 0 R" }
                    body = try encodeDictionary(dictionary, depth: 0,
                        dropping: ["First", "Last", "Next", "Prev", "Parent"], additions: additions)
                case .custom(let node): body = try encodeCustomNode(node)
                case .sparseArray(let count, let members, let depth, let aliases):
                    body = try encodeSparseArrayBody(count: count, members: members, depth: depth, aliases: aliases)
                }
                try setBody(id, body)
            }
            guard appliedPageOverrides.count == pageOverrides.count else { throw SnapshotFailure.invalidObject(#line) }
            var result = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
            var offsets = [0]
            for (index, body) in bodies.enumerated() {
                guard let body else { throw SnapshotFailure.invalidObject(#line) }
                offsets.append(result.count)
                try append(Data("\(index + 1) 0 obj\n".utf8), to: &result)
                try append(body, to: &result)
                try append(Data("\nendobj\n".utf8), to: &result)
            }
            let xref = result.count
            try append(Data("xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n".utf8), to: &result)
            for offset in offsets.dropFirst() {
                try append(Data(String(format: "%010d 00000 n \n", offset).utf8), to: &result)
            }
            try append(Data(("trailer\n<< /Size \(bodies.count + 1) \(trailerEntries.joined(separator: " ")) >>"
                + "\nstartxref\n\(xref)\n%%EOF\n").utf8), to: &result)
            return result
        }

        func contentData(reference: CGPDFPage) throws -> Data {
            guard let dictionary = reference.dictionary else { throw SnapshotFailure.invalidObject(#line) }
            guard let contents = object(dictionary, "Contents") else { return Data() }
            var streams: [CGPDFStreamRef] = []
            if CGPDFObjectGetType(contents) == .stream {
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(contents, .stream, &stream), let stream else { throw SnapshotFailure.invalidObject(#line) }
                streams.append(stream)
            } else if CGPDFObjectGetType(contents) == .array {
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(contents, .array, &array), let array,
                      CGPDFArrayGetCount(array) < 25_000 else { throw SnapshotFailure.invalidObject(#line) }
                for index in 0..<CGPDFArrayGetCount(array) {
                    var stream: CGPDFStreamRef?
                    guard CGPDFArrayGetStream(array, index, &stream), let stream else { throw SnapshotFailure.invalidObject(#line) }
                    streams.append(stream)
                }
            } else { throw SnapshotFailure.invalidObject(#line) }
            var result = Data()
            for (index, stream) in streams.enumerated() {
                guard let dictionary = CGPDFStreamGetDictionary(stream), object(dictionary, "F") == nil else {
                    throw SnapshotFailure.invalidObject(#line)
                }
                var format = CGPDFDataFormat.raw
                guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else { throw SnapshotFailure.invalidObject(#line) }
                // A content-array boundary separates tokens, but does not end
                // an open comment. LF would expose the next stream's first
                // line in readers that treat the array as one content stream.
                if index > 0 { try append(Data([32]), to: &result) }
                try append(data as Data, to: &result)
            }
            return result
        }

        func unusedXObjectName(in pageDictionary: CGPDFDictionaryRef) throws -> String {
            let resources = try dictionaryObject(inheritedObject(pageDictionary, "Resources"))
            let xobjects = try dictionaryObject(resources.flatMap { object($0, "XObject") })
            return try unusedName(prefix: "EmberBodyText", in: xobjects)
        }

        func isBodyTextXObject(named name: String, in pageDictionary: CGPDFDictionaryRef) -> Bool {
            guard let resources = try? dictionaryObject(inheritedObject(pageDictionary, "Resources")),
                  let xobjects = try? dictionaryObject(object(resources, "XObject")),
                  let value = object(xobjects, name) else { return false }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream),
                  dictionaryName(dictionary, "Subtype") == "Form" else { return false }
            var marker: CGPDFBoolean = 0
            return CGPDFDictionaryGetBoolean(dictionary, "EmberPDFBodyText", &marker) && marker != 0
        }

        func bodyTextLayoutBounds(named name: String, in pageDictionary: CGPDFDictionaryRef) throws -> CGRect? {
            guard isBodyTextXObject(named: name, in: pageDictionary),
                  let resources = try dictionaryObject(inheritedObject(pageDictionary, "Resources")),
                  let xobjects = try dictionaryObject(object(resources, "XObject")),
                  let value = object(xobjects, name) else { return nil }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { throw SnapshotFailure.invalidObject(#line) }
            guard object(dictionary, "EmberPDFBodyTextBounds") != nil else { return nil }
            guard let values = array(dictionary, "EmberPDFBodyTextBounds"), CGPDFArrayGetCount(values) == 4 else {
                throw SnapshotFailure.invalidObject(#line)
            }
            var numbers = [CGFloat]()
            for index in 0..<4 {
                var number: CGPDFReal = 0
                guard CGPDFArrayGetNumber(values, index, &number), number.isFinite else { throw SnapshotFailure.invalidObject(#line) }
                numbers.append(number)
            }
            let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
            guard valid(rect) else { throw SnapshotFailure.invalidObject(#line) }; return rect
        }

        func scannedOCRFont(named name: String, in pageDictionary: CGPDFDictionaryRef) -> (object: CGPDFObjectRef, defaultWidth: CGFloat)? {
            guard let resources = try? dictionaryObject(inheritedObject(pageDictionary, "Resources")),
                  let fonts = try? dictionaryObject(object(resources, "Font")),
                  let value = object(fonts, name), let font = try? dictionaryObject(value),
                  dictionaryName(font, "Subtype") == "Type0", dictionaryName(font, "Encoding") == "Identity-H",
                  let descendants = array(font, "DescendantFonts"), CGPDFArrayGetCount(descendants) == 1 else { return nil }
            var descendant: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant,
                  object(descendant, "W") == nil else { return nil }
            var width: CGPDFReal = 1_000
            if object(descendant, "DW") != nil {
                guard CGPDFDictionaryGetNumber(descendant, "DW", &width) else { return nil }
            }
            guard width.isFinite, width > 0, width <= 10_000 else { return nil }
            return (value, width)
        }

        func outlinedOCRMetadata(named name: String, in pageDictionary: CGPDFDictionaryRef) -> Data? {
            guard isBodyTextXObject(named: name, in: pageDictionary),
                  let resources = try? dictionaryObject(inheritedObject(pageDictionary, "Resources")),
                  let xobjects = try? dictionaryObject(object(resources, "XObject")),
                  let value = object(xobjects, name) else { return nil }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
            return boundedOutlinedOCRMetadata(in: dictionary)
        }

        func scannedErasureMetadata(named name: String, in pageDictionary: CGPDFDictionaryRef) -> Data? {
            guard isBodyTextXObject(named: name, in: pageDictionary),
                  let resources = try? dictionaryObject(inheritedObject(pageDictionary, "Resources")),
                  let xobjects = try? dictionaryObject(object(resources, "XObject")),
                  let value = object(xobjects, name) else { return nil }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
            var string: CGPDFStringRef?
            guard CGPDFDictionaryGetString(dictionary, "EmberPDFScannedErasure", &string), let string else { return nil }
            let count = CGPDFStringGetLength(string)
            guard count > 0, count <= 16 * 1_024, let bytes = CGPDFStringGetBytePtr(string) else { return nil }
            return Data(bytes: bytes, count: count)
        }

        private func boundedOutlinedOCRMetadata(in dictionary: CGPDFDictionaryRef) -> Data? {
            var string: CGPDFStringRef?
            guard CGPDFDictionaryGetString(dictionary, "EmberPDFOutlinedOCR", &string), let string else { return nil }
            let count = CGPDFStringGetLength(string)
            guard count > 0, count <= 1_024 * 1_024, let bytes = CGPDFStringGetBytePtr(string) else { return nil }
            return Data(bytes: bytes, count: count)
        }

        private func unusedName(prefix: String, in dictionary: CGPDFDictionaryRef?) throws -> String {
            for index in 1...maximumObjects {
                let name = "\(prefix)\(index)"
                if dictionary.flatMap({ object($0, name) }) == nil { return name }
            }
            throw SnapshotFailure.limitExceeded
        }

        private func donorForm(_ data: Data, ocrFont: CGPDFObjectRef?, layoutBounds: CGRect?,
                               scannedErasureMetadata: Data? = nil) throws -> Int {
            guard data.count <= maximumBytes,
                  let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider), document.numberOfPages == 1,
                  let page = document.page(at: 1), let dictionary = page.dictionary else { throw SnapshotFailure.invalidObject(#line) }
            retainedDonors.append(document)
            let outlinedMarker = boundedOutlinedOCRMetadata(in: dictionary)
            guard outlinedMarker == nil || ocrFont != nil else { throw SnapshotFailure.invalidObject(#line) }
            let resources = try dictionaryObject(inheritedObject(dictionary, "Resources"))
            let originalDonorContent = try contentData(reference: page)
            let normalizedText = ocrFont == nil
                ? normalizedDonorText(originalDonorContent, resources: resources) : nil
            let states = try dictionaryObject(resources.flatMap { object($0, "ExtGState") })
            let resetName = try unusedName(prefix: "EmberBodyReset", in: states)
            let resetID = try addBody(Data(("<< /Type /ExtGState /ca 1 /CA 1 /BM /Normal /SMask /None"
                + " /AIS false /op false /OP false /OPM 0 /TK true /SA false >>").utf8))
            let resetEntry = "/\(resetName) \(resetID) 0 R"
            let stateBody = try states.map { try encodeDictionary($0, depth: 0, additions: [resetEntry]) }
                ?? Data(("<< " + resetEntry + " >>").utf8)
            let stateID = try addBody(stateBody)
            var resourceEntries = ["/ExtGState \(stateID) 0 R"]
            var resourceDrops: Set<String> = ["ExtGState"]
            if let ocrFont {
                guard outlinedMarker != nil else { throw SnapshotFailure.invalidObject(#line) }
                let fonts = try dictionaryObject(resources.flatMap { object($0, "Font") })
                guard fonts.flatMap({ object($0, "EmberOCRSource") }) != nil else { throw SnapshotFailure.invalidObject(#line) }
                // Borrow the exact original object, retaining its resource
                // identity instead of adding an equal font dictionary copy.
                let entry = "/EmberOCRSource \(try encode(ocrFont, depth: 0))"
                let body = try encodeDictionary(fonts!, depth: 0, dropping: ["EmberOCRSource"], additions: [entry])
                resourceEntries.append("/Font \(try addBody(body)) 0 R")
                resourceDrops.insert("Font")
            } else if let normalizedText, !normalizedText.fontCMaps.isEmpty {
                guard let fonts = try dictionaryObject(resources.flatMap { object($0, "Font") }) else {
                    throw SnapshotFailure.invalidObject(#line)
                }
                var entries: [String] = []
                for (fontName, cmap) in normalizedText.fontCMaps.sorted(by: { $0.key < $1.key }) {
                    guard let font = try dictionaryObject(object(fonts, fontName)) else {
                        throw SnapshotFailure.invalidObject(#line)
                    }
                    var stream = Data("<< /Length \(cmap.count) >>\nstream\n".utf8)
                    try append(cmap, to: &stream)
                    try append(Data("\nendstream".utf8), to: &stream)
                    let cmapID = try addBody(stream)
                    let body = try encodeDictionary(font, depth: 0, dropping: ["ToUnicode"],
                        additions: ["/ToUnicode \(cmapID) 0 R"])
                    entries.append(try fontName.withCString { try name($0) } + " \(try addBody(body)) 0 R")
                }
                let body = try encodeDictionary(fonts, depth: 0,
                    dropping: Set(normalizedText.fontCMaps.keys), additions: entries)
                resourceEntries.append("/Font \(try addBody(body)) 0 R")
                resourceDrops.insert("Font")
            }
            let resourceBody = try resources.map {
                try encodeDictionary($0, depth: 0, dropping: resourceDrops, additions: resourceEntries)
            } ?? Data(("<< " + resourceEntries.joined(separator: " ") + " >>").utf8)
            let resourcesID = try addBody(resourceBody)
            var content = Data(("q /\(resetName) gs 0 g 0 G 1 w 0 J 0 j 10 M [] 0 d "
                + "BT 0 Tc 0 Tw 100 Tz 0 TL 0 Tr 0 Ts ET\n").utf8)
            try append(normalizedText?.content ?? originalDonorContent, to: &content)
            try append(Data("\nQ".utf8), to: &content)
            if captureBodyCopy {
                if content.count <= 1_024 * 1_024 { bodyDonorProgram = content.withUnsafeBytes { Data($0) } }
                else { bodyCopyUnsafe = true }
            }
            let bounds = page.getBoxRect(.mediaBox)
            guard valid(bounds) else { throw SnapshotFailure.invalidObject(#line) }
            let marker = outlinedMarker.map { " /EmberPDFOutlinedOCR <\(hex($0))>" } ?? ""
            let scannedMarker: String
            if let scannedErasureMetadata {
                guard ocrFont == nil, outlinedMarker == nil,
                      !scannedErasureMetadata.isEmpty, scannedErasureMetadata.count <= 16 * 1_024 else {
                    throw SnapshotFailure.invalidObject(#line)
                }
                scannedMarker = " /EmberPDFScannedErasure <\(hex(scannedErasureMetadata))>"
            } else { scannedMarker = "" }
            let layoutMarker: String
            if let layoutBounds {
                guard ocrFont == nil, valid(layoutBounds), bounds.contains(layoutBounds) else { throw SnapshotFailure.invalidObject(#line) }
                layoutMarker = " /EmberPDFBodyTextBounds \(try rectangle(layoutBounds))"
            } else { layoutMarker = "" }
            var result = Data(("<< /Type /XObject /Subtype /Form /FormType 1 /EmberPDFBodyText true\(marker)\(layoutMarker)\(scannedMarker) /BBox \(try rectangle(bounds))"
                + " /Resources \(resourcesID) 0 R /Length \(content.count) >>\nstream\n").utf8)
            try append(content, to: &result)
            try append(Data("\nendstream".utf8), to: &result)
            return try addBody(result)
        }

        /// Only the fresh donor's private, simple fonts are eligible. An alias
        /// sharing a dictionary is left alone, so uncounted uses cannot inherit
        /// a semantic change. Original page resources never enter this helper.
        private func normalizedDonorText(_ content: Data, resources: CGPDFDictionaryRef?)
            -> PDFGeneratedDonorTextNormalizer.Output? {
            // Optional negative shortcut: ordinary Latin donors require no
            // extra CMap decoding or per-character usage inventory.
            guard content.range(of: Data("/ActualText".utf8)) != nil,
                  let resources, let fonts = try? dictionaryObject(object(resources, "Font")),
                  CGPDFDictionaryGetCount(fonts) <= 256 else { return nil }
            var maps: [String: Data] = [:], names: [UInt: [String]] = [:]
            var mapBytes = 0, mapBudgetExceeded = false
            CGPDFDictionaryApplyBlock(fonts, { key, value, _ in
                guard strnlen(key, 4096) < 4096,
                      let font = try? self.dictionaryObject(value),
                      ["Type1", "TrueType"].contains(self.dictionaryName(font, "Subtype") ?? "") else { return true }
                let name = String(cString: key)
                names[pdfReferenceIdentity(font), default: []].append(name)
                var stream: CGPDFStreamRef?
                guard CGPDFDictionaryGetStream(font, "ToUnicode", &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream),
                      self.object(dictionary, "UseCMap") == nil else { return true }
                var format = CGPDFDataFormat.raw
                guard let bytes = CGPDFStreamCopyData(stream, &format), format == .raw,
                      CFDataGetLength(bytes) <= 1_024 * 1_024 else { return true }
                guard CFDataGetLength(bytes) <= PDFGeneratedDonorTextNormalizer.maximumCombinedCMapBytes - mapBytes else {
                    mapBudgetExceeded = true; return false
                }
                mapBytes += CFDataGetLength(bytes)
                maps[name] = bytes as Data
                return true
            }, nil)
            guard !mapBudgetExceeded else { return nil }
            for aliases in names.values where aliases.count > 1 {
                for alias in aliases { maps.removeValue(forKey: alias) }
            }
            var nonFontStates = Set<String>()
            if let states = try? dictionaryObject(object(resources, "ExtGState")),
               CGPDFDictionaryGetCount(states) <= 256 {
                CGPDFDictionaryApplyBlock(states, { key, value, _ in
                    guard strnlen(key, 4096) < 4096,
                          let state = try? self.dictionaryObject(value),
                          self.object(state, "Font") == nil else { return true }
                    nonFontStates.insert(String(cString: key))
                    return true
                }, nil)
            }
            return PDFGeneratedDonorTextNormalizer.normalize(content: content, fontCMaps: maps,
                nonFontGraphicsStates: nonFontStates)
        }

        private func dictionaryObject(_ object: CGPDFObjectRef?) throws -> CGPDFDictionaryRef? {
            guard let object else { return nil }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else {
                throw SnapshotFailure.invalidObject(#line)
            }
            return dictionary
        }

        private func encode(_ object: CGPDFObjectRef, depth: Int) throws -> String {
            visits += 1
            guard depth < 64, visits < maximumVisits else { throw SnapshotFailure.limitExceeded }
            let type = CGPDFObjectGetType(object)
            switch type {
            case .null:
                return "null"
            case .boolean:
                var value: CGPDFBoolean = 0
                guard CGPDFObjectGetValue(object, type, &value) else { throw SnapshotFailure.invalidObject(#line) }
                return value == 0 ? "false" : "true"
            case .integer:
                var value: CGPDFInteger = 0
                guard CGPDFObjectGetValue(object, type, &value) else { throw SnapshotFailure.invalidObject(#line) }
                return String(value)
            case .real:
                var value: CGPDFReal = 0
                guard CGPDFObjectGetValue(object, type, &value), value.isFinite else {
                    throw SnapshotFailure.invalidObject(#line)
                }
                return try number(value)
            case .name:
                var value: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(object, type, &value), let value else { throw SnapshotFailure.invalidObject(#line) }
                return try name(value)
            case .string:
                var value: CGPDFStringRef?
                guard CGPDFObjectGetValue(object, type, &value), let value else { throw SnapshotFailure.invalidObject(#line) }
                let length = CGPDFStringGetLength(value)
                guard length <= 1_024 * 1_024 else { throw SnapshotFailure.limitExceeded }
                guard length > 0 else { return "<>" }
                guard let bytes = CGPDFStringGetBytePtr(value) else { throw SnapshotFailure.invalidObject(#line) }
                try reserveInlineBytes(length * 2 + 2)
                return "<" + hex(UnsafeBufferPointer(start: bytes, count: length)) + ">"
            case .array, .dictionary, .stream:
                let key = pdfReferenceIdentity(object)
                if let id = identifiers[key] { return "\(id) 0 R" }
                var resolvedStream: CGPDFStreamRef?
                if documentGraph || encodedAssemblySource != nil, type == .stream {
                    guard CGPDFObjectGetValue(object, .stream, &resolvedStream), let resolvedStream else { throw SnapshotFailure.invalidObject(#line) }
                    if let id = streamIdentifiers[pdfReferenceIdentity(resolvedStream)] {
                        identifiers[key] = id
                        return "\(id) 0 R"
                    }
                }
                var resolvedDictionary: CGPDFDictionaryRef?
                if documentGraph, type == .dictionary {
                    guard CGPDFObjectGetValue(object, .dictionary, &resolvedDictionary),
                          let resolvedDictionary else { throw SnapshotFailure.invalidObject(#line) }
                    let dictionaryKey = pdfReferenceIdentity(resolvedDictionary)
                    if let alias = catalogPlan?.aliases[dictionaryKey] {
                        guard activeAliases.insert(dictionaryKey).inserted else { throw SnapshotFailure.invalidObject(#line) }
                        defer { activeAliases.remove(dictionaryKey) }
                        return try encodeCatalogValue(alias, depth: depth + 1)
                    }
                    if catalogPlan != nil, dictionaryName(resolvedDictionary, "Type") == "Page",
                       !stagedPages.contains(where: { $0 == resolvedDictionary }) { return "null" }
                    if catalogPlan != nil, dictionaryName(resolvedDictionary, "Type") == "Pages",
                       !stagedPageTreeDictionaries.contains(dictionaryKey) {
                        // Only the staged page tree may own pages. A foreign
                        // parent pointer must not silently import an entire book.
                        return "null"
                    }
                    if let id = dictionaryIdentifiers[pdfReferenceIdentity(resolvedDictionary)] {
                        identifiers[key] = id
                        return "\(id) 0 R"
                    }
                }
                guard bodies.count < maximumObjects else { throw SnapshotFailure.limitExceeded }
                let id = bodies.count + 1
                identifiers[key] = id
                if let resolvedStream { streamIdentifiers[pdfReferenceIdentity(resolvedStream)] = id }
                if let resolvedDictionary {
                    dictionaryIdentifiers[pdfReferenceIdentity(resolvedDictionary)] = id
                }
                bodies.append(nil) // Reserve first so shared/cyclic resources are not duplicated.
                if documentGraph {
                    pendingBodies.append((id, .object(object)))
                } else {
                    try setBody(id, encodeObjectBody(object, depth: depth + 1))
                }
                return "\(id) 0 R"
            @unknown default:
                throw SnapshotFailure.invalidObject(#line)
            }
        }

        private func encodeObjectBody(_ object: CGPDFObjectRef, depth: Int) throws -> Data {
            switch CGPDFObjectGetType(object) {
            case .array:
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &array), let array else { throw SnapshotFailure.invalidObject(#line) }
                let count = CGPDFArrayGetCount(array)
                guard count < 25_000 else { throw SnapshotFailure.limitExceeded }
                var values: [String] = []
                for index in 0..<count {
                    var child: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(array, index, &child), let child else { throw SnapshotFailure.invalidObject(#line) }
                    if CGPDFObjectGetType(child) == .real,
                       let original = try originalNumber(in: array, index: index, depth: depth) {
                        values.append(original)
                    } else { values.append(try encode(child, depth: depth)) }
                }
                return Data(("[" + values.joined(separator: " ") + "]").utf8)
            case .dictionary:
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { throw SnapshotFailure.invalidObject(#line) }
                return try encodeDictionary(dictionary, depth: depth)
            case .stream:
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { throw SnapshotFailure.invalidObject(#line) }
                return try encodeStream(stream, depth: depth)
            default:
                throw SnapshotFailure.invalidObject(#line)
            }
        }

        private func encodeStream(_ stream: CGPDFStreamRef, depth: Int) throws -> Data {
            guard let dictionary = CGPDFStreamGetDictionary(stream),
                  object(dictionary, "F") == nil else { throw SnapshotFailure.invalidObject(#line) }
            // Only a stream bound to the exact opened/constructed bytes may
            // bypass CG's decoder. Keep its original complete filter chain,
            // DecodeParms, masks and color resources; the existing graph
            // writer still owns every reference and catalog override.
            for source in rawStreamSources {
                if let bytes = try source.payload(for: stream) {
                    guard bytes.count <= maximumBytes - storedBytes else { throw SnapshotFailure.limitExceeded }
                    var result = try encodeDictionary(dictionary, depth: depth,
                        dropping: ["Length", "F", "FFilter", "FDecodeParms"],
                        additions: ["/Length \(bytes.count)"])
                    try append(Data("\nstream\n".utf8), to: &result)
                    try append(bytes, to: &result)
                    try append(Data("\nendstream".utf8), to: &result)
                    onResourceStreamEncoded?()
                    return result
                }
            }
            guard encodedAssemblySource == nil else { throw SnapshotFailure.invalidObject(#line) }
            var format = CGPDFDataFormat.raw
            let copied: CFData
            if compactAssembly, let content = compactContents[pdfReferenceIdentity(stream)] {
                copied = content as CFData
            } else {
                if compactAssembly {
                    // Optional preparation must not newly expand arbitrary
                    // Flate/JBIG2/font resources. Without exact raw ownership,
                    // accept only bounded unfiltered or JPEG payload copies.
                    var length: CGPDFInteger = 0
                    guard CGPDFDictionaryGetInteger(dictionary, "Length", &length), length >= 0,
                          length <= maximumBytes - storedBytes,
                          object(dictionary, "Filter") == nil ||
                            ["DCTDecode", "DCT", "JPXDecode"].contains(dictionaryName(dictionary, "Filter") ?? "")
                    else { throw SnapshotFailure.invalidObject(#line) }
                }
                // CG owns decoding and allocates before returning a size.
                // Retained resources and serialized output are bounded below.
                guard let data = CGPDFStreamCopyData(stream, &format) else { throw SnapshotFailure.invalidObject(#line) }
                copied = data
            }
            var bytes = copied as Data
            guard bytes.count <= maximumBytes - storedBytes else { throw SnapshotFailure.limitExceeded }
            var additions: [String] = []
            switch format {
            case .raw:
                // Flate/LZW/ASCII/predictor filters have already been decoded.
                // In particular, a small JBIG2 scan mask can expand to megabytes.
                // Recompress decoded bytes losslessly rather than retaining that
                // expansion on every page. No original DecodeParms apply now.
                let decoded = bytes
                if let compressed = flated(decoded) {
                    bytes = compressed
                    additions.append("/Filter /FlateDecode")
                }
                if let monochrome = group4Image(decoded, dictionary: dictionary),
                   monochrome.data.count + 128 < bytes.count {
                    // The margin also covers the additional fax parameters;
                    // choose this optional native codec only over a smaller PDF.
                    bytes = monochrome.data
                    additions = ["/Filter /CCITTFaxDecode",
                        "/DecodeParms << /K -1 /Columns \(monochrome.width) /Rows \(monochrome.height) /BlackIs1 true >>"]
                }
            case .jpegEncoded:
                additions.append("/Filter /DCTDecode")
                if let parameters = try terminalParameters(in: dictionary, filters: ["DCTDecode", "DCT"]) {
                    additions.append("/DecodeParms \(try encode(parameters, depth: depth))")
                }
            case .JPEG2000:
                additions.append("/Filter /JPXDecode")
                if let parameters = try terminalParameters(in: dictionary, filters: ["JPXDecode"]) {
                    additions.append("/DecodeParms \(try encode(parameters, depth: depth))")
                }
            @unknown default:
                throw SnapshotFailure.invalidObject(#line)
            }
            additions.append("/Length \(bytes.count)")
            var result = try encodeDictionary(dictionary, depth: depth,
                dropping: ["Length", "Filter", "DecodeParms", "F", "FFilter", "FDecodeParms"],
                additions: additions)
            try append(Data("\nstream\n".utf8), to: &result)
            try append(bytes, to: &result)
            try append(Data("\nendstream".utf8), to: &result)
            onResourceStreamEncoded?()
            return result
        }

        private func prepareOriginalNumberIndex() throws {
            guard documentGraph || carriesUnmodifiedType3Resources else { return }
            var dictionaries: [UInt: [PDFRawStreamSource]] = [:]
            var arrays: [UInt: [PDFRawStreamSource]] = [:]
            var entries = 0, remainingBytes = 8 * 1_024 * 1_024
            for source in rawStreamSources {
                // A plan may have been prepared on Main before any raw proof.
                // The isolated writer must finish catalog-number pairing before
                // taking this source's immutable container candidate snapshot.
                try source.prepareStoredDestinationNumbers()
                guard let containers = try source.numberCorrectionContainers() else { continue }
                // Account each container/source edge, including shared IDs.
                let added = containers.dictionaries.count + containers.arrays.count
                guard added <= 100_000 - entries, added <= remainingBytes / 128 else {
                    // No partial index: retain the established CG encoding if
                    // optional number preservation exceeds this writer bound.
                    numberDictionarySources.removeAll(); numberArraySources.removeAll()
                    return
                }
                entries += added; remainingBytes -= added * 128
                for (offset, identity) in containers.dictionaries.enumerated() {
                    if offset & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    dictionaries[identity, default: []].append(source)
                }
                for (offset, identity) in containers.arrays.enumerated() {
                    if offset & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    arrays[identity, default: []].append(source)
                }
            }
            numberDictionarySources = dictionaries; numberArraySources = arrays
        }

        private func originalNumber(in array: CGPDFArrayRef, index: Int, depth: Int) throws -> String? {
            // Repeated one-page Apply snapshots retain their existing
            // deterministic CG path. No candidate means zero source locks.
            guard let sources = numberArraySources[pdfReferenceIdentity(array)] else { return nil }
            var exactToken: String?
            for source in sources {
                if let token = try source.signatureNumberToken(in: array, index: index) {
                    if let exactToken, exactToken != token { throw SnapshotFailure.invalidObject(#line) }
                    exactToken = token
                }
            }
            if let exactToken {
                visits += 1
                guard depth < 64, visits < maximumVisits else { throw SnapshotFailure.limitExceeded }
                return exactToken
            }
            var number: Double?
            for source in sources {
                if case .real(let value)? = try source.originalNumber(in: array, index: index) {
                    if let number, number != value { throw SnapshotFailure.invalidObject(#line) }
                    number = value
                }
            }
            guard let number else { return nil }
            return try encodeCorrectedNumber(number, depth: depth)
        }

        private func originalNumber(in dictionary: CGPDFDictionaryRef, key: UnsafePointer<CChar>, depth: Int) throws -> String? {
            guard let sources = numberDictionarySources[pdfReferenceIdentity(dictionary)] else { return nil }
            var exactToken: String?
            for source in sources {
                if let token = try source.signatureNumberToken(in: dictionary, key: key) {
                    if let exactToken, exactToken != token { throw SnapshotFailure.invalidObject(#line) }
                    exactToken = token
                }
            }
            if let exactToken {
                visits += 1
                guard depth < 64, visits < maximumVisits else { throw SnapshotFailure.limitExceeded }
                return exactToken
            }
            var number: Double?
            for source in sources {
                if case .real(let value)? = try source.originalNumber(in: dictionary, key: key) {
                    if let number, number != value { throw SnapshotFailure.invalidObject(#line) }
                    number = value
                }
            }
            guard let number else { return nil }
            return try encodeCorrectedNumber(number, depth: depth)
        }

        private func encodeCorrectedNumber(_ number: Double, depth: Int) throws -> String {
            // A correction replaces one encode(object) call, including exactly
            // that scalar's existing whole-writer visit/depth charge.
            visits += 1
            guard depth < 64, visits < maximumVisits else { throw SnapshotFailure.limitExceeded }
            return try encodeCatalogValue(.real(number), depth: depth)
        }

        private func retainRawSource(_ source: PDFRawStreamSource) {
            if rawStreamSourceIDs.insert(ObjectIdentifier(source)).inserted { rawStreamSources.append(source) }
        }

        private func prepareRawSources(for page: PDFPage, reference: CGPDFPage) throws {
            if let raw = encodedAssemblySource {
                if let witness = encodedAssemblyOrigin {
                    guard !documentGraph, try witness.matches(page, reference: reference, raw: raw) else {
                        throw SnapshotFailure.invalidObject(#line)
                    }
                    retainRawSource(raw)
                    try raw.preparePaintingResources(for: [reference])
                    guard try witness.matches(page, reference: reference, raw: raw) else {
                        throw SnapshotFailure.invalidObject(#line)
                    }
                    return
                }
                guard !documentGraph, let native = reference.document,
                      page.pageRef?.dictionary == reference.dictionary,
                      page.pageRef?.document === native, raw.provesExactFactoryOwner(native)
                else { throw SnapshotFailure.invalidObject(#line) }
                retainRawSource(raw)
                try raw.preparePaintingResources(for: [reference])
                return
            }
            // Editing targets compare exact canonical snapshot bytes again at
            // Apply. A lock-contended optional cache must never switch that
            // representation between raw and decoded streams mid-transaction.
            // Single-page editing keeps its established deterministic encoding;
            // its many prefix checks reuse ContentTemplate instead.
            guard documentGraph else { return }
            if let raw = PDFRawStreamProvenance.source(for: page) { retainRawSource(raw) }
            for raw in rawStreamSources { try raw.preparePaintingResources(for: [reference]) }
        }

        private func group4Image(_ data: Data, dictionary: CGPDFDictionaryRef) -> (data: Data, width: Int, height: Int)? {
            guard dictionaryName(dictionary, "Subtype") == "Image",
                  dictionaryName(dictionary, "ColorSpace") == "DeviceGray" else { return nil }
            var bits: CGPDFInteger = 0, width: CGPDFInteger = 0, height: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits), bits == 1,
                  CGPDFDictionaryGetInteger(dictionary, "Width", &width), width > 0,
                  CGPDFDictionaryGetInteger(dictionary, "Height", &height), height > 0 else { return nil }
            if object(dictionary, "ImageMask") != nil {
                var imageMask: CGPDFBoolean = 0
                guard CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &imageMask), imageMask == 0 else { return nil }
            }
            guard let encoded = PDFMonochromeImageEncoder.encode(data: data, width: Int(width), height: Int(height)) else { return nil }
            return (encoded, Int(width), Int(height))
        }

        private func flated(_ data: Data) -> Data? {
            // Bound temporary compression storage independently of the final
            // document budget. Small or incompressible streams stay unchanged.
            let maximumScratch = 64 * 1_024 * 1_024
            guard data.count >= 256, data.count <= maximumScratch else { return nil }
            var length = compressBound(uLong(data.count))
            guard length <= uLong(maximumScratch) else { return nil }
            var compressed = Data(count: Int(length))
            let status = compressed.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    compress2(destination.baseAddress?.assumingMemoryBound(to: Bytef.self), &length,
                              source.baseAddress?.assumingMemoryBound(to: Bytef.self), uLong(data.count), Z_BEST_SPEED)
                }
            }
            guard status == Z_OK, length + 32 < uLong(data.count) else { return nil }
            compressed.count = Int(length)
            return compressed
        }

        /// StreamCopyData may strip an ASCII/Flate envelope while retaining the
        /// JPEG bytes. Preserve only the DCT/JPX filter's parameters, especially
        /// DCT ColorTransform, instead of reapplying the discarded filter chain.
        private func terminalParameters(in dictionary: CGPDFDictionaryRef,
                                        filters allowed: Set<String>) throws -> CGPDFObjectRef? {
            guard let filter = object(dictionary, "Filter") else { return nil }
            if CGPDFObjectGetType(filter) == .name {
                guard let filterName = objectName(filter), allowed.contains(filterName) else {
                    throw SnapshotFailure.invalidObject(#line)
                }
                return object(dictionary, "DecodeParms")
            }
            guard CGPDFObjectGetType(filter) == .array else { throw SnapshotFailure.invalidObject(#line) }
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(filter, .array, &array), let array else { throw SnapshotFailure.invalidObject(#line) }
            let count = CGPDFArrayGetCount(array)
            guard count > 0, count < 64 else { throw SnapshotFailure.limitExceeded }
            var last: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, count - 1, &last), let last,
                  let filterName = objectName(last), allowed.contains(filterName) else {
                throw SnapshotFailure.invalidObject(#line)
            }
            guard let parameters = object(dictionary, "DecodeParms") else { return nil }
            if CGPDFObjectGetType(parameters) == .null { return nil }
            guard CGPDFObjectGetType(parameters) == .array else { throw SnapshotFailure.invalidObject(#line) }
            var parametersArray: CGPDFArrayRef?
            guard CGPDFObjectGetValue(parameters, .array, &parametersArray), let parametersArray,
                  CGPDFArrayGetCount(parametersArray) == count else { throw SnapshotFailure.invalidObject(#line) }
            var lastParameters: CGPDFObjectRef?
            guard CGPDFArrayGetObject(parametersArray, count - 1, &lastParameters) else { throw SnapshotFailure.invalidObject(#line) }
            return lastParameters
        }

        private func encodeDictionary(_ dictionary: CGPDFDictionaryRef, depth: Int,
                                      dropping: Set<String> = [], additions: [String] = []) throws -> Data {
            guard CGPDFDictionaryGetCount(dictionary) < 4_096 else { throw SnapshotFailure.limitExceeded }
            if !documentGraph, let type = dictionaryName(dictionary, "Type"), ["Page", "Pages", "Catalog"].contains(type) {
                // Resource references must not import sibling pages or a whole
                // catalog into this bounded one-page snapshot.
                throw SnapshotFailure.invalidObject(#line)
            }
            if captureBodyCopy,
               object(dictionary, "StructParent") != nil || object(dictionary, "StructParents") != nil
                    || (!carriesUnmodifiedType3Resources && dictionaryName(dictionary, "Subtype") == "Type3") {
                bodyCopyUnsafe = true
            }
            var droppedKeys = dropping
            var values = additions
            let dictionaryKey = pdfReferenceIdentity(dictionary)
            if let form = markingGeneratedBodyForm, dictionaryKey == pdfReferenceIdentity(form) {
                guard !documentGraph, !generatedBodyMarkerApplied,
                      dictionaryName(dictionary, "Subtype") == "Form",
                      ["Group", "OC", "Ref", "StructParent", "StructParents", "EmberPDFBodyText",
                       "EmberPDFBodyTextBounds", "EmberPDFOutlinedOCR", "EmberPDFScannedErasure"].allSatisfy({
                        object(dictionary, $0) == nil
                      }) else { throw SnapshotFailure.invalidObject(#line) }
                // This exact fresh Form was independently bound before its
                // native owner closed. Only the inert ownership marker changes;
                // content, BBox, resources, clipping and graphics state do not.
                values.append("/EmberPDFBodyText true")
                generatedBodyMarkerApplied = true
            }
            if documentGraph, let catalog = stagedCatalog,
               dictionaryKey == pdfReferenceIdentity(catalog), let outlineRootID {
                droppedKeys.insert("Outlines")
                values.append("/Outlines \(outlineRootID) 0 R")
            }
            droppedKeys.formUnion(resolvedCatalogDrops[dictionaryKey] ?? [])
            if let additions = resolvedCatalogOverrides[dictionaryKey] {
                for (key, value) in additions {
                    droppedKeys.insert(key)
                    values.append(try key.withCString { try name($0) } + " " + encodeCatalogValue(value, depth: depth + 1))
                }
            }
            if let livePage = pageOverrides[dictionaryKey] {
                appliedPageOverrides.insert(dictionaryKey)
                for key in ["Contents", "Resources", "Group", "UserUnit", "EmberPDFPreservePageContent"] {
                    droppedKeys.insert(key)
                    if key == "Contents", livePage.translation != .zero {
                        let shift = livePage.translation
                        var content = Data("q\n1 0 0 1 \(try number(shift.x)) \(try number(shift.y)) cm\n".utf8)
                        try append(try contentData(reference: livePage.reference), to: &content)
                        try append(Data("\nQ\n".utf8), to: &content)
                        var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
                        try append(content, to: &stream)
                        try append(Data("\nendstream".utf8), to: &stream)
                        values.append("/Contents \(try addBody(stream)) 0 R")
                        continue
                    }
                    let value = key == "Resources" ? inheritedObject(livePage.dictionary, key) : object(livePage.dictionary, key)
                    if let value {
                        values.append("/\(key) \(try encode(value, depth: depth))")
                    } else if key == "Resources" {
                        values.append("/Resources << >>")
                    }
                }
            }
            if let approved = approvedDonorPrograms[dictionaryKey] {
                guard !documentGraph, approved.bytes.count <= 16 * 1_024 * 1_024,
                      let descriptor = try dictionaryObject(object(dictionary, "FontDescriptor")) else {
                    throw SnapshotFailure.invalidObject(#line)
                }
                let programID: Int
                if let existing = approvedProgramIDs[approved.digest] { programID = existing }
                else {
                    guard approved.bytes.count <= 32 * 1_024 * 1_024 - approvedProgramBytes else {
                        throw SnapshotFailure.limitExceeded
                    }
                    approvedProgramBytes += approved.bytes.count
                    let compressed = flated(approved.bytes)
                    let payload = compressed ?? approved.bytes
                    let filter = compressed == nil ? "" : " /Filter /FlateDecode"
                    var body = Data(("<< /Length \(payload.count) /Length1 \(approved.bytes.count)\(filter) >>\nstream\n").utf8)
                    try append(payload, to: &body); try append(Data("\nendstream".utf8), to: &body)
                    programID = try addBody(body); approvedProgramIDs[approved.digest] = programID
                }
                let descriptorBody = try encodeDictionary(descriptor, depth: depth + 1,
                    dropping: ["FontFile2"], additions: ["/FontFile2 \(programID) 0 R"])
                droppedKeys.insert("FontDescriptor")
                values.append("/FontDescriptor \(try addBody(descriptorBody)) 0 R")
            }
            if dictionaryName(dictionary, "Type") == "Font" {
                switch fontNames {
                case .unchanged:
                    break
                case .protectForEditing:
                    // Only markers created by this snapshot may be restored;
                    // never interpret a same-named key from an input PDF.
                    droppedKeys.insert(Self.originalFontNameKey)
                    if let original = protectedSimpleFontName(in: dictionary) {
                        fontAliasCount += 1
                        let family = original.split(separator: "+", maxSplits: 1).last.map(String.init) ?? original
                        let alias = "EmberBodyFont\(fontAliasCount)+\(family)"
                        droppedKeys.formUnion(["BaseFont", Self.originalFontNameKey])
                        values.append("/BaseFont \(try alias.withCString { try name($0) })")
                        values.append("/\(Self.originalFontNameKey) \(try original.withCString { try name($0) })")
                    }
                case .restoreOriginals:
                    if let original = dictionaryName(dictionary, Self.originalFontNameKey) {
                        if captureBodyCopy { bodyCopyUnsafe = true }
                        droppedKeys.formUnion(["BaseFont", Self.originalFontNameKey])
                        values.append("/BaseFont \(try original.withCString { try name($0) })")
                    }
                }
            }
            var error: Error?
            CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
                do {
                    guard strnlen(key, 4_096) < 4_096 else { throw SnapshotFailure.limitExceeded }
                    if !droppedKeys.contains(String(cString: key)) {
                        let original: String?
                        if CGPDFObjectGetType(value) == .real {
                            original = try self.originalNumber(in: dictionary, key: key, depth: depth)
                        } else { original = nil }
                        let encoded = try original ?? self.encode(value, depth: depth)
                        values.append(try self.name(key) + " " + encoded)
                    }
                    return true
                } catch let caught {
                    error = caught
                    return false
                }
            }, nil)
            if let error { throw error }
            return Data(("<< " + values.joined(separator: " ") + " >>").utf8)
        }

        private func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
            var value: CGPDFArrayRef?
            return CGPDFDictionaryGetArray(dictionary, key, &value) ? value : nil
        }

        private func encodeCatalogValue(_ value: PDFCatalogGraphValue, depth: Int) throws -> String {
            guard depth < 64 else { throw SnapshotFailure.limitExceeded }
            switch value {
            case .original(let object): return try encode(object, depth: depth)
            case .dictionaryReference(let dictionary):
                let key = pdfReferenceIdentity(dictionary)
                if let alias = catalogPlan?.aliases[key] {
                    guard activeAliases.insert(key).inserted else { throw SnapshotFailure.invalidObject(#line) }
                    defer { activeAliases.remove(key) }
                    return try encodeCatalogValue(alias, depth: depth + 1)
                }
                return try documentDictionaryReference(dictionary)
            case .node(let node):
                let identity = ObjectIdentifier(node)
                if let id = customIdentifiers[identity] { return "\(id) 0 R" }
                guard bodies.count < maximumObjects else { throw SnapshotFailure.limitExceeded }
                let id = bodies.count + 1
                customIdentifiers[identity] = id; bodies.append(nil)
                pendingBodies.append((id, .custom(node)))
                return "\(id) 0 R"
            case .array(let values):
                guard values.count <= 250_000 else { throw SnapshotFailure.limitExceeded }
                return try "[" + values.map { try encodeCatalogValue($0, depth: depth + 1) }.joined(separator: " ") + "]"
            case .sparseArray(let count, let members):
                guard count >= 0, count <= 250_000, members.count <= count,
                      members.keys.allSatisfy({ $0 >= 0 && $0 < count }),
                      bodies.count < maximumObjects else { throw SnapshotFailure.limitExceeded }
                try PDFSaveCancellation.checkCurrent()
                let id = bodies.count + 1
                bodies.append(nil)
                pendingBodies.append((id, .sparseArray(count: count, members: members, depth: depth, aliases: activeAliases)))
                return "\(id) 0 R"
            case .dictionary(let entries):
                return try "<< " + entries.sorted { $0.key < $1.key }.map { key, value in
                    try key.withCString { try name($0) } + " " + encodeCatalogValue(value, depth: depth + 1)
                }.joined(separator: " ") + " >>"
            case .name(let value): return try value.withCString { try name($0) }
            case .string(let bytes): return "<" + hex(bytes) + ">"
            case .integer(let number): return String(number)
            case .real(let value):
                guard value.isFinite else { throw SnapshotFailure.invalidObject(#line) }
                return try number(CGFloat(value))
            case .boolean(let value): return value ? "true" : "false"
            case .null: return "null"
            case .page(let index):
                guard stagedPages.indices.contains(index) else { throw SnapshotFailure.invalidObject(#line) }
                return try documentDictionaryReference(stagedPages[index])
            case .annotation(let page, let index):
                guard stagedPages.indices.contains(page), let array = self.array(stagedPages[page], "Annots") else { throw SnapshotFailure.invalidObject(#line) }
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, index, &dictionary), let dictionary else { throw SnapshotFailure.invalidObject(#line) }
                return try documentDictionaryReference(dictionary)
            }
        }

        /// A ParentTree slot array keeps its exact MCID holes, but belongs
        /// to its own bounded object. Inlining every page's sparse array into
        /// one tree dictionary makes a reader materialize millions of nulls
        /// when it merely asks for the tag root.
        private func encodeSparseArrayBody(count: Int, members: [Int: PDFCatalogGraphValue], depth: Int, aliases: Set<UInt>) throws -> Data {
            let previousAliases = activeAliases
            activeAliases = aliases
            defer { activeAliases = previousAliases }
            guard depth < 64, count >= 0, count <= 250_000, members.count <= count,
                  members.keys.allSatisfy({ $0 >= 0 && $0 < count }) else { throw SnapshotFailure.limitExceeded }
            try PDFSaveCancellation.checkCurrent()
            var result = "[", cursor = 0
            for (offset, pair) in members.sorted(by: { $0.key < $1.key }).enumerated() {
                if offset & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                let (index, member) = pair
                result += String(repeating: "null ", count: index - cursor)
                result += try encodeCatalogValue(member, depth: depth + 1) + " "
                cursor = index + 1
            }
            result += String(repeating: "null ", count: count - cursor)
            if count > 0 { result.removeLast() }
            return Data((result + "]").utf8)
        }

        private func encodeCustomNode(_ node: PDFCatalogGraphNode) throws -> Data {
            var entries = node.entries
            if let data = node.streamData { entries["Length"] = .integer(data.count) }
            var result = Data(try encodeCatalogValue(.dictionary(entries), depth: 0).utf8)
            if let data = node.streamData {
                try append(Data("\nstream\n".utf8), to: &result)
                try append(data, to: &result)
                try append(Data("\nendstream".utf8), to: &result)
            }
            return result
        }

        private func protectedSimpleFontName(in dictionary: CGPDFDictionaryRef) -> String? {
            guard let subtype = dictionaryName(dictionary, "Subtype"),
                  ["TrueType", "Type1"].contains(subtype),
                  let original = dictionaryName(dictionary, "BaseFont") else { return nil }
            let family = original.split(separator: "+", maxSplits: 1).last.map(String.init) ?? original
            // PDFium gives these names special encoding semantics, even for
            // embedded fonts. Do not change their interpretation to gain a
            // unique content-generator key.
            guard !["Symbol", "ZapfDingbats"].contains(family) else { return nil }
            var descriptor: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "FontDescriptor", &descriptor), let descriptor else { return nil }
            for key in ["FontFile", "FontFile2", "FontFile3"] {
                if let file = object(descriptor, key), CGPDFObjectGetType(file) == .stream { return original }
            }
            return nil
        }

        private func setBody(_ id: Int, _ body: Data) throws {
            guard body.count <= maximumBytes - storedBytes else { throw SnapshotFailure.limitExceeded }
            storedBytes += body.count
            bodies[id - 1] = body
        }

        private func addBody(_ body: Data) throws -> Int {
            guard bodies.count < maximumObjects else { throw SnapshotFailure.limitExceeded }
            bodies.append(nil)
            let id = bodies.count
            try setBody(id, body)
            return id
        }

        private func append(_ bytes: Data, to destination: inout Data) throws {
            guard bytes.count <= maximumBytes - destination.count else { throw SnapshotFailure.limitExceeded }
            destination.append(bytes)
        }

        private func reserveInlineBytes(_ count: Int) throws {
            guard count <= maximumBytes - inlineBytes else { throw SnapshotFailure.limitExceeded }
            inlineBytes += count
        }

        private func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
            var value: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dictionary, key, &value) else { return nil }
            return value
        }

        private func inheritedObject(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
            var current = dictionary
            for _ in 0..<32 {
                if let value = object(current, key) { return value }
                var parent: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(current, "Parent", &parent), let parent else { return nil }
                current = parent
            }
            return nil
        }

        private func dictionaryName(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            object(dictionary, key).flatMap(objectName)
        }

        private func objectName(_ object: CGPDFObjectRef) -> String? {
            guard CGPDFObjectGetType(object) == .name else { return nil }
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value,
                  strnlen(value, 4_096) < 4_096 else { return nil }
            return String(cString: value)
        }

        private func name(_ pointer: UnsafePointer<CChar>) throws -> String {
            let count = strnlen(pointer, 4_096)
            guard count < 4_096 else { throw SnapshotFailure.limitExceeded }
            try reserveInlineBytes(count * 3 + 1)
            var result = "/"
            for index in 0..<count {
                let byte = UInt8(bitPattern: pointer[index])
                if byte >= 33 && byte <= 126 && ![35, 37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(byte) {
                    result.append(Character(UnicodeScalar(byte)))
                } else {
                    result += "#" + hex([byte])
                }
            }
            return result
        }

        private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
            let digits = Array("0123456789ABCDEF".utf8)
            return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
        }

        private func number(_ value: CGFloat) throws -> String {
            try PDFDecimalNumber.string(value)
        }

        private func valid(_ rectangle: CGRect) -> Bool {
            [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height].allSatisfy(\.isFinite)
                && rectangle.width > 0 && rectangle.height > 0
        }

        private func rectangle(_ rectangle: CGRect) throws -> String {
            try "[\([rectangle.minX, rectangle.minY, rectangle.maxX, rectangle.maxY].map(number).joined(separator: " "))]"
        }
    }
}
