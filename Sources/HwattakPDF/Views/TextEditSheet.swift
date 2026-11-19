// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Transactional editor for a pending FreeText annotation.
///
/// Typing is kept in local `@State`; the PDF is touched only by `onCommit`.
/// Consequently Escape/cancel never leaves a half-created annotation or dirty
/// document behind. The workspace owns validation and undo registration.
struct TextEditSheet: View {
    @ObservedObject var edit: PendingTextEdit
    let onCommit: (String) -> Void
    let onDraftChanged: (String) -> Void
    let onCancel: () -> Void
    let editorActions: StudyNoteEditorActions?

    @Environment(\.colorScheme) private var colorScheme
    @State private var text: String
    @State private var focused = false
    @State private var lengthLimitReached = false
    @StateObject private var insertion = StudyNoteDraftInsertionController()

    @EmberTheme private var theme

    init(
        edit: PendingTextEdit,
        onCommit: @escaping (String) -> Void,
        onDraftChanged: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        editorActions: StudyNoteEditorActions? = nil
    ) {
        self.edit = edit
        self.onCommit = onCommit
        self.onDraftChanged = onDraftChanged
        self.onCancel = onCancel
        self.editorActions = editorActions
        // `State` must be seeded through its backing storage in an initializer.
        // Assigning `text` later in `body` would reset user typing on redraw.
        _text = State(initialValue: edit.initialText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(L10n.string("주석 내용"))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if let editorActions { insertionButtons(editorActions) }
                    Text(L10n.format("text.character_count", text.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }

                BoundedPlainTextEditor(
                    text: $text,
                    isFocused: $focused,
                    budget: PDFBoundedPlainTextView.freeTextBudget,
                    onLengthLimitReached: {
                        lengthLimitReached = true
                    },
                    insertionController: insertion
                )
                    .frame(minHeight: 150)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(focused ? theme.accent.opacity(0.65) : theme.border, lineWidth: focused ? 1.5 : 1)
                    }

                if lengthLimitReached {
                    Label(
                        L10n.format(
                            "inline_text.length_limit",
                            InlineTextDraftLimiter.maximumCharacterCount
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Label(
                    L10n.string("study.notes.editor_hint", defaultValue: "적용하면 페이지에 메모가 추가되고 메모 목록에서도 확인할 수 있습니다. 긴 내용은 목록에서 다시 열어 읽을 수 있습니다."),
                    systemImage: "info.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)

            actionBar
        }
        .frame(minWidth: 290, maxWidth: .infinity, minHeight: 330, maxHeight: .infinity)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .onAppear { focused = true }
        .onChange(of: text) { _, newValue in
            // Keep the non-PDF draft alive when a tab switch tears down this
            // sheet. It remains outside the PDF until the person explicitly
            // presses Apply; tab switching and Save only preserve the draft.
            onDraftChanged(newValue)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(edit.isEditingExistingAnnotation
                     ? L10n.string("study.notes.edit", defaultValue: "메모 수정")
                     : L10n.string("study.notes.add", defaultValue: "새 메모"))
                    .font(.headline)
                Spacer(minLength: 4)
                Text(L10n.format("page.number", edit.pageIndex + 1))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                if let editorActions {
                    Button(action: editorActions.togglePresentation) {
                        Image(systemName: editorActions.isFloating ? "sidebar.right" : "arrow.up.forward.square")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string(editorActions.isFloating ? "study.notes.editor.dock" : "study.notes.editor.float"))
                    .accessibilityLabel(L10n.string(editorActions.isFloating ? "study.notes.editor.dock" : "study.notes.editor.float"))
                    .accessibilityIdentifier("study-note-editor-location")
                }
            }
            Text(L10n.string("study.notes.saved_in_pdf", defaultValue: "메모는 이 PDF의 주석으로 저장됩니다. 파일에 남기려면 저장하세요."))
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private func insertionButtons(_ actions: StudyNoteEditorActions) -> some View {
        HStack(spacing: 3) {
            Button {
                if let value = actions.selectedText() { insertion.insert(value) }
            } label: {
                Image(systemName: "text.quote").frame(width: 24, height: 24)
            }
            .disabled(!actions.canInsertSelection || insertion.isComposing)
            .help(L10n.string("study.notes.insert.selection"))
            .accessibilityLabel(L10n.string("study.notes.insert.selection"))
            .accessibilityIdentifier("study-note-insert-selection")

            Button { insertion.insert(StudyNoteDraftInsertion.dateTime()) } label: {
                Image(systemName: "clock").frame(width: 24, height: 24)
            }
            .disabled(insertion.isComposing)
            .help(L10n.string("study.notes.insert.time"))
            .accessibilityLabel(L10n.string("study.notes.insert.time"))
            .accessibilityIdentifier("study-note-insert-time")

            Button {
                if let value = actions.currentLocation() { insertion.insert(value) }
            } label: {
                Image(systemName: "doc.text.magnifyingglass").frame(width: 24, height: 24)
            }
            .disabled(insertion.isComposing)
            .help(L10n.string("study.notes.insert.location"))
            .accessibilityLabel(L10n.string("study.notes.insert.location"))
            .accessibilityIdentifier("study-note-insert-location")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.accent)
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Spacer()
            Button(L10n.string("취소"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button {
                onCommit(text)
            } label: {
                Label(L10n.string("적용"), systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

/// SwiftUI wrapper around the same preflighted AppKit text boundary used by
/// the direct-on-page editor.
///
/// `TextEditor` is intentionally not used here. Its Binding can shorten text
/// only after TextKit has already decoded and laid out a Paste/Services/drop
/// payload. This representable keeps native spell checking, selection, input
/// methods and Undo while enforcing the PDF FreeText budget *before* layout.
struct BoundedPlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let budget: EncodedTextBudget
    let onLengthLimitReached: () -> Void
    var insertionController: StudyNoteDraftInsertionController? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            budget: budget,
            onLengthLimitReached: onLengthLimitReached
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = PDFBoundedPlainTextView(frame: .zero)
        textView.encodedTextBudget = budget
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onLengthLimitReached = context.coordinator.reportLengthLimit

        let limited = EncodedTextLimiter.limit(text, budget: budget)
        textView.string = limited.text
        if limited.wasTruncated {
            // The model normally refuses an oversized existing annotation
            // before presenting this sheet. Keep this local guard as defense
            // in depth for previews and future call sites.
            DispatchQueue.main.async {
                context.coordinator.synchronizeFromTextView(textView)
                context.coordinator.reportLengthLimit()
            }
        }

        context.coordinator.textView = textView
        context.coordinator.insertionController = insertionController
        insertionController?.attach(textView)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            text: $text,
            isFocused: $isFocused,
            budget: budget,
            onLengthLimitReached: onLengthLimitReached
        )
        guard let textView = scrollView.documentView as? PDFBoundedPlainTextView else {
            return
        }
        textView.encodedTextBudget = budget
        textView.onLengthLimitReached = context.coordinator.reportLengthLimit
        if context.coordinator.insertionController !== insertionController {
            context.coordinator.insertionController?.detach(textView)
            context.coordinator.insertionController = insertionController
            insertionController?.attach(textView)
        }

        // Do not assign an equal String: replacing NSTextView contents during
        // marked-text composition would interrupt Korean/Japanese/Chinese IME.
        if textView.string != text {
            let limited = EncodedTextLimiter.limit(text, budget: budget)
            textView.string = limited.text
            if limited.wasTruncated {
                context.coordinator.synchronizeFromTextView(textView)
                context.coordinator.reportLengthLimit()
            }
        }

        context.coordinator.requestFocusIfNeeded()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let view = scrollView.documentView as? PDFBoundedPlainTextView {
            coordinator.insertionController?.detach(view)
        }
        coordinator.cancelFocusRequest()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: PDFBoundedPlainTextView?
        weak var insertionController: StudyNoteDraftInsertionController?
        private var lastRequestedFocus = false
        private var focusRequest = UUID()
        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        private var budget: EncodedTextBudget
        private var onLengthLimitReached: () -> Void

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            budget: EncodedTextBudget,
            onLengthLimitReached: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.budget = budget
            self.onLengthLimitReached = onLengthLimitReached
        }

        func update(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            budget: EncodedTextBudget,
            onLengthLimitReached: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.budget = budget
            self.onLengthLimitReached = onLengthLimitReached
        }

        func cancelFocusRequest() { focusRequest = UUID() }

        func requestFocusIfNeeded() {
            let requested = isFocused.wrappedValue
            guard requested != lastRequestedFocus else { return }
            lastRequestedFocus = requested
            cancelFocusRequest()
            guard requested, let textView, textView.window?.firstResponder !== textView else { return }
            let request = focusRequest
            // Only an explicit false→true request can focus the editor. PDF
            // selection publishes workspace changes too; those redraws must
            // never pull focus away from a drag on the page.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, self.focusRequest == request,
                      self.isFocused.wrappedValue, let textView, textView.window != nil else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }

        func reportLengthLimit() {
            onLengthLimitReached()
        }

        func synchronizeFromTextView(_ textView: NSTextView) {
            let limited = EncodedTextLimiter.limit(
                textView.string,
                budget: budget
            )
            if textView.string != limited.text {
                textView.string = limited.text
            }
            if text.wrappedValue != limited.text {
                text.wrappedValue = limited.text
            }
            if limited.wasTruncated {
                reportLengthLimit()
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            synchronizeFromTextView(textView)
            insertionController?.updateComposition(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            insertionController?.updateComposition(from: textView)
        }
    }
}
