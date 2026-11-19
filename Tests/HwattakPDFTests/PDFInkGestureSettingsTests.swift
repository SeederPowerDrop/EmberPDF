// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInkGestureSettingsTests: XCTestCase {
    func testChangingPresetDuringDragAffectsOnlyTheNextStroke() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let start = CGPoint(x: 80, y: 120), end = CGPoint(x: 190, y: 170)
        let original = fixture.state.inkSettings
        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: start))
        fixture.state.inkSettings.selectStyle(.highlighter)
        fixture.state.inkSettings.color = .blue
        fixture.state.inkSettings.drawingOptions.shape = .ellipse
        fixture.state.inkSettings.drawingOptions.highlighterTip = .round
        fixture.view.configure(with: fixture.state)
        fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, at: end))
        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: end))
        let first = try XCTUnwrap(PressureInkAnnotation.geometry(of: XCTUnwrap(fixture.page.annotations.first)))
        XCTAssertEqual(first.style, original.style)
        XCTAssertEqual(first.options, original.drawingOptions)
        XCTAssertEqual(first.color.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(first.color.blueComponent, 0, accuracy: 0.01)
        XCTAssertEqual(first.strokes[0], PDFInkStrokeRenderer.stroke(points: [start, end], pressures: [1, 1],
            width: original.width, style: original.style, options: original.drawingOptions))

        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: start))
        fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, at: end))
        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: end))
        let second = try XCTUnwrap(PressureInkAnnotation.geometry(of: XCTUnwrap(fixture.page.annotations.last)))
        XCTAssertEqual(second.style, .highlighter)
        XCTAssertEqual(second.options.shape, .ellipse)
        XCTAssertEqual(second.options.highlighterTip, .round)
        XCTAssertEqual(second.color.blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(fixture.page.annotations.count, 2)
        fixture.state.undo()
        XCTAssertEqual(fixture.page.annotations.count, 1)
        fixture.state.redo()
        XCTAssertEqual(fixture.page.annotations.count, 2)
    }

    func testMouseReleaseRetainsTheFinalSubpixelEndpointAtEveryZoom() throws {
        for scale in [CGFloat(0.4), 1, 3] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.view.scaleFactor = scale
            fixture.view.layoutDocumentView()
            let start = CGPoint(x: 80, y: 120), move = CGPoint(x: 160, y: 140)
            let end = CGPoint(x: 160.05, y: 140.03)
            fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: start))
            fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, at: move))
            fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: end))
            let geometry = try XCTUnwrap(PressureInkAnnotation.geometry(of: XCTUnwrap(fixture.page.annotations.first)))
            let last = try XCTUnwrap(geometry.strokes.last?.points.last)
            XCTAssertEqual(last.x, end.x, accuracy: 0.0001)
            XCTAssertEqual(last.y, end.y, accuracy: 0.0001)
        }
    }

    func testShapeAndDashSettingsPersistThroughActualMouseEventsAndUndo() throws {
        for shape in [PDFInkShape.line, .rectangle, .ellipse] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.state.inkSettings.drawingOptions.shape = shape
            fixture.state.inkSettings.drawingOptions.pattern = .dashed
            fixture.view.configure(with: fixture.state)
            let start = CGPoint(x: 50, y: 80), end = CGPoint(x: 170, y: 180)
            fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: start))
            fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, at: CGPoint(x: 100, y: 200)))
            fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, at: end))
            fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: end))
            let geometry = try XCTUnwrap(PressureInkAnnotation.geometry(of: XCTUnwrap(fixture.page.annotations.first)))
            XCTAssertEqual(geometry.options, fixture.state.inkSettings.drawingOptions)
            XCTAssertEqual(geometry.strokes[0], PDFInkStrokeRenderer.stroke(points: [start, end], pressures: [1, 1],
                width: fixture.state.inkSettings.width, style: fixture.state.inkSettings.style,
                options: fixture.state.inkSettings.drawingOptions))
            fixture.state.undo()
            XCTAssertTrue(fixture.page.annotations.isEmpty)
            fixture.state.redo()
            XCTAssertEqual(fixture.page.annotations.count, 1)
        }
    }

    func testEscapeCancelsAStrokeWithoutEditingThePDF() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, at: CGPoint(x: 80, y: 120)))
        fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, at: CGPoint(x: 190, y: 170)))
        XCTAssertTrue(fixture.view.isDrawingInkStroke)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        fixture.view.keyDown(with: escape)
        XCTAssertFalse(fixture.view.isDrawingInkStroke)
        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, at: CGPoint(x: 190, y: 170)))
        XCTAssertTrue(fixture.page.annotations.isEmpty)
        XCTAssertFalse(fixture.state.isDirty)
    }

    func testShapeWidthIgnoresTabletPressureIncludingZeroOnReleaseAndLateTabletDetection() throws {
        for shape in [PDFInkShape.line, .rectangle, .ellipse] {
            for lateDetection in [false, true] {
                let fixture = try Fixture()
                defer { fixture.close() }
                fixture.state.inkSettings.pressureEnabled = true
                fixture.state.inkSettings.drawingOptions.shape = shape
                fixture.view.configure(with: fixture.state)
                let start = CGPoint(x: 50, y: 80), middle = CGPoint(x: 100, y: 130)
                let end = CGPoint(x: 170, y: 180)
                let down = lateDetection ? try fixture.event(.leftMouseDown, at: start)
                    : try fixture.tabletMouseEvent(.leftMouseDown, at: start, pressure: 0.3)
                fixture.view.mouseDown(with: down)
                fixture.view.mouseDragged(with: try fixture.tabletMouseEvent(.leftMouseDragged, at: middle, pressure: 0.7))
                fixture.view.mouseUp(with: try fixture.tabletMouseEvent(.leftMouseUp, at: end, pressure: 0))
                let geometry = try XCTUnwrap(PressureInkAnnotation.geometry(of: XCTUnwrap(fixture.page.annotations.first)))
                let expected = try XCTUnwrap(PDFInkStrokeRenderer.stroke(points: [start, end], pressures: [1, 1],
                    width: fixture.state.inkSettings.width, style: fixture.state.inkSettings.style,
                    options: fixture.state.inkSettings.drawingOptions))
                XCTAssertEqual(geometry.strokes[0], expected, "\(shape), late tablet: \(lateDetection)")
            }
        }
    }

    @MainActor
    private struct Fixture {
        let state: PDFWorkspaceState
        let page: PDFPage
        let view: InteractivePDFView
        let window: NSWindow
        let directory: URL

        init() throws {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = NSMutableData()
            let consumer = try XCTUnwrap(CGDataConsumer(data: data))
            var media = CGRect(x: 0, y: 0, width: 300, height: 400)
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
            let url = directory.appendingPathComponent("gesture.pdf")
            try (data as Data).write(to: url)
            state = PDFWorkspaceState()
            XCTAssertTrue(state.open(url: url))
            state.setMode(.editing)
            state.activeTool = .pen
            state.inkSettings.selectStyle(.fountain)
            state.inkSettings.color = .red
            state.inkSettings.pressureEnabled = false
            page = try XCTUnwrap(state.document?.page(at: 0))
            view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
            window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.document = state.document
            view.displayMode = .singlePage
            view.displayBox = .cropBox
            view.autoScales = false
            view.scaleFactor = 1
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

        func tabletMouseEvent(_ type: NSEvent.EventType, at point: CGPoint, pressure: CGFloat) throws -> NSEvent {
            let mouse = try event(type, at: point)
            let cgEvent = try XCTUnwrap(mouse.cgEvent?.copy())
            cgEvent.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            cgEvent.setDoubleValueField(.mouseEventPressure, value: Double(pressure))
            cgEvent.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
            let tablet = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            XCTAssertEqual(tablet.subtype, .tabletPoint)
            // NSEvent normalizes synthesized tablet pressure to 8-bit steps.
            XCTAssertEqual(tablet.pressure, Float(pressure), accuracy: 1.0 / 255)
            XCTAssertEqual(tablet.locationInWindow, mouse.locationInWindow)
            return tablet
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
