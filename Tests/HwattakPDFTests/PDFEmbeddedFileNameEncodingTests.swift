// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFEmbeddedFileNameEncodingTests: XCTestCase {
    private let mixed = "(zeta.txt) 6 0 R <FEFF0061006C007000680061002E007400780074> 7 0 R"

    func testMixedTextKeysUseACommonEncodingAndKeepFileSpecifications() throws {
        let source = try fixture(names: mixed, extra: "/AcroForm << /Fields [] /DA (/Helv 0 Tf) /DR << >> >>")
        let pairs = try names(source)
        XCTAssertEqual(try keys(pairs), [unicode("alpha.txt"), unicode("zeta.txt")])
        XCTAssertEqual(try fileName(pairs[1]), "alpha.bin")
        XCTAssertEqual(try fileName(pairs[3]), "zeta.bin")
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmbeddedNameEncoding-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("Mixed.pdf")
        try AtomicPDFWriter.write(extracted, to: output)
        let native = try XCTUnwrap(CGPDFDocument(output as CFURL))
        let catalog = try XCTUnwrap(native.catalog)
        let tree = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(
            XCTUnwrap(PDFCatalogStructurePreserver.dictionary(catalog, "Names")), "EmbeddedFiles"))
        let entries = try XCTUnwrap(PDFCatalogStructurePreserver.array(tree, "Names"))
        let raw = try stride(from: 0, to: CGPDFArrayGetCount(entries), by: 2).map { index -> Data in
            var string: CGPDFStringRef?
            XCTAssertTrue(CGPDFArrayGetString(entries, index, &string))
            let value = try XCTUnwrap(string)
            return Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(value)), count: CGPDFStringGetLength(value))
        }
        XCTAssertEqual(raw, [unicode("alpha.txt"), unicode("zeta.txt")])
        XCTAssertTrue(raw[0].lexicographicallyPrecedes(raw[1]), "The serialized tree is sorted by its actual unsigned key bytes.")
        if let directory = ProcessInfo.processInfo.environment["EMBER_NAME_ENCODING_QA_DIRECTORY"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try AtomicPDFWriter.write(extracted, to: destination.appendingPathComponent("mixed-embedded-name-keys.pdf"))
        }
    }

    func testEqualDecodedNamesKeepTheirDistinctRawKeysAndValues() throws {
        let source = try fixture(names: "(chapter) 6 0 R <FEFF0063006800610070007400650072> 7 0 R")
        let pairs = try names(source)
        XCTAssertEqual(try keys(pairs), [Data("chapter".utf8), unicode("chapter")])
        XCTAssertEqual(try fileName(pairs[1]), "zeta.bin")
        XCTAssertEqual(try fileName(pairs[3]), "alpha.bin")
    }

    func testNamedEmbeddedNavigationKeepsOriginalKeyBytes() throws {
        for (extra, namedActions) in [("/OpenAction << /S /GoToE /T << /R /C /N (zeta.txt) >> /D [0 /Fit] >>", ""),
                      ("/Collection << /Type /Collection /D (zeta.txt) >>", ""),
                      ("/AcroForm << /Fields [<< /FT /Tx /T (field) >>] >>", ""),
                      ("", "/JavaScript << /Names [(script) << /S /JavaScript /JS (app.alert) >>] >>")] {
            let source = try fixture(names: mixed, extra: extra, namedActions: namedActions)
            XCTAssertEqual(try keys(names(source)), [Data("zeta.txt".utf8), unicode("alpha.txt")])
        }
    }

    func testSupplementaryScalarOrderingDoesNotOverrideByteOrdering() throws {
        let source = try fixture(names: "<FEFFD800DC00> 6 0 R <FEFFE000> 7 0 R")
        XCTAssertEqual(try keys(names(source)), [Data([0xfe, 0xff, 0xd8, 0, 0xdc, 0]), Data([0xfe, 0xff, 0xe0, 0])])
    }

    private func unicode(_ text: String) -> Data { Data([0xfe, 0xff]) + text.data(using: .utf16BigEndian)! }
    private func names(_ source: PDFDocument) throws -> [PDFCatalogGraphValue] {
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: source)
        guard case .dictionary(let names)? = plan.catalogEntries["Names"],
              case .dictionary(let tree)? = names["EmbeddedFiles"],
              case .array(let entries)? = tree["Names"] else { throw FixtureFailure.invalid }
        return entries
    }
    private func keys(_ pairs: [PDFCatalogGraphValue]) throws -> [Data] {
        try stride(from: 0, to: pairs.count, by: 2).map {
            guard case .string(let bytes) = pairs[$0] else { throw FixtureFailure.invalid }; return bytes
        }
    }
    private func fileName(_ value: PDFCatalogGraphValue) throws -> String {
        guard case .original(let object) = value else { throw FixtureFailure.invalid }
        var dictionary: CGPDFDictionaryRef?, string: CGPDFStringRef?
        XCTAssertTrue(CGPDFObjectGetValue(object, .dictionary, &dictionary))
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(dictionary), "F", &string))
        return try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(string))) as String
    }
    private func fixture(names: String, extra: String = "", namedActions: String = "") throws -> PDFDocument {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 5 0 R \(namedActions) >> \(extra) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream", "<< /Names [\(names)] >>",
            "<< /Type /Filespec /F (zeta.bin) /EF << /F 8 0 R >> >>",
            "<< /Type /Filespec /F (alpha.bin) /EF << /F 9 0 R >> >>",
            "<< /Type /EmbeddedFile /Length 1 >>\nstream\nZ\nendstream",
            "<< /Type /EmbeddedFile /Length 1 >>\nstream\nA\nendstream"
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
    private enum FixtureFailure: Error { case invalid }
}
