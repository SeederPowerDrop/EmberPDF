// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Browsing scopes does not activate tabs. A card/result explicitly opens its
/// owning workspace and tab only when selected.
@MainActor
struct PDFDocumentGalleryView: View {
    @ObservedObject var workspace: MultiDocumentWorkspaceState
    let onSelect: (UUID, UUID, PDFSearchResult?) -> Void
    let onClose: () -> Void

    @EmberTheme private var theme
    @StateObject private var search = PDFGallerySearchController()
    @State private var query = ""
    @State private var scopeWorkspaceID: UUID?
    @State private var scopeGroup = "all"
    @State private var searchAttempt = 0

    init(workspace: MultiDocumentWorkspaceState,
         onSelect: @escaping (UUID, UUID, PDFSearchResult?) -> Void,
         onClose: @escaping () -> Void) {
        self.workspace = workspace
        self.onSelect = onSelect
        self.onClose = onClose
        _scopeWorkspaceID = State(initialValue: workspace.activeWorkspaceID)
    }

    private var allDocuments: [PDFGalleryDocument] {
        workspace.workspaces.flatMap { record in
            record.tabs.filter { $0.workspace.hasOpenDocument }.map { session in
                PDFGalleryDocument(workspaceID: record.id, workspaceTitle: record.title,
                    session: session, groupTitle: record.tabGroups.first { $0.tabIDs.contains(session.id) }?.title)
            }
        }
    }
    private var workspaceDocuments: [PDFGalleryDocument] {
        allDocuments.filter { scopeWorkspaceID == nil || $0.workspaceID == scopeWorkspaceID }
    }
    private var groups: [PDFTabGroup] {
        workspace.workspaces.first { $0.id == scopeWorkspaceID }?.tabGroups ?? []
    }
    private var documents: [PDFGalleryDocument] {
        workspaceDocuments.filter { item in
            if scopeGroup == "ungrouped" { return item.groupTitle == nil }
            guard let group = groups.first(where: { $0.id.uuidString == scopeGroup }) else { return true }
            return group.tabIDs.contains(item.id)
        }
    }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }
    private var results: [PDFGalleryDocumentSearchResult] {
        guard search.query == trimmedQuery else { return [] }
        let ids = Set(documents.map(\.id))
        return search.documentResults.filter { $0.isMatch && ids.contains($0.id) }
    }
    private var searchIdentity: String {
        ([trimmedQuery, String(searchAttempt)] + documents.map {
            "\($0.id)-\($0.session.workspace.revision)-\($0.session.workspace.documentURL?.absoluteString ?? "")-\($0.session.workspace.document == nil)"
        }).joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isSearching { searchStatus }
            if documents.isEmpty {
                emptyState(title: L10n.string("gallery.empty"))
            } else if isSearching {
                searchContent
            } else {
                documentGrid
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .emberTint()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("document-gallery")
        .task(id: searchIdentity) { await search.search(query: trimmedQuery, documents: documents) }
        .onDisappear { search.cancel() }
        .onChange(of: workspace.workspaces.map(\.id)) { _, ids in
            if let id = scopeWorkspaceID, !ids.contains(id) {
                scopeWorkspaceID = workspace.activeWorkspaceID
                scopeGroup = "all"
            }
        }
        .onChange(of: workspaceDocuments.map(\.id)) { _, _ in
            if scopeGroup != "all", scopeGroup != "ungrouped",
               !groups.contains(where: { $0.id.uuidString == scopeGroup }) { scopeGroup = "all" }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 46, height: 46)
                    .background(theme.selectionFill, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string("gallery.title")).font(.system(size: 23, weight: .semibold))
                    Text(L10n.string("gallery.subtitle")).font(.callout).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                }
                .buttonStyle(EmberToolbarButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help(L10n.string("gallery.close"))
                .accessibilityLabel(L10n.string("gallery.close"))
                .accessibilityIdentifier("document-gallery-close")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    scopeControls
                    Spacer(minLength: 0)
                    searchField.frame(width: 330)
                }
                VStack(alignment: .leading, spacing: 12) {
                    scopeControls
                    searchField
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .background(theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private var scopeControls: some View {
        HStack(spacing: 12) {
            Label {
                Picker(L10n.string("gallery.workspace_scope"), selection: Binding(
                    get: { scopeWorkspaceID }, set: { scopeWorkspaceID = $0; scopeGroup = "all" }
                )) {
                    Text(L10n.string("gallery.all_workspaces")).tag(Optional<UUID>.none)
                    ForEach(workspace.workspaces) { record in Text(record.title).tag(Optional(record.id)) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 190)
                .accessibilityIdentifier("gallery-workspace-picker")
            } icon: { Image(systemName: "square.3.layers.3d").foregroundStyle(theme.accent) }
            if !groups.isEmpty {
                groupScopes
            }
            Text(L10n.format("gallery.count", documents.count))
                .font(.callout).foregroundStyle(theme.secondaryText).fixedSize()
        }
    }

    /// Keep group filters beside the workspace. Extra group names scroll in
    /// this row instead of increasing the header height or shrinking search.
    private var groupScopes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                groupChip(L10n.string("gallery.all_groups"), id: "all", icon: "square.grid.2x2")
                ForEach(groups) { group in
                    groupChip(group.title, id: group.id.uuidString, icon: "folder")
                }
                groupChip(L10n.string("gallery.ungrouped"), id: "ungrouped", icon: "doc")
            }
            .padding(.horizontal, 1)
        }
        .frame(minWidth: 300, maxWidth: .infinity)
        .frame(height: 34)
        .accessibilityLabel(L10n.string("gallery.group_scope"))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.accent)
            TextField(L10n.string("gallery.search"), text: $query)
                .textFieldStyle(.plain).accessibilityIdentifier("document-gallery-search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
                    .help(L10n.string("gallery.search.clear"))
                    .accessibilityLabel(L10n.string("gallery.search.clear"))
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1) }
    }

    private func groupChip(_ title: String, id: String, icon: String) -> some View {
        Button { scopeGroup = id } label: {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(scopeGroup == id ? theme.accent : theme.secondaryText)
                .background(scopeGroup == id ? theme.selectionFill : theme.card, in: Capsule())
                .overlay { Capsule().stroke(scopeGroup == id ? theme.selectionBorder : theme.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scopeGroup == id ? .isSelected : [])
        .accessibilityIdentifier("gallery-group-\(id)")
    }

    private var documentGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 20)], spacing: 22) {
                ForEach(documents) { item in
                    PDFDocumentGalleryCard(workspace: item.session.workspace, title: item.session.displayName,
                        isCurrent: item.workspaceID == workspace.activeWorkspaceID && item.id == workspace.activeTabID,
                        action: { onSelect(item.workspaceID, item.id, nil) })
                    .overlay(alignment: .topLeading) {
                        Text(item.groupTitle.map { item.workspaceTitle + " · " + $0 } ?? item.workspaceTitle)
                            .font(.system(size: 10, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(theme.panel, in: Capsule()).padding(10).allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("document-gallery-card-\(item.id)")
                }
            }
            .padding(28)
        }
        .accessibilityIdentifier("document-gallery-grid")
    }

    private var searchStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                if search.progress.phase == .searching {
                    ProgressView().controlSize(.small)
                    Text(L10n.format("gallery.search.progress", search.progress.scannedDocuments,
                                    search.progress.totalDocuments, search.progress.scannedPages))
                    Spacer()
                    Button(L10n.string("gallery.search.stop")) { search.cancel() }
                } else {
                    Text(L10n.format("gallery.search.results", results.count, results.reduce(0) { $0 + $1.matches.count }))
                        .foregroundStyle(theme.accent)
                    Spacer()
                    Button(L10n.string("gallery.search.retry")) { searchAttempt += 1 }
                }
            }
            if search.progress.phase == .cancelled { Text(L10n.string("gallery.search.cancelled")) }
            if search.progress.isTruncated { Text(L10n.string("gallery.search.limited")) }
            if search.progress.skippedDocumentCount > 0 {
                Text(L10n.format("gallery.search.unreadable", search.progress.skippedDocumentCount))
                    .help(L10n.string("gallery.search.unreadable_detail"))
            }
        }
        .font(.caption).foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(theme.sidebar.opacity(0.7))
        .accessibilityIdentifier("gallery-search-status")
    }

    @ViewBuilder private var searchContent: some View {
        if results.isEmpty {
            if search.progress.phase == .searching || search.query != trimmedQuery {
                emptyState(title: L10n.string("gallery.search.waiting"))
            } else {
                emptyState(title: L10n.string("gallery.search.no_results"),
                           detail: L10n.string("gallery.search.no_results_help"))
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: 20)], spacing: 20) {
                    ForEach(results) { result in
                        PDFGallerySearchCard(result: result) { hit in
                            onSelect(result.document.workspaceID, result.document.id, hit)
                        }
                    }
                }
                .padding(28)
            }
            .accessibilityIdentifier("gallery-search-results")
        }
    }

    private var footer: some View {
        HStack {
            Text(L10n.string(isSearching ? "gallery.search.local" : "gallery.shortcut_hint"))
            Spacer()
            Text("⌘⇧G").monospaced()
        }
        .font(.caption).foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 28).padding(.vertical, 12).background(theme.sidebar)
    }

    private func emptyState(title: String, detail: String? = nil) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 32, weight: .light))
            Text(title).font(.callout)
            if let detail { Text(detail).font(.caption).multilineTextAlignment(.center) }
        }
        .foregroundStyle(theme.secondaryText)
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct PDFGallerySearchCard: View {
    let result: PDFGalleryDocumentSearchResult
    let onOpen: (PDFSearchResult?) -> Void
    @EmberTheme private var theme
    @State private var preview: PDFDocumentGalleryPreview?
    @State private var hoveredHit: UUID?
    @State private var isExpanded = false

    private var highlightedHit: PDFSearchResult? {
        result.matches.first { $0.id == hoveredHit } ?? result.matches.first
    }
    private var visibleHits: [PDFSearchResult] { isExpanded ? result.matches : Array(result.matches.prefix(3)) }
    private var identity: String {
        "\(result.id)-\(result.documentRevision)-\(highlightedHit?.id.uuidString ?? "filename")-\(result.document.session.workspace.document == nil)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { onOpen(result.matches.first) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.document.session.displayName)
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        .foregroundStyle(theme.primaryText)
                    Label(result.document.groupTitle.map { result.document.workspaceTitle + " · " + $0 }
                            ?? result.document.workspaceTitle, systemImage: "square.3.layers.3d")
                        .font(.caption).lineLimit(1).foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(alignment: .top, spacing: 16) {
                Button { onOpen(highlightedHit) } label: { pagePreview }
                    .buttonStyle(.plain).help(L10n.string("gallery.search.open_result"))
                    .accessibilityLabel(result.document.session.displayName)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        if !result.matches.isEmpty {
                            Text(L10n.format("gallery.search.content_count", result.matches.count))
                                .foregroundStyle(theme.accent)
                        } else if result.filenameMatched {
                            Text(L10n.string("gallery.search.filename_only")).foregroundStyle(theme.accent)
                        }
                        if result.isTruncated { Text("+").foregroundStyle(theme.secondaryText) }
                    }.font(.caption.weight(.medium))
                    ForEach(visibleHits) { hit in
                        Button { onOpen(hit) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(L10n.format("gallery.search.page", hit.pageIndex + 1)).font(.caption.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                                }.foregroundStyle(theme.accent)
                                Text(highlightedSnippet(hit)).font(.system(size: 12)).lineSpacing(3).lineLimit(3)
                                    .multilineTextAlignment(.leading).foregroundStyle(theme.primaryText)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(hoveredHit == hit.id ? theme.selectionFill : theme.canvas.opacity(0.55),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { hoveredHit = hit.id } }
                        .help(L10n.string("gallery.search.open_result"))
                        .accessibilityIdentifier("gallery-search-hit-\(result.id)-\(hit.pageIndex)-\(hit.sourceRange.location)")
                    }
                    if result.matches.count > 3 {
                        Button(isExpanded ? L10n.string("gallery.search.less") :
                                L10n.format("gallery.search.more", result.matches.count - 3)) { isExpanded.toggle() }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(theme.accent)
                    }
                    if result.status.isSkipped {
                        Text(L10n.string(result.status == .changed ? "gallery.search.changed" : "gallery.search.unavailable"))
                            .font(.caption).foregroundStyle(theme.secondaryText)
                    } else if result.matches.isEmpty && result.status == .searching {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1) }
        .task(id: identity) {
            preview = nil
            let value = await PDFDocumentGalleryPreviewService.shared.preview(
                for: result.document.session.workspace, pageIndex: highlightedHit?.pageIndex,
                highlight: highlightedHit, width: 320)
            guard !Task.isCancelled else { return }
            preview = value
        }
        .onDisappear { preview = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gallery-search-document-\(result.id)")
    }

    private var pagePreview: some View {
        VStack(spacing: 8) {
            ZStack {
                if let preview {
                    Image(nsImage: preview.image).resizable().interpolation(.high).scaledToFit()
                        .pdfReadingAppearance().shadow(color: theme.elevatedShadow, radius: 3, y: 2)
                } else {
                    Image(systemName: "doc.text").font(.system(size: 25, weight: .light)).foregroundStyle(theme.secondaryText)
                }
            }
            .frame(width: 132, height: 178)
            if let hit = highlightedHit {
                Text(L10n.format("gallery.search.page", hit.pageIndex + 1))
                    .font(.caption.monospacedDigit()).foregroundStyle(theme.accent)
            }
        }
        .accessibilityHidden(true)
    }

    private func highlightedSnippet(_ hit: PDFSearchResult) -> AttributedString {
        var attributed = AttributedString(hit.snippet)
        for range in hit.snippetMatchRanges {
            guard let stringRange = Range(range, in: hit.snippet),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed), lower < upper else { continue }
            attributed[lower..<upper].backgroundColor = theme.accent.opacity(0.22)
            attributed[lower..<upper].foregroundColor = theme.primaryText
            attributed[lower..<upper].font = .system(size: 12, weight: .semibold)
        }
        return attributed
    }
}
@MainActor
private struct PDFDocumentGalleryCard: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let title: String
    let isCurrent: Bool
    let action: () -> Void

    @EmberTheme private var theme
    @State private var preview: PDFDocumentGalleryPreview?
    @State private var isLoading = true
    @State private var isHovered = false

    private var previewIdentity: String {
        "\(workspace.revision)-\(workspace.currentPageIndex)-\(workspace.document == nil)"
    }
    private var pageLabel: String {
        L10n.format("gallery.current_page", workspace.currentPageIndex + 1, workspace.pageCount)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                previewArea
                    .frame(maxWidth: .infinity)
                    .frame(height: 270)
                    .padding(14)
                    .background(theme.canvas.opacity(0.7))
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 34, alignment: .topLeading)
                        if workspace.isDirty {
                            Circle().fill(theme.accent).frame(width: 6, height: 6)
                                .padding(.top, 5)
                                .help(L10n.string("gallery.modified"))
                        }
                    }
                    HStack {
                        Text(pageLabel).monospacedDigit()
                        Spacer(minLength: 4)
                        if isCurrent {
                            Text(L10n.string("gallery.current_document"))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                }
                .padding(14)
            }
            .background(isCurrent ? theme.selectionFill : (isHovered ? theme.hoverFill : theme.card))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isCurrent ? theme.selectionBorder : theme.border, lineWidth: isCurrent ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primaryText)
        .onHover { isHovered = $0 }
        .help(title + "\n" + L10n.string("gallery.open_document"))
        .accessibilityLabel(title + ", " + pageLabel)
        .accessibilityValue(isCurrent ? L10n.string("gallery.current_document") : "")
        .task(id: previewIdentity) {
            preview = nil
            isLoading = true
            let result = await PDFDocumentGalleryPreviewService.shared.preview(for: workspace)
            guard !Task.isCancelled else { return }
            preview = result
            isLoading = false
        }
        .onDisappear { preview = nil }
    }

    @ViewBuilder
    private var previewArea: some View {
        if let preview {
            Image(nsImage: preview.image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .pdfReadingAppearance()
                .shadow(color: theme.elevatedShadow, radius: 4, y: 2)
                .accessibilityHidden(true)
        } else {
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: workspace.document?.isLocked == true ? "lock.doc" : "doc.text")
                        .font(.system(size: 28, weight: .light))
                }
                Text(L10n.string(isLoading ? "gallery.preview_loading" :
                    (workspace.document?.isLocked == true ? "gallery.preview_locked" : "gallery.preview_unavailable")))
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(theme.secondaryText)
        }
    }
}
