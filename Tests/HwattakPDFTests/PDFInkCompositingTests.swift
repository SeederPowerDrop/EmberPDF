// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInkCompositingTests: XCTestCase {
    func testPenPaintsOverBlackTextAndColoredPaperBeforeAndAfterSaving() throws {
        for opacity in [CGFloat(0.3), 1] {
            let fixture = try makeFixture()
            let original = try bitmap(fixture.page)
            let textPoint = try blackTextPoint(in: original)
            let color = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
            let annotation = try stroke(style: .ink, color: color, opacity: opacity)
            fixture.page.addAnnotation(annotation)

            let reference = try makeFixture()
            reference.page.addAnnotation(NormalAlphaReferenceAnnotation(
                bounds: CGRect(x: 20, y: 88, width: 160, height: 24),
                color: color.withAlphaComponent(opacity)
            ))
            try writeQADocument(fixture.document, named: "composite-pen-\(opacity).pdf")
            try writeQADocument(reference.document, named: "composite-reference-\(opacity).pdf")
            let referenceDocuments = try renderedDocuments(of: reference.document)
            for (index, entry) in try renderedDocuments(of: fixture.document).enumerated() {
                let (phase, document) = entry
                let rendered = try bitmap(XCTUnwrap(document.page(at: 0)))
                let referenceBitmap = try bitmap(XCTUnwrap(referenceDocuments[index].1.page(at: 0)))
                for point in [textPoint, whitePoint, coloredPoint] {
                    let actual = try components(rendered, at: point)
                    // PDFKit's saved appearance may map DeviceRGB through an
                    // embedded color profile. Use a separately drawn native
                    // appearance as the oracle, without the app's renderer,
                    // pressure geometry, or grouped-alpha implementation.
                    let expected = try components(referenceBitmap, at: point)
                    assertColor(actual, equals: expected,
                                "Normal pen opacity \(opacity), \(phase), \(point)")
                    if phase == "live" {
                        let background = try components(original, at: point)
                        let normalAlpha = [background[0] * (1 - opacity),
                                           background[1] * (1 - opacity),
                                           background[2] * (1 - opacity) + opacity]
                        assertColor(expected, equals: normalAlpha,
                                    "Independent normal-alpha reference, opacity \(opacity), \(point)")
                    }
                }
                let inkOnText = try components(rendered, at: textPoint)
                XCTAssertEqual(inkOnText[2], opacity, accuracy: 0.025,
                               "The pen must remain visible over black text with the requested alpha, \(phase)")
            }
        }
    }

    func testHighlighterPreservesBlackTextAndTintsColoredPaperBeforeAndAfterSaving() throws {
        for (name, rgb) in [("yellow", [CGFloat(1), 1, 0]), ("blue", [CGFloat(0), 0, 1])] {
            for opacity in [CGFloat(0.3), 1] {
                let fixture = try makeFixture()
                let original = try bitmap(fixture.page)
                let textPoint = try blackTextPoint(in: original)
                let annotation = try stroke(style: .highlighter,
                    color: NSColor(deviceRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1),
                    opacity: opacity)
                fixture.page.addAnnotation(annotation)

                for (phase, document) in try renderedDocuments(of: fixture.document) {
                    let rendered = try bitmap(XCTUnwrap(document.page(at: 0)))
                    for point in [textPoint, whitePoint, coloredPoint] {
                        let background = try components(original, at: point)
                        let actual = try components(rendered, at: point)
                        // Multiplication preserves black letters even when
                        // the opacity slider reaches 100%, for every hue.
                        let expected = (0..<3).map {
                            background[$0] * (1 - opacity + rgb[$0] * opacity)
                        }
                        assertColor(actual, equals: expected,
                                    "\(name) highlighter opacity \(opacity), \(phase), \(point)")
                    }
                }
            }
        }
    }

    func testColoredPencilKeepsItsTintAndGrainAfterSaving() throws {
        for (name, rgb, dominant) in [("red", [CGFloat(0.9), 0.1, 0.2], 0),
                                      ("blue", [CGFloat(0), 0, 1], 2)] {
            let fixture = try makeFixture()
            fixture.page.addAnnotation(try stroke(style: .pencil,
                color: NSColor(deviceRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1), opacity: 0.7))
            var liveColors: [[CGFloat]] = []
            for (phase, document) in try renderedDocuments(of: fixture.document) {
                let rendered = try bitmap(XCTUnwrap(document.page(at: 0)))
                // The white gap between the text and colored panel isolates
                // tint and grain without sampling letter antialiasing.
                let colors = try (105..<125).map { x in
                    try components(rendered, at: CGPoint(x: x, y: 100))
                }
                for color in colors {
                    for channel in 0..<3 where channel != dominant {
                        XCTAssertGreaterThan(color[dominant], color[channel] + 0.06,
                                             "The \(name) pencil must retain its hue, \(phase)")
                    }
                }
                let green = colors.map { $0[1] }
                XCTAssertGreaterThan(try XCTUnwrap(green.max()) - XCTUnwrap(green.min()), 0.04,
                                     "The \(name) pencil must retain visible grain, \(phase)")
                if phase == "live" {
                    liveColors = colors
                } else {
                    for (index, color) in colors.enumerated() {
                        assertColor(color, equals: liveColors[index],
                                    "Saved \(name) pencil grain at sample \(index)")
                    }
                }
            }
        }
    }

    func testTranslucentPensAndHighlighterApplyOpacityOnceAtIntersectionsBeforeAndAfterSaving() throws {
        for style in [PDFInkStyle.ink, .fountain, .highlighter] {
            let fixture = try makeFixture()
            let stroke = try XCTUnwrap(PDFInkStrokeRenderer.stroke(
                points: [CGPoint(x: 40, y: 40), CGPoint(x: 160, y: 160),
                         CGPoint(x: 40, y: 160), CGPoint(x: 160, y: 40)],
                pressures: [1, 1, 1, 1], width: 20, style: style
            ))
            var strokes = [stroke]
            if style == .highlighter {
                // A partially erased annotation can contain multiple paths;
                // their intersections must use the same single opacity too.
                strokes.append(PDFInkStrokeGeometry(points: [CGPoint(x: 40, y: 100),
                    CGPoint(x: 120, y: 100)], widths: [20]))
            }
            fixture.page.addAnnotation(try XCTUnwrap(PressureInkAnnotation(strokes: strokes,
                color: NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 0.3), style: style
            )))
            for (phase, document) in try renderedDocuments(of: fixture.document) {
                let rendered = try bitmap(XCTUnwrap(document.page(at: 0)))
                for point in [CGPoint(x: 100, y: 100), CGPoint(x: 60, y: 140)] {
                    assertColor(try components(rendered, at: point), equals: [0.7, 0.7, 1],
                                "Self-intersection keeps one alpha, \(style), \(phase), \(point)")
                }
            }
        }
    }

    func testPencilOpacityScalesTheCompleteGrainBeforeAndAfterSaving() throws {
        let opaque = try makeFixture()
        let translucent = try makeFixture()
        let color = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        opaque.page.addAnnotation(try stroke(style: .pencil, color: color, opacity: 1))
        translucent.page.addAnnotation(try stroke(style: .pencil, color: color, opacity: 0.35))
        let opaqueDocuments = try renderedDocuments(of: opaque.document)
        let translucentDocuments = try renderedDocuments(of: translucent.document)
        for index in opaqueDocuments.indices {
            let (phase, fullDocument) = opaqueDocuments[index]
            let full = try bitmap(XCTUnwrap(fullDocument.page(at: 0)))
            let faded = try bitmap(XCTUnwrap(translucentDocuments[index].1.page(at: 0)))
            for x in 105..<125 {
                let point = CGPoint(x: x, y: 100)
                let fullColor = try components(full, at: point)
                let expected = fullColor.map { 1 - 0.35 * (1 - $0) }
                assertColor(try components(faded, at: point), equals: expected,
                            "Pencil opacity applies to the complete grain, \(phase), \(point)")
            }
        }
    }

    private let whitePoint = CGPoint(x: 112, y: 100)
    private let coloredPoint = CGPoint(x: 155, y: 100)

    private func stroke(style: PDFInkStyle, color: NSColor,
                        opacity: CGFloat) throws -> PressureInkAnnotation {
        try XCTUnwrap(PressureInkAnnotation(
            points: [CGPoint(x: 20, y: 100), CGPoint(x: 180, y: 100)],
            pressures: [1, 1], width: 24,
            color: color.withAlphaComponent(opacity), style: style
        ))
    }

    private func makeFixture() throws -> (document: PDFDocument, page: PDFPage) {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        context.setFillColor(NSColor(deviceRed: 0.25, green: 0.5, blue: 0.75, alpha: 1).cgColor)
        context.fill(CGRect(x: 130, y: 80, width: 50, height: 40))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "HHH", attributes: [
            .font: NSFont(name: "Helvetica-Bold", size: 32) ?? NSFont.boldSystemFont(ofSize: 32),
            .foregroundColor: NSColor.black
        ]))
        context.textPosition = CGPoint(x: 28, y: 86)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        return (document, try XCTUnwrap(document.page(at: 0)))
    }

    private func renderedDocuments(of document: PDFDocument) throws -> [(String, PDFDocument)] {
        let reopened = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
        // Keep both documents alive for the render loop: PDFKit
        // owns a saved annotation's appearance stream through its document.
        return [("live", document), ("save/reopen", reopened)]
    }

    private func writeQADocument(_ document: PDFDocument, named name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_INK_QA_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(document.dataRepresentation()).write(to: directory.appendingPathComponent(name))
    }

    private func blackTextPoint(in bitmap: NSBitmapImageRep) throws -> CGPoint {
        for x in 30..<100 {
            let point = CGPoint(x: x, y: 100)
            let color = try components(bitmap, at: point)
            if color.allSatisfy({ $0 < 0.02 }) { return point }
        }
        XCTFail("The fixture must contain solid black text beneath the stroke.")
        throw NSError(domain: "PDFInkCompositingTests", code: 1)
    }

    private func components(_ bitmap: NSBitmapImageRep, at point: CGPoint) throws -> [CGFloat] {
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }

    private func assertColor(_ actual: [CGFloat], equals expected: [CGFloat], _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.025,
                           "\(message), channel \(channel)", file: file, line: line)
        }
    }

    private func bitmap(_ page: PDFPage) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        page.draw(with: .mediaBox, to: graphics.cgContext)
        graphics.flushGraphics()
        return bitmap
    }
}

/// An independent Core Graphics fill through PDFKit's annotation persistence.
/// No application ink code participates in this expected-result path.
private final class NormalAlphaReferenceAnnotation: PDFAnnotation {
    private let fillColor: CGColor

    init(bounds: CGRect, color: NSColor) {
        fillColor = color.cgColor
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.normal)
        context.setAlpha(1)
        context.setFillColor(fillColor)
        context.fill(bounds)
    }
}
