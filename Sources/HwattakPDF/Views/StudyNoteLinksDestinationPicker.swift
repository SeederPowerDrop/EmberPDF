// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Observing the target directly is essential: its real page count and notes
/// arrive after lazy loading, independently of the source PDF's state.
struct StudyLinkDestinationPicker: View {
    @ObservedObject var target: PDFWorkspaceState
    let documents: MultiDocumentWorkspaceState
    let onAdd: (Int, StudyNoteItem?, String?) -> Void
    @StateObject private var catalog = StudyLinkTargetCatalog()
    @StateObject private var textSearch = StudyLinkTextSearch()
    @State private var pageDraft: StudyLinkPageDraft
    @State private var kind = DestinationKind.page
    @State private var query = ""
    @State private var selectedNoteID: ObjectIdentifier?
    @State private var selectedBookmarkID: String?
    @State private var textQuery = ""
    @State private var selectedTextResultID: UUID?
    @State private var didSubmitInvalidPage = false
    @State private var reloadGeneration = 0
    @EmberTheme private var theme

    private enum DestinationKind: String, CaseIterable {
        case page, text, note, bookmark
        var title: String {
            switch self {
            case .page: L10n.string("study.links.page", defaultValue: "페이지")
            case .text: L10n.string("study.links.search_text", defaultValue: "본문 검색")
            case .note: L10n.string("study.links.all_notes", defaultValue: "모든 메모")
            case .bookmark: L10n.string("study.links.bookmarks", defaultValue: "책갈피")
            }
        }
    }

    init(target: PDFWorkspaceState, documents: MultiDocumentWorkspaceState,
         onAdd: @escaping (Int, StudyNoteItem?, String?) -> Void) {
        self.target = target
        self.documents = documents
        self.onAdd = onAdd
        _pageDraft = State(initialValue: StudyLinkPageDraft(pageIndex: target.currentPageIndex))
    }

