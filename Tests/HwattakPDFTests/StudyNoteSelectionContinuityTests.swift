// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

@MainActor
final class StudyNoteSelectionContinuityTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StudyNoteSelection-\(UUID())")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testTextToolStartsDraftThenAllowsSelectingMorePDFText() throws {
        let workspace = try makeWorkspace()
        defer { workspace.closeDiscardingChanges() }
        workspace.activeTool = .text
        workspace.requestTextEdit(pageIndex: 0, point: CGPoint(x: 20, y: 220), annotation: nil)
        let draft = try XCTUnwrap(workspace.pendingTextEdit)
        XCTAssertEqual(workspace.activeTool, .select,
                       "A side editor must leave the PDF available for selecting quotations.")
        workspace.updatePendingTextDraft(id: draft.id, text: "My explanation")
        let document = try XCTUnwrap(workspace.document)
        workspace.currentSelection = try XCTUnwrap(document.findString("selected phrase", withOptions: []).first)
        XCTAssertTrue(workspace.pendingTextEdit === draft)
        XCTAssertEqual(draft.initialText, "My explanation")
        XCTAssertTrue(workspace.allows(.copyAndPaste))
        XCTAssertFalse(workspace.isDirty)
    }

    func testSecondPageClickCannotReplaceAnUnappliedDraft() throws {
        let workspace = try makeWorkspace()
        defer { workspace.closeDiscardingChanges() }
        workspace.requestTextEdit(pageIndex: 0, point: CGPoint(x: 20, y: 220), annotation: nil)
        let draft = try XCTUnwrap(workspace.pendingTextEdit)
        workspace.updatePendingTextDraft(id: draft.id, text: "Keep my unsaved explanation")
        workspace.requestTextEdit(pageIndex: 1, point: CGPoint(x: 90, y: 140), annotation: nil)
        XCTAssertTrue(workspace.pendingTextEdit === draft)
        XCTAssertEqual(draft.pageIndex, 0)
        XCTAssertEqual(draft.initialText, "Keep my unsaved explanation")
        XCTAssertTrue(try XCTUnwrap(workspace.document).page(at: 0)?.annotations.isEmpty == true)
        XCTAssertTrue(workspace.document?.page(at: 1)?.annotations.isEmpty == true)
        XCTAssertFalse(workspace.isDirty)
    }

    func testOpeningAndTypingDraftPreserveNativeAndRecognizedSelections() throws {
        let workspace = try makeWorkspace()
        defer { workspace.closeDiscardingChanges() }
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let native = try XCTUnwrap(document.findString("selected phrase", withOptions: []).first)
        let recognized = PDFRegionTextSelection(document: document, page: page, fragments: [
            PDFRegionTextFragment(text: "Recognized quotation", bounds: CGRect(x: 20, y: 160, width: 140, height: 15))
        ])
        for selection in [native, recognized] as [PDFSelection] {
            workspace.currentSelection = selection
            workspace.requestTextEdit(pageIndex: 0, point: CGPoint(x: 20, y: 220), annotation: nil)
            let draft = try XCTUnwrap(workspace.pendingTextEdit)
            workspace.updatePendingTextDraft(id: draft.id, text: "Draft while selecting")
            XCTAssertTrue(workspace.currentSelection === selection)
            XCTAssertEqual(selection.string, selection === native ? "selected phrase" : "Recognized quotation")
            workspace.cancelPendingText()
        }
    }

    func testEditorRefreshDoesNotTakeFocusBackFromPDFView() async throws {
        let model = NoteEditorFocusModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        pdfView.document = try XCTUnwrap(PDFDocument(url: makePDF()))
        let host = NSHostingView(rootView: NoteEditorFocusHarness(model: model))
        host.frame = NSRect(x: 320, y: 0, width: 310, height: 300)
        content.addSubview(pdfView)
        content.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while findTextView(in: host) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            host.layoutSubtreeIfNeeded()
        }
        _ = try XCTUnwrap(findTextView(in: host))
        // Allow the editor's initial, intentional focus request to finish.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(window.makeFirstResponder(pdfView))
        model.text = "A selection-driven refresh"
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(window.firstResponder === pdfView,
                      "Refreshing a side editor must not steal focus during PDF text selection.")
    }

    private func findTextView(in view: NSView) -> PDFBoundedPlainTextView? {
        if let textView = view as? PDFBoundedPlainTextView { return textView }
        for child in view.subviews { if let found = findTextView(in: child) { return found } }
        return nil
    }

    private func makeWorkspace() throws -> PDFWorkspaceState {
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: try makePDF()))
        workspace.setMode(.study)
        return workspace
    }

    private func makePDF() throws -> URL {
        let url = directory.appendingPathComponent("\(UUID()).pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 260)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Alpha selected phrase" as NSString).draw(at: CGPoint(x: 15, y: 200),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}

@MainActor
private final class NoteEditorFocusModel: ObservableObject {
    @Published var text = "Initial draft"
}

private struct NoteEditorFocusHarness: View {
    @ObservedObject var model: NoteEditorFocusModel
    var body: some View {
        // A stable true request models an editor refresh that happens before a
        // native end-editing notification has updated its focus binding.
        BoundedPlainTextEditor(text: $model.text, isFocused: .constant(true),
            budget: PDFBoundedPlainTextView.freeTextBudget, onLengthLimitReached: {})
    }
}
