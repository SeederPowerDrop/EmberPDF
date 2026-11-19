// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFGeneratedDonorTextNormalizerTests: XCTestCase {
    func testRadicalCorrectionMovesToUnicodeWithoutChangingGlyphPainting() throws {
        let program = "/F1 20 Tf (A) Tj /Span << /ActualText <FEFF4E00> >> BDC q 1 0 0 1 0 .4 cm BT /F1 20 Tf (B) Tj ET Q EMC"
        let result = try XCTUnwrap(normalize(program))
        XCTAssertEqual(String(decoding: result.content, as: UTF8.self),
            "/F1 20 Tf (A) Tj  q 1 0 0 1 0 .4 cm BT /F1 20 Tf (B) Tj ET Q ")
        let cmap = String(decoding: try XCTUnwrap(result.fontCMaps["F1"]), as: UTF8.self)
        XCTAssertTrue(cmap.contains("<41> <7532>"))
        XCTAssertTrue(cmap.contains("<42> <4E00>"))
    }

    func testUnmarkedUseOfSameCodeRetainsBothDistinctMeanings() {
        XCTAssertNil(normalize("/F1 20 Tf (B) Tj /Span << /ActualText <FEFF4E00> >> BDC (B) Tj EMC"))
    }

    func testQuartzSingleCodeRangeKeepsRangeAndOnlyCorrectsDestination() throws {
        let program = "/F1 20 Tf /Span << /ActualText <FEFF4E00> >> BDC (B) Tj EMC"
        let result = try XCTUnwrap(PDFGeneratedDonorTextNormalizer.normalize(content: Data(program.utf8),
            fontCMaps: ["F1": Data("1 beginbfrange <42> <42> <2F00> endbfrange".utf8)]))
        XCTAssertEqual(String(decoding: try XCTUnwrap(result.fontCMaps["F1"]), as: UTF8.self),
                       "1 beginbfrange <42> <42> <4E00> endbfrange")
        XCTAssertFalse(String(decoding: result.content, as: UTF8.self).contains("ActualText"))
    }

    func testConflictingActualTextAndOpaqueArrayUsesCannotRewriteFont() {
        XCTAssertNil(normalize("/F1 20 Tf /Span << /ActualText <FEFF4E00> >> BDC (B) Tj EMC /Span << /ActualText <FEFF2F00> >> BDC (B) Tj EMC"))
        XCTAssertNil(normalize("/F1 20 Tf [(A)] TJ /Span << /ActualText <FEFF4E00> >> BDC (B) Tj EMC"))
    }

    func testNestedMarkupAndMultiGlyphSemanticsStayUntouched() {
        XCTAssertNil(normalize("/F1 20 Tf /Span << /ActualText <FEFF4E00> >> BDC /Span << /ActualText <FEFF4E00> >> BDC (B) Tj EMC EMC"))
        XCTAssertNil(normalize("/F1 20 Tf /Span << /ActualText <FEFF4E004E00> >> BDC (BB) Tj EMC"))
    }

    func testRangeCMapOrMissingCodeCannotLoseActualText() {
        let program = "/F1 20 Tf /Span << /ActualText <FEFF4E00> >> BDC (B) Tj EMC"
        XCTAssertNil(PDFGeneratedDonorTextNormalizer.normalize(content: Data(program.utf8),
            fontCMaps: ["F1": Data("1 beginbfrange <41> <42> <2F00> endbfrange".utf8)]))
        XCTAssertNil(PDFGeneratedDonorTextNormalizer.normalize(content: Data(program.utf8),
            fontCMaps: ["F1": Data("1 beginbfchar <41> <7532> endbfchar".utf8)]))
    }

    func testUnprovedGraphicsStateCannotHideADifferentFont() {
        let program = "/F1 20 Tf /Other gs /Span << /ActualText <FEFF4E00> >> BDC (B) Tj EMC"
        XCTAssertNil(normalize(program))
    }

    func testUnrelatedGenuineRangePreservesPaintingAndAllowsRepeatedSingletonCorrections() throws {
        let scopes = [("B", "4E00"), ("C", "4E8C"), ("B", "4E00"),
                      ("D", "4E09"), ("C", "4E8C"), ("B", "4E00")]
        let prefix = "/F1 20 Tf (QRS) Tj "
        let program = prefix + scopes.map { code, unicode in
            "/Span << /ActualText <FEFF\(unicode)> >> BDC q BT /F1 20 Tf (\(code)) Tj ET Q EMC"
        }.joined(separator: " ")
        let cmap = """
            4 beginbfrange
            <51> <53> <5000>
            <42> <42> <2F00>
            <43> <43> <2F06>
            <44> <44> <4E09>
            endbfrange
            """
        let result = try XCTUnwrap(PDFGeneratedDonorTextNormalizer.normalize(
            content: Data(program.utf8), fontCMaps: ["F1": Data(cmap.utf8)]))
        let expectedPainting = prefix + scopes.map { code, _ in
            " q BT /F1 20 Tf (\(code)) Tj ET Q "
        }.joined(separator: " ")
        XCTAssertEqual(result.content, Data(expectedPainting.utf8))
        XCTAssertEqual(result.fontCMaps["F1"], Data(cmap
            .replacingOccurrences(of: "<42> <42> <2F00>", with: "<42> <42> <4E00>")
            .replacingOccurrences(of: "<43> <43> <2F06>", with: "<43> <43> <4E8C>").utf8))
    }

    func testUnrelatedRangesCannotConcealDuplicateOrOverlappingMappings() {
        let program = "/F1 20 Tf /Span << /ActualText <FEFF4E00> >> BDC (B) Tj EMC"
        let maps = [
            "2 beginbfrange <41> <43> <5000> <42> <42> <2F00> endbfrange",
            "2 beginbfrange <42> <42> <2F00> <41> <43> <5000> endbfrange",
            "1 beginbfrange <51> <53> <5000> endbfrange 2 beginbfchar <52> <5001> <42> <2F00> endbfchar",
            "3 beginbfrange <51> <53> <5000> <53> <54> <5002> <42> <42> <2F00> endbfrange"
        ]
        for cmap in maps {
            XCTAssertNil(PDFGeneratedDonorTextNormalizer.normalize(content: Data(program.utf8),
                fontCMaps: ["F1": Data(cmap.utf8)]))
        }
    }

    func testCorrectionsInsideGenuineRangeRemainUnsupportedAtEveryBoundary() {
        let cmap = "1 beginbfrange <41> <43> <2F00> endbfrange"
        for code in ["A", "B", "C"] {
            let program = "/F1 20 Tf /Span << /ActualText <FEFF4E00> >> BDC (\(code)) Tj EMC"
            XCTAssertNil(PDFGeneratedDonorTextNormalizer.normalize(content: Data(program.utf8),
                fontCMaps: ["F1": Data(cmap.utf8)]))
        }
    }

    func testUnrelatedRangeMustBeBoundedUnambiguousBMPMapping() {
        let program = "/F1 20 Tf /Span << /ActualText <FEFF4E00> >> BDC (B) Tj EMC"
        let malformedRanges = [
            "<53> <51> <5000>", "<0051> <0053> <5000>", "<51> <0053> <5000>",
            "<51> <53> [<5000> <5001> <5002>]", "<51> <53> <50>",
            "<51> <53> <D800DC00>", "<51> <53> <D7FF>", "<51> <53> <D800>",
            "<51> <53> <FFFF>"
        ]
        for range in malformedRanges {
            let cmap = "2 beginbfrange \(range) <42> <42> <2F00> endbfrange"
            XCTAssertNil(PDFGeneratedDonorTextNormalizer.normalize(content: Data(program.utf8),
                fontCMaps: ["F1": Data(cmap.utf8)]))
        }
        for count in ["0", "1", "3", "4097"] {
            let cmap = "\(count) beginbfrange <51> <53> <5000> <42> <42> <2F00> endbfrange"
            XCTAssertNil(PDFGeneratedDonorTextNormalizer.normalize(content: Data(program.utf8),
                fontCMaps: ["F1": Data(cmap.utf8)]))
        }
    }

    private func normalize(_ program: String) -> PDFGeneratedDonorTextNormalizer.Output? {
        PDFGeneratedDonorTextNormalizer.normalize(content: Data(program.utf8), fontCMaps: ["F1": Data("""
            /CIDInit /ProcSet findresource begin 12 dict begin begincmap
            /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            /CMapType 2 def 1 begincodespacerange <00> <FF> endcodespacerange
            2 beginbfchar <41> <7532> <42> <2F00> endbfchar
            endcmap CMapName currentdict /CMap defineresource pop end end
            """.utf8)])
    }
}
