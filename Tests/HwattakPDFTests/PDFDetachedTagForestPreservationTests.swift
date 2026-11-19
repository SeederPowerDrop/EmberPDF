// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFDetachedTagForestPreservationTests: XCTestCase {
    func testFactoryBoundDetachedForestKeepsAbsentParentAndNoRootEdgeAcrossWorkerSaves() async throws {
        let sourceBytes = fixture(), source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: sourceBytes))
        let sourcePage = try XCTUnwrap(source.page(at: 0)), originalPaint = try PDFBodyTextPageSnapshot.contentData(for: sourcePage)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let changed = try XCTUnwrap(extracted.page(at: 0)?.annotations.first)
        changed.contents = "current user link label"
        changed.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://current.example/edited")))
        let plan = try PDFCatalogStructurePreserver.plan(for: extracted)
        try assertPlanForest(plan, rootChildCount: 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DetachedTagForest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.pdf")
        let first = try await savedOnWorker(extracted, at: firstURL)
        try assertSavedForest(first, rootChildCount: 1, annotationCount: 2)
        XCTAssertEqual(first.page(at: 0)?.annotations.first?.contents, "current user link label")
        XCTAssertEqual((first.page(at: 0)?.annotations.first?.action as? PDFActionURL)?.url?.absoluteString, "https://current.example/edited")
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(first.page(at: 0))), originalPaint)
        let reopened = try PDFSourceFileAccess.loadDocument(at: firstURL).document
        let second = try await savedOnWorker(PDFPageOperations.extract(from: reopened, indexes: [0]), at: directory.appendingPathComponent("second.pdf"))
        try assertSavedForest(second, rootChildCount: 1, annotationCount: 2)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(second.page(at: 0))), originalPaint)
        let merged = try blankAnchor()
        let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: [0])
        let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 1)
        try transaction.apply(); try transaction.undo(); XCTAssertEqual(merged.pageCount, 1); try transaction.redo()
        let savedMerge = try await savedOnWorker(merged, at: directory.appendingPathComponent("merged.pdf"))
        try assertSavedForest(savedMerge, rootChildCount: 1, annotationCount: 2, pageIndex: 1)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(savedMerge.page(at: 1))), originalPaint)
        XCTAssertEqual(sourcePage.annotations.first?.contents, nil)
        XCTAssertEqual((sourcePage.annotations.first?.action as? PDFActionURL)?.url?.absoluteString, "https://original.example/one")
        let originalRoot = try nativeDictionary(source, objectKey: "StructTreeRoot")
        let originalTree = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(originalRoot, "ParentTree"))
        let originalNums = try XCTUnwrap(PDFCatalogStructurePreserver.array(originalTree, "Nums"))
        var originalOwner: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(originalNums, 1, &originalOwner))
        let originalTop = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(originalOwner), "P"))
        XCTAssertNil(PDFCatalogStructurePreserver.object(originalTop, "P"))
    }

    func testRemovedSharedOwnerTargetCannotBeResurrected() throws {
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0]), page = try XCTUnwrap(extracted.page(at: 0))
        page.removeAnnotation(try XCTUnwrap(page.annotations.first))
        let plan = try PDFCatalogStructurePreserver.plan(for: extracted)
        XCTAssertEqual(page.annotations.count, 1)
        let root = try node(plan.catalogEntries["StructTreeRoot"]), nums = try values(dictionary(root.entries["ParentTree"])["Nums"])
        XCTAssertEqual(nums.count, 2)
        let owner = try node(nums[1]), kids = try values(owner.entries["K"])
        XCTAssertEqual(kids.count, 1)
        let objr = try dictionary(kids[0])
        guard case .annotation(page: 0, index: 0)? = objr["Obj"] else { return XCTFail("Only the surviving current target may remain.") }
        page.removeAnnotation(try XCTUnwrap(page.annotations.first))
        let empty = try PDFCatalogStructurePreserver.plan(for: extracted)
        XCTAssertNil(try node(empty.catalogEntries["StructTreeRoot"]).entries["ParentTree"])
        XCTAssertTrue((empty.annotationEntries[0] ?? [:]).isEmpty)
    }

    func testUnboundFactoryAndForgedCurrentOriginCannotImportForest() throws {
        let bytes = fixture(), plain = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(plain, data: bytes)
        let unbound = try PDFPageOperations.extract(from: plain, indexes: [0])
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: unbound))
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let foreign = try XCTUnwrap(PDFDocument(data: bytes)), foreignPage = try XCTUnwrap(foreign.page(at: 0))
        let group = PDFCatalogSourceGroup(document: try XCTUnwrap(source.documentRef),
            pages: [PDFCatalogPageOrigin(sourceIndex: 0, outputIndex: 0, livePage: foreignPage, annotationIndexes: [0: 0, 1: 1])],
            rawStreamSource: try XCTUnwrap(PDFRawStreamProvenance.source(for: source)))
        var plan = PDFCatalogGraphPlan(); plan.catalogEntries["Sentinel"] = .integer(7)
        XCTAssertThrowsError(try PDFTaggedStructurePreserver.addPreservedTags(from: [group], to: &plan))
        XCTAssertEqual(plan.catalogEntries.count, 1); XCTAssertTrue(plan.aliases.isEmpty)
    }

    func testMalformedParentMembershipCycleNullAndWrongOBJRRemainRefused() throws {
        let variants: [(String, String, String)] = [
            ("/P null", "[7 0 R]", "4 0 R"),
            ("/P 42", "[7 0 R]", "4 0 R"),
            ("/P 6 0 R", "[7 0 R]", "4 0 R"),
            ("/P 7 0 R", "[7 0 R]", "4 0 R"),
            ("", "[]", "4 0 R"),
            ("", "[7 0 R 7 0 R]", "4 0 R"),
            ("", "[7 0 R 12 0 R]", "4 0 R"),
            ("", "[7 0 R]", "5 0 R")
        ]
        for (topP, topK, firstTarget) in variants {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(topP: topP, topK: topK, firstTarget: firstTarget)))
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
            XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: extracted), "\(topP),\(topK),\(firstTarget)")
        }
    }

    private func assertPlanForest(_ plan: PDFCatalogGraphPlan, rootChildCount: Int) throws {
        let root = try node(plan.catalogEntries["StructTreeRoot"]), rootKids = try values(root.entries["K"])
        XCTAssertEqual(rootKids.count, rootChildCount)
        let nums = try values(dictionary(root.entries["ParentTree"])["Nums"])
        XCTAssertEqual(nums.count, 4)
        let first = try node(nums[1]), second = try node(nums[3]); XCTAssertTrue(first === second)
        guard case .dictionaryReference(let topDictionary)? = first.entries["P"] else { return XCTFail() }
        let top = try node(plan.aliases[pdfReferenceIdentity(topDictionary)])
        XCTAssertNil(top.entries["P"], "Keep original absent P absent.")
        for kid in rootKids { XCTAssertFalse(try node(kid) === top, "Do not invent a root edge.") }
        XCTAssertEqual(try values(first.entries["K"]).count, 2)
    }
    private func assertSavedForest(_ document: PDFDocument, rootChildCount: Int, annotationCount: Int, pageIndex: Int = 0) throws {
        let page = try XCTUnwrap(document.page(at: pageIndex)), native = try XCTUnwrap(document.documentRef)
        let root = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(native.catalog), "StructTreeRoot"))
        let kids = try XCTUnwrap(PDFCatalogStructurePreserver.array(root, "K")); XCTAssertEqual(CGPDFArrayGetCount(kids), rootChildCount)
        let tree = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(root, "ParentTree"))
        let nums = try XCTUnwrap(PDFCatalogStructurePreserver.array(tree, "Nums"))
        XCTAssertEqual(CGPDFArrayGetCount(nums), annotationCount * 2)
        var first: CGPDFDictionaryRef?, second: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(nums, 1, &first)); XCTAssertTrue(CGPDFArrayGetDictionary(nums, 3, &second))
        let owner = try XCTUnwrap(first); XCTAssertEqual(pdfReferenceIdentity(owner), pdfReferenceIdentity(try XCTUnwrap(second)))
        let top = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(owner, "P"))
        XCTAssertNil(PDFCatalogStructurePreserver.object(top, "P"))
        for index in 0..<CGPDFArrayGetCount(kids) {
            var d: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(kids, index, &d))
            XCTAssertNotEqual(pdfReferenceIdentity(try XCTUnwrap(d)), pdfReferenceIdentity(top))
        }
        let objrs = try XCTUnwrap(PDFCatalogStructurePreserver.array(owner, "K"))
        XCTAssertEqual(CGPDFArrayGetCount(objrs), annotationCount)
        XCTAssertEqual(page.annotations.count, annotationCount)
        let nativePage = try XCTUnwrap(native.page(at: pageIndex + 1)?.dictionary)
        let nativeAnnotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(nativePage, "Annots"))
        for index in 0..<annotationCount {
            var objr: CGPDFDictionaryRef?, annotation: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(objrs, index, &objr))
            XCTAssertTrue(CGPDFArrayGetDictionary(nativeAnnotations, index, &annotation))
            let target = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(objr), "Obj"))
            let objrPage = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(objr), "Pg"))
            XCTAssertEqual(pdfReferenceIdentity(target), pdfReferenceIdentity(try XCTUnwrap(annotation)))
            XCTAssertEqual(pdfReferenceIdentity(objrPage), pdfReferenceIdentity(nativePage))
        }
    }
    private func blankAnchor() throws -> PDFDocument {
        let bytes = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        return try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes as Data))
    }
    private func savedOnWorker(_ document: PDFDocument, at url: URL) async throws -> PDFDocument {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let onMain = try await Task.detached(priority: .userInitiated) {
            let onMain = Thread.isMainThread
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: url, allowDirectOverwriteFallback: false)
            return onMain
        }.value
        XCTAssertFalse(onMain); return try XCTUnwrap(PDFDocument(url: url))
    }
    private func nativeDictionary(_ document: PDFDocument, objectKey: String) throws -> CGPDFDictionaryRef {
        try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(document.documentRef?.catalog), objectKey))
    }
    private func node(_ value: PDFCatalogGraphValue?) throws -> PDFCatalogGraphNode {
        guard case .node(let n)? = value else { throw NSError(domain: "TagTestNode", code: 1) }; return n
    }
    private func dictionary(_ value: PDFCatalogGraphValue?) throws -> [String: PDFCatalogGraphValue] {
        guard case .dictionary(let d)? = value else { throw NSError(domain: "TagTestDictionary", code: 1) }; return d
    }
    private func values(_ value: PDFCatalogGraphValue?) throws -> [PDFCatalogGraphValue] {
        guard case .array(let a)? = value else { throw NSError(domain: "TagTestArray", code: 1) }; return a
    }
    private func fixture(topP: String = "", topK: String = "[7 0 R]", firstTarget: String = "4 0 R") -> Data {
        let paint = "q 0 0 1 rg 10 20 30 40 re f Q\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo << /Marked true >> >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 10 0 R /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 40 30] /StructParent 10 /A << /S /URI /URI (https://original.example/one) >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [50 10 90 30] /StructParent 11 /A << /S /URI /URI (https://original.example/two) >> >>",
            "<< /Type /StructTreeRoot /K [9 0 R] /ParentTree 11 0 R >>",
            "<< /Type /StructElem /S /Link /P 8 0 R /Pg 3 0 R /K [<< /Type /OBJR /Obj \(firstTarget) /Pg 3 0 R >> << /Type /OBJR /Obj 5 0 R /Pg 3 0 R >>] >>",
            "<< /Type /StructElem /S /Sect /K \(topK) \(topP) /Lang (en) >>",
            "<< /Type /StructElem /S /Document /P 6 0 R /K [] >>",
            "<< /Length \(paint.utf8.count) >>\nstream\n\(paint)endstream",
            "<< /Nums [10 7 0 R 11 7 0 R] >>",
            // Referenced only by the malformed top-K variant. Its absent P
            // must be refused rather than synthesized during detached import.
            "<< /Type /StructElem /S /Span /K [] >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count; data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8)); return data
    }
}
