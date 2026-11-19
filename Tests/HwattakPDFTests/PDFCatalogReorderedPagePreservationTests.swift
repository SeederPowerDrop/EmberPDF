// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFCatalogReorderedPagePreservationTests: XCTestCase {
    func testRemovalBeforeFirstPreparationKeepsOriginalLabelTagAndPaintingIndexes() throws {
        let source = try fixture()
        source.removePage(at: 0)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
        let saved = try save(extracted)
        XCTAssertEqual(saved.page(at: 0)?.label, "p-2")
        XCTAssertEqual(saved.page(at: 1)?.label, "p-3")
        XCTAssertEqual(saved.findString("Second body", withOptions: []).count, 1)
        XCTAssertEqual(saved.findString("Third body", withOptions: []).count, 1)
        XCTAssertTrue(saved.findString("First body", withOptions: []).isEmpty)
        let plan = try PDFCatalogStructurePreserver.plan(for: extracted)
        let native = try XCTUnwrap(source.documentRef)
        try assertAlias(native.page(at: 2), output: 0, plan: plan)
        try assertAlias(native.page(at: 3), output: 1, plan: plan)
        XCTAssertNil(plan.aliases[try identity(native.page(at: 1))])
    }

    func testReorderThenBodyEditRefusesSavingUnprovenTagsAtTheNewIndex() throws {
        let source = try fixture()
        let last = try XCTUnwrap(source.page(at: 2))
        source.removePage(at: 2); source.insert(last, at: 0)
        try PDFCatalogStructurePreserver.prepare(source)
        let page = try XCTUnwrap(source.page(at: 0))
        let selected = try XCTUnwrap(source.findString("Third body", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
        let replacement = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Edited third", style: target.style, bounds: target.bounds)
        PDFCatalogStructurePreserver.inheritMetadata(from: page, to: replacement)
        source.removePage(at: 0); source.insert(replacement, at: 0)
        PDFCatalogStructurePreserver.refreshMarker(source)
        XCTAssertThrowsError(try save(source)) { error in
            XCTAssertEqual((error as? PDFCatalogStructurePreserver.EditedPageTagSaveFailure)?.pageNumber, 1)
        }
        XCTAssertEqual(source.findString("Edited third", withOptions: []).count, 1)
        XCTAssertTrue(source.findString("Third body", withOptions: []).isEmpty)
        XCTAssertEqual(source.findString("First body", withOptions: []).count, 1)
        XCTAssertEqual(source.findString("Second body", withOptions: []).count, 1)
        let plan = try PDFCatalogStructurePreserver.plan(for: source)
        XCTAssertNil(plan.paintingSources[0], "An edited page never borrows an old source painting.")
        XCTAssertNotNil(plan.paintingSources[1]); XCTAssertNotNil(plan.paintingSources[2])
        // A second preparation is idempotent for already-associated pages.
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        XCTAssertThrowsError(try save(source)) { error in
            XCTAssertEqual((error as? PDFCatalogStructurePreserver.EditedPageTagSaveFailure)?.pageNumber, 1)
        }
    }

    func testUnmatchedSyntheticPageNeverBorrowsMetadataByCurrentIndex() throws {
        let source = try fixture(), other = try fixture()
        let synthetic = try XCTUnwrap(other.page(at: 0)?.copy() as? PDFPage)
        source.insert(synthetic, at: 0)
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: source)
        XCTAssertNil(plan.paintingSources[0])
        for index in 1...3 { XCTAssertNotNil(plan.paintingSources[index]) }
        let native = try XCTUnwrap(source.documentRef)
        for index in 0..<3 { try assertAlias(native.page(at: index + 1), output: index + 1, plan: plan) }
    }

    private func save(_ document: PDFDocument) throws -> PDFDocument {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogReordered-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Output.pdf")
        try AtomicPDFWriter.write(document, to: url)
        return try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
    }
    private func identity(_ page: CGPDFPage?) throws -> UInt {
        pdfReferenceIdentity(try XCTUnwrap(page?.dictionary))
    }
    private func assertAlias(_ page: CGPDFPage?, output: Int, plan: PDFCatalogGraphPlan) throws {
        guard case .page(let actual)? = plan.aliases[try identity(page)] else { return XCTFail("Expected original native page alias") }
        XCTAssertEqual(actual, output)
    }
    private func fixture() throws -> PDFDocument {
        func stream(_ value: String) -> String {
            let content = "/P << /MCID 0 >> BDC BT /F1 14 Tf 20 100 Td (\(value)) Tj ET EMC"
            return "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels 6 0 R /StructTreeRoot 10 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 15 0 R >> >> /Contents 7 0 R /StructParents 0 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 15 0 R >> >> /Contents 8 0 R /StructParents 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 15 0 R >> >> /Contents 9 0 R /StructParents 2 >>",
            "<< /Nums [0 << /S /D /St 1 /P (p-) >>] >>", stream("First body"), stream("Second body"), stream("Third body"),
            "<< /Type /StructTreeRoot /K [11 0 R 12 0 R 13 0 R] /ParentTree 14 0 R >>",
            "<< /Type /StructElem /S /P /P 10 0 R /Pg 3 0 R /K 0 >>",
            "<< /Type /StructElem /S /P /P 10 0 R /Pg 4 0 R /K 0 >>",
            "<< /Type /StructElem /S /P /P 10 0 R /Pg 5 0 R /K 0 >>",
            "<< /Nums [0 [11 0 R] 1 [12 0 R] 2 [13 0 R]] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, value) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(value)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
