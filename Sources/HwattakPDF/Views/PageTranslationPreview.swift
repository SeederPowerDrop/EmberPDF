// SPDX-License-Identifier: MPL-2.0

import PDFKit
import SwiftUI

/// This PDFView is isolated from the editable source workspace. Switching the
/// preview never replaces source pages or changes the source document's state.
@MainActor
struct PageTranslationPreview: View {
    let pageNumber: Int
    let originalPDF: Data?
    let translatedPDF: Data?
    let onSave: () -> Void

    @State private var showsTranslation = false
    @State private var isExpanded = false

    private var displayedPDF: Data? { showsTranslation ? translatedPDF : originalPDF }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.format("translation.page.number", pageNumber), systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                Button {
                    isExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help(L10n.string("translation.page.expand", defaultValue: "페이지 크게 보기"))
                .accessibilityLabel(L10n.string("translation.page.expand", defaultValue: "페이지 크게 보기"))
                .disabled(displayedPDF == nil)
            }
            selection
            preview.frame(height: 510)
            if translatedPDF != nil {
                Button(L10n.string("translation.page.save_pdf", defaultValue: "번역 페이지 PDF 저장"), action: onSave)
                    .controlSize(.small)
                Text(L10n.string("translation.page.continued", defaultValue: "공간이 부족한 번역문은 다음 페이지에 이어서 표시합니다."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: translatedPDF) { _, data in showsTranslation = data != nil }
        .sheet(isPresented: $isExpanded) {
            VStack(spacing: 12) {
                HStack {
                    Text(L10n.format("translation.page.number", pageNumber)).font(.headline)
                    Spacer()
                    if translatedPDF != nil {
                        Button(L10n.string("translation.page.save_pdf", defaultValue: "번역 페이지 PDF 저장"), action: onSave)
                    }
                    Button(L10n.string("translation.page.close", defaultValue: "페이지 미리보기 닫기")) {
                        isExpanded = false
                    }.keyboardShortcut(.cancelAction)
                }
                selection
                preview
            }
            .padding(16)
            .frame(minWidth: 720, idealWidth: 920, minHeight: 580, idealHeight: 780)
        }
    }

    private var selection: some View {
        Picker(L10n.string("translation.page.preview", defaultValue: "페이지 미리보기"), selection: $showsTranslation) {
            Text(L10n.string("translation.page.original", defaultValue: "원본")).tag(false)
            Text(L10n.string("translation.page.translated", defaultValue: "번역")).tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(translatedPDF == nil)
    }

    @ViewBuilder
    private var preview: some View {
        if let data = displayedPDF {
            TranslationReadingPDFView(data: data)
                .accessibilityLabel(L10n.string("translation.page.preview", defaultValue: "페이지 미리보기"))
        } else {
            Text(L10n.string("translation.page.preview_error", defaultValue: "번역 페이지를 준비하지 못했습니다."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
private struct TranslationReadingPDFView: NSViewRepresentable {
    let data: Data
    @AppStorage(PDFReadingTheme.defaultsKey)
    private var readingThemeValue = PDFReadingTheme.original.rawValue
    @EmberTheme private var theme

    private var readingTheme: PDFReadingTheme {
        PDFReadingTheme(rawValue: readingThemeValue) ?? .original
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = true
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 6
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.backgroundColor = PDFReadingDisplayEffect.nativeCanvasColor(theme.canvas, theme: readingTheme)
        context.coordinator.readingDisplayFilter.apply(readingTheme, to: view)
        // Language controls and progress updates must not reset scroll/zoom.
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
        view.autoScales = true
    }

    @MainActor
    final class Coordinator {
        var data: Data?
        let readingDisplayFilter = PDFReadingDisplayFilterController()
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.readingDisplayFilter.detach()
    }
}
