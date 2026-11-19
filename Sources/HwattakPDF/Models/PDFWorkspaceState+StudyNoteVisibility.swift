// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Preserve the complete standard /F field, including an originally absent
/// key. Only NoView is changed; print, locking, and unknown flags survive.
struct PDFStudyNoteVisibilityState {
    static let flagsKey = PDFAnnotationKey(rawValue: "/F")
    private static let noView: Int64 = 1 << 5
    let flags: NSNumber?
    let modificationDate: Date?

    init?(annotation: PDFAnnotation) {
        if let raw = annotation.value(forAnnotationKey: Self.flagsKey) {
            guard let number = raw as? NSNumber,
                  number.isEqual(to: NSNumber(value: number.int64Value)) else { return nil }
            flags = number
        } else {
            flags = nil
        }
        modificationDate = annotation.modificationDate
    }

    private init(flags: NSNumber?, modificationDate: Date?) {
        self.flags = flags
        self.modificationDate = modificationDate
    }

    func settingHidden(_ hidden: Bool, at date: Date) -> Self {
        let original = flags?.int64Value ?? 0
        let updated = hidden ? original | Self.noView : original & ~Self.noView
        return Self(flags: NSNumber(value: updated), modificationDate: date)
    }

    func matches(_ annotation: PDFAnnotation) -> Bool {
        guard let current = Self(annotation: annotation), modificationDate == current.modificationDate else { return false }
        switch (flags, current.flags) {
        case (nil, nil): return true
        case let (left?, right?): return left.isEqual(to: right)
        default: return false
        }
    }

    func apply(to annotation: PDFAnnotation) {
        if let flags { annotation.setValue(flags, forAnnotationKey: Self.flagsKey) }
        else { annotation.removeValue(forAnnotationKey: Self.flagsKey) }
        annotation.modificationDate = modificationDate
    }
}

struct PDFStudyNoteVisibilityChange {
    let page: PDFPage
    let annotation: PDFAnnotation
    let original: PDFStudyNoteVisibilityState
    let final: PDFStudyNoteVisibilityState
}

@MainActor
extension PDFWorkspaceState {
    func canSetStudyNoteVisibility(_ note: StudyNoteItem) -> Bool {
        guard mode == .study, allows(.typedNotes), pendingTextEdit == nil, pendingInlineTextEdit == nil,
              let document, !document.isLocked, note.documentID == ObjectIdentifier(document),
              let page = note.annotation.page, document.index(for: page) != NSNotFound,
              page.annotations.contains(where: { $0 === note.annotation }),
              note.annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText",
              PDFStudyNoteVisibilityState(annotation: note.annotation) != nil else { return false }
        return true
    }

    @discardableResult
    func setStudyNoteHidden(_ hidden: Bool, note: StudyNoteItem) -> Bool {
        setStudyNotesHidden(hidden, notes: [note],
            actionLocalization: .init(key: hidden ? "study.notes.visibility.hide" : "study.notes.visibility.show"))
    }

    /// The completed note index is supplied by the caller. Never walk every
    /// page synchronously merely to hide notes in a long scanned book.
    @discardableResult
    func setAllStudyNotesHidden(_ hidden: Bool, notes: [StudyNoteItem]) -> Bool {
        setStudyNotesHidden(hidden, notes: notes,
            actionLocalization: .init(key: hidden ? "study.notes.visibility.hide_all" : "study.notes.visibility.show_all"))
    }

    private func setStudyNotesHidden(_ hidden: Bool, notes: [StudyNoteItem],
                                    actionLocalization: PDFEditActionLocalization) -> Bool {
        guard !notes.isEmpty, notes.allSatisfy(canSetStudyNoteVisibility), let document else { return false }
        prepareForDeactivation()
        guard self.document === document, notes.allSatisfy(canSetStudyNoteVisibility) else { return false }
        let date = Date()
        var seen: Set<ObjectIdentifier> = []
        var changes: [PDFStudyNoteVisibilityChange] = []
        for note in notes {
            guard seen.insert(ObjectIdentifier(note.annotation)).inserted else { continue }
            guard note.annotation.shouldDisplay == hidden else { continue }
            guard let page = note.annotation.page,
                  let original = PDFStudyNoteVisibilityState(annotation: note.annotation) else { return false }
            changes.append(PDFStudyNoteVisibilityChange(page: page, annotation: note.annotation,
                original: original, final: original.settingHidden(hidden, at: date)))
        }
        guard !changes.isEmpty else { return false }
        guard applyStudyNoteVisibilityChanges(changes, actionName: actionLocalization.resolve(),
                                              actionLocalization: actionLocalization) else { return false }
        if hidden, let selected = studyNoteLayoutSelection?.annotation,
           changes.contains(where: { $0.annotation === selected }) {
            studyNoteLayoutSelection = nil
        }
        return true
    }
}
