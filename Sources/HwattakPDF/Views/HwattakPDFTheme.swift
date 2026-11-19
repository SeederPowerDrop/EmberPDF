// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Warm, low-chroma surfaces make the document the visual center. Ember is
/// reserved for selection and actions; ordinary text keeps neutral contrast.
struct HwattakPDFTheme {
    let colorScheme: ColorScheme
    let readingTheme: PDFReadingTheme

    init(colorScheme: ColorScheme, readingTheme: PDFReadingTheme = .original) {
        self.colorScheme = colorScheme
        self.readingTheme = readingTheme
    }

    private var isDark: Bool { readingTheme == .night || colorScheme == .dark }
    private static let darkCanvas: UInt32 = 0x1D1C1A
    private static let lightCanvas: UInt32 = 0xEDEAE5

    private func color(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: Self.nativeColor(isDark ? dark : light))
    }

    private static func nativeColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xff) / 255,
                green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255, alpha: 1)
    }

    private var surfaces: (canvas: UInt32, sidebar: UInt32, panel: UInt32,
                           card: UInt32, chrome: UInt32, raised: UInt32) {
        switch readingTheme {
        case .original:
            return isDark ? (Self.darkCanvas, 0x23221F, 0x292723, 0x302E29, 0x211F1D, 0x35312B)
                          : (Self.lightCanvas, 0xF3F0EB, 0xF7F4EF, 0xFFFDFA, 0xE8E4DD, 0xFFFDFA)
        case .soft:
            return isDark ? (0x232422, 0x292A27, 0x2E302C, 0x353732, 0x252623, 0x393C35)
                          : (0xE2E2D9, 0xE9E9E0, 0xEEEDE5, 0xF1EEE7, 0xDDDED5, 0xF1EEE7)
        case .sepia:
            return isDark ? (0x27221C, 0x2E2821, 0x352D24, 0x3B3329, 0x2A241D, 0x42382C)
                          : (0xDECFB5, 0xE5D7BE, 0xEADDC6, 0xEFE3CD, 0xD8C8AB, 0xEFE3CD)
        case .night:
            return (0x1B1F1C, 0x212622, 0x262C27, 0x2C332D, 0x1E231F, 0x333B34)
        }
    }

    var canvas: Color { Color(nsColor: Self.nativeColor(surfaces.canvas)) }
    var sidebar: Color { Color(nsColor: Self.nativeColor(surfaces.sidebar)) }
    var panel: Color { Color(nsColor: Self.nativeColor(surfaces.panel)) }
    var card: Color { Color(nsColor: Self.nativeColor(surfaces.card)) }
    var chrome: Color { Color(nsColor: Self.nativeColor(surfaces.chrome)) }
    var chromeRaised: Color { Color(nsColor: Self.nativeColor(surfaces.raised)) }

    var primaryText: Color { color(0xE7E1D8, 0x302B25) }
    var secondaryText: Color { color(0xACA49A, 0x6B6258) }
    var accent: Color {
        readingTheme == .night ? Color(nsColor: Self.nativeColor(0xC9B28C))
            : color(0xD6A56F, 0x905523)
    }
    /// Text on a solid accent button needs a different contrast pairing.
    var accentForeground: Color { color(0x251C13, 0xFFFDFA) }

    var border: Color { color(0xBDB09D, 0x625443).opacity(isDark ? 0.16 : 0.14) }
    var selectionFill: Color { accent.opacity(isDark ? 0.12 : 0.08) }
    var selectionBorder: Color { accent.opacity(isDark ? 0.62 : 0.60) }
    var hoverFill: Color { color(0xE7E1D8, 0x625443).opacity(isDark ? 0.055 : 0.06) }
    var focusRing: Color { accent }
    var dropHighlight: Color { accent.opacity(isDark ? 0.20 : 0.12) }
    var elevatedShadow: Color { Color.black.opacity(isDark ? 0.20 : 0.07) }

    var success: Color { color(0x79BA96, 0x356C4B) }
    var warning: Color { color(0xE2B775, 0x8E5C1E) }

    // Existing call sites retain their semantic roles while using Ember hues.
    var brandNavy: Color { Color(nsColor: Self.nativeColor(0x30281F)) }
    var ink: Color { Color(nsColor: Self.nativeColor(0x453B30)) }
    var steel: Color { accent }
    var ribbon: Color { color(0xDE987D, 0xA64C32) }
    var ribbonSoft: Color { ribbon.opacity(isDark ? 0.16 : 0.10) }
    var ribbonLabel: Color { Color(nsColor: Self.nativeColor(0x8B3E29)) }
    var paperIvory: Color { Color(nsColor: Self.nativeColor(0xFFFDFA)) }
    var cream: Color { Color(nsColor: Self.nativeColor(0xFFF3DF)) }
    var chromeText: Color { primaryText }
    var chromeSecondaryText: Color { secondaryText }

    /// PDFKit follows native appearance changes while sharing the SwiftUI
    /// canvas palette. This changes only the space around a PDF, never its ink.
    static var adaptiveCanvasColor: NSColor {
        NSColor(name: nil) { appearance in
            nativeColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? darkCanvas : lightCanvas)
        }
    }
}

/// Every consumer observes both preferences directly, including auxiliary
/// windows without an AppPreferences environment object. Updating paper colors
/// invalidates display values without replacing the reader or its document.
@propertyWrapper
struct EmberTheme: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PDFReadingTheme.defaultsKey)
    private var readingThemeValue = PDFReadingTheme.original.rawValue

    var wrappedValue: HwattakPDFTheme {
        HwattakPDFTheme(colorScheme: colorScheme,
                       readingTheme: PDFReadingTheme(rawValue: readingThemeValue) ?? .original)
    }
}

/// Use the same accent in auxiliary windows, sheets and native SwiftUI controls.
private struct EmberTintModifier: ViewModifier {
    @EmberTheme private var theme

    func body(content: Content) -> some View {
        content.tint(theme.accent).accentColor(theme.accent)
    }
}

/// Quiet hover/press feedback without animated glow or layout movement.
struct EmberToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        @EmberTheme private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(theme.primaryText)
                .background(
                    isEnabled && configuration.isPressed ? theme.selectionFill
                        : (isEnabled && isHovered ? theme.hoverFill : Color.clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .opacity(isEnabled ? 1 : 0.38)
                .onHover { isHovered = $0 }
        }
    }
}

enum HwattakPDFRelease {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.0"
    }

    static var badge: String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }
}

private struct HwattakPDFCardModifier: ViewModifier {
    let theme: HwattakPDFTheme
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(theme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }

    }
}

extension View {
    func emberTint() -> some View { modifier(EmberTintModifier()) }

    func hwattakPDFCard(_ theme: HwattakPDFTheme, cornerRadius: CGFloat = 14) -> some View {
        modifier(HwattakPDFCardModifier(theme: theme, cornerRadius: cornerRadius))
    }
}
