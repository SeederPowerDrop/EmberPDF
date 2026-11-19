// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFGallerySearchTests: XCTestCase {
    @MainActor
    func testCrossWorkspaceSearchKeepsLazyTabsAndReadingStateUnchanged() async throws {
        let first = try fixture(name: "research.pdf", pages: ["Opening page", "CAFÉ ﬁle is the hidden passage."])
        let second = try fixture(name: "cafe file notes.pdf", pages: ["Unrelated contents"])
        let third = try fixture(name: "another.pdf", pages: ["No matching passage"])
        let workspaceIDs = [UUID(), UUID()]
        let documents = [first, second, third].enumerated().map { index, fixture in
            lazyEntry(url: fixture.url, pages: fixture.pages, workspaceID: workspaceIDs[index % 2])
        }
        let before = documents.map { Snapshot($0.session.workspace) }
        let controller = immediateController()
        await controller.search(query: "cafe file", documents: documents + [documents[0]])
        XCTAssertEqual(controller.progress.phase, .completed)
        XCTAssertEqual(controller.documentResults.count, 3, "Duplicate tab identities must not be scanned twice")
        XCTAssertEqual(controller.documentResults.filter(\.isMatch).count, 2)
        let content = try XCTUnwrap(controller.documentResults.first)
        XCTAssertFalse(content.filenameMatched)
        let hit = try XCTUnwrap(content.matches.first)
        XCTAssertEqual(hit.pageIndex, 1)
        let range = try XCTUnwrap(hit.snippetMatchRanges.first)
        XCTAssertEqual(PDFUnicodeSearchNormalizer.normalizeQuery((hit.snippet as NSString).substring(with: range)), "cafe file")
        let reopened = try XCTUnwrap(PDFDocument(url: first.url))
        XCTAssertEqual((try XCTUnwrap(reopened.page(at: 1)?.string) as NSString).substring(with: hit.sourceRange), hit.matchedText)
        XCTAssertTrue(controller.documentResults[1].filenameMatched)
        XCTAssertTrue(controller.documentResults[1].matches.isEmpty)
        for (index, entry) in documents.enumerated() { before[index].assertUnchanged(entry.session.workspace) }
        for item in [first, second, third] { XCTAssertEqual(try Data(contentsOf: item.url), item.bytes) }
    }

    @MainActor
    func testResidentUnsavedMergedTextIsSearchableWithoutSavingOrNavigating() async throws {
        let original = try fixture(pages: ["Original opening page"])
        let inserted = try fixture(pages: ["This unsaved needle must be found."])
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: original.url))
        workspace.setMode(.editing)
        workspace.merge(urls: [inserted.url], insertionIndex: 1)
        XCTAssertTrue(workspace.isDirty)
        let snapshot = Snapshot(workspace)
        let entry = PDFGalleryDocument(workspaceID: UUID(), workspaceTitle: "Work", session: PDFTabSession(workspace: workspace))
        let controller = immediateController()
        await controller.search(query: "needle", documents: [entry])
        XCTAssertEqual(controller.documentResults.first?.matches.map(\.pageIndex), [1])
        snapshot.assertUnchanged(workspace)
        XCTAssertEqual(try Data(contentsOf: original.url), original.bytes)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: original.url)).pageCount, 1)
    }

    @MainActor
    func testLockedRestrictedImageOnlyAndMissingDocumentsHaveHonestStatusesWithoutPrompts() async throws {
        let source = try fixture(pages: ["needle private contents"])
        let encrypted = source.url.deletingLastPathComponent().appendingPathComponent("needle-locked.pdf")
        let restricted = source.url.deletingLastPathComponent().appendingPathComponent("needle-restricted.pdf")
        let pdf = try XCTUnwrap(PDFDocument(url: source.url))
        XCTAssertTrue(pdf.write(to: encrypted, withOptions: [.ownerPasswordOption: "Owner9", .userPasswordOption: "Reader9"]))
        XCTAssertTrue(pdf.write(to: restricted, withOptions: [.ownerPasswordOption: "Owner9",
            .userPasswordOption: "Reader9", .accessPermissionsOption: NSNumber(value: 0)]))
        let imageOnly = try fixture(pages: [""])
        var prompts = 0
        let restrictedWorkspace = PDFWorkspaceState(passwordProvider: { _, _ in prompts += 1; return "Reader9" })
        XCTAssertTrue(restrictedWorkspace.open(url: restricted))
        XCTAssertFalse(try XCTUnwrap(restrictedWorkspace.document).allowsCopying)
        let entries = [
            lazyEntry(url: encrypted, pages: 1),
            PDFGalleryDocument(workspaceID: UUID(), workspaceTitle: "Restricted", session: PDFTabSession(workspace: restrictedWorkspace)),
            lazyEntry(url: imageOnly.url, pages: 1),
            lazyEntry(url: source.url.deletingLastPathComponent().appendingPathComponent("needle-missing.pdf"), pages: 1)
        ]
        let beforePrompts = prompts
        let controller = immediateController()
        await controller.search(query: "needle", documents: entries)
        XCTAssertEqual(controller.documentResults.map(\.status), [.locked, .copyRestricted, .noText, .unavailable])
        XCTAssertEqual(controller.progress.skippedDocumentCount, 4)
        XCTAssertEqual(controller.progress.resultCount, 0)
        XCTAssertTrue(controller.documentResults[0].filenameMatched)
        XCTAssertTrue(controller.documentResults[1].filenameMatched)
        XCTAssertEqual(prompts, beforePrompts)
        XCTAssertTrue(entries.allSatisfy { $0.session.workspace.presentedError == nil })
    }

    @MainActor
    func testCapsAreVisibleAndPageCapStillAllowsHitsOnLaterPages() async throws {
        let source = try fixture(pages: Array(repeating: "needle needle needle needle needle", count: 4))
        let documents = (0..<3).map { _ in lazyEntry(url: source.url, pages: 4) }
        var configuration = PDFGallerySearchConfiguration()
        configuration.debounceNanoseconds = 0
        configuration.maximumResultsPerDocument = 3
        configuration.maximumResultsPerPage = 2
        configuration.maximumTotalResults = 4
        let controller = PDFGallerySearchController(configuration: configuration)
        await controller.search(query: "needle", documents: documents)
        XCTAssertEqual(controller.progress.resultCount, 4)
        XCTAssertTrue(controller.progress.isTruncated)
        XCTAssertEqual(controller.documentResults[0].matches.map(\.pageIndex), [0, 0, 1])
        XCTAssertTrue(controller.documentResults[0].isTruncated)
        XCTAssertEqual(controller.documentResults[1].matches.count, 1)
        XCTAssertEqual(controller.documentResults[2].status, .notSearched)
        XCTAssertTrue(documents.allSatisfy { $0.session.workspace.document == nil })
    }

    @MainActor
    func testExactLastPageCapacityDoesNotClaimTruncationAndNoMatchScanHasNoPageCutoff() async throws {
        let source = try fixture(pages: Array(repeating: "Unrelated page", count: 40) + ["needle needle"])
        var configuration = PDFGallerySearchConfiguration()
        configuration.debounceNanoseconds = 0
        configuration.maximumResultsPerDocument = 2
        configuration.maximumResultsPerPage = 2
        configuration.maximumTotalResults = 2
        let controller = PDFGallerySearchController(configuration: configuration)
        let document = lazyEntry(url: source.url, pages: source.pages)
        await controller.search(query: "needle", documents: [document])
        XCTAssertEqual(controller.documentResults.first?.matches.map(\.pageIndex), [40, 40])
        XCTAssertEqual(controller.progress.scannedPages, 41)
        XCTAssertFalse(controller.progress.isTruncated)
        await controller.search(query: "absent", documents: [document])
        XCTAssertEqual(controller.progress.scannedPages, 41)
        XCTAssertEqual(controller.progress.resultCount, 0)
        XCTAssertEqual(controller.documentResults.first?.status, .completed)
    }

    @MainActor
    func testCancellationPreservesPublishedHitsAndNewQueryCannotReceiveOldResults() async throws {
        let source = try fixture(pages: Array(repeating: "needle one. second target.", count: 20))
        let document = lazyEntry(url: source.url, pages: source.pages)
        let controller = immediateController()
        var didCancel = false
        let observation = controller.$progress.sink { progress in
            if !didCancel, progress.resultCount > 0 {
                didCancel = true
                Task { @MainActor in controller.cancel() }
            }
        }
        await controller.search(query: "needle", documents: [document])
        withExtendedLifetime(observation) {}
        XCTAssertTrue(didCancel)
        XCTAssertEqual(controller.progress.phase, .cancelled)
        XCTAssertGreaterThan(controller.progress.resultCount, 0)
        XCTAssertLessThan(controller.progress.scannedPages, 20)
        await controller.search(query: "target", documents: [document])
        XCTAssertEqual(controller.query, "target")
        XCTAssertEqual(controller.progress.phase, .completed)
        XCTAssertTrue(controller.documentResults.flatMap(\.matches).allSatisfy { $0.matchedText == "target" })
        await controller.search(query: " \n ", documents: [document])
        XCTAssertEqual(controller.progress, .idle)
        XCTAssertTrue(controller.documentResults.isEmpty)
    }

    @MainActor
    func testSupersededDebouncedRequestNeverOverwritesLatestScope() async throws {
        let source = try fixture(pages: ["needle target"])
        var configuration = PDFGallerySearchConfiguration()
        configuration.debounceNanoseconds = 30_000_000
        let controller = PDFGallerySearchController(configuration: configuration)
        let first = lazyEntry(url: source.url, pages: 1)
        let second = lazyEntry(url: source.url, pages: 1)
        let task = Task { await controller.search(query: "needle", documents: [first]) }
        await Task.yield()
        await controller.search(query: "target", documents: [second])
        await task.value
        XCTAssertEqual(controller.documentResults.map(\.id), [second.id])
        XCTAssertEqual(controller.documentResults.flatMap(\.matches).map(\.matchedText), ["target"])
        XCTAssertEqual(controller.progress.phase, .completed)
    }

    @MainActor
    func testLazyFileReplacementDiscardsPublishedHitsAndNextSearchUsesNewBytes() async throws {
        let original = try fixture(pages: Array(repeating: "needle original", count: 8))
        let replacement = try fixture(pages: ["replacement target"])
        let entry = lazyEntry(url: original.url, pages: original.pages)
        let snapshot = Snapshot(entry.session.workspace)
        let controller = immediateController()
        var replaced = false
        let observation = controller.$progress.sink { progress in
            if !replaced, progress.resultCount > 0 {
                replaced = true
                try? replacement.bytes.write(to: original.url, options: .atomic)
            }
        }
        await controller.search(query: "needle", documents: [entry])
        withExtendedLifetime(observation) {}
        XCTAssertTrue(replaced)
        XCTAssertEqual(controller.documentResults.first?.status, .changed)
        XCTAssertEqual(controller.progress.resultCount, 0)
        snapshot.assertUnchanged(entry.session.workspace)
        await controller.search(query: "target", documents: [entry])
        XCTAssertEqual(controller.documentResults.first?.matches.count, 1)
        XCTAssertEqual(controller.documentResults.first?.totalPages, 1)
        snapshot.assertUnchanged(entry.session.workspace)
    }

    @MainActor
    func testLiveRevisionChangeDiscardsHitsRatherThanMixingDocumentVersions() async throws {
        let source = try fixture(pages: Array(repeating: "needle", count: 6))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: source.url))
        workspace.setMode(.editing)
        workspace.selectedPages = [0]
        let entry = PDFGalleryDocument(workspaceID: UUID(), workspaceTitle: "Work", session: PDFTabSession(workspace: workspace))
        let controller = immediateController()
        var edited = false
        let observation = controller.$progress.sink { progress in
            if !edited, progress.resultCount > 0 {
                edited = true
                workspace.rotateSelectedPages(clockwise: true)
            }
        }
        await controller.search(query: "needle", documents: [entry])
        withExtendedLifetime(observation) {}
        XCTAssertTrue(edited)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(controller.documentResults.first?.status, .changed)
        XCTAssertEqual(controller.progress.resultCount, 0)
        XCTAssertEqual(try Data(contentsOf: source.url), source.bytes)
    }

    @MainActor
    private func immediateController() -> PDFGallerySearchController {
        var configuration = PDFGallerySearchConfiguration()
        configuration.debounceNanoseconds = 0
        return PDFGallerySearchController(configuration: configuration)
    }

    @MainActor
    private func lazyEntry(url: URL, pages: Int, workspaceID: UUID = UUID()) -> PDFGalleryDocument {
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(url: url, pageCount: pages, currentPageIndex: min(1, pages - 1), selectedPages: [0])
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.4,
                                    scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.6))
        return PDFGalleryDocument(workspaceID: workspaceID, workspaceTitle: "Workspace \(workspaceID)",
                                  session: PDFTabSession(workspace: workspace), groupTitle: "Reference")
    }

    @MainActor
    private struct Snapshot {
        let revision: UUID
        let page: Int
        let selectedPages: Set<Int>
        let viewport: PDFViewerViewportState
        let documentID: ObjectIdentifier?
        let dirty: Bool

        init(_ workspace: PDFWorkspaceState) {
            revision = workspace.revision
            page = workspace.currentPageIndex
            selectedPages = workspace.selectedPages
            viewport = workspace.pdfViewportState
            documentID = workspace.document.map(ObjectIdentifier.init)
            dirty = workspace.isDirty
        }

        func assertUnchanged(_ workspace: PDFWorkspaceState, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(workspace.revision, revision, file: file, line: line)
            XCTAssertEqual(workspace.currentPageIndex, page, file: file, line: line)
            XCTAssertEqual(workspace.selectedPages, selectedPages, file: file, line: line)
            XCTAssertEqual(workspace.pdfViewportState, viewport, file: file, line: line)
            XCTAssertEqual(workspace.document.map(ObjectIdentifier.init), documentID, file: file, line: line)
            XCTAssertEqual(workspace.isDirty, dirty, file: file, line: line)
        }
    }

    @MainActor
    private func fixture(name: String = "document.pdf", pages: [String]) throws -> (url: URL, pages: Int, bytes: Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-GallerySearch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        let document = PDFDocument()
        for (index, text) in pages.enumerated() {
            let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 720, height: 900))
            view.backgroundColor = .white
            view.textColor = .black
            view.font = .systemFont(ofSize: 17)
            view.string = text
            let page = try XCTUnwrap(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0))
            document.insert(page, at: index)
        }
        XCTAssertTrue(document.write(to: url))
        return (url, pages.count, try Data(contentsOf: url))
    }
}
