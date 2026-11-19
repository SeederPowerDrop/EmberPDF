// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// Exact-input authority controls, not a claimed reproduction of actual054 ULP drift.
@MainActor
final class PDFOriginalInkNumberTests: XCTestCase {
    func testExactDataFactoryWorkerSaveAndExtractionPreserveWholeOriginalInkProgram() async throws {
        let data = Self.fixture()
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0)), ink = try XCTUnwrap(page.annotations.first)
        let before = try PDFPageGeometryPreserver.liveAnnotation(ink)
        let original = try PDFPageGeometryPreserver.rawAnnotation(Self.annotation(XCTUnwrap(document.documentRef)))
        XCTAssertEqual(before, original, "Positive fixture must satisfy untouched baseline==original CG geometry.")
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(ink), before)
        let direct = try await writtenOnWorker(document)
        try Self.assertStored(direct, rectangle: [10, 20, 90, 100], ink: Self.originalInk)
        let extracted = try PDFPageOperations.extract(from: document, indexes: [0])
        let copied = try XCTUnwrap(extracted.page(at: 0)?.annotations.first)
        XCTAssertFalse(copied === ink)
        let extractedData = try await writtenOnWorker(extracted)
        try Self.assertStored(extractedData, rectangle: [10, 20, 90, 100], ink: Self.originalInk)
        XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(ink), before)
        XCTAssertEqual(ink.value(forAnnotationKey: .init(rawValue: "/NM")) as? String, Self.inkName)
        XCTAssertTrue(document.page(at: 0) === page)
    }

    func testGuardedFileColdWorkerSavePreservesOriginalNumbersAndInputVersion() async throws {
        let input = temporaryURL()
        let data = Self.fixture()
        try data.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let loaded = try PDFSourceFileAccess.loadDocument(at: input)
        let originalInk = try XCTUnwrap(loaded.document.page(at: 0)?.annotations.first)
        let before = try PDFPageGeometryPreserver.liveAnnotation(originalInk)
        let original = try PDFPageGeometryPreserver.rawAnnotation(Self.annotation(XCTUnwrap(loaded.document.documentRef)))
        XCTAssertEqual(before, original, "Positive guarded fixture must satisfy untouched baseline==original.")
        try PDFCatalogStructurePreserver.prepare(loaded.document, force: true)
        XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(originalInk), before)
        let extracted = try PDFPageOperations.extract(from: loaded.document, indexes: [0])
        // No original numeric reader/observer is warmed before this production save.
        let output = try await writtenOnWorker(extracted)
        try Self.assertStored(output, rectangle: [10, 20, 90, 100], ink: Self.originalInk)
        XCTAssertEqual(try Data(contentsOf: input), data)
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: input), loaded.version)
        XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(originalInk), before)
        XCTAssertEqual(PDFDocument(data: output)?.pageCount, 1)
    }

    func testIntentionalFactoryInkEditWinsOverWholeOriginalNumericView() async throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        let annotation = try XCTUnwrap(document.page(at: 0)?.annotations.first)
        let baseline = try PDFPageGeometryPreserver.liveAnnotation(annotation)
        for path in try XCTUnwrap(annotation.paths) { annotation.remove(path) }
        annotation.bounds = CGRect(x: 100.125, y: 120.25, width: 64.5, height: 60.5)
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: CGPoint(x: 20.125, y: 40.25))
        path.line(to: CGPoint(x: 64.5, y: 60.5))
        annotation.add(path)
        let intended = try PDFPageGeometryPreserver.liveAnnotation(annotation)
        XCTAssertNotEqual(intended, baseline, "This must be an observable edit after origin capture.")
        let output = try await writtenOnWorker(document)
        try Self.assertStored(output, rectangle: [100.125, 120.25, 164.625, 180.75],
                              ink: [100.125, 120.25, 120.25, 160.5, 164.625, 180.75])
        XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(annotation), intended)
        XCTAssertEqual(annotation.value(forAnnotationKey: .init(rawValue: "/NM")) as? String, Self.inkName)
    }

    func testGenericRebindAndForeignNativeSlotCannotAcquireOriginalInkAuthority() async throws {
        let a = Self.fixture(), b = Self.fixture(first: "54.150000000000000")
        let document = try XCTUnwrap(PDFDocument(data: a))
        PDFRawStreamProvenance.bindCreated(document, data: b)
        let generic = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let owner = try XCTUnwrap(document.documentRef), annotation = try Self.annotation(owner)
        let exact = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: a))
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: exact))
        let exactOwner = try XCTUnwrap(exact.documentRef), exactAnnotation = try Self.annotation(exactOwner)
        let foreign = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: a as CFData))))
        let foreignAnnotation = try Self.annotation(foreign)
        try await Task.detached {
            var budget = PDFInkGeometryWorkBudget()
            XCTAssertNil(try generic.originalInkGeometry(in: owner, pageIndex: 0, annotationIndex: 0,
                annotation: annotation, budget: &budget), "A generic nativeA/dataB binding has no numeric authority.")
            XCTAssertEqual(generic.widgetInputFootprint.storage, "ownedOriginalBytes")
            XCTAssertNil(try source.originalInkGeometry(in: foreign, pageIndex: 0, annotationIndex: 0,
                annotation: foreignAnnotation, budget: &budget))
            XCTAssertNil(try source.originalInkGeometry(in: exactOwner, pageIndex: 0, annotationIndex: 0,
                annotation: foreignAnnotation, budget: &budget), "Even the right owner cannot authorize a foreign dictionary.")
            XCTAssertNil(try source.originalInkGeometry(in: exactOwner, pageIndex: 0, annotationIndex: 1,
                annotation: exactAnnotation, budget: &budget))
            XCTAssertEqual(source.widgetInputFootprint.storage, "ownedOriginalBytes", "Foreign checks precede context/input consumption.")
            let result = try XCTUnwrap(source.originalInkGeometry(in: exactOwner, pageIndex: 0, annotationIndex: 0,
                annotation: exactAnnotation, budget: &budget))
            XCTAssertEqual(Self.values(try XCTUnwrap(result.coordinates["InkList"])).map(\.bitPattern), Self.originalInk.map(\.bitPattern))
        }.value
    }

    func testColdMainAndForeignWorkerDoNotReadOrConsumeOriginalFile() async throws {
        let input = temporaryURL(), data = Self.fixture()
        try data.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let document = try PDFSourceFileAccess.loadDocument(at: input).document
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let owner = try XCTUnwrap(document.documentRef), annotation = try Self.annotation(owner)
        let foreign = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
        let other = try Self.annotation(foreign)
        try FileManager.default.removeItem(at: input)
        var budget = PDFInkGeometryWorkBudget()
        XCTAssertNil(try source.originalInkGeometry(in: owner, pageIndex: 0, annotationIndex: 0,
            annotation: annotation, budget: &budget))
        XCTAssertEqual(source.widgetInputFootprint.storage, "versionGuardedFile")
        try await Task.detached {
            var budget = PDFInkGeometryWorkBudget()
            XCTAssertNil(try source.originalInkGeometry(in: owner, pageIndex: 0, annotationIndex: 0,
                annotation: other, budget: &budget))
            XCTAssertEqual(source.widgetInputFootprint.storage, "versionGuardedFile")
        }.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
    }

    func testCancellationBudgetAndChangedFileAreFailClosedAndRetryableWhereSafe() async throws {
        let data = Self.fixture()
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let owner = try XCTUnwrap(document.documentRef), annotation = try Self.annotation(owner)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        try await Task.detached {
            var budget = PDFInkGeometryWorkBudget()
            XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
                try source.originalInkGeometry(in: owner, pageIndex: 0, annotationIndex: 0,
                    annotation: annotation, budget: &budget)
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(source.widgetInputFootprint.storage, "ownedOriginalBytes")
            var small = PDFInkGeometryWorkBudget(numbers: 1)
            XCTAssertNil(try source.originalInkGeometry(in: owner, pageIndex: 0, annotationIndex: 0,
                annotation: annotation, budget: &small))
            XCTAssertEqual(small.remainingNumbers, 0)
            XCTAssertLessThan(small.remainingBytes, 8 * 1_024 * 1_024, "Failed attempts keep their work charge.")
            let charged = small.remainingBytes
            XCTAssertNil(try source.originalInkGeometry(in: owner, pageIndex: 0, annotationIndex: 0,
                annotation: annotation, budget: &small))
            XCTAssertEqual(small.remainingBytes, charged)
            let readsBeforeRetry = source.originalInkCacheFootprint.readerCalls
            var retry = PDFInkGeometryWorkBudget()
            let coldBefore = retry
            XCTAssertNotNil(try source.originalInkGeometry(in: owner, pageIndex: 0, annotationIndex: 0,
                annotation: annotation, budget: &retry), "A capacity/cancellation refusal never poisons later coverage.")
            let coldCost = [coldBefore.remainingBytes - retry.remainingBytes,
                            coldBefore.remainingNumbers - retry.remainingNumbers,
                            coldBefore.remainingVisits - retry.remainingVisits]
            let first = source.originalInkCacheFootprint
            XCTAssertEqual(first.entries, 1)
            XCTAssertEqual(first.readerCalls - readsBeforeRetry, 1)
            XCTAssertFalse(first.capacityReached)
            // Repeated saves of an authorized program must never allocate C
            // scalar handles again, even though each operation pays full scope.
            for _ in 0..<256 {
                var warm = PDFInkGeometryWorkBudget()
                let warmBefore = warm
                XCTAssertNotNil(try source.originalInkGeometry(in: owner, pageIndex: 0, annotationIndex: 0,
                    annotation: annotation, budget: &warm))
                XCTAssertEqual([warmBefore.remainingBytes - warm.remainingBytes,
                                warmBefore.remainingNumbers - warm.remainingNumbers,
                                warmBefore.remainingVisits - warm.remainingVisits], coldCost)
            }
            let after = source.originalInkCacheFootprint
            XCTAssertEqual(after.entries, 1)
            XCTAssertEqual(after.readerCalls, first.readerCalls)
            XCTAssertEqual(after.cacheHits - first.cacheHits, 256)
            XCTAssertEqual(after.accountedBytes, first.accountedBytes)
            XCTAssertLessThanOrEqual(after.accountedBytes, 8 * 1_024 * 1_024)
        }.value
        let input = temporaryURL()
        try data.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let loaded = try PDFSourceFileAccess.loadDocument(at: input).document
        let oldSource = try XCTUnwrap(PDFRawStreamProvenance.source(for: loaded))
        let oldOwner = try XCTUnwrap(loaded.documentRef), oldAnnotation = try Self.annotation(oldOwner)
        let replacement = Self.fixture(first: "54.150000000000000")
        try replacement.write(to: input, options: .atomic)
        try await Task.detached {
            var budget = PDFInkGeometryWorkBudget()
            XCTAssertNil(try oldSource.originalInkGeometry(in: oldOwner, pageIndex: 0, annotationIndex: 0,
                annotation: oldAnnotation, budget: &budget))
        }.value
        XCTAssertEqual(try Data(contentsOf: input), replacement, "The proof reader never rewrites a changed input.")
    }

    private func writtenOnWorker(_ document: PDFDocument) async throws -> Data {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: output) }
        return try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: output)
            return try Data(contentsOf: output)
        }.value
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-OriginalInk-\(UUID()).pdf")
    }
    nonisolated private static var inkName: String { "Original-ink-number-authority" }
    nonisolated private static var originalInk: [Double] { [53.9, 44.8, 62.4, 74.2, 77.1, 35.6] }
    nonisolated private static func values(_ value: PDFPageGeometryPreserver.Numbers) -> [Double] {
        switch value { case .value(let number): return [number]; case .array(let list): return list.flatMap(values) }
    }
    nonisolated private static func annotation(_ owner: CGPDFDocument) throws -> CGPDFDictionaryRef {
        let page = try XCTUnwrap(owner.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        var result: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &result))
        return try XCTUnwrap(result)
    }
    nonisolated private static func assertStored(_ data: Data, rectangle: [Double], ink: [Double],
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        let stored = try InkNameRoundingTestFixture.stored(data)
        XCTAssertEqual(stored.name, Data(inkName.utf8), file: file, line: line)
        XCTAssertEqual(stored.ink.map(\.bitPattern), ink.map(\.bitPattern), file: file, line: line)
        let owner = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
        let raw = try PDFPageGeometryPreserver.rawAnnotation(annotation(owner))
        // Rect test inputs are binary-exact. Ink is checked independently by C.
        XCTAssertEqual(raw.rectangle.map(\.bitPattern), rectangle.map(\.bitPattern), file: file, line: line)
    }
    nonisolated private static func fixture(first: String = "53.9") -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R /Annots [5 0 R] >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Annot /Subtype /Ink /Rect [10 20 90 100] /InkList [[\(first) 44.8 62.4 74.2 77.1 35.6]] /C [1 0 0] /BS << /W 1 >> /NM (\(inkName)) >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, value) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(value)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
