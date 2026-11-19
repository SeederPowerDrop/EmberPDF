// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

/// Isolates the native row boundary from scrolling/virtualization geometry.
/// Every view displays the same original PDFDocument, so shared commands must
/// be consumed by the row that actually owns their page.
@MainActor
final class PDFCompactSpreadInteractionTests: XCTestCase {
    func testSearchSelectionDoesNotNavigateAnUnrelatedSpread() async throws {
        let fixture = try await makeFixture()
        defer { fixture.detach() }
        let page = try XCTUnwrap(fixture.workspace.document?.page(at: 1))
        let selection = try textSelection(on: page)
        let unrelatedPage = fixture.rows[1].currentPage
        // Search navigation owns the model selection; a row only presents it.
        fixture.workspace.currentSelection = selection

        fixture.coordinators[1].applySearchSelection(selection, to: fixture.rows[1])

        XCTAssertTrue(fixture.rows[1].currentPage === unrelatedPage)
        XCTAssertNil(fixture.rows[1].currentSelection)
        XCTAssertTrue(fixture.rows[1].highlightedSelections?.isEmpty ?? true)
        XCTAssertTrue(fixture.workspace.currentSelection === selection)

        fixture.coordinators[0].applySearchSelection(selection, to: fixture.rows[0])

        XCTAssertTrue(fixture.rows[0].currentSelection === selection)
        XCTAssertTrue(fixture.rows[0].currentSelection?.pages.first === page)
        XCTAssertTrue(fixture.rows[0].document === fixture.workspace.document)
        XCTAssertEqual(fixture.rows[0].currentSelection?.string, selection.string)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    func testMountingARowCannotReplaceManualSelectionWithAnOldSearchHit() async throws {
        let fixture = try await makeFixture()
        defer { fixture.detach() }
        let workspace = fixture.workspace
        workspace.searchText = "Original"
        workspace.performSearch()
        for _ in 0..<400 where workspace.isSearching {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(workspace.isSearching)
        workspace.selectSearchResult(at: 0)
        let oldSearchHit = try XCTUnwrap(workspace.activeSearchSelection)
        let manualPage = try XCTUnwrap(workspace.document?.page(at: 3))
        let manualSelection = try textSelection(on: manualPage)
        fixture.rows[1].setCurrentSelection(manualSelection, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: fixture.rows[1])
        XCTAssertTrue(workspace.currentSelection === manualSelection)

        // Combine immediately replays the active search selection when a
        // virtual row reattaches. That replay is not a new search command.
        fixture.coordinators[0].detach()
        let remountedCoordinator = PDFKitViewer.Coordinator(state: workspace)
        remountedCoordinator.attach(to: fixture.rows[0])
        defer { remountedCoordinator.detach() }
        XCTAssertTrue(workspace.currentSelection === manualSelection)
        remountedCoordinator.applySearchSelection(oldSearchHit, to: fixture.rows[0])
        XCTAssertTrue(workspace.currentSelection === manualSelection)
        XCTAssertTrue(workspace.activeSearchSelection === oldSearchHit)
        XCTAssertFalse(workspace.isDirty)
    }

    func testOnlyOwningSpreadConsumesStudyNoteRevealAndLayoutSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.detach() }
        let workspace = fixture.workspace
        workspace.setMode(.study)
        let document = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(document.page(at: 3))
        let annotation = PDFAnnotation(bounds: CGRect(x: 100, y: 240, width: 140, height: 60),
                                       forType: .freeText, withProperties: nil)
        annotation.contents = "A note on the second spread"
        page.addAnnotation(annotation)
        let note = StudyNoteItem(documentID: ObjectIdentifier(document), pageIndex: 3,
                                 annotation: annotation, contents: annotation.contents ?? "")
        XCTAssertTrue(workspace.revealStudyNote(note))
        let request = try XCTUnwrap(workspace.studyNoteRevealRequest)

        fixture.coordinators[0].applyStudyNoteReveal(request, to: fixture.rows[0])
        XCTAssertFalse(request.isConsumed)
        XCTAssertTrue(workspace.studyNoteRevealRequest === request)
        XCTAssertTrue(fixture.rows[0].visiblePages.allSatisfy {
            document.index(for: $0) < 2
        })

        fixture.coordinators[1].applyStudyNoteReveal(request, to: fixture.rows[1])
        XCTAssertTrue(request.isConsumed)
        XCTAssertEqual(workspace.currentPageIndex, 3)

        XCTAssertTrue(workspace.selectStudyNoteForLayout(note))
        let layoutSelection = try XCTUnwrap(workspace.studyNoteLayoutSelection)
        fixture.rows[0].configure(with: workspace)
        XCTAssertFalse(layoutSelection.isConsumed,
                       "An earlier row must not take the note's resize handles.")
        fixture.rows[1].configure(with: workspace)
        XCTAssertTrue(layoutSelection.isConsumed)
        XCTAssertTrue(layoutSelection.annotation === annotation)
        XCTAssertTrue(annotation.page === page)
        XCTAssertFalse(workspace.isDirty, "Revealing a note must not edit the PDF.")
    }

