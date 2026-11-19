// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import XCTest
@testable import HwattakPDF

final class PDFBodyTextContentStreamTests: XCTestCase {
    func testOperatorWordsInsideStringsCommentsAndMarkedPropertiesAreNotCommands() throws {
        let source = "% BT (fake) Tj ET\n/Span << /ActualText (BT /X Do ET) >> BDC\n"
            + "BT /F1 12 Tf 1 0 0 1 40 50 Tm [(literal \\(ET\\) /X Do) -250 <4254>] TJ ET\nEMC\n"
            + "BT /F1 12 Tf 1 0 0 1 40 30 Tm (real) Tj ET"
        let parsed = try PDFBodyTextContentStream.parse(Data(source.utf8))
        XCTAssertEqual(parsed.records.count, 2)
        XCTAssertTrue(parsed.forms.isEmpty)
        XCTAssertFalse(parsed.records[0].isSupported)
        XCTAssertTrue(parsed.records[1].isSupported)
    }

    func testReplacementRetainsGraphicsAndPersistentTextStateByteForByte() throws {
        let head = "q 0 0.2 0.5 0.1 k 7 M /Sh1 sh\nBT /F1 12 Tf 0.125 Tc 0.42 Tw 1 0 0 1 40 90 Tm "
        let tail = " ET\nBT 1 0 0 1 40 70 Tm (next) Tj ET\nQ"
        let parsed = try PDFBodyTextContentStream.parse(Data((head + "[(old) -250 (words)] TJ" + tail).utf8))
        let output = try parsed.rewriting(recordIndices: [0], donorInvocation: "q /Fresh Do Q")
        XCTAssertEqual(String(decoding: output, as: UTF8.self), head + "[] TJ ET\nq /Fresh Do Q\n\nBT 1 0 0 1 40 70 Tm (next) Tj ET\nQ")
    }

    func testMatricesAndGraphicsStackResolveDonorPositionInPageCoordinates() throws {
        let parsed = try PDFBodyTextContentStream.parse(Data(("q 2 0 0 3 10 20 cm 1 0 0 1 4 5 cm "
            + "BT (first) Tj ET Q BT (second) Tj ET").utf8))
        let point = CGPoint.zero.applying(parsed.records[0].transform)
        XCTAssertEqual(point.x, 18, accuracy: 0.0001)
        XCTAssertEqual(point.y, 35, accuracy: 0.0001)
        XCTAssertEqual(parsed.records[1].transform, .identity)
        let restored = CGPoint(x: 123, y: 456).applying(parsed.records[0].transform.inverted()).applying(parsed.records[0].transform)
        XCTAssertEqual(restored.x, 123, accuracy: 0.0001)
        XCTAssertEqual(restored.y, 456, accuracy: 0.0001)
    }

    func testMultiShowClippingAndMarkedBlocksRemainUnavailable() throws {
        let parsed = try PDFBodyTextContentStream.parse(Data(("BT (first) Tj (second) Tj ET\n"
            + "BT 7 Tr (clipped) Tj ET\n/Span BMC BT 0 Tr (marked) Tj ET EMC").utf8))
        XCTAssertEqual(parsed.records.count, 4)
        XCTAssertTrue(parsed.records.allSatisfy { !$0.isSupported })
        XCTAssertThrowsError(try parsed.rewriting(recordIndices: [0], donorInvocation: nil))
    }

    func testMalformedOrAmbiguousStreamsCannotBeRewritten() {
        for source in ["BT (unterminated Tj ET", "BT [(nested)] Tj", "Q BT (x) Tj ET",
                       "q BT (x) Tj ET", "BI /W 1 /H 1 ID x EI", "BT <nothex> Tj ET",
                       "BT (x) Tj BT (y) Tj ET ET"] {
            XCTAssertThrowsError(try PDFBodyTextContentStream.parse(Data(source.utf8)), source)
        }
    }

