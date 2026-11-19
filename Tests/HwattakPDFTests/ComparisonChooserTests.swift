// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class ComparisonChooserTests: XCTestCase {
    @MainActor
    func testWorkspaceFilterPreservesTabIdentityAndDoesNotWakeOrNavigateDocuments() {
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        let first = candidate(title: "Shared.pdf", workspaceID: firstWorkspace, workspaceTitle: "Research", tabIndex: 3)
        let second = candidate(title: "Shared.pdf", workspaceID: secondWorkspace, workspaceTitle: "Reading", tabIndex: 7)
        let candidates = [first, second]
        let revisions = candidates.map { $0.workspace.revision }
        let pages = candidates.map { $0.workspace.currentPageIndex }
        let pageSelections = candidates.map { $0.workspace.selectedPages }

        XCTAssertEqual(ComparisonChooserFilter().documents(in: candidates).map(\.id), [first.id, second.id])
        XCTAssertEqual(ComparisonChooserFilter(workspaceID: secondWorkspace, query: "Shared")
            .documents(in: candidates).map(\.id), [second.id])
        XCTAssertEqual(ComparisonChooserFilter(workspaceID: firstWorkspace, query: "Reading")
            .documents(in: candidates).map(\.id), [])
        XCTAssertEqual(candidates.map { $0.workspace.revision }, revisions)
        XCTAssertEqual(candidates.map { $0.workspace.currentPageIndex }, pages)
        XCTAssertEqual(candidates.map { $0.workspace.selectedPages }, pageSelections)
        XCTAssertTrue(candidates.allSatisfy { $0.workspace.isHibernated && $0.workspace.document == nil })
    }

    @MainActor
    func testSearchCombinesFilenameWorkspaceGroupAndTabNumberWithoutChangingCandidateOrder() {
        let workspaceID = UUID()
        let first = candidate(title: "Résumé.pdf", workspaceID: workspaceID, workspaceTitle: "Research", tabIndex: 7, groupTitle: "Art History")
        let second = candidate(title: "Résumé.pdf", workspaceID: workspaceID, workspaceTitle: "Research", tabIndex: 2, groupTitle: "Science")
        let candidates = [second, first]

        XCTAssertEqual(ComparisonChooserFilter(query: "  RESUME  research \n history 7 ")
            .documents(in: candidates).map(\.id), [first.id])
        XCTAssertEqual(ComparisonChooserFilter(query: "resume research")
            .documents(in: candidates).map(\.id), [second.id, first.id])
        XCTAssertTrue(ComparisonChooserFilter(query: "resume missing").documents(in: candidates).isEmpty)
        XCTAssertEqual(ComparisonChooserFilter(query: " \n ").documents(in: candidates).map(\.id), [second.id, first.id])
    }

    func testPreviewPageChoiceClampsSavedPositionsAndKeepsCoverAtFirstPage() {
        XCTAssertEqual(ComparisonChooserPreviewPage.current.pageIndex(currentPageIndex: 8, pageCount: 12), 8)
        XCTAssertEqual(ComparisonChooserPreviewPage.current.pageIndex(currentPageIndex: 80, pageCount: 12), 11)
        XCTAssertEqual(ComparisonChooserPreviewPage.current.pageIndex(currentPageIndex: -1, pageCount: 0), 0)
        XCTAssertEqual(ComparisonChooserPreviewPage.cover.pageIndex(currentPageIndex: 8, pageCount: 12), 0)
    }

    @MainActor
    func testCoverPreviewOfLazyDocumentDoesNotMoveSavedCurrentPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComparisonChooser-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.pdf")
        let source = PDFDocument()
        for color in [NSColor.red, .green, .blue] {
            let image = NSImage(size: NSSize(width: 120, height: 180), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
            source.insert(try XCTUnwrap(PDFPage(image: image)), at: source.pageCount)
        }
        XCTAssertTrue(source.write(to: url))
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(url: url, pageCount: 3, currentPageIndex: 2, selectedPages: [1, 2])
        let revision = workspace.revision
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        let page = ComparisonChooserPreviewPage.cover.pageIndex(currentPageIndex: workspace.currentPageIndex, pageCount: workspace.pageCount)
        let result = await service.preview(for: workspace, pageIndex: page, width: 120)
        let preview = try XCTUnwrap(result)

        XCTAssertEqual(preview.pageIndex, 0)
        XCTAssertEqual(preview.pageCount, 3)
        XCTAssertEqual(workspace.currentPageIndex, 2)
        XCTAssertEqual(workspace.selectedPages, [1, 2])
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertTrue(workspace.isHibernated)
        XCTAssertNil(workspace.document)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    private func candidate(title: String, workspaceID: UUID, workspaceTitle: String,
                           tabIndex: Int, groupTitle: String? = nil) -> ComparisonDocument {
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(url: URL(fileURLWithPath: "/tmp/chooser-metadata-\(UUID()).pdf"),
                                    pageCount: 12, currentPageIndex: 5, selectedPages: [2, 5])
        return ComparisonDocument(id: UUID(), title: title, workspace: workspace,
                                  workspaceID: workspaceID, workspaceTitle: workspaceTitle,
                                  tabIndex: tabIndex, groupTitle: groupTitle)
    }
}
