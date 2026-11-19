// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import Foundation
import PDFKit
import XCTest
import zlib
@testable import HwattakPDF

final class PDFWidgetEncodedAppearanceTests: XCTestCase {
    @MainActor
    func testFactoryExtractSnapshotAtomicKeepsEncodedAPAndPreciseNumbersAcrossRepeatSave() async throws {
        let data = try fixture(), original = try rawAppearance(data)
        XCTAssertEqual(original.filter, Data("/FlateDecode".utf8))
        XCTAssertEqual(original.bbox[2], Data("3:125.06700000000000001".utf8))
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let first = try await saved(extracted)
        XCTAssertEqual(try rawAppearance(first), original)
        let reopened = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: first))
        let second = try await saved(reopened)
        XCTAssertEqual(try rawAppearance(second), original)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.widgetStringValue, "Ada")
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.widgetStringValue, "Ada")
    }

    @MainActor
    func testFactoryMergeUndoRedoKeepsEncodedAPAndPreciseNumbers() async throws {
        let data = try fixture(), source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        let target = PDFDocument()
        let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0])
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: target, at: 0)
        try merge.apply(); try merge.undo(); try merge.redo()
        let result = try await saved(target)
        XCTAssertEqual(try rawAppearance(result), try rawAppearance(data))
    }

    @MainActor
    func testRealValueEditRetainsCurrentValueAndDoesNotReplayOldEncodedAppearance() async throws {
        let data = try fixture(), source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        let field = try XCTUnwrap(source.page(at: 0)?.annotations.first)
        field.widgetStringValue = "Grace"
        let saved = try await saved(source)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(data: saved)).page(at: 0)?.annotations.first?.widgetStringValue, "Grace")
        XCTAssertNotEqual(try rawAppearance(saved).encoded, try rawAppearance(data).encoded)
        XCTAssertEqual(field.widgetStringValue, "Grace")
    }

    @MainActor
    func testRealFontColorEditDoesNotReplayOldAppearance() async throws {
        let data = try fixture(), source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        let field = try XCTUnwrap(source.page(at: 0)?.annotations.first)
        field.fontColor = .blue
        let result = try await saved(source)
        XCTAssertNotEqual(try rawAppearance(result).encoded, try rawAppearance(data).encoded)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(data: result)).page(at: 0)?.annotations.first?.widgetStringValue, "Ada")
    }

    @MainActor
    func testFactoryKnownAPBeyondProofDepthFailsClosedAndKeepsDestination() async throws {
        let data = try fixture(deep: true), source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("destination.pdf"), sentinel = Data("existing destination".utf8)
        try sentinel.write(to: destination)
        let proof = try await Task.detached {
            let copy = try snapshot.takeDocument()
            do {
                _ = try PDFCatalogStructurePreserver.plan(for: copy)
                return "plan unexpectedly succeeded"
            } catch PDFPageStructurePreserver.Failure.unsupportedStructure {
                do { _ = try AtomicPDFWriter.write(copy, to: destination); return "write unexpectedly succeeded" }
                catch { return "unsupported plan and refused write" }
            }
        }.value
        XCTAssertEqual(proof, "unsupported plan and refused write")
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.widgetStringValue, "Ada")
    }

    @MainActor
    func testCancelledWidgetSaveKeepsDestinationAndSource() async throws {
        let data = try fixture(), source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        let snapshot = try PDFRecoverySnapshot(capturing: source), cancellation = PDFSaveCancellation()
        cancellation.cancel()
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("destination.pdf"), sentinel = Data("existing destination".utf8)
        try sentinel.write(to: destination)
        let refused = try await Task.detached {
            let copy = try snapshot.takeDocument()
            do { try PDFSaveCancellation.withCurrent(cancellation) { _ = try AtomicPDFWriter.write(copy, to: destination) }; return false }
            catch is CancellationError { return true }
        }.value
        XCTAssertTrue(refused)
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.widgetStringValue, "Ada")
    }

    @MainActor
    private func saved(_ source: PDFDocument) async throws -> Data {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("saved.pdf"), snapshot = try PDFRecoverySnapshot(capturing: source)
        return try await Task.detached {
            let copy = try snapshot.takeDocument()
            _ = try AtomicPDFWriter.write(copy, to: destination)
            return try Data(contentsOf: destination)
        }.value
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-encoded-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Appearance: Equatable {
        let encoded: Data
        let filter: Data
        let bbox: [Data]
        let matrix: [Data]
    }

    /// Independent QPDF C reader: compares original encoded payload and typed
    /// real spellings without CG/PDFKit reals or rendering as an equality oracle.
    private func rawAppearance(_ data: Data) throws -> Appearance {
        var status: Int32 = 0
        let context = try XCTUnwrap(data.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, data.count, data.count, 50_000, &status) })
        defer { ember_raw_pdf_destroy(context) }
        func check(_ result: Int32) throws { if result != 0 { throw NSError(domain: "RawWidgetAPTest", code: Int(result)) } }
        try check(status)
        func get(_ parent: EmberRawPDFObject, _ key: String) throws -> EmberRawPDFObject {
            var value: EmberRawPDFObject = 0; let bytes = Data(("/" + key).utf8)
            try bytes.withUnsafeBytes { try check(ember_raw_pdf_dictionary_get(context, parent, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, &value)) }; return value
        }
        func at(_ array: EmberRawPDFObject, _ index: UInt32) throws -> EmberRawPDFObject {
            var value: EmberRawPDFObject = 0; try check(ember_raw_pdf_array_item(context, array, index, &value)); return value
        }
        func copied(_ call: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> Int32) throws -> Data {
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0; try check(call(&pointer, &count)); defer { if let pointer { ember_raw_pdf_free(pointer) } }
            return pointer.map { Data(bytes: $0, count: count) } ?? Data()
        }
        var page: EmberRawPDFObject = 0; try check(ember_raw_pdf_page(context, 0, &page))
        let annotation = try at(get(page, "Annots"), 0), stream = try get(get(annotation, "AP"), "N")
        var dictionary: EmberRawPDFObject = 0; try check(ember_raw_pdf_stream_dictionary(context, stream, &dictionary))
        let encoded = try copied { ember_raw_pdf_stream_copy(context, stream, 1_024 * 1_024, nil, nil, $0, $1) }
        let filterObject = try get(dictionary, "Filter")
        var filterKind: Int32 = 0; try check(ember_raw_pdf_kind(context, filterObject, &filterKind))
        let filter = filterKind == Int32(EMBER_RAW_PDF_NAME.rawValue)
            ? try copied { ember_raw_pdf_name_copy(context, filterObject, $0, $1) } : Data("absent".utf8)
        func numbers(_ key: String, count: UInt32) throws -> [Data] {
            let array = try get(dictionary, key)
            var arrayKind: Int32 = 0; try check(ember_raw_pdf_kind(context, array, &arrayKind))
            if arrayKind == Int32(EMBER_RAW_PDF_NULL.rawValue) { return [] }
            return try (0..<count).map { index in
                let item = try at(array, index)
                var kind: Int32 = 0; try check(ember_raw_pdf_kind(context, item, &kind))
                let token = try copied { ember_raw_pdf_number_token_copy(context, item, $0, $1) }
                return Data(String(kind).utf8) + Data(":".utf8) + token
            }
        }
        return try Appearance(encoded: encoded, filter: filter, bbox: numbers("BBox", count: 4), matrix: numbers("Matrix", count: 6))
    }

    private func fixture(deep: Bool = false) throws -> Data {
        let program = Data("q 0.8 0.2 0.1 rg 0 0 125 25 re f 0 g BT /SourceFont 13 Tf 4 7 Td (CUSTOM AP) Tj ET Q\n".utf8)
        var length = compressBound(uLong(program.count)), compressed = Data(count: Int(compressBound(uLong(program.count))))
        let result = compressed.withUnsafeMutableBytes { destination in program.withUnsafeBytes { source in compress2(destination.bindMemory(to: UInt8.self).baseAddress, &length, source.bindMemory(to: UInt8.self).baseAddress, uLong(program.count), Z_BEST_COMPRESSION) } }
        XCTAssertEqual(result, Z_OK); compressed.count = Int(length)
        let extra = deep ? "/Extra " + String(repeating: "<< /Child ", count: 40) + "null " + String(repeating: ">> ", count: 40) : ""
        var objects = [
            Data("<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [4 0 R] >>".utf8),
            Data("<< /Type /Annot /Subtype /Widget /FT /Tx /T (student) /V (Ada) /Rect [30 100 180 125] /F 4 /DA (/SourceFont 13 Tf 0 g) /AP << /N 7 0 R >> >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>".utf8),
            Data("<< /Fields [4 0 R] /DA (/SourceFont 13 Tf 0 g) /DR << /Font << /SourceFont 5 0 R >> >> /NeedAppearances false >>".utf8)
        ]
        objects.append(Data("<< /Type /XObject /Subtype /Form /BBox [0 0 125.06700000000000001 25] /Matrix [1.0 0 0 1.0 0 0] /Resources << /Font << /SourceFont 5 0 R >> >> \(extra)/Filter /FlateDecode /Length \(compressed.count) >>\nstream\n".utf8) + compressed + Data("\nendstream".utf8))
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n".utf8)); data.append(object); data.append(Data("\nendobj\n".utf8)) }
        let xref = data.count; data.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)); return data
    }
}
