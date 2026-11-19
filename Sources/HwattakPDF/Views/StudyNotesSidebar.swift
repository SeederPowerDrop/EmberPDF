// SPDX-License-Identifier: MPL-2.0

import PDFKit
import SwiftUI

/// A PDF-backed notebook: the page annotation remains the source of truth.
struct StudyNotesSidebar: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let documents: MultiDocumentWorkspaceState
    let onClose: () -> Void
    @ObservedObject private var index: StudyNotesIndex

    init(workspace: PDFWorkspaceState, documents: MultiDocumentWorkspaceState, onClose: @escaping () -> Void) {
        self.workspace = workspace
        self.documents = documents
        self.onClose = onClose
        self.index = workspace.studyNotesIndex
    }

    private var notes: [StudyNoteItem] { index.notes }
    private var isScanning: Bool { index.isScanning }
    private var hiddenCount: Int { notes.filter { !$0.annotation.shouldDisplay }.count }
    @EmberTheme private var theme

    private struct ScanIdentity: Equatable {
        let document: ObjectIdentifier?
        let revision: UUID
    }

    private var scanIdentity: ScanIdentity {
        ScanIdentity(document: workspace.document.map(ObjectIdentifier.init), revision: workspace.revision)
    }

    private var hasSelection: Bool {
        workspace.allows(.copyAndPaste)
            && workspace.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.string("study.notes.title", defaultValue: "메모"), systemImage: "note.text")
                    .font(.headline)
                Spacer()
                Menu {
                    Button(L10n.string("study.notes.visibility.hide_all")) {
                        guard index.isComplete else { return }
                        workspace.setAllStudyNotesHidden(true, notes: notes)
                    }
                    .disabled(hiddenCount == notes.count)
                    Button(L10n.string("study.notes.visibility.show_all")) {
                        guard index.isComplete else { return }
                        workspace.setAllStudyNotesHidden(false, notes: notes)
                    }
                    .disabled(hiddenCount == 0)
                } label: {
                    Image(systemName: hiddenCount == notes.count && !notes.isEmpty ? "eye.slash" : "eye")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!index.isComplete || isScanning || notes.isEmpty || workspace.mode != .study
                          || !workspace.allows(.typedNotes) || workspace.pendingTextEdit != nil
                          || workspace.pendingInlineTextEdit != nil)
                .help(L10n.string("study.notes.visibility.hint"))
                .accessibilityLabel(L10n.string("study.notes.visibility.menu"))
                .accessibilityIdentifier("study-notes-visibility-menu")
                if workspace.pendingTextEdit != nil, workspace.noteEditorFloating {
                    Button { workspace.noteEditorFloating = false } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("study.notes.editor.dock"))
                    .accessibilityLabel(L10n.string("study.notes.editor.dock"))
                }
                Button(action: onClose) { Image(systemName: "xmark") }
                    .disabled(workspace.pendingTextEdit != nil && !workspace.noteEditorFloating)
                    .buttonStyle(.plain)
                    .help(L10n.string("action.close"))
                    .accessibilityLabel(L10n.string("action.close"))
            }
            .padding(16)

            if let edit = workspace.pendingTextEdit, !workspace.noteEditorFloating {
                StudyNoteDraftEditor(workspace: workspace, edit: edit)
            } else {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    workspace.addStudyNote()
                } label: {
                    Label(L10n.string("study.notes.add", defaultValue: "새 메모"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!workspace.allows(.typedNotes) || workspace.document == nil || workspace.pendingTextEdit != nil)

                Button {
                    workspace.addStudyNote(quotingSelection: true)
                } label: {
                    Label(L10n.string("study.notes.quote", defaultValue: "선택 글자로 메모"), systemImage: "text.quote")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!hasSelection || !workspace.allows(.typedNotes) || workspace.pendingTextEdit != nil)

                Text(L10n.string("study.notes.saved_in_pdf", defaultValue: "메모는 이 PDF의 주석으로 저장됩니다. 파일에 남기려면 저장하세요."))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    StudyNoteLinksPanel(workspace: workspace, documents: documents)
                    Divider()
                    if isScanning {
                        ProgressView(L10n.string("study.notes.scanning", defaultValue: "메모를 찾는 중…"))
                            .controlSize(.small)
                    }
                    if notes.isEmpty, !isScanning {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("study.notes.empty.title", defaultValue: "아직 메모가 없습니다"))
                                .font(.headline)
                            Text(L10n.string("study.notes.empty.detail", defaultValue: "PDF를 읽으며 메모를 추가하면 여기에 모아 볼 수 있습니다."))
                                .font(.callout)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.vertical, 18)
                    }
                    ForEach(notes) { note in
                        StudyNoteRow(workspace: workspace, documents: documents, note: note)
                    }
                }
                .padding(16)
            }
            VStack(spacing: 5) {
                Text(hiddenCount == 0 ? L10n.format("study.notes.count", notes.count)
                     : L10n.format("study.notes.visibility.count", notes.count, hiddenCount))
                    .font(.caption)
                if hiddenCount > 0 {
                    Text(L10n.string("study.notes.visibility.hint"))
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(theme.secondaryText)
            .padding(10)
            }
        }
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .accessibilityIdentifier("study-notes-sidebar")
        .task(id: scanIdentity) { await index.refresh(workspace: workspace) }
    }
}

