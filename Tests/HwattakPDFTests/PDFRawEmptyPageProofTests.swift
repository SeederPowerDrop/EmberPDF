// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFRawEmptyPageProofTests: XCTestCase {
    private struct Result: Sendable { let empty: Bool; let remaining: Int }

    /// Only the exact immutable CG graph and its serialized raw owner cross
    /// into workers. No live PDFDocument/PDFPage/annotation is captured there.
    private final class Request: @unchecked Sendable {
        let native: CGPDFDocument
        let source: PDFRawStreamSource?
        init(native: CGPDFDocument, source: PDFRawStreamSource?) {
            self.native = native; self.source = source
        }
        func run(pageIndex: Int = 0, budget: Int = 4_096, cancellation: PDFSaveCancellation? = nil) throws -> Result {
            var remaining = budget
            let page = try XCTUnwrap(native.page(at: pageIndex + 1))
            let operation = { try self.source?.provesEmptyPageContents(for: page, remainingEncodedBytes: &remaining) ?? false }
            let empty = try cancellation.map { try PDFSaveCancellation.withCurrent($0, operation) } ?? operation()
            return Result(empty: empty, remaining: remaining)
        }
    }

    @MainActor
    func testSameBytesRequireARealFactoryBoundary() async throws {
        let data = fixture(streams: [Data("q Q".utf8)])
        let document = try XCTUnwrap(PDFDocument(data: data))
        let native = try XCTUnwrap(document.documentRef)
        XCTAssertNil(PDFRawStreamProvenance.source(for: document))
        let unbound = Request(native: native, source: PDFRawStreamProvenance.source(for: document))
        let proofResult1 = try await Task.detached { try unbound.run() }.value
        XCTAssertFalse(proofResult1.empty)
        PDFRawStreamProvenance.bindCreated(document, data: data)
        let bound = Request(native: native, source: try XCTUnwrap(PDFRawStreamProvenance.source(for: document)))
        let result = try await Task.detached { try bound.run() }.value
        XCTAssertTrue(result.empty)
        XCTAssertEqual(result.remaining, 4_093)
        XCTAssertTrue(document.documentRef === native)
    }

    @MainActor
    func testNormalVersionGuardedLoaderCanProveItsOriginalBlankBytes() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let data = fixture(streams: [Data("q\nQ".utf8)])
        try data.write(to: url)
        let loaded = try PDFSourceFileAccess.loadDocument(at: url)
        let request = Request(native: try XCTUnwrap(loaded.document.documentRef),
                              source: try XCTUnwrap(PDFRawStreamProvenance.source(for: loaded.document)))
        let proofResult2 = try await Task.detached { try request.run() }.value
        XCTAssertTrue(proofResult2.empty)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: url), loaded.version)
    }

    @MainActor
    func testMainCacheMissIsRetryableAndWarmProofChargesItsOriginalByteCost() async throws {
        let request = try request(fixture(streams: [Data("q Q".utf8)]))
        var remaining = 4_096
        let page = try XCTUnwrap(request.native.page(at: 1))
        XCTAssertFalse(try XCTUnwrap(request.source).provesEmptyPageContents(for: page, remainingEncodedBytes: &remaining))
        XCTAssertEqual(remaining, 4_096)
        let proofResult3 = try await Task.detached { try request.run() }.value
        XCTAssertTrue(proofResult3.empty)
        XCTAssertTrue(try XCTUnwrap(request.source).provesEmptyPageContents(for: page, remainingEncodedBytes: &remaining))
        XCTAssertEqual(remaining, 4_093)
        var tooSmall = 2
        XCTAssertFalse(try XCTUnwrap(request.source).provesEmptyPageContents(for: page, remainingEncodedBytes: &tooSmall))
        XCTAssertEqual(tooSmall, 2)
    }

    @MainActor
    func testAbsentNullEmptyArrayAndEmptyStreamAreBlankWithoutInventedPainting() async throws {
        let cases = [("absent", fixture(contents: nil)), ("null", fixture(contents: "null")),
                     ("empty-array", fixture(contents: "[]")), ("empty-stream", fixture(streams: [Data()]))]
        for (label, data) in cases {
            let request = try request(data)
            let result = try await Task.detached { try request.run(budget: 0) }.value
            XCTAssertTrue(result.empty, label)
            XCTAssertEqual(result.remaining, 0, label)
        }
    }

    func testZeroLengthRawCopyStillRejectsMalformedAndFilteredEmptyStreams() {
        let allowed = [fixture(streams: [Data()]),
                       fixture(streams: [Data()], streamKeys: "/Filter null /DecodeParms null /F null /FFilter null /FDecodeParms null")]
        for data in allowed {
            XCTAssertEqual(zeroBudgetRawCopyStatus(data), Int32(EMBER_RAW_PDF_OK.rawValue))
        }
        let refused = [fixture(streams: [Data("q Q".utf8)], declaredLength: 0),
                       fixture(streams: [Data()], streamKeys: "/Filter /ASCIIHexDecode"),
                       fixture(streams: [Data()], streamKeys: "/DecodeParms << >>"),
                       fixture(streams: [Data()], streamKeys: "/F (unopened-external.pdf)"),
                       fixture(streams: [Data()], streamKeys: "/FFilter /ASCIIHexDecode"),
                       fixture(streams: [Data()], streamKeys: "/FDecodeParms << >>")]
        for (index, data) in refused.enumerated() {
            XCTAssertNotEqual(zeroBudgetRawCopyStatus(data), Int32(EMBER_RAW_PDF_OK.rawValue), "case \(index)")
        }
        XCTAssertEqual(zeroBudgetRawCopyStatus(allowed[0], cancellation: { _ in 1 }),
                       Int32(EMBER_RAW_PDF_CANCELLED.rawValue))
    }

    func testClosedTokenGrammarRejectsUnknownSyntaxAndUnbalancedGraphicsState() throws {
        for text in ["Q", "q", "qQ", "q Q Q", "% comment\n", "q %comment\n Q", "(q Q)", "<7151>", "/q", "0", "q 0 0 m Q", "BI ID EI", "q\u{000B}Q"] {
            XCTAssertFalse(try PDFEmptyContentTokens.provesEmpty(Data(text.utf8)), text)
        }
        XCTAssertTrue(try PDFEmptyContentTokens.provesEmpty(Data([0, 9, 10, 12, 13, 32])))
        XCTAssertTrue(try PDFEmptyContentTokens.provesEmpty(Data("q q Q Q\n".utf8)))
    }

    func testTokenDepthCountAndByteLimitsRemainStrict() throws {
        XCTAssertTrue(try PDFEmptyContentTokens.provesEmpty(Data(String(repeating: "q ", count: 64).utf8) + Data(String(repeating: "Q ", count: 64).utf8)))
        XCTAssertFalse(try PDFEmptyContentTokens.provesEmpty(Data(String(repeating: "q ", count: 65).utf8) + Data(String(repeating: "Q ", count: 65).utf8)))
        XCTAssertTrue(try PDFEmptyContentTokens.provesEmpty(Data(String(repeating: "q Q ", count: 256).utf8)))
        XCTAssertFalse(try PDFEmptyContentTokens.provesEmpty(Data(String(repeating: "q Q ", count: 257).utf8)))
        XCTAssertTrue(try PDFEmptyContentTokens.provesEmpty(Data(repeating: 32, count: 4_096)))
        XCTAssertFalse(try PDFEmptyContentTokens.provesEmpty(Data(repeating: 32, count: 4_097)))
    }

    @MainActor
    func testStreamArrayUsesOneAggregateBudgetAndExactTokenBoundaries() async throws {
        let cases: [(Data, Bool)] = [
            (fixture(streams: [Data("q\n".utf8), Data("Q\n".utf8)]), true),
            (fixture(streams: [Data("q".utf8), Data("Q".utf8)]), false),
            (fixture(streams: Array(repeating: Data("q Q\n".utf8), count: 16)), true),
            (fixture(streams: Array(repeating: Data("q Q\n".utf8), count: 17)), false),
            (fixture(streams: [Data(repeating: 32, count: 2_048), Data(repeating: 32, count: 2_049)]), false)]
        for (data, expected) in cases {
            let request = try request(data)
            let result = try await Task.detached { try request.run() }.value
            XCTAssertEqual(result.empty, expected)
            if !expected { XCTAssertEqual(result.remaining, 4_096) }
        }
    }

    @MainActor
    func testFilteredExternalInvalidAndActionBearingPagesRemainUnproven() async throws {
        let cases = [fixture(streamKeys: "/Filter /ASCIIHexDecode"), fixture(streamKeys: "/F (unopened-external.pdf)"),
                     fixture(streamKeys: "/DecodeParms << >>"), fixture(contents: "/Unknown"),
                     fixture(contents: "[4 0 R null]"), fixture(contents: "[[4 0 R]]"),
                     fixture(pageKeys: "/AA << >>"), fixture(pageKeys: "/PresSteps << >>"),
                     fixture(pageKeys: "/Group << /S /Transparency >>"), fixture(annotation: true)]
        for data in cases {
            let request = try request(data)
            let proofResult4 = try await Task.detached { try request.run() }.value
            XCTAssertFalse(proofResult4.empty)
        }
    }

    @MainActor
    func testInvalidCallerBudgetDoesNotReadOrPoisonTheProof() async throws {
        let request = try request(fixture())
        for budget in [-1, 4_097] {
            let result = try await Task.detached { try request.run(budget: budget) }.value
            XCTAssertFalse(result.empty)
            XCTAssertEqual(result.remaining, budget)
        }
        let result = try await Task.detached { try request.run() }.value
        XCTAssertTrue(result.empty)
    }

    @MainActor
    func testForeignPageDoesNotPoisonTheOriginalProof() async throws {
        let original = try request(fixture())
        let foreign = try native(fixture())
        let request = Request(native: foreign, source: original.source)
        let proofResult5 = try await Task.detached { try request.run() }.value
        XCTAssertFalse(proofResult5.empty)
        let proofResult6 = try await Task.detached { try original.run() }.value
        XCTAssertTrue(proofResult6.empty)
    }

    @MainActor
    func testChangedFileAndMalformedInputCannotAuthorizeBlankContents() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        try fixture().write(to: url)
        let loaded = try PDFSourceFileAccess.loadDocument(at: url)
        let request = Request(native: try XCTUnwrap(loaded.document.documentRef),
                              source: try XCTUnwrap(PDFRawStreamProvenance.source(for: loaded.document)))
        try fixture(streams: [Data("0 0 m".utf8)]).write(to: url, options: .atomic)
        let proofResult7 = try await Task.detached { try request.run() }.value
        XCTAssertFalse(proofResult7.empty)
        let graph = try native(fixture())
        let malformed = Request(native: graph, source: PDFRawStreamSource.created(native: graph, data: Data("not a PDF".utf8)))
        let proofResult8 = try await Task.detached { try malformed.run() }.value
        XCTAssertFalse(proofResult8.empty)
    }

    @MainActor
    func testConcurrentRequestsShareOnlyImmutableScalarProofAndCancellationDoesNotPoisonIt() async throws {
        let request = try request(fixture())
        let results = try await withThrowingTaskGroup(of: Result.self) { group in
            for _ in 0..<6 { group.addTask { try request.run() } }
            var values: [Result] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 6)
        XCTAssertTrue(results.allSatisfy { $0.empty && $0.remaining == 4_093 })
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        do {
            _ = try await Task.detached { try request.run(cancellation: cancellation) }.value
            XCTFail("Cancelled calls must not return a cached proof.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let proofResult9 = try await Task.detached { try request.run() }.value
        XCTAssertTrue(proofResult9.empty)
    }

    func testCancellationDuringBoundedTokenScanPropagates() throws {
        let cancellation = PDFSaveCancellation()
        var checks = 0
        XCTAssertThrowsError(try PDFEmptyContentTokens.provesEmpty(Data(repeating: 32, count: 4_096)) {
            checks += 1
            if checks == 3 { cancellation.cancel() }
            try cancellation.check()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 3)
    }

    @MainActor
    func testMoreThan256PagesContinueProvingWithoutLifetimeCoverageLimit() async throws {
        let count = 257
        func pages(resources: Bool) -> Data {
            let inherited = resources ? " /Resources << >>" : ""
            var objects = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
                           Data(("<< /Type /Pages /MediaBox [0 0 200 200] /Count \(count) /Kids [" +
                                 (0..<count).map { "\($0 + 3) 0 R" }.joined(separator: " ") + "]\(inherited) >>").utf8)]
            objects += (0..<count).map { _ in Data("<< /Type /Page /Parent 2 0 R >>".utf8) }
            return encode(objects)
        }
        // The malformed preimage required 257 Resources repairs. Keep it as a
        // refusal control; parser recovery must not authorize an empty page.
        let invalid = try request(pages(resources: false))
        let rejected = try await Task.detached { try invalid.run() }.value
        XCTAssertFalse(rejected.empty)
        XCTAssertEqual(rejected.remaining, 4_096)
        let request = try request(pages(resources: true))
        let completed = try await Task.detached {
            var count = 0
            for index in 0..<257 {
                if try request.run(pageIndex: index).empty { count += 1 }
            }
            return count
        }.value
        XCTAssertEqual(completed, 257)
        // Eviction may drop a scalar proof, but another bounded worker query
        // can establish it again instead of permanently refusing later pages.
        let repeated = try await Task.detached { try request.run(pageIndex: 0) }.value
        XCTAssertTrue(repeated.empty)
    }

    private func request(_ bytes: Data) throws -> Request {
        let document = try native(bytes)
        return Request(native: document, source: try XCTUnwrap(PDFRawStreamSource.created(native: document, data: bytes)))
    }

    private func native(_ bytes: Data) throws -> CGPDFDocument {
        try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: bytes as CFData))))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Ember-empty-proof-" + UUID().uuidString + ".pdf")
    }

    private func zeroBudgetRawCopyStatus(_ bytes: Data, cancellation: EmberRawPDFCancelCallback? = nil) -> Int32 {
        var status: Int32 = 0
        let context = bytes.withUnsafeBytes {
            ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, bytes.count, 500_000, &status)
        }
        guard let context else { return status }
        defer { ember_raw_pdf_destroy(context) }
        var page: EmberRawPDFObject = 0, contents: EmberRawPDFObject = 0
        status = ember_raw_pdf_page(context, 0, &page)
        guard status == Int32(EMBER_RAW_PDF_OK.rawValue) else { return status }
        status = Array("/Contents".utf8).withUnsafeBufferPointer {
            ember_raw_pdf_dictionary_get(context, page, $0.baseAddress, $0.count, &contents)
        }
        guard status == Int32(EMBER_RAW_PDF_OK.rawValue) else { return status }
        var pointer: UnsafeMutablePointer<UInt8>?, count = 0
        status = ember_raw_pdf_stream_copy(context, contents, 0, cancellation, nil, &pointer, &count)
        defer { if let pointer { ember_raw_pdf_free(pointer) } }
        XCTAssertEqual(count, 0)
        XCTAssertNil(pointer)
        return status
    }

    private func fixture(contents: String? = "stream", streams: [Data] = [Data("q Q".utf8)],
                         streamKeys: String = "", pageKeys: String = "", annotation: Bool = false,
                         declaredLength: Int? = nil) -> Data {
        let entries: String
        if contents == "stream" {
            entries = streams.count == 1 ? " /Contents 4 0 R" : " /Contents [" + streams.indices.map { "\($0 + 4) 0 R" }.joined(separator: " ") + "]"
        } else { entries = contents.map { " /Contents " + $0 } ?? "" }
        let annots = annotation ? " /Annots [\(4 + streams.count) 0 R]" : ""
        var objects = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
                       Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
                       Data("<< /Type /Page /Parent 2 0 R /MediaBox [54.123456789 27.000001 504.000015 720.999997] /Resources << /ProcSet [/PDF] >>\(entries)\(annots) \(pageKeys) >>".utf8)]
        for stream in streams {
            objects.append(Data("<< /Length \(declaredLength ?? stream.count) \(streamKeys) >>\nstream\n".utf8) + stream + Data("\nendstream".utf8))
        }
        if annotation { objects.append(Data("<< /Type /Annot /Subtype /Text /Rect [60 40 80 60] >>".utf8)) }
        return encode(objects)
    }

    private func encode(_ objects: [Data]) -> Data {
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8)); bytes.append(object); bytes.append(Data("\nendobj\n".utf8))
        }
        let start = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8))
        return bytes
    }
}
