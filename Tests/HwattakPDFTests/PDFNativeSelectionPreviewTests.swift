// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFNativeSelectionPreviewTests: XCTestCase {
    func testNativeSelectionNotificationsStayLiveWithoutWorkspacePublicationsUntilCommit() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        var publications = 0
        let observer = fixture.state.objectWillChange.sink { publications += 1 }
        defer { observer.cancel() }

        fixture.view.beginNativeSelectionPreview()
        for length in 1...20 {
            try fixture.select(length: length)
            XCTAssertTrue(fixture.state.currentSelection === fixture.view.currentSelection)
        }
        XCTAssertEqual(publications, 0)
        fixture.view.finishNativeSelectionPreview()
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(fixture.state.currentSelection === fixture.view.currentSelection)
        fixture.view.finishNativeSelectionPreview()
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(fixture.state.isDirty)
    }

    func testSearchAndExplicitNilTakeOverPendingNativeGesture() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        fixture.view.beginNativeSelectionPreview()
        try fixture.select(length: 6)
        let search = try XCTUnwrap(fixture.page.selection(for: NSRange(location: 12, length: 4)))
        fixture.state.activeSearchSelection = search
        fixture.coordinator.applySearchSelection(search, to: fixture.view)
        try fixture.select(length: 9) // Late selection notification from the old gesture.
        fixture.view.finishNativeSelectionPreview()
        XCTAssertTrue(fixture.state.currentSelection === search)

        fixture.view.beginNativeSelectionPreview()
        try fixture.select(length: 6)
        fixture.state.currentSelection = nil
        try fixture.select(length: 9)
        fixture.view.finishNativeSelectionPreview()
        XCTAssertNil(fixture.state.currentSelection)

        // The suppression ends with the old gesture. Keyboard/native selection
        // outside a drag continues to publish through the ordinary bridge.
        try fixture.select(length: 12)
        XCTAssertTrue(fixture.state.currentSelection === fixture.view.currentSelection)
    }

    func testToolChangeAndViewDocumentReplacementRejectStaleNativeSelections() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        fixture.state.setMode(.editing)
        fixture.view.configure(with: fixture.state)
        fixture.view.beginNativeSelectionPreview()
        try fixture.select(length: 6)
        fixture.state.activeTool = .pen
        fixture.view.configure(with: fixture.state)
        try fixture.select(length: 9)
        fixture.view.finishNativeSelectionPreview()
        XCTAssertNil(fixture.state.currentSelection)

        fixture.state.activeTool = .select
        fixture.view.configure(with: fixture.state)
        fixture.view.beginNativeSelectionPreview()
        try fixture.select(length: 6)
        fixture.view.document = try XCTUnwrap(PDFDocument(data: PDFMalformedSelectionTestFixture.data()))
        XCTAssertTrue(fixture.view.consumeNativeSelectionChange())
        fixture.view.finishNativeSelectionPreview()
        XCTAssertNil(fixture.state.currentSelection)
    }

    func testDelayedMouseUpDoesNotCommitANewerNativeGesture() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        fixture.view.beginNativeSelectionPreview()
        try fixture.select(length: 6)
        fixture.view.scheduleNativeSelectionCommit()
        fixture.view.beginNativeSelectionPreview()
        var publications = 0
        let observer = fixture.state.objectWillChange.sink { publications += 1 }
        defer { observer.cancel() }
        try fixture.select(length: 12)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(publications, 0)
        fixture.view.finishNativeSelectionPreview()
        XCTAssertEqual(publications, 1)
    }

    func testHealthyPDFNativeMouseSequenceSelectsTextAndCommitsOnce() async throws {
        try await exerciseNativeMouseSequence(viewportContext: .normal)
    }

    func testComparisonNativeMouseSequenceSelectsWhileSharedWorkspaceUsesPen() async throws {
        try await exerciseNativeMouseSequence(viewportContext: .comparison)
    }

    private func exerciseNativeMouseSequence(viewportContext: PDFViewerViewportContext) async throws {
        let fixture = try makeFixture(viewportContext: viewportContext)
        let view = fixture.view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer {
            fixture.detach()
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        if viewportContext == .comparison {
            fixture.state.setMode(.editing)
            fixture.state.activeTool = .pen
            view.configure(with: fixture.state)
            XCTAssertEqual(view.activeTool, .select)
        }
        view.autoScales = false
        view.scaleFactor = 1
        view.displayMode = .singlePage
        view.go(to: fixture.page)
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(view)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(PDFTextSelectionGeometry.needsRegionSelection(on: fixture.page))
        let originalRevision = fixture.state.revision
        let anchor = CGPoint(x: 94.1, y: 405)
        let endpoint = CGPoint(x: 192.9, y: 375)
        XCTAssertTrue(view.page(for: view.convert(anchor, from: fixture.page), nearest: false) === fixture.page)
        let expected = try XCTUnwrap(fixture.page.selection(from: anchor, to: endpoint)?.string)
        func event(_ type: NSEvent.EventType, _ point: CGPoint, number: Int) throws -> NSEvent {
            let viewPoint = view.convert(point, from: fixture.page)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: view.convert(viewPoint, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + Double(number - 80_100) * 0.01,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try event(.leftMouseDown, anchor, number: 80_100)
        let drag = try event(.leftMouseDragged, CGPoint(x: 175, y: 405), number: 80_101)
        let lastDrag = try event(.leftMouseDragged, endpoint, number: 80_102)
        let up = try event(.leftMouseUp, endpoint, number: 80_103)
        var publications = 0
        let selectionChanges = SelectionChangeCounter()
        let publisher = fixture.state.objectWillChange.sink { publications += 1 }
        let selectionObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged, object: view, queue: .main
        ) { _ in MainActor.assumeIsolated { selectionChanges.value += 1 } }
        defer {
            publisher.cancel()
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        // PDFKit versions differ in whether mouseDown runs a tracking loop.
        // Queue the rest of the actual mouse sequence before entering native
        // code so both implementations can receive their matching mouse-up.
        for queued in [drag, lastDrag, up] { NSApp.postEvent(queued, atStart: false) }
        view.mouseDown(with: down)
        for _ in 0..<3 {
            guard let queued = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) else { break }
            if queued.type == .leftMouseUp { view.mouseUp(with: queued) }
            else { view.mouseDragged(with: queued) }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertGreaterThan(selectionChanges.value, 0)
        XCTAssertEqual(view.currentSelection?.string, expected)
        XCTAssertTrue(fixture.state.currentSelection === view.currentSelection)
        XCTAssertFalse(view.regionSelection.isActive)
        XCTAssertFalse(view.consumeNativeSelectionChange(), "Mouse-up must end the preview lease.")
        XCTAssertLessThanOrEqual(publications, 2, "Native changing-character selection must publish once at commit.")
        XCTAssertEqual(fixture.state.revision, originalRevision)
        XCTAssertFalse(fixture.state.isDirty)
    }

    @MainActor
    private final class SelectionChangeCounter {
        var value = 0
    }

    @MainActor
    private struct Fixture {
        let state: PDFWorkspaceState
        let view: InteractivePDFView
        let coordinator: PDFKitViewer.Coordinator
        let page: PDFPage
        let directory: URL

        func select(length: Int) throws {
            let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: length)))
            view.setCurrentSelection(selection, animate: false)
            NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        }

        func detach() {
            view.finishNativeSelectionPreview()
            coordinator.detach()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(viewportContext: PDFViewerViewportContext = .normal) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("native-selection.pdf")
        try PDFMalformedSelectionTestFixture.data().write(to: url)
        let state = PDFWorkspaceState()
        XCTAssertTrue(state.open(url: url))
        state.setMode(.viewer)
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        view.viewportContext = viewportContext
        view.document = state.document
        view.configure(with: state)
        let coordinator = PDFKitViewer.Coordinator(state: state, viewportContext: viewportContext)
        coordinator.attach(to: view)
        return Fixture(state: state, view: view, coordinator: coordinator,
                       page: try XCTUnwrap(state.document?.page(at: 0)), directory: directory)
    }
}
