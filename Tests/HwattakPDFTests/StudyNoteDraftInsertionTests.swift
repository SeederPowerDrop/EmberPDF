// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

@MainActor
final class StudyNoteDraftInsertionTests: XCTestCase {
    private final class Editor: PDFBoundedPlainTextView {
        let history = UndoManager()
        private var ownedStorage: NSTextStorage?
        override var undoManager: UndoManager? { history }
        override convenience init(frame: NSRect) {
            self.init(frame: frame, textContainer: nil)
        }
        override init(frame: NSRect, textContainer: NSTextContainer?) {
            // NSTextView's designated nil-container initializer deliberately
            // creates no text system. Supply the same complete TextKit stack
            // its normal frame convenience initializer creates for production.
            let storage: NSTextStorage?
            let container: NSTextContainer
            if let textContainer {
                container = textContainer
                storage = textContainer.layoutManager?.textStorage
            } else {
                let newStorage = NSTextStorage()
                let layout = NSLayoutManager()
                container = NSTextContainer(size: CGSize(width: max(300, frame.width), height: .greatestFiniteMagnitude))
                layout.addTextContainer(container)
                newStorage.addLayoutManager(layout)
                storage = newStorage
            }
            super.init(frame: frame, textContainer: container)
            ownedStorage = storage
            history.groupsByEvent = false
            allowsUndo = true
            isRichText = false
        }
        required init?(coder: NSCoder) { nil }
    }

    func testInsertionReplacesCurrentSelectionAndNativeUndoRestoresDraft() {
        let editor = Editor(frame: CGRect(x: 0, y: 0, width: 300, height: 160))
        editor.string = "앞부분 기존 선택 뒷부분"
        let selection = (editor.string as NSString).range(of: "기존 선택")
        editor.setSelectedRange(selection)
        let controller = StudyNoteDraftInsertionController()
        controller.attach(editor)
        XCTAssertTrue(controller.insert("PDF 인용문"))
        XCTAssertEqual(editor.string, "앞부분 PDF 인용문 뒷부분")
        XCTAssertEqual(editor.selectedRange().location, selection.location + ("PDF 인용문" as NSString).length)
        XCTAssertEqual(editor.selectedRange().length, 0)
        XCTAssertTrue(editor.history.canUndo)
        editor.history.undo()
        XCTAssertEqual(editor.string, "앞부분 기존 선택 뒷부분")
        editor.history.redo()
        XCTAssertEqual(editor.string, "앞부분 PDF 인용문 뒷부분")
    }

    func testInsertionAtCaretPreservesSurroundingEmojiAndEachActionHasOwnUndo() {
        let editor = Editor(frame: .zero)
        editor.string = "👩🏽‍💻 끝"
        let offset = ("👩🏽‍💻 " as NSString).length
        editor.setSelectedRange(NSRange(location: offset, length: 0))
        let controller = StudyNoteDraftInsertionController()
        controller.attach(editor)
        XCTAssertTrue(controller.insert("첫째 "))
        XCTAssertTrue(controller.insert("둘째 "))
        XCTAssertEqual(editor.string, "👩🏽‍💻 첫째 둘째 끝")
        editor.history.undo()
        XCTAssertEqual(editor.string, "👩🏽‍💻 첫째 끝")
        editor.history.undo()
        XCTAssertEqual(editor.string, "👩🏽‍💻 끝")
    }

