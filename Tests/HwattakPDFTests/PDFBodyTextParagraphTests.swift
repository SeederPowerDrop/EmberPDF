// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextParagraphTests: XCTestCase {
    func testPartialMultilineSelectionAcceptsIndentedMixedScriptParagraph() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let original = try PDFBodyTextPageSnapshot.data(for: page)
        let selected = try selection(from: "차분하게", through: "기록합니다.", on: page)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
        let range = try XCTUnwrap(target.initialSelectedRange)
        XCTAssertEqual((target.text as NSString).substring(with: range), selected.string)
        XCTAssertTrue(target.text.contains("첫 문장은"))
        XCTAssertTrue(target.text.contains("0.00"))
        XCTAssertEqual(target.baseline.x, 55.2544, accuracy: 0.05)
        XCTAssertEqual(target.baseline.y, 280, accuracy: 0.05)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), original)
    }

    func testParagraphEditSaveReopenKeepsIndentAndNumericFormatting() throws {
        let original = try fixture()
        let originalPage = try XCTUnwrap(original.page(at: 0))
        let originalBytes = try PDFBodyTextPageSnapshot.data(for: originalPage)
        var source = original
        for (before, after) in [("차분하게", "꼼꼼하게"), ("꼼꼼하게", "차분하게")] {
            let page = try XCTUnwrap(source.page(at: 0))
            // Select across the script/font boundary, then change one word
            // inside that selected paragraph. Unchanged runs keep their own
            // metrics even though the editor has one primary text style.
            let selected = try selection(from: before, through: "기록합니다.", on: page)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
            let word = (target.text as NSString).range(of: before)
            XCTAssertNotEqual(word.location, NSNotFound)
            let numericBefore = try nativeGlyphs(of: "0.00", on: page)
            let firstBefore = try nativeGlyphs(of: "첫", on: page)
            let secondBefore = try nativeGlyphs(of: "다음", on: page)
            let thirdBefore = try nativeGlyphs(of: "마지막", on: page)
            XCTAssertEqual(numericBefore.first?.fontName, "TimesNewRomanPSMT")
            XCTAssertEqual(try XCTUnwrap(numericBefore.first).fontSize, 10.3, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(numericBefore.first).baseline.y, 261.601, accuracy: 0.05)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: (target.text as NSString).replacingCharacters(in: word, with: after),
                style: target.style, bounds: target.bounds)
            let live = document(edited)
            XCTAssertEqual(live.findString(after, withOptions: []).count, 1)
            XCTAssertTrue(live.findString(before, withOptions: []).isEmpty)
            XCTAssertEqual(live.findString("다음 줄에는 0.00 값을 기록합니다.", withOptions: []).count, 1)
            XCTAssertEqual(live.findString("마지막 문장은 그대로 남습니다.", withOptions: []).count, 1)
            XCTAssertEqual(try outsidePixels(edited), try outsidePixels(page))
            assertSameGlyphs(try nativeGlyphs(of: "0.00", on: edited), numericBefore)
            assertSameGlyphs(try nativeGlyphs(of: "첫", on: edited), firstBefore)
            assertSameGlyphs(try nativeGlyphs(of: "다음", on: edited), secondBefore)
            assertSameGlyphs(try nativeGlyphs(of: "마지막", on: edited), thirdBefore)

            source = try XCTUnwrap(PDFDocument(data: XCTUnwrap(live.dataRepresentation())))
            let reopened = try XCTUnwrap(source.page(at: 0))
            XCTAssertEqual(source.findString(after, withOptions: []).count, 1)
            assertSameGlyphs(try nativeGlyphs(of: "0.00", on: reopened), numericBefore)
            assertSameGlyphs(try nativeGlyphs(of: "첫", on: reopened), firstBefore)
            assertSameGlyphs(try nativeGlyphs(of: "다음", on: reopened), secondBefore)
            assertSameGlyphs(try nativeGlyphs(of: "마지막", on: reopened), thirdBefore)
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: originalPage), originalBytes)
        XCTAssertEqual(original.findString("차분하게", withOptions: []).count, 1)
    }

    func testWidelySeparatedLineStartsDoNotMergeSeparateColumns() throws {
        let source = try fixture(firstLineX: 240)
        let page = try XCTUnwrap(source.page(at: 0))
        let original = try PDFBodyTextPageSnapshot.data(for: page)
        // PDFKit may reorder separate columns. Supply the visual line
        // fragments explicitly instead of assuming their extraction order.
        let phrases = ["첫 문장은 차분하게 읽습니다.", "다음 줄에는 0.00 값을 기록합니다."]
        let selected = try PDFRegionTextSelection(document: source, page: page, fragments: phrases.map { phrase in
            let line = try XCTUnwrap(source.findString(phrase, withOptions: []).first)
            return .init(text: phrase, bounds: line.bounds(for: page))
        })
        do {
            let target = try PDFBodyTextEditor.target(on: page, selection: selected)
            XCTAssertNil(target)
        } catch {}
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), original)
    }

    func testParagraphReeditPreservesLinesBeyondLastGlyphInkBounds() throws {
        let original = try fixture(secondLineSuffix: " 값을 차례로 읽고 새로운 문장을 만들어")
        let originalPage = try XCTUnwrap(original.page(at: 0))
        let originalBytes = try PDFBodyTextPageSnapshot.data(for: originalPage)
        var source = original
        for (before, after) in [("차분하게", "차분히"), ("차분히", "차분하게")] {
            let page = try XCTUnwrap(source.page(at: 0))
            let selected = try selection(from: before, through: "만들어", on: page)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
            let word = (target.text as NSString).range(of: before)
            XCTAssertNotEqual(word.location, NSNotFound)
            // The final CJK glyph's painted bounds are narrower than its
            // advance. Saving must not shrink the paragraph's wrapping width
            // and push that unchanged glyph onto a new line during re-edit.
            let lineStart = try nativeGlyphs(of: "다음", on: originalPage)
            let lineEnd = try nativeGlyphs(of: "만들어", on: originalPage)
            let untouchedLine = try nativeGlyphs(of: "마지막", on: originalPage)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: (target.text as NSString).replacingCharacters(in: word, with: after),
                style: target.style, bounds: target.bounds)
            assertSameGlyphs(try nativeGlyphs(of: "다음", on: edited), lineStart)
            assertSameGlyphs(try nativeGlyphs(of: "만들어", on: edited), lineEnd)
            assertSameGlyphs(try nativeGlyphs(of: "마지막", on: edited), untouchedLine)
            XCTAssertEqual(try outsidePixels(edited), try outsidePixels(originalPage))
            source = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document(edited).dataRepresentation())))
            let reopened = try XCTUnwrap(source.page(at: 0))
            assertSameGlyphs(try nativeGlyphs(of: "다음", on: reopened), lineStart)
            assertSameGlyphs(try nativeGlyphs(of: "만들어", on: reopened), lineEnd)
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: originalPage), originalBytes)
    }

    private func fixture(firstLineX: CGFloat = 55.2544,
                         secondLineSuffix: String = " 값을 기록합니다.") throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 500, height: 320)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)),
            mediaBox: &mediaBox, nil))
        var compressed = CGAffineTransform(scaleX: 0.97, y: 1)
        let korean = CTFontCreateCopyWithAttributes(CTFontCreateWithName("AppleMyungjo" as CFString, 10, nil),
            10, &compressed, nil)
        let latin = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 10.3, nil)
        func draw(_ text: String, font: CTFont, x: CGFloat, y: CGFloat) -> CGFloat {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.black, .ligature: 0
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        context.beginPDFPage(nil)
        _ = draw("첫 문장은 차분하게 읽습니다.", font: korean, x: firstLineX, y: 280)
        let prefixWidth = draw("다음 줄에는 ", font: korean, x: 40, y: 262)
        let numberWidth = draw("0.00", font: latin, x: 40 + prefixWidth, y: 261.601)
        _ = draw(secondLineSuffix, font: korean, x: 40 + prefixWidth + numberWidth, y: 262)
        _ = draw("마지막 문장은 그대로 남습니다.", font: korean, x: 40, y: 244)
        _ = draw("Unaffected caption", font: CTFontCreateWithName("Helvetica" as CFString, 12, nil), x: 40, y: 205)
        context.setFillColor(CGColor(red: 0.15, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 40, y: 50, width: 120, height: 90))
        context.setStrokeColor(CGColor(red: 0.75, green: 0.2, blue: 0.1, alpha: 1))
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: 210, y: 50, width: 120, height: 90))
        context.endPDFPage()
        context.closePDF()
        let plain = try XCTUnwrap(PDFDocument(data: data as Data))
        let page = try XCTUnwrap(plain.page(at: 0))
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let blocks = try PDFBodyTextContentStream.parse(content).blocks
        // Quartz emits a separate BT/ET pair for each word and for its
        // whitespace ActualText placeholder. Typeset books keep each line
        // together. Join those pairs without changing their Tm coordinates,
        // text shows, fonts, or nested whitespace semantics.
        let matrix = try NSRegularExpression(pattern: #"[-+0-9.]+\s+([-+0-9.]+)\s+Tm"#)
        var lines: [[PDFBodyTextContentStream.TextBlock]] = []
        var lineY: Double?
        for block in blocks {
            let commands = String(decoding: content.subdata(in: block.range), as: UTF8.self) as NSString
            let match = try XCTUnwrap(matrix.firstMatch(in: commands as String,
                range: NSRange(location: 0, length: commands.length)))
            let y = try XCTUnwrap(Double(commands.substring(with: match.range(at: 1))))
            if lineY.map({ abs($0 - y) <= 1 }) == true {
                lines[lines.count - 1].append(block)
            } else {
                lines.append([block])
                lineY = y
            }
        }
        var tagged = content
        for (index, line) in lines.enumerated().reversed() {
            let range = line.first!.range.lowerBound..<line.last!.range.upperBound
            var joined = content.subdata(in: range)
            let delimiters = line.dropFirst().map { $0.range.lowerBound..<($0.range.lowerBound + 2) }
                + line.dropLast().map { ($0.range.upperBound - 2)..<$0.range.upperBound }
            for delimiter in delimiters.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                joined.removeSubrange((delimiter.lowerBound - range.lowerBound)..<(delimiter.upperBound - range.lowerBound))
            }
            var replacement = Data("/Span << /MCID \(index) >> BDC\n".utf8)
            replacement.append(joined)
            replacement.append(Data("\nEMC\n".utf8))
            tagged.replaceSubrange(range, with: replacement)
        }
        return try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.data(for: page, contentOverride: tagged)))
    }

    private func selection(from start: String, through end: String, on page: PDFPage) throws -> PDFSelection {
        let text = try XCTUnwrap(page.string) as NSString
        let first = text.range(of: start), last = text.range(of: end)
        XCTAssertNotEqual(first.location, NSNotFound)
        XCTAssertNotEqual(last.location, NSNotFound)
        XCTAssertGreaterThanOrEqual(last.location, first.location)
        return try XCTUnwrap(page.selection(for: NSRange(location: first.location,
            length: NSMaxRange(last) - first.location)))
    }

    private struct NativeGlyph {
        let fontName: String
        let fontSize: CGFloat
        let scale: CGFloat
        let baseline: CGPoint
        let color: [UInt32]
    }

    private func nativeGlyphs(of phrase: String, on source: PDFPage) throws -> [NativeGlyph] {
        // target() has initialized PDFium before this independent source/ink
        // audit. Use native origins, not PDFKit's font-dependent selection box.
        let data = try PDFBodyTextPageSnapshot.data(for: source)
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0))
            defer { FPDF_ClosePage(page) }
            let textPage = try XCTUnwrap(FPDFText_LoadPage(page))
            defer { FPDFText_ClosePage(textPage) }
            var text = ""
            var indices: [Int32] = []
            for index in 0..<FPDFText_CountChars(textPage) {
                guard let scalar = UnicodeScalar(FPDFText_GetUnicode(textPage, index)) else { continue }
                let character = String(scalar)
                text += character
                indices.append(contentsOf: repeatElement(index, count: character.utf16.count))
            }
            let range = (text as NSString).range(of: phrase)
            XCTAssertNotEqual(range.location, NSNotFound)
            guard range.location != NSNotFound else { return [] }
            return try indices[range.location..<NSMaxRange(range)].map { index in
                let object = try XCTUnwrap(FPDFText_GetTextObject(textPage, index))
                let font = try XCTUnwrap(FPDFTextObj_GetFont(object))
                let count = FPDFFont_GetBaseFontName(font, nil, 0)
                var name = [CChar](repeating: 0, count: count)
                _ = FPDFFont_GetBaseFontName(font, &name, count)
                let baseName = String(cString: name).split(separator: "+").last.map(String.init) ?? ""
                var matrix = FS_MATRIX()
                XCTAssertNotEqual(FPDFText_GetMatrix(textPage, index, &matrix), 0)
                var x = 0.0, y = 0.0
                XCTAssertNotEqual(FPDFText_GetCharOrigin(textPage, index, &x, &y), 0)
                var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 0
                XCTAssertNotEqual(FPDFText_GetFillColor(textPage, index, &red, &green, &blue, &alpha), 0)
                return NativeGlyph(fontName: baseName,
                    fontSize: CGFloat(FPDFText_GetFontSize(textPage, index)) * CGFloat(matrix.d),
                    scale: CGFloat(matrix.a / matrix.d), baseline: CGPoint(x: x, y: y),
                    color: [red, green, blue, alpha])
            }
        }
    }

    private func assertSameGlyphs(_ actual: [NativeGlyph], _ expected: [NativeGlyph],
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.fontName, b.fontName, file: file, line: line)
            XCTAssertEqual(a.fontSize, b.fontSize, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(a.scale, b.scale, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(a.baseline.x, b.baseline.x, accuracy: 0.05, file: file, line: line)
            XCTAssertEqual(a.baseline.y, b.baseline.y, accuracy: 0.05, file: file, line: line)
            XCTAssertEqual(a.color, b.color, file: file, line: line)
        }
    }

    private func document(_ page: PDFPage) -> PDFDocument {
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }

    private func outsidePixels(_ page: PDFPage) throws -> Data {
        let width = 1_000, height = 640
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: 2, y: 2)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        var result = Data()
        for y in 0..<440 {
            result.append(contentsOf: bytes[(height - 1 - y) * width * 4..<(height - y) * width * 4])
        }
        XCTAssertTrue(result.contains { $0 != 255 })
        return result
    }
}
