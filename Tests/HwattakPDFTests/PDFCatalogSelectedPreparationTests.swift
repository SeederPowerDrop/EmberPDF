// SPDX-License-Identifier: MPL-2.0
// WORK-only proposed regression tests. Requires the selected-Origin WORK patch.
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFCatalogSelectedPreparationTests: XCTestCase {
    func testExplicitSelectionDoesNotCaptureUnselectedPageOriginsAndDefaultStillCapturesWholeDocument() async throws {
        let source = try fixture()
        let pages = try (0..<4).map { try XCTUnwrap(source.page(at: $0)) }
        XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(source))
        XCTAssertTrue(pages.allSatisfy { PDFCatalogStructurePreserver.relationshipSource(for: $0) == nil })
        try PDFCatalogStructurePreserver.prepare(source, force: true, pageIndexes: [3, 0, 3])
        XCTAssertNotNil(PDFCatalogStructurePreserver.relationshipSource(for: pages[0]))
        XCTAssertNotNil(PDFCatalogStructurePreserver.relationshipSource(for: pages[3]))
        XCTAssertNil(PDFCatalogStructurePreserver.relationshipSource(for: pages[1]))
        XCTAssertNil(PDFCatalogStructurePreserver.relationshipSource(for: pages[2]))
        // Default behavior remains authoritative for a later whole-document save.
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        XCTAssertTrue(pages.allSatisfy { PDFCatalogStructurePreserver.relationshipSource(for: $0) != nil })
        let saved = try await savedOnWorker(source, expectedPaintingIndexes: [0, 1, 2, 3])
        XCTAssertEqual(saved.pageCount, 4)
    }

    func testSeparatePartialImportsFromSameOriginalKeepOneAttachmentAndOneRoleNamespace() async throws {
        let source = try fixture()
        let first = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 2])
        XCTAssertNil(PDFCatalogStructurePreserver.relationshipSource(for: try XCTUnwrap(source.page(at: 1))))
        let second = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [1, 3])
        let output = PDFDocument()
        try PDFPageStructurePreserver.prepareMerge(imports: [first, second], into: output, at: 0).apply()
        let saved = try await savedOnWorker(output)
        XCTAssertEqual(saved.pageCount, 4)
        for (index, text) in ["First body", "Third body", "Second body", "Fourth body"].enumerated() {
            XCTAssertTrue(try XCTUnwrap(saved.page(at: index)?.string).contains(text))
        }
        let native = try XCTUnwrap(saved.documentRef), catalog = try XCTUnwrap(native.catalog)
        let roles = try dictionary(try dictionary(catalog, "StructTreeRoot"), "RoleMap")
        XCTAssertEqual(try keys(roles), ["EmberTag0_Custom"], "A later capture of the same native source must not create EmberTag1_.")
        let names = try dictionary(try dictionary(catalog, "Names"), "EmbeddedFiles")
        let list = try array(names, "Names")
        XCTAssertEqual(CGPDFArrayGetCount(list), 2, "The one original attachment must be imported once.")
        var rawName: CGPDFStringRef?
        XCTAssertTrue(CGPDFArrayGetString(list, 0, &rawName))
        XCTAssertEqual(CGPDFStringCopyTextString(try XCTUnwrap(rawName)).map { $0 as String }, "scope.txt")
        var spec: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 1, &spec))
        let ef = try dictionary(try XCTUnwrap(spec), "EF")
        var payload: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(ef, "F", &payload))
        var format = CGPDFDataFormat.raw
        XCTAssertEqual(try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(payload), &format)) as Data,
                       Data("single-original attachment".utf8))
        try assertLink(saved, page: 0, target: 1, point: CGPoint(x: 12, y: 145), zoom: 1.25)
        try assertLink(saved, page: 2, target: 3, point: CGPoint(x: 20, y: 130), zoom: 1.5)
        // The live source remains unchanged by both imports and the worker save.
        try assertLink(source, page: 0, target: 2, point: CGPoint(x: 12, y: 145), zoom: 1.25)
        try assertLink(source, page: 1, target: 3, point: CGPoint(x: 20, y: 130), zoom: 1.5)
    }

    func testLaterWholePreparationKeepsCurrentNotesLinksRotationAndOriginalPaintingAfterPageRefChanges() async throws {
        let source = try fixture()
        let selected = try XCTUnwrap(source.page(at: 0)), later = try XCTUnwrap(source.page(at: 1))
        let selectedReference = try XCTUnwrap(selected.pageRef)
        let originalPrograms = try (0..<4).map { try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(source.page(at: $0))) }
        try PDFCatalogStructurePreserver.prepare(source, force: true, pageIndexes: [0])
        XCTAssertNil(PDFCatalogStructurePreserver.relationshipSource(for: later))
        try note(on: selected).contents = "Selected current note"
        try note(on: later).contents = "Later current note"
        selected.rotation = 90; later.rotation = 270
        selected.setBounds(CGRect(x: 3, y: 4, width: 190, height: 188), for: .cropBox)
        try link(on: selected).destination = nil
        try link(on: selected).action = PDFActionGoTo(destination: PDFDestination(page: later, at: CGPoint(x: 22, y: 144)))
        try link(on: later).destination = nil
        try link(on: later).action = PDFActionGoTo(destination: PDFDestination(page: selected, at: CGPoint(x: 33, y: 133)))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let selectedOrigin = try XCTUnwrap(PDFCatalogStructurePreserver.relationshipSource(for: selected))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(selectedOrigin.page.dictionary)),
                       pdfReferenceIdentity(try XCTUnwrap(selectedReference.dictionary)),
                       "The selected origin remains bound to the captured original native page after current edits.")
        let saved = try await savedOnWorker(source, expectedPaintingIndexes: [0, 1, 2, 3])
        XCTAssertEqual(saved.page(at: 0)?.rotation, 90)
        XCTAssertEqual(saved.page(at: 1)?.rotation, 270)
        XCTAssertEqual(try XCTUnwrap(saved.page(at: 0)).bounds(for: .cropBox), selected.bounds(for: .cropBox))
        XCTAssertEqual(try note(on: XCTUnwrap(saved.page(at: 0))).contents, "Selected current note")
        XCTAssertEqual(try note(on: XCTUnwrap(saved.page(at: 1))).contents, "Later current note")
        try assertLink(saved, page: 0, target: 1, point: CGPoint(x: 22, y: 144), zoom: nil)
        try assertLink(saved, page: 1, target: 0, point: CGPoint(x: 33, y: 133), zoom: nil)
        for index in 0..<4 {
            // These input content streams are unfiltered. Exact decoded bytes
            // equal their original raw painting program, without a text heuristic.
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(saved.page(at: index))), originalPrograms[index])
        }
    }

    func testPartialThenWholePreparationDoesNotRestoreOldPaintingAfterLaterBodyReplacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SelectedBodyTransaction-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.pdf")
        try fixtureData().write(to: url, options: .withoutOverwriting)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        let source = try XCTUnwrap(workspace.document)
        try PDFCatalogStructurePreserver.prepare(source, force: true, pageIndexes: [0])
        XCTAssertNil(PDFCatalogStructurePreserver.relationshipSource(for: try XCTUnwrap(source.page(at: 1))))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let page = try XCTUnwrap(source.page(at: 1))
        let selection = try XCTUnwrap(source.findString("Second body", withOptions: []).first)
        // Use the actual body transaction: it replaces serialized annotation
        // copies with existing live identities and remaps current navigation.
        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection), workspace.presentedError ?? "Body editor did not start")
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.commitPendingInlineText(id: draft.id, text: "Edited second", style: draft.style, bounds: draft.bounds)
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertNil(workspace.presentedError)
        XCTAssertFalse(source.page(at: 1) === page)
        let saved = try await savedOnWorker(source, expectedPaintingIndexes: [0, 2, 3])
        XCTAssertEqual(saved.findString("Edited second", withOptions: []).count, 1)
        XCTAssertTrue(saved.findString("Second body", withOptions: []).isEmpty)
        XCTAssertEqual(saved.findString("First body", withOptions: []).count, 1)
        XCTAssertEqual(saved.findString("Third body", withOptions: []).count, 1)
    }

    private func savedOnWorker(_ document: PDFDocument, expectedPaintingIndexes: [Int]? = nil) async throws -> PDFDocument {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SelectedPreparation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("output.pdf")
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let paintingIndexes = try await Task.detached(priority: .userInitiated) {
            guard !Thread.isMainThread else { throw TestFailure.invalidGraph }
            let owned = try snapshot.takeDocument()
            // Text/Popup native baselines deliberately refuse SDK work on main.
            // Inspect only this worker-owned graph; return plain Sendable data.
            let indexes = try PDFCatalogStructurePreserver.plan(for: owned).paintingSources.keys.sorted()
            try AtomicPDFWriter.write(owned, to: url)
            return indexes
        }.value
        if let expectedPaintingIndexes { XCTAssertEqual(paintingIndexes, expectedPaintingIndexes) }
        return try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
    }
    private func note(on page: PDFPage) throws -> PDFAnnotation { try XCTUnwrap(page.annotations.first { $0.type == "Text" }) }
    private func link(on page: PDFPage) throws -> PDFAnnotation { try XCTUnwrap(page.annotations.first { $0.type == "Link" }) }
    private func assertLink(_ doc: PDFDocument, page: Int, target: Int, point: CGPoint, zoom: CGFloat?) throws {
        let annotation = try link(on: XCTUnwrap(doc.page(at: page)))
        let destination = try XCTUnwrap((annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination)
        XCTAssertTrue(destination.page === doc.page(at: target))
        XCTAssertEqual(destination.point.x, point.x, accuracy: 0.000001)
        XCTAssertEqual(destination.point.y, point.y, accuracy: 0.000001)
        if let zoom { XCTAssertEqual(destination.zoom, zoom, accuracy: 0.000001) }
    }
    private func dictionary(_ parent: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef {
        var value: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFDictionaryGetDictionary(parent, key, &value)); return try XCTUnwrap(value)
    }
    private func array(_ parent: CGPDFDictionaryRef, _ key: String) throws -> CGPDFArrayRef {
        var value: CGPDFArrayRef?; XCTAssertTrue(CGPDFDictionaryGetArray(parent, key, &value)); return try XCTUnwrap(value)
    }
    private func keys(_ dictionary: CGPDFDictionaryRef) throws -> [String] {
        guard CGPDFDictionaryGetCount(dictionary) <= 256 else { throw TestFailure.invalidGraph }
        var values: [String] = []
        CGPDFDictionaryApplyBlock(dictionary, { key, _, _ in values.append(String(cString: key)); return true }, nil)
        return values.sorted()
    }
    private func fixture() throws -> PDFDocument {
        let bytes = try fixtureData()
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(document, data: bytes)
        XCTAssertNotNil(PDFRawStreamProvenance.source(for: document))
        return document
    }
    private func fixtureData() throws -> Data {
        func stream(_ text: String) -> String { "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream" }
        func painting(_ text: String) -> String { stream("/Custom << /MCID 0 >> BDC BT /F1 14 Tf 20 100 Td (\(text)) Tj ET EMC") }
        func page(_ content: Int, _ parentIndex: Int, _ annotations: String = "") -> String {
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 17 0 R >> >> /Contents \(content) 0 R /StructParents \(parentIndex) \(annotations) >>"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Names << /Dests 14 0 R /EmbeddedFiles 15 0 R >> /StructTreeRoot 9 0 R /MarkInfo << /Marked true >> /Outlines 27 0 R /PageLabels 30 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 >>",
            page(7, 0, "/Annots [18 0 R 20 0 R]"), page(8, 1, "/Annots [19 0 R 21 0 R]"), page(22, 2), page(23, 3),
            painting("First body"), painting("Second body"),
            "<< /Type /StructTreeRoot /K [10 0 R 11 0 R 12 0 R 13 0 R] /ParentTree 24 0 R /RoleMap << /Custom /P >> >>",
            "<< /Type /StructElem /S /Custom /P 9 0 R /Pg 3 0 R /K 0 >>",
            "<< /Type /StructElem /S /Custom /P 9 0 R /Pg 4 0 R /K 0 >>",
            "<< /Type /StructElem /S /Custom /P 9 0 R /Pg 5 0 R /K 0 >>",
            "<< /Type /StructElem /S /Custom /P 9 0 R /Pg 6 0 R /K 0 >>",
            "<< /Names [(second) [5 0 R /XYZ 12 145 1.25] (third) [6 0 R /XYZ 20 130 1.5]] >>",
            "<< /Names [(scope.txt) 16 0 R] >>",
            "<< /Type /Filespec /F (scope.txt) /EF << /F 25 0 R >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 80 25] /Border [0 0 0] /Dest (second) >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 80 25] /Border [0 0 0] /Dest (third) >>",
            "<< /Type /Annot /Subtype /Text /Rect [150 150 165 165] /Contents (First note) >>",
            "<< /Type /Annot /Subtype /Text /Rect [150 150 165 165] /Contents (Second note) >>",
            painting("Third body"), painting("Fourth body"),
            "<< /Nums [0 [10 0 R] 1 [11 0 R] 2 [12 0 R] 3 [13 0 R]] >>",
            stream("single-original attachment"),
            "<< /Title (Selected preparation) /Author (Ember QE) >>",
            "<< /Type /Outlines /First 28 0 R /Last 29 0 R /Count 2 >>",
            "<< /Title (Second chapter) /Parent 27 0 R /Next 29 0 R /Dest (second) >>",
            "<< /Title (Third chapter) /Parent 27 0 R /Prev 28 0 R /Dest (third) >>",
            "<< /Nums [0 << /S /D /St 1 /P (capture-) >>] >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 26 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
    private enum TestFailure: Error { case invalidGraph }
}
