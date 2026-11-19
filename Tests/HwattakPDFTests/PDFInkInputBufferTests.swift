// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import HwattakPDF

final class PDFInkInputBufferTests: XCTestCase {
    func testIncrementalWidthsExactlyMatchTheCommittedRendererForEveryPenAndPattern() throws {
        let points = (0..<120).map { CGPoint(x: CGFloat($0) * 2, y: sin(CGFloat($0) * 0.2) * 30) }
        let pressures = (0..<120).map { CGFloat($0 % 13) / 12 }
        for style in PDFInkStyle.allCases {
            for pattern in [PDFInkPattern.solid, .dashed] {
                var settings = InkSettings()
                settings.selectStyle(style)
                settings.drawingOptions.pattern = pattern
                var buffer = PDFInkInputBuffer(settings: settings)
                for index in points.indices { buffer.append(points[index], pressure: pressures[index]) }
                let expected = try XCTUnwrap(PDFInkStrokeRenderer.stroke(points: points, pressures: pressures,
                    width: settings.width, style: style, options: settings.drawingOptions))
                XCTAssertEqual(buffer.geometry, expected, "\(style), \(pattern)")
                XCTAssertEqual(buffer.widthSampleCount, points.count * 2 - 1)
            }
        }
    }

    func testLongFreehandStrokeRepaintsOnlyTheNearbySegments() throws {
        var settings = InkSettings()
        settings.width = 2
        var buffer = PDFInkInputBuffer(settings: settings)
        var dirty = CGRect.null
        for index in 0..<8_000 {
            dirty = buffer.append(CGPoint(x: CGFloat(index) * 3, y: 40), pressure: 1)
        }
        XCTAssertEqual(buffer.widthSampleCount, 15_999)
        XCTAssertLessThan(dirty.width, 10)
        let visible = buffer.strokes(intersecting: dirty)
        XCTAssertFalse(visible.isEmpty)
        XCTAssertLessThan(visible.reduce(0) { $0 + $1.points.count }, 10)
        XCTAssertEqual(visible.last?.points.last, buffer.points.last)
    }

    func testDirtyRegionIncludesEveryEarlierCrossingWithoutPaintingDistantSegments() {
        var buffer = PDFInkInputBuffer(settings: InkSettings())
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100),
                      CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        for point in points { buffer.append(point, pressure: 1) }
        let strokes = buffer.strokes(intersecting: CGRect(x: 45, y: -2, width: 10, height: 4))
        XCTAssertEqual(strokes.count, 2)
        XCTAssertEqual(strokes.map(\.points), [[points[0], points[1]], [points[4], points[5]]])
    }

    func testDashedPreviewClippingRetainsOriginalPhaseAndBoundsExpansion() throws {
        var settings = InkSettings()
        settings.drawingOptions.pattern = .dashed
        var buffer = PDFInkInputBuffer(settings: settings)
        for index in 0..<4 { buffer.append(CGPoint(x: CGFloat(index) * 10, y: 10), pressure: 1) }
        let originalDash = try XCTUnwrap(buffer.geometry?.dash)
        let fragment = try XCTUnwrap(buffer.strokes(intersecting: CGRect(x: 25, y: 8, width: 1, height: 4)).first)
        XCTAssertEqual(fragment.points.first?.x, 20)
        XCTAssertEqual(fragment.dash, originalDash.advanced(by: 20))

        // Every individual segment is valid, but capture must also bound the
        // total expansion before sending the accumulated preview to drawing.
        var large = PDFInkInputBuffer(settings: settings)
        large.append(CGPoint(x: 0, y: 0), pressure: 1)
        for index in 1...40 {
            large.append(CGPoint(x: index % 2 == 0 ? 0 : 100_000, y: 0), pressure: 1)
        }
        XCTAssertTrue(try XCTUnwrap(large.geometry).isValid)
        XCTAssertLessThan(large.points.count, 41)
    }

    func testShapePreviewKeepsOnlyEndpointsAndMatchesFinalShape() throws {
        for shape in [PDFInkShape.line, .rectangle, .ellipse] {
            var settings = InkSettings()
            settings.drawingOptions.shape = shape
            var buffer = PDFInkInputBuffer(settings: settings)
            for index in 0..<500 {
                buffer.append(CGPoint(x: 20 + CGFloat(index), y: 50 + CGFloat(index) / 2), pressure: 1)
            }
            XCTAssertEqual(buffer.points.count, 2)
            let expected = try XCTUnwrap(PDFInkStrokeRenderer.stroke(points: buffer.points, pressures: [1, 1],
                width: settings.width, style: settings.style, options: settings.drawingOptions))
            XCTAssertEqual(buffer.geometry, expected)
        }
    }

    func testTabletPressurePromotionRebuildsEarlierMouseSamplesOnce() throws {
        var buffer = PDFInkInputBuffer(settings: InkSettings())
        for index in 0..<30 { buffer.append(CGPoint(x: CGFloat(index), y: CGFloat(index)), pressure: 1) }
        let oldBounds = buffer.paintedBounds
        let dirty = buffer.promoteToPressure(0.35)
        XCTAssertTrue(dirty.contains(oldBounds))
        let expected = try XCTUnwrap(PDFInkStrokeRenderer.stroke(points: buffer.points,
            pressures: Array(repeating: 0.35, count: 30), width: buffer.settings.width,
            style: buffer.settings.style, options: buffer.settings.drawingOptions))
        XCTAssertEqual(buffer.geometry, expected)
        XCTAssertEqual(buffer.widthSampleCount, 59 + 30)
    }

    func testCaptureLimitCompactionRetainsTheLastVisiblePointAndReleaseEndpoint() throws {
        var buffer = PDFInkInputBuffer(settings: InkSettings())
        for index in 0..<PressureInkAnnotation.maximumPoints {
            buffer.append(CGPoint(x: CGFloat(index), y: 80), pressure: 1)
        }
        let previousLast = try XCTUnwrap(buffer.points.last)
        let release = CGPoint(x: previousLast.x + 2, y: 83)
        let dirty = buffer.append(release, pressure: 0.6)
        XCTAssertLessThan(buffer.points.count, PressureInkAnnotation.maximumPoints)
        XCTAssertEqual(buffer.points.first, CGPoint(x: 0, y: 80))
        XCTAssertEqual(buffer.points[buffer.points.count - 2], previousLast)
        XCTAssertEqual(buffer.points.last, release)
        XCTAssertTrue(dirty.contains(previousLast))
        XCTAssertEqual(buffer.geometry, PDFInkStrokeRenderer.stroke(points: buffer.points,
            pressures: buffer.pressures, width: buffer.settings.width, style: buffer.settings.style,
            options: buffer.settings.drawingOptions))
    }
}
