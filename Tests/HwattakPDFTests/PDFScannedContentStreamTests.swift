// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFScannedContentStreamTests: XCTestCase {
    func testRemovalPreservesOtherOCRStringsFontStateAndGraphicsBytesExactly() throws {
        let prefix = "q /Im0 Do /Span << /ActualText (keep BT ET) >> BDC\n"
            + "BT /OCR 1 Tf 3 Tr 10 0 0 10 20 40 Tm <AC00> Tj ET EMC\n"
            + "% (comment) Tj\nBT /OCR 1 Tf 3 Tr 10 0 0 10 20 20 Tm "
        let suffix = " ET\nBT /Other 1 Tf 1 Tc 3 Tr 10 0 0 10 20 5 Tm (keep \\(Tj\\) \\101) Tj ET Q\n"
        let source = Data((prefix + "<AC01> Tj" + suffix).utf8)
        let parsed = try PDFScannedContentStream.parse(source)

        XCTAssertEqual(parsed.shows.count, 3)
        XCTAssertEqual(try parsed.removing([1]), Data((prefix + "[] TJ" + suffix).utf8))
        XCTAssertEqual(parsed.data, source)
        XCTAssertThrowsError(try parsed.removing([0]), "Marked OCR must remain untouched.")
    }

    func testRemovalNeedsAResetBeforeTheNextRemainingShow() throws {
        let source = Data("BT 3 Tr 1 0 0 1 20 40 Tm (first) Tj (second) Tj ET".utf8)
        let parsed = try PDFScannedContentStream.parse(source)
        XCTAssertThrowsError(try parsed.removing([0]))
        XCTAssertEqual(try parsed.removing([0, 1]),
                       Data("BT 3 Tr 1 0 0 1 20 40 Tm [] TJ [] TJ ET".utf8))
        for indices in [[], [0, 0], [-1], [2]] {
            XCTAssertThrowsError(try parsed.removing(indices), "Indices: \(indices)")
        }
    }

    func testLineMatrixMovesResetIndependentlyOfRemovedGlyphAdvance() throws {
        // Td/TD/T* use the text line matrix, which Tj does not advance.
        // They are safe even though their coordinates are relative.
        for reset in ["0 -12 Td", "5 -12 TD", "T*", "1 0 0 1 20 28 Tm", "ET BT"] {
            let source = "BT 3 Tr 12 TL 1 0 0 1 20 40 Tm (first) Tj \(reset) (keep) Tj ET"
            let parsed = try PDFScannedContentStream.parse(Data(source.utf8))
            XCTAssertTrue(parsed.shows[1].resetsPosition, reset)
            XCTAssertEqual(try parsed.removing([0]),
                           Data(source.replacingOccurrences(of: "(first) Tj", with: "[] TJ").utf8), reset)
        }
        for noReset in ["/F2 9 Tf", "2 Tc", "4 Tw", "90 Tz", "14 TL", "2 Ts"] {
            let parsed = try PDFScannedContentStream.parse(Data("BT 3 Tr (first) Tj \(noReset) (keep) Tj ET".utf8))
            XCTAssertThrowsError(try parsed.removing([0]), noReset)
        }
    }

    func testOnlyUnmarkedRenderModeThreeShowsCanBeRemoved() throws {
        let source = "BT 0 Tr (visible) Tj ET q BT 3 Tr (hidden) Tj ET Q "
            + "BT (visible again) Tj ET /Span BMC BT 3 Tr (marked) Tj ET EMC "
            + "BT 3 Tr (quote) ' 1 2 (double quote) \" ET"
        let parsed = try PDFScannedContentStream.parse(Data(source.utf8))
        XCTAssertEqual(parsed.shows.map(\.invisible), [false, true, false, true, false, false])
        XCTAssertNoThrow(try parsed.removing([1]))
        for index in [0, 2, 3, 4, 5] {
            XCTAssertThrowsError(try parsed.removing([index]), "Show: \(index)")
        }
    }

    func testEarlierEmptyPlaceholdersPermitEditingAnotherOCRLine() throws {
        let source = "q 0 0 300 200 re 20 20 80 12 re W* n\n"
            + "q /Scan Do Q\nBT 3 Tr 1 0 0 1 20 40 Tm (first) Tj ET\n"
            + "BT 3 Tr 1 0 0 1 20 20 Tm (second) Tj ET\nQ\n"
            + "q 1 1 1 rg 20 20 80 12 re f Q\nq /EmberBody1 Do Q\n"
        let first = try PDFScannedContentStream.parse(Data(source.utf8)).removing([0])
        let reopened = try PDFScannedContentStream.parse(first)
        XCTAssertEqual(reopened.shows.count, 1,
                       "A previous [] TJ must not consume an OCR object ordinal.")
        XCTAssertEqual(try reopened.removing([0]), Data(source
            .replacingOccurrences(of: "(first) Tj", with: "[] TJ")
            .replacingOccurrences(of: "(second) Tj", with: "[] TJ").utf8))

        let noOps = try PDFScannedContentStream.parse(Data("BT 3 Tr () Tj [ % empty\n ] TJ (keep) Tj ET".utf8))
        XCTAssertEqual(noOps.shows.count, 1)
        XCTAssertEqual(try noOps.removing([0]), Data("BT 3 Tr () Tj [ % empty\n ] TJ [] TJ ET".utf8))
        for body in ["[120] TJ", "[() -20] TJ", "() '", "1 2 () \""] {
            XCTAssertThrowsError(try PDFScannedContentStream.parse(Data("BT 3 Tr \(body) ET".utf8)), body)
        }
    }

    func testNoOpDoesNotMakeDependentNextShowLookPositionIndependent() throws {
        let parsed = try PDFScannedContentStream.parse(Data("BT 3 Tr (first) Tj [] TJ () Tj (keep) Tj ET".utf8))
        XCTAssertEqual(parsed.shows.count, 2)
        XCTAssertFalse(parsed.shows[1].resetsPosition)
        XCTAssertThrowsError(try parsed.removing([0]))
    }

    func testInlineMaskUsesExactByteLengthInsteadOfSearchingForEmbeddedEI() throws {
        // These bytes are image pixels, including convincing PDF operators.
        // The only real OCR show follows the exact mask payload and terminator.
        let pixels = Data(" EI BT 3 Tr (fake) Tj ET\n\0".utf8)
        let prefix = Data("q BI /W 8 /H \(pixels.count) /IM true /BPC 1 ID\r\n".utf8)
        let suffix = Data("\nEI Q\nBT 3 Tr (real) Tj ET\n".utf8)
        var source = prefix
        source.append(pixels)
        source.append(suffix)
        let parsed = try PDFScannedContentStream.parse(source)
        XCTAssertEqual(parsed.shows.count, 1)
        XCTAssertEqual(parsed.shows[0].stringBytes, Array("real".utf8))
        var expected = prefix
        expected.append(pixels)
        expected.append(Data("\nEI Q\nBT 3 Tr [] TJ ET\n".utf8))
        XCTAssertEqual(try parsed.removing([0]), expected)
    }

    func testInlineMaskRowPaddingAndFullNamesAreSupported() throws {
        // A 9-pixel row occupies two bytes, independently for each row.
        var source = Data("BI /Width 9 /Height 2 /ImageMask true /BitsPerComponent 1 /Decode [1 0] ID ".utf8)
        source.append(contentsOf: [0x45, 0x49, 0x00, 0xFF])
        source.append(Data("\nEI BT 3 Tr <0041> Tj ET".utf8))
        let parsed = try PDFScannedContentStream.parse(source)
        XCTAssertEqual(parsed.shows.count, 1)
        XCTAssertEqual(parsed.shows[0].stringBytes, [0, 65])
        XCTAssertNoThrow(try parsed.removing([0]))
    }

    func testUnsupportedOrMalformedInlineImagesCannotBeRewritten() {
        let invalid = [
            "BI /W 8 /H 1 /IM true /F /FlateDecode ID x EI",
            "BI /W 8 /H 1 /IM false ID x EI",
            "BI /W 8 /H 1 /IM true /BPC 8 ID x EI",
            "BI /W 8 /H 1 /IM true /BPC true ID x EI",
            "BI /W 8 /Width 8 /H 1 /IM true ID x EI",
            "BI /W 8 /H 1 /IM true /IM true ID x EI",
            "BI /W 8 /H 1 /IM true /CS /G ID x EI",
            "BI /W 0 /H 1 /IM true ID x EI",
            "BI /W 8.5 /H 1 /IM true ID x EI",
            "BI /W 8 /H 8193 /IM true ID x EI",
            "BI /W 8 /H 1 /IM true",
            "BI /W 8 /H 8 /IM true ID x",
            "BI /W 8 /H 1 /IM true ID x EX",
            "BI /W 8 /H 1 /IM true ID x EIx",
            "BT BI /W 8 /H 1 /IM true ID x EI ET",
            "ID x EI"
        ]
        for source in invalid {
            XCTAssertThrowsError(try PDFScannedContentStream.parse(Data(source.utf8)), source)
        }
    }

    func testMalformedTextAndGraphicsStatesAreRejected() {
        for source in [
            "BT 3 Tr (unfinished Tj ET", "BT 3 Tr <GG> Tj ET",
            "BT BT 3 Tr (x) Tj ET ET", "BT 3 Tr (x) Tj", "ET",
            "q BT 3 Tr (x) Tj ET", "Q BT 3 Tr (x) Tj ET",
            "BT 8 Tr (x) Tj ET", "BT 1.5 Tr (x) Tj ET",
            "BT 1 0 Tm 3 Tr (x) Tj ET", "BT 1 T* 3 Tr (x) Tj ET",
            "BT 3 Tr [(x)] Tj ET", "BT 3 Tr (x) TJ ET",
            "BT 3 Tr 1 (x) (y) \" ET", "BT 3 Tr /Name Tj ET",
            "/Span 42 BDC BT 3 Tr (x) Tj ET EMC",
            "BMC BT 3 Tr (x) Tj ET EMC", "EMC",
            "/Span BMC BT 3 Tr (x) Tj ET 1 EMC"
        ] {
            XCTAssertThrowsError(try PDFScannedContentStream.parse(Data(source.utf8)), source)
        }
    }

    func testOperatorLikeStringBytesAreDecodedWithoutChangingTokenBoundaries() throws {
        let source = Data("% EI BT (comment) Tj\nBT 3 Tr (A\\050EI\\051\\\nB) Tj ET BT 3 Tr <41 0a 42> Tj ET".utf8)
        let parsed = try PDFScannedContentStream.parse(source)
        XCTAssertEqual(parsed.shows.count, 2)
        XCTAssertEqual(parsed.shows[0].stringBytes, Array("A(EI)B".utf8))
        XCTAssertEqual(parsed.shows[1].stringBytes, [65, 10, 66])
        XCTAssertEqual(try parsed.removing([0]), Data("% EI BT (comment) Tj\nBT 3 Tr [] TJ ET BT 3 Tr <41 0a 42> Tj ET".utf8))
    }
}
