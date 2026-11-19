// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// Optional read-only corpus verification. Output copies and the JSON report
/// are written only to an explicitly supplied separate QA directory.
final class PDFPageStructureRealFileTests: XCTestCase {
    func testCorpusExtractionPreservesSupportedPagesOrReportsSafeRejection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifest = environment["EMBER_PAGE_STRUCTURE_CORPUS_MANIFEST"],
              let directory = environment["EMBER_PAGE_STRUCTURE_QA_DIRECTORY"] else {
            throw XCTSkip("Supply EMBER_PAGE_STRUCTURE_CORPUS_MANIFEST and EMBER_PAGE_STRUCTURE_QA_DIRECTORY.")
        }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [[String: Any]] = []
        for entry in entries {
            try autoreleasepool {
                let sourceURL = URL(fileURLWithPath: entry.path)
                XCTAssertFalse(PDFSourceFileVersion.refersToSameLocation(sourceURL, output))
                let before = try PDFSourceFileVersion.capture(at: sourceURL)
                // Match the app loader: signed originals need its verified raw
                // factory provenance before a signature can become an inactive stamp.
                let document = try PDFSourceFileAccess.loadDocument(at: sourceURL).document
                let indexes = Array(Set([0, max(0, document.pageCount / 2), max(0, document.pageCount - 1)])).sorted()
                var row: [String: Any] = ["id": entry.id, "pages": document.pageCount, "selectedIndexes": indexes]
                var textHeuristicVariations: [Int] = []
                do {
                    let extracted = try PDFPageOperations.extract(from: document, indexes: indexes)
                    let destination = output.appendingPathComponent(entry.id + "-selected.pdf")
                    try AtomicPDFWriter.write(extracted, to: destination)
                    let reopened = try XCTUnwrap(PDFDocument(url: destination))
                    XCTAssertEqual(reopened.pageCount, indexes.count, entry.id)
                    for (outIndex, sourceIndex) in indexes.enumerated() {
                        let sourcePage = try XCTUnwrap(document.page(at: sourceIndex))
                        let resultPage = try XCTUnwrap(reopened.page(at: outIndex))
                        XCTAssertEqual(resultPage.rotation, sourcePage.rotation, entry.id)
                        for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                            let actual = resultPage.bounds(for: box), expected = sourcePage.bounds(for: box)
                            for (a, b) in zip([actual.minX, actual.minY, actual.width, actual.height], [expected.minX, expected.minY, expected.width, expected.height]) {
                                XCTAssertEqual(a, b, accuracy: 0.000001, entry.id)
                            }
                        }
                        let beforeText = sourcePage.string ?? "", afterText = resultPage.string ?? ""
                        if beforeText != afterText {
                            // PDFKit can infer different spacing/line ordering
                            // on old OCR scans. Check character coverage here;
                            // the required independent Poppler oracle checks
                            // word order and original embedded image pixels.
                            func coverage(_ value: String) -> [UInt32: Int] {
                                value.precomposedStringWithCanonicalMapping.unicodeScalars
                                    .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
                                    .reduce(into: [:]) { $0[$1.value, default: 0] += 1 }
                            }
                            XCTAssertEqual(coverage(afterText), coverage(beforeText), entry.id)
                            textHeuristicVariations.append(sourceIndex)
                        }
                        XCTAssertEqual(resultPage.annotations.count, sourcePage.annotations.count, entry.id)
                        let customLabels = document.documentRef?.catalog.flatMap { PDFCatalogStructurePreserver.object($0, "PageLabels") } != nil
                        XCTAssertEqual(resultPage.label, customLabels ? sourcePage.label : String(outIndex + 1), entry.id)
                    }
                    for key: PDFDocumentAttribute in [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute] {
                        XCTAssertEqual(reopened.documentAttributes?[key] as? NSObject, document.documentAttributes?[key] as? NSObject, entry.id)
                    }
                    row["status"] = "exported"
                    row["pdfKitTextHeuristicVariationIndexes"] = textHeuristicVariations
                    row["requiresIndependentTextOrderValidation"] = !textHeuristicVariations.isEmpty
                    row["output"] = destination.path
                    row["bytes"] = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? UInt64
                    let merged = try anchorDocument()
                    let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: Array(0..<extracted.pageCount))
                    let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 1)
                    try transaction.apply()
                    try transaction.undo()
                    XCTAssertEqual(merged.pageCount, 1, entry.id)
                    try transaction.redo()
                    let mergedURL = output.appendingPathComponent(entry.id + "-merged.pdf")
                    try AtomicPDFWriter.write(merged, to: mergedURL)
                    let reopenedMerge = try XCTUnwrap(PDFDocument(url: mergedURL))
                    XCTAssertEqual(reopenedMerge.pageCount, indexes.count + 1, entry.id)
                    for (index, sourceIndex) in indexes.enumerated() {
                        let customLabels = document.documentRef?.catalog.flatMap { PDFCatalogStructurePreserver.object($0, "PageLabels") } != nil
                        XCTAssertEqual(reopenedMerge.page(at: index + 1)?.label, customLabels ? document.page(at: sourceIndex)?.label : String(index + 2), entry.id)
                    }
                    row["mergeOutput"] = mergedURL.path
                    row["mergeStatus"] = "merged"
                } catch let failure as PDFPageStructurePreserver.Failure {
                    row["status"] = "safelyRejected"
                    row["reason"] = String(describing: failure)
                    XCTFail("Corpus \(entry.id) must support structural assembly: \(failure)")
                } catch {
                    row["status"] = "failed"
                    row["reason"] = String(describing: type(of: error))
                    XCTFail("Corpus \(entry.id) assembly failed: \(error)")
                }
                XCTAssertEqual(try PDFSourceFileVersion.capture(at: sourceURL), before, entry.id)
                report.append(row)
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("page-structure-corpus.json"))
    }

    func testSelectedCorpusOutputsMergeTogetherWithoutLosingPageContents() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifest = environment["EMBER_PAGE_STRUCTURE_CORPUS_MANIFEST"],
              let directory = environment["EMBER_PAGE_STRUCTURE_QA_DIRECTORY"] else {
            throw XCTSkip("Supply the explicit corpus manifest and separate QA directory.")
        }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let sourceURLs = entries.map { folder.appendingPathComponent($0.id + "-selected.pdf") }
        let versions = try sourceURLs.map { try PDFSourceFileVersion.capture(at: $0) }
        // These documents become new assembly inputs, so use the same verified
        // loader as the app. Independent PDFKit output checks below stay unchanged.
        let selected = try sourceURLs.map { try PDFSourceFileAccess.loadDocument(at: $0).document }
        let destination = PDFDocument()
        let imports = try selected.map { try PDFPageStructurePreserver.prepareImport(from: $0, indexes: Array(0..<$0.pageCount)) }
        let transaction = try PDFPageStructurePreserver.prepareMerge(imports: imports, into: destination, at: 0)
        try transaction.apply()
        try transaction.undo()
        XCTAssertEqual(destination.pageCount, 0)
        try transaction.redo()
        let expectedCount = selected.reduce(0) { $0 + $1.pageCount }
        XCTAssertEqual(destination.pageCount, expectedCount)
        let url = folder.appendingPathComponent("all-selected-merged.pdf")
        try AtomicPDFWriter.write(destination, to: url)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reopened.pageCount, expectedCount)
        var outputIndex = 0
        for (entry, source) in zip(entries, selected) {
            for index in 0..<source.pageCount {
                let before = try XCTUnwrap(source.page(at: index))
                let after = try XCTUnwrap(reopened.page(at: outputIndex))
                XCTAssertEqual(after.rotation, before.rotation, entry.id)
                XCTAssertEqual(after.bounds(for: .mediaBox), before.bounds(for: .mediaBox), entry.id)
                XCTAssertEqual(after.annotations.count, before.annotations.count, entry.id)
                XCTAssertEqual(after.string, before.string, entry.id)
                outputIndex += 1
            }
        }
        for (url, version) in zip(sourceURLs, versions) {
            XCTAssertEqual(try PDFSourceFileVersion.capture(at: url), version)
        }
    }

    private struct Entry: Decodable { let id: String; let path: String }

    private func anchorDocument() throws -> PDFDocument {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        return try XCTUnwrap(PDFDocument(data: bytes as Data))
    }
}
