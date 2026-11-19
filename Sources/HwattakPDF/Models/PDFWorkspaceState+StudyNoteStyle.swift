// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

@MainActor
extension PDFWorkspaceState {
    func isExplicitlySelectedStudyNote(_ annotation: PDFAnnotation) -> Bool {
        guard mode == .study, activeTool == .select, allows(.typedNotes), let document,
              annotation.shouldDisplay, let selection = studyNoteLayoutSelection,
              selection.documentID == ObjectIdentifier(document), selection.annotation === annotation,
              annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText",
              let page = annotation.page, document.index(for: page) != NSNotFound else { return false }
        return page.annotations.contains { $0 === annotation }
    }

    /// User-invoked inspector/handle selection is intentionally separate from
    /// reading a saved marker or merely clicking unknown page content.
    @discardableResult
    func selectStudyNoteForLayout(_ note: StudyNoteItem) -> Bool {
        guard mode == .study, allows(.typedNotes), pendingTextEdit == nil,
              note.annotation.shouldDisplay, let document, note.documentID == ObjectIdentifier(document),
              let page = note.annotation.page, document.index(for: page) != NSNotFound,
              page.annotations.contains(where: { $0 === note.annotation }),
              note.annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        else { return false }
        prepareForDeactivation()
        guard pendingInlineTextEdit == nil, self.document === document,
              note.annotation.page === page, page.annotations.contains(where: { $0 === note.annotation })
        else { return false }
        studyNoteLayoutSelection = StudyNoteLayoutSelection(document: document, annotation: note.annotation)
        return revealStudyNote(note)
    }

    @discardableResult
    func applyStudyNoteStyle(_ style: PDFStudyNoteStyle, to note: StudyNoteItem) -> StudyNoteItem? {
        guard mode == .study, allows(.typedNotes), pendingTextEdit == nil,
              let document, note.documentID == ObjectIdentifier(document),
              let page = note.annotation.page, document.index(for: page) != NSNotFound,
              page.annotations.contains(where: { $0 === note.annotation }),
              note.annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText",
              let constrained = style.constrained(to: page.bounds(for: .cropBox)) else { return nil }
        prepareForDeactivation()
        guard pendingInlineTextEdit == nil, self.document === document,
              note.annotation.page === page, page.annotations.contains(where: { $0 === note.annotation })
        else { return nil }
        if constrained.matches(PDFStudyNoteStyle(annotation: note.annotation)) { return note }
        let replacement = PDFStudyNoteAnnotation(copying: note.annotation, style: constrained)
        replacement.modificationDate = Date()
        replaceStudyNote(note.annotation, with: replacement, on: page,
                         message: L10n.string("study.note.style.updated", defaultValue: "메모 모양을 변경했습니다."),
                         actionLocalization: .init(key: "study.note.style.updated"))
        activeTool = .select
        studyNoteLayoutSelection = StudyNoteLayoutSelection(document: document, annotation: replacement)
        return StudyNoteItem(documentID: ObjectIdentifier(document), pageIndex: document.index(for: page),
                             annotation: replacement, contents: replacement.contents ?? "")
    }

    /// Shared by the side editor when reopening a saved transparent FreeText.
    /// Replacing its appearance object preserves alpha instead of allowing
    /// generic PDFKit to regenerate an opaque FreeText appearance.
    @discardableResult
    func commitExistingStudyNoteText(_ annotation: PDFAnnotation, on page: PDFPage, text: String) -> Bool {
        guard mode == .study, allows(.typedNotes), let document, document.index(for: page) != NSNotFound,
              annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText",
              page.annotations.contains(where: { $0 === annotation }),
              !InlineTextDraftLimiter.limit(text).wasTruncated else { return false }
        var style = PDFStudyNoteStyle(annotation: annotation)
        // Before styled backgrounds existed, app notes were black FreeText
        // on transparent pages. Repair only that legacy appearance; an
        // explicit transparent background chosen in the inspector is kept.
        let isLegacyOwnedNote = annotation.value(forAnnotationKey: PDFStudyNoteStyle.metadataKey) == nil
            && EditableAnnotationIdentity.kind(of: annotation) == .freeText
        let ink = PDFTextColor(annotation.fontColor ?? .black)
        let hasDarkInk = max(ink.red, ink.green, ink.blue) < 0.3
        let needsReadableBackground = isLegacyOwnedNote && hasDarkInk && style.backgroundOpacity < 0.05
        guard annotation.contents != text || needsReadableBackground else { return true }
        let shouldAutosizeLegacyNote = isLegacyOwnedNote && hasDarkInk
            && (needsReadableBackground || PDFTextColor(annotation.color)
                .visuallyEquals(PDFTextColor(PDFStudyNoteAppearance.background)))
        if needsReadableBackground {
            style.background = PDFStudyNoteAppearance.background
            style.backgroundOpacity = 1
            style.foreground = PDFStudyNoteAppearance.foreground
        }
        if shouldAutosizeLegacyNote {
            style.bounds = PDFStudyNoteAppearance.bounds(text: text,
                font: annotation.font ?? .systemFont(ofSize: 15),
                anchor: CGPoint(x: annotation.bounds.minX, y: annotation.bounds.maxY),
                pageBounds: page.bounds(for: .cropBox), preferredWidth: annotation.bounds.width)
        }
        let replacement = PDFStudyNoteAnnotation(copying: annotation, style: style)
        replacement.contents = text
        replacement.modificationDate = Date()
        EditableAnnotationIdentity.assign(.freeText, to: replacement)
        replaceStudyNote(annotation, with: replacement, on: page, message: L10n.string("status.text_updated"),
                         actionLocalization: .init(key: "status.text_updated"))
        studyNoteLayoutSelection = StudyNoteLayoutSelection(document: document, annotation: replacement)
        activeTool = .select
        studyNotesVisible = true
        return true
    }

    /// Reopened PDFKit FreeText objects regenerate their own opaque appearance
    /// on resize. Re-materialize only when an explicit drag really changes
    /// geometry; a simple selection remains a clean, read-only action.
    func commitReopenedStudyNoteGeometry(_ annotation: PDFAnnotation, on page: PDFPage,
                                         originalBounds: CGRect, originalModificationDate: Date?,
                                         message: String, actionLocalization: PDFEditActionLocalization? = nil) -> Bool {
        guard mode == .study, !(annotation is PDFStudyNoteAnnotation),
              isExplicitlySelectedStudyNote(annotation), let document else { return false }
        let style = PDFStudyNoteStyle(annotation: annotation)
        let finalDate = annotation.modificationDate
        annotation.bounds = originalBounds
        annotation.modificationDate = originalModificationDate
        let replacement = PDFStudyNoteAnnotation(copying: annotation, style: style)
        replacement.modificationDate = finalDate
        replaceStudyNote(annotation, with: replacement, on: page, message: message, actionLocalization: actionLocalization)
        studyNoteLayoutSelection = StudyNoteLayoutSelection(document: document, annotation: replacement)
        return true
    }

    private func replaceStudyNote(_ annotation: PDFAnnotation, with replacement: PDFAnnotation,
                                  on page: PDFPage, message: String,
                                  actionLocalization: PDFEditActionLocalization? = nil) {
        let original = page.annotations
        let final = original.map { $0 === annotation ? replacement : $0 }
        original.forEach(page.removeAnnotation)
        final.forEach(page.addAnnotation)
        registerAnnotationOrderChange(on: page, from: original, to: final, message: message,
                                      actionLocalization: actionLocalization)
    }
}
