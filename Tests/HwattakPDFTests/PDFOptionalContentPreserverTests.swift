// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFOptionalContentPreserverTests: XCTestCase {
    func testImportedDefaultOnAndOffStatesShareTheLiveResourceGroupIdentity() throws {
        let first = try fixture(defaults: "/BaseState /ON /OFF [5 0 R]", prefix: "First")
        let second = try fixture(defaults: "/BaseState /OFF /ON [5 0 R]", prefix: "Second")
        var plan = PDFCatalogGraphPlan()
        try PDFOptionalContentPreserver.addOptionalContent(from: [group(first, output: 0), group(second, output: 1)], to: &plan)
        let properties = try dictionary(plan.catalogEntries["OCProperties"])
        let defaults = try dictionary(properties["D"])
        XCTAssertEqual(try name(defaults["BaseState"]), "ON")
        XCTAssertEqual(try groupNames(defaults["ON"]), ["First B", "Second A"])
        XCTAssertEqual(try groupNames(defaults["OFF"]), ["First A", "Second B"])
        let allGroups = try values(properties["OCGs"])
        XCTAssertEqual(allGroups.count, 4)
        let native = try XCTUnwrap(first.documentRef)
        let page = try XCTUnwrap(native.page(at: 1)?.dictionary)
        var resources: CGPDFDictionaryRef?, entries: CGPDFDictionaryRef?, liveGroup: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(page, "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "Properties", &entries))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(entries), "LayerA", &liveGroup))
        let key = pdfReferenceIdentity(try XCTUnwrap(liveGroup))
        guard case .node(let alias) = plan.aliases[key], case .node(let catalogGroup) = allGroups[0] else {
            return XCTFail("Expected a shared graph node for live /Properties and /OCGs.")
        }
        XCTAssertTrue(alias === catalogGroup)
        var repeated = PDFCatalogGraphPlan()
        try PDFOptionalContentPreserver.addOptionalContent(from: [group(first, output: 0), group(first, output: 1)], to: &repeated)
        XCTAssertEqual(try values(dictionary(repeated.catalogEntries["OCProperties"])["OCGs"]).count, 2)
        XCTAssertEqual(repeated.aliases.count, 2)
    }

    func testUsageRulesStaySourceScopedAndOrderLockedAndRadioGroupsSurvive() throws {
        let configuration = "/OFF [5 0 R] /Locked [5 0 R] /RBGroups [[5 0 R 6 0 R]] /Order [[(Heading) 5 0 R 6 0 R]] /AS [<< /Event /View /Category [/View] >>]"
        let first = try fixture(defaults: configuration, prefix: "First", usage: true)
        let second = try fixture(defaults: configuration, prefix: "Second", usage: true)
        var plan = PDFCatalogGraphPlan()
        try PDFOptionalContentPreserver.addOptionalContent(from: [group(first, output: 0), group(second, output: 1)], to: &plan)
        let properties = try dictionary(plan.catalogEntries["OCProperties"])
        let defaults = try dictionary(properties["D"])
        XCTAssertEqual(try groupNames(defaults["Locked"]), ["First A", "Second A"])
        XCTAssertEqual(try values(defaults["RBGroups"]).count, 2)
        XCTAssertEqual(try values(defaults["Order"]).count, 2)
        let rules = try values(defaults["AS"])
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(try groupNames(dictionary(rules[0])["OCGs"]), ["First A", "First B"])
        XCTAssertEqual(try groupNames(dictionary(rules[1])["OCGs"]), ["Second A", "Second B"])
        guard case .node(let node) = try values(properties["OCGs"])[0], case .original(let usage) = node.entries["Usage"] else {
            return XCTFail("Expected original per-group Usage metadata.")
        }
        XCTAssertEqual(CGPDFObjectGetType(usage), .dictionary)
    }

    func testAlternateConfigurationNamesAreUniqueAndChangesStayWithinTheirSource() throws {
        let first = try fixture(defaults: "/Name (Default) /OFF [5 0 R] /Order [5 0 R 6 0 R]",
            alternate: "/Name (Preset) /FixtureId (first) /BaseState /OFF /ON [5 0 R]", prefix: "First")
        let second = try fixture(defaults: "/Name (Default) /Order [5 0 R 6 0 R]",
            alternate: "/Name (Preset) /FixtureId (second) /BaseState /Unchanged /OFF [5 0 R]", prefix: "Second")
        var plan = PDFCatalogGraphPlan()
        try PDFOptionalContentPreserver.addOptionalContent(from: [group(first, output: 0), group(second, output: 1)], to: &plan)
        let properties = try dictionary(plan.catalogEntries["OCProperties"])
        let alternatives = try values(properties["Configs"]).map { try dictionary($0) }
        let names = try alternatives.map { try text($0["Name"]) }
        XCTAssertEqual(Set(names).count, alternatives.count)
        let firstConfiguration = try XCTUnwrap(alternatives.first { (try? text($0["FixtureId"])) == "first" })
        let secondConfiguration = try XCTUnwrap(alternatives.first { (try? text($0["FixtureId"])) == "second" })
        XCTAssertEqual(try name(firstConfiguration["BaseState"]), "Unchanged")
        XCTAssertEqual(try groupNames(firstConfiguration["ON"]), ["First A"])
        XCTAssertEqual(try groupNames(firstConfiguration["OFF"]), ["First B"])
        XCTAssertEqual(try groupNames(secondConfiguration["ON"]), [])
        XCTAssertEqual(try groupNames(secondConfiguration["OFF"]), ["Second A"])
        XCTAssertEqual(try values(firstConfiguration["Order"]).count, 2)
    }

    func testEmptyOptionalContentIsNormalizedAndInvalidReferencesLeavePlanUnchanged() throws {
        let empty = try fixture(empty: true)
        var plan = PDFCatalogGraphPlan()
        try PDFOptionalContentPreserver.addOptionalContent(from: [group(empty, output: 0)], to: &plan)
        let properties = try dictionary(plan.catalogEntries["OCProperties"])
        XCTAssertTrue(try values(properties["OCGs"]).isEmpty)
        XCTAssertEqual(try name(dictionary(properties["D"])["BaseState"]), "ON")
        XCTAssertTrue(plan.aliases.isEmpty)
        let first = try fixture(defaults: "/Intent /View")
        let conflicting = try fixture(defaults: "/Intent /Design")
        let invalid = try fixture(defaults: "/OFF [7 0 R]")
        for groups in [[group(first, output: 0), group(conflicting, output: 1)], [group(invalid, output: 0)]] {
            var unchanged = PDFCatalogGraphPlan()
            unchanged.catalogEntries["Sentinel"] = .boolean(true)
            XCTAssertThrowsError(try PDFOptionalContentPreserver.addOptionalContent(from: groups, to: &unchanged))
            XCTAssertNotNil(unchanged.catalogEntries["Sentinel"])
            XCTAssertNil(unchanged.catalogEntries["OCProperties"])
            XCTAssertTrue(unchanged.aliases.isEmpty)
            XCTAssertTrue(unchanged.retainedDocuments.isEmpty)
        }
    }

    private func group(_ document: PDFDocument, output: Int) -> PDFCatalogSourceGroup {
        PDFCatalogSourceGroup(document: document.documentRef!, pages: [PDFCatalogPageOrigin(sourceIndex: 0, outputIndex: output, livePage: document.page(at: 0)!)])
    }
    private func values(_ value: PDFCatalogGraphValue?) throws -> [PDFCatalogGraphValue] {
        guard case .array(let values) = value else { throw NSError(domain: "OptionalContentTests", code: 1) }
        return values
    }
    private func dictionary(_ value: PDFCatalogGraphValue?) throws -> [String: PDFCatalogGraphValue] {
        guard case .dictionary(let dictionary) = value else { throw NSError(domain: "OptionalContentTests", code: 2) }
        return dictionary
    }
    private func name(_ value: PDFCatalogGraphValue?) throws -> String {
        guard case .name(let name) = value else { throw NSError(domain: "OptionalContentTests", code: 3) }
        return name
    }
    private func text(_ value: PDFCatalogGraphValue?) throws -> String {
        switch value {
        case .string(let data):
            if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian)! }
            return String(decoding: data, as: UTF8.self)
        case .original(let original):
            var string: CGPDFStringRef?
            guard CGPDFObjectGetValue(original, .string, &string), let string, let text = CGPDFStringCopyTextString(string) else { throw NSError(domain: "OptionalContentTests", code: 4) }
            return text as String
        default: throw NSError(domain: "OptionalContentTests", code: 5)
        }
    }
    private func groupNames(_ value: PDFCatalogGraphValue?) throws -> [String] {
        try values(value).map {
            guard case .node(let node) = $0 else { throw NSError(domain: "OptionalContentTests", code: 6) }
            return try text(node.entries["Name"])
        }
    }
    private func fixture(defaults: String = "", alternate: String? = nil, prefix: String = "Layer",
                         usage: Bool = false, empty: Bool = false) throws -> PDFDocument {
        let use = usage ? "/Usage << /View << /ViewState /OFF >> /Print << /PrintState /ON >> >>" : ""
        let properties = empty ? "<< /D << /OFF [] >> >>" : "<< /OCGs [5 0 R 6 0 R] /D << \(defaults) >> \(alternate.map { "/Configs [<< \($0) >>]" } ?? "") >>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties \(properties) >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Properties << /LayerA 5 0 R /LayerB 6 0 R >> >> /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /OCG /Name (\(prefix) A) \(use) >>",
            "<< /Type /OCG /Name (\(prefix) B) \(use) >>",
            "<< /Type /OCG /Name (Undeclared) >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
