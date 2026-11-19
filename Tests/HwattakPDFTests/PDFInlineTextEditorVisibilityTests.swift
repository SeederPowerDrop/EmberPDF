// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInlineTextEditorVisibilityTests: XCTestCase {
    func testLightAndDarkAppearanceKeepBlackAndWhiteInkReadableWithoutChangingStyle() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for ink in [PDFTextColor.black, .white] {
                let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 246))
                panel.appearance = NSAppearance(named: name)
                let style = InlineTextStyle(fontName: "Helvetica", fontSize: 16,
                    textColor: ink, backgroundColor: .clear, alignment: .left)
                panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
                    isEditingExistingAnnotation: false, purpose: .bodyText,
                    text: "Visible text", style: style))
                panel.layoutSubtreeIfNeeded()
                let editor = panel.textView
                XCTAssertTrue(editor.drawsBackground)
                let background = PDFTextColor(editor.backgroundColor)
                XCTAssertEqual(background.alpha, 1)
                XCTAssertTrue(background.visuallyEquals(ink == .black ? .white : .black))
                XCTAssertTrue(PDFTextColor(editor.textColor).visuallyEquals(ink))
                XCTAssertTrue(PDFTextColor(editor.insertionPointColor).visuallyEquals(ink))
                XCTAssertNotNil(editor.selectedTextAttributes[.foregroundColor])
                XCTAssertEqual(panel.currentStyle, style)
                if let directory = ProcessInfo.processInfo.environment["EMBER_BODY_EDITOR_QA_DIRECTORY"],
                   let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                    panel.cacheDisplay(in: panel.bounds, to: bitmap)
                    let folder = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let suffix = ink == .black ? "black-ink" : "white-ink"
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: folder.appendingPathComponent("editor-\(name.rawValue)-\(suffix).png"))
                }
            }
        }
    }

    func testDetachingAndRestoringBodyCanvasPreservesTextStyleAndTracksZoom() throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 114))
        host.addSubview(panel)
        panel.setBodyPresentation(in: host)
        let style = InlineTextStyle(fontName: "Helvetica", fontSize: 16,
            textColor: .black, backgroundColor: .clear, alignment: .left)
        panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
            isEditingExistingAnnotation: false, purpose: .bodyText,
            text: "Edit directly on the page", style: style))
        panel.textScrollView.frame = CGRect(x: 20, y: 160, width: 400, height: 50)
        panel.setTextPresentationScale(2)
        XCTAssertTrue(panel.textScrollView.superview === host)
        XCTAssertFalse(panel.textView.isDescendant(of: panel))
        XCTAssertEqual(panel.textView.font?.pointSize, 32)
        XCTAssertEqual(panel.currentStyle, style)
        XCTAssertEqual(panel.currentText, "Edit directly on the page")
        XCTAssertGreaterThan(panel.textView.frame.width, 100)
        panel.setBodyPresentation(in: nil)
        panel.frame.size.height = 246
        panel.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.textView.isDescendant(of: panel))
        XCTAssertEqual(panel.textView.font?.pointSize, 16)
        XCTAssertEqual(panel.currentStyle, style)
    }

    func testExistingBodyTextRendersInsideTheEditorAndTracksResize() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 246))
        window.contentView?.addSubview(panel)
        let text = "Confirmation de la validation de l’enregistrement de votre demande de séjour"
        let style = InlineTextStyle(fontName: "Helvetica-Bold", fontSize: 16,
                                    textColor: .black, backgroundColor: .clear, alignment: .left)
        panel.configure(with: PendingInlineTextEdit(pageIndex: 0,
            bounds: CGRect(x: 20, y: 100, width: 450, height: 30),
            isEditingExistingAnnotation: false, purpose: .bodyText, text: text, style: style))
        panel.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(descendants(of: PDFInlineTextView.self, in: panel).first)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let container = try XCTUnwrap(editor.textContainer)
        let layout = try XCTUnwrap(editor.layoutManager)
        layout.ensureLayout(for: container)

        XCTAssertEqual(editor.string, text)
        XCTAssertGreaterThan(editor.frame.width, 100, "A zero-width NSTextView silently paints no text even with a visible insertion caret.")
        XCTAssertEqual(editor.frame.width, scrollView.contentSize.width, accuracy: 1)
        XCTAssertGreaterThan(container.containerSize.width, 100)
        XCTAssertGreaterThan(layout.numberOfGlyphs, 50)
        XCTAssertGreaterThan(layout.usedRect(for: container).height, 10)
        XCTAssertGreaterThan(renderedDarkPixelCount(in: editor), 100, "The actual text canvas must render visible glyphs, not merely retain its string.")
        XCTAssertEqual(panel.currentStyle, style, "Editing canvas appearance must not alter the PDF's colors or font.")

        let originalWidth = editor.frame.width
        panel.frame.size.width = 340
        panel.layoutSubtreeIfNeeded()
        layout.ensureLayout(for: container)
        XCTAssertLessThan(editor.frame.width, originalWidth)
        XCTAssertEqual(editor.frame.width, scrollView.contentSize.width, accuracy: 1)
        XCTAssertGreaterThan(container.containerSize.width, 100)
        XCTAssertGreaterThan(renderedDarkPixelCount(in: editor), 100)
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { view in
            let current = (view as? T).map { [$0] } ?? []
            return current + descendants(of: type, in: view)
        }
    }

    private func renderedDarkPixelCount(in textView: NSTextView) -> Int {
        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else { return 0 }
        textView.cacheDisplay(in: textView.bounds, to: bitmap)
        var darkPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.8,
                   max(color.redComponent, color.greenComponent, color.blueComponent) < 0.3 {
                    darkPixels += 1
                }
            }
        }
        return darkPixels
    }
}
