// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A display preference, independent of document data and the user's native
/// system/light/dark preference. Positive RGB multiplication keeps black ink
/// and avoids turning photographs into negatives.
enum PDFReadingTheme: String, CaseIterable, Identifiable, Codable {
    case original
    case soft
    case sepia
    case night

    static let defaultsKey = "preferences.readingTheme"
    var id: String { rawValue }
    var title: String { L10n.string("reading.\(rawValue)") }
    var detail: String { L10n.string("reading.\(rawValue).detail") }

    var paperRGB: (red: Double, green: Double, blue: Double) {
        let hex: UInt32
        switch self {
        case .original: hex = 0xFFFFFF
        case .soft: hex = 0xF1EEE7
        case .sepia: hex = 0xE8D7B7
        case .night: hex = 0x989B92
        }
        return (Double((hex >> 16) & 0xFF) / 255,
                Double((hex >> 8) & 0xFF) / 255,
                Double(hex & 0xFF) / 255)
    }
}