/// Each presentation belongs to the clicked note button, so its arrow stays
/// beside that note even when the list is scrolled or the sidebar is resized.
private struct StudyNoteRow: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let documents: MultiDocumentWorkspaceState
    let note: StudyNoteItem
    @State private var showingAppearance = false
    @State private var showingLinks = false
    @EmberTheme private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                workspace.revealStudyNote(note)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(L10n.format("page.number", note.pageIndex + 1), systemImage: "doc.text")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.accent)
                        Spacer()
                        if !note.annotation.shouldDisplay {
                            Label(L10n.string("study.notes.visibility.hidden"), systemImage: "eye.slash")
                                .font(.caption2).foregroundStyle(theme.secondaryText)
                        }
                    }
                    Text(note.contents.isEmpty ? L10n.string("study.notes.untitled", defaultValue: "빈 메모") : note.contents)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("study.notes.reveal", defaultValue: "메모 위치로 이동"))

            HStack {
                Button(L10n.string("study.notes.edit", defaultValue: "메모 수정")) {
                    workspace.editStudyNote(note)
                }
                .disabled(!workspace.allows(.typedNotes) || workspace.pendingTextEdit != nil)
                .accessibilityIdentifier("study-note-edit-\(note.id)")
                Button { showingAppearance = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help(L10n.string("study.note.style.title"))
                    .accessibilityLabel(L10n.string("study.note.style.title"))
                    .disabled(workspace.mode != .study || workspace.pendingTextEdit != nil)
                    .accessibilityIdentifier("study-note-appearance-\(note.id)")
                    .popover(isPresented: $showingAppearance, attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
                        StudyNoteInspector(workspace: workspace, note: note)
                    }
                Button { showingLinks = true } label: { Image(systemName: "link") }
                    .help(L10n.string("study.links.title"))
                    .accessibilityLabel(L10n.string("study.links.title"))
                    .accessibilityIdentifier("study-note-connections-\(note.id)")
                    .popover(isPresented: $showingLinks, attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
                        StudyNoteLinksPanel(workspace: workspace, documents: documents, note: note)
                            .padding(16).frame(width: 380)
                    }
                Spacer()
                Button {
                    workspace.setStudyNoteHidden(note.annotation.shouldDisplay, note: note)
                } label: {
                    Image(systemName: note.annotation.shouldDisplay ? "eye" : "eye.slash")
                }
                .disabled(!workspace.canSetStudyNoteVisibility(note))
                .help(L10n.string(note.annotation.shouldDisplay
                                 ? "study.notes.visibility.hide" : "study.notes.visibility.show"))
                .accessibilityLabel(L10n.string(note.annotation.shouldDisplay
                                               ? "study.notes.visibility.hide" : "study.notes.visibility.show"))
                .accessibilityIdentifier("study-note-visibility-\(note.id)")
                Button(role: .destructive) {
                    workspace.deleteStudyNote(note)
                } label: { Image(systemName: "trash") }
                .disabled(!workspace.canDeleteStudyNote(note) || workspace.pendingTextEdit != nil)
                .help(workspace.canDeleteStudyNote(note)
                      ? L10n.string("study.notes.delete", defaultValue: "메모 삭제")
                      : L10n.string("study.notes.delete_unavailable", defaultValue: "이전에 저장된 메모는 편집 모드에서 삭제하거나 내용을 수정한 뒤 삭제할 수 있습니다."))
                .accessibilityLabel(L10n.string("study.notes.delete", defaultValue: "메모 삭제"))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(12)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1) }
    }

}
