// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFSerializationCrossReferenceRepairTests: XCTestCase {
    func testMemoryRepairChangesOnlyTheZeroOffsetFlagAndIsIdempotent() throws {
        for crlf in [false, true] {
            let original = fixture(crlf: crlf)
            let repaired = PDFSerializationCrossReferenceRepair.repair(original)
            XCTAssertEqual(repaired.count, original.count)
            let differences = original.indices.filter { original[$0] != repaired[$0] }
            XCTAssertEqual(differences.count, 1)
            let offset = try XCTUnwrap(differences.first)
            XCTAssertEqual(original[offset], 110); XCTAssertEqual(repaired[offset], 102)
            XCTAssertEqual(PDFSerializationCrossReferenceRepair.repair(repaired), repaired)
        }
    }

    func testFileRepairKeepsEveryOtherByteAndFileLength() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("staged.pdf"), original = fixture()
        try original.write(to: url)
        XCTAssertTrue(try PDFSerializationCrossReferenceRepair.repair(at: url))
        XCTAssertEqual(try Data(contentsOf: url), PDFSerializationCrossReferenceRepair.repair(original))
        XCTAssertFalse(try PDFSerializationCrossReferenceRepair.repair(at: url))
    }

    func testProtectedAndIncrementalFilesRemainUntouched() throws {
        let protected = [
            fixture(trailer: "/Encrypt 4 0 R"),
            fixture(trailer: "/Encr#79pt 4 0 R"),
            fixture(trailer: "/Prev 9"),
            fixture(trailer: "/XRefStm 9"),
            fixture(catalog: "/Perms << /DocMDP 4 0 R >>"),
            fixture(catalog: "/DSS << >>"),
            fixture(catalog: "/AcroForm << /SigFlags 1 /Fields [] >>"),
            fixture(catalog: "/AcroForm << /Fields [4 0 R] >>",
                    objects: ["<< /FT /Sig /V << /Type /Sig /ByteRange [0 1 2 3] /Contents <> >> >>"]),
            fixture(catalog: "/AcroForm << /Fields [4 0 R] >>",
                    objects: ["<< /FT /Tx /V << /Type 42 >> >>"])
        ]
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, bytes) in protected.enumerated() {
            XCTAssertEqual(PDFSerializationCrossReferenceRepair.repair(bytes), bytes, "Case \(index)")
            let url = directory.appendingPathComponent("protected-\(index).pdf")
            try bytes.write(to: url)
            XCTAssertFalse(try PDFSerializationCrossReferenceRepair.repair(at: url), "Case \(index)")
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testMalformedOrUnsupportedCrossReferencesAreNeverGuessed() throws {
        let original = fixture(), text = String(decoding: original, as: UTF8.self)
        let malformed = [
            original + Data("garbage".utf8),
            Data(text.replacingOccurrences(of: "0 5\n", with: "0 6\n").utf8),
            Data(text.replacingOccurrences(of: "0000000000 00000 n", with: "0000000000 00001 n").utf8),
            Data(text.replacingOccurrences(of: "0000000000 65535 f", with: "0000000000 65535 n").utf8),
            Data(text.replacingOccurrences(of: "/Size 5", with: "/Size 6").utf8),
            Data(text.replacingOccurrences(of: "/Size 5", with: "/Size 5 /Size 5").utf8),
            Data(text.replacingOccurrences(of: "xref\n0 5", with: "oops\n0 5").utf8),
            Data(text.replacingOccurrences(of: "0000000009 00000 n", with: "0000000010 00000 n").utf8)
        ]
        for (index, bytes) in malformed.enumerated() {
            XCTAssertEqual(PDFSerializationCrossReferenceRepair.repair(bytes), bytes, "Case \(index)")
        }
        var prefixed = Data([0]); prefixed.append(original)
        let slice = prefixed.dropFirst()
        XCTAssertEqual(PDFSerializationCrossReferenceRepair.repair(slice), slice)
    }

    func testOrdinaryOneGiBSparseFileNeedsNoWholeFileData() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ordinary-large.pdf")
        let ordinary = fixture(zeroInUse: false)
        let startMarker = try XCTUnwrap(ordinary.range(of: Data("xref\n".utf8)))
        let body = ordinary.prefix(upTo: startMarker.lowerBound)
        let oldSuffix = String(decoding: ordinary.suffix(from: startMarker.lowerBound), as: UTF8.self)
        let xrefOffset = 1_073_741_824
        let suffix = oldSuffix.replacingOccurrences(of: "startxref\n\(startMarker.lowerBound)", with: "startxref\n\(xrefOffset)")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forUpdating: url)
        try handle.write(contentsOf: body)
        try handle.truncate(atOffset: UInt64(xrefOffset))
        try handle.seek(toOffset: UInt64(xrefOffset))
        try handle.write(contentsOf: Data(suffix.utf8)); try handle.close()
        let expectedLength = xrefOffset + suffix.utf8.count
        XCTAssertFalse(try PDFSerializationCrossReferenceRepair.repair(at: url))
        let verify = try FileHandle(forReadingFrom: url)
        XCTAssertEqual(try verify.seekToEnd(), UInt64(expectedLength))
        try verify.seek(toOffset: UInt64(xrefOffset))
        XCTAssertEqual(try verify.readToEnd(), Data(suffix.utf8)); try verify.close()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ember-xref-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixture(crlf: Bool = false, zeroInUse: Bool = true, trailer: String = "",
                         catalog: String = "", objects additional: [String] = []) -> Data {
        let objects = ["<< /Type /Catalog /Pages 2 0 R \(catalog) >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>"] + additional
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let start = bytes.count, count = objects.count + 2
        bytes.append(Data("xref\n0 \(count)\n".utf8))
        func entry(_ offset: Int, _ generation: Int, _ flag: String) -> Data {
            Data((String(format: "%010d %05d %@", offset, generation, flag) + (crlf ? "\r\n" : " \n")).utf8)
        }
        bytes.append(entry(0, 65_535, "f"))
        for offset in offsets.dropFirst() { bytes.append(entry(offset, 0, "n")) }
        bytes.append(entry(0, 0, zeroInUse ? "n" : "f"))
        bytes.append(Data("trailer\n<< /Size \(count) /Root 1 0 R \(trailer) >>\nstartxref\n\(start)\n%%EOF\n".utf8))
        return bytes
    }
}