    func testOwnFormReplacementRemovesOnlyTheSelectedInvocation() throws {
        let parsed = try PDFBodyTextContentStream.parse(Data("q /Original Do /Ember#42ody Do Q".utf8))
        XCTAssertEqual(parsed.forms.map(\.name), ["Original", "EmberBody"])
        let output = try parsed.rewritingForms(recordIndices: [1], donorInvocation: "q /Next Do Q")
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "q /Original Do \nq /Next Do Q\n Q")
    }

    func testWholeTaggedTextBlockRemovesEveryShowAndOnlyWhitespaceWrappers() throws {
        let spaceStart = "/Span << /ActualText (\\376\\377\\000 ) >> BDC"
        let source = "/Span << /Lang (ko) /MCID 693 >> BDC\n"
            + "BT /CS0 cs 0 0 0 scn /GS1 gs /Perceptual ri /F1 1 Tf -0.051 Tc 0.051 Tw "
            + "10.094 0 0 10.3 66.7288 450.0787 Tm (first) Tj\n"
            + spaceStart + " (\\000\\001) Tj EMC\n(second) Tj ET\nEMC\n"
            + "BT (untouched) Tj ET"
        let parsed = try PDFBodyTextContentStream.parse(Data(source.utf8))
        XCTAssertEqual(parsed.blocks.count, 2)
        XCTAssertTrue(parsed.blocks[0].isSupported)
        XCTAssertEqual(parsed.blocks[0].showRanges.count, 3)
        XCTAssertEqual(parsed.blocks[0].whitespaceMarkupRanges.count, 2)
        XCTAssertEqual(parsed.blocks[0].graphicsStateNames, ["GS1"])
        XCTAssertEqual(parsed.blocks[0].transform, .identity)
        XCTAssertFalse(parsed.records[0].isSupported, "The older single-show route remains conservative.")
        let output = try parsed.rewritingBlocks(blockIndices: [0], donorInvocation: "q /Fresh Do Q")
        let expected = source.replacingOccurrences(of: "(first) Tj", with: "[] TJ")
            .replacingOccurrences(of: spaceStart, with: "")
            .replacingOccurrences(of: "(\\000\\001) Tj EMC", with: "[] TJ ")
            .replacingOccurrences(of: "(second) Tj ET", with: "[] TJ ET\nq /Fresh Do Q\n")
        XCTAssertEqual(String(decoding: output, as: UTF8.self), expected)
        XCTAssertNoThrow(try PDFBodyTextContentStream.parse(output))
    }

    func testWhitespaceActualTextDecodesLiteralOctalAndHexStrings() throws {
        for actualText in ["(\\376\\377\\000 )", "<FE FF 00 20>", "(\\040)", "(\\t )"] {
            let source = "BT (word) Tj /Span << /ActualText \(actualText) >> BDC ( ) Tj EMC ET"
            let parsed = try PDFBodyTextContentStream.parse(Data(source.utf8))
            XCTAssertTrue(parsed.blocks[0].isSupported, actualText)
            let output = try parsed.rewritingBlocks(blockIndices: [0], donorInvocation: nil)
            XCTAssertEqual(String(decoding: output, as: UTF8.self), "BT [] TJ  [] TJ  ET", actualText)
        }
    }

    func testWholeBlockRouteRejectsSemanticOverridesAndAmbiguousProperties() throws {
        for source in [
            "/Span << /ActualText (replacement) >> BDC BT (old) Tj ET EMC",
            "/Span << /ActualText <FEFF0020> >> BDC BT (old) Tj ET EMC",
            "/Span /Properties1 BDC BT (old) Tj ET EMC",
            "/OC /Layer1 BDC BT (old) Tj ET EMC",
            "/Span << /E (expanded) >> BDC BT (old) Tj ET EMC",
            "BT /Span << /ActualText <FEFFAC00> >> BDC (old) Tj EMC ET",
            "BT /Span << /Actual#54ext (not a space) >> BDC (old) Tj EMC ET",
            "BT /Span << /ActualText () >> BDC (old) Tj EMC ET",
            "BT /Span << /ActualText [( )] >> BDC (old) Tj EMC ET"
        ] {
            let parsed = try PDFBodyTextContentStream.parse(Data(source.utf8))
            XCTAssertFalse(parsed.blocks[0].isSupported, source)
            XCTAssertThrowsError(try parsed.rewritingBlocks(blockIndices: [0], donorInvocation: nil), source)
        }
    }

    func testWholeBlockRouteRejectsClippingQuotesPaintingAndTransformChanges() throws {
        for body in ["7 Tr (clip) Tj", "(line) '", "1 2 (line) \"", "(word) Tj 0 0 10 10 re f",
                     "1 0 0 1 0 0 cm (word) Tj", "q (word) Tj Q", "(word) Tj /Image Do"] {
            let parsed = try PDFBodyTextContentStream.parse(Data("BT \(body) ET".utf8))
            XCTAssertFalse(parsed.blocks[0].isSupported, body)
        }
        let crossing = try PDFBodyTextContentStream.parse(Data("BT /Span BMC (word) Tj ET EMC".utf8))
        XCTAssertFalse(crossing.blocks[0].isSupported)
    }

    func testWholeBlockReplacementPreservesAllPersistentStateAndUnselectedBlocks() throws {
        let source = "q 2 0 0 3 10 20 cm /Span BMC BT /F 12 Tf (one) Tj 4 0 Td (two) Tj ET EMC\n"
            + "BT 1 Tc (three) Tj ET\nBT (keep) Tj ET Q"
        let parsed = try PDFBodyTextContentStream.parse(Data(source.utf8))
        XCTAssertTrue(parsed.blocks.allSatisfy(\.isSupported))
        XCTAssertEqual(parsed.blocks[0].transform, CGAffineTransform(a: 2, b: 0, c: 0, d: 3, tx: 10, ty: 20))
        let output = try parsed.rewritingBlocks(blockIndices: [0, 1], donorInvocation: "q /Fresh Do Q")
        XCTAssertEqual(String(decoding: output, as: UTF8.self),
            "q 2 0 0 3 10 20 cm /Span BMC BT /F 12 Tf [] TJ 4 0 Td [] TJ ET\nq /Fresh Do Q\n EMC\n"
                + "BT 1 Tc [] TJ ET\nBT (keep) Tj ET Q")
        for indices in [[], [0, 0], [-1], [3]] {
            XCTAssertThrowsError(try parsed.rewritingBlocks(blockIndices: indices, donorInvocation: nil))
        }
    }

    func testDonorFormCanBeReeditedInsideMetadataOnlyTags() throws {
        let source = "/Span << /Lang (ko) /MCID 693 >> BDC BT (old) Tj ET EMC"
        let parsed = try PDFBodyTextContentStream.parse(Data(source.utf8))
        let output = try parsed.rewritingBlocks(blockIndices: [0], donorInvocation: "q /Fresh Do Q")
        let rewritten = try PDFBodyTextContentStream.parse(output)
        XCTAssertEqual(rewritten.forms.count, 1)
        XCTAssertTrue(rewritten.forms[0].isSupported)
        let second = try rewritten.rewritingForms(recordIndices: [0], donorInvocation: "q /Next Do Q")
        let text = String(decoding: second, as: UTF8.self)
        XCTAssertTrue(text.contains("/Lang (ko) /MCID 693"))
        XCTAssertTrue(text.contains("/Next Do"))
        XCTAssertFalse(text.contains("/Fresh Do"))

        for prefix in ["/Span << /ActualText ( ) >> BDC", "/Span /NamedProperties BDC", "/OC BMC"] {
            let rejected = try PDFBodyTextContentStream.parse(Data("\(prefix) /Fresh Do EMC".utf8))
            XCTAssertFalse(rejected.forms[0].isSupported, prefix)
        }
    }
}
