// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Shared between Settings and the reader's quick-access popover.
struct ReadingThemeControls: View {
    @ObservedObject var preferences: AppPreferences
    var compact = false
    var authorizeChange: () -> Bool = { true }
    @EmberTheme private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: compact ? 2 : 4), spacing: 10) {
                ForEach(PDFReadingTheme.allCases) { choice in
                    choiceButton(choice)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("reading.preview.text"))
                    .font(.system(size: 17, weight: .medium, design: .serif))
                Text(L10n.string("reading.preview.caption"))
                    .font(.system(size: 12))
            }
            .foregroundStyle(.black.opacity(0.86))
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(16)
            .background(paperColor(preferences.readingTheme), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(L10n.string("reading.preview"))

            Text(preferences.readingTheme.detail)
                .font(.callout)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("reading.display_only"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private func choiceButton(_ choice: PDFReadingTheme) -> some View {
        let selected = preferences.readingTheme == choice
        return Button {
            guard authorizeChange() else { return }
            preferences.readingTheme = choice
        } label: {
            VStack(spacing: 10) {
                Text("Aa")
                    .font(.system(size: 27, weight: .regular, design: .serif))
                    .foregroundStyle(.black.opacity(0.86))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(paperColor(choice), in: RoundedRectangle(cornerRadius: 5))
                HStack(spacing: 5) {
                    Text(choice.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? theme.accent : theme.secondaryText)
                }
            }
            .padding(10)
            .foregroundStyle(theme.primaryText)
            .background(selected ? theme.selectionFill : theme.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(selected ? theme.selectionBorder : theme.border, lineWidth: selected ? 2 : 1) }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(choice.detail)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reading-theme-\(choice.rawValue)")
    }

    private func paperColor(_ choice: PDFReadingTheme) -> Color {
        let rgb = choice.paperRGB
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

struct ReadingThemeToolbarButton: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var isPresented = false
    @EmberTheme private var theme

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "sun.haze")
                .font(.system(size: 14))
                .frame(width: 30, height: 28)
                .background(preferences.readingTheme == .original ? Color.clear : theme.selectionFill,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(EmberToolbarButtonStyle())
        .help(L10n.string("reading.title"))
        .accessibilityLabel(L10n.string("reading.title"))
        .accessibilityValue(preferences.readingTheme.title)
        .accessibilityIdentifier("reading-theme-control")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("reading.title")).font(.headline)
                ReadingThemeControls(preferences: preferences, compact: true)
            }
            .padding(20)
            .frame(width: 350)
            .background(theme.panel)
            .foregroundStyle(theme.primaryText)
            .emberTint()
        }
    }
}
