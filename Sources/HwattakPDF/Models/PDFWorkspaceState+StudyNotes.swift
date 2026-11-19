// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// A presentation snapshot, never an independent copy of the PDF annotation.
struct StudyNoteItem: Identifiable {
    let documentID: ObjectIdentifier
    let pageIndex: Int
    let annotation: PDFAnnotation
    let contents: String

    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
}

/// A one-shot viewport request. Weak annotation ownership cannot keep a closed
/// PDF alive, and identity/revision checks reject callbacks from an old page graph.
@MainActor
final class StudyNoteRevealRequest: Identifiable {
    let id = UUID()
    let documentID: ObjectIdentifier
    let revision: UUID
    weak var annotation: PDFAnnotation?
    var isConsumed = false

    init(document: PDFDocument, revision: UUID, annotation: PDFAnnotation) {
        documentID = ObjectIdentifier(document)
        self.revision = revision
        self.annotation = annotation
    }
}

@MainActor
extension PDFWorkspaceState {
    func studyNotes(on pageIndex: Int) -> [StudyNoteItem] {
        guard let document, let page = document.page(at: pageIndex) else { return [] }
        return page.annotations.compactMap { annotation in
            guard annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
            else { return nil }
            let preview = InlineTextDraftLimiter.limit(annotation.contents ?? "",
                                                       characterLimit: 2_000, utf16Limit: 8_000)
            return StudyNoteItem(documentID: ObjectIdentifier(document), pageIndex: pageIndex,
                                 annotation: annotation, contents: preview.text)
        }
    }

    @discardableResult
    func revealStudyNote(_ note: StudyNoteItem) -> Bool {
        guard let document, let location = currentStudyNoteLocation(note) else { return false }
        cancelSearch()
        activeSearchSelection = nil
        currentSelection = nil
        invalidatePDFViewportScrollPosition()
        currentPageIndex = location.index
        selectedPages = [location.index]
        activeTool = .select
        studyNoteRevealRequest = StudyNoteRevealRequest(document: document, revision: revision,
                                                        annotation: note.annotation)
        return true
    }

    func editStudyNote(_ note: StudyNoteItem) {
        guard allows(.typedNotes), pendingTextEdit == nil,
              let location = currentStudyNoteLocation(note) else { return }
        guard revealStudyNote(note) else { return }
        let bounds = note.annotation.bounds
        requestTextEdit(pageIndex: location.index,
                        point: CGPoint(x: bounds.minX, y: bounds.maxY),
                        annotation: note.annotation)
    }

    func addStudyNote(quotingSelection: Bool = false) {
        guard allows(.typedNotes), pendingTextEdit == nil,
              let page = document?.page(at: currentPageIndex) else { return }
        let quote = quotingSelection && allows(.copyAndPaste)
            ? currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        if quotingSelection, quote?.isEmpty != false { return }
        let bounds = page.bounds(for: .cropBox)
        requestTextEdit(pageIndex: currentPageIndex,
                        point: CGPoint(x: bounds.minX + bounds.width * 0.12,
                                       y: bounds.maxY - bounds.height * 0.12),
                        annotation: nil)
        if let quote, let pending = pendingTextEdit {
            updatePendingTextDraft(id: pending.id, text: quote + "\n\n")
        }
        studyNotesVisible = true
    }

    func canDeleteStudyNote(_ note: StudyNoteItem) -> Bool {
        currentStudyNoteLocation(note) != nil
            && allowsAnnotationEditing(.freeText, annotation: note.annotation)
    }

    func deleteStudyNote(_ note: StudyNoteItem) {
        commitPendingInlineTextDraftIfNeeded()
        guard pendingInlineTextEdit == nil, pendingTextEdit == nil,
              canDeleteStudyNote(note),
              let location = currentStudyNoteLocation(note),
              let originalIndex = location.page.annotations.firstIndex(where: { $0 === note.annotation })
        else { return }
        location.page.removeAnnotation(note.annotation)
        registerRemovedAnnotation(note.annotation, from: location.page, originalIndex: originalIndex,
                                  message: L10n.string("study.notes.deleted", defaultValue: "메모를 삭제했습니다."), actionLocalization: .init(key: "study.notes.deleted"))
    }

    private func currentStudyNoteLocation(_ note: StudyNoteItem) -> (page: PDFPage, index: Int)? {
        guard let document, ObjectIdentifier(document) == note.documentID,
              let page = note.annotation.page,
              note.annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText",
              page.annotations.contains(where: { $0 === note.annotation }) else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : (page, index)
    }
}

/// Stable PDF colors keep notes readable on dark artwork and after reopening
/// in another viewer. The interface's light/dark theme never alters saved ink.
@MainActor
enum PDFStudyNoteAppearance {
    static var background: NSColor { NSColor(srgbRed: 1, green: 0.97, blue: 0.78, alpha: 1) }
    static var foreground: NSColor { NSColor(srgbRed: 0.12, green: 0.12, blue: 0.10, alpha: 1) }

    static func bounds(text: String, font: NSFont, anchor: CGPoint, pageBounds: CGRect,
                       preferredWidth: CGFloat? = nil) -> CGRect {
        let naturalWidth = (text as NSString).size(withAttributes: [.font: font]).width + 16
        let width = min(pageBounds.width, preferredWidth ?? min(280, max(140, naturalWidth)))
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width - 12), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        )
        let height = min(pageBounds.height, max(32, ceil(measured.height) + 16))
        return CGRect(x: min(max(anchor.x, pageBounds.minX), pageBounds.maxX - width),
                      y: min(max(anchor.y - height, pageBounds.minY), pageBounds.maxY - height),
                      width: width, height: height)
    }
}
