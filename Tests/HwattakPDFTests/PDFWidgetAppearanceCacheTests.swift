// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFWidgetAppearanceCacheTests: XCTestCase {
    private let byteBudget = 8 * 1_024 * 1_024

    func testSeventyOriginalFormPagesCanBeReadAndRevisited() async throws {
        let source = try raw(fixture(widgetCounts: Array(repeating: 1, count: 70)))
        let proof = try await Task.detached {
            let first = try XCTUnwrap(source.originalWidgetStates(onPage: 0))
            var visited = 1
            for page in 1..<70 {
                let states = try XCTUnwrap(source.originalWidgetStates(onPage: page))
                XCTAssertEqual(states.count, 1)
                visited += 1
                XCTAssertLessThanOrEqual(source.widgetStateCacheFootprint.pages, 64)
                XCTAssertLessThanOrEqual(source.widgetStateCacheFootprint.encodedBytes, 8 * 1_024 * 1_024)
            }
            let reread = try XCTUnwrap(source.originalWidgetStates(onPage: 0))
            return (visited, first == reread, source.widgetStateCacheFootprint)
        }.value
        XCTAssertEqual(proof.0, 70)
        XCTAssertTrue(proof.1, "An evicted page must be re-proved from the original, with identical state.")
        XCTAssertEqual(proof.2.pages, 64)
        XCTAssertEqual(proof.2.refusedPages, 0)
    }

    @MainActor
    func testMainCacheHitRefreshesRecencyWithoutWarmingAMiss() async throws {
        let source = try raw(fixture(widgetCounts: Array(repeating: 1, count: 65)))
        try await Task.detached {
            for page in 0..<64 { _ = try XCTUnwrap(source.originalWidgetStates(onPage: page)) }
        }.value
        XCTAssertNotNil(try source.originalWidgetStates(onPage: 0))
        let last = try await Task.detached { try source.originalWidgetStates(onPage: 64)?.count }.value
        XCTAssertEqual(last, 1)
        XCTAssertNotNil(try source.originalWidgetStates(onPage: 0), "A main cache hit is a real use of the page.")
        XCTAssertNil(try source.originalWidgetStates(onPage: 1), "A main miss must not reopen the original PDF.")
        let revisit = try await Task.detached { try source.originalWidgetStates(onPage: 1)?.count }.value
        XCTAssertEqual(revisit, 1)
        XCTAssertEqual(source.widgetStateCacheFootprint.pages, 64)
        XCTAssertEqual(source.widgetStateCacheFootprint.refusedPages, 0)
    }

    @MainActor
    func testSeventyPageSnapshotWorkerPlanKeepsEveryOriginalAppearanceEligible() async throws {
        let bytes = fixture(widgetCounts: Array(repeating: 1, count: 70))
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(document, data: bytes)
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let proof = try await Task.detached {
            let isolated = try snapshot.takeDocument()
            let plan = try PDFCatalogStructurePreserver.plan(for: isolated)
            return (plan.widgetAppearanceCount, plan.widgetFormLocations.count,
                    plan.widgetFormDefaults != nil, source.widgetStateCacheFootprint)
        }.value
        XCTAssertEqual(proof.0, 70, "The all-widget AP proof must not stop at cache capacity.")
        XCTAssertEqual(proof.1, 70)
        XCTAssertTrue(proof.2)
        XCTAssertLessThanOrEqual(proof.3.pages, 64)
        XCTAssertLessThanOrEqual(proof.3.encodedBytes, byteBudget)
        XCTAssertEqual(proof.3.refusedPages, 0)
        XCTAssertEqual(document.pageCount, 70)
        XCTAssertEqual(document.page(at: 69)?.annotations.first?.widgetStringValue, "value-69-0")
    }

    func testEncodedByteBudgetEvictsWithoutLosingLaterCoverage() async throws {
        let source = try raw(fixture(widgetCounts: Array(repeating: 60, count: 5), styleBytes: 35_000))
        let proof = try await Task.detached {
            var totalProvedBytes = 0
            var first: [Int: PDFWidgetAppearancePreserver.State] = [:]
            for page in 0..<5 {
                let states = try XCTUnwrap(source.originalWidgetStates(onPage: page))
                XCTAssertEqual(states.count, 60)
                if page == 0 { first = states }
                totalProvedBytes += states.values.reduce(0) { $0 + $1.byteCount }
                let usage = source.widgetStateCacheFootprint
                XCTAssertLessThanOrEqual(usage.encodedBytes, 8 * 1_024 * 1_024)
                XCTAssertLessThanOrEqual(usage.pages, 64)
            }
            let afterFive = source.widgetStateCacheFootprint
            let reread = try XCTUnwrap(source.originalWidgetStates(onPage: 0))
            return (totalProvedBytes, afterFive, first == reread, source.widgetStateCacheFootprint)
        }.value
        XCTAssertGreaterThan(proof.0, byteBudget, "The fixture must actually exercise aggregate byte eviction.")
        XCTAssertLessThan(proof.1.pages, 5)
        XCTAssertTrue(proof.2)
        XCTAssertLessThanOrEqual(proof.3.encodedBytes, byteBudget)
        XCTAssertEqual(proof.3.refusedPages, 0)
    }

    func testOversizedPageIsNotCachedAsAnUnsafeSourceFailure() async throws {
        let source = try raw(fixture(widgetCounts: [260, 1], styleBytes: 35_000))
        let proof = try await Task.detached {
            XCTAssertNil(try source.originalWidgetStates(onPage: 0))
            let before = source.widgetStateCacheFootprint
            let small = try XCTUnwrap(source.originalWidgetStates(onPage: 1))
            XCTAssertNil(try source.originalWidgetStates(onPage: 0))
            return (before, small.count, source.widgetStateCacheFootprint)
        }.value
        XCTAssertEqual(proof.0.pages, 0)
        XCTAssertEqual(proof.0.encodedBytes, 0)
        XCTAssertEqual(proof.0.refusedPages, 0)
        XCTAssertEqual(proof.1, 1)
        XCTAssertEqual(proof.2.pages, 1)
        XCTAssertEqual(proof.2.refusedPages, 0, "A per-page capacity miss remains retryable.")
    }

    func testCancellationOnColdAndCachedPagesDoesNotRefuseOrEvict() async throws {
        let source = try raw(fixture(widgetCounts: Array(repeating: 1, count: 65)))
        let proof = try await Task.detached {
            for page in 0..<64 { _ = try XCTUnwrap(source.originalWidgetStates(onPage: page)) }
            let before = source.widgetStateCacheFootprint
            let cancellation = PDFSaveCancellation(); cancellation.cancel()
            for page in [64, 0] {
                XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
                    try source.originalWidgetStates(onPage: page)
                }) { XCTAssertTrue($0 is CancellationError) }
            }
            let afterCancellation = source.widgetStateCacheFootprint
            let retry = try XCTUnwrap(source.originalWidgetStates(onPage: 64))
            return (before, afterCancellation, retry.count, source.widgetStateCacheFootprint)
        }.value
        XCTAssertEqual(proof.0.pages, proof.1.pages)
        XCTAssertEqual(proof.0.encodedBytes, proof.1.encodedBytes)
        XCTAssertEqual(proof.1.refusedPages, 0)
        XCTAssertEqual(proof.2, 1)
        XCTAssertEqual(proof.3.pages, 64)
        XCTAssertEqual(proof.3.refusedPages, 0)
    }

    func testConcurrentReadersReproveOneEvictedPageWithoutDoubleAccounting() async throws {
        let bytes = fixture(widgetCounts: Array(repeating: 1, count: 70))
        let source = try raw(bytes)
        try await Task.detached {
            for page in 0..<70 { _ = try XCTUnwrap(source.originalWidgetStates(onPage: page)) }
        }.value
        let matches = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let independent = try XCTUnwrap(PDFDocument(data: bytes))
                    let annotation = try XCTUnwrap(independent.page(at: 0)?.annotations.first)
                    let expected = try XCTUnwrap(PDFWidgetAppearancePreserver.State(annotation))
                    let states = try XCTUnwrap(source.originalWidgetStates(onPage: 0))
                    return states.count == 1 && states[0] == expected
                }
            }
            var results: [Bool] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(matches.count, 8)
        XCTAssertTrue(matches.allSatisfy { $0 })
        let usage = source.widgetStateCacheFootprint
        XCTAssertEqual(usage.pages, 64)
        XCTAssertLessThanOrEqual(usage.encodedBytes, byteBudget)
        XCTAssertEqual(usage.refusedPages, 0)
    }

    func testUnprovenOriginalInputStillHasASeparateNegativeRefusal() async throws {
        let bytes = fixture(widgetCounts: [1])
        let native = try native(bytes)
        // Deliberately violate the trusted constructor only to exercise its
        // existing independent-reader proof refusal, never to authorize bytes.
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: Data("not a PDF".utf8)))
        let usage = try await Task.detached {
            XCTAssertNil(try source.originalWidgetStates(onPage: 0))
            XCTAssertNil(try source.originalWidgetStates(onPage: 0))
            return source.widgetStateCacheFootprint
        }.value
        XCTAssertEqual(usage.pages, 0)
        XCTAssertEqual(usage.encodedBytes, 0)
        XCTAssertEqual(usage.refusedPages, 1)
    }

    @MainActor
    func testOpenedOriginalInputIsFrozenOnWorkerAndConsumedInputSurvivesURLReplacementAndEviction() async throws {
        let bytes = fixture(widgetCounts: Array(repeating: 1, count: 66), omitDefaults: true)
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.pdf"); try bytes.write(to: url)
        let document = try PDFSourceFileAccess.loadDocument(at: url).document
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let expected = try XCTUnwrap(PDFWidgetAppearancePreserver.DefaultState(XCTUnwrap(document.page(at: 0)?.annotations.first)))
        XCTAssertEqual(source.widgetInputFootprint.storage, "versionGuardedFile")
        XCTAssertNil(try source.originalWidgetDefaultStates(onPage: 0))
        XCTAssertEqual(source.widgetInputFootprint.ownedDataBytes, 0, "Main cache misses must not freeze/read the file.")
        let first = try await Task.detached { try source.originalWidgetDefaultStates(onPage: 0)?[0] }.value
        XCTAssertEqual(first, expected)
        XCTAssertEqual(source.widgetInputFootprint.storage, "ownedOriginalBytes")
        XCTAssertEqual(source.widgetInputFootprint.ownedDataBytes, bytes.count)
        let page = try XCTUnwrap(document.documentRef?.page(at: 1))
        try await Task.detached { try source.preparePaintingResources(for: [page]) }.value
        XCTAssertEqual(source.widgetInputFootprint.storage, "immutableContext")
        XCTAssertEqual(source.widgetInputFootprint.ownedDataBytes, 0, "The source releases its Data when the immutable parser consumes it.")
        let replacement = fixture(widgetCounts: Array(repeating: 1, count: 66), styleBytes: 1)
        try replacement.write(to: url, options: .atomic)
        try await Task.detached {
            for page in 1..<66 { XCTAssertEqual(try source.originalWidgetDefaultStates(onPage: page)?.count, 1) }
        }.value
        XCTAssertNil(try source.originalWidgetDefaultStates(onPage: 0), "The first page must actually have been evicted.")
        let replay = try await Task.detached { try source.originalWidgetDefaultStates(onPage: 0)?[0] }.value
        XCTAssertEqual(replay, expected, "The replacement URL is not an input to the old native graph's baseline.")
        XCTAssertEqual(source.widgetStateCacheFootprint.pages, 64)
        XCTAssertEqual(source.widgetStateCacheFootprint.refusedPages, 0)
        XCTAssertEqual(try Data(contentsOf: url), replacement)
    }

    @MainActor
    func testSixtySixPageOpenedFileSavesTwiceAtSameURLAndReeditsAfterReopen() async throws {
        try await repeatSameURLSave(fromFile: true)
    }

    @MainActor
    func testSixtySixPageExactDataCreatedDocumentRemainsASeparateRepeatSaveControl() async throws {
        try await repeatSameURLSave(fromFile: false)
    }

    @MainActor
    func testFirstFileFreezeCancellationIsRetryableButChangedOriginalIsRefused() async throws {
        let bytes = fixture(widgetCounts: [1], omitDefaults: true)
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.pdf"); try bytes.write(to: url)
        let document = try PDFSourceFileAccess.loadDocument(at: url).document
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        try await Task.detached {
            XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
                try source.originalWidgetDefaultStates(onPage: 0)
            }) { XCTAssertTrue($0 is CancellationError) }
        }.value
        XCTAssertEqual(source.widgetInputFootprint.storage, "versionGuardedFile")
        XCTAssertEqual(source.widgetInputFootprint.ownedDataBytes, 0)
        XCTAssertEqual(source.widgetStateCacheFootprint.refusedPages, 0)
        let retry = try await Task.detached { try source.originalWidgetDefaultStates(onPage: 0)?.count }.value
        XCTAssertEqual(retry, 1)
        let changedURL = folder.appendingPathComponent("changed.pdf"); try bytes.write(to: changedURL)
        let changed = try PDFSourceFileAccess.loadDocument(at: changedURL).document
        let changedSource = try XCTUnwrap(PDFRawStreamProvenance.source(for: changed))
        let replacement = fixture(widgetCounts: [1], styleBytes: 1, omitDefaults: true)
        try replacement.write(to: changedURL, options: .atomic)
        let refused = try await Task.detached { try changedSource.originalWidgetDefaultStates(onPage: 0) == nil }.value
        XCTAssertTrue(refused)
        XCTAssertEqual(changedSource.widgetInputFootprint.storage, "versionGuardedFile")
        XCTAssertEqual(changedSource.widgetInputFootprint.ownedDataBytes, 0)
        XCTAssertEqual(changedSource.widgetStateCacheFootprint.refusedPages, 1)
        XCTAssertEqual(try Data(contentsOf: changedURL), replacement)
        XCTAssertEqual(changed.page(at: 0)?.annotations.first?.widgetStringValue, "value-0-0")
    }

    @MainActor
    private func repeatSameURLSave(fromFile: Bool) async throws {
        let bytes = fixture(widgetCounts: Array(repeating: 1, count: 66), omitDefaults: true)
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("repeated.pdf")
        let document: PDFDocument
        if fromFile {
            try bytes.write(to: url)
            document = try PDFSourceFileAccess.loadDocument(at: url).document
        } else {
            document = try XCTUnwrap(PDFDocument(data: bytes))
            PDFRawStreamProvenance.bindCreated(document, data: bytes)
        }
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let warmed = try await Task.detached { try source.originalWidgetDefaultStates(onPage: 0)?.count }.value
        XCTAssertEqual(warmed, 1)
        let inspection = try PDFRecoverySnapshot(capturing: document)
        let eligible = try await Task.detached {
            try PDFCatalogStructurePreserver.plan(for: inspection.takeDocument()).widgetAppearanceCount
        }.value
        XCTAssertEqual(eligible, 66, "The unchanged first save must positively preserve every original AP.")
        try await saveSnapshot(document, to: url)
        let first = try Data(contentsOf: url)
        try assertSavedWidgets(first, changed: [:], originalAppearances: bytes)
        XCTAssertEqual(source.widgetStateCacheFootprint.pages, 64)
        XCTAssertNil(try source.originalWidgetDefaultStates(onPage: 0), "Exercise a real eviction before the repeated save.")
        let field = try XCTUnwrap(document.page(at: 0)?.annotations.first)
        let defaultBefore = field.widgetDefaultStringValue
        field.widgetStringValue = "Edited once"
        XCTAssertEqual(field.widgetDefaultStringValue, defaultBefore, "This must be a value-only edit.")
        try await saveSnapshot(document, to: url)
        let second = try Data(contentsOf: url)
        try assertSavedWidgets(second, changed: [0: "Edited once"])
        XCTAssertEqual(field.widgetStringValue, "Edited once")
        XCTAssertEqual(document.page(at: 65)?.annotations.first?.widgetStringValue, "value-65-0")
        let reopened = try PDFSourceFileAccess.loadDocument(at: url).document
        try XCTUnwrap(reopened.page(at: 65)?.annotations.first).widgetStringValue = "Edited after reopen"
        try await saveSnapshot(reopened, to: url)
        try assertSavedWidgets(Data(contentsOf: url), changed: [0: "Edited once", 65: "Edited after reopen"])
        XCTAssertEqual(source.widgetStateCacheFootprint.refusedPages, 0)
        XCTAssertLessThanOrEqual(source.widgetStateCacheFootprint.encodedBytes, byteBudget)
    }

    @MainActor
    private func saveSnapshot(_ document: PDFDocument, to url: URL) async throws {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        try await Task.detached { try AtomicPDFWriter.write(snapshot.takeDocument(), to: url) }.value
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-widget-repeated-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertSavedWidgets(_ data: Data, changed: [Int: String], originalAppearances: Data? = nil) throws {
        let reader = try XCTUnwrap(PDFDocument(data: data)), document = try native(data)
        XCTAssertEqual(reader.pageCount, 66)
        XCTAssertEqual(document.numberOfPages, 66)
        let original = try originalAppearances.map(native)
        let form = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(document.catalog), "AcroForm"))
        XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(PDFCatalogStructurePreserver.array(form, "Fields"))), 66)
        for page in 0..<66 {
            let annotation = try XCTUnwrap(reader.page(at: page)?.annotations.first)
            XCTAssertEqual(reader.page(at: page)?.annotations.count, 1)
            XCTAssertEqual(annotation.fieldName, "field-\(page)-0")
            XCTAssertEqual(annotation.widgetStringValue, changed[page] ?? "value-\(page)-0")
            let raw = try rawWidget(document, page: page)
            XCTAssertNil(PDFCatalogStructurePreserver.object(raw, "DV"), "No page may gain a fallback DV during either save.")
            if let original {
                XCTAssertEqual(try appearance(raw), try appearance(rawWidget(original, page: page)), "Every unchanged source AP must survive the first save.")
            }
        }
        withExtendedLifetime((document, original)) {}
    }

    private func rawWidget(_ document: CGPDFDocument, page: Int) throws -> CGPDFDictionaryRef {
        let dictionary = try XCTUnwrap(document.page(at: page + 1)?.dictionary)
        let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
        XCTAssertEqual(CGPDFArrayGetCount(annotations), 1)
        var annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &annotation))
        return try XCTUnwrap(annotation)
    }

    private func appearance(_ annotation: CGPDFDictionaryRef) throws -> Data {
        let dictionary = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(annotation, "AP"))
        var stream: CGPDFStreamRef?
        var format = CGPDFDataFormat.raw
        XCTAssertTrue(CGPDFDictionaryGetStream(dictionary, "N", &stream))
        return try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(stream), &format)) as Data
    }

    private func raw(_ bytes: Data) throws -> PDFRawStreamSource {
        try XCTUnwrap(PDFRawStreamSource.created(native: native(bytes), data: bytes))
    }

    private func native(_ bytes: Data) throws -> CGPDFDocument {
        try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: bytes as CFData))))
    }

    private func fixture(widgetCounts: [Int], styleBytes: Int = 0, omitDefaults: Bool = false) -> Data {
        let appearance = "q 0.8 g 0 0 150 25 re f 0 g BT /SourceFont 12 Tf 3 7 Td (CUSTOM AP) Tj ET Q\n"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>", "", "",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 150 25] /Resources << /Font << /SourceFont 4 0 R >> >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream"
        ]
        var pages: [Int] = [], fields: [Int] = []
        let style = styleBytes == 0 ? "" : " /DS (" + String(repeating: "x", count: styleBytes) + ")"
        for (page, count) in widgetCounts.enumerated() {
            let pageID = objects.count + 1
            pages.append(pageID)
            let indexes = (0..<count).map { pageID + 1 + $0 }
            fields += indexes
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [\(indexes.map { "\($0) 0 R" }.joined(separator: " "))] >>")
            for index in 0..<count {
                let defaultEntry = omitDefaults ? "" : "/DV (default-\(page)-\(index))"
                objects.append("<< /Type /Annot /Subtype /Widget /FT /Tx /T (field-\(page)-\(index)) /V (value-\(page)-\(index)) \(defaultEntry) /Rect [30 100 180 125] /F 4 /DA (/SourceFont 12 Tf 0 g) /Q 1 /AP << /N 5 0 R >>\(style) >>")
            }
        }
        objects[1] = "<< /Type /Pages /Kids [\(pages.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>"
        objects[2] = "<< /Fields [\(fields.map { "\($0) 0 R" }.joined(separator: " "))] /DA (/SourceFont 12 Tf 0 g) /DR << /Font << /SourceFont 4 0 R >> >> /Q 1 >>"
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
