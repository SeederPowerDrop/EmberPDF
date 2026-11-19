// SPDX-License-Identifier: MPL-2.0

import SwiftUI

enum PDFDocumentDifferenceText {
    static func string(_ key: String, _ fallback: String) -> String {
        L10n.string("comparison.difference." + key, defaultValue: fallback)
    }
    static func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: string(key, fallback), locale: L10n.currentLanguage.locale, arguments: arguments)
    }
}

/// A narrow companion to the existing 2–4-document reading surface. Its
/// lifetime never owns, rekeys or reconstructs any native PDFView.
@MainActor
struct PDFDocumentDifferenceView: View {
    let documents: [ComparisonDocument]
    let lockedIDs: Set<UUID>
    @ObservedObject var service: PDFDocumentDifferenceService
    let reveal: ([UUID: PDFDocumentDifferenceLocation]) -> Void
    let close: () -> Void
    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var language = L10n.currentLanguage
    @EmberTheme private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(PDFDocumentDifferenceText.string("title", "Text changes"), systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(PDFDocumentDifferenceText.string("close", "Close changes"))
                    .accessibilityIdentifier("comparison-difference-close")
            }
            Text(PDFDocumentDifferenceText.string("scope", "Compares extracted text and page additions or deletions. Images, layout and annotations are not compared."))
                .font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            picker(PDFDocumentDifferenceText.string("before", "Original"), selection: $beforeID, excluding: afterID)
            picker(PDFDocumentDifferenceText.string("after", "Revised"), selection: $afterID, excluding: beforeID)
            HStack {
                Button {
                    let original = beforeID
                    beforeID = afterID
                    afterID = original
                    service.reset()
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .help(L10n.string("comparison.place.swap"))
                .accessibilityLabel(L10n.string("comparison.place.swap"))
                .accessibilityIdentifier("comparison-difference-swap")
                .disabled(service.isRunning || beforeID == nil || afterID == nil)
                Button(PDFDocumentDifferenceText.string(service.phase == .idle ? "start" : "restart", service.phase == .idle ? "Compare text" : "Compare again")) {
                    guard let before = documents.first(where: { $0.id == beforeID }),
                          let after = documents.first(where: { $0.id == afterID }) else { return }
                    service.start(before: before, after: after)
                }
                .disabled(service.isRunning || beforeID == nil || afterID == nil || beforeID == afterID)
                .accessibilityIdentifier("comparison-difference-start")
                if service.isRunning {
                    Button(PDFDocumentDifferenceText.string("cancel", "Cancel")) { service.cancel() }
                        .accessibilityIdentifier("comparison-difference-cancel")
                }
                Spacer()
            }
            status
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let report = service.report, service.phase == .completed {
                        ForEach(report.changes) { change in row(change) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("comparison-difference-results")
            Text(PDFDocumentDifferenceText.string("navigation", "Select a change to show both locations. Pinned PDFs keep their position."))
                .font(.caption2).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        .background(theme.sidebar)
        .foregroundStyle(theme.primaryText)
        .environment(\.locale, language.locale)
        .background {
            ForEach(documents) { document in
                PDFDocumentDifferenceSourceObserver(workspace: document.workspace) {
                    service.invalidateIfNeeded(availableIDs: Set(documents.map(\.id)))
                }
            }
        }
        .onAppear {
            service.invalidateIfNeeded(availableIDs: Set(documents.map(\.id)))
            normalizePair()
        }
        .onChange(of: documents.map(\.id)) { _, _ in
            service.invalidateIfNeeded(availableIDs: Set(documents.map(\.id)))
            normalizePair()
        }
        .onChange(of: beforeID) { old, new in if old != nil && old != new { service.reset() } }
        .onChange(of: afterID) { old, new in if old != nil && old != new { service.reset() } }
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageDidChange)) { _ in language = L10n.currentLanguage }
        .onDisappear { service.cancel() }
    }

    private func picker(_ title: String, selection: Binding<UUID?>, excluding: UUID?) -> some View {
        Picker(title, selection: selection) {
            ForEach(documents.filter { $0.id != excluding }) { document in
                Text(document.title).lineLimit(1).tag(Optional(document.id))
            }
        }
        .disabled(service.isRunning)
        .accessibilityIdentifier("comparison-difference-" + (title == PDFDocumentDifferenceText.string("before", "Original") ? "before" : "after"))
    }

