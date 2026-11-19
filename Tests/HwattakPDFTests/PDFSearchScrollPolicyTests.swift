// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import XCTest
@testable import HwattakPDF

final class PDFSearchScrollPolicyTests: XCTestCase {
    private let bounds = CGRect(x: 100, y: 200, width: 400, height: 1_000)

    func testVerticalProgressUsesPhysicalTopForFlippedAndUnflippedCoordinates() throws {
        XCTAssertEqual(try progress(CGPoint(x: 100, y: 200), flipped: true), 0)
        XCTAssertEqual(try progress(CGPoint(x: 100, y: 1_200), flipped: true), 1)
        XCTAssertEqual(try progress(CGPoint(x: 100, y: 200), flipped: false), 1)
        XCTAssertEqual(try progress(CGPoint(x: 100, y: 1_200), flipped: false), 0)
        XCTAssertEqual(try progress(CGPoint(x: 100, y: 450), flipped: true), 0.25)
        XCTAssertEqual(try progress(CGPoint(x: 100, y: 450), flipped: false), 0.75)
    }

    func testHorizontalProgressUsesLeftOriginRegardlessOfFlipping() throws {
        for flipped in [false, true] {
            XCTAssertEqual(try progress(CGPoint(x: 100, y: 800), axis: .horizontal, flipped: flipped), 0)
            XCTAssertEqual(try progress(CGPoint(x: 400, y: 800), axis: .horizontal, flipped: flipped), 0.75)
            XCTAssertEqual(try progress(CGPoint(x: 500, y: 800), axis: .horizontal, flipped: flipped), 1)
        }
    }

    func testMarkerProgressClampsHitsOutsideDocumentEdges() throws {
        XCTAssertEqual(try progress(CGPoint(x: 100, y: 150), flipped: true), 0)
        XCTAssertEqual(try progress(CGPoint(x: 100, y: 1_250), flipped: true), 1)
        XCTAssertEqual(try progress(CGPoint(x: 100, y: 150), flipped: false), 1)
        XCTAssertEqual(try progress(CGPoint(x: 550, y: 800), axis: .horizontal, flipped: false), 1)
    }

