// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import CoreGraphics
import Foundation
import PDFKit
import XCTest
import zlib
@testable import HwattakPDF

final class PDFRawFlateBlankProofTests: XCTestCase {
    private struct Proof: Sendable { let empty: Bool; let remaining: Int }
    private struct Copy {
        let status: Int32
        let bytes: Data
        let encodedCount: Int
        let reportedCount: Int
        let pointerWasNil: Bool
    }
    private final class CancellationCounter {
        var calls = 0
        let stop: Int
        init(_ stop: Int) { self.stop = stop }
    }
    private final class Request: @unchecked Sendable {
        let native: CGPDFDocument
        let source: PDFRawStreamSource?
        init(_ native: CGPDFDocument, _ source: PDFRawStreamSource?) { self.native = native; self.source = source }
        func run(budget: Int = 4_096, cancellation: PDFSaveCancellation? = nil) throws -> Proof {
            var remaining = budget
            let page = try XCTUnwrap(native.page(at: 1))
            let operation = { try self.source?.provesEmptyPageContents(for: page, remainingEncodedBytes: &remaining) ?? false }
            let empty = try cancellation.map { try PDFSaveCancellation.withCurrent($0, operation) } ?? operation()
            return Proof(empty: empty, remaining: remaining)
        }
    }

    @MainActor
    func testCoreGraphicsCompressedBlankHasRetryableMainMissAndChargesEncodedCost() async throws {
        let bytes = try coreGraphicsPage(painted: false)
        let request = try request(bytes)
        let nativePage = try XCTUnwrap(request.native.page(at: 1))
        let dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(try stream(nativePage)))
        var filter: UnsafePointer<CChar>?, encodedLength: CGPDFInteger = 0
        XCTAssertTrue(CGPDFDictionaryGetName(dictionary, "Filter", &filter))
        XCTAssertEqual(String(cString: try XCTUnwrap(filter)), "FlateDecode")
        XCTAssertTrue(CGPDFDictionaryGetInteger(dictionary, "Length", &encodedLength))
        XCTAssertGreaterThan(encodedLength, 0)
        XCTAssertLessThanOrEqual(encodedLength, 4_096)
        let decoded = try copy(bytes)
        XCTAssertEqual(decoded.status, Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(decoded.encodedCount, encodedLength)
        XCTAssertTrue(try PDFEmptyContentTokens.provesEmpty(decoded.bytes))
        let cost = max(decoded.encodedCount, decoded.bytes.count)
        XCTAssertGreaterThan(cost, 0)
        let cold = try request.run()
        XCTAssertFalse(cold.empty, "The new decoder must not make a cold Main query initialize the reader.")
        XCTAssertEqual(cold.remaining, 4_096)
        let worker = try await Task.detached { try request.run() }.value
        XCTAssertTrue(worker.empty)
        XCTAssertEqual(worker.remaining, 4_096 - cost)
        let warm = try request.run()
        XCTAssertTrue(warm.empty)
        XCTAssertEqual(warm.remaining, worker.remaining)
        let insufficient = try request.run(budget: cost - 1)
        XCTAssertFalse(insufficient.empty)
        XCTAssertEqual(insufficient.remaining, cost - 1)
    }