    func testUnrelatedSpreadCannotClaimOrCommitInlineDraft() async throws {
        let fixture = try await makeFixture()
        defer { fixture.detach() }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        XCTAssertTrue(workspace.requestInlineTextEdit(pageIndex: 3,
            point: CGPoint(x: 100, y: 260), annotation: nil))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(id: draft.id, text: "Owned by the second spread",
                                               style: draft.style, bounds: draft.bounds)
        let sentinelOwner = UUID()
        XCTAssertTrue(workspace.claimPendingInlineTextEditor(ownerID: sentinelOwner, draftID: draft.id))

        fixture.rows[0].configureInlineTextEditingOverlay()
        XCTAssertTrue(workspace.ownsPendingInlineTextEditor(ownerID: sentinelOwner, draftID: draft.id))
        fixture.rows[1].configureInlineTextEditingOverlay()
        XCTAssertFalse(workspace.ownsPendingInlineTextEditor(ownerID: sentinelOwner, draftID: draft.id))

        fixture.rows[0].prepareInlineTextEditingOverlayForRemoval()
        XCTAssertEqual(workspace.pendingInlineTextEdit?.id, draft.id)
        XCTAssertEqual(workspace.pendingInlineTextEdit?.text, "Owned by the second spread")
        XCTAssertFalse(workspace.isDirty)

        fixture.rows[1].prepareInlineTextEditingOverlayForRemoval()
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertEqual(workspace.document?.page(at: 3)?.annotations.last?.contents,
                       "Owned by the second spread")
        for index in 0..<3 {
            XCTAssertTrue(try XCTUnwrap(workspace.document?.page(at: index)).annotations.isEmpty)
        }
        workspace.undo()
        XCTAssertTrue(try XCTUnwrap(workspace.document?.page(at: 3)).annotations.isEmpty)
    }

