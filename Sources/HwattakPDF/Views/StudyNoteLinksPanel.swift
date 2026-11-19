// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Embed in the study sidebar for a page, or in a note row's popover for a
/// note. The shared store makes links immediately visible from either end.
struct StudyNoteLinksPanel: View {
    @ObservedObject var workspace: PDFWorkspaceState
    @ObservedObject var documents: MultiDocumentWorkspaceState
    var note: StudyNoteItem? = nil
    @ObservedObject private var store = StudyLinkStore.shared
    @State private var isAdding = false
    @State private var targetTabID: UUID?
    @State private var errorMessage: String?
    @State private var isOpening = false
    @State private var panelHeight: CGFloat = 140
    @EmberTheme private var theme

    private var source: StudyLinkEndpoint? { store.endpoint(workspace: workspace, note: note) }
    private var connections: [StudyLink] { store.connections(to: source) }
    private var targets: [PDFTabSession] {
        documents.allTabs.filter { $0.workspace.hasOpenDocument && $0.workspace.documentURL != nil }
    }
    private var target: PDFWorkspaceState? { targets.first { $0.id == targetTabID }?.workspace }
    private var sourceIdentity: String {
        "\(workspace.documentURL?.path ?? ""):\(note?.pageIndex ?? workspace.currentPageIndex)"
    }

    var body: some View {
        Group {
            if note != nil {
                // One picker instance keeps its page/filter/selection state
                // when the growing list crosses the popup's height limit.
                ScrollView {
                    panel.fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: StudyLinkPanelHeightKey.self,
                                                       value: geometry.size.height)
                            }
                        }
                }
                .frame(height: min(560, max(140, panelHeight)))
                .onPreferenceChange(StudyLinkPanelHeightKey.self) { measured in
                    guard measured.isFinite, measured > 0,
                          abs(measured - panelHeight) > 0.5 else { return }
                    panelHeight = measured
                }
            } else { panel }
        }
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .accessibilityIdentifier(note == nil ? "study-page-links" : "study-note-links")
        .task(id: sourceIdentity) {
            if let url = workspace.documentURL { store.recognizeOpenedDocument(url) }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.string("study.links.title", defaultValue: "연결"), systemImage: "link")
                    .font(.headline)
                Spacer()
                Button {
                    isAdding.toggle()
                    if isAdding { prepareTarget() }
                } label: { Image(systemName: isAdding ? "minus.circle" : "plus.circle") }
                    .buttonStyle(.plain)
                    .disabled(workspace.documentURL == nil || store.loadError != nil)
                    .help(L10n.string("study.links.add", defaultValue: "연결 추가"))
                    .accessibilityLabel(L10n.string("study.links.add", defaultValue: "연결 추가"))
            }

            if connections.isEmpty, !isAdding {
                Text(L10n.string("study.links.empty", defaultValue: "다른 PDF 페이지·메모·책갈피와 연결하세요."))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            ForEach(connections) { link in
                if let source, let destination = link.destination(from: source) {
                    connectionRow(link, destination: destination)
                }
            }
            if isAdding { creator }
            if workspace.documentURL == nil {
                Text(L10n.string("study.links.save_first", defaultValue: "연결할 PDF를 먼저 파일로 저장하세요."))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            if let errorMessage = errorMessage ?? store.loadError?.localizedDescription {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.string("study.links.local_hint", defaultValue: "연결 목록은 이 Mac의 EmberPDF에 저장되며 다른 앱에는 포함되지 않습니다. 메모 연결을 유지하려면 식별자가 추가된 PDF도 저장하세요."))
                .font(.caption2).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectionRow(_ link: StudyLink, destination: StudyLinkEndpoint) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                open(destination)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.document(id: destination.documentID)?.displayName ?? "PDF")
                        .font(.callout).lineLimit(2)
                    if let title = destination.bookmarkTitle {
                        Label(title, systemImage: "bookmark").font(.caption).lineLimit(2)
                    }
                    Label(L10n.format("page.number", destination.pageIndex + 1),
                          systemImage: destination.note == nil ? "doc.text" : "note.text")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(isOpening)
            .help(L10n.string("study.links.open", defaultValue: "연결된 위치 열기"))
            Menu {
                Button(L10n.string("study.links.reconnect", defaultValue: "파일 다시 연결…")) {
                    reconnect(destination)
                }
                Button(L10n.string("study.links.remove", defaultValue: "연결 삭제"), role: .destructive) {
                    do { try store.remove(link); errorMessage = nil }
                    catch { errorMessage = error.localizedDescription }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(isOpening)
        }
        .padding(8)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    private var creator: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("study.links.choose_pdf", defaultValue: "연결할 PDF 선택"))
                .font(.caption.weight(.semibold))
            Picker(L10n.string("study.links.pdf", defaultValue: "열린 PDF"), selection: $targetTabID) {
                ForEach(targets) { session in Text(session.displayName).tag(Optional(session.id)) }
            }
            .labelsHidden()

            if let target {
                StudyLinkDestinationPicker(target: target, documents: documents) { pageIndex, note, title in
                    add(target: target, pageIndex: pageIndex, targetNote: note, bookmarkTitle: title)
                }
                .id(targetTabID)
            } else {
                Text(L10n.string("study.links.open_target", defaultValue: "연결할 PDF를 먼저 앱에서 열어주세요."))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
        }
        .padding(10)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    private func prepareTarget() {
        errorMessage = nil
        if !targets.contains(where: { $0.id == targetTabID }) {
            targetTabID = targets.first(where: { $0.workspace !== workspace })?.id ?? targets.first?.id
        }
    }

    private func add(target: PDFWorkspaceState, pageIndex: Int, targetNote: StudyNoteItem?, bookmarkTitle: String?) {
        do {
            try store.add(from: workspace, sourceNote: note, to: target,
                          targetPage: pageIndex, targetNote: targetNote, targetBookmarkTitle: bookmarkTitle)
            isAdding = false; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func open(_ endpoint: StudyLinkEndpoint) {
        isOpening = true; errorMessage = nil
        Task { @MainActor in
            defer { isOpening = false }
            do { _ = try await store.open(endpoint, in: documents) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func reconnect(_ endpoint: StudyLinkEndpoint) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = L10n.string("study.links.reconnect", defaultValue: "파일 다시 연결…")
        panel.message = store.document(id: endpoint.documentID)?.displayName ?? "PDF"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isOpening = true; errorMessage = nil
            Task { @MainActor in
                defer { isOpening = false }
                do { _ = try await store.reconnect(endpoint, authorizedURL: url, in: documents) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct StudyLinkPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
