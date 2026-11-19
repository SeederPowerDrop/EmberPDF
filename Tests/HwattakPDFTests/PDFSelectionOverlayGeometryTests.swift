// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFSelectionOverlayGeometryTests: XCTestCase {
    func testManyLinesUseOneAffineMappingAndShortSelectionsUseDirectConversion() {
        let transform = CGAffineTransform(a: 0, b: -2.25, c: -2.25, d: 0,
                                          tx: 143.25, ty: 987_654.75)
        let rectangles = (0..<80).map {
            CGRect(x: 31.5, y: CGFloat($0) * 17.25, width: 203.5, height: 12.75)
        }
        var pointConversions = 0
        var rectangleConversions = 0
        for count in [0, 1, 2, 80] {
            pointConversions = 0
            rectangleConversions = 0
            let source = Array(rectangles.prefix(count))
            let mapped = PDFSelectionOverlayGeometry.map(source, convertRectangle: {
                rectangleConversions += 1
                return $0.applying(transform)
            }, convertPoint: {
                pointConversions += 1
                return $0.applying(transform)
            })
            XCTAssertEqual(mapped, source.map { $0.applying(transform) })
            XCTAssertEqual(pointConversions, count > 2 ? 3 : 0)
            XCTAssertEqual(rectangleConversions, count > 2 ? 0 : count)
        }
    }

    func testUnusableBasisFallsBackToNativeRectangleConversion() {
        let rectangles = (0..<4).map { CGRect(x: $0 * 30, y: 40, width: 20, height: 12) }
        var conversions = 0
        let mapped = PDFSelectionOverlayGeometry.map(rectangles, convertRectangle: {
            conversions += 1
            return $0.offsetBy(dx: 11, dy: -23)
        }, convertPoint: { _ in CGPoint(x: CGFloat.nan, y: 0) })
        XCTAssertEqual(conversions, rectangles.count)
        XCTAssertEqual(mapped, rectangles.map { $0.offsetBy(dx: 11, dy: -23) })
    }

    @MainActor
    func testNativeHighlightBoundsStayAlignedAfterRotationCropZoomAndScroll() throws {
        _ = NSApplication.shared
        let document = try makeDocument()
        let page = try XCTUnwrap(document.page(at: 1))
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 560, height: 460))
        let view = PDFView(frame: CGRect(x: 23, y: 31, width: 480, height: 360))
        let overlay = NSView(frame: CGRect(x: 7, y: 13, width: 520, height: 420))
        container.addSubview(view)
        container.addSubview(overlay)
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        view.displayMode = .singlePageContinuous
        view.displayBox = .cropBox
        view.autoScales = false
        view.document = document
        defer {
            view.clearSelection()
            view.document = nil
            window.contentView = nil
            window.close()
        }
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
        let rectangles = selection.selectionsByLine().map { $0.bounds(for: page) }
        XCTAssertGreaterThan(rectangles.count, 2)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            for zoom in [0.8, 2.15] {
                view.scaleFactor = zoom
                view.layoutDocumentView()
                view.go(to: page)
                view.layoutSubtreeIfNeeded()
                view.setCurrentSelection(selection, animate: false)
                for scroll in [CGFloat(0), 79] {
                    if let clip = view.documentView?.enclosingScrollView?.contentView {
                        clip.scroll(to: CGPoint(x: clip.bounds.minX + scroll, y: clip.bounds.minY + scroll))
                    }
                    let mapped = PDFSelectionOverlayGeometry.map(rectangles,
                        convertRectangle: { overlay.convert(view.convert($0, from: page), from: view) },
                        convertPoint: { overlay.convert(view.convert($0, from: page), from: view) })
                    let native = rectangles.map { overlay.convert(view.convert($0, from: page), from: view) }
                    for (actual, expected) in zip(mapped, native) {
                        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000_001)
                        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.000_001)
                        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000_001)
                        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000_001)
                    }
                    XCTAssertEqual(view.currentSelection?.string, selection.string)
                }
            }
        }
    }

    @MainActor
    func testChangingHighlightGeometryRetainsResolvedColorsAndRegionOutlineUpdates() throws {
        let overlay = PDFRegionSelectionOverlay(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let layer = try XCTUnwrap(overlay.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let fill = try XCTUnwrap(layer.fillColor)
        for width in 10...50 {
            overlay.setRectangles([CGRect(x: 20, y: 30, width: width, height: 12)], isRegion: false)
            XCTAssertTrue(layer.fillColor === fill)
            XCTAssertNil(layer.strokeColor)
        }
        overlay.setRectangles([CGRect(x: 20, y: 30, width: 50, height: 12)], isRegion: true)
        XCTAssertNotNil(layer.strokeColor)
        overlay.setRectangles([], isRegion: false)
        XCTAssertNil(layer.strokeColor)
        // Color preference changes must still refresh a stationary selection.
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        XCTAssertNotNil(layer.fillColor)
    }

    @MainActor
    private func makeDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 15, y: 25, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            for row in 0..<4 {
                context.textPosition = CGPoint(x: 90, y: 700 - row * 24)
                let text = NSAttributedString(string: "Native highlight row \(row)",
                    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 15, nil)])
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        for index in 0..<document.pageCount {
            document.page(at: index)?.setBounds(CGRect(x: 37, y: 49, width: 500, height: 660), for: .cropBox)
        }
        return document
    }
}