    func testNeighborDeselectionPreservesSelectionAndMarkupUsesOriginalPage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.detach() }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 1))
        let selection = try textSelection(on: page)
        fixture.rows[0].setCurrentSelection(selection, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: fixture.rows[0])
        XCTAssertTrue(workspace.currentSelection === selection)

        fixture.rows[1].clearSelection()
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: fixture.rows[1])
        XCTAssertTrue(workspace.currentSelection === selection,
                      "An offscreen or recycled neighbor must not clear the selected text.")

        workspace.highlightCurrentSelection()
        XCTAssertNotNil(workspace.markupSelectionClearRequestID)
        XCTAssertTrue(page.annotations.contains(where: { $0.type == "Highlight" }))
        for index in [0, 2, 3] {
            XCTAssertTrue(try XCTUnwrap(workspace.document?.page(at: index)).annotations.isEmpty)
        }
        for (view, coordinator) in zip(fixture.rows, fixture.coordinators) {
            coordinator.clearSelectionAfterMarkup(in: view)
            XCTAssertNil(view.currentSelection)
        }
        XCTAssertNil(workspace.currentSelection)
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testCrossSpreadPointerCommitSettlesTheMountedOwningEditorOnce() async throws {
        let fixture = try await makeFixture()
        defer { fixture.detach() }
        fixture.coordinators.forEach { $0.detach() }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let mountedHost = PDFCompactSpreadHostView(frame: CGRect(x: 0, y: 0, width: 1000, height: 840))
        fixture.window.contentView = mountedHost
        mountedHost.update(workspace: workspace, canvasColor: .windowBackgroundColor, onScrollActivity: nil)
        defer { mountedHost.tearDown() }
        for _ in 0..<100 {
            mountedHost.layoutSubtreeIfNeeded()
            if mountedHost.nativePDFView(forPageIndex: 0) != nil,
               mountedHost.nativePDFView(forPageIndex: 2) != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let owningView = try XCTUnwrap(mountedHost.nativePDFView(forPageIndex: 0))
        let neighboringContext = try XCTUnwrap(mountedHost.context(forPageIndex: 2))
        XCTAssertTrue(workspace.requestInlineTextEdit(pageIndex: 0,
            point: CGPoint(x: 100, y: 260), annotation: nil))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(id: draft.id, text: "Commit before clicking another spread",
                                               style: draft.style, bounds: draft.bounds)
        owningView.configureInlineTextEditingOverlay()

        // This is the compact-row boundary invoked before interpreting a
        // pointer action in a different native PDFView.
        neighboringContext.commitOtherInlineDraft()

        XCTAssertNil(workspace.pendingInlineTextEdit)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertEqual(page.annotations.first?.contents, "Commit before clicking another spread")
        XCTAssertTrue(try XCTUnwrap(workspace.document?.page(at: 2)).annotations.isEmpty)
        neighboringContext.commitOtherInlineDraft()
        XCTAssertEqual(page.annotations.count, 1)
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testRowsDoNotOverwriteWholeDocumentViewportOrCurrentPage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.detach() }
        let workspace = fixture.workspace
        workspace.setCurrentPage(3)
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.75,
            scrollProgress: PDFScrollProgress(horizontal: 0.17, vertical: 0.62))
        let viewport = workspace.pdfViewportState

        for (view, coordinator) in zip(fixture.rows, fixture.coordinators) {
            NotificationCenter.default.post(name: .PDFViewPageChanged, object: view)
            coordinator.captureViewportState()
        }

        XCTAssertEqual(workspace.currentPageIndex, 3)
        XCTAssertEqual(workspace.pdfViewportState, viewport,
                       "A paged row's clip percentages are not whole-document scroll percentages.")
        XCTAssertFalse(workspace.isDirty)
    }

    func testSearchCentersInOuterViewportAndRemountDoesNotRepeatTheJump() async throws {
        let fixture = try await makeFixture(pageCount: 12)
        defer { fixture.detach() }
        fixture.coordinators.forEach { $0.detach() }
        let workspace = fixture.workspace
        let mountedHost = PDFCompactSpreadHostView(frame: CGRect(x: 0, y: 0, width: 1000, height: 420))
        fixture.window.contentView = mountedHost
        mountedHost.update(workspace: workspace, canvasColor: .windowBackgroundColor, onScrollActivity: nil)
        defer { mountedHost.tearDown() }
        workspace.searchText = "Original"
        workspace.performSearch()
        for _ in 0..<400 where workspace.isSearching { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(workspace.isSearching)
        workspace.selectSearchResult(at: 8)
        let selection = try XCTUnwrap(workspace.activeSearchSelection)
        let page = try XCTUnwrap(selection.pages.first)
        XCTAssertEqual(workspace.document?.index(for: page), 8)
        mountedHost.update(workspace: workspace, canvasColor: .windowBackgroundColor, onScrollActivity: nil)
        for _ in 0..<30 {
            mountedHost.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let native = try XCTUnwrap(mountedHost.nativePDFView(forPageIndex: 8))
        let clip = mountedHost.scrollView.contentView
        let hit = clip.convert(native.convert(selection.bounds(for: page), from: page), from: native)
        XCTAssertEqual(hit.midY, clip.bounds.midY, accuracy: 1,
                       "Search must center in the outer continuous viewport, not the row's inner clip.")
        let manuallyChosenOrigin = CGPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + 60)

        clip.setBoundsOrigin(.zero)
        mountedHost.scrollView.reflectScrolledClipView(clip)
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(mountedHost.nativePDFView(forPageIndex: 8), "The distant search row should retire.")

        clip.setBoundsOrigin(manuallyChosenOrigin)
        mountedHost.scrollView.reflectScrolledClipView(clip)
        for _ in 0..<30 {
            mountedHost.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(mountedHost.nativePDFView(forPageIndex: 8))
        XCTAssertEqual(clip.bounds.origin.y, manuallyChosenOrigin.y, accuracy: 1,
                       "Recreating a row must not replay an already revealed search result.")
        XCTAssertTrue(workspace.activeSearchSelection === selection)
        XCTAssertFalse(workspace.isDirty)
    }

    func testNativeHitTestingAndCoordinateConversionRetainOriginalPageIdentity() async throws {
        let fixture = try await makeFixture(rotatedCrop: true)
        defer { fixture.detach() }
        let document = try XCTUnwrap(fixture.workspace.document)
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let bounds = page.bounds(for: .cropBox)
            let rotation = page.rotation
            let view = fixture.rows[index / 2]
            let point = CGPoint(x: bounds.midX, y: bounds.midY)
            let viewPoint = view.convert(point, from: page)
            let roundTrip = view.convert(viewPoint, to: page)

            XCTAssertTrue(view.document === document)
            XCTAssertTrue(view.page(for: viewPoint, nearest: false) === page)
            XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.001)
            XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.001)
            XCTAssertEqual(page.bounds(for: .cropBox), bounds)
            XCTAssertEqual(page.rotation, rotation)
            XCTAssertTrue(try textSelection(on: page).pages.first === page)
        }
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    private struct Fixture {
        let workspace: PDFWorkspaceState
        let host: PDFCompactSpreadHostView
        let rows: [InteractivePDFView]
        let coordinators: [PDFKitViewer.Coordinator]
        let window: NSWindow
        let directory: URL

        func detach() {
            workspace.cancelPendingInlineText()
            for coordinator in coordinators { coordinator.detach() }
            for view in rows {
                view.searchScroll.detach()
                view.regionSelection.cancel()
                view.arrowKeyRepeater.stop()
                view.prepareInlineTextEditingOverlayForRemoval()
                view.prepareAnnotationEditingOverlayForRemoval()
                view.workspaceState = nil
                view.compactSpread = nil
                view.document = nil
            }
            host.tearDown()
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
            workspace.closeDiscardingChanges()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(rotatedCrop: Bool = false, pageCount: Int = 4) async throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-compact-interactions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("four-pages.pdf")
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 500, height: 700)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let drawing = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<pageCount {
            drawing.beginPDFPage(nil)
            drawing.textPosition = CGPoint(x: 100, y: 400)
            let text = NSAttributedString(string: "Original page \(index + 1) selection",
                                          attributes: [.font: NSFont.systemFont(ofSize: 18)])
            CTLineDraw(CTLineCreateWithAttributedString(text), drawing)
            drawing.endPDFPage()
        }
        drawing.closePDF()
        try (bytes as Data).write(to: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        let document = try XCTUnwrap(workspace.document)
        if rotatedCrop {
            let page = try XCTUnwrap(document.page(at: 3))
            page.setBounds(CGRect(x: 30, y: 40, width: 440, height: 620), for: .cropBox)
            page.rotation = 90
        }
        workspace.pageColumns = 2
        workspace.twoPageDisplayMode = .continuous

        // A zero-sized host supplies page-identity authority without creating
        // its own rows; these tests deliberately control two native row views.
        let host = PDFCompactSpreadHostView(frame: .zero)
        host.update(workspace: workspace, canvasColor: .windowBackgroundColor, onScrollActivity: nil)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 840))
        let window = NSWindow(contentRect: container.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        var rows: [InteractivePDFView] = []
        var coordinators: [PDFKitViewer.Coordinator] = []
        for pageIndex in [0, 2] {
            let view = InteractivePDFView(frame: CGRect(x: 0, y: CGFloat(pageIndex / 2) * 420,
                                                       width: 1000, height: 420))
            view.compactSpread = PDFCompactSpreadContext(pageIndex: pageIndex, scaleFactor: 0.5, host: host)
            view.displayMode = .twoUp
            view.displayBox = .cropBox
            view.displaysAsBook = false
            view.displaysPageBreaks = false
            view.autoScales = false
            view.document = document
            view.scaleFactor = 0.5
            container.addSubview(view)
            view.go(to: try XCTUnwrap(document.page(at: pageIndex)))
            view.configure(with: workspace)
            view.layoutDocumentView()
            view.layoutSubtreeIfNeeded()
            let coordinator = PDFKitViewer.Coordinator(state: workspace)
            coordinator.attach(to: view)
            rows.append(view)
            coordinators.append(coordinator)
        }
        for _ in 0..<3 { try await Task.sleep(nanoseconds: 10_000_000) }
        for (index, view) in rows.enumerated() {
            XCTAssertTrue(view.visiblePages.contains(where: { $0 === document.page(at: index * 2) }))
        }
        return Fixture(workspace: workspace, host: host, rows: rows, coordinators: coordinators,
                       window: window, directory: directory)
    }

    private func textSelection(on page: PDFPage) throws -> PDFSelection {
        XCTAssertGreaterThan(page.numberOfCharacters, 0)
        return try XCTUnwrap(page.selection(for: NSRange(location: 0, length: min(8, page.numberOfCharacters))))
    }
}
