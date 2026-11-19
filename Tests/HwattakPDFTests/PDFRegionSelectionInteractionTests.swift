// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import CoreGraphics
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFRegionSelectionInteractionTests: XCTestCase {
    @MainActor
    func testStudyScanOrdinaryDragStartsLocalRegionRecognitionAndCanCancelWithoutEditing() throws {
        let fixture = try makeFixture(imageOnly: true)
        defer { fixture.detach() }
        fixture.workspace.setMode(.study)
        fixture.view.configure(with: fixture.workspace)
        XCTAssertEqual(fixture.page.numberOfCharacters, 0)
        let revision = fixture.workspace.revision

        fixture.view.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 60, y: 380), fixture: fixture))
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: 300, y: 300), fixture: fixture))
        fixture.view.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: 300, y: 300), fixture: fixture))
        XCTAssertTrue(fixture.view.regionSelection.isActive)
        XCTAssertFalse(fixture.view.regionSelection.isDragging)
        XCTAssertEqual(fixture.workspace.statusMessage, L10n.string("selection.region_recognizing"))
        // Cancel before yielding to Vision: ordinary dragging now enters the
        // existing local recognition path, without rewriting or OCR-applying.
        fixture.view.regionSelection.cancel()
        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertEqual(fixture.workspace.revision, revision)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
    }

    @MainActor
    func testMalformedPageOrdinaryDragSelectsPartialLinesImmediatelyAndSurvivesSynchronization() throws {
        for rotation in [0, 90, 180, 270] {
            let fixture = try makeFixture(malformedMetrics: true, rotation: rotation)
            defer { fixture.detach() }
            _ = try XCTUnwrap(PDFTextSelectionGeometry.needsRegionSelection(on: fixture.page) ? true : nil)
            let originalText = fixture.page.string
            let revision = fixture.workspace.revision
            let anchor = CGPoint(x: 94.1, y: 405)
            let endpoint = CGPoint(x: 192.9, y: 375)

            fixture.view.mouseDown(with: try event(.leftMouseDown, point: anchor, fixture: fixture))
            fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: endpoint, fixture: fixture))

            let duringDrag = try XCTUnwrap(fixture.workspace.currentSelection)
            XCTAssertEqual(duringDrag.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           "bravo charlie delta.\nEcho foxtrot golf")
            XCTAssertTrue(fixture.view.regionSelection.isDragging)
            XCTAssertTrue(duringDrag.pages.first === fixture.page)
            XCTAssertNil(fixture.view.currentSelection)
            XCTAssertEqual(duringDrag.selectionsByLine().count, 2)
            for line in duringDrag.selectionsByLine() {
                XCTAssertLessThan(line.bounds(for: fixture.page).height, 30)
            }

            fixture.view.configure(with: fixture.workspace)
            fixture.view.regionSelection.synchronize()
            XCTAssertTrue(fixture.view.regionSelection.isDragging)
            XCTAssertTrue(fixture.workspace.currentSelection === duringDrag)
            fixture.view.mouseUp(with: try event(.leftMouseUp, point: endpoint, fixture: fixture))
            fixture.view.regionSelection.synchronize()

            XCTAssertTrue(fixture.view.regionSelection.isActive)
            XCTAssertFalse(fixture.view.regionSelection.isDragging)
            XCTAssertEqual(fixture.workspace.currentSelection?.string, duringDrag.string)
            XCTAssertEqual(fixture.page.string, originalText)
            XCTAssertEqual(fixture.workspace.revision, revision)
            XCTAssertFalse(fixture.workspace.isDirty)
            XCTAssertFalse(fixture.workspace.canUndo)

            // A fresh reverse drag selects exactly the same text range.
            fixture.view.mouseDown(with: try event(.leftMouseDown, point: endpoint, fixture: fixture))
            fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: anchor, fixture: fixture))
            fixture.view.mouseUp(with: try event(.leftMouseUp, point: anchor, fixture: fixture))
            XCTAssertEqual(fixture.workspace.currentSelection?.string, duringDrag.string)

            fixture.view.mouseDown(with: try event(.leftMouseDown, point: anchor, fixture: fixture))
            fixture.view.mouseUp(with: try event(.leftMouseUp, point: anchor, fixture: fixture))
            XCTAssertNil(fixture.workspace.currentSelection)
            XCTAssertFalse(fixture.view.regionSelection.isActive)
        }
    }

    @MainActor
    func testMalformedPageDoubleClickSelectsWholeWordAndDragExtendsByWords() throws {
        let fixture = try makeFixture(malformedMetrics: true)
        defer { fixture.detach() }
        _ = try XCTUnwrap(PDFTextSelectionGeometry.needsRegionSelection(on: fixture.page) ? true : nil)
        let anchor = CGPoint(x: 100, y: 405)
        let endpoint = CGPoint(x: 175, y: 375)

        fixture.view.mouseDown(with: try event(
            .leftMouseDown, point: anchor, clickCount: 2, fixture: fixture
        ))
        XCTAssertEqual(fixture.workspace.currentSelection?.string, "bravo")
        fixture.view.mouseDragged(with: try event(
            .leftMouseDragged, point: endpoint, clickCount: 2, fixture: fixture
        ))
        fixture.view.mouseUp(with: try event(
            .leftMouseUp, point: endpoint, clickCount: 2, fixture: fixture
        ))

        XCTAssertEqual(fixture.workspace.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "bravo charlie delta.\nEcho foxtrot golf")

        // Releasing in blank space has no native endpoint word. The original
        // double-click must still anchor at the beginning of the whole word.
        let blankMargin = CGPoint(x: 315, y: 405)
        fixture.view.mouseDown(with: try event(
            .leftMouseDown, point: anchor, clickCount: 2, fixture: fixture
        ))
        fixture.view.mouseDragged(with: try event(
            .leftMouseDragged, point: blankMargin, clickCount: 2, fixture: fixture
        ))
        fixture.view.mouseUp(with: try event(
            .leftMouseUp, point: blankMargin, clickCount: 2, fixture: fixture
        ))
        XCTAssertEqual(fixture.workspace.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "bravo charlie delta.")
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testRepairedBodyTextDragExcludesNeighboringFigureLabelsAndKeepsPartialEndpoints() async throws {
        let fixture = try makeFixture(neighboringFigureLabels: true, hostsWindow: true)
        defer { fixture.detach() }
        XCTAssertTrue(PDFTextSelectionGeometry.needsRegionSelection(on: fixture.page))
        XCTAssertNotNil(PDFNativeSelectionProxy.makePage(for: fixture.page))
        let originalText = fixture.page.string
        let revision = fixture.workspace.revision
        let originalAnnotations = fixture.page.annotations.count
        // Courier's PDF StandardEncoding maps byte 39 to a right quotation mark.
        let expectedLines = ["The other complication is that the Earth’s",
                             "magnetic poles are not permanent.", "They move slowly over time."]
        let fullStart = CGPoint(x: 179, y: 403)
        let fullEnd = CGPoint(x: 180 + CGFloat(expectedLines[2].count) * 6 + 1, y: 363)
        let partialStart = CGPoint(x: 180 + CGFloat("The other ".count) * 6 + 0.1, y: 403)
        let partialEnd = CGPoint(x: 180 + CGFloat("They move slowly".count) * 6 - 0.1, y: 363)
        let expectedPartial = ["complication is that the Earth’s", expectedLines[1], "They move slowly"]
        for (head, tail, expected) in [(fullStart, fullEnd, expectedLines),
                                       (partialStart, partialEnd, expectedPartial)] {
            for (start, end) in [(head, tail), (tail, head)] {
                fixture.view.mouseDown(with: try event(.leftMouseDown, point: start, fixture: fixture))
                fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: end, fixture: fixture))
                let selection = try XCTUnwrap(fixture.workspace.currentSelection as? PDFRegionTextSelection)
                XCTAssertEqual(selection.string?.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                               expected.joined(separator: " "))
                XCTAssertFalse(selection.string?.contains("Geographic") ?? true)
                XCTAssertFalse(selection.string?.contains("South Pole") ?? true)
                XCTAssertTrue(selection.fragments.allSatisfy { $0.bounds.minX >= 179 && $0.bounds.height < 20 })
                XCTAssertNil(fixture.view.currentSelection)
                fixture.view.mouseUp(with: try event(.leftMouseUp, point: end, fixture: fixture))
                XCTAssertEqual(fixture.workspace.currentSelection?.string, selection.string)
            }
        }

        // Every pointer event updates live text immediately without making the
        // full SwiftUI workspace refresh. Mouse-up commits its latest endpoint.
        let shortEnd = CGPoint(x: 180 + CGFloat("The other complication".count) * 6 - 0.1, y: 403)
        fixture.view.mouseDown(with: try event(.leftMouseDown, point: fullStart, fixture: fixture))
        var publications = 0
        var statusPublications = 0
        let publicationObserver = fixture.workspace.objectWillChange.sink { publications += 1 }
        let statusObserver = fixture.workspace.$statusMessage.dropFirst().sink { _ in statusPublications += 1 }
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: shortEnd, fixture: fixture))
        let firstMove = try XCTUnwrap(fixture.workspace.currentSelection as? PDFRegionTextSelection)
        XCTAssertEqual(firstMove.string, "The other complication")
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: fullEnd, fixture: fixture))
        XCTAssertFalse(fixture.workspace.currentSelection === firstMove,
                       "The newest pointer must be visible immediately, including within the same display interval.")
        XCTAssertEqual(fixture.workspace.currentSelection?.string?.split(whereSeparator: \.isWhitespace)
            .joined(separator: " "), expectedLines.joined(separator: " "))
        XCTAssertEqual(publications, 0, "Dragging must not rebuild the SwiftUI workspace.")
        XCTAssertEqual(statusPublications, 0, "The status bar should not publish per pointer event.")
        fixture.view.mouseUp(with: try event(.leftMouseUp, point: partialEnd, fixture: fixture))
        XCTAssertEqual(publications - statusPublications, 1,
                       "The final selection should publish exactly one workspace update.")
        publicationObserver.cancel()
        statusObserver.cancel()
        let expectedReleased = [expectedLines[0], expectedLines[1], "They move slowly"].joined(separator: " ")
        XCTAssertEqual(fixture.workspace.currentSelection?.string?.split(whereSeparator: \.isWhitespace)
            .joined(separator: " "), expectedReleased)
        XCTAssertFalse(fixture.view.regionSelection.isDragging)

        // Escape owns the gesture, including a late mouse-up. Yield once to
        // make sure asynchronous callbacks cannot restore the cancelled text.
        fixture.view.mouseDown(with: try event(.leftMouseDown, point: fullStart, fixture: fixture))
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: shortEnd, fixture: fixture))
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: fullEnd, fixture: fixture))
        fixture.view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )))
        fixture.view.mouseUp(with: try event(.leftMouseUp, point: partialEnd, fixture: fixture))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertNil(fixture.view.currentSelection)
        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertEqual(fixture.workspace.revision, revision)

        // A new pointer event must validate the revision before SwiftUI's
        // synchronization callback has had a chance to cancel the gesture.
        fixture.view.mouseDown(with: try event(.leftMouseDown, point: fullStart, fixture: fixture))
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: shortEnd, fixture: fixture))
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: fullEnd, fixture: fixture))
        fixture.workspace.refreshLocalization()
        let refreshedRevision = fixture.workspace.revision
        XCTAssertNotEqual(refreshedRevision, revision)
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: partialEnd, fixture: fixture))
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertFalse(fixture.view.regionSelection.isActive)
        fixture.view.mouseUp(with: try event(.leftMouseUp, point: fullEnd, fixture: fixture))
        XCTAssertNil(fixture.workspace.currentSelection)

        // A new search result owns selection immediately, even when its view
        // update has not synchronized. Further drag/up events must leave it.
        let searchSelection = try XCTUnwrap(fixture.page.selection(for: NSRange(location: 0, length: 3)))
        fixture.view.mouseDown(with: try event(.leftMouseDown, point: fullStart, fixture: fixture))
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: shortEnd, fixture: fixture))
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: fullEnd, fixture: fixture))
        fixture.workspace.currentSelection = searchSelection
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: partialEnd, fixture: fixture))
        XCTAssertTrue(fixture.workspace.currentSelection === searchSelection)
        XCTAssertFalse(fixture.view.regionSelection.isActive)
        fixture.view.mouseUp(with: try event(.leftMouseUp, point: fullEnd, fixture: fixture))
        XCTAssertTrue(fixture.workspace.currentSelection === searchSelection)
        XCTAssertEqual(fixture.page.string, originalText)
        XCTAssertEqual(fixture.page.annotations.count, originalAnnotations)
        XCTAssertEqual(fixture.workspace.revision, refreshedRevision)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
    }

    @MainActor
    func testUnrepairableFormUsesCachedVisibleTextAndCancelsOnRevisionWithoutEditing() async throws {
        let fixture = try makeFixture(unrepairableForm: true, hostsWindow: true)
        defer { fixture.detach() }
        XCTAssertTrue(PDFTextSelectionGeometry.needsRegionSelection(on: fixture.page))
        XCTAssertNil(PDFNativeSelectionProxy.makePage(for: fixture.page))
        let originalText = fixture.page.string
        let originalAnnotations = fixture.page.annotations.count
        let revision = fixture.workspace.revision
        let anchor = CGPoint(x: 79, y: 405)
        let endpoint = CGPoint(x: 330, y: 375)

        fixture.view.mouseDown(with: try event(.leftMouseDown, point: anchor, fixture: fixture))
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: endpoint, fixture: fixture))
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        fixture.view.mouseUp(with: try event(.leftMouseUp, point: endpoint, fixture: fixture))
        XCTAssertNil(fixture.workspace.currentSelection)
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while fixture.workspace.currentSelection == nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let first = try XCTUnwrap(fixture.workspace.currentSelection as? PDFRegionTextSelection)
        XCTAssertTrue(first.string?.contains("Alpha bravo") == true)
        XCTAssertTrue(first.string?.contains("Delta echo") == true)
        XCTAssertEqual(first.fragments.count, 2)
        XCTAssertTrue(first.pages.first === fixture.page)
        XCTAssertNil(fixture.view.currentSelection)
        for fragment in first.fragments {
            XCTAssertGreaterThan(fragment.bounds.minX, 70)
            XCTAssertLessThan(fragment.bounds.maxX, 330)
            XCTAssertGreaterThan(fragment.bounds.minY, 360)
            XCTAssertLessThan(fragment.bounds.maxY, 425)
            XCTAssertGreaterThan(fragment.bounds.height, 5)
            XCTAssertLessThan(fragment.bounds.height, 30)
        }

        // No await or mouse-up occurs before checking the reverse selection:
        // the recognized page layout must drive the second drag immediately.
        fixture.view.mouseDown(with: try event(.leftMouseDown, point: endpoint, fixture: fixture))
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: anchor, fixture: fixture))
        let cached = try XCTUnwrap(fixture.workspace.currentSelection as? PDFRegionTextSelection)
        XCTAssertEqual(cached.fragments, first.fragments)
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        fixture.view.regionSelection.synchronize()
        XCTAssertTrue(fixture.workspace.currentSelection === cached)
        fixture.view.mouseUp(with: try event(.leftMouseUp, point: anchor, fixture: fixture))
        XCTAssertEqual(fixture.workspace.currentSelection?.string, first.string)
        XCTAssertEqual(fixture.workspace.revision, revision)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)

        // Localization changes a revision without modifying PDF bytes. After
        // synchronization, a new drag must be cold and its pending OCR must not
        // survive another revision, even when mouse-up arrives afterward.
        fixture.workspace.refreshLocalization()
        fixture.view.regionSelection.synchronize()
        XCTAssertNil(fixture.workspace.currentSelection)
        fixture.view.mouseDown(with: try event(.leftMouseDown, point: anchor, fixture: fixture))
        fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: endpoint, fixture: fixture))
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        fixture.workspace.refreshLocalization()
        fixture.view.regionSelection.synchronize()
        fixture.view.mouseUp(with: try event(.leftMouseUp, point: endpoint, fixture: fixture))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertNil(fixture.view.currentSelection)
        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertEqual(fixture.page.string, originalText)
        XCTAssertEqual(fixture.page.annotations.count, originalAnnotations)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
    }

    @MainActor
    func testOrdinaryDragLeavesNativeTextSelectionUntouched() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let native = try XCTUnwrap(fixture.page.selection(for: NSRange(location: 0, length: 6)))
        fixture.view.setCurrentSelection(native, animate: false)
        fixture.workspace.currentSelection = native

        XCTAssertFalse(fixture.view.regionSelection.begin(with: try event(.leftMouseDown, fixture: fixture)))

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertEqual(fixture.view.currentSelection?.string, native.string)
        XCTAssertTrue(fixture.workspace.currentSelection === native)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testOptionDragUsesEphemeralSelectionAndEscapeCancelsIt() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let revision = fixture.workspace.revision
        let text = fixture.page.string
        let annotationCount = fixture.page.annotations.count

        fixture.view.mouseDown(with: try event(.leftMouseDown, modifiers: .option, fixture: fixture))
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        fixture.view.mouseDragged(with: try event(
            .leftMouseDragged, point: CGPoint(x: 250, y: 250), modifiers: .option, fixture: fixture
        ))

        // Status/sidebar updates must not cancel the rectangle while dragging.
        fixture.view.configure(with: fixture.workspace)
        fixture.view.regionSelection.synchronize()
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        XCTAssertNil(fixture.view.currentSelection)
        XCTAssertNil(fixture.workspace.currentSelection)

        fixture.view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )))

        // Escape can arrive while the button is still held. PDFKit must not
        // inherit the rest of a gesture whose mouse-down it never received.
        fixture.view.mouseDragged(with: try event(
            .leftMouseDragged, point: CGPoint(x: 280, y: 240), fixture: fixture
        ))
        fixture.view.mouseUp(with: try event(
            .leftMouseUp, point: CGPoint(x: 280, y: 240), fixture: fixture
        ))

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertFalse(fixture.view.regionSelection.isDragging)
        XCTAssertNil(fixture.view.currentSelection)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertEqual(fixture.workspace.revision, revision)
        XCTAssertEqual(fixture.page.string, text)
        XCTAssertEqual(fixture.page.annotations.count, annotationCount)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
    }

    @MainActor
    func testOptionClickWithoutAnAreaDoesNotStartRecognition() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }

        fixture.view.mouseDown(with: try event(.leftMouseDown, modifiers: .option, fixture: fixture))
        fixture.view.mouseUp(with: try event(.leftMouseUp, modifiers: .option, fixture: fixture))

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertNil(fixture.view.regionSelection.selection)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testOptionDragDoesNotTakeOverLinksOrFormWidgets() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let point = CGPoint(x: 100, y: 330)

        for subtype in [PDFAnnotationSubtype.link, .widget] {
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 80, y: 300, width: 100, height: 60),
                forType: subtype, withProperties: nil
            )
            fixture.page.addAnnotation(annotation)
            XCTAssertFalse(fixture.view.regionSelection.begin(with: try event(
                .leftMouseDown, point: point, modifiers: .option, fixture: fixture
            )))
            XCTAssertFalse(fixture.view.regionSelection.isActive)
            fixture.page.removeAnnotation(annotation)
        }
    }

    @MainActor
    func testClearSelectionCancelsQueuedRecognitionWithoutRestoringOldText() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        try finishRegionGesture(in: fixture)
        XCTAssertTrue(fixture.view.regionSelection.isActive)
        XCTAssertFalse(fixture.view.regionSelection.isDragging)

        // The task first yields on MainActor, so this cancellation happens
        // before snapshot/Vision work and requires no OCR service in XCTest.
        fixture.view.clearSelection()
        fixture.workspace.statusMessage = "Selection cleared"
        for _ in 0..<3 { await Task.yield() }

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertNil(fixture.view.regionSelection.selection)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertEqual(fixture.workspace.statusMessage, "Selection cleared")
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testNavigationCancelsQueuedRecognitionFromPreviousPage() async throws {
        let fixture = try makeFixture(pageCount: 2, hostsWindow: true)
        defer { fixture.detach() }
        try finishRegionGesture(in: fixture)
        XCTAssertTrue(fixture.view.regionSelection.isActive)

        let nextPage = try XCTUnwrap(fixture.workspace.document?.page(at: 1))
        fixture.view.go(to: nextPage)
        fixture.view.layoutDocumentView()
        fixture.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(fixture.view.visiblePages.contains { $0 === nextPage })
        XCTAssertFalse(fixture.view.visiblePages.contains { $0 === fixture.page })
        fixture.view.regionSelection.synchronize()
        fixture.workspace.statusMessage = "Navigated to next page"
        for _ in 0..<3 { await Task.yield() }

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertNil(fixture.view.regionSelection.selection)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertEqual(fixture.workspace.statusMessage, "Navigated to next page")
    }

    @MainActor
    func testNewSearchSelectionCancelsQueuedRecognitionOnSamePage() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        try finishRegionGesture(in: fixture)
        let native = try XCTUnwrap(fixture.page.selection(for: NSRange(location: 0, length: 6)))

        // Search state is applied while the coordinator suppresses PDFKit's
        // selection notification. Synchronization must preserve the new owner.
        fixture.workspace.currentSelection = native
        fixture.view.regionSelection.synchronize()
        fixture.workspace.statusMessage = "Search result selected"
        XCTAssertFalse(fixture.view.regionSelection.isActive)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertTrue(fixture.workspace.currentSelection === native)
        XCTAssertEqual(fixture.workspace.statusMessage, "Search result selected")
    }

    @MainActor
    func testToolChangeCancelsInProgressRegion() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        fixture.workspace.setMode(.editing)
        fixture.view.configure(with: fixture.workspace)
        XCTAssertTrue(fixture.view.regionSelection.begin(with: try event(
            .leftMouseDown, modifiers: .option, fixture: fixture
        )))

        fixture.workspace.activeTool = .pen
        fixture.view.configure(with: fixture.workspace)
        fixture.view.regionSelection.synchronize()

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertFalse(fixture.view.regionSelection.isDragging)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testOptionCannotBypassDocumentCopyPermission() throws {
        let fixture = try makeFixture(copyingForbidden: true)
        defer { fixture.detach() }
        XCTAssertEqual(fixture.workspace.document?.permissionsStatus, .user)
        XCTAssertFalse(fixture.workspace.allows(.copyAndPaste))

        XCTAssertFalse(fixture.view.regionSelection.begin(with: try event(
            .leftMouseDown, modifiers: .option, fixture: fixture
        )))

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertNil(fixture.workspace.currentSelection)
    }

    @MainActor
    private struct Fixture {
        let workspace: PDFWorkspaceState
        let view: InteractivePDFView
        let page: PDFPage
        let window: NSWindow?

        func detach() {
            view.regionSelection.cancel()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            window?.makeFirstResponder(nil)
            window?.contentView = nil
            window?.close()
        }
    }

    @MainActor
    private func makeFixture(
        pageCount: Int = 1,
        copyingForbidden: Bool = false,
        malformedMetrics: Bool = false,
        unrepairableForm: Bool = false,
        neighboringFigureLabels: Bool = false,
        imageOnly: Bool = false,
        rotation: Int = 0,
        hostsWindow: Bool = false
    ) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Region-Interaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf")
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        textView.font = .systemFont(ofSize: 17)
        textView.string = "Choose only this phrase.\nThe remaining page stays unchanged."
        let sourceData = neighboringFigureLabels ? neighboringFigureLabelsData() : (unrepairableForm ? unrepairableFormData() : (malformedMetrics
            ? PDFMalformedSelectionTestFixture.data(ascent: 67_306_242, rotation: rotation)
            : textView.dataWithPDF(inside: textView.bounds)))
        let source = try XCTUnwrap(PDFDocument(data: sourceData))
        if imageOnly {
            let image = NSImage(size: CGSize(width: 400, height: 500), flipped: false) { bounds in
                NSColor.black.setFill()
                bounds.fill()
                return true
            }
            source.removePage(at: 0)
            source.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        }
        for _ in 1..<pageCount {
            source.insert(try XCTUnwrap(source.page(at: 0)?.copy() as? PDFPage), at: source.pageCount)
        }
        if copyingForbidden {
            XCTAssertTrue(source.write(to: url, withOptions: [
                .ownerPasswordOption: "OwnerPass9", .userPasswordOption: "ReaderPass9",
                .accessPermissionsOption: NSNumber(value: 0),
                PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128
            ]))
        } else if malformedMetrics || unrepairableForm || neighboringFigureLabels {
            // PDFKit's writer can replace the malformed font while rewriting;
            // load the original bytes just as opening the user's file does.
            try sourceData.write(to: url)
        } else {
            XCTAssertTrue(source.write(to: url))
        }
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in "ReaderPass9" })
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.viewer)
        workspace.activeTool = .select
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        // Page navigation followed by an async yield flushes PDFKit's tile
        // deliveries. Give that fixture a real buffered host before attaching
        // its document; a windowless autoscaled view can release a null tile
        // surface on macOS 15. The window stays owned through cancellation.
        let window: NSWindow?
        if hostsWindow {
            let host = NSWindow(contentRect: view.frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentView = view
            window = host
        } else {
            window = nil
        }
        view.displayBox = .cropBox
        view.displayMode = .singlePage
        if hostsWindow {
            view.autoScales = false
            view.scaleFactor = 1
        }
        view.document = workspace.document
        if !hostsWindow { view.autoScales = true }
        view.go(to: page)
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        view.configure(with: workspace)
        view.regionSelection.synchronize()
        return Fixture(workspace: workspace, view: view, page: page, window: window)
    }

    private func unrepairableFormData() -> Data {
        // A Form with an unmatched restore cannot be repaired by appending
        // closing operators. CoreGraphics still displays the later page text.
        let content = "q /Fm0 Do Q BT /F1 18 Tf 80 400 Td (Alpha bravo charlie.) Tj 0 -30 Td (Delta echo foxtrot.) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> /XObject << /Fm0 6 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 500] /Length 1 >>\nstream\nQ\nendstream"
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func neighboringFigureLabelsData() -> Data {
        // Stream order interleaves the neighboring diagram labels with the
        // paragraph. They must not enter the user's visible body-text drag.
        let content = """
        q /Fm0 Do Q
        BT /F1 10 Tf 180 400 Td (The other complication is that the Earth's) Tj ET
        BT /F1 10 Tf 40 389 Td (Geographic) Tj ET
        BT /F1 10 Tf 180 380 Td (magnetic poles are not permanent.) Tj ET
        BT /F1 10 Tf 40 374 Td (South Pole) Tj ET
        BT /F1 10 Tf 180 360 Td (They move slowly over time.) Tj ET
        """
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 450 500] /Resources << /Font << /F1 4 0 R >> /XObject << /Fm0 6 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 450 500] /Length 1 >>\nstream\nq\nendstream"
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    @MainActor
    private func finishRegionGesture(in fixture: Fixture) throws {
        fixture.view.mouseDown(with: try event(.leftMouseDown, modifiers: .option, fixture: fixture))
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        fixture.view.mouseUp(with: try event(
            .leftMouseUp, point: CGPoint(x: 250, y: 250), modifiers: .option, fixture: fixture
        ))
    }

    @MainActor
    private func event(
        _ type: NSEvent.EventType,
        point: CGPoint = CGPoint(x: 100, y: 330),
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1,
        fixture: Fixture
    ) throws -> NSEvent {
        let viewPoint = fixture.view.convert(point, from: fixture.page)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: fixture.view.convert(viewPoint, to: nil),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1
        ))
    }
}
