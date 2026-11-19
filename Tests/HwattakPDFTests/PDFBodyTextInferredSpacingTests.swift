// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFBodyTextInferredSpacingTests: XCTestCase {
    func testUnifiedCompatibilityAndVariationSelectedHanDoNotInferSpaces() throws {
        let bases: [UInt32] = [0x3400, 0x4E00, 0x9FFF, 0xF900, 0xFA11,
            0x20000, 0x2A700, 0x2B740, 0x2B820, 0x2CEB0, 0x2EBF0,
            0x2F800, 0x30000, 0x31350, 0x323B0]
        for value in bases {
            let han = String(try XCTUnwrap(UnicodeScalar(value)))
            for suffix in ["", "\u{FE00}", "\u{E0100}"] {
                XCTAssertFalse(PDFBodyTextInferredSpacing.needsSpace(before: han + suffix,
                    after: "字", gap: 3, fontSize: 10))
                XCTAssertFalse(PDFBodyTextInferredSpacing.needsSpace(before: "字",
                    after: han + suffix, gap: 3, fontSize: 10))
            }
        }
        XCTAssertFalse(PDFBodyTextInferredSpacing.needsSpace(before: "孔 ", after: "子", gap: 3, fontSize: 10))
        XCTAssertFalse(PDFBodyTextInferredSpacing.needsSpace(before: "孔", after: " 子", gap: 3, fontSize: 10))
    }

    func testMixedScriptNumbersAndExistingWordBoundaryRulesRemain() {
        for (left, right) in [("read", "next"), ("가", "나"), ("漢", "A"),
                              ("A", "漢"), ("漢", "3"), ("3", "漢"),
                              ("漢", "가"), ("가", "漢"), ("é", "word")] {
            XCTAssertTrue(PDFBodyTextInferredSpacing.needsSpace(before: left, after: right,
                gap: 3, fontSize: 10))
        }
        for (left, right) in [("word,", "next"), ("word", "."), ("", "word"), ("word", "")] {
            XCTAssertFalse(PDFBodyTextInferredSpacing.needsSpace(before: left, after: right,
                gap: 3, fontSize: 10))
        }
        XCTAssertFalse(PDFBodyTextInferredSpacing.needsSpace(before: "a", after: "b", gap: 1.5, fontSize: 10))
        XCTAssertTrue(PDFBodyTextInferredSpacing.needsSpace(before: "a", after: "b", gap: 1.5001, fontSize: 10))
    }
}
