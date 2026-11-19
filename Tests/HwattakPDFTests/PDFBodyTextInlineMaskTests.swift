// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFBodyTextInlineMaskTests: XCTestCase {
    func testInlineMaskBytesStayUntouchedWhenReplacingOwnDonor() throws {
        let pixels=Data(" EI /Fake Do ".utf8)
        var source=Data("q BI /W 8 /H \(pixels.count) /IM true /BPC 1 ID\r\n".utf8)
        source.append(pixels)
        source.append(Data("\nEI Q\nq /EmberBody1 Do Q\n".utf8))
        let parsed=try PDFBodyTextContentStream.parse(source)
        XCTAssertEqual(parsed.forms.map(\.name),["EmberBody1"])
        let output=try parsed.rewritingForms(recordIndices:[0],donorInvocation:"q /EmberBody2 Do Q")
        XCTAssertTrue(output.starts(with:source.prefix(source.count-Data("q /EmberBody1 Do Q\n".utf8).count)))
        XCTAssertEqual(try PDFBodyTextContentStream.parse(output).forms.map(\.name),["EmberBody2"])
    }

    func testFilteredMasksAndMasksInsideTextRemainUnsupported() {
        for source in ["BI /W 8 /H 1 /IM true /F /FlateDecode ID x EI", "BT BI /W 8 /H 1 /IM true ID x EI ET"] {
            XCTAssertThrowsError(try PDFBodyTextContentStream.parse(Data(source.utf8)))
        }
    }
}
