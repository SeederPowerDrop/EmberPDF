// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFPageGalleryTests: XCTestCase {
    func testCommandClickCanClearTheLastSelection() {
        let result = PDFPageGallerySelection.select(
            page: 2,
            selectedPages: [2],
            anchor: 2,
            pageCount: 6,
            toggling: true
        )

        XCTAssertTrue(result.selectedPages.isEmpty)
        XCTAssertEqual(result.anchor, 2)
    }

    func testShiftSelectionGrowsAndShrinksAroundTheOriginalAnchor() {
        let expanded = PDFPageGallerySelection.select(
            page: 5,
            selectedPages: [2],
            anchor: 2,
            pageCount: 8,
            extending: true
        )
        XCTAssertEqual(expanded.selectedPages, [2, 3, 4, 5])
        XCTAssertEqual(expanded.anchor, 2)

        let contracted = PDFPageGallerySelection.select(
            page: 3,
            selectedPages: expanded.selectedPages,
            anchor: expanded.anchor,
            pageCount: 8,
            extending: true
        )
        XCTAssertEqual(contracted.selectedPages, [2, 3])

        let reversed = PDFPageGallerySelection.select(
            page: 0,
            selectedPages: contracted.selectedPages,
            anchor: contracted.anchor,
            pageCount: 8,
            extending: true
        )
        XCTAssertEqual(reversed.selectedPages, [0, 1, 2])
        XCTAssertEqual(reversed.anchor, 2)
    }

    func testCommandShiftAddsRangeAndPlainClickReplacesSelection() {
        let extended = PDFPageGallerySelection.select(
            page: 4,
            selectedPages: [0, 2, 7],
            anchor: 2,
            pageCount: 8,
            extending: true,
            toggling: true
        )
        XCTAssertEqual(extended.selectedPages, [0, 2, 3, 4, 7])

        let replaced = PDFPageGallerySelection.select(
            page: 6,
            selectedPages: extended.selectedPages,
            anchor: extended.anchor,
            pageCount: 8
        )
        XCTAssertEqual(replaced.selectedPages, [6])
        XCTAssertEqual(replaced.anchor, 6)
    }

    func testSelectionHandlesDeletedPagesEmptyDocumentsAndMissingAnchor() {
        let stale = PDFPageGallerySelection.select(
            page: 4,
            selectedPages: [-1, 1, 8],
            anchor: 8,
            pageCount: 5,
            extending: true
        )
        XCTAssertEqual(stale.selectedPages, [1, 2, 3, 4])
        XCTAssertEqual(stale.anchor, 1)

        let empty = PDFPageGallerySelection.select(
            page: 0,
            selectedPages: [0, 2],
            anchor: 2,
            pageCount: 0,
            extending: true
        )
        XCTAssertTrue(empty.selectedPages.isEmpty)
        XCTAssertNil(empty.anchor)
        XCTAssertEqual(PDFPageGallerySelection.selectAll(pageCount: 3), [0, 1, 2])
        XCTAssertTrue(PDFPageGallerySelection.selectAll(pageCount: -1).isEmpty)
    }

    func testMovePlanAccountsForRemovedPagesAndRecognizesStationaryGroups() throws {
        let toEnd = try XCTUnwrap(PDFPageGalleryMovePlan(
            selectedPages: [1, 3], before: 6, pageCount: 6
        ))
        XCTAssertEqual(toEnd.sourceIndexes, [1, 3])
        XCTAssertEqual(toEnd.destinationIndexes, [4, 5])
        XCTAssertTrue(toEnd.changesOrder)

        let toStart = try XCTUnwrap(PDFPageGalleryMovePlan(
            selectedPages: [2, 4], before: 0, pageCount: 6
        ))
        XCTAssertEqual(toStart.destinationIndexes, [0, 1])

        for target in 1...4 {
            let unchanged = try XCTUnwrap(PDFPageGalleryMovePlan(
                selectedPages: [1, 2, 3], before: target, pageCount: 6
            ))
            XCTAssertFalse(unchanged.changesOrder)
        }
        XCTAssertNil(PDFPageGalleryMovePlan(selectedPages: [], before: 0, pageCount: 6))
        XCTAssertNil(PDFPageGalleryMovePlan(selectedPages: [0, 6], before: 0, pageCount: 6))
        XCTAssertNil(PDFPageGalleryMovePlan(selectedPages: [0], before: -1, pageCount: 6))
        XCTAssertNil(PDFPageGalleryMovePlan(selectedPages: [0], before: 7, pageCount: 6))
    }

    @MainActor
    func testBatchMovePreservesPageIdentityAndUndoesAsOneTransaction() throws {
        let workspace = try makeWorkspace(pageCount: 6)
        let document = try XCTUnwrap(workspace.document)
        let originalPages = try (0..<document.pageCount).map { try XCTUnwrap(document.page(at: $0)) }
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 60, height: 20),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "Keep this annotation with page 4"
        originalPages[3].addAnnotation(annotation)
        workspace.selectedPages = [1, 3]
        workspace.currentPageIndex = 3

        workspace.moveSelectedPages(before: 6)

        assertOrder(document, originalPages: originalPages, indexes: [0, 2, 4, 5, 1, 3])
        XCTAssertEqual(workspace.selectedPages, [4, 5])
        XCTAssertEqual(workspace.currentPageIndex, 4)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(originalPages[3].annotations.contains { $0 === annotation })

        workspace.undo()

        assertOrder(document, originalPages: originalPages, indexes: [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(workspace.selectedPages, [1, 3])
        XCTAssertEqual(workspace.currentPageIndex, 3)
        XCTAssertFalse(workspace.canUndo, "A batch move must add exactly one history command.")
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(workspace.canRedo)

        workspace.redo()

        assertOrder(document, originalPages: originalPages, indexes: [0, 2, 4, 5, 1, 3])
        XCTAssertEqual(workspace.selectedPages, [4, 5])
        XCTAssertEqual(workspace.currentPageIndex, 4)
        XCTAssertTrue(originalPages[3].annotations.contains { $0 === annotation })
    }

    @MainActor
    func testBatchMoveToStartAndMiddlePreservesRelativeOrder() throws {
        let workspace = try makeWorkspace(pageCount: 6)
        let document = try XCTUnwrap(workspace.document)
        let pages = try (0..<document.pageCount).map { try XCTUnwrap(document.page(at: $0)) }
        workspace.selectedPages = [2, 4]
        workspace.moveSelectedPages(before: 0)
        assertOrder(document, originalPages: pages, indexes: [2, 4, 0, 1, 3, 5])
        XCTAssertEqual(workspace.selectedPages, [0, 1])
        workspace.undo()

        workspace.selectedPages = [0, 4]
        workspace.moveSelectedPages(before: 3)
        assertOrder(document, originalPages: pages, indexes: [1, 2, 0, 4, 3, 5])
        XCTAssertEqual(workspace.selectedPages, [2, 3])
        workspace.undo()
        assertOrder(document, originalPages: pages, indexes: [0, 1, 2, 3, 4, 5])
    }

    @MainActor
    func testBatchMoveRejectsInvalidAndUnchangedRequestsWithoutSideEffects() throws {
        let workspace = try makeWorkspace(pageCount: 4)
        let document = try XCTUnwrap(workspace.document)
        let pages = try (0..<document.pageCount).map { try XCTUnwrap(document.page(at: $0)) }
        let revision = workspace.revision
        workspace.statusMessage = "unchanged status"
        workspace.presentedError = "unchanged error"

        let requests: [(Set<Int>, Int)] = [
            ([], 0), ([1, 4], 0), ([-1, 1], 0), ([1], -1), ([1], 5),
            ([1, 2], 1), ([1, 2], 2), ([1, 2], 3), ([0, 1, 2, 3], 4)
        ]
        for (selection, target) in requests {
            workspace.selectedPages = selection
            workspace.moveSelectedPages(before: target)
            assertOrder(document, originalPages: pages, indexes: [0, 1, 2, 3])
            XCTAssertEqual(workspace.selectedPages, selection)
            XCTAssertEqual(workspace.revision, revision)
            XCTAssertFalse(workspace.isDirty)
            XCTAssertFalse(workspace.canUndo)
            XCTAssertEqual(workspace.statusMessage, "unchanged status")
            XCTAssertEqual(workspace.presentedError, "unchanged error")
        }
    }

    @MainActor
    func testBatchMoveIsClosedInViewerAndStudyModes() throws {
        let workspace = try makeWorkspace(pageCount: 4)
        let document = try XCTUnwrap(workspace.document)
        let pages = try (0..<document.pageCount).map { try XCTUnwrap(document.page(at: $0)) }
        for mode in [PDFWorkspaceMode.viewer, .study] {
            workspace.setMode(mode)
            workspace.selectedPages = [0, 2]
            let revision = workspace.revision

            workspace.moveSelectedPages(before: 4)

            assertOrder(document, originalPages: pages, indexes: [0, 1, 2, 3])
            XCTAssertEqual(workspace.selectedPages, [0, 2])
            XCTAssertEqual(workspace.revision, revision)
            XCTAssertFalse(workspace.isDirty)
            XCTAssertFalse(workspace.canUndo)
        }
    }

    @MainActor
    private func makeWorkspace(pageCount: Int) throws -> PDFWorkspaceState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-PageGallery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pages.pdf")
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: CGFloat(100 + index), height: 150), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                return true
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        return workspace
    }

    private func assertOrder(
        _ document: PDFDocument,
        originalPages: [PDFPage],
        indexes: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(document.pageCount, indexes.count, file: file, line: line)
        for (destination, source) in indexes.enumerated() {
            XCTAssertTrue(document.page(at: destination) === originalPages[source], file: file, line: line)
        }
    }
}
