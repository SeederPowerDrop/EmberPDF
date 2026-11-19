// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

final class PDFDocumentDifferenceTests: XCTestCase {
    private func compare(_ before: [String], _ after: [String], limits: PDFDocumentDifferenceLimits = .init()) throws -> PDFDocumentDifferenceReport {
        try PDFDocumentDifferenceEngine.compare(.init(pages: before), .init(pages: after), limits: limits)
    }

    func testUnchangedTextNormalizesLayoutWhitespaceAndCanonicalUnicode() throws {
        let result = try compare(["  First\n\t second  ", "한글 café"], ["First second", "한글 cafe\u{301}"])
        XCTAssertTrue(result.hasNoTextChanges)
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.textlessPageCount, 0)
    }

    func testWhitespaceDoesNotJoinWordsOrHideKoreanSpacingChanges() throws {
        XCTAssertFalse(try compare(["a bc"], ["ab c"]).hasNoTextChanges)
        XCTAssertFalse(try compare(["한 글"], ["한글"]).hasNoTextChanges)
        XCTAssertFalse(try compare(["Case"], ["case"]).hasNoTextChanges)
        XCTAssertFalse(try compare(["café"], ["cafe"]).hasNoTextChanges)
    }

    func testCJKAndEmojiChangesKeepExactUTF16Ranges() throws {
        let old = "🧭 中文文書の価格は百円。", new = "🧭 中文文書の価格は千円。"
        let result = try compare([old], [new])
        let change = try XCTUnwrap(result.changes.first)
        XCTAssertEqual(result.changes.count, 1)
        XCTAssertEqual(change.kind, .modified)
        XCTAssertEqual(change.before?.excerpt, "百")
        XCTAssertEqual(change.after?.excerpt, "千")
        XCTAssertEqual((old as NSString).substring(with: try XCTUnwrap(change.before?.range)), "百")
        XCTAssertEqual((new as NSString).substring(with: try XCTUnwrap(change.after?.range)), "千")
    }

    func testInsertedPageDoesNotMarkEveryFollowingPageModified() throws {
        let result = try compare(["Page A", "Page B", "Page C"], ["Page A", "Inserted page", "Page B", "Page C"])
        XCTAssertEqual(result.changes.count, 1)
        let change = try XCTUnwrap(result.changes.first)
        XCTAssertEqual(change.kind, .added)
        XCTAssertNil(change.before)
        XCTAssertEqual(change.after?.pageIndex, 1)
        XCTAssertEqual(change.after?.excerpt, "Inserted page")
    }

    func testDeletedPageAndModifiedTextAreSeparate() throws {
        let result = try compare(["First", "Removed", "Stable", "Old value"], ["First", "Stable", "New value"])
        XCTAssertEqual(result.changes.map(\.kind), [.removed, .modified])
        XCTAssertEqual(result.changes[0].before?.pageIndex, 1)
        XCTAssertNil(result.changes[0].after)
        XCTAssertEqual(result.changes[1].before?.excerpt, "Old")
        XCTAssertEqual(result.changes[1].after?.excerpt, "New")
        XCTAssertEqual(result.changes[1].before?.pageIndex, 3)
        XCTAssertEqual(result.changes[1].after?.pageIndex, 2)
    }

    func testWordInsertionAndRemovalKeepNavigationAnchorsOnBothSides() throws {
        let added = try XCTUnwrap(try compare(["A value"], ["A new value"]).changes.first)
        XCTAssertEqual(added.kind, .added)
        XCTAssertEqual(added.before?.range.length, 0)
        XCTAssertEqual(added.after?.excerpt, "new ")
        let removed = try XCTUnwrap(try compare(["A new value"], ["A value"]).changes.first)
        XCTAssertEqual(removed.kind, .removed)
        XCTAssertEqual(removed.after?.range.length, 0)
    }

    func testBlankAndScannedTextNeverClaimAnIdenticalDocument() throws {
        XCTAssertThrowsError(try compare([""], [" \n"])) { XCTAssertEqual($0 as? PDFDocumentDifferenceFailure, .noText) }
        let partial = try compare(["Visible text", ""], ["Visible text", ""])
        XCTAssertEqual(partial.textlessPageCount, 2)
        XCTAssertFalse(partial.hasNoTextChanges)
        XCTAssertTrue(partial.changes.isEmpty)
        let removed = try compare(["Visible text", ""], ["Visible text"])
        XCTAssertEqual(removed.changes.first?.kind, .removed)
    }

    func testResultLimitAndInputLimitsAreExplicit() throws {
        var limits = PDFDocumentDifferenceLimits()
        limits.maximumChanges = 1
        let truncated = try compare(["Old A", "Old B"], ["New A", "New B"], limits: limits)
        XCTAssertEqual(truncated.changes.count, 1)
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertFalse(truncated.hasNoTextChanges)
        limits.maximumPagesPerDocument = 1
        XCTAssertThrowsError(try compare(["A", "B"], ["A"], limits: limits)) {
            XCTAssertEqual($0 as? PDFDocumentDifferenceFailure, .tooLarge)
        }
        limits = .init(); limits.maximumPageUTF16Count = 3
        XCTAssertThrowsError(try compare(["1234"], ["1234"], limits: limits)) {
            XCTAssertEqual($0 as? PDFDocumentDifferenceFailure, .tooLarge)
        }
        limits = .init(); limits.maximumTotalUTF16Count = 5
        XCTAssertThrowsError(try compare(["123"], ["123"], limits: limits)) {
            XCTAssertEqual($0 as? PDFDocumentDifferenceFailure, .tooLarge)
        }
        limits = .init(); limits.maximumDuration = -1
        XCTAssertThrowsError(try compare(["A"], ["B"], limits: limits)) {
            XCTAssertEqual($0 as? PDFDocumentDifferenceFailure, .timedOut)
        }
    }

    func testComplexPageFallsBackToOneWholePageChangeWithoutDroppingContent() throws {
        var limits = PDFDocumentDifferenceLimits(); limits.maximumTokenAlignmentCells = 4
        let report = try compare(["Alpha beta gamma"], ["Delta epsilon zeta"], limits: limits)
        XCTAssertEqual(report.changes.count, 1)
        XCTAssertTrue(report.changes[0].isWholePage)
        XCTAssertFalse(report.isTruncated)
        XCTAssertEqual(report.changes[0].before?.range.length, "Alpha beta gamma".utf16.count)
    }

    func testLargeTextbookAlignmentStaysBoundedAndCancellationWorks() async throws {
        let pages = (0..<1_576).map { "Textbook page \($0). A reference paragraph with Unicode 교재 中文." }
        var revised = pages
        revised.insert("A newly inserted page.", at: 740)
        let started = ProcessInfo.processInfo.systemUptime
        let report = try compare(pages, revised)
        XCTAssertEqual(report.changes.count, 1)
        XCTAssertEqual(report.changes.first?.after?.pageIndex, 740)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 8)
        let cancelled = Task.detached {
            try Task.checkCancellation()
            return try PDFDocumentDifferenceEngine.compare(.init(pages: pages), .init(pages: revised))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation must not produce a successful report") }
        catch is CancellationError { }
    }

    @MainActor
    func testServiceReadsAppliedPDFWithoutChangingOriginalsUndoOrNavigation() async throws {
        let before = try fixture(["First original", "Second page"])
        let after = try fixture(["First revised", "Second page"])
        let files = try [before, after].map { try Data(contentsOf: try XCTUnwrap($0.workspace.documentURL)) }
        let revisions = [before.workspace.revision, after.workspace.revision]
        before.workspace.setCurrentPage(1)
        let service = PDFDocumentDifferenceService()
        service.start(before: before, after: after)
        await service.waitForCompletion()
        XCTAssertEqual(service.phase, .completed)
        XCTAssertEqual(service.report?.changes.first?.kind, .modified)
        XCTAssertEqual(before.workspace.currentPageIndex, 1)
        XCTAssertEqual([before.workspace.revision, after.workspace.revision], revisions)
        for (index, source) in [before, after].enumerated() {
            XCTAssertFalse(source.workspace.isDirty)
            XCTAssertFalse(source.workspace.canUndo)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(source.workspace.documentURL)), files[index])
        }
        let change = try XCTUnwrap(service.report?.changes.first)
        XCTAssertEqual(service.locations(for: change, lockedIDs: [after.id]).keys.sorted { $0.uuidString < $1.uuidString }, [before.id])
        before.workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(service.locations(for: change, lockedIDs: []).isEmpty)
        XCTAssertEqual(service.phase, .invalidated)
    }

    @MainActor
    func testCancellationAndSourceChangeRejectLateWorkerResults() async throws {
        let before = try fixture(["Old"]), after = try fixture(["New"])
        let service = delayedService()
        service.start(before: before, after: after)
        await waitUntilComparing(service)
        service.cancel()
        try await Task.sleep(nanoseconds: 130_000_000)
        XCTAssertEqual(service.phase, .cancelled)
        XCTAssertNil(service.report)
        service.start(before: before, after: after)
        await waitUntilComparing(service)
        before.workspace.rotateSelectedPages(clockwise: true)
        await service.waitForCompletion()
        XCTAssertEqual(service.phase, .invalidated)
        XCTAssertNil(service.report)
    }

    @MainActor
    func testMembershipInvalidationAndLanguageNotificationsDoNotPublishStaleResults() async throws {
        let before = try fixture(["Old"]), after = try fixture(["New"])
        let service = delayedService()
        service.start(before: before, after: after)
        await waitUntilComparing(service)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        XCTAssertEqual(service.phase, .comparing, "Language changes must not cancel the immutable diff.")
        await service.waitForCompletion()
        XCTAssertEqual(service.phase, .completed)
        XCTAssertNotNil(service.report)
        service.invalidateIfNeeded(availableIDs: [before.id])
        XCTAssertEqual(service.phase, .invalidated)
        XCTAssertNil(service.report)
    }

    @MainActor
    func testDifferenceNavigationPreservesUnrelatedAndPinnedPanesWithSyncEnabled() throws {
        _ = NSApplication.shared
        let documents = try (0..<4).map { _ in try fixture((0..<8).map { "Page \($0)" }) }
        let views = documents.map { source -> InteractivePDFView in
            let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
            view.viewportContext = .comparison
            view.document = source.workspace.document
            view.autoScales = true
            view.layoutDocumentView()
            return view
        }
        let coordinator = PDFScrollSyncCoordinator(enabled: true)
        for (index, source) in documents.enumerated() {
            coordinator.register(pdfView: views[index], id: source.id, locked: index == 2)
        }
        let otherPage = PDFScrollSyncCoordinator.readingPage(in: views[3])
        let pinnedPage = PDFScrollSyncCoordinator.readingPage(in: views[2])
        let location = { (page: Int) in PDFDocumentDifferenceLocation(pageIndex: page, range: .init(location: 0, length: 4), excerpt: "Page") }
        XCTAssertTrue(coordinator.revealComparisonDifferences([
            documents[0].id: location(2), documents[1].id: location(5), documents[2].id: location(6)
        ]))
        XCTAssertTrue(PDFScrollSyncCoordinator.readingPage(in: views[0]) === documents[0].workspace.document?.page(at: 2))
        XCTAssertTrue(PDFScrollSyncCoordinator.readingPage(in: views[1]) === documents[1].workspace.document?.page(at: 5))
        XCTAssertTrue(PDFScrollSyncCoordinator.readingPage(in: views[2]) === pinnedPage)
        XCTAssertTrue(PDFScrollSyncCoordinator.readingPage(in: views[3]) === otherPage)
        XCTAssertTrue(coordinator.enabled)
        documents.forEach { XCTAssertFalse($0.workspace.isDirty) }
    }

    @MainActor
    func testDifferenceSidebarRendersCompletedAndIncompleteReportsAtCompactWidth() async throws {
        _ = NSApplication.shared
        let before = try fixture(["Original paragraph.", ""]), after = try fixture(["Revised paragraph.", ""])
        let service = PDFDocumentDifferenceService()
        service.start(before: before, after: after)
        await service.waitForCompletion()
        XCTAssertEqual(service.phase, .completed)
        let root = PDFDocumentDifferenceView(documents: [before, after], lockedIDs: [], service: service, reveal: { _ in }, close: {})
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<4 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 8_000)
        if let path = ProcessInfo.processInfo.environment["EMBER_DIFFERENCE_UI_QA_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("difference-sidebar.png"))
        }
        XCTAssertEqual(service.phase, .completed)
        XCTAssertEqual(service.report?.changes.count, 1)
    }

    @MainActor private func delayedService() -> PDFDocumentDifferenceService {
        PDFDocumentDifferenceService { before, after, limits in
            // Ignore cancellation in the fake worker to verify the completion
            // boundary itself, not just the cooperative real engine.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return try PDFDocumentDifferenceEngine.compare(before, after, limits: limits)
        }
    }

    @MainActor private func waitUntilComparing(_ service: PDFDocumentDifferenceService) async {
        for _ in 0..<200 {
            if service.phase == .comparing { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("The snapshot worker did not start")
    }

    @MainActor private func fixture(_ pages: [String]) throws -> ComparisonDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-Difference-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf"), document = PDFDocument()
        for (index, text) in pages.enumerated() {
            let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            view.font = .systemFont(ofSize: 17); view.string = text
            let pageDocument = try XCTUnwrap(PDFDocument(data: view.dataWithPDF(inside: view.bounds)))
            document.insert(try XCTUnwrap(pageDocument.page(at: 0)), at: index)
        }
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        return ComparisonDocument(id: UUID(), title: "Text comparison \(pages.count)", workspace: workspace)
    }
}
