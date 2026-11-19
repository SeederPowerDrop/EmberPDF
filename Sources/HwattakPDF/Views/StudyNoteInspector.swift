// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import SwiftUI

/// Draft controls publish only on Apply, keeping PDFKit and page thumbnails
/// idle while the user adjusts sliders or types dimensions.
struct StudyNoteInspector: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let note: StudyNoteItem
    @State private var draft: PDFStudyNoteStyle
    @State private var currentNote: StudyNoteItem
    @State private var colorTarget = ColorTarget.background
    @State private var applyFailed = false
    @EmberTheme private var theme

    private enum ColorTarget: String, CaseIterable {
        case background, foreground
        var title: String {
            switch self {
            case .background: L10n.string("study.note.style.background", defaultValue: "배경 색상")
            case .foreground: L10n.string("study.note.style.foreground", defaultValue: "글자 색상")
            }
        }
    }

    init(workspace: PDFWorkspaceState, note: StudyNoteItem) {
        self.workspace = workspace
        self.note = note
        _draft = State(initialValue: PDFStudyNoteStyle(annotation: note.annotation))
        _currentNote = State(initialValue: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("study.note.style.title", defaultValue: "메모 모양"))
                .font(.headline)
            StudyNoteStylePreview(style: draft, contents: currentNote.contents)
                .frame(height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                .accessibilityLabel(L10n.string("study.note.style.preview", defaultValue: "메모 색상과 불투명도 미리보기"))
                .accessibilityIdentifier("study-note-style-preview")
            // Keep a single settings subtree. Opening a separate system color
            // panel can dismiss a transient popover and discard its draft.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    opacityControl
                    Picker(L10n.string("study.note.style.color_target", defaultValue: "색상을 바꿀 부분"), selection: $colorTarget) {
                        ForEach(ColorTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("study-note-color-target")
                    InlineColorPalette(selection: selectedColor, title: colorTarget.title)
                        .id(colorTarget)
                    Divider()
                    dimensions
                    Text(L10n.string("study.note.style.units", defaultValue: "크기와 위치 단위는 pt이며, 세로 위치는 페이지 아래에서부터입니다."))
                        .font(.caption).foregroundStyle(theme.secondaryText)
                    Button {
                        if workspace.selectStudyNoteForLayout(currentNote) {
                            draft.bounds = currentNote.annotation.bounds
                        }
                    } label: {
                        Label(L10n.string("study.note.style.move_resize", defaultValue: "페이지에서 이동·크기 조절"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(!currentNote.annotation.shouldDisplay)
                    .accessibilityIdentifier("study-note-move-resize")
                }
                .padding(.trailing, 3)
            }
            .frame(height: 320)
            Divider()
            if applyFailed {
                Text(L10n.string("study.note.style.apply_failed", defaultValue: "메모를 변경할 수 없습니다. 메모를 다시 열어 확인해 주세요."))
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(L10n.string("study.note.style.apply_hint", defaultValue: "미리보기를 확인한 뒤 적용을 눌러 주세요."))
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.string("적용")) {
                    if let updated = workspace.applyStudyNoteStyle(draft, to: currentNote) {
                        currentNote = updated
                        draft = PDFStudyNoteStyle(annotation: updated.annotation)
                        applyFailed = false
                    } else { applyFailed = true }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("study-note-style-apply")
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 360)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
    }

    private var selectedColor: Binding<NSColor> {
        switch colorTarget {
        case .background: $draft.background
        case .foreground: $draft.foreground
        }
    }

    private var opacityControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string("study.note.style.opacity", defaultValue: "배경 불투명도"))
                Spacer()
                Text("\(Int((draft.backgroundOpacity * 100).rounded()))%").monospacedDigit()
            }
            Slider(value: $draft.backgroundOpacity, in: 0...1, step: 0.05)
                .accessibilityLabel(L10n.string("study.note.style.opacity", defaultValue: "배경 불투명도"))
                .accessibilityValue("\(Int((draft.backgroundOpacity * 100).rounded()))%")
                .accessibilityIdentifier("study-note-opacity")
        }
    }

    private var dimensions: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                numberField("study.note.style.width", fallback: "너비", value: $draft.bounds.size.width)
                numberField("study.note.style.height", fallback: "높이", value: $draft.bounds.size.height)
            }
            GridRow {
                numberField("study.note.style.x", fallback: "가로 위치", value: $draft.bounds.origin.x)
                numberField("study.note.style.y", fallback: "세로 위치", value: $draft.bounds.origin.y)
            }
            GridRow {
                numberField("study.note.style.font_size", fallback: "글자 크기", value: $draft.fontSize)
            }
        }
    }

    private func numberField(_ key: String, fallback: String, value: Binding<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(key, defaultValue: fallback)).font(.caption)
            TextField("", value: Binding<Double>(get: { Double(value.wrappedValue) },
                                                set: { value.wrappedValue = CGFloat($0) }),
                      format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.string(key, defaultValue: fallback))
                .accessibilityIdentifier(key)
        }
    }
}

/// The PDF note renderer is also the preview renderer, so a color/alpha change
/// has immediate visible feedback without touching the live PDF or its history.
private struct StudyNoteStylePreview: NSViewRepresentable {
    let style: PDFStudyNoteStyle
    let contents: String
    func makeNSView(context: Context) -> StudyNoteStyleSampleView { StudyNoteStyleSampleView() }
    func updateNSView(_ view: StudyNoteStyleSampleView, context: Context) {
        view.style = style
        view.contents = String(contents.prefix(1_000))
        view.needsDisplay = true
    }
}

private final class StudyNoteStyleSampleView: NSView {
    var style: PDFStudyNoteStyle?
    var contents = ""
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, var style else { return }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        context.setFillColor(NSColor(srgbRed: 0.78, green: 0.8, blue: 0.83, alpha: 1).cgColor)
        for x in stride(from: CGFloat(0), to: bounds.width, by: 12) {
            for y in stride(from: CGFloat(0), to: bounds.height, by: 12)
                where (Int(x / 12) + Int(y / 12)).isMultiple(of: 2) {
                context.fill(CGRect(x: x, y: y, width: 12, height: 12))
            }
        }
        style.bounds = bounds.insetBy(dx: 10, dy: 10)
        guard let style = style.constrained(to: bounds) else { return }
        let note = PDFStudyNoteAnnotation(bounds: style.bounds,
            contents: contents.isEmpty ? L10n.string("study.notes.untitled") : contents,
            font: .systemFont(ofSize: style.fontSize), background: style.background, foreground: style.foreground)
        style.apply(to: note)
        note.draw(with: .cropBox, in: context)
    }
}
