// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// A detached one-page document paired with its zero-based source index.
///
/// Keeping the index beside the document prevents batch exporters from losing
/// the original page number after noncontiguous selections are sorted.
struct ExtractedPDFPage {
    let sourcePageIndex: Int
    let document: PDFDocument
}

/// PDF 페이지 복사·추출·병합에 공통으로 쓰는 작은 연산 모음이다.
///
/// PDFKit의 `PDFPage`는 자신을 소유한 문서와 내부 객체 그래프를 공유할 수 있다.
/// 그래서 다른 문서에 페이지를 넣을 때는 반드시 `detachedCopy`를 만들어 원본과
/// 결과 문서가 같은 mutable 객체를 우연히 함께 수정하지 않게 한다.
enum PDFPageOperations {
    /// PDFKit insertion can retain/decode an entire book's shared image table.
    /// Give assembly an owned, bounded one-page backing when unused images can
    /// be proved absent from its painting. Unsupported pages keep NSCopying.
    static func compactAssemblyCopy(of page: PDFPage, remainingBytes: Int) throws -> (page: PDFPage, bytes: Int)? {
        try PDFSaveCancellation.checkCurrent()
        guard remainingBytes > 0, page.annotations.isEmpty,
              let reference = page.pageRef, let native = reference.document,
              !native.isEncrypted, let dictionary = reference.dictionary else { return nil }
        let document = page.document
        let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        let geometry = boxes.map { page.bounds(for: $0) }, rotation = page.rotation
        do {
            guard let data = try PDFBodyTextPageSnapshot.compactAssemblyPageData(for: page, maximumBytes: remainingBytes),
                  data.count <= remainingBytes else { return nil }
            try PDFSaveCancellation.checkCurrent()
            guard page.document === document, page.pageRef?.dictionary == dictionary,
                  page.pageRef?.document === native, page.annotations.isEmpty,
                  page.rotation == rotation, boxes.map({ page.bounds(for: $0) }) == geometry,
                  let factory = PDFRawStreamProvenance.bodyResultFactory(data: data),
                  let copied = factory.copyPage(), copied !== page,
                  copied.annotations.isEmpty, copied.rotation == rotation,
                  boxes.map({ copied.bounds(for: $0) }) == geometry else { return nil }
            try PDFSaveCancellation.checkCurrent()
            return (copied, data.count)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Optional optimization only. Existing assembly remains available
            // for unproved resources or a bounded snapshot that cannot fit.
            return nil
        }
    }

    /// Keep the ordinary independent NSCopying result. The fallback copies
    /// only annotation-free native painting, never a PDFKit redraw/subset.
    static func detachedCopy(of page: PDFPage) -> PDFPage? {
        if let copied = page.copy() as? PDFPage, copied !== page {
            return copied
        }
        guard page.annotations.isEmpty,
              let reference = page.pageRef, let native = reference.document,
              !native.isEncrypted, let dictionary = reference.dictionary else { return nil }
        var rawAnnotations: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "Annots", &rawAnnotations) {
            guard let rawAnnotations else { return nil }
            if CGPDFObjectGetType(rawAnnotations) != .null {
                var annotations: CGPDFArrayRef?
                guard CGPDFObjectGetValue(rawAnnotations, .array, &annotations), let annotations,
                      CGPDFArrayGetCount(annotations) == 0 else { return nil }
            }
        }
        let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        let geometry = boxes.map { page.bounds(for: $0) }
        let rotation = page.rotation
        do {
            // This writer copies the actual Contents/effective Resources and
            // emits the existing preservation marker. It omits annotations,
            // which are explicitly outside this narrow fallback above.
            let data = try PDFBodyTextPageSnapshot.originalPageData(for: page)
            guard page.pageRef?.dictionary == dictionary, page.annotations.isEmpty,
                  page.rotation == rotation, boxes.map({ page.bounds(for: $0) }) == geometry,
                  let factory = PDFRawStreamProvenance.bodyResultFactory(data: data),
                  let copied = factory.copyPage(), copied !== page,
                  copied.annotations.isEmpty, copied.rotation == rotation,
                  boxes.map({ copied.bounds(for: $0) }) == geometry else { return nil }
            // The bounded fresh factory owns only this new one-page result;
            // it keeps no live source book and grants no font/tag authority.
            return copied
        } catch {
            return nil
        }
    }

    /// 선택 인덱스를 문서 순서로 정렬해 새 PDF에 복사한다.
    static func extract(from document: PDFDocument, indexes: [Int]) throws -> PDFDocument {
        // Keep the service boundary authoritative. Model/UI callers perform the
        // same check for prompt feedback, but direct integrations must not turn
        // a restricted user-password session into an unrestricted page copy.
        try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
        let indexes = try normalizedSelection(indexes, pageCount: document.pageCount)
        let imported = try PDFPageStructurePreserver.prepareImport(from: document, indexes: indexes)
        let output = PDFDocument()
        for page in imported.pages { output.insert(page, at: output.pageCount) }
        try imported.restoreFormFields()
        output.documentAttributes = imported.attributes
        output.outlineRoot = imported.outline
        PDFCatalogStructurePreserver.inheritDocumentMetadata(from: document, to: output)
        PDFCatalogStructurePreserver.refreshMarker(output)
        if imported.containsFormFields { PDFCanonicalFormMaterializer.mark(output) }
        PDFCatalogStructurePreserver.setAssemblyImagePruning(true, for: output)
        return output
    }

    /// 선택한 각 페이지를 독립적인 한 페이지 PDF로 만든다.
    ///
    /// Every index is validated before the first page is copied. A mixed valid
    /// and invalid request therefore cannot produce a partial export batch.
    static func extractIndividually(
        from document: PDFDocument,
        indexes: [Int]
    ) throws -> [ExtractedPDFPage] {
        try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
        let indexes = try normalizedSelection(indexes, pageCount: document.pageCount)
        return try indexes.map { index in
            ExtractedPDFPage(sourcePageIndex: index, document: try extract(from: document, indexes: [index]))
        }
    }

    @discardableResult
    /// source 전체를 destination 뒤에 복사하고 실제 삽입된 페이지 수를 반환한다.
    /// 원본 `source`는 변경하지 않는다.
    static func append(contentsOf source: PDFDocument, to destination: PDFDocument) throws -> Int {
        try PDFDocumentSecurityPolicy.validateCanExtractPages(source)
        guard source.pageCount > 0 else { return 0 }
        let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: Array(0..<source.pageCount))
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: destination, at: destination.pageCount)
        try merge.apply()
        return merge.pages.count
    }

    /// Selected-page exports are set-based even when an integration passes an
    /// array. Duplicates are removed and the resulting pages follow document
    /// order, matching the visible sidebar selection contract.
    static func normalizedSelection(_ indexes: [Int], pageCount: Int) throws -> [Int] {
        guard !indexes.isEmpty else { throw WorkspaceError.noPagesSelected }
        let normalized = Set(indexes).sorted()
        guard normalized.allSatisfy({ $0 >= 0 && $0 < pageCount }) else {
            throw WorkspaceError.operationFailed(
                L10n.string(
                    "error.invalid_page_selection",
                    defaultValue: "선택한 페이지에 현재 PDF에 없는 페이지가 있습니다."
                )
            )
        }
        return normalized
    }

}
