// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextFocusScrollTests: XCTestCase {
    func testPolicyUsesFirstVisualLineAtThirtyEightPercentInBothCoordinateDirections() throws {
        let viewport = CGRect(x: 80, y: 100, width: 600, height: 500)
        let lines = [CGRect(x: 400, y: 850, width: 200, height: 20),
                     CGRect(x: 400, y: 900, width: 200, height: 20)]
        for flipped in [false, true] {
            let result = try XCTUnwrap(PDFBodyTextFocusScrollPolicy.proposedBounds(
                focusing: lines, viewport: viewport, isFlipped: flipped))
            let anchorY: CGFloat = flipped ? 860 : 910
            let distanceFromTop = flipped ? anchorY - result.minY : result.maxY - anchorY
            XCTAssertEqual(distanceFromTop / result.height, 0.38, accuracy: 0.0001)
            XCTAssertEqual(result.midX, 500, accuracy: 0.0001)
            XCTAssertEqual(result.size, viewport.size)
        }
    }

    func testExplicitTextButtonCentersFirstSelectedLineAndPreservesZoomAndSelection() throws {
        for scale: CGFloat in [1, 2] {
            let fixture = try Fixture(scale: scale)
            defer { fixture.detach() }
            let selection = try XCTUnwrap(fixture.page.selection(for: NSRange(location: 0,
                length: try XCTUnwrap(fixture.page.string).utf16.count)))
            XCTAssertEqual(selection.selectionsByLine().count, 2)
            fixture.state.currentSelection = selection
            fixture.state.selectTool(.text)
            fixture.view.configure(with: fixture.state)
            fixture.view.revealPendingBodyTextSelection()
            fixture.view.layoutSubtreeIfNeeded()

            let lines = selection.selectionsByLine().map { line in
                fixture.clip.convert(fixture.view.convert(line.bounds(for: fixture.page), from: fixture.page),
                                     from: fixture.view)
            }
            let firstY = try XCTUnwrap(fixture.clip.isFlipped ? lines.map(\.midY).min() : lines.map(\.midY).max())
            let distance = fixture.clip.isFlipped
                ? firstY - fixture.clip.bounds.minY : fixture.clip.bounds.maxY - firstY
            XCTAssertEqual(distance / fixture.clip.bounds.height, 0.38, accuracy: 0.005)
            XCTAssertEqual(fixture.view.scaleFactor, scale, accuracy: 0.0001)
            let draft = try XCTUnwrap(fixture.state.pendingInlineTextEdit)
            let panel = try XCTUnwrap(descendant(PDFInlineTextEditorPanel.self, in: fixture.view))
            XCTAssertEqual(panel.textView.selectedRange(), draft.initialSelectedRange)
            XCTAssertEqual((panel.currentText as NSString).substring(with: panel.textView.selectedRange()),
                           selection.string)
        }
    }

    func testTypingLayoutAndOverlayReplacementDoNotUndoManualScroll() throws {
        let fixture = try Fixture(scale: 1)
        defer { fixture.detach() }
        fixture.state.currentSelection = try XCTUnwrap(fixture.document.findString("First selected line", withOptions: []).first)
        fixture.state.selectTool(.text)
        fixture.view.configure(with: fixture.state)
        fixture.view.revealPendingBodyTextSelection()
        let panel = try XCTUnwrap(descendant(PDFInlineTextEditorPanel.self, in: fixture.view))
        var requested = fixture.clip.bounds
        requested.origin.y += 75
        fixture.clip.scroll(to: fixture.clip.constrainBoundsRect(requested).origin)
        let manuallyScrolled = fixture.clip.bounds.origin
        panel.textView.string += "!"
        panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.textView))
        fixture.view.configure(with: fixture.state)
        fixture.view.revealPendingBodyTextSelection()
        fixture.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.clip.bounds.origin, manuallyScrolled)

        let oldOverlay = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }.first)
        oldOverlay.removeFromSuperview()
        fixture.view.configureInlineTextEditingOverlay()
        fixture.view.revealPendingBodyTextSelection()
        XCTAssertEqual(fixture.clip.bounds.origin, manuallyScrolled,
                       "A new overlay for the same draft must not consume focus twice.")
        oldOverlay.prepareForRemoval()
    }

    func testTextButtonRevealsExistingAutomaticDraftWithoutCommittingOrLosingSelection() throws {
        for scale: CGFloat in [1, 2] {
            for hasTyped in [false, true] {
                let fixture = try Fixture(scale: scale)
                defer { fixture.detach() }
                let selection = try XCTUnwrap(fixture.page.selection(for: NSRange(location: 0,
                    length: try XCTUnwrap(fixture.page.string).utf16.count)))
                fixture.state.currentSelection = selection
                let initialViewport = fixture.clip.bounds.origin
                XCTAssertTrue(fixture.view.beginEditingSelectedBodyText())
                XCTAssertNil(fixture.state.currentSelection,
                             "The native drag handoff clears the PDF selection after opening TextKit.")
                let automaticDraft = try XCTUnwrap(fixture.state.pendingInlineTextEdit)
                let panel = try XCTUnwrap(descendant(PDFInlineTextEditorPanel.self, in: fixture.view))
                if hasTyped {
                    panel.textView.insertText("Changed first line\nSecond selected line",
                                              replacementRange: panel.textView.selectedRange())
                    panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.textView))
                }
                let draftText = panel.currentText
                let textSelection = panel.textView.selectedRange()
                XCTAssertEqual(fixture.clip.bounds.origin, initialViewport)

                fixture.state.selectTool(.text)
                fixture.view.configure(with: fixture.state)
                fixture.view.revealPendingBodyTextSelection()
                fixture.view.layoutSubtreeIfNeeded()

                XCTAssertEqual(fixture.state.pendingInlineTextEdit?.id, automaticDraft.id)
                XCTAssertEqual(fixture.state.pendingInlineTextEdit?.text, draftText)
                XCTAssertEqual(panel.textView.selectedRange(), textSelection)
                XCTAssertEqual(fixture.state.activeTool, .text)
                XCTAssertFalse(fixture.state.isDirty, "Opening the text tool must not apply an in-progress draft.")
                XCTAssertTrue(fixture.document.page(at: 0) === fixture.page)
                XCTAssertEqual(fixture.view.scaleFactor, scale, accuracy: 0.0001)
                let firstLine = try XCTUnwrap(selection.selectionsByLine().first)
                let lineRect = fixture.clip.convert(
                    fixture.view.convert(firstLine.bounds(for: fixture.page), from: fixture.page), from: fixture.view)
                let distance = fixture.clip.isFlipped
                    ? lineRect.midY - fixture.clip.bounds.minY : fixture.clip.bounds.maxY - lineRect.midY
                XCTAssertEqual(distance / fixture.clip.bounds.height, 0.38, accuracy: 0.005)
            }
        }
    }

    func testOrdinarySelectionEntryDoesNotRepositionTheViewport() throws {
        let fixture = try Fixture(scale: 1)
        defer { fixture.detach() }
        let before = fixture.clip.bounds.origin
        let selection = try XCTUnwrap(fixture.document.findString("First selected line", withOptions: []).first)
        XCTAssertTrue(fixture.state.requestBodyTextEdit(selection: selection))
        fixture.view.configure(with: fixture.state)
        fixture.view.revealPendingBodyTextSelection()
        XCTAssertEqual(fixture.clip.bounds.origin, before)
    }

    func testNativeFocusClampsAtTheDocumentBottom() throws {
        let fixture = try Fixture(scale: 1, firstBaseline: 60)
        defer { fixture.detach() }
        let selection = try XCTUnwrap(fixture.document.findString("First selected line", withOptions: []).first)
        let line = fixture.clip.convert(fixture.view.convert(selection.bounds(for: fixture.page), from: fixture.page),
                                       from: fixture.view)
        let proposed = try XCTUnwrap(PDFBodyTextFocusScrollPolicy.proposedBounds(
            focusing: [line], viewport: fixture.clip.bounds, isFlipped: fixture.clip.isFlipped))
        let expected = fixture.clip.constrainBoundsRect(proposed)
        XCTAssertNotEqual(expected.origin.y, proposed.origin.y, "Fixture must reach the page edge.")
        fixture.state.currentSelection = selection
        fixture.state.selectTool(.text)
        fixture.view.configure(with: fixture.state)
        fixture.view.revealPendingBodyTextSelection()
        XCTAssertEqual(fixture.clip.bounds.origin.y, expected.origin.y, accuracy: 0.1)
        XCTAssertEqual(fixture.view.scaleFactor, 1, accuracy: 0.0001)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private final class Fixture {
        let state = PDFWorkspaceState()
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let window: NSWindow
        let url: URL
        let document: PDFDocument
        let page: PDFPage
        let clip: NSClipView

        init(scale: CGFloat, firstBaseline: CGFloat = 900) throws {
            _ = NSApplication.shared
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 1200, height: 1600)
            let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)),
                                                   mediaBox: &box, nil))
            context.beginPDFPage(nil)
            let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 16))
            for (text, y) in [("First selected line", firstBaseline), ("Second selected line", firstBaseline - 24)] {
                context.textPosition = CGPoint(x: 500, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), context)
            }
            context.endPDFPage()
            context.closePDF()
            url = FileManager.default.temporaryDirectory.appendingPathComponent("body-focus-\(UUID().uuidString).pdf")
            try (data as Data).write(to: url)
            XCTAssertTrue(state.open(url: url))
            state.setMode(.editing)
            document = try XCTUnwrap(state.document)
            page = try XCTUnwrap(document.page(at: 0))
            window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.document = document
            view.displayMode = .singlePageContinuous
            view.autoScales = false
            view.scaleFactor = scale
            view.configure(with: state)
            view.go(to: page)
            view.layoutDocumentView()
            view.layoutSubtreeIfNeeded()
            clip = try XCTUnwrap(view.documentView?.enclosingScrollView?.contentView)
        }

        func detach() {
            state.cancelPendingInlineText()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: url)
        }
    }
}
