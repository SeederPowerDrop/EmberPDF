// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit

/// Formatting and source checks for explicit insertions into an unapplied
/// note draft. None of these actions mutate a PDF or use the clipboard.
enum StudyNoteDraftInsertion {
    static func dateTime(_ date: Date = Date(), locale: Locale = .autoupdatingCurrent,
                         timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func location(fileName: String, pageIndex: Int, pageCount: Int) -> String? {
        guard pageCount > 0, (0..<pageCount).contains(pageIndex) else { return nil }
        return L10n.format("study.notes.insert.location_format", fileName, pageIndex + 1, pageCount)
    }

    @MainActor
    static func canReadSelection(_ selection: PDFSelection?, in document: PDFDocument?, canCopy: Bool) -> Bool {
        guard canCopy, let selection, let document, !selection.pages.isEmpty else { return false }
        return selection.pages.allSatisfy { document.index(for: $0) != NSNotFound }
    }

    @MainActor
    static func selectedText(_ selection: PDFSelection?, in document: PDFDocument?, canCopy: Bool) -> String? {
        guard canReadSelection(selection, in: document, canCopy: canCopy),
              let text = selection?.string, !text.isEmpty else { return nil }
        return text
    }
}

/// The insertion boundary is the live NSTextView, not a String append. This
/// retains cursor/selection replacement, native Undo, and the existing budget
/// preflight before TextKit receives the text. A weak reference cannot retain
/// an outgoing editor window or insert into its replacement.
@MainActor
final class StudyNoteDraftInsertionController: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    var isComposing: Bool { textView?.hasMarkedText() ?? false }
    private(set) weak var textView: PDFBoundedPlainTextView?
    private var compositionRequest = UUID()
    private var lastNotifiedComposition = false

    func attach(_ view: PDFBoundedPlainTextView) {
        textView = view
        updateComposition(from: view)
    }

    func detach(_ view: PDFBoundedPlainTextView) {
        guard textView === view else { return }
        // Called by dismantleNSView while SwiftUI destroys its view graph.
        // Publishing here, even an unchanged `false`, reenters that graph and
        // can abort the process when the note window is docked or closed.
        compositionRequest = UUID()
        textView = nil
    }

    func updateComposition(from view: NSTextView) {
        guard textView === view else { return }
        let request = UUID()
        compositionRequest = request
        guard view.hasMarkedText() != lastNotifiedComposition else { return }
        // A delegate callback can also run during updateNSView. Notify only
        // after that transaction, and reject a callback from an old editor.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.textView === view,
                  self.compositionRequest == request else { return }
            let marked = view.hasMarkedText()
            guard marked != self.lastNotifiedComposition else { return }
            self.lastNotifiedComposition = marked
            self.objectWillChange.send()
        }
    }

    @discardableResult
    func insert(_ text: String) -> Bool {
        guard let textView, !text.isEmpty, !textView.hasMarkedText() else { return false }
        textView.breakUndoCoalescing()
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        textView.insertText(text, replacementRange: textView.selectedRange())
        undoManager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        textView.window?.makeFirstResponder(textView)
        textView.scrollRangeToVisible(textView.selectedRange())
        updateComposition(from: textView)
        return true
    }
}

struct StudyNoteEditorActions {
    let isFloating: Bool
    let togglePresentation: () -> Void
    let canInsertSelection: Bool
    let selectedText: () -> String?
    let currentLocation: () -> String?
}
