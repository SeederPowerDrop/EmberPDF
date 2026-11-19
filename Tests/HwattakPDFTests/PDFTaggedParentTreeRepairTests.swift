// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFTaggedParentTreeRepairTests: XCTestCase {
    func testEightyThreeMissingKeysUseExistingUniqueForwardOwnersWithoutChangingPainting() throws {
        let source = try fixture(pageCount: 84, mode: .missing)
        let before = try Data(contentsOf: XCTUnwrap(source.documentURL))
        let plan = try preserved(source)
        let parents = try parentEntries(plan)
        let children = try values(root(plan).entries["K"])
        XCTAssertEqual(parents.count, 84)
        XCTAssertEqual(plan.pageEntries.count, 84)
        for index in 0..<84 {
            XCTAssertTrue(try node(values(parents[index])[0]) === node(children[index]))
        }
        // The forward /K already names MCID zero; the deliberately unmarked
        // painting stream stays unmodified rather than fabricating an MCID.
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("/MCID"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(source.documentURL)), before)
        XCTAssertEqual(try nativeParentPairCount(source), 1)
    }

    func testExactOwnerAttributeBacklinkIsRecoveredAndNullHolesArePreserved() throws {
        let source = try fixture(pageCount: 2, mode: .attribute)
        let before = try Data(contentsOf: XCTUnwrap(source.documentURL))
        let plan = try preserved(source)
        let parents = try parentEntries(plan)
        let children = try values(root(plan).entries["K"])
        for index in 0..<2 {
            let slots = try values(parents[index])
            XCTAssertEqual(slots.count, 2)
            guard case .null = slots[0] else { return XCTFail("Keep the original MCID hole") }
            XCTAssertTrue(try node(slots[1]) === node(children[index]))
            XCTAssertNotNil(try node(children[index]).entries["A"])
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(source.documentURL)), before)
    }

    func testValidParentArraysAndTheirHolesStayIntact() throws {
        let source = try fixture(pageCount: 2, mode: .valid)
        let plan = try preserved(source)
        let parents = try parentEntries(plan)
        let children = try values(root(plan).entries["K"])
        for index in 0..<2 {
            let slots = try values(parents[index])
            XCTAssertEqual(slots.count, 2)
            guard case .null = slots[0] else { return XCTFail() }
            XCTAssertTrue(try node(slots[1]) === node(children[index]))
        }
    }

    func testDuplicateForwardOwnersAndConflictingValidReverseOwnersFailBeforeCommit() throws {
        for source in [try fixture(pageCount: 1, mode: .duplicate),
                       try fixture(pageCount: 2, mode: .conflict)] {
            var plan = PDFCatalogGraphPlan()
            plan.catalogEntries["Sentinel"] = .integer(7)
            XCTAssertThrowsError(try PDFTaggedStructurePreserver.addPreservedTags(from: [group(source)], to: &plan))
            XCTAssertEqual(plan.catalogEntries.count, 1)
            XCTAssertTrue(plan.pageEntries.isEmpty)
            XCTAssertTrue(plan.aliases.isEmpty)
        }
    }

    func testExcludedEditedPageHasNoRecoveredKeyOrForwardFigure() throws {
        let source = try fixture(pageCount: 84, mode: .missing)
        let plan = try preserved(source, excluding: 32)
        XCTAssertEqual(try parentEntries(plan).count, 83)
        XCTAssertEqual(plan.pageEntries.count, 83)
        XCTAssertNil(plan.pageEntries[32])
        let children = try values(root(plan).entries["K"])
        XCTAssertEqual(children.count, 83)
        for value in children {
            if case .page(let page)? = try node(value).entries["Pg"] { XCTAssertNotEqual(page, 32) }
        }
    }

    func testMissingAnnotationAndFormParentMappingsRemainUnsupported() throws {
        for mode in [Mode.missingAnnotation, .missingForm] {
            let source = try fixture(pageCount: 1, mode: mode)
            XCTAssertThrowsError(try preserved(source))
        }
    }

    func testReportedStadiumBookCanPlanUntouchedTagsAfterPage184Edit() throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_STADIUM_PDF"], path.hasPrefix("/") else {
            throw XCTSkip("Set EMBER_STADIUM_PDF for the private stadium-book tag regression.")
        }
        let source = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        XCTAssertEqual(source.pageCount, 408)
        let plan = try preserved(source, excluding: 183)
        XCTAssertEqual(plan.pageEntries.count, 407)
        XCTAssertEqual(try parentEntries(plan).count, 407)
        XCTAssertEqual(try values(root(plan).entries["K"]).count, 407)
        XCTAssertNil(plan.pageEntries[183])
    }

    private func preserved(_ source: PDFDocument, excluding: Int? = nil) throws -> PDFCatalogGraphPlan {
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [group(source, excluding: excluding)], to: &plan)
        return plan
    }

    private func group(_ source: PDFDocument, excluding: Int? = nil) throws -> PDFCatalogSourceGroup {
        let pages = try (0..<source.pageCount).filter { $0 != excluding }.map {
            PDFCatalogPageOrigin(sourceIndex: $0, outputIndex: $0, livePage: try XCTUnwrap(source.page(at: $0)))
        }
        return PDFCatalogSourceGroup(document: try XCTUnwrap(source.documentRef), pages: pages)
    }

    private enum Mode { case missing, attribute, valid, duplicate, conflict, missingAnnotation, missingForm }

    private func fixture(pageCount count: Int, mode: Mode) throws -> PDFDocument {
        let pageIDs = Array(4..<(4 + count)), elementIDs = Array((4 + count)..<(4 + count * 2))
        let attributeIDs = Array((4 + count * 2)..<(4 + count * 3))
        let treeID = 4 + count * 3, streamID = treeID + 1, extraID = streamID + 1
        let hasHole = mode == .attribute || mode == .valid
        let kids = elementIDs + (mode == .duplicate ? [extraID] : [])
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 3 0 R >>",
            "<< /Type /Pages /Kids [\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(count) >>",
            "<< /Type /StructTreeRoot /K [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /ParentTree \(treeID) 0 R >>"
        ]
        for index in 0..<count {
            let annotations = mode == .missingAnnotation ? "/Annots [\(extraID) 0 R]" : ""
            let forms = mode == .missingForm ? "/XObject << /Fm \(extraID) 0 R >>" : ""
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << \(forms) >> /Contents \(streamID) 0 R /StructParents \(index) \(annotations) >>")
        }
        for index in 0..<count {
            objects.append("<< /Type /StructElem /S /Figure /P 3 0 R /Pg \(pageIDs[index]) 0 R /K \(hasHole ? 1 : 0) /A \(attributeIDs[index]) 0 R >>")
        }
        for _ in 0..<count { objects.append("<< /O /Layout /BBox [0 0 100 100] >>") }
        var pairs: [String] = []
        for index in 0..<count where mode != .duplicate && (mode != .missing || index == 0) {
            let target = mode == .attribute ? attributeIDs[index] : mode == .conflict ? elementIDs[1] : elementIDs[index]
            pairs.append("\(index) [\(hasHole ? "null " : "")\(target) 0 R]")
        }
        objects.append("<< /Nums [\(pairs.joined(separator: " "))] >>")
        objects.append("<< /Length 0 >>\nstream\n\nendstream")
        if mode == .duplicate {
            objects.append("<< /Type /StructElem /S /P /P 3 0 R /Pg \(pageIDs[0]) 0 R /K 0 >>")
        } else if mode == .missingAnnotation {
            objects.append("<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] /P \(pageIDs[0]) 0 R /StructParent 999 >>")
        } else if mode == .missingForm {
            objects.append("<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >> /StructParents 999 /Length 0 >>\nstream\n\nendstream")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-tag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.pdf")
        try data.write(to: url)
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func nativeParentPairCount(_ source: PDFDocument) throws -> Int {
        var root: CGPDFDictionaryRef?, tree: CGPDFDictionaryRef?, nums: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(source.documentRef?.catalog), "StructTreeRoot", &root))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(root), "ParentTree", &tree))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(tree), "Nums", &nums))
        return CGPDFArrayGetCount(try XCTUnwrap(nums)) / 2
    }

    private func root(_ plan: PDFCatalogGraphPlan) throws -> PDFCatalogGraphNode { try node(plan.catalogEntries["StructTreeRoot"]) }
    private func node(_ value: PDFCatalogGraphValue?) throws -> PDFCatalogGraphNode { guard case .node(let node)? = value else { throw InvalidValue() }; return node }
    private func values(_ value: PDFCatalogGraphValue?) throws -> [PDFCatalogGraphValue] {
        switch value {
        case .array(let values)?: return values
        case .sparseArray(let count, let members)?:
            var values = [PDFCatalogGraphValue](repeating: .null, count: count)
            for (index, member) in members { values[index] = member }
            return values
        default: throw InvalidValue()
        }
    }
    private func parentEntries(_ plan: PDFCatalogGraphPlan) throws -> [Int: PDFCatalogGraphValue] {
        var result: [Int: PDFCatalogGraphValue] = [:]
        func collect(_ value: PDFCatalogGraphValue) throws {
            guard case .dictionary(let dictionary) = value else { throw InvalidValue() }
            if let nums = dictionary["Nums"] {
                let pairs = try values(nums)
                for index in stride(from: 0, to: pairs.count, by: 2) {
                    guard case .integer(let key) = pairs[index] else { throw InvalidValue() }
                    result[key] = pairs[index + 1]
                }
            }
            if let kids = dictionary["Kids"] { for child in try values(kids) { try collect(child) } }
        }
        try collect(try XCTUnwrap(root(plan).entries["ParentTree"]))
        return result
    }
    private struct InvalidValue: Error {}
}
