// SPDX-License-Identifier: MPL-2.0

import AppKit

/// The editing surface must stay readable even when a PDF uses transparent
/// paper or pale ink. These display colors never flow back into the draft;
/// the color wells continue to hold the document's original RGBA values.
struct PDFInlineTextEditorAppearance {
    let ink: NSColor
    let paper: NSColor

    init(style: InlineTextStyle) {
        ink = style.textColor.nsColor.withAlphaComponent(1)
        let inkLuminance = Self.luminance(style.textColor)
        let paperLuminance = Self.luminance(style.backgroundColor)
        if style.backgroundColor.alpha >= 0.999,
           Self.contrast(inkLuminance, paperLuminance) >= 4.5 {
            paper = style.backgroundColor.nsColor.withAlphaComponent(1)
        } else {
            paper = Self.contrast(inkLuminance, 1) >= Self.contrast(inkLuminance, 0)
                ? .white : .black
        }
    }

    private static func luminance(_ color: PDFTextColor) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private static func contrast(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
