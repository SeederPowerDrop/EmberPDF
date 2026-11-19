// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyLeadingSpaceDrawingTests: XCTestCase {
    private let style = InlineTextStyle(fontName: "Courier", fontSize: 10,
        textColor: .black, backgroundColor: .clear, alignment: .left)

    private func attributed(prefix: String = " ", draft: String? = nil,
                            retainSource: Bool = true) -> NSAttributedString {
        let source = prefix + "alphaCode"
        let runs = [
            InlineTextSourceRun(range: NSRange(location: 0, length: prefix.utf16.count),
                style: style, horizontalAdvance: 30),
            InlineTextSourceRun(range: NSRange(location: prefix.utf16.count, length: 9), style: style)
        ]
        return PDFBodyTextAttributedLayout.attributedString(text: draft ?? prefix + "alphaCade",
            style: style, sourceText: source, sourceStyle: style,
            sourceRuns: retainSource ? runs : [])
    }

    func testOnlyUnchangedSingleSourceSpaceReceivesDrawingPlan() throws {
        let text = attributed()
        let plan = try XCTUnwrap(PDFBodyLeadingSpaceDrawing.make(
            line: CTLineCreateWithAttributedString(text), text: text))
        XCTAssertEqual(plan.positions[0].x, 0, accuracy: 0.01)
        XCTAssertEqual(plan.positions[1].x, 30, accuracy: 0.01)
        for other in [attributed(retainSource: false), attributed(prefix: "   "),
                      attributed(draft: "alphaCade"), attributed(draft: "XalphaCade"),
                      attributed(draft: "  alphaCade")] {
            XCTAssertNil(try PDFBodyLeadingSpaceDrawing.make(
                line: CTLineCreateWithAttributedString(other), text: other))
        }
        let multiple = attributed(prefix: "   ")
        XCTAssertNil(multiple.attribute(PDFBodyLeadingSpaceDrawing.preservedAdvanceAttribute,
            at: 0, effectiveRange: nil), "Multiple source spaces keep the existing renderer; native cardinality is unresolved.")
    }

    func testUnsupportedDecorationOrChangedGeometryKeepsExistingDraw() throws {
        for mutation in ["underline", "stroke", "kern", "baseline", "font", "color", "matrix"] {
            let text = NSMutableAttributedString(attributedString: attributed())
            let remainder = NSRange(location: 1, length: text.length - 1)
            switch mutation {
            case "underline": text.addAttribute(.underlineStyle, value: 1, range: remainder)
            case "stroke": text.addAttribute(.strokeWidth, value: -2, range: remainder)
            case "kern": text.addAttribute(.kern, value: 0, range: remainder)
            case "baseline": text.addAttribute(.baselineOffset, value: 1, range: remainder)
            case "font": text.addAttribute(.font, value: try XCTUnwrap(NSFont(name: "Helvetica", size: 10)), range: remainder)
            case "color": text.addAttribute(.foregroundColor, value: NSColor.blue, range: remainder)
            default:
                let font = try XCTUnwrap(text.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
                var matrix = CGAffineTransform(scaleX: 1.5, y: 1)
                text.addAttribute(.font, value: CTFontCreateCopyWithAttributes(font as CTFont, 10, &matrix, nil), range: remainder)
            }
            XCTAssertNil(try PDFBodyLeadingSpaceDrawing.make(
                line: CTLineCreateWithAttributedString(text), text: text), mutation)
        }
    }
}
