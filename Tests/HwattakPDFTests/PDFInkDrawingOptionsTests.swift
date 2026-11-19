// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInkDrawingOptionsTests: XCTestCase {
    func testShapeUsesGestureEndpointsAndNeverIntermediateWobble() throws {
        let first = CGPoint(x: 240, y: 260), last = CGPoint(x: 40, y: 60)
        let input = [first, CGPoint(x: 300, y: 20), last]
        for shape in PDFInkShape.allCases {
            let stroke = try geometry(input, shape: shape)
            switch shape {
            case .freehand: XCTAssertEqual(stroke.points, input)
            case .line: XCTAssertEqual(stroke.points, [first, last])
            case .rectangle:
                XCTAssertEqual(stroke.points, [first, CGPoint(x: 40, y: 260), last, CGPoint(x: 240, y: 60), first])
            case .ellipse:
                XCTAssertLessThanOrEqual(stroke.points.count, 513)
                XCTAssertEqual(stroke.points.first, stroke.points.last)
                XCTAssertEqual(stroke.points.map(\.x).min()!, 40, accuracy: 0.001)
                XCTAssertEqual(stroke.points.map(\.x).max()!, 240, accuracy: 0.001)
                XCTAssertEqual(stroke.points.map(\.y).min()!, 60, accuracy: 0.001)
                XCTAssertEqual(stroke.points.map(\.y).max()!, 260, accuracy: 0.001)
                for point in stroke.points {
                    XCTAssertEqual(pow((point.x - 140) / 100, 2) + pow((point.y - 160) / 100, 2), 1, accuracy: 0.0001)
                }
            }
        }
    }

    func testDegenerateShapesStayFiniteAndBounded() throws {
        for shape in PDFInkShape.allCases {
            let point = CGPoint(x: 50, y: 50)
            let dot = try geometry([point], shape: shape)
            XCTAssertEqual(dot.points, [point])
            XCTAssertTrue(dot.isValid)
            let vertical = try geometry([point, CGPoint(x: 50, y: 250)], shape: shape)
            XCTAssertTrue(vertical.isValid)
        }
    }

    func testSquareAndRoundHighlightersHaveDifferentActualCapsAfterSaving() throws {
        for save in [false, true] {
            let square = try bitmap(annotation(tip: .square), save: save)
            let round = try bitmap(annotation(tip: .round), save: save)
            // First endpoint x=40, width=20. Square has no extension before
            // its endpoint; a round cap extends another half width.
            XCTAssertGreaterThan(try red(square, x: 34, y: 160), 0.95)
            XCTAssertLessThan(try red(round, x: 34, y: 160), 0.1)
            XCTAssertLessThan(try red(square, x: 45, y: 160), 0.1)
        }
    }

    func testDashPhaseDoesNotRestartAtCapturedSamples() throws {
        let simple = try annotation(points: [CGPoint(x: 40, y: 160), CGPoint(x: 280, y: 160)], pattern: .dashed)
        let sampled = try annotation(points: [40, 53, 79, 128, 176, 209, 280].map { CGPoint(x: $0, y: 160) }, pattern: .dashed)
        let first = try bitmap(simple), second = try bitmap(sampled)
        for x in 40..<280 {
            XCTAssertEqual(try red(first, x: x, y: 160), try red(second, x: x, y: 160), accuracy: 0.025,
                "Pointer sampling must not change visible dashes at x=\(x)")
        }
    }

    func testPartialErasingKeepsDashPhaseAfterCopySaveAndAnotherErase() throws {
        let source = try annotation(pattern: .dashed, width: 4)
        let originalDocument = try roundTrip(document(source))
        let original = try XCTUnwrap(originalDocument.page(at: 0)?.annotations.first)
        let before = try bitmap(original)
        let first = try erase(original, x: 143)
        let copied = try XCTUnwrap(first.copy() as? PDFAnnotation)
        let reopened = try roundTrip(document(copied))
        let final = try erase(XCTUnwrap(reopened.page(at: 0)?.annotations.first), x: 208)
        let after = try bitmap(final, save: true)
        for x in 45..<275 where abs(x - 143) > 16 && abs(x - 208) > 16 {
            XCTAssertEqual(try red(before, x: x, y: 160), try red(after, x: x, y: 160), accuracy: 0.025,
                "Erasing must retain dashes and gaps elsewhere at x=\(x)")
        }
        for x in [143, 208] { XCTAssertGreaterThan(try red(after, x: x, y: 160), 0.95) }
        let finalGeometry = try XCTUnwrap(PressureInkAnnotation.geometry(of: final))
        XCTAssertEqual(finalGeometry.options.pattern, .dashed)
        XCTAssertEqual(finalGeometry.strokes.count, 3)
        XCTAssertTrue(finalGeometry.strokes.dropFirst().allSatisfy { ($0.dash?.phase ?? 0) > 0 })
    }

    func testAllShapeOptionsSurviveSaveReopenAndEraseWithoutClosingFragments() throws {
        for shape in PDFInkShape.allCases {
            for pattern in PDFInkPattern.allCases {
                let options = PDFInkDrawingOptions(shape: shape, pattern: pattern, highlighterTip: .round)
                let annotation = try XCTUnwrap(PressureInkAnnotation(points: [CGPoint(x: 40, y: 60), CGPoint(x: 280, y: 260)],
                    pressures: [1, 1], width: 6, color: .black, style: .highlighter, options: options))
                let saved = try roundTrip(document(annotation))
                let generic = try XCTUnwrap(saved.page(at: 0)?.annotations.first)
                let before = try XCTUnwrap(PressureInkAnnotation.geometry(of: generic))
                XCTAssertEqual(before.options, options)
                let anchor = before.strokes[0].points[before.strokes[0].points.count / 2]
                guard case let .replaced(replacements) = PDFInkPartialEraser.replacements(for: generic,
                    from: anchor, to: anchor, radius: 7) else { return XCTFail("Shape was not erased") }
                let replacement = try XCTUnwrap(replacements.first)
                let erased = try XCTUnwrap(PressureInkAnnotation.geometry(of: replacement))
                let twice = try roundTrip(document(replacement))
                let persisted = try XCTUnwrap(PressureInkAnnotation.geometry(of: XCTUnwrap(twice.page(at: 0)?.annotations.first)))
                XCTAssertEqual(persisted.options, options)
                assertSameGeometry(persisted.strokes, erased.strokes)
                XCTAssertNotEqual(persisted.strokes, before.strokes)
            }
        }
    }

    func testMovingAndScalingPreservesRelativeDashPhase() throws {
        let source = try annotation(pattern: .dashed, width: 4)
        let erased = try erase(source, x: 143)
        let before = try XCTUnwrap(PressureInkAnnotation.geometry(of: erased))
        erased.bounds = CGRect(x: erased.bounds.minX + 20, y: erased.bounds.minY + 30,
            width: erased.bounds.width * 2, height: erased.bounds.height * 2)
        let after = try XCTUnwrap(PressureInkAnnotation.geometry(of: erased))
        for (a, b) in zip(before.strokes, after.strokes) {
            let first = try XCTUnwrap(a.dash), second = try XCTUnwrap(b.dash)
            XCTAssertEqual(second.length, first.length * 2, accuracy: 0.0001)
            XCTAssertEqual(second.phase, first.phase * 2, accuracy: 0.0001)
        }
    }

    func testLegacyOptionsDefaultAndInvalidDashMetadataIsRejected() throws {
        let source = try annotation()
        let key = PDFAnnotationKey(rawValue: "/HwattakPDFInkGeometry")
        let encoded = try XCTUnwrap(source.value(forAnnotationKey: key) as? String)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        payload["version"] = 2
        payload.removeValue(forKey: "options")
        let generic = PDFAnnotation(bounds: source.bounds, forType: .stamp, withProperties: nil)
        generic.setValue(PressureInkAnnotation.stampName, forAnnotationKey: .iconName)
        func install() throws {
            generic.setValue(String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!, forAnnotationKey: key)
        }
        try install()
        XCTAssertEqual(PressureInkAnnotation.geometry(of: generic)?.options, .init())
        payload["version"] = 3
        payload["options"] = ["shape": "freehand", "pattern": "dashed", "highlighterTip": "square"]
        try install()
        XCTAssertNil(PressureInkAnnotation.geometry(of: generic), "Dash appearance without geometry is not safely editable")
        var strokes = try XCTUnwrap(payload["strokes"] as? [[String: Any]])
        strokes[0]["dash"] = ["length": 12, "phase": -1]
        payload["strokes"] = strokes
        try install()
        XCTAssertNil(PressureInkAnnotation.geometry(of: generic))
        strokes[0]["dash"] = ["length": 0.000001, "phase": 0]
        payload["strokes"] = strokes
        try install()
        XCTAssertNil(PressureInkAnnotation.geometry(of: generic), "Unbounded dash expansion is rejected before CoreGraphics")
    }

    private func geometry(_ points: [CGPoint], shape: PDFInkShape) throws -> PDFInkStrokeGeometry {
        try XCTUnwrap(PDFInkStrokeRenderer.stroke(points: points, pressures: Array(repeating: 1, count: points.count),
            width: 4, style: .ink, options: PDFInkDrawingOptions(shape: shape)))
    }

    private func assertSameGeometry(_ actual: [PDFInkStrokeGeometry], _ expected: [PDFInkStrokeGeometry],
                                    file: StaticString = #filePath, line: UInt = #line) {
        // PDFKit rounds the serialized annotation rectangle. Transforming the
        // exact stored geometry back to that rectangle moves this fixture by
        // at most 0.000045 pt; permit 0.0001 pt, while checking every point and
        // segment so saving cannot regenerate or close any erased fragment.
        let tolerance: CGFloat = 0.0001
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.points.count, b.points.count, file: file, line: line)
            XCTAssertEqual(a.widths.count, b.widths.count, file: file, line: line)
            for (first, second) in zip(a.points, b.points) {
                XCTAssertEqual(first.x, second.x, accuracy: tolerance, file: file, line: line)
                XCTAssertEqual(first.y, second.y, accuracy: tolerance, file: file, line: line)
            }
            for (first, second) in zip(a.widths, b.widths) {
                XCTAssertEqual(first, second, accuracy: tolerance, file: file, line: line)
            }
            switch (a.dash, b.dash) {
            case (nil, nil): break
            case let (.some(first), .some(second)):
                XCTAssertEqual(first.length, second.length, accuracy: tolerance, file: file, line: line)
                XCTAssertEqual(first.phase, second.phase, accuracy: tolerance, file: file, line: line)
            default: XCTFail("Saving must preserve whether a fragment is dashed.", file: file, line: line)
            }
        }
    }

    private func annotation(points: [CGPoint] = [CGPoint(x: 40, y: 160), CGPoint(x: 280, y: 160)],
                            pattern: PDFInkPattern = .solid, tip: PDFHighlighterTip = .square,
                            width: CGFloat = 20) throws -> PressureInkAnnotation {
        try XCTUnwrap(PressureInkAnnotation(points: points, pressures: Array(repeating: 1, count: points.count),
            width: width, color: .black, style: .highlighter,
            options: PDFInkDrawingOptions(pattern: pattern, highlighterTip: tip)))
    }

    private func erase(_ annotation: PDFAnnotation, x: CGFloat) throws -> PDFAnnotation {
        guard case let .replaced(replacements) = PDFInkPartialEraser.replacements(for: annotation,
            from: CGPoint(x: x, y: 145), to: CGPoint(x: x, y: 175), radius: 7) else {
            throw NSError(domain: "PDFInkDrawingOptionsTests", code: 1)
        }
        return try XCTUnwrap(replacements.first)
    }

    private func document(_ annotation: PDFAnnotation) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 320, height: 320)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        try XCTUnwrap(document.page(at: 0)).addAnnotation(annotation)
        return document
    }

    private func roundTrip(_ document: PDFDocument) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
    }

    private func bitmap(_ annotation: PDFAnnotation, save: Bool = false) throws -> NSBitmapImageRep {
        let copy = try XCTUnwrap(annotation.copy() as? PDFAnnotation)
        let original = try document(copy)
        let target = save ? try roundTrip(original) : original
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 320,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        try XCTUnwrap(target.page(at: 0)).draw(with: .mediaBox, to: graphics.cgContext)
        graphics.flushGraphics()
        return bitmap
    }

    private func red(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
        try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)).redComponent
    }
}
