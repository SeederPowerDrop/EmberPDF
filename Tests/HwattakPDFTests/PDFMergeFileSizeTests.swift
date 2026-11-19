// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// File-size regressions exercise the actual page-copy and atomic-save paths.
/// Each fixture page has its own deterministic JPEG, so retaining an entire
/// donor document or repeatedly copying old resources cannot hide behind tiny
/// text-only pages. Optional JSON reports use EMBER_SIZE_AUDIT_DIRECTORY.
final class PDFMergeFileSizeTests: XCTestCase {
    @MainActor
    func testTwentySaveReopenCyclesDoNotAccumulateDocumentBytes() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(pageCount: 4, prefix: "UNCHANGED")
        var document = try XCTUnwrap(PDFDocument(data: source))
        let destination = folder.appendingPathComponent("unchanged.pdf")
        var cycles: [Cycle] = []

        for cycle in 1...20 {
            let saved = try saveAndReopen(document, to: destination)
            document = saved.document
            cycles.append(Cycle(cycle: cycle, pages: document.pageCount, bytes: saved.bytes))
            XCTAssertEqual(document.pageCount, 4)
            for page in 0..<4 {
                XCTAssertTrue((document.page(at: page)?.string ?? "").contains(marker("UNCHANGED", page)))
            }
        }

