// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Small, live editor for the value-type `InkSettings` owned by the workspace.
/// The binding means every slider update immediately changes the next stroke;
/// this popover does not create an undo command because it changes a tool
/// preference, not PDF content.
struct PenSettingsPopover: View {
    @Binding var settings: InkSettings
    @ObservedObject private var presets = InkPresetStore.shared

    @Environment(\.colorScheme) private var colorScheme

    @EmberTheme private var theme

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: "pencil.tip.crop.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 38, height: 38)
                    .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.string("펜 설정"))
                        .font(.headline)
                    Text(L10n.string("잉크 스타일을 미리 확인하세요"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("pen.style")).font(.callout.weight(.medium))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(PDFInkStyle.allCases) { style in
                        Button {
                            settings.selectStyle(style)
                        } label: {
                            Label(style.title, systemImage: style.symbol)
                                .font(.callout.weight(settings.style == style ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(settings.style == style ? theme.dropHighlight : theme.canvas,
                                    in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(settings.style == style ? theme.accent : theme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pen-style-\(style.rawValue)")
                        .accessibilityAddTraits(settings.style == style ? .isSelected : [])
                    }
                }
                Text(settings.style.help)
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            preview
            drawingOptions
            if settings.style != .highlighter && settings.drawingOptions.shape == .freehand {
                Toggle(L10n.string("pen.pressure.enabled"), isOn: $settings.pressureEnabled)
                Text(L10n.string("pen.pressure.help")).font(.caption2).foregroundStyle(theme.secondaryText)
            }

            VStack(spacing: 14) {
                InlineColorPalette(
                    selection: $settings.color,
                    title: L10n.string("색상")
                )
                .accessibilityLabel(L10n.string("펜 색상"))
                .accessibilityHint(L10n.string("PDF 주석 선 색상을 선택합니다."))

                Divider()
                settingSlider(
                    title: L10n.string("굵기"),
                    value: $settings.width,
                    range: InkSettings.widthRange,
                    step: 0.25,
                    valueText: String(format: "%.1f pt", settings.width)
                )
                .accessibilityIdentifier("pen-width-slider")

                settingSlider(
                    title: L10n.string("pen.opacity", defaultValue: "불투명도"),
                    value: $settings.opacity,
                    range: InkSettings.opacityRange,
                    step: 0.05,
                    valueText: "\(Int((settings.opacity * 100).rounded()))%"
                )
                .accessibilityIdentifier("pen-opacity-slider")
            }
            .padding(14)
            .hwattakPDFCard(theme, cornerRadius: 13)

            Button {
                presets.add(settings)
            } label: {
                Label(L10n.string("pen.preset.save"), systemImage: "star.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .disabled(presets.presets.count >= InkPresetStore.maximumPresets)
            .help(L10n.string(presets.presets.count >= InkPresetStore.maximumPresets
                             ? "pen.preset.limit" : "pen.preset.help"))
            .accessibilityIdentifier("pen-save-preset")
        }
        .padding(16)
        }
        .frame(width: 350, height: 660)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
    }

    private var drawingOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.string("pen.shape")).font(.caption).frame(width: 55, alignment: .leading)
                Picker(L10n.string("pen.shape"), selection: $settings.drawingOptions.shape) {
                    ForEach(PDFInkShape.allCases) { shape in
                        Image(systemName: shape.symbol).tag(shape).help(shape.title)
                            .accessibilityLabel(shape.title)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("pen-drawing-shape")
            }
            HStack(spacing: 8) {
                Text(L10n.string("pen.pattern")).font(.caption).frame(width: 55, alignment: .leading)
                Picker(L10n.string("pen.pattern"), selection: $settings.drawingOptions.pattern) {
                    ForEach(PDFInkPattern.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("pen-drawing-pattern")
            }
            if settings.style == .highlighter {
                Picker(L10n.string("pen.tip"), selection: $settings.drawingOptions.highlighterTip) {
                    ForEach(PDFHighlighterTip.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("pen-highlighter-tip")
            }
            Text(L10n.string("pen.quick.draw_help"))
                .font(.caption2).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preview: some View {
        // The preview uses the same alpha as the saved stroke appearance.
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                // A paper sample keeps Multiply highlighters visible even
                // when the surrounding settings use the dark appearance.
                .fill(Color.white)
            HStack(spacing: 18) {
                ForEach(0..<9) { _ in
                    Rectangle()
                        .fill(Color.black.opacity(0.18))
                        .frame(width: 8)
                }
            }
            .frame(height: 36)
            .accessibilityHidden(true)
            PenStrokeStylePreview(settings: settings)
                .frame(height: 60)
                .accessibilityHidden(true)
        }
        .frame(height: 64)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }

    private func settingSlider(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.dropHighlight, in: Capsule())
            }
            // Native stepped sliders draw a tick for every increment; over
            // 100 ticks obscure this short track. Quantize the value instead.
            Slider(value: Binding(get: { value.wrappedValue }, set: {
                value.wrappedValue = min(range.upperBound, max(range.lowerBound, ($0 / step).rounded() * step))
            }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

/// A real sample of the same geometry and appearance written into the PDF.
private struct PenStrokeStylePreview: NSViewRepresentable {
    let settings: InkSettings

    func makeNSView(context: Context) -> PenStrokeSampleView { PenStrokeSampleView() }
    func updateNSView(_ view: PenStrokeSampleView, context: Context) {
        view.settings = settings
        view.needsDisplay = true
    }
}

private final class PenStrokeSampleView: NSView {
    var settings = InkSettings()
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let freehand = settings.drawingOptions.shape == .freehand
        let points = freehand ? (0..<80).map { index -> CGPoint in
            let progress = CGFloat(index) / 79
            return CGPoint(x: 18 + progress * max(1, bounds.width - 36),
                y: bounds.midY + sin(progress * .pi * 2) * 10)
        } : [CGPoint(x: 24, y: bounds.midY - 17), CGPoint(x: bounds.width - 24, y: bounds.midY + 17)]
        let pressures = points.indices.map { index -> CGFloat in
            freehand && settings.style != .highlighter && settings.pressureEnabled
                ? 0.35 + 0.65 * sin(CGFloat(index) / 79 * .pi) : 1
        }
        guard let stroke = PDFInkStrokeRenderer.stroke(points: points, pressures: pressures,
            width: settings.width, style: settings.style, options: settings.drawingOptions) else { return }
        PDFInkStrokeRenderer.draw(strokes: [stroke], color: settings.pdfInkColor,
            style: settings.style, options: settings.drawingOptions, in: context)
    }
}