    @MainActor
    func testCompressedPaintingIsRejectedAndGeneralRawCopyKeepsEncodedBytes() async throws {
        let painting = Data("q 0 0 12 12 re f Q".utf8)
        let encoded = try compressed(painting)
        let bytes = fixture(streams: [encoded])
        let raw = try copy(bytes, decoded: false)
        XCTAssertEqual(raw.status, Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(raw.bytes, encoded)
        XCTAssertNotEqual(raw.bytes, painting)
        let decoded = try copy(bytes)
        XCTAssertEqual(decoded.status, Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(decoded.bytes, painting)
        XCTAssertFalse(try PDFEmptyContentTokens.provesEmpty(decoded.bytes))
        let request = try request(bytes)
        let proof = try await Task.detached { try request.run() }.value
        XCTAssertFalse(proof.empty)
        XCTAssertEqual(proof.remaining, 4_096)
        XCTAssertEqual(try copy(bytes, decoded: false).bytes, encoded,
                       "A failed blank proof must not replace the general encoded-copy payload.")
    }

    @MainActor
    func testMalformedCRCTruncatedTrailingAndUnsupportedControlsPublishNoBytes() async throws {
        let valid = try compressed(Data("q Q".utf8))
        var crc = valid; crc[crc.count - 1] ^= 1
        var badHeader = valid; badHeader[0] = 0
        let malformed = [crc, Data(valid.dropLast()), valid + Data([0]), valid + valid, badHeader]
        for (index, encoded) in malformed.enumerated() {
            let bytes = fixture(streams: [encoded])
            assertRefused(try copy(bytes), "malformed \(index)")
            let request = try request(bytes)
            let proof = try await Task.detached { try request.run() }.value
            XCTAssertFalse(proof.empty, "malformed \(index)")
            XCTAssertEqual(proof.remaining, 4_096)
        }
        let unsupported = [
            "/Filter [/FlateDecode]", "/Filter /Fl", "/Filter /ASCIIHexDecode", "/Filter /FlateDecode /DecodeParms << >>",
            "/Filter /FlateDecode /F (never-open-this-file.pdf)",
            "/Filter /FlateDecode /FFilter /FlateDecode", "/Filter /FlateDecode /FDecodeParms << >>"]
        for (index, keys) in unsupported.enumerated() {
            let bytes = fixture(streams: [valid], streamKeys: keys)
            assertRefused(try copy(bytes), "unsupported \(index)")
            let request = try request(bytes)
            let proof = try await Task.detached { try request.run() }.value
            XCTAssertFalse(proof.empty, "unsupported \(index)")
            XCTAssertEqual(proof.remaining, 4_096)
        }
        let explicitNull = fixture(streams: [valid], streamKeys:
            "/Filter /FlateDecode /DecodeParms null /F null /FFilter null /FDecodeParms null")
        XCTAssertEqual(try copy(explicitNull).status, Int32(EMBER_RAW_PDF_OK.rawValue))
        let nullRequest = try request(explicitNull)
        let nullProof = try await Task.detached { try nullRequest.run() }.value
        XCTAssertTrue(nullProof.empty)
        let empty = try copy(fixture(streams: [compressed(Data())]))
        XCTAssertEqual(empty.status, Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(empty.bytes.count, 0)
        XCTAssertGreaterThan(empty.encodedCount, 0, "An empty decoded payload still consumes original encoded bytes.")
    }

    @MainActor
    func testEncodedDecodedAndAggregateBudgetsRejectExpansionBeforePublishing() async throws {
        let exact = fixture(streams: [try compressed(Data(repeating: 32, count: 4_096))])
        let boundary = try copy(exact)
        XCTAssertEqual(boundary.status, Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(boundary.bytes.count, 4_096)
        let boundaryRequest = try request(exact)
        let boundaryProof = try await Task.detached { try boundaryRequest.run() }.value
        XCTAssertTrue(boundaryProof.empty)
        XCTAssertEqual(boundaryProof.remaining, 0)
        let bomb = fixture(streams: [try compressed(Data(repeating: 32, count: 65_536))])
        let bombCopy = try copy(bomb)
        XCTAssertEqual(bombCopy.status, Int32(EMBER_RAW_PDF_LIMIT.rawValue))
        assertRefused(bombCopy, "bounded expansion")
        let overEncoded = fixture(streams: [Data(repeating: 32, count: 4_097)])
        XCTAssertEqual(try copy(overEncoded).status, Int32(EMBER_RAW_PDF_LIMIT.rawValue))
        assertRefused(try copy(overEncoded), "encoded length before inflate")
        XCTAssertEqual(try copy(exact, maximum: 4_097).status, Int32(EMBER_RAW_PDF_ARGUMENT.rawValue))
        let stored = storedZlib(Data(repeating: 32, count: 250))
        XCTAssertEqual(stored.count, 261)
        // All16 streams individually fit. Decoded4000 fits too, but encoded
        // cost4176 must refuse instead of charging only the decoded bytes.
        for (count, expected, cost) in [(15, true, 3_915), (16, false, 4_176), (17, false, 4_437)] {
            let request = try request(fixture(streams: Array(repeating: stored, count: count)))
            let proof = try await Task.detached { try request.run() }.value
            XCTAssertEqual(proof.empty, expected, "streamcount \(count)")
            XCTAssertEqual(proof.remaining, expected ? 4_096 - cost : 4_096)
        }
    }

    @MainActor
    func testCancellationDoesNotPublishOrPoisonWorkerProof() async throws {
        let bytes = fixture(streams: [try compressed(Data("q Q".utf8))])
        // Count the callback sequence on these exact tiny bytes first. The
        // final ordinal is the real post-inflate/pre-publish checkpoint, not
        // an assumed fixed number of callbacks inside qpdf's bounded read.
        let observed = CancellationCounter(Int.max)
        let successful = try copy(bytes, cancellation: { pointer in
            guard let pointer else { return 1 }
            let counter = Unmanaged<CancellationCounter>.fromOpaque(pointer).takeUnretainedValue()
            counter.calls += 1
            return 0
        }, user: Unmanaged.passUnretained(observed).toOpaque())
        XCTAssertEqual(successful.status, Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(successful.bytes, Data("q Q".utf8))
        XCTAssertGreaterThanOrEqual(observed.calls, 6)
        let finalCheckpoint = observed.calls
        for stop in Array(Set([1, 2, 6, finalCheckpoint])).sorted() {
            let counter = CancellationCounter(stop)
            let result = try copy(bytes, cancellation: { pointer in
                guard let pointer else { return 1 }
                let counter = Unmanaged<CancellationCounter>.fromOpaque(pointer).takeUnretainedValue()
                counter.calls += 1
                return counter.calls >= counter.stop ? 1 : 0
            }, user: Unmanaged.passUnretained(counter).toOpaque())
            XCTAssertEqual(result.status, Int32(EMBER_RAW_PDF_CANCELLED.rawValue))
            XCTAssertEqual(counter.calls, stop, "The requested cancellation checkpoint must actually run.")
            assertRefused(result, "cancel checkpoint \(stop)")
        }
        let request = try request(bytes)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        do {
            _ = try await Task.detached { try request.run(cancellation: cancellation) }.value
            XCTFail("Cancellation cannot authorize a blank proof.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let retry = try await Task.detached { try request.run() }.value
        XCTAssertTrue(retry.empty)
        let expected = try copy(bytes)
        XCTAssertEqual(retry.remaining, 4_096 - max(expected.encodedCount, expected.bytes.count))
        do {
            _ = try await Task.detached { try request.run(cancellation: cancellation) }.value
            XCTFail("A cached positive must still honor cancellation.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testCoreGraphicsBlankPreservesOneActiveProfileOnlyWithExactFactoryProof() async throws {
        let profile = try XCTUnwrap(try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)).copyICCData()) as Data
        let blank = try coreGraphicsPage(painted: false)
        for (bound, painted) in [(true, false), (false, false), (true, true)] {
            let data = painted ? try coreGraphicsPage(painted: true) : blank
            let output = try XCTUnwrap(PDFDocument(data: data))
            if bound { PDFRawStreamProvenance.bindCreated(output, data: data) }
            let source = try XCTUnwrap(PDFDocument(data: profileFixture(profile)))
            try PDFPageOperations.append(contentsOf: source, to: output)
            let snapshot = try PDFRecoverySnapshot(capturing: output)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Flate-profile-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            let saved = try await Task.detached {
                try AtomicPDFWriter.write(snapshot.takeDocument(), to: url)
                return try Data(contentsOf: url)
            }.value
            let native = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: saved as CFData))))
            let catalog = try XCTUnwrap(native.catalog)
            XCTAssertEqual(native.numberOfPages, 2)
            let active = PDFCatalogStructurePreserver.array(catalog, "OutputIntents")
            let archive = PDFCatalogStructurePreserver.array(catalog, "EmberPDFSourceOutputIntents")
            if bound && !painted {
                let intents = try XCTUnwrap(active)
                XCTAssertEqual(try profileBytes(intents), profile)
                XCTAssertNil(archive)
            } else {
                XCTAssertNil(active)
                let records = try XCTUnwrap(archive)
                XCTAssertEqual(CGPDFArrayGetCount(records), 1)
                var record: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(records, 0, &record))
                let dictionary = try XCTUnwrap(record)
                XCTAssertEqual(try profileBytes(XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "OutputIntents"))), profile)
                let pages = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Pages"))
                XCTAssertEqual(CGPDFArrayGetCount(pages), 1)
                var page: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(pages, 0, &page))
                XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(page)), pdfReferenceIdentity(try XCTUnwrap(native.page(at: 2)?.dictionary)))
            }
        }
    }

    @MainActor private func request(_ bytes: Data) throws -> Request {
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(document, data: bytes)
        return Request(try XCTUnwrap(document.documentRef), try XCTUnwrap(PDFRawStreamProvenance.source(for: document)))
    }
    private func assertRefused(_ result: Copy, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(result.status, Int32(EMBER_RAW_PDF_OK.rawValue), label, file: file, line: line)
        XCTAssertTrue(result.pointerWasNil, label, file: file, line: line)
        XCTAssertEqual(result.reportedCount, 0, label, file: file, line: line)
        XCTAssertEqual(result.encodedCount, 0, label, file: file, line: line)
        XCTAssertTrue(result.bytes.isEmpty, label, file: file, line: line)
    }
    private func copy(_ bytes: Data, decoded: Bool = true, maximum: Int = 4_096,
                      cancellation: EmberRawPDFCancelCallback? = nil, user: UnsafeMutableRawPointer? = nil) throws -> Copy {
        var status: Int32 = 0
        let context = bytes.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, bytes.count, 4_096, &status) }
        let owner = try XCTUnwrap(context)
        defer { ember_raw_pdf_destroy(owner) }
        XCTAssertEqual(status, Int32(EMBER_RAW_PDF_OK.rawValue))
        var page: EmberRawPDFObject = 0, contents: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_page(owner, 0, &page), Int32(EMBER_RAW_PDF_OK.rawValue))
        let key = Data("/Contents".utf8)
        status = key.withUnsafeBytes { ember_raw_pdf_dictionary_get(owner, page, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &contents) }
        XCTAssertEqual(status, Int32(EMBER_RAW_PDF_OK.rawValue))
        var pointer: UnsafeMutablePointer<UInt8>?, count = 0, encoded = 0
        if decoded { status = ember_raw_pdf_blank_flate_copy(owner, contents, maximum, cancellation, user, &pointer, &count, &encoded) }
        else { status = ember_raw_pdf_stream_copy(owner, contents, maximum, cancellation, user, &pointer, &count); encoded = count }
        defer { if let pointer { ember_raw_pdf_free(pointer) } }
        XCTAssertGreaterThanOrEqual(count, 0)
        XCTAssertLessThanOrEqual(count, 4_096)
        guard count >= 0, count <= 4_096 else { throw NSError(domain: "FlateTestInvalidReportedCount", code: count) }
        let data = pointer.map { Data(bytes: $0, count: count) } ?? Data()
        return Copy(status: status, bytes: data, encodedCount: encoded, reportedCount: count, pointerWasNil: pointer == nil)
    }
    private func stream(_ page: CGPDFPage) throws -> CGPDFStreamRef {
        let dictionary = try XCTUnwrap(page.dictionary)
        var stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(dictionary, "Contents", &stream))
        return try XCTUnwrap(stream)
    }
    private func coreGraphicsPage(painted: Bool) throws -> Data {
        let bytes = NSMutableData(); var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        if painted { context.fill(CGRect(x: 20, y: 20, width: 30, height: 30)) }
        context.endPDFPage(); context.closePDF()
        return bytes as Data
    }
    private func compressed(_ bytes: Data) throws -> Data {
        let input = bytes.isEmpty ? Data([0]) : bytes
        var count = compressBound(uLong(bytes.count))
        var output = Data(count: Int(count))
        let status = output.withUnsafeMutableBytes { target in
            input.withUnsafeBytes { source in
                compress2(target.bindMemory(to: Bytef.self).baseAddress, &count,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(bytes.count), Z_BEST_COMPRESSION)
            }
        }
        XCTAssertEqual(status, Z_OK)
        guard status == Z_OK else { throw NSError(domain: "FlateTestCompression", code: Int(status)) }
        output.removeSubrange(Int(count)..<output.count)
        return output
    }
    private func storedZlib(_ bytes: Data) -> Data {
        precondition(bytes.count <= 65_535)
        let length = UInt16(bytes.count), inverse = ~length
        var result = Data([0x78, 0x01, 0x01, UInt8(length & 255), UInt8(length >> 8), UInt8(inverse & 255), UInt8(inverse >> 8)])
        result.append(bytes)
        var first: UInt32 = 1, second: UInt32 = 0
        for byte in bytes { first = (first + UInt32(byte)) % 65_521; second = (second + first) % 65_521 }
        let adler = (second << 16) | first
        result.append(contentsOf: [UInt8((adler >> 24) & 255), UInt8((adler >> 16) & 255), UInt8((adler >> 8) & 255), UInt8(adler & 255)])
        return result
    }
    private func fixture(streams: [Data], streamKeys: String = "/Filter /FlateDecode") -> Data {
        let contents = streams.count == 1 ? "4 0 R" : "[" + streams.indices.map { "\($0 + 4) 0 R" }.joined(separator: " ") + "]"
        var objects = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8), Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents \(contents) >>".utf8)]
        for stream in streams { objects.append(Data("<< /Length \(stream.count) \(streamKeys) >>\nstream\n".utf8) + stream + Data("\nendstream".utf8)) }
        return encode(objects)
    }
    private func profileFixture(_ profile: Data) -> Data {
        let painting = Data("q 0 0 10 10 re f Q".utf8)
        return encode([Data("<< /Type /Catalog /Pages 2 0 R /OutputIntents [<< /Type /OutputIntent /S /GTS_PDFX /OutputConditionIdentifier (test) /DestOutputProfile 5 0 R >>] >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8), Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>".utf8),
            Data("<< /Length \(painting.count) >>\nstream\n".utf8) + painting + Data("\nendstream".utf8),
            Data("<< /N 3 /Length \(profile.count) >>\nstream\n".utf8) + profile + Data("\nendstream".utf8)])
    }
    private func profileBytes(_ intents: CGPDFArrayRef) throws -> Data {
        XCTAssertEqual(CGPDFArrayGetCount(intents), 1)
        var intent: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(intents, 0, &intent))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(intent), "DestOutputProfile", &stream))
        var format = CGPDFDataFormat.raw
        return try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data
    }
    private func encode(_ objects: [Data]) -> Data {
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8)); bytes.append(object); bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