        try report("unchanged-save-reopen", sourceBytes: source.count, cycles: cycles)
        let first = try XCTUnwrap(cycles.first).bytes
        for sample in cycles.dropFirst() {
            XCTAssertLessThanOrEqual(sample.bytes, first + first / 4 + 4_096,
                "Saving unchanged content must remain near its first serialized size (cycle \(sample.cycle)).")
        }
    }

    @MainActor
    func testAppendingTwoPagesTenTimesGrowsWithAddedPages() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let initialData = try fixture(pageCount: 1, prefix: "BASE")
        let donorData = try fixture(pageCount: 2, prefix: "DONOR", seedOffset: 40)
        let donor = try XCTUnwrap(PDFDocument(data: donorData))
        let destination = folder.appendingPathComponent("append.pdf")
        let initial = try saveAndReopen(XCTUnwrap(PDFDocument(data: initialData)), to: destination)
        var document = initial.document
        var cycles = [Cycle(cycle: 0, pages: document.pageCount, bytes: initial.bytes)]

        for cycle in 1...10 {
            XCTAssertEqual(try PDFPageOperations.append(contentsOf: donor, to: document), 2)
            let saved = try saveAndReopen(document, to: destination)
            document = saved.document
            cycles.append(Cycle(cycle: cycle, pages: document.pageCount, bytes: saved.bytes))
            XCTAssertEqual(document.pageCount, 1 + cycle * 2)
            XCTAssertTrue((document.page(at: 0)?.string ?? "").contains(marker("BASE", 0)))
            for index in 1..<document.pageCount {
                XCTAssertTrue((document.page(at: index)?.string ?? "").contains(marker("DONOR", (index - 1) % 2)))
            }
            XCTAssertEqual(donor.pageCount, 2, "Appending must leave the donor intact.")
        }

        try report("append-two-pages", sourceBytes: initialData.count,
                   donorBytes: donorData.count, cycles: cycles)
        // Per-added-page resource copies are permitted. The ceiling rejects
        // accumulating old document copies and exponential growth, without
        // depending on PDFKit deduplicating identical donors across imports.
        let allowedIncrement = donorData.count * 3 / 2 + 16_384
        for sample in cycles.dropFirst() {
            XCTAssertLessThanOrEqual(sample.bytes, initial.bytes + sample.cycle * allowedIncrement,
                "A fixed two-page append must have a linear serialized-size bound.")
        }
        let increments = zip(cycles, cycles.dropFirst()).map { pair in pair.1.bytes - pair.0.bytes }
        let earlyIncrement = max(1, increments.prefix(3).max() ?? 1)
        for increment in increments.dropFirst(3) {
            XCTAssertLessThanOrEqual(increment, earlyIncrement * 2 + 8_192,
                "Later appends must not repeatedly copy all prior content.")
        }
    }

    @MainActor
    func testExtractingThreeOfTwentyPagesDoesNotRetainAllDonorImages() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceData = try fixture(pageCount: 20, prefix: "EXTRACT", seedOffset: 80)
        let source = try XCTUnwrap(PDFDocument(data: sourceData))
        let selected = [1, 8, 18]
        let extracted = try PDFPageOperations.extract(from: source, indexes: selected)
        let saved = try saveAndReopen(extracted, to: folder.appendingPathComponent("subset.pdf"))
        let cycles = [Cycle(cycle: 0, pages: source.pageCount, bytes: sourceData.count),
                      Cycle(cycle: 1, pages: saved.document.pageCount, bytes: saved.bytes)]
        try report("extract-three-of-twenty", sourceBytes: sourceData.count, cycles: cycles)

        XCTAssertEqual(source.pageCount, 20)
        XCTAssertEqual(saved.document.pageCount, selected.count)
        for (outputIndex, sourceIndex) in selected.enumerated() {
            XCTAssertTrue((saved.document.page(at: outputIndex)?.string ?? "").contains(marker("EXTRACT", sourceIndex)))
        }
        for unselected in (0..<20).filter({ !selected.contains($0) }) {
            XCTAssertFalse((saved.document.string ?? "").contains(marker("EXTRACT", unselected)))
        }
        XCTAssertLessThan(saved.bytes, sourceData.count * 35 / 100 + 16_384,
            "A three-page subset must not carry the other seventeen unique image resources.")
    }

    private struct Cycle: Codable {
        let cycle: Int
        let pages: Int
        let bytes: Int
    }

    private struct Report: Codable {
        let scenario: String
        let sourceBytes: Int
        let donorBytes: Int?
        let cycles: [Cycle]
    }

    private func report(_ scenario: String, sourceBytes: Int, donorBytes: Int? = nil,
                        cycles: [Cycle]) throws {
        print("PDF_SIZE_AUDIT \(scenario): \(cycles.map { String($0.bytes) }.joined(separator: ","))")
        guard let directory = ProcessInfo.processInfo.environment["EMBER_SIZE_AUDIT_DIRECTORY"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Report(scenario: scenario, sourceBytes: sourceBytes,
                                            donorBytes: donorBytes, cycles: cycles))
        try data.write(to: folder.appendingPathComponent("\(scenario).json"), options: .atomic)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-SizeAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func saveAndReopen(_ document: PDFDocument, to url: URL) throws -> (document: PDFDocument, bytes: Int) {
        try AtomicPDFWriter.write(document, to: url)
        let data = try Data(contentsOf: url)
        // Reopening from the saved bytes also detaches PDFKit from the inode
        // replaced by the following cycle, as closing/reopening the app would.
        return (try XCTUnwrap(PDFDocument(data: data)), data.count)
    }

    private func marker(_ prefix: String, _ index: Int) -> String {
        "\(prefix)-PAGE-\(String(format: "%03d", index))"
    }

    private func fixture(pageCount: Int, prefix: String, seedOffset: Int = 0) throws -> Data {
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Count \(pageCount) /Kids [\((0..<pageCount).map { "\(4 + $0 * 3) 0 R" }.joined(separator: " "))] >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)
        ]
        for index in 0..<pageCount {
            let pageID = 4 + index * 3
            let jpeg = try uniqueJPEG(seed: UInt64(seedOffset + index + 1))
            let content = Data(("q 320 0 0 240 40 40 cm /Im0 Do Q\n"
                + "BT /F1 14 Tf 40 300 Td (\(marker(prefix, index))) Tj ET\n").utf8)
            objects.append(Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 350] "
                + "/Resources << /Font << /F1 3 0 R >> /XObject << /Im0 \(pageID + 2) 0 R >> >> "
                + "/Contents \(pageID + 1) 0 R >>").utf8))
            objects.append(stream(content, dictionary: ""))
            objects.append(stream(jpeg, dictionary:
                "/Type /XObject /Subtype /Image /Width 512 /Height 384 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode"))
        }
        var result = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n".utf8))
            result.append(object)
            result.append(Data("\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            result.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        result.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }

    private func stream(_ data: Data, dictionary: String) -> Data {
        var result = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
        result.append(data)
        result.append(Data("\nendstream".utf8))
        return result
    }

    private func uniqueJPEG(seed: UInt64) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512,
            pixelsHigh: 384, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        var random = seed
        for row in 0..<384 {
            for column in 0..<(512 * 3) {
                random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bytes[row * bitmap.bytesPerRow + column] = UInt8(truncatingIfNeeded: random >> 32)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65]))
    }
}
