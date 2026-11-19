// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFComparisonScrollSyncTests: XCTestCase {
    func testRelativeDeltaUsesPageSizeAndCoordinateOrientation() {
        let delta = PDFComparisonScrollDelta(
            originChange: CGPoint(x: 100, y: 80),
            pageSize: CGSize(width: 1_000, height: 800), isFlipped: true
        )
        XCTAssertEqual(delta.horizontal, 0.1, accuracy: 0.0001)
        XCTAssertEqual(delta.vertical, 0.1, accuracy: 0.0001)
        XCTAssertEqual(
            delta.applying(to: CGPoint(x: 75, y: 2_000),
                           pageSize: CGSize(width: 600, height: 1_200), isFlipped: false),
            CGPoint(x: 135, y: 1_880)
        )
        let invalid = PDFComparisonScrollDelta(
            originChange: CGPoint(x: CGFloat.infinity, y: CGFloat.nan),
            pageSize: .zero, isFlipped: false
        )
        XCTAssertEqual(invalid.horizontal, 0)
        XCTAssertEqual(invalid.vertical, 0)
    }

    @MainActor
    func testPanPreservesStartingPagesAcrossUnequalDocumentLengthsAndSizes() throws {
        let source = try Fixture(pages: 20, start: 2, pageSize: CGSize(width: 1_000, height: 800))
        let target = try Fixture(pages: 60, start: 19, pageSize: CGSize(width: 800, height: 1_200))
        let coordinator = PDFScrollSyncCoordinator()
        coordinator.register(pdfView: source.view, id: source.id)
        coordinator.register(pdfView: target.view, id: target.id)
        let beforeSource = source.origin
        let beforeTarget = target.origin
        source.pan(x: 50, y: 80)
        XCTAssertEqual(source.origin.x, beforeSource.x + 50, accuracy: 0.5, "No feedback should move the driver twice.")
        XCTAssertEqual(source.origin.y, beforeSource.y + 80, accuracy: 0.5)
        XCTAssertEqual(target.origin.x, beforeTarget.x + 40, accuracy: 0.5)
        XCTAssertEqual(target.origin.y, beforeTarget.y + 120, accuracy: 0.5)
        XCTAssertGreaterThan(target.pageIndex, 15, "An initial pan must not align whole-document progress.")
    }

    @MainActor
    func testPanAtDifferentZoomFactorsUsesDocumentCoordinates() throws {
        let source = try Fixture(pages: 20, start: 2, pageSize: CGSize(width: 1_000, height: 800))
        let target = try Fixture(pages: 60, start: 19, pageSize: CGSize(width: 800, height: 1_200))
        source.view.scaleFactor = 0.5
        target.view.scaleFactor = 1.3
        let coordinator = PDFScrollSyncCoordinator()
        coordinator.register(pdfView: source.view, id: source.id)
        coordinator.register(pdfView: target.view, id: target.id)
        let before = target.origin
        source.pan(x: 50, y: 80)
        XCTAssertEqual(target.origin.x, before.x + 40, accuracy: 0.5)
        XCTAssertEqual(target.origin.y, before.y + 120, accuracy: 0.5)
    }

    @MainActor
    func testSwiftUIRefreshBeforeDeferredBoundsNotificationDoesNotConsumeScroll() throws {
        let source = try Fixture(pages: 20, start: 2)
        let target = try Fixture(pages: 30, start: 12)
        let sync = PDFScrollSyncCoordinator()
        sync.register(pdfView: source.view, id: source.id)
        sync.register(pdfView: target.view, id: target.id)
        let before = target.origin
        source.clip.postsBoundsChangedNotifications = false
        source.clip.setBoundsOrigin(CGPoint(x: source.origin.x, y: source.origin.y + 80))
        // The page observer can cause a no-op SwiftUI refresh before PDFKit
        // delivers its scroll notification. Registration and state application
        // must not silently use the new reading position as the old baseline.
        sync.beginProgrammaticUpdate(id: source.id)
        sync.updateRegistration(pdfView: source.view, id: source.id, locked: false)
        sync.endProgrammaticUpdate(id: source.id)
        sync.receiveLiveScroll(pdfView: source.view, id: source.id, locked: false)
        XCTAssertEqual(target.origin.y, before.y + 80, accuracy: 0.5)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: source.clip)
        XCTAssertEqual(target.origin.y, before.y + 80, accuracy: 0.5, "A late bounds event must not apply the delta twice.")
    }

    @MainActor
    func testInteractivePDFNativeLiveScrollAfterFitWorksWithoutBoundsNotifications() async throws {
        let source = try ComparisonFixture(pages: 12, start: 3)
        let target = try ComparisonFixture(pages: 20, start: 9)
        let sync = PDFScrollSyncCoordinator()
        source.coordinator.updateScrollSyncRegistration(coordinator: sync, id: source.id, locked: false)
        target.coordinator.updateScrollSyncRegistration(coordinator: sync, id: target.id, locked: false)
        source.view.setFrameSize(CGSize(width: 1_420, height: 300))
        target.view.setFrameSize(CGSize(width: 620, height: 580))
        await settleLayout()
        let sourceScroll = try XCTUnwrap(source.view.firstDocumentScrollView())
        let targetClip = try XCTUnwrap(target.view.firstDocumentScrollView()?.contentView)
        let before = targetClip.bounds.origin
        let sourceClip = sourceScroll.contentView
        sourceClip.postsBoundsChangedNotifications = false
        sourceClip.setBoundsOrigin(CGPoint(x: sourceClip.bounds.origin.x, y: sourceClip.bounds.origin.y + 80))
        // This is the notification the actual NSScrollView sends during a
        // trackpad/mouse-wheel gesture; no synthetic bounds event is posted.
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: sourceScroll)
        XCTAssertEqual(targetClip.bounds.origin.y, before.y + 80, accuracy: 0.5)
        source.coordinator.detach()
        target.coordinator.detach()
    }

    @MainActor
    func testNativeSubpixelViewportNoiseDoesNotDropScrollDelta() throws {
        let source = try Fixture(pages: 20, start: 2)
        let target = try Fixture(pages: 30, start: 12)
        let sync = PDFScrollSyncCoordinator()
        sync.register(pdfView: source.view, id: source.id)
        sync.register(pdfView: target.view, id: target.id)
        let before = target.origin
        source.clip.postsBoundsChangedNotifications = false
        var bounds = source.clip.bounds
        bounds.origin.y += 80
        // Observed with a real fitted pane: 1483.234532373076 becomes
        // 1483.2345323744894 during an ordinary wheel event.
        bounds.size.height += 0.0000000014
        source.clip.bounds = bounds
        sync.receiveLiveScroll(pdfView: source.view, id: source.id, locked: false)
        XCTAssertEqual(target.origin.y, before.y + 80, accuracy: 0.5)
    }

    @MainActor
    func testNativeZoomAndItsLaterRecenteringDoNotPanOtherPDFs() async throws {
        let source = try Fixture(pages: 20, start: 2)
        let target = try Fixture(pages: 30, start: 12)
        let sync = PDFScrollSyncCoordinator()
        sync.register(pdfView: source.view, id: source.id)
        sync.register(pdfView: target.view, id: target.id)
        let before = target.origin
        source.view.scaleFactor = 0.7
        // PDFKit's second bounds event has the new scale already, but is
        // still part of the same zoom/recentering operation.
        source.pan(x: 30, y: 100)
        XCTAssertEqual(target.origin, before)
        await settleLayout()
        source.pan(y: 40)
        XCTAssertEqual(target.origin.y, before.y + 40, accuracy: 0.5)
    }

    @MainActor
    func testSynchronizedPanePublishesVisiblePageAndNextUsesThatPage() async throws {
        let source = try ComparisonFixture(pages: 12, start: 3)
        let target = try ComparisonFixture(pages: 20, start: 9)
        let sync = PDFScrollSyncCoordinator()
        source.coordinator.updateScrollSyncRegistration(coordinator: sync, id: source.id, locked: false)
        target.coordinator.updateScrollSyncRegistration(coordinator: sync, id: target.id, locked: false)
        await settleLayout()
        let sourceClip = try XCTUnwrap(source.view.firstDocumentScrollView()?.contentView)
        sourceClip.setBoundsOrigin(CGPoint(x: sourceClip.bounds.origin.x, y: sourceClip.bounds.origin.y - 1_604))
        sync.receiveLiveScroll(pdfView: source.view, id: source.id, locked: false)
        let targetPage = try XCTUnwrap(target.view.page(
            for: CGPoint(x: target.view.bounds.midX, y: target.view.bounds.midY), nearest: true
        ))
        let targetIndex = try XCTUnwrap(target.state.document?.index(for: targetPage))
        XCTAssertGreaterThan(targetIndex, 9)
        XCTAssertEqual(target.state.currentPageIndex, targetIndex)
        XCTAssertFalse(target.coordinator.requiresNavigation(to: targetPage, at: targetIndex, in: target.view),
                       "A header update must not snap the target back to its native cached page.")
        let sourceIndex = source.state.currentPageIndex
        XCTAssertTrue(sync.stepPages(by: 1, sourceID: target.id))
        XCTAssertEqual(target.state.currentPageIndex, targetIndex + 1)
        XCTAssertEqual(source.state.currentPageIndex, sourceIndex + 1)
        source.coordinator.detach()
        target.coordinator.detach()
    }

    @MainActor
    func testFixedComparisonAlsoRejectsNativeContextMenuZoomActions() async throws {
        let fixture = try ComparisonFixture(pages: 12, start: 3)
        await settleLayout()
        fixture.view.comparisonContentFixed = true
        let before = fixture.view.scaleFactor
        fixture.view.zoomIn(nil)
        XCTAssertEqual(fixture.view.scaleFactor, before)
        fixture.view.zoomOut(nil)
        XCTAssertEqual(fixture.view.scaleFactor, before)
        fixture.view.scaleFactor = before * 2
        XCTAssertEqual(fixture.view.scaleFactor, before)
        XCTAssertEqual(fixture.state.currentPageIndex, 3)
    }

    @MainActor
    func testSyncToggleAndFixedPaneDoNotSnapOtherPositions() throws {
        let source = try Fixture(pages: 20, start: 2)
        let target = try Fixture(pages: 30, start: 12)
        let coordinator = PDFScrollSyncCoordinator(enabled: false)
        coordinator.register(pdfView: source.view, id: source.id)
        coordinator.register(pdfView: target.view, id: target.id, locked: true)
        let targetStart = target.origin
        source.pan(y: 30)
        XCTAssertEqual(target.origin, targetStart)
        coordinator.enabled = true
        XCTAssertEqual(target.origin, targetStart)
        source.pan(y: 30)
        XCTAssertEqual(target.origin, targetStart)
        let sourceBeforeFixedPan = source.origin
        target.pan(y: 40)
        XCTAssertEqual(target.origin, targetStart, "A fixed panel also rejects direct native scrolling.")
        XCTAssertEqual(source.origin, sourceBeforeFixedPan)
        XCTAssertFalse(coordinator.stepPages(by: 1, sourceID: target.id))
        XCTAssertFalse(coordinator.goToPage(index: 18, sourceID: target.id))
        coordinator.updateRegistration(pdfView: target.view, id: target.id, locked: false)
        source.pan(y: 30)
        XCTAssertEqual(target.origin.y, targetStart.y + 30, accuracy: 0.5)
    }

    @MainActor
    func testProgrammaticRestoreAndGeometryReflowDoNotDriveSynchronization() throws {
        let source = try Fixture(pages: 20, start: 2)
        let target = try Fixture(pages: 30, start: 12)
        let coordinator = PDFScrollSyncCoordinator()
        coordinator.register(pdfView: source.view, id: source.id)
        coordinator.register(pdfView: target.view, id: target.id)
        let targetStart = target.origin
        coordinator.beginProgrammaticUpdate(id: source.id)
        coordinator.beginProgrammaticUpdate(id: source.id)
        source.pan(y: 120)
        coordinator.endProgrammaticUpdate(id: source.id)
        source.pan(y: 60)
        XCTAssertEqual(target.origin, targetStart)
        coordinator.endProgrammaticUpdate(id: source.id)
        source.pan(y: 30)
        XCTAssertEqual(target.origin.y, targetStart.y + 30, accuracy: 0.5)
        let beforeResize = target.origin
        source.view.frame.size.width += 80
        source.view.layoutDocumentView()
        source.view.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: source.clip)
        XCTAssertEqual(target.origin, beforeResize)
    }

    @MainActor
    func testExplicitPageNavigationPreservesPageOffsetsAndClampsIndividually() throws {
        let source = try Fixture(pages: 12, start: 2)
        let target = try Fixture(pages: 10, start: 7)
        let fixed = try Fixture(pages: 20, start: 4)
        let coordinator = PDFScrollSyncCoordinator()
        for fixture in [source, target] {
            coordinator.register(pdfView: fixture.view, id: fixture.id)
        }
        coordinator.register(pdfView: fixed.view, id: fixed.id, locked: true)
        XCTAssertTrue(coordinator.stepPages(by: 1, sourceID: source.id))
        XCTAssertEqual(source.pageIndex, 3)
        XCTAssertEqual(target.pageIndex, 8)
        XCTAssertEqual(fixed.pageIndex, 4)
        XCTAssertTrue(coordinator.goToPage(index: 7, sourceID: source.id))
        XCTAssertEqual(source.pageIndex, 7)
        XCTAssertEqual(target.pageIndex, 9)
        XCTAssertEqual(fixed.pageIndex, 4)
        XCTAssertTrue(coordinator.stepPages(by: -1))
        XCTAssertEqual(source.pageIndex, 6)
        XCTAssertEqual(target.pageIndex, 8)
        XCTAssertEqual(fixed.pageIndex, 4)
    }

    @MainActor
    func testExplicitGroupPagingWorksWithAutomaticSyncOff() throws {
        let source = try Fixture(pages: 12, start: 2)
        let target = try Fixture(pages: 10, start: 7)
        let coordinator = PDFScrollSyncCoordinator(enabled: false)
        coordinator.register(pdfView: source.view, id: source.id)
        coordinator.register(pdfView: target.view, id: target.id)
        XCTAssertTrue(coordinator.stepPages(by: 1, sourceID: source.id))
        XCTAssertEqual(source.pageIndex, 3)
        XCTAssertEqual(target.pageIndex, 7)
        XCTAssertTrue(coordinator.stepPages(by: 1))
        XCTAssertEqual(source.pageIndex, 4)
        XCTAssertEqual(target.pageIndex, 8)
        XCTAssertTrue(coordinator.stepPages(by: Int.max))
        XCTAssertEqual(source.pageIndex, 11)
        XCTAssertEqual(target.pageIndex, 9)
        XCTAssertFalse(coordinator.stepPages(by: 1))
        XCTAssertTrue(coordinator.stepPages(by: Int.min))
        XCTAssertEqual(source.pageIndex, 0)
        XCTAssertEqual(target.pageIndex, 0)
    }

    @MainActor
    func testReplacementRegistrationSurvivesOldViewTeardown() throws {
        let old = try Fixture(pages: 20, start: 2)
        let replacement = try Fixture(pages: 30, start: 12)
        let target = try Fixture(pages: 10, start: 4)
        let coordinator = PDFScrollSyncCoordinator()
        coordinator.register(pdfView: old.view, id: old.id)
        coordinator.register(pdfView: target.view, id: target.id)
        coordinator.register(pdfView: replacement.view, id: old.id)
        coordinator.unregister(id: old.id, pdfView: old.view)
        let before = target.origin
        old.pan(y: 30)
        XCTAssertEqual(target.origin, before)
        replacement.pan(y: 40)
        XCTAssertEqual(target.origin.y, before.y + 40, accuracy: 0.5)
        coordinator.unregister(id: old.id, pdfView: replacement.view)
        replacement.pan(y: 30)
        XCTAssertEqual(target.origin.y, before.y + 40, accuracy: 0.5)
    }

    @MainActor
    func testFixedComparisonConsumesNavigationButPreservesCopyAndSelection() throws {
        let view = InteractivePDFView(frame: .zero)
        view.viewportContext = .comparison
        view.comparisonContentFixed = true
        let pageDown = try key(code: 121, text: "", modifiers: [])
        let copy = try key(code: 8, text: "c", modifiers: .command)
        let selectAll = try key(code: 0, text: "a", modifiers: .command)
        let zoom = try key(code: 24, text: "+", modifiers: .command)
        XCTAssertTrue(view.suppressesFixedComparisonNavigation(pageDown))
        XCTAssertTrue(view.suppressesFixedComparisonNavigation(zoom))
        XCTAssertFalse(view.suppressesFixedComparisonNavigation(copy))
        XCTAssertFalse(view.suppressesFixedComparisonNavigation(selectAll))
        view.comparisonContentFixed = false
        XCTAssertFalse(view.suppressesFixedComparisonNavigation(pageDown))
        view.comparisonContentFixed = true
        view.viewportContext = .normal
        XCTAssertFalse(view.suppressesFixedComparisonNavigation(pageDown))
    }

    @MainActor
    func testStackedComparisonFitsWholePageAndKeepsPageAcrossMixedLayoutReflow() async throws {
        let source = try ComparisonFixture(pages: 12, start: 3)
        let target = try ComparisonFixture(pages: 20, start: 9)
        let sync = PDFScrollSyncCoordinator()
        sync.register(pdfView: source.view, id: source.id)
        sync.register(pdfView: target.view, id: target.id)
        source.view.setFrameSize(CGSize(width: 1_420, height: 300))
        target.view.setFrameSize(CGSize(width: 1_420, height: 300))
        await settleLayout()
        XCTAssertEqual(source.state.currentPageIndex, 3)
        XCTAssertEqual(target.state.currentPageIndex, 9)
        XCTAssertEqual(source.view.currentPage.map { source.state.document?.index(for: $0) }, 3)
        XCTAssertEqual(target.view.currentPage.map { target.state.document?.index(for: $0) }, 9)
        XCTAssertLessThan(source.view.scaleFactor, 0.4, "A shallow pane must fit height as well as width.")
        XCTAssertTrue(source.state.pdfViewportState(for: .comparison).autoScales)
        let targetClip = try XCTUnwrap(target.view.firstDocumentScrollView()?.contentView)
        let targetOrigin = targetClip.bounds.origin
        let targetScale = target.view.scaleFactor
        source.view.setFrameSize(CGSize(width: 780, height: 260))
        await settleLayout()
        XCTAssertEqual(targetClip.bounds.origin, targetOrigin,
                       "A-only reflow must not become a synchronized user pan in B.")
        XCTAssertEqual(target.view.scaleFactor, targetScale)
        XCTAssertEqual(target.state.currentPageIndex, 9)
        source.view.setFrameSize(CGSize(width: 680, height: 240))
        target.view.setFrameSize(CGSize(width: 320, height: 560))
        await settleLayout()
        XCTAssertEqual(source.state.currentPageIndex, 3)
        XCTAssertEqual(target.state.currentPageIndex, 9)
        XCTAssertEqual(source.view.currentPage.map { source.state.document?.index(for: $0) }, 3)
        XCTAssertEqual(target.view.currentPage.map { target.state.document?.index(for: $0) }, 9)
        XCTAssertFalse(source.state.isDirty)
        XCTAssertFalse(target.state.isDirty)
    }

    @MainActor
    func testComparisonManualZoomSurvivesPaneResizeAndDoesNotPolluteNormalViewport() async throws {
        let fixture = try ComparisonFixture(pages: 12, start: 3)
        await settleLayout()
        let normalViewport = fixture.state.pdfViewportState
        fixture.view.endPageFitForManualZoom()
        fixture.view.scaleFactor = 1.3
        fixture.view.go(to: try XCTUnwrap(fixture.state.document?.page(at: 3)))
        fixture.view.setFrameSize(CGSize(width: 600, height: 280))
        await settleLayout()
        XCTAssertEqual(fixture.view.scaleFactor, 1.3, accuracy: 0.0001)
        XCTAssertEqual(fixture.state.currentPageIndex, 3)
        XCTAssertFalse(fixture.state.pdfViewportState(for: .comparison).autoScales)
        XCTAssertEqual(fixture.state.pdfViewportState, normalViewport)
    }

    @MainActor
    private func settleLayout() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private final class ComparisonFixture {
        let id = UUID()
        let state = PDFWorkspaceState()
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 680, height: 600))
        let coordinator: PDFKitViewer.Coordinator
        let url: URL

        init(pages: Int, start: Int) throws {
            let document = PDFDocument()
            for _ in 0..<pages {
                let page = PDFPage()
                page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
                document.insert(page, at: document.pageCount)
            }
            url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            XCTAssertTrue(document.write(to: url))
            XCTAssertTrue(state.open(url: url))
            state.setCurrentPage(start)
            coordinator = PDFKitViewer.Coordinator(state: state, viewportContext: .comparison)
            view.viewportContext = .comparison
            view.autoScales = false
            view.configure(with: state)
            coordinator.attach(to: view)
            coordinator.isApplyingState = true
            view.document = state.document
            view.displayMode = .singlePageContinuous
            view.pendingComparisonPageIndex = start
            view.updatePageFitMode(revealCurrentPage: true)
            view.applyComparisonPageFit()
            coordinator.isApplyingState = false
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func key(code: UInt16, text: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code
        ))
    }

    @MainActor
    private final class Fixture {
        let id = UUID()
        let view: PDFView
        let document: PDFDocument
        let clip: NSClipView
        var origin: CGPoint { clip.bounds.origin }
        var pageIndex: Int { view.currentPage.map { document.index(for: $0) } ?? NSNotFound }

        init(pages: Int, start: Int, pageSize: CGSize = CGSize(width: 1_000, height: 800)) throws {
            document = PDFDocument()
            for _ in 0..<pages {
                let page = PDFPage()
                page.setBounds(CGRect(origin: .zero, size: pageSize), for: .mediaBox)
                document.insert(page, at: document.pageCount)
            }
            view = PDFView(frame: CGRect(x: 0, y: 0, width: 350, height: 400))
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
            view.document = document
            view.autoScales = false
            view.scaleFactor = 1
            view.layoutDocumentView()
            view.layoutSubtreeIfNeeded()
            view.go(to: try XCTUnwrap(document.page(at: start)))
            view.layoutSubtreeIfNeeded()
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            clip = try XCTUnwrap(scrollView(in: view)?.contentView)
            let proposed = CGPoint(x: clip.bounds.origin.x + 100, y: clip.bounds.origin.y + 100)
            clip.setBoundsOrigin(clip.constrainBoundsRect(CGRect(origin: proposed, size: clip.bounds.size)).origin)
            XCTAssertEqual(pageIndex, start)
        }

        func pan(x: CGFloat = 0, y: CGFloat = 0) {
            let next = CGPoint(x: origin.x + x, y: origin.y + y)
            clip.setBoundsOrigin(clip.constrainBoundsRect(CGRect(origin: next, size: clip.bounds.size)).origin)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
}