    private struct LoadIdentity: Equatable { let revision: UUID; let retry: Int }
    private struct SearchIdentity: Equatable { let revision: UUID; let query: String; let ready: Bool }
    private var selectedNote: StudyNoteItem? { filteredNotes.first { $0.id == selectedNoteID } }
    private var selectedBookmark: StudyLinkBookmarkTarget? { filteredBookmarks.first { $0.id == selectedBookmarkID } }
    private var filteredNotes: [StudyNoteItem] {
        query.isEmpty ? catalog.notes : catalog.notes.filter {
            $0.contents.localizedStandardContains(query) || String($0.pageIndex + 1).contains(query)
        }
    }
    private var filteredBookmarks: [StudyLinkBookmarkTarget] {
        query.isEmpty ? catalog.bookmarks : catalog.bookmarks.filter {
            $0.title.localizedStandardContains(query) || String($0.pageIndex + 1).contains(query)
        }
    }
    private var selectedPage: Int? {
        switch kind {
        case .page: pageDraft.pageIndex(pageCount: catalog.pageCount)
        case .text: textSearch.pageIndex(for: selectedTextResultID, query: textQuery, in: target)
        case .note: selectedNote?.pageIndex
        case .bookmark: selectedBookmark?.pageIndex
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if catalog.isLoading {
                ProgressView(L10n.string("study.links.target_loading", defaultValue: "PDF를 불러오는 중…"))
                    .controlSize(.small)
            }
            if let error = catalog.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                Button(L10n.string("study.links.retry", defaultValue: "다시 불러오기")) {
                    reloadGeneration += 1
                }
            }
            Button {
                guard let pageIndex = StudyLinkReadingLocation.pageIndex(in: target) else { return }
                onAdd(pageIndex, nil, nil)
            } label: {
                Label(L10n.format("study.links.connect_current", target.currentPageIndex + 1),
                      systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(StudyLinkReadingLocation.pageIndex(in: target) == nil || catalog.isLoading)
            .accessibilityIdentifier("study-link-connect-current-page")
            Picker(L10n.string("study.links.target", defaultValue: "연결할 위치"), selection: $kind) {
                ForEach(DestinationKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in query = "" }

            if kind == .page { pageEntry }
            else if kind == .text { textSearchEntries }
            else { catalogEntries }

            if catalog.isScanning {
                ProgressView(L10n.string("study.links.targets_scanning", defaultValue: "전체 메모와 책갈피를 찾는 중…"))
                    .controlSize(.small).font(.caption)
            }
            if catalog.isTruncated {
                Text(L10n.string("study.links.targets_limited", defaultValue: "항목이 너무 많아 일부만 표시합니다. 페이지 번호로도 연결할 수 있습니다."))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            Button(L10n.string("study.links.add", defaultValue: "연결 추가")) {
                guard let pageIndex = selectedPage else { didSubmitInvalidPage = true; return }
                onAdd(pageIndex, kind == .note ? selectedNote : nil,
                      kind == .bookmark ? selectedBookmark?.title : nil)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedPage == nil || catalog.isLoading)
        }
        .task(id: LoadIdentity(revision: target.revision, retry: reloadGeneration)) {
            await catalog.load(workspace: target)
        }
        .task(id: SearchIdentity(revision: target.revision, query: kind == .text ? textQuery : "",
                                ready: target.document != nil)) {
            await textSearch.search(query: kind == .text ? textQuery : "", in: target)
        }
        .onChange(of: target.revision) { _, _ in
            selectedNoteID = nil; selectedBookmarkID = nil; selectedTextResultID = nil
        }
        .onDisappear {
            textSearch.cancel()
            catalog.releaseIfEligible(isActive: documents.activeWorkspace === target)
        }
    }

    private var textSearchEntries: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.string("study.links.search_placeholder", defaultValue: "선택한 PDF 본문에서 찾기"), text: $textQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("study-link-pdf-text-search")
                .onChange(of: textQuery) { _, value in
                    selectedTextResultID = nil
                    let bounded = StudyLinkTextSearch.boundedQuery(value)
                    if value != bounded { textQuery = bounded }
                }
            Text(L10n.string("study.links.search_hint", defaultValue: "검색 결과의 페이지를 선택해 연결하세요. 텍스트와 OCR 글자가 있는 페이지를 검색합니다."))
                .font(.caption).foregroundStyle(theme.secondaryText)
            if !textSearch.results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(textSearch.results) { result in
                            textSearchRow(result)
                        }
                    }
                }
                .frame(height: 150)
                Text(L10n.format("study.links.search_pages", textSearch.results.count))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            if textSearch.status == .searching {
                ProgressView(L10n.format("study.links.search_progress", textSearch.progress.completedPages,
                                         textSearch.progress.totalPages))
                    .controlSize(.small).font(.caption)
            } else if let message = textSearchMessage {
                Text(message).font(.caption).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if textSearch.progress.isTruncated {
                Text(L10n.format("study.links.search_limited", textSearch.results.count))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var textSearchMessage: String? {
        switch textSearch.status {
        case .idle, .searching: return nil
        case .completed:
            guard textSearch.results.isEmpty else { return nil }
            if textSearch.progress.totalPages > 0,
               textSearch.textlessPageCount == textSearch.progress.totalPages {
                return L10n.string("study.links.search_no_text", defaultValue: "검색할 글자가 없습니다. 이미지 PDF는 OCR을 적용한 뒤 검색하세요.")
            }
            return L10n.string("study.links.search_empty", defaultValue: "일치하는 본문을 찾지 못했습니다.")
        case .copyRestricted:
            return L10n.string("study.links.search_copy_restricted", defaultValue: "이 PDF의 복사 권한이 제한되어 본문 미리보기를 검색할 수 없습니다.")
        case .changed:
            return L10n.string("study.links.search_changed", defaultValue: "PDF 내용이 바뀌어 검색을 갱신합니다.")
        case .unavailable:
            return L10n.string("study.links.search_unavailable", defaultValue: "검색할 PDF를 불러오지 못했습니다.")
        }
    }

    private func textSearchRow(_ result: PDFSearchResult) -> some View {
        let selected = selectedTextResultID == result.id
        return Button { selectedTextResultID = result.id } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "doc.text.magnifyingglass")
                    .foregroundStyle(selected ? theme.accent : theme.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlightedSnippet(result)).font(.caption).lineLimit(3)
                    Text(L10n.format("page.number", result.pageIndex + 1))
                        .font(.caption2).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(7)
            .background(selected ? theme.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func highlightedSnippet(_ result: PDFSearchResult) -> AttributedString {
        var text = AttributedString(result.snippet)
        for nsRange in result.snippetMatchRanges {
            guard let range = Range(nsRange, in: result.snippet),
                  let start = AttributedString.Index(range.lowerBound, within: text),
                  let end = AttributedString.Index(range.upperBound, within: text), start < end else { continue }
            text[start..<end].backgroundColor = theme.warning.opacity(0.38)
        }
        return text
    }

    private var pageEntry: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(L10n.string("study.links.page", defaultValue: "페이지"))
                TextField("", text: $pageDraft.text)
                    .textFieldStyle(.roundedBorder).frame(width: 72)
                    .accessibilityLabel(L10n.string("study.links.page", defaultValue: "페이지"))
                    .accessibilityIdentifier("study-link-target-page")
                    .onSubmit { didSubmitInvalidPage = pageDraft.pageIndex(pageCount: catalog.pageCount) == nil }
                    .onChange(of: pageDraft.text) { _, _ in
                        if pageDraft.pageIndex(pageCount: catalog.pageCount) != nil { didSubmitInvalidPage = false }
                    }
                Stepper {
                    Text("")
                } onIncrement: { stepPage(1) } onDecrement: { stepPage(-1) }
                    .labelsHidden().disabled(catalog.pageCount == 0)
                Text(L10n.format("study.links.total_pages", catalog.pageCount))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            Text(L10n.format("study.links.current_page", target.currentPageIndex + 1))
                .font(.caption).foregroundStyle(theme.secondaryText)
            if didSubmitInvalidPage || (!pageDraft.text.isEmpty && catalog.pageCount > 0
                                         && pageDraft.pageIndex(pageCount: catalog.pageCount) == nil) {
                Text(L10n.format("study.links.page_range", max(1, catalog.pageCount)))
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var catalogEntries: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.string("study.links.filter_targets", defaultValue: "메모·책갈피 검색"), text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, value in
                    let bounded = String(decoding: value.utf16.prefix(256), as: UTF16.self)
                    if value != bounded { query = bounded }
                }
            if kind == .note {
                targetList(isEmpty: filteredNotes.isEmpty) {
                    ForEach(filteredNotes) { note in
                        targetRow(title: note.contents.isEmpty ? L10n.string("study.notes.untitled")
                                  : String(note.contents.prefix(100)), page: note.pageIndex,
                                  selected: selectedNoteID == note.id, symbol: "note.text") {
                            selectedNoteID = note.id
                        }
                    }
                }
            } else {
                Text(L10n.string("study.links.bookmark_hint", defaultValue: "PDF 목차·책갈피가 가리키는 페이지에 연결합니다."))
                    .font(.caption).foregroundStyle(theme.secondaryText)
                targetList(isEmpty: filteredBookmarks.isEmpty) {
                    ForEach(filteredBookmarks) { bookmark in
                        targetRow(title: bookmark.title, page: bookmark.pageIndex,
                                  selected: selectedBookmarkID == bookmark.id, symbol: "bookmark") {
                            selectedBookmarkID = bookmark.id
                        }
                    }
                }
            }
        }
    }

    private func targetList<Content: View>(isEmpty: Bool, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if isEmpty {
                Text(L10n.string("study.links.targets_empty", defaultValue: "선택할 항목이 없습니다."))
                    .font(.caption).foregroundStyle(theme.secondaryText).padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, content: content)
                }
                .frame(height: 150)
            }
        }
    }

    private func targetRow(title: String, page: Int, selected: Bool, symbol: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                    .foregroundStyle(selected ? theme.accent : theme.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.caption).lineLimit(2)
                    Text(L10n.format("page.number", page + 1)).font(.caption2).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(7)
            .background(selected ? theme.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stepPage(_ offset: Int) {
        let current = pageDraft.pageIndex(pageCount: catalog.pageCount) ?? target.currentPageIndex
        let next = min(max(0, current + offset), max(0, catalog.pageCount - 1))
        pageDraft = StudyLinkPageDraft(pageIndex: next)
        didSubmitInvalidPage = false
    }
}
