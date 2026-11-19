// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreText
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextOutlinedRenderingTests: XCTestCase {
    func testCondensedAndExpandedOutlinesMatchCoreTextInk() throws {
        for scale in [0.65, 0.8, 1.0, 1.2, 1.6] {
            var matrix = CGAffineTransform(scaleX: scale, y: 1)
            let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 18, &matrix)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "한국의 씨름 大뼈樓 123", attributes: [.font: font]))
            try assertOutlineMatchesLine(line)
        }
    }

    func testMixedFontsAndRunScalesMatchCoreTextInk() throws {
        let value = NSMutableAttributedString(string: "")
        for (text, name, size, scale) in [("한국의 ", "AppleSDGothicNeo-Regular", 18.0, 0.8),
                                        ("123 ", "Helvetica", 14.0, 1.3),
                                        ("大뼈樓", "AppleSDGothicNeo-Regular", 20.0, 0.9)] {
            var matrix = CGAffineTransform(scaleX: scale, y: 1)
            let font = CTFontCreateWithName(name as CFString, size, &matrix)
            value.append(NSAttributedString(string: text, attributes: [.font: font]))
        }
        try assertOutlineMatchesLine(CTLineCreateWithAttributedString(value))
    }

    func testNonFiniteAndSingularPlacementAreRejected() {
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        XCTAssertThrowsError(try PDFBodyTextEditor.outlinedGlyphPath(font: font, glyphs: [1],
            positions: [.init(x: CGFloat.nan, y: 0)], runMatrix: .identity, origin: .zero))
        XCTAssertThrowsError(try PDFBodyTextEditor.outlinedGlyphPath(font: font, glyphs: [1],
            positions: [], runMatrix: .identity, origin: .zero))
        XCTAssertThrowsError(try PDFBodyTextEditor.outlinedGlyphPath(font: font, glyphs: [1],
            positions: [.zero], runMatrix: .init(a: CGFloat.infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0), origin: .zero))
        XCTAssertThrowsError(try PDFBodyTextEditor.outlinedGlyphPath(font: font, glyphs: [1],
            positions: [.zero], runMatrix: .init(scaleX: 0, y: 1), origin: .zero))
    }

    func testOrderGuardAcceptsOneContextualReplacementAndRejectsPermutation() {
        XCTAssertTrue(PDFBodyTextEditor.preservesTextSequence(
            before: "달은 밝다. 다음 단의 달은 어둡다.", after: "빛은 밝다. 다음 단의 달은 어둡다.",
            original: "달은 밝다.", replacement: "빛은 밝다."))
        XCTAssertFalse(PDFBodyTextEditor.preservesTextSequence(
            before: "달은 밝다. 다음 단의 달은 어둡다.", after: "빛은 밝다. 다음 단의 빛은 어둡다.",
            original: "달은 밝다.", replacement: "빛은 밝다."))
        XCTAssertFalse(PDFBodyTextEditor.preservesTextSequence(
            before: "앞 문단. 원래 본문. 뒷 문단.", after: "뒷 문단. 앞 문단. 새 본문.",
            original: "원래 본문.", replacement: "새 본문."))
        XCTAssertTrue(PDFBodyTextEditor.preservesTextSequence(
            before: "앞 문단. 大뼈樓. 뒷 문단.", after: "앞 문단.\n뒷 문단.",
            original: "大뼈樓.", replacement: ""))
        XCTAssertFalse(PDFBodyTextEditor.preservesTextSequence(
            before: "앞 문단. 大뼈樓. 뒷 문단.", after: "앞 문단. 大뼈樓. 大뼈樓. 뒷 문단.",
            original: "大뼈樓.", replacement: "大뼈樓."))
    }

    func testLongRepeatedOCRStillChecksTheSingleIntendedChange() {
        let source = "앞" + String(repeating: "A", count: 50_000) + "뒤"
        let original = String(repeating: "A", count: 30_000)
        let replacement = String(repeating: "A", count: 14_999) + "B" + String(repeating: "A", count: 15_000)
        let actual = "앞" + String(repeating: "A", count: 24_999) + "B" + String(repeating: "A", count: 25_000) + "뒤"
        XCTAssertTrue(PDFBodyTextEditor.preservesTextSequence(before: source, after: actual,
            original: original, replacement: replacement))
        XCTAssertFalse(PDFBodyTextEditor.preservesTextSequence(before: source, after: actual + "A",
            original: original, replacement: replacement))
    }

    func testOrderGuardAgreesWithExhaustiveShortSubstitutions() {
        let words = ["", "a", "b", "aa", "ab", "ba", "bb", "aaa", "aab", "aba", "abb", "baa", "bab", "bba", "bbb"]
        for source in words {
            for old in words.dropFirst() {
                for new in ["", "a", "b", "ab", "ba"] {
                    var expected = Set<String>()
                    let bytes = Array(source.utf8), oldBytes = Array(old.utf8)
                    if bytes.count >= oldBytes.count {
                        for index in 0...(bytes.count - oldBytes.count) {
                            if Array(bytes[index..<(index + oldBytes.count)]) == oldBytes {
                                expected.insert(String(decoding: bytes.prefix(index), as: UTF8.self)
                                    + new + String(decoding: bytes.dropFirst(index + oldBytes.count), as: UTF8.self))
                            }
                        }
                    }
                    for actual in Set(words).union(expected) {
                        XCTAssertEqual(PDFBodyTextEditor.preservesTextSequence(before: source, after: actual,
                            original: old, replacement: new), expected.contains(actual),
                            "source=\(source), old=\(old), new=\(new), actual=\(actual)")
                    }
                }
            }
        }
    }

    private func assertOutlineMatchesLine(_ line: CTLine, file: StaticString = #filePath,
                                         line number: UInt = #line) throws {
        let origin = CGPoint(x: 73.25, y: 120.5)
        var actual = CGRect.null
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            let path = try PDFBodyTextEditor.outlinedGlyphPath(font: font, glyphs: glyphs,
                positions: positions, runMatrix: CTRunGetTextMatrix(run), origin: origin)
            if !path.isEmpty { actual = actual.union(path.boundingBoxOfPath) }
        }
        let expected = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            .offsetBy(dx: origin.x, dy: origin.y)
        for (left, right) in zip([actual.minX, actual.minY, actual.maxX, actual.maxY],
                                 [expected.minX, expected.minY, expected.maxX, expected.maxY]) {
            XCTAssertEqual(left, right, accuracy: 0.000_01, file: file, line: number)
        }
    }
}
