// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// WORK DRAFT: three synthetic points only; contains no user PDF/signature data.
enum InkNameRoundingTestFixture {
    static let name = Data("synthetic-three-point-ink".utf8)
    struct Instance { let data: Data; let document: PDFDocument }
    struct Stage {
        let owner: CGPDFDocument
        let annotations: CGPDFArrayRef
        let first: CGPDFDictionaryRef
    }
    enum Failure: Error { case invalid }

    @MainActor static func make(named: Bool = true, changedPoint: Bool = false) throws -> Instance {
        // Integer origin10/20 keeps the page-to-local operation visible. The
        // chosen noninteger literals include53.9 (not copied signature data).
        let first = changedPoint ? "54.15" : "53.9"
        let nm = named ? "/NM <\(name.map { String(format: "%02x", $0) }.joined())>" : ""
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R /Annots [5 0 R] >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Annot /Subtype /Ink /Rect [10 20 90 100] /InkList [[\(first) 44.8 62.4 74.2 77.1 35.6]] /C [1 0 0] /BS << /W 1 >> \(nm) >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let document = try XCTUnwrap(PDFDocument(data: data))
        PDFRawStreamProvenance.bindCreated(document, data: data)
        return Instance(data: data, document: document)
    }

    static func stage(_ bytes: Data) throws -> Stage {
        let owner = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: bytes as CFData))))
        let page = try XCTUnwrap(owner.page(at: 1)?.dictionary)
        let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        XCTAssertEqual(CGPDFArrayGetCount(annotations), 1)
        var first: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &first))
        return Stage(owner: owner, annotations: annotations, first: try XCTUnwrap(first))
    }

    static func values(_ value: PDFPageGeometryPreserver.Numbers) -> [Double] {
        switch value {
        case .value(let value): return [value]
        case .array(let values): return values.flatMap(self.values)
        }
    }
    static func bits(_ values: [Double]) -> [UInt64] { values.map(\.bitPattern) }

    /// Independent numeric reader for the writer's chosen geometry. Comparing
    /// doubles via QPDF avoids a second CG decimal parse changing the observer.
    static func stored(_ data: Data) throws -> (name: Data?, ink: [Double]) {
        var status: Int32 = 0
        let raw = data.withUnsafeBytes {
            ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, data.count, data.count, 10_000, &status)
        }
        let owner = try XCTUnwrap(raw); defer { ember_raw_pdf_destroy(owner) }
        XCTAssertEqual(status, Int32(EMBER_RAW_PDF_OK.rawValue))
        func get(_ parent: EmberRawPDFObject, _ key: String) throws -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0; let bytes = Data(("/" + key).utf8)
            let resultStatus = bytes.withUnsafeBytes {
                ember_raw_pdf_dictionary_get(owner, parent, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &result)
            }
            guard resultStatus == Int32(EMBER_RAW_PDF_OK.rawValue) else { throw Failure.invalid }
            return result
        }
        var page: EmberRawPDFObject = 0, annotation: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_page(owner, 0, &page), Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(ember_raw_pdf_array_item(owner, try get(page, "Annots"), 0, &annotation), Int32(EMBER_RAW_PDF_OK.rawValue))
        let nameObject = try get(annotation, "NM"); var kind: Int32 = 0
        XCTAssertEqual(ember_raw_pdf_kind(owner, nameObject, &kind), Int32(EMBER_RAW_PDF_OK.rawValue))
        var name: Data?
        if kind != Int32(EMBER_RAW_PDF_NULL.rawValue) {
            guard kind == Int32(EMBER_RAW_PDF_STRING.rawValue) else { throw Failure.invalid }
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let result = ember_raw_pdf_string_copy(owner, nameObject, &pointer, &count)
            defer { if let pointer { ember_raw_pdf_free(pointer) } }
            guard result == Int32(EMBER_RAW_PDF_OK.rawValue), count <= 1024, count == 0 || pointer != nil else { throw Failure.invalid }
            name = pointer.map { Data(bytes: $0, count: count) } ?? Data()
        }
        func flatten(_ object: EmberRawPDFObject, depth: Int) throws -> [Double] {
            guard depth <= 3 else { throw Failure.invalid }
            var kind: Int32 = 0
            XCTAssertEqual(ember_raw_pdf_kind(owner, object, &kind), Int32(EMBER_RAW_PDF_OK.rawValue))
            if kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue) {
                var count: UInt32 = 0
                XCTAssertEqual(ember_raw_pdf_array_count(owner, object, &count), Int32(EMBER_RAW_PDF_OK.rawValue))
                guard count <= 16 else { throw Failure.invalid }
                return try (0..<count).flatMap { index in
                    var item: EmberRawPDFObject = 0
                    XCTAssertEqual(ember_raw_pdf_array_item(owner, object, index, &item), Int32(EMBER_RAW_PDF_OK.rawValue))
                    return try flatten(item, depth: depth + 1)
                }
            }
            if kind == Int32(EMBER_RAW_PDF_INTEGER.rawValue) {
                var value: Int64 = 0
                XCTAssertEqual(ember_raw_pdf_integer(owner, object, &value), Int32(EMBER_RAW_PDF_OK.rawValue)); return [Double(value)]
            }
            guard kind == Int32(EMBER_RAW_PDF_REAL.rawValue) else { throw Failure.invalid }
            var value: Double = 0
            XCTAssertEqual(ember_raw_pdf_real(owner, object, &value), Int32(EMBER_RAW_PDF_OK.rawValue)); return [value]
        }
        let inkObject = try get(annotation, "InkList")
        return (name, try flatten(inkObject, depth: 0))
    }
}
