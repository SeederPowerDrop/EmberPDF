// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

struct StudyNoteDraftEditor: View {
    @ObservedObject var workspace: PDFWorkspaceState
    @ObservedObject var edit: PendingTextEdit

    var body: some View {
        TextEditSheet(edit: edit, onCommit: workspace.commitPendingText,
                      onDraftChanged: { workspace.updatePendingTextDraft(id: edit.id, text: $0) },
                      onCancel: workspace.cancelPendingText,
                      editorActions: StudyNoteEditorActions(
                        isFloating: workspace.noteEditorFloating,
                        togglePresentation: { workspace.noteEditorFloating.toggle() },
                        canInsertSelection: StudyNoteDraftInsertion.canReadSelection(workspace.currentSelection,
                            in: workspace.document, canCopy: workspace.allows(.copyAndPaste)),
                        selectedText: {
                            StudyNoteDraftInsertion.selectedText(workspace.currentSelection,
                                in: workspace.document, canCopy: workspace.allows(.copyAndPaste))
                        },
                        currentLocation: {
                            StudyNoteDraftInsertion.location(fileName: workspace.displayName,
                                pageIndex: workspace.currentPageIndex, pageCount: workspace.pageCount)
                        }))
            .id(edit.id)
    }
}

/// A document-owned panel, never a modal sheet over the page. Closing its
/// window docks the same draft; only Apply or Cancel resolves the transaction.
struct StudyNoteFloatingEditorHost: NSViewRepresentable {
    @ObservedObject var workspace: PDFWorkspaceState
    let isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(workspace: workspace, active: isActive)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.dismiss() }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var panel: NSPanel?
        private var draftID: UUID?
        private weak var workspace: PDFWorkspaceState?

        func update(workspace: PDFWorkspaceState, active: Bool) {
            self.workspace = workspace
            guard active, workspace.noteEditorFloating, let edit = workspace.pendingTextEdit else {
                dismiss()
                return
            }
            guard draftID != edit.id || panel == nil else { return }
            dismiss()
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = L10n.string(edit.isEditingExistingAnnotation ? "study.notes.edit" : "study.notes.add")
            panel.contentMinSize = NSSize(width: 330, height: 400)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.isFloatingPanel = true
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: StudyNoteDraftEditor(workspace: workspace, edit: edit))
            panel.setFrameAutosaveName("EmberStudyNoteEditor")
            if !panel.setFrameUsingName("EmberStudyNoteEditor") { panel.center() }
            self.panel = panel
            draftID = edit.id
            panel.makeKeyAndOrderFront(nil)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            workspace?.noteEditorFloating = false
            workspace?.studyNotesVisible = true
            return true
        }

        func dismiss() {
            panel?.delegate = nil
            panel?.orderOut(nil)
            panel?.close()
            panel = nil
            draftID = nil
        }
    }
}
