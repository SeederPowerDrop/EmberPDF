// SPDX-License-Identifier: MPL-2.0
import CEmberPDFRawStreams
import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import HwattakPDF

final class PDFRawFileSnapshotTests: XCTestCase {
    func testSnapshotKeepsOriginalBytesAfterSourceReplacementAndOwnDescriptorClose() async throws {
        try await Task.detached {
            let url = try Self.fixture(); defer { try? FileManager.default.removeItem(at: url) }
            let version = try PDFSourceFileVersion.capture(at: url)
            let snapshot = try XCTUnwrap(PDFRawFileSnapshot.create(url: url, expected: version))
            var status: Int32 = -1
            let context = try XCTUnwrap(ember_raw_pdf_create_snapshot(snapshot.descriptor,
                snapshot.byteCount, Int(PDFRawFileSnapshot.maximumFileBytes), 100, nil, nil, &status))
            defer { ember_raw_pdf_destroy(context) }
            XCTAssertEqual(status, 0)
            let ownFD = snapshot.descriptor
            snapshot.closeDescriptor()
            XCTAssertEqual(fcntl(ownFD, F_GETFD), -1)
            try Data("a different original".utf8).write(to: url, options: .atomic)
            var pageCount: UInt32 = 0
            XCTAssertEqual(ember_raw_pdf_page_count(context, &pageCount), 0)
            XCTAssertEqual(pageCount, 1)
            var page: EmberRawPDFObject = 0, contents: EmberRawPDFObject = 0
            XCTAssertEqual(ember_raw_pdf_page(context, 0, &page), 0)
            let key = Array("/Contents".utf8)
            XCTAssertEqual(key.withUnsafeBufferPointer {
                ember_raw_pdf_dictionary_get(context, page, $0.baseAddress, $0.count, &contents)
            }, 0)
            var bytes: UnsafeMutablePointer<UInt8>?, count = 0
            XCTAssertEqual(ember_raw_pdf_stream_copy(context, contents, 1024, nil, nil, &bytes, &count), 0)
            defer { if let bytes { ember_raw_pdf_free(bytes) } }
            XCTAssertEqual(Data(bytes: try XCTUnwrap(bytes), count: count), Data("q Q".utf8))
            var copied: UnsafeMutablePointer<UInt8>?, copiedCount = 99
            XCTAssertEqual(ember_raw_pdf_input_copy(context, 1024, nil, nil, &copied, &copiedCount),
                           Int32(EMBER_RAW_PDF_LIMIT.rawValue))
            XCTAssertNil(copied); XCTAssertEqual(copiedCount, 0)
        }.value
    }

    func testChangedSourceVersionIsNotAnOptionalFallback() async throws {
        try await Task.detached {
            let url = try Self.fixture(); defer { try? FileManager.default.removeItem(at: url) }
            let version = try PDFSourceFileVersion.capture(at: url)
            try Data("different".utf8).write(to: url, options: .atomic)
            XCTAssertThrowsError(try PDFRawFileSnapshot.create(url: url, expected: version)) {
                guard case WorkspaceError.externalModification = $0 else { return XCTFail("Must preserve conflict") }
            }
        }.value
    }