    func testMarkerProgressRejectsEmptyOrInvalidGeometry() {
        let invalidBounds = [
            CGRect.zero,
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: -1),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                   width: CGFloat.greatestFiniteMagnitude, height: 100)
        ]
        for bounds in invalidBounds {
            XCTAssertNil(PDFSearchScrollPolicy.markerProgress(
                point: CGPoint(x: 20, y: 20), documentBounds: bounds, axis: .vertical, isFlipped: true
            ))
        }
        for point in [CGPoint(x: CGFloat.nan, y: 20), CGPoint(x: 20, y: CGFloat.infinity)] {
            XCTAssertNil(PDFSearchScrollPolicy.markerProgress(
                point: point, documentBounds: bounds, axis: .vertical, isFlipped: true
            ))
        }
    }

    func testSnapOffsetMovesHitToReadingAnchorInFlippedCoordinates() throws {
        // A viewport beginning at 200 and 100 units tall reads at 228.
        XCTAssertEqual(try XCTUnwrap(snap(238)), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snap(218)), -10, accuracy: 0.0001)
    }

    func testSnapOffsetMovesHitToReadingAnchorInUnflippedCoordinates() throws {
        // The physical top is y=300, so the reading anchor is y=272.
        XCTAssertEqual(try XCTUnwrap(snap(282, flipped: false)), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snap(262, flipped: false)), -10, accuracy: 0.0001)
    }

    func testHorizontalSnapUsesLeftAnchorEvenWhenDocumentIsUnflipped() throws {
        for flipped in [false, true] {
            XCTAssertEqual(try XCTUnwrap(snap(238, axis: .horizontal, flipped: flipped)), 10, accuracy: 0.0001)
        }
    }

    func testSnapLimitsAreInclusiveAndDoNotSnapToDistantHits() throws {
        for direction in [CGFloat(-1), CGFloat(1)] {
            XCTAssertEqual(try XCTUnwrap(snap(228 + direction * 18)), direction * 18, accuracy: 0.0001)
            XCTAssertNil(snap(228 + direction * 18.01))
            XCTAssertNil(snap(228 + direction * 100))
        }
    }

    func testTinyOffsetsDoNotJitterButMinimumDistanceCanSnap() throws {
        XCTAssertNil(snap(228))
        XCTAssertNil(snap(228.5))
        XCTAssertNil(snap(227.5))
        XCTAssertEqual(try XCTUnwrap(snap(228.75)), 0.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snap(227.25)), -0.75, accuracy: 0.0001)
    }

    func testZoomChangesAllowedDocumentDistanceWithoutChangingScreenLimit() throws {
        XCTAssertEqual(try XCTUnwrap(snap(237, scale: 2)), 9, accuracy: 0.0001)
        XCTAssertNil(snap(238, scale: 2))
        XCTAssertEqual(try XCTUnwrap(snap(264, scale: 0.5)), 36, accuracy: 0.0001)
        XCTAssertNil(snap(264.1, scale: 0.5))
        XCTAssertNil(snap(228.5, scale: 1))
        XCTAssertEqual(try XCTUnwrap(snap(228.5, scale: 2)), 0.5, accuracy: 0.0001)
    }

    func testSnapRejectsInvalidInputAndOverflow() {
        for scale in [CGFloat(0), -1, .nan, .infinity] {
            XCTAssertNil(snap(238, scale: scale))
        }
        for length in [CGFloat(0), -1, .nan, .infinity] {
            XCTAssertNil(PDFSearchScrollPolicy.snapOffset(
                hitCoordinate: 238, viewportOrigin: 200, viewportLength: length,
                axis: .vertical, isFlipped: true
            ))
        }
        XCTAssertNil(snap(.nan))
        XCTAssertNil(snap(.infinity))
        XCTAssertNil(PDFSearchScrollPolicy.snapOffset(
            hitCoordinate: 238, viewportOrigin: .nan, viewportLength: 100,
            axis: .vertical, isFlipped: true
        ))
        XCTAssertNil(PDFSearchScrollPolicy.snapOffset(
            hitCoordinate: 0, viewportOrigin: .greatestFiniteMagnitude,
            viewportLength: .greatestFiniteMagnitude, axis: .vertical, isFlipped: false
        ))
    }

    func testMergingKeepsSortedRealHitPositionsOncePerTwoTrackUnits() {
        XCTAssertEqual(PDFSearchScrollPolicy.mergeMarkerProgresses(
            [0.5, 0.019, 0.01, 0.5, 0.021, 0, 1], trackLength: 100
        ), [0, 0.021, 0.5, 1])
    }

    func testMergingIgnoresInvalidValuesAndClampsEdges() {
        XCTAssertEqual(PDFSearchScrollPolicy.mergeMarkerProgresses(
            [.nan, .infinity, -.infinity, -1, 0, 0.5, 1, 2], trackLength: 100
        ), [0, 0.5, 1])
        for length in [CGFloat(0), -1, .nan, .infinity] {
            XCTAssertEqual(PDFSearchScrollPolicy.mergeMarkerProgresses([0, 0.5, 1], trackLength: length), [])
        }
        XCTAssertEqual(PDFSearchScrollPolicy.mergeMarkerProgresses([], trackLength: 100), [])
    }

    func testDenseMarkersAreBoundedByTrackResolution() {
        let values = (0...20_000).map { CGFloat($0) / 20_000 }
        let merged = PDFSearchScrollPolicy.mergeMarkerProgresses(values, trackLength: 300)
        XCTAssertEqual(merged.count, 151)
        XCTAssertEqual(merged.first, 0)
        XCTAssertEqual(merged.last, 1)
        XCTAssertEqual(merged, merged.sorted())
        XCTAssertEqual(PDFSearchScrollPolicy.mergeMarkerProgresses(values, trackLength: 1), [0])
    }

    private func progress(
        _ point: CGPoint,
        axis: PDFSearchScrollAxis = .vertical,
        flipped: Bool
    ) throws -> CGFloat {
        try XCTUnwrap(PDFSearchScrollPolicy.markerProgress(
            point: point, documentBounds: bounds, axis: axis, isFlipped: flipped
        ))
    }

    private func snap(
        _ coordinate: CGFloat,
        axis: PDFSearchScrollAxis = .vertical,
        flipped: Bool = true,
        scale: CGFloat = 1
    ) -> CGFloat? {
        PDFSearchScrollPolicy.snapOffset(
            hitCoordinate: coordinate, viewportOrigin: 200, viewportLength: 100,
            axis: axis, isFlipped: flipped, screenScale: scale
        )
    }
}
