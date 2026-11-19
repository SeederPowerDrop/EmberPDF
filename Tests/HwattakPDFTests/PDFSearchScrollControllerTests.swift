// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFSearchScrollControllerTests: XCTestCase {
    @MainActor
    func testStudyNoteRevealCentersDifferentNotesOnTheSamePage() async throws {
        let fixture = try await makeNavigationFixture()
        defer { fixture.detach() }
        let page = try XCTUnwrap(fixture.workspace.document?.page(at: 1))
        for y in [CGFloat(100), 530] {
            let annotation = PDFAnnotation(bounds: CGRect(x: 180, y: y, width: 150, height: 60),
                                           forType: .freeText, withProperties: nil)
            annotation.contents = "Note at \(y)"
            page.addAnnotation(annotation)
        }
        fixture.workspace.setMode(.study)
        fixture.workspace.currentPageIndex = 1
        fixture.view.scaleFactor = 1.5
        fixture.view.go(to: page)
        fixture.view.layoutDocumentView()
        let coordinator = PDFKitViewer.Coordinator(state: fixture.workspace)
        coordinator.attach(to: fixture.view)
        defer { coordinator.detach() }
        let notes = fixture.workspace.studyNotes(on: 1)
        XCTAssertEqual(notes.count, 2)
        var previousOrigin: CGFloat?

        for note in notes {
            XCTAssertTrue(fixture.workspace.revealStudyNote(note))
            let request = try XCTUnwrap(fixture.workspace.studyNoteRevealRequest)
            coordinator.applyStudyNoteReveal(request, to: fixture.view)
            await drainMainActor()

            let clip = try XCTUnwrap(fixture.view.firstDocumentScrollView()).contentView
            let bounds = note.annotation.bounds
            let center = clip.convert(fixture.view.convert(CGPoint(x: bounds.midX, y: bounds.midY),
                                                           from: page), from: fixture.view)
            XCTAssertEqual(center.y, clip.bounds.midY, accuracy: 0.75)
            XCTAssertEqual(fixture.workspace.currentPageIndex, 1,
                           "The second request must move the viewport without changing page index.")
            XCTAssertEqual(fixture.view.scaleFactor, 1.5, accuracy: 0.001)
            XCTAssertNil(fixture.workspace.studyNoteRevealRequest)
            if let previousOrigin {
                XCTAssertGreaterThan(abs(clip.bounds.minY - previousOrigin), 300)
            }
            previousOrigin = clip.bounds.minY
        }
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testStudyNoteRevealRejectsRequestFromAnotherDocument() async throws {
        let fixture = try await makeNavigationFixture()
        defer { fixture.detach() }
        let otherDocument = PDFDocument()
        let otherPage = PDFPage()
        otherDocument.insert(otherPage, at: 0)
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 100, height: 60),
                                       forType: .freeText, withProperties: nil)
        annotation.contents = "Old document note"
        otherPage.addAnnotation(annotation)
        let request = StudyNoteRevealRequest(document: otherDocument,
                                            revision: fixture.workspace.revision, annotation: annotation)
        fixture.workspace.studyNoteRevealRequest = request
        let coordinator = PDFKitViewer.Coordinator(state: fixture.workspace)
        coordinator.attach(to: fixture.view)
        defer { coordinator.detach() }
        let clip = try XCTUnwrap(fixture.view.firstDocumentScrollView()).contentView
        let originalOrigin = clip.bounds.origin
        let originalPage = fixture.workspace.currentPageIndex

        coordinator.applyStudyNoteReveal(request, to: fixture.view)
        await drainMainActor()

        XCTAssertEqual(clip.bounds.origin, originalOrigin)
        XCTAssertEqual(fixture.workspace.currentPageIndex, originalPage)
        XCTAssertFalse(request.isConsumed)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testExplicitSearchCentersRotatedCroppedHitAtCurrentZoomInContinuousAndPagedViews() async throws {
        let fixture = try await makeNavigationFixture { document in
            let page = document.page(at: 1)!
            page.setBounds(CGRect(x: 30, y: 40, width: 440, height: 620), for: .cropBox)
            page.rotation = 90
        }
        defer { fixture.detach() }
        fixture.workspace.searchText = "needle"
        fixture.workspace.performSearch()
        await waitForSearch(in: fixture.workspace)
        let coordinator = PDFKitViewer.Coordinator(state: fixture.workspace)
        coordinator.attach(to: fixture.view)
        defer { coordinator.detach() }

        for mode in [PDFDisplayMode.singlePageContinuous, .singlePage] {
            fixture.view.displayMode = mode
            fixture.view.autoScales = false
            fixture.view.scaleFactor = 1.7
            fixture.view.layoutDocumentView()
            fixture.workspace.selectSearchResult(at: 1)
            let selection = try XCTUnwrap(fixture.workspace.activeSearchSelection)
            coordinator.applySearchSelection(selection, to: fixture.view)
            await drainMainActor()

            let clip = try XCTUnwrap(fixture.view.firstDocumentScrollView()).contentView
            let point = try matchCenter(selection, in: fixture.view, clip: clip)
            XCTAssertEqual(point.y, clip.bounds.midY, accuracy: 0.75,
                           "The chosen occurrence should sit at vertical center in \(mode).")
            XCTAssertEqual(fixture.view.scaleFactor, 1.7, accuracy: 0.001)
            XCTAssertEqual(fixture.workspace.currentPageIndex, 1)
            XCTAssertTrue(fixture.view.currentSelection === selection)
        }
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testExplicitSearchClampsAtFirstAndLastDocumentEdges() async throws {
        let fixture = try await makeNavigationFixture()
        defer { fixture.detach() }
        fixture.workspace.searchText = "needle"
        fixture.workspace.performSearch()
        await waitForSearch(in: fixture.workspace)
        let coordinator = PDFKitViewer.Coordinator(state: fixture.workspace)
        coordinator.attach(to: fixture.view)
        defer { coordinator.detach() }

        for (index, atBeginning) in [(0, true), (2, false)] {
            fixture.workspace.selectSearchResult(at: index)
            let selection = try XCTUnwrap(fixture.workspace.activeSearchSelection)
            coordinator.applySearchSelection(selection, to: fixture.view)
            await drainMainActor()

            let clip = try XCTUnwrap(fixture.view.firstDocumentScrollView()).contentView
            let point = try matchCenter(selection, in: fixture.view, clip: clip)
            var edge = clip.bounds
            let useMinimum = atBeginning == clip.isFlipped
            edge.origin.y = useMinimum ? -1_000_000 : 1_000_000
            let expectedEdge = clip.constrainBoundsRect(edge).origin.y
            XCTAssertEqual(clip.bounds.minY, expectedEdge, accuracy: 0.75,
                           "Centering must stop at the document boundary, without adding blank scroll space.")
            XCTAssertTrue(clip.bounds.contains(point), "The edge occurrence must remain visible.")
            XCTAssertGreaterThan(abs(point.y - clip.bounds.midY), 20,
                                 "The fixture must exercise a real boundary clamp, not an interior match.")
        }
    }

    @MainActor
    func testLatestSearchSelectionWinsAndClearingCancelsDeferredRecentering() async throws {
        let fixture = try await makeNavigationFixture()
        defer { fixture.detach() }
        fixture.workspace.searchText = "needle"
        fixture.workspace.performSearch()
        await waitForSearch(in: fixture.workspace)
        let coordinator = PDFKitViewer.Coordinator(state: fixture.workspace)
        coordinator.attach(to: fixture.view)
        defer { coordinator.detach() }

        // Submit several native jumps before the queued layout correction runs.
        for index in [2, 0, 1] {
            fixture.workspace.selectSearchResult(at: index)
            coordinator.applySearchSelection(fixture.workspace.activeSearchSelection, to: fixture.view)
        }
        let latest = try XCTUnwrap(fixture.workspace.activeSearchSelection)
        await drainMainActor()
        let scroll = try XCTUnwrap(fixture.view.firstDocumentScrollView())
        let clip = scroll.contentView
        XCTAssertEqual(try matchCenter(latest, in: fixture.view, clip: clip).y,
                       clip.bounds.midY, accuracy: 0.75)
        XCTAssertEqual(fixture.workspace.currentPageIndex, 1)
        XCTAssertTrue(fixture.view.currentSelection === latest)

        fixture.workspace.selectSearchResult(at: 1)
        coordinator.applySearchSelection(fixture.workspace.activeSearchSelection, to: fixture.view)
        fixture.workspace.clearSearch()
        coordinator.applySearchSelection(nil, to: fixture.view)
        var moved = clip.bounds
        moved.origin.y += 65
        clip.setBoundsOrigin(clip.constrainBoundsRect(moved).origin)
        scroll.reflectScrolledClipView(clip)
        let userOrigin = clip.bounds.origin
        await drainMainActor()

        XCTAssertEqual(clip.bounds.origin.x, userOrigin.x, accuracy: 0.5)
        XCTAssertEqual(clip.bounds.origin.y, userOrigin.y, accuracy: 0.5,
                       "Cleared results must not pull the user's viewport back on the next run loop.")
        XCTAssertNil(fixture.workspace.activeSearchSelection)
        XCTAssertNil(fixture.view.currentSelection)
    }

    @MainActor
    func testSearchDecoratesVisibleMatchesAndDocumentLocationsWithoutInterceptingInput() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let document = try XCTUnwrap(fixture.workspace.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let originalSelection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))
        fixture.view.setCurrentSelection(originalSelection, animate: false)
        let originalSelectionText = originalSelection.string
        let originalSelectionBounds = originalSelection.bounds(for: page)
        let originalBytes = try Data(contentsOf: fixture.url)
        let viewport = try XCTUnwrap(fixture.view.firstDocumentScrollView()).contentView
        let originalOrigin = viewport.bounds.origin

        let overlay = try await search("needle", in: fixture)

        XCTAssertEqual(fixture.workspace.searchNavigatorResults.count, 3)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertFalse(overlay.matchRects.isEmpty)
        XCTAssertGreaterThanOrEqual(overlay.markerProgresses.count, 2)
        XCTAssertTrue(overlay.markerProgresses.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertLessThan(try XCTUnwrap(overlay.markerProgresses.first), try XCTUnwrap(overlay.markerProgresses.last))
        XCTAssertNotNil(overlay.activeMarkerProgress)
        XCTAssertTrue(overlay.markerTrack.intersects(overlay.bounds))
        try assertVisibleMatchIsOutlined(in: fixture, overlay: overlay)

        // The decoration is an ordinary child view, but native PDF controls
        // still own hit testing, focus and the user's existing text selection.
        XCTAssertNil(overlay.hitTest(CGPoint(x: overlay.frame.midX, y: overlay.frame.midY)))
        XCTAssertFalse(overlay.acceptsFirstResponder)
        XCTAssertFalse(overlay.isAccessibilityElement())
        XCTAssertTrue(overlay.isAccessibilityHidden())
        let hit = fixture.view.hitTest(CGPoint(x: fixture.view.bounds.midX, y: fixture.view.bounds.midY))
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit === overlay)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.view))
        XCTAssertTrue(fixture.window.firstResponder === fixture.view)
        XCTAssertTrue(fixture.view.currentSelection === originalSelection)
        XCTAssertEqual(originalSelection.string, originalSelectionText)
        XCTAssertEqual(originalSelection.bounds(for: page), originalSelectionBounds)
        XCTAssertEqual(viewport.bounds.origin, originalOrigin, "Publishing search markers must not scroll the document.")
        for index in 0..<document.pageCount {
            XCTAssertTrue(try XCTUnwrap(document.page(at: index)).annotations.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
    }

    @MainActor
    func testClearingSearchRemovesBothOutlinesAndMarkersWithoutLateRestoration() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let overlay = try await search("needle", in: fixture)
        XCTAssertFalse(overlay.matchRects.isEmpty)
        XCTAssertFalse(overlay.markerProgresses.isEmpty)

        fixture.workspace.clearSearch()
        fixture.view.searchScroll.refreshLayout()
        await drainMainActor()

        XCTAssertTrue(overlay.isHidden)
        XCTAssertTrue(overlay.matchRects.isEmpty)
        XCTAssertTrue(overlay.markerProgresses.isEmpty)
        XCTAssertNil(overlay.activeMarkerProgress)
        XCTAssertTrue(fixture.workspace.searchNavigatorResults.isEmpty)
    }

    @MainActor
    func testDocumentReplacementClearsOldLocationsAndBuildsOnlyNewDocumentMatches() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let overlay = try await search("needle", in: fixture)
        let oldIDs = Set(fixture.workspace.searchNavigatorResults.map(\.id))
        let oldDocument = try XCTUnwrap(fixture.workspace.document)
        let replacement = fixture.directory.appendingPathComponent("replacement.pdf")
        try writePDF(pages: ["A different opening line.\nReplacement only on this page."], to: replacement)

        XCTAssertTrue(fixture.workspace.open(url: replacement))
        fixture.view.document = fixture.workspace.document
        fixture.view.configure(with: fixture.workspace)
        fixture.view.go(to: try XCTUnwrap(fixture.workspace.document?.page(at: 0)))
        fixture.view.layoutDocumentView()
        fixture.view.layoutSubtreeIfNeeded()
        fixture.view.searchScroll.synchronize(with: fixture.workspace)
        await drainMainActor()

        XCTAssertFalse(fixture.workspace.document === oldDocument)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertTrue(overlay.matchRects.isEmpty)
        XCTAssertTrue(overlay.markerProgresses.isEmpty)
        XCTAssertNil(overlay.activeMarkerProgress)

        let replacementOverlay = try await search("replacement", in: fixture)
        XCTAssertEqual(fixture.workspace.searchNavigatorResults.count, 1)
        XCTAssertTrue(oldIDs.isDisjoint(with: fixture.workspace.searchNavigatorResults.map(\.id)))
        XCTAssertEqual(replacementOverlay.markerProgresses.count, 1)
        XCTAssertFalse(replacementOverlay.isHidden)
        try assertVisibleMatchIsOutlined(in: fixture, overlay: replacementOverlay)
        XCTAssertTrue(try XCTUnwrap(fixture.workspace.document?.page(at: 0)).annotations.isEmpty)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testDetachingRemovesDecorationAndStopsRespondingToLaterSearches() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let overlay = try await search("needle", in: fixture)
        XCTAssertTrue(overlay.superview === fixture.view)

        fixture.view.searchScroll.detach()
        fixture.workspace.searchText = "page"
        fixture.workspace.performSearch()
        await waitForSearch(in: fixture.workspace)
        await drainMainActor()

        XCTAssertFalse(fixture.workspace.searchNavigatorResults.isEmpty)
        XCTAssertNil(overlay.superview)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertTrue(overlay.matchRects.isEmpty)
        XCTAssertTrue(overlay.markerProgresses.isEmpty)
        XCTAssertFalse(fixture.view.subviews.contains { $0 is PDFSearchLocationOverlay })
    }

    @MainActor
    func testGalleryCoverAndTransparentAncestorsRejectUnderlyingPDFInput() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let container = try XCTUnwrap(fixture.view.superview)
        let point = fixture.view.convert(
            CGPoint(x: fixture.view.bounds.midX, y: fixture.view.bounds.midY), to: nil
        )
        func acceptsInput() -> Bool {
            PDFSearchScrollController.acceptsInput(at: point, in: fixture.window, owner: fixture.view)
        }
        XCTAssertTrue(acceptsInput())

        // Merely covering the PDF must be enough: an event monitor does not
        // participate in normal responder-chain or SwiftUI hit testing.
        let gallery = NSView(frame: container.bounds)
        container.addSubview(gallery, positioned: .above, relativeTo: fixture.view)
        XCTAssertFalse(acceptsInput(), "Gallery scrolling must not start a gesture in the covered PDF.")
        gallery.removeFromSuperview()
        XCTAssertTrue(acceptsInput())

        container.alphaValue = 0
        XCTAssertFalse(acceptsInput())
        container.alphaValue = 1
        container.wantsLayer = true
        container.layer?.opacity = 0
        XCTAssertFalse(acceptsInput(), "SwiftUI opacity can be represented by an ancestor layer.")
        container.layer?.opacity = 1
        container.isHidden = true
        XCTAssertFalse(acceptsInput())
        container.isHidden = false
        XCTAssertTrue(acceptsInput(), "Closing the gallery restores normal PDF input.")
    }

    @MainActor
    func testGalleryDeactivationAndHiddenAncestorsCancelPendingSearchSnap() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "The user's Reduce Motion preference intentionally disables assisted scrolling.")
        let fixture = try makeFixture()
        defer { fixture.detach() }
        fixture.view.searchScroll.detach()
        fixture.view.searchScroll = PDFSearchScrollController(owner: fixture.view, isWindowActive: { _ in true })
        fixture.view.searchScroll.synchronize(with: fixture.workspace)
        _ = try await search("needle", in: fixture)
        let coordinator = PDFKitViewer.Coordinator(state: fixture.workspace)
        coordinator.attach(to: fixture.view)
        defer { coordinator.detach() }
        let result = try XCTUnwrap(fixture.workspace.searchNavigatorResults.first { $0.pageIndex == 1 })
        fixture.workspace.selectSearchResult(id: result.id)
        let selection = try XCTUnwrap(fixture.workspace.activeSearchSelection)
        coordinator.applySearchSelection(selection, to: fixture.view)
        fixture.view.layoutDocumentView()
        fixture.view.layoutSubtreeIfNeeded()
        fixture.view.searchScroll.refreshLayout()
        let scroll = try XCTUnwrap(fixture.view.firstDocumentScrollView())
        let clip = scroll.contentView
        let container = try XCTUnwrap(fixture.view.superview)
        container.wantsLayer = true
        let page = try XCTUnwrap(fixture.workspace.document?.page(at: result.pageIndex))
        let rect = selection.bounds(for: page)
        let hit = clip.convert(fixture.view.convert(CGPoint(x: rect.midX, y: rect.midY), from: page), from: fixture.view)
        let scale = abs(fixture.view.convert(CGSize(width: 1, height: 1), from: clip).height)
        let targetOrigin = hit.y - clip.bounds.height * (clip.isFlipped ? 0.28 : 0.72)
        var completions = 0
        fixture.view.onSearchAssistedScrollEnded = { completions += 1 }

        for suppression in ["ancestor alpha", "ancestor layer", "deactivation"] {
            var nearMatch = clip.bounds
            nearMatch.origin.y = targetOrigin - 12 / scale
            clip.setBoundsOrigin(clip.constrainBoundsRect(nearMatch).origin)
            scroll.reflectScrolledClipView(clip)
            fixture.view.searchScroll.refreshLayout()
            await drainMainActor()
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            try await Task.sleep(nanoseconds: 50_000_000)
            clip.setBoundsOrigin(CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + 2 / scale))
            scroll.reflectScrolledClipView(clip)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            switch suppression {
            case "ancestor alpha": container.alphaValue = 0
            case "ancestor layer": container.layer?.opacity = 0
            default: fixture.workspace.prepareForDeactivation()
            }
            let pausedOrigin = clip.bounds.origin
            let pausedViewport = fixture.workspace.pdfViewportState(for: .normal)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(clip.bounds.origin, pausedOrigin, "A pending correction must stop after \(suppression).")
            XCTAssertEqual(completions, 0)
            if suppression == "deactivation" {
                XCTAssertEqual(fixture.workspace.pdfViewportState(for: .normal), pausedViewport)
                XCTAssertEqual(pausedViewport.scaleFactor, fixture.view.scaleFactor)
            }
            container.alphaValue = 1
            container.layer?.opacity = 1
        }
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertTrue(page.annotations.isEmpty)
    }

    @MainActor
    func testSettledSlowScrollSnapsNearbySearchMatchAndReportsItsFinalViewport() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "The user's Reduce Motion preference intentionally disables assisted scrolling.")
        let fixture = try makeFixture()
        defer { fixture.detach() }
        // XCTest has no foreground application activation lifecycle. Keep the
        // real window, PDFView, clip geometry and animation timer, and supply
        // only the focus signal that the application's window server provides.
        var hasWindowFocus = true
        fixture.view.searchScroll.detach()
        fixture.view.searchScroll = PDFSearchScrollController(
            owner: fixture.view,
            isWindowActive: { [weak window = fixture.window] candidate in
                hasWindowFocus && candidate === window
            }
        )
        fixture.view.searchScroll.synchronize(with: fixture.workspace)
        _ = try await search("needle", in: fixture)
        let coordinator = PDFKitViewer.Coordinator(state: fixture.workspace)
        coordinator.attach(to: fixture.view)
        defer { coordinator.detach() }
        let result = try XCTUnwrap(fixture.workspace.searchNavigatorResults.first { $0.pageIndex == 1 })
        fixture.workspace.selectSearchResult(id: result.id)
        let selection = try XCTUnwrap(fixture.workspace.activeSearchSelection)
        coordinator.applySearchSelection(selection, to: fixture.view)
        XCTAssertTrue(fixture.view.currentSelection === selection,
                      "PDFKit must preserve the selection identity used by the assisted-scroll guard.")
        fixture.view.layoutDocumentView()
        fixture.view.layoutSubtreeIfNeeded()
        fixture.view.searchScroll.refreshLayout()

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.view))
        await drainMainActor()

        let scroll = try XCTUnwrap(fixture.view.firstDocumentScrollView())
        let clip = scroll.contentView
        let page = try XCTUnwrap(fixture.workspace.document?.page(at: result.pageIndex))
        let rect = selection.bounds(for: page)
        func hitPoint() -> CGPoint {
            clip.convert(fixture.view.convert(CGPoint(x: rect.midX, y: rect.midY), from: page), from: fixture.view)
        }
        let scale = abs(fixture.view.convert(CGSize(width: 1, height: 1), from: clip).height)
        let anchorFraction: CGFloat = clip.isFlipped ? 0.28 : 0.72
        let targetOrigin = hitPoint().y - clip.bounds.height * anchorFraction
        var nearMatch = clip.bounds
        nearMatch.origin.y = targetOrigin - 12 / scale
        let constrained = clip.constrainBoundsRect(nearMatch).origin
        XCTAssertEqual(constrained.y, nearMatch.origin.y, accuracy: 0.5,
                       "The fixture must leave room on both sides of the reading position.")
        clip.setBoundsOrigin(constrained)
        scroll.reflectScrolledClipView(clip)
        fixture.view.searchScroll.refreshLayout()
        await drainMainActor()
        let programmaticOrigin = clip.bounds.origin
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(clip.bounds.origin, programmaticOrigin,
                       "Programmatic positioning must not start assisted scrolling without a user gesture.")

        var completedOrigin: CGPoint?
        let previousCompletion = fixture.view.onSearchAssistedScrollEnded
        fixture.view.onSearchAssistedScrollEnded = {
            previousCompletion?()
            completedOrigin = clip.bounds.origin
        }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        try await Task.sleep(nanoseconds: 50_000_000)
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + 2 / scale))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        hasWindowFocus = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        let unfocusedOrigin = clip.bounds.origin
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(clip.bounds.origin, unfocusedOrigin, "Losing window focus must cancel a pending correction.")
        XCTAssertNil(completedOrigin)

        hasWindowFocus = true
        let before = clip.bounds.origin
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        try await Task.sleep(nanoseconds: 50_000_000)
        clip.setBoundsOrigin(CGPoint(x: before.x, y: before.y + 2 / scale))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let userOrigin = clip.bounds.origin

        for _ in 0..<200 where completedOrigin == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNotNil(completedOrigin, "A slow, settled scroll within 18 screen points should finish a small correction.")
        XCTAssertEqual(clip.bounds.origin.y, targetOrigin, accuracy: 0.75 / scale)
        XCTAssertGreaterThan(abs(clip.bounds.origin.y - userOrigin.y) * scale, 1)
        XCTAssertLessThanOrEqual(abs(clip.bounds.origin.y - userOrigin.y) * scale, 18)
        XCTAssertEqual(completedOrigin, clip.bounds.origin)
        XCTAssertTrue(fixture.view.currentSelection === selection)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertTrue(page.annotations.isEmpty)
    }

    @MainActor
    private struct Fixture {
        let workspace: PDFWorkspaceState
        let view: InteractivePDFView
        let window: NSWindow
        let directory: URL
        let url: URL

        func detach() {
            view.searchScroll.detach()
            workspace.clearSearch()
            view.arrowKeyRepeater.stop()
            view.regionSelection.cancel()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    private func makeFixture(
        positionedHits: Bool = false,
        configureDocument: ((PDFDocument) -> Void)? = nil
    ) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-search-scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf")
        if positionedHits {
            try writePositionedHits(to: url)
        } else {
            try writePDF(pages: [
                "Needle at the beginning.\nBody text below on the first page.",
                "Needle on the later page.\nAnother needle farther down."
            ], to: url)
        }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        if let document = workspace.document { configureDocument?(document) }
        workspace.setMode(.viewer)
        workspace.activeTool = .select
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 620, height: 460))
        let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: view.frame)
        container.addSubview(view)
        window.contentView = container
        view.displayBox = .cropBox
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.document = workspace.document
        view.scaleFactor = 1
        view.configure(with: workspace)
        view.go(to: try XCTUnwrap(workspace.document?.page(at: 0)))
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        // The CoreText fixture is parsed lazily; makeNavigationFixture checks
        // visibility after PDFKit's first queued layout has finished.
        if !positionedHits { XCTAssertFalse(view.visiblePages.isEmpty) }
        view.searchScroll.synchronize(with: workspace)
        return Fixture(workspace: workspace, view: view, window: window, directory: directory, url: url)
    }

    @MainActor
    private func makeNavigationFixture(
        configureDocument: ((PDFDocument) -> Void)? = nil
    ) async throws -> Fixture {
        let fixture = try makeFixture(positionedHits: true, configureDocument: configureDocument)
        for _ in 0..<100 {
            if !fixture.view.visiblePages.isEmpty { return fixture }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("PDFKit did not finish laying out the positioned-hit fixture.")
        return fixture
    }

    @MainActor
    private func writePositionedHits(to url: URL) throws {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 500, height: 700)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for y in [CGFloat(650), 350, 30] {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 180, y: y)
            let text = NSAttributedString(string: "needle", attributes: [.font: NSFont.systemFont(ofSize: 18)])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        try (bytes as Data).write(to: url)
    }

    @MainActor
    private func matchCenter(_ selection: PDFSelection, in view: PDFView, clip: NSClipView) throws -> CGPoint {
        let page = try XCTUnwrap(selection.pages.first)
        let bounds = selection.bounds(for: page)
        return clip.convert(view.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page), from: view)
    }

    @MainActor
    private func writePDF(pages: [String], to url: URL) throws {
        let document = PDFDocument()
        for text in pages {
            let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
            textView.font = .systemFont(ofSize: 18)
            textView.string = text
            let rendered = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
            document.insert(try XCTUnwrap(rendered.page(at: 0)), at: document.pageCount)
        }
        XCTAssertTrue(document.write(to: url))
    }

    @MainActor
    private func search(_ query: String, in fixture: Fixture) async throws -> PDFSearchLocationOverlay {
        fixture.workspace.searchText = query
        fixture.workspace.performSearch()
        await waitForSearch(in: fixture.workspace)
        for _ in 0..<100 {
            fixture.view.searchScroll.refreshLayout()
            if let overlay = fixture.view.subviews.compactMap({ $0 as? PDFSearchLocationOverlay }).first,
               !overlay.matchRects.isEmpty, !overlay.markerProgresses.isEmpty {
                return overlay
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Completed search did not produce visible match outlines and location markers.")
        return try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? PDFSearchLocationOverlay }.first)
    }

    @MainActor
    private func waitForSearch(in workspace: PDFWorkspaceState) async {
        for _ in 0..<200 where workspace.isSearching {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(workspace.isSearching, "Synthetic PDF search should finish within one second.")
    }

    @MainActor
    private func drainMainActor() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    @MainActor
    private func assertVisibleMatchIsOutlined(
        in fixture: Fixture, overlay: PDFSearchLocationOverlay,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let document = try XCTUnwrap(fixture.workspace.document, file: file, line: line)
        let result = try XCTUnwrap(fixture.workspace.searchNavigatorResults.first, file: file, line: line)
        let page = try XCTUnwrap(document.page(at: result.pageIndex), file: file, line: line)
        XCTAssertTrue(fixture.view.visiblePages.contains { $0 === page }, file: file, line: line)
        let selection = try XCTUnwrap(page.selection(for: result.sourceRange), file: file, line: line)
        let bounds = selection.bounds(for: page)
        let point = overlay.convert(
            fixture.view.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page),
            from: fixture.view
        )
        XCTAssertTrue(overlay.contentClip.contains(point), file: file, line: line)
        XCTAssertTrue(overlay.matchRects.contains { $0.contains(point) }, file: file, line: line)
    }
}