    func testCancellationBeforeSnapshotDoesNotCreateInput() async throws {
        try await Task.detached {
            let url = try Self.fixture(); defer { try? FileManager.default.removeItem(at: url) }
            let version = try PDFSourceFileVersion.capture(at: url)
            let cancellation = PDFSaveCancellation(); cancellation.cancel()
            XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
                try PDFRawFileSnapshot.create(url: url, expected: version)
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try PDFSourceFileVersion.capture(at: url), version)
        }.value
    }

    func testReaderRejectsLinkedOrWritableDescriptorsAndCancellation() async throws {
        try await Task.detached {
            let url = try Self.fixture(); defer { try? FileManager.default.removeItem(at: url) }
            let version = try PDFSourceFileVersion.capture(at: url)
            let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0); defer { Darwin.close(fd) }
            var status: Int32 = -1
            XCTAssertNil(ember_raw_pdf_create_snapshot(fd, Int(version.fileSize), 1024 * 1024, 100, nil, nil, &status))
            XCTAssertEqual(status, Int32(EMBER_RAW_PDF_ARGUMENT.rawValue))
            let snapshot = try XCTUnwrap(PDFRawFileSnapshot.create(url: url, expected: version))
            XCTAssertNil(ember_raw_pdf_create_snapshot(snapshot.descriptor, snapshot.byteCount, 1024 * 1024,
                100, { _ in 1 }, nil, &status))
            XCTAssertEqual(status, Int32(EMBER_RAW_PDF_CANCELLED.rawValue))
            XCTAssertGreaterThanOrEqual(fcntl(snapshot.descriptor, F_GETFD), 0, "Failure never consumes caller FD")
            XCTAssertNil(ember_raw_pdf_create_snapshot(snapshot.descriptor, snapshot.byteCount + 1, 1024 * 1024,
                100, nil, nil, &status))
            XCTAssertEqual(status, Int32(EMBER_RAW_PDF_ARGUMENT.rawValue))
            XCTAssertNil(ember_raw_pdf_create_snapshot(snapshot.descriptor, snapshot.byteCount, snapshot.byteCount - 1,
                100, nil, nil, &status))
            XCTAssertEqual(status, Int32(EMBER_RAW_PDF_LIMIT.rawValue))
        }.value
    }

    func testLargeFileSourceReusesEncodedPaintingWithoutWholeInputCopy() async throws {
        try await Task.detached {
            // A sparse, unreferenced stream crosses the256MiB boundary without
            // allocating a256MiB test Data or decoding that stream.
            let url = try Self.fixture(padding: 256 * 1024 * 1024)
            defer { try? FileManager.default.removeItem(at: url) }
            let version = try PDFSourceFileVersion.capture(at: url)
            XCTAssertGreaterThan(version.fileSize, 256 * 1024 * 1024)
            let loaded = try PDFSourceFileAccess.loadDocument(at: url)
            let native = try XCTUnwrap(loaded.document.documentRef)
            let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: loaded.document))
            XCTAssertTrue(source.provesExactFactoryOwner(native))
            let page = try XCTUnwrap(native.page(at: 1))
            try source.preparePaintingResources(for: [page])
            var stream: CGPDFStreamRef?
            XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(page.dictionary), "Contents", &stream))
            XCTAssertEqual(try source.payload(for: XCTUnwrap(stream)), Data("q Q".utf8))
            XCTAssertEqual(source.widgetInputFootprint.ownedDataBytes, 0)
            XCTAssertNil(try source.tagReadImmutableInput(in: native), "No whole-file Data fallback")
            try Data("replacement".utf8).write(to: url, options: .atomic)
            XCTAssertEqual(try source.payload(for: XCTUnwrap(stream)), Data("q Q".utf8))
        }.value
    }

    func testOversizedFileIsRejectedBeforeSnapshot() async throws {
        try await Task.detached {
            let url = try Self.fixture(); defer { try? FileManager.default.removeItem(at: url) }
            let version = try PDFSourceFileVersion.capture(at: url)
            let excessive = PDFSourceFileVersion(canonicalURL: version.canonicalURL,
                fileSize: PDFRawFileSnapshot.maximumFileBytes + 1,
                contentModificationDate: version.contentModificationDate,
                fileSystemNumber: version.fileSystemNumber, fileSystemNodeNumber: version.fileSystemNodeNumber)
            XCTAssertNil(try PDFRawFileSnapshot.create(url: url, expected: excessive))
            let native = try XCTUnwrap(CGPDFDocument(url as CFURL))
            XCTAssertNil(PDFRawStreamSource.opened(native: native, url: url, version: excessive))
        }.value
    }

    private static func fixture(padding: UInt64 = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-file-test-\(UUID()).pdf")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var complete = false
        defer { try? handle.close(); if !complete { try? FileManager.default.removeItem(at: url) } }
        func write(_ value: String) throws { try handle.write(contentsOf: Data(value.utf8)) }
        try write("%PDF-1.7\n")
        var offsets: [UInt64] = [0]
        for body in ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                     "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 20 20] /Resources << >> /Contents 4 0 R >>",
                     "<< /Length 3 >>\nstream\nq Q\nendstream"] {
            offsets.append(try handle.offset()); try write("\(offsets.count - 1) 0 obj\n\(body)\nendobj\n")
        }
        if padding > 0 {
            offsets.append(try handle.offset()); try write("5 0 obj\n<< /Length \(padding) >>\nstream\n")
            let start = try handle.offset(); try handle.seek(toOffset: start + padding)
            try write("\nendstream\nendobj\n")
        }
        let xref = try handle.offset()
        try write("xref\n0 \(offsets.count)\n0000000000 65535 f \n")
        for value in offsets.dropFirst() { try write(String(format: "%010llu 00000 n \n", value)) }
        try write("trailer\n<< /Root 1 0 R /Size \(offsets.count) >>\nstartxref\n\(xref)\n%%EOF\n")
        complete = true; return url
    }
}
