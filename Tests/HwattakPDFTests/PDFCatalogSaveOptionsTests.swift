// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFCatalogSaveOptionsTests: XCTestCase {
    func testPlainNativeAssemblyCanStillUseExistingEncryptedSave() throws {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let source = try XCTUnwrap(PDFDocument(data: bytes as Data))
        let assembled = try PDFPageOperations.extract(from: source, indexes: [0])
        XCTAssertTrue(PDFCatalogStructurePreserver.needsMaterialization(assembled))
        XCTAssertFalse(PDFCatalogStructurePreserver.requiresCatalogSemantics(assembled))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Encrypted.pdf")
        try ProtectedPDFExporter.export(document: assembled, sourceURL: nil, to: url,
                                        userPassword: "Assembly78")
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(reopened.isEncrypted)
        XCTAssertTrue(reopened.isLocked)
        XCTAssertTrue(reopened.unlock(withPassword: "Assembly78"))
        XCTAssertEqual(reopened.pageCount, 1)
    }
}
