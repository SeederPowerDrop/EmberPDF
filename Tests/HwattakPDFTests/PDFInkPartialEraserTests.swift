// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInkPartialEraserTests: XCTestCase {
    func testSweptEraserCutsBetweenPointerEventsAndKeepsExactWidths() {
        let stroke = PDFInkStrokeGeometry(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], widths: [4])
        let result = PDFInkPartialEraser.split(stroke, from: CGPoint(x: 50, y: -30), to: CGPoint(x: 50, y: 30), radius: 5)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.fragments.count, 2)
        XCTAssertEqual(result.fragments[0].points.first, stroke.points.first)
        XCTAssertEqual(result.fragments[1].points.last, stroke.points.last)
        XCTAssertEqual(result.fragments[0].points.last!.x, 42.99, accuracy: 0.001)
        XCTAssertEqual(result.fragments[1].points.first!.x, 57.01, accuracy: 0.001)
        XCTAssertEqual(result.fragments.map(\.widths), [[4], [4]])
    }

    func testEndpointAndFullErasureDoNotLeaveOrReconnectFragments() {
        let stroke = PDFInkStrokeGeometry(points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 20)], widths: [4])
        let endpoint = PDFInkPartialEraser.split(stroke, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 20, y: 20), radius: 8)
        XCTAssertEqual(endpoint.fragments.count, 1)
        XCTAssertGreaterThan(endpoint.fragments[0].points[0].x, 30)
        let full = PDFInkPartialEraser.split(stroke, from: CGPoint(x: 0, y: 20), to: CGPoint(x: 100, y: 20), radius: 5)
        XCTAssertTrue(full.changed)
        XCTAssertTrue(full.fragments.isEmpty)
        let dot = PDFInkStrokeGeometry(points: [CGPoint(x: 30, y: 30)], widths: [6])
        XCTAssertTrue(PDFInkPartialEraser.split(dot, from: CGPoint(x: 30, y: 0), to: CGPoint(x: 30, y: 60), radius: 2).fragments.isEmpty)
    }

    func testMissIsAnExactNoOpAndInvalidGeometryIsRefused() throws {
        let ink = makeNativeInk()
        let originalPath = try XCTUnwrap(ink.paths?.first)
        guard case .unchanged = PDFInkPartialEraser.replacements(for: ink, from: .zero, to: CGPoint(x: 10, y: 10), radius: 2) else {
            return XCTFail("A distant eraser must not replace or flatten the original")
        }
        XCTAssertTrue(ink.paths?.first === originalPath)
        guard case .unsupported = PDFInkPartialEraser.replacements(for: ink, from: CGPoint(x: CGFloat.nan, y: 0), to: .zero, radius: 4) else {
            return XCTFail("Nonfinite input must be refused")
        }
        let image = PDFAnnotation(bounds: ink.bounds, forType: .stamp, withProperties: nil)
        XCTAssertFalse(PDFInkPartialEraser.supports(image))
        guard case .unsupported = PDFInkPartialEraser.replacements(for: image, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), radius: 10) else {
            return XCTFail("Images and other stamps have no editable ink geometry")
        }
    }

    func testPressureFragmentsKeepWidthsOpacityMetadataAndSourceIndependent() throws {
        let stroke = PDFInkStrokeGeometry(points: [CGPoint(x: 20, y: 100), CGPoint(x: 60, y: 100), CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 100)], widths: [4, 8, 12])
        let original = try XCTUnwrap(PressureInkAnnotation(strokes: [stroke], color: NSColor.blue.withAlphaComponent(0.35)))
        original.contents = "Keep this note"
        original.userName = nil
        original.shouldPrint = false
        let result = try replacement(original, at: CGPoint(x: 80, y: 100), radius: 5)
        let geometry = try XCTUnwrap(PressureInkAnnotation.geometry(of: result))
        XCTAssertEqual(geometry.strokes.count, 2)
        XCTAssertEqual(geometry.strokes[0].widths, [4, 8])
        XCTAssertEqual(geometry.strokes[1].widths, [8, 12])
        XCTAssertEqual(geometry.color.alphaComponent, 0.35, accuracy: 0.0001)
        XCTAssertEqual(result.contents, "Keep this note")
        XCTAssertNil(result.userName)
        XCTAssertFalse(result.shouldPrint)
        XCTAssertNil(result.page)
        XCTAssertEqual(PressureInkAnnotation.geometry(of: original)?.strokes, [stroke])
    }

    func testPressureEraseSavesAsVisibleGapAndRemainsPartiallyEditableAfterReopen() throws {
        let original = try XCTUnwrap(PressureInkAnnotation(points: [CGPoint(x: 20, y: 100), CGPoint(x: 80, y: 100), CGPoint(x: 120, y: 100), CGPoint(x: 180, y: 100)], pressures: [0.1, 0.1, 1, 1], width: 12, color: .blue))
        let partial = try replacement(original, at: CGPoint(x: 100, y: 100), radius: 8)
        let reopened = try document(containing: partial, roundTrip: true)
        let page = try XCTUnwrap(reopened.page(at: 0))
        let saved = try XCTUnwrap(page.annotations.first)
        XCTAssertNotNil(PressureInkAnnotation.geometry(of: saved), "Saved shape metadata must survive PDFKit's Stamp rebuild")
        try assertWhite(page, at: CGPoint(x: 100, y: 100))
        try assertBlue(page, at: CGPoint(x: 50, y: 100))
        try assertBlue(page, at: CGPoint(x: 150, y: 104))
        let second = try replacement(saved, at: CGPoint(x: 50, y: 100), radius: 5)
        let twice = try XCTUnwrap(document(containing: second, roundTrip: true).page(at: 0))
        try assertWhite(twice, at: CGPoint(x: 50, y: 100))
        try assertWhite(twice, at: CGPoint(x: 100, y: 100))
        try assertBlue(twice, at: CGPoint(x: 150, y: 104))
    }

    func testTranslucentStrokeHasUniformSeamsAndOpacitySurvivesCopyAndSave() throws {
        let ink = try XCTUnwrap(PressureInkAnnotation(points: [CGPoint(x: 20, y: 100), CGPoint(x: 60, y: 100), CGPoint(x: 100, y: 100), CGPoint(x: 180, y: 100)], pressures: [1, 1, 1, 1], width: 12, color: NSColor.blue.withAlphaComponent(0.35)))
        let copied = try XCTUnwrap(ink.copy() as? PressureInkAnnotation)
        XCTAssertEqual(PressureInkAnnotation.geometry(of: copied)?.color.alphaComponent ?? -1, 0.35, accuracy: 0.0001)
        let page = try XCTUnwrap(document(containing: copied, roundTrip: true).page(at: 0))
        let middle = try color(page, at: CGPoint(x: 40, y: 100))
        let joint = try color(page, at: CGPoint(x: 60, y: 100))
        XCTAssertEqual(middle.redComponent, 0.65, accuracy: 0.025)
        XCTAssertEqual(joint.redComponent, middle.redComponent, accuracy: 0.015, "Segment caps must not double the opacity")
        let saved = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(PressureInkAnnotation.geometry(of: saved)?.color.alphaComponent ?? -1, 0.35, accuracy: 0.0001)
    }

    func testNativeInkKeepsMetadataAndCanBeErasedAgainAfterSave() throws {
        let original = makeNativeInk()
        original.contents = "Original ink note"
        original.userName = "Test author"
        let partial = try replacement(original, at: CGPoint(x: 100, y: 100), radius: 8)
        XCTAssertEqual(partial.type, "Ink")
        XCTAssertEqual(partial.paths?.count, 2)
        XCTAssertEqual(partial.bounds, original.bounds)
        XCTAssertEqual(partial.border?.lineWidth, 4)
        XCTAssertEqual(partial.contents, original.contents)
        XCTAssertEqual(partial.userName, original.userName)
        XCTAssertEqual(original.paths?.count, 1)
        let page = try XCTUnwrap(document(containing: partial, roundTrip: true).page(at: 0))
        try assertWhite(page, at: CGPoint(x: 100, y: 100))
        try assertBlue(page, at: CGPoint(x: 50, y: 100))
        let saved = try XCTUnwrap(page.annotations.first)
        let next = try replacement(saved, at: CGPoint(x: 50, y: 100), radius: 5)
        let twice = try XCTUnwrap(document(containing: next, roundTrip: true).page(at: 0))
        try assertWhite(twice, at: CGPoint(x: 50, y: 100))
        try assertBlue(twice, at: CGPoint(x: 150, y: 100))
    }

    func testTranslucentNativeInkPreservesOpacityAndUntouchedSubpathsAfterSave() throws {
        let original = makeNativeInk(height: 100, horizontalPadding: 4)
        original.color = NSColor.blue.withAlphaComponent(0.4)
        let untouched = NSBezierPath()
        untouched.move(to: CGPoint(x: 4, y: 70))
        untouched.curve(to: CGPoint(x: 164, y: 70), controlPoint1: CGPoint(x: 44, y: 90), controlPoint2: CGPoint(x: 124, y: 90))
        original.add(untouched)
        let partial = try replacement(original, at: CGPoint(x: 100, y: 100), radius: 8)
        XCTAssertTrue(partial is PressureInkAnnotation)
        let geometry = try XCTUnwrap(PressureInkAnnotation.geometry(of: partial))
        XCTAssertEqual(geometry.strokes.count, 3, "Keep both cut fragments and the untouched curved subpath")
        XCTAssertEqual(geometry.color.alphaComponent, 0.4, accuracy: 0.0001)
        XCTAssertEqual(original.paths?.count, 2)
        XCTAssertEqual(untouched.element(at: 1), .cubicCurveTo)
        let page = try XCTUnwrap(document(containing: partial, roundTrip: true).page(at: 0))
        try assertWhite(page, at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(try color(page, at: CGPoint(x: 50, y: 100)).redComponent, 0.6, accuracy: 0.025)
        XCTAssertEqual(try color(page, at: CGPoint(x: 100, y: 165)).redComponent, 0.6, accuracy: 0.025)
        let saved = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(PressureInkAnnotation.geometry(of: saved)?.color.alphaComponent ?? -1, 0.4, accuracy: 0.0001)
    }

    func testClippedTranslucentNativeInkIsRefusedWithoutChangingSource() throws {
        let original = makeNativeInk()
        original.color = NSColor.blue.withAlphaComponent(0.4)
        let path = try XCTUnwrap(original.paths?.first)
        // End caps extend outside this imported /Rect. An appearance with
        // larger bounds would reveal those previously clipped pixels.
        guard case .unsupported = PDFInkPartialEraser.replacements(for: original,
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), radius: 8) else {
            return XCTFail("Refuse conversion that would reveal clipped ink")
        }
        XCTAssertEqual(original.paths?.count, 1)
        XCTAssertTrue(original.paths?.first === path)
        XCTAssertEqual(original.color.alphaComponent, 0.4, accuracy: 0.0001)
    }

    func testImportedCubicCurveIsFlattenedOnlyWhenTouched() throws {
        let ink = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 110, height: 120), forType: .ink, withProperties: nil)
        ink.color = .blue
        let border = PDFBorder(); border.lineWidth = 4; ink.border = border
        let curve = NSBezierPath()
        curve.move(to: .zero)
        curve.curve(to: CGPoint(x: 100, y: 0), controlPoint1: CGPoint(x: 0, y: 100), controlPoint2: CGPoint(x: 100, y: 100))
        ink.add(curve)
        let untouched = NSBezierPath()
        untouched.move(to: CGPoint(x: 0, y: 110))
        untouched.curve(to: CGPoint(x: 100, y: 110), controlPoint1: CGPoint(x: 30, y: 115), controlPoint2: CGPoint(x: 70, y: 115))
        ink.add(untouched)
        let partial = try replacement(ink, at: CGPoint(x: 100, y: 125), radius: 6)
        XCTAssertEqual(partial.paths?.count, 3)
        XCTAssertEqual(partial.paths?.last?.element(at: 1), .cubicCurveTo, "An untouched imported curve must retain its exact path")
        XCTAssertEqual(curve.element(at: 1), .cubicCurveTo)
        let page = try XCTUnwrap(document(containing: partial, roundTrip: true).page(at: 0))
        try assertWhite(page, at: CGPoint(x: 100, y: 125))
    }

    func testQuadraticCurveAndClosedSubpathAreSupported() throws {
        let ink = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 110, height: 120), forType: .ink, withProperties: nil)
        ink.color = .blue
        let border = PDFBorder(); border.lineWidth = 4; ink.border = border
        let curve = NSBezierPath()
        curve.move(to: .zero)
        curve.curve(to: CGPoint(x: 100, y: 0), controlPoint: CGPoint(x: 50, y: 100))
        curve.close()
        ink.add(curve)
        let originalElementCount = curve.elementCount
        let partial = try replacement(ink, at: CGPoint(x: 100, y: 100), radius: 5)
        XCTAssertEqual(curve.elementCount, originalElementCount)
        let page = try XCTUnwrap(document(containing: partial, roundTrip: true).page(at: 0))
        try assertWhite(page, at: CGPoint(x: 100, y: 100))
        try assertBlue(page, at: CGPoint(x: 100, y: 51))
    }

    func testMalformedPressureMetadataNeverBecomesEditableGeometry() {
        let stamp = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), forType: .stamp, withProperties: nil)
        stamp.setValue(PressureInkAnnotation.stampName, forAnnotationKey: .iconName)
        stamp.setValue("{not JSON}", forAnnotationKey: PDFAnnotationKey(rawValue: "/HwattakPDFInkGeometry"))
        XCTAssertNil(PressureInkAnnotation.geometry(of: stamp))
        XCTAssertFalse(PDFInkPartialEraser.supports(stamp))
        XCTAssertNil(PressureInkAnnotation(points: [CGPoint(x: CGFloat.infinity, y: 0)], pressures: [1], width: 3, color: .black))
    }

    private func replacement(_ source: PDFAnnotation, at point: CGPoint, radius: CGFloat) throws -> PDFAnnotation {
        guard case let .replaced(replacements) = PDFInkPartialEraser.replacements(for: source, from: point, to: point, radius: radius) else {
            XCTFail("Expected a partial ink replacement")
            throw NSError(domain: "PDFInkPartialEraserTests", code: 1)
        }
        XCTAssertEqual(replacements.count, 1)
        return try XCTUnwrap(replacements.first)
    }

    private func makeNativeInk(height: CGFloat = 40, horizontalPadding: CGFloat = 0) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: 20 - horizontalPadding, y: 80, width: 160 + 2 * horizontalPadding, height: height), forType: .ink, withProperties: nil)
        PDFAnnotationPrivacy.clearImplicitAuthor(on: annotation)
        annotation.color = .blue
        let border = PDFBorder(); border.lineWidth = 4; annotation.border = border
        let path = NSBezierPath()
        path.move(to: CGPoint(x: horizontalPadding, y: 20)); path.line(to: CGPoint(x: 160 + horizontalPadding, y: 20))
        path.lineCapStyle = .round
        annotation.add(path)
        return annotation
    }

    private func document(containing annotation: PDFAnnotation, roundTrip: Bool) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        try XCTUnwrap(document.page(at: 0)).addAnnotation(annotation)
        return roundTrip ? try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation()))) : document
    }

    private func color(_ page: PDFPage, at point: CGPoint) throws -> NSColor {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        page.draw(with: .mediaBox, to: graphics.cgContext)
        graphics.flushGraphics()
        return try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: 199 - Int(point.y))?.usingColorSpace(.deviceRGB))
    }
    private func assertWhite(_ page: PDFPage, at point: CGPoint, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertGreaterThan(try color(page, at: point).redComponent, 0.9, file: file, line: line)
    }
    private func assertBlue(_ page: PDFPage, at point: CGPoint, file: StaticString = #filePath, line: UInt = #line) throws {
        let sample = try color(page, at: point)
        XCTAssertLessThan(sample.redComponent, 0.25, file: file, line: line)
        XCTAssertGreaterThan(sample.blueComponent, 0.75, file: file, line: line)
    }
}
