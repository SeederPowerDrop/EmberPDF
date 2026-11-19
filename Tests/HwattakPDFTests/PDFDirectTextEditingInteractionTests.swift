// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFDirectTextEditingInteractionTests: XCTestCase {
    func testActiveSearchThenFourLineDragAndToolbarRefreshEditsTheEntireSelection() async throws {
        let lines = ["bravo first selected line", "second selected line",
                     "third selected line", "fourth selected line"]
        let content = "BT /F1 18 Tf 40 400 Td "
            + lines.enumerated().map { ($0.offset == 0 ? "" : "0 -22 Td ") + "(\($0.element)) Tj " }.joined()
            + "ET"
        let data = PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ])
        let fixture = try makeFixture(sourceData: data)
        defer { fixture.detach() }
        fixture.state.searchText = "bravo"
        fixture.state.performSearch()
        for _ in 0..<1_000 where fixture.state.isSearching {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(fixture.state.isSearching)
        let hit = try XCTUnwrap(fixture.state.activeSearchSelection)
        XCTAssertEqual(hit.string, "bravo")
        fixture.coordinator.applySearchSelection(hit, to: fixture.view)
        let original = try XCTUnwrap(fixture.page.string)
        XCTAssertEqual(original, lines.joined(separator: "\n"))
        let manual = try XCTUnwrap(fixture.page.selection(for:
            NSRange(location: 0, length: fixture.page.numberOfCharacters)))
        fixture.view.beginNativeSelectionPreview()
        fixture.view.setCurrentSelection(manual, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: fixture.view)
        fixture.view.finishNativeSelectionPreview()
        XCTAssertEqual(fixture.state.currentSelection?.string, original)

        for _ in 0..<4 {
            fixture.coordinator.applySearchSelection(hit, to: fixture.view)
            XCTAssertTrue(fixture.view.currentSelection === manual)
            XCTAssertTrue(fixture.state.currentSelection === manual)
        }
        fixture.state.selectTool(.text)
        fixture.view.configure(with: fixture.state)
        fixture.view.revealPendingBodyTextSelection()
        await drainMainQueue()
        let draft = try XCTUnwrap(fixture.state.pendingInlineTextEdit)
        let selectedRange = try XCTUnwrap(draft.initialSelectedRange)
        XCTAssertEqual((draft.text as NSString).substring(with: selectedRange), original)
        XCTAssertEqual(draft.text, original)
        XCTAssertTrue(fixture.state.activeSearchSelection === hit)
        XCTAssertFalse(fixture.state.isDirty)
        XCTAssertFalse(fixture.state.canUndo)
        XCTAssertEqual(fixture.page.string, original)
    }

    func testNativeDragThenTextButtonFocusesSelectedPhraseAndCommitsOneUndoableEdit() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let original = try XCTUnwrap(fixture.page.string)
        let selected = try fixture.selection("bravo")
        fixture.view.beginNativeSelectionPreview()
        fixture.view.setCurrentSelection(selected, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: fixture.view)
        XCTAssertNil(fixture.state.pendingInlineTextEdit, "Pointer updates must remain cheap selection only.")
        fixture.view.scheduleNativeSelectionCommit()
        await drainMainQueue()
        XCTAssertNil(fixture.state.pendingInlineTextEdit,
                     "Finishing a drag must leave an ordinary selection until the text button is pressed.")
        XCTAssertEqual(fixture.state.currentSelection?.string, "bravo")
        XCTAssertEqual(fixture.state.activeTool, .select)

        fixture.state.selectTool(.text)
        fixture.view.configure(with: fixture.state)
        fixture.view.revealPendingBodyTextSelection()
        await drainMainQueue()

        let draft = try XCTUnwrap(fixture.state.pendingInlineTextEdit)
        let range = try XCTUnwrap(draft.initialSelectedRange)
        XCTAssertEqual((draft.text as NSString).substring(with: range), "bravo")
        XCTAssertEqual(draft.purpose, .bodyText)
        XCTAssertEqual(fixture.state.activeTool, .text)
        XCTAssertFalse(fixture.state.isDirty)
        XCTAssertTrue(fixture.page.annotations.isEmpty,
                      "Editing selected body text must not create a note or free-text annotation.")
        let editor = try XCTUnwrap(descendants(PDFInlineTextView.self, in: fixture.view).first)
        try assertBodyCanvas(editor: editor, draft: draft, fixture: fixture)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), range)
        if let directory = ProcessInfo.processInfo.environment["EMBER_BODY_EDITOR_QA_DIRECTORY"] {
            fixture.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(fixture.view.bitmapImageRepForCachingDisplay(in: fixture.view.bounds))
            fixture.view.cacheDisplay(in: fixture.view.bounds, to: bitmap)
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("direct-edit-selected-phrase.png"))
        }
        editor.insertText("edited", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.string.contains("Alpha edited charlie"))
        fixture.view.configure(with: fixture.state)
        XCTAssertEqual(editor.selectedRange().length, 0, "Synchronization must not restore the original selection.")
        fixture.view.commitInlineTextEditorBeforePointerAction()
        XCTAssertNil(fixture.state.pendingInlineTextEdit)
        XCTAssertTrue(fixture.state.document?.page(at: 0)?.string?.contains("Alpha edited charlie") == true)
        XCTAssertEqual(fixture.state.activeTool, .select)
        fixture.state.undo()
        XCTAssertEqual(fixture.state.document?.page(at: 0)?.string, original)
        XCTAssertFalse(fixture.state.isDirty)
    }

    func testRepairedVisualDragWaitsForTextButtonThenSelectsExactWord() async throws {
        let fixture = try makeFixture(malformed: true)
        defer { fixture.detach() }
        XCTAssertTrue(PDFTextSelectionGeometry.needsRegionSelection(on: fixture.page))
        let start = CGPoint(x: 94.1, y: 405)
        let end = CGPoint(x: 138.9, y: 405)
        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: start))
        fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, at: end))
        let selected = try XCTUnwrap(fixture.state.currentSelection?.string)
        XCTAssertEqual(selected, "bravo")
        XCTAssertNil(fixture.state.pendingInlineTextEdit)
        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: end))
        await drainMainQueue()
        XCTAssertNil(fixture.state.pendingInlineTextEdit)
        XCTAssertEqual(fixture.state.currentSelection?.string, selected)
        XCTAssertEqual(fixture.state.activeTool, .select)

        fixture.state.selectTool(.text)
        fixture.view.configure(with: fixture.state)
        fixture.view.revealPendingBodyTextSelection()
        await drainMainQueue()
        let draft = try XCTUnwrap(fixture.state.pendingInlineTextEdit)
        let range = try XCTUnwrap(draft.initialSelectedRange)
        XCTAssertEqual((draft.text as NSString).substring(with: range), selected)
        XCTAssertEqual(draft.purpose, .bodyText)
        let editor = try XCTUnwrap(descendants(PDFInlineTextView.self, in: fixture.view).first)
        try assertBodyCanvas(editor: editor, draft: draft, fixture: fixture)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), range)
        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertFalse(fixture.state.isDirty)
        fixture.state.cancelPendingInlineText()
        XCTAssertFalse(fixture.state.canUndo)
        XCTAssertEqual(fixture.state.activeTool, .select)
    }

    func testUnsupportedSelectionTextButtonPreservesSelectionInsteadOfEnteringInsertionMode() throws {
        let content = "BT /F1 18 Tf 1 Tr 40 400 Td (Alpha bravo charlie delta.) Tj ET"
        let data = PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ])
        let fixture = try makeFixture(sourceData: data)
        defer { fixture.detach() }
        let original = try PDFBodyTextPageSnapshot.data(for: fixture.page)
        let selection = try fixture.selection("bravo")
        fixture.view.setCurrentSelection(selection, animate: false)
        fixture.state.currentSelection = selection

        fixture.state.selectTool(.text)
        fixture.view.configure(with: fixture.state)
        fixture.view.revealPendingBodyTextSelection()

        XCTAssertNil(fixture.state.pendingInlineTextEdit)
        XCTAssertTrue(fixture.state.currentSelection === selection)
        XCTAssertEqual(fixture.state.activeTool, .select,
                       "A failed selected-text edit must not turn the next click into a new text insertion.")
        XCTAssertNotNil(fixture.state.presentedError,
                        "An explicit edit request must explain that the selection could not be edited.")
        XCTAssertFalse(fixture.state.isDirty)
        XCTAssertFalse(fixture.state.canUndo)
        XCTAssertTrue(fixture.page.annotations.isEmpty)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: fixture.page), original)
    }

    func testViewerStudyAndComparisonSelectionsRemainCopyOnly() throws {
        for mode in [PDFWorkspaceMode.viewer, .study, .editing] {
            let fixture = try makeFixture(mode: mode, comparison: mode == .editing)
            defer { fixture.detach() }
            let selection = try fixture.selection("bravo")
            fixture.state.currentSelection = selection
            XCTAssertFalse(fixture.view.beginEditingSelectedBodyText())
            XCTAssertNil(fixture.state.pendingInlineTextEdit)
            XCTAssertTrue(fixture.state.currentSelection === selection)
            XCTAssertFalse(fixture.state.isDirty)
        }
    }

    func testExplicitSelectionAndStaleNativeReleaseDoNotOpenEditor() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        for stale in [false, true] {
            fixture.view.beginNativeSelectionPreview()
            fixture.view.setCurrentSelection(try fixture.selection("bravo"), animate: false)
            NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: fixture.view)
            fixture.view.scheduleNativeSelectionCommit(allowsDirectEditing: stale)
            if stale { fixture.state.currentSelection = try fixture.selection("charlie") }
            await drainMainQueue()
            XCTAssertNil(fixture.state.pendingInlineTextEdit)
            XCTAssertFalse(fixture.state.isDirty)
        }
    }

    func testNativeEditorReplacesUTF16SelectionWithIMEAndDeletePreservingSurroundings() throws {
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 600, height: 246))
        let text = "Prefix 👩🏽‍💻 바꿀 문구 suffix"
        let selected = (text as NSString).range(of: "바꿀 문구")
        let draft = PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
            isEditingExistingAnnotation: false, purpose: .bodyText, text: text,
            style: .standard(for: .bodyText), initialSelectedRange: selected)
        panel.configure(with: draft)
        XCTAssertEqual(panel.textView.selectedRange(), selected)
        panel.textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(panel.textView.hasMarkedText())
        panel.textView.insertText("한글", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(panel.currentText, "Prefix 👩🏽‍💻 한글 suffix")
        XCTAssertFalse(panel.textView.hasMarkedText())
        panel.configure(with: draft)
        panel.textView.deleteBackward(nil)
        XCTAssertEqual(panel.currentText, "Prefix 👩🏽‍💻  suffix")
    }

    private func assertBodyCanvas(editor: PDFInlineTextView, draft: PendingInlineTextEdit,
                                  fixture: Fixture, file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let panel = try XCTUnwrap(descendants(PDFInlineTextEditorPanel.self, in: fixture.view).first,
                                  file: file, line: line)
        let overlay = try XCTUnwrap(descendants(PDFInlineTextEditingOverlayView.self, in: fixture.view).first,
                                    file: file, line: line)
        XCTAssertTrue(panel.textView === editor, file: file, line: line)
        XCTAssertTrue(panel.textScrollView.superview === overlay,
                      "Selected body text must be edited on the page canvas, outside the floating formatting panel.",
                      file: file, line: line)
        XCTAssertFalse(editor.isDescendant(of: panel),
                       "The text input must not become a floating note-like editor.", file: file, line: line)
        let canvas = fixture.view.convert(panel.textScrollView.bounds, from: panel.textScrollView)
        let selectedBody = fixture.view.convert(draft.bounds, from: fixture.page)
        XCTAssertTrue(canvas.intersects(selectedBody),
                      "The editable canvas must cover the selected body text in the PDF.", file: file, line: line)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { view in
            (view as? T).map { [$0] } ?? []
        } + root.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor
    private struct Fixture {
        let state: PDFWorkspaceState
        let view: InteractivePDFView
        let coordinator: PDFKitViewer.Coordinator
        let page: PDFPage
        let window: NSWindow
        let directory: URL

        func selection(_ text: String) throws -> PDFSelection {
            let range = try XCTUnwrap(page.string as NSString?).range(of: text)
            XCTAssertNotEqual(range.location, NSNotFound)
            return try XCTUnwrap(page.selection(for: range))
        }

        func event(_ type: NSEvent.EventType, at pagePoint: CGPoint) throws -> NSEvent {
            let point = view.convert(view.convert(pagePoint, from: page), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }

        func detach() {
            state.cancelPendingInlineText()
            view.finishNativeSelectionPreview()
            coordinator.detach()
            view.regionSelection.cancel()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct NativeRenderingEnvironmentError: Error, CustomStringConvertible {
        let availability: PDFNativeRenderingAvailability

        var description: String {
            "Native PDF interaction fixture requires IOSurface creation, locking, and unlocking; "
                + "preflight returned \(availability). Run this test in a normal-permission macOS desktop session."
        }
    }

    func testUnavailableNativeRenderingFailsBeforeFixtureConstruction() throws {
        for reason in [PDFNativeRenderingAvailability.Failure.allocation, .lock, .unlock] {
            let availability = PDFNativeRenderingAvailability.unavailable(reason)
            XCTAssertThrowsError(try makeFixture(nativeRenderingAvailability: availability)) { error in
                XCTAssertEqual((error as? NativeRenderingEnvironmentError)?.availability, availability)
            }
        }
    }

    private func makeFixture(malformed: Bool = false, mode: PDFWorkspaceMode = .editing,
                             comparison: Bool = false, sourceData: Data? = nil,
                             nativeRenderingAvailability: PDFNativeRenderingAvailability = .current) throws -> Fixture {
        // PDFKit can trap in PDFTileSurface.releaseSurface after IOSurface allocation
        // is denied. Match the product prerequisite before creating any native view;
        // unsupported test hosts must fail explicitly and still require a GUI-lane run.
        guard nativeRenderingAvailability.isAvailable else {
            throw NativeRenderingEnvironmentError(availability: nativeRenderingAvailability)
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("direct-edit.pdf")
        try (sourceData ?? PDFMalformedSelectionTestFixture.data(ascent: malformed ? 67_306_242 : 800))
            .write(to: url)
        let state = PDFWorkspaceState()
        XCTAssertTrue(state.open(url: url))
        state.setMode(mode)
        state.activeTool = .select
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.viewportContext = comparison ? .comparison : .normal
        view.document = state.document
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = 1
        view.configure(with: state)
        let coordinator = PDFKitViewer.Coordinator(state: state, viewportContext: view.viewportContext)
        coordinator.attach(to: view)
        let page = try XCTUnwrap(state.document?.page(at: 0))
        view.go(to: page)
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(view)
        return Fixture(state: state, view: view, coordinator: coordinator,
                       page: page, window: window, directory: directory)
    }
}
