// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// An exact current-byte owner is a prerequisite for a future tag-only proof.
/// These tests deliberately grant no original painting or tag authority.
@MainActor
final class PDFBodyTextFactoryAuthorityTests: XCTestCase {
    func testActualEditorReplacementHasExactCurrentFactoryWithoutOldPaintingAuthority() throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let original = try XCTUnwrap(document.page(at: 0))
        try PDFCatalogStructurePreserver.prepare(document)
        let selection = try XCTUnwrap(document.findString("Original text", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: original, selection: selection))
        let replacement = try PDFBodyTextEditor.replacementPage(for: original, target: target,
            text: "Changed text", style: target.style, bounds: target.bounds)
        let currentReference = try XCTUnwrap(replacement.pageRef)
        let currentOwner = try XCTUnwrap(currentReference.document)
        let current = try XCTUnwrap(PDFRawStreamProvenance.source(for: replacement))
        XCTAssertTrue(current.provesExactFactoryOwner(currentOwner))
        XCTAssertFalse(current.provesExactFactoryOwner(try XCTUnwrap(document.documentRef)))
        XCTAssertTrue((replacement.string ?? "").contains("Changed text"))
        XCTAssertTrue((replacement.string ?? "").contains("Keep this line"))
        XCTAssertFalse((replacement.string ?? "").contains("Original text"))
        XCTAssertTrue((original.string ?? "").contains("Original text"))

        PDFCatalogStructurePreserver.inheritMetadata(from: original, to: replacement)
        let assembled = PDFDocument()
        assembled.insert(replacement, at: 0)
        let plan = try PDFCatalogStructurePreserver.plan(for: assembled)
        XCTAssertNil(plan.paintingSources[0], "Current-byte factory truth cannot revive old painting.")
    }

    func testGenericBindingCannotMintFactoryTruthFromMatchingOrForgedBytes() throws {
        let bytes = fixture()
        for supplied in [bytes, fixture(firstText: "Different text")] {
            let document = try XCTUnwrap(PDFDocument(data: bytes))
            let native = try XCTUnwrap(document.documentRef)
            PDFRawStreamProvenance.bindCreated(document, data: supplied)
            let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
            XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(document))
            XCTAssertFalse(raw.provesExactFactoryOwner(native))
            XCTAssertTrue((document.string ?? "").contains("Original text"))
        }
    }

    func testExactFactoryPageCopyInheritsOnlyItsUnchangedNativeDictionary() throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let page = try XCTUnwrap(document.page(at: 0))
        let owner = try XCTUnwrap(document.documentRef)
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: page))
        let copied = try XCTUnwrap(page.copy() as? PDFPage)
        let originalDictionary = try XCTUnwrap(page.pageRef?.dictionary)
        let copiedDictionary = try XCTUnwrap(copied.pageRef?.dictionary)
        XCTAssertTrue(originalDictionary == copiedDictionary,
                      "The production detached-copy path requires this exact native premise.")
        PDFRawStreamProvenance.inherit(from: page, to: copied)
        let inherited = try XCTUnwrap(PDFRawStreamProvenance.source(for: copied))
        XCTAssertTrue(inherited === raw)
        XCTAssertTrue(inherited.provesExactFactoryOwner(owner))
    }

    func testIdenticalBytesInAnotherNativeGraphCannotBorrowPageFactoryOwner() throws {
        let bytes = fixture()
        let original = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let foreign = try XCTUnwrap(PDFDocument(data: bytes))
        let page = try XCTUnwrap(original.page(at: 0))
        let otherPage = try XCTUnwrap(foreign.page(at: 0))
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: page))
        let originalDictionary = try XCTUnwrap(page.pageRef?.dictionary)
        let foreignDictionary = try XCTUnwrap(otherPage.pageRef?.dictionary)
        XCTAssertFalse(originalDictionary == foreignDictionary)
        XCTAssertNil(PDFRawStreamProvenance.source(for: otherPage))
        PDFRawStreamProvenance.inherit(from: page, to: otherPage)
        XCTAssertNil(PDFRawStreamProvenance.source(for: otherPage))
        XCTAssertFalse(raw.provesExactFactoryOwner(try XCTUnwrap(foreign.documentRef)))
    }

    private func fixture(firstText: String = "Original text") -> Data {
        let program = "/P << /MCID 0 >> BDC BT /F1 18 Tf 50 180 Td (\(firstText)) Tj ET EMC\n"
            + "/P << /MCID 1 >> BDC BT /F1 18 Tf 50 130 Td (Keep this line) Tj ET EMC"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo << /Marked true >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R /StructParents 0 >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(program.utf8.count) >>\nstream\n\(program)\nendstream",
            "<< /Type /StructTreeRoot /K [7 0 R 8 0 R] /ParentTree 9 0 R /ParentTreeNextKey 1 >>",
            "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 >>",
            "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 1 >>",
            "<< /Nums [0 [7 0 R 8 0 R]] >>"
        ]
        var result = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }
}
