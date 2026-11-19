// SPDX-License-Identifier: MPL-2.0

import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFScannedBodyTextInteractionTests: XCTestCase {
    /// The copyrighted fixture stays outside the repository. Run with
    /// EMBER_NEWTON_PDF pointing to the user's original; only a temporary copy
    /// is opened by the workspace, and the original file's hash is checked.
    func testNewtonPage21SelectionButtonEditsOnPageAndUndoesWithoutChangingOriginal() async throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_NEWTON_PDF"], !path.isEmpty else {
            throw XCTSkip("Set EMBER_NEWTON_PDF to the Newton math-and-universe PDF for real-document UI coverage.")
        }
        _ = NSApplication.shared
        let originalURL = URL(fileURLWithPath: path)
        let originalHash = try hash(originalURL)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("newton-body-interaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copiedURL = directory.appendingPathComponent("Newton-test-copy.pdf")
        try FileManager.default.copyItem(at: originalURL, to: copiedURL)

        let state = PDFWorkspaceState()
        XCTAssertTrue(state.open(url: copiedURL))
        state.setMode(.editing)
        let document = try XCTUnwrap(state.document)
        let pageIndex = 20
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let originalText = try XCTUnwrap(page.string)
        let unchangedPages = [10, 30, 80]
        let otherPageText = try unchangedPages.map { try XCTUnwrap(document.page(at: $0)?.string) }
        let originalPageData = try PDFBodyTextPageSnapshot.data(for: page)
        let originalAnnotationCount = page.annotations.count
        let selectedText = "달은 만유인력"
        let selectionRange = (originalText as NSString).range(of: selectedText)
        XCTAssertNotEqual(selectionRange.location, NSNotFound,
                          "This fixture must contain the reported page 21 paragraph.")
        let selection = try XCTUnwrap(page.selection(for: selectionRange))
        XCTAssertEqual(selection.string, selectedText)
        let untouchedPhrases = ["지구 주위를", "그리고", "인 천체의 주위를"]
        let originalSearchCounts = try searchCounts(for: untouchedPhrases, in: page)
        for phrase in untouchedPhrases {
            XCTAssertTrue(originalText.contains(phrase), "The original fixture must contain \(phrase).")
            XCTAssertGreaterThan(originalSearchCounts[phrase] ?? 0, 0,
                                 "Each untouched Korean phrase must be searchable before editing.")
        }

        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = document
        view.displayMode = .singlePageContinuous
        view.autoScales = false
        let scale: CGFloat = 0.8
        view.scaleFactor = scale
        state.currentPageIndex = pageIndex
        view.configure(with: state)
        let coordinator = PDFKitViewer.Coordinator(state: state, viewportContext: .normal)
        coordinator.attach(to: view)
        defer {
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
        }
        view.go(to: page)
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(view)

        // Exercise the native drag's preview/commit bridge, including its
        // asynchronous release callback, before the separate toolbar action.
        view.beginNativeSelectionPreview()
        view.setCurrentSelection(selection, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        XCTAssertNil(state.pendingInlineTextEdit)
        view.scheduleNativeSelectionCommit()
        await drainMainQueue()
        XCTAssertEqual(state.currentSelection?.string, selectedText)
        XCTAssertNil(state.pendingInlineTextEdit,
                     "Selecting scanned text alone must not create a note or start editing.")

        state.selectTool(.text)
        view.configure(with: state)
        view.revealPendingBodyTextSelection()
        await drainMainQueue()
        view.layoutSubtreeIfNeeded()

        let draft = try XCTUnwrap(state.pendingInlineTextEdit)
        XCTAssertEqual(draft.purpose, .bodyText)
        XCTAssertEqual(draft.pageIndex, pageIndex)
        let selectedRange = try XCTUnwrap(draft.initialSelectedRange)
        XCTAssertEqual((draft.text as NSString).substring(with: selectedRange), selectedText)
        let panel = try XCTUnwrap(descendant(PDFInlineTextEditorPanel.self, in: view))
        let overlay = try XCTUnwrap(descendant(PDFInlineTextEditingOverlayView.self, in: view))
        let previewPaper = try XCTUnwrap(draft.bodyTextPreviewPaperColor,
                                        "The scanned page's paper color must reach the in-place editor.")
        XCTAssertTrue(PDFTextColor(panel.textView.backgroundColor).visuallyEquals(previewPaper),
                      "The editable canvas must blend with the scanned paper instead of showing a white note.")
        XCTAssertEqual(panel.currentStyle.backgroundColor.alpha, 0, accuracy: 0.0001,
                       "The preview-only paper color must not become a saved text background.")
        XCTAssertTrue(panel.textScrollView.superview === overlay,
                      "Scanned body text must edit on the PDF page instead of inside a floating note.")
        XCTAssertFalse(panel.textView.isDescendant(of: panel))
        let canvasRect = view.convert(panel.textScrollView.bounds, from: panel.textScrollView)
        XCTAssertTrue(canvasRect.intersects(view.convert(draft.bounds, from: page)))
        XCTAssertTrue(window.firstResponder === panel.textView)
        XCTAssertEqual(panel.textView.selectedRange(), selectedRange)
        XCTAssertEqual(view.scaleFactor, scale, accuracy: 0.0001)
        XCTAssertNil(state.presentedError)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(page.annotations.count, originalAnnotationCount)

        if let destination = ProcessInfo.processInfo.environment["EMBER_BODY_EDITOR_QA_DIRECTORY"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let folder = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("newton-page21-body-editor.png"))
        }

        let replacement = "달은 중력"
        let expectedDraft = (draft.text as NSString).replacingCharacters(in: selectedRange, with: replacement)
        panel.textView.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(panel.currentText, expectedDraft,
                       "Typing must replace only the dragged range while retaining the rest of the paragraph.")
        view.configure(with: state)
        XCTAssertEqual(panel.textView.selectedRange().length, 0)
        XCTAssertTrue(PDFTextColor(panel.textView.backgroundColor).visuallyEquals(previewPaper))
        XCTAssertEqual(panel.currentStyle.backgroundColor.alpha, 0, accuracy: 0.0001,
                       "Typing and draft synchronization must keep the saved text background transparent.")
        view.commitInlineTextEditorBeforePointerAction()
        XCTAssertNil(state.pendingInlineTextEdit)
        XCTAssertNil(state.presentedError)
        XCTAssertTrue(state.isDirty)
        XCTAssertTrue(state.canUndo)
        let revised = try XCTUnwrap(state.document?.page(at: pageIndex))
        XCTAssertTrue(revised.string?.contains(replacement) == true)
        XCTAssertFalse(revised.string?.contains(selectedText) == true)
        XCTAssertEqual(revised.annotations.count, originalAnnotationCount,
                       "Committing scanned body text must not leave a FreeText annotation.")
        XCTAssertEqual(try searchCounts(for: untouchedPhrases, in: revised), originalSearchCounts,
                       "Visible scan pixels alone are insufficient: unrelated Korean OCR text must remain searchable.")

        let savedURL = directory.appendingPathComponent("Newton-edited-save-check.pdf")
        try AtomicPDFWriter.write(XCTUnwrap(state.document), to: savedURL)
        let reopened = try XCTUnwrap(PDFDocument(url: savedURL))
        let reopenedPage = try XCTUnwrap(reopened.page(at: pageIndex))
        XCTAssertEqual(try searchCounts(for: untouchedPhrases, in: reopenedPage), originalSearchCounts,
                       "Saving and reopening must preserve the untouched Korean OCR layer, including other lines.")
        XCTAssertTrue(reopenedPage.string?.contains(replacement) == true)
        XCTAssertFalse(reopenedPage.string?.contains(selectedText) == true)
        for (index, expected) in zip(unchangedPages, otherPageText) {
            XCTAssertEqual(reopened.page(at: index)?.string, expected,
                           "Saving the whole book must preserve OCR on untouched page \(index + 1).")
        }

        state.undo()
        let undone = try XCTUnwrap(state.document?.page(at: pageIndex))
        XCTAssertEqual(undone.string, originalText)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: undone), originalPageData)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(try hash(originalURL), originalHash,
                       "The user's source PDF must remain byte-for-byte unchanged.")
    }

    private func hash(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func searchCounts(for phrases: [String], in page: PDFPage) throws -> [String: Int] {
        // Restrict genuine PDFKit search to this page so identical phrases on
        // the book's other pages cannot hide a destroyed OCR layer here.
        let searchable = PDFDocument()
        searchable.insert(try XCTUnwrap(page.copy() as? PDFPage), at: 0)
        return Dictionary(uniqueKeysWithValues: phrases.map {
            ($0, searchable.findString($0, withOptions: []).count)
        })
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }
}
