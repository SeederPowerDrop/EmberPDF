// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class RecoveryCatalogPreservationTests: XCTestCase {
    func testDetachedBackgroundRecoveryKeepsAssembledTagsLabelsAndAttachment() async throws {
        let assembled = try PDFPageOperations.extract(from: fixture(), indexes: [0, 1])
        XCTAssertTrue(PDFCatalogStructurePreserver.needsMaterialization(assembled))
        let snapshot = try PDFRecoverySnapshot(capturing: assembled)
        // The detached generation owns its catalog graph even after the live
        // document no longer contains either of the imported pages.
        assembled.removePage(at: 1)
        assembled.removePage(at: 0)
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PDFRecoveryStore(directory: folder)
        let generation = try await PDFRecoveryBackgroundWriter.stage(snapshot, store: store,
            id: UUID(), displayName: "Catalog.pdf")
        defer { store.discard(generation) }
        let saved = try XCTUnwrap(PDFDocument(url: generation.url))
        try assertCatalog(saved, labels: ["iv", "v"], taggedPages: [0, 1])
        XCTAssertEqual(saved.findString("Original body", withOptions: []).count, 1)
        XCTAssertEqual(saved.findString("Unchanged caption", withOptions: []).count, 1)
        XCTAssertTrue(store.records().isEmpty)
    }

    func testDataRecoveryRefusesReplacingTaggedPaintingWithoutOwnerProof() throws {
        let assembled = try PDFPageOperations.extract(from: fixture(), indexes: [0, 1])
        let page = try XCTUnwrap(assembled.page(at: 0))
        let selection = try XCTUnwrap(assembled.findString("Original body", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let replacement = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Edited body", style: target.style, bounds: target.bounds)
        PDFCatalogStructurePreserver.inheritMetadata(from: page, to: replacement)
        assembled.removePage(at: 0)
        assembled.insert(replacement, at: 0)
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let baselineURL = folder.appendingPathComponent("Direct-save.pdf")
        XCTAssertThrowsError(try AtomicPDFWriter.write(assembled, to: baselineURL)) { error in
            XCTAssertEqual((error as? PDFCatalogStructurePreserver.EditedPageTagSaveFailure)?.pageNumber, 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: baselineURL.path))
        let snapshot = try PDFRecoverySnapshot(capturing: assembled)
        assembled.removePage(at: 0)
        XCTAssertThrowsError(try snapshot.serializedData()) { error in
            XCTAssertEqual((error as? PDFCatalogStructurePreserver.EditedPageTagSaveFailure)?.pageNumber, 1)
        }
    }

    func testUnassembledCatalogIsNotMarkedForAnEmptyProvenancePlan() throws {
        let original = try fixture()
        XCTAssertTrue(PDFCatalogStructurePreserver.shouldPreserve(original))
        XCTAssertFalse(PDFCatalogStructurePreserver.needsMaterialization(original))
        let copy = try XCTUnwrap(original.copy() as? PDFDocument)
        PDFCatalogStructurePreserver.forward(from: original, to: copy)
        XCTAssertFalse(PDFCatalogStructurePreserver.needsMaterialization(copy),
            "A catalog alone does not mean a detached assembly plan exists.")
        let data = try PDFRecoverySnapshot(capturing: original).serializedData()
        let recovered = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(recovered.findString("Original body", withOptions: []).count, 1)
        XCTAssertEqual(recovered.findString("Unchanged caption", withOptions: []).count, 1)
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryCatalog-\(UUID())", isDirectory: true)
    }

    private func assertCatalog(_ document: PDFDocument, labels: [String], taggedPages: Set<Int>) throws {
        XCTAssertEqual(document.pageCount, labels.count)
        for (index, label) in labels.enumerated() { XCTAssertEqual(document.page(at: index)?.label, label) }
        let native = try XCTUnwrap(document.documentRef), catalog = try XCTUnwrap(native.catalog)
        var structure: CGPDFDictionaryRef?, names: CGPDFDictionaryRef?, embedded: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &structure))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "Names", &names))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(names), "EmbeddedFiles", &embedded))
        var files: CGPDFArrayRef?, spec: CGPDFDictionaryRef?, ef: CGPDFDictionaryRef?, payload: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(embedded), "Names", &files))
        XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(files)), 2)
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(files), 1, &spec))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(spec), "EF", &ef))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(ef), "F", &payload))
        var format = CGPDFDataFormat.raw
        XCTAssertEqual(try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(payload), &format)) as Data,
                       Data("Exact recovery attachment".utf8))
        let pageIdentities = try Dictionary(uniqueKeysWithValues: (0..<native.numberOfPages).map { index in
            (pdfReferenceIdentity(try XCTUnwrap(native.page(at: index + 1)?.dictionary)), index)
        })
        var referencedPages = Set<Int>()
        func visit(_ value: CGPDFObjectRef, depth: Int) throws {
            guard depth < 100 else { throw FixtureFailure.invalidGraph }
            if CGPDFObjectGetType(value) == .array {
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(value, .array, &array), let array else { throw FixtureFailure.invalidGraph }
                for index in 0..<CGPDFArrayGetCount(array) {
                    var child: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(array, index, &child), let child else { throw FixtureFailure.invalidGraph }
                    try visit(child, depth: depth + 1)
                }
            } else if CGPDFObjectGetType(value) == .dictionary {
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else { throw FixtureFailure.invalidGraph }
                var page: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Pg", &page), let page {
                    referencedPages.insert(try XCTUnwrap(pageIdentities[pdfReferenceIdentity(page)]))
                }
                if let kids = PDFCatalogStructurePreserver.object(dictionary, "K") { try visit(kids, depth: depth + 1) }
            }
        }
        try visit(try XCTUnwrap(PDFCatalogStructurePreserver.object(try XCTUnwrap(structure), "K")), depth: 0)
        XCTAssertEqual(referencedPages, taggedPages)
    }

    private func fixture() throws -> PDFDocument {
        func stream(_ content: String) -> String {
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        }
        let first = "/P << /MCID 0 >> BDC BT /F1 14 Tf 20 100 Td (Original body) Tj ET EMC"
        let second = "/P << /MCID 0 >> BDC BT /F1 14 Tf 20 100 Td (Unchanged caption) Tj ET EMC"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels 5 0 R /StructTreeRoot 8 0 R /MarkInfo << /Marked true >> /Names << /EmbeddedFiles 13 0 R >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 12 0 R >> >> /Contents 6 0 R /StructParents 0 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 12 0 R >> >> /Contents 7 0 R /StructParents 1 >>",
            "<< /Nums [0 << /S /r /St 4 >>] >>", stream(first), stream(second),
            "<< /Type /StructTreeRoot /K [9 0 R 10 0 R] /ParentTree 11 0 R >>",
            "<< /Type /StructElem /S /P /P 8 0 R /Pg 3 0 R /K 0 >>",
            "<< /Type /StructElem /S /P /P 8 0 R /Pg 4 0 R /K 0 >>",
            "<< /Nums [0 [9 0 R] 1 [10 0 R]] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Names [(recovery.txt) 14 0 R] >>",
            "<< /Type /Filespec /F (recovery.txt) /EF << /F 15 0 R >> >>",
            stream("Exact recovery attachment")
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private enum FixtureFailure: Error { case invalidGraph }
}
