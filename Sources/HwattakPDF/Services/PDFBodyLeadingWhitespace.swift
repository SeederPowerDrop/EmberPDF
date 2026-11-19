// SPDX-License-Identifier: MPL-2.0
// Pure bounded evidence check for a positioned leading whitespace run.
import CoreGraphics
import Foundation

enum PDFBodyLeadingWhitespace {
    struct Sample {
        let scalar: UInt32
        let origin: CGPoint
        let linear: CGAffineTransform
        let generated: Bool
    }
    struct Fragment {
        let range: NSRange
        let horizontalAdvance: CGFloat?
    }
    struct Proof {
        let nativeText: String
        let ownedText: String
        let leadingUTF16: Int
        let advance: CGFloat

        func fragments(for content: String, offset: Int, remainderAdvance: CGFloat?) -> [Fragment]? {
            guard content.utf16.elementsEqual(nativeText.utf16) || content.utf16.elementsEqual(ownedText.utf16),
                  offset >= 0, offset <= Int.max - content.utf16.count,
                  leadingUTF16 > 0, leadingUTF16 < content.utf16.count else { return nil }
            let remaining: CGFloat?
            if let remainderAdvance {
                guard remainderAdvance.isFinite, remainderAdvance > advance else { return nil }
                remaining = remainderAdvance - advance
            } else { remaining = nil }
            return [Fragment(range: NSRange(location: offset, length: leadingUTF16), horizontalAdvance: advance),
                    Fragment(range: NSRange(location: offset + leadingUTF16,
                        length: content.utf16.count - leadingUTF16), horizontalAdvance: remaining)]
        }
    }
    static let maximumLeadingCharacters = 64

    /// ASCII spaces only initially. Tabs, semantic normalization, generated
    /// letters, multi-row objects and unknown character evidence do not prove
    /// a positioned leading-space run.
    static func prove(nativeText: String, ownedText: String, samples: [Sample],
                      sourceOrigin: CGPoint, fontSize: CGFloat) -> Proof? {
        guard !nativeText.isEmpty, ownedText.utf16.first == 0x20,
              nativeText.utf16.count <= 65_536, !ownedText.contains("\n"), !ownedText.contains("\r"),
              sourceOrigin.x.isFinite, sourceOrigin.y.isFinite,
              fontSize.isFinite, fontSize > 0 else { return nil }
        let nativeUnits = Array(nativeText.utf16), ownedUnits = Array(ownedText.utf16)
        guard nativeUnits.starts(with: ownedUnits),
              nativeUnits.dropFirst(ownedUnits.count).allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return nil }
        let leading = ownedText.unicodeScalars.prefix { $0.value == 0x20 }.count
        guard leading > 0, leading <= maximumLeadingCharacters,
              leading < ownedText.unicodeScalars.count, samples.count == leading + 1,
              let first = samples.first, let visible = samples.last, !visible.generated,
              visible.scalar != 0, let firstVisible = UnicodeScalar(visible.scalar),
              !CharacterSet.whitespacesAndNewlines.contains(firstVisible),
              first.origin == sourceOrigin else { return nil }
        let expected = Array(ownedText.unicodeScalars.prefix(leading + 1)).map(\.value)
        guard samples.map(\.scalar) == expected else { return nil }
        let coefficients = [first.linear.a, first.linear.b, first.linear.c, first.linear.d]
        guard coefficients.allSatisfy(\.isFinite), first.linear.a > 0, first.linear.d > 0,
              abs(first.linear.b) < 0.000_001, abs(first.linear.c) < 0.000_001 else { return nil }
        var lastX = sourceOrigin.x
        for sample in samples {
            let actual = [sample.linear.a, sample.linear.b, sample.linear.c, sample.linear.d]
            guard sample.origin.x.isFinite, sample.origin.y.isFinite,
                  sample.origin.x >= lastX, abs(sample.origin.y - sourceOrigin.y) <= 0.01,
                  zip(actual, coefficients).allSatisfy({ $0.isFinite && abs($0 - $1) <= 0.000_001 }) else { return nil }
            lastX = sample.origin.x
        }
        let advance = visible.origin.x - sourceOrigin.x
        guard advance.isFinite, advance > 0, advance <= min(256, max(48, fontSize * 8)) else { return nil }
        return Proof(nativeText: nativeText, ownedText: ownedText, leadingUTF16: leading, advance: advance)
    }
}
