// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// A deliberately native Markdown reader. HTML, links and images are text:
/// there is no web view, network request, image decoder or URL-opening action.
enum PluginNotesPreview {
    static let maximumPreviewCharacters = 80_000
    static let maximumPreviewLines = 1_200

    enum Kind: Equatable { case heading(Int), body, quote, code }
    struct Block: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }

    static func blocks(_ text: String) -> [Block] {
        let lines = text.prefix(maximumPreviewCharacters).components(separatedBy: .newlines)
        var inCode = false
        return lines.prefix(maximumPreviewLines).enumerated().map { index, line in
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                return Block(id: index, kind: .code, text: line)
            }
            if inCode { return Block(id: index, kind: .code, text: line) }
            let heading = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(heading), line.dropFirst(heading).hasPrefix(" ") {
                return Block(id: index, kind: .heading(heading), text: String(line.dropFirst(heading + 1)))
            }
            if line.hasPrefix("> ") { return Block(id: index, kind: .quote, text: String(line.dropFirst(2))) }
            return Block(id: index, kind: .body, text: line)
        }
    }

    static func inline(_ text: String) -> AttributedString {
        // Rendering text with inline Markdown offers emphasis without handing
        // any URL to SwiftUI's OpenURLAction. Raw HTML stays inert text.
        let inert = text.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
        var value = (try? AttributedString(markdown: inert, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let ranges = value.runs.map(\.range)
        for range in ranges { value[range].link = nil }
        return value
    }

    static func isTruncated(_ text: String) -> Bool {
        text.count > maximumPreviewCharacters || text.prefix(maximumPreviewCharacters).split(separator: "\n", omittingEmptySubsequences: false).count > maximumPreviewLines
    }
}

struct PluginNotesPanel: View {
    @ObservedObject var session: PluginNotesSession
    /// The host rechecks plugin grants and PDF copy permission for each click.
    let sourceProvider: () -> PluginNoteSource?
    let isAuthorized: () -> Bool

    @State private var showsPreview = false
    @EmberTheme private var theme

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(session.displayName + (session.isModified ? " •" : ""))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Menu {
                        Button(L10n.string("plugins.notes.new", defaultValue: "새 노트")) { session.newNote(authorization: isAuthorized) }
                        Button(L10n.string("plugins.notes.open", defaultValue: "Markdown 열기")) { session.chooseAndOpen(authorization: isAuthorized) }
                        Button(L10n.string("plugins.notes.save_as", defaultValue: "다른 이름으로 저장")) { _ = session.save(asCopy: true, authorization: isAuthorized) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 25)
                    Button(L10n.string("action.save", defaultValue: "저장")) { _ = session.save(authorization: isAuthorized) }
                        .disabled(!session.isModified && session.fileURL != nil)
                        .accessibilityIdentifier("plugin-notes-save")
                }
                Picker(L10n.string("plugins.notes.mode", defaultValue: "노트 보기"), selection: $showsPreview) {
                    Text(L10n.string("plugins.notes.edit", defaultValue: "작성")).tag(false)
                    Text(L10n.string("plugins.notes.preview", defaultValue: "미리보기")).tag(true)
                }.pickerStyle(.segmented)
                HStack(spacing: 8) {
                    Button { authorized { if let source = sourceProvider() { session.append(source.citation) } } } label: {
                        Label(L10n.string("plugins.notes.insert_source", defaultValue: "페이지 출처"), systemImage: "doc.badge.plus")
                    }.accessibilityIdentifier("plugin-notes-insert-source")
                    Button { authorized { if let quotation = sourceProvider()?.quotation { session.append(quotation) } } } label: {
                        Label(L10n.string("plugins.notes.insert_selection", defaultValue: "선택한 글"), systemImage: "text.quote")
                    }.accessibilityIdentifier("plugin-notes-insert-selection")
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(theme.panel)
            Divider().overlay(theme.border)
            if showsPreview {
                preview
            } else {
                TextEditor(text: Binding(get: { session.text }, set: { value in authorized { session.updateText(value) } }))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(theme.canvas)
                    .accessibilityLabel(L10n.string("plugins.notes.editor", defaultValue: "Markdown 노트 편집기"))
                    .accessibilityIdentifier("plugin-notes-editor")
            }
            Divider().overlay(theme.border)
            VStack(alignment: .leading, spacing: 5) {
                if let message = session.message {
                    Text(message).font(.caption).foregroundStyle(theme.accent)
                }
                Text(L10n.string("plugins.notes.local_only", defaultValue: "이 기기에서 작성합니다. 링크·이미지·HTML은 자동으로 열지 않습니다."))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .foregroundStyle(theme.primaryText)
        .background(theme.canvas)
        .accessibilityIdentifier("plugin-notes-panel")
    }

    private var preview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                if session.text.isEmpty {
                    Text(L10n.string("plugins.notes.empty", defaultValue: "생각을 적고, PDF에서 고른 문장을 함께 모아보세요."))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.vertical, 20)
                }
                ForEach(PluginNotesPreview.blocks(session.text)) { block in
                    blockView(block).frame(maxWidth: .infinity, alignment: .leading)
                }
                if PluginNotesPreview.isTruncated(session.text) {
                    Text(L10n.string("plugins.notes.preview_limit", defaultValue: "긴 노트의 앞부분을 표시합니다. 작성 화면과 저장에는 전체 내용이 유지됩니다."))
                        .font(.caption).foregroundStyle(theme.secondaryText).padding(.top, 12)
                }
            }
            .textSelection(.enabled)
            .padding(16)
        }
        .accessibilityIdentifier("plugin-notes-preview")
    }

    @ViewBuilder
    private func blockView(_ block: PluginNotesPreview.Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(PluginNotesPreview.inline(block.text)).font(.system(size: max(14, 25 - CGFloat(level) * 2), weight: .semibold)).padding(.top, 8)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(0.6)).frame(width: 3)
                Text(PluginNotesPreview.inline(block.text)).foregroundStyle(theme.secondaryText)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
        case .code:
            Text(verbatim: block.text.isEmpty ? " " : block.text).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 7).background(theme.panel)
        case .body:
            Text(PluginNotesPreview.inline(block.text.isEmpty ? " " : block.text)).font(.system(size: 13))
        }
    }

    private func authorized(_ operation: () -> Void) {
        guard isAuthorized() else { return }
        operation()
    }
}
