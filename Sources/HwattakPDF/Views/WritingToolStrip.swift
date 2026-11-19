// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// One writing cluster shared by Editing and Study. Selecting a saved pen is
/// one click; clicking it again edits that pen without leaving the document.
struct WritingToolStrip: View {
    @ObservedObject var workspace: PDFWorkspaceState
    @ObservedObject var presets: InkPresetStore = .shared
    @State private var showingPenSettings = false
    @State private var showingEraserSettings = false
    @State private var showingColors = false
    @State private var editingPresetID: UUID?
    @EmberTheme private var theme

    private var canUseTools: Bool {
        workspace.hasOpenDocument && workspace.pageColumns <= 2 && workspace.allows(.handwriting)
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(workspace.mode.availableTools) { tool in
                toolButton(tool)
            }
            Group {
            separator
            ForEach(presets.presets.prefix(4)) { preset in
                presetButton(preset)
            }
            Menu {
                ForEach(presets.presets) { preset in
                    Menu(presetLabel(preset)) {
                        Button(L10n.string("적용"), systemImage: preset.snapshot.style.symbol) {
                            _ = workspace.useInkPreset(preset)
                        }
                        Button(L10n.string("pen.quick.settings"), systemImage: "slider.horizontal.3") {
                            if workspace.useInkPreset(preset) {
                                editingPresetID = preset.id
                                showingPenSettings = true
                            }
                        }
                        Button(L10n.string("pen.preset.replace")) { presets.replace(preset.id, with: workspace.inkSettings) }
                        Button(L10n.string("pen.preset.delete"), role: .destructive) { presets.remove(preset.id) }
                    }
                }
                Divider()
                Button(L10n.string("pen.preset.save"), systemImage: "plus") {
                    presets.add(workspace.inkSettings)
                }
                .disabled(presets.presets.count >= InkPresetStore.maximumPresets)
            } label: {
                Image(systemName: "star").frame(width: 26, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L10n.string("pen.quick.more"))
            .accessibilityLabel(L10n.string("pen.quick.more"))
            .accessibilityIdentifier("writing-saved-pens")

            separator
            Menu {
                Picker(L10n.string("pen.shape"), selection: Binding(
                    get: { workspace.inkSettings.drawingOptions.shape },
                    set: { value in changePen { $0.drawingOptions.shape = value } }
                )) {
                    ForEach(PDFInkShape.allCases) { shape in
                        Label(shape.title, systemImage: shape.symbol).tag(shape)
                    }
                }
            } label: {
                Image(systemName: workspace.inkSettings.drawingOptions.shape.symbol)
                    .frame(width: 26, height: 28)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L10n.string("pen.shape"))
            .accessibilityLabel(L10n.string("pen.shape"))
            .accessibilityValue(workspace.inkSettings.drawingOptions.shape.title)
            .accessibilityIdentifier("writing-shape")

            Menu {
                Picker(L10n.string("pen.pattern"), selection: Binding(
                    get: { workspace.inkSettings.drawingOptions.pattern },
                    set: { value in changePen { $0.drawingOptions.pattern = value } }
                )) {
                    ForEach(PDFInkPattern.allCases) { pattern in
                        Text(pattern.title).tag(pattern)
                    }
                }
            } label: {
                Image(nsImage: Self.patternIcon(workspace.inkSettings.drawingOptions.pattern))
                    .renderingMode(.template).frame(width: 26, height: 28)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L10n.string("pen.pattern"))
            .accessibilityLabel(L10n.string("pen.pattern"))
            .accessibilityValue(workspace.inkSettings.drawingOptions.pattern.title)
            .accessibilityIdentifier("writing-pattern")

            Button { showingColors.toggle() } label: {
                Circle().fill(Color(nsColor: workspace.inkSettings.color))
                    .overlay(Circle().strokeBorder(theme.secondaryText.opacity(0.5), lineWidth: 1))
                    .frame(width: 18, height: 18).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(L10n.string("pen.quick.color"))
            .accessibilityLabel(L10n.string("pen.quick.color"))
            .accessibilityIdentifier("writing-color")
            .popover(isPresented: $showingColors, arrowEdge: .bottom) {
                InlineColorPalette(selection: $workspace.inkSettings.color, title: L10n.string("색상"))
                    .padding(14).frame(width: 240)
            }

            Menu {
                ForEach(widths, id: \.self) { width in
                    Button {
                        workspace.inkSettings.width = width
                    } label: {
                        Label(widthText(width), systemImage: abs(workspace.inkSettings.width - width) < 0.01
                              ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                Text(widthText(workspace.inkSettings.width))
                    .font(.caption.monospacedDigit()).frame(minWidth: 44, minHeight: 28)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L10n.string("pen.quick.width"))
            .accessibilityLabel(L10n.string("pen.quick.width"))
            .accessibilityValue(widthText(workspace.inkSettings.width))
            .accessibilityIdentifier("writing-width")

            Button {
                editingPresetID = nil
                showingPenSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(L10n.string("펜 설정"))
            .accessibilityLabel(L10n.string("pen.quick.settings"))
            .accessibilityIdentifier("writing-pen-settings")
            }
            .disabled(!canUseTools)
        }
        .font(.system(size: 13, weight: .medium))
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(theme.primaryText)
        .popover(isPresented: $showingPenSettings, arrowEdge: .bottom) {
            PenSettingsPopover(settings: $workspace.inkSettings)
        }
        .popover(isPresented: $showingEraserSettings, arrowEdge: .bottom) {
            StudyEraserSettingsPopover(mode: $workspace.eraserMode, size: $workspace.eraserSize)
        }
        .onChange(of: workspace.inkSettings) { _, settings in
            if showingPenSettings, let id = editingPresetID { presets.replace(id, with: settings) }
        }
        .onChange(of: showingPenSettings) { _, shown in
            if !shown { editingPresetID = nil }
        }
        .onChange(of: workspace.mode) { _, _ in dismissPopovers() }
        .onDisappear { dismissPopovers() }
        .onChange(of: workspace.pageColumns) { _, columns in
            if columns > 2 { dismissPopovers() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("pen.quick.title"))
        .accessibilityIdentifier("writing-tool-strip")
    }

    private func toolButton(_ tool: WorkspaceTool) -> some View {
        let selected = workspace.activeTool == tool
        return Button {
            if selected, tool == .pen {
                editingPresetID = presets.presets.first(where: { $0.snapshot.matches(workspace.inkSettings) })?.id
                showingPenSettings.toggle()
            } else if selected, tool == .eraser {
                showingEraserSettings.toggle()
            } else {
                workspace.selectTool(tool)
            }
        } label: {
            Image(systemName: tool == .pen ? workspace.inkSettings.style.symbol : tool.systemImage)
                .frame(width: 30, height: 30)
                .background(selected ? theme.dropHighlight : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? theme.accent : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canUseTool(tool))
        .help(workspace.mode.title(for: tool))
        .accessibilityLabel(workspace.mode.title(for: tool))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("writing-tool-\(tool.rawValue)")
    }

    private func presetButton(_ preset: InkPreset) -> some View {
        let selected = workspace.activeTool == .pen && preset.snapshot.matches(workspace.inkSettings)
        return Button {
            if selected {
                editingPresetID = preset.id
                showingPenSettings = true
            } else {
                _ = workspace.useInkPreset(preset)
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: preset.snapshot.style.symbol)
                    .foregroundStyle(theme.primaryText)
                    .font(.system(size: 15, weight: .semibold))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Color(nsColor: preset.snapshot.settings.color))
                            .overlay(Capsule().stroke(theme.secondaryText.opacity(0.6), lineWidth: 0.5))
                            .frame(width: 20, height: 3).offset(y: 2)
                    }
                Text(String(format: "%g", Double(preset.snapshot.width)))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
            }
            .frame(width: 32, height: 32)
            .background(selected ? theme.dropHighlight : theme.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? theme.accent : theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(presetLabel(preset))
        .accessibilityLabel(presetLabel(preset))
        .accessibilityHint(L10n.string("pen.preset.help"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("writing-preset-\(preset.id.uuidString)")
        .contextMenu {
            Button(L10n.string("pen.preset.replace")) { presets.replace(preset.id, with: workspace.inkSettings) }
            Button(L10n.string("pen.preset.delete"), role: .destructive) { presets.remove(preset.id) }
        }
    }

    private var separator: some View { Divider().frame(height: 22).padding(.horizontal, 2) }
    private var widths: [CGFloat] { workspace.inkSettings.style == .highlighter ? [8, 14, 22] : [1, 2.4, 5] }
    private static func patternIcon(_ pattern: PDFInkPattern) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: 4)); path.line(to: NSPoint(x: 18, y: 18))
            path.lineWidth = 2; path.lineCapStyle = .round
            if pattern == .dashed { path.setLineDash([3, 3], count: 2, phase: 0) }
            NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
    private func widthText(_ width: CGFloat) -> String { String(format: "%g pt", Double(width)) }
    private func presetLabel(_ preset: InkPreset) -> String {
        let snapshot = preset.snapshot
        let color = String(format: "#%02X%02X%02X", Int((snapshot.red * 255).rounded()),
                           Int((snapshot.green * 255).rounded()), Int((snapshot.blue * 255).rounded()))
        return "\(snapshot.style.title) · \(color) · \(widthText(snapshot.width)) · \(snapshot.drawingOptions.shape.title) · \(snapshot.drawingOptions.pattern.title)"
    }
    private func canUseTool(_ tool: WorkspaceTool) -> Bool {
        guard workspace.hasOpenDocument, workspace.pageColumns <= 2 else { return false }
        switch tool {
        case .select: return workspace.allows(.textSelection)
        case .text: return workspace.allows(workspace.mode == .editing ? .inlineTextEditing : .typedNotes)
        case .pen, .eraser: return workspace.allows(.handwriting)
        }
    }
    private func dismissPopovers() {
        showingPenSettings = false; showingEraserSettings = false; showingColors = false
    }
    private func changePen(_ update: (inout InkSettings) -> Void) {
        guard canUseTools else { return }
        workspace.selectTool(.pen)
        guard workspace.activeTool == .pen else { return }
        var settings = workspace.inkSettings
        update(&settings)
        workspace.inkSettings = settings
    }
}
