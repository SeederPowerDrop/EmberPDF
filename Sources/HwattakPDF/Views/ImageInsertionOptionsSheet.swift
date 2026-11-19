// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct ImageInsertionOptionsSheet: View {
    let urls: [URL]
    let onCancel: () -> Void
    let onInsert: ([PreparedImageInsertion]) -> Void

    @EmberTheme private var theme
    @State private var quality: ImageInsertionQuality = .original
    @State private var prepared: [PreparedImageInsertion] = []
    @State private var isPreparing = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.string("image.insert.options.title", defaultValue: "이미지 화질과 용량"), systemImage: "photo")
                .font(.title3.weight(.semibold))
            Text(L10n.string("image.insert.options.detail", defaultValue: "PDF에 넣기 전에 화질과 예상 용량을 확인하세요. 선택한 설정은 이번 이미지에 적용됩니다."))
                .font(.callout)
                .foregroundStyle(theme.secondaryText)

            Picker(L10n.string("image.insert.quality", defaultValue: "이미지 화질"), selection: $quality) {
                ForEach(ImageInsertionQuality.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Text(quality.detail)
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 34, alignment: .topLeading)

            Group {
                if isPreparing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.string("image.insert.preparing", defaultValue: "미리보기와 예상 용량을 준비하는 중…"))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(prepared.enumerated()), id: \.offset) { _, item in
                                previewRow(item)
                            }
                        }
                    }
                    .frame(height: prepared.count == 1 ? 180 : 240)
                }
            }
            .padding(12)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Text(L10n.string("image.insert.estimated_size", defaultValue: "예상 PDF 증가량"))
                Spacer()
                Text(isPreparing || prepared.isEmpty ? "—" : "≈ " + formattedBytes(prepared.reduce(0) { $0 + $1.estimatedAddedBytes }))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            Text(L10n.string("image.insert.estimate_note", defaultValue: "저장 방식에 따라 실제 용량은 달라질 수 있습니다. 투명 배경은 유지됩니다."))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            HStack {
                Button(L10n.string("action.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("image.insert.confirm", defaultValue: "이미지 넣기")) {
                    guard !isPreparing, errorMessage == nil, prepared.count == urls.count, !prepared.isEmpty,
                          prepared.allSatisfy({ $0.option == quality }) else { return }
                    onInsert(prepared)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isPreparing || errorMessage != nil || prepared.isEmpty
                    || prepared.count != urls.count || prepared.contains(where: { $0.option != quality }))
            }
        }
        .padding(22)
        .frame(width: 530)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .task(id: quality) { await prepareCurrentChoice() }
    }

    @ViewBuilder
    private func previewRow(_ item: PreparedImageInsertion) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: item.image)
                .resizable()
                .scaledToFit()
                .frame(width: prepared.count == 1 ? 220 : 90, height: prepared.count == 1 ? 160 : 80)
                .accessibilityLabel(item.sourceURL.lastPathComponent)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.sourceURL.lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text("\(Int(item.pixelSize.width)) × \(Int(item.pixelSize.height)) px")
                    .monospacedDigit()
                Text(L10n.string("image.insert.source_size", defaultValue: "원본 파일") + ": " + formattedBytes(item.sourceBytes))
                if item.isResized {
                    Text(L10n.string("image.insert.resized", defaultValue: "크기 조정됨"))
                }
                if item.preservesTransparency {
                    Text(L10n.string("image.insert.transparency", defaultValue: "투명 배경 유지 · 무손실 압축"))
                }
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
        }
    }

    @MainActor
    private func prepareCurrentChoice() async {
        let choice = quality
        isPreparing = true
        prepared = []
        errorMessage = nil
        let worker = Task.detached(priority: .userInitiated) {
            try ImageInsertionPreparation.prepare(urls: urls, option: choice)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, quality == choice else { return }
            prepared = result
            isPreparing = false
        } catch {
            guard !Task.isCancelled, quality == choice else { return }
            errorMessage = error.localizedDescription
            isPreparing = false
        }
    }

    private func formattedBytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}