    func testMarkedKoreanCompositionIsNeverReplacedByToolbarInsertion() {
        let editor = Editor(frame: .zero)
        editor.string = "앞 "
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        // A real keyboard event supplies this group automatically. The
        // isolated fixture disables event grouping for deterministic Undo.
        editor.history.beginUndoGrouping()
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let original = editor.string
        let range = editor.markedRange()
        let controller = StudyNoteDraftInsertionController()
        controller.attach(editor)
        XCTAssertTrue(controller.isComposing)
        XCTAssertFalse(controller.insert("인용문"))
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.markedRange(), range)
        editor.unmarkText()
        editor.history.endUndoGrouping()
        controller.updateComposition(from: editor)
        XCTAssertFalse(controller.isComposing)
        XCTAssertTrue(controller.insert(" 인용문"))
        XCTAssertEqual(editor.string, "앞 한 인용문")
    }

    func testInsertionPreflightsBudgetAndKeepsTextAfterTheCursor() {
        let editor = Editor(frame: .zero)
        editor.encodedTextBudget = EncodedTextBudget(maximumCharacters: 12, maximumUTF8Bytes: 60, maximumUTF16CodeUnits: 24)
        editor.string = "head tail"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        var limitReports = 0
        editor.onLengthLimitReached = { limitReports += 1 }
        let controller = StudyNoteDraftInsertionController()
        controller.attach(editor)
        XCTAssertTrue(controller.insert(String(repeating: "가", count: 100_000)))
        XCTAssertEqual(editor.string, "head 가가가tail")
        XCTAssertEqual(limitReports, 1)
        editor.history.undo()
        XCTAssertEqual(editor.string, "head tail")
    }

    func testDetachedOrSupersededEditorCannotReceiveInsertion() {
        let first = Editor(frame: .zero), second = Editor(frame: .zero)
        first.string = "old"; second.string = "new"
        second.setSelectedRange(NSRange(location: 3, length: 0))
        let controller = StudyNoteDraftInsertionController()
        controller.attach(first)
        controller.attach(second)
        controller.detach(first)
        XCTAssertTrue(controller.insert(" note"))
        XCTAssertEqual(first.string, "old")
        XCTAssertEqual(second.string, "new note")
        controller.detach(second)
        XCTAssertFalse(controller.insert("late"))
        XCTAssertEqual(second.string, "new note")
    }

    func testEditorDismantlingNeverPublishesIntoSwiftUIViewTeardown() {
        let editor = Editor(frame: .zero)
        let controller = StudyNoteDraftInsertionController()
        controller.attach(editor)
        let representable = BoundedPlainTextEditor(text: .constant(""), isFocused: .constant(false),
            budget: PDFBoundedPlainTextView.freeTextBudget, onLengthLimitReached: {},
            insertionController: controller)
        let coordinator = representable.makeCoordinator()
        coordinator.textView = editor
        coordinator.insertionController = controller
        let scrollView = NSScrollView()
        scrollView.documentView = editor
        var publications = 0
        let subscription = controller.objectWillChange.sink { publications += 1 }
        BoundedPlainTextEditor.dismantleNSView(scrollView, coordinator: coordinator)
        XCTAssertEqual(publications, 0, "Dismantle must not synchronously reenter SwiftUI's graph.")
        XCTAssertNil(controller.textView)
        withExtendedLifetime(subscription) {}
    }

    func testCompositionNotificationFromDetachedEditorCannotReachNewEditor() {
        let first = Editor(frame: .zero), second = Editor(frame: .zero)
        first.history.beginUndoGrouping()
        first.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        first.history.endUndoGrouping()
        let controller = StudyNoteDraftInsertionController()
        var publications = 0
        let subscription = controller.objectWillChange.sink { publications += 1 }
        controller.attach(first)
        XCTAssertTrue(controller.isComposing)
        XCTAssertEqual(publications, 0, "Attach must defer notifications until after view construction.")
        controller.detach(first)
        controller.attach(second)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertFalse(controller.isComposing)
        XCTAssertEqual(publications, 0, "An old attachment must not publish stale composition state.")
        withExtendedLifetime(subscription) {}
    }

    func testSelectionMustBelongToCurrentPDFAndAllowCopying() throws {
        let document = PDFDocument(), other = PDFDocument()
        let page = PDFPage(), foreign = PDFPage()
        document.insert(page, at: 0); other.insert(foreign, at: 0)
        let selection = PDFRegionTextSelection(document: document, page: page, fragments: [
            PDFRegionTextFragment(text: "선택한 문장", bounds: CGRect(x: 10, y: 20, width: 100, height: 20))
        ])
        XCTAssertEqual(StudyNoteDraftInsertion.selectedText(selection, in: document, canCopy: true), "선택한 문장")
        XCTAssertNil(StudyNoteDraftInsertion.selectedText(selection, in: document, canCopy: false))
        XCTAssertNil(StudyNoteDraftInsertion.selectedText(selection, in: other, canCopy: true))
        XCTAssertNil(StudyNoteDraftInsertion.selectedText(nil, in: document, canCopy: true))
        XCTAssertTrue(page.annotations.isEmpty, "Inserting source text only changes a draft, never the PDF.")
    }

    func testTimestampUsesRequestedLocaleAndTimeZoneAndLocationUsesCurrentPage() throws {
        let date = Date(timeIntervalSince1970: 1_728_472_320)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        XCTAssertEqual(StudyNoteDraftInsertion.dateTime(date, locale: formatter.locale, timeZone: formatter.timeZone),
                       formatter.string(from: date))
        XCTAssertNotEqual(StudyNoteDraftInsertion.dateTime(date, locale: formatter.locale, timeZone: formatter.timeZone),
                          StudyNoteDraftInsertion.dateTime(date, locale: formatter.locale, timeZone: TimeZone(secondsFromGMT: 0)!))
        let location = try XCTUnwrap(StudyNoteDraftInsertion.location(fileName: "A PDF.pdf", pageIndex: 8, pageCount: 196))
        XCTAssertTrue(location.contains("A PDF.pdf"))
        XCTAssertTrue(location.contains("9"))
        XCTAssertTrue(location.contains("196"))
        XCTAssertNil(StudyNoteDraftInsertion.location(fileName: "empty.pdf", pageIndex: 0, pageCount: 0))
        XCTAssertNil(StudyNoteDraftInsertion.location(fileName: "A.pdf", pageIndex: 5, pageCount: 5))
    }
}
