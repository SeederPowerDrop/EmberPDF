// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFTaggedStructurePreserverTests: XCTestCase {
    func testExtractionPrunesExcludedPageAncestorsAndPreservesMCIDHoles() throws {
        let source = try fixture()
        let group = try group(source, sourcePage: 1, output: 0)
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [group], to: &plan)
        let root = try node(plan.catalogEntries["StructTreeRoot"])
        let kids = try values(root.entries["K"])
        XCTAssertEqual(kids.count, 2)
        let paragraph = try node(kids.first)
        XCTAssertEqual(try integer(plan.pageEntries[0]?["StructParents"]), 0)
        let parentTree = try dictionary(root.entries["ParentTree"])
        let nums = try values(parentTree["Nums"])
        let mcids = try values(nums[1])
        XCTAssertEqual(mcids.count, 2)
        guard case .null = mcids[0] else { return XCTFail("MCID zero must stay a hole") }
        XCTAssertTrue(try node(mcids[1]) === paragraph)
        let originalRoot = try sourceRoot(source)
        guard case .dictionaryReference(let parent)? = paragraph.entries["P"] else { return XCTFail("Parent is a lazy source reference") }
        XCTAssertEqual(parent, originalRoot)
        XCTAssertTrue(try node(plan.aliases[pdfReferenceIdentity(originalRoot)]) === root)
        XCTAssertNil(paragraph.entries["Ref"], "A cross-reference to a pruned element must not import its page.")
        let ids = try values(dictionary(root.entries["IDTree"])["Names"])
        XCTAssertEqual(ids.count, 2)
        guard case .string(let id) = ids[0] else { return XCTFail() }
        XCTAssertEqual(String(decoding: id, as: UTF8.self), "EmberTag0_second")
    }

    func testMergingSourcesNamespacesRoleClassAndParentKeys() throws {
        let a = try fixture(role: "P"), b = try fixture(role: "Span")
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [try group(a, sourcePage: 1, output: 0), try group(b, sourcePage: 1, output: 1)], to: &plan)
        let root = try node(plan.catalogEntries["StructTreeRoot"])
        let roles = try dictionary(root.entries["RoleMap"]), classes = try dictionary(root.entries["ClassMap"])
        XCTAssertEqual(try name(roles["EmberTag0_Custom"]), "P")
        XCTAssertEqual(try name(roles["EmberTag1_Custom"]), "Span")
        XCTAssertNotNil(classes["EmberTag0_Shared"]); XCTAssertNotNil(classes["EmberTag1_Shared"])
        let paragraphs = try values(root.entries["K"]).enumerated().filter { $0.offset % 2 == 0 }.map { try node($0.element) }
        XCTAssertEqual(try name(paragraphs[0].entries["S"]), "EmberTag0_Custom")
        XCTAssertEqual(try name(paragraphs[1].entries["C"]), "EmberTag1_Shared")
        XCTAssertEqual(try integer(plan.pageEntries[0]?["StructParents"]), 0)
        XCTAssertEqual(try integer(plan.pageEntries[1]?["StructParents"]), 2)
        XCTAssertEqual(try integer(root.entries["ParentTreeNextKey"]), 4)
    }

    func testOBJRTargetsOutputAnnotationAndGetsAUniqueParentKey() throws {
        let source = try fixture()
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [try group(source, sourcePage: 1, output: 3)], to: &plan)
        let root = try node(plan.catalogEntries["StructTreeRoot"]), kids = try values(root.entries["K"])
        let link = try node(kids[1]), objr = try dictionary(values(link.entries["K"])[0])
        guard case .annotation(page: 3, index: 0)? = objr["Obj"], case .page(3)? = objr["Pg"] else { return XCTFail() }
        XCTAssertEqual(try integer(plan.annotationEntries[3]?[0]?["StructParent"]), 1)
        let original = try XCTUnwrap(group(source, sourcePage: 1, output: 3).document.page(at: 2)?.dictionary)
        var annotations: CGPDFArrayRef?, annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(original, "Annots", &annotations))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &annotation))
        let nativeAnnotation = try XCTUnwrap(annotation)
        guard case .annotation(page: 3, index: 0)? = plan.aliases[pdfReferenceIdentity(nativeAnnotation)] else { return XCTFail() }
    }

    func testTaggedFormKeepsOriginalStreamAndOverridesOnlyStructParents() throws {
        let source = try fixture(form: true)
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [try group(source, sourcePage: 1, output: 0)], to: &plan)
        let root = try node(plan.catalogEntries["StructTreeRoot"]), paragraph = try node(values(root.entries["K"])[0])
        let mcr = try dictionary(values(paragraph.entries["K"])[0])
        guard case .original(let stream)? = mcr["Stm"] else { return XCTFail() }
        var native: CGPDFStreamRef?
        XCTAssertTrue(CGPDFObjectGetValue(stream, .stream, &native))
        let dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(XCTUnwrap(native)))
        XCTAssertEqual(try integer(plan.dictionaryOverrides[pdfReferenceIdentity(dictionary)]?["StructParents"]), 2)
        XCTAssertNil(plan.aliases[pdfReferenceIdentity(dictionary)], "A stream must not be replaced by a plain dictionary.")
    }

    func testMissingPgCanUseUnambiguousSourceParentTreeWithoutChangingMCID() throws {
        let source = try fixture(omitParagraphPage: true)
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [try group(source, sourcePage: 1, output: 4)], to: &plan)
        let paragraph = try node(values(node(plan.catalogEntries["StructTreeRoot"]).entries["K"])[0])
        let mcr = try dictionary(values(paragraph.entries["K"])[0])
        guard case .page(4)? = mcr["Pg"] else { return XCTFail() }
        XCTAssertEqual(try integer(mcr["MCID"]), 1)
    }

    func testCyclesAndDuplicateSourcePagesFailBeforeMutatingPlan() throws {
        for (source, duplicate) in [(try fixture(cycle: true), false), (try fixture(), true)] {
            let first = try group(source, sourcePage: 1, output: 0)
            let group = duplicate ? PDFCatalogSourceGroup(document: first.document,
                pages: first.pages + [PDFCatalogPageOrigin(sourceIndex: 1, outputIndex: 1, livePage: first.pages[0].livePage)]) : first
            var plan = PDFCatalogGraphPlan()
            plan.catalogEntries["Sentinel"] = .integer(7)
            XCTAssertThrowsError(try PDFTaggedStructurePreserver.addPreservedTags(from: [group], to: &plan))
            XCTAssertEqual(plan.catalogEntries.count, 1)
            XCTAssertTrue(plan.aliases.isEmpty); XCTAssertTrue(plan.pageEntries.isEmpty)
        }
    }

    func testRetainedCrossReferencesDoNotCreateSwiftNodeRetentionCycles() throws {
        let source = try fixture(mutualReferences: true)
        weak var retainedRoot: PDFCatalogGraphNode?
        try autoreleasepool {
            let native = try XCTUnwrap(source.documentRef)
            let pages = try (0..<2).map { PDFCatalogPageOrigin(sourceIndex: $0, outputIndex: $0, livePage: try XCTUnwrap(source.page(at: $0))) }
            var plan = PDFCatalogGraphPlan()
            try PDFTaggedStructurePreserver.addPreservedTags(from: [PDFCatalogSourceGroup(document: native, pages: pages)], to: &plan)
            let root = try node(plan.catalogEntries["StructTreeRoot"])
            retainedRoot = root
            for value in try values(root.entries["K"]).prefix(2) {
                let reference = try values(node(value).entries["Ref"])
                XCTAssertEqual(reference.count, 1)
                guard case .dictionaryReference = reference[0] else { return XCTFail("Resolve cross-references lazily through aliases") }
            }
        }
        XCTAssertNil(retainedRoot)
    }

    func testMetadataOnlyDocumentNodeKeepsItsInfoAndMetadata() throws {
        let source = try fixture(metadataOnly: true)
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [try group(source, sourcePage: 1, output: 0)], to: &plan)
        let root = try node(plan.catalogEntries["StructTreeRoot"])
        XCTAssertNotNil(root.entries["VendorInfo"])
        let kids = try values(root.entries["K"])
        XCTAssertEqual(kids.count, 1)
        let metadata = try node(kids[0])
        XCTAssertEqual(try name(metadata.entries["S"]), "Document")
        XCTAssertNotNil(metadata.entries["Info"]); XCTAssertNotNil(metadata.entries["Metadata"])
        XCTAssertTrue(try values(metadata.entries["K"]).isEmpty)
        XCTAssertNil(root.entries["ParentTree"])
    }

    private func group(_ source: PDFDocument, sourcePage: Int, output: Int) throws -> PDFCatalogSourceGroup {
        PDFCatalogSourceGroup(document: try XCTUnwrap(source.documentRef),
            pages: [PDFCatalogPageOrigin(sourceIndex: sourcePage, outputIndex: output, livePage: try XCTUnwrap(source.page(at: sourcePage)))])
    }
    private func sourceRoot(_ source: PDFDocument) throws -> CGPDFDictionaryRef {
        var root: CGPDFDictionaryRef?
        let catalog = try XCTUnwrap(source.documentRef?.catalog)
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &root))
        return try XCTUnwrap(root)
    }
    private func fixture(role: String = "P", form: Bool = false, omitParagraphPage: Bool = false, cycle: Bool = false,
                         mutualReferences: Bool = false, metadataOnly: Bool = false) throws -> PDFDocument {
        let secondK = cycle ? "7 0 R" : form ? "<< /Type /MCR /Pg 4 0 R /Stm 12 0 R /MCID 1 >>" : "1"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 5 0 R /MarkInfo << /Marked true >> /Lang (en) >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 11 0 R /StructParents 0 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 11 0 R /StructParents 1 /Annots [10 0 R] >>",
            "<< /Type /StructTreeRoot /K [6 0 R 7 0 R 8 0 R] /ParentTree 9 0 R /RoleMap << /Custom /\(role) >> /ClassMap << /Shared << /O /Layout /TextAlign /Center >> >> >>",
            "<< /Type /StructElem /S /Custom /P 5 0 R /Pg 3 0 R /K 0 /ID (first) /C /Shared \(mutualReferences ? "/Ref [7 0 R]" : "") >>",
            "<< /Type /StructElem /S /Custom /P 5 0 R \(omitParagraphPage ? "" : "/Pg 4 0 R") /K \(secondK) /ID (second) /C /Shared /Ref [6 0 R] >>",
            "<< /Type /StructElem /S /Link /P 5 0 R /Pg 4 0 R /K << /Type /OBJR /Pg 4 0 R /Obj 10 0 R >> >>",
            "<< /Nums [0 [6 0 R] 1 [null 7 0 R] 2 8 0 R \(form ? "3 [null 7 0 R]" : "")] >>",
            "<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] /P 4 0 R /StructParent 2 >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >> /StructParents 3 /Length 0 >>\nstream\n\nendstream"
        ]
        if metadataOnly {
            objects[2] = objects[2].replacingOccurrences(of: " /StructParents 0", with: "")
            objects[3] = objects[3].replacingOccurrences(of: " /StructParents 1", with: "")
            objects[4] = "<< /Type /StructTreeRoot /K 6 0 R /VendorInfo (root metadata) >>"
            objects[5] = "<< /S /Document /P 5 0 R /K [] /Info << /Producer (test) >> /Metadata 11 0 R >>"
            objects[9] = objects[9].replacingOccurrences(of: " /StructParent 2", with: "")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
    private func node(_ value: PDFCatalogGraphValue?) throws -> PDFCatalogGraphNode { guard case .node(let node)? = value else { throw XCTUnwrapError() }; return node }
    private func dictionary(_ value: PDFCatalogGraphValue?) throws -> [String: PDFCatalogGraphValue] { guard case .dictionary(let value)? = value else { throw XCTUnwrapError() }; return value }
    private func values(_ value: PDFCatalogGraphValue?) throws -> [PDFCatalogGraphValue] {
        switch value {
        case .array(let values)?: return values
        case .sparseArray(let count, let members)?:
            var values = [PDFCatalogGraphValue](repeating: .null, count: count)
            for (index, member) in members { values[index] = member }
            return values
        default: throw XCTUnwrapError()
        }
    }
    private func integer(_ value: PDFCatalogGraphValue?) throws -> Int { guard case .integer(let value)? = value else { throw XCTUnwrapError() }; return value }
    private func name(_ value: PDFCatalogGraphValue?) throws -> String { guard case .name(let value)? = value else { throw XCTUnwrapError() }; return value }
    private struct XCTUnwrapError: Error {}
}
