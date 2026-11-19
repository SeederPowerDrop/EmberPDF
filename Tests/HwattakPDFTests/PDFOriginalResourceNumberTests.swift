// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// WORK DRAFT ONLY. Actual source adoption/build/run requires root approval.
final class PDFOriginalResourceNumberTests: XCTestCase {
    @MainActor
    func testGuardedFileExtractionSavePreservesExactPatternNumbers() async throws {
        let input = temporaryURL(), output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        let bytes = fixture(step: "0.96")
        try bytes.write(to: input)
        let loaded = try PDFSourceFileAccess.loadDocument(at: input)
        try await saveExtracted(loaded.document, to: output)
        XCTAssertEqual(try patternNumbers(Data(contentsOf: output)), [0.96, 0.96, 0.96])
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: input), loaded.version)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 1)
    }

    @MainActor
    func testFreshExactDataFactoryExtractionSavePreservesExactPatternNumbers() async throws {
        let bytes = fixture(step: "0.96")
        // A caller-owned bytesNoCopy buffer is deliberately mutated after the
        // factory returns. Both native graph and raw proof must own the old bytes.
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        defer { pointer.deallocate() }
        bytes.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        let external = Data(bytesNoCopy: pointer, count: bytes.count, deallocator: .none)
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: external))
        let altered = fixture(step: "2.50")
        XCTAssertEqual(altered.count, bytes.count)
        altered.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: altered.count)
        let output = temporaryURL(); defer { try? FileManager.default.removeItem(at: output) }
        try await saveExtracted(source, to: output)
        XCTAssertEqual(try patternNumbers(Data(contentsOf: output)), [0.96, 0.96, 0.96])
        XCTAssertEqual(try patternNumbers(bytes), [0.96, 0.96, 0.96])
    }

    @MainActor
    func testWarmMainLookupDoesNotReadDeletedInputOrChangeEditingSnapshotAndRejectsForeignContainers() async throws {
        let input = temporaryURL(); defer { try? FileManager.default.removeItem(at: input) }
        let bytes = fixture(step: "0.96"); try bytes.write(to: input)
        let document = try PDFSourceFileAccess.loadDocument(at: input).document
        let page = try XCTUnwrap(document.page(at: 0)), native = try XCTUnwrap(page.pageRef)
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let pattern = try patternReferences(native)
        XCTAssertNil(try "XStep".withCString { try source.originalNumber(in: pattern.dictionary, key: $0) },
                     "A cold Main lookup cannot initialize an input/context.")
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        try await Task.detached { try source.preparePaintingResources(for: [native]) }.value
        try FileManager.default.removeItem(at: input)
        XCTAssertEqual(try effectiveNumber(source, in: pattern.dictionary, key: "XStep"), 0.96)
        XCTAssertEqual(try effectiveNumber(source, in: pattern.bbox, index: 2), 0.96)
        XCTAssertLessThanOrEqual(source.numberCorrectionFootprint.entries, 16_384)
        XCTAssertLessThanOrEqual(source.numberCorrectionFootprint.accountedBytes, 1_024 * 1_024)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before,
                       "Single-page editing encoding must not depend on optional raw cache availability.")
        let foreign = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: bytes as CFData)!))
        let other = try patternReferences(XCTUnwrap(foreign.page(at: 1)))
        XCTAssertNil(try "XStep".withCString { try source.originalNumber(in: other.dictionary, key: $0) })
        XCTAssertNil(try source.originalNumber(in: other.bbox, index: 2))
    }

    @MainActor
    func testArbitraryAndReboundFactoriesCannotMintOrReuseNumberAuthorityForDifferentBytes() async throws {
        let a = fixture(step: "0.96"), b = fixture(step: "2.5")
        let inputA = temporaryURL(), inputB = temporaryURL()
        try a.write(to: inputA); try b.write(to: inputB)
        defer { try? FileManager.default.removeItem(at: inputA); try? FileManager.default.removeItem(at: inputB) }
        let versionA = try PDFSourceFileVersion.capture(at: inputA)
        let versionB = try PDFSourceFileVersion.capture(at: inputB)
        for binding in 0..<5 {
            let document: PDFDocument
            switch binding {
            case 2: document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: a))
            case 3, 4: document = try XCTUnwrap(PDFRawStreamProvenance.documentForGuardedLoader(at: inputA, before: versionA))
            default: document = try XCTUnwrap(PDFDocument(data: a))
            }
            if binding == 1 || binding == 3 {
                PDFRawStreamProvenance.bindOpened(document, url: inputB, version: versionB)
            } else { PDFRawStreamProvenance.bindCreated(document, data: b) }
            if binding == 4 {
                // A generic data binding consumes any pending FILE token.
                PDFRawStreamProvenance.bindOpened(document, url: inputA, version: versionA)
            }
            let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
            let page = try XCTUnwrap(document.documentRef?.page(at: 1)), refs = try patternReferences(page)
            try await Task.detached { try source.preparePaintingResources(for: [page]) }.value
            XCTAssertNil(try "XStep".withCString { try source.originalNumber(in: refs.dictionary, key: $0) })
            XCTAssertNil(try source.originalNumber(in: refs.bbox, index: 2))
            XCTAssertEqual(source.numberCorrectionFootprint.entries, 0)
            if binding != 4 {
                XCTAssertNil(try source.payload(for: refs.stream), "Native A / data B remains a strict mismatch.")
            }
        }
        XCTAssertEqual(try Data(contentsOf: inputA), a)
        XCTAssertEqual(try Data(contentsOf: inputB), b)
    }

    @MainActor
    func testChangedFileBeforePreparationCannotPublishFactoryNumberCorrections() async throws {
        let input = temporaryURL(); defer { try? FileManager.default.removeItem(at: input) }
        let original = fixture(step: "0.96"), replacement = fixture(step: "2.5")
        try original.write(to: input)
        let loaded = try PDFSourceFileAccess.loadDocument(at: input)
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: loaded.document))
        let page = try XCTUnwrap(loaded.document.page(at: 0)?.pageRef), refs = try patternReferences(page)
        try replacement.write(to: input, options: .atomic)
        XCTAssertNotEqual(try PDFSourceFileVersion.capture(at: input), loaded.version)
        try await Task.detached { try source.preparePaintingResources(for: [page]) }.value
        XCTAssertEqual(source.numberCorrectionFootprint.entries, 0)
        XCTAssertNil(try source.originalNumber(in: refs.bbox, index: 2))
        XCTAssertNil(try source.payload(for: refs.stream))
        XCTAssertEqual(try Data(contentsOf: input), replacement, "The provenance reader never writes or repairs an input.")
    }

    @MainActor
    func testEditedReplacementPaintingKeepsItsCurrentPatternNumbers() async throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(step: "0.96")))
        let originalSource = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let originalPage = try XCTUnwrap(document.page(at: 0)?.pageRef)
        try await Task.detached { try originalSource.preparePaintingResources(for: [originalPage]) }.value
        let edited = try XCTUnwrap(PDFDocument(data: fixture(step: "1.25")))
        let replacement = try XCTUnwrap(edited.page(at: 0)?.copy() as? PDFPage)
        document.removePage(at: 0); document.insert(replacement, at: 0)
        let output = temporaryURL(); defer { try? FileManager.default.removeItem(at: output) }
        try await saveExtracted(document, to: output)
        XCTAssertEqual(try patternNumbers(Data(contentsOf: output)), [1.25, 1.25, 1.25],
                       "A new current resource graph cannot inherit old-container numeric authority.")
    }

    @MainActor
    func testCancelledPreparationDoesNotPublishNumberSlotsAndRetryCanSucceed() async throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(step: "0.96")))
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let page = try XCTUnwrap(document.page(at: 0)?.pageRef), refs = try patternReferences(page)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        do {
            try await Task.detached {
                try PDFSaveCancellation.withCurrent(cancellation) { try source.preparePaintingResources(for: [page]) }
            }.value
            XCTFail("Cancelled preparation must fail before publishing any map.")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(try source.originalNumber(in: refs.bbox, index: 2))
        XCTAssertEqual(source.numberCorrectionFootprint.entries, 0)
        try await Task.detached { try source.preparePaintingResources(for: [page]) }.value
        XCTAssertEqual(try effectiveNumber(source, in: refs.bbox, index: 2), 0.96)
    }

    @MainActor
    func testCorrectionBudgetRefusesWholePaintingTransactionWithoutPublishingPartialSlots() async throws {
        // Ten thousand distinct discrepancy slots exceed 1MiB accounting but
        // stay well below the existing parser/object/array visit limits.
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(step: "0.96", extraReals: 10_000)))
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let page = try XCTUnwrap(document.page(at: 0)?.pageRef), refs = try patternReferences(page)
        var parsed: CGPDFReal = 0
        XCTAssertTrue(CGPDFDictionaryGetNumber(refs.dictionary, "XStep", &parsed))
        try await Task.detached { try source.preparePaintingResources(for: [page]) }.value
        let footprint = source.numberCorrectionFootprint
        XCTAssertLessThanOrEqual(footprint.entries, 16_384)
        XCTAssertLessThanOrEqual(footprint.accountedBytes, 1_024 * 1_024)
        if Double(parsed) != 0.96 {
            XCTAssertEqual(footprint.entries, 0, "An over-budget page cannot publish earlier verified slots.")
            XCTAssertEqual(footprint.accountedBytes, 0)
            XCTAssertNil(try source.payload(for: refs.stream), "Painting/number proofs commit as one transaction.")
        } else {
            XCTAssertEqual(footprint.entries, 0, "An equal parser result never needs a correction record.")
        }
    }

    @MainActor
    private func saveExtracted(_ document: PDFDocument, to url: URL) async throws {
        let extracted = try PDFPageOperations.extract(from: document, indexes: [0])
        let snapshot = try PDFRecoverySnapshot(capturing: extracted)
        _ = try await Task.detached { try AtomicPDFWriter.write(snapshot.takeDocument(), to: url) }.value
    }

    private func effectiveNumber(_ source: PDFRawStreamSource, in dictionary: CGPDFDictionaryRef, key: String) throws -> Double {
        if let value = try key.withCString({ try source.originalNumber(in: dictionary, key: $0) }) {
            guard case let .real(number) = value else { throw TestFailure.notReal }
            return number
        }
        var number: CGPDFReal = 0
        guard key.withCString({ CGPDFDictionaryGetNumber(dictionary, $0, &number) }) else { throw TestFailure.notReal }
        return Double(number)
    }
    private func effectiveNumber(_ source: PDFRawStreamSource, in array: CGPDFArrayRef, index: Int) throws -> Double {
        if let value = try source.originalNumber(in: array, index: index) {
            guard case let .real(number) = value else { throw TestFailure.notReal }
            return number
        }
        var number: CGPDFReal = 0
        guard CGPDFArrayGetNumber(array, index, &number) else { throw TestFailure.notReal }
        return Double(number)
    }
    private enum TestFailure: Error { case notReal }
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("number-origin-\(UUID().uuidString).pdf")
    }
    private func patternReferences(_ page: CGPDFPage) throws -> (stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, bbox: CGPDFArrayRef) {
        var resources: CGPDFDictionaryRef?, patterns: CGPDFDictionaryRef?, stream: CGPDFStreamRef?, bbox: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(page.dictionary), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "Pattern", &patterns))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(patterns), "P12", &stream))
        let dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(XCTUnwrap(stream)))
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "BBox", &bbox))
        return (try XCTUnwrap(stream), dictionary, try XCTUnwrap(bbox))
    }
    private func patternNumbers(_ data: Data) throws -> [Double] {
        var status: Int32 = 0
        let created = data.withUnsafeBytes {
            ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, data.count, data.count, 10000, &status)
        }
        let context = try XCTUnwrap(created); defer { ember_raw_pdf_destroy(context) }
        XCTAssertEqual(status, Int32(EMBER_RAW_PDF_OK.rawValue))
        func get(_ parent: EmberRawPDFObject, _ name: String) -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0
            let bytes = Array(("/" + name).utf8)
            XCTAssertEqual(bytes.withUnsafeBufferPointer {
                ember_raw_pdf_dictionary_get(context, parent, $0.baseAddress, $0.count, &result)
            }, Int32(EMBER_RAW_PDF_OK.rawValue))
            return result
        }
        var page: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_page(context, 0, &page), Int32(EMBER_RAW_PDF_OK.rawValue))
        let stream = get(get(get(page, "Resources"), "Pattern"), "P12")
        var dictionary: EmberRawPDFObject = 0, coordinate: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_stream_dictionary(context, stream, &dictionary), Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(ember_raw_pdf_array_item(context, get(dictionary, "BBox"), 2, &coordinate), Int32(EMBER_RAW_PDF_OK.rawValue))
        return [coordinate, get(dictionary, "XStep"), get(dictionary, "YStep")].map {
            var value: Double = 0
            XCTAssertEqual(ember_raw_pdf_real(context, $0, &value), Int32(EMBER_RAW_PDF_OK.rawValue))
            return value
        }
    }
    private func fixture(step: String, extraReals: Int = 0) -> Data {
        let content = "/Pattern cs /P12 scn 0 0 90 40 re f"
        let pattern = "0.5 g 0 0 0.48 0.96 re f"
        let extra = extraReals == 0 ? "" : " /NumberProof [" + Array(repeating: "0.96", count: extraReals).joined(separator: " ") + "]"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Pattern << /P12 5 0 R >>\(extra) >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox 6 0 R /XStep \(step) /YStep \(step) /Resources << >> /Length \(pattern.utf8.count) >>\nstream\n\(pattern)\nendstream",
            "[0 0 \(step) 0.96]"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
