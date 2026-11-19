// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInkPointerInteractionTests: XCTestCase {
    func testMouseReleaseKeepsTheVisibleStrokeAtThePointerAcrossCropRotationAndZoom() throws {
        for rotation in [0, 90, 180, 270] {
            for style in [PDFInkStyle.ink, .fountain] {
                try autoreleasepool {
                    let fixture = try Fixture(rotation: rotation, style: style)
                    defer { fixture.close() }
                    let points = [CGPoint(x: 135, y: 365), CGPoint(x: 215, y: 365),
                                  CGPoint(x: 215, y: 460)]
                    fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: points[0]))
                    for point in points.dropFirst() {
                        fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, at: point))
                    }
                    XCTAssertTrue(fixture.view.isDrawingInkStroke)
                    let before = try fixture.render("before")
                    let preview = try XCTUnwrap(redBounds(before), "Live ink must be visible")
                    XCTAssertFalse(fixture.state.isDirty)
                    fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: points.last!))
                    // Match PDFKitViewer's revision-driven SwiftUI update.
                    fixture.view.configure(with: fixture.state)
                    fixture.view.layoutDocumentView()
                    XCTAssertFalse(fixture.view.isDrawingInkStroke)
                    XCTAssertEqual(fixture.page.annotations.count, 1)
                    XCTAssertTrue(fixture.state.isDirty)
                    // PDFKit's native annotation layers are not included by
                    // cacheDisplay in an offscreen window. Render the committed
                    // page through its public thumbnail API at the same viewport
                    // position instead of mistaking that omission for lost ink.
                    let after = try fixture.renderCommittedPage(like: before)
                    let committed = try XCTUnwrap(redBounds(after), "Committed ink must remain visible")
                    let label = "rotation \(rotation), \(style)"
                    XCTAssertEqual(committed.midX, preview.midX, accuracy: 2, label)
                    XCTAssertEqual(committed.midY, preview.midY, accuracy: 2, label)
                    XCTAssertEqual(committed.width, preview.width, accuracy: 3, label)
                    XCTAssertEqual(committed.height, preview.height, accuracy: 3, label)
                    fixture.state.undo()
                    XCTAssertTrue(fixture.page.annotations.isEmpty)
                    fixture.state.redo()
                    XCTAssertEqual(fixture.page.annotations.count, 1)
                }
            }
        }
    }

    private func redBounds(_ bitmap: NSBitmapImageRep) -> CGRect? {
        var result = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            autoreleasepool {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.7, color.redComponent > 0.55,
                          color.redComponent - color.greenComponent > 0.35,
                          color.redComponent - color.blueComponent > 0.35 else { continue }
                    result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return result.isNull ? nil : result
    }

    @MainActor
    private struct Fixture {
        let state: PDFWorkspaceState
        let page: PDFPage
        let view: InteractivePDFView
        let window: NSWindow
        let directory: URL
        let rotation: Int
        let style: PDFInkStyle

        init(rotation: Int, style: PDFInkStyle) throws {
            _ = NSApplication.shared
            self.rotation = rotation
            self.style = style
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = NSMutableData()
            let consumer = try XCTUnwrap(CGDataConsumer(data: data))
            var media = CGRect(x: 20, y: 30, width: 500, height: 650)
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 195, y: 355, width: 40, height: 130))
            context.endPDFPage()
            context.closePDF()
            let source = try XCTUnwrap(PDFDocument(data: data as Data))
            let sourcePage = try XCTUnwrap(source.page(at: 0))
            sourcePage.setBounds(CGRect(x: 70, y: 100, width: 400, height: 500), for: .cropBox)
            sourcePage.rotation = rotation
            let url = directory.appendingPathComponent("pointer.pdf")
            try XCTUnwrap(source.dataRepresentation()).write(to: url)
            state = PDFWorkspaceState()
            XCTAssertTrue(state.open(url: url))
            state.setMode(.editing)
            state.activeTool = .pen
            state.inkSettings.selectStyle(style)
            state.inkSettings.width = 9
            state.inkSettings.color = .red
            state.inkSettings.opacity = 1
            state.inkSettings.pressureEnabled = false
            page = try XCTUnwrap(state.document?.page(at: 0))
            view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 680, height: 660))
            window = NSWindow(contentRect: CGRect(x: 137, y: 91, width: 680, height: 660),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.document = state.document
            view.displayMode = .singlePage
            view.displayBox = .cropBox
            view.autoScales = false
            view.scaleFactor = rotation == 0 ? 1.15 : 0.9
            view.configure(with: state)
            view.go(to: page)
            view.layoutDocumentView()
            view.layoutSubtreeIfNeeded()
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: view.convert(view.convert(point, from: page), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }

        func render(_ suffix: String) throws -> NSBitmapImageRep {
            let deadline = Date().addingTimeInterval(0.08)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                view.layoutSubtreeIfNeeded()
            }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Preserve the display cache's color profile in the same pixels
            // used for both assertions and optional visual evidence.
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            if let path = ProcessInfo.processInfo.environment["EMBER_INK_QA_DIRECTORY"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("pointer-\(rotation)-\(style.rawValue)-\(suffix).png"))
                if suffix == "after" {
                    try XCTUnwrap(state.document?.dataRepresentation()).write(
                        to: folder.appendingPathComponent("pointer-\(rotation)-\(style.rawValue).pdf"))
                }
            }
            return try XCTUnwrap(NSBitmapImageRep(data: png))
        }

        func renderCommittedPage(like before: NSBitmapImageRep) throws -> NSBitmapImageRep {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: before.pixelsWide, pixelsHigh: before.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = graphics
            graphics.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                                      y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            NSColor.white.setFill()
            view.bounds.fill()
            var frame = view.convert(page.bounds(for: .cropBox), from: page)
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            let thumbnail = page.thumbnail(of: CGSize(width: frame.width * 2, height: frame.height * 2), for: .cropBox)
            thumbnail.draw(in: frame)
            graphics.flushGraphics()
            if let path = ProcessInfo.processInfo.environment["EMBER_INK_QA_DIRECTORY"] {
                let folder = URL(fileURLWithPath: path)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("pointer-\(rotation)-\(style.rawValue)-committed.png"))
            }
            return bitmap
        }

        func close() {
            view.cancelInkStroke()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            view.document = nil
            window.contentView = nil
            window.close()
            state.closeDiscardingChanges()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
