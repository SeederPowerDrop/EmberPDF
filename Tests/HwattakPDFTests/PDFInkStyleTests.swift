// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInkStyleTests: XCTestCase {
    func testFountainNibDirectionAndPressureChangeRealGeometry() throws {
        let thin = try XCTUnwrap(PDFInkStrokeRenderer.stroke(
            points: [.zero, CGPoint(x: 100, y: 100)], pressures: [1, 1], width: 10, style: .fountain))
        let broad = try XCTUnwrap(PDFInkStrokeRenderer.stroke(
            points: [.zero, CGPoint(x: 100, y: -100)], pressures: [1, 1], width: 10, style: .fountain))
        let light = try XCTUnwrap(PDFInkStrokeRenderer.stroke(
            points: [.zero, CGPoint(x: 100, y: -100)], pressures: [0.2, 0.2], width: 10, style: .fountain))
        XCTAssertEqual(thin.widths[0], 2.2, accuracy: 0.001)
        XCTAssertEqual(broad.widths[0], 10, accuracy: 0.001)
        XCTAssertLessThan(light.widths[0], broad.widths[0])
    }

    func testHighlighterIsBroadAndConstantWidthWithAdjustableOpacity() throws {
        var settings = InkSettings()
        settings.color = .blue
        settings.selectStyle(.highlighter)
        XCTAssertEqual(settings.color, NSColor.blue)
        XCTAssertEqual(settings.width, 14)
        XCTAssertEqual(settings.pdfInkColor.alphaComponent, 0.3, accuracy: 0.001)
        let geometry = try XCTUnwrap(PDFInkStrokeRenderer.stroke(points: points,
            pressures: [0, 0.4, 0.8, 1], width: settings.width, style: settings.style))
        XCTAssertEqual(geometry.widths, [14, 14, 14])
        settings.opacity = 0.55
        settings.width = 22
        settings.selectStyle(.highlighter)
        XCTAssertEqual(settings.width, 22, "Tapping the selected style does not discard custom settings")
        XCTAssertEqual(settings.pdfInkColor.alphaComponent, 0.55, accuracy: 0.001)
    }

    func testPencilHasDeterministicVisibleGrainInsteadOfSolidInk() throws {
        let pencil = try makeStroke(style: .pencil, opacity: 1)
        let ink = try makeStroke(style: .ink, opacity: 1)
        let pencilPixels = try bitmap(page: document(pencil).page(at: 0), scale: 4)
        let second = try bitmap(page: document(try XCTUnwrap(pencil.copy() as? PDFAnnotation)).page(at: 0), scale: 4)
        let inkPixels = try bitmap(page: document(ink).page(at: 0), scale: 4)
        var pencilReds: [CGFloat] = []
        var inkReds: [CGFloat] = []
        for x in 200..<400 {
            let a = try XCTUnwrap(pencilPixels.colorAt(x: x, y: 400)?.usingColorSpace(.deviceRGB))
            let b = try XCTUnwrap(second.colorAt(x: x, y: 400)?.usingColorSpace(.deviceRGB))
            let c = try XCTUnwrap(inkPixels.colorAt(x: x, y: 400)?.usingColorSpace(.deviceRGB))
            pencilReds.append(a.redComponent); inkReds.append(c.redComponent)
            XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.005)
        }
        XCTAssertGreaterThan((pencilReds.max() ?? 0) - (pencilReds.min() ?? 0), 0.08)
        XCTAssertLessThan(inkReds.max() ?? 1, 0.02)
        XCTAssertGreaterThan(pencilReds.reduce(0, +) / CGFloat(pencilReds.count), 0.2)
    }

    func testEachStyleSurvivesCopySavePartialEraseAndSecondSave() throws {
        for style in PDFInkStyle.allCases {
            let source = try makeStroke(style: style, opacity: 0.45)
            let copied = try XCTUnwrap(source.copy() as? PDFAnnotation)
            let savedDocument = try roundTrip(document(copied))
            let saved = try XCTUnwrap(savedDocument.page(at: 0)?.annotations.first)
            let originalGeometry = try XCTUnwrap(PressureInkAnnotation.geometry(of: saved))
            XCTAssertEqual(originalGeometry.style, style)
            XCTAssertEqual(originalGeometry.color.alphaComponent, 0.45, accuracy: 0.001)
            guard case let .replaced(replacements) = PDFInkPartialEraser.replacements(for: saved,
                from: CGPoint(x: 100, y: 70), to: CGPoint(x: 100, y: 130), radius: 5) else {
                return XCTFail("Expected an erasable saved \(style)")
            }
            let fragment = try XCTUnwrap(replacements.first)
            let finalDocument = try roundTrip(document(fragment))
            let final = try XCTUnwrap(finalDocument.page(at: 0)?.annotations.first)
            let geometry = try XCTUnwrap(PressureInkAnnotation.geometry(of: final))
            XCTAssertEqual(geometry.style, style)
            XCTAssertEqual(geometry.color.alphaComponent, 0.45, accuracy: 0.001)
            XCTAssertEqual(geometry.strokes.count, 2)
            let rendered = try bitmap(page: finalDocument.page(at: 0), scale: 1)
            let cut = try XCTUnwrap(rendered.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB))
            let intact = try XCTUnwrap(rendered.colorAt(x: 50, y: 100)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(cut.redComponent, 0.95)
            XCTAssertLessThan(intact.redComponent, 0.9, "The saved \(style) appearance must remain visible")
            XCTAssertTrue(PDFInkPartialEraser.supports(final))
        }
    }

    func testPencilGrainIsUnchangedOutsideAnErasedEndpointAfterSaving() throws {
        let original = try roundTrip(document(makeStroke(style: .pencil, opacity: 0.8)))
        let saved = try XCTUnwrap(original.page(at: 0)?.annotations.first)
        guard case let .replaced(replacements) = PDFInkPartialEraser.replacements(for: saved,
            from: CGPoint(x: 0, y: 100), to: CGPoint(x: 60, y: 100), radius: 6) else {
            return XCTFail("Expected endpoint erasure")
        }
        let final = try roundTrip(document(XCTUnwrap(replacements.first)))
        let before = try bitmap(page: original.page(at: 0), scale: 4)
        let after = try bitmap(page: final.page(at: 0), scale: 4)
        for x in 480..<640 {
            let first = try XCTUnwrap(before.colorAt(x: x, y: 400)?.usingColorSpace(.deviceRGB))
            let second = try XCTUnwrap(after.colorAt(x: x, y: 400)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(first.redComponent, second.redComponent, accuracy: 0.01,
                "Erasing one end must not redraw the pencil grain elsewhere")
        }
    }

    func testLegacyVersionOneMetadataRemainsEditableAndUnknownStyleIsRefused() throws {
        let ink = try makeStroke(style: .ink, opacity: 0.6)
        let key = PDFAnnotationKey(rawValue: "/HwattakPDFInkGeometry")
        let encoded = try XCTUnwrap(ink.value(forAnnotationKey: key) as? String)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        payload["version"] = 1
        payload.removeValue(forKey: "style")
        let generic = PDFAnnotation(bounds: ink.bounds, forType: .stamp, withProperties: nil)
        generic.setValue(PressureInkAnnotation.stampName, forAnnotationKey: .iconName)
        generic.setValue(String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!, forAnnotationKey: key)
        XCTAssertEqual(PressureInkAnnotation.geometry(of: generic)?.style, .ink)
        payload["version"] = 2
        payload["style"] = "unsupported-external-style"
        generic.setValue(String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!, forAnnotationKey: key)
        XCTAssertNil(PressureInkAnnotation.geometry(of: generic))
    }

    func testAllStyleInputsRejectUnboundedOrNonfiniteGeometry() {
        for style in PDFInkStyle.allCases {
            XCTAssertNil(PDFInkStrokeRenderer.stroke(points: [.zero], pressures: [.nan], width: 2, style: style))
            XCTAssertNil(PDFInkStrokeRenderer.stroke(points: [CGPoint(x: CGFloat.infinity, y: 0)], pressures: [1], width: 2, style: style))
            XCTAssertNil(PDFInkStrokeRenderer.stroke(points: Array(repeating: .zero, count: 8_193),
                pressures: Array(repeating: 1, count: 8_193), width: 2, style: style))
        }
    }

    private var points: [CGPoint] {
        [CGPoint(x: 20, y: 100), CGPoint(x: 60, y: 100), CGPoint(x: 120, y: 100), CGPoint(x: 180, y: 100)]
    }

    private func makeStroke(style: PDFInkStyle, opacity: CGFloat) throws -> PressureInkAnnotation {
        try XCTUnwrap(PressureInkAnnotation(points: points, pressures: [1, 1, 1, 1], width: 12,
            color: NSColor.blue.withAlphaComponent(opacity), style: style))
    }

    private func document(_ annotation: PDFAnnotation) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        try XCTUnwrap(document.page(at: 0)).addAnnotation(annotation)
        return document
    }

    private func roundTrip(_ document: PDFDocument) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
    }

    private func bitmap(page: PDFPage?, scale: Int) throws -> NSBitmapImageRep {
        let page = try XCTUnwrap(page)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200 * scale, pixelsHigh: 200 * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        page.draw(with: .mediaBox, to: graphics.cgContext)
        graphics.flushGraphics()
        return bitmap
    }
}
