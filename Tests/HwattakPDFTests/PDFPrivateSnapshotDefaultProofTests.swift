// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFPrivateSnapshotDefaultProofTests: XCTestCase {
    func testSeventyTwoPrivateSnapshotPagesKeepAbsentAndNullDefaultsThroughMainSearchableExport() throws {
        XCTAssertTrue(Thread.isMainThread)
        let bytes = fixture(pageCount: 72)
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("private-snapshot.pdf")
        let destination = folder.appendingPathComponent("searchable.pdf")
        try bytes.write(to: source)
        let document = try PDFCatalogStructurePreserver.loadPrivateSearchableSnapshot(at: source)
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        XCTAssertEqual(document.pageCount, 72)
        for index in 0..<72 {
            let annotation = try widget(document, page: index)
            let baseline = try XCTUnwrap(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: annotation), "page \(index)")
            XCTAssertEqual(baseline.matches(annotation), true, "page \(index)")
        }
        let first = try widget(document, page: 0)
        XCTAssertNotNil(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: first),
                        "An initial proof must survive visiting more than the ordinary 64-page working set.")
        XCTAssertEqual(raw.widgetStateCacheFootprint.pages, 0)
        XCTAssertEqual(raw.widgetStateCacheFootprint.encodedBytes, 0)

        try SearchablePDFExporter.export(document: document, checkpoint: skippedCheckpoint(pageCount: 72),
                                         to: destination, sourceURL: source, renderDPI: 72)

        XCTAssertTrue(Thread.isMainThread, "The synchronous Main API remains exercised as before.")
        try assertRawWidgets(Data(contentsOf: destination), pageCount: 72)
        try assertRawWidgets(bytes, pageCount: 72)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(raw.widgetStateCacheFootprint.pages, 0,
                       "Private initial witnesses do not prewarm the ordinary independent-reader LRU on Main.")
        XCTAssertEqual(raw.widgetStateCacheFootprint.refusedPages, 0)
    }

    func testDefaultEditAfterPrivateInitialObservationWinsOverOriginalAbsenceOrNull() throws {
        let bytes = fixture(pageCount: 2)
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("private-snapshot.pdf")
        let destination = folder.appendingPathComponent("edited.pdf")
        try bytes.write(to: source)
        let document = try PDFCatalogStructurePreserver.loadPrivateSearchableSnapshot(at: source)
        for index in 0..<2 {
            let annotation = try widget(document, page: index)
            let baseline = try XCTUnwrap(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: annotation))
            XCTAssertEqual(baseline.matches(annotation), true)
            annotation.widgetDefaultStringValue = "Edited default \(index)"
            XCTAssertEqual(baseline.matches(annotation), false, "The setter must make an observable current edit.")
            let retained = try XCTUnwrap(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: annotation))
            XCTAssertEqual(retained.matches(annotation), false, "The factory must not rebase its initial proof after an edit.")
        }

        try AtomicPDFWriter.write(document, to: destination)

        try assertRawWidgets(Data(contentsOf: destination), pageCount: 2,
                             editedDefaults: [0: "Edited default 0", 1: "Edited default 1"])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testReplacementWidgetWithSameGeometryAndValuesCannotBorrowAbsentDefaultProof() throws {
        let bytes = fixture(pageCount: 1)
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("private-snapshot.pdf")
        let destination = folder.appendingPathComponent("existing.pdf")
        let previousDestination = Data("Preserve this destination on safe refusal".utf8)
        try bytes.write(to: source)
        try previousDestination.write(to: destination)
        let document = try PDFCatalogStructurePreserver.loadPrivateSearchableSnapshot(at: source)
        let page = try XCTUnwrap(document.page(at: 0))
        let original = try widget(document, page: 0)
        XCTAssertNotNil(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: original))
        let replacement = PDFAnnotation(bounds: original.bounds, forType: .widget, withProperties: nil)
        replacement.widgetFieldType = .text
        replacement.fieldName = original.fieldName
        replacement.widgetStringValue = original.widgetStringValue
        replacement.widgetDefaultStringValue = original.widgetStringValue
        XCTAssertEqual(replacement.bounds, original.bounds)
        XCTAssertEqual(replacement.fieldName, original.fieldName)
        XCTAssertEqual(replacement.widgetStringValue, original.widgetStringValue)
        XCTAssertEqual(replacement.widgetDefaultStringValue, original.widgetStringValue)
        XCTAssertTrue(replacement.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV")) is String,
                      "This new object explicitly stores a default equal to V; raw source absence must not erase it.")
        page.removeAnnotation(original)
        page.addAnnotation(replacement)
        XCTAssertTrue(page.annotations.first === replacement)
        XCTAssertNil(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: replacement))

        do {
            try AtomicPDFWriter.write(document, to: destination)
            try assertRawWidgets(Data(contentsOf: destination), pageCount: 1,
                                 editedDefaults: [0: "value-0"])
        } catch {
            if !(error is PDFPageStructurePreserver.Failure) {
                guard case .operationFailed = error as? WorkspaceError else {
                    return XCTFail("Only an intentional preservation refusal is acceptable: \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: destination), previousDestination)
        }
        XCTAssertNil(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: replacement))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testCancelledPrivateSearchableExportKeepsDestinationSourceAndOrdinaryCache() async throws {
        let bytes = fixture(pageCount: 2)
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("private-snapshot.pdf")
        let destination = folder.appendingPathComponent("existing.pdf")
        let previousDestination = Data("Unchanged existing destination".utf8)
        try bytes.write(to: source)
        try previousDestination.write(to: destination)
        let normal = try PDFSourceFileAccess.loadDocument(at: source).document
        let normalRaw = try XCTUnwrap(PDFRawStreamProvenance.source(for: normal))
        let count = try await Task.detached { try normalRaw.originalWidgetDefaultStates(onPage: 0)?.count }.value
        XCTAssertEqual(count, 1)
        let cacheBefore = normalRaw.widgetStateCacheFootprint
        let inputBefore = normalRaw.widgetInputFootprint
        XCTAssertNil(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: try widget(normal, page: 0)),
                     "The same file's ordinary reader cannot borrow another private factory's initial authority.")
        let document = try PDFCatalogStructurePreserver.loadPrivateSearchableSnapshot(at: source)
        let annotation = try widget(document, page: 0)
        XCTAssertNotNil(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: annotation))
        let privateRaw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let temporary = FileManager.default.temporaryDirectory
        let stagingBefore = try stagingFolders(in: temporary)
        let cancellation = PDFSaveCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
            try SearchablePDFExporter.export(document: document, checkpoint: skippedCheckpoint(pageCount: 2),
                                             to: destination, sourceURL: source, renderDPI: 72)
        }) { XCTAssertTrue($0 is CancellationError) }

        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: destination), previousDestination)
        XCTAssertEqual(try stagingFolders(in: temporary), stagingBefore)
        let cacheAfter = normalRaw.widgetStateCacheFootprint
        XCTAssertEqual(cacheAfter.pages, cacheBefore.pages)
        XCTAssertEqual(cacheAfter.encodedBytes, cacheBefore.encodedBytes)
        XCTAssertEqual(cacheAfter.refusedPages, cacheBefore.refusedPages)
        XCTAssertEqual(normalRaw.widgetInputFootprint.storage, inputBefore.storage)
        XCTAssertEqual(normalRaw.widgetInputFootprint.ownedDataBytes, inputBefore.ownedDataBytes)
        XCTAssertEqual(privateRaw.widgetStateCacheFootprint.pages, 0)
        XCTAssertEqual(privateRaw.widgetStateCacheFootprint.refusedPages, 0)
    }

    func testMalformedFingerprintContainersAreRefusedBeforePrivateDefaultCapture() throws {
        let folder = try temporaryFolder()
        for onWidget in [true, false] {
            for key in ["NM", "StructParent"] {
                let validToken = key == "NM" ? "(valid-identifier)" : "3"
                let controlURL = folder.appendingPathComponent("control-\(onWidget)-\(key).pdf")
                try fingerprintFixture(key: key, token: validToken, onWidget: onWidget).write(to: controlURL)
                let control = try PDFCatalogStructurePreserver.loadPrivateSearchableSnapshot(at: controlURL)
                let field = try XCTUnwrap(control.page(at: 0)?.annotations.first(where: { $0.type == "Widget" }))
                XCTAssertNotNil(PDFCatalogStructurePreserver.privateSnapshotDefaultBaseline(for: field),
                                "A valid scalar \(key) on widget=\(onWidget) must remain supported.")
                for (label, token) in [("dictionary", "<< /Nested [1 2 3] >>"), ("array", "[1 2 3]")] {
                    let bytes = fingerprintFixture(key: key, token: token, onWidget: onWidget)
                    let source = folder.appendingPathComponent("malformed-\(onWidget)-\(key)-\(label).pdf")
                    try bytes.write(to: source)
                    XCTAssertThrowsError(try PDFCatalogStructurePreserver.loadPrivateSearchableSnapshot(at: source)) { error in
                        guard case PDFPageStructurePreserver.Failure.unsupportedStructure = error else {
                            return XCTFail("Expected preflight type refusal for \(key)/\(label), received \(error)")
                        }
                    }
                    XCTAssertEqual(try Data(contentsOf: source), bytes)
                }
            }
        }
    }

    func testSharedFieldKidsReferencesConsumeActualEdgeBudgetBeforeDefaultCapture() throws {
        let parentCount = 600, childCount = 600
        let uniqueFields = 1 + parentCount + childCount
        let maximumPending = parentCount + childCount
        let actualEnqueues = 1 + parentCount + parentCount * childCount
        XCTAssertLessThan(uniqueFields, 100_000)
        XCTAssertLessThan(maximumPending, 100_000)
        XCTAssertGreaterThan(actualEnqueues, 250_000,
                             "Shared references exceed the actual-edge bound while unique nodes and queue remain small.")
        let bytes = sharedFieldsFixture(parentCount: parentCount, childCount: childCount)
        XCTAssertLessThan(bytes.count, 256 * 1_024, "The regression uses one compact shared Kids array, not a huge PDF.")
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("shared-field-edges.pdf")
        try bytes.write(to: source)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.loadPrivateSearchableSnapshot(at: source)) { error in
            guard case PDFPageStructurePreserver.Failure.tooComplex = error else {
                return XCTFail("Actual traversal work must be bounded before capture, received \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-private-default-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func stagingFolders(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("HwattakPDF-OCRExport-") })
    }

    private func widget(_ document: PDFDocument, page: Int) throws -> PDFAnnotation {
        let annotations = try XCTUnwrap(document.page(at: page)).annotations
        XCTAssertEqual(annotations.count, 1)
        let annotation = try XCTUnwrap(annotations.first)
        XCTAssertEqual(annotation.type, "Widget")
        return annotation
    }

    private func skippedCheckpoint(pageCount: Int) -> OCRCheckpoint {
        var checkpoint = OCRCheckpoint(documentFingerprint: "private-default-proof", pageCount: pageCount,
                                       configurationFingerprint: "skipped-only")
        for index in 0..<pageCount {
            checkpoint.pages[index] = OCRPageResult(pageIndex: index, text: "", observations: [],
                completedAt: Date(), skippedBecauseTextExists: true)
        }
        return checkpoint
    }

    private func assertRawWidgets(_ bytes: Data, pageCount: Int, editedDefaults: [Int: String] = [:]) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, pageCount)
        let reader = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertEqual(reader.pageCount, pageCount)
        for index in 0..<pageCount {
            let dictionary = try XCTUnwrap(document.page(at: index + 1)?.dictionary)
            let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
            XCTAssertEqual(CGPDFArrayGetCount(annotations), 1, "page \(index)")
            var annotation: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &annotation))
            let raw = try XCTUnwrap(annotation)
            XCTAssertEqual(try nativeString(raw, "V"), "value-\(index)", "page \(index)")
            XCTAssertEqual(reader.page(at: index)?.annotations.first?.widgetStringValue, "value-\(index)")
            let value = PDFCatalogStructurePreserver.object(raw, "DV")
            if let edited = editedDefaults[index] {
                XCTAssertEqual(value.map(CGPDFObjectGetType), .string, "page \(index)")
                XCTAssertEqual(try nativeString(raw, "DV"), edited)
            } else if index.isMultiple(of: 2) {
                XCTAssertNil(value, "An originally absent DV must remain absent on page \(index).")
            } else {
                XCTAssertEqual(value.map(CGPDFObjectGetType), .null,
                               "An original explicit null must remain null on page \(index).")
            }
        }
        withExtendedLifetime(document) {}
    }

    private func nativeString(_ dictionary: CGPDFDictionaryRef, _ key: String) throws -> String {
        var value: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(dictionary, key, &value))
        return try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(value)) as String?)
    }

    private func fingerprintFixture(key: String, token: String, onWidget: Bool) -> Data {
        let extra = "/\(key) \(token)"
        return encodeObjects([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>",
            "<< /Type /Pages /Kids [4 0 R] /Count 1 >>",
            "<< /Fields [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [5 0 R 6 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (field-0) /V (value-0) /Rect [30 100 180 125] \(onWidget ? extra : "") >>",
            "<< /Type /Annot /Subtype /Square /Rect [10 10 30 30] \(onWidget ? "" : extra) >>"
        ])
    }

    private func sharedFieldsFixture(parentCount: Int, childCount: Int) -> Data {
        // Object6 is shared by every parent. Children are distinct native
        // objects, each reached again from all later parents after visitation.
        let firstParent = 7, firstChild = firstParent + parentCount
        let parents = (0..<parentCount).map { "\(firstParent + $0) 0 R" }.joined(separator: " ")
        let children = (0..<childCount).map { "\(firstChild + $0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>",
            "<< /Type /Pages /Kids [4 0 R] /Count 1 >>",
            "<< /Fields [5 0 R \(parents)] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [5 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (target) /V (value) /Rect [30 100 180 125] >>",
            "[\(children)]"
        ]
        objects += (0..<parentCount).map { "<< /T (parent-\($0)) /Kids 6 0 R >>" }
        objects += (0..<childCount).map { "<< /FT /Tx /T (leaf-\($0)) /V (leaf-value-\($0)) >>" }
        return encodeObjects(objects)
    }

    private func encodeObjects(_ objects: [String]) -> Data {
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

    private func fixture(pageCount: Int) -> Data {
        let appearance = "q 0.85 g 0 0 150 25 re f 0 g BT /SourceFont 12 Tf 3 7 Td (SOURCE AP) Tj ET Q\n"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>", "", "",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 150 25] /Resources << /Font << /SourceFont 4 0 R >> >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream"
        ]
        var pages: [Int] = [], fields: [Int] = []
        for index in 0..<pageCount {
            let page = objects.count + 1, field = page + 1
            pages.append(page); fields.append(field)
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [\(field) 0 R] >>")
            let defaultEntry = index.isMultiple(of: 2) ? "" : "/DV null"
            objects.append("<< /Type /Annot /Subtype /Widget /FT /Tx /T (field-\(index)) /V (value-\(index)) \(defaultEntry) /Rect [30 100 180 125] /F 4 /DA (/SourceFont 12 Tf 0 g) /Q 1 /AP << /N 5 0 R >> >>")
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
