// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import XCTest
@testable import HwattakPDF

final class PDFCatalogImageResourcePrunerTests: XCTestCase {
    func testInheritedSharedImageNamespaceUnionsAllSelectedPagesWithoutMutatingSource() throws {
        let source = try fixture(contents: ["q /ImA Do Q % /ImB Do\nBT (/ImB Do) Tj ET", "/ImB Do", "/ImC Do"])
        let pages = try [1, 3].map { try XCTUnwrap(source.page(at: $0)) }
        let xobjects = try namespace(source)
        let key = pdfReferenceIdentity(xobjects)
        var plan = PDFCatalogGraphPlan()
        plan.dictionaryDrops[key] = ["AlreadyDropped"]

        try PDFCatalogImageResourcePruner.addPrunedImageResources(pages: pages, to: &plan)

        XCTAssertEqual(plan.dictionaryDrops[key], ["ImB", "AlreadyDropped"])
        XCTAssertFalse(plan.dictionaryDrops[key]?.contains("ImA") ?? true)
        XCTAssertFalse(plan.dictionaryDrops[key]?.contains("ImC") ?? true)
        XCTAssertEqual(CGPDFDictionaryGetCount(xobjects), 3)
        var original: CGPDFObjectRef?
        XCTAssertTrue(CGPDFDictionaryGetObject(xobjects, "ImB", &original))
        XCTAssertNotNil(original, "Only the staged plan changes; the parser graph stays intact.")
    }

    func testComplexOrUnknownUseVetoesPruningForTheWholeSharedNamespace() throws {
        let variants: [(String, String, String, String)] = [
            ("/Pattern << >>", "", "", "/ImC Do"),
            ("/Font << /F1 << /Type /Font /Subtype /Type3 >> >>", "", "", "/ImC Do"),
            ("/ExtGState << /GS0 << /SMask << /S /Alpha /G 14 0 R >> >> >>", "", "", "/ImC Do"),
            ("", "/Annots []", "", "/ImC Do"),
            ("", "", "/SMask 14 0 R", "/ImC Do"),
            ("", "", "", "/ImC Do vendorPaint"),
            ("", "", "", "/Missing Do")
        ]
        for (extraResources, extraPage, extraImage, lastContent) in variants {
            let source = try fixture(contents: ["/ImA Do", "/ImB Do", lastContent],
                extraResources: extraResources, lastPageExtra: extraPage, imageExtra: extraImage)
            var plan = PDFCatalogGraphPlan()
            plan.dictionaryDrops[UInt.max] = ["sentinel"]

            try PDFCatalogImageResourcePruner.addPrunedImageResources(
                pages: [try XCTUnwrap(source.page(at: 1)), try XCTUnwrap(source.page(at: 3))], to: &plan)

            XCTAssertEqual(plan.dictionaryDrops.count, 1)
            XCTAssertEqual(plan.dictionaryDrops[UInt.max], ["sentinel"])
        }
        let formSource = try fixture(extraXObject: "/Form0 14 0 R")
        var plan = PDFCatalogGraphPlan()
        try PDFCatalogImageResourcePruner.addPrunedImageResources(
            pages: [try XCTUnwrap(formSource.page(at: 1))], to: &plan)
        XCTAssertTrue(plan.dictionaryDrops.isEmpty)
    }

    func testLimitFailureLeavesAllExistingPlanEntriesUntouched() throws {
        let source = try fixture(contents: ["/ImA Do", "/ImB Do", String(repeating: "q Q ", count: 32) + "/ImC Do"])
        var tokenLimit = PDFCatalogImageResourcePruner.Limits()
        tokenLimit.maximumTokens = 8
        var byteLimit = PDFCatalogImageResourcePruner.Limits()
        byteLimit.maximumDecodedBytes = 1
        var visitLimit = PDFCatalogImageResourcePruner.Limits()
        visitLimit.maximumVisits = 1
        for limits in [tokenLimit, byteLimit, visitLimit] {
            var plan = PDFCatalogGraphPlan()
            plan.dictionaryDrops[UInt.max] = ["sentinel"]
            XCTAssertThrowsError(try PDFCatalogImageResourcePruner.addPrunedImageResources(
                pages: [try XCTUnwrap(source.page(at: 1)), try XCTUnwrap(source.page(at: 3))],
                to: &plan, limits: limits))
            XCTAssertEqual(plan.dictionaryDrops.count, 1)
            XCTAssertEqual(plan.dictionaryDrops[UInt.max], ["sentinel"])
            XCTAssertEqual(CGPDFDictionaryGetCount(try namespace(source)), 3)
        }
    }

    private func namespace(_ document: CGPDFDocument) throws -> CGPDFDictionaryRef {
        let page = try XCTUnwrap(document.page(at: 1)?.dictionary)
        var parent: CGPDFDictionaryRef?, resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(page, "Parent", &parent))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(parent), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &xobjects))
        return try XCTUnwrap(xobjects)
    }

    private func fixture(contents: [String] = ["/ImA Do", "/ImB Do", "/ImC Do"],
                         extraResources: String = "", lastPageExtra: String = "", imageExtra: String = "",
                         extraXObject: String = "") throws -> CGPDFDocument {
        func stream(_ data: String, entries: String = "") -> String {
            "<< /Length \(data.utf8.count) \(entries) >>\nstream\n\(data)\nendstream"
        }
        let defaultState = extraResources.contains("/ExtGState") ? "" :
            "/ExtGState << /GS0 << /Type /ExtGState /CA 1 /ca 1 /BM /Normal >> >>"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /Resources 6 0 R /MediaBox [0 0 100 100] >>"
        ]
        objects += (0..<3).map { "<< /Type /Page /Parent 2 0 R /Contents \(7 + $0) 0 R \($0 == 2 ? lastPageExtra : "") >>" }
        objects.append("<< /XObject 10 0 R \(defaultState) \(extraResources) >>")
        objects += contents.map { stream($0) }
        objects.append("<< /ImA 11 0 R /ImB 12 0 R /ImC 13 0 R \(extraXObject) >>")
        for color in ["rgb", "RGB", "abc"] {
            objects.append(stream(color, entries: "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 \(imageExtra)"))
        }
        objects.append(stream("/ImB Do", entries: "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources 6 0 R"))
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGPDFDocument(provider))
    }
}