    @ViewBuilder private var status: some View {
        switch service.phase {
        case .idle:
            Text(PDFDocumentDifferenceText.string("ready", "Choose two PDFs to compare their text."))
                .font(.caption).foregroundStyle(theme.secondaryText)
        case .capturing:
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: Double(service.capturedPages), total: Double(max(1, service.totalPages)))
                Text(PDFDocumentDifferenceText.format("reading", "Reading text: %d / %d pages", service.capturedPages, service.totalPages)).font(.caption)
            }
        case .comparing:
            HStack { ProgressView().controlSize(.small); Text(PDFDocumentDifferenceText.string("comparing", "Comparing text…")).font(.caption) }
        case .cancelled:
            message(PDFDocumentDifferenceText.string("cancelled", "Comparison cancelled. Run it again to see results."))
        case .invalidated:
            message(PDFDocumentDifferenceText.string("changed", "A source PDF changed. Compare again for current results."))
        case .failed(let failure):
            message(failureText(failure))
        case .completed:
            if let report = service.report {
                VStack(alignment: .leading, spacing: 6) {
                    if report.hasNoTextChanges {
                        Text(PDFDocumentDifferenceText.string("identical", "No text changes found.")).font(.callout.weight(.medium))
                    } else if !report.changes.isEmpty {
                        Text(PDFDocumentDifferenceText.format("count", "%d text changes", report.changes.count)).font(.callout.weight(.medium))
                    }
                    if report.textlessPageCount > 0 {
                        message(PDFDocumentDifferenceText.format("textless", "%d pages have no extractable text and could not be compared. Use OCR to compare scanned text.", report.textlessPageCount))
                    }
                    if report.isTruncated {
                        message(PDFDocumentDifferenceText.string("truncated", "The result limit was reached. This list is incomplete."))
                    }
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ change: PDFDocumentDifferenceChange) -> some View {
        Button {
            reveal(service.locations(for: change, lockedIDs: lockedIDs))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(kindText(change.kind), systemImage: change.kind == .added ? "plus.circle" : change.kind == .removed ? "minus.circle" : "pencil.circle")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 2)
                    if change.isWholePage { Text(PDFDocumentDifferenceText.string("whole_page", "Page")).font(.caption2) }
                }
                if let before = change.before { excerpt(before, side: "before", title: "Original") }
                if let after = change.after { excerpt(after, side: "after", title: "Revised") }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.canvas, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.accent.opacity(0.18)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled((service.beforeID.map { lockedIDs.contains($0) } ?? true) && (service.afterID.map { lockedIDs.contains($0) } ?? true))
        .accessibilityIdentifier("comparison-difference-result-\(change.id)")
    }

    private func excerpt(_ location: PDFDocumentDifferenceLocation, side: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(PDFDocumentDifferenceText.string(side, title) + " · " + PDFDocumentDifferenceText.format("page", "Page %d", location.pageIndex + 1))
                .font(.caption2).foregroundStyle(theme.secondaryText)
            Text(location.excerpt.isEmpty ? "—" : location.excerpt)
                .font(.caption).lineLimit(3).multilineTextAlignment(.leading)
        }
    }

    private func kindText(_ kind: PDFDocumentDifferenceChange.Kind) -> String {
        switch kind {
        case .added: PDFDocumentDifferenceText.string("added", "Added")
        case .removed: PDFDocumentDifferenceText.string("removed", "Removed")
        case .modified: PDFDocumentDifferenceText.string("modified", "Modified")
        }
    }

    private func failureText(_ failure: PDFDocumentDifferenceFailure) -> String {
        switch failure {
        case .unavailable: PDFDocumentDifferenceText.string("unavailable", "Text could not be read from these PDFs.")
        case .restricted: PDFDocumentDifferenceText.string("restricted", "Text comparison requires permission to copy text from both PDFs.")
        case .tooLarge: PDFDocumentDifferenceText.string("too_large", "These PDFs exceed the comparison limit. Compare smaller documents.")
        case .noText: PDFDocumentDifferenceText.string("no_text", "These PDFs have no extractable text. Apply OCR before comparing scanned text.")
        case .changed: PDFDocumentDifferenceText.string("changed", "A source PDF changed. Compare again for current results.")
        case .timedOut: PDFDocumentDifferenceText.string("timed_out", "Comparison took too long. Compare smaller documents.")
        }
    }

    private func normalizePair() {
        let ids = documents.map(\.id)
        if beforeID == nil, let previous = service.beforeID, ids.contains(previous) { beforeID = previous }
        if afterID == nil, let previous = service.afterID, ids.contains(previous), previous != beforeID { afterID = previous }
        if beforeID.map({ ids.contains($0) }) != true { beforeID = ids.first }
        if afterID.map({ ids.contains($0) }) != true || afterID == beforeID { afterID = ids.first { $0 != beforeID } }
    }
}

@MainActor
private struct PDFDocumentDifferenceSourceObserver: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let changed: () -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: workspace.revision) { _, _ in changed() }
    }
}
