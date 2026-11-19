// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFCatalogNameTreeLimitsTests: XCTestCase {
    func testSharedChildrenAndCyclesFailWithoutExpandingTheNameTree() throws {
        for kids in ["6 0 R 6 0 R", "5 0 R"] {
            let document = try fixture(kids: kids)
            try PDFCatalogStructurePreserver.prepare(document, force: true)
            XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document))
            XCTAssertFalse(PDFCatalogStructurePreserver.needsMaterialization(document),
                "Inspecting a bad source tree must not mark or serialize the source.")
        }
    }

    func testValidLeafKeepsItsKeyAndAnOversizedKeyIsRejected() throws {
        let document = try fixture()
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: document)
        guard case .dictionary(let names)? = plan.catalogEntries["Names"],
              case .dictionary(let embedded)? = names["EmbeddedFiles"],
              case .array(let entries)? = embedded["Names"], entries.count == 2,
              case .string(let key) = entries[0] else { return XCTFail("Expected the original bounded name tree.") }
        XCTAssertEqual(key, Data("attachment.txt".utf8))
        let oversized = try fixture(key: String(repeating: "a", count: 1_024 * 1_024 + 1))
        try PDFCatalogStructurePreserver.prepare(oversized, force: true)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: oversized))
    }

    private func fixture(kids: String = "6 0 R", key: String = "attachment.txt") throws -> PDFDocument {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 5 0 R >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Kids [\(kids)] >>",
            "<< /Names [(\(key)) 7 0 R] >>",
            "<< /Type /Filespec /F (attachment.txt) /EF << /F 8 0 R >> >>",
            "<< /Type /EmbeddedFile /Length 1 >>\nstream\nx\nendstream"
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
