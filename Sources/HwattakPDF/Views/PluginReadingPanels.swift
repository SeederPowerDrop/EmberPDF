// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

struct PluginAppearancePanel: View {
    let isAuthorized: () -> Bool
    @ObservedObject private var preferences = AppPreferences.shared
    @EmberTheme private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string("plugins.appearance.detail", defaultValue: "앱과 종이의 색상을 편안하게 조절하세요. PDF 원본에는 영향을 주지 않습니다."))
                    .font(.callout).foregroundStyle(theme.secondaryText)
                Picker(L10n.string("settings.appearance", defaultValue: "앱 테마"), selection: Binding(
                    get: { preferences.appearance },
                    set: { if isAuthorized() { preferences.appearance = $0 } }
                )) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0) } }
                // Permission revocation removes the entire host panel synchronously.
                ReadingThemeControls(preferences: preferences, compact: true, authorizeChange: isAuthorized)
            }.padding(18)
        }
    }
}

@MainActor
struct PluginRelatedDocumentsPanel: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let collection: MultiDocumentWorkspaceState
    let isAuthorized: () -> Bool
    let onOpen: (PDFRelatedDocumentResult) -> Void
    @State private var query = ""
    @State private var results: [PDFRelatedDocumentResult] = []
    @State private var task: Task<Void, Never>?
    @State private var token = UUID()
    @State private var searching = false
    @State private var hasSearched = false
    @EmberTheme private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("plugins.related.detail", defaultValue: "열린 PDF에서 공통 단어를 찾아 연결합니다. 문서마다 일부 페이지를 살펴보며, 외부로 전송하지 않습니다."))
                .font(.callout).foregroundStyle(theme.secondaryText)
            TextField(L10n.string("plugins.related.query", defaultValue: "관심 주제나 키워드"), text: $query).textFieldStyle(.roundedBorder)
                .onSubmit { start() }
            HStack {
                Button(L10n.string("plugins.related.page", defaultValue: "현재 페이지에서 주제 가져오기")) { usePage() }
                Spacer()
                Button(L10n.string(searching ? "action.cancel" : "action.search", defaultValue: searching ? "취소" : "검색")) {
                    if searching { cancel() } else { start() }
                }
            }
            if searching { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(results) { result in
                        Button {
                            guard isAuthorized(), case let .openTab(id) = result.source,
                                  collection.allTabs.contains(where: { $0.id == id }) else { return }
                            onOpen(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(result.displayName, systemImage: "doc.text").font(.headline).lineLimit(2)
                                if let match = result.matches.first {
                                    Text(L10n.format("ai.related.page", match.pageNumber)).font(.caption).foregroundStyle(theme.accent)
                                    Text(match.snippet).font(.callout).lineLimit(5)
                                    Text(match.matchedTerms.joined(separator: " · ")).font(.caption).foregroundStyle(theme.accent)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                    if hasSearched && !searching && results.isEmpty {
                        Text(L10n.string("plugins.related.empty", defaultValue: "검색한 페이지에서 관련 내용을 찾지 못했습니다. 다른 키워드로 찾아보세요."))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }.padding(16).onDisappear { cancel() }
            .onChange(of: workspace.revision) { _, _ in cancel(); results = [] }
            .accessibilityIdentifier("plugin-related-panel")
    }

    private func usePage() {
        guard isAuthorized(), workspace.allows(.copyAndPaste),
              let page = workspace.document?.page(at: workspace.currentPageIndex) else { return }
        let text = EncodedTextLimiter.limit(page.string ?? "", budget: .init(maximumCharacters: 8_000, maximumUTF8Bytes: 32_000)).text
        query = PDFLexicalRelevanceEngine.orderedTerms(in: text, limit: 12).joined(separator: " ")
    }
    private func start() {
        guard isAuthorized(), workspace.allows(.copyAndPaste) else { return }
        let bounded = String(query.prefix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bounded.isEmpty else { return }
        cancel()
        let id = UUID(); token = id
        let revision = workspace.revision
        searching = true; hasSearched = true; results = []
        task = Task { @MainActor in
            let found = await LocalRelatedPDFSearchService().search(query: bounded, workspace: collection,
                excluding: workspace.documentURL, includeRecentDocuments: false)
            guard !Task.isCancelled, id == token, workspace.revision == revision, isAuthorized() else { return }
            results = found; searching = false; task = nil
        }
    }
    private func cancel() { token = UUID(); task?.cancel(); task = nil; searching = false }
}
