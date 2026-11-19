// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct PDFCompressionSheet: View {
    let documentData: Data
    let originalBytes: Int?
    let onSave: @MainActor (Data) -> Void
    let onCancel: @MainActor () -> Void

    @StateObject private var presentation = PDFCompressionPresentation()
    @EmberTheme private var theme

    init(
        documentData: Data,
        originalBytes: Int? = nil,
        onSave: @escaping @MainActor (Data) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.documentData = documentData
        self.originalBytes = originalBytes
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var baselineBytes: Int { originalBytes ?? documentData.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 36, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("compression.title", "PDF 용량 줄이기"))
                        .font(.title3.weight(.semibold))
                    Text(localized("compression.detail", "이미지 품질을 선택하고 실제 용량을 확인한 후 복사본으로 저장합니다."))
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(localized("compression.quality", "이미지 품질"))
                    .font(.headline)
                ForEach(PDFCompressionQuality.allCases, id: \.self) { quality in
                    qualityButton(quality)
                }
            }
            .disabled(presentation.isProcessing)

            Label {
                Text(localized("compression.preservation", "텍스트와 도형은 유지됩니다. 사진은 다시 압축하므로 선택한 설정에 따라 화질이 달라질 수 있습니다."))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryText)

            previewCard
            actionBar
        }
        .padding(22)
        .frame(width: 530)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .onDisappear { presentation.cancel() }
    }

    private func qualityButton(_ quality: PDFCompressionQuality) -> some View {
        let selected = presentation.quality == quality
        return Button {
            presentation.selectQuality(quality)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? theme.accent : theme.secondaryText)
                    .font(.title3)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(qualityTitle(quality))
                        .font(.callout.weight(.semibold))
                    Text(qualityDetail(quality))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? theme.dropHighlight : theme.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? theme.accent.opacity(0.55) : theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(qualityTitle(quality))
        .accessibilityHint(qualityDetail(quality))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sizeRow(localized("compression.current_size", "현재 PDF"), bytes: baselineBytes)
            if presentation.isProcessing {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(localized("compression.processing", "이미지를 최적화하고 실제 용량을 계산하는 중…"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            } else if let result = presentation.result {
                sizeRow(localized("compression.result_size", "최적화 후"), bytes: result.compressedBytes)
                if presentation.canSave {
                    Label(savingsDescription(result), systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.success)
                } else {
                    Text(localized("compression.no_reduction", "이 설정으로는 더 줄일 수 없습니다. 다른 품질을 선택해 보세요. 현재 PDF는 변경되지 않았습니다."))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let errorMessage = presentation.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(localized("compression.preview_help", "용량 미리 계산을 누르면 저장할 파일의 크기를 확인할 수 있습니다."))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hwattakPDFCard(theme)
    }

    private func sizeRow(_ title: String, bytes: Int) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Button(L10n.string("action.cancel")) {
                presentation.cancel()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if presentation.isProcessing {
                Button(localized("compression.stop", "중단")) { presentation.cancel() }
            } else {
                Button(localized("compression.preview", "용량 미리 계산")) {
                    presentation.start(documentData: documentData, originalBytes: baselineBytes)
                }
            }
            Button(L10n.string("action.save_copy")) {
                guard presentation.canSave, let data = presentation.result?.data else { return }
                onSave(data)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!presentation.canSave)
        }
    }

    private func qualityTitle(_ quality: PDFCompressionQuality) -> String {
        switch quality {
        case .highQuality: return localized("compression.quality.high", "높은 품질")
        case .balanced: return localized("compression.quality.balanced", "균형")
        case .small: return localized("compression.quality.small", "작은 용량")
        }
    }

    private func qualityDetail(_ quality: PDFCompressionQuality) -> String {
        switch quality {
        case .highQuality:
            return localized("compression.quality.high_detail", "사진의 선명함을 우선하며 용량을 줄입니다.")
        case .balanced:
            return localized("compression.quality.balanced_detail", "일상적인 화면 보기와 파일 공유에 적합합니다.")
        case .small:
            return localized("compression.quality.small_detail", "더 강하게 줄입니다. 확대하거나 인쇄하면 사진이 흐려질 수 있습니다.")
        }
    }

    private func savingsDescription(_ result: PDFCompressionResult) -> String {
        let fraction = Double(baselineBytes - result.compressedBytes) / Double(max(1, baselineBytes))
        let percent = fraction.formatted(.percent.precision(.fractionLength(1)).locale(L10n.currentLanguage.locale))
        let format = localized("compression.savings", "%@ 감소")
        return String(format: format, locale: L10n.currentLanguage.locale, percent)
    }

    private func localized(_ key: String, _ fallback: String) -> String {
        L10n.string(key, defaultValue: fallback)
    }
}
