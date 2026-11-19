// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// A single-document chooser attached to the pane being replaced, or the add
/// button. Browsing reads metadata and bounded previews without activating tabs.
@MainActor
struct ComparisonQuickDocumentPicker: View {
    let documents: [ComparisonDocument]
    let excludedDocumentIDs: Set<UUID>
    var replacingTitle: String? = nil
    let onSelect: (UUID) -> Void
    let onOpenFile: () -> Void

    @State private var filter = ComparisonChooserFilter()
    @EmberTheme private var theme

    private var candidates: [ComparisonDocument] {
        documents.filter { !excludedDocumentIDs.contains($0.id) }
    }

    private var visibleDocuments: [ComparisonDocument] {
        filter.documents(in: candidates)
    }

    private var workspaceChoices: [(id: UUID, title: String)] {
        var seen = Set<UUID>()
        return candidates.compactMap { document in
            guard let id = document.workspaceID, seen.insert(id).inserted else { return nil }
            return (id, document.workspaceTitle ?? L10n.string("comparison.chooser.workspace"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    L10n.string(replacingTitle == nil ? "comparison.document.add" : "comparison.document.replace"),
                    systemImage: replacingTitle == nil ? "doc.badge.plus" : "arrow.triangle.2.circlepath"
                )
                .font(.headline)
                if let replacingTitle {
                    Text(replacingTitle)
                        .font(.caption).foregroundStyle(theme.secondaryText)
                        .lineLimit(1).help(replacingTitle)
                }
            }

            if !candidates.isEmpty {
                browserControls
            }

            ScrollView {
                if visibleDocuments.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: candidates.isEmpty ? "doc.badge.plus" : "magnifyingglass")
                            .font(.system(size: 27, weight: .light))
                        Text(L10n.string(candidates.isEmpty ? "comparison.document.no_candidates" : "gallery.no_results"))
                            .font(.callout).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 190)
                    .padding(.horizontal, 20)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(visibleDocuments) { document in
                            documentCard(document)
                        }
                    }
                    .padding(1)
                }
            }
            .frame(height: candidates.isEmpty ? 190 : 330)
            .accessibilityIdentifier("comparison-quick-documents")

            Divider()
            Button(action: onOpenFile) {
                Label(L10n.string("comparison.document.open"), systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("comparison-quick-open-file")
        }
        .padding(14)
        .frame(width: 420)
        .foregroundStyle(theme.primaryText)
        .background(theme.panel)
        .tint(theme.accent)
        .onChange(of: workspaceChoices.map(\.id)) { _, availableIDs in
            if let workspaceID = filter.workspaceID, !availableIDs.contains(workspaceID) {
                filter.workspaceID = nil
            }
        }
    }

    private var browserControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if !workspaceChoices.isEmpty {
                    Picker(L10n.string("gallery.workspace_scope"), selection: $filter.workspaceID) {
                        Text(L10n.string("gallery.all_workspaces")).tag(Optional<UUID>.none)
                        ForEach(workspaceChoices, id: \.id) { item in
                            Text(item.title).tag(Optional(item.id))
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .accessibilityIdentifier("comparison-quick-workspace")
                }
                Spacer(minLength: 0)
                Text(L10n.format("gallery.count", visibleDocuments.count))
                    .font(.caption).foregroundStyle(theme.secondaryText).fixedSize()
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText)
                TextField(L10n.string("comparison.chooser.search"), text: $filter.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("comparison-quick-search")
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
                    .accessibilityLabel(L10n.string("gallery.search.clear"))
                }
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(theme.border, lineWidth: 1) }
        }
    }

    private func locationLabel(_ document: ComparisonDocument) -> String {
        [document.workspaceTitle, document.groupTitle,
         document.tabIndex.map { L10n.format("comparison.chooser.tab", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func documentCard(_ document: ComparisonDocument) -> some View {
        Button { onSelect(document.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ComparisonChooserPreview(workspace: document.workspace, source: .current, width: 150)
                    .frame(height: 130).padding(8)
                    .background(theme.canvas.opacity(0.8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    Text(locationLabel(document))
                        .font(.system(size: 10)).lineLimit(2)
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
                    Text(L10n.format("gallery.current_page", document.workspace.currentPageIndex + 1, document.pageCount))
                        .font(.caption2).monospacedDigit().foregroundStyle(theme.secondaryText)
                }
                .padding(9)
            }
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(theme.border, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(document.title + "\n" + locationLabel(document))
        .accessibilityLabel(document.title + ", " + locationLabel(document))
        .accessibilityIdentifier("comparison-quick-card-\(document.id)")
    }
}
