// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFTaggedFormResourcePreservationTests: XCTestCase {
    func testDeclaredAndPaintedFormsKeepDistinctStreamsAndShareRemappedParentKey() throws {
        let source = try fixture()
        let native = try XCTUnwrap(source.documentRef)
        let group = PDFCatalogSourceGroup(document: native,
            pages: [PDFCatalogPageOrigin(sourceIndex: 1, outputIndex: 0, livePage: try XCTUnwrap(source.page(at: 1)))])
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [group], to: &plan)
        let root = try node(plan.catalogEntries["StructTreeRoot"])
        let paragraph = try node(values(root.entries["K"])[0])
        let mcr = try dictionary(values(paragraph.entries["K"])[0])
        guard case .original(let declaredObject)? = mcr["Stm"] else { return XCTFail() }
        let declared = try streamDictionary(declaredObject)
        let page = try XCTUnwrap(native.page(at: 2)?.dictionary)
        let resources = try nativeDictionary(page, "Resources"), objects = try nativeDictionary(resources, "XObject")
        let painted = try streamDictionary(XCTUnwrap(PDFCatalogStructurePreserver.object(objects, "Painted")))
        XCTAssertNotEqual(declared, painted, "The existing source has two distinct Form streams.")
        XCTAssertEqual(try integer(plan.dictionaryOverrides[identity(declared)]?["StructParents"]),
                       try integer(plan.dictionaryOverrides[identity(painted)]?["StructParents"]))
        // MCID 1 stays attached to the explicitly declared stream, even though
        // the page paints MCID 2 in a different Form with the same source key.
        XCTAssertEqual(try integer(mcr["MCID"]), 1)
        let tree = try dictionary(root.entries["ParentTree"])
        let pairs = try values(tree["Nums"])
        let key = try integer(plan.dictionaryOverrides[identity(painted)]?["StructParents"])
        let index = try XCTUnwrap(stride(from: 0, to: pairs.count, by: 2).first { (try? integer(pairs[$0])) == key })
        let slots = try values(pairs[index + 1])
        XCTAssertEqual(slots.count, 3)
        XCTAssertTrue(try node(slots[1]) === paragraph)
        guard case .null = slots[2] else { return XCTFail("An untagged painted MCID must not gain an invented association.") }
    }

    func testReachableFormWithOnlyExcludedTargetsStillGetsANullParentArray() throws {
        let source = try fixture()
        let native = try XCTUnwrap(source.documentRef)
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [PDFCatalogSourceGroup(document: native,
            pages: [PDFCatalogPageOrigin(sourceIndex: 1, outputIndex: 0, livePage: try XCTUnwrap(source.page(at: 1)))])], to: &plan)
        let page = try XCTUnwrap(native.page(at: 2)?.dictionary)
        let objects = try nativeDictionary(nativeDictionary(page, "Resources"), "XObject")
        let untagged = try streamDictionary(XCTUnwrap(PDFCatalogStructurePreserver.object(objects, "Excluded")))
        let key = try integer(plan.dictionaryOverrides[identity(untagged)]?["StructParents"])
        let tree = try dictionary(node(plan.catalogEntries["StructTreeRoot"]).entries["ParentTree"])
        let pairs = try values(tree["Nums"])
        let index = try XCTUnwrap(stride(from: 0, to: pairs.count, by: 2).first { (try? integer(pairs[$0])) == key })
        let slots = try values(pairs[index + 1])
        XCTAssertEqual(slots.count, 1)
        guard case .null = slots[0] else { return XCTFail("An excluded source page must not be imported through ParentTree.") }
    }

    func testReachableFormWithoutAuthoritativeParentEntryFailsBeforePlanMutation() throws {
        let source = try fixture(missingParent: true)
        var plan = PDFCatalogGraphPlan()
        XCTAssertThrowsError(try PDFTaggedStructurePreserver.addPreservedTags(from: [PDFCatalogSourceGroup(
            document: try XCTUnwrap(source.documentRef), pages: [PDFCatalogPageOrigin(sourceIndex: 1,
                outputIndex: 0, livePage: try XCTUnwrap(source.page(at: 1)))])], to: &plan))
        XCTAssertTrue(plan.catalogEntries.isEmpty)
        XCTAssertTrue(plan.dictionaryOverrides.isEmpty)
    }

    private func fixture(missingParent: Bool = false) throws -> PDFDocument {
        func stream(_ content: String, parent: Int) -> String {
            "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << >> /StructParents \(parent) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 5 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /StructParents 0 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /XObject << /Painted 10 0 R /Excluded 11 0 R >> >> >>",
            "<< /Type /StructTreeRoot /K [6 0 R 7 0 R] /ParentTree 8 0 R >>",
            "<< /Type /StructElem /S /P /P 5 0 R /Pg 3 0 R /K 0 >>",
            "<< /Type /StructElem /S /P /P 5 0 R /K << /Type /MCR /Pg 4 0 R /Stm 9 0 R /MCID 1 >> >>",
            "<< /Nums [0 [6 0 R] 9 [null 7 0 R null] \(missingParent ? "" : "14 [6 0 R]")] >>",
            stream("/P << /MCID 1 >> BDC EMC", parent: 9),
            stream("/P << /MCID 2 >> BDC EMC", parent: 9),
            stream("/P << /MCID 2 >> BDC EMC", parent: 14)
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
    private func identity(_ value: CGPDFDictionaryRef) -> UInt { pdfReferenceIdentity(value) }
    private func nativeDictionary(_ value: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef {
        try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(value, key))
    }
    private func streamDictionary(_ value: CGPDFObjectRef) throws -> CGPDFDictionaryRef {
        var stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFObjectGetValue(value, .stream, &stream))
        return try XCTUnwrap(CGPDFStreamGetDictionary(XCTUnwrap(stream)))
    }
    private func node(_ value: PDFCatalogGraphValue?) throws -> PDFCatalogGraphNode {
        guard case .node(let node)? = value else { throw FixtureFailure.invalid }; return node
    }
    private func dictionary(_ value: PDFCatalogGraphValue?) throws -> [String: PDFCatalogGraphValue] {
        guard case .dictionary(let entries)? = value else { throw FixtureFailure.invalid }; return entries
    }
    private func values(_ value: PDFCatalogGraphValue?) throws -> [PDFCatalogGraphValue] {
        switch value {
        case .array(let values)?: return values
        case .sparseArray(let count, let members)?:
            var values = [PDFCatalogGraphValue](repeating: .null, count: count)
            for (index, member) in members { values[index] = member }
            return values
        default: throw FixtureFailure.invalid
        }
    }
    private func integer(_ value: PDFCatalogGraphValue?) throws -> Int {
        guard case .integer(let value)? = value else { throw FixtureFailure.invalid }; return value
    }
    private enum FixtureFailure: Error { case invalid }
}
