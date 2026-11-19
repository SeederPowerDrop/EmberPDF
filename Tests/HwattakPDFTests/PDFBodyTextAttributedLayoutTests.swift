// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextAttributedLayoutTests: XCTestCase {
    private let base = InlineTextStyle(fontName: "AppleMyungjo", fontSize: 10,
        textColor: .black, backgroundColor: .clear, alignment: .left, horizontalScale: 0.97)
    private let number = InlineTextStyle(fontName: "Helvetica", fontSize: 10.3,
        textColor: .black, backgroundColor: .clear, alignment: .left)

    func testMiddleReplacementInheritsItsRunAndPreservesSurroundingFontsAndBaselines() throws {
        let source = "앞 12 뒤"
        let result = PDFBodyTextAttributedLayout.attributedString(text: "앞 4567 뒤", style: base,
            sourceText: source, sourceStyle: base, sourceRuns: runs(source), textScale: 2)
        try assertFont(result, at: 0, name: base.fontName, size: 20, horizontalScale: 0.97)
        for index in 2..<6 {
            try assertFont(result, at: index, name: number.fontName, size: 20.6, horizontalScale: 1)
            XCTAssertEqual(try offset(result, at: index), 0.8, accuracy: 0.0001)
        }
        try assertFont(result, at: 7, name: base.fontName, size: 20, horizontalScale: 0.97)
        XCTAssertEqual(try offset(result, at: 7), 0, accuracy: 0.0001)
    }

    func testCharacterBoundariesKeepEmojiSuffixAndItsFormattingAfterInsertion() throws {
        let source = "앞 12 👨‍👩‍👧‍👦 뒤"
        let changed = "앞 새로운 12 👨‍👩‍👧‍👦 뒤"
        let result = PDFBodyTextAttributedLayout.attributedString(text: changed, style: base,
            sourceText: source, sourceStyle: base, sourceRuns: runs(source))
        // Inserting Korean immediately before a numeric run inherits that
        // run's style, but fallback for the new glyphs must not change the
        // unmodified Helvetica digits that follow it.
        let inserted = (changed as NSString).range(of: "새로운")
        let insertedFont = try XCTUnwrap(result.attribute(.font, at: inserted.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(insertedFont.fontName,
                       PDFBodyTextEditor.replacementFont(for: "새로운 ", preferred: number.font).fontName)
        let digits = (changed as NSString).range(of: "12")
        try assertFont(result, at: digits.location, name: number.fontName, size: 10.3, horizontalScale: 1)
        XCTAssertEqual(try offset(result, at: digits.location), 0.4, accuracy: 0.0001)
        let suffix = (changed as NSString).range(of: "뒤")
        try assertFont(result, at: suffix.location, name: base.fontName, size: 10, horizontalScale: 0.97)
        XCTAssertEqual(result.string, changed)
    }

    func testExplicitStyleChangeUsesOneFontAndClearsSourceBaselineOffsets() throws {
        let source = "앞 12 뒤"
        var changedStyle = base
        changedStyle.fontSize = 20
        let result = PDFBodyTextAttributedLayout.attributedString(text: source, style: changedStyle,
            sourceText: source, sourceStyle: base, sourceRuns: runs(source))
        for index in 0..<result.length {
            try assertFont(result, at: index, name: base.fontName, size: 20, horizontalScale: 0.97)
            XCTAssertEqual(try offset(result, at: index), 0, accuracy: 0.0001)
        }
    }

    func testOnlyFirstLogicalLineHasIndentAndLineHeightScalesWithPreview() throws {
        let text = "들여쓴 첫 줄\n다음 줄\n마지막 줄"
        let result = PDFBodyTextAttributedLayout.attributedString(text: text, style: base,
            lineHeight: 14, firstLineIndent: 15.25, textScale: 2)
        for (phrase, expectedIndent) in [("들여쓴", CGFloat(30.5)), ("다음", 0), ("마지막", 0)] {
            let index = (text as NSString).range(of: phrase).location
            let paragraph = try XCTUnwrap(result.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(paragraph.firstLineHeadIndent, expectedIndent, accuracy: 0.0001)
            XCTAssertEqual(paragraph.minimumLineHeight, 28, accuracy: 0.0001)
            XCTAssertEqual(paragraph.maximumLineHeight, 28, accuracy: 0.0001)
        }
    }

    func testPanelUsesTheSameSourceRunsAfterTypingAndZooming() throws {
        let source = "앞 12 뒤"
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 246))
        panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
            isEditingExistingAnnotation: false, purpose: .bodyText, text: source, style: base,
            initialSelectedRange: NSRange(location: 2, length: 2), bodyTextLineHeight: 14,
            bodyTextFirstLineIndent: 15.25, bodyTextSourceText: source,
            bodyTextSourceStyle: base, bodyTextSourceRuns: runs(source)))
        XCTAssertEqual(panel.textView.selectedRange(), NSRange(location: 2, length: 2))
        panel.textView.insertText("4567", replacementRange: panel.textView.selectedRange())
        panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.textView))
        panel.setTextPresentationScale(2)
        let storage = try XCTUnwrap(panel.textView.textStorage)
        XCTAssertEqual(storage.string, "앞 4567 뒤")
        try assertFont(storage, at: 2, name: number.fontName, size: 20.6, horizontalScale: 1)
        try assertFont(storage, at: 7, name: base.fontName, size: 20, horizontalScale: 0.97)
        XCTAssertEqual(try offset(storage, at: 2), 0.8, accuracy: 0.0001)
    }

    func testInsertedWhitespaceSharesTheWholeRunKoreanFallbackFont() throws {
        let style = InlineTextStyle(fontName: "Helvetica", fontSize: 12,
            textColor: .black, backgroundColor: .clear, alignment: .left)
        let source = "한 글"
        let text = "한  글"
        let expected = PDFBodyTextEditor.replacementFont(for: text, preferred: style.font)
        XCTAssertNotEqual(expected.fontName, style.fontName, "Fixture must require a Korean fallback.")
        let fragmented = (0..<source.utf16.count).map {
            InlineTextSourceRun(range: NSRange(location: $0, length: 1), style: style)
        }
        for sourceRuns in [[InlineTextSourceRun(range: NSRange(location: 0, length: source.utf16.count), style: style)], fragmented] {
            let result = PDFBodyTextAttributedLayout.attributedString(text: text, style: style,
                sourceText: source, sourceStyle: style, sourceRuns: sourceRuns)
            for index in 0..<result.length {
                let font = try XCTUnwrap(result.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(font.fontName, expected.fontName,
                               "Spaces must not switch back to Helvetica after resolving a Korean run.")
            }
        }
    }

    func testColorWellRoundingDoesNotDiscardMixedSourceFonts() throws {
        let source = "앞 12 뒤"
        var original = base
        original.textColor = PDFTextColor(red: 0.270588, green: 0.4, blue: 0.59, alpha: 1)
        var roundTripped = original
        roundTripped.textColor = PDFTextColor(original.textColor.nsColor)
        // Include a deterministic sub-channel conversion difference even on
        // machines whose active color profile happens to round-trip exactly.
        roundTripped.textColor.red = original.textColor.red + 0.0002
        XCTAssertNotEqual(roundTripped, original)
        XCTAssertTrue(roundTripped.textColor.visuallyEquals(original.textColor))
        let result = PDFBodyTextAttributedLayout.attributedString(text: source, style: roundTripped,
            sourceText: source, sourceStyle: original, sourceRuns: runs(source))
        try assertFont(result, at: 2, name: number.fontName, size: 10.3, horizontalScale: 1)
        XCTAssertEqual(try offset(result, at: 2), 0.4, accuracy: 0.0001)

        var changed = original
        changed.textColor = PDFTextColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1)
        let uniform = PDFBodyTextAttributedLayout.attributedString(text: source, style: changed,
            sourceText: source, sourceStyle: original, sourceRuns: runs(source))
        try assertFont(uniform, at: 2, name: base.fontName, size: 10, horizontalScale: 0.97)
        XCTAssertEqual(try offset(uniform, at: 2), 0, accuracy: 0.0001)
    }

    func testSourceAdvanceCorrectsFallbackWidthAndLongerReplacementKeepsTheSameRatio() throws {
        let source = "가나다"
        let originalFont = base.renderingFont(base.font)
        let originalAdvance = width(source, font: originalFont) * 0.88
        let sourceRuns = [InlineTextSourceRun(range: NSRange(location: 0, length: source.utf16.count),
            style: base, horizontalAdvance: originalAdvance)]
        for text in [source, "가나다라마"] {
            for zoom: CGFloat in [1, 2] {
                let result = PDFBodyTextAttributedLayout.attributedString(text: text, style: base,
                    sourceText: source, sourceStyle: base, sourceRuns: sourceRuns, textScale: zoom)
                let font = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(font.pointSize, base.fontSize * zoom, accuracy: 0.0001)
                XCTAssertEqual(CTFontGetMatrix(font as CTFont).a, base.horizontalScale * 0.88, accuracy: 0.0001)
                XCTAssertEqual(CTFontGetMatrix(font as CTFont).d, 1, accuracy: 0.0001)
                XCTAssertEqual(width(text, font: font), width(text, font: originalFont) * 0.88 * zoom, accuracy: 0.0001)
                if text != source {
                    XCTAssertGreaterThan(width(text, font: font), originalAdvance * zoom,
                                         "New words must not be squeezed to the old total advance.")
                }
            }
        }
    }

    func testAdvanceCorrectionIsBoundedAndDoesNotAlterAlreadyMatchingNumbers() throws {
        let text = "123"
        let measured = width(text, font: number.font)
        for ratio: CGFloat in [0.4, 1, 1.0005, 2.1, .nan] {
            let result = PDFBodyTextAttributedLayout.attributedString(text: text, style: number,
                sourceText: text, sourceStyle: number,
                sourceRuns: [InlineTextSourceRun(range: NSRange(location: 0, length: text.utf16.count),
                    style: number, horizontalAdvance: measured * ratio)])
            let font = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(CTFontGetMatrix(font as CTFont).a, 1, accuracy: 0.0001)
            XCTAssertEqual(width(text, font: font), measured, accuracy: 0.0001)
        }
    }

    func testExplicitSizeChangeDoesNotReuseOriginalAdvanceCorrection() throws {
        let text = "가나다"
        var changed = base
        changed.fontSize = 20
        let result = PDFBodyTextAttributedLayout.attributedString(text: text, style: changed,
            sourceText: text, sourceStyle: base,
            sourceRuns: [InlineTextSourceRun(range: NSRange(location: 0, length: text.utf16.count), style: base,
                horizontalAdvance: width(text, font: base.renderingFont(base.font)) * 0.88)])
        try assertFont(result, at: 0, name: changed.fontName, size: 20, horizontalScale: changed.horizontalScale)
    }

    func testPositionedSpaceKeepsItsWidthButNewWordDoesNotInheritTheGapScale() throws {
        let style = InlineTextStyle(fontName: "Helvetica", fontSize: 12,
            textColor: .black, backgroundColor: .clear, alignment: .left, horizontalScale: 0.97)
        let originalFont = style.renderingFont(style.font)
        let gapAdvance = width(" ", font: originalFont) * 1.5
        let source = "A B"
        let sourceRuns = [InlineTextSourceRun(range: NSRange(location: 0, length: 1), style: style),
                          InlineTextSourceRun(range: NSRange(location: 1, length: 1), style: style,
                                              horizontalAdvance: gapAdvance),
                          InlineTextSourceRun(range: NSRange(location: 2, length: 1), style: style)]
        for zoom: CGFloat in [1, 2] {
            let preserved = PDFBodyTextAttributedLayout.attributedString(text: source, style: style,
                sourceText: source, sourceStyle: style, sourceRuns: sourceRuns, textScale: zoom)
            let gapFont = try XCTUnwrap(preserved.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(width(" ", font: gapFont), gapAdvance * zoom, accuracy: 0.0001)
            XCTAssertEqual(CTFontGetMatrix(gapFont as CTFont).a, 0.97 * 1.5, accuracy: 0.0001)

            // Replacing the selected space starts the changed range inside
            // the gap run, so the new word inherits its face but not its gap.
            let edited = PDFBodyTextAttributedLayout.attributedString(text: "AwordB", style: style,
                sourceText: source, sourceStyle: style, sourceRuns: sourceRuns, textScale: zoom)
            for index in 1..<5 {
                try assertFont(edited, at: index, name: style.fontName, size: 12 * zoom, horizontalScale: 0.97)
            }
            let wordFont = try XCTUnwrap(edited.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(width("word", font: wordFont), width("word", font: originalFont) * zoom, accuracy: 0.0001)
        }
    }

    private func width(_ text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func runs(_ text: String) -> [InlineTextSourceRun] {
        let digits = (text as NSString).range(of: "12")
        return [InlineTextSourceRun(range: NSRange(location: 0, length: digits.location), style: base),
                InlineTextSourceRun(range: digits, style: number, baselineOffset: 0.4),
                InlineTextSourceRun(range: NSRange(location: NSMaxRange(digits), length: text.utf16.count - NSMaxRange(digits)), style: base)]
    }

    private func assertFont(_ text: NSAttributedString, at index: Int, name: String,
                            size: CGFloat, horizontalScale: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let font = try XCTUnwrap(text.attribute(.font, at: index, effectiveRange: nil) as? NSFont, file: file, line: line)
        XCTAssertEqual(font.fontName, name, file: file, line: line)
        XCTAssertEqual(font.pointSize, size, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(CTFontGetMatrix(font as CTFont).a, horizontalScale, accuracy: 0.0001, file: file, line: line)
    }

    private func offset(_ text: NSAttributedString, at index: Int) throws -> CGFloat {
        CGFloat(try XCTUnwrap(text.attribute(.baselineOffset, at: index, effectiveRange: nil) as? NSNumber).doubleValue)
    }
}
