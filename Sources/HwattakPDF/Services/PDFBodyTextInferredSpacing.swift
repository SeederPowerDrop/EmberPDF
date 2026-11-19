// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Infers a missing word separator only; never removes source-owned whitespace.
/// Han glyph bearings are not word boundaries. Mixed-script and Hangul/Latin
/// pairs retain the existing rule until independently supported otherwise.
enum PDFBodyTextInferredSpacing {
    static func needsSpace(before: String, after: String, gap: CGFloat, fontSize: CGFloat) -> Bool {
        guard gap > fontSize * 0.15, let left = before.last, let right = after.first else { return false }
        guard !isHanIdeograph(left) || !isHanIdeograph(right) else { return false }
        return (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber)
    }

    private static func isHanIdeograph(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let base = scalars.first else { return false }
        // Use the runtime's Unicode table for unified ideographs, including
        // supplementary extensions. Compatibility ideographs not included in
        // that property are admitted only in their two dedicated Han blocks.
        // isIdeographic alone would also change Tangut and Nushu boundaries.
        let compatibility = (0xF900...0xFAFF).contains(base.value)
            || (0x2F800...0x2FA1F).contains(base.value)
        guard base.properties.isUnifiedIdeograph
            || (compatibility && base.properties.isIdeographic) else { return false }
        // An ideographic variation selector stays with its base. Other marks,
        // Kana, radicals, iteration marks and symbols keep the previous policy.
        return scalars.dropFirst().allSatisfy {
            (0xFE00...0xFE0F).contains($0.value) || (0xE0100...0xE01EF).contains($0.value)
        }
    }
}
