// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import HwattakPDF

final class PDFOutlinedOCRMetadataTests: XCTestCase {
    func testRoundTripPreservesHanjaCurrentRunsStyleAndHangingIndent() throws {
        let metadata = try fixture()
        let encoded = try metadata.encodedData()
        XCTAssertEqual(try PDFOutlinedOCRMetadata.decode(encoded), metadata)
        XCTAssertEqual(try PDFOutlinedOCRMetadata.decode(encoded).firstLineIndent, -4)
        XCTAssertEqual(try metadata.encodedData(), encoded)
    }

    func testUnsupportedVersionAndClampedStyleInputsAreRejected() throws {
        for mutate in [
            { (wire: inout [String: Any]) in wire["version"] = 2 },
            { (wire: inout [String: Any]) in var style = wire["style"] as! [String: Any]; style["fontSize"] = 1; wire["style"] = style },
            { (wire: inout [String: Any]) in var style = wire["style"] as! [String: Any]; style["horizontalScale"] = -1; wire["style"] = style },
            { (wire: inout [String: Any]) in var style = wire["style"] as! [String: Any]; style["textColor"] = [0, 0, 0, 0.5]; wire["style"] = style }
        ] {
            XCTAssertThrowsError(try PDFOutlinedOCRMetadata.decode(edited(mutate)))
        }
    }

    func testMissingNativeTextRangesAndSplitSurrogatesAreRejected() throws {
        XCTAssertThrowsError(try PDFOutlinedOCRMetadata.decode(edited { wire in
            var runs = wire["sourceRuns"] as! [[String: Any]]
            runs[0]["length"] = 3
            wire["sourceRuns"] = runs
        }))
        let text = "大🧭樓"
        let style = InlineTextStyle(fontName: "Helvetica", fontSize: 17, textColor: .black,
                                    backgroundColor: .clear, alignment: .left)
        XCTAssertThrowsError(try fixture(text: text, sourceRuns: [
            .init(range: NSRange(location: 0, length: 2), style: style),
            .init(range: NSRange(location: 2, length: 2), style: style)
        ]))
    }

    func testSemanticGeometryEncodingAndArrayLimitsAreValidated() throws {
        for mutate in [
            { (wire: inout [String: Any]) in wire["semanticEncoding"] = "guess" },
            { (wire: inout [String: Any]) in wire["semanticEncoding"] = "ascii" },
            { (wire: inout [String: Any]) in wire["semanticLineFontSizes"] = [17] },
            { (wire: inout [String: Any]) in var matrices = wire["semanticLineMatrices"] as! [[String: Any]]; matrices[0]["a"] = -1; wire["semanticLineMatrices"] = matrices }
        ] { XCTAssertThrowsError(try PDFOutlinedOCRMetadata.decode(edited(mutate))) }
    }

    func testOversizedAndMissingMarkerFieldsDoNotBecomeDefaultEditorState() throws {
        XCTAssertThrowsError(try PDFOutlinedOCRMetadata.decode(Data(repeating: 32, count: PDFOutlinedOCRMetadata.maximumBytes + 1)))
        XCTAssertThrowsError(try PDFOutlinedOCRMetadata.decode(edited { $0.removeValue(forKey: "semanticFontName") }))
        XCTAssertThrowsError(try PDFOutlinedOCRMetadata.decode(edited { $0["erasedRects"] = [] }))
    }

    func testSerializedMetadataCannotAcquireNativeSourceSpacingProof() throws {
        let style = InlineTextStyle(fontName: "Helvetica", fontSize: 17, textColor: .black,
            backgroundColor: .clear, alignment: .left)
        let metadata = try fixture(sourceRuns: [
            .init(range: NSRange(location: 0, length: 5), style: style, usesSourceUnkernedAdvances: true),
            .init(range: NSRange(location: 6, length: 3), style: style)
        ])
        XCTAssertFalse(try PDFOutlinedOCRMetadata.decode(metadata.encodedData()).sourceRuns[0].usesSourceUnkernedAdvances)
        var wire = try JSONSerialization.jsonObject(with: metadata.encodedData()) as! [String: Any]
        var runs = wire["sourceRuns"] as! [[String: Any]]
        XCTAssertNil(runs[0]["usesSourceUnkernedAdvances"], "A native geometry proof is ephemeral, not a serialized assertion.")
        for forged in [true, "true", 1] as [Any] {
            runs[0]["usesSourceUnkernedAdvances"] = forged; wire["sourceRuns"] = runs
            XCTAssertFalse(try PDFOutlinedOCRMetadata.decode(JSONSerialization.data(withJSONObject: wire)).sourceRuns[0].usesSourceUnkernedAdvances)
        }
    }

    private func edited(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var wire = try JSONSerialization.jsonObject(with: fixture().encodedData()) as! [String: Any]
        mutate(&wire)
        return try JSONSerialization.data(withJSONObject: wire)
    }

    private func fixture(text: String = "alpha\n大뼈樓", sourceRuns: [InlineTextSourceRun]? = nil) throws -> PDFOutlinedOCRMetadata {
        let style = InlineTextStyle(fontName: "Helvetica", fontSize: 17, textColor: .black,
                                    backgroundColor: .clear, alignment: .left, horizontalScale: 0.85)
        let runs = sourceRuns ?? [InlineTextSourceRun(range: NSRange(location: 0, length: 5), style: style,
                horizontalAdvance: 60), InlineTextSourceRun(range: NSRange(location: 6, length: 3), style: style,
                horizontalAdvance: 55)]
        return try PDFOutlinedOCRMetadata(id: UUID(uuidString: "6A00F621-23E6-40F1-A621-014148C0E907")!, text: text,
            style: style, bounds: CGRect(x: 20, y: 80, width: 100, height: 40), baseline: CGPoint(x: 20, y: 110),
            lineHeight: 22, firstLineIndent: -4, sourceRuns: runs,
            erasedRects: [CGRect(x: 18, y: 78, width: 104, height: 44)], paperColor: .white,
            semanticFontName: "C0_0", semanticEncoding: .utf16BE, semanticDefaultWidth: 1000,
            semanticLineMatrices: [.init(a: 0.6, b: 0, c: 0, d: 1, tx: 20, ty: 110),
                                   .init(a: 0.5, b: 0, c: 0, d: 1, tx: 20, ty: 88)],
            semanticLineFontSizes: [17, 17], semanticLineWidths: [60, 55])
    }
}
