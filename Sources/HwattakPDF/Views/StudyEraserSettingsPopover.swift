// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct StudyEraserSettingsPopover: View {
    @Binding var mode: PDFEraserMode
    @Binding var size: CGFloat

    @EmberTheme private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("study.eraser.settings", defaultValue: "지우개 설정"))
                .font(.headline)

            Picker(
                L10n.string("study.eraser.mode", defaultValue: "지우는 방식"),
                selection: $mode
            ) {
                Text(L10n.string("study.eraser.stroke", defaultValue: "획 지우기"))
                    .tag(PDFEraserMode.stroke)
                Text(L10n.string("study.eraser.partial", defaultValue: "부분 지우기"))
                    .tag(PDFEraserMode.partial)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("study-eraser-mode")

            Text(
                L10n.string(
                    "study.eraser.option_help",
                    defaultValue: "Option 키를 누르는 동안 반대 방식으로 지웁니다."
                )
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L10n.string("study.eraser.size", defaultValue: "지우개 크기"))
                    Spacer()
                    Text(sizeLabel).monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                }
                .font(.caption)
                Slider(value: $size, in: 2...48, step: 1)
                    .accessibilityLabel(
                        L10n.string("study.eraser.size", defaultValue: "지우개 크기")
                    )
                    .accessibilityValue(sizeLabel)
                    .accessibilityIdentifier("study-eraser-size")
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
    }

    private var sizeLabel: String { String(format: "%.0f pt", size) }
}
