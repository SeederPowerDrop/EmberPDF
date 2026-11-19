// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// Opt-in real-input coverage. Only the 30 explicit manifest entries are read;
/// no directory discovery, PDF output, extracted-text log or source write exists.
/// PDFKit parsing is synchronous, so the test runner still needs an external
/// process timeout. The engine receives immutable sampled strings only.
final class PDFDocumentDifferenceCorpusTests: XCTestCase {
    private struct Fixture: Decodable {
        let id: String
        let path: String
    }

    private struct Result: Encodable {
        let id: String
        let pageCount: Int
        let textlessPageCount: Int
        let comparisonSeconds: Double

        enum CodingKeys: String, CodingKey {
            case id
            case pageCount = "page_count"
            case textlessPageCount = "textless_sampled_pages"
            case comparisonSeconds = "comparison_seconds"
        }
    }

    private struct Capture {
        let snapshot: PDFDocumentDifferenceSnapshot
        let pageCount: Int
    }

    /// Error descriptions contain an opaque manifest ID and stable code only.
    private enum Failure: Error {
        case invalidManifest, invalidReportDestination
        case unreadable(String), comparisonFailed(String), missingInsertion(String)
    }

    @MainActor
    func testExplicitCorpusSelfComparisonAndInMemoryUnicodeInsertion() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifest = environment["EMBER_DIFFERENCE_CORPUS_MANIFEST"], !manifest.isEmpty else {
            throw XCTSkip("Set EMBER_DIFFERENCE_CORPUS_MANIFEST and EMBER_DIFFERENCE_CORPUS_REPORT for explicit local corpus validation.")
        }
        guard manifest.hasPrefix("/"), let destination = environment["EMBER_DIFFERENCE_CORPUS_REPORT"],
              destination.hasPrefix("/"), URL(fileURLWithPath: destination).pathExtension.lowercased() == "json" else {
            throw Failure.invalidReportDestination
        }
        let fixtures: [Fixture]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
            guard data.count <= 1_048_576 else { throw Failure.invalidManifest }
            fixtures = try JSONDecoder().decode([Fixture].self, from: data)
        } catch { throw Failure.invalidManifest }
        guard fixtures.count == 30, Set(fixtures.map(\.id)).count == 30,
              fixtures.allSatisfy({ $0.path.hasPrefix("/") && $0.id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil }),
              Set(fixtures.map { URL(fileURLWithPath: $0.path).standardizedFileURL }).count == 30 else {
            throw Failure.invalidManifest
        }
        let reportURL = URL(fileURLWithPath: destination)
        try validateReportDestination(reportURL, fixtures: fixtures)
        var results: [Result] = []
        for fixture in fixtures {
            try Task.checkCancellation()
            results.append(try await verify(fixture))
        }
        try validateReportDestination(reportURL, fixtures: fixtures)
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: reportURL, options: .atomic)
        } catch { throw Failure.invalidReportDestination }
    }

    @MainActor
    private func verify(_ fixture: Fixture) async throws -> Result {
        let url = URL(fileURLWithPath: fixture.path)
        let access = SecurityScopedAccess(url: url)
        defer { withExtendedLifetime(access) {} }
        let version: PDFSourceFileVersion
        do { version = try PDFSourceFileVersion.capture(at: url) }
        catch { throw Failure.unreadable(fixture.id) }
        defer {
            // Assert a Boolean so XCTest never dumps a private canonical URL.
            let unchanged = (try? PDFSourceFileVersion.capture(at: url)) == version
            XCTAssertTrue(unchanged, "Source metadata changed for \(fixture.id)")
        }
        let captured: Capture
        do {
            captured = try autoreleasepool {
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0,
                      document.allowsCopying || document.permissionsStatus == .owner else { throw Failure.unreadable(fixture.id) }
                let count = document.pageCount
                let indices = Array(Set([0, count / 2, count - 1])).sorted()
                let strings = try indices.map { index -> String in
                    guard let page = document.page(at: index) else { throw Failure.unreadable(fixture.id) }
                    return page.string ?? ""
                }
                return Capture(snapshot: .init(pages: strings), pageCount: count)
            }
        } catch { throw Failure.unreadable(fixture.id) }
        let snapshot = captured.snapshot
        let textless = snapshot.pages.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let selfReport = try await Task.detached(priority: .utility) {
                try PDFDocumentDifferenceEngine.compare(snapshot, snapshot)
            }.value
            XCTAssertEqual(selfReport.changes.count, 0, "Self comparison produced changes for \(fixture.id)")
            XCTAssertEqual(selfReport.textlessPageCount, textless * 2, "Textless classification mismatch for \(fixture.id)")
            XCTAssertEqual(selfReport.hasNoTextChanges, textless == 0,
                           "Unexamined textless pages must not become an identical-text claim for \(fixture.id)")
            XCTAssertFalse(selfReport.isTruncated, "Sampled self comparison was truncated for \(fixture.id)")
        } catch PDFDocumentDifferenceFailure.noText {
            XCTAssertEqual(textless, snapshot.pages.count, "Only entirely textless samples may report noText for \(fixture.id)")
        } catch { throw Failure.comparisonFailed(fixture.id) }

        if let original = snapshot.pages.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            // Use the nearest word/character boundary to the string's center.
            // Splitting an existing Latin/Hangul word changes that word, whereas
            // this probe intentionally tests a single pure insertion.
            let index = insertionIndex(in: original)
            let offset = index.utf16Offset(in: original)
            let marker = "⟦EmberPDF검증😀⟧"
            guard !original.contains(marker) else { throw Failure.missingInsertion(fixture.id) }
            let modified = String(original[..<index]) + marker + String(original[index...])
            let before = PDFDocumentDifferenceSnapshot(pages: [original])
            let after = PDFDocumentDifferenceSnapshot(pages: [modified])
            let report: PDFDocumentDifferenceReport
            do {
                report = try await Task.detached(priority: .utility) {
                    try PDFDocumentDifferenceEngine.compare(before, after)
                }.value
            } catch { throw Failure.comparisonFailed(fixture.id) }
            XCTAssertEqual(report.changes.count, 1, "Expected exactly one in-memory insertion for \(fixture.id)")
            guard let change = report.changes.first else { throw Failure.missingInsertion(fixture.id) }
            XCTAssertEqual(change.kind, .added, "Unicode probe must remain a pure addition for \(fixture.id)")
            XCTAssertEqual(change.before?.pageIndex, 0)
            XCTAssertEqual(change.after?.pageIndex, 0)
            XCTAssertEqual(change.before?.range, NSRange(location: offset, length: 0), "Before UTF-16 anchor mismatch for \(fixture.id)")
            XCTAssertEqual(change.after?.range, NSRange(location: offset, length: marker.utf16.count), "After UTF-16 range mismatch for \(fixture.id)")
            // Do not expose source text in assertion diagnostics on failure.
            XCTAssertTrue(change.after?.excerpt == marker, "Unicode insertion excerpt mismatch for \(fixture.id)")
            if let range = change.after?.range,
               range.location >= 0, range.location <= modified.utf16.count,
               range.length <= modified.utf16.count - range.location {
                XCTAssertTrue((modified as NSString).substring(with: range) == marker, "Unicode insertion source-range mismatch for \(fixture.id)")
            } else { XCTFail("Invalid UTF-16 insertion range for \(fixture.id)") }
            XCTAssertFalse(report.isTruncated, "Unicode insertion probe was truncated for \(fixture.id)")
        }
        return Result(id: fixture.id, pageCount: captured.pageCount, textlessPageCount: textless,
                      comparisonSeconds: ProcessInfo.processInfo.systemUptime - began)
    }

    private func insertionIndex(in text: String) -> String.Index {
        let middle = text.utf16.count / 2
        var best: String.Index?
        var bestDistance = Int.max
        var offset = 0
        func consider(_ index: String.Index, offset: Int) {
            let distance = abs(offset - middle)
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        for index in text.indices {
            let next = text.index(after: index)
            let current = text[index]
            let nextOffset = offset + String(current).utf16.count
            if current.isWhitespace {
                if index > text.startIndex, !text[text.index(before: index)].isWhitespace { consider(index, offset: offset) }
                if next < text.endIndex, !text[next].isWhitespace { consider(next, offset: nextOffset) }
            } else if current.unicodeScalars.contains(where: {
                (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
                    || (0x3040...0x30FF).contains($0.value)
                    || CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
            }) {
                if index > text.startIndex { consider(index, offset: offset) }
                if next < text.endIndex { consider(next, offset: nextOffset) }
            }
            offset = nextOffset
        }
        // A page containing only one unbroken word has no internal token
        // boundary. Insert before it rather than turning the word into a replacement.
        return best ?? text.startIndex
    }

    private func validateReportDestination(_ url: URL, fixtures: [Fixture]) throws {
        guard fixtures.allSatisfy({ !PDFSourceFileVersion.refersToSameLocation(url, URL(fileURLWithPath: $0.path)) }) else {
            throw Failure.invalidReportDestination
        }
    }
}
