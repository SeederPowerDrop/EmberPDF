// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Filtering only reads tab metadata. In particular, a query must never resume
/// hibernated PDFs or navigate away from the workspace being compared.
struct ComparisonChooserFilter: Equatable {
    var workspaceID: UUID?
    var query = ""

    @MainActor
    func documents(in candidates: [ComparisonDocument]) -> [ComparisonDocument] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return candidates.filter { document in
            guard workspaceID == nil || document.workspaceID == workspaceID else { return false }
            let metadata = [document.title, document.workspaceTitle, document.groupTitle,
                            document.tabIndex.map(String.init)].compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { metadata.localizedStandardContains($0) }
        }
    }
}

enum ComparisonChooserPresentation: String, CaseIterable {
    case gallery, list
    var titleKey: String { "comparison.chooser.\(rawValue)" }
    var symbol: String { self == .gallery ? "square.grid.2x2" : "list.bullet" }
}

enum ComparisonChooserPreviewPage: String, CaseIterable {
    case current, cover
    var titleKey: String { "comparison.chooser.preview.\(rawValue)" }

    func pageIndex(currentPageIndex: Int, pageCount: Int) -> Int {
        self == .cover ? 0 : min(max(0, currentPageIndex), max(0, pageCount - 1))
    }
}

/// Small raster-only cells share the gallery's serial, cancellable and bounded
/// preview cache. A lazy tab uses a temporary PDF, never `prepareForDisplay()`.
@MainActor
struct ComparisonChooserPreview: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let source: ComparisonChooserPreviewPage
    var width: CGFloat = 200

    @Environment(\.displayScale) private var displayScale
    @EmberTheme private var theme
    @State private var preview: PDFDocumentGalleryPreview?
    @State private var isLoading = true

    private var pageIndex: Int {
        source.pageIndex(currentPageIndex: workspace.currentPageIndex, pageCount: workspace.pageCount)
    }

    private var identity: String {
        "\(workspace.revision)-\(pageIndex)-\(workspace.document == nil)-\(width)-\(displayScale)"
    }

    var body: some View {
        ZStack {
            if let preview {
                Image(nsImage: preview.image)
                    .resizable().interpolation(.high).scaledToFit()
                    .pdfReadingAppearance()
                    .shadow(color: theme.elevatedShadow, radius: 3, y: 2)
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: workspace.document?.isLocked == true ? "lock.doc" : "doc.text")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .task(id: identity) {
            preview = nil
            isLoading = true
            let result = await PDFDocumentGalleryPreviewService.shared.preview(
                for: workspace, pageIndex: pageIndex, width: width * displayScale
            )
            guard !Task.isCancelled else { return }
            preview = result
            isLoading = false
        }
        .onDisappear { preview = nil }
    }
}
