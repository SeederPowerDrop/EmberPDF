// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFSparseParentArraySerializationTests: XCTestCase {
    func testSparseParentArrayIsIndirectAndPreservesEveryHoleAndRepeatedOwner() async throws {
        try await Task.detached {
            let source = try Self.source(), root = PDFCatalogGraphNode()
            let shared = PDFCatalogGraphNode(entries: ["Type": .name("StructElem"), "S": .name("P"),
                "P": .node(root), "Pg": .page(0), "K": .array([.integer(0), .integer(12_345)])])
            let last = PDFCatalogGraphNode(entries: ["Type": .name("StructElem"), "S": .name("P"),
                "P": .node(root), "Pg": .page(0), "K": .integer(99_999)])
            root.entries = ["Type": .name("StructTreeRoot"), "K": .array([.node(shared), .node(last)]),
                "ParentTree": .dictionary(["Nums": .array([.integer(0),
                    .sparseArray(count: 100_000, members: [0: .node(shared), 12_345: .node(shared), 99_999: .node(last)])])]),
                "ParentTreeNextKey": .integer(1)]
            var plan = PDFCatalogGraphPlan()
            plan.catalogEntries["StructTreeRoot"] = .node(root)
            plan.catalogEntries["MarkInfo"] = .dictionary(["Marked": .boolean(true)])
            plan.catalogEntries["EmptySparseProbe"] = .sparseArray(count: 0, members: [:])
            plan.catalogEntries["TinySparseProbe"] = .sparseArray(count: 5, members: [1: .node(shared), 3: .node(last)])
            plan.pageEntries[0] = ["StructParents": .integer(0)]
            let bytes = try Self.save(source, plan: plan), reopened = try XCTUnwrap(PDFDocument(data: bytes))
            let catalog = try XCTUnwrap(reopened.documentRef?.catalog)
            let structure = try Self.dictionary(catalog, "StructTreeRoot"), parents = try Self.dictionary(structure, "ParentTree")
            let nums = try Self.array(parents, "Nums")
            XCTAssertEqual(CGPDFArrayGetCount(nums), 2)
            var slots: CGPDFArrayRef?
            XCTAssertTrue(CGPDFArrayGetArray(nums, 1, &slots))
            let array = try XCTUnwrap(slots)
            XCTAssertEqual(CGPDFArrayGetCount(array), 100_000)
            var first: CGPDFDictionaryRef?, duplicate: CGPDFDictionaryRef?, final: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(array, 0, &first))
            XCTAssertTrue(CGPDFArrayGetDictionary(array, 12_345, &duplicate))
            XCTAssertTrue(CGPDFArrayGetDictionary(array, 99_999, &final))
            XCTAssertEqual(first, duplicate); XCTAssertNotEqual(first, final)
            for index in 0..<100_000 where ![0, 12_345, 99_999].contains(index) {
                var value: CGPDFObjectRef?
                XCTAssertTrue(CGPDFArrayGetObject(array, index, &value))
                XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(value)), .null, "MCID hole \(index)")
            }
            XCTAssertEqual(CGPDFArrayGetCount(try Self.array(catalog, "EmptySparseProbe")), 0)
            let tiny = try Self.array(catalog, "TinySparseProbe")
            XCTAssertEqual(CGPDFArrayGetCount(tiny), 5)
            for index in [0, 2, 4] {
                var value: CGPDFObjectRef?
                XCTAssertTrue(CGPDFArrayGetObject(tiny, index, &value))
                XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(value)), .null, "Leading, middle and trailing holes stay explicit")
            }
            var tinyFirst: CGPDFDictionaryRef?, tinyLast: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(tiny, 1, &tinyFirst)); XCTAssertEqual(tinyFirst, first)
            XCTAssertTrue(CGPDFArrayGetDictionary(tiny, 3, &tinyLast)); XCTAssertEqual(tinyLast, final)
            // This is the writer's controlled plain output. Its ParentTree
            // array must have a separate object body, not a giant inline tree.
            let text = String(decoding: bytes, as: UTF8.self)
            let expression = try NSRegularExpression(pattern: #"/Nums\s*\[\s*0\s+([0-9]+)\s+0\s+R\s*\]"#)
            let match = try XCTUnwrap(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
            let identifier = (text as NSString).substring(with: match.range(at: 1))
            XCTAssertTrue(text.contains("\n\(identifier) 0 obj\n["))
            XCTAssertEqual(try Self.contents(reopened), try Self.contents(source.document))
            XCTAssertEqual(source.bytes, Self.fixture())
        }.value
    }

    func testSparseArrayRejectsInvalidSlotsAndKeepsOriginalDepthLimit() async throws {
        try await Task.detached {
            let source = try Self.source()
            for value in [PDFCatalogGraphValue.sparseArray(count: -1, members: [:]),
                          .sparseArray(count: 250_001, members: [:]),
                          .sparseArray(count: 0, members: [0: .null]),
                          .sparseArray(count: 2, members: [-1: .null]),
                          .sparseArray(count: 2, members: [2: .null])] {
                var plan = PDFCatalogGraphPlan(); plan.catalogEntries["SparseProbe"] = value
                XCTAssertThrowsError(try Self.save(source, plan: plan))
            }
            for levels in [62, 63, 65] {
                var nested: PDFCatalogGraphValue = .integer(7)
                for _ in 0..<levels { nested = .sparseArray(count: 1, members: [0: nested]) }
                var plan = PDFCatalogGraphPlan(); plan.catalogEntries["SparseProbe"] = nested
                if levels == 62 { XCTAssertFalse(try Self.save(source, plan: plan).isEmpty, "A scalar at depth63 remains supported") }
                else { XCTAssertThrowsError(try Self.save(source, plan: plan), "A scalar at depth64 or more cannot gain a deferred-body depth reset") }
            }
            let aliasDocument = try Self.source().document
            let aliasOwner = try XCTUnwrap(aliasDocument.documentRef)
            let first = try XCTUnwrap(aliasOwner.catalog), second = try XCTUnwrap(aliasOwner.page(at: 1)?.dictionary)
            for indirectCycle in [false, true] {
                var cyclic = PDFCatalogGraphPlan()
                cyclic.retainedDocuments = [aliasOwner]
                cyclic.catalogEntries["SparseAliasCycle"] = .dictionaryReference(first)
                cyclic.aliases[pdfReferenceIdentity(first)] = .sparseArray(count: 1,
                    members: [0: .dictionaryReference(indirectCycle ? second : first)])
                if indirectCycle {
                    cyclic.aliases[pdfReferenceIdentity(second)] = .sparseArray(count: 1, members: [0: .dictionaryReference(first)])
                }
                XCTAssertThrowsError(try Self.save(source, plan: cyclic)) { error in
                    XCTAssertTrue(String(describing: error).hasPrefix("invalidObject("), "Preserve immediate alias-cycle refusal, not depth/resource exhaustion: \(error)")
                }
            }
            let sharedNode = PDFCatalogGraphNode(entries: ["Value": .integer(7)])
            sharedNode.entries["Self"] = .node(sharedNode)
            var valid = PDFCatalogGraphPlan()
            valid.retainedDocuments = [aliasOwner]
            valid.catalogEntries["SparseAliasShared"] = .sparseArray(count: 2,
                members: [0: .dictionaryReference(first), 1: .dictionaryReference(first)])
            valid.aliases[pdfReferenceIdentity(first)] = .node(sharedNode)
            let saved = try XCTUnwrap(PDFDocument(data: Self.save(source, plan: valid)))
            let sharedArray = try Self.array(XCTUnwrap(saved.documentRef?.catalog), "SparseAliasShared")
            var sharedFirst: CGPDFDictionaryRef?, sharedSecond: CGPDFDictionaryRef?, selfReference: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(sharedArray, 0, &sharedFirst))
            XCTAssertTrue(CGPDFArrayGetDictionary(sharedArray, 1, &sharedSecond))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(sharedFirst), "Self", &selfReference))
            XCTAssertEqual(sharedFirst, sharedSecond); XCTAssertEqual(sharedFirst, selfReference)
            XCTAssertEqual(source.bytes, Self.fixture())
        }.value
    }

    func testDeferredSparseArraysStillConsumeTheExistingObjectBudget() async throws {
        try await Task.detached {
            let source = try Self.source()
            var plan = PDFCatalogGraphPlan()
            plan.catalogEntries["SparseObjectBudget"] = .array(Array(repeating: .sparseArray(count: 0, members: [:]), count: 250_000))
            XCTAssertThrowsError(try Self.save(source, plan: plan), "The new array references cannot exceed the existing250k document objects")
            XCTAssertEqual(source.bytes, Self.fixture())
        }.value
    }

    func testCancellationRefusesSparseSerializationWithoutChangingTheSource() async throws {
        try await Task.detached {
            let source = try Self.source(), cancellation = PDFSaveCancellation()
            var plan = PDFCatalogGraphPlan()
            plan.catalogEntries["SparseProbe"] = .sparseArray(count: 250_000, members: [:])
            cancellation.cancel()
            do {
                _ = try PDFSaveCancellation.withCurrent(cancellation) { try Self.save(source, plan: plan) }
                XCTFail("Cancellation must propagate")
            } catch is CancellationError { }
            XCTAssertEqual(source.bytes, Self.fixture())
        }.value
    }

    private struct Source { let bytes: Data; let document: PDFDocument }
    private static func source() throws -> Source {
        let bytes = fixture()
        return Source(bytes: bytes, document: try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes)))
    }
    private static func save(_ source: Source, plan: PDFCatalogGraphPlan) throws -> Data {
        try PDFBodyTextPageSnapshot.preservingCatalog(in: source.bytes, from: source.document, plan: plan)
    }
    private static func dictionary(_ owner: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef {
        var value: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(owner, key, &value)); return try XCTUnwrap(value)
    }
    private static func array(_ owner: CGPDFDictionaryRef, _ key: String) throws -> CGPDFArrayRef {
        var value: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(owner, key, &value)); return try XCTUnwrap(value)
    }
    private static func contents(_ document: PDFDocument) throws -> Data {
        let page = try XCTUnwrap(document.page(at: 0)?.pageRef?.dictionary)
        var stream: CGPDFStreamRef?, format = CGPDFDataFormat.raw
        XCTAssertTrue(CGPDFDictionaryGetStream(page, "Contents", &stream))
        return try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data
    }
    private static func fixture() -> Data {
        let content = "/P <</MCID 0>> BDC EMC\n/P <</MCID 12345>> BDC EMC\n/P <</MCID 99999>> BDC EMC\n"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"]
        var bytes = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
