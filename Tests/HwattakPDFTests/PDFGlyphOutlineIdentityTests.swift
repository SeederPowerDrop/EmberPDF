// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import XCTest
@testable import HwattakPDF

final class PDFGlyphOutlineIdentityTests: XCTestCase {
    func testOnlyUnpaintedFinalMovesAfterClosedOutlineAreIgnored() {
        let original = fixture(), subset = original.mutableCopy()!
        subset.move(to: CGPoint(x: 5, y: 7))
        XCTAssertNotEqual(original, subset)
        XCTAssertTrue(PDFGlyphOutlineIdentity.matches(original, subset))
        XCTAssertTrue(PDFGlyphOutlineIdentity.matches(subset, original))
        subset.move(to: CGPoint(x: 100, y: -200))
        XCTAssertTrue(PDFGlyphOutlineIdentity.matches(original, subset))
    }

    func testEveryControlAndEndpointCoordinateRemainsExact() {
        // The surrounding square fixes the bounding box. A one-ULP change to
        // any interior move, line, quadratic, or cubic coordinate must fail.
        let original = fixture()
        for index in points.indices {
            for axis in 0..<2 {
                var altered = points
                if axis == 0 { altered[index].x = altered[index].x.nextUp }
                else { altered[index].y = altered[index].y.nextUp }
                let changed = fixture(altered)
                changed.move(to: CGPoint(x: 7, y: 9))
                XCTAssertFalse(PDFGlyphOutlineIdentity.matches(original, changed), "point \(index), axis \(axis)")
            }
        }
    }

    func testIntermediateMoveAndAdditionalDrawingAreNotDiscarded() {
        let original = fixture(), changed = original.mutableCopy()!
        changed.move(to: CGPoint(x: 4, y: 4)); changed.addLine(to: CGPoint(x: 6, y: 6)); changed.closeSubpath()
        XCTAssertFalse(PDFGlyphOutlineIdentity.matches(original, changed))
        let middle = CGMutablePath()
        middle.addRect(CGRect(x: 0, y: 0, width: 10, height: 10))
        middle.move(to: points[0]); middle.addLine(to: points[1])
        middle.move(to: CGPoint(x: 7, y: 7))
        middle.addQuadCurve(to: points[3], control: points[2])
        middle.addCurve(to: points[6], control1: points[4], control2: points[5]); middle.closeSubpath()
        middle.move(to: CGPoint(x: 7, y: 9))
        XCTAssertFalse(PDFGlyphOutlineIdentity.matches(original, middle))
    }

    func testOpenOrEmptyShapeDoesNotAcquireAnEquivalentClosedOutline() {
        let open = CGMutablePath(); open.move(to: .zero); open.addLine(to: CGPoint(x: 1, y: 2))
        let altered = open.mutableCopy()!; altered.move(to: CGPoint(x: 3, y: 4))
        XCTAssertFalse(PDFGlyphOutlineIdentity.matches(open, altered))
        let empty = CGMutablePath(), moveOnly = CGMutablePath(); moveOnly.move(to: CGPoint(x: 1, y: 2))
        XCTAssertFalse(PDFGlyphOutlineIdentity.matches(empty, moveOnly))
        XCTAssertTrue(PDFGlyphOutlineIdentity.matches(open, open.copy()!), "Already-exact paths keep existing behavior.")
    }

    func testContourOrderAndElementKindRemainExact() {
        let original = fixture(), reordered = interior(points)
        reordered.addRect(CGRect(x: 0, y: 0, width: 10, height: 10)); reordered.move(to: CGPoint(x: 7, y: 9))
        XCTAssertFalse(PDFGlyphOutlineIdentity.matches(original, reordered))
        let line = CGMutablePath(); line.move(to: .zero); line.addLine(to: CGPoint(x: 2, y: 2)); line.closeSubpath()
        let quad = CGMutablePath(); quad.move(to: .zero); quad.addQuadCurve(to: CGPoint(x: 2, y: 2), control: CGPoint(x: 1, y: 1)); quad.closeSubpath(); quad.move(to: CGPoint(x: 7, y: 9))
        XCTAssertFalse(PDFGlyphOutlineIdentity.matches(line, quad), "Even geometrically collinear elements are not rewritten.")
    }

    func testNewCanonicalAdmissionHasFiniteElementLimit() {
        let large = CGMutablePath(); large.move(to: .zero)
        for i in 0..<PDFGlyphOutlineIdentity.maximumCanonicalElements { large.addLine(to: CGPoint(x: i % 17, y: i % 19)) }
        large.closeSubpath()
        let extra = large.mutableCopy()!; extra.move(to: CGPoint(x: 7, y: 9))
        XCTAssertFalse(PDFGlyphOutlineIdentity.matches(large, extra))
    }

    private var points: [CGPoint] {
        [CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 2), CGPoint(x: 4, y: 3),
         CGPoint(x: 5, y: 4), CGPoint(x: 6, y: 5), CGPoint(x: 5, y: 6), CGPoint(x: 4, y: 7)]
    }
    private func fixture(_ replacement: [CGPoint]? = nil) -> CGMutablePath {
        let result = CGMutablePath(); result.addRect(CGRect(x: 0, y: 0, width: 10, height: 10)); result.addPath(interior(replacement ?? points)); return result
    }
    private func interior(_ p: [CGPoint]) -> CGMutablePath {
        let result = CGMutablePath(); result.move(to: p[0]); result.addLine(to: p[1])
        result.addQuadCurve(to: p[3], control: p[2]); result.addCurve(to: p[6], control1: p[4], control2: p[5]); result.closeSubpath(); return result
    }
}
