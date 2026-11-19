// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine

/// Tool preferences only: no PDF content, pointer samples, or document paths.
struct InkPresetSnapshot: Codable, Equatable {
    let style: PDFInkStyle
    let pressureEnabled: Bool
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let width: CGFloat
    let opacity: CGFloat
    let drawingOptions: PDFInkDrawingOptions

    init?(_ settings: InkSettings) {
        guard let rgb = settings.color.usingColorSpace(.deviceRGB) else { return nil }
        style = settings.style
        pressureEnabled = settings.pressureEnabled
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
        width = settings.width; opacity = settings.opacity
        drawingOptions = settings.drawingOptions
        guard isValid else { return nil }
    }

    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && width.isFinite && InkSettings.widthRange.contains(width)
            && opacity.isFinite && InkSettings.opacityRange.contains(opacity)
    }

    var settings: InkSettings {
        var result = InkSettings()
        result.style = style
        result.pressureEnabled = pressureEnabled
        result.color = NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
        result.width = width; result.opacity = opacity
        result.drawingOptions = drawingOptions
        return result
    }

    func matches(_ settings: InkSettings) -> Bool {
        guard let other = InkPresetSnapshot(settings) else { return false }
        return style == other.style && pressureEnabled == other.pressureEnabled
            && drawingOptions == other.drawingOptions
            && zip([red, green, blue, width, opacity],
                   [other.red, other.green, other.blue, other.width, other.opacity])
                .allSatisfy { abs($0 - $1) < 0.001 }
    }
}

struct InkPreset: Codable, Identifiable {
    let id: UUID
    var snapshot: InkPresetSnapshot
}

@MainActor
final class InkPresetStore: ObservableObject {
    static let shared = InkPresetStore()
    static let maximumPresets = 8
    static let defaultsKey = "ink.favoritePens.v1"
    @Published private(set) var presets: [InkPreset]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey), data.count <= 32_768,
           let decoded = try? JSONDecoder().decode([InkPreset].self, from: data),
           decoded.count <= Self.maximumPresets,
           Set(decoded.map(\.id)).count == decoded.count,
           decoded.allSatisfy({ $0.snapshot.isValid }) {
            presets = decoded
        } else {
            presets = Self.initialPresets()
        }
    }

    @discardableResult
    func add(_ settings: InkSettings) -> Bool {
        guard presets.count < Self.maximumPresets, let snapshot = InkPresetSnapshot(settings) else { return false }
        presets.append(InkPreset(id: UUID(), snapshot: snapshot))
        persist()
        return true
    }

    func replace(_ id: UUID, with settings: InkSettings) {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              let snapshot = InkPresetSnapshot(settings) else { return }
        presets[index].snapshot = snapshot
        persist()
    }

    func remove(_ id: UUID) {
        guard presets.contains(where: { $0.id == id }) else { return }
        presets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func initialPresets() -> [InkPreset] {
        let values: [(PDFInkStyle, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (.ink, 0.12, 0.12, 0.14, 2.4), (.ink, 0.12, 0.36, 0.85, 2.4),
            (.fountain, 0.85, 0.22, 0.18, 5), (.highlighter, 0.98, 0.82, 0.08, 14)
        ]
        return values.compactMap { style, red, green, blue, width in
            var settings = InkSettings()
            settings.selectStyle(style)
            settings.color = NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
            settings.width = width
            return InkPresetSnapshot(settings).map { InkPreset(id: UUID(), snapshot: $0) }
        }
    }
}

@MainActor
extension PDFWorkspaceState {
    /// A failed pending text commit must not partly switch the current pen.
    @discardableResult
    func useInkPreset(_ preset: InkPreset) -> Bool {
        guard hasOpenDocument, pageColumns <= 2, allows(.handwriting), preset.snapshot.isValid else { return false }
        selectTool(.pen)
        guard activeTool == .pen else { return false }
        inkSettings = preset.snapshot.settings
        return true
    }
}
