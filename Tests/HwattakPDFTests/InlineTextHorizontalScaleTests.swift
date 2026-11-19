// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class InlineTextHorizontalScaleTests: XCTestCase {
    func testRenderedAdvancesPreservePDFWidthWithoutChangingHeightOrBaseline() throws {
        for (name, text) in [("Helvetica", "Original vector text 012345"),
                             ("AppleSDGothicNeo-Regular", "배추는 안쪽에서부터 사용해야 한다")] {
            for size: CGFloat in [10.3, 24] {
                let base = try XCTUnwrap(NSFont(name: name, size: size))
                let original = metrics(text, font: base)
                for scale: CGFloat in [0.95, 0.98, 1, 1.2] {
                    let style = InlineTextStyle(fontName: name, fontSize: size,
                        textColor: .black, backgroundColor: .clear, alignment: .left,
                        horizontalScale: scale)
                    let rendered = style.renderingFont(base)
                    let actual = metrics(text, font: rendered)
                    XCTAssertEqual(rendered.pointSize, size, accuracy: 0.0001)
                    XCTAssertEqual(actual.width, original.width * scale, accuracy: 0.0001)
                    XCTAssertEqual(actual.ascent, original.ascent, accuracy: 0.0001)
                    XCTAssertEqual(actual.descent, original.descent, accuracy: 0.0001)
                    XCTAssertEqual(actual.leading, original.leading, accuracy: 0.0001)
                    XCTAssertEqual(metrics(text, font: style.font).width, original.width, accuracy: 0.0001,
                                   "Font resolution must remain unscaled until rendering.")
                }
            }
        }
    }

    func testZoomAndRepeatedFontConstructionDoNotCompoundHorizontalScale() throws {
        let style = InlineTextStyle(fontName: "Helvetica", fontSize: 12,
            textColor: .black, backgroundColor: .clear, alignment: .left, horizontalScale: 0.95)
        let text = "Preserved advance"
        let normal = metrics(text, font: style.font)
        let doubled = style.renderingFont(style.font, size: 24)
        let repeated = style.renderingFont(doubled, size: 24)
        XCTAssertEqual(doubled.pointSize, 24, accuracy: 0.0001)
        XCTAssertEqual(metrics(text, font: doubled).width, normal.width * 2 * 0.95, accuracy: 0.0001)
        XCTAssertEqual(metrics(text, font: repeated).width, metrics(text, font: doubled).width, accuracy: 0.0001)
        XCTAssertEqual(metrics(text, font: doubled).ascent, normal.ascent * 2, accuracy: 0.0001)
    }

    func testSystemFontScalingKeepsPointSizeAndGlyphMetricsForBlankInsertions() {
        let text = "Inserted body"
        for weight: NSFont.Weight in [.regular, .bold] {
            for size: CGFloat in [15, 30] {
                let base = NSFont.systemFont(ofSize: size, weight: weight)
                let expected = metrics(text, font: base)
                for scale: CGFloat in [0.95, 1, 1.2] {
                    let style = InlineTextStyle(fontName: base.fontName, fontSize: size,
                        textColor: .black, backgroundColor: .clear, alignment: .left,
                        horizontalScale: scale)
                    let rendered = style.renderingFont(base)
                    let repeated = style.renderingFont(rendered)
                    for actualFont in [rendered, repeated] {
                        let actual = metrics(text, font: actualFont)
                        XCTAssertEqual(actualFont.pointSize, size, accuracy: 0.0001)
                        XCTAssertEqual(actual.width, expected.width * scale, accuracy: 0.0001)
                        XCTAssertEqual(actual.ascent, expected.ascent, accuracy: 0.0001)
                        XCTAssertEqual(actual.descent, expected.descent, accuracy: 0.0001)
                        XCTAssertEqual(actual.leading, expected.leading, accuracy: 0.0001)
                        XCTAssertEqual(CTFontGetSymbolicTraits(actualFont as CTFont),
                                       CTFontGetSymbolicTraits(base as CTFont))
                    }
                }
            }
        }
    }

    func testUnscaledPreviewPreservesAppKitLineMetricsWhenZooming() throws {
        let style = InlineTextStyle(fontName: "Times-Roman", fontSize: 9.9626,
            textColor: .black, backgroundColor: .clear, alignment: .left)
        for zoom: CGFloat in [1, 2] {
            let expected = try XCTUnwrap(NSFont(name: style.fontName, size: style.fontSize * zoom))
            let rendered = style.renderingFont(style.font, size: style.fontSize * zoom)
            let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
            view.string = "Another example of native text"
            let layout = try XCTUnwrap(view.layoutManager)
            let container = try XCTUnwrap(view.textContainer)
            view.font = expected
            layout.ensureLayout(for: container)
            let expectedBaseline = layout.location(forGlyphAt: 0).y
            let expectedLineHeight = layout.defaultLineHeight(for: expected)
            view.font = rendered
            layout.ensureLayout(for: container)
            XCTAssertEqual(layout.location(forGlyphAt: 0).y, expectedBaseline, accuracy: 0.0001)
            XCTAssertEqual(layout.defaultLineHeight(for: rendered), expectedLineHeight, accuracy: 0.0001)
        }
    }

    func testStandardAndAnnotationStylesDefaultToUnscaledText() {
        for purpose in [InlineTextEditPurpose.bodyText, .freeText, .visualReplacement] {
            XCTAssertEqual(InlineTextStyle.standard(for: purpose).horizontalScale, 1)
            let annotation = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 100, height: 40),
                                           forType: .freeText, withProperties: nil)
            annotation.font = NSFont.systemFont(ofSize: 15)
            XCTAssertEqual(InlineTextStyle(annotation: annotation, purpose: purpose).horizontalScale, 1)
        }
    }

    func testHorizontalScaleRejectsInvalidValuesAndBoundsFinitePositiveValues() {
        for (requested, expected) in [(CGFloat.nan, CGFloat(1)), (.infinity, 1),
                                      (-1, 1), (0, 1), (0.01, 0.1), (20, 10)] {
            var style = InlineTextStyle(fontName: "Helvetica", fontSize: 12,
                textColor: .black, backgroundColor: .clear, alignment: .left,
                horizontalScale: requested)
            XCTAssertEqual(style.horizontalScale, expected)
            style.horizontalScale = requested
            style.normalize()
            XCTAssertEqual(style.horizontalScale, expected)
        }
    }

    func testBodyPanelPreservesWidthThroughTypingZoomAndFontSizeChanges() throws {
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 246))
        for (name, size) in [("Helvetica", CGFloat(10.3)), ("Times-Roman", 16)] {
            let style = InlineTextStyle(fontName: name, fontSize: size,
                textColor: .black, backgroundColor: .clear, alignment: .left,
                horizontalScale: 0.98)
            panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
                isEditingExistingAnnotation: false, purpose: .bodyText,
                text: "Original text", style: style))
            for zoom: CGFloat in [1, 2, 4, 1] {
                panel.setTextPresentationScale(zoom)
                panel.textView.string = "Changed text"
                panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.textView))
                let font = try XCTUnwrap(panel.textView.font)
                let unscaled = try XCTUnwrap(NSFont(name: name, size: size * zoom))
                XCTAssertEqual(panel.currentStyle.horizontalScale, 0.98)
                XCTAssertEqual(panel.currentStyle.fontSize, size)
                XCTAssertEqual(font.pointSize, size * zoom, accuracy: 0.0001)
                XCTAssertEqual(metrics(panel.currentText, font: font).width,
                               metrics(panel.currentText, font: unscaled).width * 0.98, accuracy: 0.0001)
                XCTAssertEqual(metrics(panel.currentText, font: font).ascent,
                               metrics(panel.currentText, font: unscaled).ascent, accuracy: 0.0001)
            }
        }
    }

    private func metrics(_ text: String, font: NSFont)
        -> (width: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (CGFloat(width), ascent, descent, leading)
    }
}
