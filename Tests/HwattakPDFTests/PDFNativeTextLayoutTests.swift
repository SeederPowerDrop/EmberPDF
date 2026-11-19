// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFNativeTextLayoutTests: XCTestCase {
    @MainActor
    func testLigaturesMultilingualTextAndFinalCharactersMatchNativeLines() throws {
        for font in ["Helvetica", "Times-Italic"] {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let consumer = try XCTUnwrap(CGDataConsumer(data: data))
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            for (row, text) in [
                "office efficiently: fi fl ffi.",
                "Preserve the final character!",
                "한국어 선택 영역 — café, á."
            ].enumerated() {
                context.textPosition = CGPoint(x: 40, y: 700 - row * 30)
                let attributed = NSAttributedString(string: text,
                    attributes: [.font: CTFontCreateWithName(font as CFString, 16, nil)])
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
            context.closePDF()
            let document = try XCTUnwrap(PDFDocument(data: data as Data))
            let page = try XCTUnwrap(document.page(at: 0))
            let originalText = page.string
            let native = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
                .selectionsByLine()

            for rotation in [0, 90, 180, 270] {
                page.rotation = rotation
                let layout = try XCTUnwrap(PDFNativeTextLayout.makeLines(for: page))
                XCTAssertEqual(layout.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) },
                               native.map { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) })
                XCTAssertEqual(layout.count, 3)
                XCTAssertTrue(layout[0].text.hasSuffix("ffi."))
                XCTAssertTrue(layout[1].text.hasSuffix("character!"))
                for line in layout {
                    XCTAssertEqual(line.text.count, line.characterBounds.count)
                    for (character, bounds) in zip(line.text, line.characterBounds) where !character.isWhitespace {
                        XCTAssertNotNil(bounds)
                    }
                }
            }
            XCTAssertEqual(page.string, originalText)
        }
    }

    @MainActor
    func testZeroWidthSpacesAndExpandedLineEndRangesPreserveTextOnce() throws {
        let page = NativeLayoutProbePage()

        let layout = try XCTUnwrap(PDFNativeTextLayout.makeLines(for: page))

        XCTAssertEqual(layout.count, 1)
        XCTAssertEqual(layout.first?.text, "a b")
        XCTAssertEqual(layout.first?.characterBounds.count, 3)
        XCTAssertNil(layout.first?.characterBounds[1])
        XCTAssertEqual(page.requestedCharacterIndices, [0, 1, 2])
    }
}

private final class NativeLayoutProbePage: PDFPage {
    var requestedCharacterIndices: [Int] = []
    override var numberOfCharacters: Int { 4 }

    override func selection(for range: NSRange) -> PDFSelection? {
        if range.length == 4 {
            return NativeLayoutProbeSelection(text: "a b", range: range,
                bounds: CGRect(x: 20, y: 40, width: 25, height: 10))
        }
        requestedCharacterIndices.append(range.location)
        if range.location == 1 {
            return NativeLayoutProbeSelection(text: " ", range: range, bounds: .zero)
        }
        if range.location == 0 {
            return NativeLayoutProbeSelection(text: "a", range: range,
                bounds: CGRect(x: 20, y: 40, width: 10, height: 10))
        }
        // PDFKit expands the last glyph's range over its synthesized newline;
        // querying either UTF-16 position produces the same character again.
        return NativeLayoutProbeSelection(text: "b", range: NSRange(location: 2, length: 2),
            bounds: CGRect(x: 35, y: 40, width: 10, height: 10))
    }
}

private final class NativeLayoutProbeSelection: PDFSelection {
    private let text: String
    private let selectedRange: NSRange
    private let selectedBounds: CGRect

    init(text: String, range: NSRange, bounds: CGRect) {
        self.text = text
        selectedRange = range
        selectedBounds = bounds
        super.init(document: PDFDocument())
    }

    override var string: String? { text }
    override func bounds(for page: PDFPage) -> CGRect { selectedBounds }
    override func selectionsByLine() -> [PDFSelection] { [self] }
    override func numberOfTextRanges(on page: PDFPage) -> Int { 1 }
    override func range(at index: Int, on page: PDFPage) -> NSRange { selectedRange }
}
